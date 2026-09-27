-- feature_build_preview.lua
--
-- 1.0 delivery uses a native anchor placement, not the removed PreviewPiece
-- transform field. Begin preflights and selects an anchor; the one-shot
-- Server_SpawnBuilding observer copies its transform, then deferred work
-- queues only the remaining capture records. Legacy probes stay explicit.

local M = {}

local feature_actor = require("feature_actor")
local build_access = require("feature_build_access")
local mod_paths = require("mod_paths")
local feature_buildings = require("feature_buildings")
local native_placement = require("feature_build_placement_probe")
local feature_grab = require("feature_grab")

-- Registry of every actor we've spawned in preview mode so
-- build.preview.clear can destroy them all in one sweep. Keyed by
-- actor:GetFullName() to dedupe across re-runs ; value is the actor
-- userdata. Cleaned of dead entries on every clear().
M._phantoms = {}

local PIECE_ARM_COOLDOWN_SECONDS = 0.35
local last_piece_arm_at = 0

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

-- ---------------------------------------------------------------------------
-- Locate the local player controller and its UBuildModeComponent.
-- Mirrors feature_buildings.get_local_pc_and_bmc ; duplicated here
-- (rather than required cross-module) so phase-0 has zero coupling
-- with the export/import code path.
-- ---------------------------------------------------------------------------
local function get_local_pc_and_bmc()
    local feature_net = require("feature_net")
    local pc = feature_net.local_controller()
    if not is_valid(pc) then return nil, nil, "no player controller" end

    local bmc
    pcall(function() bmc = pc.BuildModeComponent end)
    if not is_valid(bmc) and pc.GetBuildModeComponent then
        pcall(function() bmc = pc:GetBuildModeComponent() end)
    end
    if not is_valid(bmc) then return pc, nil, "no BuildModeComponent on player controller" end
    return pc, bmc, nil
end

-- ---------------------------------------------------------------------------
-- TWeakObjectPtr -> live UObject. UE4SS exposes weak ptrs as userdata
-- with a Get() method that returns the resolved object or nil/stale.
-- Fall back to a plain dereference when the wrapper is already a hard
-- pointer (varies by UE4SS version).
-- ---------------------------------------------------------------------------
local function deref_weak(weak)
    if weak == nil then return nil end
    if type(weak) == "userdata" then
        if weak.Get then
            local ok, hard = pcall(function() return weak:Get() end)
            if ok and is_valid(hard) then return hard end
        end
        if is_valid(weak) then return weak end
    end
    return nil
end

local function obj_name_or_nil(obj)
    if not is_valid(obj) then return nil end
    local s
    pcall(function() s = obj:GetFullName() end)
    if type(s) == "string" then return s end
    return nil
end

local BUILD_MODE_NAMES = {
    [0] = "None",
    [1] = "Selection",
    [2] = "Placement",
    [3] = "RepairAndEdit",
}

local function coerce_build_mode(value)
    if type(value) == "number" then return math.floor(value) end
    local text = tostring(value or "")
    local numeric = tonumber(text)
    if numeric then return math.floor(numeric) end
    local lowered = text:lower()
    for id, name in pairs(BUILD_MODE_NAMES) do
        if lowered:find(name:lower(), 1, true) then return id end
    end
    return nil
end

local function read_build_mode(bmc)
    local raw_mode
    pcall(function() raw_mode = bmc.CurrentBuildMode end)
    local mode_id = coerce_build_mode(raw_mode)
    if mode_id == nil and bmc.GetCurrentBuildMode then
        local ok_mode, getter_mode = pcall(function() return bmc:GetCurrentBuildMode() end)
        if ok_mode then
            raw_mode = getter_mode
            mode_id = coerce_build_mode(getter_mode)
        end
    end
    return mode_id, BUILD_MODE_NAMES[mode_id] or tostring(raw_mode or "Unknown"), raw_mode
end

local function read_prev_build_mode(bmc)
    local raw_mode
    pcall(function() raw_mode = bmc.PrevBuildMode end)
    local mode_id = coerce_build_mode(raw_mode)
    if mode_id == nil and bmc.GetPrevBuildMode then
        local ok_mode, getter_mode = pcall(function() return bmc:GetPrevBuildMode() end)
        if ok_mode then
            raw_mode = getter_mode
            mode_id = coerce_build_mode(getter_mode)
        end
    end
    return mode_id, BUILD_MODE_NAMES[mode_id] or tostring(raw_mode or "Unknown"), raw_mode
end

local function piece_arm_cooldown_remaining(now)
    local elapsed = now - last_piece_arm_at
    if last_piece_arm_at > 0 and elapsed >= 0 and elapsed < PIECE_ARM_COOLDOWN_SECONDS then
        return PIECE_ARM_COOLDOWN_SECONDS - elapsed
    end
    return 0
end

local function obj_class_name_or_nil(obj)
    if not is_valid(obj) then return nil end
    local cls
    pcall(function() cls = obj:GetClass() end)
    if not is_valid(cls) then return nil end
    local s
    pcall(function() s = cls:GetFullName() end)
    if type(s) == "string" then return s end
    return nil
end

local function actor_xform_or_nil(actor)
    if not is_valid(actor) then return nil end
    local rec = {}
    if actor.K2_GetActorLocation then
        local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
        if ok and loc then
            pcall(function() rec.x = loc.X end)
            pcall(function() rec.y = loc.Y end)
            pcall(function() rec.z = loc.Z end)
        end
    end
    if actor.K2_GetActorRotation then
        local ok, rot = pcall(function() return actor:K2_GetActorRotation() end)
        if ok and rot then
            pcall(function() rec.yaw = rot.Yaw end)
            pcall(function() rec.pitch = rot.Pitch end)
            pcall(function() rec.roll = rot.Roll end)
        end
    end
    return rec
end

function M.current_preview_piece()
    local pc, bmc, err = get_local_pc_and_bmc()
    if not bmc then
        return nil, nil, pc, "build mode unavailable: " .. tostring(err)
    end

    local preview_weak
    pcall(function() preview_weak = bmc.PreviewPiece end)
    local preview = deref_weak(preview_weak)
    if not is_valid(preview) then
        return nil, bmc, pc, "no PreviewPiece on BuildModeComponent"
    end
    return preview, bmc, pc, nil
end

-- ---------------------------------------------------------------------------
-- build.preview probe
--
-- Read-only diagnostic. Prints (to UE4SS log) the live state of the
-- local UBuildModeComponent so we can confirm:
--   * we can find the BMC at all
--   * CurrentBuildMode reads as a number/byte we can use
--   * CurrentlyPlacingPieceData and PreviewPiece are reachable when
--     the player has a piece in hand
--   * PreviewPiece's transform updates frame-to-frame (run probe
--     twice while moving the reticle to spot-check)
--
-- Run this verb twice in-game:
--   1) Idle, not in build mode
--   2) Holding any building piece in build mode
-- The contrast tells us which fields are nil vs populated when, which
-- is the foundation every later phase depends on.
-- ---------------------------------------------------------------------------
function M.probe()
    local pc, bmc, err = get_local_pc_and_bmc()
    if not bmc then
        return false, "build mode unavailable: " .. tostring(err)
    end

    local pc_name  = obj_name_or_nil(pc)  or "<unknown>"
    local bmc_name = obj_name_or_nil(bmc) or "<unknown>"

    local current_mode, prev_mode
    pcall(function() current_mode = bmc.CurrentBuildMode end)
    pcall(function() prev_mode    = bmc.PrevBuildMode end)
    -- Some UE4SS versions also expose the BP getter; try it as backup.
    if current_mode == nil and bmc.GetCurrentBuildMode then
        pcall(function() current_mode = bmc:GetCurrentBuildMode() end)
    end

    local placing_data_weak, preview_weak, support_weak
    pcall(function() placing_data_weak = bmc.CurrentlyPlacingPieceData end)
    pcall(function() preview_weak      = bmc.PreviewPiece end)
    pcall(function() support_weak      = bmc.PreviewSupportingPiece end)

    local placing_data = deref_weak(placing_data_weak)
    local preview      = deref_weak(preview_weak)
    local support      = deref_weak(support_weak)

    local placing_name = obj_name_or_nil(placing_data) or "<nil>"
    local preview_name = obj_name_or_nil(preview)      or "<nil>"
    local preview_cls  = obj_class_name_or_nil(preview) or "<nil>"
    local support_name = obj_name_or_nil(support)      or "<nil>"

    local preview_xform = actor_xform_or_nil(preview)
    local xform_str = "<no preview actor>"
    if preview_xform then
        xform_str = string.format(
            "loc=(%.1f, %.1f, %.1f) yaw=%.2f pitch=%.2f roll=%.2f",
            preview_xform.x   or 0/0,
            preview_xform.y   or 0/0,
            preview_xform.z   or 0/0,
            preview_xform.yaw or 0/0,
            preview_xform.pitch or 0/0,
            preview_xform.roll  or 0/0
        )
    end

    -- Quick membership probe: does the BMC actually expose the
    -- UFUNCTIONs we plan to call later? Truthy direct-index is the
    -- reliable test for UE4SS-bound UFunctions (matches the pattern
    -- used in feature_buildings.lua for Server_SpawnBuilding).
    local has_force_enter   = bmc.ForceEnterBuildMode  and true or false
    local has_exit_any      = bmc.ExitAnyMode          and true or false
    local has_on_selected   = bmc.OnPieceSelected      and true or false
    local has_server_spawn  = bmc.Server_SpawnBuilding and true or false

    print("[RSDWTools] build.preview.probe -- live UBuildModeComponent state:")
    print("  PlayerController     : " .. pc_name)
    print("  BuildModeComponent   : " .. bmc_name)
    print(string.format("  CurrentBuildMode     : %s", tostring(current_mode)))
    print(string.format("  PrevBuildMode        : %s", tostring(prev_mode)))
    print("  CurrentlyPlacingData : " .. placing_name)
    print("  PreviewPiece         : " .. preview_name)
    print("  PreviewPiece.class   : " .. preview_cls)
    print("  PreviewPiece.xform   : " .. xform_str)
    print("  PreviewSupporting    : " .. support_name)
    print(string.format(
        "  UFUNCTIONs           : ForceEnterBuildMode=%s ExitAnyMode=%s OnPieceSelected=%s Server_SpawnBuilding=%s",
        tostring(has_force_enter), tostring(has_exit_any),
        tostring(has_on_selected), tostring(has_server_spawn)))

    return true, string.format(
        "mode=%s placing=%s preview=%s",
        tostring(current_mode),
        (placing_name ~= "<nil>") and "yes" or "no",
        (preview_name ~= "<nil>") and "yes" or "no")
