-- Shared player helpers for feature_player submodules.

local M = {}

local feature_actor = require("feature_actor")

function M.is_valid_object(obj)
    return feature_actor.is_valid_object(obj)
end

function M.get_pawn()
    local pawn = feature_actor.get_local_pawn()
    if not pawn or not M.is_valid_object(pawn) then
        return nil
    end
    return pawn
end

function M.parse_bool(v)
    if type(v) == "boolean" then return v end
    local s = tostring(v or ""):lower()
    if s == "on" or s == "1" or s == "true" or s == "yes" then return true end
    if s == "off" or s == "0" or s == "false" or s == "no" then return false end
    return nil
end

function M.parse_number(v)
    local n = tonumber(v)
    if not n then return nil end
    return n
end

function M.write_field(pawn, name, value)
    local before
    local ok_read, read_val = pcall(function() return pawn[name] end)
    if ok_read then before = read_val end

    local ok_write, err = pcall(function() pawn[name] = value end)
    if not ok_write then
        return false, "write failed: " .. tostring(err)
    end

    local after = value
    local ok_after, v_after = pcall(function() return pawn[name] end)
    if ok_after then after = v_after end

    print(string.format("[RSDWTools] player.%s: %s -> %s",
        name, tostring(before), tostring(after)))
    return true, tostring(after)
end

function M.call_bool_method(pawn, method_name, value)
    if type(pawn[method_name]) ~= "function" and not pawn[method_name] then
        return false, "method '" .. method_name .. "' not found on pawn"
    end
    local ok, err = pcall(function() pawn[method_name](pawn, value and true or false) end)
    if not ok then
        return false, method_name .. " failed: " .. tostring(err)
    end
    print(string.format("[RSDWTools] player.%s(%s)",
        method_name, tostring(value and true or false)))
    return true, value and "on" or "off"
end

function M.get_component(pawn, aliases)
    for i = 1, #aliases do
        local name = aliases[i]
        local ok, val = pcall(function() return pawn[name] end)
        if ok and val ~= nil then
            return val, name
        end
    end
    return nil, "component not found (tried: " .. table.concat(aliases, ", ") .. ")"
end

function M.write_comp_field(comp, alias, name, value)
    local before
    local ok_read, read_val = pcall(function() return comp[name] end)
    if ok_read then before = read_val end

    local ok_write, err = pcall(function() comp[name] = value end)
    if not ok_write then
        return false, "write " .. alias .. "." .. name .. " failed: " .. tostring(err)
    end

    local after = value
    local ok_after, v_after = pcall(function() return comp[name] end)
    if ok_after then after = v_after end

    print(string.format("[RSDWTools] %s.%s: %s -> %s",
        alias, name, tostring(before), tostring(after)))
    return true, tostring(after)
end

function M.call_comp_method(comp, alias, method_name, ...)
    local ok_probe, method = pcall(function() return comp[method_name] end)
    if not ok_probe or method == nil then
        return false, alias .. "." .. method_name .. " not found"
    end
    local args = {...}
    local ok, result = pcall(function()
        return comp[method_name](comp, table.unpack(args))
    end)
    if not ok then
        return false, alias .. ":" .. method_name .. " failed: " .. tostring(result)
    end
    return true, result
end

function M.unwrap_param(value)
    local current = value
    for _ = 1, 3 do
        if type(current) ~= "userdata" then break end
        local has_get = false
        pcall(function() has_get = (type(current.get) == "function") end)
        if not has_get then break end
        local ok_lower, inner_lower = pcall(function() return current:get() end)
        if ok_lower and inner_lower ~= nil and inner_lower ~= current then
            current = inner_lower
        else
            break
        end
    end
    return current
end

function M.is_valid_uobject_for_diag(value)
    if type(value) ~= "userdata" then return false end
    local ok_valid, valid = pcall(function() return value:IsValid() end)
    return ok_valid and valid == true
end

function M.uobject_label_for_diag(value)
    local ok_full, full = pcall(function() return value:GetFullName() end)
    if ok_full and full and tostring(full) ~= "" then return tostring(full) end
    local ok_name, name = pcall(function() return value:GetName() end)
    if ok_name and name and tostring(name) ~= "" then return tostring(name) end
    return "<uobject>"
end

