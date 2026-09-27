-- Feature: actor "grab" tool. Latches a named actor onto the player's
-- current camera viewpoint and updates its transform every tick so the
-- actor follows the camera until released.
--
-- Design choices vs. the OLD/RSDTools implementation:
--   * One LoopAsync loop, started only when something is grabbed and
--     self-terminating on release. Zero per-frame cost when idle.
--   * Camera viewpoint comes from APlayerController:GetPlayerViewPoint,
--     which already routes through the active view target. While the
--     player is in Oculus mode the view target is AOculusPawn ; while
--     they're in normal play it's the player character. Same code path,
--     no special-case for "is oculus on".
--   * No per-tick reflection method-fallbacks. We resolve the actor +
--     its transform setters once at grab-start (via feature_actor's
--     M.move_actor / M.set_actor_rotation), and on the loop body we
--     just call them. If they fail we abort loudly instead of silently
--     trying alternates ; the old triple-fallback chain hid real bugs.
--   * Pre-allocated dest/rot tables mutated in place to keep GC out of
--     the hot path.
--   * Modes (move | rot | z | scale) are explicit verbs from the
--     router, not inferred from key state. The WPF or hotkey layer
--     decides how to map keys to verbs ; this module just executes.
--
-- Public verbs (called via command_line_router.lua):
--   camera.grab.start <name>            latch named actor to camera
--   camera.grab.release                 drop in place
--   camera.grab.cancel                  drop and restore start transform
--   camera.grab.mode <move|rot|z|scale> set what scroll-delta affects
--   camera.grab.delta <signed_number>   one wheel-tick worth (signed)
--   camera.grab.safety <on|off|toggle|status> toggle unsafe target blocks
--   camera.grab.status                  print current state to ack
--
-- All verbs run on the game thread (the bridge dispatcher already
-- wraps router calls in ExecuteInGameThread). The LoopAsync tick body
-- also runs on the game thread under UE4SS, so direct UE calls from
-- inside it are safe.

local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local feature_inventory = require("feature_inventory")
local feature_umg   = require("feature_umg")
local feature_oculus_transform = require("feature_oculus_transform")
local feature_oculus_async = require("feature_oculus_async")
local feature_camera = require("feature_camera")

local grab_safety_enabled = true

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function grab_safety_label()
    return grab_safety_enabled and "on" or "off"
end

local function parse_positive(raw, label)
    local n = tonumber(raw)
    if not n or n <= 0 then return nil, label .. " must be > 0" end
    return n, nil
end

-- Trim the engine-assigned `_UAID_<hex>_<num>` runtime suffix off an
-- actor's instance name so the UI label reads as the editor name
-- (e.g. `BP_NPC_Doric_FTUE_C_UAID_AC1A...` -> `BP_NPC_Doric_FTUE_C`).
-- We strip the FIRST occurrence ; some actors get nested suffixes when
-- spawned via subobject construction.
local function _label_for(actor)
    local s = feature_actor.short_name_of(actor)
    if not s then return "<unnamed>" end
    local trimmed = s:match("^(.-)_UAID_") or s
    return trimmed
end

-- Brief on-screen toast. Wrapped in pcall so the UMG layer being
-- absent (e.g. before player_ready) never crashes the verb.
local function _toast(msg, secs)
    pcall(function() feature_umg.toast(msg, secs or 1.5) end)
end

local function schedule_game_thread(delay_ms, fn)
    return feature_oculus_async.schedule_game_thread(delay_ms, fn)
end

local function _destroy_actor(actor)
    if not feature_actor.is_valid_object(actor) then return false end
    if actor.K2_DestroyActor then
        local ok = pcall(function() actor:K2_DestroyActor() end)
        if ok then return true end
    end
    if actor.DestroyActor then
        local ok = pcall(function() actor:DestroyActor() end)
        if ok then return true end
    end
    return false
end

