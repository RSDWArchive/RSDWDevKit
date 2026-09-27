-- Opt-in, one-shot observer. Never spawn, mutate parameters, or deliver from a hook.
local M = {}
local actors = require("feature_actor")
local net = require("feature_net")
local access = require("feature_build_access")
local hook_path = "/Script/Dominion.BuildModeComponent:Server_SpawnBuilding"
local hook_ids
local session

local function unwrap(value)
    local ok, result = pcall(function() return value:get() end)
    if ok then return result end
    return value
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function number(value, label)
    if not finite(value) then error("unreadable " .. label) end
    return value
end

local function vector(value, label)
    return {
        X = number(value.X, label .. ".X"), Y = number(value.Y, label .. ".Y"),
        Z = number(value.Z, label .. ".Z"),
    }
end

local function expire()
    if session and session.state == "waiting" and os.time() >= session.expires then
        session.state = "expired"
    end
end

local function on_spawn(context, index_arg, transform_arg, ghost_arg)
    expire()
    local current = session
    if not current or current.state ~= "waiting" then return end
    local ok, err = pcall(function()
        local bmc = unwrap(context)
        if not actors.is_valid_object(bmc) or bmc:GetAddress() ~= current.address then return end
        current.local_events = current.local_events + 1
        local index = unwrap(index_arg)
        if not finite(index) then error("unreadable piece data index") end
        if index ~= current.index then
            current.other_piece_events = current.other_piece_events + 1
            return
        end
        -- Copy only primitives while the native parameter storage is alive.
        local transform = unwrap(transform_arg)
        local location = vector(transform.Translation, "Translation")
        local rotation = vector(transform.Rotation, "Rotation")
        rotation.W = number(transform.Rotation.W, "Rotation.W")
        local scale = vector(transform.Scale3D, "Scale3D")
        local ghost = unwrap(ghost_arg)
        if type(ghost) ~= "boolean" then error("unreadable ghost flag") end
        local norm = rotation.X^2 + rotation.Y^2 + rotation.Z^2 + rotation.W^2
        if not finite(norm) or math.abs(norm - 1) > 0.01 then error("invalid rotation quaternion") end
        current.result = { location = location, rotation = rotation, scale = scale, ghost = ghost }
        current.state = "captured"
        if current.on_ready then
            -- ExecuteInGameThread alone can run inline from a game-thread hook.
            -- The one-shot delay ensures delivery starts after native placement returns.
            ExecuteWithDelay(100, function()
                if session ~= current or current.state ~= "captured" then return end
                local scheduled, schedule_error = pcall(function()
                    ExecuteInGameThread(function()
                        if session ~= current or current.state ~= "captured" then return end
                        current.state = "consumed"
                        local applied, apply_error = pcall(current.on_ready, current.result)
                        if not applied then current.state = "error"; current.error = tostring(apply_error) end
                    end)
                end)
                if not scheduled then current.state = "error"; current.error = tostring(schedule_error) end
            end)
        end
    end)
    if not ok then current.state = "error"; current.error = tostring(err) end
    -- No logging/UI, UObject retention, re-entrant RPCs or unregistration here.
end

function M.watch(on_ready, reserved_id)
    expire()
    if session and session.state == "waiting" then return false, "already watching; run placement.status or placement.clear" end
    if not RegisterHook then return false, "RegisterHook unavailable" end
    if on_ready and (not ExecuteWithDelay or not ExecuteInGameThread) then
        return false, "deferred game-thread scheduling unavailable"
    end
    local pc = net.local_controller()
    if not actors.is_valid_object(pc) then return false, "no local player controller" end
    local ok, bmc = pcall(function() return pc:GetBuildModeComponent() end)
    if not ok or not actors.is_valid_object(bmc) then return false, "no BuildModeComponent" end
    if access.mode(bmc) ~= 2 then return false, "select a vanilla building piece first (placement mode required)" end
    local data = access.selected_data(bmc)
    local index, address
    ok = pcall(function() index = data.BuildingPieceDataIndex; address = bmc:GetAddress() end)
    if not ok or not finite(index) or index < 0 or index % 1 ~= 0 or not finite(address) or address == 0 then
        return false, "could not identify the local placement component and selected piece"
    end
    local buildings = require("feature_buildings")
    if buildings._delivery_active and buildings._delivery_active.id ~= reserved_id then
        return false, "finish/cancel the active delivery before watching vanilla placement"
    end
    if not hook_ids then
        local registered, pre, post = pcall(function() return RegisterHook(hook_path, on_spawn) end)
        if not registered then return false, "placement hook unavailable: " .. tostring(pre) end
        hook_ids = { pre = pre, post = post }
    end
    session = { state = "waiting", index = index, address = address, expires = os.time() + 120,
        local_events = 0, other_piece_events = 0, on_ready = on_ready }
    return true, "watching one local placement for piece_data_index=" .. tostring(index)
        .. "; place that piece normally in-game, then run build.preview.placement.status; timeout=120s; observer only"
end

function M.state()
    expire()
    return session and session.state or "inactive", session and session.error
end

function M.status()
    expire()
    if not session then return true, "placement_probe inactive hook=" .. (hook_ids and "registered" or "off") end
    local current = session
    local message = string.format("placement_probe state=%s piece_data_index=%d local_events=%d other_piece_events=%d",
        current.state, current.index, current.local_events, current.other_piece_events)
    if current.error then return false, message .. " error=" .. current.error end
    local r = current.result
    if r then
        local q = r.rotation
        local yaw = math.atan(2 * (q.W*q.Z + q.X*q.Y), 1 - 2*(q.Y*q.Y + q.Z*q.Z)) * 180 / math.pi
        message = message .. string.format(" loc=(%.3f,%.3f,%.3f) quat=(%.6f,%.6f,%.6f,%.6f) yaw=%.3f scale=(%.3f,%.3f,%.3f) ghost=%s; RPC observed, not server-confirmed",
            r.location.X, r.location.Y, r.location.Z, q.X, q.Y, q.Z, q.W, yaw,
            r.scale.X, r.scale.Y, r.scale.Z, tostring(r.ghost))
    end
    return true, message
end

function M.clear()
    session = nil
    if hook_ids then
        if not UnregisterHook then return false, "cleared; hook remains inactive (UnregisterHook unavailable)" end
        local ok, err = pcall(function() UnregisterHook(hook_path, hook_ids.pre, hook_ids.post) end)
        if not ok then return false, "cleared; hook remains inactive: " .. tostring(err) end
        hook_ids = nil
    end
    return true, "cleared placement observer; no building/preview state changed"
end

return M
