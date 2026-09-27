-- Shared Oculus scheduling helpers.
--
-- Keep hotkey callbacks cheap: record intent immediately, then run the
-- heavier reflected work on a later game-thread slice.

local M = {}

local FRAME_MS_FALLBACK = 16
local MAX_FRAME_JOBS_PER_TICK = 1

local frame_queue = {}
local frame_loop_active = false
local frame_cursor = 0

local function normalize_frames(frames)
    local n = tonumber(frames) or 1
    n = math.floor(n + 0.5)
    if n < 1 then n = 1 end
    return n
end

local function run_frame_queue()
    frame_cursor = frame_cursor + 1

    local ran = 0
    local i = 1
    while i <= #frame_queue do
        local job = frame_queue[i]
        if type(job) == "function" then
            table.remove(frame_queue, i)
            ran = ran + 1
            local ok, err = pcall(job)
            if not ok then
                print("[RSDWTools.oculus.async] legacy frame job failed: " .. tostring(err))
            end
            if ran >= MAX_FRAME_JOBS_PER_TICK then
                break
            end
        elseif type(job) ~= "table" then
            table.remove(frame_queue, i)
            print("[RSDWTools.oculus.async] discarded invalid frame job: " .. tostring(job))
        elseif job and job.frame <= frame_cursor then
            table.remove(frame_queue, i)
            ran = ran + 1
            local ok, err = pcall(job.fn)
            if not ok then
                print("[RSDWTools.oculus.async] frame job failed: " .. tostring(err))
            end
            if ran >= MAX_FRAME_JOBS_PER_TICK then
                break
            end
        else
            i = i + 1
        end
    end

    if #frame_queue == 0 then
        frame_loop_active = false
        return true
    end
    return false
end

local function ensure_frame_loop()
    if frame_loop_active then return true end
    if EngineTickAvailable == true and type(LoopInGameThreadAfterFrames) == "function" then
        local ok, handle_or_err = pcall(function()
            return LoopInGameThreadAfterFrames(1, run_frame_queue)
        end)
        if ok and handle_or_err then
            frame_loop_active = true
            return true
        end
        print("[RSDWTools.oculus.async] engine frame queue unavailable: " .. tostring(handle_or_err))
    end
    return false
end

function M.schedule_game_thread(delay_ms, fn)
    if type(fn) ~= "function" then return false, "no callback" end
    local ms = math.max(1, math.floor((tonumber(delay_ms) or 1) + 0.5))
    if LoopAsync then
        LoopAsync(ms, function()
            if ExecuteInGameThread then
                ExecuteInGameThread(function()
                    pcall(fn)
                end)
            else
                pcall(fn)
            end
            return true
        end)
        return true, "scheduled " .. tostring(ms) .. "ms"
    end
    pcall(fn)
    return true, "ran inline"
end

function M.schedule_game_thread_after_frames(frames, fn)
    if type(fn) ~= "function" then return false, "no callback" end
    local count = normalize_frames(frames)
    local job = {
        frame = frame_cursor + count,
        fn = fn,
    }
    table.insert(frame_queue, job)
    if ensure_frame_loop() then
        return true, "scheduled " .. tostring(count) .. " frame(s)"
    end
    for i = #frame_queue, 1, -1 do
        if frame_queue[i] == job then
            table.remove(frame_queue, i)
            break
        end
    end
    return M.schedule_game_thread(count * FRAME_MS_FALLBACK, fn)
end

function M.frame_queue_status()
    return {
        active = frame_loop_active == true,
        queued = #frame_queue,
        frame = frame_cursor,
    }
end

return M
