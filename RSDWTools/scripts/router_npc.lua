local support = require("router_support")
local lazy_feature = support.lazy_feature
local matches = support.matches
local arg_after = support.arg_after

local feature_npc_drive = lazy_feature("feature_npc_drive")
local feature_npc_inspect = lazy_feature("feature_npc_inspect")

local M = {}

function M.try_handle(line)
    -- npc.drive.* experimental intact-NPC control verbs. These intentionally
    -- avoid PlayerController possession; the AI remains owned by its AIController.
    if line == "npc.drive" or line:sub(1, 10) == "npc.drive." then
        if matches(line, "npc.drive.select") then
            local ok, detail = feature_npc_drive.select(arg_after(line, "npc.drive.select"))
            if ok then return true, true, "ok npc.drive.select " .. tostring(detail) end
            return true, false, "npc.drive.select failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.status") then
            local ok, detail = feature_npc_drive.status()
            if ok then return true, true, "ok npc.drive.status " .. tostring(detail) end
            return true, false, "npc.drive.status failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.probe") then
            local ok, detail = feature_npc_drive.probe()
            if ok then return true, true, "ok npc.drive.probe " .. tostring(detail) end
            return true, false, "npc.drive.probe failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.camera") then
            local ok, detail = feature_npc_drive.camera(arg_after(line, "npc.drive.camera"))
            if ok then return true, true, "ok npc.drive.camera " .. tostring(detail) end
            return true, false, "npc.drive.camera failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.hideplayer") then
            local ok, detail = feature_npc_drive.hideplayer(arg_after(line, "npc.drive.hideplayer"))
            if ok then return true, true, "ok npc.drive.hideplayer " .. tostring(detail) end
            return true, false, "npc.drive.hideplayer failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.brain") then
            local ok, detail = feature_npc_drive.brain(arg_after(line, "npc.drive.brain"))
            if ok then return true, true, "ok npc.drive.brain " .. tostring(detail) end
            return true, false, "npc.drive.brain failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.quiet") then
            local ok, detail = feature_npc_drive.quiet(arg_after(line, "npc.drive.quiet"))
            if ok then return true, true, "ok npc.drive.quiet " .. tostring(detail) end
            return true, false, "npc.drive.quiet failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.tune") then
            local ok, detail = feature_npc_drive.tune(arg_after(line, "npc.drive.tune"))
            if ok then return true, true, "ok npc.drive.tune " .. tostring(detail) end
            return true, false, "npc.drive.tune failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.aimove") then
            local ok, detail = feature_npc_drive.aimove(arg_after(line, "npc.drive.aimove"))
            if ok then return true, true, "ok npc.drive.aimove " .. tostring(detail) end
            return true, false, "npc.drive.aimove failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.roamdata") then
            local ok, detail = feature_npc_drive.roamdata(arg_after(line, "npc.drive.roamdata"))
            if ok then return true, true, "ok npc.drive.roamdata " .. tostring(detail) end
            return true, false, "npc.drive.roamdata failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.puppet") then
            local ok, detail = feature_npc_drive.puppet(arg_after(line, "npc.drive.puppet"))
            if ok then return true, true, "ok npc.drive.puppet " .. tostring(detail) end
            return true, false, "npc.drive.puppet failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.hold") then
            local ok, detail = feature_npc_drive.hold(arg_after(line, "npc.drive.hold"))
            if ok then return true, true, "ok npc.drive.hold " .. tostring(detail) end
            return true, false, "npc.drive.hold failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.move") then
            local ok, detail = feature_npc_drive.move(arg_after(line, "npc.drive.move"))
            if ok then return true, true, "ok npc.drive.move " .. tostring(detail) end
            return true, false, "npc.drive.move failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.face") then
            local ok, detail = feature_npc_drive.face(arg_after(line, "npc.drive.face"))
            if ok then return true, true, "ok npc.drive.face " .. tostring(detail) end
            return true, false, "npc.drive.face failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.jump") then
            local ok, detail = feature_npc_drive.jump(arg_after(line, "npc.drive.jump"))
            if ok then return true, true, "ok npc.drive.jump " .. tostring(detail) end
            return true, false, "npc.drive.jump failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.repairinput") then
            local ok, detail = feature_npc_drive.repair_player_input(arg_after(line, "npc.drive.repairinput"))
            if ok then return true, true, "ok npc.drive.repairinput " .. tostring(detail) end
            return true, false, "npc.drive.repairinput failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.attack") then
            local ok, detail = feature_npc_drive.attack(arg_after(line, "npc.drive.attack"))
            if ok then return true, true, "ok npc.drive.attack " .. tostring(detail) end
            return true, false, "npc.drive.attack failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.action") then
            local ok, detail = feature_npc_drive.action(arg_after(line, "npc.drive.action"))
            if ok then return true, true, "ok npc.drive.action " .. tostring(detail) end
            return true, false, "npc.drive.action failed: " .. tostring(detail)
        end
        if matches(line, "npc.drive.clear") then
            local ok, detail = feature_npc_drive.clear()
            if ok then return true, true, "ok npc.drive.clear " .. tostring(detail) end
            return true, false, "npc.drive.clear failed: " .. tostring(detail)
        end

        return true, false, "unknown npc.drive.* verb"
    end

    -- npc.inspect.* stages an NPC and renders the inspect UMG surfaces.
    if line == "npc.inspect" or line:sub(1, 12) == "npc.inspect." then
        if matches(line, "npc.inspect.on") then
            local ok, detail = feature_npc_inspect.on(arg_after(line, "npc.inspect.on"))
            if ok then return true, true, "ok npc.inspect.on " .. tostring(detail) end
            return true, false, "npc.inspect.on failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.off") then
            local ok, detail = feature_npc_inspect.off()
            if ok then return true, true, "ok npc.inspect.off " .. tostring(detail) end
            return true, false, "npc.inspect.off failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.forceoff") or matches(line, "npc.inspect.stop") then
            local ok, detail = feature_npc_inspect.forceoff()
            if ok then return true, true, "ok npc.inspect.forceoff " .. tostring(detail) end
            return true, false, "npc.inspect.forceoff failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.snap") then
            local ok, detail = feature_npc_inspect.snap(arg_after(line, "npc.inspect.snap"))
            if ok then return true, true, "ok npc.inspect.snap " .. tostring(detail) end
            return true, false, "npc.inspect.snap failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.overlay") then
            local ok, detail = feature_npc_inspect.overlay(arg_after(line, "npc.inspect.overlay"))
            if ok then return true, true, "ok npc.inspect.overlay " .. tostring(detail) end
            return true, false, "npc.inspect.overlay failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.orbit") then
            local ok, detail = feature_npc_inspect.orbit(arg_after(line, "npc.inspect.orbit"))
            if ok then return true, true, "ok npc.inspect.orbit " .. tostring(detail) end
            return true, false, "npc.inspect.orbit failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.mouse") then
            local ok, detail = feature_npc_inspect.mouse(arg_after(line, "npc.inspect.mouse"))
            if ok then return true, true, "ok npc.inspect.mouse " .. tostring(detail) end
            return true, false, "npc.inspect.mouse failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.focus") then
            local ok, detail = feature_npc_inspect.focus(arg_after(line, "npc.inspect.focus"))
            if ok then return true, true, "ok npc.inspect.focus " .. tostring(detail) end
            return true, false, "npc.inspect.focus failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.hud") then
            local ok, detail = feature_npc_inspect.hud(arg_after(line, "npc.inspect.hud"))
            if ok then return true, true, "ok npc.inspect.hud " .. tostring(detail) end
            return true, false, "npc.inspect.hud failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.umg") then
            local ok, detail = feature_npc_inspect.umg(arg_after(line, "npc.inspect.umg"))
            if ok then return true, true, "ok npc.inspect.umg " .. tostring(detail) end
            return true, false, "npc.inspect.umg failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.nudge") then
            local ok, detail = feature_npc_inspect.nudge(arg_after(line, "npc.inspect.nudge"))
            if ok then return true, true, "ok npc.inspect.nudge " .. tostring(detail) end
            return true, false, "npc.inspect.nudge failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.scan") then
            local ok, detail = feature_npc_inspect.scan(arg_after(line, "npc.inspect.scan"))
            if ok then return true, true, "ok npc.inspect.scan " .. tostring(detail) end
            return true, false, "npc.inspect.scan failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.state") then
            local ok, detail = feature_npc_inspect.state()
            if ok then return true, true, "ok npc.inspect.state " .. tostring(detail) end
            return true, false, "npc.inspect.state failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.status") then
            local ok, detail = feature_npc_inspect.status()
            if ok then return true, true, "ok npc.inspect.status " .. tostring(detail) end
            return true, false, "npc.inspect.status failed: " .. tostring(detail)
        end
        if matches(line, "npc.inspect.select") then
            local ok, detail = feature_npc_inspect.select(arg_after(line, "npc.inspect.select"))
            if ok then return true, true, "ok npc.inspect.select " .. tostring(detail) end
            return true, false, "npc.inspect.select failed: " .. tostring(detail)
        end

        return true, false, "unknown npc.inspect.* verb"
    end

    return false, nil, nil
end

return M