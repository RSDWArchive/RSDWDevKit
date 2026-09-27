-- Oculus Scale Mode.
--
-- Targets the actor/item under the Oculus repair reticle, freezes Oculus
-- translation, and lets mouse motion scale the target in-place.

local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local feature_grab = require("feature_grab")
local feature_net = require("feature_net")
local feature_oculus = require("feature_oculus")
local feature_oculus_async = require("feature_oculus_async")
local feature_oculus_transform = require("feature_oculus_transform")
local feature_umg = require("feature_umg")

local TICK_MS = 33
local START_WARMUP_FRAMES = 4
local MODE_HOTKEY_DEBOUNCE_SECONDS = 0.08
local RESET_HOTKEY_DEBOUNCE_SECONDS = 0.18
local STOP_HOTKEY_DEBOUNCE_SECONDS = 0.18
local STOP_SETTLE_SECONDS = 0.08
local POST_STOP_OVERLAY_MS = 80
local POST_STOP_CAPTURE_MS = 140
local IDLE_INPUT_POLL_SECONDS = 0.05
local ACTIVE_INPUT_GRACE_SECONDS = 0.20
local VISUAL_PROXY_WRITE_INTERVAL_SECONDS = 0.033
-- Match Oculus grab's safer live-edit cadence. Scale writes are especially
-- sensitive because they can make collision/render state churn; avoid
-- engine-tick frequency unless we deliberately opt back in for a test.
local USE_ENGINE_TICK = false
local settings = {
    uniform_sensitivity = 0.01,
    axis_sensitivity = 0.01,
    min_scale = 0.05,
    max_scale = 50.0,
    freeze_speed = 0.000001,
    look_locked = true,
    look_scale = 0.001,
}

