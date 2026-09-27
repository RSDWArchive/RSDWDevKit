-- Teleport feature: direct x/y/z player teleport + relative directional step + live-location reporter.

local M = {}

M.x = 0.0
M.y = 0.0
M.z = 0.0

-- Matches old RSDTools TELE_STEP for muscle-memory parity.
local DIRECTIONAL_DEFAULT_STEP = 200.0

local function is_valid(obj)
    return obj and obj.IsValid and obj:IsValid()
end

local feature_net = require("feature_net")
local function get_local_player_controller()
    return feature_net.local_controller()
end

local function get_local_pawn()
    return feature_net.local_pawn()
end

local function move_actor(actor, loc)
    if not is_valid(actor) then
        return false, "invalid actor"
    end
    if actor.K2_SetActorLocation then
        local ok_call, result = pcall(function()
            local hit = {}
            return actor:K2_SetActorLocation(loc, false, hit, true)
        end)
        if ok_call then
            return result ~= false, result == false and "K2_SetActorLocation returned false" or nil
        end
    end
    if actor.SetActorLocation then
        local ok_call, result = pcall(function()
            return actor:SetActorLocation(loc)
        end)
        if ok_call then
            return result ~= false, result == false and "SetActorLocation returned false" or nil
        end
    end
    return false, "no actor location setter"
end

local function apply_teleport_now()
    local pawn = get_local_pawn()
    if not pawn then
        return false, "local player pawn not found"
    end
    local dest = { X = M.x, Y = M.y, Z = M.z }
    return move_actor(pawn, dest)
end

function M.teleport_now(x, y, z)
    if x ~= nil and y ~= nil and z ~= nil then
        M.set_target(x, y, z)
    end
    local ok_tp, err = apply_teleport_now()
    if ok_tp then
        print(string.format("[RSDWTools] tele -> %.2f %.2f %.2f OK", M.x, M.y, M.z))
        return true, nil
    end
    print(string.format("[RSDWTools] tele -> %.2f %.2f %.2f FAILED (%s)", M.x, M.y, M.z, tostring(err)))
    return false, err
end

local function try_teleport()
    if not ExecuteInGameThread then
        print("[RSDWTools] ExecuteInGameThread missing.")
        return false, "ExecuteInGameThread missing"
    end
    local ok_outer, ok_inner = pcall(function()
        return ExecuteInGameThread(function()
            M.teleport_now()
        end)
    end)
    if not ok_outer then
        return false, tostring(ok_inner)
    end
    return true, nil
end

function M.set_target(x, y, z)
    M.x = tonumber(x) or 0
    M.y = tonumber(y) or 0
    M.z = tonumber(z) or 0
end

function M.apply_stub()
    return try_teleport()
end

function M.register_console()
    if not RegisterConsoleCommandHandler then
        return
    end
end

-- Reads the local player's current world location. Must be called on the game thread.
local function read_pawn_location()
    local pawn = get_local_pawn()
    if not pawn then
        return nil, "local player pawn not found"
    end
    if pawn.K2_GetActorLocation then
        local ok, loc = pcall(function() return pawn:K2_GetActorLocation() end)
        if ok and loc then return loc end
    end
    if pawn.GetActorLocation then
        local ok, loc = pcall(function() return pawn:GetActorLocation() end)
        if ok and loc then return loc end
    end
    return nil, "could not read pawn location"
end

-- Reads yaw from the pawn's rotation. Yaw is in degrees; 0 is +X, 90 is +Y.
local function read_pawn_yaw_deg()
    local pawn = get_local_pawn()
    if not pawn then return nil end
    local rot = nil
    if pawn.K2_GetActorRotation then
        local ok, r = pcall(function() return pawn:K2_GetActorRotation() end)
        if ok then rot = r end
    end
    if not rot and pawn.GetActorRotation then
        local ok, r = pcall(function() return pawn:GetActorRotation() end)
        if ok then rot = r end
    end
    if not rot then return nil end
    local ok_yaw, yaw = pcall(function() return rot.Yaw end)
    if ok_yaw and type(yaw) == "number" then return yaw end
    return nil
end

-- Applies a relative step based on pawn facing. `direction` is one of
-- left|right|forward|backward|up|down. `step` defaults to DIRECTIONAL_DEFAULT_STEP.
-- Runs on the caller's thread; wrap in ExecuteInGameThread at the call site.
function M.apply_directional(direction, step)
    direction = type(direction) == "string" and string.lower(direction) or ""
    local dist = tonumber(step) or DIRECTIONAL_DEFAULT_STEP

    local loc, err = read_pawn_location()
    if not loc then
        return false, err or "no pawn"
    end

    local dest = { X = loc.X, Y = loc.Y, Z = loc.Z }
    if direction == "up" then
        dest.Z = dest.Z + dist
    elseif direction == "down" then
        dest.Z = dest.Z - dist
    else
        -- Horizontal moves need yaw. Fall back to world-axis if yaw is unavailable.
        local yaw_deg = read_pawn_yaw_deg() or 0.0
        local yaw_rad = yaw_deg * math.pi / 180.0
        local fwd_x = math.cos(yaw_rad)
        local fwd_y = math.sin(yaw_rad)
        local right_x = -math.sin(yaw_rad)
        local right_y = math.cos(yaw_rad)

        if direction == "forward" then
            dest.X = dest.X + fwd_x * dist
            dest.Y = dest.Y + fwd_y * dist
        elseif direction == "backward" then
            dest.X = dest.X - fwd_x * dist
            dest.Y = dest.Y - fwd_y * dist
        elseif direction == "right" then
            dest.X = dest.X + right_x * dist
            dest.Y = dest.Y + right_y * dist
        elseif direction == "left" then
            dest.X = dest.X - right_x * dist
            dest.Y = dest.Y - right_y * dist
        else
            return false, "unknown direction: " .. tostring(direction)
        end
    end

    local pawn = get_local_pawn()
    if not pawn then
        return false, "local player pawn not found"
    end
    local ok, move_err = move_actor(pawn, dest)
    if ok then
        print(string.format(
            "[RSDWTools] tele.dir %s %.1f -> %.2f %.2f %.2f OK",
            direction, dist, dest.X, dest.Y, dest.Z
        ))
        return true, string.format("%.3f %.3f %.3f", dest.X, dest.Y, dest.Z)
    end
    print(string.format(
        "[RSDWTools] tele.dir %s %.1f -> %.2f %.2f %.2f FAILED (%s)",
        direction, dist, dest.X, dest.Y, dest.Z, tostring(move_err)
    ))
    return false, move_err or "move failed"
end

-- Reports the current pawn location as "<x> <y> <z>" with invariant (period) decimals.
-- Runs on caller's thread; wrap in ExecuteInGameThread at the call site.
--
-- The local pawn / controller pointer can briefly be nil between
-- streaming events, level transitions, or the very first tick after
-- a respawn. Callers (Save Location, Capture Build, Map polling) used
-- to surface that one-frame miss as a hard failure ; instead, retry a
-- handful of times before giving up so the human never has to "click
-- twice." Each attempt is cheap (single property fetch) so the small
-- spin doesn't perceptibly delay the ack.
function M.report_current_location()
    local last_err
    for _ = 1, 5 do
        local loc, err = read_pawn_location()
        if loc then
            return true, string.format("%.3f %.3f %.3f", loc.X or 0.0, loc.Y or 0.0, loc.Z or 0.0)
        end
        last_err = err
    end
    return false, last_err or "no pawn"
end

return M
