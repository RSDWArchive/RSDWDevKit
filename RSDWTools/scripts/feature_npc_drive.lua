-- Feature: experimental intact-NPC drive verbs.
--
-- This deliberately avoids PlayerController:Possess. The selected AI stays
-- owned by its AIController; we only steer through exposed AI movement/action
-- surfaces and optionally point the player's camera at the AI.

local M = {}

local core = require("feature_npc_drive_core")
local feature_actor = require("feature_actor")
local facade = require("feature_actor_facade")
local feature_field = require("feature_field")
local feature_grab = require("feature_grab")

local DEFAULT_STEP_CM = 250.0
local DEFAULT_FACE_CM = 500.0
local DEFAULT_BLEND_SECONDS = 0.5
local CAMERA_RESET_BLEND_SECONDS = 0.3
local CAMERA_DESTROY_DEFER_MS = 350
local CAMERA_GLIDE_SECONDS = 0.55
local DEFAULT_CAMERA_DISTANCE_CM = 460.0
local MIN_CAMERA_DISTANCE_CM = 120.0
local MAX_CAMERA_DISTANCE_CM = 2000.0
local DEFAULT_CAMERA_WHEEL_ZOOM_CM = 27.5
local DEFAULT_CAMERA_HEIGHT_CM = 165.0
local DEFAULT_CAMERA_TARGET_HEIGHT_CM = 85.0
local DEFAULT_CAMERA_FOV = 78.0
local CAMERA_TICK_MS = 16
local CAMERA_MOUSE_TICK_MS = 16
local DEFAULT_CAMERA_MOUSE_YAW_DEG = 0.12
local DEFAULT_CAMERA_MOUSE_PITCH_DEG = 0.08
local MIN_CAMERA_ORBIT_PITCH = -25.0
local MAX_CAMERA_ORBIT_PITCH = 45.0
local HOLD_TICK_MS = 33
local HOLD_DRIFT_CM = 8.0
local HOLD_MOVE_TICK_MS = 75
local HOLD_MOVE_REACHED_CM = 75.0
local HOLD_MOVE_MAX_TICKS = 40
local INPUT_MOVE_TICK_MS = 33
local INPUT_MOVE_SPEED_CM_PER_SEC = 260.0
local INPUT_MOVE_MAX_TICKS = 90
local PUPPET_MOVE_TICK_MS = 16
local PUPPET_MOVE_SPEED_CM_PER_SEC = 320.0
local PUPPET_MOVE_MAX_TICKS = 180
local PUPPET_ANIM_SPEED_CM_PER_SEC = 260.0
local NATIVE_MOVE_TICK_MS = 100
local NATIVE_MOVE_REACHED_CM = 35.0
local NATIVE_MOVE_MAX_TICKS = 140
local DEFAULT_NPC_JUMP_Z = 420.0
local MIN_NPC_JUMP_Z = 120.0
local MAX_NPC_JUMP_Z = 1400.0
local JUMP_STOP_DELAY_MS = 120

RSDWTOOLS_NPC_DRIVE_CAMERA_TOKEN = (RSDWTOOLS_NPC_DRIVE_CAMERA_TOKEN or 0) + 1
local module_camera_token = RSDWTOOLS_NPC_DRIVE_CAMERA_TOKEN
RSDWTOOLS_NPC_DRIVE_MOUSE_TOKEN = (RSDWTOOLS_NPC_DRIVE_MOUSE_TOKEN or 0) + 1
local module_mouse_token = RSDWTOOLS_NPC_DRIVE_MOUSE_TOKEN
RSDWTOOLS_NPC_DRIVE_HOLD_TOKEN = (RSDWTOOLS_NPC_DRIVE_HOLD_TOKEN or 0) + 1
local module_hold_token = RSDWTOOLS_NPC_DRIVE_HOLD_TOKEN
RSDWTOOLS_NPC_DRIVE_HOLD_MOVE_TOKEN = (RSDWTOOLS_NPC_DRIVE_HOLD_MOVE_TOKEN or 0) + 1
local module_hold_move_token = RSDWTOOLS_NPC_DRIVE_HOLD_MOVE_TOKEN
RSDWTOOLS_NPC_DRIVE_INPUT_MOVE_TOKEN = (RSDWTOOLS_NPC_DRIVE_INPUT_MOVE_TOKEN or 0) + 1
local module_input_move_token = RSDWTOOLS_NPC_DRIVE_INPUT_MOVE_TOKEN
RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN = (RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN or 0) + 1
local module_puppet_move_token = RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN

local state = {
    actor = nil,
    name = nil,
    source = nil,
    camera = false,
    camera_actor = nil,
    camera_loop = false,
    camera_view_target_seen = false,
    camera_view_mismatch_ticks = 0,
    camera_external_exit = false,
    camera_glide_until = nil,
    camera_glide_duration = nil,
    camera_glide_from_location = nil,
    camera_glide_from_rotation = nil,
    camera_focus_mode = "bounds",
    camera_focus_z_offset = 0.0,
    camera_view = "back",
    camera_orbit_yaw = nil,
    camera_orbit_pitch = nil,
    camera_mouse = false,
    camera_mouse_loop = false,
    camera_mouse_yaw_sensitivity = DEFAULT_CAMERA_MOUSE_YAW_DEG,
    camera_mouse_pitch_sensitivity = DEFAULT_CAMERA_MOUSE_PITCH_DEG,
    camera_mouse_samples = 0,
    camera_mouse_last_dx = 0.0,
    camera_mouse_last_dy = 0.0,
    camera_mouse_source = "idle",
    camera_zoom_samples = 0,
    camera_zoom_last_delta = 0.0,
    camera_zoom_source = "idle",
    camera_wheel_zoom_step = DEFAULT_CAMERA_WHEEL_ZOOM_CM,
    camera_wheel_registered = false,
    mouse_last_x = nil,
    mouse_last_y = nil,
    camera_distance = DEFAULT_CAMERA_DISTANCE_CM,
    camera_height = DEFAULT_CAMERA_HEIGHT_CM,
    camera_target_height = DEFAULT_CAMERA_TARGET_HEIGHT_CM,
    player_hidden = false,
    brain_stopped = false,
    quiet = false,
    hold = false,
    hold_mode = "lock",
    hold_loop = false,
    hold_anchor = nil,
    hold_rotation = nil,
    hold_move_loop = false,
    input_move_loop = false,
    puppet = false,
    puppet_move_loop = false,
    puppet_restore = nil,
    puppet_move_style = "native",
    tune = false,
    tune_restore = nil,
    tune_root_scaled = false,
    ai_movement_enabled = nil,
    player_input_locked = false,
    roamdata_disabled = false,
    roamdata_restore = nil,
    drive_yaw = nil,
    last_move = nil,
}

local cached_camera_actor_class = nil

local function target_drive_surface(actor)
    local movement_component = core.get_movement_component(actor)
    local controller = core.get_controller(actor)
    local actions_component = core.get_actions_component(actor)
    if movement_component and movement_component.BP_AiMoveTo then return true, "BP_AiMoveTo" end
    if controller and controller.MoveToLocation then return true, "AIController.MoveToLocation" end
    if actions_component and actions_component.BP_StartAction then return true, "DominionAIActionsComponent" end
    if actor.SetAttacksDisabled or actor.SetAiVisibility or actor.SetSpecifiedTargetOverride then return true, "DominionAICharacter" end
    return false, "no AI movement/action surface found"
end

local function validate_target(actor)
    if not core.is_valid(actor) then return false, "invalid target" end
    local pawn = core.get_local_pawn()
    if core.is_valid(pawn) and actor == pawn then return false, "refusing to drive the local player pawn" end
    local ok_surface, surface = target_drive_surface(actor)
    if not ok_surface then return false, surface end
    return true, surface
end

local function current_actor()
    if core.is_valid(state.actor) then return state.actor end
    return nil
end

local function drive_log(message)
    print("[RSDWTools] npc.drive " .. tostring(message or ""))
end

local function defer_on_game_thread(delay_ms, fn)
    if LoopAsync then
        local ok_loop = pcall(function()
            LoopAsync(delay_ms or 1, function()
                if ExecuteInGameThread then
                    local ok_schedule = pcall(function() ExecuteInGameThread(fn) end)
                    if not ok_schedule then pcall(fn) end
                else
                    pcall(fn)
                end
                return true
            end)
        end)
        if ok_loop then return true end
    end
    return pcall(fn)
end

function M.is_driveable_actor(actor)
    return validate_target(actor)
end

local function selected_or_error()
    local actor = current_actor()
    if actor then return actor, nil end
    return nil, "no selected NPC; run npc.drive.select first"
end

local function get_camera_viewpoint()
    local opawn = (function()
        local object = nil
        pcall(function() object = select(1, feature_field.resolve_root("pawn.OculusComponent.OculusPawn")) end)
        return object
    end)()
    if core.is_valid(opawn) then
        local active = false
        local ok_active, active_value = pcall(function() return opawn.bOculusActive end)
        if ok_active then active = active_value == true end
        if active then
            local camera_location, camera_rotation = nil, nil
            local ok_camera, camera = pcall(function() return opawn.Camera end)
            if ok_camera and core.is_valid(camera) then
                local ok_location, component_location = pcall(function() return camera:K2_GetComponentLocation() end)
                if ok_location and component_location then camera_location = component_location end
                local ok_rotation, component_rotation = pcall(function() return camera:K2_GetComponentRotation() end)
                if ok_rotation and component_rotation then camera_rotation = component_rotation end
            end
            if not camera_location then
                local ok_location, actor_location = pcall(function() return opawn:K2_GetActorLocation() end)
                if ok_location and actor_location then camera_location = actor_location end
            end
            if not camera_rotation then
                local ok_rotation, actor_rotation = pcall(function() return opawn:K2_GetActorRotation() end)
                if ok_rotation and actor_rotation then camera_rotation = actor_rotation end
            end
            if camera_location and camera_rotation then return camera_location, camera_rotation, nil end
        end
    end

    local controller = core.get_local_controller()
    if not core.is_valid(controller) then return nil, nil, "no local controller" end
    if not controller.GetPlayerViewPoint then return nil, nil, "controller missing GetPlayerViewPoint" end
    local ok_view, location, rotation = pcall(function()
        local out_location = { X = 0, Y = 0, Z = 0 }
        local out_rotation = { Pitch = 0, Yaw = 0, Roll = 0 }
        controller:GetPlayerViewPoint(out_location, out_rotation)
        return out_location, out_rotation
    end)
    if not ok_view then return nil, nil, "GetPlayerViewPoint raised: " .. tostring(location) end
    return location, rotation, nil
end

