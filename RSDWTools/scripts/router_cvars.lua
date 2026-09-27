local support = require("router_support")
local lazy_feature = support.lazy_feature
local trim = support.trim

local feature_cvars = lazy_feature("feature_cvars")

local M = {}

function M.try_handle(line)
    if line == "cvars.dump" then
        local ok, detail = feature_cvars.dump()
        if ok then return true, true, "ok cvars.dump " .. tostring(detail) end
        return true, false, "cvars.dump failed: " .. tostring(detail)
    end

    if line == "cvars.filming" or line:sub(1, 14) == "cvars.filming " then
        local ok, detail = feature_cvars.filming(trim(line:sub(14)))
        if ok then return true, true, "ok cvars.filming " .. tostring(detail) end
        return true, false, "cvars.filming failed: " .. tostring(detail)
    end

    if line:sub(1, 9) == "cvars.set" then
        local ok, detail = feature_cvars.set(trim(line:sub(10)))
        if ok then return true, true, "ok cvars.set " .. tostring(detail) end
        return true, false, "cvars.set failed: " .. tostring(detail)
    end

    return false, nil, nil
end

return M