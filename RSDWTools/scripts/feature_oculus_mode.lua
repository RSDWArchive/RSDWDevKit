-- Oculus modal mode coordinator.
--
-- Provides one hotkey-facing surface for Grab, Rotation, and Scale. When the
-- user switches from one modal tool to another, this module applies the
-- current mode, waits for its queued cleanup to settle, then starts the next
-- mode against the same actor reference.

local M = {}

local feature_actor = require("feature_actor")
local feature_grab = require("feature_grab")
local feature_oculus_async = require("feature_oculus_async")
local feature_oculus_input_guard = require("feature_oculus_input_guard")
local feature_oculus_proxy = require("feature_oculus_proxy")
local feature_oculus_rotation = require("feature_oculus_rotation")
local feature_oculus_scale = require("feature_oculus_scale")

local SWITCH_SETTLE_FRAMES = 4
local SWITCH_QUIET_FRAMES = 30
local SWITCH_START_DELAY_FRAMES = 6
local SWITCH_POST_GUARD_RELEASE_START_FRAMES = 6
local SWITCH_POST_START_GRAB_GUARD_FRAMES = 18
local SWITCH_RETRY_FRAMES = 2
local SWITCH_TIMEOUT_MS = 2500
local MODAL_REENTRY_SETTLE_SECONDS = 0.55

local pending_switch = nil
local pending_start = nil
local switch_token = 0
local modal_settle_until_clock = 0.0
local modal_settle_reason = nil

local function log_switch(pending, phase, detail)
    if type(pending) ~= "table" then return end
    print(string.format("[RSDWTools.oculus.mode] switch %s -> %s target=%s phase=%s%s",
        tostring(pending.from), tostring(pending.to), tostring(pending.name),
        tostring(phase or pending.phase or "unknown"),
        detail and (" ; " .. tostring(detail)) or ""))
end

local function normalize_mode(mode)
    local m = tostring(mode or ""):lower():match("^%s*(.-)%s*$") or ""
    if m == "rotate" then m = "rotation" end
    if m == "rot" then m = "rotation" end
    if m == "scaling" then m = "scale" end
    if m == "grab" or m == "rotation" or m == "scale" then return m end
    return nil
end

local function mode_label(mode)
    if mode == "grab" then return "Grab" end
    if mode == "rotation" then return "Rotation" end
    if mode == "scale" then return "Scale" end
    return tostring(mode or "unknown")
end

local function refresh_help(force)
    local cfg = package.loaded["feature_oculus_config"]
    if type(cfg) == "table" and type(cfg.refresh_hotkey_help) == "function" then
        pcall(function() cfg.refresh_hotkey_help(force == true) end)
    end
end

local function schedule_frames(frames, fn)
    return feature_oculus_async.schedule_game_thread_after_frames(frames, function()
        local ok, err = pcall(fn)
        if not ok then
            print("[RSDWTools.oculus.mode] scheduled step failed: " .. tostring(err))
        end
    end)
end

local function modal_settle_remaining()
    local remaining = (tonumber(modal_settle_until_clock) or 0.0) - os.clock()
    if remaining > 0 then return remaining end
    return 0.0
end

function M.note_settle(reason, seconds)
    local duration = tonumber(seconds) or MODAL_REENTRY_SETTLE_SECONDS
    if duration <= 0 then return true, "settle skipped" end
    local until_clock = os.clock() + duration
    if until_clock > (tonumber(modal_settle_until_clock) or 0.0) then
        modal_settle_until_clock = until_clock
        modal_settle_reason = tostring(reason or "modal")
    end
    return true, string.format("settle %.2fs reason=%s", duration, tostring(reason or "modal"))
end

local function release_pending_guard(pending, reason)
    if pending and pending.guard_token then
        pcall(function() feature_oculus_input_guard.release(pending.guard_token, reason or "mode.switch") end)
        pending.guard_token = nil
    end
end

