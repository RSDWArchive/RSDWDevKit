local support = require("router_support")
local lazy_feature = support.lazy_feature

local feature_probe = lazy_feature("feature_probe")

local M = {}

if RSDWTOOLS_PROBE_DEBUG == nil then
    RSDWTOOLS_PROBE_DEBUG = true
end

local PROBE_NOISE_PATTERNS = {
    "not currently live",
    "no live instance",
    "no live instance of",
    "FindAllOf failed",
}

local function probe_failure_is_noise(body)
    if type(body) ~= "string" then return false end
    for _, pattern in ipairs(PROBE_NOISE_PATTERNS) do
        if body:find(pattern, 1, true) then return true end
    end
    return false
end

function M.try_handle(line)
    if line:sub(1, 14) == "probe.resolve " then
        local ok, detail = feature_probe.resolve(line:sub(15))
        if ok then return true, true, "ok probe.resolve " .. tostring(detail) end
        if RSDWTOOLS_PROBE_DEBUG and not probe_failure_is_noise(detail) then
            print("[RSDWTools][probe.resolve] " .. line:sub(15) .. " -> " .. tostring(detail))
        end
        return true, false, "probe.resolve failed: " .. tostring(detail)
    end
    if line:sub(1, 11) == "probe.read " then
        local ok, detail = feature_probe.read(line:sub(12))
        if ok then return true, true, "ok probe.read " .. tostring(detail) end
        if RSDWTOOLS_PROBE_DEBUG and not probe_failure_is_noise(detail) then
            print("[RSDWTools][probe.read] " .. line:sub(12) .. " -> " .. tostring(detail))
        end
        return true, false, "probe.read failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "probe.find_class " then
        local ok, detail = feature_probe.find_class(line:sub(18))
        if ok then return true, true, "ok probe.find_class " .. tostring(detail) end
        if RSDWTOOLS_PROBE_DEBUG and not probe_failure_is_noise(detail) then
            print("[RSDWTools][probe.find_class] " .. line:sub(18) .. " -> " .. tostring(detail))
        end
        return true, false, "probe.find_class failed: " .. tostring(detail)
    end
    if line:sub(1, 19) == "probe.widget.spawn " then
        local ok, detail = feature_probe.widget_spawn(line:sub(20))
        if ok then return true, true, "ok probe.widget.spawn " .. tostring(detail) end
        return true, false, "probe.widget.spawn failed: " .. tostring(detail)
    end
    if line == "probe.widget.remove" or line:sub(1, 20) == "probe.widget.remove " then
        local ok, detail = feature_probe.widget_remove(line:sub(21))
        if ok then return true, true, "ok probe.widget.remove " .. tostring(detail) end
        return true, false, "probe.widget.remove failed: " .. tostring(detail)
    end
    if line == "probe.widget.list" then
        local ok, detail = feature_probe.widget_list("")
        if ok then return true, true, "ok probe.widget.list " .. tostring(detail) end
        return true, false, "probe.widget.list failed: " .. tostring(detail)
    end

    return false, nil, nil
end

return M