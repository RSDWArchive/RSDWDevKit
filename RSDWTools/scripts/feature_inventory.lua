-- feature_inventory.lua
--
-- Player inventory + recipe-progression RPC verbs. Backs the Item
-- Service / Recipe Service panes in the WPF UI.
--
-- Verbs:
--   world.items.give    <asset_short_name> [count]
--   world.recipes.unlock <asset_short_name>
--
-- Resolution strategy for an asset short name (e.g. "ITEM_Armour_T2_Body_Linen"
-- or "RECIPE_Ammo_Arrows_Bone_Bleed"):
--
--   1. FindFirstOf(name) -- if a CDO or live instance is already in
--      the global object array, use it directly. Cheap and avoids a
--      registry sweep.
--   2. AssetRegistry sweep cache: on first use we call
--      registry:GetAssetsByClass({ItemData,RecipeData}) (subclasses
--      included) and build a lookup `asset_name -> package_name`.
--      Subsequent calls hit the cache. The cache is invalidated
--      lazily ; if a name misses we re-sweep once before giving up
--      to handle plugins that loaded after our first sweep.
--   3. LoadAsset(package_name) + StaticFindObject(package_name + "." + name)
--      to materialize the UItemData / URecipeData object.
--
-- Game-side calls used:
--   pc.BP_Components_PersonalInventory:AddItemByData(itemData, count, durability=1.0, tags=empty)
--   pc.BP_Components_Progress:UnlockRecipes({recipeData})
--
-- Component reach paths come from the catalog dump (rootKind=component,
-- reachPath=pawn->PlayerController->BP_Components_<Name>). We try the
-- shipped BP wrapper component first ; if unavailable we fall back to
-- the native parent (PersonalInventoryComponent / ProgressComponent)
-- which exposes the same API.

local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local mod_paths = require("mod_paths")
local unwrap_param

-- ---------------------------------------------------------------------------
-- Local lookup helpers.
-- ---------------------------------------------------------------------------
local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function actor_short_name(actor)
    if not is_valid(actor) then return nil end
    return feature_actor.short_name_of(actor)
end

local function actor_location(actor)
    if not is_valid(actor) then return nil end
    if actor.K2_GetActorLocation then
        local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
        if ok and loc then return loc end
    end
    if actor.GetActorLocation then
        local ok, loc = pcall(function() return actor:GetActorLocation() end)
        if ok and loc then return loc end
    end
    return nil
end

local function is_runtime_world_item(actor)
    if not is_valid(actor) then return false end
    local cls_name, full_name
    pcall(function()
        local cls = actor:GetClass()
        if cls then
            if cls.GetFName then
                local fn = cls:GetFName()
                if fn and fn.ToString then cls_name = fn:ToString() end
            end
            if not cls_name and cls.GetName then cls_name = cls:GetName() end
        end
    end)
    pcall(function() full_name = actor:GetFullName() end)
    local hay = ((cls_name or "") .. " " .. (full_name or "")):lower()
    return hay:find("runtimespawnedworlditem", 1, true) ~= nil
        or hay:find("bp_runtimespawnedworlditem", 1, true) ~= nil
end

local ITEM_FIND_CLASSES = {
    "BP_RuntimeSpawnedWorldItem_C",
    "BP_RuntimeSpawnedWorldItem_NoDelayForMagnet_C",
    "BP_RuntimeSpawnedWorldItem_ProcessingStation_C",
    "RuntimeSpawnedWorldItem",
    "WorldItem",
}