local function release_pending_guard_after_frames(frames, pending, reason)
    if not pending or not pending.guard_token then return end
    schedule_frames(frames, function()
        release_pending_guard(pending, reason)
    end)
end

local function active_mode()
    if pending_start and pending_start.to == "grab" then return "grab_pending" end
    if feature_oculus_rotation.is_active and feature_oculus_rotation.is_active() then return "rotation" end
    if feature_oculus_scale.is_active and feature_oculus_scale.is_active() then return "scale" end
    if feature_oculus_proxy.is_active and feature_oculus_proxy.is_active() then return "grab" end
    if feature_grab.is_active and feature_grab.is_active() then return "grab" end
    if feature_grab.is_pending and feature_grab.is_pending() then return "grab_pending" end
    return nil
end

local function current_actor_for(mode)
    local actor, name, source
    if mode == "grab" then
        if feature_oculus_proxy.current_actor then
            actor, name, source = feature_oculus_proxy.current_actor()
        end
        if not feature_actor.is_valid_object(actor) and feature_grab.current_actor then
            actor, name, source = feature_grab.current_actor()
        end
    elseif mode == "rotation" and feature_oculus_rotation.current_actor then
        actor, name, source = feature_oculus_rotation.current_actor()
    elseif mode == "scale" and feature_oculus_scale.current_actor then
        actor, name, source = feature_oculus_scale.current_actor()
    end
    if feature_actor.is_valid_object(actor) then
        return actor, tostring(name or mode_label(mode)), tostring(source or mode)
    end
    return nil, nil, nil
end

local function apply_mode(mode, suppress_capture)
    if mode == "grab" then
        if feature_oculus_proxy.is_active and feature_oculus_proxy.is_active() then
            return feature_oculus_proxy.place_confirm()
        end
        return feature_grab.release()
    end
    if mode == "rotation" then return feature_oculus_rotation.stop(suppress_capture == true) end
    if mode == "scale" then return feature_oculus_scale.stop(suppress_capture == true) end
    return false, "no active mode to apply"
end

local function start_mode_on_actor(mode, actor)
    if not feature_actor.is_valid_object(actor) then return false, "target actor lost" end
    if mode == "grab" then
        return feature_grab.start_actor_preserving_transform(actor, nil, nil, {
            source = "mode.switch",
            context = "mode.switch",
            bypass_cooldown = true,
        })
    end
    if mode == "rotation" then
        return feature_oculus_rotation.start_actor(actor, "mode.switch")
    end
    if mode == "scale" then
        return feature_oculus_scale.start_actor(actor, "mode.switch")
    end
    return false, "unknown mode " .. tostring(mode)
end

local function start_mode_from_reticle(mode)
    if mode == "grab" then
        return feature_grab.start()
    end
    if mode == "rotation" then return feature_oculus_rotation.start() end
    if mode == "scale" then return feature_oculus_scale.start() end
    return false, "unknown mode " .. tostring(mode)
end

