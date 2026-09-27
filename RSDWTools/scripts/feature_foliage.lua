-- feature_foliage.lua
-- Developer-facing foliage scan/conversion verbs. These stay conservative by
-- default because instance-foliage mutation can touch a lot of world state.

local M = {}

local feature_actor = require("feature_actor")
local feature_grab = require("feature_grab")
local feature_net = require("feature_net")
local mod_paths = require("mod_paths")
local safety = require("safety")

local SCAN_FILE = "foliage_scan.json"
local ACTION_FILE = "foliage_actions.json"

local DEFAULT_NEAR_RADIUS = 5000.0
local DEFAULT_SCAN_LIMIT = 250
local MAX_SCAN_LIMIT = 2500
local DEFAULT_ACTION_LIMIT = 1
local MAX_ACTION_LIMIT = 25
local DEFAULT_FOREST_LIMIT = 25
local MAX_FOREST_LIMIT = 250
local DEFAULT_CONVERT_DISTANCE = 125.0
local DEFAULT_SINGLE_CONVERT_DISTANCE = 1.0
local TREE_LOOKUP_RADIUS_AFTER_CONVERT = 325.0
local SINGLE_LOOKAT_PICK_RADIUS = 250.0
local SINGLE_TREE_PICK_RADIUS = 900.0
local SINGLE_TREE_PICK_MAX_XY_RADIUS = 350.0
local LAST_CONVERTED_CAP = 32
local TREE_FAMILY_CATEGORY = "tree_family"

local COMPONENT_CLASS_DEFS = {
    { name = "BP_InteractableFoliageISMC_Tree_C",    category = "tree" },
    { name = "BP_InteractableFoliageISMC_Sapling_C", category = "sapling" },
    { name = "BP_InteractableFoliageISMC_PickUps_C", category = "pickup" },
    { name = "BP_InteractableFoliageISMC_OreNode_C", category = "ore" },
    { name = "InteractableFoliageISMComponent",      category = nil },
}

local RESOURCE_ACTOR_CLASS_DEFS = {
    { name = "FellableTree", category = "tree" },
    { name = "SaplingBase",  category = "sapling" },
}

