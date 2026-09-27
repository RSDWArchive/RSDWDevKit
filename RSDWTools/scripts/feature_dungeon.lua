-- feature_dungeon.lua
-- Read-only probes for the dormant/live dungeon surfaces.

local M = {}

local feature_actor = require("feature_actor")
local mod_paths = require("mod_paths")
local safety = require("safety")

local DEFAULT_SAMPLE_LIMIT = 6
local MAX_SAMPLE_LIMIT = 25

local CLASS_SPECS = {
    {
        key = "DungeonSubsystem",
        queries = { "DungeonSubsystem" },
        fields = {
            { name = "PlayersInDungeonsData", mode = "count" },
        },
    },
    {
        key = "DungeonSpawnManager",
        queries = { "DungeonSpawnManager" },
        fields = {
            { name = "SpawnedDungeons", mode = "count" },
        },
    },
    {
        key = "GameplayObjectRegistry",
        queries = { "GameplayObjectRegistry" },
        fields = {
            { name = "Dungeons", mode = "count" },
        },
    },
    {
        key = "Dungeon",
        queries = { "Dungeon" },
        fields = {
            { name = "DungeonEntrance", mode = "soft" },
            { name = "DungeonExit", mode = "soft" },
        },
    },
    {
        key = "DungeonTeleport",
        queries = { "DungeonTeleport" },
        fields = {
            { name = "DungeonState", mode = "value" },
            { name = "BiomeType", mode = "value" },
            { name = "CustomSeed", mode = "value" },
            { name = "Client_DungeonSeed", mode = "value" },
            { name = "DungeonInterface", mode = "object" },
        },
    },
    {
        key = "DungeonTeleportBossGym",
        queries = { "DungeonTeleportBossGym" },
        fields = {
            { name = "TargetToTeleport", mode = "object" },
            { name = "TargetToSpawnBoss", mode = "object" },
            { name = "BossActorClass", mode = "object" },
            { name = "bIsSpawnBossOnEnterGym", mode = "value" },
        },
    },
    {
        key = "DungeonModel",
        queries = { "DungeonModel" },
        fields = {
            { name = "Client_DungeonSeed", mode = "value" },
            { name = "DungeonGenerator", mode = "object" },
            { name = "ItemSpawnManager", mode = "object" },
            { name = "DungeonDoorsManager", mode = "object" },
            { name = "CharacterManager", mode = "object" },
        },
    },
    {
        key = "MapGenerationSettings",
        queries = { "MapGenerationSettings" },
        fields = {
            { name = "DungeonDepth", mode = "value" },
            { name = "DungeonDeleteDelay", mode = "value" },
            { name = "DungeonGeneratorV2", mode = "soft" },
        },
    },
    { key = "DungeonController", queries = { "DungeonController" }, fields = {} },
    { key = "MiniBossGymSubsystem", queries = { "MiniBossGymSubsystem" }, fields = {} },
    { key = "DungeonChest", queries = { "DungeonChest" }, fields = {} },
    { key = "DungeonSpawner", queries = { "DungeonSpawner" }, fields = {} },
    { key = "DungeonChestSpawner", queries = { "DungeonChestSpawner" }, fields = {} },
    { key = "DungeonRoomUnit", queries = { "DungeonRoomUnit" }, fields = {} },
    { key = "DungeonHallwayUnit", queries = { "DungeonHallwayUnit" }, fields = {} },
    { key = "DungeonTriggerBox", queries = { "DungeonTriggerBox" }, fields = {} },
    { key = "ResourceSpawnVolume", queries = { "ResourceSpawnVolume" }, fields = {} },
    { key = "Lever", queries = { "Lever" }, fields = {} },
}

