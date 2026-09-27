-- feature_progress.lua
-- Dedicated verbs for the vanilla-persistent AWorldProgressManager SaveGame fields.

local M = {}

local safety = require("safety")

local function is_valid(obj)
    return safety.is_uobject(obj)
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function find_first_of(class_name)
    if not FindAllOf then return nil end
    local ok, list = pcall(FindAllOf, class_name)
    if not ok or not list then return nil end
    local n = 0
    pcall(function() n = #list end)
    if n == 0 then
        local ok_num, num_val = pcall(function() return list:Num() end)
        if ok_num and type(num_val) == "number" then n = num_val end
    end
    for i = 1, n do
        local eok, entry = pcall(function() return list[i] end)
        if eok and entry ~= nil and is_valid(entry) then return entry end
    end
    return nil
end

local function get_manager()
    local subsystem = find_first_of("WorldProgressSubsystem")
    if subsystem and is_valid(subsystem) then
        local ok_mgr, mgr = pcall(function() return subsystem:GetWorldProgressManager() end)
        if ok_mgr and mgr ~= nil and is_valid(mgr) then return mgr end
        local ok_field, mgr_field = pcall(function() return subsystem.WorldProgressManager end)
        if ok_field and mgr_field ~= nil and is_valid(mgr_field) then return mgr_field end
    end

    local candidates = { "WorldProgressManager", "AWorldProgressManager" }
    for _, class_name in ipairs(candidates) do
        local obj = find_first_of(class_name)
        if obj ~= nil and is_valid(obj) then return obj end
    end
    return nil, "no live WorldProgressManager"
end

local function get_defeated_set(mgr)
    local ok, set = pcall(function() return mgr.DefeatedBossesInternalNames end)
    if not ok or set == nil then return nil, "DefeatedBossesInternalNames unreadable" end
    return set
end

local function get_world_hooks_set(mgr)
    local ok, set = pcall(function() return mgr.WorldHooksTriggered end)
    if not ok or set == nil then return nil, "WorldHooksTriggered unreadable" end
    return set
end

local function set_num(set)
    local ok, n = pcall(function() return set:Num() end)
    if ok and type(n) == "number" then return n end
    return nil
end

local function contains(set, value)
    local ok, hit = pcall(function()
        if set.Contains then return set:Contains(value) end
        return false
    end)
    return ok and hit == true
end

local function add_to_set(set, value)
    local already = contains(set, value)
    local ok, err = pcall(function() set:Add(value) end)
    if not ok then return false, tostring(err) end
    return true, already and "already-present" or "added"
end

local function remove_from_set(set, value)
    local already = contains(set, value)
    local ok, err = pcall(function() set:Remove(value) end)
    if not ok then return false, tostring(err) end
    return true, already and "removed" or "not-present"
end

local function load_object(path)
    local obj = nil
    if LoadObject then
        local ok, loaded = pcall(LoadObject, path)
        if ok and loaded ~= nil then obj = loaded end
    end
    if obj == nil and LoadAsset then
        local ok, loaded = pcall(LoadAsset, path)
        if ok and loaded ~= nil then obj = loaded end
    end
    if obj == nil and StaticFindObject then
        local ok, loaded = pcall(StaticFindObject, path)
        if ok and loaded ~= nil then obj = loaded end
    end
    if obj == nil then return nil end

    local class_name = safety.class_name_of(obj) or ""
    if class_name == "BlueprintGeneratedClass" or class_name == "Class" then
        local ok_cdo, cdo = pcall(function() return obj:GetDefaultObject() end)
        if ok_cdo and cdo ~= nil then obj = cdo end
    end
    return obj
end

local function load_world_hook(path)
    local hook = load_object(path)
    if hook ~= nil and is_valid(hook) then return hook end

    if path:sub(-2) ~= "_C" then
        local class_path = path .. "_C"
        hook = load_object(class_path)
        if hook ~= nil and is_valid(hook) then return hook end
    end
    return nil, "WorldHook asset lookup failed: " .. tostring(path)
end

local function bool_text(ok, value)
    if not ok then return "unknown" end
    return tostring(value == true)
end

local function hook_triggered_text(mgr, hook)
    local ok, triggered = pcall(function() return mgr:HasWorldHookBeenTriggered(hook) end)
    return bool_text(ok, triggered)
end

local function hook_set_state_text(mgr, hook)
    local set = get_world_hooks_set(mgr)
    if not set then return "unknown", "?" end
    local ok, hit = pcall(function()
        if set.Contains then return set:Contains(hook) end
        return false
    end)
    return bool_text(ok, hit), tostring(set_num(set) or "?")
end

local function hook_multi_text(hook)
    local ok, multi = pcall(function() return hook:GetCanBeTriggeredMultipleTimes() end)
    if ok then return tostring(multi == true) end
    local ok_field, field_val = pcall(function() return hook.bCanBeTriggeredMultipleTimes end)
    return bool_text(ok_field, field_val)
end

local function property_text(obj, key)
    local ok, value = pcall(function() return obj[key] end)
    if not ok or value == nil then return "?" end
    if type(value) == "userdata" then
        local ok_method, method = pcall(function() return value.ToString end)
        if ok_method and method then
            local ok_string, text = pcall(function() return value:ToString() end)
            if ok_string and text ~= nil then return tostring(text) end
        end
    end
    return tostring(value)
end

local function hook_summary(mgr, hook)
    local in_set, set_count = hook_set_state_text(mgr, hook)
    return string.format("class=%s triggered=%s set=%s setCount=%s multi=%s persistenceID=%s",
        safety.class_name_of(hook) or "WorldHook",
        hook_triggered_text(mgr, hook),
        in_set,
        set_count,
        hook_multi_text(hook),
        property_text(hook, "PersistenceID"))
end

local PROGRESS_TAG_ALIASES = {
    ["imaru.can_spawn"] = {
        tag = "WorldProgress.Imaru.CanSpawnImaru",
        path = "/Game/Gameplay/AI/DragonImaru/Misc/BP_DragonImaru_SpawnTrigger.BP_DragonImaru_SpawnTrigger_C",
        field = "CanSpawnImaruTag",
    },
    ["worldprogress.imaru.canspawnimaru"] = {
        tag = "WorldProgress.Imaru.CanSpawnImaru",
        path = "/Game/Gameplay/AI/DragonImaru/Misc/BP_DragonImaru_SpawnTrigger.BP_DragonImaru_SpawnTrigger_C",
        field = "CanSpawnImaruTag",
    },
    ["imaru.pending_seal"] = {
        tag = "WorldProgress.Imaru.PendingSealDoor",
        path = "/Game/Gameplay/Quests/FH_Quests/DeathQuest_Fellhollow/BP_Seal_Switchable.BP_Seal_Switchable_C",
        field = "PendingSealTag",
    },
    ["worldprogress.imaru.pendingsealdoor"] = {
        tag = "WorldProgress.Imaru.PendingSealDoor",
        path = "/Game/Gameplay/Quests/FH_Quests/DeathQuest_Fellhollow/BP_Seal_Switchable.BP_Seal_Switchable_C",
        field = "PendingSealTag",
    },
}

local function progress_tag_list_text()
    return "imaru.can_spawn=WorldProgress.Imaru.CanSpawnImaru imaru.pending_seal=WorldProgress.Imaru.PendingSealDoor"
end

local function resolve_progress_tag(key)
    local normalized = tostring(key or ""):lower()
    local rec = PROGRESS_TAG_ALIASES[normalized]
    if not rec then return nil, "unknown progress tag alias. known: " .. progress_tag_list_text() end
    local holder = load_object(rec.path)
    if holder == nil or not is_valid(holder) then return nil, "tag holder asset lookup failed: " .. rec.path end
    local ok, tag = pcall(function() return holder[rec.field] end)
    if not ok or tag == nil then return nil, "tag field unreadable: " .. rec.field end
    return tag, rec.tag
end

function M.probe(_args)
    local mgr, err = get_manager()
    if not mgr then return false, err end
    local set, serr = get_defeated_set(mgr)
    if not set then return false, serr end
    local n = set_num(set)
    return true, string.format("manager=%s defeatedBosses=%s velgar=%s imaru=%s",
        safety.class_name_of(mgr) or "WorldProgressManager",
        tostring(n or "?"),
        tostring(contains(set, "ai_boss_velgar")),
        tostring(contains(set, "ai_boss_imaru")))
end

function M.has(args)
    local internal_name = trim(args)
    if internal_name == "" then return false, "usage: world.progress.has <bossInternalName>" end
    local mgr, err = get_manager()
    if not mgr then return false, err end
    local set, serr = get_defeated_set(mgr)
    if not set then return false, serr end
    return true, string.format("%s=%s", internal_name, tostring(contains(set, internal_name)))
end

function M.defeat(args)
    local internal_name = trim(args)
    if internal_name == "" then return false, "usage: world.progress.defeat <bossInternalName>" end
    local mgr, err = get_manager()
    if not mgr then return false, err end
    local set, serr = get_defeated_set(mgr)
    if not set then return false, serr end
    local ok, detail = add_to_set(set, internal_name)
    if not ok then return false, "DefeatedBossesInternalNames Add failed: " .. tostring(detail) end
    local n = set_num(set)
    return true, string.format("%s %s defeatedBosses=%s", detail, internal_name, tostring(n or "?"))
end

function M.undefeat(args)
    local internal_name = trim(args)
    if internal_name == "" then return false, "usage: world.progress.undefeat <bossInternalName>" end
    local mgr, err = get_manager()
    if not mgr then return false, err end
    local set, serr = get_defeated_set(mgr)
    if not set then return false, serr end
    local ok, detail = remove_from_set(set, internal_name)
    if not ok then return false, "DefeatedBossesInternalNames Remove failed: " .. tostring(detail) end
    local n = set_num(set)
    return true, string.format("%s %s defeatedBosses=%s", detail, internal_name, tostring(n or "?"))
end

function M.trigger_hook(args)
    local path = trim(args)
    if path == "" then return false, "usage: world.progress.hook.trigger </Game/.../BP_Hook.BP_Hook_C>" end
    local mgr, err = get_manager()
    if not mgr then return false, err end
    local hook, herr = load_world_hook(path)
    if not hook then return false, herr end
    local before = hook_triggered_text(mgr, hook)
    local before_set = hook_set_state_text(mgr, hook)
    local multi = hook_multi_text(hook)
    local ok, call_err = pcall(function() mgr:TriggerWorldHook(hook) end)
    if not ok then return false, "TriggerWorldHook failed: " .. tostring(call_err) end
    local after = hook_triggered_text(mgr, hook)
    local after_set = hook_set_state_text(mgr, hook)
    return true, string.format("triggered %s before=%s beforeSet=%s after=%s afterSet=%s multi=%s", path, before, before_set, after, after_set, multi)
end

function M.reset_hook(args)
    local path = trim(args)
    if path == "" then return false, "usage: world.progress.hook.reset </Game/.../BP_Hook.BP_Hook_C>" end
    local mgr, err = get_manager()
    if not mgr then return false, err end
    local hook, herr = load_world_hook(path)
    if not hook then return false, herr end
    local set, serr = get_world_hooks_set(mgr)
    if not set then return false, serr end
    local before = hook_triggered_text(mgr, hook)
    local before_set = hook_set_state_text(mgr, hook)
    local ok, detail = remove_from_set(set, hook)
    if not ok then return false, "WorldHooksTriggered Remove failed: " .. tostring(detail) end
    local after = hook_triggered_text(mgr, hook)
    local after_set = hook_set_state_text(mgr, hook)
    return true, string.format("safe-reset %s %s before=%s beforeSet=%s after=%s afterSet=%s multi=%s", path, detail, before, before_set, after, after_set, hook_multi_text(hook))
end

function M.mark_hook(args)
    local path = trim(args)
    if path == "" then return false, "usage: world.progress.hook.mark </Game/.../BP_Hook.BP_Hook_C>" end
    local mgr, err = get_manager()
    if not mgr then return false, err end
    local hook, herr = load_world_hook(path)
    if not hook then return false, herr end
    local set, serr = get_world_hooks_set(mgr)
    if not set then return false, serr end
    local before = hook_triggered_text(mgr, hook)
    local before_set = hook_set_state_text(mgr, hook)
    local ok, detail = add_to_set(set, hook)
    if not ok then return false, "WorldHooksTriggered Add failed: " .. tostring(detail) end
    local after = hook_triggered_text(mgr, hook)
    local after_set = hook_set_state_text(mgr, hook)
    return true, string.format("marked %s %s before=%s beforeSet=%s after=%s afterSet=%s multi=%s", path, detail, before, before_set, after, after_set, hook_multi_text(hook))
end

function M.fire_hook(args)
    local path = trim(args)
    if path == "" then return false, "usage: world.progress.hook.fire </Game/.../BP_Hook.BP_Hook_C>" end
    local mgr, err = get_manager()
    if not mgr then return false, err end
    local hook, herr = load_world_hook(path)
    if not hook then return false, herr end
    local before = hook_triggered_text(mgr, hook)
    local before_set = hook_set_state_text(mgr, hook)
    local ok, call_err = pcall(function() hook:OnTriggered() end)
    if not ok then
        local err_text = tostring(call_err or "")
        if err_text:find("UObject instance is nullptr", 1, true) then
            return false, "OnTriggered unusable for this loaded hook object; it has no live UObject/world context"
        end
        return false, "OnTriggered failed: " .. err_text
    end
    local after = hook_triggered_text(mgr, hook)
    local after_set = hook_set_state_text(mgr, hook)
    return true, string.format("fired %s before=%s beforeSet=%s after=%s afterSet=%s multi=%s", path, before, before_set, after, after_set, hook_multi_text(hook))
end

function M.value_list(_args)
    return true, progress_tag_list_text()
end

function M.value_get(args)
    local key = trim(args)
    if key == "" then return false, "usage: world.progress.value.get <alias>; known: " .. progress_tag_list_text() end
    local mgr, err = get_manager()
    if not mgr then return false, err end
    local tag, tag_name_or_err = resolve_progress_tag(key)
    if not tag then return false, tag_name_or_err end
    local ok, value = pcall(function() return mgr:GetWorldProgressValue(tag) end)
    if not ok then return false, "GetWorldProgressValue failed: " .. tostring(value) end
    return true, string.format("%s=%s", tag_name_or_err, tostring(value))
end

function M.value_set(args)
    local key, value_text, persistence = tostring(args or ""):match("^%s*(%S+)%s+(%S+)%s*(.-)%s*$")
    if not key then return false, "usage: world.progress.value.set <alias> <number> [save|transient]; known: " .. progress_tag_list_text() end
    persistence = persistence:lower()
    if persistence ~= "" and persistence ~= "save" and persistence ~= "transient" then
        return false, "persistence must be save or transient"
    end
    local value = tonumber(value_text)
    if value == nil or value ~= value or math.abs(value) == math.huge then return false, "value must be a finite number" end
    local save_value = persistence ~= "transient"
    local mgr, err = get_manager()
    if not mgr then return false, err end
    local tag, tag_name_or_err = resolve_progress_tag(key)
    if not tag then return false, tag_name_or_err end
    local ok_before, before = pcall(function() return mgr:GetWorldProgressValue(tag) end)
    local ok, call_err = pcall(function() mgr:SetWorldProgressValue(tag, value, save_value) end)
    if not ok then return false, "SetWorldProgressValue failed: " .. tostring(call_err) end
    local ok_after, after = pcall(function() return mgr:GetWorldProgressValue(tag) end)
    return true, string.format("%s before=%s after=%s save=%s", tag_name_or_err, tostring(ok_before and before or "?"), tostring(ok_after and after or "?"), tostring(save_value))
end

function M.hook_has(args)
    local path = trim(args)
    if path == "" then return false, "usage: world.progress.hook.has </Game/.../BP_Hook.BP_Hook_C>" end
    local mgr, err = get_manager()
    if not mgr then return false, err end
    local hook, herr = load_world_hook(path)
    if not hook then return false, herr end
    return true, string.format("%s=%s", path, hook_triggered_text(mgr, hook))
end

function M.hook_probe(args)
    local path = trim(args)
    if path == "" then return false, "usage: world.progress.hook.probe </Game/.../BP_Hook.BP_Hook_C>" end
    local mgr, err = get_manager()
    if not mgr then return false, err end
    local hook, herr = load_world_hook(path)
    if not hook then return false, herr end
    return true, hook_summary(mgr, hook)
end

return M
