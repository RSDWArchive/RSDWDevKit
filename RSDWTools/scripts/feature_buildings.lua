-- feature_buildings.lua
--
-- Player-placed building inspection / serialization.
--
-- Goal arc:
--   v1 (this file)  : describe / count / nearest
--                     read-only; dumps to stdout so we can verify the
--                     schema before committing to JSON.
--   v2 (next round) : world.buildings.export <name>
--                     full enumeration -> JSON file under ipc/.
--   v3 (after that) : world.buildings.import <name>
--                     replay via UBuildModeComponent::Server_SpawnBuilding
--                     ; assumes the existing free-build mod has zeroed
--                     piece requirements (world.foreach BuildingPieceData
--                     clear Requirements).
--
-- Discovery uses the authoritative manager registry through feature_build_access.
-- Actor-backed entries use live actor transforms; lightweight entries use their
-- ClientVisible state. Completeness is checked before serialization.
--
-- Per-piece schema we currently capture (subject to validation in v1):
--   piece_id          : uint32  (BuildingPieceID, the registry key)
--   piece_data_index  : int32   (capture-time BuildingPieceDataIndex cache)
--   piece_data_name   : string  (BuildingPieceData full name)
--   spud_guid         : string  (FGuid as printable string)
--   class_name        : string  (GetClass():GetFullName())
--   short_name        : string  (GetName())
--   x,y,z             : floats  (GetActorLocation)
--   yaw               : float   (GetActorRotation().Yaw -- per FClientVisibleBuildingPieceState)
--   actual_rot        : {pitch,roll,yaw}  -- safety-net; expected pitch=roll=0
--   actual_scale      : {x,y,z}            -- safety-net; expected (1,1,1)
--   stability         : float   (StabilityValue)
--   is_ghosted        : bool
--   is_preview        : bool
--   distance_to_player: float   (only in describe / nearest output)

local M = {}

local feature_actor = require("feature_actor")
local build_access = require("feature_build_access")
local piece_aliases = require("building_piece_aliases")
local feature_field = require("feature_field")
local feature_inventory = require("feature_inventory")
local feature_player_spawn = require("feature_player_spawn")
local mod_paths = require("mod_paths")

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