end

-- ---------------------------------------------------------------------------
-- Filename sanitizer mirroring feature_buildings.sanitize_name so the
-- attach1 verb accepts the same names as the existing export/import
-- verbs (and matches files under ipc/building/<name>.json).
-- ---------------------------------------------------------------------------
local function sanitize_name(name)
    name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then name = "default" end
    name = name:gsub("[^%w%-_%.]", "_")
    return name
end

local function capture_path_for(name)
    local dir = mod_paths.buildings_dir()
    if not dir then return nil end
    return dir .. "\\" .. sanitize_name(name) .. ".json"
end

-- ---------------------------------------------------------------------------
-- Pull the FIRST piece_data_name out of a capture JSON without doing a
-- full parse. The capture format (see feature_buildings.export) always
-- writes piece_data_name as a quoted string field on each entry, so a
-- regex grab of the first occurrence is sufficient for phase 1.
-- ---------------------------------------------------------------------------
local function read_first_piece_data_name(json_body)
    if type(json_body) ~= "string" then return nil end
    -- Accept "piece_data_name":"..." with optional whitespace.
    local s = json_body:match('"piece_data_name"%s*:%s*"([^"]+)"')
    return s
end

-- ---------------------------------------------------------------------------
-- Use the same exact identity/verified rename resolver for preview anchors,
-- explicit piece selection, and the rest of a delivered capture.
-- ---------------------------------------------------------------------------
local resolve_piece_data = feature_buildings._resolve_piece_data

-- ---------------------------------------------------------------------------
-- build.preview.attach1 <name>
--
-- Phase 1 sanity test for force-selecting a piece from Lua. Reads
-- ipc/building/<name>.json, extracts the first piece_data_name,
-- resolves it to a UBuildingPieceData, ensures the player is in build
-- mode, then calls UBuildModeComponent::OnPieceSelected(pieceData).
-- The engine should respond by spawning its own PreviewPiece for that
-- data ; verify by running build.preview.probe immediately after.
-- ---------------------------------------------------------------------------
function M.attach1(args_str)
    local name = sanitize_name(args_str)
    local path = capture_path_for(name)
    if not path then return false, "could not resolve mod ipc directory" end

    local body = mod_paths.read_file(path)
    if not body then return false, "could not read " .. path end

    local first_name = read_first_piece_data_name(body)
    if not first_name then
        return false, "no piece_data_name found in " .. path
    end
    print("[RSDWTools] build.preview.attach1: first piece_data_name = " .. first_name)

    local piece_data, perr = resolve_piece_data(first_name)
    if not piece_data then return false, perr end
    local resolved_full = obj_name_or_nil(piece_data) or "<unknown>"
    print("[RSDWTools] build.preview.attach1: resolved -> " .. resolved_full)

    local _pc, bmc, err = get_local_pc_and_bmc()
    if not bmc then return false, "build mode unavailable: " .. tostring(err) end

    -- Make sure we're actually in build mode. Mode 0=idle, 1=menu, 2=placing.
    -- Force-enter when idle ; the engine handles the menu->placing
    -- transition itself once OnPieceSelected fires.
    local current_mode
    pcall(function() current_mode = bmc.CurrentBuildMode end)
    if current_mode == 0 and bmc.ForceEnterBuildMode then
        print("[RSDWTools] build.preview.attach1: ForceEnterBuildMode (was idle)")
        local fok, ferr = pcall(function() bmc:ForceEnterBuildMode() end)
        if not fok then
            print("[RSDWTools] build.preview.attach1: ForceEnterBuildMode errored: " .. tostring(ferr))
        end
    end

    if not bmc.OnPieceSelected then
        return false, "BuildModeComponent has no OnPieceSelected"
    end
    local sok, serr = pcall(function() bmc:OnPieceSelected(piece_data) end)
    if not sok then
        return false, "OnPieceSelected errored: " .. tostring(serr)
    end

    print("[RSDWTools] build.preview.attach1: OnPieceSelected dispatched ; "
        .. "run build.preview.probe to confirm PreviewPiece appeared")
    return true, "selected " .. (first_name:match("([^/]+)$") or first_name)
end

-- ---------------------------------------------------------------------------
-- Read UBuildingPieceData.BuildableActor (a TSoftClassPtr<ABaseBuildingActor>)
-- and force-resolve it to a live UClass.
--
-- UE4SS's TSoftClassPtr wrapper only exposes GetAssetPathName and
-- GetSubPathString -- there's no Get/LoadSynchronous binding. So
-- "resolve via piece data" really means: ask the engine to load the
-- class for us by triggering the same OnPieceSelected path the player
-- would. That call internally LoadSynchronous'es BuildableActor and
-- spawns a PreviewPiece whose class is the now-loaded UClass.
--
-- We pull the class off PreviewPiece, then optionally clean up the
-- engine-side preview state if the caller asked for it. Caches the
-- resolved UClass keyed by the piece-data full name so subsequent
-- pieces of the same type are zero-cost.
-- ---------------------------------------------------------------------------
M._class_cache = {}

local function load_class_via_engine(piece_data, bmc)
    if not is_valid(piece_data) then return nil, "no piece_data" end
    local pd_name = obj_name_or_nil(piece_data) or "<unknown>"
    local cached = M._class_cache[pd_name]
    if is_valid(cached) then return cached end

    if not is_valid(bmc) then return nil, "no BuildModeComponent" end
    if not bmc.OnPieceSelected then return nil, "OnPieceSelected missing" end

    -- ForceEnterBuildMode if idle so OnPieceSelected actually spawns
    -- a PreviewPiece. Mode 0=idle, 1=menu, 2=placing.
    local current_mode
    pcall(function() current_mode = bmc.CurrentBuildMode end)
    if current_mode == 0 and bmc.ForceEnterBuildMode then
        pcall(function() bmc:ForceEnterBuildMode() end)
    end

    local sok, serr = pcall(function() bmc:OnPieceSelected(piece_data) end)
    if not sok then
        return nil, "OnPieceSelected errored: " .. tostring(serr)
    end

    -- The engine sets PreviewPiece synchronously inside OnPieceSelected
    -- (the load + spawn happens on the same call) so we can read it
    -- back immediately.
    local preview_weak
    pcall(function() preview_weak = bmc.PreviewPiece end)
    local preview = deref_weak(preview_weak)
    if not is_valid(preview) then
        return nil, "PreviewPiece still nil after OnPieceSelected"
    end

    local cls
    pcall(function() cls = preview:GetClass() end)
    if not is_valid(cls) then
        return nil, "PreviewPiece:GetClass() failed"
    end

    M._class_cache[pd_name] = cls

    -- Destroy the engine's preview directly so it doesn't leak as a
    -- real building when we exit. ExitAnyMode alone doesn't reliably
    -- clean it up ; we proved that with the +91-actor leak in Phase 2.
    pcall(function() preview:K2_DestroyActor() end)
    if bmc.ExitAnyMode then
        pcall(function() bmc:ExitAnyMode() end)
    end

    return cls
end