local function enumerate_runtime_world_items()
    if not FindAllOf then return {} end
    local out, seen = {}, {}
    local function add(actor)
        if not is_runtime_world_item(actor) then return end
        local key = actor_short_name(actor) or tostring(actor)
        if seen[key] then return end
        seen[key] = true
        out[#out + 1] = actor
    end
    for _, class_name in ipairs(ITEM_FIND_CLASSES) do
        local ok, list = pcall(FindAllOf, class_name)
        if ok and type(list) == "table" then
            for _, actor in ipairs(list) do add(actor) end
        end
    end
    if #out == 0 then
        local ok, actors = pcall(function()
            local list = FindAllOf("Actor")
            if type(list) ~= "table" then list = FindAllOf("AActor") end
            return list
        end)
        if ok and type(actors) == "table" then
            for _, actor in ipairs(actors) do add(actor) end
        end
    end
    return out
end

local function distance_sq(a, b)
    if not a or not b then return nil end
    local dx = (a.X or 0) - (b.X or 0)
    local dy = (a.Y or 0) - (b.Y or 0)
    local dz = (a.Z or 0) - (b.Z or 0)
    return dx * dx + dy * dy + dz * dz
end

local function collect_runtime_world_item_names_near(loc, radius)
    local names = {}
    local r2 = (radius or 750.0) * (radius or 750.0)
    for _, actor in ipairs(enumerate_runtime_world_items()) do
        local name = actor_short_name(actor)
        local d2 = distance_sq(actor_location(actor), loc)
        if name and d2 and d2 <= r2 then
            names[name] = true
        end
    end
    return names
end

local function first_actor_from_world_item_set(...)
    for arg_i = 1, select("#", ...) do
        local coll = select(arg_i, ...)
        if coll ~= nil then
            local n = 0
            pcall(function()
                local len = #coll
                if type(len) == "number" then n = len end
            end)
            if n == 0 and type(coll) == "userdata" then
                pcall(function()
                    local v = coll:Num()
                    if type(v) == "number" then n = v end
                end)
            end
            for _, base in ipairs({ 1, 0 }) do
                local last_i = base == 1 and n or math.max(0, n - 1)
                for i = base, last_i do
                    local ok_entry, entry = pcall(function() return coll[i] end)
                    if ok_entry then
                        entry = unwrap_param(entry)
                        if is_runtime_world_item(entry) then return entry end
                    end
                end
            end
        end
    end
    return nil
end

local function find_new_runtime_world_item_near(loc, before_names, radius)
    local r2 = (radius or 750.0) * (radius or 750.0)
    local best, best_d2 = nil, nil
    for _, actor in ipairs(enumerate_runtime_world_items()) do
        local name = actor_short_name(actor)
        if name and not before_names[name] then
            local d2 = distance_sq(actor_location(actor), loc)
            if d2 and d2 <= r2 and (not best_d2 or d2 < best_d2) then
                best = actor
                best_d2 = d2
            end
        end
    end
    return best
end

local function remember_last_spawned_world_item(actor)
    if not is_runtime_world_item(actor) then return nil end
    pcall(function()
        feature_field.set_last_spawned(actor)
    end)
    return actor_short_name(actor)
end

local function object_full_name(obj)
    if not is_valid(obj) or not obj.GetFullName then return nil end
    local ok, value = pcall(function() return obj:GetFullName() end)
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
end

local function object_class_name(obj)
    if not is_valid(obj) then return nil end
    local cls
    pcall(function() cls = obj:GetClass() end)
    if not is_valid(cls) then return nil end
    if cls.GetFullName then
        local ok, value = pcall(function() return cls:GetFullName() end)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    if cls.GetName then
        local ok, value = pcall(function() return cls:GetName() end)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    return nil
end

local function simple_value(v)
    local tv = type(v)
    if tv == "string" or tv == "number" or tv == "boolean" or v == nil then return v end
    return tostring(v)
end

local function read_simple_field(obj, field_name)
    if not is_valid(obj) then return nil end
    local ok, value = pcall(function() return obj[field_name] end)
    if ok then return simple_value(value) end
    return nil
end

local function read_method_value(obj, method_name, ...)
    if not is_valid(obj) then return nil end
    local fn = obj[method_name]
    if not fn then return nil end
    local args = { ... }
    local ok, value = pcall(function() return fn(obj, table.unpack(args)) end)
    if ok then return simple_value(value) end
    return nil
end

local function item_transform_snapshot(actor)
    local loc = actor_location(actor)
    local rot
    if is_valid(actor) and actor.K2_GetActorRotation then
        local ok, value = pcall(function() return actor:K2_GetActorRotation() end)
        if ok then rot = value end
    end
    local scale = feature_actor.get_actor_scale3d and feature_actor.get_actor_scale3d(actor) or nil
    return {
        x = loc and loc.X or nil,
        y = loc and loc.Y or nil,
        z = loc and loc.Z or nil,
        pitch = rot and rot.Pitch or nil,
        yaw = rot and rot.Yaw or nil,
        roll = rot and rot.Roll or nil,
        scale_x = scale and scale.X or nil,
        scale_y = scale and scale.Y or nil,
        scale_z = scale and scale.Z or nil,
    }
end

local function add_component(out, seen, comp, label)
    if not is_valid(comp) then return end
    local key = object_full_name(comp) or tostring(comp)
    if seen[key] then return end
    seen[key] = true
    out[#out + 1] = { label = label, ref = comp }
end

local function get_runtime_item_components(actor)
    local out, seen = {}, {}
    if not is_valid(actor) then return out end

    add_component(out, seen, actor.RootComponent, "RootComponent")
    for _, field_name in ipairs({
        "ItemMesh",
        "LaunchableComponent",
        "MagneticComponentGrantItem",
        "InteractionCollision",
        "InteractionComponent",
        "NS_Sparkles",
    }) do
        local ok, value = pcall(function() return actor[field_name] end)
        if ok then add_component(out, seen, value, field_name) end
    end
    for _, method_name in ipairs({
        "GetStaticMeshComponent",
        "GetLaunchableComponent",
        "GetMagneticComponent",
        "GetInteractionCollision",
        "GetInteractionComponent",
    }) do
        local fn = actor[method_name]
        if fn then
            local ok, value = pcall(function() return fn(actor) end)
            if ok then add_component(out, seen, value, method_name .. "()") end
        end
    end
    return out
end

local function none_bone_name()
    if FName then
        local ok, value = pcall(FName, "")
        if ok then return value end
    end
    return ""
end

local function component_snapshot(entry)
    local comp = entry and entry.ref
    local bone = none_bone_name()
    return {
        label = entry and entry.label or nil,
        name = object_full_name(comp),
        class = object_class_name(comp),
        b_auto_activate = read_simple_field(comp, "bAutoActivate"),
        b_is_active = read_simple_field(comp, "bIsActive"),
        active = read_method_value(comp, "IsActive"),
        component_tick_enabled = read_method_value(comp, "IsComponentTickEnabled"),
        b_visible = read_simple_field(comp, "bVisible"),
        b_hidden_in_game = read_simple_field(comp, "bHiddenInGame"),
        mobility = read_simple_field(comp, "Mobility"),
        collision_enabled = read_method_value(comp, "GetCollisionEnabled"),
        collision_profile = read_method_value(comp, "GetCollisionProfileName"),
        generate_overlap_events = read_method_value(comp, "GetGenerateOverlapEvents"),
        simulating_physics = read_method_value(comp, "IsSimulatingPhysics", bone),
        gravity_enabled = read_method_value(comp, "IsGravityEnabled"),
        b_launched = read_simple_field(comp, "bLaunched"),
        b_just_launched = read_simple_field(comp, "bJustLaunched"),
        launch_is_launched = read_method_value(comp, "IsLaunched"),
        b_allow_auto_magnetization = read_simple_field(comp, "bAllowAutoMagnetization"),
        b_auto_magnetization_enabled = read_simple_field(comp, "bAutoMagnetizationEnabled"),
        b_has_been_granted = read_simple_field(comp, "bHasBeenGranted"),
        magnet_auto_enabled = read_method_value(comp, "IsAutoMagnetizationEnabled"),
        has_set_mobility = is_valid(comp) and comp.SetMobility ~= nil or false,
        has_set_simulate_physics = is_valid(comp) and comp.SetSimulatePhysics ~= nil or false,
        has_set_enable_gravity = is_valid(comp) and comp.SetEnableGravity ~= nil or false,
        has_put_rigid_body_to_sleep = is_valid(comp) and comp.PutRigidBodyToSleep ~= nil or false,
        has_pause_launch = is_valid(comp) and comp.PauseLaunch ~= nil or false,
    }
end

local function runtime_item_snapshot(actor, note)
    if not is_runtime_world_item(actor) then return nil end
    local components = {}
    for _, entry in ipairs(get_runtime_item_components(actor)) do
        components[#components + 1] = component_snapshot(entry)
    end
    return {
        note = note,
        actor = {
            name = actor_short_name(actor),
            full_name = object_full_name(actor),
            class = object_class_name(actor),
        },
        transform = item_transform_snapshot(actor),
        fields = {
            bRegisterAsRuntimeSpawned = read_simple_field(actor, "bRegisterAsRuntimeSpawned"),
            bCanExpire = read_simple_field(actor, "bCanExpire"),
            ExpirationTimeInGameEndTicks = read_simple_field(actor, "ExpirationTimeInGameEndTicks"),
            bExpireEvenIfDroppedAndNoAutoMagnetize = read_simple_field(actor, "bExpireEvenIfDroppedAndNoAutoMagnetize"),
            NameOfPlayerCharacterThatDroppedItem = read_simple_field(actor, "NameOfPlayerCharacterThatDroppedItem"),
            GuidOfPlayerCharacterThatDroppedItem = read_simple_field(actor, "GuidOfPlayerCharacterThatDroppedItem"),
            NetCullDistanceBand = read_simple_field(actor, "NetCullDistanceBand"),
            player_character_that_dropped_item = read_method_value(actor, "GetPlayerCharacterThatDroppedItem"),
        },
        components = components,
    }
end

local function json_escape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
         :gsub("\"", "\\\"")
         :gsub("\b", "\\b")
         :gsub("\f", "\\f")
         :gsub("\n", "\\n")
         :gsub("\r", "\\r")
         :gsub("\t", "\\t")
    return '"' .. s .. '"'
end

local function is_array_table(t)
    local max_i, count = 0, 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        if k > max_i then max_i = k end
        count = count + 1
    end
    return max_i == count
end

local function json_value(v)
    local tv = type(v)
    if tv == "nil" then return "null" end
    if tv == "boolean" then return v and "true" or "false" end
    if tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return string.format("%.6f", v):gsub("0+$", ""):gsub("%.$", "")
    end
    if tv == "string" then return json_escape(v) end
    if tv ~= "table" then return json_escape(tostring(v)) end
    local parts = {}
    if is_array_table(v) then
        for i = 1, #v do parts[#parts + 1] = json_value(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k, _ in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = json_escape(k) .. ":" .. json_value(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function write_runtime_item_report(file_stem, report, lines)
    local dir = mod_paths.ipc_dir()
    if not dir then return false, "ipc dir unavailable" end
    pcall(os.execute, ('if not exist "%s" mkdir "%s"'):format(dir, dir))
    local json_path = dir .. "\\" .. file_stem .. ".json"
    local text_path = dir .. "\\" .. file_stem .. ".txt"
    local ok_json, json_result = mod_paths.write_atomic(json_path, json_value(report))
    if not ok_json then return false, json_result end
    local ok_text, text_result = mod_paths.write_atomic(text_path, table.concat(lines, "\n") .. "\n")
    if not ok_text then return false, text_result end
    return true, json_path .. " ; " .. text_path
end

local function bool_text(v)
    if type(v) == "boolean" then return v and "true" or "false" end
    if v == nil then return "<nil>" end
    return tostring(v)
end

local function append_snapshot_lines(lines, snap)
    if type(snap) ~= "table" then return end
    local actor = snap.actor or {}
    local fields = snap.fields or {}
    lines[#lines + 1] = string.format("%s: %s", tostring(snap.note or "snapshot"), tostring(actor.name or "<unnamed>"))
    lines[#lines + 1] = string.format("  class=%s", tostring(actor.class or "<unknown>"))
    lines[#lines + 1] = string.format("  runtime=%s can_expire=%s dropper=%s guid=%s",
        bool_text(fields.bRegisterAsRuntimeSpawned),
        bool_text(fields.bCanExpire),
        tostring(fields.NameOfPlayerCharacterThatDroppedItem or ""),
        tostring(fields.GuidOfPlayerCharacterThatDroppedItem or ""))
    for _, comp in ipairs(snap.components or {}) do
        lines[#lines + 1] = string.format("  component %-28s sim=%s gravity=%s collision=%s launched=%s",
            tostring(comp.label or "?"),
            bool_text(comp.simulating_physics),
            bool_text(comp.gravity_enabled),
            tostring(comp.collision_enabled or "<nil>"),
            bool_text(comp.launch_is_launched))
        if comp.b_launched ~= nil or comp.b_just_launched ~= nil or comp.active ~= nil
            or comp.b_visible ~= nil or comp.b_hidden_in_game ~= nil then
            lines[#lines + 1] = string.format("    active=%s auto=%s bLaunched=%s bJustLaunched=%s visible=%s hidden=%s tick=%s",
                bool_text(comp.active),
                bool_text(comp.b_auto_activate),
                bool_text(comp.b_launched),
                bool_text(comp.b_just_launched),
                bool_text(comp.b_visible),
                bool_text(comp.b_hidden_in_game),
                bool_text(comp.component_tick_enabled))
        end
    end
end

local function resolve_runtime_item_target(args_str, default_lastspawned)
    local raw = tostring(args_str or ""):gsub("%s+[cC][oO][nN][fF][iI][rR][mM]%s*$", "")
    raw = raw:match("^%s*(.-)%s*$") or ""
    if raw == "" and default_lastspawned then raw = "lastspawned" end

    local actor, err
    if raw == "" or raw:lower() == "lastspawned" or raw:lower() == "latest" then
        actor, err = feature_field.resolve_root("lastspawned")
        if not is_valid(actor) then
            return nil, "no lastspawned runtime item: " .. tostring(err)
        end
    else
        actor = feature_actor.resolve_actor_by_name(raw)
        if not is_valid(actor) then
            return nil, "actor not found: " .. raw
        end
    end
    if not is_runtime_world_item(actor) then
        return nil, "target is not BP_RuntimeSpawnedWorldItem: " .. tostring(actor_short_name(actor) or raw)
    end
    return actor, raw
end

local function apply_runtime_item_stabilize(actor)
    if not is_runtime_world_item(actor) then
        return { ok = false, error = "not runtime world item" }
    end

    local result = {
        ok = true,
        actor = actor_short_name(actor),
        actions = {},
        failures = {},
    }
    local function action(label, fn, required)
        local ok, err = pcall(fn)
        if ok and err ~= false then
            result.actions[#result.actions + 1] = label
        else
            result.failures[#result.failures + 1] = label .. ": " .. tostring(err)
            if required then
                result.ok = false
                result.error = (result.error and result.error .. "; " or "") .. label .. " failed"
            end
        end
    end
    local function required_bool(field, value, object, label)
        object, label = object or actor, label or "actor"
        action(label .. "." .. field .. "=" .. tostring(value), function()
            if type(object[field]) ~= "boolean" then error("unsupported boolean field " .. field) end
            object[field] = value
            return object[field] == value
        end, true)
    end
    local function class_has(comp, needle)
        local class_name = object_class_name(comp)
        return type(class_name) == "string"
            and class_name:lower():find(tostring(needle or ""):lower(), 1, true) ~= nil
    end
    local function is_primitiveish(comp)
        return class_has(comp, "StaticMeshComponent")
            or class_has(comp, "BoxComponent")
            or class_has(comp, "NiagaraComponent")
    end

    required_bool("bRegisterAsRuntimeSpawned", true)
    -- 1.0 expiration is opt-in; preserve the saved duration rather than forging end ticks.
    required_bool("bCanExpire", false)
    required_bool("bExpireEvenIfDroppedAndNoAutoMagnetize", false)
    action("actor.NameOfPlayerCharacterThatDroppedItem=''", function()
        actor.NameOfPlayerCharacterThatDroppedItem = ""
    end)

    local zero = { X = 0.0, Y = 0.0, Z = 0.0 }
    local bone = none_bone_name()
    local physics_components = 0
    for _, entry in ipairs(get_runtime_item_components(actor)) do
        local comp = entry.ref
        local label = tostring(entry.label or "component")
        if is_valid(comp) and comp.SetComponentTickEnabled
            and (class_has(comp, "LaunchableComponent")
                or class_has(comp, "MagneticComponent_GrantItem")
                or class_has(comp, "NiagaraComponent")) then
            action(label .. ".SetComponentTickEnabled(false)", function() comp:SetComponentTickEnabled(false) end)
        end

        if is_valid(comp) and class_has(comp, "LaunchableComponent") then
            required_bool("bLaunched", false, comp, label)
            action(label .. ".bJustLaunched=false", function() comp.bJustLaunched = false end)
            action(label .. ".bAutoActivate=false", function() comp.bAutoActivate = false end)
            action(label .. ".bIsActive=false", function() comp.bIsActive = false end)
            if comp.PauseLaunch then
                action(label .. ".PauseLaunch", function() comp:PauseLaunch() end)
            end
            if comp.SetActive then
                action(label .. ".SetActive(false,false)", function() comp:SetActive(false, false) end)
            end
            if comp.Deactivate then
                action(label .. ".Deactivate", function() comp:Deactivate() end)
            end
        end

        if is_valid(comp) and class_has(comp, "MagneticComponent_GrantItem") then
            required_bool("bAllowAutoMagnetization", false, comp, label)
            required_bool("bAutoMagnetizationEnabled", false, comp, label)
            action(label .. ".bAutoActivate=false", function() comp.bAutoActivate = false end)
            if comp.SetActive then
                action(label .. ".SetActive(false,false)", function() comp:SetActive(false, false) end)
            end
            if comp.Deactivate then
                action(label .. ".Deactivate", function() comp:Deactivate() end)
            end
        end

        if is_valid(comp) and class_has(comp, "NiagaraComponent") then
            action(label .. ".bAutoActivate=false", function() comp.bAutoActivate = false end)
            action(label .. ".bIsActive=false", function() comp.bIsActive = false end)
            action(label .. ".bVisible=false", function() comp.bVisible = false end)
            action(label .. ".bHiddenInGame=true", function() comp.bHiddenInGame = true end)
            if comp.SetAutoActivate then
                action(label .. ".SetAutoActivate(false)", function() comp:SetAutoActivate(false) end)
            end
            if comp.SetActive then
                action(label .. ".SetActive(false,false)", function() comp:SetActive(false, false) end)
            end
            if comp.Deactivate then
                action(label .. ".Deactivate", function() comp:Deactivate() end)
            end
            if comp.SetVisibility then
                action(label .. ".SetVisibility(false,true)", function() comp:SetVisibility(false, true) end)
            end
            if comp.SetHiddenInGame then
                action(label .. ".SetHiddenInGame(true,true)", function() comp:SetHiddenInGame(true, true) end)
            end
        end

        if is_valid(comp) and is_primitiveish(comp) and comp.SetMobility then
            action(label .. ".SetMobility(Movable)", function() comp:SetMobility("EComponentMobility::Movable") end)
            action(label .. ".SetMobility(2)", function() comp:SetMobility(2) end)
        end
        if is_valid(comp) and is_primitiveish(comp) and comp.SetAllPhysicsLinearVelocity then
            action(label .. ".SetAllPhysicsLinearVelocity(0)", function() comp:SetAllPhysicsLinearVelocity(zero, false) end)
        end
        if is_valid(comp) and is_primitiveish(comp) and comp.SetAllPhysicsAngularVelocityInDegrees then
            action(label .. ".SetAllPhysicsAngularVelocityInDegrees(0)", function()
                comp:SetAllPhysicsAngularVelocityInDegrees(zero, false)
            end)
        end
        if is_valid(comp) and is_primitiveish(comp) and not class_has(comp, "NiagaraComponent") then
            physics_components = physics_components + 1
            action(label .. ".SetSimulatePhysics(false)", function() comp:SetSimulatePhysics(false) end, true)
            action(label .. ".SetEnableGravity(false)", function() comp:SetEnableGravity(false) end, true)
        end
        if is_valid(comp) and is_primitiveish(comp) and comp.PutRigidBodyToSleep then
            action(label .. ".PutRigidBodyToSleep", function() comp:PutRigidBodyToSleep(bone) end)
        end
    end
    action("physics component resolved", function() return physics_components > 0 end, true)
    return result
end

function M.stabilize_runtime_world_item(actor)
    local before = runtime_item_snapshot(actor, "before")
    local result = apply_runtime_item_stabilize(actor)
    local after = runtime_item_snapshot(actor, "after")
    return result.ok == true, result, before, after
end

function M.stabilize_runtime_world_item_fast(actor)
    local result = apply_runtime_item_stabilize(actor)
    return result.ok == true, result
end

function M.runtime_snapshot(args_str)
    local actor, target = resolve_runtime_item_target(args_str, true)
    if not actor then return false, target end
    local snap = runtime_item_snapshot(actor, "snapshot")
    local lines = {
        "world.items.runtime.snapshot",
        "target=" .. tostring(target),
    }
    append_snapshot_lines(lines, snap)
    local report = {
        ok = true,
        command = "world.items.runtime.snapshot",
        target = target,
        snapshot = snap,
    }
    local ok_write, write_detail = write_runtime_item_report("world_items_runtime_snapshot", report, lines)
    if not ok_write then return false, write_detail end
    return true, "wrote " .. write_detail
end

function M.runtime_stabilize(args_str)
    local actor, target = resolve_runtime_item_target(args_str, true)
    if not actor then return false, target end
    local before = runtime_item_snapshot(actor, "before")
    local result = apply_runtime_item_stabilize(actor)
    local after = runtime_item_snapshot(actor, "after")
    local lines = {
        "world.items.runtime.stabilize",
        "target=" .. tostring(target),
        "actions=" .. tostring(#(result.actions or {})) .. " failures=" .. tostring(#(result.failures or {})),
    }
    append_snapshot_lines(lines, before)
    append_snapshot_lines(lines, after)
    for _, failure in ipairs(result.failures or {}) do
        lines[#lines + 1] = "failure: " .. tostring(failure)
    end
    local report = {
        ok = result.ok == true,
        command = "world.items.runtime.stabilize",
        target = target,
        result = result,
        before = before,
        after = after,
    }
    local ok_write, write_detail = write_runtime_item_report("world_items_runtime_stabilize", report, lines)
    if not ok_write then return false, write_detail end
    if result.ok ~= true then return false, tostring(result.error or "stabilize failed") end
    return true, string.format("actions=%d failures=%d wrote %s",
        #(result.actions or {}), #(result.failures or {}), write_detail)
end

local function get_pawn()
    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return nil, "no local pawn" end
    return pawn
end

local function get_pc()
    local pawn, err = get_pawn()
    if not pawn then return nil, err end
    local ok, pc = pcall(function() return pawn:GetController() end)
    if ok and is_valid(pc) then return pc end
    ok, pc = pcall(function() return pawn.Controller end)
    if ok and is_valid(pc) then return pc end
    return nil, "no player controller"
end

-- Resolve a component on the player controller. Tries the BP wrapper
-- first (e.g. BP_Components_PersonalInventory) and falls back to the
-- native parent (PersonalInventoryComponent) so the verbs still work
-- on stripped builds where the BP wrapper isn't present.
local function get_component(field_candidates)
    local pc, err = get_pc()
    if not pc then return nil, err end
    for _, name in ipairs(field_candidates) do
        local ok, v = pcall(function() return pc[name] end)
        if ok and is_valid(v) then return v end
    end
    return nil, "no component (" .. table.concat(field_candidates, " / ") .. ") on PC"
end

-- ---------------------------------------------------------------------------
-- AssetRegistry helpers + per-class lookup cache.
-- ---------------------------------------------------------------------------

-- UE4SS wraps reflected TArray<TStruct> elements in LocalUnrealParam ;
-- one or two :get() calls peel back to the real userdata. Without this
-- `entry.PackageName` returns a wrapper whose own fields are nil and the
-- whole sweep silently produces zero records. Mirrors feature_assets.unwrap_param.
function unwrap_param(v)
    if type(v) ~= "userdata" then return v end
    for _ = 1, 2 do
        local has_get = false
        pcall(function() has_get = (type(v.get) == "function") end)
        if not has_get then return v end
        local ok, inner = pcall(function() return v:get() end)
        if not ok or inner == nil then return v end
        v = inner
        if type(v) ~= "userdata" then return v end
    end
    return v
end

local function fname_to_string(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    if type(v) == "userdata" then
        -- Peel LocalUnrealParam wrappers first.
        for _ = 1, 2 do
            if type(v) == "userdata" then
                local has_get = false
                pcall(function() has_get = (type(v.get) == "function") end)
                if has_get then
                    local ok, inner = pcall(function() return v:get() end)
                    if ok and inner ~= nil then v = inner else break end
                else
                    break
                end
            else
                break
            end
        end
        if type(v) == "string" then return v end
        if type(v) == "userdata" then
            for _, m in ipairs({ "ToString", "GetName", "GetPlainNameString" }) do
                local ok, s = pcall(function() return v[m](v) end)
                if ok and type(s) == "string" and s ~= "" then return s end
            end
        end
    end
    return nil
end

local function resolve_registry()
    if not StaticFindObject then return nil, nil, "StaticFindObject unavailable" end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not is_valid(helpers) then return nil, nil, "UAssetRegistryHelpers CDO not found" end
    local ok, reg = pcall(function() return helpers:GetAssetRegistry() end)
    if not ok or not is_valid(reg) then return nil, helpers, "GetAssetRegistry failed" end
    return reg, helpers, nil
end

-- per-class cache of asset_name -> package_name (e.g. "ITEM_Foo" -> "/Game/.../ITEM_Foo")
local _name_lookup = {}     -- [class_name] = { asset_name = package_name }
local _name_lookup_ci = {}  -- [class_name] = { lower(asset_name) = package_name }
local _swept = {}           -- [class_name] = true (already swept once this session)

local function build_lookup(class_name)
    -- class_name e.g. "ItemData" or "RecipeData" (native /Script/Dominion class).
    local registry, _helpers, rerr = resolve_registry()
    if not registry then return nil, nil, rerr end
    local class_path = { PackageName = FName("/Script/Dominion"), AssetName = FName(class_name) }
    local out = {}
    local ok, err = pcall(function()
        registry:GetAssetsByClass(class_path, out, true)
    end)
    if not ok then return nil, nil, "GetAssetsByClass failed: " .. tostring(err) end
    local n = 0
    pcall(function() n = #out end)
    local lut, lut_ci = {}, {}
    local count = 0
    for i = 1, n do
        local entry = unwrap_param(out[i])
        local pkg, name
        if entry then
            pcall(function() pkg = fname_to_string(entry.PackageName) end)
            pcall(function() name = fname_to_string(entry.AssetName) end)
        end
        if pkg and name and name ~= "" then
            lut[name] = pkg
            local low = name:lower()
            lut_ci[low] = pkg
            -- Tail key: drop the leading prefix segment so the website's
            -- internal_name (e.g. "spell_axtralprojection") can match the
            -- cooked asset ("USD_AxtralProjection"). Only set when not
            -- already taken so a literal hit always wins over a tail hit.
            local tail = low:match("^[%w]+_(.+)$")
            if tail and not lut_ci[tail] then
                lut_ci[tail] = pkg
            end
            count = count + 1
        end
    end
    print(string.format("[RSDWTools] inventory: AssetRegistry sweep %s -> %d entries",
        class_name, count))
    return lut, lut_ci, nil
end

-- Resolve a short asset name to a live UObject (DataAsset). Returns
-- (obj, err). The class_name argument is the native AR class to seed
-- the sweep cache from (e.g. "ItemData" or "RecipeData").
local function resolve_asset(short_name, class_name)
    if type(short_name) ~= "string" or short_name == "" then
        return nil, "empty asset name"
    end

    -- Phase 1: cheap FindFirstOf if the asset is already in memory.
    if FindFirstOf then
        local ok, obj = pcall(FindFirstOf, short_name)
        if ok and type(obj) == "userdata" and is_valid(obj) then
            local fn
            pcall(function() fn = obj:GetFullName() end)
            -- Skip Default__ CDOs ; the asset object itself is what we want.
            if type(fn) ~= "string" or not fn:find("Default__", 1, true) then
                return obj, nil
            end
        end
    end

    -- Phase 2: AssetRegistry lookup (build cache on first miss).
    local lut = _name_lookup[class_name]
    if not lut then
        local built, built_ci, berr = build_lookup(class_name)
        if not built then return nil, berr end
        _name_lookup[class_name] = built
        _name_lookup_ci[class_name] = built_ci
        _swept[class_name] = true
        lut = built
    end

    local pkg = lut[short_name]
    if not pkg then
        -- Case-insensitive try (website internal_name is often lowercased
        -- e.g. "spell_accesspersonalchest" while the cooked asset is
        -- PascalCase "USD_AccessPersonalChest"). build_lookup also indexes
        -- the tail-after-first-underscore so prefix mismatches still resolve.
        local lut_ci = _name_lookup_ci[class_name]
        if lut_ci then
            local low = short_name:lower()
            pkg = lut_ci[low]
            if not pkg then
                local tail = low:match("^[%w]+_(.+)$")
                if tail then pkg = lut_ci[tail] end
            end
        end
    end
    if not pkg then
        -- Force one rebuild in case the asset just loaded (plugin etc).
        if _swept[class_name] then
            _swept[class_name] = false
            local rebuilt, rebuilt_ci = build_lookup(class_name)
            if rebuilt then
                _name_lookup[class_name] = rebuilt
                _name_lookup_ci[class_name] = rebuilt_ci
                _swept[class_name] = true
                pkg = rebuilt[short_name]
                if not pkg and rebuilt_ci then
                    local low = short_name:lower()
                    pkg = rebuilt_ci[low]
                    if not pkg then
                        local tail = low:match("^[%w]+_(.+)$")
                        if tail then pkg = rebuilt_ci[tail] end
                    end
                end
            end
        end
        if not pkg then
            return nil, "asset not found in registry: " .. short_name
        end
    end

    -- Phase 3: ensure loaded + materialise.
    if LoadAsset then pcall(LoadAsset, pkg) end
    -- The case-insensitive path may have given us a pkg whose leaf is
    -- the canonical case (e.g. Spell_AccessPersonalChest). Recover the
    -- canonical leaf from the package path itself so StaticFindObject
    -- gets the matching object_path.
    local canonical = pkg:match("([^/]+)$") or short_name
    local obj_path = pkg .. "." .. canonical
    if not StaticFindObject then return nil, "StaticFindObject unavailable" end
    local ok, obj = pcall(StaticFindObject, obj_path)
    if not ok or not is_valid(obj) then
        return nil, "StaticFindObject failed for " .. obj_path
    end
    return obj, nil
end

-- ---------------------------------------------------------------------------
-- world.items.give <ITEM_AssetName> [count]
-- ---------------------------------------------------------------------------
function M.give(args_str)
    local raw = tostring(args_str or ""):match("^%s*(.-)%s*$")
    if raw == "" then
        return false, "usage: world.items.give <ITEM_AssetName> [count]"
    end
    -- First whitespace-delimited token is the asset name ; the rest
    -- (if numeric) is the count. We do not split on dots because asset
    -- short names may legitimately contain underscores but never dots.
    local name, count_str = raw:match("^(%S+)%s*(.*)$")
    local count = tonumber(count_str)
    if not count then count = 1 end
    if count < 1 then count = 1 end
    if count > 9999 then count = 9999 end

    local item, ierr = resolve_asset(name, "ItemData")
    if not item then return false, ierr end

    local inv, cerr = get_component({ "BP_Components_PersonalInventory", "PersonalInventoryComponent" })
    if not inv then return false, cerr end

    -- We previously tried AddItemByData first and only fell back to
    -- DropItemByData when it returned false. In practice AddItemByData
    -- has a long list of silent-reject conditions (no compatible slot
    -- category yet, weight cap, slot lock, etc.) and on a fresh
    -- character it just never accepts anything. DropItemByData is the
    -- same path the game's own "drop from inventory" UI uses ; it
    -- spawns AWorldItem actors at the supplied transform that the
    -- player picks up immediately. Use it as the primary path.
    -- Header: bool DropItemByData(UItemData*, FTransform, int32, TSet<AWorldItem*>&).
    if not inv.DropItemByData then
        return false, "DropItemByData missing on inventory component"
    end

    local pawn = feature_actor.get_local_pawn()
    local loc
    if is_valid(pawn) then
        local ok_loc, v = pcall(function() return pawn:K2_GetActorLocation() end)
        if ok_loc and v then loc = v end
        if not loc then
            local ok_loc2, v2 = pcall(function() return pawn:GetActorLocation() end)
            if ok_loc2 and v2 then loc = v2 end
        end
    end
    if not loc then
        return false, "could not get pawn location to drop item"
    end

    local xform = {
        Rotation    = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Scale3D     = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
    local before_names = collect_runtime_world_item_names_near(loc, 750.0)
    local out_set = {}
    local ret, ret_out
    local ok, err = pcall(function()
        ret, ret_out = inv:DropItemByData(item, xform, count, out_set)
    end)
    if not ok then return false, "DropItemByData errored: " .. tostring(err) end
    if ret == false then
        return false, string.format("DropItemByData refused %s", name)
    end
    local spawned_actor = first_actor_from_world_item_set(out_set, ret_out)
        or find_new_runtime_world_item_near(loc, before_names, 750.0)
    local spawned_name = remember_last_spawned_world_item(spawned_actor)
    local suffix = spawned_name and (" lastspawned=" .. spawned_name) or ""
    print(string.format("[RSDWTools] items.give %s x%d -> dropped%s", name, count, suffix))
    return true, string.format("%s x%d (dropped)%s", name, count, suffix)
end

-- ---------------------------------------------------------------------------
-- world.recipes.unlock <RECIPE_AssetName>
--
-- Wraps a single recipe in a one-element TArray<URecipeData> for the
-- BP UnlockRecipes(TArray) signature. Bulk callers should issue the
-- verb once per recipe ; the PIE round-trip is cheap and per-call
-- console feedback is more useful than batching.
-- ---------------------------------------------------------------------------
function M.unlock_recipe(args_str)
    local name = tostring(args_str or ""):match("^%s*(.-)%s*$")
    if name == "" then
        return false, "usage: world.recipes.unlock <RECIPE_AssetName>"
    end

    local recipe, rerr = resolve_asset(name, "RecipeData")
    if not recipe then return false, rerr end

    local prog, cerr = get_component({ "BP_Components_Progress", "ProgressComponent" })
    if not prog then return false, cerr end

    if not prog.UnlockRecipes and not prog["UnlockRecipes"] then
        return false, "UnlockRecipes not on progress component"
    end

    local arr = { recipe }
    local ok, err = pcall(function() prog:UnlockRecipes(arr) end)
    if not ok then return false, "UnlockRecipes errored: " .. tostring(err) end
    print(string.format("[RSDWTools] recipes.unlock %s -> ok", name))
    return true, name
end

-- ---------------------------------------------------------------------------
-- world.buildings.unlock_all
--
-- Bulk variant of unlock_recipe for UBuildingPieceData. Sweeps the
-- AssetRegistry for every BuildingPieceData (subclasses included),
-- materialises each via LoadAsset + StaticFindObject, then calls
-- progress:UnlockBuildings(arr) once with the full list.
--
-- Header: void UnlockBuildings(const TArray<UBuildingPieceData*>&)
-- Same shape as UnlockRecipes ; same OnRep_BuildingsUnlocked delegate
-- on the client side. Replicated, so a single call updates the full
-- BuildingsUnlocked TArray on the player's progress component.
-- ---------------------------------------------------------------------------
function M.unlock_all_buildings(_args_str)
    local prog, cerr = get_component({ "BP_Components_Progress", "ProgressComponent" })
    if not prog then return false, cerr end
    if not prog.UnlockBuildings and not prog["UnlockBuildings"] then
        return false, "UnlockBuildings not on progress component"
    end

    -- Reuse the lookup cache that resolve_asset builds, but force a
    -- fresh sweep so a freshly-loaded plugin's pieces are picked up.
    local lut, lut_ci, berr = build_lookup("BuildingPieceData")
    if not lut then return false, berr end
    _name_lookup["BuildingPieceData"] = lut
    _name_lookup_ci["BuildingPieceData"] = lut_ci
    _swept["BuildingPieceData"] = true

    local arr = {}
    local materialised, missed = 0, 0
    for short_name, pkg in pairs(lut) do
        if LoadAsset then pcall(LoadAsset, pkg) end
        local obj_path = pkg .. "." .. short_name
        local ok, obj = pcall(StaticFindObject, obj_path)
        if ok and is_valid(obj) then
            arr[#arr + 1] = obj
            materialised = materialised + 1
        else
            missed = missed + 1
        end
    end

    if materialised == 0 then
        return false, "no BuildingPieceData assets resolved"
    end

    local ok, err = pcall(function() prog:UnlockBuildings(arr) end)
    if not ok then return false, "UnlockBuildings errored: " .. tostring(err) end

    print(string.format("[RSDWTools] buildings.unlock_all -> %d unlocked, %d unresolved",
        materialised, missed))
    return true, string.format("unlocked=%d unresolved=%d", materialised, missed)
end

-- ---------------------------------------------------------------------------
-- world.spells.unlock <SpellAssetName>
--
-- Mirrors unlock_recipe but for UUtilitySpellData. The website's
-- spells.json uses lowercased internal_names (e.g. "spell_axtralprojection")
-- ; resolve_asset's case-insensitive fallback handles the case difference
-- against the cooked asset (e.g. "Spell_AxtralProjection").
--
-- Header: void UnlockSpells(const TArray<UUtilitySpellData*>&)
-- ---------------------------------------------------------------------------
function M.unlock_spell(args_str)
    local name = tostring(args_str or ""):match("^%s*(.-)%s*$")
    if name == "" then
        return false, "usage: world.spells.unlock <SpellAssetName>"
    end

    local spell, serr = resolve_asset(name, "UtilitySpellData")
    if not spell then return false, serr end

    local prog, cerr = get_component({ "BP_Components_Progress", "ProgressComponent" })
    if not prog then return false, cerr end
    if not prog.UnlockSpells and not prog["UnlockSpells"] then
        return false, "UnlockSpells not on progress component"
    end

    local arr = { spell }
    local ok, err = pcall(function() prog:UnlockSpells(arr) end)
    if not ok then return false, "UnlockSpells errored: " .. tostring(err) end
    print(string.format("[RSDWTools] spells.unlock %s -> ok", name))
    return true, name
end

-- ---------------------------------------------------------------------------
-- world.spells.unlock_all
--
-- Bulk variant of unlock_spell. Sweeps every UUtilitySpellData visible
-- to the AssetRegistry, materialises each, then calls UnlockSpells once.
-- ---------------------------------------------------------------------------
function M.unlock_all_spells(_args_str)
    local prog, cerr = get_component({ "BP_Components_Progress", "ProgressComponent" })
    if not prog then return false, cerr end
    if not prog.UnlockSpells and not prog["UnlockSpells"] then
        return false, "UnlockSpells not on progress component"
    end

    local lut, lut_ci, berr = build_lookup("UtilitySpellData")
    if not lut then return false, berr end
    _name_lookup["UtilitySpellData"] = lut
    _name_lookup_ci["UtilitySpellData"] = lut_ci
    _swept["UtilitySpellData"] = true

    local arr = {}
    local materialised, missed = 0, 0
    for short_name, pkg in pairs(lut) do
        if LoadAsset then pcall(LoadAsset, pkg) end
        local obj_path = pkg .. "." .. short_name
        local ok, obj = pcall(StaticFindObject, obj_path)
        if ok and is_valid(obj) then
            arr[#arr + 1] = obj
            materialised = materialised + 1
        else
            missed = missed + 1
        end
    end

    if materialised == 0 then
        return false, "no UtilitySpellData assets resolved"
    end

    local ok, err = pcall(function() prog:UnlockSpells(arr) end)
    if not ok then return false, "UnlockSpells errored: " .. tostring(err) end

    print(string.format("[RSDWTools] spells.unlock_all -> %d unlocked, %d unresolved",
        materialised, missed))
    return true, string.format("unlocked=%d unresolved=%d", materialised, missed)
end

-- Internal helpers promoted for Build Service capture/replay. They stay
-- underscore-prefixed because they are not public console verbs.
M._is_runtime_world_item = is_runtime_world_item
M._enumerate_runtime_world_items = enumerate_runtime_world_items

return M