local function repair_player_ui_input(reason)
    local controller = core.get_local_controller()
    if not core.is_valid(controller) then return false, "no local controller" end
    local notes = {}

    if controller.ResetIgnoreMoveInput then
        local ok_reset = pcall(function() controller:ResetIgnoreMoveInput() end)
        notes[#notes + 1] = ok_reset and "move_ignore=reset" or "move_ignore_reset_failed"
    elseif controller.SetIgnoreMoveInput then
        local ok_set = pcall(function() controller:SetIgnoreMoveInput(false) end)
        notes[#notes + 1] = ok_set and "move_ignore=off" or "move_ignore_failed"
    end
    if controller.ResetIgnoreLookInput then
        local ok_reset = pcall(function() controller:ResetIgnoreLookInput() end)
        notes[#notes + 1] = ok_reset and "look_ignore=reset" or "look_ignore_reset_failed"
    elseif controller.SetIgnoreLookInput then
        local ok_set = pcall(function() controller:SetIgnoreLookInput(false) end)
        notes[#notes + 1] = ok_set and "look_ignore=off" or "look_ignore_failed"
    end

    local ok_click = pcall(function() controller.bEnableClickEvents = true end)
    notes[#notes + 1] = ok_click and "click_events=on" or "click_events_failed"
    local ok_hover = pcall(function() controller.bEnableMouseOverEvents = true end)
    notes[#notes + 1] = ok_hover and "hover_events=on" or "hover_events_failed"

    local wbl = core.get_widget_blueprint_library()
    if core.is_valid(wbl) and wbl.SetInputMode_GameOnly then
        local ok_mode = pcall(function() wbl:SetInputMode_GameOnly(controller, true) end)
        notes[#notes + 1] = ok_mode and "input_mode=gameonly" or "input_mode_failed"
    end

    state.player_input_locked = false
    return true, "player_ui_input repaired " .. tostring(reason or "") .. " " .. table.concat(notes, "; ")
end

local function set_player_input_locked(locked, reason)
    local controller = core.get_local_controller()
    if not core.is_valid(controller) then return false, "no local controller" end
    local desired = locked and true or false
    local notes = {}
    local changed = false

    if controller.SetIgnoreMoveInput then
        local ok_move = pcall(function() controller:SetIgnoreMoveInput(desired) end)
        notes[#notes + 1] = ok_move and ("move_ignore=" .. core.bool_word(desired)) or "move_ignore_failed"
        changed = changed or ok_move
    elseif not desired and controller.ResetIgnoreMoveInput then
        local ok_reset = pcall(function() controller:ResetIgnoreMoveInput() end)
        notes[#notes + 1] = ok_reset and "move_ignore=reset" or "move_ignore_reset_failed"
        changed = changed or ok_reset
    else
        notes[#notes + 1] = "move_ignore=unavailable"
    end

    if controller.SetIgnoreLookInput then
        local ok_look = pcall(function() controller:SetIgnoreLookInput(desired) end)
        notes[#notes + 1] = ok_look and ("look_ignore=" .. core.bool_word(desired)) or "look_ignore_failed"
        changed = changed or ok_look
    elseif not desired and controller.ResetIgnoreLookInput then
        local ok_reset = pcall(function() controller:ResetIgnoreLookInput() end)
        notes[#notes + 1] = ok_reset and "look_ignore=reset" or "look_ignore_reset_failed"
        changed = changed or ok_reset
    else
        notes[#notes + 1] = "look_ignore=unavailable"
    end

    if changed then
        state.player_input_locked = desired
        return true, "player_input_lock=" .. core.bool_word(desired) .. " " .. tostring(reason or "") .. " " .. table.concat(notes, "; ")
    end
    return false, "player_input_lock failed " .. tostring(reason or "") .. " " .. table.concat(notes, "; ")
end

local function set_view_target(target, blend_seconds)
    if not core.is_valid(target) then return false, "invalid view target" end
    local controller = core.get_local_controller()
    if not core.is_valid(controller) then return false, "no local controller" end
    if not controller.SetViewTargetWithBlend then return false, "controller missing SetViewTargetWithBlend" end
    if controller.GetViewTarget then
        local ok_current, current = pcall(function() return controller:GetViewTarget() end)
        if ok_current and core.is_valid(current) and (current == target or tostring(current) == tostring(target)) then
            return true, "camera=" .. core.object_label(target) .. " already"
        end
    end
    local ok_set, err = pcall(function()
        controller:SetViewTargetWithBlend(target, blend_seconds or DEFAULT_BLEND_SECONDS, 0, 0.0, false)
    end)
    if not ok_set then return false, "SetViewTargetWithBlend failed: " .. tostring(err) end
    return true, "camera=" .. core.object_label(target)
end

local function reset_view_target(blend_seconds)
    local pawn = core.get_local_pawn()
    if not core.is_valid(pawn) then return false, "no local pawn" end
    return set_view_target(pawn, blend_seconds or CAMERA_RESET_BLEND_SECONDS)
end

local function atan2_radians(y_value, x_value)
    if math.atan2 then return math.atan2(y_value, x_value) end
    return math.atan(y_value, x_value)
end

local function clamp_number(value, min_value, max_value)
    value = tonumber(value) or 0.0
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

local function set_camera_distance(value)
    state.camera_distance = clamp_number(value, MIN_CAMERA_DISTANCE_CM, MAX_CAMERA_DISTANCE_CM)
    return state.camera_distance
end

local function default_orbit_pitch()
    local vertical = (tonumber(state.camera_height) or DEFAULT_CAMERA_HEIGHT_CM) - (tonumber(state.camera_target_height) or DEFAULT_CAMERA_TARGET_HEIGHT_CM)
    local distance = math.max(1.0, tonumber(state.camera_distance) or DEFAULT_CAMERA_DISTANCE_CM)
    return clamp_number(atan2_radians(vertical, distance) * 180.0 / math.pi, MIN_CAMERA_ORBIT_PITCH, MAX_CAMERA_ORBIT_PITCH)
end

local function ensure_orbit_angles(actor, actor_yaw)
    if state.camera_orbit_yaw == nil then
        state.camera_orbit_yaw = core.normalize_yaw((tonumber(actor_yaw) or 0.0) + 28.0)
    end
    if state.camera_orbit_pitch == nil then
        state.camera_orbit_pitch = default_orbit_pitch()
    else
        state.camera_orbit_pitch = clamp_number(state.camera_orbit_pitch, MIN_CAMERA_ORBIT_PITCH, MAX_CAMERA_ORBIT_PITCH)
    end
end

local function vector_or_nil(value)
    if type(value) ~= "table" then return nil end
    local x, y, z = tonumber(value.X), tonumber(value.Y), tonumber(value.Z)
    if not x or not y or not z then return nil end
    return { X = x, Y = y, Z = z }
end

local function actor_bounds_center(actor)
    if not core.is_valid(actor) or not actor.GetActorBounds then return nil end
    local origin = { X = 0.0, Y = 0.0, Z = 0.0 }
    local extent = { X = 0.0, Y = 0.0, Z = 0.0 }
    local ok_bounds = pcall(function() actor:GetActorBounds(false, origin, extent, false) end)
    if not ok_bounds then return nil end
    local center = vector_or_nil(origin)
    local box_extent = vector_or_nil(extent)
    if not center or not box_extent then return nil end
    if math.abs(box_extent.X or 0) < 1.0 and math.abs(box_extent.Y or 0) < 1.0 and math.abs(box_extent.Z or 0) < 1.0 then return nil end
    return center
end

local function ai_aim_point(actor)
    if core.is_valid(actor) and actor.GetAIAimPoint then
        local ok_aim, aim_point = pcall(function() return actor:GetAIAimPoint() end)
        local aim = ok_aim and vector_or_nil(aim_point) or nil
        if aim then return aim end
    end
    return nil
end

local function apply_focus_offset(focus)
    if not focus then return nil end
    return {
        X = focus.X or 0,
        Y = focus.Y or 0,
        Z = (focus.Z or 0) + (tonumber(state.camera_focus_z_offset) or 0.0),
    }
end

local function camera_focus_location(actor, actor_location)
    local focus = nil
    if state.camera_focus_mode == "aim" then
        focus = ai_aim_point(actor) or actor_bounds_center(actor)
    else
        focus = actor_bounds_center(actor) or ai_aim_point(actor)
    end
    if focus then return apply_focus_offset(focus) end
    return apply_focus_offset({
        X = actor_location.X or 0,
        Y = actor_location.Y or 0,
        Z = (actor_location.Z or 0) + state.camera_target_height,
    })
end

local function rotation_looking_at(from_location, to_location)
    local delta_x = (to_location.X or 0) - (from_location.X or 0)
    local delta_y = (to_location.Y or 0) - (from_location.Y or 0)
    local delta_z = (to_location.Z or 0) - (from_location.Z or 0)
    local yaw = atan2_radians(delta_y, delta_x) * 180.0 / math.pi
    local horizontal = math.sqrt(delta_x * delta_x + delta_y * delta_y)
    local pitch = atan2_radians(delta_z, horizontal) * 180.0 / math.pi
    return { Pitch = pitch, Yaw = yaw, Roll = 0.0 }
end

local function rotator_to_quat(rot)
    rot = rot or {}
    local pitch = (tonumber(rot.Pitch or rot.X) or 0) * math.pi / 360.0
    local yaw = (tonumber(rot.Yaw or rot.Y) or 0) * math.pi / 360.0
    local roll = (tonumber(rot.Roll or rot.Z) or 0) * math.pi / 360.0

    local sin_pitch, cos_pitch = math.sin(pitch), math.cos(pitch)
    local sin_yaw, cos_yaw = math.sin(yaw), math.cos(yaw)
    local sin_roll, cos_roll = math.sin(roll), math.cos(roll)

    return {
        X = cos_roll * sin_pitch * sin_yaw - sin_roll * cos_pitch * cos_yaw,
        Y = -cos_roll * sin_pitch * cos_yaw - sin_roll * cos_pitch * sin_yaw,
        Z = cos_roll * cos_pitch * sin_yaw - sin_roll * sin_pitch * cos_yaw,
        W = cos_roll * cos_pitch * cos_yaw + sin_roll * sin_pitch * sin_yaw,
    }
end

local function build_spawn_transform(location, rotation)
    return {
        Rotation = rotator_to_quat(rotation),
        Translation = { X = location.X or 0, Y = location.Y or 0, Z = location.Z or 0 },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
end

local function set_actor_pose(actor, location, rotation)
    if not core.is_valid(actor) then return false, "invalid actor" end
    local hit = {}
    local ok_set, result = pcall(function()
        return actor:K2_SetActorLocationAndRotation(location, rotation, false, hit, true)
    end)
    if ok_set and result ~= false then return true end

    local ok_teleport, teleport_result = pcall(function() return actor:K2_TeleportTo(location, rotation) end)
    if ok_teleport and teleport_result ~= false then return true end

    local ok_location = feature_actor.move_actor(actor, location)
    local ok_rotation = feature_actor.set_actor_rotation(actor, rotation)
    if ok_location ~= false and ok_rotation ~= false then return true end
    return false, tostring(result or teleport_result or "no reflected actor pose setter accepted pose")
end

local function camera_glide_pose(target_location, target_rotation)
    local until_time = tonumber(state.camera_glide_until)
    local duration = tonumber(state.camera_glide_duration) or 0.0
    local from_location = state.camera_glide_from_location
    local from_rotation = state.camera_glide_from_rotation
    local now = os.clock()
    if not until_time or duration <= 0.0 or now >= until_time or type(from_location) ~= "table" or type(from_rotation) ~= "table" then
        state.camera_glide_until = nil
        state.camera_glide_from_location = nil
        state.camera_glide_from_rotation = nil
        return target_location, target_rotation
    end

    local alpha = 1.0 - math.max(0.0, until_time - now) / duration
    alpha = alpha * alpha * (3.0 - 2.0 * alpha)
    local function n(value) return tonumber(value) or 0.0 end
    local function lerp(a, b) return n(a) + (n(b) - n(a)) * alpha end
    local start_yaw = n(from_rotation.Yaw)
    local yaw_delta = core.normalize_yaw(n(target_rotation.Yaw) - start_yaw)
    return {
        X = lerp(from_location.X, target_location.X),
        Y = lerp(from_location.Y, target_location.Y),
        Z = lerp(from_location.Z, target_location.Z),
    }, {
        Pitch = lerp(from_rotation.Pitch, target_rotation.Pitch),
        Yaw = core.normalize_yaw(start_yaw + yaw_delta * alpha),
        Roll = lerp(from_rotation.Roll, target_rotation.Roll),
    }
end

local function begin_camera_glide(target_location, target_rotation)
    if not core.is_valid(state.camera_actor) then return false end
    local from_location = feature_actor.actor_location(state.camera_actor)
    local from_rotation = feature_actor.actor_rotation(state.camera_actor)
    if not from_location or not from_rotation then return false end
    state.camera_glide_from_location = { X = from_location.X or 0.0, Y = from_location.Y or 0.0, Z = from_location.Z or 0.0 }
    state.camera_glide_from_rotation = { Pitch = from_rotation.Pitch or 0.0, Yaw = from_rotation.Yaw or 0.0, Roll = from_rotation.Roll or 0.0 }
    state.camera_glide_duration = CAMERA_GLIDE_SECONDS
    state.camera_glide_until = os.clock() + CAMERA_GLIDE_SECONDS
    return true
end

local function camera_actor_class()
    if core.is_valid(cached_camera_actor_class) then return cached_camera_actor_class end
    cached_camera_actor_class = core.resolve_script_class("/Script/Engine.CameraActor")
    return cached_camera_actor_class
end

local function compute_follow_camera_pose(actor)
    local actor_location = feature_actor.actor_location(actor)
    if not actor_location then return nil, nil, "could not read selected actor location" end
    local actor_rotation = feature_actor.actor_rotation(actor) or { Yaw = 0.0 }
    local yaw = tonumber(actor_rotation.Yaw) or 0.0
    local view = state.camera_view or "back"
    if view == "orbit" then
        ensure_orbit_angles(actor, yaw)
    end
    local camera_basis_yaw = (view == "orbit" and state.camera_orbit_yaw) or yaw
    local radians = camera_basis_yaw * math.pi / 180.0
    local forward = { X = math.cos(radians), Y = math.sin(radians), Z = 0.0 }
    local right = { X = -forward.Y, Y = forward.X, Z = 0.0 }
    local dir_x, dir_y = -forward.X, -forward.Y
    if view == "front" then
        dir_x, dir_y = forward.X, forward.Y
    elseif view == "orbit" then
        dir_x, dir_y = forward.X, forward.Y
    elseif view == "frontright" then
        dir_x, dir_y = forward.X * 0.78 + right.X * 0.45, forward.Y * 0.78 + right.Y * 0.45
    elseif view == "frontleft" then
        dir_x, dir_y = forward.X * 0.78 - right.X * 0.45, forward.Y * 0.78 - right.Y * 0.45
    elseif view == "right" then
        dir_x, dir_y = right.X, right.Y
    elseif view == "left" then
        dir_x, dir_y = -right.X, -right.Y
    end
    local focus = camera_focus_location(actor, actor_location)
    if view == "orbit" then
        local pitch = clamp_number(state.camera_orbit_pitch or default_orbit_pitch(), MIN_CAMERA_ORBIT_PITCH, MAX_CAMERA_ORBIT_PITCH)
        state.camera_orbit_pitch = pitch
        local pitch_radians = pitch * math.pi / 180.0
        local horizontal = math.max(40.0, state.camera_distance * math.cos(pitch_radians))
        local camera_location = {
            X = (focus.X or 0) + dir_x * horizontal,
            Y = (focus.Y or 0) + dir_y * horizontal,
            Z = (focus.Z or 0) + state.camera_distance * math.sin(pitch_radians),
        }
        return camera_location, rotation_looking_at(camera_location, focus), nil
    end
    local camera_location = {
        X = (actor_location.X or 0) + dir_x * state.camera_distance,
        Y = (actor_location.Y or 0) + dir_y * state.camera_distance,
        Z = (actor_location.Z or 0) + state.camera_height,
    }
    return camera_location, rotation_looking_at(camera_location, focus), nil
end

local function configure_camera_actor(camera_actor)
    if not core.is_valid(camera_actor) then return end
    pcall(function() camera_actor.FOVAngle = DEFAULT_CAMERA_FOV end)
    local ok_component, camera_component = pcall(function() return camera_actor.CameraComponent end)
    if ok_component and core.is_valid(camera_component) then
        pcall(function() camera_component:SetFieldOfView(DEFAULT_CAMERA_FOV) end)
        pcall(function() camera_component:SetConstraintAspectRatio(false) end)
    end
end

local function spawn_follow_camera_actor(actor)
    local location, rotation, pose_err = compute_follow_camera_pose(actor)
    if not location then return nil, pose_err end
    local class_object = camera_actor_class()
    if not core.is_valid(class_object) then return nil, "CameraActor class not found" end
    local gameplay_statics = core.get_gameplay_statics()
    if not core.is_valid(gameplay_statics) then return nil, "GameplayStatics CDO not found" end
    local controller = core.get_local_controller()
    if not core.is_valid(controller) then return nil, "no local controller" end

    local spawn_transform = build_spawn_transform(location, rotation)
    local camera_actor = nil
    local ok_begin, begin_err = pcall(function()
        camera_actor = gameplay_statics:BeginDeferredActorSpawnFromClass(
            controller,
            class_object,
            spawn_transform,
            2,
            controller,
            0
        )
    end)
    if not ok_begin then return nil, "BeginDeferredActorSpawnFromClass failed: " .. tostring(begin_err) end
    if not core.is_valid(camera_actor) then return nil, "BeginDeferredActorSpawnFromClass returned null" end

    local ok_finish, finish_err = pcall(function()
        gameplay_statics:FinishSpawningActor(camera_actor, spawn_transform, 0)
    end)
    if not ok_finish then
        pcall(function() camera_actor:K2_DestroyActor() end)
        return nil, "FinishSpawningActor failed: " .. tostring(finish_err)
    end
    configure_camera_actor(camera_actor)
    set_actor_pose(camera_actor, location, rotation)
    return camera_actor, nil
end

local function destroy_camera_actor_now(camera_actor)
    if core.is_valid(camera_actor) then
        pcall(function() camera_actor:K2_DestroyActor() end)
    end
end

local function destroy_camera_actor_deferred(camera_actor, delay_ms)
    delay_ms = tonumber(delay_ms) or 0
    if delay_ms > 0 and LoopAsync then
        local ok_loop = pcall(function()
            LoopAsync(delay_ms, function()
                if ExecuteInGameThread then
                    local ok_schedule = pcall(function()
                        ExecuteInGameThread(function()
                            destroy_camera_actor_now(camera_actor)
                        end)
                    end)
                    if not ok_schedule then destroy_camera_actor_now(camera_actor) end
                else
                    destroy_camera_actor_now(camera_actor)
                end
                return true
            end)
        end)
        if ok_loop then return end
    end
    destroy_camera_actor_now(camera_actor)
end

local function destroy_follow_camera_actor(delay_ms)
    local camera_actor = state.camera_actor
    state.camera_actor = nil
    state.camera_view_target_seen = false
    state.camera_view_mismatch_ticks = 0
    destroy_camera_actor_deferred(camera_actor, delay_ms)
end

local function same_object(first, second)
    if not core.is_valid(first) or not core.is_valid(second) then return false end
    if first == second then return true end
    return tostring(first) == tostring(second)
end

local function camera_view_target_state()
    if not core.is_valid(state.camera_actor) then return "missing" end
    local controller = core.get_local_controller()
    if not core.is_valid(controller) or not controller.GetViewTarget then return "unknown" end
    local ok_target, target = pcall(function() return controller:GetViewTarget() end)
    if not ok_target or not core.is_valid(target) then return "unknown" end
    return same_object(target, state.camera_actor) and "active" or "inactive"
end

local function camera_view_target_active()
    local view_state = camera_view_target_state()
    if view_state == "active" then
        state.camera_view_target_seen = true
        state.camera_view_mismatch_ticks = 0
        return true
    end
    if view_state == "inactive" then return false end
    return true
end

local function camera_externally_exited()
    local view_state = camera_view_target_state()
    if view_state == "active" then
        state.camera_view_target_seen = true
        state.camera_view_mismatch_ticks = 0
        state.camera_external_exit = false
        return false
    end
    if view_state ~= "inactive" then
        state.camera_view_mismatch_ticks = 0
        return false
    end
    if not state.camera_view_target_seen then return false end
    state.camera_view_mismatch_ticks = (state.camera_view_mismatch_ticks or 0) + 1
    if state.camera_view_mismatch_ticks < 8 then return false end
    state.camera_external_exit = true
    return true
end

local function tick_follow_camera()
    if RSDWTOOLS_NPC_DRIVE_CAMERA_TOKEN ~= module_camera_token then return false end
    if not state.camera then return false end
    if core.is_valid(state.camera_actor) and camera_externally_exited() then
        state.camera = false
        state.camera_mouse = false
        state.camera_glide_until = nil
        return false
    end
    local actor = current_actor()
    if not actor then
        state.camera = false
        state.camera_mouse = false
        state.camera_glide_until = nil
        reset_view_target(CAMERA_RESET_BLEND_SECONDS)
        return false
    end
    if not core.is_valid(state.camera_actor) then
        local camera_actor = nil
        local spawn_err = nil
        camera_actor, spawn_err = spawn_follow_camera_actor(actor)
        if not core.is_valid(camera_actor) then
            print("[RSDWTools] npc.drive.camera follow spawn failed: " .. tostring(spawn_err))
            return true
        end
        state.camera_actor = camera_actor
        set_view_target(camera_actor, 0.0)
    end

    local location, rotation, pose_err = compute_follow_camera_pose(actor)
    if not location then
        print("[RSDWTools] npc.drive.camera pose failed: " .. tostring(pose_err))
        return true
    end
    location, rotation = camera_glide_pose(location, rotation)
    set_actor_pose(state.camera_actor, location, rotation)
    return true
end

local function number_from_out(value)
    if type(value) == "number" then return value end
    if type(value) == "table" then
        return tonumber(value.Value or value.value or value[1] or value.X or value.Y or 0.0) or 0.0
    end
    return tonumber(value) or 0.0
end

local input_fkey_cache = {}
local function input_fkey(name)
    if input_fkey_cache[name] then return input_fkey_cache[name] end
    if not FName then return nil end
    local ok_name, fname = pcall(function() return FName(name) end)
    if not ok_name or not fname then return nil end
    local key = { KeyName = fname }
    input_fkey_cache[name] = key
    return key
end

local function input_axis_name(name)
    if not FName then return nil end
    local ok_name, fname = pcall(function() return FName(name) end)
    if ok_name then return fname end
    return nil
end

local function read_mouse_axis_delta(controller)
    if not core.is_valid(controller) then return nil, nil, "no local controller" end
    local mouse_x = input_fkey("MouseX")
    local mouse_y = input_fkey("MouseY")
    if mouse_x and mouse_y and controller.GetInputAnalogKeyState then
        local ok_x, dx = pcall(function() return controller:GetInputAnalogKeyState(mouse_x) end)
        local ok_y, dy = pcall(function() return controller:GetInputAnalogKeyState(mouse_y) end)
        if ok_x and ok_y then return tonumber(dx) or 0.0, tonumber(dy) or 0.0, "analog" end
    end
    if mouse_x and mouse_y and controller.GetInputAxisKeyValue then
        local ok_x, dx = pcall(function() return controller:GetInputAxisKeyValue(mouse_x) end)
        local ok_y, dy = pcall(function() return controller:GetInputAxisKeyValue(mouse_y) end)
        if ok_x and ok_y then return tonumber(dx) or 0.0, tonumber(dy) or 0.0, "axiskey" end
    end
    if controller.GetInputAxisValue then
        local axis_x = input_axis_name("MouseX")
        local axis_y = input_axis_name("MouseY")
        if axis_x and axis_y then
            local ok_x, dx = pcall(function() return controller:GetInputAxisValue(axis_x) end)
            local ok_y, dy = pcall(function() return controller:GetInputAxisValue(axis_y) end)
            if ok_x and ok_y then return tonumber(dx) or 0.0, tonumber(dy) or 0.0, "axis" end
        end
    end
    return nil, nil, "axis unavailable"
end

local function read_mouse_position_delta(controller)
    if not core.is_valid(controller) or not controller.GetMousePosition then return nil, nil, "no mouse position" end
    local out_x, out_y = { Value = 0.0 }, { Value = 0.0 }
    local ok_pos, success = pcall(function() return controller:GetMousePosition(out_x, out_y) end)
    if not ok_pos or success == false then return nil, nil, "mouse position unavailable" end
    local x, y = number_from_out(out_x), number_from_out(out_y)
    if state.mouse_last_x == nil or state.mouse_last_y == nil then
        state.mouse_last_x, state.mouse_last_y = x, y
        return 0.0, 0.0, "position"
    end
    local dx, dy = x - state.mouse_last_x, y - state.mouse_last_y
    state.mouse_last_x, state.mouse_last_y = x, y
    return dx, dy, "position"
end

local function read_mouse_delta()
    local controller = core.get_local_controller()
    if not core.is_valid(controller) then return nil, nil, "no local controller" end
    local ax, ay, asource = read_mouse_axis_delta(controller)
    if ax ~= nil and ay ~= nil and (math.abs(ax) >= 0.01 or math.abs(ay) >= 0.01) then return ax, ay, asource end
    if controller.GetInputMouseDelta then
        local out_x, out_y = { Value = 0.0 }, { Value = 0.0 }
        local ok_delta, result_x, result_y = pcall(function() return controller:GetInputMouseDelta(out_x, out_y) end)
        if ok_delta then
            local dx = tonumber(result_x) or number_from_out(out_x)
            local dy = tonumber(result_y) or number_from_out(out_y)
            if math.abs(dx) >= 0.01 or math.abs(dy) >= 0.01 then return dx, dy, "delta" end
            local px, py, psource = read_mouse_position_delta(controller)
            if px ~= nil and py ~= nil and (math.abs(px) >= 0.01 or math.abs(py) >= 0.01) then return px, py, psource end
            if ax ~= nil and ay ~= nil then return ax, ay, asource end
            return dx, dy, "delta"
        end

        local ok_return, dx_return, dy_return = pcall(function() return controller:GetInputMouseDelta(0.0, 0.0) end)
        if ok_return and (tonumber(dx_return) or tonumber(dy_return)) then
            local dx, dy = tonumber(dx_return) or 0.0, tonumber(dy_return) or 0.0
            if math.abs(dx) >= 0.01 or math.abs(dy) >= 0.01 then return dx, dy, "delta:return" end
        end
    end
    if ax ~= nil and ay ~= nil then return ax, ay, asource end
    return read_mouse_position_delta(controller)
end

local function apply_mouse_orbit_delta(actor, dx, dy, source)
    dx = tonumber(dx) or 0.0
    dy = tonumber(dy) or 0.0
    state.camera_mouse_last_dx = dx
    state.camera_mouse_last_dy = dy
    state.camera_mouse_source = source or "unknown"
    if math.abs(dx) < 0.01 and math.abs(dy) < 0.01 then return false end

    local actor_rotation = feature_actor.actor_rotation(actor) or { Yaw = 0.0 }
    ensure_orbit_angles(actor, tonumber(actor_rotation.Yaw) or 0.0)
    state.camera_view = "orbit"
    state.camera_orbit_yaw = core.normalize_yaw((state.camera_orbit_yaw or 0.0) - dx * state.camera_mouse_yaw_sensitivity)
    state.camera_orbit_pitch = clamp_number((state.camera_orbit_pitch or default_orbit_pitch()) + dy * state.camera_mouse_pitch_sensitivity, MIN_CAMERA_ORBIT_PITCH, MAX_CAMERA_ORBIT_PITCH)
    state.camera_mouse_samples = (state.camera_mouse_samples or 0) + 1

    if core.is_valid(state.camera_actor) then
        local location, rotation = compute_follow_camera_pose(actor)
        state.camera_glide_until = nil
        if location then set_actor_pose(state.camera_actor, location, rotation) end
    end
    return true
end

local function apply_camera_zoom_delta(actor, notches, source)
    if not core.is_valid(actor) then return false end
    notches = tonumber(notches) or 0.0
    state.camera_zoom_last_delta = notches
    state.camera_zoom_source = source or "unknown"
    if math.abs(notches) < 0.01 then return false end

    local old_distance = tonumber(state.camera_distance) or DEFAULT_CAMERA_DISTANCE_CM
    local step = tonumber(state.camera_wheel_zoom_step) or DEFAULT_CAMERA_WHEEL_ZOOM_CM
    local new_distance = set_camera_distance(old_distance - notches * step)
    state.camera_zoom_samples = (state.camera_zoom_samples or 0) + 1
    state.camera_view = "orbit"

    if core.is_valid(state.camera_actor) then
        local location, rotation = compute_follow_camera_pose(actor)
        state.camera_glide_until = nil
        if location then set_actor_pose(state.camera_actor, location, rotation) end
    end
    return math.abs(new_distance - old_distance) >= 0.01
end

local function camera_zoom_can_poll()
    return RSDWTOOLS_NPC_DRIVE_MOUSE_TOKEN == module_mouse_token
        and state.camera_mouse == true
        and state.camera == true
        and state.camera_external_exit ~= true
        and core.is_valid(state.camera_actor)
        and current_actor() ~= nil
end

local function ensure_camera_zoom_wheel()
    if state.camera_wheel_registered then return end
    local ok_wheel, wheel = pcall(require, "feature_wheel_hook")
    if not ok_wheel or type(wheel) ~= "table" or type(wheel.register) ~= "function" then
        state.camera_zoom_source = "wheel unavailable"
        return
    end
    wheel.register("up", {}, function()
        apply_camera_zoom_delta(current_actor(), 1.0, "wheel:up")
    end, camera_zoom_can_poll)
    wheel.register("down", {}, function()
        apply_camera_zoom_delta(current_actor(), -1.0, "wheel:down")
    end, camera_zoom_can_poll)
    state.camera_wheel_registered = true
end

local function tick_mouse_orbit()
    if RSDWTOOLS_NPC_DRIVE_MOUSE_TOKEN ~= module_mouse_token then return false end
    if not state.camera_mouse or not state.camera then return false end
    local actor = current_actor()
    if not actor then
        state.camera_mouse = false
        return false
    end
    local dx, dy, source = read_mouse_delta()
    if dx ~= nil and dy ~= nil then
        apply_mouse_orbit_delta(actor, dx, dy, source)
    else
        state.camera_mouse_source = tostring(source or "unavailable")
    end
    return true
end

local function start_mouse_loop()
    if state.camera_mouse_loop then return end
    if not LoopAsync then
        print("[RSDWTools] npc.drive.camera mouse: LoopAsync unavailable; mouse orbit disabled.")
        return
    end
    state.camera_mouse_loop = true
    LoopAsync(CAMERA_MOUSE_TICK_MS, function()
        local keep_running = tick_mouse_orbit()
        if not keep_running then
            state.camera_mouse_loop = false
            return true
        end
        return false
    end)
end

local function start_camera_loop()
    if state.camera_loop then return end
    if not LoopAsync then
        print("[RSDWTools] npc.drive.camera: LoopAsync unavailable; camera will not follow.")
        return
    end
    state.camera_loop = true
    LoopAsync(CAMERA_TICK_MS, function()
        local keep_running = tick_follow_camera()
        if not keep_running then
            state.camera_loop = false
            return true
        end
        return false
    end)
end

local function ensure_follow_camera(actor, blend_seconds)
    if not core.is_valid(actor) then return false, "invalid selected actor" end
    local should_glide = state.camera == true and core.is_valid(state.camera_actor)
    if not core.is_valid(state.camera_actor) then
        local camera_actor, spawn_err = spawn_follow_camera_actor(actor)
        if not core.is_valid(camera_actor) then return false, spawn_err end
        state.camera_actor = camera_actor
    else
        local location, rotation = compute_follow_camera_pose(actor)
        if location then
            if should_glide and not begin_camera_glide(location, rotation) then
                set_actor_pose(state.camera_actor, location, rotation)
            elseif not should_glide then
                state.camera_glide_until = nil
                set_actor_pose(state.camera_actor, location, rotation)
            end
        end
    end
    local ok_view, detail = set_view_target(state.camera_actor, blend_seconds or DEFAULT_BLEND_SECONDS)
    if not ok_view then return false, detail end
    state.camera = true
    state.camera_external_exit = false
    state.camera_view_target_seen = false
    state.camera_view_mismatch_ticks = 0
    start_camera_loop()
    return true, string.format("camera=%s distance=%.0f height=%.0f", state.camera_view or "back", state.camera_distance, state.camera_height)
end

local function set_player_hidden(hidden)
    local pawn = core.get_local_pawn()
    if not core.is_valid(pawn) then return false, "no local pawn" end
    if not pawn.SetActorHiddenInGame then return false, "pawn missing SetActorHiddenInGame" end
    local ok_hidden, err = pcall(function() pawn:SetActorHiddenInGame(hidden and true or false) end)
    if not ok_hidden then return false, "SetActorHiddenInGame failed: " .. tostring(err) end
    state.player_hidden = hidden and true or false
    return true, "player_hidden=" .. core.bool_word(state.player_hidden)
end

local function stop_brain(actor)
    local brain = core.get_brain_component(actor)
    if not core.is_valid(brain) then return false, "no BrainComponent" end
    if not brain.StopLogic then return false, "BrainComponent missing StopLogic" end
    local ok_stop, err = pcall(function() brain:StopLogic("RSDWTools npc.drive") end)
    if not ok_stop then return false, "StopLogic failed: " .. tostring(err) end
    state.brain_stopped = true
    return true, "brain=stopped"
end

local function start_brain(actor)
    local brain = core.get_brain_component(actor)
    if not core.is_valid(brain) then return false, "no BrainComponent" end
    local ok_start, err = false, nil
    if brain.StartLogic then
        ok_start, err = pcall(function() brain:StartLogic() end)
    end
    if not ok_start and brain.RestartLogic then
        ok_start, err = pcall(function() brain:RestartLogic() end)
    end
    if not ok_start then return false, "StartLogic/RestartLogic failed: " .. tostring(err) end
    state.brain_stopped = false
    return true, "brain=running"
end

local function get_ai_function_library()
    if not StaticFindObject then return nil end
    local ok_find, object = pcall(StaticFindObject, "/Script/Dominion.Default__DominionAiFunctionLibrary")
    if ok_find and core.is_valid(object) then return object end
    return nil
end

local function get_alertness_component(actor)
    local controller = core.get_controller(actor)
    if not core.is_valid(controller) then return nil end
    local ok_get, component = pcall(function() return controller:GetAlertnessComponent() end)
    if ok_get and core.is_valid(component) then return component end
    local ok_field, field_component = pcall(function() return controller.AIAlertnessComponent end)
    if ok_field and core.is_valid(field_component) then return field_component end
    return nil
end

local function add_unique_component(components, seen, component, label)
    if not core.is_valid(component) then return end
    local key = tostring(component)
    if seen[key] then return end
    seen[key] = true
    components[#components + 1] = { object = component, label = label or core.object_label(component) }
end

local function collect_quiet_components(actor)
    local components = {}
    local seen = {}
    local controller = core.get_controller(actor)

    if core.is_valid(controller) then
        for unused_index, field_name in ipairs({ "AmbientMovementComponent", "PatrollingComponent", "FlyAwayComponent", "CombatStrategyComponent" }) do
            local ok_field, component = pcall(function() return controller[field_name] end)
            if ok_field then add_unique_component(components, seen, component, field_name) end
        end

        local ok_patrol, patrol_component = pcall(function() return controller:GetPatrollingComponent() end)
        if ok_patrol then add_unique_component(components, seen, patrol_component, "PatrollingComponent") end

        for unused_index, class_path in ipairs({
            "/Script/Dominion.AIAmbientMovementComponent",
            "/Script/Dominion.AIPatrollingComponent",
            "/Script/Dominion.AIFlyAwayComponent",
            "/Script/Dominion.AICombatStrategyComponent",
        }) do
            local class_object = core.resolve_script_class(class_path)
            if core.is_valid(class_object) then
                local ok_component, component = pcall(function() return controller:GetComponentByClass(class_object) end)
                if ok_component then add_unique_component(components, seen, component, class_path:match("%.([^%.]+)$") or class_path) end
            end
        end
    end

    for unused_index, field_name in ipairs({ "DominionAIActionsComponent", "AttackOpportunityComponent", "CombatModeInitiatorComponent" }) do
        local ok_field, component = pcall(function() return actor[field_name] end)
        if ok_field then add_unique_component(components, seen, component, field_name) end
    end

    for unused_index, getter_name in ipairs({ "GetAIActionsComponent", "GetAttackOpportunityComponent" }) do
        local ok_get, component = pcall(function() return actor[getter_name](actor) end)
        if ok_get then add_unique_component(components, seen, component, getter_name) end
    end

    for unused_index, class_path in ipairs({
        "/Script/Dominion.DominionAIActionsComponent",
        "/Script/Dominion.AIOpportunisticOperationsComponent",
        "/Script/Dominion.CombatModeInitiatorComponent",
    }) do
        local class_object = core.resolve_script_class(class_path)
        if core.is_valid(class_object) then
            local ok_component, component = pcall(function() return actor:GetComponentByClass(class_object) end)
            if ok_component then add_unique_component(components, seen, component, class_path:match("%.([^%.]+)$") or class_path) end
        end
    end

    return components
end

local function try_note(notes, failures, success_text, failure_text, callback)
    local ok_call, result = pcall(callback)
    if ok_call and result ~= false then
        notes[#notes + 1] = success_text
        return true
    end
    failures[#failures + 1] = failure_text .. "=" .. tostring(ok_call and result or result)
    return false
end

local function distance_between(first_location, second_location)
    if not first_location or not second_location then return 0.0 end
    local delta_x = (second_location.X or 0) - (first_location.X or 0)
    local delta_y = (second_location.Y or 0) - (first_location.Y or 0)
    local delta_z = (second_location.Z or 0) - (first_location.Z or 0)
    return math.sqrt(delta_x * delta_x + delta_y * delta_y + delta_z * delta_z)
end

local function set_quiet_mode(actor, enabled)
    if not core.is_valid(actor) then return false, "invalid target" end
    local notes = {}
    local failures = {}
    local any_success = false
    local ai_library = get_ai_function_library()

    any_success = try_note(notes, failures, enabled and "attacks=disabled" or "attacks=enabled", "attacks", function()
        return actor:SetAttacksDisabled(enabled and true or false, actor)
    end) or any_success

    if core.is_valid(ai_library) then
        if enabled then
            any_success = try_note(notes, failures, "engage=blocked", "engage", function()
                return ai_library:SetOverrideCanEngageForAI(actor, false)
            end) or any_success
        else
            any_success = try_note(notes, failures, "engage=restored", "engage", function()
                return ai_library:UnsetOverrideCanEngageForAI(actor)
            end) or any_success
        end

        any_success = try_note(notes, failures, enabled and "alertness=locked" or "alertness=unlocked", "alertness.lib", function()
            return ai_library:SetAllowAlertnessStateChange(actor, not enabled)
        end) or any_success
    end

    local alertness_component = get_alertness_component(actor)
    if core.is_valid(alertness_component) then
        any_success = try_note(notes, failures, enabled and "alert_component=locked" or "alert_component=unlocked", "alertness.component", function()
            return alertness_component:AllowStateChange(not enabled)
        end) or any_success
    end

    local actions_component = core.get_actions_component(actor)
    if enabled and core.is_valid(actions_component) then
        any_success = try_note(notes, failures, "action=stopped", "action", function()
            return actions_component:Multicast_StopCurrentAIAction()
        end) or any_success
    end

    local ticked_components = 0
    for unused_index, component_info in ipairs(collect_quiet_components(actor)) do
        local component = component_info.object
        if core.is_valid(component) then
            local ok_tick, tick_result = pcall(function() return component:SetComponentTickEnabled(not enabled) end)
            if ok_tick and tick_result ~= false then
                ticked_components = ticked_components + 1
                any_success = true
            else
                failures[#failures + 1] = tostring(component_info.label) .. ".tick=" .. tostring(tick_result)
            end
        end
    end
    if ticked_components > 0 then notes[#notes + 1] = "component_ticks=" .. (enabled and "paused:" or "resumed:") .. tostring(ticked_components) end

    if any_success then
        state.quiet = enabled and true or false
        return true, "quiet=" .. core.bool_word(state.quiet) .. " " .. table.concat(notes, "; ")
    end
    return false, "no quiet control succeeded" .. (#failures > 0 and ": " .. table.concat(failures, "; ") or "")
end

local function stop_active_movement(actor, freeze_path_following)
    local notes = {}
    local controller = core.get_controller(actor)
    if core.is_valid(controller) then
        local ok_stop = pcall(function() return controller:StopMovement() end)
        if ok_stop then notes[#notes + 1] = "controller_stop" end
        pcall(function() controller:K2_ClearFocus() end)
    end

    local movement_component = core.get_movement_component(actor)
    if core.is_valid(movement_component) then
        local ok_immediate = pcall(function() return movement_component:StopMovementImmediately() end)
        if ok_immediate then notes[#notes + 1] = "movement_stop" end
        pcall(function() return movement_component:StopMovementKeepPathing() end)
    end

    local path_component = core.get_path_following_component(actor)
    if freeze_path_following and core.is_valid(path_component) then
        local ok_tick = pcall(function() return path_component:SetComponentTickEnabled(false) end)
        if ok_tick then notes[#notes + 1] = "path_tick=paused" end
    end

    return table.concat(notes, ",")
end

local function set_path_following_enabled(actor, enabled)
    local path_component = core.get_path_following_component(actor)
    if not core.is_valid(path_component) then return false end
    local ok_tick = pcall(function() return path_component:SetComponentTickEnabled(enabled and true or false) end)
    return ok_tick
end

local function set_movement_disabled(actor, disabled)
    if not core.is_valid(actor) or not actor.SetMovementDisabled then return false, "missing SetMovementDisabled" end
    local ok_disable, result = pcall(function() return actor:SetMovementDisabled(disabled and true or false, actor) end)
    if ok_disable and result ~= false then return true, "movement_disabled=" .. core.bool_word(disabled) end
    return false, "SetMovementDisabled=" .. tostring(result)
end

local function is_movement_disabled(actor)
    if not core.is_valid(actor) or not actor.IsMovementDisabled then return nil end
    local ok_disabled, disabled = pcall(function() return actor:IsMovementDisabled() end)
    if ok_disabled then return disabled == true end
    return nil
end

local function call0(object, method_name)
    if not core.is_valid(object) then return false, nil end
    return pcall(function() return object[method_name](object) end)
end

local function call1(object, method_name, arg1)
    if not core.is_valid(object) then return false, nil end
    return pcall(function() return object[method_name](object, arg1) end)
end

local function call2(object, method_name, arg1, arg2)
    if not core.is_valid(object) then return false, nil end
    return pcall(function() return object[method_name](object, arg1, arg2) end)
end

local function format_probe_value(ok, value)
    if not ok then return "err" end
    if value == nil then return "nil" end
    if type(value) == "boolean" then return tostring(value) end
    if type(value) == "number" then return string.format("%.3f", value) end
    if type(value) == "userdata" then return core.object_label(value) end
    return tostring(value)
end

local function safe_object_field(object, field_name)
    if not core.is_valid(object) then return nil end
    local ok_field, value = pcall(function() return object[field_name] end)
    if ok_field then return value end
    return nil
end

local function raw_field(parent, field_name)
    if parent == nil then return false, nil, "nil parent" end
    local ok_field, value = pcall(function() return parent[field_name] end)
    if ok_field then return true, value, nil end
    return false, nil, tostring(value)
end

local function raw_write(parent, field_name, value)
    if parent == nil then return false, "nil parent" end
    local ok_write, err = pcall(function() parent[field_name] = value end)
    if ok_write then return true, nil end
    return false, tostring(err)
end

local function raw_number(parent, field_name)
    local ok_field, value, err = raw_field(parent, field_name)
    if ok_field and type(value) == "number" then return true, value end
    return false, err or tostring(value)
end

local function raw_bool(parent, field_name)
    local ok_field, value, err = raw_field(parent, field_name)
    if ok_field and type(value) == "boolean" then return true, value end
    return false, err or tostring(value)
end

local function format_raw(ok, value)
    if ok then return tostring(value) end
    return "err:" .. tostring(value)
end

local function get_loaded_data(actor)
    if not core.is_valid(actor) then return nil, "invalid target" end
    local ok_data, loaded_data, err = raw_field(actor, "LoadedData")
    if ok_data and core.is_valid(loaded_data) then return loaded_data, nil end
    return nil, err or "LoadedData invalid"
end

local function component_labels(components)
    local labels = {}
    for index, component_info in ipairs(components or {}) do
        labels[index] = tostring(component_info.label or core.object_label(component_info.object))
    end
    return table.concat(labels, ",")
end

local function refresh_hold_anchor(actor)
    local location = feature_actor.actor_location(actor)
    if location then
        state.hold_anchor = { X = location.X or 0, Y = location.Y or 0, Z = location.Z or 0 }
    end
    local rotation = feature_actor.actor_rotation(actor)
    if rotation then
        state.hold_rotation = { Pitch = rotation.Pitch or 0, Yaw = rotation.Yaw or 0, Roll = rotation.Roll or 0 }
        if state.drive_yaw == nil then state.drive_yaw = tonumber(rotation.Yaw) or 0.0 end
    end
end

local function tick_hold()
    if RSDWTOOLS_NPC_DRIVE_HOLD_TOKEN ~= module_hold_token then return false end
    if not state.hold then return false end
    if state.hold_mode ~= "pin" then return false end
    if state.hold_move_loop then return true end
    local actor = current_actor()
    if not actor then
        state.hold = false
        return false
    end

    if not state.hold_anchor then refresh_hold_anchor(actor) end
    stop_active_movement(actor, true)

    local current_location = feature_actor.actor_location(actor)
    if current_location and state.hold_anchor and distance_between(current_location, state.hold_anchor) > HOLD_DRIFT_CM then
        feature_actor.move_actor(actor, state.hold_anchor)
    end
    if state.hold_rotation then
        feature_actor.set_actor_rotation(actor, state.hold_rotation)
    end
    return true
end

local function start_hold_loop()
    if state.hold_loop then return end
    if not LoopAsync then
        print("[RSDWTools] npc.drive.hold: LoopAsync unavailable; hold will not tick.")
        return
    end
    state.hold_loop = true
    LoopAsync(HOLD_TICK_MS, function()
        local keep_running = tick_hold()
        if not keep_running then
            state.hold_loop = false
            return true
        end
        return false
    end)
end

local function set_hold_mode(actor, enabled)
    if not core.is_valid(actor) then return false, "invalid target" end
    if enabled then
        local mode = state.hold_mode == "pin" and "pin" or "lock"
        refresh_hold_anchor(actor)
        local ok_override, override_result = facade.set_target(actor, nil)
        if not ok_override then return false, "target clear failed: " .. tostring(override_result) end
        local ok_quiet, quiet_detail = set_quiet_mode(actor, true)
        local ok_disable, disable_detail = set_movement_disabled(actor, true)
        local stop_detail = stop_active_movement(actor, mode == "pin")
        state.hold = true
        state.hold_mode = mode
        if state.hold_mode == "pin" then start_hold_loop() end
        local anchor = state.hold_anchor or { X = 0, Y = 0, Z = 0 }
        return true, string.format("hold=on mode=%s anchor=(%.0f,%.0f,%.0f) %s stop=%s quiet=%s", state.hold_mode, anchor.X or 0, anchor.Y or 0, anchor.Z or 0, ok_disable and disable_detail or disable_detail, stop_detail ~= "" and stop_detail or "none", ok_quiet and "on" or tostring(quiet_detail))
    end

    state.hold = false
    state.hold_anchor = nil
    state.hold_rotation = nil
    state.hold_move_loop = false
    set_path_following_enabled(actor, true)
    set_movement_disabled(actor, false)
    local ok_quiet, quiet_detail = set_quiet_mode(actor, false)
    return true, "hold=off path_tick=running quiet=" .. (ok_quiet and "off" or tostring(quiet_detail))
end

local function relock_hold_after_move(actor, destination, distance)
    if not state.hold or not core.is_valid(actor) then return end
    if not LoopAsync then
        set_movement_disabled(actor, true)
        stop_active_movement(actor, state.hold_mode == "pin")
        return
    end

    RSDWTOOLS_NPC_DRIVE_HOLD_MOVE_TOKEN = RSDWTOOLS_NPC_DRIVE_HOLD_MOVE_TOKEN + 1
    local move_token = RSDWTOOLS_NPC_DRIVE_HOLD_MOVE_TOKEN
    local max_ticks = math.max(10, math.min(HOLD_MOVE_MAX_TICKS, math.floor((tonumber(distance) or DEFAULT_STEP_CM) / 45.0) + 12))
    local tick_count = 0
    state.hold_move_loop = true
    LoopAsync(HOLD_MOVE_TICK_MS, function()
        if RSDWTOOLS_NPC_DRIVE_HOLD_MOVE_TOKEN ~= move_token or RSDWTOOLS_NPC_DRIVE_HOLD_MOVE_TOKEN < module_hold_move_token then
            return true
        end
        if not state.hold or not core.is_valid(actor) or actor ~= current_actor() then
            state.hold_move_loop = false
            return true
        end

        tick_count = tick_count + 1
        local current_location = feature_actor.actor_location(actor)
        local reached = current_location and distance_between(current_location, destination) <= HOLD_MOVE_REACHED_CM
        if reached or tick_count >= max_ticks then
            refresh_hold_anchor(actor)
            stop_active_movement(actor, state.hold_mode == "pin")
            set_movement_disabled(actor, true)
            if state.hold_mode == "pin" then start_hold_loop() end
            state.hold_move_loop = false
            return true
        end
        return false
    end)
end

local function release_hold_for_move(actor)
    if not state.hold then return "" end
    RSDWTOOLS_NPC_DRIVE_HOLD_MOVE_TOKEN = RSDWTOOLS_NPC_DRIVE_HOLD_MOVE_TOKEN + 1
    state.hold_move_loop = false
    set_path_following_enabled(actor, true)
    local ok_disable, disable_detail = set_movement_disabled(actor, false)
    if state.quiet then pcall(function() set_quiet_mode(actor, true) end) end
    local stop_detail = stop_active_movement(actor, false)
    return (ok_disable and disable_detail or disable_detail) .. " stop=" .. (stop_detail ~= "" and stop_detail or "none")
end

local function set_tune_mode(actor, enabled)
    if not core.is_valid(actor) then return false, "invalid target" end
    local notes = {}
    if enabled then
        if not state.tune then
            local restore = { quiet = state.quiet }
            local ok_should_walk, should_walk = call0(actor, "GetShouldWalk")
            if ok_should_walk and type(should_walk) == "boolean" then restore.should_walk = should_walk end
            local ok_distance, distance_multiplier = call0(actor, "GetDistanceMultiplier")
            if ok_distance and type(distance_multiplier) == "number" then restore.distance_multiplier = distance_multiplier end
            local ok_target, specified_target = facade.snapshot(actor)
            if not ok_target then return false, "target snapshot failed: " .. tostring(specified_target) end
            restore.specified_target = specified_target
            state.tune_restore = restore
        end

        local ok_quiet, quiet_detail = set_quiet_mode(actor, true)
        notes[#notes + 1] = ok_quiet and quiet_detail or "quiet_failed=" .. tostring(quiet_detail)
        local stop_detail = stop_active_movement(actor, true)
        notes[#notes + 1] = "stop=" .. (stop_detail ~= "" and stop_detail or "none")

        local ok_walk, walk_result = call1(actor, "SetShouldWalk", true)
        notes[#notes + 1] = ok_walk and "should_walk=true" or "should_walk_failed=" .. tostring(walk_result)
        local ok_distance_set, distance_result = call1(actor, "SetDistanceMultiplier", 0.0)
        notes[#notes + 1] = ok_distance_set and "distance_multiplier=0" or "distance_multiplier_failed=" .. tostring(distance_result)
        local ok_preferred, preferred_result = call1(actor, "SetPreferredDistanceToTargetOverride", 0.0)
        notes[#notes + 1] = ok_preferred and "preferred_distance=0" or "preferred_distance_failed=" .. tostring(preferred_result)
        notes[#notes + 1] = ok_override and "target_override=cleared" or "target_override_failed=" .. tostring(override_result)

        state.tune = true
        return true, "tune=on " .. table.concat(notes, "; ")
    end

    local restore = state.tune_restore or {}
    if restore.specified_target ~= nil then
        local ok_override, override_result = facade.restore(actor, restore.specified_target)
        if not ok_override then
            return false, "target restore failed (snapshot retained; retry tune off): " .. tostring(override_result)
        end
        notes[#notes + 1] = "target_override=restored"
    end
    set_path_following_enabled(actor, true)
    local ok_stop = stop_active_movement(actor, false)
    notes[#notes + 1] = "stop=" .. (ok_stop ~= "" and ok_stop or "none")

    if restore.should_walk ~= nil then
        local ok_walk, walk_result = call1(actor, "SetShouldWalk", restore.should_walk)
        notes[#notes + 1] = ok_walk and "should_walk=restored" or "should_walk_restore_failed=" .. tostring(walk_result)
    end
    if restore.distance_multiplier ~= nil then
        local ok_distance_set, distance_result = call1(actor, "SetDistanceMultiplier", restore.distance_multiplier)
        notes[#notes + 1] = ok_distance_set and string.format("distance_multiplier=%.3f", restore.distance_multiplier) or "distance_multiplier_restore_failed=" .. tostring(distance_result)
    else
        local ok_distance_set, distance_result = call1(actor, "SetDistanceMultiplier", 1.0)
        notes[#notes + 1] = ok_distance_set and "distance_multiplier=1" or "distance_multiplier_restore_failed=" .. tostring(distance_result)
    end
    local ok_preferred, preferred_result = call0(actor, "ResetPreferredDistanceToTargetOverride")
    notes[#notes + 1] = ok_preferred and "preferred_distance=reset" or "preferred_distance_reset_failed=" .. tostring(preferred_result)
    if state.tune_root_scaled then
        local ok_root, root_result = call1(actor, "BP_SetRootMotionScale", 1.0)
        notes[#notes + 1] = ok_root and "root_motion=1" or "root_motion_restore_failed=" .. tostring(root_result)
    end

    local ok_quiet, quiet_detail = set_quiet_mode(actor, restore.quiet == true)
    notes[#notes + 1] = ok_quiet and quiet_detail or "quiet_restore_failed=" .. tostring(quiet_detail)
    state.tune = false
    state.tune_restore = nil
    state.tune_root_scaled = false
    return true, "tune=off " .. table.concat(notes, "; ")
end

local function set_global_ai_movement(enabled)
    local pawn = core.get_local_pawn()
    if not core.is_valid(pawn) then return false, "no local player pawn" end
    local disabled = not enabled
    local notes = {}
    local failures = {}
    local any_success = false

    for unused_index, method_name in ipairs({ "domDisableAiMovement", "Server_DisableAIMovement" }) do
        local ok_call, result = call1(pawn, method_name, disabled)
        if ok_call then
            any_success = true
            notes[#notes + 1] = method_name .. "=" .. tostring(disabled)
        else
            failures[#failures + 1] = method_name .. "=" .. tostring(result)
        end
    end

    if not any_success then
        return false, "no global AI movement call succeeded: " .. table.concat(failures, "; ")
    end
    state.ai_movement_enabled = enabled and true or false
    return true, "ai_movement=" .. core.bool_word(state.ai_movement_enabled) .. " " .. table.concat(notes, "; ")
end

local function capture_roamdata(data)
    local restore = { data = data, data_label = core.object_label(data), mover = {}, ambient = {} }
    local ok_mover, mover = raw_field(data, "MoverConfig")
    restore.mover_struct = ok_mover and mover or nil
    if ok_mover then
        local ok_can_roam, can_roam = raw_bool(mover, "bCanRoam")
        if ok_can_roam then restore.mover.bCanRoam = can_roam end
        local ok_run, run_speed = raw_number(mover, "RunSpeed")
        if ok_run then restore.mover.RunSpeed = run_speed end
        local ok_walk, walk_speed = raw_number(mover, "WalkSpeed")
        if ok_walk then restore.mover.WalkSpeed = walk_speed end
    end

    local ok_ambient, ambient = raw_field(data, "AmbientConfig")
    restore.ambient_struct = ok_ambient and ambient or nil
    if ok_ambient then
        for unused_index, field_name in ipairs({ "AmbientMovementMinDistance", "AmbientMovementMaxDistance", "AmbientMinWaitingTime", "AmbientMaxWaitingTime" }) do
            local ok_value, value = raw_number(ambient, field_name)
            if ok_value then restore.ambient[field_name] = value end
        end
    end
    return restore
end

local function roamdata_restore_matches(restore, data)
    if not restore or not core.is_valid(data) then return false end
    if restore.data == data then return true end
    return restore.data_label ~= nil and restore.data_label == core.object_label(data)
end

local function write_struct_fields(parent, struct_name, struct_value, fields)
    local notes = {}
    local failures = {}
    if struct_value == nil then return notes, { struct_name .. "=missing" } end
    for field_name, value in pairs(fields) do
        local ok_write, err = raw_write(struct_value, field_name, value)
        if ok_write then
            notes[#notes + 1] = struct_name .. "." .. field_name .. "=" .. tostring(value)
        else
            failures[#failures + 1] = struct_name .. "." .. field_name .. "=" .. tostring(err)
        end
    end
    local ok_commit, commit_err = raw_write(parent, struct_name, struct_value)
    if ok_commit then
        notes[#notes + 1] = struct_name .. "=committed"
    else
        failures[#failures + 1] = struct_name .. ".commit=" .. tostring(commit_err)
    end
    return notes, failures
end

local function roamdata_snapshot_text(data)
    local ok_mover, mover = raw_field(data, "MoverConfig")
    local ok_ambient, ambient = raw_field(data, "AmbientConfig")
    local ok_can_roam, can_roam = false, "no mover"
    local ok_run, run_speed = false, "no mover"
    local ok_walk, walk_speed = false, "no mover"
    local ok_min, min_distance = false, "no ambient"
    local ok_max, max_distance = false, "no ambient"
    local ok_wait_min, wait_min = false, "no ambient"
    local ok_wait_max, wait_max = false, "no ambient"
    if ok_mover then
        ok_can_roam, can_roam = raw_bool(mover, "bCanRoam")
        ok_run, run_speed = raw_number(mover, "RunSpeed")
        ok_walk, walk_speed = raw_number(mover, "WalkSpeed")
    end
    if ok_ambient then
        ok_min, min_distance = raw_number(ambient, "AmbientMovementMinDistance")
        ok_max, max_distance = raw_number(ambient, "AmbientMovementMaxDistance")
        ok_wait_min, wait_min = raw_number(ambient, "AmbientMinWaitingTime")
        ok_wait_max, wait_max = raw_number(ambient, "AmbientMaxWaitingTime")
    end
    return string.format(
        "data=%s bCanRoam=%s run=%s walk=%s ambient_min=%s ambient_max=%s wait_min=%s wait_max=%s",
        core.object_label(data), format_raw(ok_can_roam, can_roam), format_raw(ok_run, run_speed), format_raw(ok_walk, walk_speed), format_raw(ok_min, min_distance), format_raw(ok_max, max_distance), format_raw(ok_wait_min, wait_min), format_raw(ok_wait_max, wait_max))
end

local function set_roamdata_enabled(actor, enabled)
    local data, data_err = get_loaded_data(actor)
    if not core.is_valid(data) then return false, tostring(data_err) end
    local notes = {}
    local failures = {}

    if enabled then
        if not state.roamdata_disabled then
            return true, "roamdata=on already " .. roamdata_snapshot_text(data)
        end
        local restore = state.roamdata_restore
        if not roamdata_restore_matches(restore, data) then
            return false, "no matching roamdata restore snapshot for " .. core.object_label(data)
        end

        local mover_notes, mover_failures = write_struct_fields(data, "MoverConfig", restore.mover_struct, restore.mover)
        local ambient_notes, ambient_failures = write_struct_fields(data, "AmbientConfig", restore.ambient_struct, restore.ambient)
        for unused_index, note in ipairs(mover_notes) do notes[#notes + 1] = note end
        for unused_index, note in ipairs(ambient_notes) do notes[#notes + 1] = note end
        for unused_index, failure in ipairs(mover_failures) do failures[#failures + 1] = failure end
        for unused_index, failure in ipairs(ambient_failures) do failures[#failures + 1] = failure end
        set_path_following_enabled(actor, true)
        state.roamdata_disabled = false
        state.roamdata_restore = nil
        return true, "roamdata=on " .. table.concat(notes, "; ") .. (#failures > 0 and " failures=" .. table.concat(failures, "; ") or "")
    end

    if not state.roamdata_disabled or not roamdata_restore_matches(state.roamdata_restore, data) then
        state.roamdata_restore = capture_roamdata(data)
    end

    local ok_mover, mover, mover_err = raw_field(data, "MoverConfig")
    local ok_ambient, ambient, ambient_err = raw_field(data, "AmbientConfig")
    if not ok_mover then failures[#failures + 1] = "MoverConfig=" .. tostring(mover_err) end
    if not ok_ambient then failures[#failures + 1] = "AmbientConfig=" .. tostring(ambient_err) end

    local mover_notes, mover_failures = write_struct_fields(data, "MoverConfig", ok_mover and mover or nil, { bCanRoam = false })
    local ambient_notes, ambient_failures = write_struct_fields(data, "AmbientConfig", ok_ambient and ambient or nil, {
        AmbientMovementMinDistance = 0.0,
        AmbientMovementMaxDistance = 0.0,
        AmbientMinWaitingTime = 999999.0,
        AmbientMaxWaitingTime = 999999.0,
    })
    for unused_index, note in ipairs(mover_notes) do notes[#notes + 1] = note end
    for unused_index, note in ipairs(ambient_notes) do notes[#notes + 1] = note end
    for unused_index, failure in ipairs(mover_failures) do failures[#failures + 1] = failure end
    for unused_index, failure in ipairs(ambient_failures) do failures[#failures + 1] = failure end

    local stop_detail = stop_active_movement(actor, true)
    notes[#notes + 1] = "stop=" .. (stop_detail ~= "" and stop_detail or "none")
    state.roamdata_disabled = true
    return true, "roamdata=off " .. table.concat(notes, "; ") .. (#failures > 0 and " failures=" .. table.concat(failures, "; ") or "")
end

local function set_roamdata_values(actor, can_roam, min_distance, max_distance, min_wait, max_wait, run_speed, walk_speed)
    local data, data_err = get_loaded_data(actor)
    if not core.is_valid(data) then return false, tostring(data_err) end
    local notes = {}
    local failures = {}
    local ok_mover, mover, mover_err = raw_field(data, "MoverConfig")
    local ok_ambient, ambient, ambient_err = raw_field(data, "AmbientConfig")
    if not ok_mover then failures[#failures + 1] = "MoverConfig=" .. tostring(mover_err) end
    if not ok_ambient then failures[#failures + 1] = "AmbientConfig=" .. tostring(ambient_err) end

    local mover_fields = { bCanRoam = can_roam and true or false }
    if run_speed ~= nil then mover_fields.RunSpeed = run_speed end
    if walk_speed ~= nil then mover_fields.WalkSpeed = walk_speed end
    local ambient_fields = {
        AmbientMovementMinDistance = min_distance,
        AmbientMovementMaxDistance = max_distance,
        AmbientMinWaitingTime = min_wait,
        AmbientMaxWaitingTime = max_wait,
    }
    local mover_notes, mover_failures = write_struct_fields(data, "MoverConfig", ok_mover and mover or nil, mover_fields)
    local ambient_notes, ambient_failures = write_struct_fields(data, "AmbientConfig", ok_ambient and ambient or nil, ambient_fields)
    for unused_index, note in ipairs(mover_notes) do notes[#notes + 1] = note end
    for unused_index, note in ipairs(ambient_notes) do notes[#notes + 1] = note end
    for unused_index, failure in ipairs(mover_failures) do failures[#failures + 1] = failure end
    for unused_index, failure in ipairs(ambient_failures) do failures[#failures + 1] = failure end

    state.roamdata_disabled = not can_roam
    if can_roam then state.roamdata_restore = nil end
    return true, "roamdata=set " .. table.concat(notes, "; ") .. (#failures > 0 and " failures=" .. table.concat(failures, "; ") or "")
end

local function horizontal_basis_from_yaw(yaw)
    local radians = (tonumber(yaw) or 0.0) * math.pi / 180.0
    local forward = { X = math.cos(radians), Y = math.sin(radians), Z = 0.0 }
    local right = { X = -math.sin(radians), Y = math.cos(radians), Z = 0.0 }
    return forward, right, tonumber(yaw) or 0.0
end

local function camera_horizontal_basis(actor)
    if state.hold and state.drive_yaw ~= nil then
        return horizontal_basis_from_yaw(state.drive_yaw)
    end

    local camera_location, camera_rotation = get_camera_viewpoint()
    local yaw = camera_rotation and tonumber(camera_rotation.Yaw)
    if not yaw then
        local actor_rotation = feature_actor.actor_rotation(actor)
        yaw = actor_rotation and tonumber(actor_rotation.Yaw) or 0.0
    end
    return horizontal_basis_from_yaw(yaw)
end

local direct_move_to_location
local input_move_to_location
local slide_move_to_location
local anim_slide_move_to_location
local native_move_to_location

local function move_to_location(actor, destination, reason)
    local failures = {}
    local origin = feature_actor.actor_location(actor)
    local distance = distance_between(origin, destination)
    local hold_release_detail = ""
    local hold_was_enabled = state.hold
    if hold_was_enabled then
        hold_release_detail = release_hold_for_move(actor)
    end
    local movement_component = core.get_movement_component(actor)
    if core.is_valid(movement_component) and movement_component.BP_AiMoveTo then
        local ok_move, result = pcall(function() return movement_component:BP_AiMoveTo(destination, true) end)
        if ok_move and result ~= false then
            if hold_was_enabled then relock_hold_after_move(actor, destination, distance) end
            state.last_move = string.format("%s%s BP_AiMoveTo result=%s from=(%.0f,%.0f,%.0f) dest=(%.0f,%.0f,%.0f) d=%.0f%s", reason or "move", hold_was_enabled and ".hold-release" or "", tostring(result), origin and origin.X or 0, origin and origin.Y or 0, origin and origin.Z or 0, destination.X or 0, destination.Y or 0, destination.Z or 0, distance, hold_was_enabled and " relock=armed " .. tostring(hold_release_detail) or "")
            return true, state.last_move
        end
        failures[#failures + 1] = "BP_AiMoveTo=" .. tostring(ok_move and result or result)
    end

    local controller = core.get_controller(actor)
    if core.is_valid(controller) and controller.MoveToLocation then
        local ok_move, result = pcall(function()
            return controller:MoveToLocation(destination, 35.0, false, true, true, false, nil, true)
        end)
        if ok_move then
            if hold_was_enabled then relock_hold_after_move(actor, destination, distance) end
            state.last_move = string.format("%s%s MoveToLocation result=%s from=(%.0f,%.0f,%.0f) dest=(%.0f,%.0f,%.0f) d=%.0f%s", reason or "move", hold_was_enabled and ".hold-release" or "", tostring(result), origin and origin.X or 0, origin and origin.Y or 0, origin and origin.Z or 0, destination.X or 0, destination.Y or 0, destination.Z or 0, distance, hold_was_enabled and " relock=armed " .. tostring(hold_release_detail) or "")
            return true, state.last_move
        end
        failures[#failures + 1] = "MoveToLocation=" .. tostring(result)
    end

    if hold_was_enabled then
        set_movement_disabled(actor, true)
        stop_active_movement(actor, state.hold_mode == "pin")
    end
    state.last_move = "failed " .. (#failures > 0 and table.concat(failures, "; ") or "no movement surface")
    return false, "no movement call succeeded" .. (#failures > 0 and ": " .. table.concat(failures, "; ") or "")
end

local function read_move_status(actor)
    local controller = core.get_controller(actor)
    if not core.is_valid(controller) or not controller.GetMoveStatus then return "unknown" end
    local ok_status, status = pcall(function() return controller:GetMoveStatus() end)
    if not ok_status then return "error:" .. tostring(status) end
    return tostring(status)
end

function native_move_to_location(actor, destination, reason)
    local origin = feature_actor.actor_location(actor)
    if not origin then return false, "could not read selected actor location" end
    local distance = distance_between(origin, destination)
    if distance < 1.0 then return false, "native move distance too small" end

    local movement_component = core.get_movement_component(actor)
    if not core.is_valid(movement_component) or not movement_component.BP_AiMoveTo then
        return false, "selected actor has no BP_AiMoveTo movement surface"
    end

    RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN = RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN + 1
    local move_token = RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN
    state.puppet_move_loop = true

    local was_puppet = state.puppet
    local was_quiet = state.quiet
    if not was_puppet then set_quiet_mode(actor, true) end
    set_path_following_enabled(actor, true)
    set_movement_disabled(actor, false)
    stop_active_movement(actor, false)

    local delta = {
        X = (destination.X or 0) - (origin.X or 0),
        Y = (destination.Y or 0) - (origin.Y or 0),
        Z = (destination.Z or 0) - (origin.Z or 0),
    }
    state.drive_yaw = atan2_radians(delta.Y, delta.X) * 180.0 / math.pi

    local ok_move, result = pcall(function() return movement_component:BP_AiMoveTo(destination, true) end)
    if not ok_move or result == false then
        state.puppet_move_loop = false
        if was_puppet then
            set_movement_disabled(actor, true)
            set_path_following_enabled(actor, false)
        else
            set_path_following_enabled(actor, true)
            set_movement_disabled(actor, false)
            set_quiet_mode(actor, was_quiet)
        end
        return false, "BP_AiMoveTo failed: " .. tostring(ok_move and result or result)
    end

    local tick_count = 0
    local max_ticks = math.max(10, math.min(NATIVE_MOVE_MAX_TICKS, math.ceil(((distance / PUPPET_ANIM_SPEED_CM_PER_SEC) * 1000.0) / NATIVE_MOVE_TICK_MS) + 50))
    local last_remaining = distance
    local last_status = read_move_status(actor)

    local function finish_native(finish_reason)
        state.puppet_move_loop = false
        local final_location = feature_actor.actor_location(actor)
        last_remaining = final_location and distance_between(final_location, destination) or last_remaining
        local keep_locked = was_puppet and state.puppet
        if keep_locked then
            stop_active_movement(actor, true)
            set_movement_disabled(actor, true)
            set_path_following_enabled(actor, false)
        else
            set_path_following_enabled(actor, true)
            set_movement_disabled(actor, false)
            set_quiet_mode(actor, was_quiet)
        end
        state.last_move = string.format("%s native BP_AiMoveTo result=%s ticks=%d/%d reason=%s from=(%.0f,%.0f,%.0f) now=(%.0f,%.0f,%.0f) dest=(%.0f,%.0f,%.0f) requested_d=%.0f remaining=%.0f status=%s", reason or "move.native", tostring(result), tick_count, max_ticks, tostring(finish_reason or "done"), origin.X or 0, origin.Y or 0, origin.Z or 0, final_location and final_location.X or 0, final_location and final_location.Y or 0, final_location and final_location.Z or 0, destination.X or 0, destination.Y or 0, destination.Z or 0, distance, last_remaining or 0, tostring(last_status))
    end

    if not LoopAsync then
        state.last_move = string.format("%s native BP_AiMoveTo result=%s no_loopasync requested_d=%.0f", reason or "move.native", tostring(result), distance)
        return true, state.last_move
    end

    LoopAsync(NATIVE_MOVE_TICK_MS, function()
        if RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN ~= move_token or RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN < module_puppet_move_token then
            state.puppet_move_loop = false
            return true
        end
        if not core.is_valid(actor) or actor ~= current_actor() then
            state.puppet_move_loop = false
            return true
        end
        tick_count = tick_count + 1
        local current_location = feature_actor.actor_location(actor)
        if current_location then last_remaining = distance_between(current_location, destination) end
        last_status = read_move_status(actor)
        local traveled = current_location and distance_between(origin, current_location) or 0.0
        local status_lower = tostring(last_status):lower()
        local status_idle = status_lower:find("idle", 1, true) ~= nil or tostring(last_status) == "0"
        if last_remaining <= NATIVE_MOVE_REACHED_CM then
            finish_native("reached")
            return true
        end
        if status_idle and tick_count >= 6 and traveled > 30.0 then
            finish_native("idle")
            return true
        end
        if tick_count >= max_ticks then
            finish_native("timeout")
            return true
        end
        return false
    end)

    state.last_move = string.format("%s native BP_AiMoveTo started result=%s ticks=%d requested_d=%.0f status=%s", reason or "move.native", tostring(result), max_ticks, distance, tostring(last_status))
    return true, state.last_move
end

function direct_move_to_location(actor, destination, reason)
    local origin = feature_actor.actor_location(actor)
    local hold_was_enabled = state.hold
    if hold_was_enabled then release_hold_for_move(actor) end
    local ok_move, move_err = feature_actor.move_actor(actor, destination)
    if not ok_move then return false, "direct move failed: " .. tostring(move_err) end
    local distance = distance_between(origin, destination)
    state.last_move = string.format("%s direct SetActorLocation from=(%.0f,%.0f,%.0f) dest=(%.0f,%.0f,%.0f) d=%.0f", reason or "move", origin and origin.X or 0, origin and origin.Y or 0, origin and origin.Z or 0, destination.X or 0, destination.Y or 0, destination.Z or 0, distance)
    if hold_was_enabled then
        state.hold_anchor = { X = destination.X or 0, Y = destination.Y or 0, Z = destination.Z or 0 }
        stop_active_movement(actor, state.hold_mode == "pin")
        set_movement_disabled(actor, true)
    end
    return true, state.last_move
end

local function add_movement_input(actor, direction, scale)
    local ok_input, result = pcall(function() return actor:AddMovementInput(direction, scale or 1.0, true) end)
    if ok_input then return true, result end
    return false, result
end

local function set_component_field(object, field_name, value)
    if not core.is_valid(object) then return false end
    local ok_write = pcall(function() object[field_name] = value end)
    return ok_write
end

local function move_actor_for_locomotion(actor, location, rotation)
    if not core.is_valid(actor) then return false, "invalid actor" end
    if actor.K2_SetActorLocationAndRotation and rotation then
        local ok_call, result = pcall(function()
            local hit = {}
            return actor:K2_SetActorLocationAndRotation(location, rotation, false, hit, false)
        end)
        if ok_call then return result ~= false, result == false and "K2_SetActorLocationAndRotation returned false" or nil end
    end
    if actor.K2_SetActorLocation then
        local ok_call, result = pcall(function()
            local hit = {}
            return actor:K2_SetActorLocation(location, false, hit, false)
        end)
        if ok_call then return result ~= false, result == false and "K2_SetActorLocation returned false" or nil end
    end
    return feature_actor.move_actor(actor, location)
end

local function feed_locomotion_signal(actor, direction, velocity)
    local notes = {}
    local ok_input = add_movement_input(actor, direction, 1.0)
    if ok_input then notes[#notes + 1] = "actor_input" end

    local movement_component = core.get_movement_component(actor)
    if not core.is_valid(movement_component) then return table.concat(notes, ",") end

    if movement_component.SetMovementMode then
        local ok_mode = pcall(function() return movement_component:SetMovementMode(1, 0) end)
        if ok_mode then notes[#notes + 1] = "walk_mode" end
    end
    if movement_component.AddInputVector then
        local ok_vector = pcall(function() return movement_component:AddInputVector(direction, true) end)
        if ok_vector then notes[#notes + 1] = "component_input" end
    end
    if movement_component.RequestDirectMove then
        local ok_request = pcall(function() return movement_component:RequestDirectMove(velocity, true) end)
        if ok_request then notes[#notes + 1] = "direct_move_request" end
    end
    local fields = { "Velocity", "LastUpdateVelocity", "RequestedVelocity", "LastUpdateRequestedVelocity", "AnimRootMotionVelocity" }
    local wrote = 0
    for unused_index, field_name in ipairs(fields) do
        if set_component_field(movement_component, field_name, velocity) then wrote = wrote + 1 end
    end
    if set_component_field(movement_component, "bHasRequestedVelocity", true) then wrote = wrote + 1 end
    if wrote > 0 then notes[#notes + 1] = "velocity_fields=" .. tostring(wrote) end
    return table.concat(notes, ",")
end

local function clear_locomotion_signal(actor)
    local zero = { X = 0.0, Y = 0.0, Z = 0.0 }
    local movement_component = core.get_movement_component(actor)
    if core.is_valid(movement_component) then
        set_component_field(movement_component, "Velocity", zero)
        set_component_field(movement_component, "LastUpdateVelocity", zero)
        set_component_field(movement_component, "RequestedVelocity", zero)
        set_component_field(movement_component, "LastUpdateRequestedVelocity", zero)
        set_component_field(movement_component, "AnimRootMotionVelocity", zero)
        set_component_field(movement_component, "bHasRequestedVelocity", false)
    end
end

function input_move_to_location(actor, destination, reason)
    local origin = feature_actor.actor_location(actor)
    if not origin then return false, "could not read selected actor location" end
    local delta_x = (destination.X or 0) - (origin.X or 0)
    local delta_y = (destination.Y or 0) - (origin.Y or 0)
    local horizontal_distance = math.sqrt(delta_x * delta_x + delta_y * delta_y)
    if horizontal_distance < 1.0 then return false, "input move distance too small" end

    local direction = { X = delta_x / horizontal_distance, Y = delta_y / horizontal_distance, Z = 0.0 }
    local hold_was_enabled = state.hold
    local hold_release_detail = ""
    if hold_was_enabled then hold_release_detail = release_hold_for_move(actor) end
    if state.tune then set_path_following_enabled(actor, false) end
    stop_active_movement(actor, state.tune)

    local ok_first, first_result = add_movement_input(actor, direction, 1.0)
    if not ok_first then
        if hold_was_enabled then
            set_movement_disabled(actor, true)
            stop_active_movement(actor, state.hold_mode == "pin")
        end
        return false, "AddMovementInput failed: " .. tostring(first_result)
    end

    local tick_count = 0
    local duration_seconds = horizontal_distance / INPUT_MOVE_SPEED_CM_PER_SEC
    local max_ticks = math.max(3, math.min(INPUT_MOVE_MAX_TICKS, math.ceil((duration_seconds * 1000.0) / INPUT_MOVE_TICK_MS)))
    RSDWTOOLS_NPC_DRIVE_INPUT_MOVE_TOKEN = RSDWTOOLS_NPC_DRIVE_INPUT_MOVE_TOKEN + 1
    local input_token = RSDWTOOLS_NPC_DRIVE_INPUT_MOVE_TOKEN
    state.input_move_loop = true

    local function finish_input_move(finish_reason)
        state.input_move_loop = false
        local final_location = feature_actor.actor_location(actor)
        if hold_was_enabled then
            refresh_hold_anchor(actor)
            stop_active_movement(actor, state.hold_mode == "pin")
            set_movement_disabled(actor, true)
            if state.hold_mode == "pin" then start_hold_loop() end
        elseif state.tune then
            stop_active_movement(actor, true)
        end
        state.last_move = string.format("%s input AddMovementInput ticks=%d/%d reason=%s from=(%.0f,%.0f,%.0f) now=(%.0f,%.0f,%.0f) requested_d=%.0f%s", reason or "move.input", tick_count, max_ticks, tostring(finish_reason or "done"), origin.X or 0, origin.Y or 0, origin.Z or 0, final_location and final_location.X or 0, final_location and final_location.Y or 0, final_location and final_location.Z or 0, horizontal_distance, hold_was_enabled and " hold_release=" .. tostring(hold_release_detail) or "")
    end

    if not LoopAsync then
        finish_input_move("no_loopasync")
        return true, state.last_move
    end

    LoopAsync(INPUT_MOVE_TICK_MS, function()
        if RSDWTOOLS_NPC_DRIVE_INPUT_MOVE_TOKEN ~= input_token or RSDWTOOLS_NPC_DRIVE_INPUT_MOVE_TOKEN < module_input_move_token then
            finish_input_move("cancelled")
            return true
        end
        if not core.is_valid(actor) or actor ~= current_actor() then
            state.input_move_loop = false
            return true
        end
        tick_count = tick_count + 1
        local ok_tick = add_movement_input(actor, direction, 1.0)
        if not ok_tick or tick_count >= max_ticks then
            finish_input_move(ok_tick and "done" or "input_failed")
            return true
        end
        return false
    end)

    state.last_move = string.format("%s input AddMovementInput started ticks=%d requested_d=%.0f dir=(%.2f,%.2f,%.2f)%s", reason or "move.input", max_ticks, horizontal_distance, direction.X or 0, direction.Y or 0, direction.Z or 0, hold_was_enabled and " " .. tostring(hold_release_detail) or "")
    return true, state.last_move
end

function slide_move_to_location(actor, destination, reason)
    local origin = feature_actor.actor_location(actor)
    if not origin then return false, "could not read selected actor location" end
    local distance = distance_between(origin, destination)
    if distance < 1.0 then return false, "slide move distance too small" end

    RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN = RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN + 1
    local move_token = RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN
    state.puppet_move_loop = true

    local was_puppet = state.puppet
    local was_quiet = state.quiet
    if not was_puppet then set_quiet_mode(actor, true) end
    set_path_following_enabled(actor, false)
    set_movement_disabled(actor, true)
    stop_active_movement(actor, true)

    local delta = {
        X = (destination.X or 0) - (origin.X or 0),
        Y = (destination.Y or 0) - (origin.Y or 0),
        Z = (destination.Z or 0) - (origin.Z or 0),
    }
    local yaw = atan2_radians(delta.Y, delta.X) * 180.0 / math.pi
    local rotation = { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }
    feature_actor.set_actor_rotation(actor, rotation)
    state.drive_yaw = yaw

    local duration_seconds = distance / PUPPET_MOVE_SPEED_CM_PER_SEC
    local max_ticks = math.max(2, math.min(PUPPET_MOVE_MAX_TICKS, math.ceil((duration_seconds * 1000.0) / PUPPET_MOVE_TICK_MS)))
    local tick_count = 0

    local function finish_slide(finish_reason)
        state.puppet_move_loop = false
        local final_location = feature_actor.actor_location(actor)
        stop_active_movement(actor, true)
        local keep_locked = was_puppet and state.puppet
        if keep_locked then
            set_movement_disabled(actor, true)
            set_path_following_enabled(actor, false)
        else
            set_path_following_enabled(actor, true)
            set_movement_disabled(actor, false)
            set_quiet_mode(actor, was_quiet)
        end
        state.last_move = string.format("%s slide SetActorLocation ticks=%d/%d reason=%s from=(%.0f,%.0f,%.0f) now=(%.0f,%.0f,%.0f) requested_d=%.0f yaw=%.1f", reason or "move.slide", tick_count, max_ticks, tostring(finish_reason or "done"), origin.X or 0, origin.Y or 0, origin.Z or 0, final_location and final_location.X or 0, final_location and final_location.Y or 0, final_location and final_location.Z or 0, distance, yaw)
    end

    if not LoopAsync then
        local ok_move, move_err = feature_actor.move_actor(actor, destination)
        finish_slide(ok_move and "no_loopasync" or tostring(move_err))
        return ok_move ~= false, state.last_move
    end

    LoopAsync(PUPPET_MOVE_TICK_MS, function()
        if RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN ~= move_token or RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN < module_puppet_move_token then
            finish_slide("cancelled")
            return true
        end
        if not core.is_valid(actor) or actor ~= current_actor() then
            state.puppet_move_loop = false
            return true
        end
        tick_count = tick_count + 1
        local alpha = math.min(1.0, tick_count / max_ticks)
        local next_location = {
            X = (origin.X or 0) + delta.X * alpha,
            Y = (origin.Y or 0) + delta.Y * alpha,
            Z = (origin.Z or 0) + delta.Z * alpha,
        }
        local ok_move = feature_actor.move_actor(actor, next_location)
        feature_actor.set_actor_rotation(actor, rotation)
        if ok_move == false or tick_count >= max_ticks then
            finish_slide(ok_move == false and "move_failed" or "done")
            return true
        end
        return false
    end)

    state.last_move = string.format("%s slide SetActorLocation started ticks=%d requested_d=%.0f yaw=%.1f", reason or "move.slide", max_ticks, distance, yaw)
    return true, state.last_move
end

function anim_slide_move_to_location(actor, destination, reason)
    local origin = feature_actor.actor_location(actor)
    if not origin then return false, "could not read selected actor location" end
    local distance = distance_between(origin, destination)
    if distance < 1.0 then return false, "anim move distance too small" end

    local delta = {
        X = (destination.X or 0) - (origin.X or 0),
        Y = (destination.Y or 0) - (origin.Y or 0),
        Z = (destination.Z or 0) - (origin.Z or 0),
    }
    local horizontal_distance = math.sqrt(delta.X * delta.X + delta.Y * delta.Y)
    if horizontal_distance < 1.0 then return false, "anim move horizontal distance too small" end
    local direction = { X = delta.X / horizontal_distance, Y = delta.Y / horizontal_distance, Z = 0.0 }
    local velocity = { X = direction.X * PUPPET_ANIM_SPEED_CM_PER_SEC, Y = direction.Y * PUPPET_ANIM_SPEED_CM_PER_SEC, Z = 0.0 }
    local yaw = atan2_radians(delta.Y, delta.X) * 180.0 / math.pi
    local rotation = { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }

    RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN = RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN + 1
    local move_token = RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN
    state.puppet_move_loop = true

    local was_puppet = state.puppet
    local was_quiet = state.quiet
    if not was_puppet then set_quiet_mode(actor, true) end
    set_path_following_enabled(actor, false)
    set_movement_disabled(actor, false)
    stop_active_movement(actor, false)
    feature_actor.set_actor_rotation(actor, rotation)
    state.drive_yaw = yaw

    local duration_seconds = distance / PUPPET_ANIM_SPEED_CM_PER_SEC
    local max_ticks = math.max(2, math.min(PUPPET_MOVE_MAX_TICKS, math.ceil((duration_seconds * 1000.0) / PUPPET_MOVE_TICK_MS)))
    local tick_count = 0
    local locomotion_notes = ""

    local function finish_anim_slide(finish_reason)
        state.puppet_move_loop = false
        local final_location = feature_actor.actor_location(actor)
        clear_locomotion_signal(actor)
        stop_active_movement(actor, true)
        local keep_locked = was_puppet and state.puppet
        if keep_locked then
            set_movement_disabled(actor, true)
            set_path_following_enabled(actor, false)
        else
            set_path_following_enabled(actor, true)
            set_movement_disabled(actor, false)
            set_quiet_mode(actor, was_quiet)
        end
        state.last_move = string.format("%s anim SetActorLocation+input ticks=%d/%d reason=%s from=(%.0f,%.0f,%.0f) now=(%.0f,%.0f,%.0f) requested_d=%.0f yaw=%.1f signal=%s", reason or "move.anim", tick_count, max_ticks, tostring(finish_reason or "done"), origin.X or 0, origin.Y or 0, origin.Z or 0, final_location and final_location.X or 0, final_location and final_location.Y or 0, final_location and final_location.Z or 0, distance, yaw, locomotion_notes ~= "" and locomotion_notes or "none")
    end

    if not LoopAsync then
        feed_locomotion_signal(actor, direction, velocity)
        local ok_move, move_err = move_actor_for_locomotion(actor, destination, rotation)
        finish_anim_slide(ok_move and "no_loopasync" or tostring(move_err))
        return ok_move ~= false, state.last_move
    end

    LoopAsync(PUPPET_MOVE_TICK_MS, function()
        if RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN ~= move_token or RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN < module_puppet_move_token then
            finish_anim_slide("cancelled")
            return true
        end
        if not core.is_valid(actor) or actor ~= current_actor() then
            state.puppet_move_loop = false
            clear_locomotion_signal(actor)
            return true
        end
        tick_count = tick_count + 1
        locomotion_notes = feed_locomotion_signal(actor, direction, velocity) or ""
        local alpha = math.min(1.0, tick_count / max_ticks)
        local next_location = {
            X = (origin.X or 0) + delta.X * alpha,
            Y = (origin.Y or 0) + delta.Y * alpha,
            Z = (origin.Z or 0) + delta.Z * alpha,
        }
        local ok_move = move_actor_for_locomotion(actor, next_location, rotation)
        feature_actor.set_actor_rotation(actor, rotation)
        if ok_move == false or tick_count >= max_ticks then
            finish_anim_slide(ok_move == false and "move_failed" or "done")
            return true
        end
        return false
    end)

    state.last_move = string.format("%s anim SetActorLocation+input started ticks=%d requested_d=%.0f yaw=%.1f", reason or "move.anim", max_ticks, distance, yaw)
    return true, state.last_move
end

local function set_puppet_mode(actor, enabled)
    if not core.is_valid(actor) then return false, "invalid target" end
    if enabled then
        if not state.puppet then
            state.puppet_restore = { quiet = state.quiet }
        end
        local ok_quiet, quiet_detail = set_quiet_mode(actor, true)
        set_path_following_enabled(actor, false)
        local ok_disable, disable_detail = set_movement_disabled(actor, true)
        local stop_detail = stop_active_movement(actor, true)
        state.puppet = true
        refresh_hold_anchor(actor)
        return true, "puppet=on style=" .. tostring(state.puppet_move_style or "anim") .. " " .. (ok_disable and disable_detail or tostring(disable_detail)) .. " stop=" .. (stop_detail ~= "" and stop_detail or "none") .. " quiet=" .. (ok_quiet and "on" or tostring(quiet_detail))
    end

    local restore = state.puppet_restore or {}
    state.puppet = false
    state.quiet = false
    RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN = RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN + 1
    state.puppet_move_loop = false
    clear_locomotion_signal(actor)
    set_path_following_enabled(actor, true)
    local ok_disable, disable_detail = set_movement_disabled(actor, false)
    local ok_quiet, quiet_detail = set_quiet_mode(actor, restore.quiet == true)
    state.puppet_restore = nil
    return true, "puppet=off " .. (ok_disable and disable_detail or tostring(disable_detail)) .. " quiet=" .. (ok_quiet and (restore.quiet and "on" or "off") or tostring(quiet_detail))
end

local function schedule_puppet_restore(actor, restore, delay_ms)
    if not core.is_valid(actor) then return false end
    return defer_on_game_thread(delay_ms or 80, function()
        if not core.is_valid(actor) then return end
        clear_locomotion_signal(actor)
        set_path_following_enabled(actor, true)
        set_movement_disabled(actor, false)
        set_quiet_mode(actor, restore and restore.quiet == true)
    end)
end

local function atan2_degrees(y_value, x_value)
    local radians
    if math.atan2 then
        radians = math.atan2(y_value, x_value)
    else
        radians = math.atan(y_value, x_value)
    end
    return radians * 180.0 / math.pi
end

local function face_location(actor, location, reason)
    if state.hold then
        local actor_location = feature_actor.actor_location(actor)
        if not actor_location then return false, "could not read actor location for hold rotation" end
        local yaw = atan2_degrees((location.Y or 0) - (actor_location.Y or 0), (location.X or 0) - (actor_location.X or 0))
        local rotation = { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }
        local ok_rotation = feature_actor.set_actor_rotation(actor, rotation)
        if not ok_rotation then return false, "hold SetActorRotation failed" end
        state.hold_rotation = rotation
        state.drive_yaw = yaw
        return true, string.format("%s hold SetActorRotation yaw=%.1f", reason or "face", yaw)
    end

    local movement_component = core.get_movement_component(actor)
    if core.is_valid(movement_component) and movement_component.BP_TryRotateTowardsPositionWithAMontage then
        local ok_face, result = pcall(function() return movement_component:BP_TryRotateTowardsPositionWithAMontage(location) end)
        if ok_face and result ~= false then
            return true, string.format("%s via rotation montage -> (%.0f, %.0f, %.0f)", reason or "face", location.X or 0, location.Y or 0, location.Z or 0)
        end
    end

    local actor_location = feature_actor.actor_location(actor)
    if not actor_location then return false, "could not read actor location for fallback rotation" end
    local yaw = atan2_degrees((location.Y or 0) - (actor_location.Y or 0), (location.X or 0) - (actor_location.X or 0))
    local ok_rotation = feature_actor.set_actor_rotation(actor, { Pitch = 0.0, Yaw = yaw, Roll = 0.0 })
    if not ok_rotation then return false, "rotation montage and SetActorRotation both failed" end
    return true, string.format("%s via SetActorRotation yaw=%.1f", reason or "face", yaw)
end

local function normalize_class_path(value)
    local class_path = core.trim(value)
    if class_path == "" then return "" end
    class_path = class_path:gsub("^/?Game/Plugins/GameFeatures/([^/]+)/Content/", "/%1/")
    class_path = class_path:gsub("^/?RSDragonwilds/Plugins/GameFeatures/([^/]+)/Content/", "/%1/")
    class_path = class_path:gsub("^/?Plugins/GameFeatures/([^/]+)/Content/", "/%1/")
    if class_path:sub(1, 8) == "/Script/" then return class_path end
    if class_path:sub(1, 1) ~= "/" then return class_path end

    local package_path, object_name = class_path:match("^(.-)%.([^%.]+)$")
    if package_path and object_name then
        if object_name:sub(-2) ~= "_C" then object_name = object_name .. "_C" end
        return package_path .. "." .. object_name
    end

    local asset_name = class_path:match("([^/]+)$") or ""
    if asset_name ~= "" and asset_name:sub(-2) ~= "_C" then asset_name = asset_name .. "_C" end
    return class_path .. "." .. asset_name
end

local function resolve_uclass(value)
    local class_path = normalize_class_path(value)
    if class_path == "" then return nil, "empty class path" end

    if StaticFindObject then
        local ok_find, class_object = pcall(StaticFindObject, class_path)
        if ok_find and core.is_valid(class_object) then return class_object, class_path end
    end
    if LoadObject then
        local ok_load, class_object = pcall(LoadObject, class_path)
        if ok_load and core.is_valid(class_object) then return class_object, class_path end
    end
    if LoadAsset then
        local ok_asset, class_object = pcall(LoadAsset, class_path)
        if ok_asset and core.is_valid(class_object) then return class_object, class_path end
    end

    if FindAllOf then
        local short_name = class_path:match("([^/.]+)$") or class_path
        for unused_index, container_class in ipairs({ "BlueprintGeneratedClass", "Class" }) do
            local ok_all, candidates = pcall(FindAllOf, container_class)
            if ok_all and type(candidates) == "table" then
                for candidate_index, candidate in ipairs(candidates) do
                    if core.is_valid(candidate) and core.object_friendly_name(candidate) == short_name then
                        return candidate, short_name
                    end
                end
            end
        end
    end

    return nil, "class not found: " .. class_path
end

local function get_attack_async_cdo()
    if not StaticFindObject then return nil end
    local ok_find, object = pcall(StaticFindObject, "/Script/Dominion.Default__PerformAiAttackAsyncAction")
    if ok_find and core.is_valid(object) then return object end
    return nil
end

function M.select(value_str)
    local arg = core.trim(value_str)
    local actor, source
    if arg == "" or arg == "@" or arg:lower() == "look" or arg:lower() == "reticle" then
        actor, source = feature_grab.pick_actor_under_reticle()
        if not core.is_valid(actor) then return false, tostring(source or "no actor under reticle") end
    else
        actor = feature_actor.resolve_actor_by_name(arg)
        source = "name"
        if not core.is_valid(actor) then return false, "actor not found: " .. arg end
    end

    drive_log("select validate " .. core.object_label(actor))
    local ok_target, surface = validate_target(actor)
    if not ok_target then return false, "target is not driveable: " .. tostring(surface) end
    drive_log("select validated surface=" .. tostring(surface))

    if state.actor and state.actor ~= actor then drive_log("select cleanup old " .. core.object_label(state.actor)) end
    if state.tune and core.is_valid(state.actor) then
        local ok_restore, detail = set_tune_mode(state.actor, false)
        if not ok_restore then return false, "cannot retarget before restoring previous tune session: " .. tostring(detail) end
    end
    if state.actor and state.actor ~= actor and state.brain_stopped and core.is_valid(state.actor) then
        pcall(function() start_brain(state.actor) end)
    end
    if state.actor and state.actor ~= actor and state.hold and core.is_valid(state.actor) then
        pcall(function() set_hold_mode(state.actor, false) end)
    end
    if state.actor and state.actor ~= actor and state.puppet and core.is_valid(state.actor) then
        pcall(function() set_puppet_mode(state.actor, false) end)
    end
    if state.actor and state.actor ~= actor and state.tune_root_scaled and core.is_valid(state.actor) then
        pcall(function() call1(state.actor, "BP_SetRootMotionScale", 1.0) end)
    end
    if state.actor and state.actor ~= actor and state.roamdata_disabled and core.is_valid(state.actor) then
        pcall(function() set_roamdata_enabled(state.actor, true) end)
    end
    if state.actor and state.actor ~= actor and state.quiet and core.is_valid(state.actor) then
        pcall(function() set_quiet_mode(state.actor, false) end)
    end

    state.actor = actor
    state.name = core.object_label(actor)
    state.source = source or "unknown"
    state.brain_stopped = false
    state.quiet = false
    state.hold = false
    state.hold_mode = "lock"
    state.hold_anchor = nil
    state.hold_rotation = nil
    state.hold_move_loop = false
    state.input_move_loop = false
    state.puppet = false
    state.puppet_move_loop = false
    state.puppet_restore = nil
    state.puppet_move_style = "native"
    state.tune = false
    state.tune_restore = nil
    state.tune_root_scaled = false
    state.roamdata_disabled = false
    state.roamdata_restore = nil
    state.drive_yaw = nil
    state.last_move = nil

    local camera_note = ""
    if state.camera then
        drive_log("select retarget camera " .. core.object_label(actor))
        local ok_camera, camera_detail = ensure_follow_camera(actor, DEFAULT_BLEND_SECONDS)
        camera_note = ok_camera and " camera=retargeted" or " camera_failed=" .. tostring(camera_detail)
        drive_log("select retarget " .. tostring(camera_detail))
    end

    return true, string.format("selected %s [class=%s, src=%s, surface=%s]%s", state.name, feature_field.class_name_of(actor) or "<unknown>", state.source, surface, camera_note)
end

function M.status()
    local actor = current_actor()
    if not actor then return true, "idle" end
    local movement_component = core.get_movement_component(actor)
    local controller = core.get_controller(actor)
    local brain = core.get_brain_component(actor)
    local actions_component = core.get_actions_component(actor)
    local movement_surface = core.is_valid(movement_component) and (movement_component.BP_AiMoveTo and "BP_AiMoveTo" or feature_field.class_name_of(movement_component) or "component") or "none"
    local controller_surface = core.is_valid(controller) and (feature_field.class_name_of(controller) or "controller") or "none"
    local brain_surface = core.is_valid(brain) and "yes" or "no"
    local actions_surface = core.is_valid(actions_component) and "yes" or "no"
    local movement_disabled = is_movement_disabled(actor)
    return true, string.format(
        "selected=%s valid=true camera=%s player_hidden=%s brain_stopped=%s quiet=%s tune=%s roamdata=%s ai_movement=%s hold=%s hold_mode=%s puppet=%s puppet_style=%s input_move=%s puppet_move=%s movement_disabled=%s drive_yaw=%s movement=%s controller=%s brain=%s actions=%s last_move=%s",
        state.name or core.object_label(actor), core.bool_word(state.camera), core.bool_word(state.player_hidden), core.bool_word(state.brain_stopped), core.bool_word(state.quiet), core.bool_word(state.tune), state.roamdata_disabled and "off" or "on", state.ai_movement_enabled == nil and "unknown" or core.bool_word(state.ai_movement_enabled), core.bool_word(state.hold), state.hold_mode or "lock", core.bool_word(state.puppet), state.puppet_move_style or "native", core.bool_word(state.input_move_loop), core.bool_word(state.puppet_move_loop), movement_disabled == nil and "unknown" or core.bool_word(movement_disabled), state.drive_yaw == nil and "none" or string.format("%.1f", state.drive_yaw),
        movement_surface, controller_surface, brain_surface, actions_surface, tostring(state.last_move or "none"))
end

function M.current_actor()
    return current_actor()
end

function M.release_puppet_for_retarget()
    if not state.puppet then return true, "puppet=idle" end
    local actor = state.actor
    local restore = state.puppet_restore or {}
    state.puppet = false
    state.quiet = false
    RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN = RSDWTOOLS_NPC_DRIVE_PUPPET_MOVE_TOKEN + 1
    state.puppet_move_loop = false
    state.puppet_restore = nil
    if not core.is_valid(actor) then return true, "puppet=cleared" end
    local ok_defer = schedule_puppet_restore(actor, restore, 80)
    return true, ok_defer and "puppet=off scheduled" or "puppet=off schedule failed"
end

function M.camera_active()
    return state.camera == true and core.is_valid(state.camera_actor) and state.camera_external_exit ~= true
end

function M.inspect_active(actor)
    if state.camera ~= true then return false end
    if not core.is_valid(state.camera_actor) or state.camera_external_exit == true then return false end
    if core.is_valid(actor) then
        local current = current_actor()
        if not same_object(current, actor) then return false end
    end
    return true
end

function M.probe()
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local controller = core.get_controller(actor)
    local movement_component = core.get_movement_component(actor)
    local path_component = core.get_path_following_component(actor)
    local quiet_components = collect_quiet_components(actor)
    local ok_should_walk, should_walk = call0(actor, "GetShouldWalk")
    local ok_can_roam, can_roam = call0(actor, "CanRoam")
    local ok_current_alertness, current_alertness = call0(actor, "GetCurrentAlertnessState")
    local ok_distance, distance_multiplier = call0(actor, "GetDistanceMultiplier")
    local ok_preferred_distance, preferred_distance = call0(actor, "GetPreferredDistanceToTarget")
    local ok_specified_target, specified_target = call0(actor, "GetSpecifiedTargetOverride")
    if ok_specified_target then specified_target = facade.to_actor(specified_target) end
    local ok_input_ignored, input_ignored = call0(actor, "IsMoveInputIgnored")
    local ok_move_status, move_status = call0(controller, "GetMoveStatus")
    local ok_path_status, path_status = call0(path_component, "GetStatus")
    local loaded_data = safe_object_field(actor, "LoadedData")
    local current_target
    pcall(function() current_target = facade.to_actor(actor.CurrentTarget) end)
    local movement_disabled = is_movement_disabled(actor)

    return true, string.format(
        "selected=%s class=%s should_walk=%s can_roam=%s alertness=%s movement_disabled=%s input_ignored=%s distance_multiplier=%s preferred_distance=%s current_target=%s specified_target=%s loaded_data=%s controller=%s movement=%s path=%s move_status=%s path_status=%s suppress_components=%d[%s]",
        state.name or core.object_label(actor), feature_field.class_name_of(actor) or "<unknown>", format_probe_value(ok_should_walk, should_walk), format_probe_value(ok_can_roam, can_roam), format_probe_value(ok_current_alertness, current_alertness), movement_disabled == nil and "unknown" or tostring(movement_disabled), format_probe_value(ok_input_ignored, input_ignored), format_probe_value(ok_distance, distance_multiplier), format_probe_value(ok_preferred_distance, preferred_distance), core.object_label(current_target), format_probe_value(ok_specified_target, specified_target), core.object_label(loaded_data), core.object_label(controller), core.object_label(movement_component), core.object_label(path_component), format_probe_value(ok_move_status, move_status), format_probe_value(ok_path_status, path_status), #quiet_components, component_labels(quiet_components))
end

function M.tune(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local arg = core.trim(value_str):lower()
    local command, tail = arg:match("^(%S*)%s*(.-)$")
    command = core.trim(command)
    tail = core.trim(tail)
    if command == "root" or command == "rootmotion" or command == "root_motion" then
        local scale = tonumber(tail)
        if not scale then return false, "usage: npc.drive.tune root <scale>" end
        local ok_root, root_result = call1(actor, "BP_SetRootMotionScale", scale)
        if not ok_root then return false, "BP_SetRootMotionScale failed: " .. tostring(root_result) end
        state.tune_root_scaled = math.abs(scale - 1.0) > 0.001
        return true, string.format("root_motion=%.3f", scale)
    end

    local parsed = core.parse_onoff(command ~= "" and command or value_str)
    if parsed == "invalid" then return false, "usage: npc.drive.tune [on|off|toggle] or npc.drive.tune root <scale>" end
    local next_enabled = parsed
    if next_enabled == nil then next_enabled = not state.tune end
    return set_tune_mode(actor, next_enabled)
end

function M.aimove(value_str)
    local parsed = core.parse_onoff(value_str)
    if parsed == "invalid" then return false, "usage: npc.drive.aimove [on|off|toggle]" end
    local next_enabled = parsed
    if next_enabled == nil then next_enabled = state.ai_movement_enabled == false end
    return set_global_ai_movement(next_enabled)
end

function M.roamdata(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local arg = core.trim(value_str):lower()
    if arg == "probe" or arg == "status" or arg == "get" then
        local data, data_err = get_loaded_data(actor)
        if not core.is_valid(data) then return false, tostring(data_err) end
        return true, roamdata_snapshot_text(data)
    end
    if arg == "defaults" or arg == "default" or arg == "kebbit" then
        return set_roamdata_values(actor, true, 200.0, 400.0, 3.0, 6.0, nil, nil)
    end
    if arg:sub(1, 4) == "set " then
        local can_roam_text, min_text, max_text, min_wait_text, max_wait_text, run_text, walk_text = core.trim(value_str):match("^%S+%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*(%S*)%s*(%S*)$")
        local can_roam = core.parse_onoff(can_roam_text)
        local min_distance = tonumber(min_text)
        local max_distance = tonumber(max_text)
        local min_wait = tonumber(min_wait_text)
        local max_wait = tonumber(max_wait_text)
        local run_speed = run_text ~= "" and tonumber(run_text) or nil
        local walk_speed = walk_text ~= "" and tonumber(walk_text) or nil
        if can_roam == nil or can_roam == "invalid" or not min_distance or not max_distance or not min_wait or not max_wait or (run_text ~= "" and not run_speed) or (walk_text ~= "" and not walk_speed) then
            return false, "usage: npc.drive.roamdata set <on|off> <minDist> <maxDist> <minWait> <maxWait> [runSpeed walkSpeed]"
        end
        return set_roamdata_values(actor, can_roam, min_distance, max_distance, min_wait, max_wait, run_speed, walk_speed)
    end
    local parsed = core.parse_onoff(value_str)
    if parsed == "invalid" then return false, "usage: npc.drive.roamdata [off|on|toggle|probe|defaults] or npc.drive.roamdata set <on|off> <minDist> <maxDist> <minWait> <maxWait> [runSpeed walkSpeed]" end
    local next_enabled = parsed
    if next_enabled == nil then next_enabled = state.roamdata_disabled end
    return set_roamdata_enabled(actor, next_enabled)
end

function M.puppet(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local body = core.trim(value_str)
    local command = core.trim((body:match("^(%S*)") or "")):lower()
    if command == "native" or command == "ai" or command == "aimove" or command == "montage" or command == "bp" then
        state.puppet_move_style = "native"
        return true, "puppet_style=native puppet=" .. core.bool_word(state.puppet)
    end
    if command == "anim" or command == "animation" or command == "hybrid" or command == "walk" then
        state.puppet_move_style = "anim"
        return true, "puppet_style=anim puppet=" .. core.bool_word(state.puppet)
    end
    if command == "slide" or command == "glide" or command == "direct" then
        state.puppet_move_style = "slide"
        return true, "puppet_style=slide puppet=" .. core.bool_word(state.puppet)
    end
    local parsed = core.parse_onoff(value_str)
    if parsed == "invalid" then return false, "usage: npc.drive.puppet [on|off|toggle|native|anim|slide]" end
    local next_enabled = parsed
    if next_enabled == nil then next_enabled = not state.puppet end
    return set_puppet_mode(actor, next_enabled)
end

local function stop_camera_backend()
    local ok_reset, detail = reset_view_target(CAMERA_RESET_BLEND_SECONDS)
    if not ok_reset then return false, detail end
    state.camera = false
    state.camera_mouse = false
    state.camera_external_exit = false
    state.camera_view_target_seen = false
    state.camera_view_mismatch_ticks = 0
    state.camera_glide_until = nil
    state.camera_glide_from_location = nil
    state.camera_glide_from_rotation = nil
    return true, "camera=player camera_actor=kept"
end

function M.camera(value_str)
    local body = core.trim(value_str)
    local explicit_off = false
    for token in string.gmatch(body, "%S+") do
        if core.parse_onoff(token) == false then explicit_off = true end
    end
    if explicit_off then return stop_camera_backend() end

    local actor, err = selected_or_error()
    if not actor then return false, err end
    local parsed = nil
    local saw_action = false
    local numbers = {}
    for token in string.gmatch(body, "%S+") do
        local action = core.parse_onoff(token)
        local view = core.parse_camera_view(token)
        local number = tonumber(token)
        if action ~= "invalid" then
            parsed = action
            saw_action = true
        elseif view then
            state.camera_view = view
            if view == "orbit" then
                local rotation = feature_actor.actor_rotation(actor) or { Yaw = 0.0 }
                ensure_orbit_angles(actor, tonumber(rotation.Yaw) or 0.0)
            end
        elseif number then
            numbers[#numbers + 1] = number
        else
            return false, "usage: npc.drive.camera [on|off|toggle] [front|frontright|frontleft|left|right|back] [distance_cm height_cm]"
        end
    end
    local distance = numbers[1]
    local height = numbers[2]
    if distance then set_camera_distance(distance) end
    if height then state.camera_height = math.max(40.0, math.min(height, 800.0)) end
    local next_enabled = parsed
    if next_enabled == nil then
        next_enabled = saw_action and (not state.camera) or ((body ~= "") and true or not state.camera)
    end
    if next_enabled then
        local ok_camera, detail = ensure_follow_camera(actor, DEFAULT_BLEND_SECONDS)
        if not ok_camera then return false, detail end
        return true, detail
    end
    return stop_camera_backend()
end

function M.camera_orbit(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local body = core.trim(value_str)
    local words = {}
    for token in string.gmatch(body, "%S+") do words[#words + 1] = token end
    local actor_rotation = feature_actor.actor_rotation(actor) or { Yaw = 0.0 }
    local actor_yaw = tonumber(actor_rotation.Yaw) or 0.0
    ensure_orbit_angles(actor, actor_yaw)
    local current = state.camera_orbit_yaw or core.normalize_yaw(actor_yaw + 28.0)
    local command = (words[1] or "right"):lower()
    local amount = tonumber(words[2]) or 15.0
    if command == "left" or command == "l" then
        current = current + math.abs(amount)
    elseif command == "right" or command == "r" then
        current = current - math.abs(amount)
    elseif command == "front" or command == "face" then
        current = actor_yaw
    elseif command == "frontright" or command == "front-right" or command == "inspect" then
        current = actor_yaw + 28.0
    elseif command == "frontleft" or command == "front-left" then
        current = actor_yaw - 28.0
    elseif command == "back" or command == "behind" then
        current = actor_yaw + 180.0
    elseif command == "profile-right" then
        current = actor_yaw + 90.0
    elseif command == "profile-left" then
        current = actor_yaw - 90.0
    elseif command == "yaw" or command == "set" then
        if not tonumber(words[2]) then return false, "usage: npc.inspect.orbit yaw <degrees>" end
        current = tonumber(words[2]) or current
    elseif command == "pitch" then
        if not tonumber(words[2]) then return false, "usage: npc.inspect.orbit pitch <degrees>" end
        state.camera_orbit_pitch = clamp_number(tonumber(words[2]) or state.camera_orbit_pitch or default_orbit_pitch(), MIN_CAMERA_ORBIT_PITCH, MAX_CAMERA_ORBIT_PITCH)
    elseif tonumber(command) then
        current = current + tonumber(command)
    elseif command == "reset" or command == "center" or command == "orbit" or command == "" then
        current = actor_yaw + 28.0
    else
        return false, "usage: npc.inspect.orbit [left|right|front|frontright|frontleft|back|profile-left|profile-right|yaw <degrees>|pitch <degrees>|<delta_degrees>] [amount]"
    end

    local distance = nil
    local height = nil
    if command == "left" or command == "l" or command == "right" or command == "r" or command == "yaw" or command == "set" or command == "pitch" then
        distance = tonumber(words[3])
        height = tonumber(words[4])
    elseif tonumber(command) then
        distance = tonumber(words[2])
        height = tonumber(words[3])
    else
        distance = tonumber(words[2])
        height = tonumber(words[3])
    end
    if distance then set_camera_distance(distance) end
    if height then state.camera_height = math.max(40.0, math.min(height, 800.0)) end

    state.camera_view = "orbit"
    state.camera_orbit_yaw = core.normalize_yaw(current)
    local ok_camera, detail = ensure_follow_camera(actor, 0.12)
    if not ok_camera then return false, detail end
    return true, string.format("orbit_yaw=%.1f pitch=%.1f distance=%.0f height=%.0f", state.camera_orbit_yaw, state.camera_orbit_pitch or default_orbit_pitch(), state.camera_distance, state.camera_height)
end

function M.camera_mouse(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local body = core.trim(value_str)
    local parsed = nil
    local numbers = {}
    for token in string.gmatch(body, "%S+") do
        local low = token:lower()
        local action = core.parse_onoff(token)
        local number = tonumber(token)
        if action ~= "invalid" then
            parsed = action
        elseif low == "speed" or low == "sens" or low == "sensitivity" then
            -- accepted as a readability token before numeric values
        elseif number then
            numbers[#numbers + 1] = number
        else
            return false, "usage: npc.inspect.mouse [on|off|toggle] [yaw_sensitivity pitch_sensitivity]"
        end
    end
    if numbers[1] then state.camera_mouse_yaw_sensitivity = math.max(0.01, math.min(numbers[1], 1.0)) end
    if numbers[2] then state.camera_mouse_pitch_sensitivity = math.max(0.01, math.min(numbers[2], 1.0)) end

    local next_enabled = parsed
    if next_enabled == nil then next_enabled = not state.camera_mouse end
    state.camera_mouse = next_enabled and true or false
    state.mouse_last_x, state.mouse_last_y = nil, nil
    if state.camera_mouse then
        state.camera_view = "orbit"
        local rotation = feature_actor.actor_rotation(actor) or { Yaw = 0.0 }
        ensure_orbit_angles(actor, tonumber(rotation.Yaw) or 0.0)
        local ok_camera, detail = ensure_follow_camera(actor, 0.12)
        if not ok_camera then
            state.camera_mouse = false
            return false, detail
        end
        ensure_camera_zoom_wheel()
        start_mouse_loop()
        return true, string.format("mouse=on yaw_sens=%.2f pitch_sens=%.2f source=%s zoom=wheel distance=%.0f", state.camera_mouse_yaw_sensitivity, state.camera_mouse_pitch_sensitivity, tostring(state.camera_mouse_source or "polling"), state.camera_distance)
    end
    return true, "mouse=off"
end

function M.camera_focus(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local body = core.trim(value_str)
    local words = {}
    for token in string.gmatch(body, "%S+") do words[#words + 1] = token end
    local command = (words[1] or "status"):lower()
    local value = tonumber(words[2])
    if command == "bounds" or command == "center" or command == "body" then
        state.camera_focus_mode = "bounds"
    elseif command == "aim" or command == "head" then
        state.camera_focus_mode = "aim"
    elseif command == "reset" or command == "zero" then
        state.camera_focus_mode = "bounds"
        state.camera_focus_z_offset = 0.0
    elseif command == "up" then
        state.camera_focus_z_offset = (tonumber(state.camera_focus_z_offset) or 0.0) + math.abs(value or 10.0)
    elseif command == "down" then
        state.camera_focus_z_offset = (tonumber(state.camera_focus_z_offset) or 0.0) - math.abs(value or 10.0)
    elseif command == "z" or command == "offset" or command == "set" then
        if value == nil then return false, "usage: npc.inspect.focus z <offset>" end
        state.camera_focus_z_offset = math.max(-300.0, math.min(value, 300.0))
    elseif tonumber(command) then
        state.camera_focus_z_offset = math.max(-300.0, math.min(tonumber(command) or 0.0, 300.0))
    elseif command == "status" or command == "" then
        -- no-op
    else
        return false, "usage: npc.inspect.focus [bounds|aim|up <cm>|down <cm>|z <offset>|reset]"
    end
    state.camera_focus_z_offset = math.max(-300.0, math.min(tonumber(state.camera_focus_z_offset) or 0.0, 300.0))
    if state.camera and core.is_valid(state.camera_actor) then
        local location, rotation = compute_follow_camera_pose(actor)
        if location then set_actor_pose(state.camera_actor, location, rotation) end
    end
    return true, string.format("focus=%s z_offset=%.0f", state.camera_focus_mode or "bounds", tonumber(state.camera_focus_z_offset) or 0.0)
end

function M.camera_input_status()
    return string.format(
        "mouse=%s samples=%d last=%.2f,%.2f source=%s zoom_samples=%d last_zoom=%.1f zoom_source=%s distance=%.0f focus=%s z_offset=%.0f view=%s seen=%s mismatch=%d orbit_yaw=%s pitch=%s",
        core.bool_word(state.camera_mouse), state.camera_mouse_samples or 0,
        tonumber(state.camera_mouse_last_dx) or 0.0, tonumber(state.camera_mouse_last_dy) or 0.0,
        tostring(state.camera_mouse_source or "idle"),
        state.camera_zoom_samples or 0,
        tonumber(state.camera_zoom_last_delta) or 0.0,
        tostring(state.camera_zoom_source or "idle"),
        tonumber(state.camera_distance) or DEFAULT_CAMERA_DISTANCE_CM,
        tostring(state.camera_focus_mode or "bounds"), tonumber(state.camera_focus_z_offset) or 0.0,
        camera_view_target_state(), core.bool_word(state.camera_view_target_seen), state.camera_view_mismatch_ticks or 0,
        state.camera_orbit_yaw and string.format("%.1f", state.camera_orbit_yaw) or "-",
        state.camera_orbit_pitch and string.format("%.1f", state.camera_orbit_pitch) or "-"
    )
end

function M.repair_player_input(value_str)
    return repair_player_ui_input(core.trim(value_str))
end

function M.set_player_input_locked(locked, reason)
    return set_player_input_locked(locked, reason)
end

function M.hideplayer(value_str)
    local parsed = core.parse_onoff(value_str)
    if parsed == "invalid" then return false, "usage: npc.drive.hideplayer [on|off|toggle]" end
    local next_hidden = parsed
    if next_hidden == nil then next_hidden = not state.player_hidden end
    return set_player_hidden(next_hidden)
end

function M.brain(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local arg = core.trim(value_str):lower()
    if arg == "" or arg == "toggle" then
        if state.brain_stopped then return start_brain(actor) end
        if state.quiet then return set_quiet_mode(actor, false) end
        local ok_brain, detail = stop_brain(actor)
        if ok_brain then return true, detail end
        local ok_quiet, quiet_detail = set_quiet_mode(actor, true)
        if ok_quiet then return true, "brain=no; " .. quiet_detail end
        return false, tostring(detail) .. "; quiet fallback failed: " .. tostring(quiet_detail)
    end
    if arg == "stop" or arg == "pause" or arg == "off" then
        local ok_brain, detail = stop_brain(actor)
        if ok_brain then return true, detail end
        local ok_quiet, quiet_detail = set_quiet_mode(actor, true)
        if ok_quiet then return true, "brain=no; " .. quiet_detail end
        return false, tostring(detail) .. "; quiet fallback failed: " .. tostring(quiet_detail)
    end
    if arg == "start" or arg == "resume" or arg == "restart" or arg == "on" then
        local notes = {}
        if state.brain_stopped then
            local ok_brain, detail = start_brain(actor)
            notes[#notes + 1] = ok_brain and detail or "brain_start_failed=" .. tostring(detail)
        end
        if state.quiet then
            local ok_quiet, detail = set_quiet_mode(actor, false)
            notes[#notes + 1] = ok_quiet and detail or "quiet_failed=" .. tostring(detail)
        end
        if #notes == 0 then return true, "brain/quiet already running" end
        return true, table.concat(notes, "; ")
    end
    return false, "usage: npc.drive.brain [stop|start|toggle]"
end

function M.quiet(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local parsed = core.parse_onoff(value_str)
    if parsed == "invalid" then return false, "usage: npc.drive.quiet [on|off|toggle]" end
    local next_enabled = parsed
    if next_enabled == nil then next_enabled = not state.quiet end
    return set_quiet_mode(actor, next_enabled)
end

function M.hold(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local arg = core.trim(value_str):lower()
    local command, tail = arg:match("^(%S*)%s*(.-)$")
    command = core.trim(command)
    if command == "pin" or command == "hard" then
        state.hold_mode = "pin"
        if state.hold then return set_hold_mode(actor, true) end
        return set_hold_mode(actor, true)
    end
    if command == "lock" or command == "soft" then
        state.hold_mode = "lock"
        if state.hold then return set_hold_mode(actor, true) end
        return set_hold_mode(actor, true)
    end
    local parsed = core.parse_onoff(command ~= "" and command or value_str)
    if parsed == "invalid" then return false, "usage: npc.drive.hold [on|off|toggle|lock|pin]" end
    local next_enabled = parsed
    if next_enabled == nil then next_enabled = not state.hold end
    if next_enabled then state.hold_mode = "lock" end
    return set_hold_mode(actor, next_enabled)
end

function M.move(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local body = core.trim(value_str)
    local command, tail = body:match("^(%S*)%s*(.-)$")
    command = core.trim(command)
    tail = core.trim(tail)
    if command == "" then command = "forward" end

    local command_lower = command:lower()
    local direct = false
    local input = false
    local slide = false
    local anim = false
    local native = false
    if command_lower == "direct" or command_lower == "nudge" or command_lower == "teleport" then
        direct = true
        command, tail = tail:match("^(%S*)%s*(.-)$")
        command = core.trim(command)
        tail = core.trim(tail)
        if command == "" then command = "forward" end
        command_lower = command:lower()
    elseif command_lower == "input" or command_lower == "pawn" or command_lower == "manual" then
        input = true
        command, tail = tail:match("^(%S*)%s*(.-)$")
        command = core.trim(command)
        tail = core.trim(tail)
        if command == "" then command = "forward" end
        command_lower = command:lower()
    elseif command_lower == "slide" or command_lower == "puppet" then
        slide = true
        command, tail = tail:match("^(%S*)%s*(.-)$")
        command = core.trim(command)
        tail = core.trim(tail)
        if command == "" then command = "forward" end
        command_lower = command:lower()
    elseif command_lower == "anim" or command_lower == "animation" or command_lower == "hybrid" or command_lower == "walk" then
        anim = true
        command, tail = tail:match("^(%S*)%s*(.-)$")
        command = core.trim(command)
        tail = core.trim(tail)
        if command == "" then command = "forward" end
        command_lower = command:lower()
    elseif command_lower == "native" or command_lower == "ai" or command_lower == "aimove" or command_lower == "montage" or command_lower == "bp" then
        native = true
        command, tail = tail:match("^(%S*)%s*(.-)$")
        command = core.trim(command)
        tail = core.trim(tail)
        if command == "" then command = "forward" end
        command_lower = command:lower()
    end
    if command_lower == "reticle" or command_lower == "look" or command_lower == "to_reticle" or command_lower == "to-reticle" then
        local hit_actor, location, source, location_err = feature_grab.pick_location_under_reticle()
        if not location then return false, tostring(location_err or "no reticle location") end
        if direct then return direct_move_to_location(actor, location, "move.direct.reticle:" .. tostring(source or "unknown")) end
        if input then return input_move_to_location(actor, location, "move.input.reticle:" .. tostring(source or "unknown")) end
        if native or (state.puppet and state.puppet_move_style == "native" and not slide and not anim) then return native_move_to_location(actor, location, "move.native.reticle:" .. tostring(source or "unknown")) end
        if anim or (state.puppet and state.puppet_move_style ~= "slide" and not slide) then return anim_slide_move_to_location(actor, location, "move.anim.reticle:" .. tostring(source or "unknown")) end
        if slide or state.puppet then return slide_move_to_location(actor, location, "move.slide.reticle:" .. tostring(source or "unknown")) end
        return move_to_location(actor, location, "move.reticle:" .. tostring(source or "unknown"))
    end

    local direction = command_lower
    local distance = tonumber(tail)
    if tonumber(command_lower) then
        direction = "forward"
        distance = tonumber(command_lower)
    end
    distance = distance or DEFAULT_STEP_CM

    local forward, right = camera_horizontal_basis(actor)
    local direction_map = {
        forward = forward,
        fwd = forward,
        back = { X = -forward.X, Y = -forward.Y, Z = 0.0 },
        backward = { X = -forward.X, Y = -forward.Y, Z = 0.0 },
        left = { X = -right.X, Y = -right.Y, Z = 0.0 },
        right = right,
    }
    local vector = direction_map[direction]
    if not vector then return false, "usage: npc.drive.move <forward|back|left|right|reticle> [distance_cm]" end

    local origin = feature_actor.actor_location(actor)
    if not origin then return false, "could not read selected actor location" end
    local destination = {
        X = (origin.X or 0) + vector.X * distance,
        Y = (origin.Y or 0) + vector.Y * distance,
        Z = (origin.Z or 0) + vector.Z * distance,
    }
    if direct then return direct_move_to_location(actor, destination, "move.direct." .. direction) end
    if input then return input_move_to_location(actor, destination, "move.input." .. direction) end
    if native or (state.puppet and state.puppet_move_style == "native" and not slide and not anim) then return native_move_to_location(actor, destination, "move.native." .. direction) end
    if anim or (state.puppet and state.puppet_move_style ~= "slide" and not slide) then return anim_slide_move_to_location(actor, destination, "move.anim." .. direction) end
    if slide or state.puppet then return slide_move_to_location(actor, destination, "move.slide." .. direction) end
    return move_to_location(actor, destination, "move." .. direction)
end

function M.face(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local arg = core.trim(value_str):lower()
    if arg == "" or arg == "reticle" or arg == "look" or arg == "to_reticle" or arg == "to-reticle" then
        local hit_actor, location, source, location_err = feature_grab.pick_location_under_reticle()
        if not location and arg ~= "" then return false, tostring(location_err or "no reticle location") end
        if location then return face_location(actor, location, "face." .. tostring(source or "reticle")) end
    end

    local origin = feature_actor.actor_location(actor)
    if not origin then return false, "could not read selected actor location" end
    local forward = camera_horizontal_basis(actor)
    local destination = {
        X = (origin.X or 0) + forward.X * DEFAULT_FACE_CM,
        Y = (origin.Y or 0) + forward.Y * DEFAULT_FACE_CM,
        Z = origin.Z or 0,
    }
    return face_location(actor, destination, "face.camera")
end

local function schedule_stop_jumping(actor)
    if not LoopAsync or not ExecuteInGameThread or not core.is_valid(actor) or not actor.StopJumping then return false end
    local ok_loop = pcall(function()
        LoopAsync(JUMP_STOP_DELAY_MS, function()
            ExecuteInGameThread(function()
                if core.is_valid(actor) and actor.StopJumping then
                    pcall(function() return actor:StopJumping() end)
                end
            end)
            return true
        end)
    end)
    return ok_loop
end

function M.jump(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local text = core.trim(value_str):lower()
    local force_launch = false
    local jump_z = DEFAULT_NPC_JUMP_Z
    for token in text:gmatch("%S+") do
        if token == "launch" or token == "force" then
            force_launch = true
        else
            local number = tonumber(token)
            if number then jump_z = clamp_number(number, MIN_NPC_JUMP_Z, MAX_NPC_JUMP_Z) end
        end
    end

    local notes = {}
    local can_jump = nil
    if actor.CanJump then
        local ok_can, result = pcall(function() return actor:CanJump() end)
        if ok_can then can_jump = result == true else notes[#notes + 1] = "CanJump failed" end
    end

    if not force_launch and can_jump ~= false and actor.Jump then
        local ok_jump, result = pcall(function() return actor:Jump() end)
        if ok_jump then
            local stopped = schedule_stop_jumping(actor)
            return true, "jump requested " .. core.object_label(actor) .. (stopped and " stop=scheduled" or "")
        end
        notes[#notes + 1] = "Jump failed: " .. tostring(result)
    elseif not force_launch and can_jump == false then
        notes[#notes + 1] = "CanJump=false"
    end

    if actor.LaunchCharacter then
        local velocity = { X = 0.0, Y = 0.0, Z = jump_z }
        local ok_launch, result = pcall(function() return actor:LaunchCharacter(velocity, false, true) end)
        if ok_launch then
            return true, string.format("launch jump %s z=%.0f%s", core.object_label(actor), jump_z, #notes > 0 and " (" .. table.concat(notes, "; ") .. ")" or "")
        end
        notes[#notes + 1] = "LaunchCharacter failed: " .. tostring(result)
    end

    return false, "selected NPC has no usable Jump/LaunchCharacter surface" .. (#notes > 0 and ": " .. table.concat(notes, "; ") or "")
end

function M.attack(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local class_path = core.trim(value_str)
    if class_path == "" then return false, "usage: npc.drive.attack <AiAttackDataClassPath>" end
    local attack_class, resolved = resolve_uclass(class_path)
    if not core.is_valid(attack_class) then return false, tostring(resolved) end
    local attack_cdo = get_attack_async_cdo()
    if not core.is_valid(attack_cdo) or not attack_cdo.PerformAiAttack then return false, "PerformAiAttack CDO/method not found" end
    local ok_attack, result = pcall(function() return attack_cdo:PerformAiAttack(actor, attack_class) end)
    if not ok_attack then return false, "PerformAiAttack failed: " .. tostring(result) end
    return true, "attack dispatched " .. core.object_friendly_name(attack_class)
end

function M.action(value_str)
    local actor, err = selected_or_error()
    if not actor then return false, err end
    local class_path = core.trim(value_str)
    if class_path == "" then return false, "usage: npc.drive.action <DominionAIActionClassPath>" end
    local action_class, resolved = resolve_uclass(class_path)
    if not core.is_valid(action_class) then return false, tostring(resolved) end
    local actions_component = core.get_actions_component(actor)
    if not core.is_valid(actions_component) or not actions_component.BP_StartAction then return false, "selected AI has no BP_StartAction component" end
    local ok_action, result = pcall(function() return actions_component:BP_StartAction(action_class) end)
    if not ok_action then return false, "BP_StartAction failed: " .. tostring(result) end
    return true, "action started " .. core.object_friendly_name(action_class)
end

function M.clear()
    local notes = {}
    local actor = current_actor()

    if state.camera then
        local ok_camera, detail = stop_camera_backend()
        notes[#notes + 1] = ok_camera and tostring(detail) or "camera_failed=" .. tostring(detail)
    end
    if state.player_hidden then
        local ok_hidden, detail = set_player_hidden(false)
        notes[#notes + 1] = ok_hidden and "player_hidden=off" or "player_unhide_failed=" .. tostring(detail)
    end
    if state.brain_stopped and actor then
        local ok_brain, detail = start_brain(actor)
        notes[#notes + 1] = ok_brain and "brain=running" or "brain_start_failed=" .. tostring(detail)
    end
    if state.tune and actor then
        local ok_tune, detail = set_tune_mode(actor, false)
        notes[#notes + 1] = ok_tune and "tune=off" or "tune_failed=" .. tostring(detail)
    end
    if state.tune_root_scaled and actor then
        local ok_root, detail = call1(actor, "BP_SetRootMotionScale", 1.0)
        notes[#notes + 1] = ok_root and "root_motion=1" or "root_motion_failed=" .. tostring(detail)
    end
    if state.roamdata_disabled and actor then
        local ok_roamdata, detail = set_roamdata_enabled(actor, true)
        notes[#notes + 1] = ok_roamdata and "roamdata=on" or "roamdata_failed=" .. tostring(detail)
    end
    if state.ai_movement_enabled == false then
        local ok_aimove, detail = set_global_ai_movement(true)
        notes[#notes + 1] = ok_aimove and "ai_movement=on" or "ai_movement_failed=" .. tostring(detail)
    end
    if state.quiet and actor then
        local ok_quiet, detail = set_quiet_mode(actor, false)
        notes[#notes + 1] = ok_quiet and "quiet=off" or "quiet_failed=" .. tostring(detail)
    end
    if state.hold and actor then
        local ok_hold, detail = set_hold_mode(actor, false)
        notes[#notes + 1] = ok_hold and "hold=off" or "hold_failed=" .. tostring(detail)
    end
    if state.puppet and actor then
        local ok_puppet, detail = set_puppet_mode(actor, false)
        notes[#notes + 1] = ok_puppet and "puppet=off" or "puppet_failed=" .. tostring(detail)
    end

    if actor and state.tune and state.tune_restore then
        return false, "cleanup incomplete; tune snapshot retained, retry npc.drive.clear: " .. table.concat(notes, "; ")
    end

    state.actor = nil
    state.name = nil
    state.source = nil
    state.camera = false
    state.camera_mouse = false
    state.camera_external_exit = false
    state.camera_view_target_seen = false
    state.camera_view_mismatch_ticks = 0
    state.player_hidden = false
    state.brain_stopped = false
    state.quiet = false
    state.hold = false
    state.hold_mode = "lock"
    state.hold_anchor = nil
    state.hold_rotation = nil
    state.hold_move_loop = false
    state.input_move_loop = false
    state.puppet = false
    state.puppet_move_loop = false
    state.puppet_restore = nil
    state.puppet_move_style = "native"
    state.tune = false
    state.tune_restore = nil
    state.tune_root_scaled = false
    state.ai_movement_enabled = nil
    state.roamdata_disabled = false
    state.roamdata_restore = nil
    state.drive_yaw = nil
    state.last_move = nil

    if #notes == 0 then return true, "cleared" end
    return true, "cleared " .. table.concat(notes, "; ")
end

return M