local LAST_CONVERTED_TARGETS = {}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_words(s)
    local out = {}
    for w in tostring(s or ""):gmatch("%S+") do
        out[#out + 1] = w
    end
    return out
end

local function clamp_number(n, min_v, max_v)
    n = tonumber(n)
    if n == nil then return nil end
    if n < min_v then n = min_v end
    if n > max_v then n = max_v end
    return n
end

local function clamp_int(n, min_v, max_v)
    n = clamp_number(n, min_v, max_v)
    if n == nil then return nil end
    return math.floor(n)
end

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function class_name(obj)
    local safe_name = safety.class_name_of(obj)
    if safe_name then return safe_name end
    local ok, full = pcall(function() return obj:GetFullName() end)
    if ok and type(full) == "string" and full ~= "" then
        local first = full:match("^(%S+)")
        if first and first ~= "" then return first end
    end
    return "UnknownClass"
end

local function short_name_from_full(full)
    if type(full) ~= "string" or full == "" then return nil end
    local after_dot = full:match("%.([^%.%s]+)$")
    if after_dot and after_dot ~= "" then return after_dot end
    local tail = full:match("([^%s]+)$") or full
    return tail ~= "" and tail or nil
end

local function object_short_name(obj)
    if not is_valid(obj) then return nil end
    local ok, n = pcall(function() return obj:GetName() end)
    if ok and type(n) == "string" and n ~= "" then return n end
    local ok_full, full = pcall(function() return obj:GetFullName() end)
    if ok_full then return short_name_from_full(full) end
    return nil
end

local function object_full_name(obj)
    if not is_valid(obj) then return nil end
    local ok, n = pcall(function() return obj:GetFullName() end)
    if ok and type(n) == "string" and n ~= "" then return n end
    return nil
end

local function object_identity_text(obj)
    return string.lower(table.concat({
        tostring(class_name(obj) or ""),
        tostring(object_short_name(obj) or ""),
        tostring(object_full_name(obj) or ""),
    }, " "))
end

local function is_foliage_container_actor(actor)
    if not is_valid(actor) then return false end
    local text = object_identity_text(actor)
    return text:find("instancedfoliageactor", 1, true) ~= nil
        or text:find("instanced_foliage_actor", 1, true) ~= nil
end

local function is_cdo(obj)
    local full = object_full_name(obj)
    return type(full) == "string" and full:find("Default__", 1, true) ~= nil
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

local function component_location(comp)
    if not is_valid(comp) then return nil end
    if comp.K2_GetComponentLocation then
        local ok, loc = pcall(function() return comp:K2_GetComponentLocation() end)
        if ok and loc then return loc end
    end
    local owner = nil
    if comp.GetOwner then
        pcall(function() owner = comp:GetOwner() end)
    end
    return actor_location(owner)
end

local function pawn_location()
    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return nil end
    return actor_location(pawn)
end

local function world_context()
    local pawn = feature_actor.get_local_pawn()
    if is_valid(pawn) then return pawn, pawn end
    local pc = feature_net.local_controller()
    if is_valid(pc) then return pc, nil end
    return nil, nil
end

local function dist_sq(a, b)
    if not a or not b then return math.huge end
    local dx = (tonumber(a.X) or 0) - (tonumber(b.X) or 0)
    local dy = (tonumber(a.Y) or 0) - (tonumber(b.Y) or 0)
    local dz = (tonumber(a.Z) or 0) - (tonumber(b.Z) or 0)
    return dx * dx + dy * dy + dz * dz
end

local function dist_sq_xy(a, b)
    if not a or not b then return math.huge end
    local dx = (tonumber(a.X) or 0) - (tonumber(b.X) or 0)
    local dy = (tonumber(a.Y) or 0) - (tonumber(b.Y) or 0)
    return dx * dx + dy * dy
end

local function vec_copy(v)
    if not v then return nil end
    local x, y, z = tonumber(v.X), tonumber(v.Y), tonumber(v.Z)
    if x == nil or y == nil or z == nil then return nil end
    return { X = x, Y = y, Z = z }
end

local function transform_location(xform)
    if type(xform) == "table" then
        return vec_copy(xform.Translation) or vec_copy(xform.Location) or vec_copy(xform.Position)
    end
    if type(xform) == "userdata" then
        if xform.GetLocation then
            local ok, loc = pcall(function() return xform:GetLocation() end)
            if ok then return vec_copy(loc) end
        end
        local loc = nil
        pcall(function() loc = xform.Translation end)
        return vec_copy(loc)
    end
    return nil
end

local function json_string(s)
    local escaped = tostring(s or "")
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
    return '"' .. escaped .. '"'
end

local function json_num(n)
    n = tonumber(n)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return "null" end
    return string.format("%.6g", n)
end

local function json_bool(v)
    return v and "true" or "false"
end

local function json_value(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "number" then return json_num(v) end
    if t == "boolean" then return json_bool(v) end
    return json_string(v)
end

local function json_kv(key, value)
    return json_string(key) .. ":" .. json_value(value)
end

local function encode_vec_fields(loc)
    if not loc then return "" end
    return ',"x":' .. json_num(loc.X) .. ',"y":' .. json_num(loc.Y) .. ',"z":' .. json_num(loc.Z)
end

local function encode_counts(counts)
    local parts = {}
    local keys = { "tree", "sapling", "pickup", "ore", "unknown" }
    for _, key in ipairs(keys) do
        parts[#parts + 1] = json_string(key) .. ":" .. tostring(counts[key] or 0)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function encode_component(entry)
    local parts = {
        json_kv("class", entry.class),
        json_kv("category", entry.category),
        json_kv("name", entry.name),
        json_kv("full_name", entry.full_name),
        json_kv("owner", entry.owner),
        json_kv("mesh", entry.mesh),
        json_kv("foliage_type", entry.foliage_type),
        json_kv("instance_count", entry.instance_count),
        json_kv("near_count", entry.near_count)
    }
    if entry.distance then parts[#parts + 1] = json_kv("distance", entry.distance) end
    local loc = entry.location
    return "{" .. table.concat(parts, ",") .. encode_vec_fields(loc) .. "}"
end

local function encode_instance(entry)
    local parts = {
        json_kv("component_index", entry.component_index),
        json_kv("instance_index", entry.instance_index),
        json_kv("class", entry.class),
        json_kv("category", entry.category),
        json_kv("owner", entry.owner),
        json_kv("mesh", entry.mesh),
        json_kv("distance", entry.distance)
    }
    return "{" .. table.concat(parts, ",") .. encode_vec_fields(entry.location) .. "}"
end

local function encode_result(entry)
    local parts = {}
    for key, value in pairs(entry) do
        if key ~= "location" then
            parts[#parts + 1] = json_kv(key, value)
        end
    end
    return "{" .. table.concat(parts, ",") .. encode_vec_fields(entry.location) .. "}"
end

local function encode_map(entries, encode_entry)
    local parts = {}
    for i, entry in ipairs(entries or {}) do
        parts[#parts + 1] = json_string(tostring(i)) .. ":" .. encode_entry(entry)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function write_ipc_json(file_name, body)
    local dir = mod_paths.ipc_dir()
    if not dir then return false, "ipc dir unavailable" end
    return mod_paths.write_atomic(dir .. "\\" .. file_name, body)
end

local function as_number(v)
    if type(v) == "number" then return v end
    if type(v) == "string" then return tonumber(v) end
    local primitive = nil
    pcall(function() primitive = safety.read_primitive(v) end)
    if type(primitive) == "number" then return primitive end
    if type(primitive) == "string" then return tonumber(primitive) end
    return tonumber(tostring(v))
end

local function tarray_length(list)
    if type(list) == "table" then return #list end
    if type(list) ~= "userdata" then return 0 end
    local ok_len, len = pcall(function() return #list end)
    if ok_len and type(len) == "number" then return len end
    local ok_num, num = pcall(function() return list:Num() end)
    if ok_num and type(num) == "number" then return num end
    return 0
end

local function tarray_get(list, i)
    if type(list) == "table" then return list[i] end
    local ok, value = pcall(function() return list[i] end)
    if ok then return value end
    return nil
end

local function find_all_live(class_name_to_find)
    local out = {}
    if not FindAllOf then return out end
    local ok, list = pcall(FindAllOf, class_name_to_find)
    if not ok or not list then return out end
    local n = tarray_length(list)
    for i = 1, n do
        local entry = tarray_get(list, i)
        if is_valid(entry) and not is_cdo(entry) then
            out[#out + 1] = entry
        end
    end
    return out
end

local function read_primitive_text(obj, field)
    local ok, value = pcall(function() return obj[field] end)
    if not ok or value == nil then return nil end
    local primitive = safety.read_primitive(value)
    if primitive == nil then return nil end
    return tostring(primitive)
end

local function static_mesh_name(comp)
    if not is_valid(comp) then return nil end
    local mesh = nil
    if comp.GetStaticMesh then
        pcall(function() mesh = comp:GetStaticMesh() end)
    end
    if not is_valid(mesh) then
        pcall(function() mesh = comp.StaticMesh end)
    end
    return object_short_name(mesh) or object_full_name(mesh)
end

local function owner_name(comp)
    if not is_valid(comp) or not comp.GetOwner then return nil end
    local owner = nil
    pcall(function() owner = comp:GetOwner() end)
    return object_short_name(owner) or object_full_name(owner)
end

local function infer_category(cls, foliage_type, mesh, hint)
    if hint then return hint end
    local text = string.lower(table.concat({ tostring(cls or ""), tostring(foliage_type or ""), tostring(mesh or "") }, " "))
    if text:find("tree", 1, true) then return "tree" end
    if text:find("sapling", 1, true) then return "sapling" end
    if text:find("pickup", 1, true) or text:find("pickups", 1, true) then return "pickup" end
    if text:find("ore", 1, true) then return "ore" end
    return "unknown"
end

local function normalize_category(value)
    local s = string.lower(trim(value))
    if s == "" or s == "all" or s == "any" or s == "*" then return "all" end
    if s == "tree" or s == "trees" then return "tree" end
    if s == "sapling" or s == "saplings" then return "sapling" end
    if s == "pickup" or s == "pickups" or s == "pick_up" or s == "pickups" then return "pickup" end
    if s == "ore" or s == "ores" or s == "orenode" or s == "ore_node" or s == "ore_nodes" then return "ore" end
    return nil
end

local function category_matches(actual, requested)
    if requested == nil or requested == "all" then return true end
    if requested == TREE_FAMILY_CATEGORY then return actual == "tree" or actual == "sapling" end
    return actual == requested
end

local function collect_components()
    local out = {}
    local seen = {}
    for _, def in ipairs(COMPONENT_CLASS_DEFS) do
        local list = find_all_live(def.name)
        for _, comp in ipairs(list) do
            local full = object_full_name(comp) or tostring(comp)
            if not seen[full] then
                seen[full] = true
                local cls = class_name(comp)
                local mesh = static_mesh_name(comp)
                local foliage_type = read_primitive_text(comp, "FoliageType")
                out[#out + 1] = {
                    object = comp,
                    class = cls,
                    class_hint = def.category,
                    name = object_short_name(comp),
                    full_name = full,
                    owner = owner_name(comp),
                    mesh = mesh,
                    foliage_type = foliage_type,
                    category = infer_category(cls, foliage_type, mesh, def.category),
                }
            end
        end
    end
    return out
end

local function instance_count(comp)
    if not is_valid(comp) or not comp.GetInstanceCount then return 0 end
    local ok, n = pcall(function() return comp:GetInstanceCount() end)
    n = ok and tonumber(n) or 0
    if n == nil or n < 0 then return 0 end
    return math.floor(n)
end

local function overlapping_instance_indices(comp, center, radius)
    local out = {}
    if not is_valid(comp) or not comp.GetInstancesOverlappingSphere then return out end
    local ok, list = pcall(function()
        return comp:GetInstancesOverlappingSphere(center, radius, true)
    end)
    if not ok or not list then return out end
    local n = tarray_length(list)
    for i = 1, n do
        local idx = as_number(tarray_get(list, i))
        if idx ~= nil then out[#out + 1] = math.floor(idx) end
    end
    return out
end

local function get_instance_location(comp, index)
    if not is_valid(comp) or not comp.GetInstanceTransform then return nil, "GetInstanceTransform unavailable" end
    local out = {}
    local ok, ret, extra = pcall(function()
        return comp:GetInstanceTransform(index, out, true)
    end)
    if not ok then return nil, tostring(ret) end
    if ret == false then return nil, "GetInstanceTransform returned false" end
    local loc = transform_location(out) or transform_location(ret) or transform_location(extra)
    if loc then return loc, nil end
    return nil, "no location in transform"
end

local function first_indices(count, limit)
    local out = {}
    local n = math.min(count or 0, limit or 0)
    for i = 0, n - 1 do out[#out + 1] = i end
    return out
end

local function build_scan_payload(mode, radius, limit, components, instances, counts, totals)
    local parts = {
        '"ok":true',
        json_kv("mode", mode),
        json_kv("radius", radius),
        json_kv("limit", limit),
        json_kv("component_count", totals.component_count or 0),
        json_kv("reported_component_count", #components),
        json_kv("total_instance_count", totals.total_instance_count or 0),
        json_kv("near_instance_count", totals.near_instance_count or 0),
        json_kv("reported_instance_count", #instances),
        '"categories":' .. encode_counts(counts),
        json_kv("generated_unix", os.time()),
        '"components":' .. encode_map(components, encode_component),
        '"instances":' .. encode_map(instances, encode_instance)
    }
    return "{" .. table.concat(parts, ",") .. "}"
end

local function scan(mode, radius, limit)
    local center = pawn_location()
    if mode == "near" and not center then return false, "no local pawn location" end

    local components = collect_components()
    local component_entries = {}
    local instance_entries = {}
    local counts = { tree = 0, sapling = 0, pickup = 0, ore = 0, unknown = 0 }
    local totals = { component_count = #components, total_instance_count = 0, near_instance_count = 0 }

    for _, meta in ipairs(components) do
        local comp = meta.object
        local count = instance_count(comp)
        totals.total_instance_count = totals.total_instance_count + count

        local indices = nil
        local near_count = nil
        if mode == "near" then
            indices = overlapping_instance_indices(comp, center, radius)
            near_count = #indices
            totals.near_instance_count = totals.near_instance_count + near_count
        else
            indices = first_indices(count, math.max(0, limit - #instance_entries))
            near_count = nil
            totals.near_instance_count = totals.near_instance_count + count
        end

        local counted = mode == "near" and near_count or count
        counts[meta.category] = (counts[meta.category] or 0) + counted

        if count > 0 and (mode ~= "near" or near_count > 0) then
            local loc = component_location(comp)
            component_entries[#component_entries + 1] = {
                class = meta.class,
                category = meta.category,
                name = meta.name,
                full_name = meta.full_name,
                owner = meta.owner,
                mesh = meta.mesh,
                foliage_type = meta.foliage_type,
                instance_count = count,
                near_count = near_count,
                distance = center and loc and math.sqrt(dist_sq(center, loc)) or nil,
                location = loc,
            }
            local component_index = #component_entries

            for _, idx in ipairs(indices or {}) do
                if #instance_entries >= limit then break end
                local loc = get_instance_location(comp, idx)
                instance_entries[#instance_entries + 1] = {
                    component_index = component_index,
                    instance_index = idx,
                    class = meta.class,
                    category = meta.category,
                    owner = meta.owner,
                    mesh = meta.mesh,
                    distance = center and loc and math.sqrt(dist_sq(center, loc)) or nil,
                    location = loc,
                }
            end
        end
    end

    table.sort(instance_entries, function(a, b)
        return (a.distance or math.huge) < (b.distance or math.huge)
    end)

    local body = build_scan_payload(mode, radius, limit, component_entries, instance_entries, counts, totals)
    local ok, path_or_err = write_ipc_json(SCAN_FILE, body)
    if not ok then return false, path_or_err end
    return true, string.format("components=%d instances=%d near=%d tree=%d sapling=%d pickup=%d ore=%d file=%s",
        totals.component_count,
        totals.total_instance_count,
        totals.near_instance_count,
        counts.tree or 0,
        counts.sapling or 0,
        counts.pickup or 0,
        counts.ore or 0,
        path_or_err)
end

local function parse_scan_near_args(args)
    local words = split_words(args)
    local radius = tonumber(words[1]) or DEFAULT_NEAR_RADIUS
    if radius < 1 then radius = 1 end
    local limit = tonumber(words[2]) or DEFAULT_SCAN_LIMIT
    limit = clamp_int(limit, 1, MAX_SCAN_LIMIT)
    return radius, limit
end

local function parse_scan_all_args(args)
    local words = split_words(args)
    local limit = tonumber(words[1]) or DEFAULT_SCAN_LIMIT
    limit = clamp_int(limit, 1, MAX_SCAN_LIMIT)
    return limit
end

function M.scan_near(args)
    local radius, limit = parse_scan_near_args(args)
    return scan("near", radius, limit)
end

function M.scan_all(args)
    local limit = parse_scan_all_args(args)
    return scan("all", nil, limit)
end

local function get_foliage_library()
    if not StaticFindObject then return nil end
    local ok, obj = pcall(StaticFindObject, "/Script/Dominion.Default__InteractableFoliageFunctionLibrary")
    if ok and is_valid(obj) then return obj end
    return nil
end

local function get_dominion_runtime_library()
    if not StaticFindObject then return nil end
    local ok, obj = pcall(StaticFindObject, "/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
    if ok and is_valid(obj) then return obj end
    return nil
end

local function get_fellable_tree_class()
    if not StaticFindObject then return nil end
    local candidates = {
        "/Script/Dominion.FellableTree",
        "/Game/Gameplay/World/Trees/BP_FellableTree_Base.BP_FellableTree_Base_C",
    }
    for _, path in ipairs(candidates) do
        local ok, obj = pcall(StaticFindObject, path)
        if ok and obj then return obj end
    end
    return nil
end

local function tree_near_location_native(loc, radius, count_stumps)
    local lib = get_dominion_runtime_library()
    local tree_class = get_fellable_tree_class()
    local context = world_context()
    if not (lib and tree_class and context and loc) then return nil end
    local ok, tree = pcall(function()
        return lib:GetTreeNearbyLocation(context, tree_class, loc, radius, count_stumps and true or false)
    end)
    if ok and is_valid(tree) and not is_cdo(tree) and not is_foliage_container_actor(tree) then return tree end
    return nil
end

local function collect_resource_actors_near(category, center, radius, limit)
    local actors = {}
    local seen = {}

    local function add_actor(actor, actual_category)
        if not category_matches(actual_category, category) then return end
        if not is_valid(actor) or is_cdo(actor) then return end
        if is_foliage_container_actor(actor) then return end
        local key = object_full_name(actor) or tostring(actor)
        if seen[key] then return end
        local loc = actor_location(actor)
        local d2 = loc and dist_sq(center, loc) or math.huge
        if d2 <= radius * radius then
            seen[key] = true
            actors[#actors + 1] = { object = actor, category = actual_category, location = loc, distance_sq = d2 }
        end
    end

    if category_matches("tree", category) then
        add_actor(tree_near_location_native(center, radius, true), "tree")
    end

    for _, def in ipairs(RESOURCE_ACTOR_CLASS_DEFS) do
        if category_matches(def.category, category) then
            local list = find_all_live(def.name)
            for _, actor in ipairs(list) do
                add_actor(actor, def.category)
            end
        end
    end

    table.sort(actors, function(a, b) return a.distance_sq < b.distance_sq end)
    if limit then
        while #actors > limit do table.remove(actors) end
    end
    return actors
end

local function collect_resource_actors_all(category, limit)
    local actors = {}
    local seen = {}

    local function add_actor(actor, actual_category)
        if not category_matches(actual_category, category) then return end
        if not is_valid(actor) or is_cdo(actor) then return end
        if is_foliage_container_actor(actor) then return end
        local key = object_full_name(actor) or tostring(actor)
        if seen[key] then return end
        seen[key] = true
        actors[#actors + 1] = { object = actor, category = actual_category, location = actor_location(actor) }
    end

    for _, def in ipairs(RESOURCE_ACTOR_CLASS_DEFS) do
        if category_matches(def.category, category) then
            local list = find_all_live(def.name)
            for _, actor in ipairs(list) do
                add_actor(actor, def.category)
                if limit and #actors >= limit then break end
            end
        end
        if limit and #actors >= limit then break end
    end
    return actors
end

local function resource_actor_near_location(loc, radius, category)
    if category_matches("tree", category or "tree") then
        local native_tree = tree_near_location_native(loc, radius, true)
        if is_valid(native_tree) then return native_tree end
    end
    local actors = collect_resource_actors_near(category or "tree", loc, radius, 1)
    return actors[1] and actors[1].object or nil
end

local function is_fellable_tree_actor(actor)
    if not is_valid(actor) or is_cdo(actor) then return false end
    if is_foliage_container_actor(actor) then return false end
    if actor.ForceReduceToStump or actor.ForceSplitIntoLogAndStump then return true end
    local cls = string.lower(tostring(class_name(actor) or ""))
    return cls:find("fellabletree", 1, true) ~= nil or cls:find("fellable_tree", 1, true) ~= nil
end

local function remember_converted_target(target, tree)
    if not target or not target.location then return end
    LAST_CONVERTED_TARGETS[#LAST_CONVERTED_TARGETS + 1] = {
        location = target.location,
        tree = is_valid(tree) and tree or nil,
        category = target.category,
        mesh = target.mesh,
        owner = target.owner,
        instance_index = target.index,
        distance = target.distance_sq < math.huge and math.sqrt(target.distance_sq) or nil,
        generated_unix = os.time(),
    }
    while #LAST_CONVERTED_TARGETS > LAST_CONVERTED_CAP do
        table.remove(LAST_CONVERTED_TARGETS, 1)
    end
end

local function last_conversion_center()
    for i = #LAST_CONVERTED_TARGETS, 1, -1 do
        local entry = LAST_CONVERTED_TARGETS[i]
        if entry then
            if is_valid(entry.tree) then
                local loc = actor_location(entry.tree)
                if loc then return loc, "last.tree", entry end
            end
            if entry.location then
                return entry.location, "last.instance", entry
            end
        end
    end
    return nil, "no successful foliage conversion recorded"
end

local function lookat_center()
    local picker = feature_grab.pick_location_under_reticle or feature_grab.pick_target_under_reticle
    if not picker then
        return nil, "camera lookat target helper unavailable", nil
    end
    local actor, loc, source, err = picker()
    if not loc then return nil, tostring(err or "no lookat location"), nil end
    return loc, "lookat." .. tostring(source or "unknown"), object_short_name(actor)
end

local function collect_instance_targets(category, center, radius, limit)
    local components = collect_components()
    local targets = {}
    local stats = { component_count = #components, matching_components = 0, near_instance_count = 0 }
    local transform_cap = math.min(MAX_SCAN_LIMIT, math.max(100, (limit or 1) * 20))

    for _, meta in ipairs(components) do
        if category_matches(meta.category, category) then
            stats.matching_components = stats.matching_components + 1
            local indices = overlapping_instance_indices(meta.object, center, radius)
            stats.near_instance_count = stats.near_instance_count + #indices
            for _, idx in ipairs(indices) do
                if #targets >= transform_cap then break end
                local loc, err = get_instance_location(meta.object, idx)
                targets[#targets + 1] = {
                    component = meta.object,
                    component_class = meta.class,
                    category = meta.category,
                    owner = meta.owner,
                    mesh = meta.mesh,
                    index = idx,
                    location = loc,
                    transform_error = err,
                    distance_sq = loc and dist_sq(center, loc) or math.huge,
                }
            end
        end
        if #targets >= transform_cap then break end
    end

    table.sort(targets, function(a, b) return a.distance_sq < b.distance_sq end)
    while #targets > limit do table.remove(targets) end
    return targets, stats
end

local function collect_single_tree_instance_target(center)
    local targets, stats = collect_instance_targets("tree", center, SINGLE_TREE_PICK_RADIUS, 100)
    local max_xy_sq = SINGLE_TREE_PICK_MAX_XY_RADIUS * SINGLE_TREE_PICK_MAX_XY_RADIUS
    local best = nil
    for _, target in ipairs(targets or {}) do
        if target.location then
            local xy_sq = dist_sq_xy(center, target.location)
            if xy_sq <= max_xy_sq then
                target.distance_xy_sq = xy_sq
                if (not best)
                    or xy_sq < best.distance_xy_sq
                    or (xy_sq == best.distance_xy_sq and target.distance_sq < best.distance_sq) then
                    best = target
                end
            end
        end
    end
    return best, stats
end

local function component_meta_for(comp)
    if not is_valid(comp) then return nil end
    local comp_full = object_full_name(comp)
    for _, meta in ipairs(collect_components()) do
        if meta.object == comp then return meta end
        if comp_full and object_full_name(meta.object) == comp_full then return meta end
    end
    return nil
end

local function instance_target_from_hit(hit_details, hit_loc, fallback_target)
    local comp = hit_details and hit_details.component or nil
    local idx = as_number(hit_details and hit_details.item or nil)
    if idx ~= nil then idx = math.floor(idx) end
    if is_valid(comp) and idx ~= nil and idx >= 0 then
        local meta = component_meta_for(comp)
        if meta and category_matches(meta.category, "tree") then
            local loc, loc_err = get_instance_location(comp, idx)
            return {
                component = comp,
                component_class = meta.class,
                category = meta.category,
                owner = meta.owner,
                mesh = meta.mesh,
                index = idx,
                location = loc or hit_loc,
                transform_error = loc_err,
                distance_sq = (loc and hit_loc) and dist_sq(hit_loc, loc) or 0,
                source = "hit.item",
            }
        end
        return nil, "reticle hit instance is not recognized as tree foliage"
    end
    return fallback_target, nil
end

local function convert_instance_target_to_actor(target, convert_distance, category)
    if not target then return false, nil, "no foliage instance target" end
    if not target.location then return false, nil, target.transform_error or "no instance location" end
    local lib = get_foliage_library()
    if not lib then return false, nil, "InteractableFoliageFunctionLibrary CDO not found" end
    local context, requirer = world_context()
    if not context then return false, nil, "no world context" end
    local ok_call, call_err = pcall(function()
        return lib:ConvertFoliageNearbyLocation(context, target.location, convert_distance, true, true, requirer)
    end)
    if not ok_call then return false, nil, tostring(call_err) end
    local tree = resource_actor_near_location(target.location, TREE_LOOKUP_RADIUS_AFTER_CONVERT, category or target.category or "tree")
    if is_foliage_container_actor(tree) then tree = nil end
    remember_converted_target(target, tree)
    return true, tree, nil
end

local function foliage_lookat_center(category)
    local center, origin, label = lookat_center()
    if not center then return nil, origin, label end
    local targets = collect_instance_targets(category or "tree", center, SINGLE_LOOKAT_PICK_RADIUS, 1)
    local target = targets and targets[1] or nil
    if target and target.location then
        return target.location, origin .. ":instance", label
    end
    return center, origin, label
end

local function collect_all_instance_targets(category, limit)
    local components = collect_components()
    local targets = {}
    local stats = { component_count = #components, matching_components = 0, near_instance_count = 0 }

    for _, meta in ipairs(components) do
        if category_matches(meta.category, category) then
            stats.matching_components = stats.matching_components + 1
            local count = instance_count(meta.object)
            stats.near_instance_count = stats.near_instance_count + count
            local remaining = limit and (limit - #targets) or count
            if remaining > 0 then
                local indices = first_indices(count, remaining)
                for _, idx in ipairs(indices) do
                    local loc, err = get_instance_location(meta.object, idx)
                    targets[#targets + 1] = {
                        component = meta.object,
                        component_class = meta.class,
                        category = meta.category,
                        owner = meta.owner,
                        mesh = meta.mesh,
                        index = idx,
                        location = loc,
                        transform_error = err,
                        distance_sq = math.huge,
                    }
                    if limit and #targets >= limit then break end
                end
            end
        end
        if limit and #targets >= limit then break end
    end

    return targets, stats
end

local function encode_action_payload(meta, results)
    local parts = {
        '"ok":true',
        json_kv("action", meta.action),
        json_kv("category", meta.category),
        json_kv("origin", meta.origin),
        json_kv("radius", meta.radius),
        json_kv("limit", meta.limit),
        json_kv("convert_distance", meta.convert_distance),
        json_kv("redundant", meta.redundant),
        json_kv("requested_count", meta.requested_count or 0),
        json_kv("success_count", meta.success_count or 0),
        json_kv("failure_count", meta.failure_count or 0),
        json_kv("component_count", meta.component_count or 0),
        json_kv("matching_components", meta.matching_components or 0),
        json_kv("near_instance_count", meta.near_instance_count or 0),
        json_kv("generated_unix", os.time()),
        '"results":' .. encode_map(results, encode_result)
    }
    return "{" .. table.concat(parts, ",") .. "}"
end

local function write_action(meta, results)
    local ok, path_or_err = write_ipc_json(ACTION_FILE, encode_action_payload(meta, results))
    if not ok then return false, path_or_err end
    return true, path_or_err
end

local function parse_convert_args(args)
    local words = split_words(args)
    if #words == 0 then
        return nil, nil, nil, nil, "usage: world.foliage.convert.near <trees|saplings|pickups|ore|all> <radius> [limit] [convertDistance]"
    end

    local category = normalize_category(words[1])
    local radius_index = 2
    if not category then
        if tonumber(words[1]) then
            category = "all"
            radius_index = 1
        else
            return nil, nil, nil, nil, "unknown foliage category: " .. tostring(words[1])
        end
    end

    local radius = tonumber(words[radius_index])
    if radius == nil then
        return nil, nil, nil, nil, "usage: world.foliage.convert.near <trees|saplings|pickups|ore|all> <radius> [limit] [convertDistance]"
    end
    if radius < 1 then radius = 1 end

    local limit = tonumber(words[radius_index + 1]) or DEFAULT_ACTION_LIMIT
    limit = clamp_int(limit, 1, MAX_ACTION_LIMIT)
    local convert_distance = tonumber(words[radius_index + 2]) or DEFAULT_CONVERT_DISTANCE
    convert_distance = clamp_number(convert_distance, 1, 1000)
    return category, radius, limit, convert_distance, nil
end

function M.convert_near(args)
    local category, radius, limit, convert_distance, err = parse_convert_args(args)
    if err then return false, err end

    local center = pawn_location()
    if not center then return false, "no local pawn location" end

    local lib = get_foliage_library()
    if not lib then return false, "InteractableFoliageFunctionLibrary CDO not found" end

    local context, requirer = world_context()
    if not context then return false, "no world context" end

    local targets, stats = collect_instance_targets(category, center, radius, limit)
    local results = {}
    local success_count = 0
    local failure_count = 0

    for _, target in ipairs(targets) do
        local ok_call, call_err = false, nil
        if target.location then
            ok_call, call_err = pcall(function()
                return lib:ConvertFoliageNearbyLocation(context, target.location, convert_distance, true, true, requirer)
            end)
        else
            call_err = target.transform_error or "no instance location"
        end
        if ok_call then success_count = success_count + 1 else failure_count = failure_count + 1 end
        local tree = ok_call and resource_actor_near_location(target.location, TREE_LOOKUP_RADIUS_AFTER_CONVERT, target.category or category) or nil
        if ok_call then remember_converted_target(target, tree) end
        results[#results + 1] = {
            action = "convert",
            ok = ok_call,
            error = ok_call and nil or tostring(call_err),
            category = target.category,
            component_class = target.component_class,
            owner = target.owner,
            mesh = target.mesh,
            instance_index = target.index,
            distance = target.distance_sq < math.huge and math.sqrt(target.distance_sq) or nil,
            convert_distance = convert_distance,
            tree = object_short_name(tree),
            tree_class = tree and class_name(tree) or nil,
            location = target.location,
        }
    end

    local meta = {
        action = "convert.near",
        category = category,
        radius = radius,
        limit = limit,
        convert_distance = convert_distance,
        requested_count = #targets,
        success_count = success_count,
        failure_count = failure_count,
        component_count = stats.component_count,
        matching_components = stats.matching_components,
        near_instance_count = stats.near_instance_count,
    }
    local ok_write, path_or_err = write_action(meta, results)
    if not ok_write then return false, path_or_err end
    local nearest = (#targets > 0 and targets[1].distance_sq < math.huge) and math.sqrt(targets[1].distance_sq) or nil
    local nearest_text = nearest and string.format(" nearest=%.1f", nearest) or ""
    return true, string.format("category=%s targets=%d converted=%d failed=%d near=%d%s file=%s",
        category, #targets, success_count, failure_count, stats.near_instance_count, nearest_text, path_or_err)
end

local function tree_is_stump(tree)
    if not is_valid(tree) then return nil end
    if tree.IsStump then
        local ok, value = pcall(function() return tree:IsStump() end)
        if ok then return value and true or false end
    end
    local ok, value = pcall(function() return tree.bIsStump end)
    if ok and value ~= nil then return value and true or false end
    return nil
end

local function get_foliage_depictable_component(actor)
    if not is_valid(actor) then return nil end
    if actor.GetFoliageDepictableComponent then
        local ok, comp = pcall(function() return actor:GetFoliageDepictableComponent() end)
        if ok and is_valid(comp) then return comp end
    end
    for _, field in ipairs({ "FoliageDepictableComponent", "FoliageDepictable" }) do
        local ok, comp = pcall(function() return actor[field] end)
        if ok and is_valid(comp) then return comp end
    end
    return nil
end

local function make_depiction_redundant(actor)
    local comp = get_foliage_depictable_component(actor)
    if not comp then return false, "no FoliageDepictableComponent" end
    if not comp.MakeFoliageDepictionRedundant then return false, "MakeFoliageDepictionRedundant unavailable" end
    local ok, err = pcall(function() comp:MakeFoliageDepictionRedundant() end)
    if not ok then return false, tostring(err) end
    return true, "ok"
end

local function destroy_tree_actor(tree)
    if not is_valid(tree) then return false, "invalid tree" end
    if is_foliage_container_actor(tree) then return false, "refusing to destroy foliage container actor" end
    local last_err = nil
    if tree.K2_DestroyActor then
        local ok, err = pcall(function() tree:K2_DestroyActor() end)
        if ok then return true, "K2_DestroyActor" end
        last_err = err
    end
    if tree.DestroyActor then
        local ok, err = pcall(function() tree:DestroyActor() end)
        if ok then return true, "DestroyActor" end
        last_err = err
    end
    return false, last_err and tostring(last_err) or "no destroy method"
end

local function normalize_tree_verb(verb)
    local value = string.lower(tostring(verb or ""))
    if value == "delete" or value == "remove" or value == "properdestroy" or value == "proper_destroy" then
        return "destroy"
    end
    return value
end

local function apply_tree_action(tree, verb, redundant)
    verb = normalize_tree_verb(verb)
    if not is_valid(tree) then
        return false, { action = verb, ok = false, error = "invalid tree" }
    end

    local before_stump = tree_is_stump(tree)
    local ok_action, action_err = true, nil
    local action_detail = nil
    local ok_redundant, redundant_err = true, nil

    if verb == "stump" then
        if tree.ForceReduceToStump then
            ok_action, action_err = pcall(function() tree:ForceReduceToStump() end)
        else
            ok_action, action_err = false, "ForceReduceToStump unavailable"
        end
    elseif verb == "split" then
        if tree.ForceSplitIntoLogAndStump then
            ok_action, action_err = pcall(function() tree:ForceSplitIntoLogAndStump() end)
        else
            ok_action, action_err = false, "ForceSplitIntoLogAndStump unavailable"
        end
    elseif verb == "redundant" then
        ok_action, action_err = make_depiction_redundant(tree)
    elseif verb == "destroy" then
        ok_redundant, redundant_err = make_depiction_redundant(tree)
        ok_action, action_detail = destroy_tree_actor(tree)
        if not ok_action then action_err = action_detail end
    else
        ok_action, action_err = false, "unknown tree action: " .. tostring(verb)
    end

    if verb ~= "redundant" and verb ~= "destroy" and redundant then
        ok_redundant, redundant_err = make_depiction_redundant(tree)
    end

    local ok_result = ok_action and ok_redundant
    local result = {
        action = verb,
        ok = ok_result,
        error = ok_action and nil or tostring(action_err),
        redundant_ok = ok_redundant,
        redundant_error = ok_redundant and nil or tostring(redundant_err),
        tree = object_short_name(tree),
        tree_class = class_name(tree),
        before_stump = before_stump,
        after_stump = tree_is_stump(tree),
    }
    if verb == "destroy" then
        result.destroyed_ok = ok_action
        result.destroy_method = ok_action and action_detail or nil
    end
    return ok_result, result
end

local function parse_tree_args(args, verb)
    local words = split_words(args)
    local source = "player"
    local radius_index = 1
    local first = string.lower(tostring(words[1] or ""))
    if first == "last" or first == "converted" or first == "conversion" then
        source = "last"
        radius_index = 2
    elseif first == "player" or first == "pawn" then
        source = "player"
        radius_index = 2
    end

    local radius = tonumber(words[radius_index])
    if radius == nil then
        return nil, nil, nil, nil, "usage: world.foliage.tree." .. verb .. ".near [player|last] <radius> [limit] [redundant|keepdepiction]"
    end
    if radius < 1 then radius = 1 end

    local limit = DEFAULT_ACTION_LIMIT
    local flag_start = radius_index + 1
    if tonumber(words[radius_index + 1]) then
        limit = tonumber(words[radius_index + 1])
        flag_start = radius_index + 2
    end
    limit = clamp_int(limit, 1, MAX_ACTION_LIMIT)

    local redundant = false
    for i = flag_start, #words do
        local flag = string.lower(words[i])
        if flag == "redundant" or flag == "persist" or flag == "persistent" or flag == "save" or flag == "true" or flag == "yes" then
            redundant = true
        elseif flag == "keepdepiction" or flag == "keep" or flag == "false" or flag == "no" then
            redundant = false
        else
            return nil, nil, nil, nil, "unknown flag: " .. tostring(words[i])
        end
    end
    return source, radius, limit, redundant, nil
end

local function run_tree_action(verb, args)
    verb = normalize_tree_verb(verb)
    local source, radius, limit, redundant, err = parse_tree_args(args, verb)
    if err then return false, err end

    local center, origin = nil, source
    if source == "last" then
        center, origin = last_conversion_center()
        if not center then return false, origin end
    else
        center = pawn_location()
        if not center then return false, "no local pawn location" end
    end

    local action_category = (verb == "destroy" or verb == "redundant") and TREE_FAMILY_CATEGORY or "tree"
    local targets = collect_resource_actors_near(action_category, center, radius, limit)
    local results = {}
    local success_count = 0
    local failure_count = 0

    for _, target in ipairs(targets) do
        local tree = target.object
        local ok_result, result = apply_tree_action(tree, verb, redundant)
        if ok_result then success_count = success_count + 1 else failure_count = failure_count + 1 end
        result.distance = math.sqrt(target.distance_sq)
        result.location = target.location
        result.category = target.category
        results[#results + 1] = result
    end

    local meta = {
        action = "tree." .. verb .. ".near",
        category = action_category,
        origin = origin,
        radius = radius,
        limit = limit,
        redundant = (verb == "redundant") or (verb == "destroy") or redundant,
        requested_count = #targets,
        success_count = success_count,
        failure_count = failure_count,
    }
    local ok_write, path_or_err = write_action(meta, results)
    if not ok_write then return false, path_or_err end
    if verb == "redundant" then
        return true, string.format("origin=%s category=%s targets=%d redundant=%d failed=%d file=%s",
            tostring(origin), tostring(action_category), #targets, success_count, failure_count, path_or_err)
    end
    if verb == "destroy" then
        return true, string.format("origin=%s category=%s targets=%d destroyed=%d failed=%d file=%s",
            tostring(origin), tostring(action_category), #targets, success_count, failure_count, path_or_err)
    end
    return true, string.format("origin=%s trees=%d %s=%d failed=%d redundant=%s file=%s",
        tostring(origin), #targets, verb, success_count, failure_count, tostring(redundant), path_or_err)
end

local function parse_lookat_convert_args(args)
    local words = split_words(args)
    local category = "tree"
    local radius_index = 1
    local maybe_category = normalize_category(words[1])
    if maybe_category and not tonumber(words[1]) then
        category = maybe_category
        radius_index = 2
    end

    local radius = tonumber(words[radius_index])
    if radius == nil then
        return nil, nil, nil, nil, "usage: world.foliage.convert.lookat [trees|saplings|pickups|ore|all] <radius> [limit] [convertDistance]"
    end
    if radius < 1 then radius = 1 end

    local limit = tonumber(words[radius_index + 1]) or DEFAULT_FOREST_LIMIT
    limit = clamp_int(limit, 1, MAX_FOREST_LIMIT)
    local convert_distance = tonumber(words[radius_index + 2]) or DEFAULT_CONVERT_DISTANCE
    convert_distance = clamp_number(convert_distance, 1, 1000)
    return category, radius, limit, convert_distance, nil
end

local function parse_forest_action_args(args, verb)
    verb = normalize_tree_verb(verb)
    local words = split_words(args)
    local include_saplings = verb == "destroy" or verb == "redundant"
    local category = include_saplings and TREE_FAMILY_CATEGORY or "tree"
    local radius_index = 1
    local first = string.lower(tostring(words[1] or ""))
    local explicit_tree_only = false
    local maybe_category = normalize_category(words[1])
    if include_saplings and (first == "treeonly" or first == "treesonly" or first == "fulltrees" or first == "full_trees") then
        category = "tree"
        radius_index = 2
        explicit_tree_only = true
    elseif maybe_category and not tonumber(words[1]) then
        category = maybe_category
        radius_index = 2
    end
    if include_saplings and not explicit_tree_only and (category == "tree" or category == "all") then
        category = TREE_FAMILY_CATEGORY
    end
    if include_saplings then
        if category ~= TREE_FAMILY_CATEGORY and category ~= "tree" and category ~= "sapling" then
            return nil, nil, nil, nil, nil, "world.foliage.tree." .. verb .. ".lookat currently supports trees/saplings only"
        end
    elseif category ~= "tree" and category ~= "all" then
        return nil, nil, nil, nil, nil, "world.foliage.tree." .. verb .. ".lookat currently supports trees only"
    end
    if not include_saplings then category = "tree" end

    local radius = tonumber(words[radius_index])
    if radius == nil then
        local flag_usage = verb == "destroy" and "" or " [redundant|keepdepiction]"
        return nil, nil, nil, nil, nil, "usage: world.foliage.tree." .. verb .. ".lookat [trees|treeonly|saplings] <radius> [limit] [convertDistance]" .. flag_usage
    end
    if radius < 1 then radius = 1 end

    local limit = DEFAULT_FOREST_LIMIT
    local convert_distance = DEFAULT_CONVERT_DISTANCE
    local pos = radius_index + 1
    if tonumber(words[pos]) then
        limit = tonumber(words[pos])
        pos = pos + 1
    end
    limit = clamp_int(limit, 1, MAX_FOREST_LIMIT)
    if tonumber(words[pos]) then
        convert_distance = tonumber(words[pos])
        pos = pos + 1
    end
    convert_distance = clamp_number(convert_distance, 1, 1000)

    local redundant = false
    for i = pos, #words do
        local flag = string.lower(words[i])
        if flag == "redundant" or flag == "persist" or flag == "persistent" or flag == "save" or flag == "true" or flag == "yes" then
            redundant = true
        elseif flag == "keepdepiction" or flag == "keep" or flag == "false" or flag == "no" then
            redundant = false
        else
            return nil, nil, nil, nil, nil, "unknown flag: " .. tostring(words[i])
        end
    end

    return category, radius, limit, convert_distance, redundant, nil
end

local function parse_destroy_all_args(args)
    local words = split_words(args)
    local confirmed = false
    local category = TREE_FAMILY_CATEGORY
    local limit = nil
    local unbounded = false
    local convert_distance = DEFAULT_CONVERT_DISTANCE
    local numeric_count = 0

    for _, word in ipairs(words) do
        local flag = string.lower(tostring(word or ""))
        local n = tonumber(word)
        if flag == "confirm" or flag == "confirmed" or flag == "force" or flag == "yes" then
            confirmed = true
        elseif flag == "tree" or flag == "trees" or flag == "all" or flag == "loaded" then
            category = TREE_FAMILY_CATEGORY
        elseif flag == "treeonly" or flag == "treesonly" or flag == "fulltrees" or flag == "full_trees" then
            category = "tree"
        elseif flag == "sapling" or flag == "saplings" then
            category = "sapling"
        elseif flag == "unbounded" or flag == "unlimited" or flag == "allloaded" or flag == "all_loaded" then
            unbounded = true
        elseif n ~= nil then
            numeric_count = numeric_count + 1
            if numeric_count == 1 then
                if n > MAX_FOREST_LIMIT then
                    return nil, nil, nil, "limit too high for all-loaded destroy: max " .. tostring(MAX_FOREST_LIMIT) .. " per command, or pass unbounded to run the old full sweep"
                end
                limit = clamp_int(n, 1, MAX_FOREST_LIMIT)
            elseif numeric_count == 2 then
                convert_distance = clamp_number(n, 1, 1000)
            else
                return nil, nil, nil, "too many numeric args"
            end
        else
            return nil, nil, nil, "unknown flag: " .. tostring(word)
        end
    end

    if not confirmed then
        return nil, nil, nil, "usage: world.foliage.forest.destroy.all confirm [trees|treeonly|saplings] [limit<=250|unbounded] [convertDistance]"
    end
    if limit == nil and not unbounded then
        return nil, nil, nil, "refusing unbounded all-loaded destroy on the game thread; add a limit like 250, or pass unbounded to run the old full sweep"
    end
    return category, limit, convert_distance, nil
end

local function parse_tree_all_action_args(args, verb)
    local words = split_words(args)
    local confirmed = false
    local limit = nil
    local unbounded = false
    local convert_distance = DEFAULT_CONVERT_DISTANCE
    local redundant = false
    local numeric_count = 0

    for _, word in ipairs(words) do
        local flag = string.lower(tostring(word or ""))
        local n = tonumber(word)
        if flag == "confirm" or flag == "confirmed" or flag == "force" or flag == "yes" then
            confirmed = true
        elseif flag == "tree" or flag == "trees" or flag == "treeonly" or flag == "treesonly" or flag == "fulltrees" or flag == "full_trees" or flag == "all" or flag == "loaded" then
        elseif flag == "redundant" or flag == "persist" or flag == "persistent" or flag == "save" or flag == "true" then
            redundant = true
        elseif flag == "keepdepiction" or flag == "keep" or flag == "false" or flag == "no" then
            redundant = false
        elseif flag == "sapling" or flag == "saplings" then
            return nil, nil, nil, "world.foliage.tree." .. tostring(verb) .. ".all supports full trees only"
        elseif flag == "unbounded" or flag == "unlimited" or flag == "allloaded" or flag == "all_loaded" then
            unbounded = true
        elseif n ~= nil then
            numeric_count = numeric_count + 1
            if numeric_count == 1 then
                if n > MAX_FOREST_LIMIT then
                    return nil, nil, nil, "limit too high for all-loaded tree action: max " .. tostring(MAX_FOREST_LIMIT) .. " per command, or pass unbounded to run the old full sweep"
                end
                limit = clamp_int(n, 1, MAX_FOREST_LIMIT)
            elseif numeric_count == 2 then
                convert_distance = clamp_number(n, 1, 1000)
            else
                return nil, nil, nil, "too many numeric args"
            end
        else
            return nil, nil, nil, "unknown flag: " .. tostring(word)
        end
    end

    if not confirmed then
        return nil, nil, nil, "usage: world.foliage.forest." .. tostring(verb) .. ".all confirm [limit<=250|unbounded] [convertDistance] [redundant|keepdepiction]"
    end
    if limit == nil and not unbounded then
        return nil, nil, nil, "refusing unbounded all-loaded tree action on the game thread; add a limit like 250, or pass unbounded to run the old full sweep"
    end
    return limit, convert_distance, redundant, nil
end

local function parse_single_tree_args(args, verb)
    local words = split_words(args)
    local convert_distance = DEFAULT_SINGLE_CONVERT_DISTANCE
    local redundant = false
    local numeric_seen = false

    for _, word in ipairs(words) do
        local flag = string.lower(tostring(word or ""))
        local n = tonumber(word)
        if flag == "tree" or flag == "target" or flag == "single" or flag == "lookat" then
        elseif flag == "redundant" or flag == "persist" or flag == "persistent" or flag == "save" or flag == "true" or flag == "yes" then
            redundant = true
        elseif flag == "keepdepiction" or flag == "keep" or flag == "false" or flag == "no" then
            if normalize_tree_verb(verb) == "destroy" then
                return nil, nil, "world.foliage.tree.destroy.single always marks the depiction redundant before destroy"
            end
            redundant = false
        elseif n ~= nil then
            if numeric_seen then return nil, nil, "too many numeric args" end
            convert_distance = clamp_number(n, 1, 1000)
            numeric_seen = true
        else
            return nil, nil, "unknown flag: " .. tostring(word)
        end
    end

    if normalize_tree_verb(verb) == "convert" then redundant = false end
    if normalize_tree_verb(verb) == "destroy" then redundant = true end
    return convert_distance, redundant, nil
end

local function run_convert_targets(action_name, center, origin, category, radius, limit, convert_distance, after_verb, redundant)
    after_verb = after_verb and normalize_tree_verb(after_verb) or nil
    local lib = get_foliage_library()
    if not lib then return false, "InteractableFoliageFunctionLibrary CDO not found" end

    local context, requirer = world_context()
    if not context then return false, "no world context" end

    local targets, stats = collect_instance_targets(category, center, radius, limit)
    local results = {}
    local converted_count = 0
    local success_count = 0
    local failure_count = 0

    for _, target in ipairs(targets) do
        local ok_call, call_err = false, nil
        if target.location then
            ok_call, call_err = pcall(function()
                return lib:ConvertFoliageNearbyLocation(context, target.location, convert_distance, true, true, requirer)
            end)
        else
            call_err = target.transform_error or "no instance location"
        end

        local tree = ok_call and resource_actor_near_location(target.location, TREE_LOOKUP_RADIUS_AFTER_CONVERT, target.category or category) or nil
        if ok_call then
            converted_count = converted_count + 1
            remember_converted_target(target, tree)
        end

        local result = {
            action = after_verb or "convert",
            ok = ok_call,
            convert_ok = ok_call,
            convert_error = ok_call and nil or tostring(call_err),
            category = target.category,
            component_class = target.component_class,
            owner = target.owner,
            mesh = target.mesh,
            instance_index = target.index,
            distance = target.distance_sq < math.huge and math.sqrt(target.distance_sq) or nil,
            convert_distance = convert_distance,
            tree = object_short_name(tree),
            tree_class = tree and class_name(tree) or nil,
            location = target.location,
        }

        local ok_result = ok_call
        if after_verb then
            if is_valid(tree) then
                local ok_tree, tree_result = apply_tree_action(tree, after_verb, redundant)
                ok_result = ok_call and ok_tree
                for k, v in pairs(tree_result) do
                    if result[k] == nil then result[k] = v end
                end
                result.tree_action_ok = ok_tree
            else
                ok_result = false
                result.tree_action_ok = false
                result.error = ok_call and "converted, but no tree/sapling actor resolved" or result.convert_error
            end
        end
        result.ok = ok_result

        if ok_result then success_count = success_count + 1 else failure_count = failure_count + 1 end
        results[#results + 1] = result
    end

    local meta = {
        action = action_name,
        category = category,
        origin = origin,
        radius = radius,
        limit = limit,
        convert_distance = convert_distance,
        redundant = after_verb == "redundant" or after_verb == "destroy" or redundant,
        requested_count = #targets,
        success_count = success_count,
        failure_count = failure_count,
        component_count = stats.component_count,
        matching_components = stats.matching_components,
        near_instance_count = stats.near_instance_count,
    }
    local ok_write, path_or_err = write_action(meta, results)
    if not ok_write then return false, path_or_err end

    local nearest = (#targets > 0 and targets[1].distance_sq < math.huge) and math.sqrt(targets[1].distance_sq) or nil
    local nearest_text = nearest and string.format(" nearest=%.1f", nearest) or ""
    if after_verb then
        return true, string.format("origin=%s targets=%d converted=%d %s=%d failed=%d near=%d%s file=%s",
            tostring(origin), #targets, converted_count, after_verb, success_count, failure_count, stats.near_instance_count, nearest_text, path_or_err)
    end
    return true, string.format("origin=%s category=%s targets=%d converted=%d failed=%d near=%d%s file=%s",
        tostring(origin), category, #targets, converted_count, failure_count, stats.near_instance_count, nearest_text, path_or_err)
end

local function run_single_tree_action(verb, args)
    verb = normalize_tree_verb(verb)
    if verb ~= "convert" and verb ~= "stump" and verb ~= "split" and verb ~= "destroy" then
        return false, "unsupported single tree action: " .. tostring(verb)
    end

    local convert_distance, redundant, err = parse_single_tree_args(args, verb)
    if err then return false, err end
    local picker = feature_grab.pick_hit_under_reticle or feature_grab.pick_location_under_reticle or feature_grab.pick_target_under_reticle
    if not picker then
        return false, "camera lookat target helper unavailable"
    end

    local actor, hit_loc, source, pick_err, hit_details = picker()
    if not hit_loc then return false, tostring(pick_err or "no lookat location") end

    local origin = "lookat." .. tostring(source or "unknown")
    local label = object_short_name(actor)
    if label then origin = origin .. ":" .. label end

    local stats = { component_count = 0, matching_components = 0, near_instance_count = 0 }
    local results = {}
    local converted_count = 0
    local success_count = 0
    local failure_count = 0
    local resolved_tree = nil
    local result = nil
    local ok_result = false

    local direct_tree = is_fellable_tree_actor(actor) and actor or resource_actor_near_location(hit_loc, TREE_LOOKUP_RADIUS_AFTER_CONVERT, "tree")
    if not label and is_fellable_tree_actor(direct_tree) then
        label = object_short_name(direct_tree)
        if label then origin = origin .. ":" .. label end
    end

    if is_fellable_tree_actor(direct_tree) then
        resolved_tree = direct_tree
        local direct_source = direct_tree == actor and "actor" or "lookup"
        if verb == "convert" then
            ok_result = true
            result = {
                action = "convert",
                ok = true,
                source = direct_source,
                already_actor = true,
                category = "tree",
                tree = object_short_name(direct_tree),
                tree_class = class_name(direct_tree),
                location = actor_location(direct_tree) or hit_loc,
            }
        else
            ok_result, result = apply_tree_action(direct_tree, verb, redundant)
            result.source = direct_source
            result.category = "tree"
            result.location = actor_location(direct_tree) or hit_loc
        end
    else
        local fallback_target, collected_stats = collect_single_tree_instance_target(hit_loc)
        stats = collected_stats or stats
        local instance_target, instance_target_err = instance_target_from_hit(hit_details, hit_loc, fallback_target)
        local source_kind = instance_target and instance_target.source or "lookup.instance"
        local target_category = instance_target and instance_target.category or "tree"
        local target_location = (instance_target and instance_target.location) or hit_loc
        local target_distance = (instance_target and instance_target.distance_sq and instance_target.distance_sq < math.huge) and math.sqrt(instance_target.distance_sq) or nil
        local target_distance_xy = instance_target and instance_target.distance_xy_sq and math.sqrt(instance_target.distance_xy_sq) or nil
        local convert_ok = false
        local convert_err = instance_target_err

        if instance_target and instance_target.location then
            resolved_tree = resource_actor_near_location(instance_target.location, TREE_LOOKUP_RADIUS_AFTER_CONVERT, "tree")
        end
        if not is_fellable_tree_actor(resolved_tree) then
            resolved_tree = nil
        end

        if not is_fellable_tree_actor(resolved_tree) and instance_target then
            convert_ok, resolved_tree, convert_err = convert_instance_target_to_actor(instance_target, convert_distance, "tree")
            if convert_ok then converted_count = 1 end
        end

        if is_fellable_tree_actor(resolved_tree) and not label then
            label = object_short_name(resolved_tree)
            if label then origin = origin .. ":" .. label end
        end

        if not is_fellable_tree_actor(resolved_tree) then
            ok_result = false
            result = {
                action = verb,
                ok = false,
                source = source_kind,
                convert_ok = convert_ok,
                convert_error = tostring(convert_err or "no tree foliage instance under reticle"),
                error = convert_ok and "converted, but no FellableTree actor resolved" or tostring(convert_err or "no tree foliage instance under reticle"),
                category = target_category,
                component_class = instance_target and instance_target.component_class or nil,
                owner = instance_target and instance_target.owner or nil,
                mesh = instance_target and instance_target.mesh or nil,
                instance_index = instance_target and instance_target.index or nil,
                hit_item = hit_details and hit_details.item or nil,
                distance = target_distance,
                distance_xy = target_distance_xy,
                convert_distance = convert_distance,
                location = target_location,
            }
        elseif verb == "convert" then
            ok_result = true
            result = {
                action = "convert",
                ok = true,
                source = source_kind,
                already_actor = not convert_ok,
                convert_ok = convert_ok,
                category = target_category,
                component_class = instance_target and instance_target.component_class or nil,
                owner = instance_target and instance_target.owner or nil,
                mesh = instance_target and instance_target.mesh or nil,
                instance_index = instance_target and instance_target.index or nil,
                distance = target_distance,
                distance_xy = target_distance_xy,
                convert_distance = convert_distance,
                tree = object_short_name(resolved_tree),
                tree_class = class_name(resolved_tree),
                location = actor_location(resolved_tree) or target_location,
            }
        else
            local ok_tree, tree_result = apply_tree_action(resolved_tree, verb, redundant)
            ok_result = ok_tree
            result = tree_result
            result.source = source_kind
            result.convert_ok = convert_ok
            result.category = target_category
            result.component_class = instance_target and instance_target.component_class or nil
            result.owner = instance_target and instance_target.owner or nil
            result.mesh = instance_target and instance_target.mesh or nil
            result.instance_index = instance_target and instance_target.index or nil
            result.distance = target_distance
            result.distance_xy = target_distance_xy
            result.convert_distance = convert_distance
            result.location = actor_location(resolved_tree) or target_location
            result.tree_action_ok = ok_tree
        end
    end

    result.ok = ok_result
    if ok_result then success_count = 1 else failure_count = 1 end
    results[#results + 1] = result

    local meta = {
        action = "tree." .. verb .. ".single",
        category = "tree",
        origin = origin,
        radius = SINGLE_LOOKAT_PICK_RADIUS,
        limit = 1,
        convert_distance = convert_distance,
        redundant = redundant,
        requested_count = 1,
        success_count = success_count,
        failure_count = failure_count,
        component_count = stats.component_count,
        matching_components = stats.matching_components,
        near_instance_count = stats.near_instance_count,
    }
    local ok_write, path_or_err = write_action(meta, results)
    if not ok_write then return false, path_or_err end

    local command_ok = failure_count == 0 and success_count > 0
    if verb == "convert" then
        local resolved = is_valid(resolved_tree) and 1 or 0
        return command_ok, string.format("origin=%s converted=%d resolved=%d failed=%d file=%s",
            tostring(origin), converted_count, resolved, failure_count, path_or_err)
    end
    if verb == "destroy" then
        return command_ok, string.format("origin=%s converted=%d destroyed=%d failed=%d file=%s",
            tostring(origin), converted_count, success_count, failure_count, path_or_err)
    end
    return command_ok, string.format("origin=%s converted=%d %s=%d failed=%d redundant=%s file=%s",
        tostring(origin), converted_count, verb, success_count, failure_count, tostring(redundant), path_or_err)
end

local function run_destroy_targets(action_name, center, origin, category, radius, limit, convert_distance)
    local actor_targets = collect_resource_actors_near(category, center, radius, limit)
    local remaining_limit = limit - #actor_targets
    if remaining_limit < 0 then remaining_limit = 0 end

    local stats = { component_count = 0, matching_components = 0, near_instance_count = 0 }
    local instance_targets = {}
    if remaining_limit > 0 then
        instance_targets, stats = collect_instance_targets(category, center, radius, remaining_limit)
    end

    local context, requirer = nil, nil
    local conversion_err = nil
    local lib = nil
    if #instance_targets > 0 then
        lib = get_foliage_library()
        if lib then
            context, requirer = world_context()
            if not context then conversion_err = "no world context" end
        else
            conversion_err = "InteractableFoliageFunctionLibrary CDO not found"
        end
    end

    local results = {}
    local converted_count = 0
    local success_count = 0
    local failure_count = 0

    for _, target in ipairs(actor_targets) do
        local ok_result, result = apply_tree_action(target.object, "destroy", true)
        if ok_result then success_count = success_count + 1 else failure_count = failure_count + 1 end
        result.source = "actor"
        result.category = target.category
        result.distance = math.sqrt(target.distance_sq)
        result.location = target.location
        results[#results + 1] = result
    end

    for _, target in ipairs(instance_targets) do
        local ok_call, call_err = false, nil
        if conversion_err then
            call_err = conversion_err
        elseif target.location then
            ok_call, call_err = pcall(function()
                return lib:ConvertFoliageNearbyLocation(context, target.location, convert_distance, true, true, requirer)
            end)
        else
            call_err = target.transform_error or "no instance location"
        end

        local tree = ok_call and resource_actor_near_location(target.location, TREE_LOOKUP_RADIUS_AFTER_CONVERT, target.category or category) or nil
        if ok_call then
            converted_count = converted_count + 1
            remember_converted_target(target, tree)
        end

        local result = {
            action = "destroy",
            ok = ok_call,
            source = "instance",
            convert_ok = ok_call,
            convert_error = ok_call and nil or tostring(call_err),
            category = target.category,
            component_class = target.component_class,
            owner = target.owner,
            mesh = target.mesh,
            instance_index = target.index,
            distance = target.distance_sq < math.huge and math.sqrt(target.distance_sq) or nil,
            convert_distance = convert_distance,
            tree = object_short_name(tree),
            tree_class = tree and class_name(tree) or nil,
            location = target.location,
        }

        local ok_result = ok_call
        if is_valid(tree) then
            local ok_tree, tree_result = apply_tree_action(tree, "destroy", true)
            ok_result = ok_call and ok_tree
            for key, value in pairs(tree_result) do
                if result[key] == nil then result[key] = value end
            end
            result.tree_action_ok = ok_tree
        else
            ok_result = false
            result.tree_action_ok = false
            result.error = ok_call and "converted, but no tree/sapling actor resolved" or result.convert_error
        end
        result.ok = ok_result

        if ok_result then success_count = success_count + 1 else failure_count = failure_count + 1 end
        results[#results + 1] = result
    end

    local meta = {
        action = action_name,
        category = category,
        origin = origin,
        radius = radius,
        limit = limit,
        convert_distance = convert_distance,
        redundant = true,
        requested_count = #actor_targets + #instance_targets,
        success_count = success_count,
        failure_count = failure_count,
        component_count = stats.component_count,
        matching_components = stats.matching_components,
        near_instance_count = stats.near_instance_count,
    }
    local ok_write, path_or_err = write_action(meta, results)
    if not ok_write then return false, path_or_err end

    local nearest = (#instance_targets > 0 and instance_targets[1].distance_sq < math.huge) and math.sqrt(instance_targets[1].distance_sq) or nil
    local nearest_text = nearest and string.format(" nearest=%.1f", nearest) or ""
    return true, string.format("origin=%s category=%s actors=%d targets=%d converted=%d destroyed=%d failed=%d near=%d%s file=%s",
        tostring(origin), tostring(category), #actor_targets, #instance_targets, converted_count, success_count, failure_count, stats.near_instance_count, nearest_text, path_or_err)
end

local function run_destroy_all_targets(category, limit, convert_distance)
    local actor_targets = collect_resource_actors_all(category, limit)

    local remaining_limit = limit and (limit - #actor_targets) or nil
    if remaining_limit and remaining_limit < 0 then remaining_limit = 0 end

    local stats = { component_count = 0, matching_components = 0, near_instance_count = 0 }
    local instance_targets = {}
    if remaining_limit == nil or remaining_limit > 0 then
        instance_targets, stats = collect_all_instance_targets(category, remaining_limit)
    end

    local context, requirer = nil, nil
    local conversion_err = nil
    local lib = nil
    if #instance_targets > 0 then
        lib = get_foliage_library()
        if lib then
            context, requirer = world_context()
            if not context then conversion_err = "no world context" end
        else
            conversion_err = "InteractableFoliageFunctionLibrary CDO not found"
        end
    end

    local results = {}
    local converted_count = 0
    local success_count = 0
    local failure_count = 0

    for _, target in ipairs(actor_targets) do
        local ok_result, result = apply_tree_action(target.object, "destroy", true)
        if ok_result then success_count = success_count + 1 else failure_count = failure_count + 1 end
        result.source = "actor"
        result.category = target.category
        result.location = target.location
        results[#results + 1] = result
    end

    for _, target in ipairs(instance_targets) do
        local ok_call, call_err = false, nil
        if conversion_err then
            call_err = conversion_err
        elseif target.location then
            ok_call, call_err = pcall(function()
                return lib:ConvertFoliageNearbyLocation(context, target.location, convert_distance, true, true, requirer)
            end)
        else
            call_err = target.transform_error or "no instance location"
        end

        local tree = ok_call and resource_actor_near_location(target.location, TREE_LOOKUP_RADIUS_AFTER_CONVERT, target.category or category) or nil
        if ok_call then
            converted_count = converted_count + 1
            remember_converted_target(target, tree)
        end

        local result = {
            action = "destroy",
            ok = ok_call,
            source = "instance",
            convert_ok = ok_call,
            convert_error = ok_call and nil or tostring(call_err),
            category = target.category,
            component_class = target.component_class,
            owner = target.owner,
            mesh = target.mesh,
            instance_index = target.index,
            convert_distance = convert_distance,
            tree = object_short_name(tree),
            tree_class = tree and class_name(tree) or nil,
            location = target.location,
        }

        local ok_result = ok_call
        if is_valid(tree) then
            local ok_tree, tree_result = apply_tree_action(tree, "destroy", true)
            ok_result = ok_call and ok_tree
            for key, value in pairs(tree_result) do
                if result[key] == nil then result[key] = value end
            end
            result.tree_action_ok = ok_tree
        else
            ok_result = false
            result.tree_action_ok = false
            result.error = ok_call and "converted, but no tree/sapling actor resolved" or result.convert_error
        end
        result.ok = ok_result

        if ok_result then success_count = success_count + 1 else failure_count = failure_count + 1 end
        results[#results + 1] = result
    end

    local meta = {
        action = "tree.destroy.all",
        category = category,
        origin = "all.loaded",
        radius = nil,
        limit = limit,
        convert_distance = convert_distance,
        redundant = true,
        requested_count = #actor_targets + #instance_targets,
        success_count = success_count,
        failure_count = failure_count,
        component_count = stats.component_count,
        matching_components = stats.matching_components,
        near_instance_count = stats.near_instance_count,
    }
    local ok_write, path_or_err = write_action(meta, results)
    if not ok_write then return false, path_or_err end

    return true, string.format("origin=all.loaded category=%s actors=%d targets=%d converted=%d destroyed=%d failed=%d all_instances=%d file=%s",
        tostring(category), #actor_targets, #instance_targets, converted_count, success_count, failure_count, stats.near_instance_count, path_or_err)
end

local function run_tree_all_action(verb, limit, convert_distance, redundant)
    verb = normalize_tree_verb(verb)
    if verb ~= "stump" and verb ~= "split" then
        return false, "unsupported all tree action: " .. tostring(verb)
    end

    local actor_targets = collect_resource_actors_all("tree", limit)
    local remaining_limit = limit and (limit - #actor_targets) or nil
    if remaining_limit and remaining_limit < 0 then remaining_limit = 0 end

    local stats = { component_count = 0, matching_components = 0, near_instance_count = 0 }
    local instance_targets = {}
    if remaining_limit == nil or remaining_limit > 0 then
        instance_targets, stats = collect_all_instance_targets("tree", remaining_limit)
    end

    local context, requirer = nil, nil
    local conversion_err = nil
    local lib = nil
    if #instance_targets > 0 then
        lib = get_foliage_library()
        if lib then
            context, requirer = world_context()
            if not context then conversion_err = "no world context" end
        else
            conversion_err = "InteractableFoliageFunctionLibrary CDO not found"
        end
    end

    local results = {}
    local converted_count = 0
    local success_count = 0
    local failure_count = 0

    for _, target in ipairs(actor_targets) do
        local ok_result, result = apply_tree_action(target.object, verb, redundant)
        if ok_result then success_count = success_count + 1 else failure_count = failure_count + 1 end
        result.source = "actor"
        result.category = target.category
        result.location = target.location
        results[#results + 1] = result
    end

    for _, target in ipairs(instance_targets) do
        local ok_call, call_err = false, nil
        if conversion_err then
            call_err = conversion_err
        elseif target.location then
            ok_call, call_err = pcall(function()
                return lib:ConvertFoliageNearbyLocation(context, target.location, convert_distance, true, true, requirer)
            end)
        else
            call_err = target.transform_error or "no instance location"
        end

        local tree = ok_call and resource_actor_near_location(target.location, TREE_LOOKUP_RADIUS_AFTER_CONVERT, "tree") or nil
        if ok_call then
            converted_count = converted_count + 1
            remember_converted_target(target, tree)
        end

        local result = {
            action = verb,
            ok = ok_call,
            source = "instance",
            convert_ok = ok_call,
            convert_error = ok_call and nil or tostring(call_err),
            category = target.category,
            component_class = target.component_class,
            owner = target.owner,
            mesh = target.mesh,
            instance_index = target.index,
            convert_distance = convert_distance,
            tree = object_short_name(tree),
            tree_class = tree and class_name(tree) or nil,
            location = target.location,
        }

        local ok_result = ok_call
        if is_valid(tree) then
            local ok_tree, tree_result = apply_tree_action(tree, verb, redundant)
            ok_result = ok_call and ok_tree
            for key, value in pairs(tree_result) do
                if result[key] == nil then result[key] = value end
            end
            result.tree_action_ok = ok_tree
        else
            ok_result = false
            result.tree_action_ok = false
            result.error = ok_call and "converted, but no FellableTree resolved" or result.convert_error
        end
        result.ok = ok_result

        if ok_result then success_count = success_count + 1 else failure_count = failure_count + 1 end
        results[#results + 1] = result
    end

    local meta = {
        action = "tree." .. verb .. ".all",
        category = "tree",
        origin = "all.loaded",
        radius = nil,
        limit = limit,
        convert_distance = convert_distance,
        redundant = redundant,
        requested_count = #actor_targets + #instance_targets,
        success_count = success_count,
        failure_count = failure_count,
        component_count = stats.component_count,
        matching_components = stats.matching_components,
        near_instance_count = stats.near_instance_count,
    }
    local ok_write, path_or_err = write_action(meta, results)
    if not ok_write then return false, path_or_err end

    return true, string.format("origin=all.loaded category=tree actors=%d targets=%d converted=%d %s=%d failed=%d redundant=%s all_instances=%d file=%s",
        #actor_targets, #instance_targets, converted_count, verb, success_count, failure_count, tostring(redundant), stats.near_instance_count, path_or_err)
end

function M.convert_lookat(args)
    local category, radius, limit, convert_distance, err = parse_lookat_convert_args(args)
    if err then return false, err end
    local center, origin, label = foliage_lookat_center(category)
    if not center then return false, origin end
    if label then origin = origin .. ":" .. label end
    return run_convert_targets("convert.lookat", center, origin, category, radius, limit, convert_distance, nil, false)
end

function M.tree_convert_single(args)
    return run_single_tree_action("convert", args)
end

function M.tree_stump_single(args)
    return run_single_tree_action("stump", args)
end

function M.tree_split_single(args)
    return run_single_tree_action("split", args)
end

function M.tree_destroy_single(args)
    return run_single_tree_action("destroy", args)
end

local function run_tree_lookat(verb, args)
    verb = normalize_tree_verb(verb)
    local category, radius, limit, convert_distance, redundant, err = parse_forest_action_args(args, verb)
    if err then return false, err end
    local center, origin, label = foliage_lookat_center(category)
    if not center then return false, origin end
    if label then origin = origin .. ":" .. label end
    if verb == "destroy" then
        return run_destroy_targets("tree.destroy.lookat", center, origin, category, radius, limit, convert_distance)
    end
    return run_convert_targets("tree." .. verb .. ".lookat", center, origin, category, radius, limit, convert_distance, verb, redundant)
end

function M.tree_stump_lookat(args)
    return run_tree_lookat("stump", args)
end

function M.tree_split_lookat(args)
    return run_tree_lookat("split", args)
end

function M.tree_redundant_lookat(args)
    return run_tree_lookat("redundant", args)
end

function M.tree_destroy_lookat(args)
    return run_tree_lookat("destroy", args)
end

function M.tree_destroy_all(args)
    local category, limit, convert_distance, err = parse_destroy_all_args(args)
    if err then return false, err end
    return run_destroy_all_targets(category, limit, convert_distance)
end

function M.tree_stump_all(args)
    local limit, convert_distance, redundant, err = parse_tree_all_action_args(args, "stump")
    if err then return false, err end
    return run_tree_all_action("stump", limit, convert_distance, redundant)
end

function M.tree_split_all(args)
    local limit, convert_distance, redundant, err = parse_tree_all_action_args(args, "split")
    if err then return false, err end
    return run_tree_all_action("split", limit, convert_distance, redundant)
end

function M.tree_stump_near(args)
    return run_tree_action("stump", args)
end

function M.tree_split_near(args)
    return run_tree_action("split", args)
end

function M.tree_redundant_near(args)
    return run_tree_action("redundant", args)
end

function M.tree_destroy_near(args)
    return run_tree_action("destroy", args)
end

return M