-- ---------------------------------------------------------------------------
-- FindAllOf wrapper -- mirrors feature_world.find_first_valid but returns
-- an array of every live (non-stale, non-CDO) instance. Filters out the
-- class default object since it shows up alongside real instances and has
-- no transform / placement state.
-- ---------------------------------------------------------------------------
local function find_all_live(class_name)
    local out = {}
    if not FindAllOf then return out end
    local ok, list = pcall(FindAllOf, class_name)
    if not ok or not list then return out end
    local n = 0
    pcall(function() n = #list end)
    if n == 0 then
        local ok_num, num_val = pcall(function() return list:Num() end)
        if ok_num and type(num_val) == "number" then n = num_val end
    end
    for i = 1, n do
        local eok, entry = pcall(function() return list[i] end)
        if eok and type(entry) == "userdata" and is_valid(entry) then
            local fn
            pcall(function() fn = entry:GetFullName() end)
            if type(fn) == "string" and not fn:find("Default__", 1, true) then
                out[#out + 1] = entry
            end
        end
    end
    return out
end

local function find_first_live(class_name)
    local arr = find_all_live(class_name)
    return arr[1]
end

-- BuildingPieceDataIndex is transient runtime state. Game updates can insert
-- or reorder data assets, so a saved integer is not a durable piece identity.
-- Resolve the captured full asset name and read its current index immediately
-- before delivery. Index-only legacy captures require a verified mapping.
local function resolve_piece_data_object(full_name)
    if type(full_name) ~= "string" or full_name == "" then
        return nil, "missing piece_data_name"
    end

    local _, object_path = full_name:match("^(%S+)%s+(.+)$")
    object_path = object_path or full_name
    if not StaticFindObject then return nil, "StaticFindObject unavailable" end

    local function find(path)
        local obj
        pcall(function() obj = StaticFindObject(path) end)
        if not is_valid(obj) and LoadAsset then
            local package_path = path:match("^(.+)%.[^%.]+$") or path
            pcall(LoadAsset, package_path)
            pcall(function() obj = StaticFindObject(path) end)
        end
        if is_valid(obj) then
            local name
            pcall(function() name = obj:GetFullName() end)
            if type(name) == "string" and name:match("^BuildingPieceData /") then
                return obj, nil, name
            end
        end
    end

    -- Prefer the original asset if still available. Only known, exact renames
    -- may substitute for a missing asset; both routes must resolve real data.
    local obj, _, name = find(object_path)
    if obj then return obj, nil, name end
    local alias = piece_aliases[object_path]
    if alias then
        obj, _, name = find(alias)
        if obj then return obj, nil, name end
        return nil, "could not resolve " .. object_path .. " or verified alias " .. alias
    end
    return nil, "could not resolve " .. object_path
end

local function resolve_piece_indices(records)
    records = type(records) == "table" and records or {}
    local stats = {
        total = #records,
        named = 0,
        unique = 0,
        remapped = 0,
        aliased = 0,
        fallback = 0,
    }
    local cache = {}
    local saved_name_by_index = {}
    local live_name_by_index = {}
    local errors = {}
    local updates = {}

    local function add_error(message)
        if #errors < 8 then errors[#errors + 1] = message end
    end

    for i, rec in ipairs(records) do
        local saved_index = tonumber(rec.piece_data_index)
        if not saved_index or saved_index < 0 or saved_index ~= math.floor(saved_index) then
            saved_index = nil
        else
            saved_index = math.floor(saved_index)
        end
        local piece_name = rec.piece_data_name
        if type(piece_name) == "string" and piece_name ~= "" then
            stats.named = stats.named + 1

            local resolved = cache[piece_name]
            if not resolved then
                stats.unique = stats.unique + 1
                local asset, asset_err, canonical_name = resolve_piece_data_object(piece_name)
                if not asset then
                    resolved = { ok = false, error = asset_err }
                else
                    local live_index
                    pcall(function() live_index = asset.BuildingPieceDataIndex end)
                    live_index = tonumber(live_index)
                    if not live_index or live_index < 0 or live_index ~= math.floor(live_index) then
                        resolved = {
                            ok = false,
                            error = "asset has no valid runtime BuildingPieceDataIndex",
                        }
                    else
                        resolved = { ok = true, index = live_index, name = canonical_name }
                    end
                end
                cache[piece_name] = resolved
            end

            if not resolved.ok then
                add_error(string.format(
                    "record %d: %s (%s)", i, piece_name, tostring(resolved.error)))
            else
                if saved_index then
                    local prior_saved_name = saved_name_by_index[saved_index]
                    if prior_saved_name and prior_saved_name ~= resolved.name then
                        add_error(string.format(
                            "record %d: saved index %d names both '%s' and '%s'",
                            i, saved_index, prior_saved_name, resolved.name))
                    else
                        saved_name_by_index[saved_index] = resolved.name
                    end
                end
                local prior_live_name = live_name_by_index[resolved.index]
                if prior_live_name and prior_live_name ~= resolved.name then
                    add_error(string.format(
                        "runtime index %d resolves both '%s' and '%s'",
                        resolved.index, prior_live_name, resolved.name))
                else
                    live_name_by_index[resolved.index] = resolved.name
                end
                if saved_index ~= resolved.index then stats.remapped = stats.remapped + 1 end
                local requested_path = piece_name:match("^%S+%s+(.+)$") or piece_name
                if resolved.name ~= "BuildingPieceData " .. requested_path then
                    stats.aliased = stats.aliased + 1
                end
                updates[#updates + 1] = { record = rec, index = resolved.index, name = resolved.name }
            end
        elseif saved_index and saved_index >= 0 and saved_index == math.floor(saved_index) then
            stats.fallback = stats.fallback + 1
            add_error(string.format("record %d: legacy index-only piece %d has no verified source-build mapping; recapture or supply piece_data_name", i, saved_index))
        else
            add_error(string.format("record %d: missing piece_data_name and valid index", i))
        end
    end

    local detail = string.format(
        "runtime_indices total=%d named=%d unique=%d remapped=%d legacy_fallback=%d aliased=%d",
        stats.total, stats.named, stats.unique, stats.remapped, stats.fallback, stats.aliased)
    if #errors > 0 then
        return false, detail .. " errors=" .. table.concat(errors, " ; "), stats
    end
    -- Update only the in-memory delivery plan, and only after every identity
    -- passes. Saved capture files and their original transforms stay untouched.
    for _, update in ipairs(updates) do
        update.record.piece_data_index = update.index
        update.record.piece_data_name = update.name
    end
    return true, detail, stats
end

-- ---------------------------------------------------------------------------
-- Local pawn location, used as the "player position" reference for
-- distance ordering in describe / nearest. nil if the player isn't in
-- a world yet.
-- ---------------------------------------------------------------------------
local function pawn_location()
    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return nil end
    if pawn.K2_GetActorLocation then
        local ok, loc = pcall(function() return pawn:K2_GetActorLocation() end)
        if ok and loc then return loc end
    end
    if pawn.GetActorLocation then
        local ok, loc = pcall(function() return pawn:GetActorLocation() end)
        if ok and loc then return loc end
    end
    return nil
end

local function dist_sq(a, b)
    if not a or not b then return math.huge end
    local dx = (a.X or 0) - (b.X or 0)
    local dy = (a.Y or 0) - (b.Y or 0)
    local dz = (a.Z or 0) - (b.Z or 0)
    return dx * dx + dy * dy + dz * dz
end

-- ---------------------------------------------------------------------------
-- Capture a structured snapshot of a single building actor. Best-effort
-- on every field ; missing values come back as nil rather than aborting,
-- so a malformed actor just yields a sparse record instead of failing
-- the whole walk.
-- ---------------------------------------------------------------------------
local function snapshot_piece(actor)
    if not is_valid(actor) then return nil end
    local rec = {}

    pcall(function() rec.short_name = actor:GetName() end)
    pcall(function() rec.full_name = actor:GetFullName() end)
    pcall(function()
        local cls = actor:GetClass()
        if cls then rec.class_name = cls:GetFullName() end
    end)

    pcall(function() rec.piece_id = actor.BuildingPieceID end)
    pcall(function() rec.piece_data_index = actor.BuildingPieceDataIndex end)
    pcall(function()
        local pd = actor.BuildingPieceData
        if pd and pd.IsValid and pd:IsValid() then
            pcall(function() rec.piece_data_name = pd:GetFullName() end)
        end
    end)
    pcall(function()
        local g = actor.SpudGuid
        if g then
            -- FGuid often prints via tostring or :ToString() ; try both.
            local ok_ts, s = pcall(function() return tostring(g) end)
            if ok_ts and type(s) == "string" then rec.spud_guid = s end
            if not rec.spud_guid and g.ToString then
                local ok2, s2 = pcall(function() return g:ToString() end)
                if ok2 and type(s2) == "string" then rec.spud_guid = s2 end
            end
        end
    end)

    pcall(function() rec.stability = actor.StabilityValue end)
    pcall(function() rec.is_ghosted = actor.bIsGhosted end)
    pcall(function() rec.is_preview = actor.bIsPreview end)

    -- Location (preferred on the schema)
    local loc
    if actor.K2_GetActorLocation then
        pcall(function() loc = actor:K2_GetActorLocation() end)
    end
    if not loc and actor.GetActorLocation then
        pcall(function() loc = actor:GetActorLocation() end)
    end
    if loc then
        rec.x = loc.X; rec.y = loc.Y; rec.z = loc.Z
    end

    -- Full rotation. yaw remains the compatibility field used by old
    -- captures; pitch/roll allow SPUD-backed/interactable actors to
    -- replay with their live transform when the game supports it.
    local rot
    if actor.K2_GetActorRotation then
        pcall(function() rot = actor:K2_GetActorRotation() end)
    end
    if not rot and actor.GetActorRotation then
        pcall(function() rot = actor:GetActorRotation() end)
    end
    if rot then
        rec.pitch = rot.Pitch
        rec.yaw = rot.Yaw
        rec.roll = rot.Roll
        rec.actual_rot = { pitch = rot.Pitch, roll = rot.Roll, yaw = rot.Yaw }
    end

    -- Scale. Structural pieces usually persist unit scale only, but
    -- interactable/SPUD-backed building actors can carry full scale.
    local scale
    if actor.K2_GetActorScale3D then
        pcall(function() scale = actor:K2_GetActorScale3D() end)
    end
    if not scale and actor.GetActorScale3D then
        pcall(function() scale = actor:GetActorScale3D() end)
    end
    if scale then
        rec.scale_x = scale.X
        rec.scale_y = scale.Y
        rec.scale_z = scale.Z
        rec.actual_scale = { x = scale.X, y = scale.Y, z = scale.Z }
    end

    return rec
end

-- ---------------------------------------------------------------------------
-- Manager / subsystem cross-check counts, so we can see at a glance
-- whether FindAllOf agrees with the registry.
-- ---------------------------------------------------------------------------
local function manager_counts()
    local counts = { findall = nil, manager = nil, subsystem = nil }

    local actors = find_all_live("BaseBuildingActor")
    counts.findall = #actors

    local mgr = find_first_live("GlobalBuildingManager")
    if is_valid(mgr) then
        pcall(function()
            local m = mgr.BuildingPieces
            if m then
                local n
                pcall(function() n = m:Num() end)
                if type(n) ~= "number" then pcall(function() n = #m end) end
                counts.manager = n
            end
        end)
    end

    local sub = find_first_live("BuildingSubsystem")
    if is_valid(sub) then
        pcall(function()
            local m = sub.PieceIDToBuildingPieceActor
            if m then
                local n
                pcall(function() n = m:Num() end)
                if type(n) ~= "number" then pcall(function() n = #m end) end
                counts.subsystem = n
            end
        end)
    end

    return counts
end

-- ---------------------------------------------------------------------------
-- Authoritative enumeration: walk UBuildingSubsystem.PieceIDToBuildingPieceActor
-- (TMap<uint32, ABaseBuildingActor*>). This is the registry the placement
-- pipeline maintains, so a piece is in this map iff it has been
-- successfully registered as a player-placed structure. FindAllOf is
-- noisier (preview/ghost residue, CDOs) ; we keep it as a fallback only.
--
-- Returns: array of ABaseBuildingActor* userdata, in undefined order.
-- ---------------------------------------------------------------------------
local function enumerate_registered_pieces()
    local out = {}
    local sub = find_first_live("BuildingSubsystem")
    if is_valid(sub) then
        local map
        pcall(function() map = sub.PieceIDToBuildingPieceActor end)
        if map and map.ForEach then
            local ok = pcall(function()
                map:ForEach(function(_k, v)
                    -- TMap<uint32, ABaseBuildingActor*> ; v is the actor handle
                    local actor = v
                    -- UE4SS sometimes wraps the value in a property accessor ;
                    -- try :get() if direct use isn't a userdata.
                    if type(actor) ~= "userdata" then
                        local got
                        pcall(function() got = v:get() end)
                        if type(got) == "userdata" then actor = got end
                    end
                    if type(actor) == "userdata" and is_valid(actor) then
                        out[#out + 1] = actor
                    end
                end)
            end)
            if ok and #out > 0 then return out end
        end
    end

    -- Fallback: filter FindAllOf by manager.BuildingPieces membership
    -- (or just take everything FindAllOf returns if even that's missing).
    -- This branch should only fire if the subsystem map walk failed.
    print("[RSDWTools] buildings: subsystem map walk failed, falling back to FindAllOf")
    return find_all_live("BaseBuildingActor")
end

-- ---------------------------------------------------------------------------
-- Public: print a record to stdout in a single readable block. Used by
-- describe / nearest. Keeps numerics terse.
-- ---------------------------------------------------------------------------
local function fmt_num(v)
    if type(v) ~= "number" then return tostring(v) end
    return string.format("%.2f", v)
end

local function print_record(rec, distance)
    print("[RSDWTools] -- building piece --")
    if distance then
        print(string.format("  distance        : %.1f", distance))
    end
    print(string.format("  short_name      : %s", tostring(rec.short_name)))
    print(string.format("  class_name      : %s", tostring(rec.class_name)))
    print(string.format("  piece_id        : %s", tostring(rec.piece_id)))
    print(string.format("  piece_data_idx  : %s", tostring(rec.piece_data_index)))
    print(string.format("  piece_data_name : %s", tostring(rec.piece_data_name)))
    print(string.format("  spud_guid       : %s", tostring(rec.spud_guid)))
    print(string.format("  location        : (%s, %s, %s)",
        fmt_num(rec.x), fmt_num(rec.y), fmt_num(rec.z)))
    print(string.format("  yaw             : %s", fmt_num(rec.yaw)))
    if rec.actual_rot then
        print(string.format("  actual_rot      : pitch=%s roll=%s yaw=%s",
            fmt_num(rec.actual_rot.pitch), fmt_num(rec.actual_rot.roll), fmt_num(rec.actual_rot.yaw)))
    end
    if rec.actual_scale then
        print(string.format("  actual_scale    : (%s, %s, %s)",
            fmt_num(rec.actual_scale.x), fmt_num(rec.actual_scale.y), fmt_num(rec.actual_scale.z)))
    end
    print(string.format("  stability       : %s", fmt_num(rec.stability)))
    print(string.format("  is_ghosted      : %s  is_preview: %s",
        tostring(rec.is_ghosted), tostring(rec.is_preview)))
end

-- ---------------------------------------------------------------------------
-- world.buildings.count
-- Quick "how many pieces are alive right now?" probe. Returns the
-- FindAllOf number to the caller for the router's ok detail line ;
-- also logs the manager + subsystem cross-check.
-- ---------------------------------------------------------------------------
function M.count()
    return build_access.status()
end

-- ---------------------------------------------------------------------------
-- world.buildings.nearest
-- Find and dump the single closest BaseBuildingActor to the player.
-- ---------------------------------------------------------------------------
function M.nearest()
    local origin = pawn_location()
    if not origin then return false, "could not locate player pawn" end
    local records, err = build_access.capture_records(snapshot_piece)
    if not records then return false, err end
    local best, distance
    for _, rec in ipairs(records) do
        local d = dist_sq(origin, { X = rec.x, Y = rec.y, Z = rec.z })
        if not distance or d < distance then best, distance = rec, d end
    end
    if not best then return false, "no registered pieces" end
    print_record(best, math.sqrt(distance))
    return true, string.format("piece_id=%s dist=%.1f", tostring(best.piece_id), math.sqrt(distance))
end

-- ---------------------------------------------------------------------------
-- world.buildings.describe [N]
-- Logs cross-check counts and dumps the N closest pieces (default 3).
-- This is the schema-validation pass: with this output we can verify
-- whether every field we plan to serialize is actually populated, and
-- whether actual_rot/actual_scale ever deviate from the assumed
-- yaw-only / unit-scale invariants.
-- ---------------------------------------------------------------------------
function M.describe(args_str)
    local raw = tostring(args_str or ""):lower():match("^%s*(%S*)")
    local limit = raw == "all" and math.huge or math.max(1, math.floor(tonumber(raw) or 3))
    local records, detail = build_access.capture_records(snapshot_piece)
    if not records then return false, detail end
    local origin = pawn_location()
    if origin then
        table.sort(records, function(a, b)
            return dist_sq(origin, {X=a.x,Y=a.y,Z=a.z}) < dist_sq(origin, {X=b.x,Y=b.y,Z=b.z})
        end)
    end
    for i = 1, math.min(limit, #records) do
        local rec = records[i]
        print_record(rec, origin and math.sqrt(dist_sq(origin, {X=rec.x,Y=rec.y,Z=rec.z})) or nil)
    end
    return true, detail
end

-- ---------------------------------------------------------------------------
-- JSON encoding (minimal, hand-rolled to match the rest of the mod ;
-- no cjson dependency). Numbers are emitted with %.6g so floats round-trip
-- safely. Strings escape the same way feature_scan / feature_ui do.
-- ---------------------------------------------------------------------------
local function json_escape_str(s)
    local escaped = tostring(s or "")
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
    return '"' .. escaped .. '"'
end

local function json_num(v)
    if type(v) ~= "number" then return "null" end
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if v == math.floor(v) and math.abs(v) < 1e15 then
        return string.format("%d", v)
    end
    return string.format("%.6g", v)
end

local function json_bool(v)
    if v == nil then return "null" end
    return v and "true" or "false"
end

local function json_str_or_null(v)
    if v == nil then return "null" end
    return json_escape_str(v)
end

-- Encodes one piece record as a flat JSON object. We deliberately keep
-- the schema small + flat so a human can hand-edit a JSON if needed.
-- Fields the import path needs are required ; cosmetic / debug fields
-- (class_name, piece_data_name, stability) are kept for traceability
-- across a save move but ignored by replay.
local function encode_piece(rec)
    local parts = {
        '"piece_id":' .. json_num(rec.piece_id),
        '"piece_data_index":' .. json_num(rec.piece_data_index),
        '"piece_data_name":' .. json_str_or_null(rec.piece_data_name),
        '"class_name":' .. json_str_or_null(rec.class_name),
        '"capture_source":' .. json_str_or_null(rec.capture_source or "live_actor"),
        '"x":' .. json_num(rec.x),
        '"y":' .. json_num(rec.y),
        '"z":' .. json_num(rec.z),
        '"pitch":' .. json_num(rec.pitch),
        '"yaw":' .. json_num(rec.yaw),
        '"roll":' .. json_num(rec.roll),
        '"scale_x":' .. json_num(rec.scale_x),
        '"scale_y":' .. json_num(rec.scale_y),
        '"scale_z":' .. json_num(rec.scale_z),
        '"spud_guid":' .. json_str_or_null(rec.spud_guid),
        '"stability":' .. json_num(rec.stability),
        '"is_ghosted":' .. json_bool(rec.is_ghosted),
    }
    return "{" .. table.concat(parts, ",") .. "}"
end

local function full_name(obj)
    if not is_valid(obj) or not obj.GetFullName then return nil end
    local ok, value = pcall(function() return obj:GetFullName() end)
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
end

local function object_short_name(obj)
    if not is_valid(obj) then return nil end
    local name = feature_actor.short_name_of(obj)
    if name and name ~= "" then return name end
    if obj.GetName then
        local ok, value = pcall(function() return obj:GetName() end)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    return nil
end

local function object_path(obj)
    local full = full_name(obj)
    if not full then return nil end
    local path = full:match("^%S+%s+(.+)$") or full
    path = tostring(path or ""):match("^%s*(.-)%s*$") or ""
    path = path:gsub("^'", ""):gsub("'$", "")
    if path == "" then return nil end
    return path
end

local function read_world_item_data(actor)
    if not is_valid(actor) then return nil end
    for _, method_name in ipairs({ "BP_GetItemData", "GetSpawnedItemData", "GetPrimaryAssociatedItemData" }) do
        local fn = actor[method_name]
        if fn then
            local ok, value = pcall(function() return fn(actor) end)
            if ok and is_valid(value) then return value, method_name end
        end
    end
    for _, field_name in ipairs({ "ItemData", "SpawnedItemData", "PrimaryAssociatedItemData" }) do
        local ok, value = pcall(function() return actor[field_name] end)
        if ok and is_valid(value) then return value, field_name end
    end
    return nil
end

local function read_item_count(actor)
    if not is_valid(actor) then return 1 end
    for _, field_name in ipairs({ "Count", "ItemCount", "StackCount", "Quantity", "Amount" }) do
        local ok, value = pcall(function() return actor[field_name] end)
        local n = ok and tonumber(value) or nil
        if n and n >= 1 then return math.floor(n) end
    end
    return 1
end

local function actor_class_full_name(actor)
    if not is_valid(actor) then return nil end
    local cls
    pcall(function() cls = actor:GetClass() end)
    return full_name(cls)
end

local function snapshot_runtime_item(actor)
    if not is_valid(actor) then return nil, "invalid actor" end
    if feature_inventory._is_runtime_world_item
       and not feature_inventory._is_runtime_world_item(actor) then
        return nil, "not runtime item"
    end

    local item_data, item_source = read_world_item_data(actor)
    if not is_valid(item_data) then
        return nil, "no readable ItemData"
    end

    local loc = feature_actor.actor_location(actor)
    if not loc then return nil, "no actor location" end
    local rot = feature_actor.actor_rotation(actor) or { Pitch = 0, Yaw = 0, Roll = 0 }
    local scale = feature_actor.get_actor_scale3d(actor) or { X = 1, Y = 1, Z = 1 }

    return {
        actor_name      = object_short_name(actor),
        actor_class     = actor_class_full_name(actor),
        item_asset_name = object_short_name(item_data),
        item_asset_path = object_path(item_data),
        item_source     = item_source,
        count           = read_item_count(actor),
        x               = loc.X,
        y               = loc.Y,
        z               = loc.Z,
        pitch           = rot.Pitch,
        yaw             = rot.Yaw,
        roll            = rot.Roll,
        scale_x         = scale.X,
        scale_y         = scale.Y,
        scale_z         = scale.Z,
    }
end

local function encode_item(rec)
    local parts = {
        '"actor_name":' .. json_str_or_null(rec.actor_name),
        '"actor_class":' .. json_str_or_null(rec.actor_class),
        '"item_asset_name":' .. json_str_or_null(rec.item_asset_name),
        '"item_asset_path":' .. json_str_or_null(rec.item_asset_path),
        '"item_source":' .. json_str_or_null(rec.item_source),
        '"count":' .. json_num(rec.count),
        '"x":' .. json_num(rec.x),
        '"y":' .. json_num(rec.y),
        '"z":' .. json_num(rec.z),
        '"pitch":' .. json_num(rec.pitch),
        '"yaw":' .. json_num(rec.yaw),
        '"roll":' .. json_num(rec.roll),
        '"scale_x":' .. json_num(rec.scale_x),
        '"scale_y":' .. json_num(rec.scale_y),
        '"scale_z":' .. json_num(rec.scale_z),
    }
    return "{" .. table.concat(parts, ",") .. "}"
end

-- ---------------------------------------------------------------------------
-- Output path: <mod_root>\ipc\building\<name>.json
-- One file per export, no fixed prefix ; the WPF "Building Service" tab
-- enumerates everything in this folder regardless of filename so users
-- can drop shared .json files in directly.
-- ---------------------------------------------------------------------------
local function sanitize_name(name)
    -- Allow letters, digits, dash, underscore. Anything else becomes _.
    -- Empty / weird input falls back to "default".
    local s = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    -- Strip a trailing .json so users can paste full filenames.
    s = s:gsub("%.[Jj][Ss][Oo][Nn]$", "")
    if s == "" then return "default" end
    return (s:gsub("[^%w%-_]", "_"))
end

local function export_path_for(name)
    local dir = mod_paths.buildings_dir()
    if not dir then return nil end
    return dir .. "\\" .. sanitize_name(name) .. ".json"
end

-- ---------------------------------------------------------------------------
-- world.buildings.export <name>
-- ---------------------------------------------------------------------------
-- world.buildings.export <name> [ghosts_only]
-- Walks the registered pieces, snapshots each, writes JSON. Skips the
-- distance / actual_rot / actual_scale / spud_guid fields entirely ;;
-- describe verified the schema invariants so we don't carry the noise.
-- Pieces with missing required fields (no location, no piece_data_index)
-- are skipped with a log line instead of aborting.
--
-- The optional `ghosts_only` flag filters to pieces with is_ghosted=true.
-- Used by the WPF "Commit All Ghosts" workaround : capture ghosts to a
-- temp build, delete them, redeliver as real pieces (the engine's
-- Donation path doesn't seem to actually flip persistent ghosts to real
-- regardless of pre-filled CompletionStatus, so capture+rebuild is the
-- only reliable way).
-- ---------------------------------------------------------------------------
function M.export(args_str)
    local raw = tostring(args_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local ghosts_only = false
    local include_items = false
    -- Strip a trailing "include_items" / "items" token before anchor
    -- parsing so WPF can append it after anchor metadata.
    local stripped_i, n_i = raw:gsub("%s+[iI][nN][cC][lL][uU][dD][eE]_[iI][tT][eE][mM][sS]%s*$", "")
    if n_i > 0 then
        include_items = true
        raw = stripped_i
    else
        local stripped_items, n_items = raw:gsub("%s+[iI][tT][eE][mM][sS]%s*$", "")
        if n_items > 0 then
            include_items = true
            raw = stripped_items
        end
    end
    -- Strip a trailing "ghosts_only" token (case-insensitive) so the
    -- name parser doesn't fold it into the filename.
    local stripped, n_replaced = raw:gsub("%s+[gG][hH][oO][sS][tT][sS]_[oO][nN][lL][yY]%s*$", "")
    if n_replaced > 0 then
        ghosts_only = true
        raw = stripped
    end

    -- Optional anchor=<int> token : when present we record the chosen
    -- piece_data_index in the JSON top level so build.preview.preview
    -- can promote that piece to the reticle on delivery. Stripped from
    -- the name parser the same way ghosts_only is.
    local anchor_idx = nil
    local stripped_a, n_a = raw:gsub("%s+[aA][nN][cC][hH][oO][rR]=(%-?%d+)%s*$", function(num)
        anchor_idx = tonumber(num)
        return ""
    end)
    if n_a > 0 then raw = stripped_a end

    -- Optional anchor_pid=<int> token : the per-instance BuildingPieceID
    -- of the actor the user actually pointed at. piece_data_index alone
    -- is ambiguous when the build contains multiple copies of the same
    -- archetype (e.g. four foundations). With this we can pick the
    -- exact instance and physically swap it to position 1 so the
    -- preview path (which always uses pieces[1] as the anchor) lands
    -- on the right spot. Tokens can appear in either order.
    local anchor_pid = nil
    for _ = 1, 2 do
        local stripped_p, n_p = raw:gsub("%s+[aA][nN][cC][hH][oO][rR]_[pP][iI][dD]=(%-?%d+)%s*$",
            function(num)
                anchor_pid = tonumber(num)
                return ""
            end)
        if n_p > 0 then raw = stripped_p end
        local stripped_a2, n_a2 = raw:gsub("%s+[aA][nN][cC][hH][oO][rR]=(%-?%d+)%s*$", function(num)
            anchor_idx = tonumber(num)
            return ""
        end)
        if n_a2 > 0 then raw = stripped_a2 end
        if n_p == 0 and n_a2 == 0 then break end
    end

    local name = sanitize_name(raw)
    local out_path = export_path_for(name)
    if not out_path then
        return false, "could not resolve mod ipc directory (game not loaded?)"
    end

    local records, capture_detail = build_access.capture_records(snapshot_piece)
    if not records then return false, capture_detail end
    print("[RSDWTools] buildings.export: " .. capture_detail)
    if #records == 0 then
        return false, "no registered building pieces ; nothing to export"
    end

    local kept = {}
    local skipped = 0
    local filtered_out = 0
    for i = 1, #records do
        local rec = records[i]
        if rec
            and type(rec.piece_data_index) == "number"
            and type(rec.x) == "number"
            and type(rec.y) == "number"
            and type(rec.z) == "number" then
            if ghosts_only and rec.is_ghosted ~= true then
                filtered_out = filtered_out + 1
            else
                kept[#kept + 1] = rec
            end
        else
            skipped = skipped + 1
        end
    end

    if skipped > 0 then return false, "capture incomplete: refusing to write " .. tostring(skipped) .. " unresolved pieces" end

    -- Sort by Z ascending so the import path naturally rebuilds
    -- foundations before walls before roofs (stability dependencies).
    table.sort(kept, function(a, b) return (a.z or 0) < (b.z or 0) end)

    -- If an anchor was specified, physically promote that piece to
    -- position 1. Preview/import always treats pieces[1] as the anchor,
    -- so making it the actual anchor at capture time means we don't
    -- need any anchor-lookup logic at delivery time. Match priority:
    --   1. piece_id == anchor_pid   (per-instance ; unique)
    --   2. piece_data_index == anchor_idx (archetype ; first match wins)
    -- If neither hits, leave order alone and just record the metadata.
    local anchor_resolved_pid = nil
    if anchor_pid then
        for i = 1, #kept do
            if kept[i].piece_id == anchor_pid then
                if i > 1 then
                    local row = table.remove(kept, i)
                    table.insert(kept, 1, row)
                end
                anchor_resolved_pid = anchor_pid
                break
            end
        end
    end
    if not anchor_resolved_pid and anchor_idx then
        for i = 1, #kept do
            if kept[i].piece_data_index == anchor_idx then
                if i > 1 then
                    local row = table.remove(kept, i)
                    table.insert(kept, 1, row)
                end
                break
            end
        end
    end

    local items = {}
    local item_skipped = 0
    if include_items then
        local enumerator = feature_inventory._enumerate_runtime_world_items
        if type(enumerator) == "function" then
            local runtime_items = enumerator()
            for i = 1, #runtime_items do
                local rec, why = snapshot_runtime_item(runtime_items[i])
                if rec
                   and (type(rec.item_asset_name) == "string" or type(rec.item_asset_path) == "string")
                   and type(rec.x) == "number"
                   and type(rec.y) == "number"
                   and type(rec.z) == "number" then
                    items[#items + 1] = rec
                else
                    item_skipped = item_skipped + 1
                    print(string.format("[RSDWTools] buildings.export: skipped runtime item %d (%s)",
                        i, tostring(why or "missing required fields")))
                end
            end
        else
            item_skipped = item_skipped + 1
            print("[RSDWTools] buildings.export: runtime item enumerator unavailable")
        end
    end

    local body_parts = {}
    body_parts[#body_parts + 1] = '{"schema":"rsdwtools.buildings.v1"'
    body_parts[#body_parts + 1] = ',"name":' .. json_escape_str(name)
    body_parts[#body_parts + 1] = ',"generated_unix":' .. tostring(os.time())
    body_parts[#body_parts + 1] = ',"count":' .. tostring(#kept)
    body_parts[#body_parts + 1] = ',"skipped":' .. tostring(skipped)
    if include_items then
        body_parts[#body_parts + 1] = ',"item_count":' .. tostring(#items)
        body_parts[#body_parts + 1] = ',"item_skipped":' .. tostring(item_skipped)
    end
    if anchor_idx then
        body_parts[#body_parts + 1] = ',"anchor_piece_data_index":' .. tostring(anchor_idx)
    end
    if anchor_pid then
        body_parts[#body_parts + 1] = ',"anchor_piece_id":' .. tostring(anchor_pid)
    end
    body_parts[#body_parts + 1] = ',"pieces":['
    for i = 1, #kept do
        if i > 1 then body_parts[#body_parts + 1] = "," end
        body_parts[#body_parts + 1] = encode_piece(kept[i])
    end
    if include_items then
        body_parts[#body_parts + 1] = '],"items":['
        for i = 1, #items do
            if i > 1 then body_parts[#body_parts + 1] = "," end
            body_parts[#body_parts + 1] = encode_item(items[i])
        end
    end
    body_parts[#body_parts + 1] = ']}'
    local body = table.concat(body_parts)

    local ok, detail = mod_paths.write_atomic(out_path, body)
    if not ok then
        return false, "write failed: " .. tostring(detail)
    end
    if ghosts_only then
        print(string.format("[RSDWTools] buildings.export: wrote %d ghost pieces (filtered_out=%d skipped=%d items=%d item_skipped=%d) -> %s",
            #kept, filtered_out, skipped, #items, item_skipped, out_path))
        return true, string.format("count=%d filtered_out=%d skipped=%d%s path=%s",
            #kept, filtered_out, skipped,
            include_items and string.format(" items=%d item_skipped=%d", #items, item_skipped) or "",
            out_path)
    end
    print(string.format("[RSDWTools] buildings.export: wrote %d pieces (skipped %d items=%d item_skipped=%d) -> %s",
        #kept, skipped, #items, item_skipped, out_path))
    return true, string.format("count=%d skipped=%d%s path=%s",
        #kept, skipped,
        include_items and string.format(" items=%d item_skipped=%d", #items, item_skipped) or "",
        out_path)
end

-- ===========================================================================
-- IMPORT (v3): rebuild pieces from a previously exported JSON file.
--
-- Strategy:
--   1. Resolve player controller -> BuildModeComponent (the dump shows
--      ADominionPlayerController.BuildModeComponent at offset 0x0C60).
--   2. For each piece in the JSON, build an FTransform from
--      (x,y,z) + yaw and call Server_SpawnBuilding(piece_data_index,
--      transform, false, AvailableInventories).
--   3. AvailableInventories is passed empty -- the existing free-build
--      mod (world.foreach BuildingPieceData clear Requirements) zeros
--      cost, so the function should not need to consume from any
--      inventory.
--
-- Caveats called out up-front:
--   * No "creative-mode" placement bypass on this build that we know
--     of -- if Server_SpawnBuilding still validates collision/stability
--     against the live world, pieces in clipped/unsupported spots will
--     silently no-op.
--   * Yaw-only rebuild matches FClientVisibleBuildingPieceState ; pitch
--     and roll were always 0 in describe output. Quat is built from yaw.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Tiny ad-hoc JSON reader. Our exports are simple: one flat object with
-- "pieces" : [ { ...flat... }, ... ]. We don't need a full parser.
-- We pull the pieces array and split into individual {...} substrings,
-- then for each known field do a regex extract. This keeps us free of
-- third-party JSON deps.
-- ---------------------------------------------------------------------------
local function json_unescape(s)
    return (s:gsub("\\n", "\n"):gsub("\\r", "\r"):gsub("\\t", "\t")
             :gsub('\\"', '"'):gsub("\\\\", "\\"))
end

local function extract_named_array(body, key, required)
    -- Find "<key>":[ ... ] by paren-matching square brackets.
    local start_i = body:find('"' .. key .. '"%s*:%s*%[')
    if not start_i then
        if required == false then return nil, nil end
        return nil, "no " .. tostring(key) .. " array in JSON"
    end
    local arr_open = body:find("%[", start_i)
    if not arr_open then return nil, "malformed " .. tostring(key) .. " array" end

    local depth = 0
    local i = arr_open
    local n = #body
    local arr_close
    while i <= n do
        local c = body:sub(i, i)
        if c == "[" then depth = depth + 1
        elseif c == "]" then
            depth = depth - 1
            if depth == 0 then arr_close = i; break end
        elseif c == '"' then
            -- skip string
            i = i + 1
            while i <= n do
                local cc = body:sub(i, i)
                if cc == "\\" then i = i + 2
                elseif cc == '"' then break
                else i = i + 1 end
            end
        end
        i = i + 1
    end
    if not arr_close then return nil, "unterminated " .. tostring(key) .. " array" end
    return body:sub(arr_open + 1, arr_close - 1)
end

local function split_objects(arr_body)
    -- Walk arr_body and split into top-level {...} objects, ignoring
    -- braces inside strings. arr_body is the inside of [ ... ].
    local out = {}
    local i, n = 1, #arr_body
    while i <= n do
        -- skip whitespace + commas
        while i <= n and (arr_body:sub(i, i):match("[%s,]")) do i = i + 1 end
        if i > n then break end
        if arr_body:sub(i, i) ~= "{" then
            -- bail ; malformed
            return out
        end
        local depth = 0
        local start = i
        while i <= n do
            local c = arr_body:sub(i, i)
            if c == "{" then depth = depth + 1
            elseif c == "}" then
                depth = depth - 1
                if depth == 0 then
                    out[#out + 1] = arr_body:sub(start, i)
                    i = i + 1
                    break
                end
            elseif c == '"' then
                i = i + 1
                while i <= n do
                    local cc = arr_body:sub(i, i)
                    if cc == "\\" then i = i + 2
                    elseif cc == '"' then break
                    else i = i + 1 end
                end
            end
            i = i + 1
        end
    end
    return out
end

local function field_num(obj_body, key)
    local v = obj_body:match('"' .. key .. '"%s*:%s*(-?[%d%.eE%+%-]+)')
    return v and tonumber(v) or nil
end

local function field_str(obj_body, key)
    local v = obj_body:match('"' .. key .. '"%s*:%s*"((\\.?[^"\\]*)*)"')
    -- The pattern above is fragile under nested escapes ; fall back to
    -- a permissive grab if needed.
    if v then return json_unescape(v) end
    local raw = obj_body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
    return raw and json_unescape(raw) or nil
end

local function field_bool(obj_body, key)
    local v = obj_body:match('"' .. key .. '"%s*:%s*(%a+)')
    if v == "true" then return true end
    if v == "false" then return false end
    return nil
end

local class_path_from_full

local function parse_pieces(body)
    local arr, err = extract_named_array(body, "pieces", true)
    if not arr then return nil, err end
    local objs = split_objects(arr)
    local out = {}
    for i = 1, #objs do
        local o = objs[i]
        out[#out + 1] = {
            piece_id         = field_num(o, "piece_id"),
            piece_data_index = field_num(o, "piece_data_index"),
            piece_data_name  = field_str(o, "piece_data_name"),
            class_name       = field_str(o, "class_name"),
            x                = field_num(o, "x"),
            y                = field_num(o, "y"),
            z                = field_num(o, "z"),
            pitch            = field_num(o, "pitch"),
            yaw              = field_num(o, "yaw"),
            roll             = field_num(o, "roll"),
            scale_x          = field_num(o, "scale_x"),
            scale_y          = field_num(o, "scale_y"),
            scale_z          = field_num(o, "scale_z"),
            spud_guid        = field_str(o, "spud_guid"),
            stability        = field_num(o, "stability"),
            is_ghosted       = field_bool(o, "is_ghosted"),
        }
    end
    return out
end

local function parse_items(body)
    local arr, err = extract_named_array(body, "items", false)
    if not arr then
        if err then return nil, err end
        return {}
    end
    local objs = split_objects(arr)
    local out = {}
    for i = 1, #objs do
        local o = objs[i]
        out[#out + 1] = {
            actor_name      = field_str(o, "actor_name"),
            actor_class     = field_str(o, "actor_class"),
            item_asset_name = field_str(o, "item_asset_name"),
            item_asset_path = field_str(o, "item_asset_path"),
            item_source     = field_str(o, "item_source"),
            count           = field_num(o, "count"),
            x               = field_num(o, "x"),
            y               = field_num(o, "y"),
            z               = field_num(o, "z"),
            pitch           = field_num(o, "pitch"),
            yaw             = field_num(o, "yaw"),
            roll            = field_num(o, "roll"),
            scale_x         = field_num(o, "scale_x"),
            scale_y         = field_num(o, "scale_y"),
            scale_z         = field_num(o, "scale_z"),
        }
    end
    return out
end

local function parse_actors(body)
    local arr, err = extract_named_array(body, "actors", false)
    if not arr then
        if err then return nil, err end
        return {}
    end
    local objs = split_objects(arr)
    local out = {}
    for i = 1, #objs do
        local o = objs[i]
        local class_path = field_str(o, "class_path")
            or field_str(o, "path")
            or field_str(o, "bp")
            or field_str(o, "class")
        if not class_path then
            class_path = class_path_from_full(field_str(o, "actor_class"))
        end
        out[#out + 1] = {
            actor_name  = field_str(o, "actor_name"),
            actor_class = field_str(o, "actor_class"),
            class_path  = class_path,
            x           = field_num(o, "x"),
            y           = field_num(o, "y"),
            z           = field_num(o, "z"),
            pitch       = field_num(o, "pitch"),
            yaw         = field_num(o, "yaw"),
            roll        = field_num(o, "roll"),
            scale_x     = field_num(o, "scale_x"),
            scale_y     = field_num(o, "scale_y"),
            scale_z     = field_num(o, "scale_z"),
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Player / build-mode resolution. We need the live ADominionPlayerController
-- and its UBuildModeComponent (offset 0x0C60 in dumps).
-- ---------------------------------------------------------------------------
local function get_local_pc_and_bmc()
    -- Use feature_net for the canonical local-PC lookup so this
    -- always agrees with the rest of the mod in multiplayer.
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
-- Build an FTransform-shaped Lua table from x/y/z + full rotator +
-- scale. UE4SS will coerce a table with the same field names as the
-- struct layout into the parameter. Old JSON that only has yaw falls
-- back to pitch=0, roll=0, scale=1.
-- ---------------------------------------------------------------------------
local function rotator_to_quat(pitch_deg, yaw_deg, roll_deg)
    local pitch = (pitch_deg or 0) * math.pi / 180.0
    local yaw = (yaw_deg or 0) * math.pi / 180.0
    local roll = (roll_deg or 0) * math.pi / 180.0
    local cy, sy = math.cos(yaw * 0.5), math.sin(yaw * 0.5)
    local cp, sp = math.cos(pitch * 0.5), math.sin(pitch * 0.5)
    local cr, sr = math.cos(roll * 0.5), math.sin(roll * 0.5)
    return {
        -- Match Unreal's FRotator::Quaternion sign convention. Using
        -- the usual math-library XYZ convention flips Pitch/Roll while
        -- leaving Yaw looking correct.
        X = cr * sp * sy - sr * cp * cy,
        Y = -cr * sp * cy - sr * cp * sy,
        Z = cr * cp * sy - sr * sp * cy,
        W = cr * cp * cy + sr * sp * sy,
    }
end

local function make_transform(x, y, z, pitch_deg, yaw_deg, roll_deg, sx, sy, sz)
    return {
        Rotation    = rotator_to_quat(pitch_deg, yaw_deg, roll_deg),
        Translation = { X = x or 0, Y = y or 0, Z = z or 0 },
        Scale3D     = { X = sx or 1, Y = sy or 1, Z = sz or 1 },
    }
end

local function normalize_count(v)
    local n = tonumber(v) or 1
    if n < 1 then n = 1 end
    if n > 9999 then n = 9999 end
    return math.floor(n)
end

function class_path_from_full(full)
    if type(full) ~= "string" or full == "" then return nil end
    local path = full:match("^%S+%s+(.+)$") or full
    path = tostring(path or ""):match("^%s*(.-)%s*$") or ""
    path = path:gsub("^'", ""):gsub("'$", "")
    if path == "" then return nil end
    return path
end

local function apply_actor_transform(actor, rec)
    if not is_valid(actor) or type(rec) ~= "table" then
        return false, "invalid actor/record"
    end
    feature_actor.force_actor_movable(actor)
    pcall(function() actor.bRegisterAsRuntimeSpawned = true end)

    local loc = { X = rec.x or 0, Y = rec.y or 0, Z = rec.z or 0 }
    local rot = { Pitch = rec.pitch or 0, Yaw = rec.yaw or 0, Roll = rec.roll or 0 }
    local scale = {
        X = rec.scale_x or 1,
        Y = rec.scale_y or 1,
        Z = rec.scale_z or 1,
    }

    local ok_loc, loc_err = feature_actor.move_actor(actor, loc)
    if not ok_loc then return false, "move failed: " .. tostring(loc_err) end
    if not feature_actor.set_actor_rotation(actor, rot) then return false, "item rotation apply failed after spawn" end
    if not feature_actor.set_actor_scale3d(actor, scale) then return false, "item scale apply failed after spawn" end
    return true
end

local function spawn_item_record(rec)
    if type(rec) ~= "table" then return false, "bad item record" end
    if type(rec.x) ~= "number" or type(rec.y) ~= "number" or type(rec.z) ~= "number" then
        return false, "item missing x/y/z"
    end
    local count = normalize_count(rec.count)
    local item_name = rec.item_asset_name
    local item_path = rec.item_asset_path
    local ok_spawn, spawn_detail = false, nil

    if type(item_name) == "string" and item_name ~= "" then
        ok_spawn, spawn_detail = feature_inventory.give(item_name .. " " .. tostring(count))
    elseif type(item_path) == "string" and item_path ~= "" then
        local actor_class_path = class_path_from_full(rec.actor_class)
        local spawn_args = item_path .. " " .. tostring(count)
        if actor_class_path then spawn_args = spawn_args .. " " .. actor_class_path end
        ok_spawn, spawn_detail = feature_player_spawn.spawn_item(spawn_args)
    end
    if not ok_spawn then
        return false, "spawn failed: " .. tostring(spawn_detail or "no item identity")
    end

    local actor
    pcall(function() actor = feature_field.resolve_root("lastspawned") end)
    if not is_valid(actor) then
        return false, "spawned item but lastspawned was not resolvable"
    end

    local ok_xform, xform_detail = apply_actor_transform(actor, rec)
    if not ok_xform then
        return false, xform_detail
    end

    local ok_stable, stable_result = feature_inventory.stabilize_runtime_world_item(actor)
    if not ok_stable then
        local err = stable_result
        if type(stable_result) == "table" then
            err = stable_result.error or stable_result.detail or stable_result.message
        end
        return false, "stabilize failed after spawn: " .. tostring(err)
    end

    local actions = 0
    local failures = 0
    if type(stable_result) == "table" then
        if type(stable_result.actions) == "table" then actions = #stable_result.actions end
        if type(stable_result.failures) == "table" then failures = #stable_result.failures end
    end
    return true, tostring(spawn_detail or "spawned")
        .. string.format(" ; stabilized actions=%d failures=%d", actions, failures)
end

local function replay_items_absolute(items)
    if type(items) ~= "table" or #items == 0 then
        return { sent = 0, failed = 0, skipped = 0 }
    end
    local counts = { sent = 0, failed = 0, skipped = 0 }
    for i = 1, #items do
        local rec = items[i]
        local ok, detail = spawn_item_record(rec)
        if ok then
            counts.sent = counts.sent + 1
            print(string.format("[RSDWTools] buildings.import: item[%d] spawned %s x%d at (%.1f, %.1f, %.1f) ; %s",
                i, tostring(rec.item_asset_name or rec.item_asset_path), normalize_count(rec.count),
                rec.x or 0, rec.y or 0, rec.z or 0, tostring(detail or "")))
        else
            counts.failed = counts.failed + 1
            print(string.format("[RSDWTools] buildings.import: item[%d] failed (%s)",
                i, tostring(detail)))
        end
    end
    return counts
end

local function rotate_record_relative(rec, origin, anchor_loc, theta_deg)
    if type(rec) ~= "table" or type(origin) ~= "table" or not anchor_loc then return nil end
    if type(rec.x) ~= "number" or type(rec.y) ~= "number" or type(rec.z) ~= "number" then return nil end
    local theta_rad = (theta_deg or 0) * math.pi / 180.0
    local cos_t, sin_t = math.cos(theta_rad), math.sin(theta_rad)
    local dx = rec.x - (origin.x or 0)
    local dy = rec.y - (origin.y or 0)
    local dz = rec.z - (origin.z or 0)
    local rx = dx * cos_t - dy * sin_t
    local ry = dx * sin_t + dy * cos_t
    local out = {}
    for k, v in pairs(rec) do out[k] = v end
    out.x = (anchor_loc.X or 0) + rx
    out.y = (anchor_loc.Y or 0) + ry
    out.z = (anchor_loc.Z or 0) + dz
    out.yaw = (rec.yaw or 0) + (theta_deg or 0)
    return out
end

local function transform_records_relative(records, origin, anchor_loc, theta_deg, label)
    local transformed = {}
    local skipped = 0
    if type(records) ~= "table" then return transformed, skipped end
    for i = 1, #records do
        local rec = rotate_record_relative(records[i], origin, anchor_loc, theta_deg)
        if rec then
            transformed[#transformed + 1] = rec
        else
            skipped = skipped + 1
            print(string.format(
                "[RSDWTools] buildings.import: %s[%d] skipped (bad relative transform)",
                tostring(label or "record"), i))
        end
    end
    return transformed, skipped
end

local function replay_items_relative(items, origin, anchor_loc, theta_deg)
    if type(items) ~= "table" or #items == 0 then
        return { sent = 0, failed = 0, skipped = 0 }
    end
    local transformed, skipped = transform_records_relative(
        items, origin, anchor_loc, theta_deg, "item")
    local counts = { sent = 0, failed = 0, skipped = skipped }
    local spawned = replay_items_absolute(transformed)
    counts.sent = counts.sent + spawned.sent
    counts.failed = counts.failed + spawned.failed
    counts.skipped = counts.skipped + spawned.skipped
    return counts
end

local function spawn_transform_args(class_path, rec)
    local cp = class_path_from_full(class_path)
    if not cp or cp == "" then return nil, "missing class_path" end
    if type(rec.x) ~= "number" or type(rec.y) ~= "number" or type(rec.z) ~= "number" then
        return nil, "actor missing x/y/z"
    end
    return string.format(
        '%s {"loc":[%s,%s,%s],"rot":[%s,%s,%s],"scale":[%s,%s,%s]}',
        cp,
        json_num(rec.x), json_num(rec.y), json_num(rec.z),
        json_num(rec.pitch or 0), json_num(rec.yaw or 0), json_num(rec.roll or 0),
        json_num(rec.scale_x or 1), json_num(rec.scale_y or 1), json_num(rec.scale_z or 1)
    ), nil
end

local function spawn_actor_record(rec)
    if type(rec) ~= "table" then return false, "bad actor record" end
    local class_path = rec.class_path or class_path_from_full(rec.actor_class)
    local args, arg_err = spawn_transform_args(class_path, rec)
    if not args then return false, arg_err end
    local ok, detail = feature_player_spawn.spawn_transform(args)
    if not ok then return false, detail end
    return true, detail
end

local function replay_actors_absolute(actors)
    if type(actors) ~= "table" or #actors == 0 then
        return { sent = 0, failed = 0, skipped = 0 }
    end
    local counts = { sent = 0, failed = 0, skipped = 0 }
    for i = 1, #actors do
        local rec = actors[i]
        local ok, detail = spawn_actor_record(rec)
        if ok then
            counts.sent = counts.sent + 1
            print(string.format("[RSDWTools] buildings.import: actor[%d] spawned %s at (%.1f, %.1f, %.1f) ; %s",
                i, tostring(rec.class_path or rec.actor_class), rec.x or 0, rec.y or 0, rec.z or 0,
                tostring(detail or "")))
        else
            counts.failed = counts.failed + 1
            print(string.format("[RSDWTools] buildings.import: actor[%d] failed (%s)",
                i, tostring(detail)))
        end
    end
    return counts
end

local function replay_actors_relative(actors, origin, anchor_loc, theta_deg)
    if type(actors) ~= "table" or #actors == 0 then
        return { sent = 0, failed = 0, skipped = 0 }
    end
    local transformed, skipped = transform_records_relative(
        actors, origin, anchor_loc, theta_deg, "actor")
    local counts = { sent = 0, failed = 0, skipped = skipped }
    local spawned = replay_actors_absolute(transformed)
    counts.sent = counts.sent + spawned.sent
    counts.failed = counts.failed + spawned.failed
    counts.skipped = counts.skipped + spawned.skipped
    return counts
end

-- ---------------------------------------------------------------------------
-- Paced build-content delivery
--
-- Server_SpawnBuilding is a reliable RPC, but a successful Lua call only
-- proves that the request was dispatched. Newer game builds need time to
-- register support/placement state between pieces, so replaying hundreds of
-- calls in one frame can leave a large portion of the structure unplaced.
-- Included runtime items and actors/NPCs use heavier synchronous spawn paths,
-- so they share this queue instead of all running in the final piece tick.
--
-- One delivery may be active at a time. LoopAsync supplies the wall-clock
-- cadence and ExecuteInGameThread performs paced work. A zero interval is an
-- explicit compatibility option that batches all content in one game-thread
-- turn. The status verb lets WPF keep requirements cleared until all work has
-- actually been dispatched.
-- ---------------------------------------------------------------------------
local DELIVERY_INTERVAL_MS = 0
local DELIVERY_MIN_INTERVAL_MS = 0
local DELIVERY_MAX_INTERVAL_MS = 5000
local DELIVERY_DIRECT_SETTLE_TICKS = 1
local DELIVERY_PREVIEW_SETTLE_TICKS = 6
local DELIVERY_FINAL_SETTLE_TICKS = 8

M._delivery_active = nil
M._delivery_last = nil
M._delivery_next_id = 0
M._delivery_external_pump = false

local function error_text(value, fallback)
    if value == nil then return fallback or "unknown error" end
    if type(value) == "string" then return value end
    local ok, text = pcall(function() return tostring(value) end)
    if ok and type(text) == "string" and text ~= "" then return text end
    return fallback or "unprintable error"
end

local function normalize_delivery_interval_ms(value)
    local parsed = tonumber(value) or DELIVERY_INTERVAL_MS
    return math.max(
        DELIVERY_MIN_INTERVAL_MS,
        math.min(DELIVERY_MAX_INTERVAL_MS, math.floor(parsed)))
end

local function parse_delivery_interval_ms(args_str)
    local raw = tostring(args_str or ""):lower()
    local token = raw:match("interval_ms%s*=%s*([^%s]+)")
    if token == nil then return nil end
    local value = tonumber(token)
    if value == nil then
        return nil, string.format(
            "interval_ms must be a number from %d to %d",
            DELIVERY_MIN_INTERVAL_MS, DELIVERY_MAX_INTERVAL_MS)
    end
    return normalize_delivery_interval_ms(value)
end

local function delivery_count_detail(prefix, counts)
    counts = type(counts) == "table" and counts or {}
    return string.format("%s_sent=%d %s_failed=%d %s_skipped=%d",
        prefix, tonumber(counts.sent) or 0,
        prefix, tonumber(counts.failed) or 0,
        prefix, tonumber(counts.skipped) or 0)
end

local function delivery_processed(job)
    local item_counts = type(job.item_counts) == "table" and job.item_counts or {}
    local actor_counts = type(job.actor_counts) == "table" and job.actor_counts or {}
    return (tonumber(job.dispatched) or 0)
        + (tonumber(job.failed) or 0)
        + (tonumber(item_counts.sent) or 0)
        + (tonumber(item_counts.failed) or 0)
        + (tonumber(actor_counts.sent) or 0)
        + (tonumber(actor_counts.failed) or 0)
end

local function delivery_has_errors(job)
    local item_counts = type(job.item_counts) == "table" and job.item_counts or {}
    local actor_counts = type(job.actor_counts) == "table" and job.actor_counts or {}
    return (tonumber(job.failed) or 0) > 0
        or (tonumber(job.skipped) or 0) > 0
        or (tonumber(item_counts.failed) or 0) > 0
        or (tonumber(item_counts.skipped) or 0) > 0
        or (tonumber(actor_counts.failed) or 0) > 0
        or (tonumber(actor_counts.skipped) or 0) > 0
end

local function delivery_status_detail(job)
    if type(job) ~= "table" then
        return "delivery active=0 state=idle"
    end
    local processed = delivery_processed(job)
    local total = tonumber(job.total) or 0
    local remaining = math.max(0, total - processed)
    local piece_processed = (tonumber(job.dispatched) or 0) + (tonumber(job.failed) or 0)
    local active = M._delivery_active == job and 1 or 0
    local detail = string.format(
        "delivery id=%d active=%d state=%s source=%s total=%d processed=%d remaining=%d interval_ms=%d dispatch_mode=%s pieces_total=%d pieces_processed=%d dispatched=%d failed=%d skipped=%d items_total=%d actors_total=%d indices_remapped=%d legacy_index_fallback=%d",
        tonumber(job.id) or 0, active, tostring(job.state or "unknown"),
        tostring(job.source or "unknown"), total, processed, remaining,
        tonumber(job.interval_ms) or DELIVERY_INTERVAL_MS,
        (tonumber(job.interval_ms) or DELIVERY_INTERVAL_MS) == 0 and "instant_batch" or "paced",
        tonumber(job.piece_total) or 0, piece_processed,
        tonumber(job.dispatched) or 0, tonumber(job.failed) or 0,
        tonumber(job.skipped) or 0,
        tonumber(job.item_total) or 0, tonumber(job.actor_total) or 0,
        tonumber(job.indices_remapped) or 0,
        tonumber(job.legacy_index_fallback) or 0)
    if job.item_counts then
        detail = detail .. " " .. delivery_count_detail("items", job.item_counts)
    end
    if job.actor_counts then
        detail = detail .. " " .. delivery_count_detail("actors", job.actor_counts)
    end
    if job.error then
        detail = detail .. " error=" .. tostring(job.error):gsub("%s+", "_")
    end
    if job.request_id then detail = detail .. " request=" .. job.request_id end
    return detail
end

local function fail_delivery(job, err)
    if type(job) ~= "table" then return end
    job.state = "failed"
    job.error = error_text(err, "unknown delivery error")
    job.step_pending = false
    job.bmc = nil
    if M._delivery_active == job then M._delivery_active = nil end
    M._delivery_last = job
    print("[RSDWTools] buildings.delivery: " .. delivery_status_detail(job))
end

local function complete_delivery(job)
    job.state = "finalizing"
    job.state = delivery_has_errors(job) and "complete_with_errors" or "complete"
    job.step_pending = false
    job.bmc = nil
    if M._delivery_active == job then M._delivery_active = nil end
    M._delivery_last = job
    print("[RSDWTools] buildings.delivery: " .. delivery_status_detail(job))
end

local function run_delivery_step(job, quiet)
    if M._delivery_active ~= job then return end

    if job.state == "settling_start" then
        if job.settle_remaining > 0 then
            job.settle_remaining = job.settle_remaining - 1
            return
        end
        job.state = "dispatching_pieces"
    end

    if job.state == "dispatching_pieces" then
        local entry = job.entries[job.cursor]
        if entry then
            if not is_valid(job.bmc) or not job.bmc.Server_SpawnBuilding then
                fail_delivery(job, "BuildModeComponent became invalid")
                return
            end
            local xform = make_transform(
                entry.x, entry.y, entry.z,
                entry.pitch, entry.yaw, entry.roll,
                entry.scale_x, entry.scale_y, entry.scale_z)
            local ok, err = pcall(function()
                job.bmc:Server_SpawnBuilding(
                    entry.piece_data_index, xform, job.spawn_ghost, job.empty_inv)
            end)
            job.cursor = job.cursor + 1
            if ok then
                job.dispatched = job.dispatched + 1
            else
                job.failed = job.failed + 1
                print(string.format(
                    "[RSDWTools] buildings.delivery: id=%d piece=%d index=%s dispatch failed: %s",
                    job.id, job.cursor - 1, tostring(entry.piece_data_index), tostring(err)))
            end
            local processed = delivery_processed(job)
            if not quiet and (processed == 1 or processed % 25 == 0 or processed == job.total) then
                print("[RSDWTools] buildings.delivery: " .. delivery_status_detail(job))
            end
            return
        end
        job.state = "dispatching_items"
    end

    if job.state == "dispatching_items" then
        local rec = job.item_entries[job.item_cursor]
        if rec then
            local call_ok, ok, detail = pcall(spawn_item_record, rec)
            job.item_cursor = job.item_cursor + 1
            if call_ok and ok then
                job.item_counts.sent = job.item_counts.sent + 1
                print(string.format(
                    "[RSDWTools] buildings.import: item[%d] spawned %s x%d at (%.1f, %.1f, %.1f) ; %s",
                    job.item_cursor - 1,
                    tostring(rec.item_asset_name or rec.item_asset_path),
                    normalize_count(rec.count),
                    rec.x or 0, rec.y or 0, rec.z or 0,
                    tostring(detail or "")))
            else
                job.item_counts.failed = job.item_counts.failed + 1
                local err = call_ok and detail or ok
                print(string.format(
                    "[RSDWTools] buildings.import: item[%d] failed (%s)",
                    job.item_cursor - 1, tostring(err)))
            end
            local processed = delivery_processed(job)
            if not quiet and (processed == 1 or processed % 25 == 0 or processed == job.total) then
                print("[RSDWTools] buildings.delivery: " .. delivery_status_detail(job))
            end
            return
        end
        job.state = "dispatching_actors"
    end

    if job.state == "dispatching_actors" then
        local rec = job.actor_entries[job.actor_cursor]
        if rec then
            local call_ok, ok, detail = pcall(spawn_actor_record, rec)
            job.actor_cursor = job.actor_cursor + 1
            if call_ok and ok then
                job.actor_counts.sent = job.actor_counts.sent + 1
                print(string.format(
                    "[RSDWTools] buildings.import: actor[%d] spawned %s at (%.1f, %.1f, %.1f) ; %s",
                    job.actor_cursor - 1,
                    tostring(rec.class_path or rec.actor_class),
                    rec.x or 0, rec.y or 0, rec.z or 0,
                    tostring(detail or "")))
            else
                job.actor_counts.failed = job.actor_counts.failed + 1
                local err = call_ok and detail or ok
                print(string.format(
                    "[RSDWTools] buildings.import: actor[%d] failed (%s)",
                    job.actor_cursor - 1, tostring(err)))
            end
            local processed = delivery_processed(job)
            if not quiet and (processed == 1 or processed % 25 == 0 or processed == job.total) then
                print("[RSDWTools] buildings.delivery: " .. delivery_status_detail(job))
            end
            return
        end
        job.state = "settling_finish"
        job.settle_remaining = job.final_settle_ticks
    end

    if job.state == "settling_finish" then
        if job.settle_remaining > 0 then
            job.settle_remaining = job.settle_remaining - 1
            return
        end
        complete_delivery(job)
    end
end

function M.set_delivery_external_pump(enabled)
    M._delivery_external_pump = enabled == true
end

-- Called from the bridge's single scheduler loop. This prevents a second
-- LoopAsync callback from entering Lua while WPF status polling is active.
-- A zero interval batches all content in one game-thread turn after the
-- normal anchor settle; positive intervals dispatch one record when due.
function M.delivery_pump(elapsed_ms)
    local job = M._delivery_active
    if type(job) ~= "table" or job.state == "waiting_for_anchor" or job.step_pending then
        return false
    end
    if not ExecuteInGameThread then return false, "ExecuteInGameThread unavailable" end

    local interval = tonumber(job.interval_ms) or DELIVERY_INTERVAL_MS
    local state = tostring(job.state or "")
    if interval > 0 and state:match("^dispatching_") then
        job.interval_elapsed_ms = (tonumber(job.interval_elapsed_ms) or 0)
            + math.max(1, tonumber(elapsed_ms) or 1)
        if job.interval_elapsed_ms < interval then return false end
        job.interval_elapsed_ms = job.interval_elapsed_ms % interval
    end

    local id = job.id
    job.step_pending = true
    local scheduled, schedule_err = pcall(function()
        ExecuteInGameThread(function()
            local current = M._delivery_active
            if current ~= job or current.id ~= id then return end
            local step_ok, step_err = pcall(function()
                if interval == 0 then
                    local limit = math.max(16,
                        #current.entries + #current.item_entries + #current.actor_entries + 16)
                    for _ = 1, limit do
                        if M._delivery_active ~= current then break end
                        local before = current.state
                        run_delivery_step(current, true)
                        if before == "settling_start" and current.state == "settling_start" then break end
                        if current.state == "settling_finish" then break end
                    end
                    if M._delivery_active == current and current.state == "settling_finish"
                        and not current.instant_batch_logged then
                        current.instant_batch_logged = true
                        print("[RSDWTools] buildings.delivery: instant batch dispatched ; "
                            .. delivery_status_detail(current))
                    end
                else
                    run_delivery_step(current, false)
                end
            end)
            current.step_pending = false
            if not step_ok then
                fail_delivery(current, error_text(step_err, "delivery step failed without an error message"))
            end
        end)
    end)
    if not scheduled then
        job.step_pending = false
        fail_delivery(job, "could not schedule game-thread step: "
            .. error_text(schedule_err, "unknown scheduler error"))
        return false, job.error
    end
    return true
end

local function start_delivery_loop(job)
    if M._delivery_external_pump then return true end
    if not LoopAsync then return false, "LoopAsync unavailable" end

    local id = job.id
    local scheduler_delay_ms = math.max(1, job.interval_ms)
    local loop_ok, loop_err = pcall(function()
        LoopAsync(scheduler_delay_ms, function()
            local active = M._delivery_active
            if active ~= job or active.id ~= id then return true end
            M.delivery_pump(scheduler_delay_ms)
            return false
        end)
    end)
    if not loop_ok then
        return false, "could not start delivery loop: " .. error_text(loop_err)
    end
    return true
end

local function queue_piece_delivery(opts)
    opts = opts or {}
    if (tonumber(opts.skipped) or 0) > 0 or (tonumber(opts.item_skipped) or 0) > 0
        or (tonumber(opts.actor_skipped) or 0) > 0 then
        return false, "delivery preflight failed: unresolved transforms; no entries dispatched"
    end
    local reserved = opts.resume_id and M._delivery_active
    if opts.resume_id and (not reserved or reserved.id ~= opts.resume_id or reserved.state ~= "waiting_for_anchor") then
        return false, "preview delivery reservation expired or cancelled"
    end
    if M._delivery_active and not reserved then
        return false, "delivery already active ; " .. delivery_status_detail(M._delivery_active)
    end
    local entries = type(opts.entries) == "table" and opts.entries or {}
    local item_entries = type(opts.item_entries) == "table" and opts.item_entries or {}
    local actor_entries = type(opts.actor_entries) == "table" and opts.actor_entries or {}
    for _, group in ipairs({ entries, item_entries, actor_entries }) do
        for i, rec in ipairs(group) do
            for _, field in ipairs({ "x", "y", "z", "pitch", "yaw", "roll", "scale_x", "scale_y", "scale_z" }) do
                local v = rec[field]
                local required = field == "x" or field == "y" or field == "z"
                if (required or v ~= nil) and (type(v) ~= "number" or v ~= v or math.abs(v) == math.huge) then
                    return false, "delivery preflight failed: invalid " .. field .. " in record " .. i
                end
            end
        end
    end
    if #entries > 0 and not is_valid(opts.bmc) then
        return false, "invalid BuildModeComponent"
    end
    local indices_ok, indices_detail, indices_stats = resolve_piece_indices(entries)
    if not indices_ok then
        return false, "piece identity validation failed: " .. tostring(indices_detail)
    end
    if #entries > 0 then
        print("[RSDWTools] buildings.delivery: " .. indices_detail)
    end

    if opts.validate_only then
        return true, string.format("preflight passed pieces=%d items=%d actors=%d; %s", #entries, #item_entries, #actor_entries, indices_detail)
    end

    if not reserved then M._delivery_next_id = M._delivery_next_id + 1 end
    local native_anchor = opts.native_anchor == true and 1 or 0
    local job = {
        id = reserved and reserved.id or M._delivery_next_id,
        request_id = opts.request_id or (reserved and reserved.request_id),
        source = tostring(opts.source or "unknown"):gsub("%s+", "_"),
        state = opts.wait_for_anchor and "waiting_for_anchor" or "settling_start",
        entries = entries,
        piece_total = #entries + native_anchor,
        item_entries = item_entries,
        item_total = #item_entries,
        actor_entries = actor_entries,
        actor_total = #actor_entries,
        total = #entries + #item_entries + #actor_entries + native_anchor,
        cursor = 1,
        item_cursor = 1,
        actor_cursor = 1,
        dispatched = native_anchor,
        failed = 0,
        skipped = tonumber(opts.skipped) or 0,
        item_counts = {
            sent = 0,
            failed = 0,
            skipped = tonumber(opts.item_skipped) or 0,
        },
        actor_counts = {
            sent = 0,
            failed = 0,
            skipped = tonumber(opts.actor_skipped) or 0,
        },
        bmc = opts.bmc,
        empty_inv = {},
        spawn_ghost = opts.spawn_ghost == true,
        interval_ms = normalize_delivery_interval_ms(opts.interval_ms),
        settle_remaining = math.max(0, math.floor(
            tonumber(opts.initial_settle_ticks) or DELIVERY_DIRECT_SETTLE_TICKS)),
        final_settle_ticks = math.max(0, math.floor(
            tonumber(opts.final_settle_ticks) or DELIVERY_FINAL_SETTLE_TICKS)),
        indices_remapped = indices_stats.remapped,
        legacy_index_fallback = indices_stats.fallback,
        step_pending = false,
    }
    M._delivery_active = job
    M._delivery_last = job

    if opts.wait_for_anchor then
        return true, string.format("waiting_for_anchor id=%d total=%d interval_ms=%d; left-click one valid anchor in-game", job.id, job.total, job.interval_ms), job.id
    end
    local ok, err = start_delivery_loop(job)
    if not ok then
        fail_delivery(job, err)
        return false, err
    end
    print("[RSDWTools] buildings.delivery: queued " .. delivery_status_detail(job))
    return true, string.format(
        "queued id=%d total=%d pieces=%d items=%d actors=%d skipped=%d interval_ms=%d settle_ticks=%d indices_remapped=%d legacy_index_fallback=%d",
        job.id, job.total, job.piece_total, job.item_total, job.actor_total,
        job.skipped + job.item_counts.skipped + job.actor_counts.skipped,
        job.interval_ms, job.settle_remaining,
        job.indices_remapped, job.legacy_index_fallback)
end

function M.delivery_status()
    local job = M._delivery_active
    if job and job.state == "waiting_for_anchor" and job.observer_state then
        local state, err = job.observer_state()
        if state == "error" or state == "expired" or state == "inactive" then
            fail_delivery(job, err or ("placement observer " .. state))
        end
    end
    return true, delivery_status_detail(M._delivery_active or M._delivery_last)
end

function M.delivery_cancel(id)
    id = tonumber(id)
    local job = M._delivery_active
    if not job then
        if M._delivery_last and M._delivery_last.id == id then return true, delivery_status_detail(M._delivery_last) end
        return false, "no matching delivery"
    end
    if job.id ~= id then return false, "delivery ID mismatch; nothing cancelled" end
    job.state, job.bmc, job.step_pending = "cancelled", nil, false
    M._delivery_active, M._delivery_last = nil, job
    return true, delivery_status_detail(job) .. "; already placed content is not removed"
end

function M._fail_preview_delivery(id, err)
    local job = M._delivery_active
    if job and job.id == id and job.state == "waiting_for_anchor" then fail_delivery(job, err) end
end

M._queue_piece_delivery = queue_piece_delivery
M._DELIVERY_PREVIEW_SETTLE_TICKS = DELIVERY_PREVIEW_SETTLE_TICKS
M._resolve_piece_indices = resolve_piece_indices
M._resolve_piece_data = resolve_piece_data_object
M._parse_delivery_interval_ms = parse_delivery_interval_ms

-- ---------------------------------------------------------------------------
-- world.buildings.import <name> [ghost] [interval_ms=N]
-- Reads ipc/buildings_<name>.json and queues each piece, included item, and
-- actor/NPC for paced replay. Use world.buildings.delivery.status to observe
-- the queue until active=0.
--
-- Optional second token "ghost" passes bSpawnGhost=true for each queued
-- request. Used by the WPF "Ghost Building Mode" checkbox so deliveries
-- land as persistent ghost shells the user can later commit or wipe.
-- ---------------------------------------------------------------------------
function M.import(args_str, validate_only)
    args_str = args_str or ""
    local name_tok = args_str:match("^%s*(%S+)") or ""
    local rest = args_str:sub(#name_tok + 1):lower()
    local ghost_mode = rest:find("ghost", 1, true) ~= nil
    local interval_ms, interval_err = parse_delivery_interval_ms(rest)
    if interval_err then return false, interval_err end
    local name = sanitize_name(name_tok)
    local path = export_path_for(name)
    if not path then
        return false, "could not resolve mod ipc directory"
    end

    local body = mod_paths.read_file(path)
    if not body then
        return false, "could not read " .. path
    end
    local pieces, perr = parse_pieces(body)
    if not pieces then
        if tostring(perr or ""):find("no pieces array", 1, true) then
            pieces = {}
        else
            return false, "JSON parse: " .. tostring(perr)
        end
    end
    local items, ierr = parse_items(body)
    if not items then
        return false, "JSON parse items: " .. tostring(ierr)
    end
    local actors, aerr = parse_actors(body)
    if not actors then
        return false, "JSON parse actors: " .. tostring(aerr)
    end
    if #pieces == 0 and #items == 0 and #actors == 0 then
        return false, "no pieces/items/actors in JSON"
    end

    local bmc = nil
    if #pieces > 0 then
        local _pc, resolved_bmc, err = get_local_pc_and_bmc()
        if not resolved_bmc then
            return false, "build mode unavailable: " .. tostring(err)
        end
        bmc = resolved_bmc
        if type(bmc.Server_SpawnBuilding) ~= "function" and not bmc.Server_SpawnBuilding then
            -- UE4SS exposes UFunctions as callable members -- the truthy
            -- check via direct index is the reliable test.
            return false, "BuildModeComponent has no Server_SpawnBuilding"
        end
    end

    -- Ghost-mode delivery: pass bSpawnGhost=true to Server_SpawnBuilding
    -- so the engine spawns each piece as a proper persistent ghost
    -- (server-side state, replicated, survives save+reload). The
    -- previous approach of post-spawn pinning bIsGhosted=true on the
    -- client only had no effect on the persisted state.
    local spawn_ghost = ghost_mode and true or false
    if ghost_mode and #pieces > 0 then
        print("[RSDWTools] buildings.import: ghost-mode armed (Server_SpawnBuilding bSpawnGhost=true)")
    end

    local entries = {}
    local skipped = 0
    for i = 1, #pieces do
        local p = pieces[i]
        if type(p.piece_data_index) ~= "number" or type(p.x) ~= "number"
            or type(p.y) ~= "number" or type(p.z) ~= "number" then
            print(string.format("  [%d] skipped (missing required fields)", i))
            skipped = skipped + 1
        else
            entries[#entries + 1] = {
                piece_data_index = p.piece_data_index,
                piece_data_name = p.piece_data_name,
                x = p.x, y = p.y, z = p.z,
                pitch = p.pitch, yaw = p.yaw, roll = p.roll,
                scale_x = p.scale_x, scale_y = p.scale_y, scale_z = p.scale_z,
            }
        end
    end

    local ok, detail = queue_piece_delivery({
        source = "import:" .. name,
        validate_only = validate_only == true,
        entries = entries,
        skipped = skipped,
        bmc = bmc,
        spawn_ghost = spawn_ghost,
        interval_ms = interval_ms,
        item_entries = items,
        actor_entries = actors,
        initial_settle_ticks = DELIVERY_DIRECT_SETTLE_TICKS,
    })
    if not ok then return false, detail end
    return true, string.format("%s items=%d actors=%d%s",
        detail, #items, #actors,
        (ghost_mode and #entries > 0) and " persistent_ghosts=1" or "")
end

-- ---------------------------------------------------------------------------
-- world.buildings.list
-- Lists every *.json under ipc\building\ for discoverability. Best-effort
-- using io.popen("dir") since Lua stdlib has no dir-iter ; if popen is
-- restricted in this UE4SS build we just say so.
-- ---------------------------------------------------------------------------
function M.list()
    local dir = mod_paths.buildings_dir()
    if not dir then return false, "ipc dir unresolved" end
    local found = {}
    local ok, pipe = pcall(io.popen, ('dir /b "%s\\*.json" 2>NUL'):format(dir))
    if ok and pipe then
        for line in pipe:lines() do
            line = (line or ""):gsub("[\r\n]+$", "")
            if line ~= "" then
                local short = line:match("^(.+)%.[Jj][Ss][Oo][Nn]$") or line
                found[#found + 1] = short
            end
        end
        pipe:close()
    end
    if #found == 0 then
        print("[RSDWTools] buildings.list: no exports found in " .. dir)
        return true, "0 exports in " .. dir
    end
    print(string.format("[RSDWTools] buildings.list: %d export(s) in %s", #found, dir))
    for i = 1, #found do print("  - " .. found[i]) end
    return true, string.format("%d export(s)", #found)
end

-- ---------------------------------------------------------------------------
-- world.buildings.catalog [name]
--
-- Enumerate every loaded UBuildingPieceData asset and dump
--   { piece_data_index, piece_data_name, short_name }
-- for each. Writes ipc/building/_catalog[_<name>].json (leading
-- underscore keeps it from colliding with normal capture exports and
-- sorts it to the top of the WPF list).
--
-- BuildingPieceDataIndex is a property on UBuildingPieceData itself
-- (header offset 0x0180) so we read it directly off each asset rather
-- than walking UBuildingPieceSubsystem.BuildingPieceDataIndexToBuildingPieceData
-- (TMap iteration from Lua is fiddly and FindAllOf reaches the same
-- set). CDOs are filtered out via the existing find_all_live helper.
--
-- Returns ack body : "count=N skipped=K path=..."
-- ---------------------------------------------------------------------------
function M.catalog(args_str)
    local raw = (args_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local suffix = raw == "" and "" or ("_" .. sanitize_name(raw))
    local dir = mod_paths.buildings_dir()
    if not dir then
        return false, "could not resolve mod ipc directory (game not loaded?)"
    end
    local out_path = dir .. "\\_catalog" .. suffix .. ".json"

    local assets = find_all_live("BuildingPieceData")
    if #assets == 0 then
        return false, "FindAllOf BuildingPieceData returned 0 ; assets not loaded?"
    end

    local kept = {}
    local skipped = 0
    for i = 1, #assets do
        local a = assets[i]
        local rec = {}
        pcall(function() rec.short_name = a:GetName() end)
        pcall(function() rec.piece_data_name = a:GetFullName() end)
        pcall(function() rec.piece_data_index = a.BuildingPieceDataIndex end)
        if type(rec.piece_data_index) == "number"
            and rec.piece_data_name and rec.piece_data_name ~= "" then
            kept[#kept + 1] = rec
        else
            skipped = skipped + 1
        end
    end

    -- Stable sort by index so the file diffs cleanly across runs and
    -- a human can scan it for index gaps.
    table.sort(kept, function(a, b) return (a.piece_data_index or 0) < (b.piece_data_index or 0) end)

    local body_parts = {}
    body_parts[#body_parts + 1] = '{"schema":"rsdwtools.buildings.catalog.v1"'
    body_parts[#body_parts + 1] = ',"generated_unix":' .. tostring(os.time())
    body_parts[#body_parts + 1] = ',"count":' .. tostring(#kept)
    body_parts[#body_parts + 1] = ',"skipped":' .. tostring(skipped)
    body_parts[#body_parts + 1] = ',"pieces":['
    for i = 1, #kept do
        if i > 1 then body_parts[#body_parts + 1] = "," end
        local r = kept[i]
        body_parts[#body_parts + 1] = "{"
            .. '"piece_data_index":' .. json_num(r.piece_data_index)
            .. ',"short_name":'      .. json_str_or_null(r.short_name)
            .. ',"piece_data_name":' .. json_str_or_null(r.piece_data_name)
            .. "}"
    end
    body_parts[#body_parts + 1] = "]}"
    local body = table.concat(body_parts)

    local ok, detail = mod_paths.write_atomic(out_path, body)
    if not ok then
        return false, "write failed: " .. tostring(detail)
    end
    print(string.format("[RSDWTools] buildings.catalog: wrote %d entries (skipped %d) -> %s",
        #kept, skipped, out_path))
    return true, string.format("count=%d skipped=%d path=%s", #kept, skipped, out_path)
end

-- ---------------------------------------------------------------------------
-- world.buildings.catalog.disk [name]
--
-- AssetRegistry sweep of every UBuildingPieceData asset on disk
-- (loaded or not). Complements world.buildings.catalog, which only
-- sees pieces that have been paged into memory this session.
--
-- Why both:
--   FindAllOf("BuildingPieceData") only enumerates assets currently
--   live in the global UObject array. The dump-time count of
--   reflected BuildingPieceData lines is ~728 yet the loaded catalog
--   tops out at 648, so ~80 pieces are sitting in pak files we have
--   never touched. The AssetRegistry knows about every cooked asset
--   regardless of load state, so we can compare the two files to see
--   what is missing and (later) force-load the gaps to recover their
--   piece_data_index.
--
-- Strategy:
--   1. Resolve UAssetRegistryHelpers CDO -> IAssetRegistry (same
--      pattern BPModLoaderMod uses).
--   2. Walk the three known BuildingPieces roots with
--      GetAssetsByPath(PackagePath, OutAssetData, true, true).
--   3. For each FAssetData, capture { package_name, package_path,
--      asset_name, asset_class, object_path, loaded } and filter to
--      AssetClass == "BuildingPieceData" (in case other asset types
--      live alongside under the same path).
--
-- The on-disk roots match what the loaded catalog reports today:
--   /Game/Gameplay/BaseBuilding/Data/BuildingPieces
--   /Game/Gameplay/BaseBuilding_New/BuildingPieces
--   /Fishing/Gameplay/BaseBuilding/BuildingPieces
-- ---------------------------------------------------------------------------
local DISK_CATALOG_ROOTS = {
    "/Game/Gameplay/BaseBuilding/Data/BuildingPieces",
    "/Game/Gameplay/BaseBuilding_New/BuildingPieces",
    "/Fishing/Gameplay/BaseBuilding/BuildingPieces",
}

local function resolve_asset_registry()
    if not StaticFindObject then
        return nil, "StaticFindObject not available"
    end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not is_valid(helpers) then
        return nil, "UAssetRegistryHelpers CDO not found"
    end
    local ok, registry = pcall(function() return helpers:GetAssetRegistry() end)
    if not ok or not registry then
        return nil, "GetAssetRegistry call failed: " .. tostring(registry)
    end
    if not is_valid(registry) then
        return nil, "GetAssetRegistry returned invalid registry"
    end
    return registry, helpers
end

-- Read a single FAssetData row into a plain Lua table. Each FName field
-- is coerced via :ToString() ; the call is wrapped in pcall because a
-- malformed entry should skip rather than abort the whole sweep.
--
-- Note: FAssetData.AssetClass (FName) is deprecated in UE5 and returns
-- None for cooked assets ; the real class lives on AssetClassPath
-- (FTopLevelAssetPath { PackageName, AssetName }). We read both, then
-- prefer AssetClassPath.AssetName for filtering. The legacy field is
-- kept in the JSON for diagnostics.
--
-- UE4SS Lua FName access: depending on UE4SS build, FName fields can be
-- read as either userdata-with-:ToString() OR as a plain Lua string. We
-- handle both. Errors from each access are captured into rec.errors so
-- a failed sweep self-documents instead of returning all-nil rows.
local function fname_to_string(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    if type(v) == "userdata" then
        -- UE4SS wraps reflected struct fields and TArray elements in
        -- LocalUnrealParam / RemoteUnrealParam. Both expose :get() to
        -- materialize the underlying value. We may need to unwrap one
        -- or two layers (param -> FName) before :ToString() works.
        for _ = 1, 2 do
            if type(v) == "userdata" then
                local has_get = false
                pcall(function() has_get = (type(v.get) == "function") end)
                if has_get then
                    local ok, inner = pcall(function() return v:get() end)
                    if ok and inner ~= nil then
                        v = inner
                    else
                        break
                    end
                else
                    break
                end
            else
                break
            end
        end
        if type(v) == "string" then return v end
        if type(v) == "userdata" then
            for _, m in ipairs({ "ToString", "GetName", "GetPlainNameString" }) do
                local ok, s = pcall(function() return v[m](v) end)
                if ok and type(s) == "string" and s ~= "" then return s end
            end
            local ok, s = pcall(tostring, v)
            if ok and type(s) == "string" and s ~= "" and s ~= "nil"
                and not s:find("LocalUnrealParam") and not s:find("RemoteUnrealParam") then
                return s
            end
        end
    end
    return nil
end

-- Unwrap a TArray element / struct-field LocalUnrealParam down to the
-- underlying userdata (e.g. FAssetData struct). One :get() call is
-- usually enough but we tolerate two.
local function unwrap_param(v)
    if type(v) ~= "userdata" then return v end
    for _ = 1, 2 do
        local has_get = false
        pcall(function() has_get = (type(v.get) == "function") end)
        if not has_get then return v end
        local ok, inner = pcall(function() return v:get() end)
        if not ok or inner == nil then return v end
        v = inner
        if type(v) ~= "userdata" then return v end
    end
    return v
end

local function asset_data_to_record(entry, helpers)
    local rec = { errors = {} }
    local function try(field, fn)
        local ok, err = pcall(fn)
        if not ok then rec.errors[#rec.errors + 1] = field .. ":" .. tostring(err) end
    end
    try("PackageName", function() rec.package_name = fname_to_string(entry.PackageName) end)
    try("PackagePath", function() rec.package_path = fname_to_string(entry.PackagePath) end)
    try("AssetName",   function() rec.asset_name   = fname_to_string(entry.AssetName) end)
    try("AssetClass",  function() rec.asset_class_legacy = fname_to_string(entry.AssetClass) end)
    try("AssetClassPath.PackageName", function()
        rec.asset_class_package = fname_to_string(entry.AssetClassPath.PackageName)
    end)
    try("AssetClassPath.AssetName", function()
        rec.asset_class = fname_to_string(entry.AssetClassPath.AssetName)
    end)
    -- Fallback: if AssetClassPath access failed but AssetClass legacy
    -- still has a value (some engine builds keep it populated), use it.
    if not rec.asset_class and rec.asset_class_legacy
        and rec.asset_class_legacy ~= "" and rec.asset_class_legacy ~= "None" then
        rec.asset_class = rec.asset_class_legacy
    end
    if rec.package_name and rec.asset_name then
        rec.object_path = rec.package_name .. "." .. rec.asset_name
    end
    if helpers and is_valid(helpers) then
        try("IsAssetLoaded", function() rec.loaded = helpers:IsAssetLoaded(entry) end)
    end
    return rec
end

function M.catalog_disk(args_str)
    local raw = (args_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local suffix = raw == "" and "" or ("_" .. sanitize_name(raw))
    local dir = mod_paths.buildings_dir()
    if not dir then
        return false, "could not resolve mod ipc directory (game not loaded?)"
    end
    local out_path = dir .. "\\_catalog_disk" .. suffix .. ".json"

    local registry, helpers_or_err = resolve_asset_registry()
    if not registry then
        return false, helpers_or_err
    end
    local helpers = helpers_or_err

    -- Per-root scan. We pass an empty Lua table as the OutAssetData
    -- TArray ; UE4SS marshals reflected USTRUCT array out-params back
    -- into it. Recursive=true, IncludeOnlyOnDiskAssets=true so we
    -- catch unloaded paks (the whole point of this verb).
    local kept = {}
    local total_seen = 0
    local skipped_class = 0
    local per_root_counts = {}
    local class_hist = {}
    local error_hist = {}
    local first_entry_dump = nil
    for _, root in ipairs(DISK_CATALOG_ROOTS) do
        local out = {}
        local ok, _ = pcall(function()
            registry:GetAssetsByPath(FName(root), out, true, true)
        end)
        local n = 0
        pcall(function() n = #out end)
        if not ok then
            print("[RSDWTools] buildings.catalog.disk: GetAssetsByPath failed for " .. root)
        end
        per_root_counts[root] = n
        for i = 1, n do
            local entry = unwrap_param(out[i])
            if entry then
                total_seen = total_seen + 1
                local rec = asset_data_to_record(entry, helpers)
                -- One-shot diagnostic on the very first entry: capture
                -- type info so we can see exactly how the struct is
                -- shaped at runtime.
                if first_entry_dump == nil then
                    first_entry_dump = {
                        entry_type = type(entry),
                        rec = rec,
                    }
                end
                for _, err in ipairs(rec.errors) do
                    local key = err:match("^([^:]+)") or err
                    error_hist[key] = (error_hist[key] or 0) + 1
                end
                local cls_key = rec.asset_class or "<nil>"
                class_hist[cls_key] = (class_hist[cls_key] or 0) + 1
                if rec.asset_class == "BuildingPieceData" then
                    kept[#kept + 1] = rec
                else
                    skipped_class = skipped_class + 1
                end
            end
        end
    end

    -- Echo the diagnostic to stdout for the log scrape.
    if first_entry_dump then
        print("[RSDWTools] buildings.catalog.disk diag: first rec object_path=" .. tostring(first_entry_dump.rec.object_path)
            .. " package_name=" .. tostring(first_entry_dump.rec.package_name)
            .. " asset_name=" .. tostring(first_entry_dump.rec.asset_name)
            .. " asset_class=" .. tostring(first_entry_dump.rec.asset_class)
            .. " asset_class_legacy=" .. tostring(first_entry_dump.rec.asset_class_legacy))
        for _, err in ipairs(first_entry_dump.rec.errors or {}) do
            print("[RSDWTools] buildings.catalog.disk diag err: " .. err)
        end
    end

    -- Stable sort by object_path so diffs are clean across runs.
    table.sort(kept, function(a, b)
        return (a.object_path or "") < (b.object_path or "")
    end)

    local body_parts = {}
    body_parts[#body_parts + 1] = '{"schema":"rsdwtools.buildings.catalog_disk.v1"'
    body_parts[#body_parts + 1] = ',"generated_unix":' .. tostring(os.time())
    body_parts[#body_parts + 1] = ',"total_scanned":' .. tostring(total_seen)
    body_parts[#body_parts + 1] = ',"skipped_wrong_class":' .. tostring(skipped_class)
    body_parts[#body_parts + 1] = ',"count":' .. tostring(#kept)
    body_parts[#body_parts + 1] = ',"roots":['
    for i, root in ipairs(DISK_CATALOG_ROOTS) do
        if i > 1 then body_parts[#body_parts + 1] = "," end
        body_parts[#body_parts + 1] = '{"path":' .. json_str_or_null(root)
            .. ',"hits":' .. tostring(per_root_counts[root] or 0) .. '}'
    end
    body_parts[#body_parts + 1] = '],"class_histogram":{'
    do
        local first = true
        for cls, n in pairs(class_hist) do
            if not first then body_parts[#body_parts + 1] = "," end
            first = false
            body_parts[#body_parts + 1] = json_str_or_null(cls) .. ":" .. tostring(n)
        end
    end
    body_parts[#body_parts + 1] = '},"error_histogram":{'
    do
        local first = true
        for field, n in pairs(error_hist) do
            if not first then body_parts[#body_parts + 1] = "," end
            first = false
            body_parts[#body_parts + 1] = json_str_or_null(field) .. ":" .. tostring(n)
        end
    end
    body_parts[#body_parts + 1] = '},"pieces":['
    for i = 1, #kept do
        if i > 1 then body_parts[#body_parts + 1] = "," end
        local r = kept[i]
        body_parts[#body_parts + 1] = "{"
            .. '"object_path":'  .. json_str_or_null(r.object_path)
            .. ',"package_name":' .. json_str_or_null(r.package_name)
            .. ',"package_path":' .. json_str_or_null(r.package_path)
            .. ',"asset_name":'   .. json_str_or_null(r.asset_name)
            .. ',"asset_class":'  .. json_str_or_null(r.asset_class)
            .. ',"asset_class_package":' .. json_str_or_null(r.asset_class_package)
            .. ',"loaded":'       .. (r.loaded == true and "true" or "false")
            .. "}"
    end
    body_parts[#body_parts + 1] = "]}"
    local body = table.concat(body_parts)

    local ok, detail = mod_paths.write_atomic(out_path, body)
    if not ok then
        return false, "write failed: " .. tostring(detail)
    end
    print(string.format("[RSDWTools] buildings.catalog.disk: wrote %d entries (scanned %d, %d non-BuildingPieceData skipped) -> %s",
        #kept, total_seen, skipped_class, out_path))
    return true, string.format("count=%d scanned=%d path=%s", #kept, total_seen, out_path)
end

-- ---------------------------------------------------------------------------
-- world.buildings.stability <on|off>
--
-- Toggle building stability simulation at runtime. We attack it from
-- three angles because we don't yet know which one actually shipped
-- working in this build:
--
--   1. UDominionCheatManager::domBuildingTickStability(bool)
--      and domUpdateStabilityValuesInCellManager(bool). The header
--      dump shows these as exec UFUNCTIONs targeted exactly at the
--      stability sim. They may no-op (the prior round-12 spell dom*
--      wrappers all silently ignored their args), but they may also
--      Just Work for buildings since that's a different subsystem.
--
--   2. AGlobalBuildingManager.StabilityComponent ->
--      SetComponentTickEnabled / SetActive. If the stability solver
--      lives on a UActorComponent that ticks, we can stop it from
--      ticking entirely. This is the most reliable hammer because it
--      bypasses any cheat-gating on the dom* path.
--
--   3. For "off", sweep every live ABaseBuildingActor and pin
--      StabilityValue=1.0 so anything already mid-decay snaps back
--      to full. Cheap, idempotent, immediately visible.
--
-- Required because Server_SpawnBuilding-replayed structures
-- (build.preview.commit, world.buildings.import) sometimes spawn
-- with low stability values and start collapsing seconds later.
-- ---------------------------------------------------------------------------
function M.set_stability(args_str)
    local raw = (args_str or ""):lower():gsub("%s+", "")
    if raw == "" then
        return false, "usage: world.buildings.stability on|off"
    end
    local enable
    if raw == "on" or raw == "true" or raw == "1" then enable = true
    elseif raw == "off" or raw == "false" or raw == "0" then enable = false
    else return false, "expected on|off, got " .. raw end

    local pc, _bmc, err = get_local_pc_and_bmc()
    if not pc then return false, "no player controller: " .. tostring(err) end

    -- Best-effort: ensure cheats are enabled so the dom* exec funcs
    -- aren't gated. EnableCheats() is the standard UCheatManager path
    -- and is safe to call multiple times. May no-op in shipping.
    pcall(function() pc:EnableCheats() end)

    local cm
    pcall(function() cm = pc:GetDominionCheatManager() end)
    if not is_valid(cm) then pcall(function() cm = pc.CheatManager end) end

    local cheats_called = {}
    if is_valid(cm) then
        if cm.domBuildingTickStability then
            local ok = pcall(function() cm:domBuildingTickStability(enable) end)
            if ok then cheats_called[#cheats_called + 1] = "tick=" .. tostring(enable) end
        end
        if cm.domUpdateStabilityValuesInCellManager then
            local ok = pcall(function() cm:domUpdateStabilityValuesInCellManager(enable) end)
            if ok then cheats_called[#cheats_called + 1] = "cell=" .. tostring(enable) end
        end
    end

    -- Direct hammer: stop the BuildingStabilityComponent from ticking.
    -- AGlobalBuildingManager owns it as a subobject ; in shipped builds
    -- there is exactly one instance per world. Walk all of them
    -- defensively just in case multi-server / dedicated configs end up
    -- with more than one.
    local comps_touched = 0
    for _, mgr in pairs(find_all_live("GlobalBuildingManager")) do
        local sc
        pcall(function() sc = mgr.StabilityComponent end)
        if is_valid(sc) then
            pcall(function() sc:SetComponentTickEnabled(enable) end)
            pcall(function() sc:SetActive(enable) end)
            comps_touched = comps_touched + 1
        end
    end

    -- For "off", pin every live piece to max stability so any actor
    -- that already started decaying snaps back. Setting StabilityValue
    -- directly is sufficient -- the OnRep / replication path will
    -- propagate to clients on the next net update.
    local pieces_pinned = 0
    if not enable then
        for _, a in pairs(find_all_live("BaseBuildingActor")) do
            pcall(function() a.StabilityValue = 1.0 end)
            pieces_pinned = pieces_pinned + 1
        end
    end

    local cheats_str = (#cheats_called > 0) and table.concat(cheats_called, ",") or "none"
    print(string.format(
        "[RSDWTools] world.buildings.stability: mode=%s cheats=[%s] mgr_components=%d pieces_pinned=%d",
        enable and "on" or "off", cheats_str, comps_touched, pieces_pinned))
    return true, string.format("mode=%s cheats=[%s] mgr_components=%d pieces_pinned=%d",
        enable and "on" or "off", cheats_str, comps_touched, pieces_pinned)
end

-- ---------------------------------------------------------------------------
-- world.buildings.protect <on|off>
--
-- Background watcher that defends every live ABaseBuildingActor against
-- the engine's post-spawn validity / completion / stability checks. This
-- is the answer to "force_place spawns the piece, then 200ms later the
-- engine destroys it because it's overlapping/floating/etc."
--
-- HOW THE DESTROY HAPPENS (from the dump):
--   * After Server_SpawnBuilding lands, the engine eventually fires
--     ABaseBuildingActor::OnValiditySpawnStateChanged(state) where state
--     is one of EValiditySpawnState::{Overlapping, Floating, Unstable,
--     ...}. This is a UFUNCTION BlueprintImplementableEvent ; the BP
--     graph implementation is what calls K2_DestroyActor.
--   * For finished pieces, FBuildingCompletionStatus.CurrentAmount may
--     drift back toward zero if no inventory was provided. Some BPs
--     destroy on incomplete state.
--   * StabilityValue<threshold also collapses pieces over time -- handled
--     separately by world.buildings.stability off.
--
-- WHAT THIS DOES (per LoopAsync tick, ~16ms):
--   * Look up the BMC's current PreviewPiece and SKIP it (otherwise
--     we'd hide the reticle ghost the user is aiming with).
--   * For every other live BaseBuildingActor whose bIsPreview is
--     already false:
--       - bIsGhosted = false      (treat as fully-built)
--       - StabilityValue = 1.0    (pin max stability)
--       - bIgnoreReplicationManager = false
--   * We deliberately do NOT touch bIsPreview ; if an actor is still
--     marked preview it's either the reticle ghost or a transient
--     mid-spawn we shouldn't race with.
--
-- This does NOT install a UFunction hook on K2_DestroyActor or on the
-- BIE itself ; UE4SS hooks on BIEs are unreliable in this build (we
-- crashed on LocalUnrealParam unwrapping last time). The pin-and-pray
-- approach is empirically what works.
--
-- LIMITATIONS:
--   * Pieces that are destroyed in a single frame BEFORE our next tick
--     (16ms window) won't be saved. If you see destruction after
--     enabling protect, tighten the loop interval or pre-arm before
--     spawning.
--   * Walking every BaseBuildingActor every frame is O(N). At 1000+
--     pieces this gets expensive ; consider toggling off after the
--     spawn flurry settles.
-- ---------------------------------------------------------------------------
M._protect_loop_armed = false

function M.set_protect(args_str)
    local raw = (args_str or ""):lower():gsub("%s+", "")
    if raw == "" then
        return false, "usage: world.buildings.protect on|off"
    end
    local enable
    if raw == "on" or raw == "true" or raw == "1" then enable = true
    elseif raw == "off" or raw == "false" or raw == "0" then enable = false
    else return false, "expected on|off, got " .. raw end

    if not enable then
        if not M._protect_loop_armed then
            return true, "already off"
        end
        M._protect_loop_armed = false
        print("[RSDWTools] world.buildings.protect: off (loop will exit on next tick)")
        return true, "off"
    end

    if M._protect_loop_armed then
        return true, "already on"
    end
    if not LoopAsync then
        return false, "LoopAsync unavailable"
    end

    M._protect_loop_armed = true
    LoopAsync(16, function()
        if not M._protect_loop_armed then return true end

        -- Identify the BMC's current PreviewPiece so we DON'T clobber
        -- it. Pinning bIsPreview=false / bIsGhosted=false on the live
        -- preview actor hides the reticle ghost (the BMC keys its
        -- ghost-material path off bIsPreview/bIsGhosted) and freezes
        -- placement. Skipping it costs us nothing — the preview
        -- actor isn't a real spawned piece yet.
        local preview_actor = nil
        local pc = find_first_live("DominionPlayerController")
        if is_valid(pc) and pc.BuildModeComponent then
            local bmc = pc.BuildModeComponent
            if is_valid(bmc) and bmc.PreviewPiece then
                local pp = bmc.PreviewPiece
                -- TWeakObjectPtr -- try Get(), fall back to direct deref
                local ok, resolved = pcall(function()
                    if type(pp) == "userdata" and pp.Get then return pp:Get() end
                    return pp
                end)
                if ok and is_valid(resolved) then preview_actor = resolved end
            end
        end

        local actors = find_all_live("BaseBuildingActor")
        for i = 1, #actors do
            local a = actors[i]
            if is_valid(a) and a ~= preview_actor then
                -- Only protect actors that are NOT flagged as a preview
                -- piece. Anything still marked preview is either the
                -- BMC's reticle ghost (handled above) or a half-spawned
                -- transient we shouldn't fight with.
                local is_preview = false
                pcall(function() is_preview = a.bIsPreview and true or false end)
                if not is_preview then
                    pcall(function() a.bIsGhosted = false end)
                    pcall(function() a.StabilityValue = 1.0 end)
                    pcall(function() a.bIgnoreReplicationManager = false end)
                end
            end
        end
        return false
    end)
    print("[RSDWTools] world.buildings.protect: on (16ms tick, all live BaseBuildingActor)")
    return true, "on"
end

-- ---------------------------------------------------------------------------
-- world.buildings.delete_ghosts
--
-- Persistently destroy every ghosted ABaseBuildingActor in the world by
-- routing through the canonical server RPC :
--   UBuildInteractionComponent::Server_InteractActor(
--       EBuildInteractionType::Destroy,
--       ABaseBuildingActor*,
--       const ADominionPlayerController*,
--       const TArray<UInventoryComponent*>&)
--
-- The previous implementation used K2_DestroyActor which only removes
-- the client-side proxy ; the server's GlobalBuildingManager.BuildingPieces
-- TMap still holds the entry so the piece reappears on save+reload.
-- Going through Server_InteractActor lets the engine remove from the
-- piece registry, despawn cleanly, and persist the deletion.
--
-- Returns "destroyed=N skipped=M".
-- ---------------------------------------------------------------------------
function M.delete_ghosts()
    local pc, _bmc, perr = get_local_pc_and_bmc()
    if not is_valid(pc) then return false, "no player controller: " .. tostring(perr) end
    local bic
    pcall(function() bic = pc:GetBuildInteractionComponent() end)
    if not is_valid(bic) then return false, "BuildInteractionComponent unavailable" end
    local records, err = build_access.capture_records(snapshot_piece)
    if not records then return false, err end
    local dispatched, failed = 0, 0
    for _, rec in ipairs(records) do
        if rec.is_ghosted then
            local ok, detail = pcall(function()
                bic:Server_Interact(rec.piece_id, 3, {}, { X = rec.x, Y = rec.y, Z = rec.z })
            end)
            if ok then dispatched = dispatched + 1 else
                failed = failed + 1
                print("[RSDWTools] ghost delete failed id=" .. tostring(rec.piece_id) .. ": " .. tostring(detail))
            end
        end
    end
    return failed == 0, string.format("destroyed=%d skipped=%d dispatched=%d (server result requires recapture)", dispatched, failed, dispatched)
end

-- ---------------------------------------------------------------------------
-- world.buildings.commit_ghosts
--
-- Persistently commit every ghosted ABaseBuildingActor to the
-- "fully built" state by :
--   1. Pre-filling each piece's CompletionStatus.CurrentAmount[] to
--      match its AmountNeeded[] (so the engine sees zero items
--      outstanding).
--   2. Routing UBuildInteractionComponent::Server_InteractActor with
--      EBuildInteractionType::Donation. With nothing left to deposit
--      the engine takes the "completion" branch : flips bIsGhosted=false
--      server-side, replicates the OnRep, and updates the registry.
--
-- The previous implementation only flipped bIsGhosted client-side, so
-- the server's persisted state remained ghosted and the piece reverted
-- on save+reload.
--
-- Returns "committed=N scanned=M skipped=K".
-- ---------------------------------------------------------------------------
function M.commit_ghosts()
    return false, "unsupported in 1.0: direct ghost completion requires a verified native building resolver; use the WPF capture/delete/redeliver workflow on a backed-up world"
end

-- ---------------------------------------------------------------------------
-- world.buildings.requirements <save|clear|restore|status>
--
-- Manage the per-asset Requirements TArray on every loaded
-- UBuildingPieceData. Replaces the previous "world.foreach
-- BuildingPieceData clear Requirements" sledgehammer because that
-- approach has a nasty side effect : with empty Requirements, ANY
-- placement (including manual in-game ghost building) is auto-completed
-- by the engine instantly, so the player can never make a real ghost.
--
-- Subcommands:
--   save     : snapshot current Requirements into M._requirements_snapshot
--              (keyed by asset GetFullName()). Idempotent ; will not
--              overwrite an existing snapshot unless one isn't there yet.
--   clear    : auto-saves first if no snapshot exists, then empties
--              every asset's Requirements TArray. Use BEFORE a Deliver
--              if you want non-ghost-mode pieces to spawn for free.
--   restore  : copy the snapshot back into every asset, restoring
--              normal in-game build costs. Drops the snapshot.
--   status   : report whether a snapshot is held, how many entries
--              are cleared right now, and how many are intact.
--
-- WARNING: clear affects ALL placements globally including yours and
-- other players in co-op. Always restore when you're done delivering.
-- ---------------------------------------------------------------------------
M._requirements_snapshot = nil

local function deepcopy_req_array(arr)
    -- TArray<FResourceRequirement> -> Lua list of { Amount, ItemData }.
    -- We hold raw UItemData* pointers ; assets stay alive for the whole
    -- session so this is safe.
    local out = {}
    if not arr then return out end
    local n = 0
    pcall(function() n = #arr end)
    for i = 1, n do
        local entry = arr[i]
        if entry then
            out[#out + 1] = {
                Amount   = entry.Amount or 0,
                ItemData = entry.ItemData,
            }
        end
    end
    return out
end

function M.set_requirements(args_str)
    local raw = (args_str or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then
        return false, "usage: world.buildings.requirements <save|clear|restore|status>"
    end
    if raw == "restore" and M._delivery_active then
        return false, "delivery still active ; " .. delivery_status_detail(M._delivery_active)
    end

    local assets = find_all_live("BuildingPieceData")
    if #assets == 0 then
        return false, "FindAllOf BuildingPieceData returned 0 ; assets not loaded?"
    end

    if raw == "status" then
        local snap = M._requirements_snapshot
        local snap_count = 0
        if snap then for _ in pairs(snap) do snap_count = snap_count + 1 end end
        local empty_now, intact_now = 0, 0
        for i = 1, #assets do
            local a = assets[i]
            local n = 0
            pcall(function() n = #a.Requirements end)
            if n == 0 then empty_now = empty_now + 1 else intact_now = intact_now + 1 end
        end
        return true, string.format("snapshot=%d empty=%d intact=%d total=%d",
            snap_count, empty_now, intact_now, #assets)
    end

    if raw == "save" then
        if M._requirements_snapshot then
            return true, "snapshot already exists ; restore first or use clear (which auto-saves)"
        end
        local snap = {}
        local n = 0
        for i = 1, #assets do
            local a = assets[i]
            local key
            pcall(function() key = a:GetFullName() end)
            if key then
                snap[key] = deepcopy_req_array(a.Requirements)
                n = n + 1
            end
        end
        M._requirements_snapshot = snap
        print(string.format("[RSDWTools] requirements: snapshot saved (%d assets)", n))
        return true, string.format("saved=%d", n)
    end

    if raw == "clear" then
        if not M._requirements_snapshot then
            -- Auto-save first so restore works later.
            local snap = {}
            for i = 1, #assets do
                local a = assets[i]
                local key
                pcall(function() key = a:GetFullName() end)
                if key then
                    snap[key] = deepcopy_req_array(a.Requirements)
                end
            end
            M._requirements_snapshot = snap
            print("[RSDWTools] requirements: auto-saved snapshot before clear")
        end
        local cleared = 0
        for i = 1, #assets do
            local a = assets[i]
            local ok = pcall(function() a.Requirements = {} end)
            if ok then cleared = cleared + 1 end
        end
        print(string.format("[RSDWTools] requirements: cleared %d asset(s)", cleared))
        return true, string.format("cleared=%d", cleared)
    end

    if raw == "restore" then
        local snap = M._requirements_snapshot
        if not snap then
            return false, "no snapshot to restore (call save or clear first)"
        end
        local restored, missing = 0, 0
        for i = 1, #assets do
            local a = assets[i]
            local key
            pcall(function() key = a:GetFullName() end)
            local entries = key and snap[key] or nil
            if entries then
                local rebuilt = {}
                for j = 1, #entries do
                    rebuilt[j] = {
                        Amount   = entries[j].Amount,
                        ItemData = entries[j].ItemData,
                    }
                end
                local ok = pcall(function() a.Requirements = rebuilt end)
                if ok then restored = restored + 1 else missing = missing + 1 end
            else
                missing = missing + 1
            end
        end
        M._requirements_snapshot = nil
        print(string.format("[RSDWTools] requirements: restored %d asset(s) (missing=%d) ; snapshot dropped",
            restored, missing))
        return true, string.format("restored=%d missing=%d", restored, missing)
    end

    return false, "unknown subcommand '" .. raw .. "' ; expected save|clear|restore|status"
end

-- ---------------------------------------------------------------------------
-- world.buildings.rotation.step <deg> -- precision control over the
-- build-mode preview rotation snap. The shipping value (15 by default ;
-- 30 in some configs) is what makes the mouse wheel "tick" in coarse
-- jumps. Writing 1 to UBuildingSettings.ModifyRotationStepDeg gives full
-- per-degree control. The property is on the UDeveloperSettings CDO,
-- so we resolve the singleton via StaticFindObject and write the int32
-- field directly. No restart required ; the build-mode component reads
-- this every wheel input.
--
-- Bounds : the field is int32 and fully signed. We clamp to 1..180
-- because 0 freezes rotation and values >180 alias to a negative
-- direction. Negatives are technically valid (inverts wheel) but
-- aren't what the user asked for ; clamp keeps the UI predictable.
-- Pass no arg to read the current value.
-- ---------------------------------------------------------------------------
function M.set_rotation_step(args_str)
    local raw = (args_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local settings = StaticFindObject and StaticFindObject("/Script/Dominion.Default__BuildingSettings") or nil
    if not is_valid(settings) then
        return false, "could not resolve /Script/Dominion.Default__BuildingSettings (not loaded?)"
    end

    if raw == "" then
        local cur
        local ok = pcall(function() cur = settings.ModifyRotationStepDeg end)
        if not ok or cur == nil then
            return false, "read failed: ModifyRotationStepDeg unreadable"
        end
        return true, "current=" .. tostring(cur)
    end

    local n = tonumber(raw)
    if not n then return false, "usage: world.buildings.rotation.step <deg 1-180>  (current: read with no arg)" end
    n = math.floor(n + 0.5)
    if n < 1   then n = 1   end
    if n > 180 then n = 180 end

    local prev
    pcall(function() prev = settings.ModifyRotationStepDeg end)
    local ok, err = pcall(function() settings.ModifyRotationStepDeg = n end)
    if not ok then return false, "write failed: " .. tostring(err) end

    print(string.format("[RSDWTools] world.buildings.rotation.step: %s -> %d",
        tostring(prev), n))
    return true, string.format("ModifyRotationStepDeg=%d (was %s)", n, tostring(prev))
end

-- Public re-exports for sibling modules (feature_build_preview).
-- Kept underscore-prefixed to signal "internal helper, not a router verb".
M._parse_pieces = parse_pieces
M._parse_items = parse_items
M._parse_actors = parse_actors
M._capture_path_for = export_path_for
M._sanitize_name = sanitize_name
M._get_local_pc_and_bmc = get_local_pc_and_bmc
M._make_transform = make_transform
M._transform_records_relative = transform_records_relative
M._replay_items_absolute = replay_items_absolute
M._replay_items_relative = replay_items_relative
M._replay_actors_absolute = replay_actors_absolute
M._replay_actors_relative = replay_actors_relative

return M
