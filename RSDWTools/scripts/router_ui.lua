local support = require("router_support")
local lazy_feature = support.lazy_feature

local feature_umg = lazy_feature("feature_umg")
local feature_ui = lazy_feature("feature_ui")

local M = {}

function M.try_handle(line)
    -- Round 51: transient on-screen toast. Wire format:
    --   umg <duration_seconds> <message...>
    if line == "umg" or line:sub(1, 4) == "umg " then
        local rest = line:sub(5)
        local dur_str, text = rest:match("^%s*(%S+)%s+(.+)$")
        if not dur_str then
            return true, false, "umg requires <duration_seconds> <message>"
        end
        local dur = tonumber(dur_str)
        if not dur then
            return true, false, "umg duration must be a number ; got '" .. dur_str .. "'"
        end
        feature_umg.toast(text, dur)
        return true, true, "ok umg " .. dur_str
    end

    local tab = line:match("^ui%.tab%s+([%w_%-]+)%s*$")
    if tab then
        local normalized = tab:lower()
        if normalized == "tele" then
            normalized = "teleport"
        end
        if normalized == "home" then
            normalized = "player"
        end
        if feature_umg and feature_umg.set_external_tab then
            pcall(function() feature_umg.set_external_tab(normalized) end)
        end
        return true, true, "ok ui.tab " .. normalized
    end

    if line == "ui.widgets.scan" then
        local ok, detail = feature_ui.scan_widgets("all")
        if ok then return true, true, "ok ui.widgets.scan " .. tostring(detail) end
        return true, false, "ui.widgets.scan failed: " .. tostring(detail)
    end
    if line:sub(1, 16) == "ui.widgets.scan " then
        local scope = line:sub(17):match("^%s*(%S+)") or "all"
        local ok, detail = feature_ui.scan_widgets(scope)
        if ok then return true, true, "ok ui.widgets.scan " .. tostring(detail) end
        return true, false, "ui.widgets.scan failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "ui.widgets.setvis " then
        local ok, detail = feature_ui.set_widget_vis(line:sub(19))
        if ok then return true, true, "ok ui.widgets.setvis " .. tostring(detail) end
        return true, false, "ui.widgets.setvis failed: " .. tostring(detail)
    end
    if line:sub(1, 19) == "ui.widgets.hudroot " then
        local ok, detail = feature_ui.set_hud_root(line:sub(20))
        if ok then return true, true, "ok ui.widgets.hudroot " .. tostring(detail) end
        return true, false, "ui.widgets.hudroot failed: " .. tostring(detail)
    end
    if line:sub(1, 20) == "ui.widgets.activate " then
        local ok, detail = feature_ui.activate_widget(line:sub(21))
        if ok then return true, true, "ok ui.widgets.activate " .. tostring(detail) end
        return true, false, "ui.widgets.activate failed: " .. tostring(detail)
    end
    if line:sub(1, 16) == "ui.widgets.push " then
        local ok, detail = feature_ui.push_widget(line:sub(17))
        if ok then return true, true, "ok ui.widgets.push " .. tostring(detail) end
        return true, false, "ui.widgets.push failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "ui.menus.navigate " then
        local ok, detail = feature_ui.menus_navigate(line:sub(19))
        if ok then return true, true, "ok ui.menus.navigate " .. tostring(detail) end
        return true, false, "ui.menus.navigate failed: " .. tostring(detail)
    end
    if line:sub(1, 15) == "ui.widgets.set " then
        local ok, detail = feature_ui.set_widget(line:sub(16))
        if ok then return true, true, "ok ui.widgets.set " .. tostring(detail) end
        return true, false, "ui.widgets.set failed: " .. tostring(detail)
    end
    if line == "ui.widgets.resetall" then
        local ok, detail = feature_ui.reset_all()
        if ok then return true, true, "ok ui.widgets.resetall " .. tostring(detail) end
        return true, false, "ui.widgets.resetall failed: " .. tostring(detail)
    end
    if line == "ui.widgets.hideall" then
        local ok, detail = feature_ui.hide_all()
        if ok then return true, true, "ok ui.widgets.hideall " .. tostring(detail) end
        return true, false, "ui.widgets.hideall failed: " .. tostring(detail)
    end

    if line == "rsdwt_hotkeys_reload" then
        local ok, mod = pcall(require, "feature_hotkeys")
        if not ok or type(mod) ~= "table" then
            return true, false, "feature_hotkeys missing: " .. tostring(mod)
        end
        local rok, rerr = pcall(function() mod.reload() end)
        if not rok then return true, false, "reload crashed: " .. tostring(rerr) end
        return true, true, "ok rsdwt_hotkeys_reload"
    end

    return false, nil, nil
end

return M