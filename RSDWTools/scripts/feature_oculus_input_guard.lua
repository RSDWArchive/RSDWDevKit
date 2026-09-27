-- Short-lived Oculus input guard.
--
-- Used during staged operations where the actor reference/transform has
-- already been chosen but the actual mode/spawn/grab work is intentionally
-- delayed across a few game-thread slices. It freezes Oculus translation and
-- camera look so the reticle/camera state cannot drift during that gap.

local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local feature_net = require("feature_net")
local feature_oculus_async = require("feature_oculus_async")

local REAPPLY_MS = 100
local FREEZE_SPEED = 0.01
local LOOK_SCALE = 0.0

local state = {
    active = false,
    token_next = 0,
    tokens = {},
    saved_motion = nil,
    saved_look = nil,
    look_ignore_applied = false,
    pulse_generation = 0,
    pulse_started = false,
}

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function read_field(obj, field_name)
    if not is_valid(obj) then return nil end
    local ok, value = pcall(function() return obj[field_name] end)
    if ok then return value end
    return nil
end

local function write_field(obj, field_name, value)
    if not is_valid(obj) then return false end
    local ok = pcall(function() obj[field_name] = value end)
    return ok == true
end

local function zero_vector()
    return { X = 0.0, Y = 0.0, Z = 0.0 }
end

local function signed_scale(original, magnitude)
    magnitude = tonumber(magnitude) or 0.0
    local source = tonumber(original)
    if source and source < 0 then return -magnitude end
    return magnitude
end

local function movement_component()
    local opawn, _ = feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
    if not is_valid(opawn) then return nil end
    local movement = read_field(opawn, "MovementComponent")
    if is_valid(movement) then return movement end
    return nil
end

local function save_motion()
    local movement = movement_component()
    if not movement then return nil end
    return {
        movement = movement,
        MaxSpeed = read_field(movement, "MaxSpeed"),
        Acceleration = read_field(movement, "Acceleration"),
        Deceleration = read_field(movement, "Deceleration"),
    }
end

local function apply_motion_lock()
    local saved = state.saved_motion
    local movement = saved and saved.movement or movement_component()
    if not is_valid(movement) then return false end
    write_field(movement, "MaxSpeed", FREEZE_SPEED)
    write_field(movement, "Acceleration", FREEZE_SPEED)
    write_field(movement, "Deceleration", FREEZE_SPEED)
    if movement.StopMovementImmediately then
        pcall(function() movement:StopMovementImmediately() end)
    end
    if movement.ConsumeInputVector then
        pcall(function() movement:ConsumeInputVector() end)
    end
    write_field(movement, "Velocity", zero_vector())
    return true
end

local function restore_motion()
    local saved = state.saved_motion
    state.saved_motion = nil
    if type(saved) ~= "table" or not is_valid(saved.movement) then return end
    if saved.MaxSpeed ~= nil then write_field(saved.movement, "MaxSpeed", saved.MaxSpeed) end
    if saved.Acceleration ~= nil then write_field(saved.movement, "Acceleration", saved.Acceleration) end
    if saved.Deceleration ~= nil then write_field(saved.movement, "Deceleration", saved.Deceleration) end
end

local function save_look()
    local controller = feature_net.local_controller()
    if not is_valid(controller) then return nil end
    local saved = { controller = controller }
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
    return saved
end

local function apply_look_lock()
    local saved = state.saved_look
    local controller = saved and saved.controller or feature_net.local_controller()
    if not is_valid(controller) then return false end
    if controller.SetIgnoreLookInput and state.look_ignore_applied ~= true and (not saved or saved.ignore_look ~= true) then
        pcall(function() controller:SetIgnoreLookInput(true) end)
        state.look_ignore_applied = true
    end
    if controller.SetDeprecatedInputPitchScale then
        pcall(function() controller:SetDeprecatedInputPitchScale(signed_scale(saved and saved.pitch_scale, LOOK_SCALE)) end)
    else
        write_field(controller, "InputPitchScale", signed_scale(saved and saved.pitch_scale, LOOK_SCALE))
    end
    if controller.SetDeprecatedInputYawScale then
        pcall(function() controller:SetDeprecatedInputYawScale(signed_scale(saved and saved.yaw_scale, LOOK_SCALE)) end)
    else
        write_field(controller, "InputYawScale", signed_scale(saved and saved.yaw_scale, LOOK_SCALE))
    end
    return true
end

local function restore_look()
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
    if state.look_ignore_applied == true and controller.SetIgnoreLookInput then
        pcall(function() controller:SetIgnoreLookInput(false) end)
    elseif saved.ignore_look == nil and controller.ResetIgnoreLookInput then
        pcall(function() controller:ResetIgnoreLookInput() end)
    end
    state.look_ignore_applied = false
end

local function token_count()
    local count = 0
    for _, _ in pairs(state.tokens) do count = count + 1 end
    return count
end

local function reapply_locks()
    if not state.active then return false end
    apply_motion_lock()
    apply_look_lock()
    return true
end

local function start_pulse()
    if state.pulse_started then return end
    if not LoopAsync then return end
    state.pulse_generation = state.pulse_generation + 1
    local generation = state.pulse_generation
    state.pulse_started = true
    LoopAsync(REAPPLY_MS, function()
        if generation ~= state.pulse_generation then return true end
        if not state.active then
            state.pulse_started = false
            return true
        end
        feature_oculus_async.schedule_game_thread(1, function()
            if generation == state.pulse_generation and state.active then
                reapply_locks()
            end
        end)
        return false
    end)
end

local function activate()
    if state.active then
        reapply_locks()
        return true
    end
    state.saved_motion = save_motion()
    state.saved_look = save_look()
    state.active = true
    reapply_locks()
    start_pulse()
    return true
end

local function deactivate()
    state.active = false
    state.tokens = {}
    state.pulse_generation = state.pulse_generation + 1
    state.pulse_started = false
    restore_look()
    state.look_ignore_applied = false
    restore_motion()
end

function M.acquire(reason)
    state.token_next = state.token_next + 1
    local token = state.token_next
    state.tokens[token] = tostring(reason or "guard")
    activate()
    return token, "input guard acquired " .. tostring(reason or "guard")
end

function M.release(token, reason)
    if token == nil then return false, "missing input guard token" end
    state.tokens[token] = nil
    if token_count() == 0 then
        deactivate()
        return true, "input guard released " .. tostring(reason or "")
    end
    return true, "input guard token released " .. tostring(reason or "")
end

function M.release_all(reason)
    if not state.active and token_count() == 0 then
        return true, "input guard inactive"
    end
    deactivate()
    return true, "input guard released all " .. tostring(reason or "")
end

function M.is_active()
    return state.active == true
end

function M.status()
    return true, string.format("active=%s tokens=%d", tostring(state.active == true), token_count())
end

return M
