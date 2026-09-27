-- feature_transmog.lua
--
-- Experimental player-equipment transmog verbs. These are deliberately
-- visual-only: they do not move inventory items, do not write UItemData, and do
-- not mutate PlayerEquipmentComponent.Current*Wearable. The first pass is a
-- test harness for proving which mesh/material paths are stable enough to build
-- a real UI on top of.
--
-- Verbs routed by command_line_router.lua:
--   player.transmog.status [head|body|legs|cape|all]
--   player.transmog.list [filter] [limit]
--   player.transmog.capture
--   player.transmog.apply <head|body|legs|cape> <WearableEquipmentData asset>
--   player.transmog.outfit head=<asset>;body=<asset>;legs=<asset>;cape=<asset>
--   player.transmog.hide <head|cape|all>  (body/legs intentionally unsupported)
--   player.transmog.clear [head|body|legs|cape|all]
--   player.transmog.reapply [head|body|legs|cape|all]
--   player.transmog.debug [head|body|legs|cape|all]

local M = {}

local feature_actor = require("feature_actor")

local SLOT_ORDER = { "head", "body", "legs", "cape" }
local SLOTS = {
    head = {
        label = "head",
        aliases = { helmet = true, helm = true, hat = true },
        current = "CurrentHeadWearable",
        mesh = "OutfitHeadMesh",
        rep = "OnRep_CurrentHeadWearable",
        reveal = { "HeadMesh", "HairMesh", "FacialHairMesh" },
    },
    body = {
        label = "body",
        aliases = { chest = true, torso = true, top = true },
        current = "CurrentBodyWearable",
        mesh = "OutfitBodyMesh",
        rep = "OnRep_CurrentBodyWearable",
        reveal = { "BodyMesh", "DefaultOutfitBodyMesh" },
    },
    legs = {
        label = "legs",
        aliases = { leg = true, pants = true, bottoms = true },
        current = "CurrentLegsWearable",
        mesh = "OutfitLegsMesh",
        rep = "OnRep_CurrentLegsWearable",
        reveal = { "BodyMesh", "DefaultOutfitLegsMesh" },
    },
    cape = {
        label = "cape",
        aliases = { cloak = true, back = true },
        current = "CurrentCapeWearable",
        mesh = "OutfitCapeMesh",
        rep = "OnRep_CurrentCapeWearable",
    },
}

local OVERRIDES = {}
local BASELINE = {}
local LOOKUP = {}
local LOOKUP_CI = {}
local SWEPT = {}

local COMPONENT_SNAPSHOT_ORDER = {
    "HeadMesh",
    "HairMesh",
    "FacialHairMesh",
    "BodyMesh",
    "DefaultOutfitBodyMesh",
    "DefaultOutfitLegsMesh",
    "OutfitHeadMesh",
    "OutfitBodyMesh",
    "OutfitLegsMesh",
    "OutfitCapeMesh",
}

local SLOT_COMPONENTS = {
    head = { "HeadMesh", "HairMesh", "FacialHairMesh", "OutfitHeadMesh" },
    body = { "OutfitBodyMesh", "BodyMesh", "DefaultOutfitBodyMesh" },
    legs = { "OutfitLegsMesh", "BodyMesh", "DefaultOutfitLegsMesh" },
    cape = { "OutfitCapeMesh" },
}

local BODY_MASK_PARAMS_BY_SLOT = {
    head = { "HeadOpacityMask", "Head Opacity Mask" },
    body = { "BodyOpacityMask", "Body Opacity Mask" },
    legs = { "LegsOpacityMask", "Legs Opacity Mask" },
}
local BODY_MASK_DEBUG_PARAMS = {
    "HeadOpacityMask",
    "BodyOpacityMask",
    "LegsOpacityMask",
    "Head Opacity Mask",
    "Body Opacity Mask",
    "Legs Opacity Mask",
}
local VISIBLE_MASK_TEXTURE_PATHS = {
    "/Game/Materials/DefaultTextures/T_Default_Black_D.T_Default_Black_D",
    "/Engine/EngineResources/DefaultTexture.DefaultTexture",
}
local VISIBLE_MASK_TEXTURE = false

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function read_field(obj, name)
    if not is_valid(obj) then return nil end
    local ok, value = pcall(function() return obj[name] end)
    if ok then return value end
    return nil
end

local function safe_name(obj)
    if not is_valid(obj) then return "none" end
    local ok, name = pcall(function() return obj:GetName() end)
    if ok and type(name) == "string" and name ~= "" then return name end
    local ok_full, full = pcall(function() return obj:GetFullName() end)
    if ok_full and type(full) == "string" and full ~= "" then return full end
    return tostring(obj)
end