local function finish_pending_switch(token)
    local pending = pending_switch
    if not pending or pending.token ~= token then return end

    local current = active_mode()
    if current == pending.from or current == "grab_pending" then
        local elapsed_ms = (os.clock() - pending.started_clock) * 1000.0
        if elapsed_ms < SWITCH_TIMEOUT_MS then
            pending.phase = "waiting_current"
            schedule_frames(SWITCH_RETRY_FRAMES, function() finish_pending_switch(token) end)
            return
        end
        release_pending_guard(pending, "mode.switch.timeout")
        pending_switch = nil
        print(string.format("[RSDWTools.oculus.mode] switch %s -> %s timed out waiting for current mode to settle",
            tostring(pending.from), tostring(pending.to)))
        refresh_help(true)
        return
    end

    if current ~= nil then
        pending.clear_frames = nil
        pending.phase = "waiting_other"
        schedule_frames(SWITCH_RETRY_FRAMES, function() finish_pending_switch(token) end)
        return
    end

    if pending.clear_frames == nil then
        if not pending.guard_token then
            local guard_token = feature_oculus_input_guard.acquire("mode.switch." .. tostring(pending.from) .. ".to." .. tostring(pending.to))
            pending.guard_token = guard_token
        end
        pending.clear_frames = SWITCH_QUIET_FRAMES
        pending.phase = "quiet"
        log_switch(pending, "quiet", "frames=" .. tostring(SWITCH_QUIET_FRAMES))
        schedule_frames(1, function() finish_pending_switch(token) end)
        return
    end

    if pending.clear_frames > 0 then
        pending.clear_frames = pending.clear_frames - 1
        pending.phase = "quiet"
        schedule_frames(1, function() finish_pending_switch(token) end)
        return
    end

    if pending.starting == true then return end
    pending.starting = true
    pending.phase = "start_delay"
    log_switch(pending, "start_delay", "frames=" .. tostring(SWITCH_START_DELAY_FRAMES))
    schedule_frames(SWITCH_START_DELAY_FRAMES, function()
        local current_pending = pending_switch
        if not current_pending or current_pending.token ~= token then return end
        if active_mode() ~= nil then
            current_pending.starting = false
            current_pending.clear_frames = nil
            current_pending.phase = "waiting_restart"
            schedule_frames(SWITCH_RETRY_FRAMES, function() finish_pending_switch(token) end)
            return
        end

        local function start_destination()
            local start_pending = pending_switch
            if not start_pending or start_pending.token ~= token then return end
            if active_mode() ~= nil then
                start_pending.starting = false
                start_pending.clear_frames = nil
                start_pending.phase = "waiting_restart"
                schedule_frames(SWITCH_RETRY_FRAMES, function() finish_pending_switch(token) end)
                return
            end

            start_pending.phase = "start"
            log_switch(start_pending, "start", "begin")
            local ok_start, start_detail = start_mode_on_actor(start_pending.to, start_pending.actor)
            pending_switch = nil
            if ok_start then
                print(string.format("[RSDWTools.oculus.mode] switch %s -> %s ready target=%s ; %s",
                    tostring(start_pending.from), tostring(start_pending.to), tostring(start_pending.name), tostring(start_detail)))
                if start_pending.to == "grab" then
                    release_pending_guard_after_frames(SWITCH_POST_START_GRAB_GUARD_FRAMES, start_pending, "mode.switch.after_grab_start")
                end
            else
                release_pending_guard(start_pending, "mode.switch.start_failed")
                print(string.format("[RSDWTools.oculus.mode] switch %s -> %s failed target=%s ; %s",
                    tostring(start_pending.from), tostring(start_pending.to), tostring(start_pending.name), tostring(start_detail)))
                refresh_help(true)
            end
        end

        if current_pending.to ~= "grab" and current_pending.guard_token then
            log_switch(current_pending, "guard_release", "gap_frames=" .. tostring(SWITCH_POST_GUARD_RELEASE_START_FRAMES))
            release_pending_guard(current_pending, "mode.switch.before_start")
            current_pending.phase = "guard_release_gap"
            schedule_frames(SWITCH_POST_GUARD_RELEASE_START_FRAMES, start_destination)
            return
        end

        start_destination()
    end)
end