local STATIC_OBJECTS = {
    {
        key = "DominionRuntimeBlueprintLibrary",
        path = "/Script/Dominion.Default__DominionRuntimeBlueprintLibrary",
    },
    {
        key = "MapGenerationSettingsCDO",
        path = "/Script/Dungeon.Default__MapGenerationSettings",
        fields = {
            { name = "DungeonDepth", mode = "value" },
            { name = "DungeonDeleteDelay", mode = "value" },
            { name = "DungeonGeneratorV2", mode = "soft" },
        },
    },
}

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse_limit(args_str)
    local token = trim(args_str):match("^(%S+)")
    local limit = tonumber(token) or DEFAULT_SAMPLE_LIMIT
    limit = math.floor(limit)
    if limit < 1 then limit = 1 end
    if limit > MAX_SAMPLE_LIMIT then limit = MAX_SAMPLE_LIMIT end
    return limit
end

local function is_valid(obj)
    if type(obj) ~= "userdata" then return false end
    local valid_ok, valid_value = pcall(function() return obj:IsValid() end)
    if valid_ok then return valid_value == true end
    return safety.is_uobject(obj)
end

local function safe_full_name(obj)
    if type(obj) ~= "userdata" then return "" end
    local full_ok, full_name = pcall(function() return obj:GetFullName() end)
    if full_ok and type(full_name) == "string" and full_name ~= "" then return full_name end
    local name_ok, short_name = pcall(function() return obj:GetName() end)
    if name_ok and type(short_name) == "string" then return short_name end
    return ""
end

local function safe_name(obj)
    if type(obj) ~= "userdata" then return "" end
    local name_ok, short_name = pcall(function() return obj:GetName() end)
    if name_ok and type(short_name) == "string" and short_name ~= "" then return short_name end
    local full_name = safe_full_name(obj)
    return full_name:match("([^%.%s]+)$") or full_name
end

local function object_key(obj)
    local full_name = safe_full_name(obj)
    if full_name ~= "" then return full_name end
    return tostring(obj)
end

local function is_default_object(obj)
    local full_name = safe_full_name(obj)
    return full_name:find("Default__", 1, true) ~= nil
end

local function vec_text(loc)
    if not loc then return "" end
    local x_value, y_value, z_value = 0, 0, 0
    pcall(function() x_value = tonumber(loc.X) or 0 end)
    pcall(function() y_value = tonumber(loc.Y) or 0 end)
    pcall(function() z_value = tonumber(loc.Z) or 0 end)
    return string.format("%.1f,%.1f,%.1f", x_value, y_value, z_value)
end

local function object_location_text(obj)
    local loc = nil
    pcall(function() loc = feature_actor.actor_location(obj) end)
    if not loc then return "" end
    return vec_text(loc)
end

local function vec_arg(loc)
    local x_value, y_value, z_value = 0, 0, 0
    pcall(function() x_value = tonumber(loc.X) or 0 end)
    pcall(function() y_value = tonumber(loc.Y) or 0 end)
    pcall(function() z_value = tonumber(loc.Z) or 0 end)
    return { X = x_value, Y = y_value, Z = z_value }
end

local function soft_path_of_safe(value)
    if value == nil then return nil end
    local object_id_ok, object_id = pcall(function() return value:GetObjectID() end)
    if not object_id_ok or object_id == nil then return nil end
    local asset_name_ok, asset_name = pcall(function() return object_id:GetAssetPathName() end)
    if not asset_name_ok or asset_name == nil then return nil end
    local string_ok, asset_path = pcall(function() return asset_name:ToString() end)
    if not string_ok or type(asset_path) ~= "string" or asset_path == "" or asset_path == "None" then
        return nil
    end
    local sub_ok, sub_path = pcall(function() return object_id:GetSubPathString() end)
    if sub_ok and sub_path ~= nil then
        local sub_string_ok, sub_string = pcall(function() return sub_path:ToString() end)
        if sub_string_ok and type(sub_string) == "string" and sub_string ~= "" then
            return asset_path .. ":" .. sub_string
        end
    end
    return asset_path
end