local function full_name(obj)
    if not is_valid(obj) then return nil end
    local ok, name = pcall(function() return obj:GetFullName() end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

local function asset_identifier(obj)
    if not is_valid(obj) then return "none" end
    if obj.GetPathName then
        local ok, path = pcall(function() return obj:GetPathName() end)
        if ok and type(path) == "string" and path ~= "" then return path end
    end
    local fn = full_name(obj)
    if type(fn) == "string" then
        local path = fn:match("%s(/[^%s]+)$")
        if path and path ~= "" then return path end
    end
    return safe_name(obj)
end

local function unwrap_param(value)
    if type(value) ~= "userdata" then return value end
    for _ = 1, 2 do
        local has_get = false
        pcall(function() has_get = (type(value.get) == "function") end)
        if not has_get then return value end
        local ok, inner = pcall(function() return value:get() end)
        if not ok or inner == nil then return value end
        value = inner
        if type(value) ~= "userdata" then return value end
    end
    return value
end

local function fname_to_string(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    if type(value) == "userdata" then
        value = unwrap_param(value)
        if type(value) == "string" then return value end
        if type(value) == "userdata" then
            for _, method in ipairs({ "ToString", "GetName", "GetPlainNameString" }) do
                local ok, result = pcall(function() return value[method](value) end)
                if ok and type(result) == "string" and result ~= "" then return result end
            end
        end
    end
    return nil
end

local function array_len(arr)
    local n = 0
    pcall(function() n = #arr end)
    if n == 0 and type(arr) == "userdata" then
        pcall(function() n = arr:Num() end)
    end
    return n or 0
end

local function array_get(arr, index)
    if not arr then return nil end
    for _, candidate in ipairs({ index, index + 1 }) do
        local ok, value = pcall(function() return arr[candidate] end)
        if ok and value ~= nil then return unwrap_param(value) end
        ok, value = pcall(function() return arr:Get(candidate) end)
        if ok and value ~= nil then return unwrap_param(value) end
    end
    return nil
end

local function resolve_registry()
    if not StaticFindObject then return nil, "StaticFindObject unavailable" end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not is_valid(helpers) then return nil, "UAssetRegistryHelpers CDO not found" end
    local ok, registry = pcall(function() return helpers:GetAssetRegistry() end)
    if not ok or not is_valid(registry) then return nil, "GetAssetRegistry failed" end
    return registry, nil
end

local function build_lookup(class_name)
    if not FName then return nil, nil, "FName unavailable" end
    local registry, rerr = resolve_registry()
    if not registry then return nil, nil, rerr end

    local class_path = { PackageName = FName("/Script/Dominion"), AssetName = FName(class_name) }
    local out = {}
    local ok, err = pcall(function()
        registry:GetAssetsByClass(class_path, out, true)
    end)
    if not ok then return nil, nil, "GetAssetsByClass failed: " .. tostring(err) end

    local lut, lut_ci = {}, {}
    local n = array_len(out)
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
            local tail = low:match("^[%w]+_(.+)$")
            if tail and not lut_ci[tail] then lut_ci[tail] = pkg end
        end
    end
    return lut, lut_ci, nil
end

local function ensure_lookup(class_name)
    if LOOKUP[class_name] then return LOOKUP[class_name], LOOKUP_CI[class_name], nil end
    local lut, lut_ci, err = build_lookup(class_name)
    if not lut then return nil, nil, err end
    LOOKUP[class_name] = lut
    LOOKUP_CI[class_name] = lut_ci
    SWEPT[class_name] = true
    return lut, lut_ci, nil
end

local function object_path_from_package(pkg, explicit_leaf)
    if not pkg or pkg == "" then return nil end
    if pkg:find("%.") then return pkg end
    local leaf = explicit_leaf or pkg:match("([^/]+)$")
    if not leaf or leaf == "" then return nil end
    return pkg .. "." .. leaf
end

local function resolve_asset_path(path)
    local raw = trim(path)
    if raw == "" then return nil, "empty asset path" end

    local object_path = object_path_from_package(raw)
    local pkg = raw:match("^(.+)%.([^%.]+)$") or raw
    local asset

    if LoadObject and object_path then
        local ok, obj = pcall(LoadObject, object_path)
        if ok and is_valid(obj) then asset = obj end
    end
    if not asset and LoadAsset then
        pcall(LoadAsset, pkg)
        if object_path then pcall(LoadAsset, object_path) end
    end
    if not asset and StaticFindObject and object_path then
        local ok, obj = pcall(StaticFindObject, object_path)
        if ok and is_valid(obj) then asset = obj end
    end

    if not asset then return nil, "asset path lookup failed: " .. raw end
    return asset, nil
end

local function resolve_asset(name, class_name)
    local raw = trim(name)
    if raw == "" then return nil, "empty asset name" end

    if raw:sub(1, 1) == "/" then
        return resolve_asset_path(raw)
    end

    if FindFirstOf then
        local ok, obj = pcall(FindFirstOf, raw)
        if ok and is_valid(obj) then
            local fn = full_name(obj)
            if type(fn) ~= "string" or not fn:find("Default__", 1, true) then
                return obj, nil
            end
        end
    end

    local lut, lut_ci, err = ensure_lookup(class_name)
    if not lut then return nil, err end

    local low = raw:lower()
    local pkg = lut[raw] or (lut_ci and lut_ci[low])
    if not pkg and lut_ci then
        local tail = low:match("^[%w]+_(.+)$")
        if tail then pkg = lut_ci[tail] end
    end
    if not pkg and SWEPT[class_name] then
        LOOKUP[class_name], LOOKUP_CI[class_name], SWEPT[class_name] = nil, nil, nil
        lut, lut_ci = ensure_lookup(class_name)
        if lut then
            pkg = lut[raw] or (lut_ci and lut_ci[low])
            if not pkg and lut_ci then
                local tail = low:match("^[%w]+_(.+)$")
                if tail then pkg = lut_ci[tail] end
            end
        end
    end
    if not pkg then return nil, "asset not found in registry: " .. raw end

    if LoadAsset then pcall(LoadAsset, pkg) end
    local object_path = object_path_from_package(pkg)
    if not StaticFindObject or not object_path then return nil, "StaticFindObject unavailable" end
    local ok, obj = pcall(StaticFindObject, object_path)
    if not ok or not is_valid(obj) then return nil, "StaticFindObject failed for " .. tostring(object_path) end
    return obj, nil
end

local function make_fname(name)
    if FName then
        local ok, result = pcall(FName, name)
        if ok and result ~= nil then return result end
    end
    return name
end

local function get_visible_mask_texture()
    if VISIBLE_MASK_TEXTURE ~= false then return VISIBLE_MASK_TEXTURE end
    VISIBLE_MASK_TEXTURE = nil
    for _, path in ipairs(VISIBLE_MASK_TEXTURE_PATHS) do
        local texture = resolve_asset_path(path)
        if is_valid(texture) then
            VISIBLE_MASK_TEXTURE = texture
            return VISIBLE_MASK_TEXTURE
        end
    end
    return nil
end

local function normalize_slot(slot_text)
    local key = trim(slot_text):lower()
    if key == "" then return nil, "slot required: head|body|legs|cape|all" end
    if key == "all" or key == "*" then return "all" end
    for slot, def in pairs(SLOTS) do
        if key == slot or def.aliases[key] then return slot end
    end
    return nil, "unknown slot '" .. tostring(slot_text) .. "' (expected head|body|legs|cape|all)"
end

local function get_pawn()
    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return nil, "no local pawn" end
    return pawn, nil
end

local function get_equipment_component()
    local pawn, perr = get_pawn()
    if not pawn then return nil, perr end

    if pawn.GetPlayerEquipmentComponent then
        local ok, comp = pcall(function() return pawn:GetPlayerEquipmentComponent() end)
        if ok and is_valid(comp) then return comp, nil end
    end
    for _, field in ipairs({ "PlayerEquipmentComponent", "BP_Components_PlayerEquipment" }) do
        local comp = read_field(pawn, field)
        if is_valid(comp) then return comp, nil end
    end
    return nil, "no PlayerEquipmentComponent on local pawn"
end

local function get_customization_component()
    local pawn, perr = get_pawn()
    if not pawn then return nil, perr end

    if pawn.GetPlayerCustomizationComponent then
        local ok, comp = pcall(function() return pawn:GetPlayerCustomizationComponent() end)
        if ok and is_valid(comp) then return comp, nil end
    end
    for _, field in ipairs({ "PlayerCustomizationComponent", "BP_Components_PlayerCustomization" }) do
        local comp = read_field(pawn, field)
        if is_valid(comp) then return comp, nil end
    end
    return nil, "no PlayerCustomizationComponent on local pawn"
end

local function get_body_type()
    local comp = get_customization_component()
    if is_valid(comp) and comp.GetBodyType then
        local ok, body_type = pcall(function() return comp:GetBodyType() end)
        if ok and body_type ~= nil then return body_type, nil end
    end
    if is_valid(comp) then
        local body_type = read_field(comp, "BodyType")
        if body_type ~= nil then return body_type, nil end
    end
    return 0, "body type fallback: Male(0)"
end

local function body_type_text(body_type)
    local value = body_type
    if type(value) == "userdata" then
        local ok, inner = pcall(function() return value:get() end)
        if ok and inner ~= nil then value = inner end
    end
    if value == 0 then return "Male(0)" end
    if value == 1 then return "Female(1)" end
    return tostring(value)
end

local function get_slot_objects(slot)
    local def = SLOTS[slot]
    if not def then return nil, nil, nil, "unknown slot: " .. tostring(slot) end
    local equipment, err = get_equipment_component()
    if not equipment then return nil, nil, nil, err end
    local mesh = read_field(equipment, def.mesh)
    if not is_valid(mesh) then return equipment, nil, nil, "missing mesh component: " .. def.mesh end
    local current = read_field(equipment, def.current)
    return equipment, current, mesh, nil
end

local function set_component_visible(component, visible)
    if not is_valid(component) then return end
    if component.SetHiddenInGame then pcall(function() component:SetHiddenInGame(not visible, false) end) end
    if component.SetVisibility then pcall(function() component:SetVisibility(visible, false) end) end
end

local function force_component_renderable(component)
    if not is_valid(component) then return "missing" end
    local changed = {}
    set_component_visible(component, true)
    if component.SetRenderInMainPass then
        local ok = pcall(function() component:SetRenderInMainPass(true) end)
        changed[#changed + 1] = "main=" .. tostring(ok)
    end
    if component.SetOwnerNoSee then
        local ok = pcall(function() component:SetOwnerNoSee(false) end)
        changed[#changed + 1] = "owner_no_see=" .. tostring(ok)
    end
    if component.SetOnlyOwnerSee then
        local ok = pcall(function() component:SetOnlyOwnerSee(false) end)
        changed[#changed + 1] = "only_owner=" .. tostring(ok)
    end
    if component.SetComponentTickEnabled then
        local ok = pcall(function() component:SetComponentTickEnabled(true) end)
        changed[#changed + 1] = "tick=" .. tostring(ok)
    end
    if component.MarkRenderStateDirty then pcall(function() component:MarkRenderStateDirty() end) end
    if component.ForceUpdateBounds then pcall(function() component:ForceUpdateBounds() end) end
    if component.UpdateBounds then pcall(function() component:UpdateBounds() end) end

    for _, field in ipairs({
        { "bRenderInMainPass", true },
        { "bVisibleInSceneCaptureOnly", false },
        { "bOwnerNoSee", false },
        { "bOnlyOwnerSee", false },
        { "bVisibleInReflectionCaptures", true },
        { "bVisibleInRealTimeSkyCaptures", true },
        { "bVisibleInRayTracing", true },
    }) do
        if read_field(component, field[1]) ~= nil then pcall(function() component[field[1]] = field[2] end) end
    end
    if #changed == 0 then return "basic" end
    return table.concat(changed, ",")
end

local function set_skeletal_mesh(component, mesh)
    if not is_valid(component) then return false, "invalid mesh component" end
    if not is_valid(mesh) then return false, "invalid skeletal mesh" end

    if component.SetSkeletalMesh then
        local ok = pcall(function() component:SetSkeletalMesh(mesh, true) end)
        if ok then return true, "SetSkeletalMesh" end
        ok = pcall(function() component:SetSkeletalMesh(mesh) end)
        if ok then return true, "SetSkeletalMesh" end
    end
    if component.SetSkeletalMeshAsset then
        local ok = pcall(function() component:SetSkeletalMeshAsset(mesh) end)
        if ok then return true, "SetSkeletalMeshAsset" end
        ok = pcall(function() component:SetSkeletalMeshAsset(mesh, true) end)
        if ok then return true, "SetSkeletalMeshAsset" end
    end
    local ok = pcall(function() component.SkeletalMesh = mesh end)
    if ok then return true, "SkeletalMesh field" end
    return false, "no skeletal mesh setter worked"
end

local function set_anim_class(component, anim_class)
    if not is_valid(component) or not is_valid(anim_class) then return "none" end
    if not component.SetAnimInstanceClass then return "missing" end
    local ok, err = pcall(function() component:SetAnimInstanceClass(anim_class) end)
    if ok then return "ok" end
    return "failed:" .. tostring(err)
end

local function get_material_texture_parameter(material, parameter_name)
    if not is_valid(material) or not material.K2_GetTextureParameterValue then return nil end
    local ok, texture = pcall(function() return material:K2_GetTextureParameterValue(make_fname(parameter_name)) end)
    if ok and is_valid(texture) then return texture end
    return nil
end

local function set_material_texture_parameter(material, parameter_name, texture)
    if not is_valid(material) or not material.SetTextureParameterValue then return false, "missing" end
    if not is_valid(texture) then return false, "no_texture" end
    local ok, err = pcall(function() material:SetTextureParameterValue(make_fname(parameter_name), texture) end)
    if ok then return true, "ok" end
    return false, tostring(err)
end

local function get_component_mesh(component)
    if not is_valid(component) then return nil end
    if component.GetSkeletalMeshAsset then
        local ok, mesh = pcall(function() return component:GetSkeletalMeshAsset() end)
        if ok and is_valid(mesh) then return mesh end
    end
    if component.GetSkinnedAsset then
        local ok, mesh = pcall(function() return component:GetSkinnedAsset() end)
        if ok and is_valid(mesh) then return mesh end
    end
    for _, field_name in ipairs({ "SkeletalMesh", "SkinnedAsset" }) do
        local mesh = read_field(component, field_name)
        if is_valid(mesh) then return mesh end
    end
    return nil
end

local function get_component_anim(component)
    if not is_valid(component) then return nil end
    if component.GetAnimClass then
        local ok, anim_class = pcall(function() return component:GetAnimClass() end)
        if ok and is_valid(anim_class) then return anim_class end
    end
    local anim_class = read_field(component, "AnimClass")
    if is_valid(anim_class) then return anim_class end
    return nil
end

local function capture_component_state(component)
    if not is_valid(component) then return nil end
    local state = {
        mesh = get_component_mesh(component),
        anim_class = get_component_anim(component),
        materials = {},
        texture_params = {},
        material_count = 0,
    }
    if component.GetNumMaterials then
        pcall(function() state.material_count = component:GetNumMaterials() end)
    end
    if component.GetMaterial and state.material_count and state.material_count > 0 then
        local capped_count = math.min(state.material_count, 16)
        for material_index = 0, capped_count - 1 do
            local ok, material = pcall(function() return component:GetMaterial(material_index) end)
            if ok and is_valid(material) then
                state.materials[material_index] = material
                state.texture_params[material_index] = {}
                for _, parameter_name in ipairs(BODY_MASK_DEBUG_PARAMS) do
                    local texture = get_material_texture_parameter(material, parameter_name)
                    if is_valid(texture) then state.texture_params[material_index][parameter_name] = texture end
                end
            end
        end
    end
    return state
end

local function capture_equipment_baseline(equipment)
    if not is_valid(equipment) then return "no_equipment" end
    local captured = {}
    for _, component_name in ipairs(COMPONENT_SNAPSHOT_ORDER) do
        if not BASELINE[component_name] then
            local component = read_field(equipment, component_name)
            if is_valid(component) then
                BASELINE[component_name] = capture_component_state(component)
                captured[#captured + 1] = component_name
            end
        end
    end
    if #captured == 0 then return "already" end
    return table.concat(captured, ",")
end

local function restore_component_materials(component, state)
    if not is_valid(component) or not state or not component.SetMaterial then return "none" end
    local restored = 0
    for material_index, material in pairs(state.materials or {}) do
        if is_valid(material) then
            local ok = pcall(function() component:SetMaterial(material_index, material) end)
            if ok then restored = restored + 1 end
        end
    end
    if restored == 0 then return "none" end
    return tostring(restored)
end

local function show_all_material_sections(component)
    if not is_valid(component) or not component.ShowAllMaterialSections then return "missing" end
    local restored = 0
    for lod_index = 0, 7 do
        local ok = pcall(function() component:ShowAllMaterialSections(lod_index) end)
        if ok then restored = restored + 1 end
    end
    if restored == 0 then return "failed" end
    return "lods=" .. tostring(restored)
end

local function unhide_all_bones(component)
    if not is_valid(component) then return "missing" end
    if not component.GetNumBones or not component.GetBoneName or not component.UnHideBoneByName then return "missing_api" end
    local bone_count = 0
    pcall(function() bone_count = component:GetNumBones() end)
    if not bone_count or bone_count <= 0 then return "none" end

    local checked = 0
    local hidden_before = 0
    local unhidden = 0
    for bone_index = 0, math.min(bone_count - 1, 511) do
        local ok_bone, bone_name = pcall(function() return component:GetBoneName(bone_index) end)
        if ok_bone and bone_name ~= nil then
            checked = checked + 1
            if component.IsBoneHiddenByName then
                local ok_hidden, is_hidden = pcall(function() return component:IsBoneHiddenByName(bone_name) end)
                if ok_hidden and is_hidden then hidden_before = hidden_before + 1 end
            end
            local ok_unhide = pcall(function() component:UnHideBoneByName(bone_name) end)
            if ok_unhide then unhidden = unhidden + 1 end
        end
    end
    return "checked=" .. tostring(checked) .. ",hidden_before=" .. tostring(hidden_before) .. ",unhidden=" .. tostring(unhidden)
end

local function clear_hide_skin(component)
    if not is_valid(component) then return "missing" end
    local before = read_field(component, "bHideSkin")
    local ok = pcall(function() component.bHideSkin = false end)
    return "before=" .. tostring(before) .. ",set=" .. tostring(ok)
end

local function set_body_mask_params(equipment, slot, texture)
    if not is_valid(equipment) then return "no_equipment" end
    local params = BODY_MASK_PARAMS_BY_SLOT[slot]
    if not params then return "none" end
    local body_component = read_field(equipment, "BodyMesh")
    if not is_valid(body_component) then return "no_bodymesh" end
    if not is_valid(texture) then return "no_texture" end
    if not body_component.GetNumMaterials or not body_component.GetMaterial then return "no_material_api" end

    local material_count = 0
    pcall(function() material_count = body_component:GetNumMaterials() end)
    local changes = {}
    for material_index = 0, math.min(material_count or 0, 4) - 1 do
        local ok_material, material = pcall(function() return body_component:GetMaterial(material_index) end)
        if ok_material and is_valid(material) then
            for _, parameter_name in ipairs(params) do
                local ok_set, detail = set_material_texture_parameter(material, parameter_name, texture)
                if ok_set then
                    changes[#changes + 1] = tostring(material_index) .. ":" .. parameter_name .. "=" .. safe_name(texture)
                else
                    changes[#changes + 1] = tostring(material_index) .. ":" .. parameter_name .. "_failed=" .. tostring(detail)
                end
            end
        end
    end
    if #changes == 0 then return "none" end
    return table.concat(changes, ",")
end

local function neutralize_body_mask_for_slot(equipment, slot)
    if not BODY_MASK_PARAMS_BY_SLOT[slot] then return "none" end
    local texture = get_visible_mask_texture()
    if not is_valid(texture) then return "no_visible_mask_texture" end
    return set_body_mask_params(equipment, slot, texture)
end

local function restore_saved_body_mask_for_slot(equipment, slot)
    if not BODY_MASK_PARAMS_BY_SLOT[slot] then return "none" end
    if not is_valid(equipment) then return "no_equipment" end
    local body_component = read_field(equipment, "BodyMesh")
    if not is_valid(body_component) then return "no_bodymesh" end
    if not body_component.GetMaterial then return "no_material_api" end

    local body_state = BASELINE["BodyMesh"]
    if not body_state or not body_state.texture_params then return "no_saved_masks" end

    local restored = {}
    for material_index, params in pairs(body_state.texture_params) do
        local ok_material, material = pcall(function() return body_component:GetMaterial(material_index) end)
        if ok_material and is_valid(material) then
            for _, parameter_name in ipairs(BODY_MASK_PARAMS_BY_SLOT[slot]) do
                local texture = params and params[parameter_name]
                if is_valid(texture) then
                    local ok_set, detail = set_material_texture_parameter(material, parameter_name, texture)
                    if ok_set then
                        restored[#restored + 1] = tostring(material_index) .. ":" .. parameter_name .. "=" .. safe_name(texture)
                    else
                        restored[#restored + 1] = tostring(material_index) .. ":" .. parameter_name .. "_failed=" .. tostring(detail)
                    end
                end
            end
        end
    end
    if #restored == 0 then return "none" end
    return table.concat(restored, ",")
end

local function restore_component_for_hide(component_name, component)
    if not is_valid(component) then return component_name .. "=missing" end
    local state = BASELINE[component_name]
    local mesh_result = "mesh=unchanged"
    if state and is_valid(state.mesh) then
        local ok_mesh, mesh_detail = set_skeletal_mesh(component, state.mesh)
        mesh_result = ok_mesh and ("mesh=" .. tostring(mesh_detail)) or ("mesh_failed=" .. tostring(mesh_detail))
    end
    local anim_result = "anim=none"
    if state and is_valid(state.anim_class) then
        anim_result = "anim=" .. set_anim_class(component, state.anim_class)
    end
    local material_result = "materials=" .. restore_component_materials(component, state)
    local section_result = "sections=" .. show_all_material_sections(component)
    local bone_result = "bones=" .. unhide_all_bones(component)
    local hide_skin_result = "hide_skin=" .. clear_hide_skin(component)
    local render_result = "render=" .. force_component_renderable(component)
    return component_name .. "(" .. table.concat({ mesh_result, anim_result, material_result, section_result, bone_result, hide_skin_result, render_result }, ",") .. ")"
end

local function component_bool(component, field_name, method_name)
    if not is_valid(component) then return "missing" end
    if method_name and component[method_name] then
        local ok, value = pcall(function() return component[method_name](component) end)
        if ok then return tostring(value) end
    end
    local value = read_field(component, field_name)
    if value ~= nil then return tostring(value) end
    return "unknown"
end

local function component_material_summary(component)
    if not is_valid(component) or not component.GetNumMaterials or not component.GetMaterial then return "materials=unknown" end
    local material_count = 0
    pcall(function() material_count = component:GetNumMaterials() end)
    local names = {}
    for material_index = 0, math.min(material_count or 0, 4) - 1 do
        local ok, material = pcall(function() return component:GetMaterial(material_index) end)
        names[#names + 1] = tostring(material_index) .. ":" .. (ok and safe_name(material) or "err")
    end
    return "materials=" .. tostring(material_count or 0) .. "[" .. table.concat(names, ",") .. "]"
end

local function material_section_probe(component)
    if not is_valid(component) or not component.IsMaterialSectionShown then return "sections=unknown" end
    local probes = {}
    for material_id = 0, 7 do
        local ok, shown = pcall(function() return component:IsMaterialSectionShown(material_id, 0) end)
        if ok then probes[#probes + 1] = tostring(material_id) .. ":" .. tostring(shown) end
    end
    if #probes == 0 then return "sections=unreadable" end
    return "sections[LOD0]=" .. table.concat(probes, ",")
end

local function hidden_bone_summary(component)
    if not is_valid(component) then return "bones=missing" end
    if not component.GetNumBones or not component.GetBoneName or not component.IsBoneHiddenByName then return "bones=unknown" end
    local bone_count = 0
    pcall(function() bone_count = component:GetNumBones() end)
    if not bone_count or bone_count <= 0 then return "bones=0" end

    local hidden = 0
    local samples = {}
    for bone_index = 0, math.min(bone_count - 1, 511) do
        local ok_bone, bone_name = pcall(function() return component:GetBoneName(bone_index) end)
        if ok_bone and bone_name ~= nil then
            local ok_hidden, is_hidden = pcall(function() return component:IsBoneHiddenByName(bone_name) end)
            if ok_hidden and is_hidden then
                hidden = hidden + 1
                if #samples < 8 then samples[#samples + 1] = fname_to_string(bone_name) or tostring(bone_name) end
            end
        end
    end
    if #samples == 0 then return "bones=" .. tostring(bone_count) .. ",hidden=0" end
    return "bones=" .. tostring(bone_count) .. ",hidden=" .. tostring(hidden) .. "[" .. table.concat(samples, ",") .. "]"
end

local function mask_parameter_summary(component)
    if not is_valid(component) or not component.GetNumMaterials or not component.GetMaterial then return "masks=unknown" end
    local material_count = 0
    pcall(function() material_count = component:GetNumMaterials() end)
    local values = {}
    for material_index = 0, math.min(material_count or 0, 2) - 1 do
        local ok_material, material = pcall(function() return component:GetMaterial(material_index) end)
        if ok_material and is_valid(material) then
            for _, parameter_name in ipairs(BODY_MASK_DEBUG_PARAMS) do
                local texture = get_material_texture_parameter(material, parameter_name)
                if is_valid(texture) then values[#values + 1] = tostring(material_index) .. ":" .. parameter_name .. "=" .. safe_name(texture) end
            end
        end
    end
    if #values == 0 then return "masks=none" end
    return "masks=" .. table.concat(values, ",")
end

local function render_flag_summary(component)
    if not is_valid(component) then return "render=missing" end
    local values = {}
    for _, field_name in ipairs({
        "bRenderInMainPass",
        "bOwnerNoSee",
        "bOnlyOwnerSee",
        "bVisibleInSceneCaptureOnly",
        "bVisibleInReflectionCaptures",
        "bVisibleInRealTimeSkyCaptures",
        "bVisibleInRayTracing",
        "VisibilityId",
    }) do
        local value = read_field(component, field_name)
        if value ~= nil then values[#values + 1] = field_name .. "=" .. tostring(value) end
    end
    if #values == 0 then return "render=unknown" end
    return "render=" .. table.concat(values, ",")
end

local function custom_primitive_data_summary(component)
    if not is_valid(component) then return "cpd=missing" end
    local source = "internal"
    local cpd = read_field(component, "CustomPrimitiveDataInternal")
    if cpd == nil then
        source = "public"
        cpd = read_field(component, "CustomPrimitiveData")
    end
    if cpd == nil then return "cpd=none" end
    local data = read_field(cpd, "Data")
    if data == nil then return "cpd=" .. source .. ":no_data" end
    local count = array_len(data)
    local values = {}
    for index = 0, math.min((count or 0) - 1, 15) do
        local value = array_get(data, index)
        if value ~= nil then values[#values + 1] = tostring(index) .. "=" .. tostring(value) end
    end
    if #values == 0 then return "cpd=" .. source .. ":count=" .. tostring(count or 0) end
    return "cpd=" .. source .. ":count=" .. tostring(count or 0) .. "[" .. table.concat(values, ",") .. "]"
end

local function component_summary(equipment, component_name)
    local component = read_field(equipment, component_name)
    if not is_valid(component) then return component_name .. "=missing" end
    local mesh = get_component_mesh(component)
    local anim_class = get_component_anim(component)
    local saved = BASELINE[component_name]
    local saved_mesh = saved and saved.mesh or nil
    return component_name .. "(" .. table.concat({
        "mesh=" .. safe_name(mesh),
        "saved=" .. safe_name(saved_mesh),
        "anim=" .. safe_name(anim_class),
        "visible=" .. component_bool(component, "bVisible", "IsVisible"),
        "hidden=" .. component_bool(component, "bHiddenInGame", nil),
        "hide_skin=" .. tostring(read_field(component, "bHideSkin")),
        render_flag_summary(component),
        custom_primitive_data_summary(component),
        component_material_summary(component),
        mask_parameter_summary(component),
        hidden_bone_summary(component),
        material_section_probe(component),
    }, ";") .. ")"
end

local function clear_mesh_component(component)
    if not is_valid(component) then return "missing" end
    if component.SetSkeletalMesh then pcall(function() component:SetSkeletalMesh(nil, true) end) end
    if component.SetSkeletalMeshAsset then pcall(function() component:SetSkeletalMeshAsset(nil) end) end
    set_component_visible(component, false)
    return "hidden"
end

local function set_named_components_visible(equipment, names, visible)
    local changed = {}
    for _, name in ipairs(names or {}) do
        local component = read_field(equipment, name)
        if is_valid(component) then
            set_component_visible(component, visible)
            changed[#changed + 1] = name
        end
    end
    if #changed == 0 then return "none" end
    return table.concat(changed, ",")
end

local function reveal_underlay_for_slot(equipment, slot)
    local def = SLOTS[slot]
    if not def then return "none" end
    capture_equipment_baseline(equipment)
    local changed = {}
    for _, name in ipairs(def.reveal or {}) do
        local component = read_field(equipment, name)
        if is_valid(component) then
            changed[#changed + 1] = restore_component_for_hide(name, component)
        end
    end
    local mask_detail = neutralize_body_mask_for_slot(equipment, slot)
    if mask_detail ~= "none" then changed[#changed + 1] = "BodyMeshMasks(" .. mask_detail .. ")" end
    if #changed == 0 then return "none" end
    return table.concat(changed, ",")
end

local function hide_underlay_for_slot(equipment, slot)
    local def = SLOTS[slot]
    if not def then return "none" end
    local names = {}
    for _, name in ipairs(def.reveal or {}) do
        if name:find("^DefaultOutfit") then names[#names + 1] = name end
    end
    return set_named_components_visible(equipment, names, false)
end

local function is_body_or_legs(slot)
    return slot == "body" or slot == "legs"
end

local function body_legs_hide_unsupported(slot)
    return "slot=" .. tostring(slot) .. ";hide=unsupported;base BodyMesh stays armor-masked while body/legs gear is equipped; use apply or clear instead"
end

local function call_dom_hide_outfit(equipment, hidden)
    if not is_valid(equipment) then return "missing_equipment" end
    for _, method_name in ipairs({ "domHideOutfit", "DomHideOutfit" }) do
        local fn = read_field(equipment, method_name)
        if type(fn) == "function" then
            local ok, err = pcall(function() fn(equipment, hidden and true or false) end)
            if ok then return method_name .. "=" .. tostring(hidden and true or false) end
            ok, err = pcall(function() equipment[method_name](equipment, hidden and true or false) end)
            if ok then return method_name .. "=" .. tostring(hidden and true or false) end
            return method_name .. "_failed:" .. tostring(err)
        end
    end
    local direct_detail = "domHideOutfit_missing"
    local ok_net, feature_net = pcall(require, "feature_net")
    if not ok_net or not feature_net or not feature_net.local_controller then return direct_detail end
    local pc = feature_net.local_controller()
    if not is_valid(pc) then return direct_detail .. ";exec=no_player_controller" end
    local ksl = StaticFindObject and StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") or nil
    if not is_valid(ksl) or not ksl.ExecuteConsoleCommand then return direct_detail .. ";exec=no_ksl" end
    local command = "domHideOutfit " .. tostring(hidden and true or false)
    local ok_exec, exec_err = pcall(function() ksl:ExecuteConsoleCommand(pc, command, pc) end)
    if ok_exec then return direct_detail .. ";exec=" .. command end
    return direct_detail .. ";exec_failed:" .. tostring(exec_err)
end

local function get_wearable_mesh(wearable, body_type)
    if not is_valid(wearable) then return nil, "invalid wearable" end
    if not wearable.GetSkeletalMesh then return nil, "GetSkeletalMesh missing on " .. safe_name(wearable) end
    local ok, mesh = pcall(function() return wearable:GetSkeletalMesh(body_type) end)
    if not ok then return nil, "GetSkeletalMesh failed: " .. tostring(mesh) end
    if not is_valid(mesh) then return nil, "GetSkeletalMesh returned nil for " .. safe_name(wearable) end
    return mesh, nil
end

local function get_wearable_anim(wearable, body_type)
    if not is_valid(wearable) or not wearable.GetAnimBlueprintClass then return nil end
    local ok, anim = pcall(function() return wearable:GetAnimBlueprintClass(body_type) end)
    if ok and is_valid(anim) then return anim end
    return nil
end

local function apply_materials(wearable, body_type, component)
    if not is_valid(wearable) or not wearable.ApplyMaterialsToSkeletalMeshComponent then return "missing" end
    local ok, err = pcall(function()
        wearable:ApplyMaterialsToSkeletalMeshComponent(body_type, component)
    end)
    if ok then return "ok" end
    return "failed:" .. tostring(err)
end

local function apply_visual(slot, wearable, remember)
    local equipment, _current, mesh_component, serr = get_slot_objects(slot)
    if not equipment then return false, serr end
    if not mesh_component then return false, serr end
    local snapshot_detail = capture_equipment_baseline(equipment)

    local body_type, berr = get_body_type()
    local mesh, merr = get_wearable_mesh(wearable, body_type)
    if not mesh then return false, merr end

    set_component_visible(mesh_component, true)
    local ok_mesh, mesh_method = set_skeletal_mesh(mesh_component, mesh)
    if not ok_mesh then return false, mesh_method end

    local anim = get_wearable_anim(wearable, body_type)
    local anim_result = set_anim_class(mesh_component, anim)
    local material_result = apply_materials(wearable, body_type, mesh_component)
    local render_result = force_component_renderable(mesh_component)

    if remember then
        OVERRIDES[slot] = {
            wearable = wearable,
            asset = safe_name(wearable),
        }
    end

    return true, table.concat({
        "slot=" .. slot,
        "asset=" .. safe_name(wearable),
        "body_type=" .. body_type_text(body_type),
        "mesh=" .. safe_name(mesh),
        "mesh_set=" .. tostring(mesh_method),
        "anim=" .. anim_result,
        "materials=" .. material_result,
        "render=" .. render_result,
        "snapshot=" .. snapshot_detail,
        berr and ("note=" .. berr) or nil,
    }, ";")
end

local function reapply_non_hidden_outfit_slots()
    local details = {}
    for _, slot in ipairs(SLOT_ORDER) do
        local override = OVERRIDES[slot]
        if not (override and override.hidden) then
            if override and is_valid(override.wearable) then
                local ok, detail = apply_visual(slot, override.wearable, false)
                details[#details + 1] = slot .. "=" .. (ok and "override" or ("failed:" .. tostring(detail)))
            else
                local _equipment, current = get_slot_objects(slot)
                if is_valid(current) then
                    local ok, detail = apply_visual(slot, current, false)
                    details[#details + 1] = slot .. "=" .. (ok and "actual" or ("failed:" .. tostring(detail)))
                else
                    details[#details + 1] = slot .. "=none"
                end
            end
        end
    end
    if #details == 0 then return "none" end
    return table.concat(details, ",")
end

local function sync_native_outfit_visible_state()
    local equipment, err = get_equipment_component()
    if not equipment then return "native_visible=no_equipment:" .. tostring(err) end
    return "native_visible=" .. call_dom_hide_outfit(equipment, false)
end

local function hide_slot_visual(slot, equipment, mesh_component)
    if is_body_or_legs(slot) then
        return body_legs_hide_unsupported(slot)
    end
    local clear_detail = clear_mesh_component(mesh_component)
    local reveal_detail = reveal_underlay_for_slot(equipment, slot)
    return "hide=" .. clear_detail .. ";reveal=" .. reveal_detail
end

local function call_slot_onrep(equipment, slot, previous)
    local def = SLOTS[slot]
    if not def or not is_valid(equipment) then return false, "missing equipment component" end
    local fn = equipment[def.rep]
    if type(fn) ~= "function" then return false, def.rep .. " missing" end
    local ok, err = pcall(function() fn(equipment, previous) end)
    if ok then return true, "OnRep" end
    ok, err = pcall(function() fn(equipment) end)
    if ok then return true, "OnRep" end
    return false, tostring(err)
end

local function restore_slot(slot)
    local equipment, current, mesh_component, serr = get_slot_objects(slot)
    if not equipment then return false, serr end
    if not mesh_component then return false, serr end
    capture_equipment_baseline(equipment)

    local previous = OVERRIDES[slot] and OVERRIDES[slot].wearable or nil
    OVERRIDES[slot] = nil

    local ok_rep, rep_detail = call_slot_onrep(equipment, slot, previous)
    local mask_restore = restore_saved_body_mask_for_slot(equipment, slot)
    if ok_rep then return true, "slot=" .. slot .. ";restore=" .. rep_detail .. ";masks=" .. mask_restore end

    if is_valid(current) then
        local ok, detail = apply_visual(slot, current, false)
        if ok then return true, detail .. ";restore=fallback_actual;masks=" .. mask_restore end
        return false, detail .. ";onrep_failed=" .. rep_detail
    end

    local clear_detail = clear_mesh_component(mesh_component)
    local reveal_detail = reveal_underlay_for_slot(equipment, slot)
    return true, "slot=" .. slot .. ";restore=" .. clear_detail .. ";reveal=" .. reveal_detail .. ";masks=" .. mask_restore .. ";onrep_failed=" .. rep_detail
end

local function slots_from_arg(arg, default_all)
    local raw = trim(arg)
    if raw == "" then
        if default_all then return SLOT_ORDER, nil end
        return nil, "slot required: head|body|legs|cape"
    end
    local slot, err = normalize_slot(raw)
    if not slot then return nil, err end
    if slot == "all" then return SLOT_ORDER, nil end
    return { slot }, nil
end

function M.status(args_str)
    local slots, err = slots_from_arg(args_str or "all", true)
    if not slots then return false, err end

    local body_type, berr = get_body_type()
    local parts = { "body_type=" .. body_type_text(body_type) }
    if berr then parts[#parts + 1] = "note=" .. berr end

    for _, slot in ipairs(slots) do
        local _equipment, current, mesh_component, serr = get_slot_objects(slot)
        local override = OVERRIDES[slot]
        local override_label = "none"
        if override then
            override_label = override.hidden and "hidden" or override.asset or "unknown"
        end
        local component_state = serr and ("missing:" .. serr) or (is_valid(mesh_component) and "ok" or "missing")
        parts[#parts + 1] = string.format("%s(actual=%s,override=%s,component=%s)",
            slot,
            is_valid(current) and safe_name(current) or "none",
            override_label,
            component_state)
    end
    return true, table.concat(parts, "|")
end

function M.list(args_str)
    local raw = trim(args_str)
    local filter, limit_text = raw:match("^(%S+)%s+(%S+)$")
    if not filter then filter = raw end
    if filter ~= "" and tonumber(filter) then
        limit_text = filter
        filter = ""
    end
    local limit = tonumber(limit_text) or 80
    if limit < 1 then limit = 1 end
    if limit > 500 then limit = 500 end

    local lut, _lut_ci, err = ensure_lookup("WearableEquipmentData")
    if not lut then return false, err end

    local names = {}
    local filter_low = filter:lower()
    for name, _pkg in pairs(lut) do
        if filter_low == "" or name:lower():find(filter_low, 1, true) then
            names[#names + 1] = name
        end
    end
    table.sort(names)

    local shown = {}
    for i = 1, math.min(#names, limit) do shown[#shown + 1] = names[i] end
    return true, string.format("count=%d;shown=%d;filter=%s|%s", #names, #shown, filter, table.concat(shown, ","))
end

function M.capture(_args_str)
    local equipment, err = get_equipment_component()
    if not equipment then return false, err end

    local parts = {}
    for _, slot in ipairs(SLOT_ORDER) do
        local def = SLOTS[slot]
        local wearable = read_field(equipment, def.current)
        parts[#parts + 1] = slot .. "=" .. asset_identifier(wearable)
    end
    return true, table.concat(parts, ";")
end

function M.apply(args_str)
    local raw = trim(args_str)
    local slot_text, asset_name = raw:match("^(%S+)%s+(.+)$")
    if not slot_text or trim(asset_name) == "" then
        return false, "usage: player.transmog.apply <head|body|legs|cape> <WearableEquipmentData asset>"
    end

    local slot, serr = normalize_slot(slot_text)
    if not slot then return false, serr end
    if slot == "all" then return false, "apply requires one concrete slot, not all" end

    local wearable, werr = resolve_asset(asset_name, "WearableEquipmentData")
    if not wearable then return false, werr end
    local previous_override = OVERRIDES[slot]
    local native_detail = "none"
    if previous_override and previous_override.hidden and is_body_or_legs(slot) then
        native_detail = sync_native_outfit_visible_state()
    end
    local ok, detail = apply_visual(slot, wearable, true)
    if ok and previous_override and previous_override.hidden then
        local equipment = get_equipment_component()
        if is_valid(equipment) then
            local mask_restore = restore_saved_body_mask_for_slot(equipment, slot)
            hide_underlay_for_slot(equipment, slot)
            native_detail = native_detail .. ";masks=" .. mask_restore
        end
    end
    if ok then return true, detail .. ";" .. native_detail end
    return false, detail
end

function M.outfit(args_str)
    local raw = trim(args_str)
    if raw == "" then
        return false, "usage: player.transmog.outfit head=<asset>;body=<asset>;legs=<asset>;cape=<asset>"
    end

    local assignments = {}
    local count = 0
    for part in raw:gmatch("[^;]+") do
        local item = trim(part)
        if item ~= "" then
            local split_at = item:find("=", 1, true)
            if not split_at then
                return false, "invalid outfit part '" .. item .. "' (expected slot=asset)"
            end
            local slot_text = trim(item:sub(1, split_at - 1))
            local asset_name = trim(item:sub(split_at + 1))
            if asset_name == "" then
                return false, "asset required for slot '" .. slot_text .. "'"
            end
            local slot, serr = normalize_slot(slot_text)
            if not slot then return false, serr end
            if slot == "all" then return false, "outfit requires concrete slots, not all" end
            if assignments[slot] then return false, "duplicate outfit slot: " .. slot end
            assignments[slot] = asset_name
            count = count + 1
        end
    end

    if count == 0 then
        return false, "usage: player.transmog.outfit head=<asset>;body=<asset>;legs=<asset>;cape=<asset>"
    end

    local details = {}
    local failures = {}
    for _, slot in ipairs(SLOT_ORDER) do
        local asset_name = assignments[slot]
        if asset_name then
            local ok, detail = M.apply(slot .. " " .. asset_name)
            if ok then
                details[#details + 1] = slot .. ":" .. tostring(detail)
            else
                failures[#failures + 1] = slot .. ":" .. tostring(detail)
            end
        end
    end

    if #failures > 0 then
        return false, "applied=" .. tostring(#details) .. ";failed=" .. tostring(#failures) .. "|" .. table.concat(failures, "|")
    end
    return true, "applied=" .. tostring(#details) .. "|" .. table.concat(details, "|")
end

function M.hide(args_str)
    local slots, err = slots_from_arg(args_str or "all", false)
    if not slots then return false, err end

    local details = {}
    local failures = {}
    local unsupported = {}
    for _, slot in ipairs(slots) do
        if is_body_or_legs(slot) then
            unsupported[#unsupported + 1] = body_legs_hide_unsupported(slot)
        else
            local equipment, _current, mesh_component, serr = get_slot_objects(slot)
            if not mesh_component then
                failures[#failures + 1] = slot .. ":" .. tostring(serr)
            else
                local snapshot_detail = capture_equipment_baseline(equipment)
                local hide_detail = hide_slot_visual(slot, equipment, mesh_component)
                OVERRIDES[slot] = { hidden = true, asset = "hidden" }
                details[#details + 1] = "slot=" .. slot .. ";snapshot=" .. snapshot_detail .. ";" .. hide_detail
            end
        end
    end
    if #failures > 0 then return false, table.concat(failures, "|") end
    if #details == 0 and #unsupported > 0 then return false, table.concat(unsupported, "|") end
    for _, detail in ipairs(unsupported) do details[#details + 1] = detail end
    return true, table.concat(details, "|")
end

function M.clear(args_str)
    local slots, err = slots_from_arg(args_str or "all", true)
    if not slots then return false, err end

    local details = {}
    local failures = {}
    local needs_native_visible = false
    for _, slot in ipairs(slots) do
        if is_body_or_legs(slot) then needs_native_visible = true end
        local ok, detail = restore_slot(slot)
        if ok then details[#details + 1] = detail else failures[#failures + 1] = slot .. ":" .. tostring(detail) end
    end
    if needs_native_visible then details[#details + 1] = sync_native_outfit_visible_state() end
    if #failures > 0 then return false, table.concat(failures, "|") end
    return true, table.concat(details, "|")
end

function M.reapply(args_str)
    local slots, err = slots_from_arg(args_str or "all", true)
    if not slots then return false, err end

    local details = {}
    local failures = {}
    for _, slot in ipairs(slots) do
        local override = OVERRIDES[slot]
        if override and override.hidden then
            if is_body_or_legs(slot) then
                OVERRIDES[slot] = nil
                details[#details + 1] = body_legs_hide_unsupported(slot) .. ";override=cleared"
            else
                local equipment, _current, mesh_component, serr = get_slot_objects(slot)
                if not mesh_component then
                    failures[#failures + 1] = slot .. ":" .. tostring(serr)
                else
                    local hide_detail = hide_slot_visual(slot, equipment, mesh_component)
                    details[#details + 1] = "slot=" .. slot .. ";" .. hide_detail
                end
            end
        elseif override and is_valid(override.wearable) then
            local ok, detail = apply_visual(slot, override.wearable, false)
            if ok then details[#details + 1] = detail else failures[#failures + 1] = slot .. ":" .. tostring(detail) end
        else
            details[#details + 1] = "slot=" .. slot .. ";override=none"
        end
    end
    if #failures > 0 then return false, table.concat(failures, "|") end
    return true, table.concat(details, "|")
end

function M.debug(args_str)
    local slots, err = slots_from_arg(args_str or "all", true)
    if not slots then return false, err end
    local equipment, eq_err = get_equipment_component()
    if not equipment then return false, eq_err end
    capture_equipment_baseline(equipment)

    local seen = {}
    local parts = {}
    for _, slot in ipairs(slots) do
        for _, component_name in ipairs(SLOT_COMPONENTS[slot] or {}) do
            if not seen[component_name] then
                seen[component_name] = true
                parts[#parts + 1] = component_summary(equipment, component_name)
            end
        end
    end
    if #parts == 0 then return false, "no components for requested slot" end
    return true, table.concat(parts, "|")
end

return M
