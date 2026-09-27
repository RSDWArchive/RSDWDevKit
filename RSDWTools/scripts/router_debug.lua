local support = require("router_support")
local lazy_feature = support.lazy_feature

local feature_debug_hud = lazy_feature("feature_debug_hud")
local feature_debug_watch = lazy_feature("feature_debug_watch")

local M = {}

function M.try_handle(line)
    local compatibility = line:match("^compat%.([%w_]+)$")
    if compatibility then
        local ok, detail = require("feature_compatibility").run(compatibility)
        return true, ok, (ok and "ok compat." or "compat.") .. compatibility .. " " .. tostring(detail)
    end
    if line == "debug.hud.probe" then
        local ok, detail = feature_debug_hud.probe()
        if ok then return true, true, "ok debug.hud.probe " .. tostring(detail) end
        return true, false, "debug.hud.probe failed: " .. tostring(detail)
    end
    if line == "debug.hud.functions" then
        local ok, detail = feature_debug_hud.functions()
        if ok then return true, true, "ok debug.hud.functions " .. tostring(detail) end
        return true, false, "debug.hud.functions failed: " .. tostring(detail)
    end
    if line == "debug.hud.draw.probe" or line:sub(1, 21) == "debug.hud.draw.probe " then
        local arg = line:sub(22)
        local ok, detail = feature_debug_hud.draw_probe(arg)
        if ok then return true, true, "ok debug.hud.draw.probe " .. tostring(detail) end
        return true, false, "debug.hud.draw.probe failed: " .. tostring(detail)
    end
    if line == "debug.hud.show.list" then
        local ok, detail = feature_debug_hud.show_list()
        if ok then return true, true, "ok debug.hud.show.list " .. tostring(detail) end
        return true, false, "debug.hud.show.list failed: " .. tostring(detail)
    end
    if line == "debug.hud.show.reset" then
        local ok, detail = feature_debug_hud.show_reset()
        if ok then return true, true, "ok debug.hud.show.reset " .. tostring(detail) end
        return true, false, "debug.hud.show.reset failed: " .. tostring(detail)
    end
    if line == "debug.hud.show.cats" then
        local ok, detail = feature_debug_hud.show_cats()
        if ok then return true, true, "ok debug.hud.show.cats " .. tostring(detail) end
        return true, false, "debug.hud.show.cats failed: " .. tostring(detail)
    end
    if line:sub(1, 19) == "debug.hud.show.sub " then
        local ok, detail = feature_debug_hud.show_sub(line:sub(20))
        if ok then return true, true, "ok debug.hud.show.sub " .. tostring(detail) end
        return true, false, "debug.hud.show.sub failed: " .. tostring(detail)
    end
    if line:sub(1, 15) == "debug.hud.show " then
        local ok, detail = feature_debug_hud.show(line:sub(16))
        if ok then return true, true, "ok debug.hud.show " .. tostring(detail) end
        return true, false, "debug.hud.show failed: " .. tostring(detail)
    end
    if line:sub(1, 15) == "debug.hud.flag " then
        local ok, detail = feature_debug_hud.flag(line:sub(16))
        if ok then return true, true, "ok debug.hud.flag " .. tostring(detail) end
        return true, false, "debug.hud.flag failed: " .. tostring(detail)
    end
    if line == "debug.hud.target.next" then
        local ok, detail = feature_debug_hud.target_next()
        if ok then return true, true, "ok debug.hud.target.next " .. tostring(detail) end
        return true, false, "debug.hud.target.next failed: " .. tostring(detail)
    end
    if line == "debug.hud.target.prev" then
        local ok, detail = feature_debug_hud.target_prev()
        if ok then return true, true, "ok debug.hud.target.prev " .. tostring(detail) end
        return true, false, "debug.hud.target.prev failed: " .. tostring(detail)
    end
    if line == "debug.draw.label.clear" or line:sub(1, 23) == "debug.draw.label.clear " then
        local ok, detail = feature_debug_hud.draw_label_clear(line:sub(24))
        if ok then return true, true, "ok debug.draw.label.clear " .. tostring(detail) end
        return true, false, "debug.draw.label.clear failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "debug.draw.label " then
        local ok, detail = feature_debug_hud.draw_label(line:sub(18))
        if ok then return true, true, "ok debug.draw.label " .. tostring(detail) end
        return true, false, "debug.draw.label failed: " .. tostring(detail)
    end
    if line == "debug.watch.list" then
        local ok, detail = feature_debug_watch.list()
        if ok then return true, true, "ok debug.watch.list " .. tostring(detail) end
        return true, false, "debug.watch.list failed: " .. tostring(detail)
    end
    if line == "debug.watch.clear" then
        local ok, detail = feature_debug_watch.clear()
        if ok then return true, true, "ok debug.watch.clear " .. tostring(detail) end
        return true, false, "debug.watch.clear failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "debug.watch.probe " then
        local ok, detail = feature_debug_watch.probe(line:sub(19))
        if ok then return true, true, "ok debug.watch.probe " .. tostring(detail) end
        return true, false, "debug.watch.probe failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "debug.watch.snap " then
        local ok, detail = feature_debug_watch.snap(line:sub(18))
        if ok then return true, true, "ok debug.watch.snap " .. tostring(detail) end
        return true, false, "debug.watch.snap failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "debug.watch.diag " then
        local ok, detail = feature_debug_watch.diag(line:sub(18))
        if ok then return true, true, "ok debug.watch.diag " .. tostring(detail) end
        return true, false, "debug.watch.diag failed: " .. tostring(detail)
    end
    if line:sub(1, 19) == "debug.watch.remove " then
        local ok, detail = feature_debug_watch.remove(line:sub(20))
        if ok then return true, true, "ok debug.watch.remove " .. tostring(detail) end
        return true, false, "debug.watch.remove failed: " .. tostring(detail)
    end
    if line:sub(1, 16) == "debug.watch.add " then
        local ok, detail = feature_debug_watch.add(line:sub(17))
        if ok then return true, true, "ok debug.watch.add " .. tostring(detail) end
        return true, false, "debug.watch.add failed: " .. tostring(detail)
    end

    return false, nil, nil
end

return M