local function value_label(value)
    local value_type = type(value)
    if value == nil then return "<nil>" end
    if value_type == "boolean" or value_type == "number" then return tostring(value) end
    if value_type == "string" then return value end
    if value_type == "userdata" then
        local soft_path = soft_path_of_safe(value)
        if soft_path then return soft_path end
        if safety.is_uobject(value) then
            local class_name = safety.class_name_of(value) or "UObject"
            local name = safe_name(value)
            if name ~= "" then return class_name .. " '" .. name .. "'" end
            return class_name
        end
        return safety.describe(value)
    end
    return tostring(value)
end

local function container_count_text(value)
    if value == nil then return "<nil>" end
    local len_ok, len_value = pcall(function() return #value end)
    if len_ok and type(len_value) == "number" then return tostring(len_value) end
    local num_ok, num_value = pcall(function() return value:Num() end)
    if num_ok and type(num_value) == "number" then return tostring(num_value) end
    local foreach_count = 0
    local foreach_ok = pcall(function()
        value:ForEach(function(_key, _entry)
            foreach_count = foreach_count + 1
        end)
    end)
    if foreach_ok then return tostring(foreach_count) end
    return value_label(value)
end

local function field_value_text(obj, field_spec)
    local read_ok, value = pcall(function() return obj[field_spec.name] end)
    if not read_ok then return "<read failed: " .. tostring(value) .. ">" end
    if field_spec.mode == "count" then return container_count_text(value) end
    if field_spec.mode == "soft" then return soft_path_of_safe(value) or value_label(value) end
    return value_label(value)
end

local function collect_entry(entry, bucket, seen)
    if not is_valid(entry) then return end
    local key = object_key(entry)
    if seen[key] then return end
    seen[key] = true
    if is_default_object(entry) then
        bucket.defaults[#bucket.defaults + 1] = entry
    else
        bucket.live[#bucket.live + 1] = entry
    end
end

local function collect_from_plain_table(list, bucket, seen)
    for _table_key, entry in pairs(list) do
        collect_entry(entry, bucket, seen)
    end
end

local function collect_from_array_like(list, bucket, seen)
    local count = 0
    pcall(function() count = #list end)
    if count == 0 then
        local num_ok, num_value = pcall(function() return list:Num() end)
        if num_ok and type(num_value) == "number" then count = num_value end
    end
    for index = 1, count do
        local entry_ok, entry = pcall(function() return list[index] end)
        if entry_ok then collect_entry(entry, bucket, seen) end
    end
end

local function find_objects(queries)
    local bucket = { live = {}, defaults = {}, errors = {} }
    local seen = {}
    if not FindAllOf then
        bucket.errors[#bucket.errors + 1] = "FindAllOf unavailable"
        return bucket
    end
    for _query_index, class_name in ipairs(queries) do
        local find_ok, list_or_error = pcall(FindAllOf, class_name)
        if not find_ok then
            bucket.errors[#bucket.errors + 1] = tostring(class_name) .. ": " .. tostring(list_or_error)
        elseif list_or_error ~= nil then
            if type(list_or_error) == "table" then
                collect_from_plain_table(list_or_error, bucket, seen)
            else
                collect_from_array_like(list_or_error, bucket, seen)
            end
        end
    end
    return bucket
end

local function live_dungeons()
    local bucket = find_objects({ "Dungeon" })
    table.sort(bucket.live, function(left, right)
        return safe_full_name(left) < safe_full_name(right)
    end)
    return bucket.live, bucket.errors
end

local function read_object_field(obj, field_name)
    local read_ok, value = pcall(function() return obj[field_name] end)
    if read_ok and is_valid(value) then return value end
    -- Resolve only already-loaded soft references; never stream a dungeon to probe it.
    if read_ok and value ~= nil then
        local ok, loaded = pcall(function() return value:Get() end)
        if ok and is_valid(loaded) then return loaded end
        local path = soft_path_of_safe(value)
        if path and StaticFindObject then
            ok, loaded = pcall(StaticFindObject, path)
            if ok and is_valid(loaded) then return loaded end
        end
    end
    return nil
end

local function actor_location_safe(obj)
    local loc = nil
    pcall(function() loc = feature_actor.actor_location(obj) end)
    return loc
end

local function destination_from_location(loc, z_offset)
    local dest = vec_arg(loc)
    dest.Z = (dest.Z or 0) + (z_offset or 0)
    return dest
end

local function move_local_pawn_to(loc, z_offset)
    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return false, "no local pawn" end
    if not loc then return false, "no destination location" end
    local dest = destination_from_location(loc, z_offset)
    local move_ok, move_error = feature_actor.move_actor(pawn, dest)
    if not move_ok then return false, tostring(move_error or "move failed") end
    return true, dest
end

local function dungeon_ref_summary(obj, field_name)
    local ref = read_object_field(obj, field_name)
    if not ref then return { name = "", full_name = "", location = "" } end
    return {
        name = safe_name(ref),
        full_name = safe_full_name(ref),
        location = object_location_text(ref),
    }
end

local function dungeon_summary(index, obj)
    return {
        index = index,
        name = safe_name(obj),
        full_name = safe_full_name(obj),
        location = object_location_text(obj),
        entrance = dungeon_ref_summary(obj, "DungeonEntrance"),
        exit = dungeon_ref_summary(obj, "DungeonExit"),
    }
end

local function json_escape(value)
    local text = tostring(value or "")
    text = text:gsub("\\", "\\\\"):gsub('"', '\\"')
    text = text:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    text = text:gsub("[%z\1-\8\11\12\14-\31]", "")
    return text
end

local function is_array_table(value)
    local max_index = 0
    local item_count = 0
    for key, _entry in pairs(value) do
        if type(key) ~= "number" then return false end
        if key > max_index then max_index = key end
        item_count = item_count + 1
    end
    return max_index == item_count
end

local function json_value(value)
    local value_type = type(value)
    if value == nil then return "null" end
    if value_type == "boolean" then return value and "true" or "false" end
    if value_type == "number" then return tostring(value) end
    if value_type == "string" then return '"' .. json_escape(value) .. '"' end
    if value_type ~= "table" then return '"' .. json_escape(tostring(value)) .. '"' end

    local parts = {}
    if is_array_table(value) then
        parts[#parts + 1] = "["
        for index = 1, #value do
            if index > 1 then parts[#parts + 1] = "," end
            parts[#parts + 1] = json_value(value[index])
        end
        parts[#parts + 1] = "]"
    else
        local keys = {}
        for key, _entry in pairs(value) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        parts[#parts + 1] = "{"
        for index = 1, #keys do
            if index > 1 then parts[#parts + 1] = "," end
            local key = keys[index]
            parts[#parts + 1] = '"' .. json_escape(key) .. '":' .. json_value(value[key])
        end
        parts[#parts + 1] = "}"
    end
    return table.concat(parts)
end

local function static_find(path)
    if not StaticFindObject then return nil, "StaticFindObject unavailable" end
    local find_ok, object_or_error = pcall(StaticFindObject, path)
    if not find_ok then return nil, tostring(object_or_error) end
    if object_or_error == nil or not is_valid(object_or_error) then return nil, "not found" end
    return object_or_error, nil
end

local function runtime_library()
    return static_find("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
end

local function player_location_report()
    local result = {
        status = "unknown",
        location = "",
        reason = "",
    }
    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then
        result.reason = "no local pawn"
        return result
    end
    local loc = feature_actor.actor_location(pawn)
    if not loc then
        result.reason = "could not read player location"
        return result
    end
    result.location = vec_text(loc)
    local runtime, runtime_error = runtime_library()
    if not runtime then
        result.reason = "DominionRuntimeBlueprintLibrary: " .. tostring(runtime_error)
        return result
    end
    local fn_ok, inside_fn = pcall(function() return runtime["IsLocationInsideDungeon"] end)
    if not fn_ok then
        result.reason = "IsLocationInsideDungeon lookup failed: " .. tostring(inside_fn)
        return result
    end
    if inside_fn == nil then
        result.reason = "IsLocationInsideDungeon missing"
        return result
    end
    local loc_arg = vec_arg(loc)
    local call_ok, inside_or_error = pcall(function()
        return inside_fn(runtime, pawn, loc_arg)
    end)
    if not call_ok then
        result.reason = tostring(inside_or_error)
        return result
    end
    result.status = tostring(inside_or_error == true)
    return result
end

local function append_object_sample(report_entry, lines, obj, field_specs)
    local sample = {
        name = safe_name(obj),
        class = safety.class_name_of(obj) or "",
        full_name = safe_full_name(obj),
        location = object_location_text(obj),
        fields = {},
    }
    report_entry.samples[#report_entry.samples + 1] = sample

    local header = string.format("    - %s [%s]", sample.name ~= "" and sample.name or "<unnamed>", sample.class)
    if sample.location ~= "" then header = header .. " loc=" .. sample.location end
    lines[#lines + 1] = header

    for _field_index, field_spec in ipairs(field_specs or {}) do
        local text_value = field_value_text(obj, field_spec)
        sample.fields[field_spec.name] = text_value
        lines[#lines + 1] = string.format("        %s=%s", field_spec.name, text_value)
    end
end

local function append_class_report(report, lines, spec, sample_limit)
    local bucket = find_objects(spec.queries)
    local entry = {
        class = spec.key,
        queries = spec.queries,
        live_count = #bucket.live,
        default_count = #bucket.defaults,
        errors = bucket.errors,
        samples = {},
    }
    report.classes[#report.classes + 1] = entry

    lines[#lines + 1] = string.format("  %s: live=%d default=%d", spec.key, #bucket.live, #bucket.defaults)
    for error_index = 1, #bucket.errors do
        lines[#lines + 1] = "    error: " .. tostring(bucket.errors[error_index])
    end
    local max_sample = math.min(#bucket.live, sample_limit)
    for index = 1, max_sample do
        append_object_sample(entry, lines, bucket.live[index], spec.fields)
    end
end

local function append_static_report(report, lines)
    for _static_index, spec in ipairs(STATIC_OBJECTS) do
        local obj, find_error = static_find(spec.path)
        local entry = {
            key = spec.key,
            path = spec.path,
            found = obj ~= nil,
            error = find_error or "",
            name = obj and safe_name(obj) or "",
            class = obj and (safety.class_name_of(obj) or "") or "",
            fields = {},
        }
        report.static_objects[#report.static_objects + 1] = entry
        if obj then
            lines[#lines + 1] = string.format("  static %s: found class=%s", spec.key, entry.class)
            for _field_index, field_spec in ipairs(spec.fields or {}) do
                local text_value = field_value_text(obj, field_spec)
                entry.fields[field_spec.name] = text_value
                lines[#lines + 1] = string.format("      %s=%s", field_spec.name, text_value)
            end
        else
            lines[#lines + 1] = string.format("  static %s: missing (%s)", spec.key, tostring(find_error))
        end
    end
end

local function write_report_files(file_stem, report, lines)
    local ipc_dir = mod_paths.ipc_dir()
    if not ipc_dir then return false, "ipc dir unavailable" end
    pcall(os.execute, ('if not exist "%s" mkdir "%s"'):format(ipc_dir, ipc_dir))

    local json_path = ipc_dir .. "\\" .. file_stem .. ".json"
    local text_path = ipc_dir .. "\\" .. file_stem .. ".txt"
    local json_ok, json_result = mod_paths.write_atomic(json_path, json_value(report))
    local text_ok, text_result = mod_paths.write_atomic(text_path, table.concat(lines, "\n") .. "\n")
    if json_ok and text_ok then return true, json_result .. " ; " .. text_result end
    return false, tostring(json_result) .. " ; " .. tostring(text_result)
end

function M.probe(args_str)
    local sample_limit = parse_limit(args_str)
    local report = {
        command = "world.dungeon.probe",
        sample_limit = sample_limit,
        player = player_location_report(),
        static_objects = {},
        classes = {},
    }
    local lines = {
        "[RSDWTools] world.dungeon.probe --",
        string.format("  player: inside=%s loc=%s reason=%s", report.player.status, report.player.location, report.player.reason),
    }

    append_static_report(report, lines)
    for _spec_index, spec in ipairs(CLASS_SPECS) do
        append_class_report(report, lines, spec, sample_limit)
    end

    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_probe", report, lines)
    if write_ok then return true, "wrote " .. tostring(write_detail) end
    return true, "see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.list(args_str)
    local sample_limit = parse_limit(args_str)
    if trim(args_str) == "" then sample_limit = MAX_SAMPLE_LIMIT end
    local dungeons, errors = live_dungeons()
    local report = {
        command = "world.dungeon.list",
        count = #dungeons,
        sample_limit = sample_limit,
        errors = errors,
        dungeons = {},
    }
    local lines = {
        "[RSDWTools] world.dungeon.list --",
        string.format("  live ADungeon actors: %d", #dungeons),
    }
    for error_index = 1, #errors do
        lines[#lines + 1] = "  error: " .. tostring(errors[error_index])
    end
    local max_sample = math.min(#dungeons, sample_limit)
    for index = 1, max_sample do
        local entry = dungeon_summary(index, dungeons[index])
        report.dungeons[#report.dungeons + 1] = entry
        lines[#lines + 1] = string.format("  [%d] %s loc=%s", entry.index, entry.name, entry.location)
        lines[#lines + 1] = string.format("      entrance=%s loc=%s", entry.entrance.name, entry.entrance.location)
        lines[#lines + 1] = string.format("      exit=%s loc=%s", entry.exit.name, entry.exit.location)
    end
    if #dungeons > max_sample then
        lines[#lines + 1] = string.format("  ... +%d more; pass a larger limit up to %d", #dungeons - max_sample, MAX_SAMPLE_LIMIT)
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_list", report, lines)
    if write_ok then return true, "count=" .. tostring(#dungeons) .. " wrote " .. tostring(write_detail) end
    return true, "count=" .. tostring(#dungeons) .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.goto_dungeon(args_str)
    local args = trim(args_str)
    local index_token, mode = args:match("^(%S+)%s*(%S*)")
    if not index_token then return false, "usage: world.dungeon.goto <index> [entrance|exit|center]" end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    mode = trim(mode):lower()
    if mode == "" then mode = "entrance" end
    if mode == "c" then mode = "center" end
    if mode == "e" then mode = "entrance" end
    if mode == "x" then mode = "exit" end
    if mode ~= "center" and mode ~= "entrance" and mode ~= "exit" then
        return false, "mode must be entrance, exit, or center"
    end

    local dungeons = live_dungeons()
    if index < 1 or index > #dungeons then
        return false, string.format("index out of range 1..%d", #dungeons)
    end
    local dungeon = dungeons[index]
    local target = dungeon
    local target_label = "center"
    local z_offset = 200.0
    if mode == "entrance" then
        target = read_object_field(dungeon, "DungeonEntrance")
        target_label = "entrance"
        z_offset = 120.0
    elseif mode == "exit" then
        target = read_object_field(dungeon, "DungeonExit")
        target_label = "exit"
        z_offset = 120.0
    end
    if not is_valid(target) then return false, "target " .. target_label .. " is not a valid actor" end

    local loc = actor_location_safe(target)
    if not loc then return false, "could not read " .. target_label .. " location" end
    local move_ok, dest_or_error = move_local_pawn_to(loc, z_offset)
    if not move_ok then return false, dest_or_error end
    local detail = string.format("index=%d mode=%s dungeon=%s target=%s dest=%s",
        index, mode, safe_name(dungeon), safe_name(target), vec_text(dest_or_error))
    print("[RSDWTools] world.dungeon.goto " .. detail)
    return true, detail
end

function M.where()
    local result = player_location_report()
    local line = string.format("[RSDWTools] world.dungeon.where inside=%s loc=%s reason=%s",
        result.status, result.location, result.reason)
    print(line)
    return true, string.format("inside=%s loc=%s reason=%s", result.status, result.location, result.reason)
end

return M