-- Legacy fallback. Kept because for Phase 2 we may want to spawn
-- without first selecting (e.g. capture's first piece IS the anchor,
-- but companions don't need engine-side selection). If this proves
-- robust enough we'll fold it in ; for now Phase 1.5 prefers the
-- engine-route above.
local function resolve_actor_class(class_name_full)
    if type(class_name_full) ~= "string" then return nil, "no class_name" end
    local _, path = class_name_full:match("^(%S+)%s+(.+)$")
    if not path then path = class_name_full end

    if not StaticFindObject then return nil, "StaticFindObject unavailable" end
    local cls
    pcall(function() cls = StaticFindObject(path) end)
    if is_valid(cls) then return cls end

    local pkg = path:match("^(.+)%.[^%.]+$") or path
    if LoadAsset then
        pcall(LoadAsset, pkg)
        pcall(function() cls = StaticFindObject(path) end)
        if is_valid(cls) then return cls end
    end
    return nil, "could not resolve actor class: " .. path
end

-- ---------------------------------------------------------------------------
-- Resolve the local UWorld. Mirrors UEHelpers.GetWorld but doesn't
-- hard-require UEHelpers (we already pull it in main.lua so it's
-- usually present, but the require has been spotty in some build paths).
-- ---------------------------------------------------------------------------
local function get_world()
    local pawn = feature_actor.get_local_pawn()
    if is_valid(pawn) and pawn.GetWorld then
        local ok, w = pcall(function() return pawn:GetWorld() end)
        if ok and is_valid(w) then return w end
    end
    local ok_req, ue = pcall(require, "UEHelpers")
    if ok_req and ue and ue.GetWorld then
        local ok, w = pcall(ue.GetWorld)
        if ok and is_valid(w) then return w end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Compute a spawn location 300 units in front of the local pawn so the
-- spawned phantom lands somewhere visible without colliding with the
-- player. Falls back to pawn location if rotation read fails.
-- ---------------------------------------------------------------------------
local function spot_in_front_of_pawn(distance)
    distance = distance or 300.0
    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return nil end

    local loc
    pcall(function() loc = pawn:K2_GetActorLocation() end)
    if not loc then return nil end

    local rot
    pcall(function() rot = pawn:K2_GetActorRotation() end)
    local yaw_deg = (rot and rot.Yaw) or 0.0
    local yaw_rad = yaw_deg * math.pi / 180.0
    local fx, fy = math.cos(yaw_rad), math.sin(yaw_rad)
    return {
        X = (loc.X or 0) + fx * distance,
        Y = (loc.Y or 0) + fy * distance,
        Z = (loc.Z or 0),
    }, yaw_deg
end

-- ---------------------------------------------------------------------------
-- Mark a freshly-spawned ABaseBuildingActor as a phantom: bIsPreview
-- so engine code that checks IsPreview() short-circuits (interaction,
-- targeting, save serialization), bIgnoreReplicationManager so the
-- replication bookkeeping leaves it alone, and OnGhostStateChanged(true)
-- as a best-effort BP-event nudge in case the BP graph swaps to the
-- ghost material on that callback.
-- ---------------------------------------------------------------------------
local function configure_phantom(actor)
    if not is_valid(actor) then return end
    -- Phase 2 debug pass: do NOT set bIsPreview / bIgnoreReplicationManager.
    -- Those flags appear to make ABaseBuildingActor hide its mesh until
    -- the full placement pipeline (PieceID, replication, etc.) wires in.
    -- We just want to SEE the phantoms right now ; cosmetic ghosting is
    -- a Phase 2.5 problem. We accept the world.buildings.count
    -- pollution that comes with leaving them as full-fat buildings.
    pcall(function() actor.bIsGhosted = true end)
end

-- ---------------------------------------------------------------------------
-- build.preview.spawn1 <name>
--
-- Phase 1.5 sanity test for the spawn pipeline. Reads the first piece
-- from ipc/building/<name>.json, resolves its UClass, spawns a SINGLE
-- phantom 300 units in front of the player, and registers it in
-- M._phantoms for cleanup.
--
-- Validates (without yet involving the reticle / attachment / math):
--   * UWorld:SpawnActor works for these BPs
--   * bIsPreview / bIsGhosted / OnGhostStateChanged produce a usable
--     ghost visual rather than a fully-built piece
--   * the actor doesn't immediately register itself as a real building
--     (run world.buildings.count before+after to spot pollution)
-- ---------------------------------------------------------------------------
function M.spawn1(args_str)
    local name = sanitize_name(args_str)
    local path = capture_path_for(name)
    if not path then return false, "could not resolve mod ipc directory" end

    local body = mod_paths.read_file(path)
    if not body then return false, "could not read " .. path end

    local pieces, perr = feature_buildings._parse_pieces(body)
    if not pieces then return false, "JSON parse: " .. tostring(perr) end
    if #pieces == 0 then return false, "no pieces in JSON" end

    local first = pieces[1]
    if type(first.class_name) ~= "string" then
        return false, "first piece has no class_name"
    end

    local _pc, bmc, berr = get_local_pc_and_bmc()
    if not bmc then return false, "build mode unavailable: " .. tostring(berr) end

    -- Resolution strategy: ask the engine to load the BP class for us
    -- via OnPieceSelected -> PreviewPiece:GetClass(). UE4SS's TSoftClassPtr
    -- wrapper has no Get/LoadSynchronous, and bare LoadAsset on these
    -- BP_*_C classes is unreliable cold ; the engine's blessed path
    -- always works because that's what the in-game placement uses.
    local cls, cerr
    if type(first.piece_data_name) == "string" then
        print("[RSDWTools] build.preview.spawn1: piece_data_name = " .. first.piece_data_name)
        local pd, perr2 = resolve_piece_data(first.piece_data_name)
        if pd then
            cls, cerr = load_class_via_engine(pd, bmc)
            if cls then
                print("[RSDWTools] build.preview.spawn1: class via engine PreviewPiece -> "
                    .. (obj_name_or_nil(cls) or "<unknown>"))
            else
                print("[RSDWTools] build.preview.spawn1: engine-route resolve failed: "
                    .. tostring(cerr))
            end
        else
            print("[RSDWTools] build.preview.spawn1: piece_data resolve failed: "
                .. tostring(perr2))
        end
    end

    -- Fallback: try the class_name string directly. May still race-fail.
    if not cls then
        print("[RSDWTools] build.preview.spawn1: falling back to class_name path = "
            .. first.class_name)
        cls, cerr = resolve_actor_class(first.class_name)
        if not cls then return false, cerr end
        print("[RSDWTools] build.preview.spawn1: resolved class -> "
            .. (obj_name_or_nil(cls) or "<unknown>"))
    end

    local world = get_world()
    if not is_valid(world) then return false, "no UWorld" end
    if not world.SpawnActor then return false, "UWorld:SpawnActor missing in this UE4SS build" end

    local loc, yaw = spot_in_front_of_pawn(300.0)
    if not loc then return false, "could not compute spawn location (no pawn?)" end
    local rot = { Pitch = 0, Yaw = yaw or 0, Roll = 0 }

    local spawned
    local sok, serr = pcall(function()
        spawned = world:SpawnActor(cls, loc, rot)
    end)
    if not sok then
        return false, "SpawnActor errored: " .. tostring(serr)
    end
    if not is_valid(spawned) then
        return false, "SpawnActor returned nil/invalid"
    end

    local spawned_name = obj_name_or_nil(spawned) or "<unknown>"
    print(string.format(
        "[RSDWTools] build.preview.spawn1: spawned %s at (%.1f, %.1f, %.1f) yaw=%.1f",
        spawned_name, loc.X, loc.Y, loc.Z, yaw or 0))

    configure_phantom(spawned)
    M._phantoms[spawned_name] = spawned

    print("[RSDWTools] build.preview.spawn1: configured as phantom (bIsPreview, bIsGhosted) ; "
        .. "use build.preview.clear to destroy")
    return true, "spawned " .. (spawned_name:match("([^/]+)$") or spawned_name)
end

-- ---------------------------------------------------------------------------
-- build.preview.clear
--
-- Destroy every phantom tracked in M._phantoms. Idempotent: stale or
-- already-destroyed entries are skipped. Always clears the registry
-- at the end so a partial failure doesn't leave us stuck.
-- ---------------------------------------------------------------------------
function M.clear()
    local destroyed, skipped = 0, 0
    for k, actor in pairs(M._phantoms) do
        if is_valid(actor) then
            local ok = pcall(function() actor:K2_DestroyActor() end)
            if ok then destroyed = destroyed + 1
            else skipped = skipped + 1 end
        else
            skipped = skipped + 1
        end
        M._phantoms[k] = nil
    end
    print(string.format("[RSDWTools] build.preview.clear: destroyed=%d skipped=%d",
        destroyed, skipped))
    return true, string.format("destroyed=%d skipped=%d", destroyed, skipped)
end

-- ---------------------------------------------------------------------------
-- build.preview.preview <name> [max]
--
-- Phase 2: spawn the WHOLE capture as phantoms anchored to the
-- reticle. The capture's first piece becomes the origin ; every other
-- piece is positioned by its delta from that origin, rotated so the
-- build faces the same direction the pawn is facing, and translated
-- onto the reticle spot in front of the pawn.
--
-- ---------------------------------------------------------------------------
-- build.preview.preview <name> [anchor_piece_data_index]
--
-- ENGINE-DRIVEN PREVIEW + COMMIT REPLAY.
--
-- Phase-2 redesign after we proved the spawn-everything-as-phantoms
-- approach paints actors all over the world for any capture whose
-- "first piece" is far from the rest. Instead, we lean on the engine:
--
--   1. Pre-pass: resolve every unique piece_data_name -> UClass via
--      load_class_via_engine (which destroys the engine's preview
--      after reading its class so nothing leaks).
--   2. Re-select the first piece via OnPieceSelected. Engine puts a
--      real PreviewPiece on the player's reticle with the proper
--      ghost material, snap behaviour, collision validity, etc.
--   3. RegisterHook on UBuildModeComponent::Server_SpawnBuilding.
--      The player aims and clicks normally. When the engine fires
--      Server_SpawnBuilding for the anchor piece:
--        a. Read the committed FTransform (location + yaw).
--        b. delta_xyz = committed_xyz - first.xyz
--           delta_yaw = committed_yaw - first.yaw
--        c. For each remaining piece, compute its world transform
--           by translating + rotating around the anchor, then call
--           bmc:Server_SpawnBuilding(p.piece_data_index, xform,
--           false, {}). Same primitive world.buildings.import uses.
--        d. UnregisterHook.
--
--   4. M.cancel does ExitAnyMode + UnregisterHook + clear session,
--      for when the player wants to bail without committing.
--
-- The user only ever sees ONE piece on the reticle (the anchor). The
-- whole rest of the build snaps in instantly when they commit.
-- ---------------------------------------------------------------------------
local function rotate_xy(dx, dy, cos_t, sin_t)
    return dx * cos_t - dy * sin_t,
           dx * sin_t + dy * cos_t
end

-- Convert a UE FQuat (FTransform.Rotation) yaw component to degrees.
-- For a yaw-only quaternion (X=0, Y=0): yaw = 2 * atan2(Z, W) (rad).
-- For the general case: yaw = atan2(2*(W*Z + X*Y), 1 - 2*(Y*Y + Z*Z)).
local function quat_to_yaw_deg(q)
    if not q then return 0.0 end
    local qx = tonumber(q.X) or 0
    local qy = tonumber(q.Y) or 0
    local qz = tonumber(q.Z) or 0
    local qw = tonumber(q.W) or 1
    local sin_yaw_cos_pitch = 2.0 * (qw * qz + qx * qy)
    local cos_yaw_cos_pitch = 1.0 - 2.0 * (qy * qy + qz * qz)
    return math.atan(sin_yaw_cos_pitch, cos_yaw_cos_pitch) * 180.0 / math.pi
end

-- Active session state. Set by M.preview, cleared by the hook callback
-- (after replay) or M.cancel.
M._session = nil

local function clear_session()
    if not M._session then return end
    if M._session.delivery_id then native_placement.clear() end
    -- preview_full leaves a silhouette_root + N silhouette ghost actors
    -- in the world. Destroy them all so they don't pollute the world
    -- after commit / cancel / re-arm. Stops the tracking LoopAsync via
    -- the loop_armed gate (the loop returns true when it sees the
    -- session has been dropped).
    if M._session.full then
        M._session.loop_armed = false
        if type(M._session.silhouettes) == "table" then
            for _, s in pairs(M._session.silhouettes) do
                if is_valid(s) then
                    pcall(function() s:K2_DestroyActor() end)
                end
            end
        end
        if is_valid(M._session.silhouette_root) then
            pcall(function() M._session.silhouette_root:K2_DestroyActor() end)
        end
    end
    M._session = nil
end

function M.preview(args_str)
    args_str = args_str or ""
    local name = sanitize_name(args_str:match("^(%S+)") or args_str)
    -- Optional second token: piece_data_index to use as the reticle
    -- anchor. When the JSON contains a piece with this index we move
    -- it to position 1 so the rest of the existing logic (first-piece
    -- anchor, deltas computed against pieces[1]) works unchanged.
    -- Falls back to pieces[1] when not found, matching legacy behaviour.
    --
    -- If no explicit anchor arg is supplied, we'll also look in the
    -- JSON top level for "anchor_piece_data_index" written there at
    -- capture time by world.buildings.export anchor=<idx>. This is the
    -- preferred path now ; the verb arg is kept for one-off overrides.
    local anchor_arg = args_str:match("^%S+%s+(%S+)")
    local desired_anchor_idx = tonumber(anchor_arg)

    -- Safety: never have two sessions overlap. If one exists, cancel it
    -- silently so a stale hook doesn't replay onto the new commit.
    if M._session then
        if feature_buildings._delivery_active then return false, "delivery already active; finish/cancel it first" end
        print("[RSDWTools] build.preview.preview: clearing previous session")
        clear_session()
    end

    local path = capture_path_for(name)
    if not path then return false, "could not resolve mod ipc directory" end
    local body = mod_paths.read_file(path)
    if not body then return false, "could not read " .. path end

    -- No explicit verb arg ; look for capture-time anchor in JSON.
    -- Tolerant regex : handles whitespace and signed ints. Lives at
    -- the top level of the object so the simple substring match below
    -- doesn't risk false hits inside the pieces array.
    --
    -- New captures also write "anchor_piece_id" (per-instance unique)
    -- which we prefer when present : it picks the exact actor the
    -- user pointed at rather than just any piece sharing its
    -- piece_data_index. Note that with the new export path the anchor
    -- is already at pieces[1] so this is mostly defensive ; older
    -- captures relied on lookup-then-promote here.
    local desired_anchor_pid = nil
    if not desired_anchor_idx then
        local stored_pid = body:match('"anchor_piece_id"%s*:%s*(%-?%d+)')
        if stored_pid then desired_anchor_pid = tonumber(stored_pid) end
        local stored = body:match('"anchor_piece_data_index"%s*:%s*(%-?%d+)')
        if stored then
            desired_anchor_idx = tonumber(stored)
            if desired_anchor_idx then
                print(string.format(
                    "[RSDWTools] build.preview.preview: using capture-time anchor idx=%d pid=%s from JSON",
                    desired_anchor_idx, tostring(desired_anchor_pid)))
            end
        end
    end

    if not (feature_buildings and feature_buildings._parse_pieces) then
        return false, "feature_buildings._parse_pieces not exposed"
    end
    local pieces, perr = feature_buildings._parse_pieces(body)
    if not pieces then return false, "JSON parse: " .. tostring(perr) end
    if #pieces == 0 then return false, "no pieces in JSON" end
    local items = {}
    if feature_buildings._parse_items then
        local parsed_items, ierr = feature_buildings._parse_items(body)
        if parsed_items then
            items = parsed_items
        else
            return false, "item parse: " .. tostring(ierr)
        end
    end
    local actors = {}
    if feature_buildings._parse_actors then
        local parsed_actors, aerr = feature_buildings._parse_actors(body)
        if parsed_actors then
            actors = parsed_actors
        else
            return false, "actor parse: " .. tostring(aerr)
        end
    end

    -- Honour the user-picked anchor by promoting the matching piece
    -- to position 1. We try piece_id first (per-instance, unique),
    -- then fall back to piece_data_index (archetype, first match).
    -- If neither hits we leave pieces unchanged ; the legacy
    -- "first piece is the anchor" path handles it.
    if desired_anchor_pid or desired_anchor_idx then
        local found_at = nil
        if desired_anchor_pid then
            for i, p in ipairs(pieces) do
                if type(p.piece_id) == "number" and p.piece_id == desired_anchor_pid then
                    found_at = i
                    break
                end
            end
        end
        if not found_at and desired_anchor_idx then
            for i, p in ipairs(pieces) do
                if type(p.piece_data_index) == "number"
                   and p.piece_data_index == desired_anchor_idx then
                    found_at = i
                    break
                end
            end
        end
        if found_at and found_at > 1 then
            local anchor = table.remove(pieces, found_at)
            table.insert(pieces, 1, anchor)
            print(string.format(
                "[RSDWTools] build.preview.preview: anchor (pid=%s idx=%s) found at original index %d, promoted to first",
                tostring(desired_anchor_pid), tostring(desired_anchor_idx), found_at))
        elseif not found_at then
            print(string.format(
                "[RSDWTools] build.preview.preview: anchor (pid=%s idx=%s) not present in build, falling back to first piece",
                tostring(desired_anchor_pid), tostring(desired_anchor_idx)))
        end
    end

    local first = pieces[1]
    if type(first.x) ~= "number" or type(first.y) ~= "number" or type(first.z) ~= "number" then
        return false, "first piece missing x/y/z"
    end
    if type(first.piece_data_name) ~= "string" then
        return false, "first piece missing piece_data_name"
    end

    local _pc, bmc, berr = get_local_pc_and_bmc()
    if not bmc then return false, "build mode unavailable: " .. tostring(berr) end
    if not bmc.OnPieceSelected then return false, "BMC has no OnPieceSelected" end
    if not bmc.Server_SpawnBuilding then return false, "BMC has no Server_SpawnBuilding" end

    local checked, check_error = feature_buildings._queue_piece_delivery({
        entries = pieces, item_entries = items, actor_entries = actors, bmc = bmc, validate_only = true,
    })
    if not checked then return false, check_error end

    -- ----- Build piece_data_index map. Server_SpawnBuilding takes the
    -- index (an int), not a UClass, so we don't need a class warmup
    -- pass. We just need to make sure every piece either has its
    -- piece_data_index set in the JSON, or we can fill it in from a
    -- sibling piece that uses the same piece_data_name.
    local idx_by_pd = {}
    for _, p in ipairs(pieces) do
        if type(p.piece_data_name) == "string"
           and type(p.piece_data_index) == "number"
           and not idx_by_pd[p.piece_data_name] then
            idx_by_pd[p.piece_data_name] = p.piece_data_index
        end
    end

    -- ----- Resolve the first piece data, then drive engine into
    -- placing mode with it on the reticle. The user gets the engine's
    -- own preview. The anchor must be a valid native placement; its
    -- placement RPC supplies the final transform for the remainder.
    local first_pd, fperr = resolve_piece_data(first.piece_data_name)
    if not first_pd then return false, "could not resolve first piece_data: " .. tostring(fperr) end

    -- Make sure we're idle before kicking the engine into placing.
    -- If we left a previous session in placing/menu state, OnPieceSelected
    -- can no-op or spawn the preview into a bad state.
    if bmc.ExitAnyMode then
        pcall(function() bmc:ExitAnyMode() end)
        pcall(function() bmc:ExitAnyMode() end)
    end

    if bmc.ForceEnterBuildMode then
        pcall(function() bmc:ForceEnterBuildMode() end)
    end
    local sok, serr = pcall(function() bmc:OnPieceSelected(first_pd) end)
    if not sok then
        return false, "OnPieceSelected errored: " .. tostring(serr)
    end

    -- 1.0 exposes selected data/mode, not the preview actor or its transform.
    if not build_access.selection_matches(bmc, first_pd) then
        if bmc.ExitAnyMode then pcall(function() bmc:ExitAnyMode() end) end
        return false, "engine did not enter placement mode with the requested anchor"
    end

    M._session = {
        name        = name,
        pieces      = pieces,
        items       = items,
        actors      = actors,
        first       = first,
        idx_by_pd   = idx_by_pd,
        bmc         = bmc,
    }

    print(string.format(
        "[RSDWTools] build.preview.preview: session armed, %d pieces queued, %d items queued, %d actors queued ; aim with the engine's reticle preview, then run build.preview.commit (or build.preview.cancel)",
        #pieces, #items, #actors))
    return true, string.format("armed pieces=%d items=%d actors=%d", #pieces, #items, #actors)
end

-- ---------------------------------------------------------------------------
-- build.preview.preview_full <name>
--
-- Same arming as build.preview.preview, but ALSO spawns the entire
-- rest of the capture as ghost silhouettes attached to a parent actor
-- that follows the engine's reticle preview. The user sees the whole
-- structure as a translucent ghost on their cursor instead of just
-- the first piece, then commits with build.preview.commit (which
-- destroys the silhouettes and replays the real Server_SpawnBuilding
-- pipeline at whatever transform the reticle preview is at).
--
-- HOW IT WORKS (option C, fixed):
--
--   The naive "use the engine's PreviewPiece as silhouette parent"
--   approach (first attempt) crashed because OnPieceSelected destroys
--   the prior PreviewPiece on every call ; our parent disappeared
--   under us. The fixed pipeline never reuses engine-managed actors:
--
--   Phase A (staggered class resolution):
--     For each unique piece_data, drive load_class_via_engine which
--     OnPieceSelected -> reads PreviewPiece:GetClass() ->
--     K2_DestroyActor -> ExitAnyMode. One call per LoopAsync tick so
--     BMC's BuildPlacementComponent doesn't get stuck (we proved an
--     81-call synchronous burst breaks BMC -- bug H from the prior
--     session).
--
--   Phase B (silhouette spawn):
--     world:SpawnActor(piece_1_class) at a far-away location ->
--     silhouette_root. configure_silhouette to ghost it. Then for
--     every remaining piece, world:SpawnActor(piece_class) at the
--     anchor + capture-relative offset, AttachToActor(silhouette_root,
--     KeepRelative). Multiple spawns per tick is fine here because we
--     are NOT touching BMC.
--
--   Phase C (reticle + tracking):
--     OnPieceSelected(piece_1_pd) so the engine paints a clean
--     piece_1 ghost on the user's reticle. Start a LoopAsync that
--     copies reticle PreviewPiece transform -> silhouette_root every
--     frame. All silhouettes follow via attachment.
--
--   M.commit destroys silhouettes/silhouette_root before replaying
--   via Server_SpawnBuilding so we don't leave ghost shells
--   overlapping the real spawns.
--
-- COSTS:
--   * Phase A: 25ms * unique_pd_count (e.g. 45 unique = ~1.1s).
--   * Phase B: SILHOUETTE_BATCH_PER_TICK * 25ms per batch. For 1781
--     pieces at batch=20 -> ~2.2s. Adjust SILHOUETTE_BATCH_PER_TICK
--     for very large captures.
--   * Phase C: one transform read + write per frame regardless of N.
-- ---------------------------------------------------------------------------
local SILHOUETTE_STAGGER_MS     = 25
local SILHOUETTE_TRACK_MS       = 16
local SILHOUETTE_BATCH_PER_TICK = 20

local function table_size(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function configure_silhouette(actor)
    if not is_valid(actor) then return end
    pcall(function() actor:SetActorEnableCollision(false) end)
    pcall(function() actor.bIsGhosted = true end)
    pcall(function() actor.bIsPreview = true end)
    pcall(function() actor.bIgnoreReplicationManager = true end)
end

local function start_silhouette_tracking_loop()
    if not LoopAsync then
        print("[RSDWTools] build.preview.preview_full: LoopAsync unavailable, silhouettes won't follow reticle")
        return
    end
    LoopAsync(SILHOUETTE_TRACK_MS, function()
        local sess = M._session
        if not sess or not sess.full or not sess.loop_armed then
            return true -- end loop
        end
        if not is_valid(sess.bmc) or not is_valid(sess.silhouette_root) then
            return true
        end
        local pp
        pcall(function() pp = sess.bmc.PreviewPiece end)
        pp = deref_weak(pp)
        if not is_valid(pp) then return false end -- preview not ready

        local loc, rot
        pcall(function() loc = pp:K2_GetActorLocation() end)
        pcall(function() rot = pp:K2_GetActorRotation() end)
        if loc then
            pcall(function()
                sess.silhouette_root:K2_SetActorLocation(loc, false, nil, false)
            end)
        end
        if rot then
            pcall(function()
                sess.silhouette_root:K2_SetActorRotation(rot, false, nil)
            end)
        end
        return false
    end)
end

-- Phase B: spawn silhouettes via world:SpawnActor + attach. No BMC
-- interaction whatsoever ; this is safe to do many-per-tick.
local function start_silhouette_spawn_phase()
    if not LoopAsync then return false, "LoopAsync unavailable" end
    LoopAsync(SILHOUETTE_STAGGER_MS, function()
        local sess = M._session
        if not sess or not sess.full or not sess.loop_armed then return true end
        if not is_valid(sess.world) or not is_valid(sess.silhouette_root) then
            sess.loop_armed = false
            return true
        end

        local first = sess.first
        local root_loc = sess.root_spawn_loc
        local spawned_this_tick = 0

        while spawned_this_tick < SILHOUETTE_BATCH_PER_TICK do
            local k = sess.queue_idx or 2
            if k > #sess.pieces then
                -- Phase B done. Restore reticle to piece_1, start tracker.
                local first_pd = sess.pd_cache and sess.pd_cache[first.piece_data_name]
                if is_valid(first_pd) and is_valid(sess.bmc) and sess.bmc.OnPieceSelected then
                    if sess.bmc.ForceEnterBuildMode then
                        pcall(function() sess.bmc:ForceEnterBuildMode() end)
                    end
                    pcall(function() sess.bmc:OnPieceSelected(first_pd) end)
                end
                print(string.format(
                    "[RSDWTools] build.preview.preview_full: spawned %d silhouettes, reticle armed",
                    #sess.silhouettes))
                start_silhouette_tracking_loop()
                return true
            end

            sess.queue_idx = k + 1
            local p = sess.pieces[k]
            if type(p.piece_data_name) == "string" then
                local cls = sess.class_cache[p.piece_data_name]
                if is_valid(cls) and sess.world.SpawnActor then
                    local dx = (p.x or 0) - (first.x or 0)
                    local dy = (p.y or 0) - (first.y or 0)
                    local dz = (p.z or 0) - (first.z or 0)
                    local dyaw = (p.yaw or 0) - (first.yaw or 0)
                    local spawn_loc = {
                        X = (root_loc.X or 0) + dx,
                        Y = (root_loc.Y or 0) + dy,
                        Z = (root_loc.Z or 0) + dz,
                    }
                    local spawn_rot = { Pitch = 0, Yaw = dyaw, Roll = 0 }
                    local spawned
                    pcall(function()
                        spawned = sess.world:SpawnActor(cls, spawn_loc, spawn_rot)
                    end)
                    if is_valid(spawned) then
                        configure_silhouette(spawned)
                        if spawned.K2_AttachToActor then
                            pcall(function()
                                -- EAttachmentRule: 0=KeepRelative, 1=KeepWorld, 2=SnapToTarget
                                spawned:K2_AttachToActor(sess.silhouette_root, "None", 0, 0, 0, true)
                            end)
                        end
                        sess.silhouettes[#sess.silhouettes + 1] = spawned
                    end
                end
            end
            spawned_this_tick = spawned_this_tick + 1
        end
        return false
    end)
    return true
end

-- Phase A: resolve every unique piece_data -> UClass, one per tick,
-- via load_class_via_engine. When done, transition to Phase B.
local function start_class_resolution_phase()
    if not LoopAsync then return false, "LoopAsync unavailable" end
    LoopAsync(SILHOUETTE_STAGGER_MS, function()
        local sess = M._session
        if not sess or not sess.full or not sess.loop_armed then return true end
        if not is_valid(sess.bmc) then sess.loop_armed = false; return true end

        local q = sess.unique_pd_queue
        local i = sess.unique_pd_idx or 1
        if i > #q then
            -- Phase A done. Verify piece_1 class resolved, then move to Phase B.
            local first = sess.first
            local first_cls = sess.class_cache[first.piece_data_name]
            if not is_valid(first_cls) then
                sess.loop_armed = false
                clear_session()
                print("[RSDWTools] build.preview.preview_full: piece_1 class did not resolve, aborting")
                return true
            end
            -- Spawn silhouette_root via world:SpawnActor at a spot in
            -- front of the player so the very first frame doesn't
            -- show silhouettes 200km away while the tracking loop
            -- catches up.
            local root_loc = spot_in_front_of_pawn(500.0) or { X = 0, Y = 0, Z = 0 }
            sess.root_spawn_loc = root_loc
            local spawned_root
            pcall(function()
                spawned_root = sess.world:SpawnActor(first_cls, root_loc, { Pitch = 0, Yaw = 0, Roll = 0 })
            end)
            if not is_valid(spawned_root) then
                sess.loop_armed = false
                clear_session()
                print("[RSDWTools] build.preview.preview_full: silhouette_root SpawnActor failed")
                return true
            end
            configure_silhouette(spawned_root)
            sess.silhouette_root = spawned_root
            print(string.format(
                "[RSDWTools] build.preview.preview_full: phase A done, %d unique classes, starting phase B",
                table_size(sess.class_cache)))
            start_silhouette_spawn_phase()
            return true
        end

        sess.unique_pd_idx = i + 1
        local pd_name = q[i]
        local pd = sess.pd_cache[pd_name]
        if is_valid(pd) and not is_valid(sess.class_cache[pd_name]) then
            local cls = load_class_via_engine(pd, sess.bmc)
            if is_valid(cls) then
                sess.class_cache[pd_name] = cls
            end
        end
        return false
    end)
    return true
end

function M.preview_full(args_str)
    -- DISABLED. Two attempts at silhouette spawn (engine-PreviewPiece-as-parent
    -- and SpawnActor-after-staggered-class-resolution) both crashed the game on
    -- larger captures. Root cause not isolated yet ; suspect that calling
    -- bmc:OnPieceSelected from inside a LoopAsync tick destabilizes
    -- BuildPlacementComponent state in a way that takes a few frames to fault.
    --
    -- Until we can reproduce on a small (3-5 piece) capture and bisect, this
    -- verb is a no-op stub. Use build.preview.preview for the single-anchor
    -- workflow that's known to work.
    return false, "preview_full disabled (crash bisect pending) ; use build.preview.preview"
end

-- ---------------------------------------------------------------------------
-- Deferred native placement handoff. The anchor has already been requested
-- by vanilla input. Apply its yaw/location to the remaining records only.
-- ---------------------------------------------------------------------------
local function deliver_native_anchor(sess, observed)
    if M._session ~= sess then return false, "preview session cancelled" end
    local ghost_mode, interval_ms = sess.ghost_mode, sess.interval_ms

    local bmc = sess.bmc
    if not is_valid(bmc) then
        clear_session()
        return false, "BMC no longer valid"
    end
    if not bmc.Server_SpawnBuilding then
        clear_session()
        return false, "BMC has no Server_SpawnBuilding"
    end

    if observed.ghost ~= ghost_mode then
        return false, "native anchor ghost mode does not match the WPF setting; anchor left in world, no remaining pieces delivered"
    end
    local q, scale = observed.rotation, observed.scale
    if math.abs(q.X) > 0.0001 or math.abs(q.Y) > 0.0001
        or math.abs(scale.X - 1) > 0.0001 or math.abs(scale.Y - 1) > 0.0001 or math.abs(scale.Z - 1) > 0.0001 then
        return false, "native anchor must have yaw-only rotation and unit scale; remaining delivery stopped"
    end
    local anchor_loc, anchor_yaw_deg = observed.location, quat_to_yaw_deg(q)

    local first = sess.first
    local pieces = sess.pieces
    local idx_map = sess.idx_by_pd

    local theta_deg = anchor_yaw_deg - (first.yaw or 0)
    local theta_rad = theta_deg * math.pi / 180.0
    local cos_t, sin_t = math.cos(theta_rad), math.sin(theta_rad)

    print(string.format(
        "[RSDWTools] build.preview.commit: native anchor=(%.1f, %.1f, %.1f) yaw=%.1f theta=%.1f, queueing %d remaining pieces",
        anchor_loc.X or 0, anchor_loc.Y or 0, anchor_loc.Z or 0,
        anchor_yaw_deg, theta_deg, #pieces - 1))

    -- Drop the engine's preview before we replay so the engine doesn't
    -- try to keep its preview piece "valid" against our spawning
    -- structure. ExitAnyMode also closes any open menu UI.
    if bmc.ExitAnyMode then pcall(function() bmc:ExitAnyMode() end) end

    -- For preview_full sessions, destroy the silhouette ghosts BEFORE
    -- the real spawn loop so the user doesn't briefly see ghost +
    -- real overlapping. Stop the tracking LoopAsync via loop_armed so
    -- it doesn't keep writing transform onto a destroyed silhouette_root.
    if sess.full then
        sess.loop_armed = false
        if type(sess.silhouettes) == "table" then
            for _, s in pairs(sess.silhouettes) do
                if is_valid(s) then pcall(function() s:K2_DestroyActor() end) end
            end
            sess.silhouettes = {}
        end
        if is_valid(sess.silhouette_root) then
            pcall(function() sess.silhouette_root:K2_DestroyActor() end)
            sess.silhouette_root = nil
        end
    end

    -- Ghost-mode delivery: pass bSpawnGhost=true so the engine spawns
    -- each piece as a proper persistent ghost (server-side state,
    -- replicated, survives save+reload). Replaces the previous
    -- post-spawn client-side bIsGhosted=true pinning which had no
    -- persisted effect.
    local spawn_ghost = ghost_mode and true or false

    local entries = {}
    local skipped = 0
    -- The engine already placed pieces[1]. Never replay it a second time.
    for i = 2, #pieces do
        local p = pieces[i]
        local pd_idx = (type(p.piece_data_index) == "number" and p.piece_data_index)
            or (type(p.piece_data_name) == "string" and idx_map[p.piece_data_name])
        if type(pd_idx) ~= "number" or type(p.x) ~= "number"
           or type(p.y) ~= "number" or type(p.z) ~= "number" then
            skipped = skipped + 1
        else
            local dx = p.x - (first.x or 0)
            local dy = p.y - (first.y or 0)
            local dz = p.z - (first.z or 0)
            local rx, ry = rotate_xy(dx, dy, cos_t, sin_t)
            local world_x = (anchor_loc.X or 0) + rx
            local world_y = (anchor_loc.Y or 0) + ry
            local world_z = (anchor_loc.Z or 0) + dz
            entries[#entries + 1] = {
                piece_data_index = pd_idx,
                piece_data_name = p.piece_data_name,
                x = world_x, y = world_y, z = world_z,
                pitch = p.pitch, yaw = (p.yaw or 0) + theta_deg, roll = p.roll,
                scale_x = p.scale_x, scale_y = p.scale_y, scale_z = p.scale_z,
            }
        end
    end

    local item_entries, item_skipped = feature_buildings._transform_records_relative(
        sess.items or {}, first, anchor_loc, theta_deg, "item")
    local actor_entries, actor_skipped = feature_buildings._transform_records_relative(
        sess.actors or {}, first, anchor_loc, theta_deg, "actor")

    local ok, detail = feature_buildings._queue_piece_delivery({
        source = "preview",
        resume_id = sess.delivery_id,
        native_anchor = true,
        entries = entries,
        skipped = skipped,
        bmc = bmc,
        spawn_ghost = spawn_ghost,
        interval_ms = interval_ms,
        item_entries = item_entries,
        item_skipped = item_skipped,
        actor_entries = actor_entries,
        actor_skipped = actor_skipped,
        initial_settle_ticks = feature_buildings._DELIVERY_PREVIEW_SETTLE_TICKS or 6,
    })
    clear_session()
    if not ok then return false, detail end

    local suffix = ghost_mode and " (spawned as persistent ghosts)" or ""
    return true, string.format("%s items=%d actors=%d%s",
        detail,
        sess.items and #sess.items or 0,
        sess.actors and #sess.actors or 0,
        suffix)
end

-- ---------------------------------------------------------------------------
-- Arm one native placement. The queue is reserved now but does not run
-- until the observer hands off a copied transform after the native RPC.
-- ---------------------------------------------------------------------------
function M.commit(args_str)
    local sess = M._session
    if not sess then return false, "no preview session; begin a preview first" end
    if sess.delivery_id then return false, "already waiting for anchor placement" end
    local interval_ms, interval_error = feature_buildings._parse_delivery_interval_ms(args_str or "")
    if interval_error then return false, interval_error end
    sess.request_id = (args_str or ""):match("request=([%w%-]+)")
    local first = sess.first
    if math.abs(first.pitch or 0) > 0.0001 or math.abs(first.roll or 0) > 0.0001
        or math.abs((first.scale_x or 1) - 1) > 0.0001
        or math.abs((first.scale_y or 1) - 1) > 0.0001
        or math.abs((first.scale_z or 1) - 1) > 0.0001 then
        return false, "preview anchor must have yaw-only rotation and unit scale; capture using an unscaled floor as anchor"
    end
    sess.interval_ms = interval_ms
    sess.ghost_mode = false
    for token in (args_str or ""):gmatch("%S+") do
        if token == "ghost" then sess.ghost_mode = true end
    end
    local ok, detail, id = feature_buildings._queue_piece_delivery({
        source = "preview", entries = sess.pieces, item_entries = sess.items, actor_entries = sess.actors,
        bmc = sess.bmc, wait_for_anchor = true, interval_ms = interval_ms, spawn_ghost = sess.ghost_mode,
        request_id = sess.request_id,
    })
    if not ok then return false, detail end
    sess.delivery_id = id
    feature_buildings._delivery_active.observer_state = native_placement.state
    local watch_called, watched, watch_error = pcall(native_placement.watch, function(observed)
        local job = feature_buildings._delivery_active
        if not job or job.id ~= id or job.state ~= "waiting_for_anchor" then return end
        local called, delivered, result = pcall(deliver_native_anchor, sess, observed)
        if not called or not delivered then
            local err = tostring(called and result or delivered)
            feature_buildings._fail_preview_delivery(id, err)
            if M._session == sess then M.cancel(id) end
            print("[RSDWTools] build.preview delivery failed: " .. err)
        end
    end, id)
    if not watch_called then watch_error, watched = tostring(watched), false end
    if not watched then
        feature_buildings._fail_preview_delivery(id, watch_error)
        M.cancel(id)
        return false, watch_error
    end
    return true, detail
end

function M.begin(args_str)
    local name, options = (args_str or ""):match("^(%S+)%s*(.*)$")
    if not name then return false, "usage: build.preview.begin <capture> [ghost] [interval_ms=N]" end
    local ok, detail = M.preview(name)
    if not ok then return false, detail end
    local called
    called, ok, detail = pcall(M.commit, options)
    if not called then detail, ok = tostring(ok), false end
    if not ok then
        local id = M._session and M._session.delivery_id
        if id then feature_buildings._fail_preview_delivery(id, detail) end
        M.cancel(id)
    end
    return ok, detail
end

-- A scoped ID also cancels an already-started queue without touching other jobs.
function M.cancel(expected_id)
    local id = tonumber(expected_id)
    if not M._session then
        if id then return feature_buildings.delivery_cancel(id) end
        return true, "no active session"
    end
    if id and id ~= M._session.delivery_id then return false, "preview delivery id mismatch" end
    if M._session.delivery_id then feature_buildings.delivery_cancel(M._session.delivery_id) end
    local bmc = M._session.bmc
    clear_session()
    if is_valid(bmc) then pcall(function() bmc:ExitAnyMode() end) end
    print("[RSDWTools] build.preview.cancel: session dropped")
    return true, "cancelled"
end

-- ---------------------------------------------------------------------------
-- build.preview.force_place
--
-- Fire Server_SpawnBuilding for whatever the BMC currently has on the
-- reticle, at the reticle's current world transform. Bypasses the
-- engine's UI validity gate (red ghost / "blocked" / "unstable")
-- entirely -- the player doesn't have to actually click, and the
-- placement check never runs.
--
-- Works whether the reticle was armed by:
--   * the engine's normal build menu (player picked a piece via UI)
--   * build.preview.piece <name|index>
--   * build.preview.preview / preview_full (anchor piece)
--
-- This is the same primitive M.commit uses for the anchor piece, but
-- exposed standalone so a single piece can be force-placed without
-- requiring an active capture session.
--
-- Resolves the piece_data_index from the engine-side
-- bmc.CurrentlyPlacingPieceData.BuildingPieceDataIndex ; falls back
-- to scanning the PreviewPiece for an obvious owner if needed.
-- ---------------------------------------------------------------------------
function M.force_place()
    local _pc, bmc, berr = get_local_pc_and_bmc()
    if not bmc then return false, "build mode unavailable: " .. tostring(berr) end
    if not bmc.Server_SpawnBuilding then return false, "BMC has no Server_SpawnBuilding" end
    local placement, placement_err = build_access.preview_transform(bmc)
    if not placement then return false, placement_err end

    -- Locate the live PreviewPiece actor. We read both the placement
    -- transform AND the piece_data_index off this actor : the engine
    -- can clear bmc.CurrentlyPlacingPieceData the moment its UI-side
    -- placement check goes red (e.g. user is aiming into a "blocked"
    -- zone), even while PreviewPiece itself stays parented to the
    -- reticle. The actor mirrors both BuildingPieceDataIndex (replicated,
    -- OnRep_BuildingPieceDataIndex at offset 0x0738) and a direct
    -- BuildingPieceData* (0x0730), so we can recover the index
    -- without relying on the (sometimes-stale) BMC weak ptr.
    local pp_weak
    pcall(function() pp_weak = bmc.PreviewPiece end)
    local pp = deref_weak(pp_weak)
    if not is_valid(pp) then
        return false, "no PreviewPiece on BMC ; engine dropped the preview"
    end

    -- Resolve piece_data_index. Try the live preview actor first
    -- (works in zones where the engine has soft-cleared the BMC's
    -- CurrentlyPlacingPieceData but the visual ghost is still alive),
    -- then BuildingPieceData on the actor, then fall back to the
    -- BMC's TWeakObjectPtr<UBuildingPieceData>.
    local pd_idx, pd_source
    pcall(function() pd_idx = pp.BuildingPieceDataIndex end)
    if type(pd_idx) == "number" then pd_source = "PreviewPiece" end

    if type(pd_idx) ~= "number" then
        local pd_on_actor
        pcall(function() pd_on_actor = pp.BuildingPieceData end)
        if is_valid(pd_on_actor) then
            pcall(function() pd_idx = pd_on_actor.BuildingPieceDataIndex end)
            if type(pd_idx) == "number" then pd_source = "PreviewPiece.BuildingPieceData" end
        end
    end

    local pd  -- kept for the trailing GetName() log line
    if type(pd_idx) ~= "number" then
        local pd_weak
        pcall(function() pd_weak = bmc.CurrentlyPlacingPieceData end)
        pd = deref_weak(pd_weak)
        if is_valid(pd) then
            pcall(function() pd_idx = pd.BuildingPieceDataIndex end)
            if type(pd_idx) == "number" then pd_source = "BMC.CurrentlyPlacingPieceData" end
        end
    end

    if type(pd_idx) ~= "number" then
        return false, "could not resolve piece_data_index from PreviewPiece, "
            .. "PreviewPiece.BuildingPieceData, or BMC.CurrentlyPlacingPieceData "
            .. "; arm a piece first (build menu, build.preview.piece, etc.)"
    end

    local loc, rot
    pcall(function() loc = pp:K2_GetActorLocation() end)
    pcall(function() rot = pp:K2_GetActorRotation() end)
    if not loc then return false, "could not read PreviewPiece location" end
    local yaw_deg = (rot and rot.Yaw) or 0

    local yaw_rad = yaw_deg * math.pi / 180.0
    local half = yaw_rad * 0.5
    local xform = {
        Rotation    = { X = 0, Y = 0, Z = math.sin(half), W = math.cos(half) },
        Translation = { X = loc.X or 0, Y = loc.Y or 0, Z = loc.Z or 0 },
        Scale3D     = { X = 1, Y = 1, Z = 1 },
    }

    local empty_inv = {}
    local ok, err = pcall(function()
        bmc:Server_SpawnBuilding(pd_idx, xform, false, empty_inv)
    end)
    if not ok then
        return false, "Server_SpawnBuilding errored: " .. tostring(err)
    end

    local pd_short
    if is_valid(pd) then
        pcall(function() pd_short = pd:GetName() end)
    end
    if not pd_short then
        -- Fall back to the BuildingPieceData hung off the preview actor
        -- so the log line stays informative when we resolved the index
        -- straight off PreviewPiece.BuildingPieceDataIndex.
        local pd_on_actor
        pcall(function() pd_on_actor = pp.BuildingPieceData end)
        if is_valid(pd_on_actor) then
            pcall(function() pd_short = pd_on_actor:GetName() end)
        end
    end
    print(string.format(
        "[RSDWTools] build.preview.force_place: spawned idx=%d (%s, src=%s) at (%.1f, %.1f, %.1f) yaw=%.1f",
        pd_idx, pd_short or "<unknown>", pd_source or "?",
        loc.X or 0, loc.Y or 0, loc.Z or 0, yaw_deg))
    return true, string.format("placed idx=%d", pd_idx)
end

-- ---------------------------------------------------------------------------
-- build.preview.piece <name_or_index>
--
-- Generic single-piece preview. Accepts either:
--   - a piece_data_index (integer)         e.g. 142
--   - a piece_data short name (substring)  e.g. Lodestone
--   - a piece_data full path               e.g. "BuildingPieceData /Game/.../BUILDPIECE_X.BUILDPIECE_X"
--
-- Resolves the piece data, drives the engine into placing mode with
-- it on the reticle, and clears any prior session. No commit ; no
-- replay. The user can then aim and click normally to place it via
-- the engine's standard placement flow (subject to the usual
-- validity checks), OR run build.preview.commit-style verbs against
-- the active preview if we add them later.
--
-- This is useful for testing whether arbitrary pieces from the
-- catalog can be put on the reticle, and for ad-hoc placement of
-- pieces that aren't in your build menu unlock list.
-- ---------------------------------------------------------------------------
local function resolve_piece_by_index(idx)
    if not FindAllOf then return nil, "FindAllOf unavailable" end
    local list = FindAllOf("BuildingPieceData")
    if type(list) ~= "table" then return nil, "BuildingPieceData FindAllOf returned non-table" end
    for _, a in pairs(list) do
        if is_valid(a) then
            local i
            pcall(function() i = a.BuildingPieceDataIndex end)
            if i == idx then return a end
        end
    end
    return nil, "no loaded BuildingPieceData with index=" .. tostring(idx)
end

local function resolve_piece_by_short_name(needle)
    if not FindAllOf then return nil, "FindAllOf unavailable" end
    local list = FindAllOf("BuildingPieceData")
    if type(list) ~= "table" then return nil, "BuildingPieceData FindAllOf returned non-table" end
    local needle_l = needle:lower()
    -- Prefer exact short-name match, fall back to substring.
    local exact, fuzzy
    for _, a in pairs(list) do
        if is_valid(a) then
            local sn
            pcall(function() sn = a:GetName() end)
            if type(sn) == "string" then
                local sn_l = sn:lower()
                if sn_l == needle_l then exact = a; break end
                if not fuzzy and sn_l:find(needle_l, 1, true) then fuzzy = a end
            end
        end
    end
    if exact then return exact end
    if fuzzy then return fuzzy end
    return nil, "no BuildingPieceData matching '" .. needle .. "'"
end

local function resolve_piece_arg(raw)
    raw = (raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return nil, nil, "usage: build.preview.piece <index|short_name|full_path>" end

    local pd, perr
    local as_int = tonumber(raw)
    if as_int and math.floor(as_int) == as_int then
        pd, perr = resolve_piece_by_index(math.floor(as_int))
    elseif raw:find("/", 1, true) or raw:find(" ", 1, true) then
        pd, perr = resolve_piece_data(raw)
    else
        pd, perr = resolve_piece_by_short_name(raw)
    end
    if not pd then return nil, nil, "could not resolve piece: " .. tostring(perr) end

    local resolved
    pcall(function() resolved = pd:GetFullName() end)
    return pd, resolved or raw, nil
end

function M.resolve_piece_arg(args_str)
    local pd, resolved, err = resolve_piece_arg(args_str)
    if not pd then return false, tostring(err), nil end
    return true, tostring(resolved), pd
end

function M.current_mode_info()
    local pc, bmc, berr = get_local_pc_and_bmc()
    if not bmc then return false, "build mode unavailable: " .. tostring(berr), nil end

    local mode_id, mode_name, raw_mode = read_build_mode(bmc)
    local prev_id, prev_name, raw_prev = read_prev_build_mode(bmc)
    local preview = deref_weak(select(2, pcall(function() return bmc.PreviewPiece end)))
    local placing_data = deref_weak(select(2, pcall(function() return bmc.CurrentlyPlacingPieceData end)))
    local info = {
        pc = pc,
        bmc = bmc,
        mode_id = mode_id,
        mode = mode_name,
        raw_mode = raw_mode,
        prev_id = prev_id,
        prev = prev_name,
        raw_prev = raw_prev,
        preview = preview,
        placing_data = placing_data,
    }
    return true, info
end

function M.mode_status()
    local ok, info_or_err = M.current_mode_info()
    if not ok then return false, tostring(info_or_err) end
    local info = info_or_err
    return true, string.format(
        "mode=%s mode_id=%s prev=%s prev_id=%s preview=%s placing=%s",
        tostring(info.mode),
        tostring(info.mode_id or "?"),
        tostring(info.prev),
        tostring(info.prev_id or "?"),
        obj_name_or_nil(info.preview) or "<none>",
        obj_name_or_nil(info.placing_data) or "<none>")
end

function M.exit_any_mode()
    local _pc, bmc, berr = get_local_pc_and_bmc()
    if not bmc then return false, "build mode unavailable: " .. tostring(berr) end
    if not bmc.ExitAnyMode then return false, "BMC has no ExitAnyMode" end
    local ok1, err1 = pcall(function() bmc:ExitAnyMode() end)
    local ok2, err2 = pcall(function() bmc:ExitAnyMode() end)
    if not ok1 and not ok2 then
        return false, "ExitAnyMode errored: " .. tostring(err1 or err2)
    end
    return true, "exited build mode"
end

function M.force_enter_build_mode()
    local _pc, bmc, berr = get_local_pc_and_bmc()
    if not bmc then return false, "build mode unavailable: " .. tostring(berr), nil end
    if not bmc.ForceEnterBuildMode then return false, "BMC has no ForceEnterBuildMode", bmc end
    local ok, err = pcall(function() bmc:ForceEnterBuildMode() end)
    if not ok then return false, "ForceEnterBuildMode errored: " .. tostring(err), bmc end
    return true, "entered build mode", bmc
end

function M.select_piece_data(piece_data)
    if not is_valid(piece_data) then return false, "invalid BuildingPieceData", nil, nil end
    local _pc, bmc, berr = get_local_pc_and_bmc()
    if not bmc then return false, "build mode unavailable: " .. tostring(berr), nil, nil end
    if not bmc.OnPieceSelected then return false, "BMC has no OnPieceSelected", nil, bmc end

    local sok, serr = pcall(function() bmc:OnPieceSelected(piece_data) end)
    if not sok then
        return false, "OnPieceSelected errored: " .. tostring(serr), nil, bmc
    end

    local preview_check
    pcall(function() preview_check = bmc.PreviewPiece end)
    local preview_actor = deref_weak(preview_check)
    if not is_valid(preview_actor) and not build_access.selection_matches(bmc, piece_data) then
        return false, "selected piece not ready in placement mode; retry after the build menu settles", nil, bmc
    end

    print(string.format("[RSDWTools] build.preview.select_piece_data: PreviewPiece -> %s",
        obj_name_or_nil(preview_actor) or "<unknown>"))
    return true, "selected piece", preview_actor, bmc
end

function M.select_piece(args_str)
    local pd, resolved, resolve_err = resolve_piece_arg(args_str)
    if not pd then return false, tostring(resolve_err) end
    local ok, detail, preview = M.select_piece_data(pd)
    if not ok then return false, tostring(detail) end
    return true, string.format("selected %s preview=%s",
        tostring(resolved),
        obj_name_or_nil(preview) or "<unknown>")
end

function M.repair_probe(args_str)
    local args = (args_str or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local pc, bmc, berr = get_local_pc_and_bmc()
    if not bmc then return false, "build mode unavailable: " .. tostring(berr) end

    local ok_before, before = M.mode_status()
    local results = {
        "before={" .. tostring(ok_before and before or "<unavailable>") .. "}",
        "OnToggleRepairAndEditModeInput=" .. tostring(bmc.OnToggleRepairAndEditModeInput ~= nil),
        "OnToggleBuildModeInput=" .. tostring(bmc.OnToggleBuildModeInput ~= nil),
        "ExitAnyMode=" .. tostring(bmc.ExitAnyMode ~= nil),
    }

    if args == "try" or args == "attempt" then
        if not bmc.OnToggleRepairAndEditModeInput then
            results[#results + 1] = "try=missing OnToggleRepairAndEditModeInput"
        else
            local attempts = {
                { label = "nil", fn = function() return bmc:OnToggleRepairAndEditModeInput(nil) end },
                { label = "table", fn = function() return bmc:OnToggleRepairAndEditModeInput({}) end },
                { label = "true", fn = function() return bmc:OnToggleRepairAndEditModeInput(true) end },
            }
            for _, attempt in ipairs(attempts) do
                local ok_call, err = pcall(attempt.fn)
                results[#results + 1] = "try_" .. attempt.label .. "=" .. tostring(ok_call)
                    .. (ok_call and "" or (":" .. tostring(err)))
                if ok_call then break end
            end
        end
    else
        results[#results + 1] = "try=skipped; run build.repair.probe try for guarded call attempts"
    end

    local ok_after, after = M.mode_status()
    results[#results + 1] = "after={" .. tostring(ok_after and after or "<unavailable>") .. "}"
    local detail = table.concat(results, " ; ")
    print("[RSDWTools] build.repair.probe " .. detail)
    return true, detail
end

function M.piece(args_str)
    local raw = (args_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then return false, "usage: build.preview.piece <index|short_name|full_path>" end

    local _pc, bmc, berr = get_local_pc_and_bmc()
    if not bmc then return false, "build mode unavailable: " .. tostring(berr) end
    if not bmc.OnPieceSelected then return false, "BMC has no OnPieceSelected" end

    -- Drop any prior session so we don't conflate with capture-driven
    -- preview state.
    if M._session then clear_session() end

    local pd, resolved, resolve_err = resolve_piece_arg(raw)
    if not pd then return false, tostring(resolve_err) end
    print("[RSDWTools] build.preview.piece: resolved -> " .. tostring(resolved))

    local now = os.clock()
    local cooldown_remaining = piece_arm_cooldown_remaining(now)
    if cooldown_remaining > 0 then
        print(string.format(
            "[RSDWTools] build.preview.piece: skipped rapid re-arm (%.2fs cooldown remaining)",
            cooldown_remaining))
        return true, string.format("armed recently ; skipped %.2fs cooldown", cooldown_remaining)
    end
    last_piece_arm_at = now

    -- Reset to idle so OnPieceSelected reliably spawns a fresh PreviewPiece.
    if bmc.ExitAnyMode then
        pcall(function() bmc:ExitAnyMode() end)
        pcall(function() bmc:ExitAnyMode() end)
    end
    if bmc.ForceEnterBuildMode then
        pcall(function() bmc:ForceEnterBuildMode() end)
    end
    local select_ok, select_detail, preview_actor = M.select_piece_data(pd)
    if not select_ok then
        if bmc.ExitAnyMode then pcall(function() bmc:ExitAnyMode() end) end
        return false, tostring(select_detail)
    end

    print(string.format("[RSDWTools] build.preview.piece: PreviewPiece -> %s",
        obj_name_or_nil(preview_actor) or "<unknown>"))
    return true, "armed " .. (resolved or raw)
end

-- ---------------------------------------------------------------------------
-- build.preview.lookat
--
-- QOL combo: probe the actor under the reticle (same source priority as
-- camera.lookat ;; detector first, camera trace fallback) and, if it's
-- a BaseBuildingActor, immediately arm its piece on the build reticle
-- via the same OnPieceSelected path M.piece uses. One verb -> one
-- hotkey -> "copy this piece into my hand".
--
-- Fail-fast cases (with useful messages so the player knows WHY) :
--   * reticle on nothing                 -> propagate trace error
--   * reticle on a non-building actor    -> "<short> is not a building
--                                           piece (class=...)"
--   * actor has no BuildingPieceDataIndex -> rare ; report it
--
-- Note: actor.BuildingPieceDataIndex is an int32 set by the engine on
-- every spawned BaseBuildingActor (we already use it in
-- feature_buildings.snapshot_piece for export/describe), so this works
-- on real pieces AND on pieces in ghost state.
-- ---------------------------------------------------------------------------
function M.lookat()
    local targeted, target_err = build_access.targeted_piece()
    if targeted then return M.piece(tostring(targeted.piece_data_index)) end
    local actor, source = feature_grab.pick_actor_under_reticle()
    if not feature_actor.is_valid_object(actor) then
        return false, tostring(source or "no actor under reticle")
    end

    local short = feature_actor.short_name_of(actor) or "<unnamed>"
    local class
    pcall(function() class = actor:GetClass():GetName() end)
    class = class or "<unknown>"

    local idx
    -- BuildingPieceDataIndex is uproperty int32 ;; pcall in case the
    -- actor doesn't expose it (UE4SS access errors throw). The presence
    -- of this field is also our "is this a BaseBuildingActor?" check ;;
    -- cleaner than walking the class hierarchy.
    pcall(function() idx = actor.BuildingPieceDataIndex end)
    if type(idx) ~= "number" then
        return false, string.format("%s has no actor building index (class=%s, src=%s); %s",
            short, class, tostring(source), tostring(target_err))
    end

    print(string.format(
        "[RSDWTools] build.preview.lookat: %s [class=%s, src=%s, idx=%d] -> arming",
        short, class, tostring(source), idx))

    -- Delegate to M.piece so the placement-mode path stays in one
    -- place (PreviewPiece spawn check, ExitAnyMode dance, etc.).
    return M.piece(tostring(idx))
end

-- ---------------------------------------------------------------------------
-- world.buildings.lookat_anchor
--
-- Read-only sibling of M.lookat : returns the BuildingPieceDataIndex
-- of whatever building piece is under the player's reticle, WITHOUT
-- entering placing mode. Used by the WPF Capture Build flow's
-- "Specify a Build Anchor" dialog : the user looks at the actor they
-- want as the anchor, the WPF runs this verb, parses the returned
-- index, then calls world.buildings.export with anchor=<idx>.
-- ---------------------------------------------------------------------------
function M.lookat_anchor()
    local targeted, target_err = build_access.targeted_piece()
    if targeted then
        return true, string.format("idx=%d pid=%d class=BuildingPieceHandle short=BuildingPiece_%d source=%s",
            targeted.piece_data_index, targeted.piece_id, targeted.piece_id,
            tostring(targeted.source or "repair_target"))
    end

    local actor, _impact, source, trace_err, hit_details = feature_grab.pick_hit_under_reticle()
    local traced_piece, handle_err = build_access.piece_from_hit(hit_details)
    if traced_piece then
        print(string.format(
            "[RSDWTools] world.buildings.lookat_anchor: lightweight piece [src=%s, idx=%d, pid=%d]",
            tostring(traced_piece.source), traced_piece.piece_data_index, traced_piece.piece_id))
        return true, string.format(
            "idx=%d pid=%d class=BuildingPieceHandle short=BuildingPiece_%d source=%s",
            traced_piece.piece_data_index, traced_piece.piece_id, traced_piece.piece_id,
            tostring(traced_piece.source or "trace_handle"))
    end
    if not feature_actor.is_valid_object(actor) then
        return false, string.format(
            "no building piece under reticle; repair_target=%s; trace_handle=%s; trace=%s. "
                .. "Enter vanilla Repair mode and aim until the piece is highlighted, then retry",
            tostring(target_err or "unavailable"), tostring(handle_err or "unavailable"),
            tostring(trace_err or source or "no hit"))
    end

    local short = feature_actor.short_name_of(actor) or "<unnamed>"
    local class
    pcall(function() class = actor:GetClass():GetName() end)
    class = class or "<unknown>"

    local idx
    pcall(function() idx = actor.BuildingPieceDataIndex end)
    if type(idx) ~= "number" then
        return false, string.format(
            "%s is not a building piece (class=%s, src=%s); repair_target=%s; trace_handle=%s. "
                .. "Enter vanilla Repair mode and aim until the piece is highlighted, then retry",
            short, class, tostring(source), tostring(target_err or "unavailable"),
            tostring(handle_err or "unavailable"))
    end

    -- BuildingPieceID is the per-instance unique id (vs piece_data_index
    -- which is the per-archetype id). We return both so the WPF can
    -- record the exact actor instance the user picked, not just any
    -- piece with the same piece_data_index. Optional ; older builds
    -- of the actor class might lack it.
    local pid
    pcall(function() pid = actor.BuildingPieceID end)
    local pid_str = (type(pid) == "number") and tostring(pid) or "nil"

    print(string.format(
        "[RSDWTools] world.buildings.lookat_anchor: %s [class=%s, src=%s, idx=%d, pid=%s]",
        short, class, tostring(source), idx, pid_str))
    return true, string.format("idx=%d pid=%s class=%s short=%s",
        idx, pid_str, class, short)
end

-- ---------------------------------------------------------------------------
-- build.preview.diag <name> [n]
--
-- Read-only sanity check on the math. Parses the JSON, computes the
-- anchor + theta the same way M.preview does, then prints the first N
-- pieces' raw capture coords + computed world spawn coords. No spawns,
-- no engine calls beyond reading the local pawn. Used to confirm the
-- deltas are sane (not blasting actors miles away from the player).
-- ---------------------------------------------------------------------------
function M.diag(args_str)
    args_str = args_str or ""
    local name, n_str = args_str:match("^(%S+)%s*(%S*)%s*$")
    if not name then name = sanitize_name(args_str) end
    name = sanitize_name(name)
    local n_show = tonumber(n_str) or 5

    local path = capture_path_for(name)
    if not path then return false, "could not resolve mod ipc directory" end
    local body = mod_paths.read_file(path)
    if not body then return false, "could not read " .. path end

    if not (feature_buildings and feature_buildings._parse_pieces) then
        return false, "feature_buildings._parse_pieces not exposed"
    end
    local pieces, perr = feature_buildings._parse_pieces(body)
    if not pieces or #pieces == 0 then
        return false, "JSON parse: " .. tostring(perr or "no pieces")
    end

    local first = pieces[1]
    local anchor, pawn_yaw = spot_in_front_of_pawn(300.0)
    if not anchor then return false, "no pawn anchor" end
    local theta_deg = (pawn_yaw or 0) - (first.yaw or 0)
    local theta_rad = theta_deg * math.pi / 180.0
    local cos_t, sin_t = math.cos(theta_rad), math.sin(theta_rad)

    print(string.format("[RSDWTools] build.preview.diag: total=%d anchor=(%.1f, %.1f, %.1f) pawn_yaw=%.1f origin_yaw=%.1f theta=%.1f",
        #pieces, anchor.X, anchor.Y, anchor.Z, pawn_yaw or 0, first.yaw or 0, theta_deg))
    print(string.format("[RSDWTools] build.preview.diag: first piece capture=(%.1f, %.1f, %.1f) yaw=%.1f piece_data=%s",
        first.x or 0, first.y or 0, first.z or 0, first.yaw or 0, tostring(first.piece_data_name)))

    local upto = math.min(#pieces, n_show)
    for i = 1, upto do
        local p = pieces[i]
        local dx = (p.x or 0) - (first.x or 0)
        local dy = (p.y or 0) - (first.y or 0)
        local dz = (p.z or 0) - (first.z or 0)
        local rx, ry = rotate_xy(dx, dy, cos_t, sin_t)
        local lx, ly, lz = anchor.X + rx, anchor.Y + ry, anchor.Z + dz
        print(string.format(
            "[RSDWTools] build.preview.diag: [%d] cap=(%.1f, %.1f, %.1f) delta=(%.1f, %.1f, %.1f) world=(%.1f, %.1f, %.1f) class=%s",
            i, p.x or 0, p.y or 0, p.z or 0, dx, dy, dz, lx, ly, lz, tostring(p.piece_data_name)))
    end
    return true, string.format("printed %d/%d", upto, #pieces)
end

return M
