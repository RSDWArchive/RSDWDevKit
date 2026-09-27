-- Shared-memory bridge Lua hooks (Phase 1 line protocol).
-- Uses globals exported by the UE4SS C++ wrapper mod.

local M = {}

local started = false
local available = false
local last_error = ""

function M.is_available()
    return available
end

function M.last_error()
    return last_error
end

function M.start()
    if started then
        return available
    end
    started = true

    if type(rawget(_G, "BridgeLineInitCpp")) == "function"
        and type(rawget(_G, "BridgeLinePollRequestCpp")) == "function"
        and type(rawget(_G, "BridgeLineWriteAckCpp")) == "function" then
        local okg, rg = pcall(function() return BridgeLineInitCpp() end)
        available = okg and tonumber(rg or 0) == 1
        use_globals = available
        if not available then
            last_error = "BridgeLineInitCpp failed"
        end
        return available
    end
    available = false
    last_error = "BridgeLine*Cpp globals unavailable (wrapper mod not loaded)"
    return false
end

-- Non-blocking poll: returns command line string or nil.
function M.poll_request()
    if not available then
        return nil
    end
    local okg, line = pcall(function()
        return BridgeLinePollRequestCpp()
    end)
    if not okg then
        last_error = tostring(line)
        return nil
    end
    if type(line) ~= "string" or line == "" then
        return nil
    end
    return line
end

function M.write_ack(line)
    if not available then
        return false
    end
    local okg, rv = pcall(function()
        return BridgeLineWriteAckCpp(tostring(line or ""))
    end)
    if not okg then
        last_error = tostring(rv)
        return false
    end
    return tonumber(rv or 0) == 1 or rv == true
end

return M

