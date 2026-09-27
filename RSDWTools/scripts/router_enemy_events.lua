local support = require("router_support")
local lazy_feature = support.lazy_feature
local matches = support.matches
local arg_after = support.arg_after

local feature_enemy_aggro = lazy_feature("feature_enemy_aggro")
local feature_world_events = lazy_feature("feature_world_events")

local M = {}

local function ok_or_fail(prefix, ok, detail)
    if ok then return true, true, "ok " .. prefix .. " " .. tostring(detail) end
    return true, false, prefix .. " failed: " .. tostring(detail)
end

function M.try_handle(line)
    if line == "enemy.aggro" or line:sub(1, #"enemy.aggro.") == "enemy.aggro." then
        if matches(line, "enemy.aggro.scan") then
            return ok_or_fail("enemy.aggro.scan", feature_enemy_aggro.scan(arg_after(line, "enemy.aggro.scan")))
        end
        if matches(line, "enemy.aggro.discover") then
            return ok_or_fail("enemy.aggro.discover", feature_enemy_aggro.discover(arg_after(line, "enemy.aggro.discover")))
        end
        if matches(line, "enemy.aggro.status") then
            return ok_or_fail("enemy.aggro.status", feature_enemy_aggro.status(arg_after(line, "enemy.aggro.status")))
        end
        if matches(line, "enemy.aggro.target") then
            return ok_or_fail("enemy.aggro.target", feature_enemy_aggro.target(arg_after(line, "enemy.aggro.target")))
        end
        if matches(line, "enemy.aggro.draw") then
            return ok_or_fail("enemy.aggro.draw", feature_enemy_aggro.draw(arg_after(line, "enemy.aggro.draw")))
        end
        if matches(line, "enemy.aggro.force") then
            return ok_or_fail("enemy.aggro.force", feature_enemy_aggro.force(arg_after(line, "enemy.aggro.force")))
        end
        if matches(line, "enemy.aggro.clear") then
            return ok_or_fail("enemy.aggro.clear", feature_enemy_aggro.clear(arg_after(line, "enemy.aggro.clear")))
        end
        if matches(line, "enemy.aggro.restore") then
            return ok_or_fail("enemy.aggro.restore", feature_enemy_aggro.restore(arg_after(line, "enemy.aggro.restore")))
        end
        return true, false, "unknown enemy.aggro.* verb"
    end

    if line == "world.wave" or line:sub(1, #"world.wave ") == "world.wave " then
        return ok_or_fail("world.wave", feature_world_events.light_wave(arg_after(line, "world.wave")))
    end

    if line == "world.dragon" or line:sub(1, #"world.dragon ") == "world.dragon " then
        return ok_or_fail("world.dragon", feature_world_events.light_dragon(arg_after(line, "world.dragon")))
    end

    if line == "world.encounter" or line:sub(1, #"world.encounter.") == "world.encounter." then
        if matches(line, "world.encounter.stop") then
            return ok_or_fail("world.encounter.stop", feature_world_events.encounter_stop(arg_after(line, "world.encounter.stop")))
        end
        if matches(line, "world.encounter.cleanup") then
            return ok_or_fail("world.encounter.cleanup", feature_world_events.encounter_stop(arg_after(line, "world.encounter.cleanup")))
        end
        return true, false, "unknown world.encounter.* verb"
    end

    if line == "world.event" or line:sub(1, #"world.event.") == "world.event." then
        if matches(line, "world.event.list") then
            return ok_or_fail("world.event.list", feature_world_events.list(arg_after(line, "world.event.list")))
        end
        if matches(line, "world.event.probe") then
            return ok_or_fail("world.event.probe", feature_world_events.probe(arg_after(line, "world.event.probe")))
        end
        if matches(line, "world.event.definitions") then
            return ok_or_fail("world.event.definitions", feature_world_events.probe(arg_after(line, "world.event.definitions")))
        end
        if matches(line, "world.event.definition") then
            return ok_or_fail("world.event.definition", feature_world_events.definition(arg_after(line, "world.event.definition")))
        end
        if matches(line, "world.event.def") then
            return ok_or_fail("world.event.def", feature_world_events.definition(arg_after(line, "world.event.def")))
        end
        if matches(line, "world.event.defstate") then
            return ok_or_fail("world.event.defstate", feature_world_events.definition_state(arg_after(line, "world.event.defstate")))
        end
        if matches(line, "world.event.resolve") then
            return ok_or_fail("world.event.resolve", feature_world_events.resolve(arg_after(line, "world.event.resolve")))
        end
        if matches(line, "world.event.triggers") then
            return ok_or_fail("world.event.triggers", feature_world_events.triggers(arg_after(line, "world.event.triggers")))
        end
        if matches(line, "world.event.managerstate") then
            return ok_or_fail("world.event.managerstate", feature_world_events.manager_state(arg_after(line, "world.event.managerstate")))
        end
        if matches(line, "world.event.manager") then
            return ok_or_fail("world.event.manager", feature_world_events.manager_state(arg_after(line, "world.event.manager")))
        end
        if matches(line, "world.event.triggerscan") then
            return ok_or_fail("world.event.triggerscan", feature_world_events.trigger_scan(arg_after(line, "world.event.triggerscan")))
        end
        if matches(line, "world.event.triggervalue") then
            return ok_or_fail("world.event.triggervalue", feature_world_events.trigger_value(arg_after(line, "world.event.triggervalue")))
        end
        if matches(line, "world.event.firetrigger") then
            return ok_or_fail("world.event.firetrigger", feature_world_events.fire_trigger(arg_after(line, "world.event.firetrigger")))
        end
        if matches(line, "world.event.fireobject") then
            return ok_or_fail("world.event.fireobject", feature_world_events.fire_object(arg_after(line, "world.event.fireobject")))
        end
        if matches(line, "world.event.resettrigger") then
            return ok_or_fail("world.event.resettrigger", feature_world_events.reset_trigger(arg_after(line, "world.event.resettrigger")))
        end
        if matches(line, "world.event.resetobject") then
            return ok_or_fail("world.event.resetobject", feature_world_events.reset_object(arg_after(line, "world.event.resetobject")))
        end
        if matches(line, "world.event.active") then
            return ok_or_fail("world.event.active", feature_world_events.active(arg_after(line, "world.event.active")))
        end
        if matches(line, "world.event.status") then
            return ok_or_fail("world.event.status", feature_world_events.active(arg_after(line, "world.event.status")))
        end
        if matches(line, "world.event.eventstate") then
            return ok_or_fail("world.event.eventstate", feature_world_events.event_state(arg_after(line, "world.event.eventstate")))
        end
        if matches(line, "world.event.aicomponent.link") then
            return ok_or_fail("world.event.aicomponent.link", feature_world_events.ai_component_link(arg_after(line, "world.event.aicomponent.link")))
        end
        if matches(line, "world.event.aicomponent") then
            return ok_or_fail("world.event.aicomponent", feature_world_events.ai_component(arg_after(line, "world.event.aicomponent")))
        end
        if matches(line, "world.event.waves") then
            return ok_or_fail("world.event.waves", feature_world_events.waves(arg_after(line, "world.event.waves")))
        end
        if matches(line, "world.event.spawnwave") then
            return ok_or_fail("world.event.spawnwave", feature_world_events.spawn_wave(arg_after(line, "world.event.spawnwave")))
        end
        if matches(line, "world.event.cleanupspawned") then
            return ok_or_fail("world.event.cleanupspawned", feature_world_events.cleanup_spawned(arg_after(line, "world.event.cleanupspawned")))
        end
        if matches(line, "world.event.spawned") then
            return ok_or_fail("world.event.spawned", feature_world_events.cleanup_spawned(arg_after(line, "world.event.spawned")))
        end
        if matches(line, "world.event.startwave") then
            return ok_or_fail("world.event.startwave", feature_world_events.start_wave(arg_after(line, "world.event.startwave")))
        end
        if matches(line, "world.event.dragonprobe") then
            return ok_or_fail("world.event.dragonprobe", feature_world_events.dragon_probe(arg_after(line, "world.event.dragonprobe")))
        end
        if matches(line, "world.event.dragonkick") then
            return ok_or_fail("world.event.dragonkick", feature_world_events.dragon_kick(arg_after(line, "world.event.dragonkick")))
        end
        if matches(line, "world.event.dragonmanager") then
            return ok_or_fail("world.event.dragonmanager", feature_world_events.dragon_manager(arg_after(line, "world.event.dragonmanager")))
        end
        if matches(line, "world.event.kick") then
            return ok_or_fail("world.event.kick", feature_world_events.kick(arg_after(line, "world.event.kick")))
        end
        if matches(line, "world.event.startlive") then
            return ok_or_fail("world.event.startlive", feature_world_events.start_live(arg_after(line, "world.event.startlive")))
        end
        if matches(line, "world.event.destroy") then
            return ok_or_fail("world.event.destroy", feature_world_events.destroy_live(arg_after(line, "world.event.destroy")))
        end
        if matches(line, "world.event.startdef") then
            return ok_or_fail("world.event.startdef", feature_world_events.start_definition(arg_after(line, "world.event.startdef")))
        end
        if matches(line, "world.event.startprobe") then
            return ok_or_fail("world.event.startprobe", feature_world_events.start_probe(arg_after(line, "world.event.startprobe")))
        end
        if matches(line, "world.event.spawnprobe") then
            return ok_or_fail("world.event.spawnprobe", feature_world_events.spawn_probe(arg_after(line, "world.event.spawnprobe")))
        end
        if matches(line, "world.event.start_definition") then
            return ok_or_fail("world.event.start_definition", feature_world_events.start_definition(arg_after(line, "world.event.start_definition")))
        end
        if matches(line, "world.event.start") then
            return ok_or_fail("world.event.start", feature_world_events.start(arg_after(line, "world.event.start")))
        end
        if matches(line, "world.event.clientflag") then
            return ok_or_fail("world.event.clientflag", feature_world_events.client_flag(arg_after(line, "world.event.clientflag")))
        end
        return true, false, "unknown world.event.* verb"
    end

    return false, nil, nil
end

return M