local function actor_identity_text(actor)
    if not feature_actor.is_valid_object(actor) then return "" end
    local parts = {}
    local cls = feature_field.class_name_of(actor)
    if cls then parts[#parts + 1] = cls end
    local short = feature_actor.short_name_of(actor)
    if short then parts[#parts + 1] = short end
    local ok_full, full = pcall(function() return actor:GetFullName() end)
    if ok_full and full then parts[#parts + 1] = tostring(full) end
    return table.concat(parts, " "):lower()
end

local function actor_class_name(actor)
    return feature_field.class_name_of(actor) or "<unknown>"
end

local function actor_full_name(actor)
    if not feature_actor.is_valid_object(actor) then return "<invalid>" end
    local ok, full = pcall(function() return actor:GetFullName() end)
    if ok and full then return tostring(full) end
    return "<full unavailable>"
end

local function object_name_safe(obj)
    if not feature_actor.is_valid_object(obj) then return "<invalid>" end
    local ok, name = pcall(function()
        if obj.GetName then return obj:GetName() end
        if obj.GetFName then
            local fname = obj:GetFName()
            if fname and fname.ToString then return fname:ToString() end
        end
        return nil
    end)
    if ok and name then return tostring(name) end
    return "<unnamed>"
end

local function root_component(actor)
    if not feature_actor.is_valid_object(actor) then return nil end
    local ok, root = pcall(function() return actor.RootComponent end)
    if ok and feature_actor.is_valid_object(root) then return root end
    if actor.GetRootComponent then
        local ok_get, got = pcall(function() return actor:GetRootComponent() end)
        if ok_get and feature_actor.is_valid_object(got) then return got end
    end
    return nil
end

local function component_detail(component)
    if not feature_actor.is_valid_object(component) then return "root=<none>" end
    local cls = feature_field.class_name_of(component) or "<unknown>"
    local mobility = "?"
    local sim = "?"
    local collision = "?"
    pcall(function()
        if component.Mobility ~= nil then mobility = tostring(component.Mobility) end
    end)
    pcall(function()
        if component.IsSimulatingPhysics then sim = tostring(component:IsSimulatingPhysics()) end
    end)
    pcall(function()
        if component.GetCollisionEnabled then collision = tostring(component:GetCollisionEnabled()) end
    end)
    return string.format("root=%s root_class=%s mobility=%s sim=%s collision=%s",
        object_name_safe(component), tostring(cls), tostring(mobility), tostring(sim), tostring(collision))
end

local function vec_line(vec)
    if not vec then return "(?,?,?)" end
    return string.format("(%.0f,%.0f,%.0f)", vec.X or 0, vec.Y or 0, vec.Z or 0)
end

local function rot_line(rot)
    if not rot then return "(?,?,?)" end
    return string.format("(p=%.1f,y=%.1f,r=%.1f)", rot.Pitch or 0, rot.Yaw or 0, rot.Roll or 0)
end

local function scale_line(scale)
    if not scale then return "(?,?,?)" end
    return string.format("(%.3f,%.3f,%.3f)", scale.X or 0, scale.Y or 0, scale.Z or 0)
end

local function grab_block_reason(a)
    local cls_name, full_name
    pcall(function()
        local c = a:GetClass()
        if c then cls_name = c:GetName() end
    end)
    pcall(function() full_name = a:GetFullName() end)
    local hay = ((cls_name or "") .. " " .. (full_name or "")):lower()

    local building_piece_data_index
    pcall(function() building_piece_data_index = a.BuildingPieceDataIndex end)
    if type(building_piece_data_index) == "number" then
        return "building piece", "BuildingPieceDataIndex=" .. tostring(building_piece_data_index)
    end

    if hay:find("staticmeshactor", 1, true)
        or hay:find("instancedfoliageactor", 1, true)
        or hay:find("landscapestreamingproxy", 1, true)
        or hay:find("landscapeproxy", 1, true)
        or hay:find("bpp_", 1, true) then
        return "world-static/environment", cls_name or full_name or "<unknown>"
    end

    return nil
end

local function is_character_like_actor(actor)
    local hay = actor_identity_text(actor)
    if hay == "" then return false end
    return hay:find("bp_npc_", 1, true) ~= nil
        or hay:find("bp_ai_", 1, true) ~= nil
        or hay:find("_character", 1, true) ~= nil
        or hay:find("dominionaicharacter", 1, true) ~= nil
        or hay:find("baseinteractablenpc", 1, true) ~= nil
end

local function target_diagnostic_line(actor, source, loc)
    if not feature_actor.is_valid_object(actor) then return "target=<invalid>" end
    local short = feature_actor.short_name_of(actor) or "<unnamed>"
    local root = root_component(actor)
    local actor_loc = loc or feature_actor.actor_location(actor)
    local actor_rot = feature_actor.actor_rotation(actor)
    local actor_scale = feature_actor.get_actor_scale3d(actor)
    local blocked_kind, blocked_detail = grab_block_reason(actor)
    local blocked = blocked_kind and (blocked_kind .. ":" .. tostring(blocked_detail)) or "no"
    return string.format(
        "target=%s class=%s source=%s loc=%s rot=%s scale=%s blocked=%s %s full=%s",
        tostring(short), tostring(actor_class_name(actor)), tostring(source or "?"), vec_line(actor_loc),
        rot_line(actor_rot), scale_line(actor_scale), tostring(blocked),
        component_detail(root), actor_full_name(actor))
end

local function target_light_line(actor, source, loc)
    if not feature_actor.is_valid_object(actor) then return "target=<invalid>" end
    local short = feature_actor.short_name_of(actor) or "<unnamed>"
    local actor_loc = loc or feature_actor.actor_location(actor)
    return string.format("target=%s source=%s loc=%s",
        tostring(short), tostring(source or "?"), vec_line(actor_loc))
end

local function is_runtime_world_item_actor(actor)
    if not feature_actor.is_valid_object(actor) then return false end
    if feature_inventory._is_runtime_world_item then
        local ok, is_item = pcall(function()
            return feature_inventory._is_runtime_world_item(actor)
        end)
        if ok and is_item == true then return true end
    end
    local text = actor_identity_text(actor)
    return text:find("runtimespawnedworlditem", 1, true) ~= nil
end

local function looks_like_tree_destroy_target(actor)
    local text = actor_identity_text(actor)
    if text == "" then return false end
    return text:find("fellabletree", 1, true) ~= nil
        or text:find("fellable_tree", 1, true) ~= nil
        or text:find("saplingbase", 1, true) ~= nil
        or text:find("instancedfoliageactor", 1, true) ~= nil
        or text:find("instanced_foliage_actor", 1, true) ~= nil
        or text:find("interactablefoliage", 1, true) ~= nil
        or text:find("foliageismc_tree", 1, true) ~= nil
        or text:find("foliageismcomponent", 1, true) ~= nil
end

local function destroy_tree_under_reticle()
    local ok_mod, foliage = pcall(require, "feature_foliage")
    if not ok_mod or type(foliage) ~= "table" or type(foliage.tree_destroy_single) ~= "function" then
        return false, "feature_foliage unavailable"
    end
    return foliage.tree_destroy_single("")
end

-- ---------- tunables ----------

-- Tick rate for the follow loop. 30 Hz is plenty: the camera updates
-- at 60 Hz natively, the grabbed actor follows on alternate frames.
-- Halving the tick rate vs. 60 Hz halves our reflection cost for an
-- imperceptible loss in smoothness because the camera (which the eye
-- tracks) is still buttery.
local GRAB_TICK_MS = 33

-- Distance + Z deltas (per wheel notch).
local STEP_DISTANCE = 50.0    -- cm
local STEP_Z = 25.0           -- cm
local STEP_ROT_DEG = 15.0     -- yaw degrees
local STEP_SCALE = 0.10       -- uniform multiplier delta
local SCALE_MIN = 0.05
local SCALE_MAX = 50.0

local function steps_line()
    return string.format(
        "distance=%.3g z=%.3g yaw=%.3g scale=%.3g min=%.3g max=%.3g",
        STEP_DISTANCE, STEP_Z, STEP_ROT_DEG, STEP_SCALE, SCALE_MIN, SCALE_MAX)
end

-- Default placement distance from the camera if we can't measure where
-- the actor was when grabbed (e.g. its location read failed).
local DEFAULT_DISTANCE = 300.0

-- Maximum trace distance for "grab what I'm looking at". 100m covers
-- any reasonable in-game pick distance ; we don't want to trace to
-- infinity and grab terrain on the horizon by accident.
local LOOKAT_MAX_DISTANCE = 10000.0

-- Runtime-spawned pickups often do not block the Visibility trace used by
-- camera.lookat. Scan can still see them because it enumerates actors, so
-- Oculus picking gets a tiny actor-enumeration pass for these item wrappers.
local WORLD_ITEM_RAY_RADIUS = 115.0
local WORLD_ITEM_FORCE_RAY_RADIUS = 220.0
local WORLD_ITEM_DEPTH_LEEWAY = 175.0
local WORLD_ITEM_FIND_CLASSES = {
    "BP_RuntimeSpawnedWorldItem_C",
    "BP_RuntimeSpawnedWorldItem_NoDelayForMagnet_C",
    "BP_RuntimeSpawnedWorldItem_ProcessingStation_C",
    "RuntimeSpawnedWorldItem",
    "WorldItem",
}
local SAFE_GRAB_DELAY_MS = 80
local FINISH_SETTLE_SECONDS = 0.0
local FINISH_HOTKEY_DEBOUNCE_SECONDS = 0.18
local GRAB_RESTART_COOLDOWN_SECONDS = 0.75
local POST_FINISH_STABILIZE_MS = 90
local POST_FINISH_CAPTURE_MS = 150
local POST_FINISH_HELP_MS = 180
local CHARACTER_QUIET_RESTORE_MS = 220
local GRAB_MAX_FOLLOW_STEP_CM = 2500.0
local GRAB_CHARACTER_MAX_FOLLOW_STEP_CM = 275.0
local GRAB_START_WARMUP_FRAMES = 0
local GRAB_CHARACTER_START_WARMUP_FRAMES = 6
local GRAB_CHARACTER_MOVE_INTERVAL_SECONDS = 0.10
local GRAB_IDLE_CAMERA_POLL_SECONDS = 0.05
local GRAB_ACTIVE_CAMERA_GRACE_SECONDS = 0.20
local GRAB_DEST_EPSILON_CM = 0.35
local GRAB_CAMERA_LOC_EPSILON_CM = 0.35
local GRAB_CAMERA_ROT_EPSILON_DEG = 0.03
local GRAB_OCULUS_INACTIVE_CANCEL_FRAMES = 10
-- Round 69: debug-camera grab was notably smoother/stabler with the plain
-- LoopAsync(33ms) driver while world time was nearly frozen. For this Oculus
-- experiment, keep the same simple 30 Hz cadence instead of the engine-tick
-- driver so we can compare movement behavior apples-to-apples.
local GRAB_USE_ENGINE_TICK = false
-- Grab Mode UI is intentionally one-shot: schedule the top strip shortly after
-- start, then hide it on finish. No polling/live values during actor movement.
local GRAB_MODAL_UMG_ENABLED = true
local GRAB_MODAL_OVERLAY_DELAY_MS = 80

local function schedule_help_refresh(delay_ms)
    schedule_game_thread(delay_ms or POST_FINISH_HELP_MS, function()
        local ok_cfg, cfg = pcall(require, "feature_oculus_config")
        if ok_cfg and type(cfg) == "table" and type(cfg.refresh_hotkey_help) == "function" then
            pcall(function() cfg.refresh_hotkey_help(true) end)
        end
    end)
end

local function note_modal_settle(reason)
    local mode = package.loaded["feature_oculus_mode"]
    if type(mode) == "table" and type(mode.note_settle) == "function" then
        pcall(function() mode.note_settle(reason or "grab.finish") end)
    end
end

-- ---------- state ----------

-- Single in-flight grab. We deliberately don't support stacking grabs:
-- the user can only steer one actor at a time and the UX is clearer.
local grab = nil
local grab_diag = {
    ticks = 0,
    camera_failures = 0,
    move_failures = 0,
    auto_cancels = 0,
    clamped_steps = 0,
    rotation_writes = 0,
    rotation_failures = 0,
    camera_polls = 0,
    idle_camera_skips = 0,
    skipped_moves = 0,
    oculus_inactive_reads = 0,
    last_tick_clock = 0,
    last_camera_error = nil,
    last_move_error = nil,
    last_rotation_error = nil,
    last_oculus_active_error = nil,
}
local grab_tick_fn = nil
local grab_loop_driver = nil
local grab_engine_tick_started = false
local pending_grab = nil
local pending_grab_token = 0
local last_grab_finish_clock = -1000.0
local _oculus_is_active
-- Shape:
--   {
--     actor       = userdata,
--     name        = "<short name>",
--     orig_loc    = { X, Y, Z },          -- for cancel()
--     orig_rot    = { Pitch, Yaw, Roll }, -- for cancel()
--     orig_scale  = { X, Y, Z },          -- for cancel()
--     oculus_started = bool,              -- auto-cancel if Oculus exits
--     distance    = number,               -- cm in front of camera
--     z_offset    = number,               -- cm above camera plane
--     yaw_offset  = number,               -- deg added to held actor yaw
--     scale       = number,               -- uniform scalar
--     scale_dirty = bool,                 -- pending uniform scale write on tick
--     rotation_dirty = bool,              -- pending rotation write on tick
--     mode        = "move" | "rot" | "z" | "scale",
--     dest        = { X, Y, Z },          -- pre-allocated, mutated in place
--     rot         = { Pitch, Yaw, Roll }, -- pre-allocated, mutated in place
--     last_dest   = { X, Y, Z },          -- last successfully requested dest
--     last_dest_valid = bool,             -- false for the first tick
--     last_cam_loc = { X, Y, Z },         -- last sampled Oculus camera loc
--     last_cam_rot = { Pitch, Yaw, Roll },-- last sampled Oculus camera rot
--     loop_armed  = bool,                 -- LoopAsync handle is live
--   }

local function refresh_hotkey_help(force)
    local cfg = package.loaded["feature_oculus_config"]
    if type(cfg) == "table" and type(cfg.refresh_hotkey_help) == "function" then
        pcall(function() cfg.refresh_hotkey_help(force == true) end)
    end
end

local function grab_mode_label(g)
    if type(g) ~= "table" then return "Move" end
    if g.pending_finish == true then
        local kind = tostring(g.pending_finish_kind or "release")
        if kind == "cancel" then return "Cancelling" end
        return "Releasing"
    end
    local mode = tostring(g.mode or "move")
    if mode == "rot" then return "Rotate" end
    if mode == "z" then return "Z Lift" end
    if mode == "scale" then return "Scale" end
    return "Move"
end

local function grab_top_status(g)
    return "Grab Mode"
end

local function update_grab_overlay(force, refresh_help_panel)
    if GRAB_MODAL_UMG_ENABLED ~= true then
        return
    end
    if grab then
        local token_grab = grab
        schedule_game_thread(GRAB_MODAL_OVERLAY_DELAY_MS, function()
            if grab == token_grab then
                pcall(function() feature_umg.oculus_rotation_overlay(true, grab_top_status(grab), "", "grab") end)
            end
        end)
        if refresh_help_panel == true then
            refresh_hotkey_help(force == true)
        end
    else
        pcall(function() feature_umg.oculus_rotation_overlay(false) end)
    end
end

local function hide_grab_overlay()
    if GRAB_MODAL_UMG_ENABLED ~= true then
        return
    end
    pcall(function() feature_umg.oculus_rotation_overlay(false) end)
end

local function restart_cooldown_remaining()
    local elapsed = os.clock() - (tonumber(last_grab_finish_clock) or -1000.0)
    local remaining = GRAB_RESTART_COOLDOWN_SECONDS - elapsed
    if remaining > 0 then return remaining end
    return 0
end

local function restart_cooldown_message()
    local remaining = restart_cooldown_remaining()
    if remaining <= 0 then return nil end
    return string.format("grab settling %.2fs", remaining)
end

-- ---------- camera viewpoint ----------

-- Pulls the active player camera location + rotation. Routes through
-- GetPlayerViewPoint so we automatically follow whatever pawn is the
-- current view target for normal play.
--
-- Special case: when the oculus freecam is active the game does NOT
-- swap the view target on the player controller. The oculus pawn
-- renders its own camera independently, so GetPlayerViewPoint keeps
-- returning the player character's eyes (and the InteractableDetector
-- that traces from there sees nothing useful while the player is far
-- away). Detect that and read straight from the oculus pawn's
-- UCameraComponent instead. Reach path matches the working camera.json
-- kits: pawn.OculusComponent.OculusPawn.Camera + .TargetRotation.
local function get_camera_viewpoint()
    -- 1. DebugCamera override. The stock DebugCamera can keep moving while
    -- world time is nearly frozen, so editor-style reticle tools should read
    -- from it before falling back to the gameplay/Oculus camera paths.
    if feature_camera.debug_camera_viewpoint then
        local dbg_loc, dbg_rot, dbg_err = feature_camera.debug_camera_viewpoint()
        if dbg_loc and dbg_rot then
            return dbg_loc, dbg_rot, nil
        end
    end

    -- 2. Oculus override (only when actually active).
    local opawn = (function()
        local p, _ = feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
        return p
    end)()
    if feature_actor.is_valid_object(opawn) then
        local active = false
        local ok_a, v = pcall(function() return opawn.bOculusActive end)
        if ok_a then active = (v == true) end
        if active then
            -- Prefer the camera component's world transform so we match
            -- exactly what's being rendered (TargetPosition/Rotation are
            -- the network-replicated targets, not the interpolated frame
            -- values, so they can lag a tick behind the visible camera).
            local cam_loc, cam_rot
            local ok_c, cam = pcall(function() return opawn.Camera end)
            if ok_c and feature_actor.is_valid_object(cam) then
                local ok_l, l = pcall(function() return cam:K2_GetComponentLocation() end)
                if ok_l and l then cam_loc = l end
                local ok_r, r = pcall(function() return cam:K2_GetComponentRotation() end)
                if ok_r and r then cam_rot = r end
            end
            -- Fall back to the pawn's own actor transform if the camera
            -- component reflection failed (rare, but keep the path live).
            if not cam_loc then
                local ok_l, l = pcall(function() return opawn:K2_GetActorLocation() end)
                if ok_l and l then cam_loc = l end
            end
            if not cam_rot then
                local ok_r, r = pcall(function() return opawn:K2_GetActorRotation() end)
                if ok_r and r then cam_rot = r end
            end
            if cam_loc and cam_rot then
                return cam_loc, cam_rot, nil
            end
            -- If we got here oculus is "active" but reflection failed.
            -- Fall through to the controller path below.
        end
    end

    -- 3. Standard path (player char, spectator, set-view-target).
    local pc, err = feature_field.resolve_root("controller")
    if not pc then return nil, nil, "no controller: " .. tostring(err) end
    if not pc.GetPlayerViewPoint then
        return nil, nil, "controller missing GetPlayerViewPoint"
    end
    -- UE outputs are passed in as a struct ; UE4SS auto-allocates them.
    local ok, loc, rot = pcall(function()
        local l = { X = 0, Y = 0, Z = 0 }
        local r = { Pitch = 0, Yaw = 0, Roll = 0 }
        pc:GetPlayerViewPoint(l, r)
        return l, r
    end)
    if not ok then return nil, nil, "GetPlayerViewPoint raised: " .. tostring(loc) end
    return loc, rot, nil
end

-- ---------- camera trace ----------
--
-- Casts a line from the active camera straight forward and returns the
-- first hit actor (+ hit location, + impact normal). Used by lookat
-- and by the no-arg form of camera.grab.start.
--
-- Implementation notes:
--   * KismetSystemLibrary::LineTraceSingle is the only trace API that has
--     proven stable across UE4SS reflection on this build. The OLD
--     RSDTools mod tried World:LineTraceSingleByChannel directly and
--     it null-deref'd ; the kismet wrapper resolves the hidden world
--     context arg internally, sidestepping that.
--   * We pass an actor-ignore list containing the local pawn AND the
--     oculus pawn. Without this, every grab attempt while in oculus
--     mode would just hit your own collision sphere first.
--   * "TraceTypeQuery1" is ECC_Visibility on a stock UE 5.x project.
--     Game-specific channels (e.g. ECC_Pawn) might miss world geometry,
--     but visibility hits everything renderable, which is what the
--     "grab what's under the reticle" intent wants.
local _ksl = nil  -- cached UKismetSystemLibrary CDO
local function get_kismet_lib()
    if _ksl and _ksl.IsValid and _ksl:IsValid() then return _ksl end
    if not StaticFindObject then return nil end
    local ok, obj = pcall(StaticFindObject, "/Script/Engine.Default__KismetSystemLibrary")
    if ok and obj and obj.IsValid and obj:IsValid() then
        _ksl = obj
        return _ksl
    end
    return nil
end

local function get_oculus_pawn_safe()
    local pawn, _ = feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
    return pawn  -- may be nil ; that's fine, just means oculus isn't active
end

local function build_camera_ray(distance)
    distance = tonumber(distance) or LOOKAT_MAX_DISTANCE
    if distance < 100.0 then distance = LOOKAT_MAX_DISTANCE end

    local cam_loc, cam_rot, err = get_camera_viewpoint()
    if not cam_loc then return nil, nil, nil, nil, "camera unavailable: " .. tostring(err) end

    local pitch = (cam_rot.Pitch or 0) * math.pi / 180.0
    local yaw   = (cam_rot.Yaw   or 0) * math.pi / 180.0
    local cp = math.cos(pitch)
    local fx = cp * math.cos(yaw)
    local fy = cp * math.sin(yaw)
    local fz = math.sin(pitch)

    local start_v = { X = cam_loc.X, Y = cam_loc.Y, Z = cam_loc.Z }
    local end_v = {
        X = cam_loc.X + fx * distance,
        Y = cam_loc.Y + fy * distance,
        Z = cam_loc.Z + fz * distance,
    }
    return start_v, end_v, { X = fx, Y = fy, Z = fz }, cam_rot, nil
end

local function ray_projection(start_v, forward, loc)
    if not start_v or not forward or not loc then return nil, nil end
    local dx = (loc.X or 0) - (start_v.X or 0)
    local dy = (loc.Y or 0) - (start_v.Y or 0)
    local dz = (loc.Z or 0) - (start_v.Z or 0)
    local along = dx * (forward.X or 0) + dy * (forward.Y or 0) + dz * (forward.Z or 0)
    local total_sq = dx * dx + dy * dy + dz * dz
    local perp_sq = total_sq - along * along
    if perp_sq < 0 then perp_sq = 0 end
    return along, perp_sq
end

local function is_world_item_actor(actor)
    if not feature_actor.is_valid_object(actor) then return false end
    local cls_name, full_name
    pcall(function()
        local cls = actor:GetClass()
        if cls then
            if cls.GetFName then
                local fn = cls:GetFName()
                if fn and fn.ToString then cls_name = fn:ToString() end
            end
            if not cls_name and cls.GetName then cls_name = cls:GetName() end
        end
    end)
    pcall(function() full_name = actor:GetFullName() end)
    local hay = ((cls_name or "") .. " " .. (full_name or "")):lower()
    return hay:find("runtimespawnedworlditem", 1, true) ~= nil
        or hay:find("bp_runtimespawnedworlditem", 1, true) ~= nil
end

local function enumerate_world_item_actors()
    if not FindAllOf then return {} end
    local out, seen = {}, {}

    local function add(actor)
        if not is_world_item_actor(actor) then return end
        local key = feature_actor.short_name_of(actor)
        if not key or key == "" then key = tostring(actor) end
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = actor
    end

    local function scan_class(class_name)
        local ok, list = pcall(FindAllOf, class_name)
        if not ok or type(list) ~= "table" then return end
        for _, actor in ipairs(list) do
            add(actor)
        end
    end

    for _, class_name in ipairs(WORLD_ITEM_FIND_CLASSES) do
        scan_class(class_name)
    end

    -- Some UE4SS builds only accept "Actor"/"AActor" for broad live-object
    -- walks. If the targeted class scans yielded nothing, fall back once.
    if #out == 0 then
        local ok, actors = pcall(function()
            local list = FindAllOf("Actor")
            if type(list) ~= "table" then list = FindAllOf("AActor") end
            return list
        end)
        if ok and type(actors) == "table" then
            for _, actor in ipairs(actors) do
                add(actor)
            end
        end
    end

    return out
end

local function pick_world_item_candidate(opts)
    opts = opts or {}
    local radius = opts.radius or (opts.force and WORLD_ITEM_FORCE_RAY_RADIUS or WORLD_ITEM_RAY_RADIUS)
    local start_v, _end_v, forward, _cam_rot, ray_err = build_camera_ray(opts.distance or LOOKAT_MAX_DISTANCE)
    if not start_v then return nil, nil, nil, tostring(ray_err) end

    local trace_along = nil
    if opts.trace_impact then
        trace_along = select(1, ray_projection(start_v, forward, opts.trace_impact))
    end

    local best = nil
    local radius_sq = radius * radius
    for _, actor in ipairs(enumerate_world_item_actors()) do
        local loc = feature_actor.actor_location(actor)
        if loc then
            local along, perp_sq = ray_projection(start_v, forward, loc)
            if along and along > 0 and along <= (opts.distance or LOOKAT_MAX_DISTANCE) and perp_sq <= radius_sq then
                if opts.force
                    or not trace_along
                    or along <= trace_along + WORLD_ITEM_DEPTH_LEEWAY then
                    local score = perp_sq + along * 0.05
                    if not best or score < best.score then
                        best = {
                            actor = actor,
                            loc = loc,
                            along = along,
                            perp = math.sqrt(perp_sq),
                            score = score,
                        }
                    end
                end
            end
        end
    end

    if best then
        local source = opts.force and "trace.item.force" or "trace.item"
        return best.actor, best.loc, source, nil, best
    end
    return nil, nil, nil, "no runtime world item near reticle", nil
end

local function _trace_from_camera(distance)
    local start_v, end_v, _forward, _cam_rot, ray_err = build_camera_ray(distance)
    if not start_v then return nil, nil, tostring(ray_err) end

    local ksl = get_kismet_lib()
    if not ksl then return nil, nil, "KismetSystemLibrary CDO unavailable" end

    local world = (function()
        local w, _ = feature_field.resolve_root("world")
        return w
    end)()
    if not world then return nil, nil, "no world" end

    -- Build the ignore list. Pawn is the player character ; oculus pawn
    -- is the freecam pawn we're flying. Either may be nil depending on
    -- mode ; we just leave the slot empty when so.
    local ignore = {}
    local pawn = feature_actor.get_local_pawn()
    if feature_actor.is_valid_object(pawn) then ignore[#ignore + 1] = pawn end
    local opawn = get_oculus_pawn_safe()
    if feature_actor.is_valid_object(opawn) then ignore[#ignore + 1] = opawn end

    local hit = {}
    local trace_color = { R = 0, G = 0, B = 0, A = 0 }
    local hit_color   = { R = 0, G = 0, B = 0, A = 0 }

    -- Try a tight line trace first (cheapest, gives the exact reticle hit
    -- when the target is solid + well-aligned). If that returns no hit OR
    -- a hit with no resolvable actor (e.g. instanced static mesh foliage,
    -- raw landscape components), retry with a sphere sweep so distant
    -- pawns / thin geometry get caught. Two-pass keeps the common case
    -- fast while making the freecam pick "feel" forgiving like the OLD
    -- selection code's wider tolerance.
    local function _do_line_trace()
        return pcall(function()
            return ksl:LineTraceSingle(
                world, start_v, end_v,
                "TraceTypeQuery1",        -- ECC_Visibility
                false,                     -- bTraceComplex
                ignore,
                "EDrawDebugTrace::None",
                hit,
                true,                      -- bIgnoreSelf
                trace_color, hit_color,
                0.0                        -- DrawTime
            )
        end)
    end
    local function _do_sphere_trace(radius)
        -- Fresh table so the first-pass output doesn't leak into the
        -- second when the line trace half-failed.
        hit = {}
        return pcall(function()
            return ksl:SphereTraceSingle(
                world, start_v, end_v, radius,
                "TraceTypeQuery1",
                false,
                ignore,
                "EDrawDebugTrace::None",
                hit,
                true,
                trace_color, hit_color,
                0.0
            )
        end)
    end

    -- Resolves the first usable actor handle out of an FHitResult.
    -- IMPORTANT: do NOT pre-filter Component / HitObjectHandle through
    -- is_valid_object. UE4SS marshals Component as a userdata wrapper
    -- (not a plain UObject*) and HitObjectHandle as a Lua TABLE (the
    -- FActorInstanceHandle struct), neither of which IsValid accepts.
    -- We just pcall the accessors and trust the result if it comes
    -- back as a live UObject.
    local function _unpack_actor(hr)
        local a = nil
        local h = hr.HitObjectHandle
        if h then
            -- Struct form: try a method first (some UE4SS builds expose
            -- it on the table) ; fall back to the raw Actor field.
            if type(h) == "table" or type(h) == "userdata" then
                if h.GetActor then
                    local okh, v = pcall(function() return h:GetActor() end)
                    if okh and feature_actor.is_valid_object(v) then a = v end
                end
                if (not a) and h.Actor and feature_actor.is_valid_object(h.Actor) then
                    a = h.Actor
                end
                if (not a) and h.ReferenceObject and feature_actor.is_valid_object(h.ReferenceObject) then
                    a = h.ReferenceObject
                end
            end
        end
        if (not a) and hr.Actor and feature_actor.is_valid_object(hr.Actor) then
            a = hr.Actor
        end
        local comp = hr.Component
        local comp_obj = comp
        if comp then
            if feature_actor.is_valid_object(comp) then
                comp_obj = comp
            else
                local okg, real = pcall(function()
                    if comp.get then return comp:get() end
                    if comp.ToObject then return comp:ToObject() end
                    return nil
                end)
                if okg and feature_actor.is_valid_object(real) then
                    comp_obj = real
                end
            end
        end
        if (not a) and comp_obj then
            -- Component is userdata. GetOwner may exist directly, or we
            -- may need to go through the wrapper's :get() / :ToObject()
            -- (UE4SS's RemoteUnrealParam pattern). Try both.
            if comp_obj and comp_obj.GetOwner then
                local oko, v = pcall(function() return comp_obj:GetOwner() end)
                if oko and feature_actor.is_valid_object(v) then a = v end
            end
            if not a then
                local okg, real = pcall(function() return comp_obj end)
                if okg and real and real.GetOwner then
                    local oko, v = pcall(function() return real:GetOwner() end)
                    if oko and feature_actor.is_valid_object(v) then a = v end
                end
            end
        end
        return a, comp_obj or comp
    end

    local ok, did_hit = _do_line_trace()
    if not ok then return nil, nil, "trace raised: " .. tostring(did_hit) end

    local actor, comp = nil, nil
    if did_hit then actor, comp = _unpack_actor(hit) end

    if not feature_actor.is_valid_object(actor) then
        -- Sphere fallback. 50cm radius matches the OLD selection code's
        -- "what you're roughly aiming at" tolerance and reliably picks up
        -- NPCs at range without grabbing terrain right under the reticle.
        local ok2, did_hit2 = _do_sphere_trace(50.0)
        if ok2 and did_hit2 then
            actor, comp = _unpack_actor(hit)
        end
    end

    if not feature_actor.is_valid_object(actor) then
        -- Still nothing. Dump every top-level key of the hit struct
        -- so we can see how UE4SS is marshalling FHitResult in this
        -- build (the field name for the component varies between UE
        -- versions: Component / HitComponent / PhysMaterial owner).
        -- We log to UE4SS console AND return a compact summary so it
        -- shows up in the bridge ack too.
        local keys = {}
        for k, v in pairs(hit) do
            local tv = type(v)
            local extra = ""
            if tv == "userdata" and v.GetFullName then
                local okn, n = pcall(function() return v:GetFullName() end)
                if okn then extra = "=" .. tostring(n) end
            elseif tv == "table" then
                extra = "={...}"
            elseif tv ~= "function" then
                extra = "=" .. tostring(v)
            end
            keys[#keys + 1] = k .. "(" .. tv .. ")" .. extra
        end
        table.sort(keys)
        local dump = table.concat(keys, ", ")
        if print then print("[grab.trace] FHitResult fields: " .. dump .. "\n") end

        -- Also dump the HitObjectHandle struct's inner keys ; UE 5.x
        -- buries the actor pointer inside it (e.g. Manager + InstanceUID
        -- + ReferenceObject) and we want to see what shape this build
        -- ships before guessing.
        if hit.HitObjectHandle and type(hit.HitObjectHandle) == "table" then
            local hkeys = {}
            for k, v in pairs(hit.HitObjectHandle) do
                hkeys[#hkeys + 1] = k .. "(" .. type(v) .. ")"
            end
            table.sort(hkeys)
            if print then print("[grab.trace] HitObjectHandle: " .. table.concat(hkeys, ", ") .. "\n") end
        end

        local cclass = "<no component>"
        local comp_raw = hit.Component
        if comp_raw then
            -- Try class name without going through is_valid_object,
            -- which rejects non-UObject userdata wrappers.
            local okc, cn = pcall(function()
                if comp_raw.GetClass then
                    local c = comp_raw:GetClass()
                    if c and c.GetFName then return c:GetFName():ToString() end
                    if c and c.GetName then return c:GetName() end
                end
                if comp_raw.GetFullName then return comp_raw:GetFullName() end
                return nil
            end)
            if okc and cn then cclass = tostring(cn) end
        end
        local impact = hit.Location or hit.ImpactPoint
        local where = ""
        if impact then
            where = string.format(" @ (%.0f, %.0f, %.0f)", impact.X or 0, impact.Y or 0, impact.Z or 0)
        end
        local short = dump
        if #short > 240 then short = short:sub(1, 240) .. "..." end
        return nil, impact,
            "hit non-actor geometry [comp=" .. cclass .. "]" .. where .. " fields=" .. short,
            {
                component = comp,
                item = hit.Item,
                my_item = hit.MyItem,
                element_index = hit.ElementIndex,
                face_index = hit.FaceIndex,
                hit = hit,
            }
    end
    local impact = hit.Location or hit.ImpactPoint
    return actor, impact, nil, {
        component = comp,
        item = hit.Item,
        my_item = hit.MyItem,
        element_index = hit.ElementIndex,
        face_index = hit.FaceIndex,
        hit = hit,
    }
end

-- ---------- math ----------

local function deg2rad(d) return d * math.pi / 180.0 end

local function camera_forward(rot)
    -- Flat XY forward (yaw only). Used for the legacy "distance on
    -- floor plane" model ; kept for the seed-distance computation in
    -- M.start so a horizontal grab still feels stable when the player
    -- is looking nearly straight down.
    local yaw = deg2rad(rot and rot.Yaw or 0)
    return math.cos(yaw), math.sin(yaw)
end

-- Full 3D forward unit vector (pitch + yaw). UE rotators: pitch up is
-- +ve, so positive pitch yields +Z. This is what makes the grab feel
-- oculus-y: looking up raises the held actor along the sight line.
local function camera_forward_3d(rot)
    local pitch = deg2rad(rot and rot.Pitch or 0)
    local yaw   = deg2rad(rot and rot.Yaw or 0)
    local cp = math.cos(pitch)
    return cp * math.cos(yaw), cp * math.sin(yaw), math.sin(pitch)
end

local function vec_len_xy(dx, dy, dz)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function angle_delta_abs(a, b)
    local d = (tonumber(a) or 0.0) - (tonumber(b) or 0.0)
    while d > 180.0 do d = d - 360.0 end
    while d < -180.0 do d = d + 360.0 end
    if d < 0 then d = -d end
    return d
end

local function loc_delta_len(a, b)
    if not a or not b then return math.huge end
    return vec_len_xy(
        (a.X or 0) - (b.X or 0),
        (a.Y or 0) - (b.Y or 0),
        (a.Z or 0) - (b.Z or 0))
end

local function rot_delta_len(a, b)
    if not a or not b then return math.huge end
    return math.max(
        angle_delta_abs(a.Pitch or a.pitch, b.Pitch or b.pitch),
        angle_delta_abs(a.Yaw or a.yaw, b.Yaw or b.yaw),
        angle_delta_abs(a.Roll or a.roll, b.Roll or b.roll))
end

local function clamp_grab_destination_step(g)
    if type(g) ~= "table" or not g.dest then return end
    local max_step = g.character_profile == true
        and GRAB_CHARACTER_MAX_FOLLOW_STEP_CM
        or GRAB_MAX_FOLLOW_STEP_CM
    if max_step <= 0 then return end
    if g.last_dest_valid ~= true or not g.last_dest then
        return
    end
    local dx = (g.dest.X or 0) - (g.last_dest.X or 0)
    local dy = (g.dest.Y or 0) - (g.last_dest.Y or 0)
    local dz = (g.dest.Z or 0) - (g.last_dest.Z or 0)
    local dist = vec_len_xy(dx, dy, dz)
    if dist <= max_step or dist <= 0.001 then return end
    local t = max_step / dist
    g.dest.X = (g.last_dest.X or 0) + dx * t
    g.dest.Y = (g.last_dest.Y or 0) + dy * t
    g.dest.Z = (g.last_dest.Z or 0) + dz * t
    grab_diag.clamped_steps = (grab_diag.clamped_steps or 0) + 1
end

local function character_move_methods(g)
    local methods = {
        "root_world_location",
        "actor_location",
    }
    if type(g) == "table" and g.character_move_method then
        local preferred = tostring(g.character_move_method)
        local ordered = { preferred }
        for _, method in ipairs(methods) do
            if method ~= preferred then ordered[#ordered + 1] = method end
        end
        return ordered
    end
    return methods
end

local function component_location(component)
    if not feature_actor.is_valid_object(component) then return nil end
    if component.K2_GetComponentLocation then
        local ok, loc = pcall(function() return component:K2_GetComponentLocation() end)
        if ok and loc then return loc end
    end
    if component.GetComponentLocation then
        local ok, loc = pcall(function() return component:GetComponentLocation() end)
        if ok and loc then return loc end
    end
    return nil
end

local function component_rotation(component)
    if not feature_actor.is_valid_object(component) then return nil end
    if component.K2_GetComponentRotation then
        local ok, rot = pcall(function() return component:K2_GetComponentRotation() end)
        if ok and rot then return rot end
    end
    if component.GetComponentRotation then
        local ok, rot = pcall(function() return component:GetComponentRotation() end)
        if ok and rot then return rot end
    end
    return nil
end

local function component_scale(component)
    if not feature_actor.is_valid_object(component) then return nil end
    if component.GetComponentScale then
        local ok, scale = pcall(function() return component:GetComponentScale() end)
        if ok and scale then return scale end
    end
    if component.GetWorldScale then
        local ok, scale = pcall(function() return component:GetWorldScale() end)
        if ok and scale then return scale end
    end
    local ok_rel, rel = pcall(function() return component.RelativeScale3D end)
    if ok_rel and rel then return rel end
    return nil
end

local function component_relative_scale(component)
    if not feature_actor.is_valid_object(component) then return nil end
    local ok_rel, rel = pcall(function() return component.RelativeScale3D end)
    if ok_rel and rel then return rel end
    return nil
end

local function component_set_world_location(component, loc)
    if not feature_actor.is_valid_object(component) then return false, "invalid component" end
    if component.K2_SetWorldLocation then
        local ok_call, result = pcall(function()
            local hit = {}
            return component:K2_SetWorldLocation(loc, false, hit, false)
        end)
        if ok_call and result ~= false then return true, "K2_SetWorldLocation" end
        return false, ok_call and "K2_SetWorldLocation=false" or tostring(result)
    end
    if component.SetWorldLocation then
        local ok_call, result = pcall(function()
            return component:SetWorldLocation(loc)
        end)
        if ok_call and result ~= false then return true, "SetWorldLocation" end
        return false, ok_call and "SetWorldLocation=false" or tostring(result)
    end
    return false, "no world-location setter"
end

local function component_set_world_rotation(component, rot)
    if not feature_actor.is_valid_object(component) then return false, "invalid component" end
    if component.K2_SetWorldRotation then
        local ok_call, result = pcall(function()
            local hit = {}
            return component:K2_SetWorldRotation(rot, false, hit, true)
        end)
        if ok_call and result ~= false then return true, "K2_SetWorldRotation" end
        ok_call, result = pcall(function()
            local hit = {}
            return component:K2_SetWorldRotation(rot, false, hit)
        end)
        if ok_call and result ~= false then return true, "K2_SetWorldRotation3" end
    end
    if component.SetWorldRotation then
        local ok_call, result = pcall(function()
            return component:SetWorldRotation(rot)
        end)
        if ok_call and result ~= false then return true, "SetWorldRotation" end
    end
    return false, "no world-rotation setter"
end

local function component_set_world_scale(component, scale, entry)
    if not feature_actor.is_valid_object(component) then return false, "invalid component" end
    if component.SetWorldScale3D then
        local ok_call, result = pcall(function()
            return component:SetWorldScale3D(scale)
        end)
        if ok_call and result ~= false then return true, "SetWorldScale3D" end
    end
    if component.SetRelativeScale3D then
        local rel = entry and entry.origin_relative_scale
        local origin = entry and entry.origin_actor_scale
        if rel and origin then
            local target = {
                X = (rel.X or 1) * (((origin.X or 1) ~= 0) and ((scale.X or 1) / (origin.X or 1)) or 1),
                Y = (rel.Y or 1) * (((origin.Y or 1) ~= 0) and ((scale.Y or 1) / (origin.Y or 1)) or 1),
                Z = (rel.Z or 1) * (((origin.Z or 1) ~= 0) and ((scale.Z or 1) / (origin.Z or 1)) or 1),
            }
            local ok_call, result = pcall(function()
                return component:SetRelativeScale3D(target)
            end)
            if ok_call and result ~= false then return true, "SetRelativeScale3D:relative" end
        end
        local ok_call, result = pcall(function()
            return component:SetRelativeScale3D(scale)
        end)
        if ok_call and result ~= false then return true, "SetRelativeScale3D" end
    end
    return false, "no world-scale setter"
end

local function capture_character_visual_components(actor, origin_loc, origin_rot, origin_scale)
    if not feature_actor.is_valid_object(actor) then return nil end
    origin_loc = origin_loc or feature_actor.actor_location(actor)
    origin_rot = origin_rot or feature_actor.actor_rotation(actor)
    origin_scale = origin_scale or feature_actor.get_actor_scale3d(actor)
    if not origin_loc then return nil end
    local root = nil
    local ok_root, root_value = pcall(function() return actor.RootComponent end)
    if ok_root and feature_actor.is_valid_object(root_value) then root = root_value end
    local fields = {
        "Mesh",
        "ReplacementMesh",
        "ReplacementMeshComponent",
        "ReplacementMeshComponent1",
        "SkeletalMeshComponent",
        "CharacterMesh",
    }
    local seen = {}
    local out = {}
    for _, field_name in ipairs(fields) do
        local ok_field, component = pcall(function() return actor[field_name] end)
        if ok_field and feature_actor.is_valid_object(component) and component ~= root and not seen[component] then
            local loc = component_location(component)
            if loc then
                local rot = component_rotation(component)
                local scale = component_scale(component)
                local relative_scale = component_relative_scale(component)
                seen[component] = true
                out[#out + 1] = {
                    component = component,
                    label = field_name,
                    offset = {
                        X = (loc.X or 0) - (origin_loc.X or 0),
                        Y = (loc.Y or 0) - (origin_loc.Y or 0),
                        Z = (loc.Z or 0) - (origin_loc.Z or 0),
                    },
                    rot_offset = rot and origin_rot and {
                        Pitch = (rot.Pitch or 0) - (origin_rot.Pitch or 0),
                        Yaw = (rot.Yaw or 0) - (origin_rot.Yaw or 0),
                        Roll = (rot.Roll or 0) - (origin_rot.Roll or 0),
                    } or nil,
                    scale_ratio = scale and origin_scale and {
                        X = ((origin_scale.X or 1) ~= 0) and ((scale.X or 1) / (origin_scale.X or 1)) or 1,
                        Y = ((origin_scale.Y or 1) ~= 0) and ((scale.Y or 1) / (origin_scale.Y or 1)) or 1,
                        Z = ((origin_scale.Z or 1) ~= 0) and ((scale.Z or 1) / (origin_scale.Z or 1)) or 1,
                    } or nil,
                    origin_actor_scale = origin_scale and {
                        X = origin_scale.X or 1,
                        Y = origin_scale.Y or 1,
                        Z = origin_scale.Z or 1,
                    } or nil,
                    origin_relative_scale = relative_scale and {
                        X = relative_scale.X or 1,
                        Y = relative_scale.Y or 1,
                        Z = relative_scale.Z or 1,
                    } or nil,
                }
            end
        end
    end
    if #out <= 0 then return nil end
    return out
end

local function move_character_visual_components(g, loc)
    if type(g) ~= "table" or type(g.character_visual_components) ~= "table" then return 0, 0 end
    local moved = 0
    local failed = 0
    for _, entry in ipairs(g.character_visual_components) do
        local component = entry and entry.component
        if feature_actor.is_valid_object(component) then
            local offset = entry.offset or {}
            local target = {
                X = (loc.X or 0) + (offset.X or 0),
                Y = (loc.Y or 0) + (offset.Y or 0),
                Z = (loc.Z or 0) + (offset.Z or 0),
            }
            local ok_move = component_set_world_location(component, target)
            if ok_move then moved = moved + 1 else failed = failed + 1 end
        else
            failed = failed + 1
        end
    end
    return moved, failed
end

local function rotate_character_visual_components(g, rot)
    if type(g) ~= "table" or type(g.character_visual_components) ~= "table" or not rot then return 0, 0 end
    local moved = 0
    local failed = 0
    for _, entry in ipairs(g.character_visual_components) do
        local component = entry and entry.component
        if feature_actor.is_valid_object(component) then
            local offset = entry.rot_offset or {}
            local target = {
                Pitch = (rot.Pitch or 0) + (offset.Pitch or 0),
                Yaw = (rot.Yaw or 0) + (offset.Yaw or 0),
                Roll = (rot.Roll or 0) + (offset.Roll or 0),
            }
            local ok_move = component_set_world_rotation(component, target)
            if ok_move then moved = moved + 1 else failed = failed + 1 end
        else
            failed = failed + 1
        end
    end
    return moved, failed
end

local function scale_character_visual_components(g, scale)
    if type(g) ~= "table" or type(g.character_visual_components) ~= "table" or not scale then return 0, 0 end
    local moved = 0
    local failed = 0
    for _, entry in ipairs(g.character_visual_components) do
        local component = entry and entry.component
        if feature_actor.is_valid_object(component) then
            local ratio = entry.scale_ratio or {}
            local target = {
                X = (scale.X or 1) * (ratio.X or 1),
                Y = (scale.Y or 1) * (ratio.Y or 1),
                Z = (scale.Z or 1) * (ratio.Z or 1),
            }
            local ok_move = component_set_world_scale(component, target, entry)
            if ok_move then moved = moved + 1 else failed = failed + 1 end
        else
            failed = failed + 1
        end
    end
    return moved, failed
end

local function reset_character_visual_components(g, actor_loc, actor_rot, actor_scale)
    if type(g) ~= "table" then return 0, 0 end
    local loc = actor_loc
    local moved, failed = 0, 0
    if loc then
        local m, f = move_character_visual_components(g, loc)
        moved = moved + m
        failed = failed + f
    end
    local rot = actor_rot
    if rot then
        local m, f = rotate_character_visual_components(g, rot)
        moved = moved + m
        failed = failed + f
    end
    local scale = actor_scale
    if scale then
        local m, f = scale_character_visual_components(g, scale)
        moved = moved + m
        failed = failed + f
    end
    return moved, failed
end

local function character_proxy_anchor_from_visuals(g)
    if type(g) ~= "table" or type(g.character_visual_components) ~= "table" then
        return nil, "no visual components"
    end
    local sum = { X = 0, Y = 0, Z = 0 }
    local count = 0
    for _, entry in ipairs(g.character_visual_components) do
        local component = entry and entry.component
        if feature_actor.is_valid_object(component) then
            local loc = component_location(component)
            if loc then
                local offset = entry.offset or {}
                sum.X = sum.X + ((loc.X or 0) - (offset.X or 0))
                sum.Y = sum.Y + ((loc.Y or 0) - (offset.Y or 0))
                sum.Z = sum.Z + ((loc.Z or 0) - (offset.Z or 0))
                count = count + 1
            end
        end
    end
    if count <= 0 then return nil, "no readable visual component locations" end
    return {
        X = sum.X / count,
        Y = sum.Y / count,
        Z = sum.Z / count,
    }, "visual_anchor count=" .. tostring(count)
end

local function try_character_move_method(actor, root, method, loc, rot)
    local hit = {}
    if method == "actor_location" and actor.K2_SetActorLocation then
        local ok_call, result = pcall(function()
            return actor:K2_SetActorLocation(loc, false, hit, false)
        end)
        if ok_call and result ~= false then return true, method end
        return false, method .. "=" .. (ok_call and "false" or tostring(result))
    end
    if method == "root_world_location" and feature_actor.is_valid_object(root) and root.K2_SetWorldLocation then
        local ok_call, result = pcall(function()
            return root:K2_SetWorldLocation(loc, false, hit, false)
        end)
        if ok_call and result ~= false then return true, method end
        return false, method .. "=" .. (ok_call and "false" or tostring(result))
    end
    return false, method .. "=unavailable"
end

local function try_character_final_actor_location(actor, loc)
    if not feature_actor.is_valid_object(actor) or not loc then
        return false, "invalid actor/location"
    end
    feature_actor.force_actor_movable(actor)
    local ok_move, move_detail = feature_actor.move_actor(actor, loc)
    if ok_move then return true, "feature_actor.move_actor" end

    local hit = {}
    if actor.K2_SetActorLocation then
        local ok_call, result = pcall(function()
            return actor:K2_SetActorLocation(loc, false, hit, true)
        end)
        if ok_call and result ~= false then return true, "actor_location_teleport" end
        local first_err = ok_call and "K2_SetActorLocation teleport=true returned false" or tostring(result)
        ok_call, result = pcall(function()
            return actor:K2_SetActorLocation(loc, false, hit, false)
        end)
        if ok_call and result ~= false then return true, "actor_location" end
        return false, tostring(move_detail or "feature_actor.move_actor failed")
            .. "; " .. first_err .. "; " .. (ok_call and "K2_SetActorLocation=false" or tostring(result))
    end
    return false, tostring(move_detail or "feature_actor.move_actor failed")
end

local function apply_character_final_location(g)
    if type(g) ~= "table" or g.character_profile ~= true then return true, "not character" end
    if not feature_actor.is_valid_object(g.actor) then return false, "invalid character actor" end

    local proxy_target, proxy_detail = character_proxy_anchor_from_visuals(g)
    local target = proxy_target or (g.last_dest_valid == true and g.last_dest) or g.dest or g.orig_loc
    if not target then return false, "no final character destination" end
    local wanted = { X = target.X or 0, Y = target.Y or 0, Z = target.Z or 0 }
    local before = feature_actor.actor_location(g.actor)
    local pre_reset_moved, pre_reset_failed = reset_character_visual_components(g, before)
    local ok_move, move_detail = try_character_final_actor_location(g.actor, wanted)
    local after = feature_actor.actor_location(g.actor)
    local delta = loc_delta_len(after, wanted)

    if ok_move and after and delta <= 35.0 then
        local visual_moved, visual_failed = reset_character_visual_components(g, after)
        print(string.format(
            "[RSDWTools] grab.character final apply ok method=%s proxy=%s before=(%.0f,%.0f,%.0f) wanted=(%.0f,%.0f,%.0f) actor=(%.0f,%.0f,%.0f) delta=%.1f pre_reset=%d/%d visual_reset=%d/%d",
            tostring(move_detail),
            tostring(proxy_detail or "fallback"),
            before and before.X or 0, before and before.Y or 0, before and before.Z or 0,
            wanted.X or 0, wanted.Y or 0, wanted.Z or 0,
            after.X or 0, after.Y or 0, after.Z or 0,
            delta,
            pre_reset_moved, pre_reset_failed,
            visual_moved, visual_failed))
        return true, tostring(move_detail)
    end

    local visual_moved, visual_failed = reset_character_visual_components(g, before or after or g.orig_loc)
    print(string.format(
        "[RSDWTools] grab.character final apply refused method=%s proxy=%s ok=%s wanted=(%.0f,%.0f,%.0f) actor=(%.0f,%.0f,%.0f) delta=%.1f pre_reset=%d/%d visual_restore=%d/%d",
        tostring(move_detail),
        tostring(proxy_detail or "fallback"),
        tostring(ok_move),
        wanted.X or 0, wanted.Y or 0, wanted.Z or 0,
        after and after.X or 0, after and after.Y or 0, after and after.Z or 0,
        delta,
        pre_reset_moved, pre_reset_failed,
        visual_moved, visual_failed))
    return false, tostring(move_detail or "final move refused")
end

local function move_grab_actor(g, loc, rot)
    if type(g) ~= "table" or not feature_actor.is_valid_object(g.actor) then
        return false, "invalid grab actor"
    end
    local actor = g.actor
    if g.character_profile == true then
        -- Characters/NPCs are too sensitive for continuous authoritative
        -- actor/root movement. During grab we only drag their known visual
        -- components as a proxy; release attempts one final actor placement.
        local visual_moved, visual_failed = move_character_visual_components(g, loc)
        g.character_move_method = "visual_proxy"
        g.character_visual_moved = visual_moved
        g.character_visual_failed = visual_failed
        if visual_moved > 0 then return true, "visual_proxy" end
        return false, "visual_proxy moved no components"
    end
    return feature_actor.move_actor(actor, loc)
end

local function should_apply_character_move(g)
    if type(g) ~= "table" or g.character_profile ~= true then return true end
    if GRAB_CHARACTER_MOVE_INTERVAL_SECONDS <= 0 then return true end
    local now = os.clock()
    local next_clock = tonumber(g.next_character_move_clock) or 0.0
    if next_clock > 0 and now < next_clock then
        return false
    end
    g.next_character_move_clock = now + GRAB_CHARACTER_MOVE_INTERVAL_SECONDS
    return true
end

local function debug_character_move(g, moved, move_err)
    if type(g) ~= "table" or g.character_profile ~= true then return end
    g.character_move_debug_count = (tonumber(g.character_move_debug_count) or 0) + 1
    local remaining = tonumber(g.character_move_debug_remaining) or 0
    if remaining > 0 then
        g.character_move_debug_remaining = remaining - 1
    elseif (g.character_move_debug_count % 20) ~= 0 then
        return
    end
    local d = g.dest or {}
    local actual = feature_actor.actor_location(g.actor)
    print(string.format(
        "[RSDWTools] grab.character move #%d %s %s method=%s visual=%d/%d dest=(%.0f,%.0f,%.0f) actor=(%.0f,%.0f,%.0f)",
        tonumber(g.character_move_debug_count) or 0,
        moved == false and "failed" or "ok",
        moved == false and tostring(move_err or "unknown") or "",
        tostring(g.character_move_method or "none"),
        tonumber(g.character_visual_moved) or 0,
        tonumber(g.character_visual_failed) or 0,
        d.X or 0, d.Y or 0, d.Z or 0,
        actual and actual.X or 0, actual and actual.Y or 0, actual and actual.Z or 0))
end

local function remember_grab_destination(g)
    if type(g) ~= "table" or not g.dest then return end
    g.last_dest = g.last_dest or { X = 0, Y = 0, Z = 0 }
    g.last_dest.X = g.dest.X or 0
    g.last_dest.Y = g.dest.Y or 0
    g.last_dest.Z = g.dest.Z or 0
    g.last_dest_valid = true
end

local function destination_changed(g)
    if type(g) ~= "table" or not g.dest then return false end
    if g.last_dest_valid ~= true or not g.last_dest then return true end
    return loc_delta_len(g.dest, g.last_dest) >= GRAB_DEST_EPSILON_CM
end

local function should_poll_grab_camera(g)
    if type(g) ~= "table" then return false end
    if g.pending_finish == true then return true end
    local now = os.clock()
    local next_clock = tonumber(g.next_camera_poll_clock) or 0.0
    if next_clock > 0 and now < next_clock then
        grab_diag.idle_camera_skips = (grab_diag.idle_camera_skips or 0) + 1
        return false
    end
    return true
end

local function remember_grab_camera(g, cam_loc, cam_rot)
    if type(g) ~= "table" then return true end
    grab_diag.camera_polls = (grab_diag.camera_polls or 0) + 1
    local now = os.clock()
    local loc_changed = loc_delta_len(cam_loc, g.last_cam_loc) >= GRAB_CAMERA_LOC_EPSILON_CM
    local rot_changed = rot_delta_len(cam_rot, g.last_cam_rot) >= GRAB_CAMERA_ROT_EPSILON_DEG
    g.last_cam_loc = g.last_cam_loc or { X = 0, Y = 0, Z = 0 }
    g.last_cam_loc.X = cam_loc and cam_loc.X or 0
    g.last_cam_loc.Y = cam_loc and cam_loc.Y or 0
    g.last_cam_loc.Z = cam_loc and cam_loc.Z or 0
    g.last_cam_rot = g.last_cam_rot or { Pitch = 0, Yaw = 0, Roll = 0 }
    g.last_cam_rot.Pitch = cam_rot and cam_rot.Pitch or 0
    g.last_cam_rot.Yaw = cam_rot and cam_rot.Yaw or 0
    g.last_cam_rot.Roll = cam_rot and cam_rot.Roll or 0

    if loc_changed or rot_changed then
        g.active_camera_until = now + GRAB_ACTIVE_CAMERA_GRACE_SECONDS
        g.next_camera_poll_clock = 0
        return true
    end
    if now < (tonumber(g.active_camera_until) or 0.0) then
        g.next_camera_poll_clock = 0
        return false
    end
    g.next_camera_poll_clock = now + GRAB_IDLE_CAMERA_POLL_SECONDS
    return false
end

-- ---------- tick body ----------

local function restore_grab_snapshot(g)
    if type(g) ~= "table" or not feature_actor.is_valid_object(g.actor) then return false end
    move_grab_actor(g, g.orig_loc, g.orig_rot)
    feature_actor.set_actor_rotation(g.actor, g.orig_rot)
    if g.orig_scale then
        feature_actor.set_actor_scale3d(g.actor, g.orig_scale)
    end
    return true
end

local function disarm_grab_loop(g)
    if type(g) == "table" then g.loop_armed = false end
    grab_tick_fn = nil
    grab_loop_driver = nil
end

local function schedule_transform_capture(actor, source)
    if not feature_actor.is_valid_object(actor) then return end
    schedule_game_thread(POST_FINISH_CAPTURE_MS, function()
        if not feature_actor.is_valid_object(actor) then return end
        local ok_capture, capture_detail = feature_oculus_transform.capture_actor(actor, source)
        if ok_capture and tostring(capture_detail) == "disabled" then
            return
        elseif ok_capture then
            print("[RSDWTools] " .. tostring(source) .. " transform refreshed")
        else
            print("[RSDWTools] " .. tostring(source) .. " transform capture failed: " .. tostring(capture_detail))
        end
    end)
end

local function schedule_runtime_item_stabilize(actor, name)
    if not feature_actor.is_valid_object(actor) or not feature_inventory._is_runtime_world_item then
        return
    end
    local ok_item, is_item = pcall(function() return feature_inventory._is_runtime_world_item(actor) end)
    if not ok_item or is_item ~= true then return end
    schedule_game_thread(POST_FINISH_STABILIZE_MS, function()
        if not feature_actor.is_valid_object(actor) then return end
        local ok_stable, stable_result = feature_inventory.stabilize_runtime_world_item(actor)
        if ok_stable then
            local actions = stable_result and stable_result.actions or {}
            local failures = stable_result and stable_result.failures or {}
            print(string.format("[RSDWTools] grab.release stabilized runtime item %s actions=%d failures=%d",
                tostring(name), #actions, #failures))
        else
            print("[RSDWTools] grab.release runtime item stabilize failed for " .. tostring(name))
        end
    end)
end

local function read_component_tick_enabled(component)
    if not feature_actor.is_valid_object(component) or not component.IsComponentTickEnabled then
        return nil
    end
    local ok, enabled = pcall(function() return component:IsComponentTickEnabled() end)
    if ok and type(enabled) == "boolean" then return enabled end
    return nil
end

local function set_component_tick_enabled(component, enabled)
    if not feature_actor.is_valid_object(component) or not component.SetComponentTickEnabled then
        return false
    end
    local ok, result = pcall(function() return component:SetComponentTickEnabled(enabled and true or false) end)
    return ok and result ~= false
end

local function get_actor_controller(actor)
    if not feature_actor.is_valid_object(actor) then return nil end
    if actor.GetController then
        local ok, controller = pcall(function() return actor:GetController() end)
        if ok and feature_actor.is_valid_object(controller) then return controller end
    end
    local ok_field, controller = pcall(function() return actor.Controller end)
    if ok_field and feature_actor.is_valid_object(controller) then return controller end
    return nil
end

local function get_brain_component_from_controller(controller)
    if not feature_actor.is_valid_object(controller) then return nil end
    local ok, brain = pcall(function() return controller.BrainComponent end)
    if ok and feature_actor.is_valid_object(brain) then return brain end
    return nil
end

local function get_movement_component(actor)
    if not feature_actor.is_valid_object(actor) then return nil end
    if actor.GetMovementComponent then
        local ok, component = pcall(function() return actor:GetMovementComponent() end)
        if ok and feature_actor.is_valid_object(component) then return component end
    end
    for _, field_name in ipairs({ "AiMovementComponent", "AIMovementComponent", "CharacterMovement", "MovementComponent" }) do
        local ok_field, component = pcall(function() return actor[field_name] end)
        if ok_field and feature_actor.is_valid_object(component) then return component end
    end
    return nil
end

local function get_path_following_component(controller)
    if not feature_actor.is_valid_object(controller) then return nil end
    if controller.GetPathFollowingComponent then
        local ok, component = pcall(function() return controller:GetPathFollowingComponent() end)
        if ok and feature_actor.is_valid_object(component) then return component end
    end
    local ok_field, component = pcall(function() return controller.PathFollowingComponent end)
    if ok_field and feature_actor.is_valid_object(component) then return component end
    return nil
end

local function read_actor_movement_disabled(actor)
    if not feature_actor.is_valid_object(actor) or not actor.IsMovementDisabled then return nil end
    local ok, disabled = pcall(function() return actor:IsMovementDisabled() end)
    if ok and type(disabled) == "boolean" then return disabled end
    return nil
end

local function set_actor_movement_disabled(actor, disabled)
    if not feature_actor.is_valid_object(actor) or not actor.SetMovementDisabled then return false end
    local ok, result = pcall(function() return actor:SetMovementDisabled(disabled and true or false, actor) end)
    return ok and result ~= false
end

local function begin_character_quiet(actor, name)
    if not feature_actor.is_valid_object(actor) then return nil end
    local quiet = {
        actor = actor,
        name = tostring(name or feature_actor.short_name_of(actor) or "<character>"),
        notes = {},
    }
    local controller = get_actor_controller(actor)
    quiet.controller = controller
    if feature_actor.is_valid_object(controller) then
        local ok_stop = pcall(function() return controller:StopMovement() end)
        if ok_stop then quiet.notes[#quiet.notes + 1] = "controller_stop" end
        pcall(function() return controller:K2_ClearFocus() end)
        local brain = get_brain_component_from_controller(controller)
        quiet.brain = brain
        if feature_actor.is_valid_object(brain) and brain.StopLogic then
            local ok_brain = pcall(function() return brain:StopLogic("RSDWTools camera.grab") end)
            if ok_brain then
                quiet.brain_stopped = true
                quiet.notes[#quiet.notes + 1] = "brain_stop"
            end
        end
        local path = get_path_following_component(controller)
        quiet.path = path
        quiet.path_tick = read_component_tick_enabled(path)
        if set_component_tick_enabled(path, false) then
            quiet.path_tick_touched = true
            quiet.notes[#quiet.notes + 1] = "path_tick_off"
        end
    end

    local movement = get_movement_component(actor)
    quiet.movement = movement
    if feature_actor.is_valid_object(movement) then
        local ok_immediate = pcall(function() return movement:StopMovementImmediately() end)
        if ok_immediate then quiet.notes[#quiet.notes + 1] = "movement_stop" end
        pcall(function() return movement:StopMovementKeepPathing() end)
    end

    print("[RSDWTools] grab.character quiet on " .. quiet.name .. " " .. table.concat(quiet.notes, ","))
    return quiet
end

local function restore_character_quiet_now(quiet, reason)
    if type(quiet) ~= "table" then return end
    local notes = {}
    local actor = quiet.actor
    if quiet.movement_disabled_touched and feature_actor.is_valid_object(actor) then
        local restore_disabled = quiet.movement_disabled == true
        if set_actor_movement_disabled(actor, restore_disabled) then
            notes[#notes + 1] = "movement_disabled=" .. tostring(restore_disabled)
        end
    end
    if quiet.movement_tick_touched and feature_actor.is_valid_object(quiet.movement) then
        local restore_tick = quiet.movement_tick
        if restore_tick == nil then restore_tick = true end
        if set_component_tick_enabled(quiet.movement, restore_tick) then
            notes[#notes + 1] = "movement_tick=" .. tostring(restore_tick)
        end
    end
    if quiet.path_tick_touched and feature_actor.is_valid_object(quiet.path) then
        local restore_tick = quiet.path_tick
        if restore_tick == nil then restore_tick = true end
        if set_component_tick_enabled(quiet.path, restore_tick) then
            notes[#notes + 1] = "path_tick=" .. tostring(restore_tick)
        end
    end
    if quiet.brain_stopped and feature_actor.is_valid_object(quiet.brain) then
        local ok_start = false
        if quiet.brain.StartLogic then
            ok_start = pcall(function() return quiet.brain:StartLogic() end)
        end
        if not ok_start and quiet.brain.RestartLogic then
            ok_start = pcall(function() return quiet.brain:RestartLogic() end)
        end
        if ok_start then notes[#notes + 1] = "brain_start" end
    end
    print("[RSDWTools] grab.character quiet off "
        .. tostring(quiet.name or "<character>")
        .. " reason=" .. tostring(reason or "release")
        .. " " .. table.concat(notes, ","))
end

local function schedule_character_quiet_restore(quiet, reason, delay_ms)
    if type(quiet) ~= "table" then return end
    schedule_game_thread(delay_ms or CHARACTER_QUIET_RESTORE_MS, function()
        restore_character_quiet_now(quiet, reason)
    end)
end

local function prepare_runtime_item_for_grab(actor, name, options, context)
    if not is_runtime_world_item_actor(actor) then return end
    options.safe_profile = true
    options.location_only = true
    options.skip_force_movable = true

    if type(feature_inventory.stabilize_runtime_world_item_fast) ~= "function" then return end
    local ok_call, ok_stable, stable_result = pcall(function()
        return feature_inventory.stabilize_runtime_world_item_fast(actor)
    end)
    if not ok_call then
        print("[RSDWTools] grab.runtime pre-stabilize raised for "
            .. tostring(name) .. ": " .. tostring(ok_stable))
        return
    end
    if ok_stable then
        local actions = stable_result and stable_result.actions or {}
        local failures = stable_result and stable_result.failures or {}
        print(string.format("[RSDWTools] grab.runtime pre-stabilized %s context=%s actions=%d failures=%d",
            tostring(name), tostring(context or "grab"), #actions, #failures))
    else
        local err = stable_result and stable_result.error or "stabilize failed"
        print("[RSDWTools] grab.runtime pre-stabilize failed for "
            .. tostring(name) .. ": " .. tostring(err))
    end
end

local function schedule_finish_side_effects(g, kind)
    if type(g) ~= "table" then return end
    local name = tostring(g.name or "<grab>")
    local source = kind == "cancel" and "grab.cancel" or "grab.release"
    local detail = g.finish_detail and (" ; " .. tostring(g.finish_detail)) or ""
    last_grab_finish_clock = os.clock()
    note_modal_settle("grab." .. tostring(kind or "finish"))
    -- Keep release/cancel finalization intentionally tiny. The held actor has
    -- already received its final movement tick; doing runtime-item
    -- stabilization or transform capture from this path has proven too crashy
    -- in Shipping. Those heavier actor reads/writes should be invoked by an
    -- explicit command once placement is stable.
    schedule_help_refresh(POST_FINISH_HELP_MS)
    print("[RSDWTools] " .. source .. " applied: " .. name .. " (post actor work skipped)" .. detail)
end

local function apply_pending_finish(g)
    if type(g) ~= "table" or g.pending_finish ~= true then return false end
    local elapsed = os.clock() - (tonumber(g.pending_finish_clock) or 0.0)
    if elapsed < FINISH_SETTLE_SECONDS then return false end
    local kind = tostring(g.pending_finish_kind or "release")
    if kind == "cancel" then
        restore_grab_snapshot(g)
        g.finish_detail = "cancel restored start transform"
    elseif g.character_profile == true then
        local ok_final, final_detail = apply_character_final_location(g)
        g.finish_detail = ok_final
            and ("character final placement ok: " .. tostring(final_detail))
            or ("character final placement failed: " .. tostring(final_detail))
    end
    schedule_character_quiet_restore(g.character_quiet, kind)
    schedule_finish_side_effects(g, kind)
    return true
end

-- Compute the desired world transform from the camera viewpoint + the
-- per-grab offsets, then push it onto the actor. Returns false on a
-- terminal failure (auto-release on next tick).
local function tick_grab()
    -- Snapshot the upvalue to a local. M.release()/M.cancel() can null
    -- `grab` between the get_camera_viewpoint() call (which marshals
    -- through ExecuteInGameThread) and the subsequent field writes.
    -- Observed in user log 2026-05-15: line "grab.dest.X = ..." crashed
    -- with "attempt to index a nil value (upvalue 'grab')". The local
    -- snapshot keeps this tick consistent even if the upvalue clears
    -- mid-flight ; the loop callback in start_loop() will see the nil
    -- on the next iteration and exit cleanly.
    local g = grab
    if not g then return false end
    grab_diag.ticks = (grab_diag.ticks or 0) + 1
    grab_diag.last_tick_clock = os.clock()
    if g.oculus_started == true then
        local active_now, active_detail = _oculus_is_active()
        if not active_now then
            g.oculus_inactive_frames = (tonumber(g.oculus_inactive_frames) or 0) + 1
            grab_diag.oculus_inactive_reads = (grab_diag.oculus_inactive_reads or 0) + 1
            grab_diag.last_oculus_active_error = tostring(active_detail or "inactive")
            if g.oculus_inactive_frames < GRAB_OCULUS_INACTIVE_CANCEL_FRAMES then
                if g.oculus_inactive_frames == 1 then
                    print("[RSDWTools] grab: Oculus inactive read while grabbed; pausing before cancel "
                        .. tostring(g.name) .. " detail=" .. tostring(active_detail))
                end
                return true
            end
            restore_grab_snapshot(g)
            schedule_character_quiet_restore(g.character_quiet, "oculus_exit", 1)
            grab_diag.auto_cancels = (grab_diag.auto_cancels or 0) + 1
            print("[RSDWTools] grab: Oculus exited while grabbed, safe-cancelled "
                .. tostring(g.name) .. " inactive_frames=" .. tostring(g.oculus_inactive_frames)
                .. " detail=" .. tostring(active_detail))
            return false
        end
        g.oculus_inactive_frames = 0
    end
    local actor = g.actor
    if not feature_actor.is_valid_object(actor) then
        schedule_character_quiet_restore(g.character_quiet, "target_invalid", 1)
        print("[RSDWTools] grab: target invalid, releasing.")
        return false
    end
    if g.pending_finish == true and apply_pending_finish(g) then
        return false
    end
    if (tonumber(g.start_warmup_frames) or 0) > 0 then
        g.start_warmup_frames = g.start_warmup_frames - 1
        return true
    end
    if not should_poll_grab_camera(g) then
        return true
    end
    local cam_loc, cam_rot, err = get_camera_viewpoint()
    if not cam_loc then
        grab_diag.camera_failures = (grab_diag.camera_failures or 0) + 1
        grab_diag.last_camera_error = tostring(err)
        -- Don't release on a single failed read ; the controller can
        -- transiently disappear during view target swaps. Just skip.
        return true
    end
    -- Re-check after the cross-thread call.
    if not grab or grab ~= g then return false end
    remember_grab_camera(g, cam_loc, cam_rot)

    -- Full 3D forward so pitching the camera moves the held actor up
    -- and down along the sight line (oculus feel). z_offset is an
    -- additional vertical nudge applied on top, driven by `z` mode.
    local fx, fy, fz = camera_forward_3d(cam_rot)
    g.dest.X = (cam_loc.X or 0) + fx * g.distance
    g.dest.Y = (cam_loc.Y or 0) + fy * g.distance
    g.dest.Z = (cam_loc.Z or 0) + fz * g.distance + g.z_offset
    clamp_grab_destination_step(g)

    local needs_move = destination_changed(g)
    if needs_move then
        if should_apply_character_move(g) then
            local moved, move_err = move_grab_actor(g, g.dest)
            debug_character_move(g, moved, move_err)
            if moved == false then
                grab_diag.move_failures = (grab_diag.move_failures or 0) + 1
                grab_diag.last_move_error = tostring(move_err)
                -- One failed write isn't fatal -- the engine occasionally
                -- rejects a sweep when the destination collides. Keep going ;
                -- next tick the camera has moved a bit and may succeed.
                if apply_pending_finish(g) then
                    return false
                end
                return true
            end
            remember_grab_destination(g)
        end
    else
        grab_diag.skipped_moves = (grab_diag.skipped_moves or 0) + 1
    end
    if g.location_only ~= true and g.rotation_dirty == true then
        local held_rotation = g.fixed_rotation or g.orig_rot or { Pitch = 0, Yaw = 0, Roll = 0 }
        g.rot.Pitch = held_rotation.Pitch or 0
        g.rot.Yaw = ((held_rotation.Yaw or 0) + g.yaw_offset) % 360.0
        g.rot.Roll = held_rotation.Roll or 0
        if feature_actor.set_actor_rotation(actor, g.rot) then
            g.rotation_dirty = false
            grab_diag.rotation_writes = (grab_diag.rotation_writes or 0) + 1
        else
            grab_diag.rotation_failures = (grab_diag.rotation_failures or 0) + 1
            grab_diag.last_rotation_error = "set_actor_rotation failed"
            g.rotation_dirty = false
        end
    end
    if g.location_only ~= true and g.scale_dirty == true then
        local s = g.scale or 1.0
        if feature_actor.set_actor_scale3d(actor, { X = s, Y = s, Z = s }) then
            g.scale_dirty = false
        end
    end
    if apply_pending_finish(g) then
        return false
    end
    return true
end

local function start_loop()
    if not grab then return end
    if grab.loop_armed and grab_tick_fn ~= nil then return end
    grab.loop_armed = true
    local this_grab = grab
    local function run_step()
        if not grab then
            disarm_grab_loop(this_grab)
            return true
        end
        local ok_tick, keep = pcall(tick_grab)
        if not ok_tick then
            print("[RSDWTools] grab: tick failed: " .. tostring(keep))
            schedule_character_quiet_restore(this_grab and this_grab.character_quiet, "tick_failed", 1)
            grab = nil
            disarm_grab_loop(this_grab)
            hide_grab_overlay()
            return true
        end
        if not keep then
            local finished = grab
            grab = nil
            disarm_grab_loop(finished or this_grab)
            hide_grab_overlay()
            return true
        end
        return false
    end

    if GRAB_USE_ENGINE_TICK == true and EngineTickAvailable == true and type(LoopInGameThreadAfterFrames) == "function" then
        grab_tick_fn = run_step
        grab_loop_driver = "engine_tick"
        if not grab_engine_tick_started then
            local ok, handle_or_err = pcall(function()
                return LoopInGameThreadAfterFrames(1, function()
                    local tick = grab_tick_fn
                    if not tick then
                        if not grab then grab_loop_driver = nil end
                        return
                    end
                    if tick() then
                        grab_tick_fn = nil
                        grab_loop_driver = nil
                    end
                end)
            end)
            if ok and handle_or_err then
                grab_engine_tick_started = true
                return
            end
            print("[RSDWTools] grab: engine tick unavailable: " .. tostring(handle_or_err))
            grab_tick_fn = nil
            grab_loop_driver = nil
        else
            return
        end
    end

    if not LoopAsync then
        print("[RSDWTools] grab: LoopAsync unavailable, cannot tick.")
        disarm_grab_loop(grab)
        return
    end
    grab_loop_driver = "loop_async"
    LoopAsync(GRAB_TICK_MS, run_step)
end

-- ---------- public verbs ----------

-- The game's own interaction system already answers "what is the
-- player looking at right now?" via UInteractableDetectorComponent on
-- the player character. It traces every tick to drive nameplates +
-- the press-to-interact prompt, so we just read its result instead of
-- racing it with our own trace. The detector lives on the live pawn
-- and updates from the active camera viewpoint, so it works in oculus
-- mode too as long as the player character itself is loaded.
--
--   pawn.InteractableDetector.CurrentWorldActor      AActor* (any actor)
--   pawn.InteractableDetector.CurrentInteractable    UInteractionComponent*
--
-- We prefer CurrentWorldActor because nameplates use it (NPCs, animals,
-- buildings, dropped items) ; CurrentInteractable is only set when the
-- thing is also currently interactable, which is a stricter set.
local function _detector_pick()
    local pawn = feature_actor.get_local_pawn()
    if not feature_actor.is_valid_object(pawn) then return nil end
    local det = nil
    local ok, getter = pcall(function() return pawn.GetInteractableDetector end)
    if ok and getter then
        local ok2, d = pcall(function() return pawn:GetInteractableDetector() end)
        if ok2 then det = d end
    end
    if not feature_actor.is_valid_object(det) then
        local ok3, d = pcall(function() return pawn.InteractableDetector end)
        if ok3 then det = d end
    end
    if not feature_actor.is_valid_object(det) then return nil end
    local ok4, a = pcall(function() return det.CurrentWorldActor end)
    if ok4 and feature_actor.is_valid_object(a) then return a end
    -- Fall back to CurrentInteractable's owner (UInteractionComponent
    -- is a UActorComponent, so its owner is the world actor).
    local ok5, ic = pcall(function() return det.CurrentInteractable end)
    if ok5 and feature_actor.is_valid_object(ic) and ic.GetOwner then
        local ok6, owner = pcall(function() return ic:GetOwner() end)
        if ok6 and feature_actor.is_valid_object(owner) then return owner end
    end
    return nil
end

-- True if the player is currently flying around in the oculus freecam.
-- Detector reads should be SKIPPED in that case: the detector runs on
-- the (hidden) player character, so its CurrentWorldActor reflects
-- "what the player char is looking at", not the freecam reticle.
_oculus_is_active = function()
    local feature_oculus = package.loaded["feature_oculus"]
    if type(feature_oculus) == "table" and type(feature_oculus.require_state) == "function" then
        local ok_require, active_ok, detail = pcall(function()
            return feature_oculus.require_state("active")
        end)
        if ok_require then
            if active_ok == true then return true, tostring(detail or "feature_oculus.require_state") end
            if active_ok == false then
                -- Fall through to the direct pawn flag below; it is cheap
                -- and gives grab a second opinion during state handoffs.
            end
        end
    end

    local opawn = (function()
        local p, _ = feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
        return p
    end)()
    if not feature_actor.is_valid_object(opawn) then return false, "no OculusPawn" end
    local ok, v = pcall(function() return opawn.bOculusActive end)
    if ok and v == true then return true, "OculusPawn.bOculusActive" end
    if not ok then return false, "OculusPawn.bOculusActive read failed" end
    return false, "OculusPawn.bOculusActive=false"
end

local function _prefer_detector_pick()
    if _oculus_is_active() then return false end
    if feature_camera.is_debug_camera_active and feature_camera.is_debug_camera_active() then
        return false
    end
    return true
end

local function resolve_grab_target(name)
    local actor, picked_name, source, loc
    if name and name ~= "" then
        actor = feature_actor.resolve_actor_by_name(name)
        if not actor then return nil, nil, nil, nil, "actor not found: " .. tostring(name) end
        picked_name = name
        source = "name"
        loc = feature_actor.actor_location(actor)
        return actor, picked_name, source, loc, nil
    end

    -- Prefer the game's interaction detector when the player char is in
    -- control ; in oculus mode the detector is irrelevant (it is tied to
    -- the hidden player char), so trace directly.
    local picked = nil
    if _prefer_detector_pick() then
        picked = _detector_pick()
        if picked then source = "detector" end
    end
    if not picked then
        local hit_actor, impact, terr = _trace_from_camera(LOOKAT_MAX_DISTANCE)
        local item_actor, item_loc, item_source = pick_world_item_candidate({ trace_impact = impact })
        if item_actor then
            picked = item_actor
            source = item_source
            loc = item_loc
        elseif hit_actor then
            picked = hit_actor
            source = "trace"
            loc = impact
        else
            return nil, nil, nil, nil, "lookat: " .. tostring(terr)
        end
    end

    actor = picked
    picked_name = feature_actor.short_name_of(actor) or "<unnamed>"
    loc = loc or feature_actor.actor_location(actor)
    return actor, picked_name, source or "unknown", loc, nil
end

-- camera.grab.start [<name>]
--
-- With <name>: resolve via feature_actor by exact short name (same path
-- used by every other actor.* verb).
-- Without <name>: ask the game's interaction detector first, then fall
-- back to a forward line trace. The local pawn and the oculus pawn
-- are always excluded from the trace so we never grab ourselves.
-- Internal : begin a grab session given a fully-resolved (actor, name)
-- pair. All public M.start* entries funnel through here so the static-
-- class block, transform seeding and grab-state allocation only live
-- in one place. Returns the same (ok, detail) tuple as M.start.
local function _begin_grab(actor, picked_name, options)
    options = options or {}
    local target_is_character = is_character_like_actor(actor)
    -- Round 67: the DebugCamera editor probe proved the stable grab shape is
    -- "prepare once, then write location only while held". Make normal Oculus
    -- grab follow that same minimal path for every actor type, including NPCs.
    -- Rotation/Scale modes remain the intended way to edit non-location
    -- transforms.
    options.location_only = true
    local character_profile = false
    -- Round 62+: forbid grabbing world-static / foliage / building-piece
    -- actors. These are engine-owned placement/world objects; moving them
    -- outside their native systems can desync collision, nav, placement or
    -- persistence state. Match on cheap actor properties and names rather
    -- than walking class ancestry, which has been unsafe in this UE4SS build.
    if grab_safety_enabled then
        local blocked_kind, blocked_detail = grab_block_reason(actor)
        if blocked_kind then
            return false, string.format(
                "refusing to grab '%s' : target is %s (%s) and is unsafe to move with camera.grab ; use camera.grab.safety off to bypass",
                tostring(picked_name), tostring(blocked_kind), tostring(blocked_detail))
        end
    end

    local cam_loc, cam_rot, cerr = get_camera_viewpoint()
    if not cam_loc then return false, "camera unavailable: " .. tostring(cerr) end

    local orig_loc = feature_actor.actor_location(actor) or
                     { X = cam_loc.X, Y = cam_loc.Y, Z = cam_loc.Z }
    local orig_rot = feature_actor.actor_rotation(actor) or
                     { Pitch = 0, Yaw = 0, Roll = 0 }
    local fixed_rotation = nil
    if options.fixed_rotation then
        fixed_rotation = {
            Pitch = options.fixed_rotation.Pitch or options.fixed_rotation.pitch or 0,
            Yaw   = options.fixed_rotation.Yaw   or options.fixed_rotation.yaw   or 0,
            Roll  = options.fixed_rotation.Roll  or options.fixed_rotation.roll  or 0,
        }
    end

    -- Seed distance/z so the actor doesn't snap on the first tick.
    -- New (3D-forward) model: distance is the projection of the
    -- camera->actor vector onto the camera's forward unit vector, and
    -- z_offset captures whatever residual vertical remains after that
    -- projection (so actors slightly off the sight line don't pop to
    -- the centre when grabbed). Yaw offset starts at zero.
    local dx = (orig_loc.X or 0) - (cam_loc.X or 0)
    local dy = (orig_loc.Y or 0) - (cam_loc.Y or 0)
    local dz = (orig_loc.Z or 0) - (cam_loc.Z or 0)
    local fx, fy, fz = camera_forward_3d(cam_rot)
    local proj = dx * fx + dy * fy + dz * fz
    if proj < 50.0 then proj = DEFAULT_DISTANCE end
    local z_residual = dz - fz * proj
    if options.center_on_reticle then
        z_residual = 0.0
    end
    local horiz = proj

    local begin_diag = target_is_character
        and target_light_line(actor, options.source or "unknown", orig_loc)
        or target_diagnostic_line(actor, options.source or "unknown", orig_loc)
    print("[RSDWTools] grab.begin " .. begin_diag
        .. string.format(" safe=%s location_only=%s skip_movable=%s",
            tostring(options.safe_profile == true),
            tostring(options.location_only == true),
            tostring(options.skip_force_movable == true)))
    if target_is_character then
        print("[RSDWTools] grab.begin simple character location-only path for " .. tostring(picked_name))
    end

    if options.skip_force_movable == true then
        print("[RSDWTools] grab.begin skipping force_actor_movable for " .. tostring(picked_name))
    else
        local ok_force, force_err = pcall(function() feature_actor.force_actor_movable(actor) end)
        if not ok_force then
            print("[RSDWTools] grab.begin force_actor_movable failed: " .. tostring(force_err))
        end
    end

    local character_quiet = nil
    local character_visual_components = nil

    local cur_scale = feature_actor.get_actor_scale3d(actor)
        or { X = 1, Y = 1, Z = 1 }
    local uniform = ((cur_scale.X or 1) + (cur_scale.Y or 1) + (cur_scale.Z or 1)) / 3.0

    grab_diag.ticks = 0
    grab_diag.camera_failures = 0
    grab_diag.move_failures = 0
    grab_diag.clamped_steps = 0
    grab_diag.rotation_writes = 0
    grab_diag.rotation_failures = 0
    grab_diag.camera_polls = 0
    grab_diag.idle_camera_skips = 0
    grab_diag.skipped_moves = 0
    grab_diag.oculus_inactive_reads = 0
    grab_diag.last_tick_clock = 0
    grab_diag.last_camera_error = nil
    grab_diag.last_move_error = nil
    grab_diag.last_rotation_error = nil
    grab_diag.last_oculus_active_error = nil

    grab = {
        actor      = actor,
        name       = picked_name,
        orig_loc   = { X = orig_loc.X or 0, Y = orig_loc.Y or 0, Z = orig_loc.Z or 0 },
        orig_rot   = {
            Pitch = orig_rot.Pitch or 0,
            Yaw   = orig_rot.Yaw or 0,
            Roll  = orig_rot.Roll or 0,
        },
        orig_scale = (not character_profile) and {
            X = cur_scale.X or 1,
            Y = cur_scale.Y or 1,
            Z = cur_scale.Z or 1,
        } or nil,
        oculus_started = _oculus_is_active() == true,
        distance   = horiz,
        z_offset   = z_residual,
        yaw_offset = 0.0,
        scale      = uniform,
        scale_dirty = false,
        rotation_dirty = false,
        mode       = "move",
        dest       = { X = 0, Y = 0, Z = 0 },
        rot        = fixed_rotation and {
            Pitch = fixed_rotation.Pitch,
            Yaw = fixed_rotation.Yaw,
            Roll = fixed_rotation.Roll,
        } or {
            Pitch = orig_rot.Pitch or 0,
            Yaw = orig_rot.Yaw or 0,
            Roll = orig_rot.Roll or 0,
        },
        last_dest = { X = orig_loc.X or 0, Y = orig_loc.Y or 0, Z = orig_loc.Z or 0 },
        last_dest_valid = true,
        last_cam_loc = { X = cam_loc.X or 0, Y = cam_loc.Y or 0, Z = cam_loc.Z or 0 },
        last_cam_rot = {
            Pitch = cam_rot.Pitch or 0,
            Yaw = cam_rot.Yaw or 0,
            Roll = cam_rot.Roll or 0,
        },
        next_camera_poll_clock = 0,
        next_character_move_clock = 0,
        character_move_method = nil,
        character_visual_components = character_visual_components,
        character_visual_moved = 0,
        character_visual_failed = 0,
        character_move_debug_count = 0,
        character_move_debug_remaining = character_profile and 8 or 0,
        active_camera_until = 0,
        start_warmup_frames = character_profile
            and GRAB_CHARACTER_START_WARMUP_FRAMES
            or GRAB_START_WARMUP_FRAMES,
        character_profile = character_profile,
        character_quiet = character_quiet,
        fixed_rotation = fixed_rotation,
        location_only = options.location_only == true,
        safe_profile = options.safe_profile == true,
        loop_armed = false,
        pending_finish = false,
        pending_finish_kind = nil,
        pending_finish_clock = 0,
        last_finish_hotkey_clock = 0,
        oculus_inactive_frames = 0,
    }
    start_loop()
    update_grab_overlay(true)
    return true, string.format("grabbed %s @ dist=%.0f z=%.0f", picked_name, horiz, z_residual)
end

-- camera.grab.start [<name>]
--
-- With <name>: resolve via feature_actor by exact short name (same path
-- used by every other actor.* verb).
-- Without <name>: ask the game's interaction detector first, then fall
-- back to a forward line trace. The local pawn and the oculus pawn
-- are always excluded from the trace so we never grab ourselves.
function M.start(name)
    if grab then
        return false, "already grabbing " .. tostring(grab.name) .. " ; release first"
    end
    local cooldown = restart_cooldown_message()
    if cooldown then return false, cooldown end
    -- Round 62: require oculus freecam to be active before allowing
    -- a grab to start. The grab pipeline anchors the actor to the
    -- camera viewpoint each tick ; outside oculus mode that viewpoint
    -- is the player char's own camera, which means the grabbed actor
    -- floats in front of the player and rides their head movement.
    -- Forcing oculus-only avoids that footgun and keeps grab semantics
    -- aligned with the freecam workflow it was designed for.
    if not _oculus_is_active() then
        return false, "camera.grab.start requires oculus freecam to be active"
    end

    local actor, picked_name, source, _loc, err = resolve_grab_target(name)
    if not feature_actor.is_valid_object(actor) then return false, tostring(err or "actor not found") end
    return _begin_grab(actor, picked_name, { source = source })
end

local function begin_pending_safe_grab(token)
    local pending = pending_grab
    if not pending or pending.token ~= token then return end
    pending_grab = nil
    if grab then
        print("[RSDWTools] grab.safe skipped: already grabbing " .. tostring(grab.name))
        return
    end
    if not feature_actor.is_valid_object(pending.actor) then
        print("[RSDWTools] grab.safe failed: pending target invalid " .. tostring(pending.name))
        _toast("Safe grab failed: target lost", 2.0)
        schedule_help_refresh(1)
        return
    end
    local ok, result_ok, result_detail = pcall(function()
        local options = { source = pending.source }
        prepare_runtime_item_for_grab(pending.actor, pending.name, options, "safe")
        return _begin_grab(pending.actor, pending.name, options)
    end)
    if not ok then
        print("[RSDWTools] grab.safe raised: " .. tostring(result_ok))
        _toast("Safe grab failed", 2.0)
        schedule_help_refresh(1)
        return
    end
    if result_ok then
        print("[RSDWTools] grab.safe started: " .. tostring(result_detail))
    else
        print("[RSDWTools] grab.safe failed: " .. tostring(result_detail))
        _toast("Safe grab failed: " .. tostring(result_detail), 2.0)
        schedule_help_refresh(1)
    end
end

function M.start_safe(name)
    if grab then
        return false, "already grabbing " .. tostring(grab.name) .. " ; release first"
    end
    local cooldown = restart_cooldown_message()
    if cooldown then return false, cooldown end
    if pending_grab then
        return false, "safe grab already pending " .. tostring(pending_grab.name)
    end
    if not _oculus_is_active() then
        return false, "camera.grab.start_safe requires oculus freecam to be active"
    end

    local actor, picked_name, source, loc, err = resolve_grab_target(name)
    if not feature_actor.is_valid_object(actor) then return false, tostring(err or "actor not found") end

    local diag = is_character_like_actor(actor)
        and target_light_line(actor, source, loc)
        or target_diagnostic_line(actor, source, loc)
    print("[RSDWTools] grab.safe probe " .. diag)
    pending_grab_token = pending_grab_token + 1
    local token = pending_grab_token
    pending_grab = {
        token = token,
        actor = actor,
        name = picked_name,
        source = source,
    }

    local function run()
        begin_pending_safe_grab(token)
    end

    if LoopAsync then
        LoopAsync(SAFE_GRAB_DELAY_MS, function()
            if ExecuteInGameThread then
                ExecuteInGameThread(run)
            else
                run()
            end
            return true
        end)
    else
        run()
    end

    return true, string.format("queued safe grab in %dms; %s", SAFE_GRAB_DELAY_MS, diag)
end

function M.start_item()
    if grab then
        return false, "already grabbing " .. tostring(grab.name) .. " ; release first"
    end
    local cooldown = restart_cooldown_message()
    if cooldown then return false, cooldown end
    if not _oculus_is_active() then
        return false, "camera.grab.item requires oculus freecam to be active"
    end
    local actor, _loc, _source, err = pick_world_item_candidate({ force = true })
    if not feature_actor.is_valid_object(actor) then
        return false, tostring(err or "no runtime world item near reticle")
    end
    local picked_name = feature_actor.short_name_of(actor) or "<unnamed item>"
    local options = { source = "trace.item" }
    prepare_runtime_item_for_grab(actor, picked_name, options, "item")
    return _begin_grab(actor, picked_name, options)
end

function M.toggle_item()
    if grab then
        return M.release()
    end
    return M.start_item()
end

-- camera.grab.lastspawned
--
-- Grab whichever actor world.spawn / world.spawn.item most recently
-- produced. Resolves through the `lastspawned` reach root in
-- feature_field, so it auto-clears if the actor has been destroyed
-- since the spawn. Same oculus-required guard as M.start ; the
-- intended workflow is "fly around in oculus, spawn at reticle, then
-- nudge the new actor into precise position before releasing".
local function start_lastspawned_with_options(options)
    options = options or {}
    if grab then
        return false, "already grabbing " .. tostring(grab.name) .. " ; release first"
    end
    local cooldown = restart_cooldown_message()
    if cooldown then return false, cooldown end
    if not _oculus_is_active() then
        return false, "camera.grab.lastspawned requires oculus freecam to be active"
    end
    local actor, rerr = feature_field.resolve_root("lastspawned")
    if not actor then
        return false, "no lastspawned actor (or it has been destroyed): " .. tostring(rerr)
    end
    local picked_name = feature_actor.short_name_of(actor) or "lastspawned"
    prepare_runtime_item_for_grab(actor, picked_name, options, "lastspawned")
    if options and options.scale then
        local ok_scale = feature_actor.set_actor_scale3d(actor, options.scale)
        if not ok_scale then
            return false, "spawned actor found, but source scale copy failed"
        end
    end
    if options and options.rotation then
        local ok_rot = feature_actor.set_actor_rotation(actor, options.rotation)
        if not ok_rot then
            return false, "spawned actor found, but source rotation copy failed"
        end
    end
    return _begin_grab(actor, picked_name, options)
end

function M.start_actor_preserving_transform(actor, rotation, scale, options)
    options = options or {}
    if grab then
        return false, "already grabbing " .. tostring(grab.name) .. " ; release first"
    end
    if options.bypass_cooldown ~= true then
        local cooldown = restart_cooldown_message()
        if cooldown then return false, cooldown end
    end
    if not _oculus_is_active() then
        return false, "camera.grab.start_actor_preserving_transform requires oculus freecam to be active"
    end
    if not feature_actor.is_valid_object(actor) then
        return false, "actor is no longer valid"
    end

    local picked_name = feature_actor.short_name_of(actor) or "spawned actor"
    prepare_runtime_item_for_grab(actor, picked_name, options, options.context or "deferred_clone")
    if scale then
        local ok_scale = feature_actor.set_actor_scale3d(actor, scale)
        if not ok_scale then
            return false, "spawned actor found, but source scale copy failed"
        end
    end
    if rotation then
        local ok_rot = feature_actor.set_actor_rotation(actor, rotation)
        if not ok_rot then
            return false, "spawned actor found, but source rotation copy failed"
        end
    end
    return _begin_grab(actor, picked_name, options)
end

function M.start_lastspawned()
    return start_lastspawned_with_options({ center_on_reticle = true })
end

function M.start_lastspawned_preserving_transform(rotation, scale)
    return start_lastspawned_with_options({
        rotation = rotation,
        scale = scale,
        fixed_rotation = rotation,
    })
end

local function pick_target_under_reticle()
    local actor, source, impact = nil, nil, nil
    if _prefer_detector_pick() then
        actor = _detector_pick()
        if actor then source = "detector" end
    end
    if not actor then
        local hit_actor, hit_impact, err = _trace_from_camera(LOOKAT_MAX_DISTANCE)
        local item_actor, item_loc, item_source = pick_world_item_candidate({ trace_impact = hit_impact })
        if item_actor then
            actor = item_actor
            impact = item_loc
            source = item_source
        elseif hit_actor then
            actor = hit_actor
            impact = hit_impact
            source = "trace"
        else
            return nil, nil, nil, "no actor under reticle (trace: " .. tostring(err) .. ")"
        end
    end
    local loc = impact or feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 }
    return actor, loc, source, nil
end

local function pick_trace_target_under_reticle()
    if _prefer_detector_pick() then
        local actor = _detector_pick()
        if feature_actor.is_valid_object(actor) then
            return actor, feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 }, "detector", nil
        end
    end
    local hit_actor, hit_impact, err = _trace_from_camera(LOOKAT_MAX_DISTANCE)
    if feature_actor.is_valid_object(hit_actor) then
        return hit_actor, hit_impact or feature_actor.actor_location(hit_actor) or { X = 0, Y = 0, Z = 0 }, "trace", nil
    end
    return nil, hit_impact, nil, "no actor under reticle (trace: " .. tostring(err) .. ")"
end

local function pick_location_under_reticle()
    if _prefer_detector_pick() then
        local actor = _detector_pick()
        if feature_actor.is_valid_object(actor) then
            return actor, feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 }, "detector", nil
        end
    end
    local hit_actor, hit_impact, err = _trace_from_camera(LOOKAT_MAX_DISTANCE)
    if feature_actor.is_valid_object(hit_actor) then
        return hit_actor, hit_impact or feature_actor.actor_location(hit_actor) or { X = 0, Y = 0, Z = 0 }, "trace", nil
    end
    if hit_impact then
        return nil, hit_impact, "trace.geometry", err
    end
    return nil, nil, nil, "no location under reticle (trace: " .. tostring(err) .. ")"
end

-- camera.lookat -- pure read-only "what's the camera pointed at?".
-- Source priority:
--   1. Detector (player-char path) -- only when NOT in oculus mode,
--      because the detector traces from the player character itself.
--   2. KismetSystemLibrary line trace from the active camera viewpoint
--      (which becomes the oculus pawn's camera while flying around).
function M.lookat()
    local actor, loc, source, err = pick_target_under_reticle()
    if not actor then return false, err end
    local short = feature_actor.short_name_of(actor) or "<unnamed>"
    local class = feature_field.class_name_of(actor) or "<unknown>"
    -- Toast a tidy label (engine `_UAID_*` suffix stripped) so the
    -- player can glance at the screen and know what their reticle is
    -- on without alt-tabbing to the bridge log.
    _toast(_label_for(actor), 1.5)
    local ok_capture, capture_detail = feature_oculus_transform.capture_actor(actor, source)
    if not ok_capture then
        print("[RSDWTools] camera.lookat transform capture failed: " .. tostring(capture_detail))
    end
    return true, string.format(
        "%s [class=%s, src=%s] @ (%.0f, %.0f, %.0f)",
        short, class, source, loc.X or 0, loc.Y or 0, loc.Z or 0
    )
end

function M.lookat_item()
    local actor, loc, source, err = pick_world_item_candidate({ force = true })
    if not actor then return false, err end
    local short = feature_actor.short_name_of(actor) or "<unnamed>"
    local class = feature_field.class_name_of(actor) or "<unknown>"
    _toast(_label_for(actor), 1.5)
    local ok_capture, capture_detail = feature_oculus_transform.capture_actor(actor, source)
    if not ok_capture then
        print("[RSDWTools] camera.lookat.item transform capture failed: " .. tostring(capture_detail))
    end
    return true, string.format(
        "%s [class=%s, src=%s] @ (%.0f, %.0f, %.0f)",
        short, class, source, loc.X or 0, loc.Y or 0, loc.Z or 0
    )
end

function M.pick_target_under_reticle()
    return pick_target_under_reticle()
end

function M.probe(name)
    local actor, picked_name, source, loc, err = resolve_grab_target(name)
    if not feature_actor.is_valid_object(actor) then return false, tostring(err or "no actor under reticle") end
    local detail = target_diagnostic_line(actor, source, loc)
    print("[RSDWTools] camera.grab.probe " .. detail)
    _toast("Probe: " .. _label_for(actor), 1.5)
    return true, detail .. " picked=" .. tostring(picked_name)
end

function M.destroy_lookat()
    local build_access = require("feature_build_access")
    local targeted = build_access.targeted_piece()
    if targeted then return build_access.destroy_targeted(targeted) end
    local actor, loc, source, err = pick_target_under_reticle()
    if not feature_actor.is_valid_object(actor) then return false, tostring(err or "no actor under reticle") end

    local pawn = feature_actor.get_local_pawn()
    if feature_actor.is_valid_object(pawn) and actor == pawn then
        return false, "refusing to destroy local player pawn"
    end
    local opawn = get_oculus_pawn_safe()
    if feature_actor.is_valid_object(opawn) and actor == opawn then
        return false, "refusing to destroy oculus pawn"
    end

    local label = _label_for(actor)
    local short = feature_actor.short_name_of(actor) or "<unnamed>"
    local class = feature_field.class_name_of(actor) or "<unknown>"
    local building_index
    pcall(function() building_index = actor.BuildingPieceDataIndex end)
    if type(building_index) == "number" or class:find("BuildingManager", 1, true)
        or class:find("Lightweight", 1, true) or short:find("BuildingManager", 1, true) then
        return false, "building target unresolved; refusing actor destruction. Aim in Repair mode and run compat.buildings"
    end
    if looks_like_tree_destroy_target(actor) then
        local ok_tree, tree_detail = destroy_tree_under_reticle()
        if ok_tree then
            _toast("Destroyed tree: " .. label, 1.5)
            return true, "foliage tree destroy: " .. tostring(tree_detail)
        end
        print("[RSDWTools] camera.destroy.lookat foliage fallback failed: " .. tostring(tree_detail))
    end
    if grab and grab.actor == actor then
        local old_grab = grab
        schedule_character_quiet_restore(old_grab.character_quiet, "destroy_lookat", 1)
        grab = nil
        disarm_grab_loop(old_grab)
        hide_grab_overlay()
    end
    if not _destroy_actor(actor) then return false, "destroy failed: " .. tostring(short) end
    _toast("Destroyed: " .. label, 1.5)
    return true, string.format("%s [class=%s, src=%s] @ (%.0f, %.0f, %.0f)",
        short, class, tostring(source), loc.X or 0, loc.Y or 0, loc.Z or 0)
end

-- camera.grab.release   -- drop in place
local function queue_finish(kind)
    if not grab then return false, "not grabbing anything" end
    local g = grab
    local now = os.clock()
    local last = tonumber(g.last_finish_hotkey_clock) or 0.0
    if g.pending_finish == true then
        return true, tostring(g.pending_finish_kind or "finish") .. " already queued " .. tostring(g.name)
    end
    if (now - last) < FINISH_HOTKEY_DEBOUNCE_SECONDS then
        return true, "finish already queued " .. tostring(g.name)
    end
    g.last_finish_hotkey_clock = now
    g.pending_finish = true
    g.pending_finish_kind = kind == "cancel" and "cancel" or "release"
    g.pending_finish_clock = now
    update_grab_overlay(true)
    return true, tostring(g.pending_finish_kind) .. " queued " .. tostring(g.name)
end

function M.release()
    return queue_finish("release")
end

-- camera.grab.toggle [<name>] -- one verb, two behaviors. If something
-- is currently grabbed, drop it (release). Otherwise start a new grab
-- using the same name-resolution / detector path as camera.grab.start.
-- Lets a single hotkey serve as "pick up / put down".
function M.toggle(name)
    if grab then
        return M.release()
    end
    return M.start(name)
end

function M.toggle_safe(name)
    if grab then
        return M.release()
    end
    if pending_grab then
        local name_pending = pending_grab.name
        pending_grab_token = pending_grab_token + 1
        pending_grab = nil
        schedule_help_refresh(1)
        return true, "cancelled pending safe grab " .. tostring(name_pending)
    end
    return M.start_safe(name)
end

-- camera.grab.cancel    -- drop and restore start transform
function M.cancel()
    return queue_finish("cancel")
end

local function cancel_now(reason)
    if not grab then return false, "not grabbing anything" end
    local name = grab.name
    local old_grab = grab
    restore_grab_snapshot(old_grab)
    schedule_character_quiet_restore(old_grab.character_quiet, tostring(reason or "cancel"), 1)
    grab = nil
    disarm_grab_loop(old_grab)
    last_grab_finish_clock = os.clock()
    hide_grab_overlay()
    schedule_help_refresh(1)
    return true, "cancelled " .. name .. " (restored; " .. tostring(reason or "now") .. ")"
end

function M.safe_cancel()
    if pending_grab then
        local name_pending = pending_grab.name
        pending_grab_token = pending_grab_token + 1
        pending_grab = nil
        schedule_help_refresh(1)
        return true, "cancelled pending safe grab " .. tostring(name_pending)
    end
    if not grab then return true, "not grabbing" end
    return cancel_now("safe_cancel")
end

-- camera.grab.mode <move|rot|z|scale>
local VALID_MODES = { move = true, rot = true, z = true, scale = true }
function M.mode(mode_str)
    if not grab then return false, "not grabbing" end
    local m = tostring(mode_str or ""):lower()
    if not VALID_MODES[m] then
        return false, "mode must be one of: move, rot, z, scale"
    end
    grab.mode = m
    update_grab_overlay(true)
    return true, "mode=" .. m
end

-- camera.grab.safety <on|off|toggle|status>
--
-- Runtime-only safety switch. Default is ON on script load, which keeps the
-- historical block list for building pieces, landscape/static world actors,
-- foliage, and BPP_ placement actors. Turning it OFF lets camera.grab start on
-- those targets until the user turns it back ON or the script reloads.
function M.safety(mode_str)
    local mode = trim(mode_str):lower()
    if mode == "" or mode == "status" then
        return true, "safety=" .. grab_safety_label() .. "; blocked=building_piece,staticmeshactor,landscapeproxy,instancedfoliageactor,bpp_"
    end
    if mode == "toggle" then
        grab_safety_enabled = not grab_safety_enabled
    elseif mode == "on" or mode == "true" or mode == "1" or mode == "safe" then
        grab_safety_enabled = true
    elseif mode == "off" or mode == "false" or mode == "0" or mode == "unsafe" or mode == "allow" or mode == "allow_all" then
        grab_safety_enabled = false
    else
        return false, "usage: camera.grab.safety <on|off|toggle|status>"
    end

    if grab_safety_enabled then
        return true, "safety=on; camera.grab blocks unsafe world/static targets"
    end
    return true, "safety=off; camera.grab target blocks bypassed"
end

-- Shared target safety gate for Oculus tools that mutate actor transforms
-- without entering a normal camera.grab session. It intentionally follows the
-- same runtime toggle and block list as camera.grab so the user only has one
-- safety switch to understand.
function M.validate_target_safety(actor, action_label)
    if not feature_actor.is_valid_object(actor) then return false, "invalid target" end
    if not grab_safety_enabled then return true, "safety=off" end

    local blocked_kind, blocked_detail = grab_block_reason(actor)
    if not blocked_kind then return true, "safety=on" end

    local name = feature_actor.short_name_of(actor) or "<unnamed>"
    local action = tostring(action_label or "modify")
    return false, string.format(
        "refusing to %s '%s' : target is %s (%s) and is unsafe for Oculus transform modes ; use camera.grab.safety off to bypass",
        action, tostring(name), tostring(blocked_kind), tostring(blocked_detail))
end

function M.is_character_like(actor)
    return is_character_like_actor(actor)
end

function M.capture_visual_proxy(actor, origin_loc, origin_rot, origin_scale)
    if not feature_actor.is_valid_object(actor) then return nil, "invalid actor" end
    origin_loc = origin_loc or feature_actor.actor_location(actor)
    origin_rot = origin_rot or feature_actor.actor_rotation(actor)
    origin_scale = origin_scale or feature_actor.get_actor_scale3d(actor)
    local components = capture_character_visual_components(actor, origin_loc, origin_rot, origin_scale)
    if type(components) ~= "table" or #components <= 0 then
        return nil, "no visual components"
    end
    return {
        actor = actor,
        character_visual_components = components,
    }, "components=" .. tostring(#components)
end

function M.move_visual_proxy(proxy, loc)
    return move_character_visual_components(proxy, loc)
end

function M.rotate_visual_proxy(proxy, rot)
    return rotate_character_visual_components(proxy, rot)
end

function M.scale_visual_proxy(proxy, scale)
    return scale_character_visual_components(proxy, scale)
end

function M.reset_visual_proxy(proxy, actor_loc, actor_rot, actor_scale)
    return reset_character_visual_components(proxy, actor_loc, actor_rot, actor_scale)
end

-- camera.grab.steps [distanceCm zCm yawDeg scaleDelta minScale maxScale]
-- Runtime-tunable wheel/step behavior. Oculus init can set these from
-- oculus.json without changing every individual wheel command binding.
function M.steps(args_str)
    local parts = {}
    for part in tostring(args_str or ""):gmatch("%S+") do parts[#parts + 1] = part end
    if #parts == 0 then return true, steps_line() end
    if #parts ~= 6 then
        return false, "usage: camera.grab.steps [distanceCm zCm yawDeg scaleDelta minScale maxScale]"
    end

    local distance, err = parse_positive(parts[1], "distanceCm")
    if not distance then return false, err end
    local z, z_err = parse_positive(parts[2], "zCm")
    if not z then return false, z_err end
    local yaw, yaw_err = parse_positive(parts[3], "yawDeg")
    if not yaw then return false, yaw_err end
    local scale, scale_err = parse_positive(parts[4], "scaleDelta")
    if not scale then return false, scale_err end
    local min_scale, min_err = parse_positive(parts[5], "minScale")
    if not min_scale then return false, min_err end
    local max_scale, max_err = parse_positive(parts[6], "maxScale")
    if not max_scale then return false, max_err end
    if min_scale > max_scale then
        return false, "minScale must be <= maxScale"
    end

    STEP_DISTANCE = distance
    STEP_Z = z
    STEP_ROT_DEG = yaw
    STEP_SCALE = scale
    SCALE_MIN = min_scale
    SCALE_MAX = max_scale
    return true, steps_line()
end

-- camera.grab.delta <signed_number>
-- Applies one wheel-tick of input to the active mode.
function M.delta(delta_str)
    if not grab then return false, "not grabbing" end
    local d = tonumber(delta_str)
    if not d or d == 0 then return false, "delta must be a non-zero number" end

    if grab.mode == "move" then
        grab.distance = math.max(50.0, grab.distance + d * STEP_DISTANCE)
        return true, string.format("distance=%.0f", grab.distance)
    elseif grab.mode == "z" then
        grab.z_offset = grab.z_offset + d * STEP_Z
        return true, string.format("z_offset=%.0f", grab.z_offset)
    elseif grab.mode == "rot" then
        if grab.location_only == true then
            return false, "grab is location-only; rotation nudges are disabled"
        end
        grab.yaw_offset = (grab.yaw_offset + d * STEP_ROT_DEG) % 360.0
        grab.rotation_dirty = true
        return true, string.format("yaw_offset=%.1f", grab.yaw_offset)
    elseif grab.mode == "scale" then
        if grab.location_only == true then
            return false, "grab is location-only; scale nudges are disabled"
        end
        local s = grab.scale + d * STEP_SCALE
        if s < SCALE_MIN then s = SCALE_MIN end
        if s > SCALE_MAX then s = SCALE_MAX end
        grab.scale = s
        grab.scale_dirty = true
        return true, string.format("scale=%.3f", s)
    end
    return false, "unknown mode " .. tostring(grab.mode)
end

-- camera.grab.rotate <signed> -- dedicated yaw nudge that ignores the
-- active mode. Lets the user bind a separate hotkey/wheel axis to
-- spinning the held actor without having to switch into `rot` mode
-- first (mimics oculus's scroll-to-rotate-while-holding behaviour).
function M.rotate(delta_str)
    if not grab then return false, "not grabbing" end
    if grab.location_only == true then
        return false, "grab is location-only; rotation nudges are disabled"
    end
    local d = tonumber(delta_str) or 1
    if d == 0 then d = 1 end
    grab.yaw_offset = (grab.yaw_offset + d * STEP_ROT_DEG) % 360.0
    grab.rotation_dirty = true
    return true, string.format("yaw_offset=%.1f", grab.yaw_offset)
end

-- camera.grab.lift <signed> -- dedicated Z-axis nudge that ignores the
-- active mode. Mirrors `camera.grab.rotate` ; lets a hotkey lift/lower
-- the held actor without flipping `mode` to `z` first.
function M.lift(delta_str)
    if not grab then return false, "not grabbing" end
    local d = tonumber(delta_str) or 1
    if d == 0 then d = 1 end
    grab.z_offset = grab.z_offset + d * STEP_Z
    return true, string.format("z_offset=%.0f", grab.z_offset)
end

-- camera.grab.scale <signed> -- dedicated uniform-scale nudge that
-- ignores the active mode. Mirrors `camera.grab.rotate` ; lets a
-- hotkey grow/shrink the held actor without flipping `mode` to
-- `scale` first.
function M.scale_delta(delta_str)
    if not grab then return false, "not grabbing" end
    if grab.location_only == true then
        return false, "grab is location-only; scale nudges are disabled"
    end
    local d = tonumber(delta_str) or 1
    if d == 0 then d = 1 end
    local s = grab.scale + d * STEP_SCALE
    if s < SCALE_MIN then s = SCALE_MIN end
    if s > SCALE_MAX then s = SCALE_MAX end
    grab.scale = s
    grab.scale_dirty = true
    return true, string.format("scale=%.3f", s)
end

-- camera.grab.status -- pure introspection ; no state change.
function M.status()
    local age = 0.0
    if grab_diag.last_tick_clock and grab_diag.last_tick_clock > 0 then
        age = os.clock() - grab_diag.last_tick_clock
    end
    local diag = string.format(
        "driver=%s ticks=%d age=%.2fs cam_poll=%d idle_skip=%d move_skip=%d cam_fail=%d move_fail=%d rot_write=%d rot_fail=%d clamped=%d inactive=%d auto_cancel=%d last_cam=%s last_move=%s last_rot=%s last_active=%s",
        tostring(grab_loop_driver or "none"),
        tonumber(grab_diag.ticks) or 0,
        age,
        tonumber(grab_diag.camera_polls) or 0,
        tonumber(grab_diag.idle_camera_skips) or 0,
        tonumber(grab_diag.skipped_moves) or 0,
        tonumber(grab_diag.camera_failures) or 0,
        tonumber(grab_diag.move_failures) or 0,
        tonumber(grab_diag.rotation_writes) or 0,
        tonumber(grab_diag.rotation_failures) or 0,
        tonumber(grab_diag.clamped_steps) or 0,
        tonumber(grab_diag.oculus_inactive_reads) or 0,
        tonumber(grab_diag.auto_cancels) or 0,
        tostring(grab_diag.last_camera_error or "none"),
        tostring(grab_diag.last_move_error or "none"),
        tostring(grab_diag.last_rotation_error or "none"),
        tostring(grab_diag.last_oculus_active_error or "none"))
    if pending_grab then
        return true, "pending name=" .. tostring(pending_grab.name)
            .. " source=" .. tostring(pending_grab.source)
            .. " safety=" .. grab_safety_label() .. " " .. diag
    end
    if not grab then return true, "idle safety=" .. grab_safety_label() .. " " .. diag end
    return true, string.format(
        "name=%s mode=%s dist=%.0f z=%.0f yaw=%.1f scale=%.3f loc_only=%s char=%s safe=%s safety=%s finish=%s %s",
        grab.name, grab.mode, grab.distance, grab.z_offset,
        grab.yaw_offset, grab.scale, tostring(grab.location_only == true),
        tostring(grab.character_profile == true), tostring(grab.safe_profile == true), grab_safety_label(),
        grab.pending_finish and tostring(grab.pending_finish_kind or "pending") or "none", diag
    )
end

-- Externally observable: are we currently grabbing? Used by feature_hotkeys
-- to decide whether to dispatch wheel-delta verbs.
function M.is_active() return grab ~= nil end

function M.is_pending()
    return pending_grab ~= nil
end

function M.is_modal_active()
    return grab ~= nil or pending_grab ~= nil
end

function M.restart_cooldown_remaining()
    return restart_cooldown_remaining()
end

function M.restart_cooldown_message()
    return restart_cooldown_message()
end

function M.top_status()
    return grab_top_status(grab)
end

function M.current_actor()
    if not grab or not feature_actor.is_valid_object(grab.actor) then return nil end
    return grab.actor, grab.name, "grab"
end

function M.help_details()
    if pending_grab then
        return "Starting safe grab..."
    end
    if not grab then return "" end
    return "Move actor (Move camera)"
end

-- pick_actor_under_reticle()  --  shared "what's under the crosshair?"
-- helper for OTHER features that want to target without going through
-- the Scan tab. Same source priority as M.lookat() (detector first when
-- not in oculus, camera trace as fallback) but with no toast/ack side
-- effects, and returns the raw UObject + a source tag for callers to
-- log themselves. Returns (actor_or_nil, source_string_or_err).
function M.pick_actor_under_reticle()
    if _prefer_detector_pick() then
        local a = _detector_pick()
        if feature_actor.is_valid_object(a) then return a, "detector" end
    end
    local hit_actor, _impact, err = _trace_from_camera(LOOKAT_MAX_DISTANCE)
    local item_actor, _item_loc, item_source = pick_world_item_candidate({ trace_impact = _impact })
    if feature_actor.is_valid_object(item_actor) then return item_actor, item_source end
    if feature_actor.is_valid_object(hit_actor) then return hit_actor, "trace" end
    return nil, "no actor under reticle (trace: " .. tostring(err) .. ")"
end

function M.pick_target_under_reticle()
    return pick_target_under_reticle()
end

function M.pick_trace_target_under_reticle()
    return pick_trace_target_under_reticle()
end

function M.pick_location_under_reticle()
    return pick_location_under_reticle()
end

function M.pick_hit_under_reticle()
    if _prefer_detector_pick() then
        local actor = _detector_pick()
        if feature_actor.is_valid_object(actor) then
            return actor, feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 }, "detector", nil, nil
        end
    end
    local actor, loc, err, details = _trace_from_camera(LOOKAT_MAX_DISTANCE)
    local item_actor, item_loc, item_source, _item_err, item_details =
        pick_world_item_candidate({ trace_impact = loc })
    if feature_actor.is_valid_object(item_actor) then
        return item_actor, item_loc or feature_actor.actor_location(item_actor) or { X = 0, Y = 0, Z = 0 }, item_source, nil, item_details
    end
    if feature_actor.is_valid_object(actor) then
        return actor, loc or feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 }, "trace", nil, details
    end
    if loc then
        return nil, loc, "trace.geometry", err, details
    end
    return nil, nil, nil, "no hit under reticle (trace: " .. tostring(err) .. ")", details
end

function M.reticle_ray(distance)
    return build_camera_ray(distance or LOOKAT_MAX_DISTANCE)
end

return M