local function queue_switch(from_mode, to_mode)
    if pending_switch then
        return true, string.format("switch already queued %s -> %s target=%s",
            tostring(pending_switch.from), tostring(pending_switch.to), tostring(pending_switch.name))
    end

    local actor, name = current_actor_for(from_mode)
    if not feature_actor.is_valid_object(actor) then
        return false, "current " .. mode_label(from_mode) .. " target unavailable"
    end

    local guard_token = nil
    if from_mode == "grab" then
        guard_token = feature_oculus_input_guard.acquire("mode.switch.grab.to." .. tostring(to_mode))
    end

    local ok_apply, apply_detail = apply_mode(from_mode, true)
    if not ok_apply then
        if guard_token then feature_oculus_input_guard.release(guard_token, "mode.switch.apply_failed") end
        return false, "apply current mode failed: " .. tostring(apply_detail)
    end

    switch_token = switch_token + 1
    local token = switch_token
    pending_switch = {
        token = token,
        from = from_mode,
        to = to_mode,
        actor = actor,
        name = name,
        guard_token = guard_token,
        started_clock = os.clock(),
        phase = "settle",
    }
    log_switch(pending_switch, "queued", tostring(apply_detail))
    schedule_frames(SWITCH_SETTLE_FRAMES, function() finish_pending_switch(token) end)
    return true, string.format("switch queued %s -> %s target=%s ; %s",
        mode_label(from_mode), mode_label(to_mode), tostring(name), tostring(apply_detail))
end

local function queue_start_from_reticle(mode)
    if pending_start then
        return true, string.format("start already queued %s phase=%s",
            tostring(pending_start.to), tostring(pending_start.phase or "queued"))
    end

    switch_token = switch_token + 1
    local token = switch_token
    local guard_token = feature_oculus_input_guard.acquire("mode.start." .. tostring(mode))
    pending_start = {
        token = token,
        to = mode,
        guard_token = guard_token,
        phase = "queued",
        started_clock = os.clock(),
    }
    print(string.format("[RSDWTools.oculus.mode] start %s queued", tostring(mode)))

    local function attempt_start()
        local pending = pending_start
        if not pending or pending.token ~= token then return end
        local remaining = modal_settle_remaining()
        if remaining > 0 then
            pending.phase = "settle"
            pending.settle_remaining = remaining
            schedule_frames(SWITCH_RETRY_FRAMES, attempt_start)
            return
        end
        pending.phase = "start"
        print(string.format("[RSDWTools.oculus.mode] start %s begin", tostring(mode)))
        local ok_start, start_detail = start_mode_from_reticle(mode)
        pending_start = nil
        if ok_start then
            print(string.format("[RSDWTools.oculus.mode] start %s ready ; %s",
                tostring(mode), tostring(start_detail)))
            release_pending_guard_after_frames(SWITCH_POST_START_GRAB_GUARD_FRAMES, pending, "mode.start.ready")
        else
            release_pending_guard(pending, "mode.start.failed")
            print(string.format("[RSDWTools.oculus.mode] start %s failed ; %s",
                tostring(mode), tostring(start_detail)))
            refresh_help(true)
        end
    end

    schedule_frames(SWITCH_START_DELAY_FRAMES, attempt_start)

    return true, "start queued " .. mode
end

function M.activate(mode)
    local target = normalize_mode(mode)
    if not target then
        return false, "usage: camera.oculus.mode <grab|rotation|scale|status>"
    end

    local current = active_mode()
    if current == "grab_pending" then
        if target == "grab" then
            return true, "grab start already queued"
        end
        return false, "safe grab is still pending; press Grab again to cancel or wait for it to start"
    end

    if not current then
        return queue_start_from_reticle(target)
    end

    if current == target then
        return apply_mode(current, false)
    end

    return queue_switch(current, target)
end

function M.status()
    if pending_start then
        return true, string.format("pending start %s phase=%s settle=%.2fs",
            tostring(pending_start.to), tostring(pending_start.phase or "queued"),
            modal_settle_remaining())
    end
    if pending_switch then
        return true, string.format("pending %s -> %s target=%s phase=%s quiet_frames=%s",
            tostring(pending_switch.from), tostring(pending_switch.to), tostring(pending_switch.name),
            tostring(pending_switch.phase or "unknown"), tostring(pending_switch.clear_frames or "n/a"))
    end
    return true, string.format("active=%s settle=%.2fs reason=%s",
        tostring(active_mode() or "none"),
        modal_settle_remaining(),
        tostring(modal_settle_reason or "none"))
end

return M