local state = {
    active = false,
    actor = nil,
    name = nil,
    source = nil,
    mode = "uniform",
    original_scale = nil,
    current_scale = nil,
    saved_motion = nil,
    saved_look = nil,
    loop_armed = false,
    token = 0,
    mouse_last_x = nil,
    mouse_last_y = nil,
    mouse_source = "none",
    camera_last_pitch = nil,
    camera_last_yaw = nil,
    writes = 0,
    actor_write_failures = 0,
    root_writes = 0,
    last_dx = 0.0,
    last_dy = 0.0,
    last_write_path = "none",
    last_mode_hotkey_clock = 0,
    last_reset_hotkey_clock = 0,
    pending_reset = false,
    pending_reset_capture = false,
    last_reset_ok = nil,
    last_stop_hotkey_clock = 0,
    pending_stop = false,
    pending_stop_clock = 0,
    pending_stop_capture = false,
    pending_stop_overlay = false,
    last_stop_detail = nil,
    loop_driver = nil,
    tick_fn = nil,
    engine_tick_started = false,
    start_warmup_frames = 0,
    next_input_poll_clock = 0,
    active_input_until = 0,
    input_polls = 0,
    idle_input_skips = 0,
    visual_proxy = nil,
    visual_proxy_detail = nil,
    visual_proxy_writes = 0,
    visual_proxy_failures = 0,
    visual_proxy_next_clock = 0,
    visual_proxy_dirty = false,
}

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function short_label(actor)
    local name = feature_actor.short_name_of(actor) or ""
    name = name:gsub("_UAID_[%x_]+$", "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name ~= "" then return name end
    return "<unnamed>"
end

local function num(v, fallback)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return fallback or 0.0
    end
    return n
end

local function clamp_scale(value)
    local n = num(value, 1.0)
    if n < settings.min_scale then n = settings.min_scale end
    if n > settings.max_scale then n = settings.max_scale end
    return n
end

local function copy_scale(scale)
    scale = scale or {}
    return {
        X = clamp_scale(scale.X or scale.x or 1.0),
        Y = clamp_scale(scale.Y or scale.y or 1.0),
        Z = clamp_scale(scale.Z or scale.z or 1.0),
    }
end

local function read_field(obj, field_name)
    if not is_valid(obj) then return nil end
    local ok, value = pcall(function() return obj[field_name] end)
    if ok then return value end
    return nil
end

local function write_field(obj, field_name, value)
    if not is_valid(obj) then return false, "invalid target" end
    local ok, err = pcall(function() obj[field_name] = value end)
    if ok then return true end
    return false, tostring(err)
end

local function zero_vector()
    return { X = 0.0, Y = 0.0, Z = 0.0 }
end

local function movement_component()
    local opawn, err = feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
    if not is_valid(opawn) then return nil, "no OculusPawn: " .. tostring(err) end
    local movement = read_field(opawn, "MovementComponent")
    if is_valid(movement) then return movement, nil end
    return nil, "no Oculus MovementComponent"
end

local function freeze_camera_motion()
    local movement, err = movement_component()
    if not movement then return false, err end
    local saved = {
        movement = movement,
        MaxSpeed = read_field(movement, "MaxSpeed"),
        Acceleration = read_field(movement, "Acceleration"),
        Deceleration = read_field(movement, "Deceleration"),
    }
    local controller = feature_net.local_controller()
    if is_valid(controller) then
        saved.controller = controller
        if controller.IsMoveInputIgnored then
            pcall(function() saved.ignore_move = controller:IsMoveInputIgnored() end)
        end
        if controller.SetIgnoreMoveInput then
            local ok_ignore = pcall(function() controller:SetIgnoreMoveInput(true) end)
            saved.ignore_move_applied = ok_ignore == true
        end
    end

    local freeze_value = math.max(0.000001, num(settings.freeze_speed, 0.000001))
    local ok_speed, speed_err = write_field(movement, "MaxSpeed", freeze_value)
    local ok_accel, accel_err = write_field(movement, "Acceleration", freeze_value)
    local ok_decel, decel_err = write_field(movement, "Deceleration", freeze_value)
    if movement.StopMovementImmediately then
        pcall(function() movement:StopMovementImmediately() end)
    end
    if movement.ConsumeInputVector then
        pcall(function() movement:ConsumeInputVector() end)
    end
    write_field(movement, "Velocity", zero_vector())
    if not (ok_speed and ok_accel and ok_decel) then
        if saved.MaxSpeed ~= nil then write_field(movement, "MaxSpeed", saved.MaxSpeed) end
        if saved.Acceleration ~= nil then write_field(movement, "Acceleration", saved.Acceleration) end
        if saved.Deceleration ~= nil then write_field(movement, "Deceleration", saved.Deceleration) end
        return false, string.format("freeze failed speed=%s accel=%s decel=%s",
            tostring(speed_err or ok_speed),
            tostring(accel_err or ok_accel),
            tostring(decel_err or ok_decel))
    end
    state.saved_motion = saved
    return true, "camera movement frozen"
end

local function restore_camera_motion()
    local saved = state.saved_motion
    state.saved_motion = nil
    if type(saved) ~= "table" then return end
    if is_valid(saved.controller) then
        if saved.controller.SetIgnoreMoveInput then
            pcall(function() saved.controller:SetIgnoreMoveInput(false) end)
        end
        if saved.controller.ResetIgnoreMoveInput then
            pcall(function() saved.controller:ResetIgnoreMoveInput() end)
        end
    end
    if not is_valid(saved.movement) then return end
    if saved.MaxSpeed ~= nil then write_field(saved.movement, "MaxSpeed", saved.MaxSpeed) end
    if saved.Acceleration ~= nil then write_field(saved.movement, "Acceleration", saved.Acceleration) end
    if saved.Deceleration ~= nil then write_field(saved.movement, "Deceleration", saved.Deceleration) end
end

local function signed_scale(original, magnitude)
    magnitude = math.max(0.0, num(magnitude, 0.001))
    local source = tonumber(original)
    if source and source < 0 then return -magnitude end
    return magnitude
end

local function damp_camera_look()
    local controller = feature_net.local_controller()
    if not is_valid(controller) then return false, "no local controller" end

    local saved = {
        controller = controller,
        look_locked = settings.look_locked == true,
        look_scale = num(settings.look_scale, 0.001),
    }
    if controller.IsLookInputIgnored then
        pcall(function() saved.ignore_look = controller:IsLookInputIgnored() end)
    end
    if controller.GetDeprecatedInputPitchScale then
        pcall(function() saved.pitch_scale = controller:GetDeprecatedInputPitchScale() end)
    else
        saved.pitch_scale = read_field(controller, "InputPitchScale")
    end
    if controller.GetDeprecatedInputYawScale then
        pcall(function() saved.yaw_scale = controller:GetDeprecatedInputYawScale() end)
    else
        saved.yaw_scale = read_field(controller, "InputYawScale")
    end

    local applied = false
    if settings.look_locked == true and saved.ignore_look ~= true and controller.SetIgnoreLookInput then
        local ok = pcall(function() controller:SetIgnoreLookInput(true) end)
        saved.ignore_look_applied = ok == true
        applied = applied or ok
    end

    local scale = math.max(0.0, num(settings.look_scale, 0.001))
    if controller.SetDeprecatedInputPitchScale then
        local ok = pcall(function() controller:SetDeprecatedInputPitchScale(signed_scale(saved.pitch_scale, scale)) end)
        applied = applied or ok
    else
        local ok = write_field(controller, "InputPitchScale", signed_scale(saved.pitch_scale, scale))
        applied = applied or ok
    end
    if controller.SetDeprecatedInputYawScale then
        local ok = pcall(function() controller:SetDeprecatedInputYawScale(signed_scale(saved.yaw_scale, scale)) end)
        applied = applied or ok
    else
        local ok = write_field(controller, "InputYawScale", signed_scale(saved.yaw_scale, scale))
        applied = applied or ok
    end

    state.saved_look = saved
    return applied, string.format("camera look %s scale=%.4f",
        settings.look_locked and "locked" or "damped",
        scale)
end

local function restore_camera_look()
    local saved = state.saved_look
    state.saved_look = nil
    if type(saved) ~= "table" or not is_valid(saved.controller) then return end
    local controller = saved.controller
    if saved.pitch_scale ~= nil then
        if controller.SetDeprecatedInputPitchScale then
            pcall(function() controller:SetDeprecatedInputPitchScale(saved.pitch_scale) end)
        else
            write_field(controller, "InputPitchScale", saved.pitch_scale)
        end
    end
    if saved.yaw_scale ~= nil then
        if controller.SetDeprecatedInputYawScale then
            pcall(function() controller:SetDeprecatedInputYawScale(saved.yaw_scale) end)
        else
            write_field(controller, "InputYawScale", saved.yaw_scale)
        end
    end
    if controller.SetIgnoreLookInput then
        pcall(function() controller:SetIgnoreLookInput(false) end)
    end
    if controller.ResetIgnoreLookInput then
        pcall(function() controller:ResetIgnoreLookInput() end)
    end
end

local function repair_oculus_camera_after_modal(reason)
    local function run_repair(tag)
        pcall(function()
            if feature_oculus.repair_camera_after_modal then
                feature_oculus.repair_camera_after_modal(tag)
            elseif feature_oculus.reapply_speed then
                feature_oculus.reapply_speed(tag)
            end
        end)
    end

    local tag = "scale." .. tostring(reason or "modal")
    run_repair(tag)
    feature_oculus_async.schedule_game_thread(80, function() run_repair(tag .. ".deferred") end)
    feature_oculus_async.schedule_game_thread(200, function() run_repair(tag .. ".late") end)
end

local function set_live_scale(actor, scale, authoritative)
    if not is_valid(actor) or not scale then return false end
    state.writes = (state.writes or 0) + 1
    if authoritative ~= true and state.visual_proxy then
        state.visual_proxy_dirty = true
        local now = os.clock()
        local next_clock = tonumber(state.visual_proxy_next_clock) or 0.0
        if next_clock > 0 and now < next_clock then
            state.last_write_path = "visual_proxy_pending"
            return true
        end
        state.visual_proxy_next_clock = now + VISUAL_PROXY_WRITE_INTERVAL_SECONDS
        local moved, failed = feature_grab.scale_visual_proxy(state.visual_proxy, scale)
        state.visual_proxy_writes = (state.visual_proxy_writes or 0) + moved
        state.visual_proxy_failures = (state.visual_proxy_failures or 0) + failed
        if moved > 0 then
            state.last_write_path = "visual_proxy"
            state.visual_proxy_dirty = false
            return true
        end
        state.last_write_path = "visual_proxy_failed"
        return false
    end
    local actor_ok = feature_actor.set_actor_scale3d(actor, scale)
    if actor_ok then
        state.last_write_path = "actor"
        return true
    end

    state.actor_write_failures = (state.actor_write_failures or 0) + 1
    feature_actor.force_actor_movable(actor)
    actor_ok = feature_actor.set_actor_scale3d(actor, scale)
    if actor_ok then
        state.last_write_path = "actor_after_movable"
        return true
    end

    local root_ok = false
    local root = read_field(actor, "RootComponent")
    if is_valid(root) then
        if root.SetWorldScale3D then
            local ok_call, result = pcall(function() return root:SetWorldScale3D(scale) end)
            if ok_call then root_ok = result ~= false end
        end
        if not root_ok and root.SetRelativeScale3D then
            local ok_call, result = pcall(function() return root:SetRelativeScale3D(scale) end)
            if ok_call then root_ok = result ~= false end
        end
    end
    if root_ok then
        state.root_writes = (state.root_writes or 0) + 1
        state.last_write_path = "root"
    else
        state.last_write_path = "failed"
    end
    return root_ok
end

local function flush_visual_proxy_if_due()
    if not state.visual_proxy or state.visual_proxy_dirty ~= true then return false end
    if not state.current_scale then return false end
    return set_live_scale(state.actor, state.current_scale)
end

local function reset_visual_proxy_to_actor(actor, scale)
    if not state.visual_proxy or not is_valid(actor) then return 0, 0 end
    return feature_grab.reset_visual_proxy(
        state.visual_proxy,
        nil,
        nil,
        scale or feature_actor.get_actor_scale3d(actor))
end

local function apply_visual_proxy_final_scale(actor, scale)
    if not state.visual_proxy then return true, "no visual proxy" end
    if not is_valid(actor) then return false, "invalid actor" end
    local desired = copy_scale(scale or state.current_scale or state.original_scale)
    local pre_moved, pre_failed = reset_visual_proxy_to_actor(actor, feature_actor.get_actor_scale3d(actor))
    local ok = set_live_scale(actor, desired, true)
    local after_scale = feature_actor.get_actor_scale3d(actor)
    local reset_scale = ok and desired or after_scale
    local post_moved, post_failed = reset_visual_proxy_to_actor(actor, reset_scale)
    return ok, string.format("visual_proxy final=%s pre=%d/%d post=%d/%d",
        tostring(ok), pre_moved, pre_failed, post_moved, post_failed)
end

local function normalize_angle_delta(delta)
    delta = num(delta, 0.0)
    while delta > 180.0 do delta = delta - 360.0 end
    while delta < -180.0 do delta = delta + 360.0 end
    return delta
end

local function read_camera_rotation()
    local opawn = feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
    if is_valid(opawn) then
        local cam = read_field(opawn, "Camera")
        if is_valid(cam) and cam.K2_GetComponentRotation then
            local ok, rot = pcall(function() return cam:K2_GetComponentRotation() end)
            if ok and rot then return rot, "oculus.camera" end
        end
        if opawn.K2_GetActorRotation then
            local ok, rot = pcall(function() return opawn:K2_GetActorRotation() end)
            if ok and rot then return rot, "oculus.pawn" end
        end
    end
    local controller = feature_net.local_controller()
    if is_valid(controller) and controller.GetPlayerViewPoint then
        local ok, _loc, rot = pcall(function()
            local loc = { X = 0, Y = 0, Z = 0 }
            local out_rot = { Pitch = 0, Yaw = 0, Roll = 0 }
            controller:GetPlayerViewPoint(loc, out_rot)
            return loc, out_rot
        end)
        if ok and rot then return rot, "controller" end
    end
    return nil, "camera unavailable"
end

local function read_camera_look_delta()
    local rot, source = read_camera_rotation()
    if not rot then return nil, nil, source end
    local pitch = num(rot.Pitch or rot.pitch, 0.0)
    local yaw = num(rot.Yaw or rot.yaw, 0.0)
    if state.camera_last_pitch == nil or state.camera_last_yaw == nil then
        state.camera_last_pitch = pitch
        state.camera_last_yaw = yaw
        return 0.0, 0.0, source .. ":seed"
    end
    local dyaw = normalize_angle_delta(yaw - state.camera_last_yaw)
    local dpitch = normalize_angle_delta(pitch - state.camera_last_pitch)
    state.camera_last_pitch = pitch
    state.camera_last_yaw = yaw
    if math.abs(dyaw) < 0.001 and math.abs(dpitch) < 0.001 then
        return 0.0, 0.0, source
    end
    local dx = -dyaw / math.max(0.001, settings.axis_sensitivity)
    local dy = dpitch / math.max(0.001, settings.uniform_sensitivity)
    return dx, dy, source .. ":look"
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

local function number_from_out(value)
    if type(value) == "number" then return value end
    if type(value) == "table" then
        return tonumber(value.Value or value.value or value[1] or value.X or value.Y or 0.0) or 0.0
    end
    return tonumber(value) or 0.0
end

local function read_mouse_axis_delta(controller)
    if not is_valid(controller) then return nil, nil, "no local controller" end
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
    if not is_valid(controller) or not controller.GetMousePosition then return nil, nil, "no mouse position" end
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
    local controller = feature_net.local_controller()
    if not is_valid(controller) then return nil, nil, "no local controller" end
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
            if ax ~= nil and ay ~= nil and (math.abs(ax) >= 0.01 or math.abs(ay) >= 0.01) then return ax, ay, asource end
            if math.abs(dx) >= 0.01 or math.abs(dy) >= 0.01 then return dx, dy, "delta" end
        end
        local ok_return, dx_return, dy_return = pcall(function() return controller:GetInputMouseDelta(0.0, 0.0) end)
        if ok_return and (tonumber(dx_return) or tonumber(dy_return)) then
            local dx, dy = tonumber(dx_return) or 0.0, tonumber(dy_return) or 0.0
            if math.abs(dx) >= 0.01 or math.abs(dy) >= 0.01 then return dx, dy, "delta:return" end
        end
    end
    if ax ~= nil and ay ~= nil and (math.abs(ax) >= 0.01 or math.abs(ay) >= 0.01) then return ax, ay, asource end
    local px, py, psource = read_mouse_position_delta(controller)
    if px ~= nil and py ~= nil and (math.abs(px) >= 0.01 or math.abs(py) >= 0.01) then return px, py, psource end
    return read_camera_look_delta()
end

local function mode_label(mode)
    mode = mode or state.mode or "uniform"
    if mode == "x" then return "X axis scale" end
    if mode == "y" then return "Y axis scale" end
    if mode == "z" then return "Z axis scale" end
    return "Uniform scale"
end

local function short_mode_label(mode)
    mode = mode or state.mode or "uniform"
    if mode == "x" then return "X Axis" end
    if mode == "y" then return "Y Axis" end
    if mode == "z" then return "Z Axis" end
    return "Uniform"
end

local function refresh_hotkey_help()
    local config = package.loaded["feature_oculus_config"]
    if type(config) == "table" and type(config.refresh_hotkey_help) == "function" then
        pcall(function() config.refresh_hotkey_help() end)
    end
end

local function note_modal_settle(reason)
    local mode = package.loaded["feature_oculus_mode"]
    if type(mode) == "table" and type(mode.note_settle) == "function" then
        pcall(function() mode.note_settle(reason or "scale.stop") end)
    end
end

function M.help_status()
    return M.help_details()
end

function M.top_status()
    return "Scale Mode"
end

function M.help_details()
    return "Adjust scale (Mouse up/down)\nConfirm changes (Left Click)\nGrab Mode (G)\nRotation Mode (R)"
end

local function update_overlay(force, refresh_help_panel)
    if state.active then
        pcall(function() feature_umg.oculus_rotation_overlay(true, M.top_status(), "", "scale") end)
    else
        pcall(function() feature_umg.oculus_rotation_overlay(false) end)
    end
    if force == true or refresh_help_panel == true then
        refresh_hotkey_help()
    end
end

local function schedule_game_thread(delay_ms, fn)
    return feature_oculus_async.schedule_game_thread(delay_ms, fn)
end

local function mode_hotkey_allows_force_refresh()
    local now = os.clock()
    local last = tonumber(state.last_mode_hotkey_clock) or 0.0
    state.last_mode_hotkey_clock = now
    return (now - last) >= MODE_HOTKEY_DEBOUNCE_SECONDS
end

local function cleanup(options)
    options = options or {}
    state.active = false
    state.actor = nil
    state.name = nil
    state.source = nil
    state.mode = "uniform"
    state.original_scale = nil
    state.current_scale = nil
    state.mouse_last_x = nil
    state.mouse_last_y = nil
    state.mouse_source = "none"
    state.camera_last_pitch = nil
    state.camera_last_yaw = nil
    state.writes = 0
    state.actor_write_failures = 0
    state.root_writes = 0
    state.last_dx = 0.0
    state.last_dy = 0.0
    state.last_write_path = "none"
    state.last_mode_hotkey_clock = 0
    state.last_reset_hotkey_clock = 0
    state.pending_reset = false
    state.pending_reset_capture = false
    state.last_reset_ok = nil
    state.last_stop_hotkey_clock = 0
    state.pending_stop = false
    state.pending_stop_clock = 0
    state.pending_stop_capture = false
    state.pending_stop_overlay = false
    state.last_stop_detail = nil
    state.loop_armed = false
    state.tick_fn = nil
    state.loop_driver = nil
    state.start_warmup_frames = 0
    state.next_input_poll_clock = 0
    state.active_input_until = 0
    state.input_polls = 0
    state.idle_input_skips = 0
    state.visual_proxy = nil
    state.visual_proxy_detail = nil
    state.visual_proxy_writes = 0
    state.visual_proxy_failures = 0
    state.visual_proxy_next_clock = 0
    state.visual_proxy_dirty = false
    restore_camera_look()
    restore_camera_motion()
    repair_oculus_camera_after_modal(options.reason or "cleanup")
    if options.defer_overlay ~= true then
        update_overlay(true)
    end
end

local function capture_current(reason)
    if is_valid(state.actor) then
        pcall(function() feature_oculus_transform.capture_actor(state.actor, reason or "scale") end)
    end
end

local function stop_for_invalid_target()
    local label = tostring(state.name or "<target>")
    cleanup()
    pcall(function() feature_umg.toast("Scale Mode stopped: target lost (" .. label .. ")", 2.0) end)
end

local function schedule_post_stop(actor, capture_requested, overlay_requested)
    if overlay_requested == true then
        schedule_game_thread(POST_STOP_OVERLAY_MS, function()
            pcall(function() feature_umg.oculus_rotation_overlay(false) end)
            refresh_hotkey_help()
        end)
    end
    if capture_requested == true then
        schedule_game_thread(POST_STOP_CAPTURE_MS, function()
            if is_valid(actor) then
                pcall(function() feature_oculus_transform.capture_actor(actor, "scale.stop") end)
            end
        end)
    end
end

local function apply_scale_delta(dx, dy)
    if not state.active then return false end
    local scale = state.current_scale
    if not scale then return false end
    dx = tonumber(dx) or 0.0
    dy = tonumber(dy) or 0.0
    state.last_dx = dx
    state.last_dy = dy
    if math.abs(dx) < 0.01 and math.abs(dy) < 0.01 then return false end
    local delta = dy
    if state.mode == "x" then
        scale.X = clamp_scale(num(scale.X, 1.0) + delta * settings.axis_sensitivity)
    elseif state.mode == "y" then
        scale.Y = clamp_scale(num(scale.Y, 1.0) + delta * settings.axis_sensitivity)
    elseif state.mode == "z" then
        scale.Z = clamp_scale(num(scale.Z, 1.0) + delta * settings.axis_sensitivity)
    else
        local next_scale = clamp_scale((num(scale.X, 1.0) + num(scale.Y, 1.0) + num(scale.Z, 1.0)) / 3.0 + delta * settings.uniform_sensitivity)
        scale.X = next_scale
        scale.Y = next_scale
        scale.Z = next_scale
    end
    return set_live_scale(state.actor, scale)
end

local function should_poll_input()
    local now = os.clock()
    local next_clock = tonumber(state.next_input_poll_clock) or 0.0
    if next_clock > 0 and now < next_clock then
        state.idle_input_skips = (state.idle_input_skips or 0) + 1
        state.last_dx = 0.0
        state.last_dy = 0.0
        return false
    end
    return true
end

local function note_input_poll(dx, dy)
    local now = os.clock()
    state.input_polls = (state.input_polls or 0) + 1
    dx = tonumber(dx) or 0.0
    dy = tonumber(dy) or 0.0
    if math.abs(dx) >= 0.01 or math.abs(dy) >= 0.01 then
        state.active_input_until = now + ACTIVE_INPUT_GRACE_SECONDS
        state.next_input_poll_clock = 0
        return
    end
    if now < (tonumber(state.active_input_until) or 0.0) then
        state.next_input_poll_clock = 0
        return
    end
    state.next_input_poll_clock = now + IDLE_INPUT_POLL_SECONDS
end

local function apply_pending_reset()
    if state.pending_reset ~= true then return false end
    state.pending_reset = false
    if not state.active then return true end
    if not is_valid(state.actor) then
        stop_for_invalid_target()
        return true
    end
    state.current_scale = copy_scale(state.original_scale)
    state.last_dx = 0.0
    state.last_dy = 0.0
    state.mouse_last_x = nil
    state.mouse_last_y = nil
    state.camera_last_pitch = nil
    state.camera_last_yaw = nil
    local ok = set_live_scale(state.actor, state.current_scale)
    state.last_reset_ok = ok == true
    if state.pending_reset_capture == true then
        state.pending_reset_capture = false
        capture_current("scale.reset")
    end
    update_overlay(true)
    if not ok then
        print("[RSDWTools] scale mode reset write failed for " .. tostring(state.name or "<target>"))
    end
    return true
end

local function finish_stop(reason)
    if not state.active then return true, "inactive" end
    local label = tostring(state.name or "<target>")
    local actor = state.actor
    local capture_requested = state.pending_stop_capture == true
    local overlay_requested = state.pending_stop_overlay == true
    local final_ok, final_detail = apply_visual_proxy_final_scale(actor, state.current_scale)
    local writes = tonumber(state.writes) or 0
    local detail = string.format("applied %s reason=%s writes=%d path=%s final=%s",
        label,
        tostring(reason or "stop"),
        writes,
        tostring(state.last_write_path or "none"),
        tostring(final_detail or final_ok))
    cleanup({ defer_overlay = true })
    note_modal_settle("scale.stop")
    schedule_post_stop(actor, capture_requested, overlay_requested)
    print("[RSDWTools] scale mode stop applied: " .. detail)
    return true, detail
end

local function apply_pending_stop()
    if state.pending_stop ~= true then return false, false end
    local elapsed = os.clock() - (tonumber(state.pending_stop_clock) or 0.0)
    if elapsed < STOP_SETTLE_SECONDS then
        return true, false
    end
    finish_stop("queued")
    return true, true
end

local function tick_scale()
    if not state.active then return true end
    if not is_valid(state.actor) then
        stop_for_invalid_target()
        return true
    end
    if apply_pending_reset() then
        return false
    end
    local stop_pending, stop_done = apply_pending_stop()
    if stop_pending then
        return stop_done
    end
    if (tonumber(state.start_warmup_frames) or 0) > 0 then
        state.start_warmup_frames = state.start_warmup_frames - 1
        state.last_dx = 0.0
        state.last_dy = 0.0
        state.mouse_source = "warmup"
        return false
    end
    if not should_poll_input() then
        state.mouse_source = "idle"
        return false
    end
    local dx, dy, source = read_mouse_delta()
    state.mouse_source = source or state.mouse_source or "unknown"
    note_input_poll(dx, dy)
    if dx ~= nil and dy ~= nil then
        apply_scale_delta(dx, dy)
    end
    flush_visual_proxy_if_due()
    return false
end

local function start_loop()
    if state.loop_armed and state.tick_fn ~= nil then return end
    state.loop_armed = true
    local token = state.token
    local function run_step()
        if token ~= state.token then
            state.loop_armed = false
            return true
        end
        if not state.active then
            state.loop_armed = false
            return true
        end
        local ok_step, done = pcall(tick_scale)
        if not ok_step then
            print("[RSDWTools] scale mode tick failed: " .. tostring(done))
            cleanup()
            state.loop_armed = false
            return true
        end
        if done then
            state.loop_armed = false
            return true
        end
        return false
    end

    if USE_ENGINE_TICK == true and EngineTickAvailable == true and type(LoopInGameThreadAfterFrames) == "function" then
        state.tick_fn = run_step
        state.loop_driver = "engine_tick"
        if not state.engine_tick_started then
            local ok, handle_or_err = pcall(function()
                return LoopInGameThreadAfterFrames(1, function()
                    local tick = state.tick_fn
                    if not tick then
                        if not state.active then state.loop_armed = false end
                        return
                    end
                    if tick() then
                        state.tick_fn = nil
                        state.loop_armed = false
                        if state.loop_driver == "engine_tick" then state.loop_driver = nil end
                    end
                end)
            end)
            if ok and handle_or_err then
                state.engine_tick_started = true
                return
            end
            print("[RSDWTools] scale mode engine tick unavailable: " .. tostring(handle_or_err))
            state.tick_fn = nil
            state.loop_driver = nil
        else
            return
        end
    end

    if not LoopAsync then return end
    state.loop_driver = "loop_async"
    LoopAsync(TICK_MS, run_step)
end

local function parse_mode(args)
    local value = trim(args):lower()
    if value == "" then return nil, "usage: camera.oculus.scale.mode <uniform|x|y|z>" end
    if value == "free" then value = "uniform" end
    if value == "uniform" or value == "x" or value == "y" or value == "z" then return value end
    return nil, "mode must be one of uniform, x, y, z"
end

function M.is_active()
    return state.active == true
end

local function start_with_actor(actor, source)
    if state.active then
        return true, "already active target=" .. tostring(state.name) .. " mode=" .. tostring(state.mode)
    end
    local ok_repair, repair_detail = feature_oculus.require_state("repair")
    if not ok_repair then return false, "requires Oculus Repair mode: " .. tostring(repair_detail) end
    if feature_grab.is_active and feature_grab.is_active() then
        return false, "release the grabbed actor before entering Scale Mode"
    end

    if not is_valid(actor) then
        return false, tostring(source or "no actor under reticle")
    end
    if type(feature_grab.validate_target_safety) == "function" then
        local safe_ok, safe_detail = feature_grab.validate_target_safety(actor, "scale")
        if not safe_ok then return false, tostring(safe_detail) end
    end

    local scale = feature_actor.get_actor_scale3d(actor)
    if not scale then return false, "target scale unavailable" end
    local actor_loc = feature_actor.actor_location(actor)
    local actor_rot = feature_actor.actor_rotation(actor)
    local visual_proxy, visual_detail = nil, nil
    if type(feature_grab.is_character_like) == "function" and feature_grab.is_character_like(actor) then
        visual_proxy, visual_detail = feature_grab.capture_visual_proxy(actor, actor_loc, actor_rot, scale)
        print("[RSDWTools] scale mode visual proxy " .. tostring(visual_proxy and "on" or "off")
            .. " target=" .. tostring(short_label(actor))
            .. " detail=" .. tostring(visual_detail))
    end
    if not visual_proxy then
        feature_actor.force_actor_movable(actor)
    end

    local frozen, freeze_detail = freeze_camera_motion()
    if not frozen then return false, tostring(freeze_detail) end
    damp_camera_look()

    state.token = state.token + 1
    state.active = true
    state.actor = actor
    state.name = short_label(actor)
    state.source = tostring(source or "reticle")
    state.mode = "uniform"
    state.original_scale = copy_scale(scale)
    state.current_scale = copy_scale(scale)
    state.mouse_last_x = nil
    state.mouse_last_y = nil
    state.mouse_source = "none"
    state.camera_last_pitch = nil
    state.camera_last_yaw = nil
    state.writes = 0
    state.actor_write_failures = 0
    state.root_writes = 0
    state.last_dx = 0.0
    state.last_dy = 0.0
    state.last_write_path = "none"
    state.last_mode_hotkey_clock = 0
    state.last_reset_hotkey_clock = 0
    state.pending_reset = false
    state.pending_reset_capture = false
    state.last_reset_ok = nil
    state.last_stop_hotkey_clock = 0
    state.pending_stop = false
    state.pending_stop_clock = 0
    state.pending_stop_capture = false
    state.pending_stop_overlay = false
    state.last_stop_detail = nil
    state.start_warmup_frames = START_WARMUP_FRAMES
    state.next_input_poll_clock = 0
    state.active_input_until = 0
    state.input_polls = 0
    state.idle_input_skips = 0
    state.visual_proxy = visual_proxy
    state.visual_proxy_detail = visual_detail
    state.visual_proxy_writes = 0
    state.visual_proxy_failures = 0
    state.visual_proxy_next_clock = 0
    state.visual_proxy_dirty = false
    print("[RSDWTools] scale mode start target=" .. tostring(state.name)
        .. " source=" .. tostring(state.source)
        .. string.format(" scale=(%.3f,%.3f,%.3f)",
            num(state.current_scale.X, 1.0),
            num(state.current_scale.Y, 1.0),
            num(state.current_scale.Z, 1.0)))
    update_overlay(true)
    start_loop()
    return true, "target=" .. tostring(state.name) .. " source=" .. tostring(state.source) .. " mode=uniform"
end

function M.start()
    local actor, source = feature_grab.pick_actor_under_reticle()
    return start_with_actor(actor, source)
end

function M.start_actor(actor, source)
    return start_with_actor(actor, source or "mode.switch")
end

function M.current_actor()
    if state.active ~= true or not is_valid(state.actor) then return nil end
    return state.actor, state.name, state.source
end

function M.stop(suppress_capture)
    if not state.active then return true, "inactive" end
    if not is_valid(state.actor) then
        stop_for_invalid_target()
        return false, "target lost"
    end
    local now = os.clock()
    local last = tonumber(state.last_stop_hotkey_clock) or 0.0
    if state.pending_stop == true or (now - last) < STOP_HOTKEY_DEBOUNCE_SECONDS then
        return true, "stop already queued " .. tostring(state.name)
    end
    state.last_stop_hotkey_clock = now
    state.pending_stop = true
    state.pending_stop_clock = now
    state.pending_stop_capture = suppress_capture ~= true
    state.pending_stop_overlay = suppress_capture ~= true
    state.last_stop_detail = "queued"
    state.last_dx = 0.0
    state.last_dy = 0.0
    state.mouse_last_x = nil
    state.mouse_last_y = nil
    state.camera_last_pitch = nil
    state.camera_last_yaw = nil
    print("[RSDWTools] scale mode stop queued target=" .. tostring(state.name)
        .. " writes=" .. tostring(state.writes or 0)
        .. " path=" .. tostring(state.last_write_path or "none"))
    return true, "stop queued " .. tostring(state.name)
end

function M.stop_now(reason)
    if not state.active then return true, "inactive" end
    state.pending_stop = true
    state.pending_stop_clock = 0
    state.pending_stop_capture = true
    state.pending_stop_overlay = true
    return finish_stop(reason or "immediate")
end

function M.toggle()
    if state.active then return M.stop() end
    return M.start()
end

function M.mode(args)
    if not state.active then return false, "scale mode inactive" end
    local value, err = parse_mode(args)
    if not value then return false, err end
    state.mode = value
    if mode_hotkey_allows_force_refresh() then
        update_overlay(true, false)
    end
    return true, "mode=" .. value .. " " .. mode_label(value)
end

function M.reset()
    if not state.active then return false, "scale mode inactive" end
    if not is_valid(state.actor) then
        stop_for_invalid_target()
        return false, "target lost"
    end
    local now = os.clock()
    local last = tonumber(state.last_reset_hotkey_clock) or 0.0
    if (now - last) < RESET_HOTKEY_DEBOUNCE_SECONDS then
        return true, "reset already queued " .. tostring(state.name)
    end
    state.last_reset_hotkey_clock = now
    state.current_scale = copy_scale(state.original_scale)
    state.pending_reset = true
    state.pending_reset_capture = true
    state.last_dx = 0.0
    state.last_dy = 0.0
    state.mouse_last_x = nil
    state.mouse_last_y = nil
    state.camera_last_pitch = nil
    state.camera_last_yaw = nil
    return true, "reset queued " .. tostring(state.name)
end

function M.status()
    if not state.active then return true, "inactive" end
    local scale = state.current_scale or {}
    return true, string.format("active target=%s mode=%s source=%s mouse=%s driver=%s writes=%d actor_fail=%d root=%d visual=%s/%d/%d path=%s reset_pending=%s reset_ok=%s stop_pending=%s polls=%d idle_skips=%d dx=%.3f dy=%.3f x=%.3f y=%.3f z=%.3f bounds=%.3f..%.3f",
        tostring(state.name),
        tostring(state.mode),
        tostring(state.source),
        tostring(state.mouse_source),
        tostring(state.loop_driver or "none"),
        tonumber(state.writes) or 0,
        tonumber(state.actor_write_failures) or 0,
        tonumber(state.root_writes) or 0,
        tostring(state.visual_proxy_detail or "none"),
        tonumber(state.visual_proxy_writes) or 0,
        tonumber(state.visual_proxy_failures) or 0,
        tostring(state.last_write_path),
        tostring(state.pending_reset == true),
        tostring(state.last_reset_ok),
        tostring(state.pending_stop == true),
        tonumber(state.input_polls) or 0,
        tonumber(state.idle_input_skips) or 0,
        num(state.last_dx, 0.0),
        num(state.last_dy, 0.0),
        num(scale.X, 1.0),
        num(scale.Y, 1.0),
        num(scale.Z, 1.0),
        num(settings.min_scale, 0.05),
        num(settings.max_scale, 50.0))
end

function M.sensitivity(args)
    local parts = {}
    for part in tostring(args or ""):gmatch("%S+") do parts[#parts + 1] = part end
    if #parts == 0 then
        return true, string.format("uniform=%.4f axis=%.4f",
            settings.uniform_sensitivity,
            settings.axis_sensitivity)
    end
    local uniform = tonumber(parts[1])
    local axis = tonumber(parts[2]) or uniform
    if not uniform or uniform <= 0 or not axis or axis <= 0 then
        return false, "usage: camera.oculus.scale.sensitivity <uniform> [axis]"
    end
    settings.uniform_sensitivity = uniform
    settings.axis_sensitivity = axis
    return M.sensitivity("")
end

function M.freeze(args)
    local value = trim(args)
    if value == "" then
        return true, string.format("freeze_speed=%.4f", settings.freeze_speed)
    end
    local parsed = tonumber(value)
    if not parsed or parsed <= 0 then
        return false, "usage: camera.oculus.scale.freeze <positive-speed>"
    end
    settings.freeze_speed = parsed
    return true, string.format("freeze_speed=%.4f", settings.freeze_speed)
end

function M.bounds(args)
    local parts = {}
    for part in tostring(args or ""):gmatch("%S+") do parts[#parts + 1] = part end
    if #parts == 0 then
        return true, string.format("min=%.4f max=%.4f", settings.min_scale, settings.max_scale)
    end
    if #parts ~= 2 then
        return false, "usage: camera.oculus.scale.bounds <min> <max>"
    end
    local min_scale = tonumber(parts[1])
    local max_scale = tonumber(parts[2])
    if not min_scale or not max_scale or min_scale <= 0 or max_scale <= 0 or min_scale > max_scale then
        return false, "usage: camera.oculus.scale.bounds <min> <max> where 0 < min <= max"
    end
    settings.min_scale = min_scale
    settings.max_scale = max_scale
    if state.current_scale then state.current_scale = copy_scale(state.current_scale) end
    return M.bounds("")
end

function M.look(args)
    local parts = {}
    for part in tostring(args or ""):gmatch("%S+") do parts[#parts + 1] = part end
    if #parts == 0 then
        return true, string.format("mode=%s scale=%.4f",
            settings.look_locked and "locked" or "damped",
            settings.look_scale)
    end

    local mode = trim(parts[1]):lower()
    local scale_index = 2
    if tonumber(parts[1]) ~= nil then
        scale_index = 1
    elseif mode == "locked" or mode == "lock" or mode == "on" or mode == "true" or mode == "1" then
        settings.look_locked = true
    elseif mode == "damped" or mode == "damp" or mode == "soft" or mode == "off" or mode == "false" or mode == "0" then
        settings.look_locked = false
    else
        return false, "usage: camera.oculus.scale.look <locked|damped> [scale]"
    end

    local scale = tonumber(parts[scale_index])
    if scale ~= nil then
        if scale < 0 then return false, "look scale must be >= 0" end
        settings.look_scale = scale
    end
    return M.look("")
end

function M.handle_modal_hotkey(key)
    if not state.active then return false end
    local k = trim(key):upper()
    if k == "V" or k == "LEFT_MOUSE_BUTTON" or k == "LEFT_MOUSE" then
        M.stop()
        return true
    elseif k == "X" or k == "Y" or k == "Z" then
        M.mode(k:lower())
        return true
    elseif k == "MIDDLE_MOUSE_BUTTON" or k == "MIDDLE" or k == "MIDDLE_MOUSE" then
        M.reset()
        return true
    end
    return false
end

return M
