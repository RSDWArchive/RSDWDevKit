local M = {}

function M.lazy_feature(module_name)
    local module = nil
    return setmetatable({}, {
        __index = function(_, key)
            if not module then
                module = require(module_name)
            end
            return module[key]
        end
    })
end

function M.trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.arg_after(line, verb)
    return M.trim(tostring(line or ""):sub(#verb + 1))
end

function M.matches(line, verb)
    return line == verb or line:sub(1, #verb + 1) == verb .. " "
end

return M
