local support = require("router_support")
local lazy_feature = support.lazy_feature

local feature_assets = lazy_feature("feature_assets")
local feature_build_preview = lazy_feature("feature_build_preview")
local feature_buildings = lazy_feature("feature_buildings")
local feature_dungeon = lazy_feature("feature_dungeon")
local feature_dungeon_proc = lazy_feature("feature_dungeon_proc")
local feature_field = lazy_feature("feature_field")
local feature_foliage = lazy_feature("feature_foliage")
local feature_foreach = lazy_feature("feature_foreach")
local feature_introspect = lazy_feature("feature_introspect")
local feature_inventory = lazy_feature("feature_inventory")
local feature_net = lazy_feature("feature_net")
local feature_persistence = lazy_feature("feature_persistence")
local feature_player_spawn = lazy_feature("feature_player_spawn")
local feature_progress = lazy_feature("feature_progress")
local feature_skills = lazy_feature("feature_skills")
local feature_spud = lazy_feature("feature_spud")
local feature_world = lazy_feature("feature_world")
local feature_world_settings = lazy_feature("feature_world_settings")

local M = {}

function M.try_handle(line)
    -- world.* verbs: time-of-day, weather (Round 17).
    if line:sub(1, 6) == "world." then
        local function arg_after(verb)
            local rest = line:sub(#verb + 1)
            return (tostring(rest or ""):gsub("^%s+", ""):gsub("%s+$", ""))
        end

        if line == "world.dungeon.probe" or line:sub(1, #"world.dungeon.probe ") == "world.dungeon.probe " then
            local ok, detail = feature_dungeon.probe(arg_after("world.dungeon.probe"))
            if ok then return true, true, "ok world.dungeon.probe " .. tostring(detail) end
            return true, false, "world.dungeon.probe failed: " .. tostring(detail)
        end
        if line == "world.dungeon.scan" or line:sub(1, #"world.dungeon.scan ") == "world.dungeon.scan " then
            local ok, detail = feature_dungeon.probe(arg_after("world.dungeon.scan"))
            if ok then return true, true, "ok world.dungeon.scan " .. tostring(detail) end
            return true, false, "world.dungeon.scan failed: " .. tostring(detail)
        end
        if line == "world.dungeon.list" or line:sub(1, #"world.dungeon.list ") == "world.dungeon.list " then
            local ok, detail = feature_dungeon.list(arg_after("world.dungeon.list"))
            if ok then return true, true, "ok world.dungeon.list " .. tostring(detail) end
            return true, false, "world.dungeon.list failed: " .. tostring(detail)
        end
        if line == "world.dungeon.goto" or line:sub(1, #"world.dungeon.goto ") == "world.dungeon.goto " then
            local ok, detail = feature_dungeon.goto_dungeon(arg_after("world.dungeon.goto"))
            if ok then return true, true, "ok world.dungeon.goto " .. tostring(detail) end
            return true, false, "world.dungeon.goto failed: " .. tostring(detail)
        end
        if line == "world.dungeon.where" then
            local ok, detail = feature_dungeon.where()
            if ok then return true, true, "ok world.dungeon.where " .. tostring(detail) end
            return true, false, "world.dungeon.where failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.probe" or line:sub(1, #"world.dungeon.proc.probe ") == "world.dungeon.proc.probe " then
            local ok, detail = feature_dungeon_proc.probe(arg_after("world.dungeon.proc.probe"))
            if ok then return true, true, "ok world.dungeon.proc.probe " .. tostring(detail) end
            return true, false, "world.dungeon.proc.probe failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.scan" or line:sub(1, #"world.dungeon.proc.scan ") == "world.dungeon.proc.scan " then
            local ok, detail = feature_dungeon_proc.probe(arg_after("world.dungeon.proc.scan"))
            if ok then return true, true, "ok world.dungeon.proc.scan " .. tostring(detail) end
            return true, false, "world.dungeon.proc.scan failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.models" or line:sub(1, #"world.dungeon.proc.models ") == "world.dungeon.proc.models " then
            local ok, detail = feature_dungeon_proc.models(arg_after("world.dungeon.proc.models"))
            if ok then return true, true, "ok world.dungeon.proc.models " .. tostring(detail) end
            return true, false, "world.dungeon.proc.models failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.status" or line:sub(1, #"world.dungeon.proc.status ") == "world.dungeon.proc.status " then
            local ok, detail = feature_dungeon_proc.status(arg_after("world.dungeon.proc.status"))
            if ok then return true, true, "ok world.dungeon.proc.status " .. tostring(detail) end
            return true, false, "world.dungeon.proc.status failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.spawnmanagers" or line:sub(1, #"world.dungeon.proc.spawnmanagers ") == "world.dungeon.proc.spawnmanagers " then
            local ok, detail = feature_dungeon_proc.spawn_managers(arg_after("world.dungeon.proc.spawnmanagers"))
            if ok then return true, true, "ok world.dungeon.proc.spawnmanagers " .. tostring(detail) end
            return true, false, "world.dungeon.proc.spawnmanagers failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.managers" or line:sub(1, #"world.dungeon.proc.managers ") == "world.dungeon.proc.managers " then
            local ok, detail = feature_dungeon_proc.manager_objects(arg_after("world.dungeon.proc.managers"))
            if ok then return true, true, "ok world.dungeon.proc.managers " .. tostring(detail) end
            return true, false, "world.dungeon.proc.managers failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.state" or line:sub(1, #"world.dungeon.proc.generated.state ") == "world.dungeon.proc.generated.state " then
            local ok, detail = feature_dungeon_proc.generated_state(arg_after("world.dungeon.proc.generated.state"))
            if ok then return true, true, "ok world.dungeon.proc.generated.state " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.state failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.spawners" or line:sub(1, #"world.dungeon.proc.generated.spawners ") == "world.dungeon.proc.generated.spawners " then
            local ok, detail = feature_dungeon_proc.generated_spawners(arg_after("world.dungeon.proc.generated.spawners"))
            if ok then return true, true, "ok world.dungeon.proc.generated.spawners " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.spawners failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.populationplan" or line:sub(1, #"world.dungeon.proc.generated.populationplan ") == "world.dungeon.proc.generated.populationplan " then
            local ok, detail = feature_dungeon_proc.generated_populationplan(arg_after("world.dungeon.proc.generated.populationplan"))
            if ok then return true, true, "ok world.dungeon.proc.generated.populationplan " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.populationplan failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.entrance.probe" or line:sub(1, #"world.dungeon.proc.generated.entrance.probe ") == "world.dungeon.proc.generated.entrance.probe " then
            local ok, detail = feature_dungeon_proc.generated_entrance_probe(arg_after("world.dungeon.proc.generated.entrance.probe"))
            if ok then return true, true, "ok world.dungeon.proc.generated.entrance.probe " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.entrance.probe failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.entranceroom.probe" or line:sub(1, #"world.dungeon.proc.generated.entranceroom.probe ") == "world.dungeon.proc.generated.entranceroom.probe " then
            local ok, detail = feature_dungeon_proc.generated_entrance_probe(arg_after("world.dungeon.proc.generated.entranceroom.probe"))
            if ok then return true, true, "ok world.dungeon.proc.generated.entranceroom.probe " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.entranceroom.probe failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.entrance.patchprobe" or line:sub(1, #"world.dungeon.proc.generated.entrance.patchprobe ") == "world.dungeon.proc.generated.entrance.patchprobe " then
            local ok, detail = feature_dungeon_proc.generated_entrance_patchprobe(arg_after("world.dungeon.proc.generated.entrance.patchprobe"))
            if ok then return true, true, "ok world.dungeon.proc.generated.entrance.patchprobe " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.entrance.patchprobe failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.entranceroom.patchprobe" or line:sub(1, #"world.dungeon.proc.generated.entranceroom.patchprobe ") == "world.dungeon.proc.generated.entranceroom.patchprobe " then
            local ok, detail = feature_dungeon_proc.generated_entrance_patchprobe(arg_after("world.dungeon.proc.generated.entranceroom.patchprobe"))
            if ok then return true, true, "ok world.dungeon.proc.generated.entranceroom.patchprobe " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.entranceroom.patchprobe failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.entrance.patchtest" or line:sub(1, #"world.dungeon.proc.generated.entrance.patchtest ") == "world.dungeon.proc.generated.entrance.patchtest " then
            local ok, detail = feature_dungeon_proc.generated_entrance_patchtest(arg_after("world.dungeon.proc.generated.entrance.patchtest"))
            if ok then return true, true, "ok world.dungeon.proc.generated.entrance.patchtest " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.entrance.patchtest failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.entranceroom.patchtest" or line:sub(1, #"world.dungeon.proc.generated.entranceroom.patchtest ") == "world.dungeon.proc.generated.entranceroom.patchtest " then
            local ok, detail = feature_dungeon_proc.generated_entrance_patchtest(arg_after("world.dungeon.proc.generated.entranceroom.patchtest"))
            if ok then return true, true, "ok world.dungeon.proc.generated.entranceroom.patchtest " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.entranceroom.patchtest failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.bossroom.probe" or line:sub(1, #"world.dungeon.proc.generated.bossroom.probe ") == "world.dungeon.proc.generated.bossroom.probe " then
            local ok, detail = feature_dungeon_proc.generated_bossroom_probe(arg_after("world.dungeon.proc.generated.bossroom.probe"))
            if ok then return true, true, "ok world.dungeon.proc.generated.bossroom.probe " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.bossroom.probe failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.bossroom.snapshot" or line:sub(1, #"world.dungeon.proc.generated.bossroom.snapshot ") == "world.dungeon.proc.generated.bossroom.snapshot " then
            local ok, detail = feature_dungeon_proc.generated_bossroom_snapshot(arg_after("world.dungeon.proc.generated.bossroom.snapshot"))
            if ok then return true, true, "ok world.dungeon.proc.generated.bossroom.snapshot " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.bossroom.snapshot failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.bossroom.death" or line:sub(1, #"world.dungeon.proc.generated.bossroom.death ") == "world.dungeon.proc.generated.bossroom.death " then
            local ok, detail = feature_dungeon_proc.generated_bossroom_death(arg_after("world.dungeon.proc.generated.bossroom.death"))
            if ok then return true, true, "ok world.dungeon.proc.generated.bossroom.death " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.bossroom.death failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.bossroom.unlock" or line:sub(1, #"world.dungeon.proc.generated.bossroom.unlock ") == "world.dungeon.proc.generated.bossroom.unlock " then
            local ok, detail = feature_dungeon_proc.generated_bossroom_unlock(arg_after("world.dungeon.proc.generated.bossroom.unlock"))
            if ok then return true, true, "ok world.dungeon.proc.generated.bossroom.unlock " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.bossroom.unlock failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.bossroom.spawnboss" or line:sub(1, #"world.dungeon.proc.generated.bossroom.spawnboss ") == "world.dungeon.proc.generated.bossroom.spawnboss " then
            local ok, detail = feature_dungeon_proc.generated_bossroom_spawnboss(arg_after("world.dungeon.proc.generated.bossroom.spawnboss"))
            if ok then return true, true, "ok world.dungeon.proc.generated.bossroom.spawnboss " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.bossroom.spawnboss failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.bossroom.bossstatus" or line:sub(1, #"world.dungeon.proc.generated.bossroom.bossstatus ") == "world.dungeon.proc.generated.bossroom.bossstatus " then
            local ok, detail = feature_dungeon_proc.generated_bossroom_bossstatus(arg_after("world.dungeon.proc.generated.bossroom.bossstatus"))
            if ok then return true, true, "ok world.dungeon.proc.generated.bossroom.bossstatus " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.bossroom.bossstatus failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.bossroom.killboss" or line:sub(1, #"world.dungeon.proc.generated.bossroom.killboss ") == "world.dungeon.proc.generated.bossroom.killboss " then
            local ok, detail = feature_dungeon_proc.generated_bossroom_killboss(arg_after("world.dungeon.proc.generated.bossroom.killboss"))
            if ok then return true, true, "ok world.dungeon.proc.generated.bossroom.killboss " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.bossroom.killboss failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.surface" or line:sub(1, #"world.dungeon.proc.generated.surface ") == "world.dungeon.proc.generated.surface " then
            local ok, detail = feature_dungeon_proc.generated_surface(arg_after("world.dungeon.proc.generated.surface"))
            if ok then return true, true, "ok world.dungeon.proc.generated.surface " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.surface failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.wallprobe" or line:sub(1, #"world.dungeon.proc.generated.wallprobe ") == "world.dungeon.proc.generated.wallprobe " then
            local ok, detail = feature_dungeon_proc.generated_wallprobe(arg_after("world.dungeon.proc.generated.wallprobe"))
            if ok then return true, true, "ok world.dungeon.proc.generated.wallprobe " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.wallprobe failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.wallremove" or line:sub(1, #"world.dungeon.proc.generated.wallremove ") == "world.dungeon.proc.generated.wallremove " then
            local ok, detail = feature_dungeon_proc.generated_wallremove(arg_after("world.dungeon.proc.generated.wallremove"))
            if ok then return true, true, "ok world.dungeon.proc.generated.wallremove " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.wallremove failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.openwalls" or line:sub(1, #"world.dungeon.proc.generated.openwalls ") == "world.dungeon.proc.generated.openwalls " then
            local ok, detail = feature_dungeon_proc.generated_openwalls(arg_after("world.dungeon.proc.generated.openwalls"))
            if ok then return true, true, "ok world.dungeon.proc.generated.openwalls " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.openwalls failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated.floorcell" or line:sub(1, #"world.dungeon.proc.generated.floorcell ") == "world.dungeon.proc.generated.floorcell " then
            local ok, detail = feature_dungeon_proc.generated_floorcell(arg_after("world.dungeon.proc.generated.floorcell"))
            if ok then return true, true, "ok world.dungeon.proc.generated.floorcell " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated.floorcell failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generated" or line:sub(1, #"world.dungeon.proc.generated ") == "world.dungeon.proc.generated " then
            local ok, detail = feature_dungeon_proc.generated_objects(arg_after("world.dungeon.proc.generated"))
            if ok then return true, true, "ok world.dungeon.proc.generated " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generated failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generator.fieldone" or line:sub(1, #"world.dungeon.proc.generator.fieldone ") == "world.dungeon.proc.generator.fieldone " then
            local ok, detail = feature_dungeon_proc.generator_fieldone(arg_after("world.dungeon.proc.generator.fieldone"))
            if ok then return true, true, "ok world.dungeon.proc.generator.fieldone " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generator.fieldone failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generator.classrefs" or line:sub(1, #"world.dungeon.proc.generator.classrefs ") == "world.dungeon.proc.generator.classrefs " then
            local ok, detail = feature_dungeon_proc.generator_classrefs(arg_after("world.dungeon.proc.generator.classrefs"))
            if ok then return true, true, "ok world.dungeon.proc.generator.classrefs " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generator.classrefs failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generator.spawnref" or line:sub(1, #"world.dungeon.proc.generator.spawnref ") == "world.dungeon.proc.generator.spawnref " then
            local ok, detail = feature_dungeon_proc.generator_spawnref(arg_after("world.dungeon.proc.generator.spawnref"))
            if ok then return true, true, "ok world.dungeon.proc.generator.spawnref " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generator.spawnref failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generator.spawnlayout" or line:sub(1, #"world.dungeon.proc.generator.spawnlayout ") == "world.dungeon.proc.generator.spawnlayout " then
            local ok, detail = feature_dungeon_proc.generator_spawnlayout(arg_after("world.dungeon.proc.generator.spawnlayout"))
            if ok then return true, true, "ok world.dungeon.proc.generator.spawnlayout " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generator.spawnlayout failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generator.spawnconnected" or line:sub(1, #"world.dungeon.proc.generator.spawnconnected ") == "world.dungeon.proc.generator.spawnconnected " then
            local ok, detail = feature_dungeon_proc.generator_spawnconnected(arg_after("world.dungeon.proc.generator.spawnconnected"))
            if ok then return true, true, "ok world.dungeon.proc.generator.spawnconnected " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generator.spawnconnected failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generator.spawnclear" or line:sub(1, #"world.dungeon.proc.generator.spawnclear ") == "world.dungeon.proc.generator.spawnclear " then
            local ok, detail = feature_dungeon_proc.generator_spawnclear(arg_after("world.dungeon.proc.generator.spawnclear"))
            if ok then return true, true, "ok world.dungeon.proc.generator.spawnclear " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generator.spawnclear failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generator.spawnoptions" or line:sub(1, #"world.dungeon.proc.generator.spawnoptions ") == "world.dungeon.proc.generator.spawnoptions " then
            local ok, detail = feature_dungeon_proc.generator_spawnoptions(arg_after("world.dungeon.proc.generator.spawnoptions"))
            if ok then return true, true, "ok world.dungeon.proc.generator.spawnoptions " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generator.spawnoptions failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generator.autowire" or line:sub(1, #"world.dungeon.proc.generator.autowire ") == "world.dungeon.proc.generator.autowire " then
            local ok, detail = feature_dungeon_proc.generator_autowire(arg_after("world.dungeon.proc.generator.autowire"))
            if ok then return true, true, "ok world.dungeon.proc.generator.autowire " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generator.autowire failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generator.callone" or line:sub(1, #"world.dungeon.proc.generator.callone ") == "world.dungeon.proc.generator.callone " then
            local ok, detail = feature_dungeon_proc.generator_callone(arg_after("world.dungeon.proc.generator.callone"))
            if ok then return true, true, "ok world.dungeon.proc.generator.callone " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generator.callone failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generator.roomoption" or line:sub(1, #"world.dungeon.proc.generator.roomoption ") == "world.dungeon.proc.generator.roomoption " then
            local ok, detail = feature_dungeon_proc.generator_roomoption(arg_after("world.dungeon.proc.generator.roomoption"))
            if ok then return true, true, "ok world.dungeon.proc.generator.roomoption " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generator.roomoption failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.generator.roomoptions.summary" or line:sub(1, #"world.dungeon.proc.generator.roomoptions.summary ") == "world.dungeon.proc.generator.roomoptions.summary " then
            local ok, detail = feature_dungeon_proc.generator_roomoptions_summary(arg_after("world.dungeon.proc.generator.roomoptions.summary"))
            if ok then return true, true, "ok world.dungeon.proc.generator.roomoptions.summary " .. tostring(detail) end
            return true, false, "world.dungeon.proc.generator.roomoptions.summary failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.manager.construct" or line:sub(1, #"world.dungeon.proc.manager.construct ") == "world.dungeon.proc.manager.construct " then
            local ok, detail = feature_dungeon_proc.manager_construct(arg_after("world.dungeon.proc.manager.construct"))
            if ok then return true, true, "ok world.dungeon.proc.manager.construct " .. tostring(detail) end
            return true, false, "world.dungeon.proc.manager.construct failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.manager.constructwire" or line:sub(1, #"world.dungeon.proc.manager.constructwire ") == "world.dungeon.proc.manager.constructwire " then
            local ok, detail = feature_dungeon_proc.manager_constructwire(arg_after("world.dungeon.proc.manager.constructwire"))
            if ok then return true, true, "ok world.dungeon.proc.manager.constructwire " .. tostring(detail) end
            return true, false, "world.dungeon.proc.manager.constructwire failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.manager.constructgraph" or line:sub(1, #"world.dungeon.proc.manager.constructgraph ") == "world.dungeon.proc.manager.constructgraph " then
            local ok, detail = feature_dungeon_proc.manager_constructgraph(arg_after("world.dungeon.proc.manager.constructgraph"))
            if ok then return true, true, "ok world.dungeon.proc.manager.constructgraph " .. tostring(detail) end
            return true, false, "world.dungeon.proc.manager.constructgraph failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.manager.assign" or line:sub(1, #"world.dungeon.proc.manager.assign ") == "world.dungeon.proc.manager.assign " then
            local ok, detail = feature_dungeon_proc.manager_assign(arg_after("world.dungeon.proc.manager.assign"))
            if ok then return true, true, "ok world.dungeon.proc.manager.assign " .. tostring(detail) end
            return true, false, "world.dungeon.proc.manager.assign failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.manager.backref" or line:sub(1, #"world.dungeon.proc.manager.backref ") == "world.dungeon.proc.manager.backref " then
            local ok, detail = feature_dungeon_proc.manager_backref(arg_after("world.dungeon.proc.manager.backref"))
            if ok then return true, true, "ok world.dungeon.proc.manager.backref " .. tostring(detail) end
            return true, false, "world.dungeon.proc.manager.backref failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.manager.current" or line:sub(1, #"world.dungeon.proc.manager.current ") == "world.dungeon.proc.manager.current " then
            local ok, detail = feature_dungeon_proc.manager_current(arg_after("world.dungeon.proc.manager.current"))
            if ok then return true, true, "ok world.dungeon.proc.manager.current " .. tostring(detail) end
            return true, false, "world.dungeon.proc.manager.current failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.spawnmanager.adopt.model" or line:sub(1, #"world.dungeon.proc.spawnmanager.adopt.model ") == "world.dungeon.proc.spawnmanager.adopt.model " then
            local ok, detail = feature_dungeon_proc.spawn_manager_adopt_model(arg_after("world.dungeon.proc.spawnmanager.adopt.model"))
            if ok then return true, true, "ok world.dungeon.proc.spawnmanager.adopt.model " .. tostring(detail) end
            return true, false, "world.dungeon.proc.spawnmanager.adopt.model failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.bridge.model" or line:sub(1, #"world.dungeon.proc.bridge.model ") == "world.dungeon.proc.bridge.model " then
            local ok, detail = feature_dungeon_proc.bridge_model(arg_after("world.dungeon.proc.bridge.model"))
            if ok then return true, true, "ok world.dungeon.proc.bridge.model " .. tostring(detail) end
            return true, false, "world.dungeon.proc.bridge.model failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.spawn.linked" or line:sub(1, #"world.dungeon.proc.spawn.linked ") == "world.dungeon.proc.spawn.linked " then
            local ok, detail = feature_dungeon_proc.spawn_linked(arg_after("world.dungeon.proc.spawn.linked"))
            if ok then return true, true, "ok world.dungeon.proc.spawn.linked " .. tostring(detail) end
            return true, false, "world.dungeon.proc.spawn.linked failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.spawn.bootstrap" or line:sub(1, #"world.dungeon.proc.spawn.bootstrap ") == "world.dungeon.proc.spawn.bootstrap " then
            local ok, detail = feature_dungeon_proc.spawn_bootstrap(arg_after("world.dungeon.proc.spawn.bootstrap"))
            if ok then return true, true, "ok world.dungeon.proc.spawn.bootstrap " .. tostring(detail) end
            return true, false, "world.dungeon.proc.spawn.bootstrap failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.entry.surface" or line:sub(1, #"world.dungeon.proc.entry.surface ") == "world.dungeon.proc.entry.surface " then
            local ok, detail = feature_dungeon_proc.entry_surface(arg_after("world.dungeon.proc.entry.surface"))
            if ok then return true, true, "ok world.dungeon.proc.entry.surface " .. tostring(detail) end
            return true, false, "world.dungeon.proc.entry.surface failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.model.inspect" or line:sub(1, #"world.dungeon.proc.model.inspect ") == "world.dungeon.proc.model.inspect " then
            local ok, detail = feature_dungeon_proc.model_inspect(arg_after("world.dungeon.proc.model.inspect"))
            if ok then return true, true, "ok world.dungeon.proc.model.inspect " .. tostring(detail) end
            return true, false, "world.dungeon.proc.model.inspect failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.model.surface" or line:sub(1, #"world.dungeon.proc.model.surface ") == "world.dungeon.proc.model.surface " then
            local ok, detail = feature_dungeon_proc.model_surface(arg_after("world.dungeon.proc.model.surface"))
            if ok then return true, true, "ok world.dungeon.proc.model.surface " .. tostring(detail) end
            return true, false, "world.dungeon.proc.model.surface failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.model.callcheck" or line:sub(1, #"world.dungeon.proc.model.callcheck ") == "world.dungeon.proc.model.callcheck " then
            local ok, detail = feature_dungeon_proc.model_callcheck(arg_after("world.dungeon.proc.model.callcheck"))
            if ok then return true, true, "ok world.dungeon.proc.model.callcheck " .. tostring(detail) end
            return true, false, "world.dungeon.proc.model.callcheck failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.model.callone" or line:sub(1, #"world.dungeon.proc.model.callone ") == "world.dungeon.proc.model.callone " then
            local ok, detail = feature_dungeon_proc.model_callone(arg_after("world.dungeon.proc.model.callone"))
            if ok then return true, true, "ok world.dungeon.proc.model.callone " .. tostring(detail) end
            return true, false, "world.dungeon.proc.model.callone failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.model.callscan" or line:sub(1, #"world.dungeon.proc.model.callscan ") == "world.dungeon.proc.model.callscan " then
            local ok, detail = feature_dungeon_proc.model_callscan(arg_after("world.dungeon.proc.model.callscan"))
            if ok then return true, true, "ok world.dungeon.proc.model.callscan " .. tostring(detail) end
            return true, false, "world.dungeon.proc.model.callscan failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.model.contextone" or line:sub(1, #"world.dungeon.proc.model.contextone ") == "world.dungeon.proc.model.contextone " then
            local ok, detail = feature_dungeon_proc.model_contextone(arg_after("world.dungeon.proc.model.contextone"))
            if ok then return true, true, "ok world.dungeon.proc.model.contextone " .. tostring(detail) end
            return true, false, "world.dungeon.proc.model.contextone failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.model.fieldone" or line:sub(1, #"world.dungeon.proc.model.fieldone ") == "world.dungeon.proc.model.fieldone " then
            local ok, detail = feature_dungeon_proc.model_fieldone(arg_after("world.dungeon.proc.model.fieldone"))
            if ok then return true, true, "ok world.dungeon.proc.model.fieldone " .. tostring(detail) end
            return true, false, "world.dungeon.proc.model.fieldone failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleports" or line:sub(1, #"world.dungeon.proc.teleports ") == "world.dungeon.proc.teleports " then
            local ok, detail = feature_dungeon_proc.teleports(arg_after("world.dungeon.proc.teleports"))
            if ok then return true, true, "ok world.dungeon.proc.teleports " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleports failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleport.callcheck" or line:sub(1, #"world.dungeon.proc.teleport.callcheck ") == "world.dungeon.proc.teleport.callcheck " then
            local ok, detail = feature_dungeon_proc.teleport_callcheck(arg_after("world.dungeon.proc.teleport.callcheck"))
            if ok then return true, true, "ok world.dungeon.proc.teleport.callcheck " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleport.callcheck failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleport.callone" or line:sub(1, #"world.dungeon.proc.teleport.callone ") == "world.dungeon.proc.teleport.callone " then
            local ok, detail = feature_dungeon_proc.teleport_callone(arg_after("world.dungeon.proc.teleport.callone"))
            if ok then return true, true, "ok world.dungeon.proc.teleport.callone " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleport.callone failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleport.interact" or line:sub(1, #"world.dungeon.proc.teleport.interact ") == "world.dungeon.proc.teleport.interact " then
            local ok, detail = feature_dungeon_proc.teleport_interact(arg_after("world.dungeon.proc.teleport.interact"))
            if ok then return true, true, "ok world.dungeon.proc.teleport.interact " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleport.interact failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleport.configure" or line:sub(1, #"world.dungeon.proc.teleport.configure ") == "world.dungeon.proc.teleport.configure " then
            local ok, detail = feature_dungeon_proc.teleport_configure(arg_after("world.dungeon.proc.teleport.configure"))
            if ok then return true, true, "ok world.dungeon.proc.teleport.configure " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleport.configure failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleport.surface" or line:sub(1, #"world.dungeon.proc.teleport.surface ") == "world.dungeon.proc.teleport.surface " then
            local ok, detail = feature_dungeon_proc.teleport_surface(arg_after("world.dungeon.proc.teleport.surface"))
            if ok then return true, true, "ok world.dungeon.proc.teleport.surface " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleport.surface failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleport.bring" or line:sub(1, #"world.dungeon.proc.teleport.bring ") == "world.dungeon.proc.teleport.bring " then
            local ok, detail = feature_dungeon_proc.teleport_bring(arg_after("world.dungeon.proc.teleport.bring"))
            if ok then return true, true, "ok world.dungeon.proc.teleport.bring " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleport.bring failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleport.interaction.surface" or line:sub(1, #"world.dungeon.proc.teleport.interaction.surface ") == "world.dungeon.proc.teleport.interaction.surface " then
            local ok, detail = feature_dungeon_proc.teleport_interaction_surface(arg_after("world.dungeon.proc.teleport.interaction.surface"))
            if ok then return true, true, "ok world.dungeon.proc.teleport.interaction.surface " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleport.interaction.surface failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleport.interaction.guard" or line:sub(1, #"world.dungeon.proc.teleport.interaction.guard ") == "world.dungeon.proc.teleport.interaction.guard " then
            local ok, detail = feature_dungeon_proc.teleport_interaction_guard(arg_after("world.dungeon.proc.teleport.interaction.guard"))
            if ok then return true, true, "ok world.dungeon.proc.teleport.interaction.guard " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleport.interaction.guard failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleport.interaction.request" or line:sub(1, #"world.dungeon.proc.teleport.interaction.request ") == "world.dungeon.proc.teleport.interaction.request " then
            local ok, detail = feature_dungeon_proc.teleport_interaction_request(arg_after("world.dungeon.proc.teleport.interaction.request"))
            if ok then return true, true, "ok world.dungeon.proc.teleport.interaction.request " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleport.interaction.request failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.postinteract" or line:sub(1, #"world.dungeon.proc.postinteract ") == "world.dungeon.proc.postinteract " then
            local ok, detail = feature_dungeon_proc.post_interact(arg_after("world.dungeon.proc.postinteract"))
            if ok then return true, true, "ok world.dungeon.proc.postinteract " .. tostring(detail) end
            return true, false, "world.dungeon.proc.postinteract failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleport.assign.model" or line:sub(1, #"world.dungeon.proc.teleport.assign.model ") == "world.dungeon.proc.teleport.assign.model " then
            local ok, detail = feature_dungeon_proc.teleport_assign_model(arg_after("world.dungeon.proc.teleport.assign.model"))
            if ok then return true, true, "ok world.dungeon.proc.teleport.assign.model " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleport.assign.model failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleport.notify.model" or line:sub(1, #"world.dungeon.proc.teleport.notify.model ") == "world.dungeon.proc.teleport.notify.model " then
            local ok, detail = feature_dungeon_proc.teleport_notify_model(arg_after("world.dungeon.proc.teleport.notify.model"))
            if ok then return true, true, "ok world.dungeon.proc.teleport.notify.model " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleport.notify.model failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.teleport.callscan" or line:sub(1, #"world.dungeon.proc.teleport.callscan ") == "world.dungeon.proc.teleport.callscan " then
            local ok, detail = feature_dungeon_proc.teleport_callscan(arg_after("world.dungeon.proc.teleport.callscan"))
            if ok then return true, true, "ok world.dungeon.proc.teleport.callscan " .. tostring(detail) end
            return true, false, "world.dungeon.proc.teleport.callscan failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.manual.spawnunit" or line:sub(1, #"world.dungeon.proc.manual.spawnunit ") == "world.dungeon.proc.manual.spawnunit " then
            local ok, detail = feature_dungeon_proc.manual_spawnunit(arg_after("world.dungeon.proc.manual.spawnunit"))
            if ok then return true, true, "ok world.dungeon.proc.manual.spawnunit " .. tostring(detail) end
            return true, false, "world.dungeon.proc.manual.spawnunit failed: " .. tostring(detail)
        end
        if line == "world.dungeon.proc.class" or line:sub(1, #"world.dungeon.proc.class ") == "world.dungeon.proc.class " then
            local ok, detail = feature_dungeon_proc.class_info(arg_after("world.dungeon.proc.class"))
            if ok then return true, true, "ok world.dungeon.proc.class " .. tostring(detail) end
            return true, false, "world.dungeon.proc.class failed: " .. tostring(detail)
        end

        if line == "world.progress.probe" or line:sub(1, 21) == "world.progress.probe " then
            local ok, detail = feature_progress.probe(arg_after("world.progress.probe"))
            if ok then return true, true, "ok world.progress.probe " .. tostring(detail) end
            return true, false, "world.progress.probe failed: " .. tostring(detail)
        end
        if line == "world.progress.has" or line:sub(1, 19) == "world.progress.has " then
            local ok, detail = feature_progress.has(arg_after("world.progress.has"))
            if ok then return true, true, "ok world.progress.has " .. tostring(detail) end
            return true, false, "world.progress.has failed: " .. tostring(detail)
        end
        if line == "world.progress.defeat" or line:sub(1, 22) == "world.progress.defeat " then
            local ok, detail = feature_progress.defeat(arg_after("world.progress.defeat"))
            if ok then return true, true, "ok world.progress.defeat " .. tostring(detail) end
            return true, false, "world.progress.defeat failed: " .. tostring(detail)
        end
        if line == "world.progress.undefeat" or line:sub(1, 24) == "world.progress.undefeat " then
            local ok, detail = feature_progress.undefeat(arg_after("world.progress.undefeat"))
            if ok then return true, true, "ok world.progress.undefeat " .. tostring(detail) end
            return true, false, "world.progress.undefeat failed: " .. tostring(detail)
        end
        if line == "world.progress.value.list" or line:sub(1, #"world.progress.value.list ") == "world.progress.value.list " then
            local ok, detail = feature_progress.value_list(arg_after("world.progress.value.list"))
            if ok then return true, true, "ok world.progress.value.list " .. tostring(detail) end
            return true, false, "world.progress.value.list failed: " .. tostring(detail)
        end
        if line == "world.progress.value.get" or line:sub(1, #"world.progress.value.get ") == "world.progress.value.get " then
            local ok, detail = feature_progress.value_get(arg_after("world.progress.value.get"))
            if ok then return true, true, "ok world.progress.value.get " .. tostring(detail) end
            return true, false, "world.progress.value.get failed: " .. tostring(detail)
        end
        if line == "world.progress.value.set" or line:sub(1, #"world.progress.value.set ") == "world.progress.value.set " then
            local ok, detail = feature_progress.value_set(arg_after("world.progress.value.set"))
            if ok then return true, true, "ok world.progress.value.set " .. tostring(detail) end
            return true, false, "world.progress.value.set failed: " .. tostring(detail)
        end
        if line == "world.progress.hook.probe" or line:sub(1, #"world.progress.hook.probe ") == "world.progress.hook.probe " then
            local ok, detail = feature_progress.hook_probe(arg_after("world.progress.hook.probe"))
            if ok then return true, true, "ok world.progress.hook.probe " .. tostring(detail) end
            return true, false, "world.progress.hook.probe failed: " .. tostring(detail)
        end
        if line == "world.progress.hook.has" or line:sub(1, #"world.progress.hook.has ") == "world.progress.hook.has " then
            local ok, detail = feature_progress.hook_has(arg_after("world.progress.hook.has"))
            if ok then return true, true, "ok world.progress.hook.has " .. tostring(detail) end
            return true, false, "world.progress.hook.has failed: " .. tostring(detail)
        end
        if line == "world.progress.hook.fire" or line:sub(1, #"world.progress.hook.fire ") == "world.progress.hook.fire " then
            local ok, detail = feature_progress.fire_hook(arg_after("world.progress.hook.fire"))
            if ok then return true, true, "ok world.progress.hook.fire " .. tostring(detail) end
            return true, false, "world.progress.hook.fire failed: " .. tostring(detail)
        end
        if line == "world.progress.hook.mark" or line:sub(1, #"world.progress.hook.mark ") == "world.progress.hook.mark " then
            local ok, detail = feature_progress.mark_hook(arg_after("world.progress.hook.mark"))
            if ok then return true, true, "ok world.progress.hook.mark " .. tostring(detail) end
            return true, false, "world.progress.hook.mark failed: " .. tostring(detail)
        end
        if line == "world.progress.hook.trigger" or line:sub(1, #"world.progress.hook.trigger ") == "world.progress.hook.trigger " then
            local ok, detail = feature_progress.trigger_hook(arg_after("world.progress.hook.trigger"))
            if ok then return true, true, "ok world.progress.hook.trigger " .. tostring(detail) end
            return true, false, "world.progress.hook.trigger failed: " .. tostring(detail)
        end
        if line == "world.progress.hook.reset" or line:sub(1, #"world.progress.hook.reset ") == "world.progress.hook.reset " then
            local ok, detail = feature_progress.reset_hook(arg_after("world.progress.hook.reset"))
            if ok then return true, true, "ok world.progress.hook.reset " .. tostring(detail) end
            return true, false, "world.progress.hook.reset failed: " .. tostring(detail)
        end
        if line == "world.resource.probe" or line:sub(1, #"world.resource.probe ") == "world.resource.probe " then
            local ok, detail = feature_persistence.resource_probe(arg_after("world.resource.probe"))
            if ok then return true, true, "ok world.resource.probe " .. tostring(detail) end
            return true, false, "world.resource.probe failed: " .. tostring(detail)
        end
        if line == "world.resource.set" or line:sub(1, #"world.resource.set ") == "world.resource.set " then
            local ok, detail = feature_persistence.resource_set(arg_after("world.resource.set"))
            if ok then return true, true, "ok world.resource.set " .. tostring(detail) end
            return true, false, "world.resource.set failed: " .. tostring(detail)
        end
        if line == "world.resource.pause" or line:sub(1, #"world.resource.pause ") == "world.resource.pause " then
            local ok, detail = feature_persistence.resource_pause(arg_after("world.resource.pause"))
            if ok then return true, true, "ok world.resource.pause " .. tostring(detail) end
            return true, false, "world.resource.pause failed: " .. tostring(detail)
        end
        if line == "world.resource.take" or line:sub(1, #"world.resource.take ") == "world.resource.take " then
            local ok, detail = feature_persistence.resource_take(arg_after("world.resource.take"))
            if ok then return true, true, "ok world.resource.take " .. tostring(detail) end
            return true, false, "world.resource.take failed: " .. tostring(detail)
        end

        -- world.foliage.* : cautious developer/test verbs for interactable
        -- foliage ISM discovery, native conversion, and converted-tree state.
        if line == "world.foliage.scan.near" or line:sub(1, #"world.foliage.scan.near ") == "world.foliage.scan.near " then
            local ok, detail = feature_foliage.scan_near(arg_after("world.foliage.scan.near"))
            if ok then return true, true, "ok world.foliage.scan.near " .. tostring(detail) end
            return true, false, "world.foliage.scan.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.scan.all" or line:sub(1, #"world.foliage.scan.all ") == "world.foliage.scan.all " then
            local ok, detail = feature_foliage.scan_all(arg_after("world.foliage.scan.all"))
            if ok then return true, true, "ok world.foliage.scan.all " .. tostring(detail) end
            return true, false, "world.foliage.scan.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.convert.lookat" or line:sub(1, #"world.foliage.convert.lookat ") == "world.foliage.convert.lookat " then
            local ok, detail = feature_foliage.convert_lookat(arg_after("world.foliage.convert.lookat"))
            if ok then return true, true, "ok world.foliage.convert.lookat " .. tostring(detail) end
            return true, false, "world.foliage.convert.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.convert.near" or line:sub(1, #"world.foliage.convert.near ") == "world.foliage.convert.near " then
            local ok, detail = feature_foliage.convert_near(arg_after("world.foliage.convert.near"))
            if ok then return true, true, "ok world.foliage.convert.near " .. tostring(detail) end
            return true, false, "world.foliage.convert.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.convert.single" or line:sub(1, #"world.foliage.tree.convert.single ") == "world.foliage.tree.convert.single " then
            local ok, detail = feature_foliage.tree_convert_single(arg_after("world.foliage.tree.convert.single"))
            if ok then return true, true, "ok world.foliage.tree.convert.single " .. tostring(detail) end
            return true, false, "world.foliage.tree.convert.single failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.stump.single" or line:sub(1, #"world.foliage.tree.stump.single ") == "world.foliage.tree.stump.single " then
            local ok, detail = feature_foliage.tree_stump_single(arg_after("world.foliage.tree.stump.single"))
            if ok then return true, true, "ok world.foliage.tree.stump.single " .. tostring(detail) end
            return true, false, "world.foliage.tree.stump.single failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.split.single" or line:sub(1, #"world.foliage.tree.split.single ") == "world.foliage.tree.split.single " then
            local ok, detail = feature_foliage.tree_split_single(arg_after("world.foliage.tree.split.single"))
            if ok then return true, true, "ok world.foliage.tree.split.single " .. tostring(detail) end
            return true, false, "world.foliage.tree.split.single failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.destroy.single" or line:sub(1, #"world.foliage.tree.destroy.single ") == "world.foliage.tree.destroy.single " then
            local ok, detail = feature_foliage.tree_destroy_single(arg_after("world.foliage.tree.destroy.single"))
            if ok then return true, true, "ok world.foliage.tree.destroy.single " .. tostring(detail) end
            return true, false, "world.foliage.tree.destroy.single failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.destroy.all" or line:sub(1, #"world.foliage.tree.destroy.all ") == "world.foliage.tree.destroy.all " then
            local ok, detail = feature_foliage.tree_destroy_all(arg_after("world.foliage.tree.destroy.all"))
            if ok then return true, true, "ok world.foliage.tree.destroy.all " .. tostring(detail) end
            return true, false, "world.foliage.tree.destroy.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.destroy.all" or line:sub(1, #"world.foliage.forest.destroy.all ") == "world.foliage.forest.destroy.all " then
            local ok, detail = feature_foliage.tree_destroy_all(arg_after("world.foliage.forest.destroy.all"))
            if ok then return true, true, "ok world.foliage.forest.destroy.all " .. tostring(detail) end
            return true, false, "world.foliage.forest.destroy.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.properdestroy.all" or line:sub(1, #"world.foliage.tree.properdestroy.all ") == "world.foliage.tree.properdestroy.all " then
            local ok, detail = feature_foliage.tree_destroy_all(arg_after("world.foliage.tree.properdestroy.all"))
            if ok then return true, true, "ok world.foliage.tree.properdestroy.all " .. tostring(detail) end
            return true, false, "world.foliage.tree.properdestroy.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.properdestroy.all" or line:sub(1, #"world.foliage.forest.properdestroy.all ") == "world.foliage.forest.properdestroy.all " then
            local ok, detail = feature_foliage.tree_destroy_all(arg_after("world.foliage.forest.properdestroy.all"))
            if ok then return true, true, "ok world.foliage.forest.properdestroy.all " .. tostring(detail) end
            return true, false, "world.foliage.forest.properdestroy.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.delete.all" or line:sub(1, #"world.foliage.tree.delete.all ") == "world.foliage.tree.delete.all " then
            local ok, detail = feature_foliage.tree_destroy_all(arg_after("world.foliage.tree.delete.all"))
            if ok then return true, true, "ok world.foliage.tree.delete.all " .. tostring(detail) end
            return true, false, "world.foliage.tree.delete.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.delete.all" or line:sub(1, #"world.foliage.forest.delete.all ") == "world.foliage.forest.delete.all " then
            local ok, detail = feature_foliage.tree_destroy_all(arg_after("world.foliage.forest.delete.all"))
            if ok then return true, true, "ok world.foliage.forest.delete.all " .. tostring(detail) end
            return true, false, "world.foliage.forest.delete.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.stump.all" or line:sub(1, #"world.foliage.tree.stump.all ") == "world.foliage.tree.stump.all " then
            local ok, detail = feature_foliage.tree_stump_all(arg_after("world.foliage.tree.stump.all"))
            if ok then return true, true, "ok world.foliage.tree.stump.all " .. tostring(detail) end
            return true, false, "world.foliage.tree.stump.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.stump.all" or line:sub(1, #"world.foliage.forest.stump.all ") == "world.foliage.forest.stump.all " then
            local ok, detail = feature_foliage.tree_stump_all(arg_after("world.foliage.forest.stump.all"))
            if ok then return true, true, "ok world.foliage.forest.stump.all " .. tostring(detail) end
            return true, false, "world.foliage.forest.stump.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.split.all" or line:sub(1, #"world.foliage.tree.split.all ") == "world.foliage.tree.split.all " then
            local ok, detail = feature_foliage.tree_split_all(arg_after("world.foliage.tree.split.all"))
            if ok then return true, true, "ok world.foliage.tree.split.all " .. tostring(detail) end
            return true, false, "world.foliage.tree.split.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.split.all" or line:sub(1, #"world.foliage.forest.split.all ") == "world.foliage.forest.split.all " then
            local ok, detail = feature_foliage.tree_split_all(arg_after("world.foliage.forest.split.all"))
            if ok then return true, true, "ok world.foliage.forest.split.all " .. tostring(detail) end
            return true, false, "world.foliage.forest.split.all failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.destroy.lookat" or line:sub(1, #"world.foliage.tree.destroy.lookat ") == "world.foliage.tree.destroy.lookat " then
            local ok, detail = feature_foliage.tree_destroy_lookat(arg_after("world.foliage.tree.destroy.lookat"))
            if ok then return true, true, "ok world.foliage.tree.destroy.lookat " .. tostring(detail) end
            return true, false, "world.foliage.tree.destroy.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.destroy.lookat" or line:sub(1, #"world.foliage.forest.destroy.lookat ") == "world.foliage.forest.destroy.lookat " then
            local ok, detail = feature_foliage.tree_destroy_lookat(arg_after("world.foliage.forest.destroy.lookat"))
            if ok then return true, true, "ok world.foliage.forest.destroy.lookat " .. tostring(detail) end
            return true, false, "world.foliage.forest.destroy.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.properdestroy.lookat" or line:sub(1, #"world.foliage.tree.properdestroy.lookat ") == "world.foliage.tree.properdestroy.lookat " then
            local ok, detail = feature_foliage.tree_destroy_lookat(arg_after("world.foliage.tree.properdestroy.lookat"))
            if ok then return true, true, "ok world.foliage.tree.properdestroy.lookat " .. tostring(detail) end
            return true, false, "world.foliage.tree.properdestroy.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.properdestroy.lookat" or line:sub(1, #"world.foliage.forest.properdestroy.lookat ") == "world.foliage.forest.properdestroy.lookat " then
            local ok, detail = feature_foliage.tree_destroy_lookat(arg_after("world.foliage.forest.properdestroy.lookat"))
            if ok then return true, true, "ok world.foliage.forest.properdestroy.lookat " .. tostring(detail) end
            return true, false, "world.foliage.forest.properdestroy.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.delete.lookat" or line:sub(1, #"world.foliage.tree.delete.lookat ") == "world.foliage.tree.delete.lookat " then
            local ok, detail = feature_foliage.tree_destroy_lookat(arg_after("world.foliage.tree.delete.lookat"))
            if ok then return true, true, "ok world.foliage.tree.delete.lookat " .. tostring(detail) end
            return true, false, "world.foliage.tree.delete.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.delete.lookat" or line:sub(1, #"world.foliage.forest.delete.lookat ") == "world.foliage.forest.delete.lookat " then
            local ok, detail = feature_foliage.tree_destroy_lookat(arg_after("world.foliage.forest.delete.lookat"))
            if ok then return true, true, "ok world.foliage.forest.delete.lookat " .. tostring(detail) end
            return true, false, "world.foliage.forest.delete.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.stump.lookat" or line:sub(1, #"world.foliage.tree.stump.lookat ") == "world.foliage.tree.stump.lookat " then
            local ok, detail = feature_foliage.tree_stump_lookat(arg_after("world.foliage.tree.stump.lookat"))
            if ok then return true, true, "ok world.foliage.tree.stump.lookat " .. tostring(detail) end
            return true, false, "world.foliage.tree.stump.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.stump.lookat" or line:sub(1, #"world.foliage.forest.stump.lookat ") == "world.foliage.forest.stump.lookat " then
            local ok, detail = feature_foliage.tree_stump_lookat(arg_after("world.foliage.forest.stump.lookat"))
            if ok then return true, true, "ok world.foliage.forest.stump.lookat " .. tostring(detail) end
            return true, false, "world.foliage.forest.stump.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.stump.near" or line:sub(1, #"world.foliage.tree.stump.near ") == "world.foliage.tree.stump.near " then
            local ok, detail = feature_foliage.tree_stump_near(arg_after("world.foliage.tree.stump.near"))
            if ok then return true, true, "ok world.foliage.tree.stump.near " .. tostring(detail) end
            return true, false, "world.foliage.tree.stump.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.split.lookat" or line:sub(1, #"world.foliage.tree.split.lookat ") == "world.foliage.tree.split.lookat " then
            local ok, detail = feature_foliage.tree_split_lookat(arg_after("world.foliage.tree.split.lookat"))
            if ok then return true, true, "ok world.foliage.tree.split.lookat " .. tostring(detail) end
            return true, false, "world.foliage.tree.split.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.split.lookat" or line:sub(1, #"world.foliage.forest.split.lookat ") == "world.foliage.forest.split.lookat " then
            local ok, detail = feature_foliage.tree_split_lookat(arg_after("world.foliage.forest.split.lookat"))
            if ok then return true, true, "ok world.foliage.forest.split.lookat " .. tostring(detail) end
            return true, false, "world.foliage.forest.split.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.split.near" or line:sub(1, #"world.foliage.tree.split.near ") == "world.foliage.tree.split.near " then
            local ok, detail = feature_foliage.tree_split_near(arg_after("world.foliage.tree.split.near"))
            if ok then return true, true, "ok world.foliage.tree.split.near " .. tostring(detail) end
            return true, false, "world.foliage.tree.split.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.redundant.lookat" or line:sub(1, #"world.foliage.tree.redundant.lookat ") == "world.foliage.tree.redundant.lookat " then
            local ok, detail = feature_foliage.tree_redundant_lookat(arg_after("world.foliage.tree.redundant.lookat"))
            if ok then return true, true, "ok world.foliage.tree.redundant.lookat " .. tostring(detail) end
            return true, false, "world.foliage.tree.redundant.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.forest.redundant.lookat" or line:sub(1, #"world.foliage.forest.redundant.lookat ") == "world.foliage.forest.redundant.lookat " then
            local ok, detail = feature_foliage.tree_redundant_lookat(arg_after("world.foliage.forest.redundant.lookat"))
            if ok then return true, true, "ok world.foliage.forest.redundant.lookat " .. tostring(detail) end
            return true, false, "world.foliage.forest.redundant.lookat failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.redundant.near" or line:sub(1, #"world.foliage.tree.redundant.near ") == "world.foliage.tree.redundant.near " then
            local ok, detail = feature_foliage.tree_redundant_near(arg_after("world.foliage.tree.redundant.near"))
            if ok then return true, true, "ok world.foliage.tree.redundant.near " .. tostring(detail) end
            return true, false, "world.foliage.tree.redundant.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.destroy.near" or line:sub(1, #"world.foliage.tree.destroy.near ") == "world.foliage.tree.destroy.near " then
            local ok, detail = feature_foliage.tree_destroy_near(arg_after("world.foliage.tree.destroy.near"))
            if ok then return true, true, "ok world.foliage.tree.destroy.near " .. tostring(detail) end
            return true, false, "world.foliage.tree.destroy.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.properdestroy.near" or line:sub(1, #"world.foliage.tree.properdestroy.near ") == "world.foliage.tree.properdestroy.near " then
            local ok, detail = feature_foliage.tree_destroy_near(arg_after("world.foliage.tree.properdestroy.near"))
            if ok then return true, true, "ok world.foliage.tree.properdestroy.near " .. tostring(detail) end
            return true, false, "world.foliage.tree.properdestroy.near failed: " .. tostring(detail)
        end
        if line == "world.foliage.tree.delete.near" or line:sub(1, #"world.foliage.tree.delete.near ") == "world.foliage.tree.delete.near " then
            local ok, detail = feature_foliage.tree_destroy_near(arg_after("world.foliage.tree.delete.near"))
            if ok then return true, true, "ok world.foliage.tree.delete.near " .. tostring(detail) end
            return true, false, "world.foliage.tree.delete.near failed: " .. tostring(detail)
        end
        if line == "world.chest.probe" or line:sub(1, #"world.chest.probe ") == "world.chest.probe " then
            local ok, detail = feature_persistence.chest_probe(arg_after("world.chest.probe"))
            if ok then return true, true, "ok world.chest.probe " .. tostring(detail) end
            return true, false, "world.chest.probe failed: " .. tostring(detail)
        end
        if line == "world.chest.state" or line:sub(1, #"world.chest.state ") == "world.chest.state " then
            local ok, detail = feature_persistence.chest_state(arg_after("world.chest.state"))
            if ok then return true, true, "ok world.chest.state " .. tostring(detail) end
            return true, false, "world.chest.state failed: " .. tostring(detail)
        end
        if line == "world.chest.respawn_disabled" or line:sub(1, #"world.chest.respawn_disabled ") == "world.chest.respawn_disabled " then
            local ok, detail = feature_persistence.chest_respawn_disabled(arg_after("world.chest.respawn_disabled"))
            if ok then return true, true, "ok world.chest.respawn_disabled " .. tostring(detail) end
            return true, false, "world.chest.respawn_disabled failed: " .. tostring(detail)
        end
        if line == "world.spud.persist" or line:sub(1, 19) == "world.spud.persist " then
            local ok, detail = feature_spud.persist(arg_after("world.spud.persist"))
            if ok then return true, true, "ok world.spud.persist " .. tostring(detail) end
            return true, false, "world.spud.persist failed: " .. tostring(detail)
        end
        if line == "world.spud.unpersist" or line:sub(1, 21) == "world.spud.unpersist " then
            local ok, detail = feature_spud.unpersist(arg_after("world.spud.unpersist"))
            if ok then return true, true, "ok world.spud.unpersist " .. tostring(detail) end
            return true, false, "world.spud.unpersist failed: " .. tostring(detail)
        end

        -- Round 54: bulk per-class operations -- the "loop" primitive
        -- the single-target Mod model can't express. Powers things like
        -- a one-shot "Free Build" mod entry that zeroes Requirements
        -- on every BuildingPieceData live in the world.
        --   world.findall <ClassName>
        --   world.foreach <ClassName> set <Field> <Value>
        --   world.foreach <ClassName> call <Method> [args...]   ($it = current instance)
        --   world.foreach <ClassName> clear <Field>
        if line:sub(1, 13) == "world.findall" then
            local val = arg_after("world.findall")
            if val == "" then return true, false, "usage: world.findall <ClassName>" end
            local ok, detail = feature_foreach.findall(val)
            if ok then return true, true, "ok world.findall " .. tostring(detail) end
            return true, false, "world.findall failed: " .. tostring(detail)
        end

        -- world.cdo.dump.all
        --   Bulk variant : dumps every UDeveloperSettings CDO into
        --   ipc/cdo/<ClassName>.json, one file per class. Powers the
        --   "snapshot every settings class at once" workflow so the C#
        --   side can iterate the directory rather than re-dispatching
        --   per class. Must be checked BEFORE the bare `world.cdo.dump`
        --   prefix below since they share the first 14 characters.
        if line == "world.cdo.dump.all" or line:sub(1, 19) == "world.cdo.dump.all " then
            local ok, detail = feature_introspect.dump_cdo_all()
            if ok then return true, true, "ok world.cdo.dump.all " .. tostring(detail) end
            return true, false, "world.cdo.dump.all failed: " .. tostring(detail)
        end

        -- world.cdo.dump.deep <ClassName> [maxDepth=2]
        --   Recursive dump : dumps the class, then for every soft path
        --   / class ref / object path in its fields, follows and dumps
        --   that too. Output goes to ipc/cdo/<Class>.json (per-class
        --   files, NOT actor_info.json) and ipc/asset/<sanitised>.json.
        --   A walk audit lands at ipc/cdo_deep_log.txt. Depth-limited
        --   (default 2, hard cap 5) and cycle-protected. MUST be matched
        --   before the bare `world.cdo.dump` prefix.
        if line == "world.cdo.dump.deep" or line:sub(1, 20) == "world.cdo.dump.deep " then
            local val = arg_after("world.cdo.dump.deep")
            if val == "" then return true, false, "usage: world.cdo.dump.deep <ClassName> [maxDepth=2]" end
            local ok, detail = feature_introspect.dump_cdo_deep(val)
            if ok then return true, true, "ok world.cdo.dump.deep " .. tostring(detail) end
            return true, false, "world.cdo.dump.deep failed: " .. tostring(detail)
        end

        -- world.cdo.dump <ClassName | /Script/Module.Class>
        --   Reuses the actor-info reflection pipeline against the named
        --   class's CDO and writes ipc/actor_info.json so the WPF Inspect
        --   tab can browse settings classes (BuildingSettings, ItemSettings,
        --   etc.) the same way it browses live actors. Path form is
        --   preferred -- it mirrors the .ini section header
        --   `[/Script/Module.Class]`. Short-name form falls back to
        --   FindFirstOf, which works for any class with at least one
        --   live instance (true for most UDeveloperSettings, where the
        --   CDO _is_ the runtime instance).
        if line:sub(1, 14) == "world.cdo.dump" then
            local val = arg_after("world.cdo.dump")
            if val == "" then return true, false, "usage: world.cdo.dump <ClassName|/Script/Module.Class>" end
            local ok, detail = feature_introspect.dump_cdo(val)
            if ok then return true, true, "ok world.cdo.dump " .. tostring(detail) end
            return true, false, "world.cdo.dump failed: " .. tostring(detail)
        end

        -- world.asset.dump </Game/Path/To/Asset.Asset | SoftPath>
        --   Force-loads a soft asset reference and dumps the resolved
        --   UObject the same way world.cdo.dump dumps a class default.
        --   Used to crack open soft refs harvested from CDO dumps
        --   (GearPresets, BuildPieceCatalogueRef, etc.) without
        --   exposing the live engine to in-place container/struct
        --   walks (which have crashed in the past -- see comments
        --   in feature_introspect.try_read_field).
        --   Output : ipc/asset/<sanitized>.json.
        if line:sub(1, 16) == "world.asset.dump" then
            local val = arg_after("world.asset.dump")
            if val == "" then return true, false, "usage: world.asset.dump </Game/...|SoftPath>" end
            local ok, detail = feature_introspect.dump_asset(val)
            if ok then return true, true, "ok world.asset.dump " .. tostring(detail) end
            return true, false, "world.asset.dump failed: " .. tostring(detail)
        end

        -- world.func.call <Target> <Method> [args...]
        --   Resolve a UObject and invoke a UFunction. Target accepts
        --   short-name, full path, or shortcuts ("cheatmgr", "player").
        --   Args are space-separated and lightly coerced (true/false,
        --   numbers, otherwise string). Pcall-wrapped end-to-end so
        --   typos don't crash the game thread.
        if line:sub(1, 15) == "world.func.call" then
            local val = arg_after("world.func.call")
            if val == "" then return true, false, "usage: world.func.call <Target> <Method> [args...]" end
            local ok, detail = feature_introspect.func_call(val)
            if ok then return true, true, "ok world.func.call " .. tostring(detail) end
            return true, false, "world.func.call failed: " .. tostring(detail)
        end

        -- world.cheat.exec <command [args...]>
        --   Send the entire payload as one console command through the
        --   local PlayerController. Goes through UE's exec dispatcher
        --   so cheat-manager methods bind to the LIVE local pawn /
        --   cheat manager, not whichever instance FindFirstOf returned.
        --   Use this when world.func.call reports success but nothing
        --   happens in-game.
        if line == "world.cheat.exec" or line:sub(1, 17) == "world.cheat.exec " then
            local val = arg_after("world.cheat.exec")
            if val == "" then return true, false, "usage: world.cheat.exec <command [args...]>" end
            local ok, detail = feature_introspect.cheat_exec(val)
            if ok then return true, true, "ok world.cheat.exec " .. tostring(detail) end
            return true, false, "world.cheat.exec failed: " .. tostring(detail)
        end

        -- world.diff.cdo.snap <ClassName>
        -- world.diff.cdo.compare <ClassName>
        --   Snapshot/compare a class's CDO field values to discover
        --   what a cheat or runtime event mutated. The .compare verb
        --   writes ipc/cdo_diff_<Class>.json. Snapshots live in
        --   Lua-side memory only -- they're not persisted across
        --   game restarts. Order matters : snap first, mutate, compare.
        --
        --   Longer prefix MUST be checked first (snap/compare share
        --   the `world.diff.cdo` stem).
        if line == "world.diff.cdo.snap" or line:sub(1, 20) == "world.diff.cdo.snap " then
            local val = arg_after("world.diff.cdo.snap")
            if val == "" then return true, false, "usage: world.diff.cdo.snap <ClassName>" end
            local ok, detail = feature_introspect.diff_cdo_snap(val)
            if ok then return true, true, "ok world.diff.cdo.snap " .. tostring(detail) end
            return true, false, "world.diff.cdo.snap failed: " .. tostring(detail)
        end
        if line == "world.diff.cdo.compare" or line:sub(1, 23) == "world.diff.cdo.compare " then
            local val = arg_after("world.diff.cdo.compare")
            if val == "" then return true, false, "usage: world.diff.cdo.compare <ClassName>" end
            local ok, detail = feature_introspect.diff_cdo_compare(val)
            if ok then return true, true, "ok world.diff.cdo.compare " .. tostring(detail) end
            return true, false, "world.diff.cdo.compare failed: " .. tostring(detail)
        end

        -- world.diff.actor.snap <ActorName | player | cheatmgr | /Path>
        -- world.diff.actor.compare <same target>
        --   Snapshot/compare a LIVE actor instance (not its CDO).
        --   This is what cheats actually mutate -- domFullHeal touches
        --   the live ASC / pawn, not the class default. Walks the
        --   full class chain so inherited fields are caught too.
        --   Output : ipc/actor_diff_<name>.json.
        if line == "world.diff.actor.snap" or line:sub(1, 22) == "world.diff.actor.snap " then
            local val = arg_after("world.diff.actor.snap")
            if val == "" then return true, false, "usage: world.diff.actor.snap <ActorName|player|cheatmgr|/Path>" end
            local ok, detail = feature_introspect.diff_actor_snap(val)
            if ok then return true, true, "ok world.diff.actor.snap " .. tostring(detail) end
            return true, false, "world.diff.actor.snap failed: " .. tostring(detail)
        end
        if line == "world.diff.actor.compare" or line:sub(1, 25) == "world.diff.actor.compare " then
            local val = arg_after("world.diff.actor.compare")
            if val == "" then return true, false, "usage: world.diff.actor.compare <same target as snap>" end
            local ok, detail = feature_introspect.diff_actor_compare(val)
            if ok then return true, true, "ok world.diff.actor.compare " .. tostring(detail) end
            return true, false, "world.diff.actor.compare failed: " .. tostring(detail)
        end

        if line:sub(1, 13) == "world.foreach" then
            local val = arg_after("world.foreach")
            if val == "" then return true, false, "usage: world.foreach <ClassName> <set|call|clear> <args...>" end
            local ok, detail = feature_foreach.foreach(val)
            if ok then return true, true, "ok world.foreach " .. tostring(detail) end
            return true, false, "world.foreach failed: " .. tostring(detail)
        end

        -- world.buildings.* : player-placed building inspection (read-only v1).
        --   world.buildings.count            -- cross-check totals to log
        --   world.buildings.nearest          -- dump the closest piece to player
        --   world.buildings.describe [N]     -- dump N closest pieces (default 3)
        -- Output is logged to stdout ; the router-returned detail is a one-liner.
        if line == "world.buildings.count" then
            local ok, detail = feature_buildings.count()
            if ok then return true, true, "ok world.buildings.count " .. tostring(detail) end
            return true, false, "world.buildings.count failed: " .. tostring(detail)
        end
        -- world.buildings.lookat_anchor
        --   Returns the BuildingPieceDataIndex of the actor under the
        --   reticle without entering placing mode. Used by the WPF
        --   Capture Build "Specify a Build Anchor" flow.
        if line == "world.buildings.lookat_anchor" then
            local ok, detail = feature_build_preview.lookat_anchor()
            if ok then return true, true, "ok world.buildings.lookat_anchor " .. tostring(detail) end
            return true, false, "world.buildings.lookat_anchor failed: " .. tostring(detail)
        end
        if line == "world.buildings.nearest" then
            local ok, detail = feature_buildings.nearest()
            if ok then return true, true, "ok world.buildings.nearest " .. tostring(detail) end
            return true, false, "world.buildings.nearest failed: " .. tostring(detail)
        end
        if line:sub(1, 24) == "world.buildings.describe" then
            local ok, detail = feature_buildings.describe(arg_after("world.buildings.describe"))
            if ok then return true, true, "ok world.buildings.describe " .. tostring(detail) end
            return true, false, "world.buildings.describe failed: " .. tostring(detail)
        end
        -- world.buildings.export <name>
        --   writes ipc/buildings_<name>.json with the registered pieces.
        if line:sub(1, 22) == "world.buildings.export" then
            local ok, detail = feature_buildings.export(arg_after("world.buildings.export"))
            if ok then return true, true, "ok world.buildings.export " .. tostring(detail) end
            return true, false, "world.buildings.export failed: " .. tostring(detail)
        end
        -- world.buildings.import <name>
        --   reads ipc/buildings_<name>.json and replays each piece via
        --   UBuildModeComponent.Server_SpawnBuilding. Assumes the
        --   free-build mod (world.foreach BuildingPieceData clear
        --   Requirements) has zeroed costs ; otherwise the spawn RPC
        --   will reject for missing materials.
        if line == "world.buildings.validate" or line:sub(1, 25) == "world.buildings.validate " then
            local ok, detail = feature_buildings.import(arg_after("world.buildings.validate"), true)
            return true, ok, (ok and "ok " or "") .. "world.buildings.validate " .. tostring(detail)
        end
        if line:sub(1, 22) == "world.buildings.import" then
            local ok, detail = feature_buildings.import(arg_after("world.buildings.import"))
            if ok then return true, true, "ok world.buildings.import " .. tostring(detail) end
            return true, false, "world.buildings.import failed: " .. tostring(detail)
        end
        if line == "world.buildings.delivery.status" then
            local ok, detail = feature_buildings.delivery_status()
            if ok then return true, true, "ok world.buildings.delivery.status " .. tostring(detail) end
            return true, false, "world.buildings.delivery.status failed: " .. tostring(detail)
        end
        -- world.buildings.list : enumerate available exports.
        if line == "world.buildings.list" then
            local ok, detail = feature_buildings.list()
            if ok then return true, true, "ok world.buildings.list " .. tostring(detail) end
            return true, false, "world.buildings.list failed: " .. tostring(detail)
        end
        -- world.buildings.catalog.disk [name]
        --   AssetRegistry sweep of BuildingPieceData on disk
        --   (loaded or not). Writes ipc/building/_catalog_disk.json.
        --   Must precede the world.buildings.catalog check below
        --   because the prefix-23 substring check would otherwise
        --   swallow ".disk" as the name argument.
        if line:sub(1, 28) == "world.buildings.catalog.disk" then
            local ok, detail = feature_buildings.catalog_disk(arg_after("world.buildings.catalog.disk"))
            if ok then return true, true, "ok world.buildings.catalog.disk " .. tostring(detail) end
            return true, false, "world.buildings.catalog.disk failed: " .. tostring(detail)
        end
        -- world.buildings.catalog [name]
        --   FindAllOf BuildingPieceData -> dump short_name +
        --   piece_data_index + piece_data_name to
        --   ipc/building/_catalog[_<name>].json. Use to resolve
        --   indices for hand-crafted Server_SpawnBuilding calls or
        --   to seed a delivery JSON without first capturing live
        --   pieces in a world.
        if line:sub(1, 23) == "world.buildings.catalog" then
            local ok, detail = feature_buildings.catalog(arg_after("world.buildings.catalog"))
            if ok then return true, true, "ok world.buildings.catalog " .. tostring(detail) end
            return true, false, "world.buildings.catalog failed: " .. tostring(detail)
        end

        -- world.buildings.stability <on|off>
        --   Toggle the building stability simulation. "off" stops the
        --   stability tick + pins every existing piece to max so
        --   replayed structures don't collapse. "on" restores normal
        --   behavior. See feature_buildings.set_stability for the
        --   three independent levers it pulls.
        if line:sub(1, 25) == "world.buildings.stability" then
            local ok, detail = feature_buildings.set_stability(arg_after("world.buildings.stability"))
            if ok then return true, true, "ok world.buildings.stability " .. tostring(detail) end
            return true, false, "world.buildings.stability failed: " .. tostring(detail)
        end

        -- world.buildings.protect <on|off>
        --   Background watcher (16ms) that pins bIsGhosted=false +
        --   StabilityValue=1.0 + bIsPreview=false on every live
        --   BaseBuildingActor so the engine's post-spawn validity /
        --   ghost-decay path doesn't auto-destroy force_place'd or
        --   Server_SpawnBuilding'd pieces. Enable BEFORE you fire
        --   build.preview.commit / force_place ; disable after the
        --   structure settles to save CPU.
        if line:sub(1, 23) == "world.buildings.protect" then
            local ok, detail = feature_buildings.set_protect(arg_after("world.buildings.protect"))
            if ok then return true, true, "ok world.buildings.protect " .. tostring(detail) end
            return true, false, "world.buildings.protect failed: " .. tostring(detail)
        end

        -- world.buildings.delete_ghosts
        --   K2_DestroyActor every live BaseBuildingActor whose bIsGhosted
        --   is true. Pairs with the WPF "Ghost Building Mode" workflow.
        if line == "world.buildings.delete_ghosts" then
            local ok, detail = feature_buildings.delete_ghosts()
            if ok then return true, true, "ok world.buildings.delete_ghosts " .. tostring(detail) end
            return true, false, "world.buildings.delete_ghosts failed: " .. tostring(detail)
        end

        -- world.buildings.commit_ghosts
        --   Flip bIsGhosted=false (and pin StabilityValue=1.0) on every
        --   live BaseBuildingActor whose bIsGhosted is true. Converts
        --   "tentative" placements into real pieces.
        if line == "world.buildings.commit_ghosts" then
            local ok, detail = feature_buildings.commit_ghosts()
            if ok then return true, true, "ok world.buildings.commit_ghosts " .. tostring(detail) end
            return true, false, "world.buildings.commit_ghosts failed: " .. tostring(detail)
        end

        -- world.buildings.requirements <save|clear|restore|status>
        --   Manage Requirements TArray on every UBuildingPieceData.
        --   Use save+clear before a Deliver Build that should spawn for
        --   free, then restore once you're done so manual ghost-mode
        --   building works again. status reports the current state.
        if line:sub(1, 28) == "world.buildings.requirements" then
            local ok, detail = feature_buildings.set_requirements(arg_after("world.buildings.requirements"))
            if ok then return true, true, "ok world.buildings.requirements " .. tostring(detail) end
            return true, false, "world.buildings.requirements failed: " .. tostring(detail)
        end

        -- world.buildings.rotation.step [deg]
        --   Precision control for the in-game build-preview rotation
        --   snap (the wheel-tick angle in oculus / build mode). Writes
        --   UBuildingSettings.ModifyRotationStepDeg on the CDO. Default
        --   is 15 ; pass 1 for full per-degree control. Read with no
        --   arg. Range clamps to 1..180 (0 freezes, >180 wraps).
        if line:sub(1, 29) == "world.buildings.rotation.step" then
            local ok, detail = feature_buildings.set_rotation_step(arg_after("world.buildings.rotation.step"))
            if ok then return true, true, "ok world.buildings.rotation.step " .. tostring(detail) end
            return true, false, "world.buildings.rotation.step failed: " .. tostring(detail)
        end

        -- world.settings.unlock_all
        --   Flip every loaded UDifficultySettingData so PlayerAdjustable
        --   = AllModes (3) and bCanBeChangedAfterWorldCreation = true.
        --   Result : the Main Menu "Edit Settings" panel exposes every
        --   setting on every world (Standard / Hardcore / Custom /
        --   Creative), and post-creation edits are no longer blocked.
        --   Idempotent ; first call snapshots originals so .restore can
        --   undo it.
        if line == "world.settings.unlock_all" then
            local ok, detail = feature_world_settings.apply()
            if ok then return true, true, "ok world.settings.unlock_all " .. tostring(detail) end
            return true, false, "world.settings.unlock_all failed: " .. tostring(detail)
        end

        -- world.settings.restore
        --   Walk the snapshot taken by .unlock_all and write the
        --   original PlayerAdjustable / bCanBeChangedAfterWorldCreation
        --   values back. No-op if no snapshot exists.
        if line == "world.settings.restore" then
            local ok, detail = feature_world_settings.restore()
            if ok then return true, true, "ok world.settings.restore " .. tostring(detail) end
            return true, false, "world.settings.restore failed: " .. tostring(detail)
        end

        -- world.settings.list
        --   Dump every loaded UDifficultySettingData with its current
        --   PlayerAdjustable + bCanBeChangedAfterWorldCreation values.
        --   Useful for verifying .unlock_all actually took.
        if line == "world.settings.list" then
            local ok, detail = feature_world_settings.list()
            if ok then return true, true, "ok world.settings.list " .. tostring(detail) end
            return true, false, "world.settings.list failed: " .. tostring(detail)
        end

        -- world.settings.scan
        --   Enumerate every loaded UDifficultySettingData, write
        --   ipc/world_settings.json (id, name, tag, slider min/max,
        --   PlayerAdjustable, current value, etc.), and stash an
        --   id->asset registry the .set verb can resolve. The World
        --   Service tab calls this on Scan.
        if line == "world.settings.scan" then
            local ok, detail = feature_world_settings.scan()
            if ok then return true, true, "ok world.settings.scan " .. tostring(detail) end
            return true, false, "world.settings.scan failed: " .. tostring(detail)
        end

        -- world.settings.set_range <id> <min> <max>
        --   Overwrite the FrontEndSliderData.MinValue/MaxValue on the
        --   target UDifficultySettingData so the in-game World Settings
        --   slider can travel outside its developer-defined bounds.
        --   `id` is the integer the last scan assigned.
        if line:sub(1, 25) == "world.settings.set_range " then
            local ok, detail = feature_world_settings.set_range(line:sub(26))
            if ok then return true, true, "ok world.settings.set_range " .. tostring(detail) end
            return true, false, "world.settings.set_range failed: " .. tostring(detail)
        end


        -- world.items.give <ITEM_AssetName> [count]
        --   Resolves the item DataAsset by short name (with an
        --   AssetRegistry sweep cache + LoadAsset fallback) and calls
        --   pc.BP_Components_PersonalInventory:AddItemByData. Backs the
        --   Item Service "Spawn" button.
        if line:sub(1, 17) == "world.items.give " then
            local ok, detail = feature_inventory.give(line:sub(18))
            if ok then return true, true, "ok world.items.give " .. tostring(detail) end
            return true, false, "world.items.give failed: " .. tostring(detail)
        end
        -- world.items.runtime.snapshot [lastspawned|<actor_name>]
        --   Diagnostics for BP_RuntimeSpawnedWorldItem persistence/physics.
        if line == "world.items.runtime.snapshot" or line:sub(1, #"world.items.runtime.snapshot ") == "world.items.runtime.snapshot " then
            local ok, detail = feature_inventory.runtime_snapshot(arg_after("world.items.runtime.snapshot"))
            if ok then return true, true, "ok world.items.runtime.snapshot " .. tostring(detail) end
            return true, false, "world.items.runtime.snapshot failed: " .. tostring(detail)
        end
        if line == "world.items.snapshot" or line:sub(1, #"world.items.snapshot ") == "world.items.snapshot " then
            local ok, detail = feature_inventory.runtime_snapshot(arg_after("world.items.snapshot"))
            if ok then return true, true, "ok world.items.snapshot " .. tostring(detail) end
            return true, false, "world.items.snapshot failed: " .. tostring(detail)
        end
        -- world.items.runtime.stabilize [lastspawned|<actor_name>] [confirm]
        --   Marks a runtime world item as a settled/persistent Oculus placement.
        if line == "world.items.runtime.stabilize" or line:sub(1, #"world.items.runtime.stabilize ") == "world.items.runtime.stabilize " then
            local ok, detail = feature_inventory.runtime_stabilize(arg_after("world.items.runtime.stabilize"))
            if ok then return true, true, "ok world.items.runtime.stabilize " .. tostring(detail) end
            return true, false, "world.items.runtime.stabilize failed: " .. tostring(detail)
        end
        if line == "world.items.stabilize" or line:sub(1, #"world.items.stabilize ") == "world.items.stabilize " then
            local ok, detail = feature_inventory.runtime_stabilize(arg_after("world.items.stabilize"))
            if ok then return true, true, "ok world.items.stabilize " .. tostring(detail) end
            return true, false, "world.items.stabilize failed: " .. tostring(detail)
        end
        -- world.recipes.unlock <RECIPE_AssetName>
        --   Same resolution path as world.items.give, then calls
        --   pc.BP_Components_Progress:UnlockRecipes({recipe}). Backs the
        --   Recipe Service "Unlock" button.
        if line:sub(1, 21) == "world.recipes.unlock " then
            local ok, detail = feature_inventory.unlock_recipe(line:sub(22))
            if ok then return true, true, "ok world.recipes.unlock " .. tostring(detail) end
            return true, false, "world.recipes.unlock failed: " .. tostring(detail)
        end
        -- world.buildings.unlock_all
        --   AssetRegistry sweep of every UBuildingPieceData ; bulk
        --   pc.BP_Components_Progress:UnlockBuildings({...}). Backs
        --   the Build Service "Unlock All Buildings" button.
        if line == "world.buildings.unlock_all" then
            local ok, detail = feature_inventory.unlock_all_buildings("")
            if ok then return true, true, "ok world.buildings.unlock_all " .. tostring(detail) end
            return true, false, "world.buildings.unlock_all failed: " .. tostring(detail)
        end
        -- world.spells.unlock <SpellAssetName>
        --   Same shape as world.recipes.unlock but for UUtilitySpellData.
        --   Backs the Spell Service "Unlock spell" right-click action.
        if line:sub(1, 20) == "world.spells.unlock " then
            local ok, detail = feature_inventory.unlock_spell(line:sub(21))
            if ok then return true, true, "ok world.spells.unlock " .. tostring(detail) end
            return true, false, "world.spells.unlock failed: " .. tostring(detail)
        end
        -- world.spells.unlock_all
        --   AssetRegistry sweep of every UUtilitySpellData ; bulk
        --   pc.BP_Components_Progress:UnlockSpells({...}). Backs the
        --   Spell Service "Unlock All Spells" button.
        if line == "world.spells.unlock_all" then
            local ok, detail = feature_inventory.unlock_all_spells("")
            if ok then return true, true, "ok world.spells.unlock_all " .. tostring(detail) end
            return true, false, "world.spells.unlock_all failed: " .. tostring(detail)
        end
        -- world.skills.dump
        --   Dump every entry of pc.SkillComponent.Skills with current
        --   XP / level / max / next-level threshold. Used by Skill
        --   Service to populate / refresh the per-skill cards.
        if line == "world.skills.dump" then
            local ok, detail = feature_skills.dump("")
            if ok then return true, true, "ok world.skills.dump " .. tostring(detail) end
            return true, false, "world.skills.dump failed: " .. tostring(detail)
        end

        -- world.skills.add_xp <SKILL_AssetName> <amount>
        if line:sub(1, 20) == "world.skills.add_xp " then
            local ok, detail = feature_skills.add_xp(line:sub(21))
            if ok then return true, true, "ok world.skills.add_xp " .. tostring(detail) end
            return true, false, "world.skills.add_xp failed: " .. tostring(detail)
        end
        -- world.skills.set_level <SKILL_AssetName> <level>
        if line:sub(1, 23) == "world.skills.set_level " then
            local ok, detail = feature_skills.set_level(line:sub(24))
            if ok then return true, true, "ok world.skills.set_level " .. tostring(detail) end
            return true, false, "world.skills.set_level failed: " .. tostring(detail)
        end

        -- world.assets.classes
        --   AssetRegistry sweep : enumerate every subclass of
        --   DataAsset / PrimaryDataAsset / DominionDataAsset visible
        --   to the cooked build. Output : ipc/assets/_classes.json
        if line == "world.assets.classes" then
            local ok, detail = feature_assets.classes()
            if ok then return true, true, "ok world.assets.classes " .. tostring(detail) end
            return true, false, "world.assets.classes failed: " .. tostring(detail)
        end
        -- world.assets.catalog <ClassName>
        --   Sweep every cooked asset of <ClassName> (subclasses
        --   included) and dump ipc/assets/_catalog_<ClassName>.json.
        --   <ClassName> may be bare (defaults to /Script/Dominion),
        --   short-qualified (Engine.PrimaryAssetLabel), or fully
        --   qualified (/Script/Engine.PrimaryAssetLabel).
        if line:sub(1, 20) == "world.assets.catalog" then
            local ok, detail = feature_assets.catalog(arg_after("world.assets.catalog"))
            if ok then return true, true, "ok world.assets.catalog " .. tostring(detail) end
            return true, false, "world.assets.catalog failed: " .. tostring(detail)
        end
        -- world.assets.paths [root]
        --   Dump GetSubPaths(root, recursive=true) so we can see what
        --   folder trees exist before scoping a class catalog by path.
        --   Default root is /Game. Output : ipc/assets/_paths_<root>.json
        if line:sub(1, 18) == "world.assets.paths" then
            local ok, detail = feature_assets.paths(arg_after("world.assets.paths"))
            if ok then return true, true, "ok world.assets.paths " .. tostring(detail) end
            return true, false, "world.assets.paths failed: " .. tostring(detail)
        end

        -- Round 53: dedicated summon route. Bypasses player.field.call's
        -- reflection-into-CheatManager::Summon path (which uses LoadObject
        -- and fails on un-loaded packages) and instead pipes through
        -- PlayerController:ConsoleCommand("summon ...") which is the same
        -- exec route the in-game `~` console uses and handles asset
        -- on-demand loading + _C class resolution.
        if line:sub(1, 13) == "world.summon " then
            local ok, detail = feature_player_spawn.summon(line:sub(14))
            if ok then return true, true, "ok world.summon " .. tostring(detail) end
            return true, false, "world.summon failed: " .. tostring(detail)
        end

        -- world.class.load : diagnostic/preload route for the reflected
        -- Kismet soft-class path pipeline. If this succeeds, the class is
        -- now in memory and world.spawn should be able to resolve it via
        -- its normal StaticFindObject fast path.
        if line:sub(1, 17) == "world.class.load " then
            local ok, detail = feature_player_spawn.load_class(line:sub(18))
            if ok then return true, true, "ok world.class.load " .. tostring(detail) end
            return true, false, "world.class.load failed: " .. tostring(detail)
        end

        -- world.spawn.safe : convenience route for UI/favorites. Prefer the
        -- transform-aware deferred spawn, but fall back to native console
        -- summon for classes that still resist the spawn resolver.
        if line:sub(1, 17) == "world.spawn.safe " then
            local ok, detail = feature_player_spawn.spawn_safe(line:sub(18))
            if ok then return true, true, "ok world.spawn.safe " .. tostring(detail) end
            return true, false, "world.spawn.safe failed: " .. tostring(detail)
        end

        -- world.spawn.transform : explicit transform variant for tools that
        -- already know world-space placement. Keeps plain world.spawn's
        -- aim-trace/default-scale contract untouched for the Summon view.
        if line:sub(1, 22) == "world.spawn.transform " then
            local ok, detail = feature_player_spawn.spawn_transform(line:sub(23))
            if ok then return true, true, "ok world.spawn.transform " .. tostring(detail) end
            return true, false, "world.spawn.transform failed: " .. tostring(detail)
        end

        -- world.spawn : transform-aware counterpart to world.summon. Routes
        -- through UGameplayStatics::BeginDeferredActorSpawnFromClass +
        -- FinishSpawningActor so we get (a) aim-trace location instead of
        -- PC origin, (b) a deferred init window for required UPROPERTYs.
        -- Optional JSON tail :  world.spawn <ClassPath> {"ItemData":"/Game/.../IT_X.IT_X"}
        if line:sub(1, 12) == "world.spawn " then
            local ok, detail = feature_player_spawn.spawn(line:sub(13))
            if ok then return true, true, "ok world.spawn " .. tostring(detail) end
            return true, false, "world.spawn failed: " .. tostring(detail)
        end

        -- world.spawn.item : the WorldItemSubsystem-aware variant. Routes
        -- through UItemHelperLibrary::SpawnAndLaunchItem_Sync, the same
        -- function the game uses internally for every loot drop / craft
        -- output. Result is a fully-wired pickup (collect grants the item,
        -- magnet pull works, inventory queries see it). world.spawn alone
        -- gets you a visible-but-broken pickup because it only constructs
        -- the actor without enrolling it with the subsystem.
        if line:sub(1, 17) == "world.spawn.item " then
            local ok, detail = feature_player_spawn.spawn_item(line:sub(18))
            if ok then return true, true, "ok world.spawn.item " .. tostring(detail) end
            return true, false, "world.spawn.item failed: " .. tostring(detail)
        end

        -- world.bookmark <slot> -- stash the current `lastspawned` actor
        -- under <slot> so it can be referenced later via the
        -- `slot:<slot>` reach root. Solves the wiring problem when you
        -- need to refer to actor A *after* spawning actor B (B becomes
        -- the new lastspawned, A would otherwise be unreachable).
        -- Bookmarks are session-only ; UObject pointers don't survive
        -- save/reload, but they don't need to -- only the live
        -- configure-then-save flow uses them.
        if line:sub(1, 15) == "world.bookmark " then
            local slot = line:sub(16):match("^%s*(%S+)%s*$")
            if not slot then return true, false, "usage: world.bookmark <slot>" end
            local ok, detail = feature_field.bookmark_last_spawned(slot)
            if ok then return true, true, "ok world.bookmark " .. tostring(detail) end
            return true, false, "world.bookmark failed: " .. tostring(detail)
        end
        if line:sub(1, 22) == "world.bookmark.forget " then
            local slot = line:sub(23):match("^%s*(%S+)%s*$")
            if not slot then return true, false, "usage: world.bookmark.forget <slot>" end
            local ok, detail = feature_field.forget_bookmark(slot)
            if ok then return true, true, "ok world.bookmark.forget " .. tostring(detail) end
            return true, false, "world.bookmark.forget failed: " .. tostring(detail)
        end
        if line == "world.bookmark.list" then
            local entries = feature_field.list_bookmarks()
            if #entries == 0 then return true, true, "ok world.bookmark.list (empty)" end
            return true, true, "ok world.bookmark.list " .. table.concat(entries, ",")
        end

        -- world.net.roster : passive roster snapshot for the WPF Multi
        -- tab. Returns a single-line JSON array in the ack body so the
        -- viewer can parse without a follow-up file read.
        if line == "world.net.roster" then
            return true, true, feature_net.json_roster()
        end

        -- world.time.release (reset visual override)
        if line == "world.time.release" then
            local ok, detail = feature_world.release_time()
            if ok then return true, true, "ok world.time.release " .. tostring(detail) end
            return true, false, "world.time.release failed: " .. tostring(detail)
        end

        -- world.time.probe -- read-only dump (must be checked before the
        -- generic `world.time <hour>` prefix so it isn't swallowed).
        if line == "world.time.probe" then
            local ok, detail = feature_world.probe_time()
            if ok then return true, true, "ok world.time.probe " .. tostring(detail) end
            return true, false, "world.time.probe failed: " .. tostring(detail)
        end

        -- world.time <hour>
        if line:sub(1, 10) == "world.time" and line:sub(1, 16) ~= "world.time.pause"
            and line:sub(1, 16) ~= "world.time.speed"
            and line:sub(1, 16) ~= "world.time.probe" then
            local val = arg_after("world.time")
            if val == "" then return true, false, "usage: world.time <hour 0-24>" end
            local ok, detail = feature_world.set_time(val)
            if ok then return true, true, "ok world.time " .. tostring(detail) end
            return true, false, "world.time failed: " .. tostring(detail)
        end

        -- world.time.pause <on|off>
        if line:sub(1, 16) == "world.time.pause" then
            local val = arg_after("world.time.pause")
            if val == "" then return true, false, "usage: world.time.pause <on|off>" end
            local ok, detail = feature_world.pause_time(val)
            if ok then return true, true, "ok world.time.pause " .. tostring(detail) end
            return true, false, "world.time.pause failed: " .. tostring(detail)
        end

        -- world.time.speed <minutes>
        if line:sub(1, 16) == "world.time.speed" then
            local val = arg_after("world.time.speed")
            if val == "" then return true, false, "usage: world.time.speed <minutes>" end
            local ok, detail = feature_world.set_day_speed(val)
            if ok then return true, true, "ok world.time.speed " .. tostring(detail) end
            return true, false, "world.time.speed failed: " .. tostring(detail)
        end

        -- world.dawn <hour>
        if line:sub(1, 10) == "world.dawn" then
            local val = arg_after("world.dawn")
            if val == "" then return true, false, "usage: world.dawn <hour 0-24>" end
            local ok, detail = feature_world.set_dawn(val)
            if ok then return true, true, "ok world.dawn " .. tostring(detail) end
            return true, false, "world.dawn failed: " .. tostring(detail)
        end

        -- world.dusk <hour>
        if line:sub(1, 10) == "world.dusk" then
            local val = arg_after("world.dusk")
            if val == "" then return true, false, "usage: world.dusk <hour 0-24>" end
            local ok, detail = feature_world.set_dusk(val)
            if ok then return true, true, "ok world.dusk " .. tostring(detail) end
            return true, false, "world.dusk failed: " .. tostring(detail)
        end

        -- world.storedtime <hour>  (round 25: persistent game-clock write)
        if line:sub(1, 16) == "world.storedtime" then
            local val = arg_after("world.storedtime")
            if val == "" then return true, false, "usage: world.storedtime <hour 0-24>" end
            local ok, detail = feature_world.set_storedtime(val)
            if ok then return true, true, "ok world.storedtime " .. tostring(detail) end
            return true, false, "world.storedtime failed: " .. tostring(detail)
        end

        -- world.weather <type>
        -- Exclusions cover every more-specific world.weather.* verb below.
        if line:sub(1, 13) == "world.weather"
            and line:sub(1, 19) ~= "world.weather.pause"
            and line:sub(1, 19) ~= "world.weather.probe"
            and line:sub(1, 19) ~= "world.weather.where"
            and line:sub(1, 18) ~= "world.weather.list"
            and line:sub(1, 22) ~= "world.weather.regional"
            and line:sub(1, 29) ~= "world.weather.region_priority" then
            local val = arg_after("world.weather")
            if val == "" then return true, false, "usage: world.weather <0-9 or name>" end
            local ok, detail = feature_world.set_weather(val)
            if ok then return true, true, "ok world.weather " .. tostring(detail) end
            return true, false, "world.weather failed: " .. tostring(detail)
        end

        -- world.weather.pause <on|off>
        if line:sub(1, 19) == "world.weather.pause" then
            local val = arg_after("world.weather.pause")
            if val == "" then return true, false, "usage: world.weather.pause <on|off>" end
            local ok, detail = feature_world.pause_weather(val)
            if ok then return true, true, "ok world.weather.pause " .. tostring(detail) end
            return true, false, "world.weather.pause failed: " .. tostring(detail)
        end

        -- world.weather.probe -- read-only dump of subsystem + regional state
        if line == "world.weather.probe" then
            local ok, detail = feature_world.probe_weather()
            if ok then return true, true, "ok world.weather.probe " .. tostring(detail) end
            return true, false, "world.weather.probe failed: " .. tostring(detail)
        end

        -- world.weather.where -- GetWeatherAtLocation(player)
        if line == "world.weather.where" then
            local ok, detail = feature_world.weather_where()
            if ok then return true, true, "ok world.weather.where " .. tostring(detail) end
            return true, false, "world.weather.where failed: " .. tostring(detail)
        end

        -- world.weather.list -- enumerate every accepted EWeatherType value +
        --   alias. Useful for UI dropdowns ; detail is pipe-delimited.
        if line == "world.weather.list" then
            local ok, detail = feature_world.weather_list()
            if ok then return true, true, "ok world.weather.list " .. tostring(detail) end
            return true, false, "world.weather.list failed: " .. tostring(detail)
        end

        -- world.weather.regional <type> -- raw : write WeatherType on every
        --   UDynamicRegionalWeather + UStaticRegionalWeather (bypass
        --   TrySetWeather to test if regional state is overriding it).
        if line:sub(1, 22) == "world.weather.regional" then
            local val = arg_after("world.weather.regional")
            if val == "" then return true, false, "usage: world.weather.regional <0-9 or name>" end
            local ok, detail = feature_world.set_regional_weather(val)
            if ok then return true, true, "ok world.weather.regional " .. tostring(detail) end
            return true, false, "world.weather.regional failed: " .. tostring(detail)
        end

        -- world.weather.region_priority <int> -- raw : write Priority on
        --   every ARegionSpecificGlobalWeatherActor (composite priority test).
        if line:sub(1, 29) == "world.weather.region_priority" then
            local val = arg_after("world.weather.region_priority")
            if val == "" then return true, false, "usage: world.weather.region_priority <int>" end
            local ok, detail = feature_world.set_region_priority(val)
            if ok then return true, true, "ok world.weather.region_priority " .. tostring(detail) end
            return true, false, "world.weather.region_priority failed: " .. tostring(detail)
        end

        return true, false, "unknown world.* verb"
    end

    return false, nil, nil
end

return M