function M.tarray_count(value)
    if type(value) ~= "userdata" then return nil end
    local ok_len, len = pcall(function() return #value end)
    if ok_len and type(len) == "number" then return len end
    local ok_num, num = pcall(function() return value:Num() end)
    if ok_num and type(num) == "number" then return num end
    local ok_array_num, array_num = pcall(function() return value:GetArrayNum() end)
    if ok_array_num and type(array_num) == "number" then return array_num end
    return nil
end

function M.tarray_get(value, index)
    local ok_index, item = pcall(function() return value[index] end)
    if ok_index and item ~= nil then return M.unwrap_param(item), true end
    local ok_get, got = pcall(function() return value:Get(index) end)
    if ok_get and got ~= nil then return M.unwrap_param(got), true end
    return nil, false
end

function M.value_label(value)
    value = M.unwrap_param(value)
    local kind = type(value)
    if value == nil then return "nil" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then return tostring(value) end
    if kind == "string" then return value end
    if kind == "table" then return "<table>" end
    if kind == "userdata" then
        if M.is_valid_uobject_for_diag(value) then return M.uobject_label_for_diag(value) end
        return "<userdata>"
    end
    return tostring(value)
end

function M.read_path(root, path)
    local current = root
    for segment in tostring(path or ""):gmatch("[^.]+") do
        current = M.unwrap_param(current)
        if current == nil then return false, "nil before " .. segment end
        local ok_read, value = pcall(function() return current[segment] end)
        if not ok_read then return false, tostring(value) end
        current = value
    end
    return true, M.unwrap_param(current)
end

function M.first_error_line(value)
    local text = tostring(value or "")
    return text:match("([^\r\n]+)") or text
end

function M.field_text(root, path)
    local ok_read, value = M.read_path(root, path)
    if not ok_read then return "<read failed: " .. M.first_error_line(value) .. ">" end
    if value == nil then return "nil" end
    local count = M.tarray_count(M.unwrap_param(value))
    if count then return string.format("%s <array count=%d>", M.value_label(value), count) end
    return M.value_label(value)
end

M.SPELLCASTING_COMP_ALIASES = {
    "SpellcastingComponent",
    "BP_Components_SpellcastingComponent",
    "BP_Components_Spellcasting",
}

function M.get_spellcasting_component(pawn)
    local pc = nil
    local ok, p = pcall(function() return pawn.PlayerController end)
    if ok and type(p) == "userdata" and M.is_valid_object(p) then
        pc = p
    end
    if not pc then
        local ok2, p2 = pcall(function() return pawn.Controller end)
        if ok2 and type(p2) == "userdata" and M.is_valid_object(p2) then
            pc = p2
        end
    end
    if not pc then return nil, "no PlayerController on pawn" end
    for _, alias in ipairs(M.SPELLCASTING_COMP_ALIASES) do
        local ok_c, comp = pcall(function() return pc[alias] end)
        if ok_c and type(comp) == "userdata" and M.is_valid_object(comp) then
            return comp, alias, pc
        end
    end
    return nil, "no SpellcastingComponent on PlayerController"
end

local _ksl_cdo = nil

function M.get_kismet_system_library()
    if _ksl_cdo and _ksl_cdo.IsValid and _ksl_cdo:IsValid() then return _ksl_cdo end
    if not StaticFindObject then return nil end
    local ok, obj = pcall(StaticFindObject, "/Script/Engine.Default__KismetSystemLibrary")
    if ok and obj and obj.IsValid and obj:IsValid() then
        _ksl_cdo = obj
        return _ksl_cdo
    end
    return nil
end

function M.is_valid_uobject(obj)
    return obj and obj.IsValid and obj:IsValid()
end

function M.normalize_uclass_path(class_path)
    local cp = class_path and tostring(class_path):match("^%s*(.-)%s*$") or ""
    if cp == "" then return cp end

    local quoted = cp:match("^[%w_]+%'(.+)'$")
    if quoted and quoted ~= "" then cp = quoted end

    if cp:find("^/Game/") then
        if cp:find("%.") then
            if not cp:find("_C$") then cp = cp .. "_C" end
        else
            local leaf = cp:match("([^/]+)$")
            if leaf and leaf ~= "" then
                local asset_leaf = leaf:gsub("_C$", "")
                local package_path = cp
                if asset_leaf ~= leaf then
                    package_path = cp:sub(1, #cp - #leaf) .. asset_leaf
                end
                cp = package_path .. "." .. asset_leaf .. "_C"
            elseif not cp:find("_C$") then
                cp = cp .. "_C"
            end
        end
    end
    return cp
end

function M.safe_uobject_label(obj)
    if not M.is_valid_uobject(obj) then return "<invalid>" end
    local ok_full, full = pcall(function() return obj:GetFullName() end)
    if ok_full and full and tostring(full) ~= "" then return tostring(full) end
    local ok_name, name = pcall(function() return obj:GetFName():ToString() end)
    if ok_name and name and tostring(name) ~= "" then return tostring(name) end
    return tostring(obj)
end

function M.resolve_uclass_via_kismet_softclass(class_path)
    local cp = M.normalize_uclass_path(class_path)
    if cp == "" then return nil, "empty class path", cp end
    if cp:sub(1, 1) ~= "/" then
        return nil, "soft-class load needs a fully qualified /Game or /Script path", cp
    end

    local ksl = M.get_kismet_system_library()
    if not ksl then return nil, "KismetSystemLibrary CDO not found", cp end

    local ok_path, soft_path = pcall(function() return ksl:MakeSoftClassPath(cp) end)
    if not ok_path then return nil, "MakeSoftClassPath failed: " .. tostring(soft_path), cp end
    if soft_path == nil then return nil, "MakeSoftClassPath returned nil", cp end

    local ok_ref, soft_ref = pcall(function() return ksl:Conv_SoftClassPathToSoftClassRef(soft_path) end)
    if not ok_ref then return nil, "Conv_SoftClassPathToSoftClassRef failed: " .. tostring(soft_ref), cp end
    if soft_ref == nil then return nil, "Conv_SoftClassPathToSoftClassRef returned nil", cp end

    local ok_load, loaded_class = pcall(function() return ksl:LoadClassAsset_Blocking(soft_ref) end)
    if ok_load and M.is_valid_uobject(loaded_class) then
        return loaded_class, "LoadClassAsset_Blocking", cp
    end

    local blocking_err = ok_load and "returned null" or tostring(loaded_class)
    return nil, "LoadClassAsset_Blocking " .. blocking_err, cp
end

function M.resolve_uclass(class_path)
    local cp = M.normalize_uclass_path(class_path)

    if StaticFindObject then
        local ok, c = pcall(StaticFindObject, cp)
        if ok and c and c.IsValid and c:IsValid() then return c end
    end
    if LoadObject then
        local ok, c = pcall(LoadObject, cp)
        if ok and c and c.IsValid and c:IsValid() then return c end
    end
    if LoadAsset then
        local ok, c = pcall(LoadAsset, cp)
        if ok and c and c.IsValid and c:IsValid() then return c end
    end
    if StaticFindObject then
        local package_path = cp:match("^(.-)%.[^./]+$")
        if package_path and package_path ~= "" and package_path:sub(1, 1) == "/" then
            local feature_net = require("feature_net")
            local pc = feature_net.local_controller()
            local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
            if pc and ksl and ksl.IsValid and ksl:IsValid() then
                pcall(function() ksl:ExecuteConsoleCommand(pc, "obj load name=" .. package_path, pc) end)
                local ok_c, c = pcall(StaticFindObject, cp)
                if ok_c and c and c.IsValid and c:IsValid() then return c end
            end
        end
    end
    local short = cp:match("([^/.]+)$") or cp
    local short_no_a = short
    if short:sub(1, 1) == "A" and #short > 1 then short_no_a = short:sub(2) end

    if FindAllOf then
        for _, container_class in ipairs({ "BlueprintGeneratedClass", "Class" }) do
            local ok_a, all = pcall(FindAllOf, container_class)
            if ok_a and type(all) == "table" then
                for _, candidate in ipairs(all) do
                    if candidate and candidate.IsValid and candidate:IsValid() then
                        local ok_n, fname = pcall(function() return candidate:GetFName():ToString() end)
                        if ok_n and (fname == short or fname == short_no_a) then
                            return candidate
                        end
                    end
                end
            end
        end
    end
    return nil
end

function M.resolve_class_cdo(class_obj)
    if not class_obj then return nil, "nil class" end
    local ok_cdo, cdo = pcall(function() return class_obj:GetCDO() end)
    if ok_cdo and cdo ~= nil then return cdo end
    local ok_default, default_obj = pcall(function() return class_obj:GetDefaultObject() end)
    if ok_default and default_obj ~= nil then return default_obj end
    local ok_field, field = pcall(function() return class_obj.ClassDefaultObject end)
    if ok_field and field ~= nil then return field end
    return nil, "could not resolve class default object"
end

function M.get_player_anim_instance()
    local pawn = M.get_pawn()
    if not pawn then return nil, "no local pawn" end

    local mesh = nil
    local ok_method, method = pcall(function() return pawn.GetMesh end)
    if ok_method and type(method) == "function" then
        local ok_mesh, value = pcall(function() return pawn:GetMesh() end)
        if ok_mesh and M.is_valid_uobject(value) then mesh = value end
    end
    if not mesh then
        for _, field_name in ipairs({ "Mesh", "SkeletalMeshComponent", "BodyMesh" }) do
            local ok_field, value = pcall(function() return pawn[field_name] end)
            if ok_field and M.is_valid_uobject(value) then
                mesh = value
                break
            end
        end
    end
    if not mesh then return nil, "player skeletal mesh not found" end

    if mesh.GetAnimInstance then
        local ok_anim, anim = pcall(function() return mesh:GetAnimInstance() end)
        if ok_anim and M.is_valid_uobject(anim) then return anim, nil end
    end
    local ok_field, anim = pcall(function() return mesh.AnimScriptInstance end)
    if ok_field and M.is_valid_uobject(anim) then return anim, nil end
    return nil, "player anim instance not found"
end

function M.animation_short_name(path)
    local leaf = tostring(path or ""):match("([^/.]+)$")
    return leaf or tostring(path or "")
end

function M.looks_like_ranged_attack(path)
    local lower = tostring(path or ""):lower()
    return lower:find("bow", 1, true) ~= nil
        or lower:find("crossbow", 1, true) ~= nil
        or lower:find("ranged", 1, true) ~= nil
end

return M
