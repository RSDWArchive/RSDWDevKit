-- Detached Oculus mesh proxy probe.
--
-- This is an experiment for safer actor manipulation: instead of moving live
-- actor-owned components, spawn a separate StaticMeshActor/SkeletalMeshActor
-- that copies the target's visible mesh. If this proves stable, Grab/Rotate/
-- Scale can move the detached proxy and apply one final transform to the real
-- actor on confirm.

local M = {}

local feature_actor = require("feature_actor")
local feature_oculus_async = require("feature_oculus_async")
local feature_build_preview = require("feature_build_preview")
local feature_field = require("feature_field")
local feature_grab = require("feature_grab")
local feature_player_core = require("feature_player_core")
local feature_oculus_input_guard = require("feature_oculus_input_guard")
local feature_umg = require("feature_umg")

local proxies = {}
local placement = nil
local placement_starting = nil
local placement_start_token = 0
local attachgrab = nil
local attachgrab_flow = { starting = nil, token = 0 }
local preview_swap = nil
local preview_swap_starting = nil
local preview_move = nil
local preview_swap_token = 0
local PLACE_ARM_DELAY_FRAMES = 2
local PLACE_PREVIEW_STABLE_FRAMES = 3
local PLACE_ATTACH_DELAY_FRAMES = 2
local PLACE_FINALIZE_DELAY_FRAMES = 1
local PLACE_PREVIEW_SAMPLE_FRAMES = { 0, 1, 2, 5, 10, 20 }
attachgrab_flow.config = {
    PRETARGET_DELAY_FRAMES = 8,
    START_DELAY_FRAMES = 8,
    ARM_DELAY_FRAMES = 2,
    PROXY_MESH_READY_POLL_FRAMES = 2,
    PROXY_MESH_READY_MAX_ATTEMPTS = 12,
    SAMPLE_FRAMES = { 0, 1, 2, 5, 10, 20 },
    ATTACH_DELAY_FRAMES = 2,
    FINALIZE_DELAY_FRAMES = 1,
    POST_CONFIRM_FREEZE_STOP_DELAY_MS = 900,
    STABLE_THRESHOLD_CM = 1.0,
}
local PREVIEW_SWAP_ARM_DELAY_MS = 80
local PREVIEW_SWAP_POLL_MS = 40
local PREVIEW_SWAP_EXIT_READY_MAX_ATTEMPTS = 25
local PREVIEW_SWAP_ENTER_READY_MAX_ATTEMPTS = 25
local PREVIEW_SWAP_PREVIEW_READY_MAX_ATTEMPTS = 45
local PREVIEW_SWAP_POST_CONFIRM_EXIT_MS = 120
local PREVIEW_SWAP_APPLY_RETRY_FRAMES = 2
local PREVIEW_SWAP_APPLY_MAX_ATTEMPTS = 12
local PREVIEW_SWAP_REARM_COOLDOWN_MS = 900
local PREVIEW_SWAP_LIFECYCLE_SETTLE_MS = 3500
local PREVIEW_SWAP_LIFECYCLE_POLL_MS = 80
local actor_world_transform
local sync_proxy_to_preview_once
local DEFAULT_PLACE_HOST_PIECE = "BuildingPieceData /Game/Gameplay/BaseBuilding_New/BuildingPieces/Tier1_Brynmoor/Beams/DA_T1_Beam_Thin_Medium_Vertical.DA_T1_Beam_Thin_Medium_Vertical"
local PREVIEW_SWAP_STATIC_HOST = DEFAULT_PLACE_HOST_PIECE
local PREVIEW_SWAP_SKELETAL_HOST = "BuildingPieceData /Game/Gameplay/BaseBuilding/Data/BuildingPieces/Furniture/Storage/BUILDPIECE_ArmourMannequin.BUILDPIECE_ArmourMannequin"
local PREVIEW_MOVE_DEFAULT_HOST = "528"
local PREVIEW_COMPONENT_PROXY_NAME_PREFIX = "RSDWToolsPreviewSkeletalProxy_"
local DEFAULT_PLACE_HOST_FALLBACKS = {
    "535",
    "DA_T1_Beam_Thin_Medium_Vertical",
    "T1_Beam_Thin_Medium_Vertical",
    "Beam_Thin_Medium_Vertical",
}
local PREVIEW_SWAP_HOST_FALLBACKS = {
    static = {
        "535",
        "DA_T1_Beam_Thin_Medium_Vertical",
        "T1_Beam_Thin_Medium_Vertical",
        "Beam_Thin_Medium_Vertical",
    },
    skeletal = {
        "51",
        "BUILDPIECE_ArmourMannequin",
        "ArmourMannequin",
        "Armour Mannequin",
        "80",
        "BUILDPIECE_ProcessingStation_Tanner",
        "ProcessingStation_Tanner",
        "Tanner",
    },
}
local preview_swap_settle_until_ms = 0
local preview_swap_lifecycle_busy = false
local preview_swap_lifecycle_token = 0
local preview_swap_lifecycle_reason = nil

local function now_ms()
    return os.clock() * 1000.0
end

local function mark_preview_swap_settle(reason)
    local until_ms = now_ms() + PREVIEW_SWAP_REARM_COOLDOWN_MS
    if until_ms > preview_swap_settle_until_ms then
        preview_swap_settle_until_ms = until_ms
    end
    print("[RSDWTools.oculus.preview.swap] settle " .. tostring(reason or "preview.swap")
        .. " cooldown_ms=" .. tostring(PREVIEW_SWAP_REARM_COOLDOWN_MS))

    preview_swap_lifecycle_token = preview_swap_lifecycle_token + 1
    local token = preview_swap_lifecycle_token
    preview_swap_lifecycle_busy = true
    preview_swap_lifecycle_reason = tostring(reason or "preview.swap")
    print("[RSDWTools.oculus.preview.swap] lifecycle busy reason=" .. tostring(preview_swap_lifecycle_reason)
        .. " settle_ms=" .. tostring(PREVIEW_SWAP_LIFECYCLE_SETTLE_MS))
    feature_oculus_async.schedule_game_thread(PREVIEW_SWAP_LIFECYCLE_SETTLE_MS, function()
        if preview_swap_lifecycle_token ~= token then return end
        preview_swap_lifecycle_busy = false
        local ready_reason = preview_swap_lifecycle_reason
        preview_swap_lifecycle_reason = nil
        print("[RSDWTools.oculus.preview.swap] lifecycle ready reason=" .. tostring(ready_reason))
    end)
end

local function preview_swap_rearm_delay_ms()
    local remaining = preview_swap_settle_until_ms - now_ms()
    if remaining > 0 then
        return PREVIEW_SWAP_ARM_DELAY_MS + math.ceil(remaining)
    end
    return PREVIEW_SWAP_ARM_DELAY_MS
end

local COMPONENT_FIELDS = {
    "Mesh",
    "MeshComponent",
    "RootStaticMeshComponent",
    "StaticMeshComponent",
    "SkeletalMeshComponent",
    "SkinnedMeshComponent",
    "CharacterMesh",
    "VisualMesh",
    "VisualMeshComponent",
    "RockMesh",
    "RockMeshComponent",
    "OreMesh",
    "OreMeshComponent",
    "ReplacementMesh",
    "ReplacementMeshComponent",
    "ReplacementMeshComponent1",
    "ItemMesh",
    "WorldItemMesh",
}

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function safe_full_name(obj)
    if not is_valid(obj) or not obj.GetFullName then return nil end
    local ok, value = pcall(function() return obj:GetFullName() end)
    if ok and type(value) == "string" and value ~= "" then return value end
    return nil
end

local function safe_short_name(obj)
    return feature_actor.short_name_of(obj) or "<unnamed>"
end

local function class_name(obj)
    local value = feature_field.class_name_of(obj)
    if type(value) == "string" and value ~= "" then return value end
    local full = safe_full_name(obj)
    if type(full) == "string" then
        local inferred = full:match("^([^%s]+)")
        if inferred and inferred ~= "" then return inferred end
    end
    return ""
end

local function read_field(obj, field_name)
    if not is_valid(obj) then return nil end
    local ok, value = pcall(function() return obj[field_name] end)
    if ok then return value end
    return nil
end

local function container_count(value)
    if value == nil then return 0 end
    local ok_len, len = pcall(function() return #value end)
    if ok_len and type(len) == "number" and len > 0 then return len end
    if type(value) == "userdata" then
        local ok_num, num = pcall(function() return value:Num() end)
        if ok_num and type(num) == "number" then return num end
    end
    return 0
end

local function container_item(value, index)
    if value == nil then return nil end
    for _, candidate in ipairs({ index, index - 1 }) do
        local ok, item = pcall(function() return value[candidate] end)
        if ok and item ~= nil then return item end
        if type(value) == "userdata" then
            ok, item = pcall(function() return value:Get(candidate) end)
            if ok and item ~= nil then return item end
        end
    end
    return nil
end

function M._probe_raw_field(value, key)
    if value == nil then return nil end
    local ok, field = pcall(function() return value[key] end)
    if ok then return field end
    return nil
end

function M._probe_vector_summary(value)
    if value == nil then return "<nil>" end
    local x = M._probe_raw_field(value, "X") or M._probe_raw_field(value, "x")
    local y = M._probe_raw_field(value, "Y") or M._probe_raw_field(value, "y")
    local z = M._probe_raw_field(value, "Z") or M._probe_raw_field(value, "z")
    if x == nil and y == nil and z == nil then return tostring(value) end
    return string.format("(%.1f,%.1f,%.1f)", tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
end

function M._probe_rot_summary(value)
    if value == nil then return "<nil>" end
    local p = M._probe_raw_field(value, "Pitch") or M._probe_raw_field(value, "pitch")
    local y = M._probe_raw_field(value, "Yaw") or M._probe_raw_field(value, "yaw")
    local r = M._probe_raw_field(value, "Roll") or M._probe_raw_field(value, "roll")
    if p == nil and y == nil and r == nil then return tostring(value) end
    return string.format("(P%.1f,Y%.1f,R%.1f)", tonumber(p) or 0, tonumber(y) or 0, tonumber(r) or 0)
end

local function actor_transform(actor)
    return {
        loc = feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 },
        rot = feature_actor.actor_rotation(actor) or { Pitch = 0, Yaw = 0, Roll = 0 },
        scale = feature_actor.get_actor_scale3d(actor) or { X = 1, Y = 1, Z = 1 },
    }
end

local function copy_loc(loc)
    loc = loc or {}
    return { X = loc.X or loc.x or 0, Y = loc.Y or loc.y or 0, Z = loc.Z or loc.z or 0 }
end

local function copy_rot(rot)
    rot = rot or {}
    return { Pitch = rot.Pitch or rot.pitch or 0, Yaw = rot.Yaw or rot.yaw or 0, Roll = rot.Roll or rot.roll or 0 }
end

local function copy_scale(scale)
    scale = scale or {}
    return { X = scale.X or scale.x or 1, Y = scale.Y or scale.y or 1, Z = scale.Z or scale.z or 1 }
end

local function vec_sub(a, b)
    a = a or {}
    b = b or {}
    return {
        X = (a.X or 0) - (b.X or 0),
        Y = (a.Y or 0) - (b.Y or 0),
        Z = (a.Z or 0) - (b.Z or 0),
    }
end

local function vec_add(a, b)
    a = a or {}
    b = b or {}
    return {
        X = (a.X or 0) + (b.X or 0),
        Y = (a.Y or 0) + (b.Y or 0),
        Z = (a.Z or 0) + (b.Z or 0),
    }
end

local function normalize_angle(value)
    local v = tonumber(value) or 0
    while v > 180 do v = v - 360 end
    while v <= -180 do v = v + 360 end
    return v
end

local function rot_sub(a, b)
    a = a or {}
    b = b or {}
    return {
        Pitch = normalize_angle((a.Pitch or 0) - (b.Pitch or 0)),
        Yaw = normalize_angle((a.Yaw or 0) - (b.Yaw or 0)),
        Roll = normalize_angle((a.Roll or 0) - (b.Roll or 0)),
    }
end

local function rot_add(a, b)
    a = a or {}
    b = b or {}
    return {
        Pitch = normalize_angle((a.Pitch or 0) + (b.Pitch or 0)),
        Yaw = normalize_angle((a.Yaw or 0) + (b.Yaw or 0)),
        Roll = normalize_angle((a.Roll or 0) + (b.Roll or 0)),
    }
end

local function resolve_native_actor_class(kind)
    local path = kind == "skeletal" and "/Script/Engine.SkeletalMeshActor" or "/Script/Engine.StaticMeshActor"
    local candidates = {
        path,
        "Class " .. path,
    }
    if StaticFindObject then
        for _, candidate in ipairs(candidates) do
            local ok, obj = pcall(StaticFindObject, candidate)
            if ok and is_valid(obj) then return obj, candidate end
        end
    end
    if LoadObject then
        for _, candidate in ipairs({ path, "Class " .. path }) do
            local ok, obj = pcall(LoadObject, candidate)
            if ok and is_valid(obj) then return obj, candidate end
        end
    end
    return nil, "could not resolve native class " .. path
end

local function spawn_actor(class_obj, xform)
    local world = feature_field.resolve_root("world")
    if not is_valid(world) then return nil, "no UWorld" end
    if not world.SpawnActor then return nil, "UWorld:SpawnActor missing" end
    local loc = copy_loc(xform and xform.loc)
    local rot = copy_rot(xform and xform.rot)
    local actor
    local ok, err = pcall(function()
        actor = world:SpawnActor(class_obj, loc, rot)
    end)
    if not ok then return nil, "SpawnActor failed: " .. tostring(err) end
    if not is_valid(actor) then return nil, "SpawnActor returned invalid" end
    return actor, nil
end

local function component_kind(component)
    local cls = class_name(component):lower()
    local full = tostring(safe_full_name(component) or ""):lower()
    local hay = cls .. " " .. full
    if hay:find("skeletalmeshcomponent", 1, true) or hay:find("skinnedmeshcomponent", 1, true) then
        return "skeletal"
    end
    if hay:find("staticmeshcomponent", 1, true) then
        return "static"
    end
    return nil
end

local function get_static_mesh(component)
    if not is_valid(component) then return nil, "invalid static component" end
    if component.GetStaticMesh then
        local ok, mesh = pcall(function() return component:GetStaticMesh() end)
        if ok and is_valid(mesh) then return mesh, "GetStaticMesh" end
    end
    local mesh = read_field(component, "StaticMesh")
    if is_valid(mesh) then return mesh, "StaticMesh field" end
    return nil, "no static mesh asset"
end

local function get_skeletal_mesh(component)
    if not is_valid(component) then return nil, "invalid skeletal component" end
    if component.GetSkeletalMeshAsset then
        local ok, mesh = pcall(function() return component:GetSkeletalMeshAsset() end)
        if ok and is_valid(mesh) then return mesh, "GetSkeletalMeshAsset" end
    end
    if component.GetSkinnedAsset then
        local ok, mesh = pcall(function() return component:GetSkinnedAsset() end)
        if ok and is_valid(mesh) then return mesh, "GetSkinnedAsset" end
    end
    for _, field_name in ipairs({ "SkeletalMesh", "SkinnedAsset" }) do
        local mesh = read_field(component, field_name)
        if is_valid(mesh) then return mesh, field_name .. " field" end
    end
    return nil, "no skeletal mesh asset"
end

local function get_mesh_from_component(component)
    local kind = component_kind(component)
    if kind == "skeletal" then
        local mesh, route = get_skeletal_mesh(component)
        if mesh then return kind, mesh, route end
        return nil, nil, route
    end
    if kind == "static" then
        local mesh, route = get_static_mesh(component)
        if mesh then return kind, mesh, route end
        return nil, nil, route
    end
    return nil, nil, "not a mesh component"
end

local function get_component_transform(component, actor)
    local loc, rot, scale
    if is_valid(component) then
        if component.K2_GetComponentLocation then
            pcall(function() loc = component:K2_GetComponentLocation() end)
        elseif component.GetComponentLocation then
            pcall(function() loc = component:GetComponentLocation() end)
        end
        if component.K2_GetComponentRotation then
            pcall(function() rot = component:K2_GetComponentRotation() end)
        elseif component.GetComponentRotation then
            pcall(function() rot = component:GetComponentRotation() end)
        end
        if component.GetComponentScale then
            pcall(function() scale = component:GetComponentScale() end)
        end
    end
    local ax = actor_transform(actor)
    return {
        loc = loc or ax.loc,
        rot = rot or ax.rot,
        scale = scale or ax.scale,
    }
end

local function get_materials(component)
    local materials = {}
    if not is_valid(component) then return materials end
    local count = nil
    if component.GetNumMaterials then
        local ok, value = pcall(function() return component:GetNumMaterials() end)
        if ok then count = tonumber(value) end
    end
    count = math.max(0, math.min(32, count or 0))
    for i = 0, count - 1 do
        if component.GetMaterial then
            local ok, mat = pcall(function() return component:GetMaterial(i) end)
            if ok and is_valid(mat) then materials[#materials + 1] = { index = i, material = mat } end
        end
    end
    return materials
end

local function find_mesh_descriptor(actor)
    if not is_valid(actor) then return nil, "invalid actor" end
    local root = read_field(actor, "RootComponent")
    local candidates = {}
    for _, field_name in ipairs(COMPONENT_FIELDS) do
        local component = read_field(actor, field_name)
        if is_valid(component) then
            candidates[#candidates + 1] = { component = component, label = field_name }
        end
    end
    if is_valid(root) then
        candidates[#candidates + 1] = { component = root, label = "RootComponent" }
    end

    local notes = {}
    for _, candidate in ipairs(candidates) do
        local kind, mesh, route_or_err = get_mesh_from_component(candidate.component)
        if kind and is_valid(mesh) then
            return {
                kind = kind,
                mesh = mesh,
                component = candidate.component,
                component_label = candidate.label,
                mesh_route = route_or_err,
                component_transform = get_component_transform(candidate.component, actor),
                materials = get_materials(candidate.component),
            }, nil
        end
        notes[#notes + 1] = tostring(candidate.label) .. "=" .. tostring(route_or_err or "not mesh")
    end
    return nil, "no readable SM/SK mesh on known fields (" .. table.concat(notes, "; ") .. ")"
end

local function proxy_component(actor, kind)
    if not is_valid(actor) then return nil end
    local fields = kind == "skeletal"
        and { "SkeletalMeshComponent", "Mesh", "SkinnedMeshComponent" }
        or { "StaticMeshComponent", "Mesh" }
    for _, field_name in ipairs(fields) do
        local component = read_field(actor, field_name)
        if is_valid(component) then return component, field_name end
    end
    local root = read_field(actor, "RootComponent")
    if is_valid(root) then return root, "RootComponent" end
    return nil
end

local function set_proxy_mesh(component, kind, mesh)
    if not is_valid(component) then return false, "invalid proxy component" end
    if not is_valid(mesh) then return false, "invalid mesh asset" end
    if kind == "skeletal" then
        if component.SetSkeletalMesh then
            local ok = pcall(function() return component:SetSkeletalMesh(mesh, true) end)
            if ok then return true, "SetSkeletalMesh" end
            ok = pcall(function() return component:SetSkeletalMesh(mesh) end)
            if ok then return true, "SetSkeletalMesh" end
        end
        if component.SetSkeletalMeshAsset then
            local ok = pcall(function() return component:SetSkeletalMeshAsset(mesh, true) end)
            if ok then return true, "SetSkeletalMeshAsset" end
            ok = pcall(function() return component:SetSkeletalMeshAsset(mesh) end)
            if ok then return true, "SetSkeletalMeshAsset" end
        end
        local ok = pcall(function() component.SkeletalMesh = mesh end)
        if ok then return true, "SkeletalMesh field" end
        return false, "no skeletal setter"
    end
    if component.SetStaticMesh then
        local ok = pcall(function() return component:SetStaticMesh(mesh) end)
        if ok then return true, "SetStaticMesh" end
    end
    local ok = pcall(function() component.StaticMesh = mesh end)
    if ok then return true, "StaticMesh field" end
    return false, "no static setter"
end

local function apply_proxy_materials(component, materials)
    local applied = 0
    if not is_valid(component) or type(materials) ~= "table" or not component.SetMaterial then return 0 end
    for _, entry in ipairs(materials) do
        if is_valid(entry.material) then
            local ok = pcall(function() component:SetMaterial(entry.index or 0, entry.material) end)
            if ok then applied = applied + 1 end
        end
    end
    return applied
end

local function make_proxy_renderable(actor, component)
    if is_valid(actor) then
        if actor.SetActorEnableCollision then pcall(function() actor:SetActorEnableCollision(false) end) end
        if actor.SetActorHiddenInGame then pcall(function() actor:SetActorHiddenInGame(false) end) end
        pcall(function() actor.bRegisterAsRuntimeSpawned = true end)
    end
    if is_valid(component) then
        if component.SetCollisionEnabled then pcall(function() component:SetCollisionEnabled(0) end) end
        if component.SetHiddenInGame then pcall(function() component:SetHiddenInGame(false, false) end) end
        if component.SetVisibility then pcall(function() component:SetVisibility(true, false) end) end
        if component.SetRenderInMainPass then pcall(function() component:SetRenderInMainPass(true) end) end
        if component.SetOwnerNoSee then pcall(function() component:SetOwnerNoSee(false) end) end
        if component.SetOnlyOwnerSee then pcall(function() component:SetOnlyOwnerSee(false) end) end
        if component.SetComponentTickEnabled then pcall(function() component:SetComponentTickEnabled(false) end) end
        if component.MarkRenderStateDirty then pcall(function() component:MarkRenderStateDirty() end) end
        if component.ForceUpdateBounds then pcall(function() component:ForceUpdateBounds() end) end
        if component.UpdateBounds then pcall(function() component:UpdateBounds() end) end
    end
end

local function resolve_uclass(path)
    if type(path) ~= "string" or path == "" then return nil end
    local ok_core, core_class = pcall(function() return feature_player_core.resolve_uclass(path) end)
    if ok_core and is_valid(core_class) then return core_class end
    local candidates = { path, "Class " .. path }
    if StaticFindObject then
        for _, candidate in ipairs(candidates) do
            local ok, obj = pcall(StaticFindObject, candidate)
            if ok and is_valid(obj) then return obj end
        end
    end
    if LoadObject then
        for _, candidate in ipairs(candidates) do
            local ok, obj = pcall(LoadObject, candidate)
            if ok and is_valid(obj) then return obj end
        end
    end
    return nil
end

local function component_mesh_asset(component, kind)
    if not is_valid(component) then return nil end
    if kind == "skeletal" then
        local mesh = get_skeletal_mesh(component)
        return mesh
    end
    if kind == "static" then
        local mesh = get_static_mesh(component)
        return mesh
    end
    local inferred = component_kind(component)
    if inferred then return component_mesh_asset(component, inferred) end
    return nil
end

local function component_material_count(component)
    if not is_valid(component) or not component.GetNumMaterials then return 0 end
    local ok, count = pcall(function() return component:GetNumMaterials() end)
    if ok and type(count) == "number" then return count end
    return 0
end

local function material_summary(component, max_materials)
    if not is_valid(component) or not component.GetNumMaterials or not component.GetMaterial then return "materials=unknown" end
    local count = 0
    pcall(function() count = component:GetNumMaterials() end)
    local names = {}
    for material_index = 0, math.min(tonumber(count) or 0, tonumber(max_materials) or 8) - 1 do
        local ok, material = pcall(function() return component:GetMaterial(material_index) end)
        names[#names + 1] = tostring(material_index) .. ":" .. (ok and safe_short_name(material) or "err")
    end
    return "materials=" .. tostring(count or 0) .. "[" .. table.concat(names, ",") .. "]"
end

local function fname_to_string(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    local ok_to_string, text = pcall(function()
        if value.ToString then return value:ToString() end
        return nil
    end)
    if ok_to_string and text ~= nil then return tostring(text) end
    return tostring(value)
end

local function anim_class_summary(component)
    if not is_valid(component) then return "anim=missing" end
    local anim = nil
    if component.GetAnimClass then
        pcall(function() anim = component:GetAnimClass() end)
    end
    if not is_valid(anim) then
        anim = read_field(component, "AnimClass")
    end
    if not is_valid(anim) then
        anim = read_field(component, "AnimBlueprintGeneratedClass")
    end
    local anim_instance = read_field(component, "AnimScriptInstance")
    local mode = read_field(component, "AnimationMode")
    local parts = {
        "anim=" .. tostring(is_valid(anim) and safe_short_name(anim) or "<none>"),
    }
    if mode ~= nil then parts[#parts + 1] = "mode=" .. tostring(mode) end
    if is_valid(anim_instance) then parts[#parts + 1] = "instance=" .. tostring(class_name(anim_instance)) end
    return table.concat(parts, ",")
end

local function material_section_summary(component)
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
    local count = 0
    pcall(function() count = component:GetNumBones() end)
    if not count or count <= 0 then return "bones=0" end
    local hidden = 0
    local samples = {}
    for bone_index = 0, math.min(count - 1, 511) do
        local ok_bone, bone_name = pcall(function() return component:GetBoneName(bone_index) end)
        if ok_bone and bone_name ~= nil then
            local ok_hidden, is_hidden = pcall(function() return component:IsBoneHiddenByName(bone_name) end)
            if ok_hidden and is_hidden then
                hidden = hidden + 1
                if #samples < 8 then samples[#samples + 1] = fname_to_string(bone_name) or tostring(bone_name) end
            end
        end
    end
    if #samples == 0 then return "bones=" .. tostring(count) .. ",hidden=0" end
    return "bones=" .. tostring(count) .. ",hidden=" .. tostring(hidden) .. "[" .. table.concat(samples, ",") .. "]"
end

local function render_flag_summary(component)
    if not is_valid(component) then return "render=missing" end
    local values = {}
    for _, field_name in ipairs({
        "bHiddenInGame",
        "bVisible",
        "bRenderInMainPass",
        "bOwnerNoSee",
        "bOnlyOwnerSee",
        "bVisibleInSceneCaptureOnly",
        "bVisibleInReflectionCaptures",
        "bVisibleInRealTimeSkyCaptures",
        "bVisibleInRayTracing",
        "VisibilityId",
        "bHideSkin",
    }) do
        local value = read_field(component, field_name)
        if value ~= nil then values[#values + 1] = field_name .. "=" .. tostring(value) end
    end
    if #values == 0 then return "render=unknown" end
    return "render=" .. table.concat(values, ",")
end

local function show_all_material_sections(component)
    if not is_valid(component) or not component.ShowAllMaterialSections then return "sections=missing" end
    local restored = 0
    for lod_index = 0, 7 do
        local ok = pcall(function() component:ShowAllMaterialSections(lod_index) end)
        if ok then restored = restored + 1 end
    end
    if restored == 0 then return "sections=failed" end
    return "sections=lods=" .. tostring(restored)
end

local function unhide_all_bones(component)
    if not is_valid(component) then return "bones=missing" end
    if not component.GetNumBones or not component.GetBoneName or not component.UnHideBoneByName then return "bones=missing_api" end
    local count = 0
    pcall(function() count = component:GetNumBones() end)
    if not count or count <= 0 then return "bones=none" end
    local hidden_before = 0
    local unhidden = 0
    for bone_index = 0, math.min(count - 1, 511) do
        local ok_bone, bone_name = pcall(function() return component:GetBoneName(bone_index) end)
        if ok_bone and bone_name ~= nil then
            if component.IsBoneHiddenByName then
                local ok_hidden, is_hidden = pcall(function() return component:IsBoneHiddenByName(bone_name) end)
                if ok_hidden and is_hidden then hidden_before = hidden_before + 1 end
            end
            local ok_unhide = pcall(function() component:UnHideBoneByName(bone_name) end)
            if ok_unhide then unhidden = unhidden + 1 end
        end
    end
    return "bones=checked=" .. tostring(count) .. ",hidden_before=" .. tostring(hidden_before) .. ",unhidden=" .. tostring(unhidden)
end

local function clear_hide_skin(component)
    if not is_valid(component) then return "hide_skin=missing" end
    local before = read_field(component, "bHideSkin")
    local ok = pcall(function() component.bHideSkin = false end)
    return "hide_skin=before=" .. tostring(before) .. ",set=" .. tostring(ok)
end

local function read_visibility_flags(component)
    local flags = {}
    if not is_valid(component) then return flags end
    for _, field_name in ipairs({
        "bHiddenInGame",
        "bVisible",
        "bRenderInMainPass",
        "bOwnerNoSee",
        "bOnlyOwnerSee",
        "bVisibleInSceneCaptureOnly",
        "bVisibleInReflectionCaptures",
        "bVisibleInRealTimeSkyCaptures",
        "bVisibleInRayTracing",
    }) do
        local ok, value = pcall(function() return component[field_name] end)
        if ok and value ~= nil then flags[field_name] = value end
    end
    return flags
end

local function visibility_summary(flags)
    flags = flags or {}
    local parts = {}
    for _, key in ipairs({ "bHiddenInGame", "bVisible", "bRenderInMainPass", "bOwnerNoSee", "bOnlyOwnerSee" }) do
        if flags[key] ~= nil then parts[#parts + 1] = key .. "=" .. tostring(flags[key]) end
    end
    if #parts == 0 then return "flags=<none>" end
    return table.concat(parts, ",")
end

local function refresh_component_renderable(component, tick_enabled)
    if not is_valid(component) then return false end
    if component.SetHiddenInGame then pcall(function() component:SetHiddenInGame(false, false) end) end
    if component.SetVisibility then pcall(function() component:SetVisibility(true, false) end) end
    if component.SetRenderInMainPass then pcall(function() component:SetRenderInMainPass(true) end) end
    if component.SetOwnerNoSee then pcall(function() component:SetOwnerNoSee(false) end) end
    if component.SetOnlyOwnerSee then pcall(function() component:SetOnlyOwnerSee(false) end) end
    if component.SetComponentTickEnabled then pcall(function() component:SetComponentTickEnabled(tick_enabled == true) end) end
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
    if component.MarkRenderStateDirty then pcall(function() component:MarkRenderStateDirty() end) end
    if component.ForceUpdateBounds then pcall(function() component:ForceUpdateBounds() end) end
    if component.UpdateBounds then pcall(function() component:UpdateBounds() end) end
    return true
end

local function clear_skeletal_mesh_for_probe(component)
    if not is_valid(component) then return "clear=component_missing" end
    local results = {}
    local function attempt(label, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = tostring(label) .. "=" .. tostring(ok and "ok" or err)
        return ok
    end
    if component.SetSkinnedAssetAndUpdate then
        attempt("SetSkinnedAssetAndUpdate(nil)", function() component:SetSkinnedAssetAndUpdate(nil, true) end)
    end
    if component.SetSkeletalMesh then
        attempt("SetSkeletalMesh(nil,true)", function() component:SetSkeletalMesh(nil, true) end)
    end
    if component.SetSkeletalMeshAsset then
        attempt("SetSkeletalMeshAsset(nil)", function() component:SetSkeletalMeshAsset(nil) end)
    end
    if read_field(component, "SkeletalMesh") ~= nil then
        attempt("SkeletalMesh=nil", function() component.SkeletalMesh = nil end)
    end
    if read_field(component, "SkinnedAsset") ~= nil then
        attempt("SkinnedAsset=nil", function() component.SkinnedAsset = nil end)
    end
    if #results == 0 then return "clear=no_api" end
    return "clear=" .. table.concat(results, "|")
end

local function compact_probe_error(value)
    local text = tostring(value or "")
    text = text:gsub("[\r\n].*", "")
    if #text > 260 then text = text:sub(1, 257) .. "..." end
    return text
end

local function apply_skeletal_mesh_route(component, mesh, route)
    if not is_valid(component) then return false, "invalid preview component" end
    if not is_valid(mesh) then return false, "invalid target mesh" end
    local normalized = trim(route):lower()
    if normalized == "" then normalized = "auto" end
    normalized = normalized:gsub("%-", "_")

    if normalized == "auto" or normalized == "skinned" then
        if component.SetSkinnedAssetAndUpdate then
            local ok, err = pcall(function() component:SetSkinnedAssetAndUpdate(mesh, true) end)
            if ok then return true, "SetSkinnedAssetAndUpdate" end
            return false, "SetSkinnedAssetAndUpdate failed: " .. tostring(err)
        end
        if normalized == "skinned" then return false, "SetSkinnedAssetAndUpdate missing" end
    end
    if normalized == "skinned_false" or normalized == "skinnedfalse" then
        if component.SetSkinnedAssetAndUpdate then
            local ok, err = pcall(function() component:SetSkinnedAssetAndUpdate(mesh, false) end)
            if ok then return true, "SetSkinnedAssetAndUpdate(false)" end
            return false, "SetSkinnedAssetAndUpdate(false) failed: " .. tostring(err)
        end
        return false, "SetSkinnedAssetAndUpdate missing"
    end
    if normalized == "transmog" or normalized == "transmog_order" then
        local errors = {}
        if component.SetSkeletalMesh then
            local ok, err = pcall(function() component:SetSkeletalMesh(mesh, true) end)
            if ok then return true, "transmog:SetSkeletalMesh(true)" end
            errors[#errors + 1] = "SetSkeletalMesh(true)=" .. compact_probe_error(err)
            ok, err = pcall(function() component:SetSkeletalMesh(mesh) end)
            if ok then return true, "transmog:SetSkeletalMesh(raw)" end
            errors[#errors + 1] = "SetSkeletalMesh(raw)=" .. compact_probe_error(err)
        else
            errors[#errors + 1] = "SetSkeletalMesh=missing"
        end
        if component.SetSkeletalMeshAsset then
            local ok, err = pcall(function() component:SetSkeletalMeshAsset(mesh) end)
            if ok then return true, "transmog:SetSkeletalMeshAsset(raw)" end
            errors[#errors + 1] = "SetSkeletalMeshAsset(raw)=" .. compact_probe_error(err)
            ok, err = pcall(function() component:SetSkeletalMeshAsset(mesh, true) end)
            if ok then return true, "transmog:SetSkeletalMeshAsset(true)" end
            errors[#errors + 1] = "SetSkeletalMeshAsset(true)=" .. compact_probe_error(err)
        else
            errors[#errors + 1] = "SetSkeletalMeshAsset=missing"
        end
        local ok, err = pcall(function() component.SkeletalMesh = mesh end)
        if ok then return true, "transmog:SkeletalMesh field" end
        errors[#errors + 1] = "SkeletalMesh field=" .. compact_probe_error(err)
        return false, table.concat(errors, " | ")
    end
    if normalized == "skeletal" then
        if component.SetSkeletalMesh then
            local ok, err = pcall(function() component:SetSkeletalMesh(mesh, true) end)
            if ok then return true, "SetSkeletalMesh(true)" end
            return false, "SetSkeletalMesh(true) failed: " .. tostring(err)
        end
        return false, "SetSkeletalMesh missing"
    end
    if normalized == "skeletal_raw" or normalized == "skeletalraw" then
        if component.SetSkeletalMesh then
            local ok, err = pcall(function() component:SetSkeletalMesh(mesh) end)
            if ok then return true, "SetSkeletalMesh(raw)" end
            return false, "SetSkeletalMesh(raw) failed: " .. tostring(err)
        end
        return false, "SetSkeletalMesh missing"
    end
    if normalized == "asset" or normalized == "asset_raw" or normalized == "assetraw" then
        if component.SetSkeletalMeshAsset then
            local ok, err = pcall(function() component:SetSkeletalMeshAsset(mesh) end)
            if ok then return true, "SetSkeletalMeshAsset(raw)" end
            return false, "SetSkeletalMeshAsset(raw) failed: " .. tostring(err)
        end
        return false, "SetSkeletalMeshAsset missing"
    end
    if normalized == "asset_true" or normalized == "assettrue" then
        if component.SetSkeletalMeshAsset then
            local ok, err = pcall(function() component:SetSkeletalMeshAsset(mesh, true) end)
            if ok then return true, "SetSkeletalMeshAsset(true)" end
            return false, "SetSkeletalMeshAsset(true) failed: " .. tostring(err)
        end
        return false, "SetSkeletalMeshAsset missing"
    end
    if normalized == "field_skeletal" or normalized == "skeletal_field" then
        local ok, err = pcall(function() component.SkeletalMesh = mesh end)
        if ok then return true, "SkeletalMesh field" end
        return false, "SkeletalMesh field failed: " .. tostring(err)
    end
    if normalized == "field_skinned" or normalized == "skinned_field" then
        local ok, err = pcall(function() component.SkinnedAsset = mesh end)
        if ok then return true, "SkinnedAsset field" end
        return false, "SkinnedAsset field failed: " .. tostring(err)
    end
    local clear_prefix, followup = normalized:match("^(clear_then)_(.+)$")
    if clear_prefix and followup and followup ~= "" then
        local clear_detail = clear_skeletal_mesh_for_probe(component)
        local ok, detail = apply_skeletal_mesh_route(component, mesh, followup)
        return ok, tostring(clear_detail) .. " -> " .. tostring(detail)
    end

    return false, "unknown skeletal route '" .. tostring(route) .. "'"
end

local function set_preview_component_mesh(component, kind, mesh, route)
    if not is_valid(component) then return false, "invalid preview component" end
    if not is_valid(mesh) then return false, "invalid target mesh" end
    if kind == "skeletal" then
        if route and trim(route) ~= "" then
            return apply_skeletal_mesh_route(component, mesh, route)
        end
        if component.SetSkinnedAssetAndUpdate then
            local ok = pcall(function() component:SetSkinnedAssetAndUpdate(mesh, true) end)
            if ok then return true, "SetSkinnedAssetAndUpdate" end
        end
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
        ok = pcall(function() component.SkinnedAsset = mesh end)
        if ok then return true, "SkinnedAsset field" end
        return false, "no skeletal preview setter"
    end
    if kind == "static" then
        if component.SetStaticMesh then
            local ok = pcall(function() return component:SetStaticMesh(mesh) end)
            if ok then return true, "SetStaticMesh" end
        end
        local ok = pcall(function() component.StaticMesh = mesh end)
        if ok then return true, "StaticMesh field" end
        return false, "no static preview setter"
    end
    return false, "unsupported preview component kind " .. tostring(kind)
end

local function component_class_path(kind)
    if kind == "skeletal" then return "/Script/Engine.SkeletalMeshComponent" end
    if kind == "static" then return "/Script/Engine.StaticMeshComponent" end
    return nil
end

local function diag_push(diag, key, value)
    if type(diag) ~= "table" then return end
    diag[key] = diag[key] or {}
    diag[key][#diag[key] + 1] = tostring(value)
end

local function component_label(component)
    if not is_valid(component) then return "<invalid>" end
    local name = safe_short_name(component)
    local cls = class_name(component)
    if cls ~= "" then return tostring(name) .. "[" .. tostring(cls) .. "]" end
    return tostring(name)
end

local function add_component_candidate(list, seen, component, label)
    if not is_valid(component) then return end
    local key = safe_full_name(component) or tostring(component)
    if seen[key] then return end
    local kind = component_kind(component)
    if not kind then return end
    seen[key] = true
    local mesh = component_mesh_asset(component, kind)
    list[#list + 1] = {
        component = component,
        label = label or safe_short_name(component),
        kind = kind,
        mesh = mesh,
        mesh_name = is_valid(mesh) and safe_short_name(mesh) or "<none>",
        material_count = component_material_count(component),
        flags = read_visibility_flags(component),
    }
end

local function root_component_for_actor(actor, diag)
    if not is_valid(actor) then return nil end
    local attempts = {}
    local direct = read_field(actor, "RootComponent")
    if is_valid(direct) then
        if diag then diag.root_route = "RootComponent" end
        return direct
    end
    attempts[#attempts + 1] = "RootComponent=<nil>"
    if actor.K2_GetRootComponent then
        local ok, root = pcall(function() return actor:K2_GetRootComponent() end)
        if ok and is_valid(root) then
            if diag then diag.root_route = "K2_GetRootComponent" end
            return root
        end
        attempts[#attempts + 1] = "K2_GetRootComponent=" .. tostring(ok and "<nil>" or root)
    end
    if actor.GetRootComponent then
        local ok, root = pcall(function() return actor:GetRootComponent() end)
        if ok and is_valid(root) then
            if diag then diag.root_route = "GetRootComponent" end
            return root
        end
        attempts[#attempts + 1] = "GetRootComponent=" .. tostring(ok and "<nil>" or root)
    end
    if diag then diag.root_route = table.concat(attempts, ",") end
    return nil
end

local function scan_attached_children(list, seen, component, depth, diag)
    if not is_valid(component) or (tonumber(depth) or 0) > 2 then return end
    local child_containers = {}
    if component.GetAttachChildren then
        local ok, children = pcall(function() return component:GetAttachChildren() end)
        if ok and children ~= nil then
            child_containers[#child_containers + 1] = { label = "GetAttachChildren", value = children }
        else
            diag_push(diag, "child_queries", "GetAttachChildren=" .. tostring(ok and "<nil>" or children))
        end
    end
    local field_children = read_field(component, "AttachChildren")
    if field_children ~= nil then
        child_containers[#child_containers + 1] = { label = "AttachChildren", value = field_children }
    end
    for _, container in ipairs(child_containers) do
        local count = container_count(container.value)
        diag_push(diag, "child_queries", tostring(container.label) .. "#" .. tostring(depth) .. "=" .. tostring(count))
        for index = 1, math.min(count, 24) do
            local child = container_item(container.value, index)
            if is_valid(child) then
                diag_push(diag, "children", tostring(container.label) .. "#" .. tostring(index) .. "=" .. component_label(child))
                add_component_candidate(list, seen, child, tostring(container.label) .. "#" .. tostring(index))
                scan_attached_children(list, seen, child, (tonumber(depth) or 0) + 1, diag)
            end
        end
    end
end

local function add_components_by_class(actor, list, seen, kind, class_path, diag)
    local class_obj = resolve_uclass(class_path)
    local class_state = is_valid(class_obj) and "resolved" or "class_failed"
    local added = 0
    local count = 0
    local error_text = ""
    if is_valid(class_obj) and actor and actor.K2_GetComponentsByClass then
        local ok, components = pcall(function() return actor:K2_GetComponentsByClass(class_obj) end)
        if ok then
            count = container_count(components)
            for index = 1, count do
                local before = #list
                add_component_candidate(list, seen, container_item(components, index), kind .. "#" .. tostring(index))
                if #list > before then added = added + 1 end
            end
        else
            error_text = tostring(components)
        end
    elseif not (actor and actor.K2_GetComponentsByClass) then
        error_text = "K2_GetComponentsByClass missing"
    end
    diag_push(diag, "class_queries", string.format("%s:%s count=%d added=%d %s",
        tostring(kind),
        tostring(class_state),
        tonumber(count) or 0,
        tonumber(added) or 0,
        tostring(error_text)))

    if is_valid(class_obj) and actor and actor.GetComponentByClass then
        local ok, component = pcall(function() return actor:GetComponentByClass(class_obj) end)
        if ok and is_valid(component) then
            local before = #list
            add_component_candidate(list, seen, component, "GetComponentByClass:" .. tostring(kind))
            diag_push(diag, "class_queries", string.format("%s:GetComponentByClass hit added=%d",
                tostring(kind),
                #list > before and 1 or 0))
        elseif actor.GetComponentByClass then
            diag_push(diag, "class_queries", string.format("%s:GetComponentByClass %s",
                tostring(kind),
                tostring(ok and "miss" or component)))
        end
    end
end

local function mesh_components_for_actor(actor, diag)
    local list, seen = {}, {}
    for _, field_name in ipairs({
        "Mesh",
        "MeshComponent",
        "StaticMeshComponent",
        "SkeletalMeshComponent",
        "SkinnedMeshComponent",
        "CharacterMesh",
        "BuildingMesh",
        "BuildingMeshComponent",
        "PreviewMesh",
        "PreviewMeshComponent",
        "PreviewStaticMesh",
        "PreviewSkeletalMesh",
        "RootStaticMeshComponent",
        "StaticMesh",
        "SkeletalMesh",
        "MeshComp",
        "VisualMesh",
        "VisualMeshComponent",
        "RockMesh",
        "RockMeshComponent",
        "OreMesh",
        "OreMeshComponent",
        "Body",
        "Rack",
        "TanningRack",
        "RootComponent",
    }) do
        local value = read_field(actor, field_name)
        if is_valid(value) then
            diag_push(diag, "fields", tostring(field_name) .. "=" .. component_label(value))
        end
        add_component_candidate(list, seen, value, field_name)
    end
    local root = root_component_for_actor(actor, diag)
    if is_valid(root) then
        diag_push(diag, "root", component_label(root) .. " via " .. tostring(diag and diag.root_route or "root"))
        add_component_candidate(list, seen, root, "root:" .. tostring(diag and diag.root_route or "root"))
        diag_push(diag, "child_queries", "skipped; using K2_GetComponentsByClass")
    end
    if actor and actor.K2_GetComponentsByClass then
        for _, spec in ipairs({
            { "static", "/Script/Engine.StaticMeshComponent" },
            { "skeletal", "/Script/Engine.SkeletalMeshComponent" },
        }) do
            add_components_by_class(actor, list, seen, spec[1], spec[2], diag)
        end
    else
        diag_push(diag, "class_queries", "K2_GetComponentsByClass missing")
    end
    return list
end

local function compatible_preview_component(preview, kind)
    local diag = {}
    local components = mesh_components_for_actor(preview, diag)
    for _, entry in ipairs(components) do
        if entry.kind == kind then return entry, components, diag end
    end
    return nil, components, diag
end

local function compact_list(values, max_items)
    if type(values) ~= "table" or #values == 0 then return "<none>" end
    local out = {}
    local max = math.min(#values, tonumber(max_items) or 4)
    for i = 1, max do out[#out + 1] = tostring(values[i]) end
    if #values > max then out[#out + 1] = "...+" .. tostring(#values - max) end
    return table.concat(out, " | ")
end

local function preview_diag_summary(diag)
    if type(diag) ~= "table" then return "" end
    local parts = {
        "root=" .. tostring(compact_list(diag.root, 2)),
        "fields=" .. tostring(compact_list(diag.fields, 4)),
        "classes=" .. tostring(compact_list(diag.class_queries, 4)),
        "children=" .. tostring(compact_list(diag.children, 4)),
        "child_queries=" .. tostring(compact_list(diag.child_queries, 4)),
    }
    return table.concat(parts, " ; ")
end

local function preview_inspect_summary(preview, components, diag)
    if not is_valid(preview) then return "preview=<none>" end
    local xform = actor_world_transform(preview)
    local loc = xform and xform.loc or {}
    local rot = xform and xform.rot or {}
    local parts = {
        "preview=" .. tostring(safe_short_name(preview)),
        "class=" .. tostring(class_name(preview)),
        string.format("loc=(%.1f,%.1f,%.1f)", loc.X or 0, loc.Y or 0, loc.Z or 0),
        string.format("rot=(P%.1f,Y%.1f,R%.1f)", rot.Pitch or 0, rot.Yaw or 0, rot.Roll or 0),
        "components=" .. tostring(#(components or {})),
    }
    local max = math.min(#(components or {}), 6)
    for i = 1, max do
        local entry = components[i]
        parts[#parts + 1] = string.format("#%d[%s] %s mesh=%s mats=%d %s",
            i,
            tostring(entry.kind),
            tostring(entry.label),
            tostring(entry.mesh_name),
            tonumber(entry.material_count) or 0,
            visibility_summary(entry.flags))
    end
    if #(components or {}) == 0 or diag then
        parts[#parts + 1] = preview_diag_summary(diag)
    end
    return table.concat(parts, " ; ")
end

function M._probe_component_bounds_summary(component)
    if not is_valid(component) then return "bounds=missing" end
    local bounds = M._probe_raw_field(component, "Bounds")
    if bounds ~= nil then
        local origin = M._probe_raw_field(bounds, "Origin")
        local extent = M._probe_raw_field(bounds, "BoxExtent")
        local radius = M._probe_raw_field(bounds, "SphereRadius")
        if origin ~= nil or extent ~= nil or radius ~= nil then
            return "bounds=o" .. M._probe_vector_summary(origin)
                .. ",e" .. M._probe_vector_summary(extent)
                .. ",r=" .. tostring(radius or "<nil>")
        end
        return "bounds=" .. compact_probe_error(bounds)
    end
    return "bounds=<none>"
end

function M._probe_target_mesh_component_summary(actor, source)
    if not is_valid(actor) then return false, tostring(source or "target") .. " invalid" end
    local diag = {}
    local components = mesh_components_for_actor(actor, diag)
    local ax = actor_world_transform(actor) or actor_transform(actor)
    local parts = {
        "target=" .. tostring(safe_short_name(actor)),
        "class=" .. tostring(class_name(actor)),
        "source=" .. tostring(source or "target"),
        "actor_loc=" .. M._probe_vector_summary(ax and ax.loc),
        "actor_rot=" .. M._probe_rot_summary(ax and ax.rot),
        "actor_scale=" .. M._probe_vector_summary(ax and ax.scale),
        "components=" .. tostring(#components),
    }

    local max_components = math.min(#components, 12)
    for i = 1, max_components do
        local entry = components[i]
        local kind, mesh, route_or_err = get_mesh_from_component(entry.component)
        local cxform, xform_err = M._probe_component_world_transform(entry.component)
        parts[#parts + 1] = string.format(
            "#%d label=%s class=%s kind=%s mesh=%s route=%s mats=%d %s loc=%s rot=%s scale=%s %s %s",
            i,
            tostring(entry.label),
            tostring(class_name(entry.component)),
            tostring(kind or entry.kind or "<none>"),
            tostring(is_valid(mesh) and safe_short_name(mesh) or entry.mesh_name or "<none>"),
            tostring(route_or_err or "<route>"),
            tonumber(entry.material_count) or 0,
            material_summary(entry.component, 4),
            cxform and M._probe_vector_summary(cxform.loc) or ("<" .. tostring(xform_err) .. ">"),
            cxform and M._probe_rot_summary(cxform.rot) or "<unknown>",
            cxform and M._probe_vector_summary(cxform.scale) or "<unknown>",
            render_flag_summary(entry.component),
            M._probe_component_bounds_summary(entry.component))
    end
    if #components > max_components then
        parts[#parts + 1] = "more_components=" .. tostring(#components - max_components)
    end
    parts[#parts + 1] = preview_diag_summary(diag)
    return true, table.concat(parts, " ; ")
end

local function destroy_actor(actor)
    if not is_valid(actor) then return false end
    if actor.K2_DestroyActor then
        local ok = pcall(function() actor:K2_DestroyActor() end)
        if ok then return true end
    end
    if actor.DestroyActor then
        local ok = pcall(function() actor:DestroyActor() end)
        if ok then return true end
    end
    return false
end

local function remove_proxy_entry(entry)
    if not entry then return end
    for i = #proxies, 1, -1 do
        if proxies[i] == entry or proxies[i].actor == entry.actor then
            table.remove(proxies, i)
            return
        end
    end
end

local function latest_live_proxy_entry()
    if attachgrab and attachgrab.proxy_entry and is_valid(attachgrab.proxy_entry.actor) then
        return attachgrab.proxy_entry
    end
    if attachgrab_flow.starting and attachgrab_flow.starting.proxy_entry and is_valid(attachgrab_flow.starting.proxy_entry.actor) then
        return attachgrab_flow.starting.proxy_entry
    end
    if placement and placement.proxy_entry and is_valid(placement.proxy_entry.actor) then
        return placement.proxy_entry
    end
    if placement_starting and placement_starting.proxy_entry and is_valid(placement_starting.proxy_entry.actor) then
        return placement_starting.proxy_entry
    end
    for i = #proxies, 1, -1 do
        local entry = proxies[i]
        if entry and is_valid(entry.actor) then return entry end
        table.remove(proxies, i)
    end
    return nil
end

function M._proxy_assign_mesh_verified(entry)
    if not entry then return false, "missing proxy entry" end
    local component = entry.component
    if not is_valid(component) then return false, "proxy component invalid" end
    local mesh = entry.mesh
    if not is_valid(mesh) then return false, "proxy mesh invalid" end

    local details = {}
    local function verify(label)
        local current = component_mesh_asset(component, entry.kind)
        if is_valid(current) then
            entry.mesh_ready = true
            entry.mesh_ready_detail = tostring(label) .. "=" .. tostring(safe_short_name(current))
            entry.material_count = apply_proxy_materials(component, entry.source_component and get_materials(entry.source_component) or {})
            make_proxy_renderable(entry.actor, component)
            return true, entry.mesh_ready_detail
        end
        details[#details + 1] = tostring(label) .. "=<none>"
        return false, nil
    end

    local ready, detail = verify("before")
    if ready then return true, detail end

    if entry.kind == "static" then
        if component.SetStaticMesh then
            local ok, value = pcall(function() return component:SetStaticMesh(mesh) end)
            details[#details + 1] = "SetStaticMesh=" .. tostring(ok and ("ok:" .. tostring(value)) or ("err:" .. compact_probe_error(value)))
            ready, detail = verify("SetStaticMesh.after")
            if ready then return true, detail .. " ; " .. table.concat(details, " ; ") end
        else
            details[#details + 1] = "SetStaticMesh=missing"
        end

        local ok_field, field_err = pcall(function()
            component.StaticMesh = mesh
            return true
        end)
        details[#details + 1] = "StaticMesh_field=" .. tostring(ok_field and "ok" or ("err:" .. compact_probe_error(field_err)))
        if component.OnRep_StaticMesh then
            local ok_rep, rep_err = pcall(function() return component:OnRep_StaticMesh(nil) end)
            details[#details + 1] = "OnRep_StaticMesh(nil)=" .. tostring(ok_rep and "ok" or ("err:" .. compact_probe_error(rep_err)))
        end
        ready, detail = verify("field.after")
        if ready then return true, detail .. " ; " .. table.concat(details, " ; ") end
    else
        local ok_mesh, mesh_route = set_proxy_mesh(component, entry.kind, mesh)
        details[#details + 1] = "set_proxy_mesh=" .. tostring(ok_mesh) .. ":" .. tostring(mesh_route)
        ready, detail = verify("set_proxy_mesh.after")
        if ready then return true, detail .. " ; " .. table.concat(details, " ; ") end
    end

    make_proxy_renderable(entry.actor, component)
    ready, detail = verify("render_refresh.after")
    if ready then return true, detail .. " ; " .. table.concat(details, " ; ") end

    entry.mesh_ready = false
    entry.mesh_ready_detail = table.concat(details, " ; ")
    return false, entry.mesh_ready_detail
end

local function spawn_proxy_for_actor(actor, xform, source)
    if not is_valid(actor) then return nil, "invalid target actor" end

    local desc, desc_err = find_mesh_descriptor(actor)
    if not desc then return nil, tostring(desc_err) end

    local class_obj, class_detail = resolve_native_actor_class(desc.kind)
    if not class_obj then return nil, class_detail end

    local proxy_xform = xform or desc.component_transform or actor_transform(actor)
    local proxy, spawn_err = spawn_actor(class_obj, proxy_xform)
    if not proxy then return nil, spawn_err end

    local component, component_label = proxy_component(proxy, desc.kind)
    if not component then
        destroy_actor(proxy)
        return nil, "proxy spawned but mesh component was not found"
    end

    local ok_mesh, mesh_route = set_proxy_mesh(component, desc.kind, desc.mesh)
    if not ok_mesh then
        destroy_actor(proxy)
        return nil, "proxy mesh assignment failed: " .. tostring(mesh_route)
    end

    local material_count = apply_proxy_materials(component, desc.materials)
    local scale_source = (xform and xform.scale) or (desc.component_transform and desc.component_transform.scale)
    if desc.kind == "skeletal" then
        scale_source = (desc.component_transform and desc.component_transform.scale) or (xform and xform.scale)
    end
    local scale = copy_scale(scale_source)
    feature_actor.force_actor_movable(proxy)
    feature_actor.set_actor_scale3d(proxy, scale)
    make_proxy_renderable(proxy, component)

    local proxy_name = safe_short_name(proxy)
    local target_name = safe_short_name(actor)
    local mesh_name = safe_short_name(desc.mesh)
    local entry = {
        actor = proxy,
        component = component,
        target = actor,
        target_name = target_name,
        kind = desc.kind,
        mesh = desc.mesh,
        source_component = desc.component,
        proxy_name = proxy_name,
        mesh_name = mesh_name,
        component_label = component_label,
        source_component_label = desc.component_label,
        material_count = material_count,
        visual_scale = scale,
    }
    proxies[#proxies + 1] = entry
    local mesh_ready, mesh_ready_detail = M._proxy_assign_mesh_verified(entry)
    entry.mesh_ready = mesh_ready == true
    entry.mesh_ready_detail = tostring(mesh_ready_detail or "")

    print(string.format(
        "[RSDWTools.oculus.proxy] spawned kind=%s target=%s source=%s src_comp=%s src_mesh=%s proxy=%s proxy_comp=%s class=%s mesh_route=%s materials=%d mesh_ready=%s loc=(%.1f,%.1f,%.1f) scale=(%.2f,%.2f,%.2f) src_%s proxy_%s",
        tostring(desc.kind),
        tostring(target_name),
        tostring(source),
        tostring(desc.component_label),
        tostring(mesh_name),
        tostring(proxy_name),
        tostring(component_label),
        tostring(class_detail),
        tostring(desc.mesh_route),
        material_count,
        tostring(entry.mesh_ready_detail),
        proxy_xform.loc and proxy_xform.loc.X or 0,
        proxy_xform.loc and proxy_xform.loc.Y or 0,
        proxy_xform.loc and proxy_xform.loc.Z or 0,
        scale.X or 1,
        scale.Y or 1,
        scale.Z or 1,
        render_flag_summary(desc.component),
        render_flag_summary(component)))

    return entry, nil
end

local function read_actor_hidden(actor)
    if not is_valid(actor) then return nil end
    local hidden
    if actor.IsHidden then
        pcall(function() hidden = actor:IsHidden() end)
    end
    if hidden == nil and actor.GetActorHiddenInGame then
        pcall(function() hidden = actor:GetActorHiddenInGame() end)
    end
    if hidden == nil then
        pcall(function() hidden = actor.bHidden end)
    end
    if hidden == nil then return false end
    return hidden == true
end

local function set_actor_hidden(actor, hidden)
    if not is_valid(actor) then return false end
    if actor.SetActorHiddenInGame then
        local ok = pcall(function() actor:SetActorHiddenInGame(hidden == true) end)
        if ok then return true end
    end
    local ok = pcall(function() actor.bHidden = hidden == true end)
    return ok == true
end

local function visibility_snapshot(component)
    local rec = { component = component }
    pcall(function() rec.hidden = component.bHiddenInGame end)
    pcall(function() rec.visible = component.bVisible end)
    pcall(function() rec.render = component.bRenderInMainPass end)
    return rec
end

local function hide_component_visual(component)
    if not is_valid(component) then return false end
    local changed = false
    if component.SetHiddenInGame then
        local ok = pcall(function() component:SetHiddenInGame(true, false) end)
        changed = changed or ok
    end
    if component.SetVisibility then
        local ok = pcall(function() component:SetVisibility(false, false) end)
        changed = changed or ok
    end
    if component.SetRenderInMainPass then
        local ok = pcall(function() component:SetRenderInMainPass(false) end)
        changed = changed or ok
    end
    if component.MarkRenderStateDirty then pcall(function() component:MarkRenderStateDirty() end) end
    return changed
end

local function restore_component_visuals(snapshot)
    if type(snapshot) ~= "table" then return 0 end
    local restored = 0
    for _, rec in ipairs(snapshot) do
        local component = rec and rec.component
        if is_valid(component) then
            if rec.hidden ~= nil and component.SetHiddenInGame then
                pcall(function() component:SetHiddenInGame(rec.hidden == true, false) end)
            end
            if rec.visible ~= nil and component.SetVisibility then
                pcall(function() component:SetVisibility(rec.visible == true, false) end)
            end
            if rec.render ~= nil and component.SetRenderInMainPass then
                pcall(function() component:SetRenderInMainPass(rec.render == true) end)
            end
            if component.MarkRenderStateDirty then pcall(function() component:MarkRenderStateDirty() end) end
            restored = restored + 1
        end
    end
    return restored
end

local function same_component(a, b)
    if not (is_valid(a) and is_valid(b)) then return false end
    if a == b then return true end
    local a_name = safe_full_name(a)
    local b_name = safe_full_name(b)
    return a_name ~= nil and b_name ~= nil and a_name == b_name
end

local function hide_preview_sibling_visuals(preview, selected_component)
    if not is_valid(preview) or not is_valid(selected_component) then return {}, 0 end
    local fields = {
        "HeadMesh",
        "BodyMesh",
    }
    local seen = {}
    local snapshot = {}
    local hidden = 0
    for _, field_name in ipairs(fields) do
        local component = read_field(preview, field_name)
        if is_valid(component) and not same_component(component, selected_component) then
            local key = safe_full_name(component) or tostring(component)
            if not seen[key] then
                seen[key] = true
                local kind = component_kind(component)
                if kind or component.SetVisibility or component.SetHiddenInGame or component.SetRenderInMainPass then
                    snapshot[#snapshot + 1] = visibility_snapshot(component)
                    if hide_component_visual(component) then hidden = hidden + 1 end
                end
            end
        end
    end
    return snapshot, hidden
end

local function hide_preview_component_proxy_host_visuals(preview, proxy_component)
    if not is_valid(preview) or not is_valid(proxy_component) then return {}, 0 end
    local fields = {
        "Mesh",
        "StaticMesh",
        "StaticMeshComponent",
        "PreviewMesh",
        "PreviewMeshComponent",
        "PreviewStaticMesh",
        "BuildingMesh",
        "BuildingMeshComponent",
        "HeadMesh",
        "BodyMesh",
    }
    local seen = {}
    local snapshot = {}
    local hidden = 0
    for _, field_name in ipairs(fields) do
        local component = read_field(preview, field_name)
        if is_valid(component) and not same_component(component, proxy_component) then
            local key = safe_full_name(component) or tostring(component)
            if not seen[key] then
                seen[key] = true
                local kind = component_kind(component)
                if kind or component.SetVisibility or component.SetHiddenInGame or component.SetRenderInMainPass then
                    snapshot[#snapshot + 1] = visibility_snapshot(component)
                    if hide_component_visual(component) then hidden = hidden + 1 end
                end
            end
        end
    end
    return snapshot, hidden
end

local function hide_preview_host_visuals(preview)
    if not is_valid(preview) then return {}, 0 end
    local fields = {
        "Mesh",
        "MeshComponent",
        "StaticMeshComponent",
        "SkeletalMeshComponent",
        "SkinnedMeshComponent",
        "CharacterMesh",
        "BuildingMesh",
        "PreviewMesh",
        "RootComponent",
    }
    local seen = {}
    local snapshot = {}
    local hidden = 0
    for _, field_name in ipairs(fields) do
        local component = read_field(preview, field_name)
        if is_valid(component) then
            local key = safe_full_name(component) or tostring(component)
            if not seen[key] then
                seen[key] = true
                local kind = component_kind(component)
                if kind or component.SetVisibility or component.SetHiddenInGame or component.SetRenderInMainPass then
                    snapshot[#snapshot + 1] = visibility_snapshot(component)
                    if hide_component_visual(component) then hidden = hidden + 1 end
                end
            end
        end
    end
    return snapshot, hidden
end

local function attach_proxy_to_preview(entry, preview, prefer_component)
    local proxy = entry and entry.actor
    if not is_valid(proxy) or not is_valid(preview) then return false, "invalid proxy/preview" end
    local socket = (FName and FName("")) or ""
    local attempts = {}
    local actor_attempts = {}
    local component_attempts = {}
    local preview_root = read_field(preview, "RootComponent")
    if proxy.K2_AttachToActor then
        actor_attempts[#actor_attempts + 1] = { "K2_AttachToActor KeepWorld", function()
            return proxy:K2_AttachToActor(preview, socket, "KeepWorld", "KeepWorld", "KeepWorld", false)
        end }
        actor_attempts[#actor_attempts + 1] = { "K2_AttachToActor enum", function()
            return proxy:K2_AttachToActor(preview, socket, "EAttachmentRule::KeepWorld", "EAttachmentRule::KeepWorld", "EAttachmentRule::KeepWorld", false)
        end }
        actor_attempts[#actor_attempts + 1] = { "K2_AttachToActor numeric", function()
            return proxy:K2_AttachToActor(preview, socket, 1, 1, 1, false)
        end }
    end
    if is_valid(preview_root) and proxy.K2_AttachToComponent then
        component_attempts[#component_attempts + 1] = { "K2_AttachToComponent KeepWorld", function()
            return proxy:K2_AttachToComponent(preview_root, socket, "KeepWorld", "KeepWorld", "KeepWorld", false)
        end }
        component_attempts[#component_attempts + 1] = { "K2_AttachToComponent numeric", function()
            return proxy:K2_AttachToComponent(preview_root, socket, 1, 1, 1, false)
        end }
    end
    local ordered = prefer_component and { component_attempts, actor_attempts } or { actor_attempts, component_attempts }
    for _, list in ipairs(ordered) do
        for _, attempt in ipairs(list) do
            attempts[#attempts + 1] = attempt
        end
    end

    local function zero_relative_after_attach()
        local root = read_field(proxy, "RootComponent")
        if not is_valid(root) then return "rel=<no_root>" end
        local results = {}
        local function note(label, fn)
            local ok, err = pcall(fn)
            results[#results + 1] = tostring(label) .. "=" .. tostring(ok and "ok" or compact_probe_error(err))
            return ok
        end
        if root.K2_SetRelativeLocation then
            note("K2_SetRelativeLocation", function() return root:K2_SetRelativeLocation({ X = 0, Y = 0, Z = 0 }, false, {}, false) end)
        elseif root.SetRelativeLocation then
            note("SetRelativeLocation", function() return root:SetRelativeLocation({ X = 0, Y = 0, Z = 0 }) end)
        end
        if root.K2_SetRelativeRotation then
            note("K2_SetRelativeRotation", function() return root:K2_SetRelativeRotation({ Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, false) end)
        elseif root.SetRelativeRotation then
            note("SetRelativeRotation", function() return root:SetRelativeRotation({ Pitch = 0, Yaw = 0, Roll = 0 }) end)
        end
        results[#results + 1] = "SetRelativeScale3D=preserved"
        if #results == 0 then return "rel=no_api" end
        return "rel=" .. table.concat(results, ",")
    end

    local last_err = "no attach function"
    for _, attempt in ipairs(attempts) do
        local ok, result = pcall(attempt[2])
        if ok and result ~= false then
            local rel_detail = ""
            if prefer_component then rel_detail = " " .. zero_relative_after_attach() end
            return true, attempt[1] .. rel_detail
        end
        last_err = tostring(attempt[1]) .. " failed: " .. tostring(result)
    end
    return false, last_err
end

local function component_parent_label(component)
    if not is_valid(component) then return "<none>" end
    local parent
    if component.GetAttachParent then
        pcall(function() parent = component:GetAttachParent() end)
    end
    if not is_valid(parent) then
        parent = read_field(component, "AttachParent")
    end
    return is_valid(parent) and safe_short_name(parent) or "<none>"
end

local function actor_parent_label(actor)
    if not is_valid(actor) then return "<none>" end
    local parent
    if actor.GetAttachParentActor then
        pcall(function() parent = actor:GetAttachParentActor() end)
    end
    return is_valid(parent) and safe_short_name(parent) or "<none>"
end

local function attachment_summary(actor)
    if not is_valid(actor) then return "actor=<invalid>" end
    local root = read_field(actor, "RootComponent")
    return string.format("actor_parent=%s root=%s root_parent=%s",
        actor_parent_label(actor),
        is_valid(root) and safe_short_name(root) or "<none>",
        component_parent_label(root))
end

local function loc_delta(a, b)
    if not a or not b then return nil end
    local dx = (a.X or 0) - (b.X or 0)
    local dy = (a.Y or 0) - (b.Y or 0)
    local dz = (a.Z or 0) - (b.Z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

actor_world_transform = function(actor)
    if not is_valid(actor) then return nil, "invalid actor" end
    local loc = feature_actor.actor_location(actor)
    local rot = feature_actor.actor_rotation(actor)
    if not loc then return nil, "could not read actor location" end
    return {
        loc = copy_loc(loc),
        rot = copy_rot(rot),
        scale = copy_scale(feature_actor.get_actor_scale3d(actor)),
    }, nil
end

local function component_world_transform(component)
    if not is_valid(component) then return nil, "invalid component" end
    local loc, rot, scale
    if component.K2_GetComponentLocation then
        pcall(function() loc = component:K2_GetComponentLocation() end)
    elseif component.GetComponentLocation then
        pcall(function() loc = component:GetComponentLocation() end)
    end
    if component.K2_GetComponentRotation then
        pcall(function() rot = component:K2_GetComponentRotation() end)
    elseif component.GetComponentRotation then
        pcall(function() rot = component:GetComponentRotation() end)
    end
    if component.GetComponentScale then
        pcall(function() scale = component:GetComponentScale() end)
    end
    if not loc then return nil, "could not read component location" end
    return {
        loc = copy_loc(loc),
        rot = copy_rot(rot),
        scale = copy_scale(scale),
    }, nil
end

function M._probe_component_world_transform(component)
    return component_world_transform(component)
end

local function current_preview_transform(session)
    local preview = session and session.preview
    if not is_valid(preview) then
        preview = nil
        local fresh = feature_build_preview.current_preview_piece
        if fresh then
            local p = fresh()
            if is_valid(p) then preview = p end
        end
    end
    if not is_valid(preview) then return nil, "no live PreviewPiece" end
    return actor_world_transform(preview)
end

local function current_proxy_transform(session)
    local entry = session and session.proxy_entry
    if not entry then return nil, "no proxy entry" end
    if is_valid(entry.component) then
        local xform = component_world_transform(entry.component)
        if xform then return xform, "proxy_component" end
    end
    if is_valid(entry.actor) then
        local xform = actor_world_transform(entry.actor)
        if xform then return xform, "proxy_actor" end
    end
    return nil, "proxy no longer valid"
end

local function exit_build_preview(session)
    if session and is_valid(session.bmc) and session.bmc.ExitAnyMode then
        pcall(function() session.bmc:ExitAnyMode() end)
        pcall(function() session.bmc:ExitAnyMode() end)
    else
        pcall(function() feature_build_preview.cancel() end)
    end
end

local function restore_target_visibility(session)
    if session and is_valid(session.target) then
        set_actor_hidden(session.target, session.original_hidden == true)
    end
end

local function release_preview_swap_guard(session, reason)
    if session and session.guard_token then
        pcall(function() feature_oculus_input_guard.release(session.guard_token, reason or "preview.swap") end)
        session.guard_token = nil
    end
end

local function destroy_proxy_entry(entry)
    if entry then
        remove_proxy_entry(entry)
        if is_valid(entry.actor) then destroy_actor(entry.actor) end
    end
end

local function cleanup_placement(session, restore_preview)
    if not session then return end
    if restore_preview then
        restore_component_visuals(session.preview_visuals)
    end
    destroy_proxy_entry(session.proxy_entry)
    exit_build_preview(session)
end

local function schedule_frames(frames, fn)
    return feature_oculus_async.schedule_game_thread_after_frames(frames, function()
        local ok, err = pcall(fn)
        if not ok then
            print("[RSDWTools.oculus.proxy.place] staged step failed: " .. tostring(err))
            if placement_starting then
                local pending = placement_starting
                placement_starting = nil
                destroy_proxy_entry(pending.proxy_entry)
                exit_build_preview(pending)
            end
            if preview_swap_starting then
                local pending = preview_swap_starting
                preview_swap_starting = nil
                mark_preview_swap_settle("schedule_frames_error")
                exit_build_preview(pending)
            end
            if preview_move and preview_move.phase ~= "active" then
                local pending = preview_move
                preview_move = nil
                mark_preview_swap_settle("preview_move_schedule_frames_error")
                if pending.guard_token then
                    pcall(function() feature_oculus_input_guard.release(pending.guard_token, "preview.move.error") end)
                    pending.guard_token = nil
                end
                exit_build_preview(pending)
            end
        end
    end)
end

local function schedule_ms(delay_ms, fn)
    return feature_oculus_async.schedule_game_thread(delay_ms, function()
        local ok, err = pcall(fn)
        if not ok then
            print("[RSDWTools.oculus.proxy.place] staged step failed: " .. tostring(err))
            if placement_starting then
                local pending = placement_starting
                placement_starting = nil
                destroy_proxy_entry(pending.proxy_entry)
                exit_build_preview(pending)
            end
            if preview_swap_starting then
                local pending = preview_swap_starting
                preview_swap_starting = nil
                mark_preview_swap_settle("schedule_ms_error")
                exit_build_preview(pending)
            end
            if preview_move and preview_move.phase ~= "active" then
                local pending = preview_move
                preview_move = nil
                mark_preview_swap_settle("preview_move_schedule_ms_error")
                if pending.guard_token then
                    pcall(function() feature_oculus_input_guard.release(pending.guard_token, "preview.move.error") end)
                    pending.guard_token = nil
                end
                exit_build_preview(pending)
            end
        end
    end)
end

sync_proxy_to_preview_once = function(session)
    if not session then return false, "no placement session" end
    local entry = session.proxy_entry
    if not entry or not is_valid(entry.actor) then return false, "proxy actor invalid" end

    print(string.format("[RSDWTools.oculus.proxy.place] trace target=%s phase=%s sync current_preview_transform begin",
        tostring(session.target_name or "<target>"), tostring(session.phase or "?")))
    local xform, xform_err = current_preview_transform(session)
    if not xform then return false, tostring(xform_err or "PreviewPiece transform unavailable") end
    print(string.format("[RSDWTools.oculus.proxy.place] trace target=%s phase=%s sync current_preview_transform ok loc=(%.1f,%.1f,%.1f)",
        tostring(session.target_name or "<target>"),
        tostring(session.phase or "?"),
        xform.loc and xform.loc.X or 0,
        xform.loc and xform.loc.Y or 0,
        xform.loc and xform.loc.Z or 0))

    print(string.format("[RSDWTools.oculus.proxy.place] trace target=%s phase=%s sync move_actor begin",
        tostring(session.target_name or "<target>"), tostring(session.phase or "?")))
    local ok_loc = feature_actor.move_actor(entry.actor, xform.loc)
    print(string.format("[RSDWTools.oculus.proxy.place] trace target=%s phase=%s sync move_actor result=%s",
        tostring(session.target_name or "<target>"), tostring(session.phase or "?"), tostring(ok_loc)))
    local ok_rot = true
    if xform.rot then
        print(string.format("[RSDWTools.oculus.proxy.place] trace target=%s phase=%s sync set_actor_rotation begin",
            tostring(session.target_name or "<target>"), tostring(session.phase or "?")))
        ok_rot = feature_actor.set_actor_rotation(entry.actor, xform.rot)
        print(string.format("[RSDWTools.oculus.proxy.place] trace target=%s phase=%s sync set_actor_rotation result=%s",
            tostring(session.target_name or "<target>"), tostring(session.phase or "?"), tostring(ok_rot)))
    end
    if not (ok_loc and ok_rot) then
        return false, string.format("proxy sync failed loc=%s rot=%s",
            tostring(ok_loc), tostring(ok_rot))
    end
    return true, "visual_attach"
end

local function active_pending(token)
    local pending = placement_starting
    if not pending or pending.token ~= token then return nil end
    if pending.cancelled == true then return nil end
    if placement then
        placement_starting = nil
        return nil
    end
    return pending
end

local function fail_pending_start(pending, reason)
    if not pending then return end
    if placement_starting and placement_starting.token == pending.token then
        placement_starting = nil
    end
    destroy_proxy_entry(pending.proxy_entry)
    exit_build_preview(pending)
    print("[RSDWTools.oculus.proxy.place] start failed target=" .. tostring(pending.target_name) .. " ; " .. tostring(reason))
end

local place_start_arm
local place_start_spawn
local place_start_sample
local place_start_attach
local place_start_finalize

local function trace_pending(pending, message)
    print(string.format("[RSDWTools.oculus.proxy.place] trace target=%s phase=%s %s",
        tostring(pending and pending.target_name or "<target>"),
        tostring(pending and pending.phase or "?"),
        tostring(message)))
end

local function move_target_once(target, xform)
    if not is_valid(target) then return false, "target actor is invalid" end
    if not xform or not xform.loc then return false, "missing destination transform" end

    local preserved_scale = feature_actor.get_actor_scale3d(target)
    feature_actor.force_actor_movable(target)

    local ok_loc, loc_err = feature_actor.move_actor(target, xform.loc)
    local ok_rot = true
    if xform.rot then
        ok_rot = feature_actor.set_actor_rotation(target, xform.rot)
    end
    local ok_scale = true
    if preserved_scale then
        ok_scale = feature_actor.set_actor_scale3d(target, preserved_scale)
    end

    if not (ok_loc and ok_rot and ok_scale) then
        return false, string.format("partial proxy transform apply failed: loc=%s rot=%s scale=%s%s",
            tostring(ok_loc),
            tostring(ok_rot),
            tostring(ok_scale),
            loc_err and (" loc_err=" .. tostring(loc_err)) or "")
    end

    return true, string.format("applied loc=(%.2f,%.2f,%.2f) rot=(%.2f,%.2f,%.2f) scale=(%.3f,%.3f,%.3f)",
        xform.loc.X or 0,
        xform.loc.Y or 0,
        xform.loc.Z or 0,
        xform.rot and xform.rot.Pitch or 0,
        xform.rot and xform.rot.Yaw or 0,
        xform.rot and xform.rot.Roll or 0,
        preserved_scale and preserved_scale.X or 1,
        preserved_scale and preserved_scale.Y or 1,
        preserved_scale and preserved_scale.Z or 1)
end

local function target_transform_from_proxy(session)
    local proxy_xform, source = current_preview_transform(session)
    if proxy_xform then
        source = "preview_actor"
    else
        proxy_xform, source = current_proxy_transform(session)
    end
    if not proxy_xform then return nil, source end
    local xform = {
        loc = copy_loc(proxy_xform.loc),
        rot = copy_rot(proxy_xform.rot),
        scale = copy_scale(proxy_xform.scale),
    }
    if session and session.root_from_mesh_offset then
        xform.loc = vec_add(xform.loc, session.root_from_mesh_offset)
    end
    if session and session.root_from_mesh_rotation then
        xform.rot = rot_add(xform.rot, session.root_from_mesh_rotation)
    end
    return xform, source
end

local function preview_swap_host_for(kind)
    if kind == "skeletal" then return PREVIEW_SWAP_SKELETAL_HOST end
    return PREVIEW_SWAP_STATIC_HOST
end

local function preview_swap_fallbacks_for(kind)
    return PREVIEW_SWAP_HOST_FALLBACKS[kind] or {}
end

local function fail_preview_swap_start(session, reason)
    if preview_swap_starting and preview_swap_starting.token == session.token then
        preview_swap_starting = nil
    end
    mark_preview_swap_settle("failed")
    release_preview_swap_guard(session, "preview.swap.failed")
    restore_target_visibility(session)
    exit_build_preview(session)
    print("[RSDWTools.oculus.preview.swap] start failed target=" .. tostring(session.target_name)
        .. " ; " .. tostring(reason))
end

local preview_swap_debug_detail

local function snapshot_preview_component(component, kind)
    if not is_valid(component) then return nil end
    return {
        component = component,
        kind = kind,
        mesh = component_mesh_asset(component, kind),
        materials = get_materials(component),
        flags = read_visibility_flags(component),
    }
end

local function object_name_for_preview_component(session)
    local token = session and session.token or math.floor(now_ms())
    return PREVIEW_COMPONENT_PROXY_NAME_PREFIX .. tostring(token)
end

local function try_component_call(results, label, fn)
    local ok, value = pcall(fn)
    results[#results + 1] = tostring(label) .. "=" .. tostring(ok and "ok" or compact_probe_error(value))
    return ok, value
end

local function attach_component_to_preview_root(component, preview)
    local results = {}
    local diag = {}
    local root = root_component_for_actor(preview, diag)
    if not is_valid(root) then
        return false, "preview root missing: " .. tostring(diag.root_route or "unknown")
    end
    local socket = ""
    local attached = false
    if component.K2_AttachToComponent then
        local ok = try_component_call(results, "K2_AttachToComponent KeepRelative", function()
            return component:K2_AttachToComponent(root, socket, "KeepRelative", "KeepRelative", "KeepRelative", false)
        end)
        attached = attached or ok
        if not ok then
            ok = try_component_call(results, "K2_AttachToComponent numeric", function()
                return component:K2_AttachToComponent(root, socket, 0, 0, 0, false)
            end)
            attached = attached or ok
        end
    end
    if (not attached) and component.AttachToComponent then
        local ok = try_component_call(results, "AttachToComponent numeric", function()
            return component:AttachToComponent(root, socket, 0, 0, 0, false)
        end)
        attached = attached or ok
    end
    if not attached then
        return false, table.concat(results, " | ")
    end

    if component.SetRelativeLocation then
        try_component_call(results, "SetRelativeLocation", function() component:SetRelativeLocation({ X = 0, Y = 0, Z = 0 }) end)
    elseif component.K2_SetRelativeLocation then
        try_component_call(results, "K2_SetRelativeLocation", function() component:K2_SetRelativeLocation({ X = 0, Y = 0, Z = 0 }, false, {}, false) end)
    end
    if component.SetRelativeRotation then
        try_component_call(results, "SetRelativeRotation", function() component:SetRelativeRotation({ Pitch = 0, Yaw = 0, Roll = 0 }) end)
    elseif component.K2_SetRelativeRotation then
        try_component_call(results, "K2_SetRelativeRotation", function() component:K2_SetRelativeRotation({ Pitch = 0, Yaw = 0, Roll = 0 }, false, {}, false) end)
    end
    if component.SetRelativeScale3D then
        try_component_call(results, "SetRelativeScale3D", function() component:SetRelativeScale3D({ X = 1, Y = 1, Z = 1 }) end)
    end
    return true, table.concat(results, " | ")
end

local function register_preview_component(component, preview)
    local results = {}
    if is_valid(preview) and preview.AddInstanceComponent then
        try_component_call(results, "AddInstanceComponent", function() return preview:AddInstanceComponent(component) end)
    end
    if is_valid(preview) and preview.AddOwnedComponent then
        try_component_call(results, "AddOwnedComponent", function() return preview:AddOwnedComponent(component) end)
    end
    if component.OnComponentCreated then
        try_component_call(results, "OnComponentCreated", function() return component:OnComponentCreated() end)
    end
    if component.SetMobility then
        try_component_call(results, "SetMobility(2)", function() return component:SetMobility(2) end)
    end
    if component.SetCollisionEnabled then
        try_component_call(results, "SetCollisionEnabled(0)", function() return component:SetCollisionEnabled(0) end)
    end
    local world = feature_field.resolve_root("world")
    if is_valid(world) and component.RegisterComponentWithWorld then
        try_component_call(results, "RegisterComponentWithWorld", function() return component:RegisterComponentWithWorld(world) end)
    elseif component.RegisterComponent then
        try_component_call(results, "RegisterComponent", function() return component:RegisterComponent() end)
    end
    if component.Activate then
        try_component_call(results, "Activate", function() return component:Activate(true) end)
    end
    refresh_component_renderable(component, false)
    if #results == 0 then return "register=no_api" end
    return table.concat(results, " | ")
end

local function destroy_preview_component_proxy(session)
    local component = session and session.preview_component_created
    if not is_valid(component) then return false, "component invalid" end
    local results = {}
    if component.SetVisibility then
        try_component_call(results, "SetVisibility(false)", function() return component:SetVisibility(false, false) end)
    end
    if component.SetHiddenInGame then
        try_component_call(results, "SetHiddenInGame(true)", function() return component:SetHiddenInGame(true, false) end)
    end
    if component.UnregisterComponent then
        try_component_call(results, "UnregisterComponent", function() return component:UnregisterComponent() end)
    end
    if component.K2_DestroyComponent then
        try_component_call(results, "K2_DestroyComponent", function() return component:K2_DestroyComponent(component) end)
    end
    if component.DestroyComponent then
        local ok = try_component_call(results, "DestroyComponent(false)", function() return component:DestroyComponent(false) end)
        if not ok then
            try_component_call(results, "DestroyComponent()", function() return component:DestroyComponent() end)
        end
    end
    session.preview_component_created = nil
    if #results == 0 then return false, "destroy=no_api" end
    return true, table.concat(results, " | ")
end

local function create_preview_skeletal_component(session, preview)
    if not (StaticConstructObject and FName) then
        return nil, "StaticConstructObject/FName unavailable"
    end
    local cls = resolve_uclass("/Script/Engine.SkeletalMeshComponent")
    if not is_valid(cls) then return nil, "could not resolve /Script/Engine.SkeletalMeshComponent" end
    local name = object_name_for_preview_component(session)
    local component
    print("[RSDWTools.oculus.preview.component] create begin target=" .. tostring(session and session.target_name)
        .. " outer=" .. tostring(safe_short_name(preview))
        .. " name=" .. tostring(name))
    local ok_construct, construct_err = pcall(function()
        component = StaticConstructObject(cls, preview, FName(name))
    end)
    if not ok_construct then return nil, "StaticConstructObject failed: " .. tostring(construct_err) end
    if not is_valid(component) then return nil, "StaticConstructObject returned invalid component" end
    print("[RSDWTools.oculus.preview.component] create ok target=" .. tostring(session and session.target_name)
        .. " component=" .. tostring(safe_short_name(component)))
    return component, name
end

local function apply_preview_component_proxy(session, preview)
    if session.kind ~= "skeletal" then
        return false, "component proxy probe is skeletal-only for now"
    end
    local component, create_detail = create_preview_skeletal_component(session, preview)
    if not is_valid(component) then return false, tostring(create_detail) end

    session.preview_component = component
    session.preview_component_created = component
    session.preview_component_label = "created:" .. tostring(create_detail)
    session.preview_component_snapshot = nil

    local ok_mesh, mesh_route = set_preview_component_mesh(component, "skeletal", session.desc.mesh, session.setter_route)
    if not ok_mesh then
        destroy_preview_component_proxy(session)
        return false, tostring(mesh_route)
    end
    local material_count = apply_proxy_materials(component, session.desc.materials)
    refresh_component_renderable(component, false)

    local ok_attach, attach_detail = attach_component_to_preview_root(component, preview)
    if not ok_attach then
        destroy_preview_component_proxy(session)
        return false, "attach failed: " .. tostring(attach_detail)
    end
    local register_detail = register_preview_component(component, preview)
    local sibling_snapshot, sibling_hidden = hide_preview_component_proxy_host_visuals(preview, component)
    session.preview_sibling_visuals = sibling_snapshot
    session.preview_sibling_hidden = sibling_hidden

    session.mesh_route = mesh_route
    session.material_count = material_count
    session.applied_at = os.clock()
    print(string.format(
        "[RSDWTools.oculus.preview.component] applied target=%s host=%s component=%s mesh=%s route=%s materials=%d hidden_host=%d attach=%s register=%s preview=%s",
        tostring(session.target_name),
        tostring(session.host_piece),
        tostring(session.preview_component_label),
        tostring(session.mesh_name),
        tostring(mesh_route),
        material_count,
        tonumber(sibling_hidden) or 0,
        tostring(attach_detail),
        tostring(register_detail),
        tostring(safe_short_name(preview))))
    return true, string.format("component-proxy target=%s host=%s component=%s mesh=%s route=%s materials=%d hidden_host=%d",
        tostring(session.target_name),
        tostring(session.host_piece),
        tostring(session.preview_component_label),
        tostring(session.mesh_name),
        tostring(mesh_route),
        material_count,
        tonumber(sibling_hidden) or 0)
end

local function apply_preview_swap(session, preview)
    if session and session.strategy == "component_proxy" then
        return apply_preview_component_proxy(session, preview)
    end

    local selected, components, diag = compatible_preview_component(preview, session.kind)
    session.preview_components = components
    session.preview_component_diag = diag
    if not selected or not is_valid(selected.component) then
        return false, "no compatible " .. tostring(session.kind) .. " component on PreviewPiece ; "
            .. preview_inspect_summary(preview, components, diag)
    end

    session.preview_component = selected.component
    session.preview_component_label = selected.label
    session.preview_component_snapshot = snapshot_preview_component(selected.component, session.kind)

    local ok_mesh, mesh_route = set_preview_component_mesh(selected.component, session.kind, session.desc.mesh, session.setter_route)
    if not ok_mesh then return false, tostring(mesh_route) end
    local material_count = apply_proxy_materials(selected.component, session.desc.materials)
    refresh_component_renderable(selected.component, true)
    local sibling_snapshot, sibling_hidden = hide_preview_sibling_visuals(preview, selected.component)
    session.preview_sibling_visuals = sibling_snapshot
    session.preview_sibling_hidden = sibling_hidden

    session.mesh_route = mesh_route
    session.material_count = material_count
    session.applied_at = os.clock()
    print(string.format(
        "[RSDWTools.oculus.preview.swap] applied target=%s kind=%s host=%s component=%s mesh=%s route=%s materials=%d hidden_siblings=%d preview=%s",
        tostring(session.target_name),
        tostring(session.kind),
        tostring(session.host_piece),
        tostring(session.preview_component_label),
        tostring(session.mesh_name),
        tostring(mesh_route),
        material_count,
        tonumber(sibling_hidden) or 0,
        tostring(safe_short_name(preview))))
    return true, string.format("swapped target=%s kind=%s host=%s component=%s mesh=%s route=%s materials=%d hidden_siblings=%d",
        tostring(session.target_name),
        tostring(session.kind),
        tostring(session.host_piece),
        tostring(session.preview_component_label),
        tostring(session.mesh_name),
        tostring(mesh_route),
        material_count,
        tonumber(sibling_hidden) or 0)
end

local function reapply_preview_swap_skeletal_route(session, route)
    if not session then return false, "no active or captured preview swap" end
    if session.kind ~= "skeletal" then return false, "skeletal route probe only applies to skeletal swaps" end
    local normalized = trim(route):lower()
    if normalized == "" then
        return false, "usage: camera.oculus.preview.swap.skelroute <auto|skinned|skinned_false|skeletal|skeletal_raw|asset|asset_true|field_skeletal|field_skinned|clear_then_skeletal|clear_then_skinned>"
    end

    session.setter_route = normalized
    if not is_valid(session.preview_component) then
        return true, "route set for next apply route=" .. tostring(normalized)
    end
    if not session.desc or not is_valid(session.desc.mesh) then
        return false, "missing captured source mesh"
    end

    local before_ok, before = preview_swap_debug_detail(session)
    local ok_mesh, mesh_route = set_preview_component_mesh(session.preview_component, "skeletal", session.desc.mesh, normalized)
    if ok_mesh then
        session.mesh_route = mesh_route
        session.material_count = apply_proxy_materials(session.preview_component, session.desc.materials)
        refresh_component_renderable(session.preview_component, true)
    end
    if session.preview_component.RecreateRenderState_Concurrent then pcall(function() session.preview_component:RecreateRenderState_Concurrent() end) end
    if session.preview_component.MarkRenderStateDirty then pcall(function() session.preview_component:MarkRenderStateDirty() end) end
    if session.preview_component.ForceUpdateBounds then pcall(function() session.preview_component:ForceUpdateBounds() end) end
    if session.preview_component.UpdateBounds then pcall(function() session.preview_component:UpdateBounds() end) end
    local after_ok, after = preview_swap_debug_detail(session)
    local detail = "route=" .. tostring(normalized)
        .. " ok=" .. tostring(ok_mesh)
        .. " mesh_route=" .. tostring(ok_mesh and mesh_route or compact_probe_error(mesh_route))
        .. " materials=" .. tostring(session.material_count or 0)
        .. " before={" .. tostring(before_ok and before or "<failed>") .. "}"
        .. " after={" .. tostring(after_ok and after or "<failed>") .. "}"
    print("[RSDWTools.oculus.preview.swap] skelroute " .. detail)
    return true, detail
end

local preview_swap_arm
local preview_swap_wait_exit_ready
local preview_swap_enter_build
local preview_swap_wait_enter_ready
local preview_swap_select_piece
local preview_swap_wait_preview_ready
local preview_swap_apply
local preview_swap_arm_when_lifecycle_ready

local function resolve_preview_swap_host(session)
    if not session then return false, "no preview swap session" end
    if preview_swap then return false, "preview swap already active" end
    if not is_valid(session.target) then
        return false, "target actor is no longer valid before preview arm"
    end

    session.phase = "resolve_host"
    local host_piece = session.host_piece
    print("[RSDWTools.oculus.preview.swap] resolve host target=" .. tostring(session.target_name)
        .. " host=" .. tostring(host_piece))
    local ok_piece, piece_detail, piece_data = feature_build_preview.resolve_piece_arg(host_piece)
    if not ok_piece then
        local first_detail = piece_detail
        for _, fallback in ipairs(preview_swap_fallbacks_for(session.kind)) do
            local fallback_ok, fallback_detail, fallback_data = feature_build_preview.resolve_piece_arg(fallback)
            if fallback_ok then
                ok_piece = true
                piece_detail = fallback_detail
                piece_data = fallback_data
                host_piece = fallback
                session.host_piece = fallback
                break
            end
            piece_detail = tostring(first_detail) .. " ; fallback " .. tostring(fallback) .. ": " .. tostring(fallback_detail)
        end
    end
    if not ok_piece then
        return false, "could not arm preview host '" .. tostring(host_piece) .. "': " .. tostring(piece_detail)
    end
    session.piece_detail = piece_detail
    session.piece_data = piece_data
    session.phase = "host_resolved"
    return true, tostring(piece_detail)
end

local function arm_preview_swap_session(session)
    local ok_resolve, resolve_detail = resolve_preview_swap_host(session)
    if not ok_resolve then return false, resolve_detail end

    session.phase = "exit_before_build"
    local exit_ok, exit_detail = feature_build_preview.exit_any_mode()
    if not exit_ok then return false, tostring(exit_detail) end
    session.exit_detail = exit_detail
    session.phase = "exit_requested"
    return true, tostring(resolve_detail) .. "; " .. tostring(exit_detail)
end

preview_swap_arm = function(token)
    local session = preview_swap_starting
    if not session or session.token ~= token then return end
    print("[RSDWTools.oculus.preview.swap] arm begin target=" .. tostring(session.target_name)
        .. " phase=" .. tostring(session.phase or "queued"))
    if preview_swap then
        preview_swap_starting = nil
        mark_preview_swap_settle("already_active")
        return
    end
    local ok_arm, arm_detail = arm_preview_swap_session(session)
    if not ok_arm then return fail_preview_swap_start(session, arm_detail) end
    print("[RSDWTools.oculus.preview.swap] wait exit ready target=" .. tostring(session.target_name)
        .. " poll_ms=" .. tostring(PREVIEW_SWAP_POLL_MS)
        .. " ; " .. tostring(arm_detail))
    session.phase = "exit_ready_wait"
    session.exit_ready_attempts = 0
    schedule_ms(PREVIEW_SWAP_POLL_MS, function() preview_swap_wait_exit_ready(token) end)
end

preview_swap_arm_when_lifecycle_ready = function(token)
    local session = preview_swap_starting
    if not session or session.token ~= token then return end
    if preview_swap_lifecycle_busy then
        session.phase = "lifecycle_wait"
        if session.lifecycle_wait_logged ~= true then
            session.lifecycle_wait_logged = true
            print("[RSDWTools.oculus.preview.swap] lifecycle wait target=" .. tostring(session.target_name)
                .. " reason=" .. tostring(preview_swap_lifecycle_reason or "busy")
                .. " poll_ms=" .. tostring(PREVIEW_SWAP_LIFECYCLE_POLL_MS))
        end
        schedule_ms(PREVIEW_SWAP_LIFECYCLE_POLL_MS, function()
            preview_swap_arm_when_lifecycle_ready(token)
        end)
        return
    end
    return preview_swap_arm(token)
end

preview_swap_wait_exit_ready = function(token)
    local session = preview_swap_starting
    if not session or session.token ~= token then return end
    if preview_swap then
        preview_swap_starting = nil
        return
    end

    session.exit_ready_attempts = (session.exit_ready_attempts or 0) + 1
    local ok_mode, info = feature_build_preview.current_mode_info()
    local preview_valid = ok_mode and is_valid(info.preview)
    local mode_id = ok_mode and info.mode_id or nil
    -- ExitAnyMode clears Placement/PreviewPiece, but Oculus Repair mode can
    -- legitimately remain active. That is still a clean state for
    -- ForceEnterBuildMode; requiring mode_id=0 caused grab to fail safely but
    -- never reach the mannequin preview from normal Repair mode.
    if ok_mode and not preview_valid and (mode_id == 0 or mode_id == 3) then
        print("[RSDWTools.oculus.preview.swap] exit ready target=" .. tostring(session.target_name)
            .. " mode=" .. tostring(info.mode))
        return preview_swap_enter_build(token)
    end

    if ok_mode and not preview_valid and mode_id == 1 then
        print("[RSDWTools.oculus.preview.swap] selection already ready target=" .. tostring(session.target_name)
            .. " mode=" .. tostring(info.mode))
        return preview_swap_select_piece(token)
    end

    if session.exit_ready_attempts >= PREVIEW_SWAP_EXIT_READY_MAX_ATTEMPTS then
        return fail_preview_swap_start(session, "timed out waiting for build mode exit"
            .. " mode=" .. tostring(ok_mode and info.mode or info)
            .. " mode_id=" .. tostring(mode_id or "?")
            .. " preview=" .. tostring(preview_valid))
    end

    session.phase = "exit_ready_wait"
    schedule_ms(PREVIEW_SWAP_POLL_MS, function() preview_swap_wait_exit_ready(token) end)
end

preview_swap_enter_build = function(token)
    local session = preview_swap_starting
    if not session or session.token ~= token then return end
    if preview_swap then
        preview_swap_starting = nil
        return
    end

    session.phase = "enter_build"
    local ok_enter, enter_detail, bmc = feature_build_preview.force_enter_build_mode()
    if not ok_enter then return fail_preview_swap_start(session, enter_detail) end
    session.bmc = bmc
    session.enter_detail = enter_detail
    print("[RSDWTools.oculus.preview.swap] wait enter ready target=" .. tostring(session.target_name)
        .. " poll_ms=" .. tostring(PREVIEW_SWAP_POLL_MS)
        .. " ; " .. tostring(enter_detail))
    session.phase = "enter_ready_wait"
    session.enter_ready_attempts = 0
    schedule_ms(PREVIEW_SWAP_POLL_MS, function() preview_swap_wait_enter_ready(token) end)
end

preview_swap_wait_enter_ready = function(token)
    local session = preview_swap_starting
    if not session or session.token ~= token then return end
    if preview_swap then
        preview_swap_starting = nil
        return
    end

    session.enter_ready_attempts = (session.enter_ready_attempts or 0) + 1
    local ok_mode, info = feature_build_preview.current_mode_info()
    local mode_id = ok_mode and info.mode_id or nil
    if ok_mode and mode_id == 1 then
        print("[RSDWTools.oculus.preview.swap] enter ready target=" .. tostring(session.target_name)
            .. " mode=" .. tostring(info.mode))
        return preview_swap_select_piece(token)
    end

    if session.enter_ready_attempts >= PREVIEW_SWAP_ENTER_READY_MAX_ATTEMPTS then
        return fail_preview_swap_start(session, "timed out waiting for build selection mode"
            .. " mode=" .. tostring(ok_mode and info.mode or info)
            .. " mode_id=" .. tostring(mode_id or "?"))
    end

    session.phase = "enter_ready_wait"
    schedule_ms(PREVIEW_SWAP_POLL_MS, function() preview_swap_wait_enter_ready(token) end)
end

preview_swap_select_piece = function(token)
    local session = preview_swap_starting
    if not session or session.token ~= token then return end
    if preview_swap then
        preview_swap_starting = nil
        return
    end

    session.phase = "select_piece"
    local ok_select, select_detail, preview, bmc = feature_build_preview.select_piece_data(session.piece_data)
    if not ok_select then return fail_preview_swap_start(session, select_detail) end
    session.preview = preview
    session.bmc = bmc
    session.select_detail = select_detail
    print("[RSDWTools.oculus.preview.swap] wait preview ready target=" .. tostring(session.target_name)
        .. " poll_ms=" .. tostring(PREVIEW_SWAP_POLL_MS)
        .. " ; " .. tostring(select_detail))
    session.phase = "preview_ready_wait"
    session.preview_ready_attempts = 0
    schedule_ms(PREVIEW_SWAP_POLL_MS, function() preview_swap_wait_preview_ready(token) end)
end

preview_swap_wait_preview_ready = function(token)
    local session = preview_swap_starting
    if not session or session.token ~= token then return end
    if preview_swap then
        preview_swap_starting = nil
        return
    end

    session.preview_ready_attempts = (session.preview_ready_attempts or 0) + 1
    local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if is_valid(preview) then
        session.preview = preview
        session.bmc = bmc
        if session.strategy == "component_proxy" then
            print("[RSDWTools.oculus.preview.component] preview ready target=" .. tostring(session.target_name)
                .. " preview=" .. tostring(safe_short_name(preview))
                .. " component=create:SkeletalMeshComponent")
            return preview_swap_apply(token)
        end
        local selected = compatible_preview_component(preview, session.kind)
        if selected and is_valid(selected.component) then
            print("[RSDWTools.oculus.preview.swap] preview ready target=" .. tostring(session.target_name)
                .. " preview=" .. tostring(safe_short_name(preview))
                .. " component=" .. tostring(selected.label))
            return preview_swap_apply(token)
        end
    end

    if session.preview_ready_attempts >= PREVIEW_SWAP_PREVIEW_READY_MAX_ATTEMPTS then
        return fail_preview_swap_start(session, "timed out waiting for compatible PreviewPiece"
            .. " preview=" .. tostring(is_valid(preview) and safe_short_name(preview) or preview_err)
            .. " kind=" .. tostring(session.kind))
    end

    session.phase = "preview_ready_wait"
    schedule_ms(PREVIEW_SWAP_POLL_MS, function() preview_swap_wait_preview_ready(token) end)
end

preview_swap_apply = function(token)
    local session = preview_swap_starting
    if not session or session.token ~= token then return end
    if preview_swap then
        preview_swap_starting = nil
        return
    end

    session.phase = "apply_preview"
    local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then
        session.bmc = bmc
        session.apply_attempts = (session.apply_attempts or 0) + 1
        if session.apply_attempts < PREVIEW_SWAP_APPLY_MAX_ATTEMPTS then
            session.phase = "apply_wait_preview"
            schedule_frames(PREVIEW_SWAP_APPLY_RETRY_FRAMES, function() preview_swap_apply(token) end)
            return
        end
        return fail_preview_swap_start(session, tostring(preview_err or "PreviewPiece missing after arming host"))
    end
    session.preview = preview
    session.bmc = bmc

    local ok, detail = apply_preview_swap(session, preview)
    if not ok then
        session.apply_attempts = (session.apply_attempts or 0) + 1
        if session.apply_attempts < PREVIEW_SWAP_APPLY_MAX_ATTEMPTS then
            session.phase = "apply_wait_component"
            schedule_frames(PREVIEW_SWAP_APPLY_RETRY_FRAMES, function() preview_swap_apply(token) end)
            return
        end
        return fail_preview_swap_start(session, detail)
    end

    session.target_hidden_for_preview = set_actor_hidden(session.target, true)

    preview_swap_starting = nil
    preview_swap = session
    session.phase = "active"
    release_preview_swap_guard(session, "preview.swap.active")
    pcall(function() feature_umg.toast("Preview Swap: " .. tostring(session.target_name), 1.3) end)
end

local function preview_swap_current_transform(session)
    local xform, err = current_preview_transform(session)
    if xform then return xform, "preview_actor" end
    return nil, err
end

local function preview_swap_corrected_component_transform(session)
    if not session then return nil, "no active preview swap" end

    local target_root, target_root_err = actor_world_transform(session.target)
    if not target_root then
        return nil, "could not read target actor root: " .. tostring(target_root_err)
    end

    local source_component = session.desc and session.desc.component
    if not is_valid(source_component) then
        return nil, "source mesh component is invalid"
    end
    local source_component_xform, source_component_err = component_world_transform(source_component)
    if not source_component_xform then
        return nil, "could not read source mesh component: " .. tostring(source_component_err)
    end

    local preview_component = session.preview_component
    if not is_valid(preview_component) then
        return nil, "preview mesh component is invalid"
    end
    local preview_component_xform, preview_component_err = component_world_transform(preview_component)
    if not preview_component_xform then
        return nil, "could not read preview mesh component: " .. tostring(preview_component_err)
    end

    local root_from_source_mesh_loc = vec_sub(target_root.loc, source_component_xform.loc)
    local root_from_source_mesh_rot = rot_sub(target_root.rot, source_component_xform.rot)
    return {
        loc = vec_add(preview_component_xform.loc, root_from_source_mesh_loc),
        rot = rot_add(preview_component_xform.rot, root_from_source_mesh_rot),
        scale = copy_scale(target_root.scale),
    }, "preview_component_corrected"
end

local function preview_swap_confirm_transform(session)
    local corrected, corrected_err = preview_swap_corrected_component_transform(session)
    if corrected then return corrected, "preview_component_corrected" end

    local xform, source = preview_swap_current_transform(session)
    if xform then
        return xform, tostring(source) .. " fallback_after=" .. tostring(corrected_err)
    end
    return nil, tostring(source or corrected_err)
end

local function fmt_vec3(value)
    value = value or {}
    return string.format("(%.2f,%.2f,%.2f)", value.X or 0, value.Y or 0, value.Z or 0)
end

local function fmt_rot3(value)
    value = value or {}
    return string.format("(P%.2f,Y%.2f,R%.2f)", value.Pitch or 0, value.Yaw or 0, value.Roll or 0)
end

local function fmt_xform(value)
    if not value then return "<missing>" end
    return "loc=" .. fmt_vec3(value.loc) .. " rot=" .. fmt_rot3(value.rot) .. " scale=" .. fmt_vec3(value.scale)
end

local function preview_swap_xform_detail(session)
    if not session then return false, "no active preview swap" end
    local target_root, target_root_err = actor_world_transform(session.target)
    local source_component = session.desc and session.desc.component
    local source_component_xform, source_component_err = nil, "no source component"
    if is_valid(source_component) then
        source_component_xform, source_component_err = component_world_transform(source_component)
    end
    local preview_actor_xform, preview_actor_source = preview_swap_current_transform(session)
    local preview_component_xform, preview_component_err = nil, "no preview component"
    if is_valid(session.preview_component) then
        preview_component_xform, preview_component_err = component_world_transform(session.preview_component)
    end

    local root_from_source_mesh_loc = nil
    local root_from_source_mesh_rot = nil
    if target_root and source_component_xform then
        root_from_source_mesh_loc = vec_sub(target_root.loc, source_component_xform.loc)
        root_from_source_mesh_rot = rot_sub(target_root.rot, source_component_xform.rot)
    end

    local preview_root_from_component_loc = nil
    local preview_root_from_component_rot = nil
    if preview_actor_xform and preview_component_xform then
        preview_root_from_component_loc = vec_sub(preview_actor_xform.loc, preview_component_xform.loc)
        preview_root_from_component_rot = rot_sub(preview_actor_xform.rot, preview_component_xform.rot)
    end

    local corrected = nil
    if preview_component_xform and root_from_source_mesh_loc and root_from_source_mesh_rot then
        corrected = {
            loc = vec_add(preview_component_xform.loc, root_from_source_mesh_loc),
            rot = rot_add(preview_component_xform.rot, root_from_source_mesh_rot),
            scale = copy_scale(target_root and target_root.scale),
        }
    end

    local current_delta = nil
    if preview_actor_xform and corrected then
        current_delta = {
            loc = vec_sub(corrected.loc, preview_actor_xform.loc),
            rot = rot_sub(corrected.rot, preview_actor_xform.rot),
        }
    end
    local confirm_xform, confirm_source = preview_swap_confirm_transform(session)

    local parts = {
        "target=" .. tostring(session.target_name),
        "host=" .. tostring(session.host_piece),
        "component=" .. tostring(session.preview_component_label),
        "target_root{" .. fmt_xform(target_root) .. (target_root and "" or (" err=" .. tostring(target_root_err))) .. "}",
        "source_component{" .. fmt_xform(source_component_xform) .. (source_component_xform and "" or (" err=" .. tostring(source_component_err))) .. "}",
        "preview_actor{" .. fmt_xform(preview_actor_xform) .. (preview_actor_xform and (" source=" .. tostring(preview_actor_source)) or (" err=" .. tostring(preview_actor_source))) .. "}",
        "preview_component{" .. fmt_xform(preview_component_xform) .. (preview_component_xform and "" or (" err=" .. tostring(preview_component_err))) .. "}",
        "root_from_source_mesh loc=" .. fmt_vec3(root_from_source_mesh_loc) .. " rot=" .. fmt_rot3(root_from_source_mesh_rot),
        "preview_root_from_component loc=" .. fmt_vec3(preview_root_from_component_loc) .. " rot=" .. fmt_rot3(preview_root_from_component_rot),
        "current_confirm{" .. fmt_xform(preview_actor_xform) .. "}",
        "corrected_from_component{" .. fmt_xform(corrected) .. "}",
        "next_confirm{" .. fmt_xform(confirm_xform) .. " source=" .. tostring(confirm_source) .. "}",
    }
    if current_delta then
        parts[#parts + 1] = "delta_corrected_minus_current loc=" .. fmt_vec3(current_delta.loc)
            .. " rot=" .. fmt_rot3(current_delta.rot)
    end
    local detail = table.concat(parts, " ; ")
    print("[RSDWTools.oculus.preview.swap] xform " .. detail)
    return true, detail
end

local function cleanup_preview_swap(session, exit_preview)
    if not session then return end
    destroy_preview_component_proxy(session)
    if exit_preview == false then
        restore_component_visuals(session.preview_sibling_visuals)
    end
    release_preview_swap_guard(session, "preview.swap.cleanup")
    if exit_preview ~= false then exit_build_preview(session) end
end

local function schedule_post_confirm_exit(bmc, reason)
    schedule_ms(PREVIEW_SWAP_POST_CONFIRM_EXIT_MS, function()
        local ok = false
        if is_valid(bmc) and bmc.ExitAnyMode then
            local ok1 = pcall(function() bmc:ExitAnyMode() end)
            local ok2 = pcall(function() bmc:ExitAnyMode() end)
            ok = ok1 or ok2
        else
            local exit_ok = feature_build_preview.exit_any_mode()
            ok = exit_ok == true
        end
        print("[RSDWTools.oculus.preview.swap] post-confirm exit "
            .. tostring(reason or "preview.swap.confirm")
            .. " ok=" .. tostring(ok))
    end)
end

local function preview_swap_status_detail()
    if preview_swap_starting then
        return true, string.format("starting phase=%s target=%s kind=%s host=%s",
            tostring(preview_swap_starting.phase or "queued"),
            tostring(preview_swap_starting.target_name),
            tostring(preview_swap_starting.kind),
            tostring(preview_swap_starting.host_piece))
    end
    if preview_swap_lifecycle_busy then
        return true, "settling lifecycle=busy reason=" .. tostring(preview_swap_lifecycle_reason or "preview.swap")
    end
    if not preview_swap then return true, "inactive" end
    local session = preview_swap
    local preview_valid = is_valid(session.preview)
    local target_valid = is_valid(session.target)
    local component_valid = is_valid(session.preview_component)
    local xform = nil
    if preview_valid then xform = actor_world_transform(session.preview) end
    local loc = xform and xform.loc or {}
    local rot = xform and xform.rot or {}
    return true, string.format(
        "active target=%s kind=%s host=%s preview_valid=%s target_valid=%s component_valid=%s component=%s mesh=%s loc=(%.1f,%.1f,%.1f) rot=(P%.1f,Y%.1f,R%.1f)",
        tostring(session.target_name),
        tostring(session.kind),
        tostring(session.host_piece),
        tostring(preview_valid),
        tostring(target_valid),
        tostring(component_valid),
        tostring(session.preview_component_label),
        tostring(session.mesh_name),
        loc.X or 0,
        loc.Y or 0,
        loc.Z or 0,
        rot.Pitch or 0,
        rot.Yaw or 0,
        rot.Roll or 0)
end

local function component_anim_class(component)
    if not is_valid(component) then return nil end
    local anim = nil
    if component.GetAnimClass then
        pcall(function() anim = component:GetAnimClass() end)
    end
    if not is_valid(anim) then
        anim = read_field(component, "AnimClass")
    end
    if not is_valid(anim) then
        anim = read_field(component, "AnimBlueprintGeneratedClass")
    end
    return is_valid(anim) and anim or nil
end

local function set_component_anim_class(component, anim_class)
    if not is_valid(component) then return "anim=component_missing" end
    if not is_valid(anim_class) then return "anim=no_source" end
    if not component.SetAnimInstanceClass then return "anim=setter_missing" end
    local ok, err = pcall(function() component:SetAnimInstanceClass(anim_class) end)
    if ok then return "anim=set:" .. tostring(safe_short_name(anim_class)) end
    return "anim=failed:" .. tostring(err)
end

local function anim_probe_attempt(results, label, fn)
    local ok, err = pcall(fn)
    results[#results + 1] = tostring(label) .. "=" .. tostring(ok and "ok" or compact_probe_error(err))
    return ok
end

local function set_animation_mode_probe(component, mode, results)
    if component.SetAnimationMode then
        local label = "SetAnimationMode(" .. tostring(mode) .. ",true)"
        local ok = anim_probe_attempt(results, label, function() component:SetAnimationMode(mode, true) end)
        if not ok then
            anim_probe_attempt(results, "SetAnimationMode(" .. tostring(mode) .. ",false)", function()
                component:SetAnimationMode(mode, false)
            end)
        end
    end
    if read_field(component, "AnimationMode") ~= nil then
        anim_probe_attempt(results, "AnimationMode=" .. tostring(mode), function()
            component.AnimationMode = mode
        end)
    end
end

local function preview_swap_anim_probe(session, mode)
    if not session then return false, "no active preview swap" end
    if session.kind ~= "skeletal" then return false, "animation probe is skeletal-only" end
    local component = session.preview_component
    if not is_valid(component) then return false, "preview component invalid" end

    mode = trim(mode):lower()
    if mode == "" then mode = "status" end
    if mode == "status" then
        return preview_swap_debug_detail(session)
    end

    local before_ok, before = preview_swap_debug_detail(session)
    local results = {}

    if mode == "clear" or mode == "none" or mode == "single" then
        set_animation_mode_probe(component, 1, results)
        if component.SetAnimInstanceClass then
            anim_probe_attempt(results, "SetAnimInstanceClass(nil)", function() component:SetAnimInstanceClass(nil) end)
        end
        for _, field_name in ipairs({ "AnimClass", "AnimBlueprintGeneratedClass", "AnimScriptInstance" }) do
            if read_field(component, field_name) ~= nil then
                anim_probe_attempt(results, field_name .. "=nil", function() component[field_name] = nil end)
            end
        end
    elseif mode == "copy" or mode == "source" then
        set_animation_mode_probe(component, 0, results)
        results[#results + 1] = set_component_anim_class(component, component_anim_class(session.desc and session.desc.component))
    elseif mode == "blueprint" or mode == "mode0" then
        set_animation_mode_probe(component, 0, results)
    elseif mode == "mode1" or mode == "singlemode" then
        set_animation_mode_probe(component, 1, results)
    elseif mode == "mode2" or mode == "custom" then
        set_animation_mode_probe(component, 2, results)
    elseif mode == "tickon" then
        if component.SetComponentTickEnabled then
            anim_probe_attempt(results, "SetComponentTickEnabled(true)", function() component:SetComponentTickEnabled(true) end)
        end
    elseif mode == "tickoff" then
        if component.SetComponentTickEnabled then
            anim_probe_attempt(results, "SetComponentTickEnabled(false)", function() component:SetComponentTickEnabled(false) end)
        end
    elseif mode == "pauseon" then
        if component.SetPauseAnims then
            anim_probe_attempt(results, "SetPauseAnims(true)", function() component:SetPauseAnims(true) end)
        end
        if read_field(component, "bPauseAnims") ~= nil then
            anim_probe_attempt(results, "bPauseAnims=true", function() component.bPauseAnims = true end)
        end
    elseif mode == "pauseoff" then
        if component.SetPauseAnims then
            anim_probe_attempt(results, "SetPauseAnims(false)", function() component:SetPauseAnims(false) end)
        end
        if read_field(component, "bPauseAnims") ~= nil then
            anim_probe_attempt(results, "bPauseAnims=false", function() component.bPauseAnims = false end)
        end
    elseif mode == "refresh" or mode == "pose" then
        if component.InitAnim then
            anim_probe_attempt(results, "InitAnim", function() component:InitAnim(true) end)
        end
        if component.RefreshBoneTransforms then
            anim_probe_attempt(results, "RefreshBoneTransforms", function() component:RefreshBoneTransforms() end)
        end
        if component.RefreshSlaveComponents then
            anim_probe_attempt(results, "RefreshSlaveComponents", function() component:RefreshSlaveComponents() end)
        end
        if component.FinalizeBoneTransform then
            anim_probe_attempt(results, "FinalizeBoneTransform", function() component:FinalizeBoneTransform() end)
        end
        if component.TickAnimation then
            anim_probe_attempt(results, "TickAnimation", function() component:TickAnimation(0.016, false) end)
        end
    else
        return false, "usage: camera.oculus.preview.swap.anim <status|clear|copy|blueprint|mode1|mode2|tickon|tickoff|pauseon|pauseoff|refresh>"
    end

    if component.MarkRenderDynamicDataDirty then pcall(function() component:MarkRenderDynamicDataDirty() end) end
    if component.MarkRenderStateDirty then pcall(function() component:MarkRenderStateDirty() end) end
    if component.ForceUpdateBounds then pcall(function() component:ForceUpdateBounds() end) end
    if component.UpdateBounds then pcall(function() component:UpdateBounds() end) end
    refresh_component_renderable(component, true)

    local after_ok, after = preview_swap_debug_detail(session)
    local detail = "mode=" .. tostring(mode)
        .. " results=" .. (#results > 0 and table.concat(results, ",") or "no_api")
        .. " before={" .. tostring(before_ok and before or "<failed>") .. "}"
        .. " after={" .. tostring(after_ok and after or "<failed>") .. "}"
    print("[RSDWTools.oculus.preview.swap] anim " .. detail)
    return true, detail
end

local function component_debug_summary(label, component, kind)
    if not is_valid(component) then return tostring(label) .. "=missing" end
    local mesh = component_mesh_asset(component, kind)
    return tostring(label) .. "(" .. table.concat({
        "name=" .. tostring(safe_short_name(component)),
        "class=" .. tostring(class_name(component)),
        "mesh=" .. tostring(is_valid(mesh) and safe_short_name(mesh) or "<none>"),
        anim_class_summary(component),
        material_summary(component, 8),
        material_section_summary(component),
        hidden_bone_summary(component),
        render_flag_summary(component),
    }, ";") .. ")"
end

preview_swap_debug_detail = function(session)
    if not session then return false, "no active preview swap" end
    local parts = {
        "target=" .. tostring(session.target_name),
        "kind=" .. tostring(session.kind),
        "host=" .. tostring(session.host_piece),
        "route=" .. tostring(session.mesh_route or "<none>"),
        component_debug_summary("source", session.desc and session.desc.component, session.kind),
        component_debug_summary("preview", session.preview_component, session.kind),
    }
    return true, table.concat(parts, " ; ")
end

local function cleanup_preview_swap_component(session, mode)
    if not session then return false, "no active preview swap" end
    if session.kind ~= "skeletal" then return false, "cleanup probe is skeletal-only for now" end
    local component = session.preview_component
    if not is_valid(component) then return false, "preview component invalid" end
    mode = trim(mode):lower()
    if mode == "" then mode = "basic" end
    if mode ~= "basic" and mode ~= "anim" and mode ~= "full" then
        return false, "usage: camera.oculus.preview.swap.cleanup [basic|anim]"
    end

    local before_ok, before = preview_swap_debug_detail(session)
    local results = {
        show_all_material_sections(component),
        unhide_all_bones(component),
        clear_hide_skin(component),
        "render=" .. tostring(refresh_component_renderable(component, true)),
    }
    if mode == "anim" or mode == "full" then
        results[#results + 1] = set_component_anim_class(component, component_anim_class(session.desc and session.desc.component))
    end
    if component.RecreateRenderState_Concurrent then pcall(function() component:RecreateRenderState_Concurrent() end) end
    if component.MarkRenderStateDirty then pcall(function() component:MarkRenderStateDirty() end) end
    if component.ForceUpdateBounds then pcall(function() component:ForceUpdateBounds() end) end
    if component.UpdateBounds then pcall(function() component:UpdateBounds() end) end
    local after_ok, after = preview_swap_debug_detail(session)
    local detail = "mode=" .. tostring(mode)
        .. " results=" .. table.concat(results, ",")
        .. " before={" .. tostring(before_ok and before or "<failed>") .. "}"
        .. " after={" .. tostring(after_ok and after or "<failed>") .. "}"
    print("[RSDWTools.oculus.preview.swap] cleanup " .. detail)
    return true, detail
end

function M.clear()
    if attachgrab_flow.starting then
        local pending = attachgrab_flow.starting
        attachgrab_flow.starting = nil
        pending.cancelled = true
        attachgrab_flow.cleanup(pending, true)
    end
    if attachgrab then
        local session = attachgrab
        attachgrab = nil
        attachgrab_flow.cleanup(session, true)
    end
    if placement_starting then
        local pending = placement_starting
        placement_starting = nil
        pending.cancelled = true
        destroy_proxy_entry(pending.proxy_entry)
        exit_build_preview(pending)
    end
    if placement then
        local session = placement
        placement = nil
        restore_target_visibility(session)
        cleanup_placement(session, true)
    end
    if preview_swap_starting then
        local session = preview_swap_starting
        preview_swap_starting = nil
        cleanup_preview_swap(session, true)
    end
    if preview_swap then
        local session = preview_swap
        preview_swap = nil
        cleanup_preview_swap(session, true)
    end
    local destroyed = 0
    local skipped = 0
    for i = #proxies, 1, -1 do
        local entry = proxies[i]
        if entry and is_valid(entry.actor) and destroy_actor(entry.actor) then
            destroyed = destroyed + 1
        else
            skipped = skipped + 1
        end
        table.remove(proxies, i)
    end
    return true, string.format("cleared detached proxies destroyed=%d skipped=%d", destroyed, skipped)
end

function M.spawn()
    local actor, _loc, source, err = feature_grab.pick_target_under_reticle()
    if not is_valid(actor) then return false, tostring(err or "no actor under reticle") end

    local entry, spawn_err = spawn_proxy_for_actor(actor, nil, source)
    if not entry then return false, spawn_err end
    pcall(function() feature_umg.toast("Proxy: " .. tostring(entry.target_name), 1.5) end)

    return true, string.format(
        "proxy=%s kind=%s target=%s mesh=%s src_comp=%s proxy_comp=%s materials=%d active=%d",
        entry.proxy_name,
        tostring(entry.kind),
        entry.target_name,
        entry.mesh_name,
        tostring(entry.source_component_label),
        tostring(entry.component_label),
        entry.material_count or 0,
        #proxies)
end

function M.target_mesh_inspect()
    local actor, actor_name, source = nil, nil, nil
    if attachgrab and is_valid(attachgrab.target) then
        actor = attachgrab.target
        actor_name = attachgrab.target_name
        source = "attachgrab"
    elseif attachgrab_flow.starting and is_valid(attachgrab_flow.starting.target) then
        actor = attachgrab_flow.starting.target
        actor_name = attachgrab_flow.starting.target_name
        source = "attachgrab.starting"
    else
        local picked, _loc, picked_source, err = feature_grab.pick_target_under_reticle()
        if not is_valid(picked) then return false, tostring(err or "no actor under reticle") end
        actor = picked
        actor_name = safe_short_name(actor)
        source = picked_source or "trace"
    end
    local ok, detail = M._probe_target_mesh_component_summary(actor, source)
    if ok then
        print("[RSDWTools.oculus.proxy.target.inspect] " .. tostring(detail))
        return true, detail
    end
    return false, tostring(detail or ("could not inspect " .. tostring(actor_name or "<target>")))
end

function M.proxy_inspect()
    local entry = latest_live_proxy_entry()
    if not entry or not is_valid(entry.actor) then
        return false, "no live detached proxy ; start attachgrab or run camera.oculus.proxy.spawn first"
    end
    local ok_proxy, proxy_detail = M._probe_target_mesh_component_summary(entry.actor, "proxy")
    local target_detail = "<target unavailable>"
    if is_valid(entry.target) then
        local ok_target, detail = M._probe_target_mesh_component_summary(entry.target, "proxy.target")
        target_detail = ok_target and detail or ("<target inspect failed: " .. tostring(detail) .. ">")
    end
    local entry_detail = string.format(
        "entry target=%s proxy=%s kind=%s src_comp=%s proxy_comp=%s mesh=%s mats=%s visual_scale=%s proxy_render=%s",
        tostring(entry.target_name or "<target>"),
        tostring(entry.proxy_name or "<proxy>"),
        tostring(entry.kind or "<kind>"),
        tostring(entry.source_component_label or "<src>"),
        tostring(entry.component_label or "<component>"),
        tostring(entry.mesh_name or "<mesh>"),
        tostring(entry.material_count or "<mats>"),
        M._probe_vector_summary(entry.visual_scale),
        render_flag_summary(entry.component))
    local detail = entry_detail
        .. " ; proxy{" .. tostring(ok_proxy and proxy_detail or ("inspect failed: " .. tostring(proxy_detail))) .. "}"
        .. " ; source{" .. tostring(target_detail) .. "}"
    print("[RSDWTools.oculus.proxy.inspect] " .. tostring(detail))
    return ok_proxy == true, detail
end

function M.proxy_static_mesh_probe()
    local entry = latest_live_proxy_entry()
    if not entry or not is_valid(entry.actor) then
        return false, "no live detached proxy ; start attachgrab or run camera.oculus.proxy.spawn first"
    end
    if entry.kind ~= "static" then
        return false, "latest proxy is not static kind=" .. tostring(entry.kind or "<kind>")
    end
    local component = entry.component
    if not is_valid(component) then return false, "proxy component invalid" end
    local mesh = entry.mesh
    if not is_valid(mesh) then return false, "entry mesh invalid" end

    local results = {}
    local function mesh_state(label)
        local current, route = get_static_mesh(component)
        results[#results + 1] = tostring(label)
            .. ":mesh=" .. tostring(is_valid(current) and safe_short_name(current) or "<none>")
            .. ",route=" .. tostring(route)
            .. ",mats=" .. tostring(component_material_count(component))
            .. "," .. tostring(render_flag_summary(component))
            .. "," .. tostring(M._probe_component_bounds_summary(component))
    end
    local function attempt(label, fn)
        local ok, value = pcall(fn)
        results[#results + 1] = tostring(label) .. "=" .. tostring(ok and ("ok:" .. tostring(value)) or ("err:" .. compact_probe_error(value)))
        mesh_state(label .. ".after")
        return ok, value
    end

    results[#results + 1] = "target_mesh=" .. tostring(safe_short_name(mesh))
        .. ",proxy=" .. tostring(entry.proxy_name)
        .. ",component=" .. tostring(entry.component_label)
        .. ",has_SetStaticMesh=" .. tostring(component.SetStaticMesh ~= nil)
        .. ",has_OnRep_StaticMesh=" .. tostring(component.OnRep_StaticMesh ~= nil)
    mesh_state("before")

    if component.SetStaticMesh then
        attempt("SetStaticMesh", function() return component:SetStaticMesh(mesh) end)
    else
        results[#results + 1] = "SetStaticMesh=missing"
    end

    attempt("StaticMesh_field", function()
        component.StaticMesh = mesh
        return true
    end)

    if component.OnRep_StaticMesh then
        attempt("OnRep_StaticMesh(nil)", function() return component:OnRep_StaticMesh(nil) end)
    else
        results[#results + 1] = "OnRep_StaticMesh=missing"
    end

    if component.ReregisterComponent then
        attempt("ReregisterComponent", function() return component:ReregisterComponent() end)
    else
        results[#results + 1] = "ReregisterComponent=missing"
    end

    make_proxy_renderable(entry.actor, component)
    mesh_state("after_render_refresh")
    local applied = apply_proxy_materials(component, entry.source_component and get_materials(entry.source_component) or {})
    results[#results + 1] = "apply_source_materials=" .. tostring(applied)
    mesh_state("final")

    local detail = table.concat(results, " ; ")
    print("[RSDWTools.oculus.proxy.staticmesh.probe] " .. tostring(detail))
    return true, detail
end

function M.sync_preview()
    local entry = latest_live_proxy_entry()
    if not entry or not is_valid(entry.actor) then
        return false, "no live detached proxy ; run camera.oculus.proxy.spawn first"
    end
    local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then
        return false, tostring(preview_err or "no active PreviewPiece ; run build.preview.piece first")
    end
    local session = {
        proxy_entry = entry,
        preview = preview,
        bmc = bmc,
        target_name = entry.target_name,
        phase = "manual_sync_preview",
    }
    local synced, sync_detail = sync_proxy_to_preview_once(session)
    if not synced then return false, tostring(sync_detail) end
    make_proxy_renderable(entry.actor, entry.component)
    return true, "synced proxy=" .. tostring(entry.proxy_name)
        .. " preview=" .. tostring(safe_short_name(preview))
        .. " " .. attachment_summary(entry.actor)
end

function M.attach_preview(args_str)
    local entry = latest_live_proxy_entry()
    if not entry or not is_valid(entry.actor) then
        return false, "no live detached proxy ; run camera.oculus.proxy.spawn first"
    end
    local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then
        return false, tostring(preview_err or "no active PreviewPiece ; run build.preview.piece first")
    end

    local arg = trim(args_str):lower()
    local do_sync = not (arg == "nosync" or arg == "--nosync" or arg == "raw")
    local sync_detail = "sync=skipped"
    if do_sync then
        local session = {
            proxy_entry = entry,
            preview = preview,
            bmc = bmc,
            target_name = entry.target_name,
            phase = "manual_attach_preview",
        }
        local synced, detail = sync_proxy_to_preview_once(session)
        if not synced then return false, "sync before attach failed: " .. tostring(detail) end
        sync_detail = "sync=ok"
    end

    local attached, attach_detail = attach_proxy_to_preview(entry, preview)
    if not attached then return false, tostring(attach_detail) end
    make_proxy_renderable(entry.actor, entry.component)
    return true, sync_detail
        .. " attach=" .. tostring(attach_detail)
        .. " proxy=" .. tostring(entry.proxy_name)
        .. " preview=" .. tostring(safe_short_name(preview))
        .. " proxy_" .. attachment_summary(entry.actor)
        .. " preview_" .. attachment_summary(preview)
end

function M.preview_inspect()
    local preview, _bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then
        return false, tostring(preview_err or "no active PreviewPiece ; run build.preview.piece first")
    end
    local diag = {}
    local components = mesh_components_for_actor(preview, diag)
    local detail = preview_inspect_summary(preview, components, diag)
    print("[RSDWTools.oculus.preview.inspect] " .. detail)
    return true, detail
end

local function prepare_preview_swap_session(args_str, actor_override, source_override)
    if preview_swap or preview_swap_starting then
        return nil, "preview swap already active or starting ; confirm/cancel first"
    end

    local actor = actor_override
    local source = source_override
    local err = nil
    if not is_valid(actor) then
        local picked, _loc, picked_source, pick_err = feature_grab.pick_target_under_reticle()
        actor = picked
        source = picked_source
        err = pick_err
    end
    if not is_valid(actor) then return nil, tostring(err or "no actor under reticle") end

    if feature_grab.validate_target_safety then
        local safe_ok, safe_detail = feature_grab.validate_target_safety(actor, "grab")
        if not safe_ok then return nil, tostring(safe_detail) end
    end

    local desc, desc_err = find_mesh_descriptor(actor)
    if not desc then return nil, tostring(desc_err) end

    local requested = trim(args_str):lower()
    if requested == "" then requested = "auto" end
    if requested ~= "auto" and requested ~= "static" and requested ~= "skeletal" then
        return nil, "usage: camera.oculus.preview.swap.<start|capture> [auto|static|skeletal]"
    end

    local kind = requested == "auto" and desc.kind or requested
    if kind ~= desc.kind then
        return nil, string.format("target mesh kind is %s; requested %s host would be incompatible", tostring(desc.kind), tostring(kind))
    end

    preview_swap_token = preview_swap_token + 1
    local token = preview_swap_token
    local target_name = safe_short_name(actor)
    local mesh_name = safe_short_name(desc.mesh)
    return {
        token = token,
        phase = "captured",
        target = actor,
        target_name = target_name,
        source = source or "reticle",
        desc = desc,
        kind = kind,
        host_piece = preview_swap_host_for(kind),
        original_hidden = read_actor_hidden(actor),
        original_actor_loc = copy_loc(actor_transform(actor).loc),
        original_actor_rot = copy_rot(actor_transform(actor).rot),
        mesh_name = mesh_name,
    }, nil
end

local function preview_component_host_for(raw)
    local value = trim(raw)
    local normalized = value:lower()
    if normalized == "" or normalized == "auto" or normalized == "static" or normalized == "beam" then
        return PREVIEW_SWAP_STATIC_HOST
    end
    if normalized == "skeletal" or normalized == "mannequin" or normalized == "armourmannequin" or normalized == "armor" then
        return PREVIEW_SWAP_SKELETAL_HOST
    end
    return value
end

local function prepare_preview_component_session(args_str, actor_override, source_override)
    local session, err = prepare_preview_swap_session("skeletal", actor_override, source_override)
    if not session then return nil, tostring(err) end
    if session.kind ~= "skeletal" or not (session.desc and session.desc.kind == "skeletal") then
        return nil, "component proxy probe currently requires a skeletal target"
    end
    session.strategy = "component_proxy"
    session.host_piece = preview_component_host_for(args_str)
    return session, nil
end

local function preview_component_start_for_actor(actor, source, args_str)
    print("[RSDWTools.oculus.preview.component] start request source=" .. tostring(source or "reticle")
        .. " args=" .. tostring(trim(args_str)))
    local session, err = prepare_preview_component_session(args_str, actor, source)
    if not session then return false, tostring(err) end
    session.phase = "queued"
    local guard_token = feature_oculus_input_guard.acquire("preview.component.start")
    session.guard_token = guard_token
    preview_swap_starting = session
    print(string.format("[RSDWTools.oculus.preview.component] start queued target=%s kind=%s mesh=%s host=%s source=%s",
        tostring(session.target_name),
        tostring(session.kind),
        tostring(session.mesh_name),
        tostring(session.host_piece),
        tostring(session.source)))
    local arm_delay_ms = preview_swap_rearm_delay_ms()
    if arm_delay_ms > PREVIEW_SWAP_ARM_DELAY_MS then
        print("[RSDWTools.oculus.preview.component] arm delayed target=" .. tostring(session.target_name)
            .. " delay_ms=" .. tostring(arm_delay_ms)
            .. " base_ms=" .. tostring(PREVIEW_SWAP_ARM_DELAY_MS))
    end
    schedule_ms(arm_delay_ms, function() preview_swap_arm_when_lifecycle_ready(session.token) end)
    return true, string.format("start queued target=%s host=%s mesh=%s",
        tostring(session.target_name),
        tostring(session.host_piece),
        tostring(session.mesh_name))
end

local function preview_swap_start_for_actor(actor, source, args_str)
    local session, err = prepare_preview_swap_session(args_str, actor, source)
    if not session then return false, tostring(err) end
    session.phase = "queued"
    local guard_token = feature_oculus_input_guard.acquire("preview.swap.start")
    session.guard_token = guard_token
    preview_swap_starting = session
    print(string.format("[RSDWTools.oculus.preview.swap] start queued target=%s kind=%s mesh=%s host=%s source=%s",
        tostring(session.target_name),
        tostring(session.kind),
        tostring(session.mesh_name),
        tostring(session.host_piece),
        tostring(session.source)))
    local arm_delay_ms = preview_swap_rearm_delay_ms()
    if arm_delay_ms > PREVIEW_SWAP_ARM_DELAY_MS then
        print("[RSDWTools.oculus.preview.swap] arm delayed target=" .. tostring(session.target_name)
            .. " delay_ms=" .. tostring(arm_delay_ms)
            .. " base_ms=" .. tostring(PREVIEW_SWAP_ARM_DELAY_MS))
    end
    schedule_ms(arm_delay_ms, function() preview_swap_arm_when_lifecycle_ready(session.token) end)
    return true, string.format("start queued target=%s kind=%s host=%s mesh=%s",
        tostring(session.target_name),
        tostring(session.kind),
        tostring(session.host_piece),
        tostring(session.mesh_name))
end

function M.preview_swap_capture(args_str)
    local session, err = prepare_preview_swap_session(args_str)
    if not session then return false, tostring(err) end
    preview_swap_starting = session
    print(string.format("[RSDWTools.oculus.preview.swap] captured target=%s kind=%s mesh=%s host=%s",
        tostring(session.target_name),
        tostring(session.kind),
        tostring(session.mesh_name),
        tostring(session.host_piece)))
    return true, string.format("captured target=%s kind=%s host=%s mesh=%s",
        tostring(session.target_name),
        tostring(session.kind),
        tostring(session.host_piece),
        tostring(session.mesh_name))
end

function M.preview_component_capture(args_str)
    local session, err = prepare_preview_component_session(args_str)
    if not session then return false, tostring(err) end
    preview_swap_starting = session
    print(string.format("[RSDWTools.oculus.preview.component] captured target=%s mesh=%s host=%s",
        tostring(session.target_name),
        tostring(session.mesh_name),
        tostring(session.host_piece)))
    return true, string.format("captured target=%s host=%s mesh=%s",
        tostring(session.target_name),
        tostring(session.host_piece),
        tostring(session.mesh_name))
end

function M.preview_component_resolve()
    local session = preview_swap_starting or preview_swap
    if not session then return false, "no captured component probe ; run camera.oculus.preview.component.capture first" end
    if preview_swap and preview_swap == session then return false, "component probe already active ; cancel/confirm first" end
    print("[RSDWTools.oculus.preview.component] resolve begin target=" .. tostring(session.target_name)
        .. " phase=" .. tostring(session.phase))
    local ok, detail = resolve_preview_swap_host(session)
    if not ok then return false, tostring(detail) end
    print("[RSDWTools.oculus.preview.component] resolve ok target=" .. tostring(session.target_name)
        .. " piece=" .. tostring(detail))
    return true, "resolved target=" .. tostring(session.target_name) .. " " .. tostring(detail)
end

function M.preview_component_exit()
    local session = preview_swap_starting or preview_swap
    if not session then return false, "no captured component probe ; run camera.oculus.preview.component.capture first" end
    print("[RSDWTools.oculus.preview.component] exit begin target=" .. tostring(session.target_name)
        .. " phase=" .. tostring(session.phase))
    local ok, detail = feature_build_preview.exit_any_mode()
    if not ok then return false, tostring(detail) end
    session.exit_detail = detail
    session.phase = "manual_exit_requested"
    print("[RSDWTools.oculus.preview.component] exit ok target=" .. tostring(session.target_name)
        .. " " .. tostring(detail))
    return true, tostring(detail)
end

function M.preview_component_enter()
    local session = preview_swap_starting or preview_swap
    if not session then return false, "no captured component probe ; run camera.oculus.preview.component.capture first" end
    print("[RSDWTools.oculus.preview.component] enter begin target=" .. tostring(session.target_name)
        .. " phase=" .. tostring(session.phase))
    local ok, detail, bmc = feature_build_preview.force_enter_build_mode()
    if not ok then return false, tostring(detail) end
    session.bmc = bmc
    session.enter_detail = detail
    session.phase = "manual_entered"
    print("[RSDWTools.oculus.preview.component] enter ok target=" .. tostring(session.target_name)
        .. " " .. tostring(detail))
    return true, tostring(detail)
end

function M.preview_component_select()
    local session = preview_swap_starting or preview_swap
    if not session then return false, "no captured component probe ; run camera.oculus.preview.component.capture first" end
    if not is_valid(session.piece_data) then
        local ok_resolve, resolve_detail = resolve_preview_swap_host(session)
        if not ok_resolve then return false, tostring(resolve_detail) end
    end
    print("[RSDWTools.oculus.preview.component] select begin target=" .. tostring(session.target_name)
        .. " host=" .. tostring(session.host_piece)
        .. " phase=" .. tostring(session.phase))
    local ok, detail, preview, bmc = feature_build_preview.select_piece_data(session.piece_data)
    if not ok then return false, tostring(detail) end
    session.preview = preview
    session.bmc = bmc
    session.select_detail = detail
    session.phase = "manual_selected"
    print("[RSDWTools.oculus.preview.component] select ok target=" .. tostring(session.target_name)
        .. " preview=" .. tostring(is_valid(preview) and safe_short_name(preview) or "<missing>")
        .. " " .. tostring(detail))
    return true, tostring(detail)
end

function M.preview_component_preview()
    local session = preview_swap_starting or preview_swap
    if not session then return false, "no captured component probe ; run camera.oculus.preview.component.capture first" end
    print("[RSDWTools.oculus.preview.component] preview begin target=" .. tostring(session.target_name)
        .. " phase=" .. tostring(session.phase))
    local preview, bmc, _pc, err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then return false, tostring(err or "no live PreviewPiece") end
    session.preview = preview
    session.bmc = bmc
    session.phase = "manual_preview_ready"
    local xform = actor_world_transform(preview)
    print("[RSDWTools.oculus.preview.component] preview ok target=" .. tostring(session.target_name)
        .. " preview=" .. tostring(safe_short_name(preview))
        .. " xform=" .. tostring(xform and fmt_xform(xform) or "<missing>"))
    return true, "preview=" .. tostring(safe_short_name(preview))
        .. " " .. tostring(xform and fmt_xform(xform) or "")
end

function M.preview_component_create()
    local session = preview_swap_starting or preview_swap
    if not session then return false, "no captured component probe ; run camera.oculus.preview.component.capture first" end
    local preview = session.preview
    if not is_valid(preview) then
        preview = feature_build_preview.current_preview_piece()
        if is_valid(preview) then session.preview = preview end
    end
    if not is_valid(preview) then return false, "no live PreviewPiece ; run camera.oculus.preview.component.preview first" end
    if is_valid(session.preview_component_created) then
        return true, "already created component=" .. tostring(safe_short_name(session.preview_component_created))
    end
    local component, detail = create_preview_skeletal_component(session, preview)
    if not is_valid(component) then return false, tostring(detail) end
    session.preview_component = component
    session.preview_component_created = component
    session.preview_component_label = "created:" .. tostring(detail)
    session.preview_component_snapshot = nil
    session.phase = "manual_component_created"
    return true, "created component=" .. tostring(safe_short_name(component))
end

function M.preview_component_mesh()
    local session = preview_swap_starting or preview_swap
    if not session then return false, "no captured component probe ; run camera.oculus.preview.component.capture first" end
    local component = session.preview_component_created or session.preview_component
    if not is_valid(component) then return false, "no created component ; run camera.oculus.preview.component.create first" end
    if not (session.desc and is_valid(session.desc.mesh)) then return false, "missing captured skeletal mesh" end
    print("[RSDWTools.oculus.preview.component] mesh begin target=" .. tostring(session.target_name)
        .. " component=" .. tostring(safe_short_name(component))
        .. " mesh=" .. tostring(session.mesh_name))
    local ok, detail = set_preview_component_mesh(component, "skeletal", session.desc.mesh, session.setter_route)
    if not ok then return false, tostring(detail) end
    local material_count = apply_proxy_materials(component, session.desc.materials)
    refresh_component_renderable(component, false)
    session.mesh_route = detail
    session.material_count = material_count
    session.phase = "manual_mesh_set"
    print("[RSDWTools.oculus.preview.component] mesh ok target=" .. tostring(session.target_name)
        .. " route=" .. tostring(detail)
        .. " materials=" .. tostring(material_count))
    return true, "mesh route=" .. tostring(detail) .. " materials=" .. tostring(material_count)
end

function M.preview_component_attach()
    local session = preview_swap_starting or preview_swap
    if not session then return false, "no captured component probe ; run camera.oculus.preview.component.capture first" end
    local component = session.preview_component_created or session.preview_component
    if not is_valid(component) then return false, "no created component ; run camera.oculus.preview.component.create first" end
    if not is_valid(session.preview) then return false, "no PreviewPiece ; run camera.oculus.preview.component.preview first" end
    print("[RSDWTools.oculus.preview.component] attach begin target=" .. tostring(session.target_name)
        .. " component=" .. tostring(safe_short_name(component))
        .. " preview=" .. tostring(safe_short_name(session.preview)))
    local ok, detail = attach_component_to_preview_root(component, session.preview)
    if not ok then return false, tostring(detail) end
    session.attach_detail = detail
    session.phase = "manual_attached"
    print("[RSDWTools.oculus.preview.component] attach ok target=" .. tostring(session.target_name)
        .. " " .. tostring(detail))
    return true, tostring(detail)
end

function M.preview_component_register()
    local session = preview_swap_starting or preview_swap
    if not session then return false, "no captured component probe ; run camera.oculus.preview.component.capture first" end
    local component = session.preview_component_created or session.preview_component
    if not is_valid(component) then return false, "no created component ; run camera.oculus.preview.component.create first" end
    if not is_valid(session.preview) then return false, "no PreviewPiece ; run camera.oculus.preview.component.preview first" end
    print("[RSDWTools.oculus.preview.component] register begin target=" .. tostring(session.target_name)
        .. " component=" .. tostring(safe_short_name(component)))
    local detail = register_preview_component(component, session.preview)
    session.register_detail = detail
    session.phase = "manual_registered"
    print("[RSDWTools.oculus.preview.component] register ok target=" .. tostring(session.target_name)
        .. " " .. tostring(detail))
    return true, tostring(detail)
end

function M.preview_component_hidehost()
    local session = preview_swap_starting or preview_swap
    if not session then return false, "no captured component probe ; run camera.oculus.preview.component.capture first" end
    local component = session.preview_component_created or session.preview_component
    if not is_valid(component) then return false, "no created component ; run camera.oculus.preview.component.create first" end
    if not is_valid(session.preview) then return false, "no PreviewPiece ; run camera.oculus.preview.component.preview first" end
    print("[RSDWTools.oculus.preview.component] hidehost begin target=" .. tostring(session.target_name)
        .. " preview=" .. tostring(safe_short_name(session.preview)))
    local snapshot, hidden = hide_preview_component_proxy_host_visuals(session.preview, component)
    session.preview_sibling_visuals = snapshot
    session.preview_sibling_hidden = hidden
    session.phase = "manual_host_hidden"
    print("[RSDWTools.oculus.preview.component] hidehost ok target=" .. tostring(session.target_name)
        .. " hidden=" .. tostring(hidden))
    return true, "hidden_host=" .. tostring(hidden)
end

function M.preview_component_finish()
    local session = preview_swap_starting
    if not session then
        if preview_swap then return true, "already active target=" .. tostring(preview_swap.target_name) end
        return false, "no starting component probe ; run camera.oculus.preview.component.capture first"
    end
    if not is_valid(session.preview_component) then return false, "no created component ; run create/mesh/attach/register first" end
    preview_swap_starting = nil
    preview_swap = session
    session.phase = "active"
    release_preview_swap_guard(session, "preview.component.active")
    pcall(function() feature_umg.toast("Preview Component: " .. tostring(session.target_name), 1.3) end)
    print("[RSDWTools.oculus.preview.component] finish active target=" .. tostring(session.target_name)
        .. " component=" .. tostring(session.preview_component_label))
    return true, "active target=" .. tostring(session.target_name)
        .. " component=" .. tostring(session.preview_component_label)
end

function M.preview_swap_arm()
    local session = preview_swap_starting
    if not session then return false, "no captured preview swap ; run camera.oculus.preview.swap.capture first" end
    if preview_swap then return false, "preview swap already active" end
    local ok, detail = arm_preview_swap_session(session)
    if not ok then return false, tostring(detail) end
    return true, string.format("armed target=%s kind=%s host=%s %s",
        tostring(session.target_name),
        tostring(session.kind),
        tostring(session.host_piece),
        tostring(detail))
end

function M.preview_swap_apply()
    local session = preview_swap_starting
    if not session then return false, "no armed preview swap ; run camera.oculus.preview.swap.capture then .arm first" end
    if preview_swap then return false, "preview swap already active" end

    session.phase = "manual_apply_preview"
    local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then
        session.bmc = bmc
        return false, tostring(preview_err or "PreviewPiece missing")
    end
    session.preview = preview
    session.bmc = bmc

    local ok, detail = apply_preview_swap(session, preview)
    if not ok then
        session.phase = "apply_failed"
        print("[RSDWTools.oculus.preview.swap] manual apply failed target=" .. tostring(session.target_name)
            .. " ; " .. tostring(detail))
        return false, tostring(detail)
    end

    preview_swap_starting = nil
    preview_swap = session
    session.phase = "active"
    pcall(function() feature_umg.toast("Preview Swap: " .. tostring(session.target_name), 1.3) end)
    return true, tostring(detail)
end

function M.preview_swap_start(args_str)
    return preview_swap_start_for_actor(nil, "reticle", args_str)
end

function M.preview_swap_start_actor(actor, source, args_str)
    return preview_swap_start_for_actor(actor, source or "actor", args_str)
end

function M.preview_component_start(args_str)
    return preview_component_start_for_actor(nil, "reticle", args_str)
end

function M.preview_component_start_actor(actor, source, args_str)
    return preview_component_start_for_actor(actor, source or "actor", args_str)
end

function M.preview_component_arm()
    return M.preview_swap_arm()
end

function M.preview_component_apply()
    return M.preview_swap_apply()
end

function M.preview_component_status()
    return preview_swap_status_detail()
end

function M.preview_component_confirm()
    return M.preview_swap_confirm()
end

function M.preview_component_cancel()
    return M.preview_swap_cancel()
end

local function prepare_preview_move_session(args_str, actor_override, source_override)
    if preview_move then
        return nil, "preview move already captured ; confirm/cancel first"
    end
    if preview_swap or preview_swap_starting or placement or placement_starting then
        return nil, "another preview/proxy placement session is active ; confirm/cancel first"
    end

    local actor = actor_override
    local source = source_override
    local err = nil
    if not is_valid(actor) then
        local picked, _loc, picked_source, pick_err = feature_grab.pick_target_under_reticle()
        actor = picked
        source = picked_source
        err = pick_err
    end
    if not is_valid(actor) then return nil, tostring(err or "no actor under reticle") end

    if feature_grab.validate_target_safety then
        local safe_ok, safe_detail = feature_grab.validate_target_safety(actor, "preview move")
        if not safe_ok then return nil, tostring(safe_detail) end
    end

    local host = trim(args_str)
    if host == "" then host = PREVIEW_MOVE_DEFAULT_HOST end
    local ok_piece, piece_detail, piece_data = feature_build_preview.resolve_piece_arg(host)
    if not ok_piece then
        return nil, "could not resolve preview move host '" .. tostring(host) .. "': " .. tostring(piece_detail)
    end

    local target_root = actor_world_transform(actor) or actor_transform(actor)
    local desc, desc_err = find_mesh_descriptor(actor)
    local root_from_mesh_offset = nil
    local root_from_mesh_rotation = nil
    local mesh_name = nil
    local source_component_label = nil
    if desc and is_valid(desc.component) then
        source_component_label = desc.component_label
        mesh_name = safe_short_name(desc.mesh)
        local source_component_xform = component_world_transform(desc.component)
        if source_component_xform then
            if target_root and target_root.loc and source_component_xform.loc then
                root_from_mesh_offset = vec_sub(target_root.loc, source_component_xform.loc)
            end
            if target_root and target_root.rot and source_component_xform.rot then
                root_from_mesh_rotation = rot_sub(target_root.rot, source_component_xform.rot)
            end
        end
    end

    preview_swap_token = preview_swap_token + 1
    return {
        token = preview_swap_token,
        target = actor,
        target_name = safe_short_name(actor),
        source = source or "reticle",
        desc = desc,
        desc_err = desc_err,
        mesh_name = mesh_name,
        source_component_label = source_component_label,
        root_from_mesh_offset = root_from_mesh_offset,
        root_from_mesh_rotation = root_from_mesh_rotation,
        host_piece = host,
        piece_detail = piece_detail,
        piece_data = piece_data,
        original_actor_loc = copy_loc(target_root.loc),
        original_actor_rot = copy_rot(target_root.rot),
    }, nil
end

function M.preview_move_start_actor(actor, source, args_str)
    if preview_swap_lifecycle_busy then
        local detail = "grab cooling down after " .. tostring(preview_swap_lifecycle_reason or "previous placement")
            .. "; try again in a moment"
        print("[RSDWTools.oculus.preview.move] " .. detail)
        return true, detail
    end

    local session, err = prepare_preview_move_session(args_str or "", actor, source or "actor")
    if not session then return false, tostring(err) end
    session.phase = "queued"
    session.guard_token = feature_oculus_input_guard.acquire("preview.move.start")
    preview_move = session

    print(string.format("[RSDWTools.oculus.preview.move] start queued target=%s host=%s mesh=%s source=%s",
        tostring(session.target_name),
        tostring(session.host_piece),
        tostring(session.mesh_name or "<raw>"),
        tostring(session.source)))

    local token = session.token
    local wait_lifecycle, wait_exit_ready, enter_build, wait_enter_ready, select_piece, wait_preview_ready
    local function fail(reason)
        if preview_move ~= session or session.token ~= token then return end
        preview_move = nil
        mark_preview_swap_settle("preview.move.start_failed")
        if session.guard_token then
            pcall(function() feature_oculus_input_guard.release(session.guard_token, "preview.move.start_failed") end)
            session.guard_token = nil
        end
        exit_build_preview(session)
        print("[RSDWTools.oculus.preview.move] start failed target=" .. tostring(session.target_name)
            .. " ; " .. tostring(reason))
    end
    local function release_guard(reason)
        if session.guard_token then
            pcall(function() feature_oculus_input_guard.release(session.guard_token, reason or "preview.move.ready") end)
            session.guard_token = nil
        end
    end

    wait_lifecycle = function()
        if preview_move ~= session or session.token ~= token then return end
        if preview_swap_lifecycle_busy then
            session.phase = "lifecycle_wait"
            if session.lifecycle_wait_logged ~= true then
                session.lifecycle_wait_logged = true
                print("[RSDWTools.oculus.preview.move] lifecycle wait target=" .. tostring(session.target_name)
                    .. " reason=" .. tostring(preview_swap_lifecycle_reason or "busy")
                    .. " poll_ms=" .. tostring(PREVIEW_SWAP_LIFECYCLE_POLL_MS))
            end
            schedule_ms(PREVIEW_SWAP_LIFECYCLE_POLL_MS, wait_lifecycle)
            return
        end

        session.phase = "exit_before_build"
        print("[RSDWTools.oculus.preview.move] exit begin target=" .. tostring(session.target_name))
        local ok_exit, exit_detail = feature_build_preview.exit_any_mode()
        if not ok_exit then return fail(exit_detail) end
        session.exit_detail = exit_detail
        session.phase = "exit_ready_wait"
        session.exit_ready_attempts = 0
        print("[RSDWTools.oculus.preview.move] exit requested target=" .. tostring(session.target_name)
            .. " ; " .. tostring(exit_detail))
        schedule_ms(PREVIEW_SWAP_POLL_MS, wait_exit_ready)
    end

    wait_exit_ready = function()
        if preview_move ~= session or session.token ~= token then return end
        session.exit_ready_attempts = (session.exit_ready_attempts or 0) + 1
        local ok_mode, info = feature_build_preview.current_mode_info()
        local preview_valid = ok_mode and is_valid(info.preview)
        local mode_id = ok_mode and info.mode_id or nil
        if ok_mode and not preview_valid and (mode_id == 0 or mode_id == 3) then
            print("[RSDWTools.oculus.preview.move] exit ready target=" .. tostring(session.target_name)
                .. " mode=" .. tostring(info.mode))
            return enter_build()
        end
        if ok_mode and not preview_valid and mode_id == 1 then
            print("[RSDWTools.oculus.preview.move] selection already ready target=" .. tostring(session.target_name)
                .. " mode=" .. tostring(info.mode))
            return select_piece()
        end
        if session.exit_ready_attempts >= PREVIEW_SWAP_EXIT_READY_MAX_ATTEMPTS then
            return fail("timed out waiting for build mode exit"
                .. " mode=" .. tostring(ok_mode and info.mode or info)
                .. " mode_id=" .. tostring(mode_id or "?")
                .. " preview=" .. tostring(preview_valid))
        end
        session.phase = "exit_ready_wait"
        schedule_ms(PREVIEW_SWAP_POLL_MS, wait_exit_ready)
    end

    enter_build = function()
        if preview_move ~= session or session.token ~= token then return end
        session.phase = "enter_build"
        print("[RSDWTools.oculus.preview.move] enter begin target=" .. tostring(session.target_name))
        local ok_enter, enter_detail, bmc = feature_build_preview.force_enter_build_mode()
        if not ok_enter then return fail(enter_detail) end
        session.bmc = bmc
        session.enter_detail = enter_detail
        session.phase = "enter_ready_wait"
        session.enter_ready_attempts = 0
        print("[RSDWTools.oculus.preview.move] enter requested target=" .. tostring(session.target_name)
            .. " ; " .. tostring(enter_detail))
        schedule_ms(PREVIEW_SWAP_POLL_MS, wait_enter_ready)
    end

    wait_enter_ready = function()
        if preview_move ~= session or session.token ~= token then return end
        session.enter_ready_attempts = (session.enter_ready_attempts or 0) + 1
        local ok_mode, info = feature_build_preview.current_mode_info()
        local mode_id = ok_mode and info.mode_id or nil
        if ok_mode and mode_id == 1 then
            print("[RSDWTools.oculus.preview.move] enter ready target=" .. tostring(session.target_name)
                .. " mode=" .. tostring(info.mode))
            return select_piece()
        end
        if session.enter_ready_attempts >= PREVIEW_SWAP_ENTER_READY_MAX_ATTEMPTS then
            return fail("timed out waiting for build selection mode"
                .. " mode=" .. tostring(ok_mode and info.mode or info)
                .. " mode_id=" .. tostring(mode_id or "?"))
        end
        session.phase = "enter_ready_wait"
        schedule_ms(PREVIEW_SWAP_POLL_MS, wait_enter_ready)
    end

    select_piece = function()
        if preview_move ~= session or session.token ~= token then return end
        session.phase = "select_piece"
        print("[RSDWTools.oculus.preview.move] select begin target=" .. tostring(session.target_name)
            .. " host=" .. tostring(session.host_piece))
        local ok_select, select_detail, preview, bmc = feature_build_preview.select_piece_data(session.piece_data)
        if not ok_select then return fail(select_detail) end
        session.preview = preview
        session.bmc = bmc
        session.select_detail = select_detail
        session.phase = "preview_ready_wait"
        session.preview_ready_attempts = 0
        print("[RSDWTools.oculus.preview.move] select requested target=" .. tostring(session.target_name)
            .. " preview=" .. tostring(is_valid(preview) and safe_short_name(preview) or "<missing>")
            .. " ; " .. tostring(select_detail))
        -- Give the vanilla PreviewPiece a short moment to finish its own
        -- post-selection setup before Oculus reads it and exposes Grab Mode.
        schedule_ms(250, wait_preview_ready)
    end

    wait_preview_ready = function()
        if preview_move ~= session or session.token ~= token then return end
        session.preview_ready_attempts = (session.preview_ready_attempts or 0) + 1
        local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
        if is_valid(preview) then
            session.preview = preview
            session.bmc = bmc
            session.phase = "active"
            release_guard("preview.move.active")
            print("[RSDWTools.oculus.preview.move] active target=" .. tostring(session.target_name)
                .. " preview=" .. tostring(safe_short_name(preview))
                .. " host=" .. tostring(session.host_piece)
                .. " mesh=" .. tostring(session.mesh_name or "<raw>"))
            return
        end
        if session.preview_ready_attempts >= PREVIEW_SWAP_PREVIEW_READY_MAX_ATTEMPTS then
            return fail("timed out waiting for PreviewPiece after selecting host: " .. tostring(preview_err))
        end
        session.phase = "preview_ready_wait"
        schedule_ms(PREVIEW_SWAP_POLL_MS, wait_preview_ready)
    end

    schedule_ms(preview_swap_rearm_delay_ms(), wait_lifecycle)
    return true, string.format("start queued target=%s host=%s mesh=%s",
        tostring(session.target_name),
        tostring(session.host_piece),
        tostring(session.mesh_name or "<raw>"))
end

function M.preview_move_start(args_str)
    return M.preview_move_start_actor(nil, "reticle", args_str or "")
end

function M.preview_move_capture(args_str)
    local session, err = prepare_preview_move_session(args_str or "")
    if not session then return false, tostring(err) end
    preview_move = session
    print("[RSDWTools.oculus.preview.move] captured target=" .. tostring(session.target_name)
        .. " source=" .. tostring(session.source)
        .. " host=" .. tostring(session.host_piece)
        .. " mesh=" .. tostring(session.mesh_name or "<raw>")
        .. " src_comp=" .. tostring(session.source_component_label or "<none>")
        .. " " .. tostring(session.piece_detail))
    return true, "captured target=" .. tostring(session.target_name)
        .. " host=" .. tostring(session.host_piece)
        .. " mesh=" .. tostring(session.mesh_name or "<raw>")
        .. " " .. tostring(session.piece_detail)
end

function M.preview_move_status()
    local session = preview_move
    if not session then return true, "preview move active=0" end
    local preview, _bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    local preview_valid = is_valid(preview)
    local xform = preview_valid and actor_world_transform(preview) or nil
    local loc = xform and xform.loc or {}
    local rot = xform and xform.rot or {}
    local corrected_loc = nil
    local corrected_rot = nil
    if xform and session.root_from_mesh_offset then
        corrected_loc = vec_add(xform.loc, session.root_from_mesh_offset)
    end
    if xform and session.root_from_mesh_rotation then
        corrected_rot = rot_add(xform.rot, session.root_from_mesh_rotation)
    end
    return true, string.format(
        "preview move active=1 target=%s host=%s mesh=%s preview_valid=%s preview=%s loc=(%.1f,%.1f,%.1f) rot=(P%.1f,Y%.1f,R%.1f)%s%s",
        tostring(session.target_name),
        tostring(session.host_piece),
        tostring(session.mesh_name or "<raw>"),
        tostring(preview_valid),
        preview_valid and tostring(safe_short_name(preview)) or "<none>",
        loc.X or 0,
        loc.Y or 0,
        loc.Z or 0,
        rot.Pitch or 0,
        rot.Yaw or 0,
        rot.Roll or 0,
        corrected_loc and string.format(" corrected=(%.1f,%.1f,%.1f P%.1f,Y%.1f,R%.1f)",
            corrected_loc.X or 0,
            corrected_loc.Y or 0,
            corrected_loc.Z or 0,
            corrected_rot and corrected_rot.Pitch or rot.Pitch or 0,
            corrected_rot and corrected_rot.Yaw or rot.Yaw or 0,
            corrected_rot and corrected_rot.Roll or rot.Roll or 0) or "",
        preview_valid and "" or (" err=" .. tostring(preview_err)))
end

function M.preview_move_confirm()
    local session = preview_move
    if not session then return false, "no active preview move ; run camera.oculus.preview.move.capture first" end
    if not is_valid(session.target) then
        preview_move = nil
        if session.guard_token then
            pcall(function() feature_oculus_input_guard.release(session.guard_token, "preview.move.target_lost") end)
            session.guard_token = nil
        end
        pcall(function() feature_build_preview.exit_any_mode() end)
        mark_preview_swap_settle("preview.move.target_lost")
        return false, "target actor is no longer valid"
    end

    local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then
        return false, tostring(preview_err or "no live PreviewPiece ; run build.preview.enter/select first")
    end
    session.preview = preview
    session.bmc = bmc

    local xform, xform_err = actor_world_transform(preview)
    if not xform then return false, tostring(xform_err or "could not read PreviewPiece transform") end
    local source = "preview_actor"
    if session.root_from_mesh_offset or session.root_from_mesh_rotation then
        xform = {
            loc = session.root_from_mesh_offset and vec_add(xform.loc, session.root_from_mesh_offset) or copy_loc(xform.loc),
            rot = session.root_from_mesh_rotation and rot_add(xform.rot, session.root_from_mesh_rotation) or copy_rot(xform.rot),
            scale = copy_scale(xform.scale),
        }
        source = "preview_actor_corrected"
    end

    preview_move = nil
    if session.guard_token then
        pcall(function() feature_oculus_input_guard.release(session.guard_token, "preview.move.confirm") end)
        session.guard_token = nil
    end
    local moved, move_detail = move_target_once(session.target, xform)
    exit_build_preview(session)
    mark_preview_swap_settle("preview.move.confirm")
    if not moved then return false, tostring(move_detail) end

    print(string.format(
        "[RSDWTools.oculus.preview.move] confirm target=%s host=%s source=%s loc=(%.1f,%.1f,%.1f) rot=(P%.1f,Y%.1f,R%.1f)",
        tostring(session.target_name),
        tostring(session.host_piece),
        tostring(source),
        xform.loc and xform.loc.X or 0,
        xform.loc and xform.loc.Y or 0,
        xform.loc and xform.loc.Z or 0,
        xform.rot and xform.rot.Pitch or 0,
        xform.rot and xform.rot.Yaw or 0,
        xform.rot and xform.rot.Roll or 0))
    return true, "placed target=" .. tostring(session.target_name)
        .. " host=" .. tostring(session.host_piece)
        .. " source=" .. tostring(source) .. " "
        .. tostring(move_detail)
end

function M.preview_move_cancel()
    local session = preview_move
    preview_move = nil
    if session and session.guard_token then
        pcall(function() feature_oculus_input_guard.release(session.guard_token, "preview.move.cancel") end)
        session.guard_token = nil
    end
    pcall(function() feature_build_preview.exit_any_mode() end)
    if session then mark_preview_swap_settle("preview.move.cancel") end
    if not session then return true, "no active preview move" end
    print("[RSDWTools.oculus.preview.move] cancel target=" .. tostring(session.target_name))
    return true, "cancelled target=" .. tostring(session.target_name)
end

function M.preview_swap_status()
    return preview_swap_status_detail()
end

function M.preview_swap_debug()
    local session = preview_swap or preview_swap_starting
    local ok, detail = preview_swap_debug_detail(session)
    if ok then print("[RSDWTools.oculus.preview.swap] debug " .. tostring(detail)) end
    return ok, detail
end

function M.preview_swap_xform()
    return preview_swap_xform_detail(preview_swap)
end

function M.preview_swap_skelroute(args_str)
    local session = preview_swap or preview_swap_starting
    return reapply_preview_swap_skeletal_route(session, args_str or "")
end

function M.preview_swap_anim(args_str)
    return preview_swap_anim_probe(preview_swap, args_str or "")
end

function M.preview_swap_cleanup(args_str)
    return cleanup_preview_swap_component(preview_swap, args_str or "")
end

function M.preview_swap_host(args_str)
    local session = preview_swap_starting
    if preview_swap then return false, "preview swap is already active ; cancel/confirm before changing host" end
    if not session then return false, "no captured preview swap ; run camera.oculus.preview.swap.capture first" end
    local raw = trim(args_str)
    if raw == "" then return false, "usage: camera.oculus.preview.swap.host <piece index|piece name|piece full path|static|skeletal>" end
    local lowered = raw:lower()
    if lowered == "static" or lowered == "default_static" then
        raw = PREVIEW_SWAP_STATIC_HOST
    elseif lowered == "skeletal" or lowered == "default_skeletal" then
        raw = PREVIEW_SWAP_SKELETAL_HOST
    end
    session.host_piece = raw
    return true, "host set target=" .. tostring(session.target_name)
        .. " kind=" .. tostring(session.kind)
        .. " host=" .. tostring(session.host_piece)
end

function M.preview_host_audit(args_str)
    local raw = trim(args_str)
    if raw == "" then return false, "usage: camera.oculus.preview.host.audit <piece index|piece name|piece full path>" end
    local ok_piece, piece_detail = feature_build_preview.piece(raw)
    if not ok_piece then return false, tostring(piece_detail) end
    local preview, _bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then
        return true, "armed " .. tostring(piece_detail)
            .. " ; preview not readable yet: " .. tostring(preview_err or "no PreviewPiece")
            .. " ; run camera.oculus.preview.inspect after the preview appears"
    end
    local diag = {}
    local components = mesh_components_for_actor(preview, diag)
    local detail = "armed " .. tostring(piece_detail) .. " ; " .. preview_inspect_summary(preview, components, diag)
    print("[RSDWTools.oculus.preview.host.audit] " .. detail)
    return true, detail
end

function M.preview_swap_confirm()
    if preview_swap_starting then
        return true, "preview swap still starting phase=" .. tostring(preview_swap_starting.phase or "queued")
    end
    local session = preview_swap
    if not session then return false, "no active preview swap" end

    local xform, source = preview_swap_confirm_transform(session)
    if not xform then
        preview_swap = nil
        restore_target_visibility(session)
        cleanup_preview_swap(session, true)
        mark_preview_swap_settle("confirm_transform_failed")
        return false, "could not read final PreviewPiece transform: " .. tostring(source)
    end

    preview_swap = nil
    cleanup_preview_swap(session, true)
    local moved, move_detail = move_target_once(session.target, xform)
    restore_target_visibility(session)
    if not moved then
        mark_preview_swap_settle("confirm_move_failed")
        return false, tostring(move_detail)
    end

    print(string.format(
        "[RSDWTools.oculus.preview.swap] confirm target=%s source=%s loc=(%.1f,%.1f,%.1f) rot=(P%.1f,Y%.1f,R%.1f)",
        tostring(session.target_name),
        tostring(source),
        xform.loc and xform.loc.X or 0,
        xform.loc and xform.loc.Y or 0,
        xform.loc and xform.loc.Z or 0,
        xform.rot and xform.rot.Pitch or 0,
        xform.rot and xform.rot.Yaw or 0,
        xform.rot and xform.rot.Roll or 0))
    mark_preview_swap_settle("confirm")
    schedule_post_confirm_exit(session.bmc, "preview.swap.confirm")
    pcall(function() feature_umg.toast("Preview Swap Placed: " .. tostring(session.target_name), 1.3) end)
    return true, string.format("placed target=%s kind=%s host=%s source=%s %s",
        tostring(session.target_name),
        tostring(session.kind),
        tostring(session.host_piece),
        tostring(source),
        tostring(move_detail))
end

function M.preview_swap_cancel()
    if preview_swap_starting then
        local session = preview_swap_starting
        preview_swap_starting = nil
        restore_target_visibility(session)
        cleanup_preview_swap(session, true)
        mark_preview_swap_settle("cancel_starting")
        print("[RSDWTools.oculus.preview.swap] cancel starting target=" .. tostring(session.target_name))
        return true, "cancelled starting target=" .. tostring(session.target_name)
    end
    local session = preview_swap
    if not session then return true, "no active preview swap" end
    preview_swap = nil
    restore_target_visibility(session)
    cleanup_preview_swap(session, true)
    mark_preview_swap_settle("cancel")
    print("[RSDWTools.oculus.preview.swap] cancel target=" .. tostring(session.target_name))
    pcall(function() feature_umg.toast("Preview Swap Cancelled", 1.2) end)
    return true, "cancelled target=" .. tostring(session.target_name)
end

place_start_arm = function(token)
    local pending = active_pending(token)
    if not pending then return end
    if not is_valid(pending.target) then
        return fail_pending_start(pending, "target actor is no longer valid before preview arm")
    end
    if not pending.proxy_entry or not is_valid(pending.proxy_entry.actor) then
        return fail_pending_start(pending, "proxy actor missing before preview arm")
    end

    pending.phase = "arm_preview"
    trace_pending(pending, "begin host=" .. tostring(pending.host_piece))
    local host_piece = pending.host_piece
    trace_pending(pending, "feature_build_preview.piece begin")
    local ok_piece, piece_detail = feature_build_preview.piece(host_piece)
    if not ok_piece and pending.using_default_host then
        local first_detail = piece_detail
        for _, fallback in ipairs(DEFAULT_PLACE_HOST_FALLBACKS) do
            trace_pending(pending, "feature_build_preview.piece fallback begin " .. tostring(fallback))
            local fallback_ok, fallback_detail = feature_build_preview.piece(fallback)
            if fallback_ok then
                ok_piece = true
                piece_detail = fallback_detail
                host_piece = fallback
                pending.host_piece = fallback
                break
            end
            piece_detail = tostring(first_detail) .. " ; fallback " .. tostring(fallback) .. ": " .. tostring(fallback_detail)
        end
    end
    if not ok_piece then
        return fail_pending_start(pending, "could not arm preview host '" .. tostring(host_piece) .. "': " .. tostring(piece_detail))
    end
    trace_pending(pending, "feature_build_preview.piece ok detail=" .. tostring(piece_detail))

    trace_pending(pending, "current_preview_piece begin")
    local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then
        pending.bmc = bmc
        return fail_pending_start(pending, tostring(preview_err or "PreviewPiece missing after arming host"))
    end
    trace_pending(pending, "current_preview_piece ok preview=" .. tostring(safe_short_name(preview)))

    pending.preview = preview
    pending.bmc = bmc
    pending.phase = "preview_sample"
    pending.preview_sample_index = 1
    pending.preview_sample_name = nil
    pending.preview_sample_loc = nil
    print(string.format("[RSDWTools.oculus.proxy.place] staged target=%s phase=preview_sample frames=%s",
        tostring(pending.target_name), table.concat(PLACE_PREVIEW_SAMPLE_FRAMES, ",")))
    place_start_sample(token)
end

place_start_spawn = function(token)
    local pending = active_pending(token)
    if not pending then return end
    if not is_valid(pending.target) then
        return fail_pending_start(pending, "target actor is no longer valid before proxy spawn")
    end

    pending.phase = "spawn_proxy"
    trace_pending(pending, "actor_transform target begin")
    local xform = actor_transform(pending.target)
    trace_pending(pending, string.format("actor_transform target ok loc=(%.1f,%.1f,%.1f)",
        xform.loc and xform.loc.X or 0,
        xform.loc and xform.loc.Y or 0,
        xform.loc and xform.loc.Z or 0))

    trace_pending(pending, "spawn_proxy_for_actor begin")
    local entry, spawn_err = spawn_proxy_for_actor(pending.target, xform, "proxy.place")
    if not entry then
        return fail_pending_start(pending, tostring(spawn_err))
    end
    pending.proxy_entry = entry
    trace_pending(pending, "spawn_proxy_for_actor ok proxy=" .. tostring(entry.proxy_name))

    pending.root_from_mesh_offset = nil
    pending.root_from_mesh_rotation = nil
    if is_valid(entry.source_component) then
        trace_pending(pending, "source_component_transform begin comp=" .. tostring(entry.source_component_label))
        local source_component_xform = component_world_transform(entry.source_component)
        if source_component_xform then
            if pending.original_actor_loc and source_component_xform.loc then
                pending.root_from_mesh_offset = vec_sub(pending.original_actor_loc, source_component_xform.loc)
            end
            if pending.original_actor_rot and source_component_xform.rot then
                pending.root_from_mesh_rotation = rot_sub(pending.original_actor_rot, source_component_xform.rot)
            end
        end
        trace_pending(pending, "source_component_transform done")
    end

    pending.phase = "proxy_spawned"
    print(string.format("[RSDWTools.oculus.proxy.place] staged target=%s phase=proxy_spawned arm_frames=%d root_from_mesh_rot=(%.1f,%.1f,%.1f)",
        tostring(pending.target_name),
        PLACE_ARM_DELAY_FRAMES,
        pending.root_from_mesh_rotation and pending.root_from_mesh_rotation.Pitch or 0,
        pending.root_from_mesh_rotation and pending.root_from_mesh_rotation.Yaw or 0,
        pending.root_from_mesh_rotation and pending.root_from_mesh_rotation.Roll or 0))
    schedule_frames(PLACE_ARM_DELAY_FRAMES, function() place_start_arm(token) end)
end

place_start_sample = function(token)
    local pending = active_pending(token)
    if not pending then return end

    local sample_index = pending.preview_sample_index or 1
    local sample_frame = PLACE_PREVIEW_SAMPLE_FRAMES[sample_index] or 0
    pending.phase = "preview_sample"

    local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then
        pending.bmc = bmc or pending.bmc
        return fail_pending_start(pending, tostring(preview_err or "PreviewPiece missing during sample"))
    end
    pending.preview = preview
    pending.bmc = bmc or pending.bmc

    local preview_name = safe_short_name(preview)
    local changed = ""
    if pending.preview_sample_name and pending.preview_sample_name ~= preview_name then
        changed = " changed_from=" .. tostring(pending.preview_sample_name)
    end
    pending.preview_sample_name = preview_name

    local xform, xform_err = actor_world_transform(preview)
    if not xform then
        return fail_pending_start(pending, "could not read sampled PreviewPiece transform: " .. tostring(xform_err))
    end
    local delta = loc_delta(xform.loc, pending.preview_sample_loc)
    pending.preview_sample_loc = copy_loc(xform.loc)

    print(string.format(
        "[RSDWTools.oculus.proxy.place] sample target=%s frame=%s preview=%s%s loc=(%.1f,%.1f,%.1f) rot=(P%.1f,Y%.1f,R%.1f) moved=%.2f %s",
        tostring(pending.target_name),
        tostring(sample_frame),
        tostring(preview_name),
        changed,
        xform.loc.X or 0,
        xform.loc.Y or 0,
        xform.loc.Z or 0,
        xform.rot.Pitch or 0,
        xform.rot.Yaw or 0,
        xform.rot.Roll or 0,
        delta or 0,
        attachment_summary(preview)))

    if sample_index < #PLACE_PREVIEW_SAMPLE_FRAMES then
        local next_frame = PLACE_PREVIEW_SAMPLE_FRAMES[sample_index + 1]
        local delay = math.max(1, (next_frame or sample_frame + 1) - sample_frame)
        pending.preview_sample_index = sample_index + 1
        schedule_frames(delay, function() place_start_sample(token) end)
        return
    end

    pending.phase = "attach_wait"
    print(string.format("[RSDWTools.oculus.proxy.place] staged target=%s phase=attach_wait frames=%d after_sample_frame=%s",
        tostring(pending.target_name),
        PLACE_ATTACH_DELAY_FRAMES,
        tostring(sample_frame)))
    schedule_frames(PLACE_ATTACH_DELAY_FRAMES, function() place_start_attach(token) end)
end

place_start_attach = function(token)
    local pending = active_pending(token)
    if not pending then return end
    local entry = pending.proxy_entry
    if not entry or not is_valid(entry.actor) then
        return fail_pending_start(pending, "proxy actor lost before attach")
    end

    pending.phase = "attach_preview"
    trace_pending(pending, "current_preview_piece begin")
    local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then
        pending.bmc = bmc or pending.bmc
        return fail_pending_start(pending, tostring(preview_err or "PreviewPiece missing before attach"))
    end
    pending.preview = preview
    pending.bmc = bmc or pending.bmc
    trace_pending(pending, "current_preview_piece ok preview=" .. tostring(safe_short_name(preview)))

    trace_pending(pending, "sync_proxy_to_preview_once begin")
    local synced, sync_detail = sync_proxy_to_preview_once(pending)
    if not synced then
        return fail_pending_start(pending, "proxy spawned but visual attach init failed: " .. tostring(sync_detail))
    end
    trace_pending(pending, "sync_proxy_to_preview_once ok")
    trace_pending(pending, "attach_proxy_to_preview begin")
    local attached, attach_detail = attach_proxy_to_preview(entry, preview)
    if not attached then
        return fail_pending_start(pending, "proxy spawned but visual attach failed: " .. tostring(attach_detail))
    end
    trace_pending(pending, "attach_proxy_to_preview ok attach=" .. tostring(attach_detail)
        .. " proxy_" .. attachment_summary(entry.actor)
        .. " preview_" .. attachment_summary(preview))
    pending.attach_detail = attach_detail
    pending.preview_visuals = {}
    pending.preview_hidden = 0
    pending.phase = "finalize_wait"
    schedule_frames(PLACE_FINALIZE_DELAY_FRAMES, function() place_start_finalize(token) end)
end

place_start_finalize = function(token)
    local pending = active_pending(token)
    if not pending then return end
    if not is_valid(pending.target) then
        return fail_pending_start(pending, "target actor lost before finalize")
    end

    local hidden_ok = set_actor_hidden(pending.target, true)
    if not hidden_ok then
        return fail_pending_start(pending, "could not hide original target actor")
    end

    placement = {
        target = pending.target,
        target_name = pending.target_name,
        original_hidden = pending.original_hidden == true,
        preview = pending.preview,
        bmc = pending.bmc,
        host_piece = pending.host_piece,
        proxy_entry = pending.proxy_entry,
        preview_visuals = pending.preview_visuals or {},
        preview_hidden = pending.preview_hidden or 0,
        attach_detail = pending.attach_detail,
        root_from_mesh_offset = pending.root_from_mesh_offset,
        root_from_mesh_rotation = pending.root_from_mesh_rotation,
        source = pending.source,
        started_at = os.clock(),
    }
    placement_starting = nil
    pending.proxy_entry = nil

    pcall(function() feature_umg.toast("Proxy Placement: " .. pending.target_name, 1.5) end)
    print(string.format(
        "[RSDWTools.oculus.proxy.place] start target=%s source=%s host=%s proxy=%s attach=%s hidden_preview_components=%d root_from_mesh=(%.1f,%.1f,%.1f) root_from_mesh_rot=(%.1f,%.1f,%.1f)",
        tostring(pending.target_name),
        tostring(pending.source),
        tostring(pending.host_piece),
        tostring(placement.proxy_entry and placement.proxy_entry.proxy_name or "<proxy>"),
        tostring(pending.attach_detail),
        pending.preview_hidden or 0,
        pending.root_from_mesh_offset and pending.root_from_mesh_offset.X or 0,
        pending.root_from_mesh_offset and pending.root_from_mesh_offset.Y or 0,
        pending.root_from_mesh_offset and pending.root_from_mesh_offset.Z or 0,
        pending.root_from_mesh_rotation and pending.root_from_mesh_rotation.Pitch or 0,
        pending.root_from_mesh_rotation and pending.root_from_mesh_rotation.Yaw or 0,
        pending.root_from_mesh_rotation and pending.root_from_mesh_rotation.Roll or 0))
end

function attachgrab_flow.pending(token)
    local pending = attachgrab_flow.starting
    if not pending or pending.token ~= token then return nil end
    if pending.cancelled == true then return nil end
    if attachgrab then
        attachgrab_flow.starting = nil
        return nil
    end
    return pending
end

function attachgrab_flow.label(session)
    if not session then return "attachgrab inactive" end
    local attach_detail = compact_probe_error(session.attach_detail or "<none>")
    local entry = session.proxy_entry
    return string.format(
        "phase=%s target=%s proxy=%s kind=%s src_comp=%s mesh=%s mats=%s host=%s preview_valid=%s target_valid=%s hidden=%s attach=%s",
        tostring(session.phase or "active"),
        tostring(session.target_name or "<target>"),
        tostring(entry and entry.proxy_name or "<proxy>"),
        tostring(entry and entry.kind or "<kind>"),
        tostring(entry and entry.source_component_label or "<src>"),
        tostring(entry and entry.mesh_name or "<mesh>"),
        tostring(entry and entry.material_count or "<mats>"),
        tostring(session.host_piece or "<host>"),
        tostring(is_valid(session.preview)),
        tostring(is_valid(session.target)),
        tostring(session.target_hidden == true),
        tostring(attach_detail))
end

function attachgrab_flow.freeze_start(reason)
    local ok_mod, feature_oculus = pcall(require, "feature_oculus")
    if not ok_mod or type(feature_oculus) ~= "table" or type(feature_oculus.freeze_start) ~= "function" then
        return false, "camera.oculus.freeze.start unavailable: " .. tostring(feature_oculus)
    end
    local ok_call, ok_freeze, detail = pcall(function() return feature_oculus.freeze_start("fast") end)
    if not ok_call then
        return false, tostring(ok_freeze)
    end
    if ok_freeze ~= true then
        return false, tostring(detail)
    end
    print("[RSDWTools.oculus.proxy.attachgrab] freeze start " .. tostring(reason or "grab") .. " ; " .. tostring(detail))
    return true, tostring(detail)
end

function attachgrab_flow.freeze_stop(reason)
    local ok_mod, feature_oculus = pcall(require, "feature_oculus")
    if not ok_mod or type(feature_oculus) ~= "table" or type(feature_oculus.freeze_stop) ~= "function" then
        return false, "camera.oculus.freeze.stop unavailable: " .. tostring(feature_oculus)
    end
    local ok_call, ok_stop, detail = pcall(function() return feature_oculus.freeze_stop(tostring(reason or "attachgrab")) end)
    if not ok_call then
        print("[RSDWTools.oculus.proxy.attachgrab] freeze stop failed " .. tostring(reason or "grab") .. " ; " .. tostring(ok_stop))
        return false, tostring(ok_stop)
    end
    if ok_stop ~= true then
        print("[RSDWTools.oculus.proxy.attachgrab] freeze stop partial " .. tostring(reason or "grab") .. " ; " .. tostring(detail))
        return false, tostring(detail)
    end
    print("[RSDWTools.oculus.proxy.attachgrab] freeze stop " .. tostring(reason or "grab") .. " ; " .. tostring(detail))
    return true, tostring(detail)
end

function attachgrab_flow.schedule_confirm_freeze_stop(session)
    if not session then return "not scheduled" end
    local token = session.token
    local delay_ms = tonumber(attachgrab_flow.config.POST_CONFIRM_FREEZE_STOP_DELAY_MS) or 900
    feature_oculus_async.schedule_game_thread(delay_ms, function()
        if attachgrab_flow.token ~= token then
            print("[RSDWTools.oculus.proxy.attachgrab] delayed freeze stop skipped token changed")
            return
        end
        if attachgrab or attachgrab_flow.starting then
            print("[RSDWTools.oculus.proxy.attachgrab] delayed freeze stop skipped grab active")
            return
        end
        local ok_freeze, freeze_detail = attachgrab_flow.freeze_stop("attachgrab.confirm.delayed")
        if not ok_freeze then
            print("[RSDWTools.oculus.proxy.attachgrab] delayed freeze restore warning: " .. tostring(freeze_detail))
        end
    end)
    print("[RSDWTools.oculus.proxy.attachgrab] freeze stop delayed attachgrab.confirm ms=" .. tostring(delay_ms))
    return "delayed " .. tostring(delay_ms) .. "ms"
end

function attachgrab_flow.restore_original(session)
    if not session or not is_valid(session.target) then return end
    if session.original_actor_loc then
        pcall(function() feature_actor.move_actor(session.target, session.original_actor_loc) end)
    end
    if session.original_actor_rot then
        pcall(function() feature_actor.set_actor_rotation(session.target, session.original_actor_rot) end)
    end
    if session.original_actor_scale then
        pcall(function() feature_actor.set_actor_scale3d(session.target, session.original_actor_scale) end)
    end
    pcall(function() set_actor_hidden(session.target, session.original_hidden == true) end)
    session.target_hidden = session.original_hidden == true
end

function attachgrab_flow.cleanup(session, restore_original)
    if not session then return end
    if restore_original then
        attachgrab_flow.restore_original(session)
    elseif is_valid(session.target) then
        pcall(function() set_actor_hidden(session.target, session.original_hidden == true) end)
        session.target_hidden = session.original_hidden == true
    end
    destroy_proxy_entry(session.proxy_entry)
    exit_build_preview(session)
    local ok_freeze, freeze_detail = attachgrab_flow.freeze_stop("attachgrab.cleanup")
    session.freeze_stop_detail = tostring(freeze_detail)
    if not ok_freeze then
        print("[RSDWTools.oculus.proxy.attachgrab] cleanup freeze restore warning: " .. tostring(freeze_detail))
    end
end

function attachgrab_flow.fail(session, reason)
    if session and attachgrab_flow.starting and attachgrab_flow.starting.token == session.token then
        attachgrab_flow.starting = nil
    end
    attachgrab_flow.cleanup(session, true)
    print("[RSDWTools.oculus.proxy.attachgrab] start failed target="
        .. tostring(session and session.target_name or "<target>") .. " ; " .. tostring(reason))
end

function attachgrab_flow.scheduled(delay_ms, fn)
    return feature_oculus_async.schedule_game_thread(delay_ms, function()
        local ok, err = pcall(fn)
        if not ok then
            print("[RSDWTools.oculus.proxy.attachgrab] staged step failed: " .. tostring(err))
            if attachgrab_flow.starting then
                local pending = attachgrab_flow.starting
                attachgrab_flow.starting = nil
                attachgrab_flow.cleanup(pending, true)
            end
        end
    end)
end

function attachgrab_flow.schedule_frames(frames, fn)
    return feature_oculus_async.schedule_game_thread_after_frames(frames, function()
        local ok, err = pcall(fn)
        if not ok then
            print("[RSDWTools.oculus.proxy.attachgrab] staged frame failed: " .. tostring(err))
            if attachgrab_flow.starting then
                local pending = attachgrab_flow.starting
                attachgrab_flow.starting = nil
                attachgrab_flow.cleanup(pending, true)
            end
        end
    end)
end

function attachgrab_flow.compute_root_offsets(session, entry)
    session.root_from_mesh_offset = nil
    session.root_from_mesh_rotation = nil
    if not (session and entry and is_valid(entry.source_component)) then return end
    local source_component_xform = component_world_transform(entry.source_component)
    if not source_component_xform then return end
    if session.original_actor_loc and source_component_xform.loc then
        session.root_from_mesh_offset = vec_sub(session.original_actor_loc, source_component_xform.loc)
    end
    if session.original_actor_rot and source_component_xform.rot then
        session.root_from_mesh_rotation = rot_sub(session.original_actor_rot, source_component_xform.rot)
    end
end

function attachgrab_flow.resolve_host(session)
    if not session then return false, "no attachgrab session" end
    local host_piece = session.host_piece
    local ok_piece, piece_detail, piece_data = feature_build_preview.resolve_piece_arg(host_piece)
    if not ok_piece and session.using_default_host then
        local first_detail = piece_detail
        for _, fallback in ipairs(DEFAULT_PLACE_HOST_FALLBACKS) do
            local fallback_ok, fallback_detail, fallback_data = feature_build_preview.resolve_piece_arg(fallback)
            if fallback_ok then
                ok_piece = true
                piece_detail = fallback_detail
                piece_data = fallback_data
                host_piece = fallback
                session.host_piece = fallback
                break
            end
            piece_detail = tostring(first_detail) .. " ; fallback " .. tostring(fallback) .. ": " .. tostring(fallback_detail)
        end
    end
    if not ok_piece then
        return false, "could not resolve attachgrab host '" .. tostring(host_piece) .. "': " .. tostring(piece_detail)
    end
    session.piece_data = piece_data
    session.piece_detail = piece_detail
    return true, piece_detail
end


function attachgrab_flow.start_spawn(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    if not is_valid(pending.target) then
        return attachgrab_flow.fail(pending, "target actor is no longer valid before proxy spawn")
    end

    pending.phase = "spawn_proxy"
    print("[RSDWTools.oculus.proxy.attachgrab] proxy spawn begin target=" .. tostring(pending.target_name))
    local xform = actor_transform(pending.target)
    local entry, spawn_err = spawn_proxy_for_actor(pending.target, xform, "proxy.attachgrab")
    if not entry then
        return attachgrab_flow.fail(pending, tostring(spawn_err))
    end
    pending.proxy_entry = entry
    attachgrab_flow.compute_root_offsets(pending, entry)

    print(string.format(
        "[RSDWTools.oculus.proxy.attachgrab] proxy spawned target=%s proxy=%s root_from_mesh=(%.1f,%.1f,%.1f) root_rot=(%.1f,%.1f,%.1f)",
        tostring(pending.target_name),
        tostring(entry.proxy_name),
        pending.root_from_mesh_offset and pending.root_from_mesh_offset.X or 0,
        pending.root_from_mesh_offset and pending.root_from_mesh_offset.Y or 0,
        pending.root_from_mesh_offset and pending.root_from_mesh_offset.Z or 0,
        pending.root_from_mesh_rotation and pending.root_from_mesh_rotation.Pitch or 0,
        pending.root_from_mesh_rotation and pending.root_from_mesh_rotation.Yaw or 0,
        pending.root_from_mesh_rotation and pending.root_from_mesh_rotation.Roll or 0))
    pending.proxy_mesh_ready_attempts = 0
    attachgrab_flow.schedule_frames(attachgrab_flow.config.PROXY_MESH_READY_POLL_FRAMES, function() attachgrab_flow.wait_proxy_mesh_ready(token) end)
end

function attachgrab_flow.wait_proxy_mesh_ready(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    local entry = pending.proxy_entry
    if not entry or not is_valid(entry.actor) then
        return attachgrab_flow.fail(pending, "proxy actor lost before mesh-ready check")
    end

    pending.proxy_mesh_ready_attempts = (pending.proxy_mesh_ready_attempts or 0) + 1
    local ready, ready_detail = M._proxy_assign_mesh_verified(entry)
    if ready then
        pending.phase = "proxy_mesh_ready"
        print("[RSDWTools.oculus.proxy.attachgrab] proxy mesh ready target="
            .. tostring(pending.target_name)
            .. " attempt=" .. tostring(pending.proxy_mesh_ready_attempts)
            .. " ; " .. tostring(ready_detail))
        attachgrab_flow.schedule_frames(attachgrab_flow.config.ARM_DELAY_FRAMES, function() attachgrab_flow.wait_lifecycle(token) end)
        return
    end

    if pending.proxy_mesh_ready_attempts >= (tonumber(attachgrab_flow.config.PROXY_MESH_READY_MAX_ATTEMPTS) or 12) then
        return attachgrab_flow.fail(pending, "proxy mesh did not become readable: " .. tostring(ready_detail))
    end

    pending.phase = "proxy_mesh_wait"
    print("[RSDWTools.oculus.proxy.attachgrab] proxy mesh wait target="
        .. tostring(pending.target_name)
        .. " attempt=" .. tostring(pending.proxy_mesh_ready_attempts)
        .. " ; " .. tostring(ready_detail))
    attachgrab_flow.schedule_frames(attachgrab_flow.config.PROXY_MESH_READY_POLL_FRAMES, function() attachgrab_flow.wait_proxy_mesh_ready(token) end)
end

function attachgrab_flow.wait_lifecycle(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    if preview_swap_lifecycle_busy then
        pending.phase = "lifecycle_wait"
        if pending.lifecycle_wait_logged ~= true then
            pending.lifecycle_wait_logged = true
            print("[RSDWTools.oculus.proxy.attachgrab] lifecycle wait target=" .. tostring(pending.target_name)
                .. " reason=" .. tostring(preview_swap_lifecycle_reason or "busy"))
        end
        attachgrab_flow.scheduled(PREVIEW_SWAP_LIFECYCLE_POLL_MS, function() attachgrab_flow.wait_lifecycle(token) end)
        return
    end
    return attachgrab_flow.exit_before_build(token)
end

function attachgrab_flow.exit_before_build(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    if not is_valid(pending.proxy_entry and pending.proxy_entry.actor) then
        return attachgrab_flow.fail(pending, "proxy actor lost before build preview")
    end
    local ok_resolve, resolve_detail = attachgrab_flow.resolve_host(pending)
    if not ok_resolve then return attachgrab_flow.fail(pending, resolve_detail) end

    pending.phase = "exit_before_build"
    local ok_exit, exit_detail = feature_build_preview.exit_any_mode()
    if not ok_exit then return attachgrab_flow.fail(pending, exit_detail) end
    pending.exit_detail = exit_detail
    pending.phase = "exit_ready_wait"
    pending.exit_ready_attempts = 0
    print("[RSDWTools.oculus.proxy.attachgrab] exit requested target=" .. tostring(pending.target_name)
        .. " ; " .. tostring(resolve_detail) .. " ; " .. tostring(exit_detail))
    attachgrab_flow.scheduled(PREVIEW_SWAP_POLL_MS, function() attachgrab_flow.wait_exit_ready(token) end)
end

function attachgrab_flow.wait_exit_ready(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    pending.exit_ready_attempts = (pending.exit_ready_attempts or 0) + 1
    local ok_mode, info = feature_build_preview.current_mode_info()
    local preview_valid = ok_mode and is_valid(info.preview)
    local mode_id = ok_mode and info.mode_id or nil
    if ok_mode and not preview_valid and (mode_id == 0 or mode_id == 3) then
        return attachgrab_flow.enter_build(token)
    end
    if ok_mode and not preview_valid and mode_id == 1 then
        return attachgrab_flow.select_piece(token)
    end
    if pending.exit_ready_attempts >= PREVIEW_SWAP_EXIT_READY_MAX_ATTEMPTS then
        return attachgrab_flow.fail(pending, "timed out waiting for build mode exit"
            .. " mode=" .. tostring(ok_mode and info.mode or info)
            .. " mode_id=" .. tostring(mode_id or "?")
            .. " preview=" .. tostring(preview_valid))
    end
    pending.phase = "exit_ready_wait"
    attachgrab_flow.scheduled(PREVIEW_SWAP_POLL_MS, function() attachgrab_flow.wait_exit_ready(token) end)
end

function attachgrab_flow.enter_build(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    pending.phase = "enter_build"
    local ok_enter, enter_detail, bmc = feature_build_preview.force_enter_build_mode()
    if not ok_enter then return attachgrab_flow.fail(pending, enter_detail) end
    pending.bmc = bmc
    pending.enter_detail = enter_detail
    pending.phase = "enter_ready_wait"
    pending.enter_ready_attempts = 0
    attachgrab_flow.scheduled(PREVIEW_SWAP_POLL_MS, function() attachgrab_flow.wait_enter_ready(token) end)
end

function attachgrab_flow.wait_enter_ready(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    pending.enter_ready_attempts = (pending.enter_ready_attempts or 0) + 1
    local ok_mode, info = feature_build_preview.current_mode_info()
    local mode_id = ok_mode and info.mode_id or nil
    if ok_mode and mode_id == 1 then
        return attachgrab_flow.select_piece(token)
    end
    if pending.enter_ready_attempts >= PREVIEW_SWAP_ENTER_READY_MAX_ATTEMPTS then
        return attachgrab_flow.fail(pending, "timed out waiting for build selection mode"
            .. " mode=" .. tostring(ok_mode and info.mode or info)
            .. " mode_id=" .. tostring(mode_id or "?"))
    end
    pending.phase = "enter_ready_wait"
    attachgrab_flow.scheduled(PREVIEW_SWAP_POLL_MS, function() attachgrab_flow.wait_enter_ready(token) end)
end

function attachgrab_flow.select_piece(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    pending.phase = "select_piece"
    local ok_select, select_detail, preview, bmc = feature_build_preview.select_piece_data(pending.piece_data)
    if not ok_select then return attachgrab_flow.fail(pending, select_detail) end
    pending.preview = preview
    pending.bmc = bmc
    pending.select_detail = select_detail
    pending.phase = "preview_ready_wait"
    pending.preview_ready_attempts = 0
    print("[RSDWTools.oculus.proxy.attachgrab] select requested target=" .. tostring(pending.target_name)
        .. " preview=" .. tostring(is_valid(preview) and safe_short_name(preview) or "<missing>")
        .. " ; " .. tostring(select_detail))
    attachgrab_flow.scheduled(PREVIEW_SWAP_POLL_MS, function() attachgrab_flow.wait_preview_ready(token) end)
end

function attachgrab_flow.wait_preview_ready(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    pending.preview_ready_attempts = (pending.preview_ready_attempts or 0) + 1
    local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if is_valid(preview) then
        pending.preview = preview
        pending.bmc = bmc
        pending.phase = "preview_sample"
        pending.preview_sample_index = 1
        pending.preview_sample_loc = nil
        pending.preview_stable_count = 0
        print("[RSDWTools.oculus.proxy.attachgrab] preview ready target=" .. tostring(pending.target_name)
            .. " preview=" .. tostring(safe_short_name(preview)))
        return attachgrab_flow.sample_preview(token)
    end
    if pending.preview_ready_attempts >= PREVIEW_SWAP_PREVIEW_READY_MAX_ATTEMPTS then
        return attachgrab_flow.fail(pending, "timed out waiting for PreviewPiece after selecting host: " .. tostring(preview_err))
    end
    pending.phase = "preview_ready_wait"
    attachgrab_flow.scheduled(PREVIEW_SWAP_POLL_MS, function() attachgrab_flow.wait_preview_ready(token) end)
end

function attachgrab_flow.sample_preview(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    local sample_index = pending.preview_sample_index or 1
    local sample_frame = attachgrab_flow.config.SAMPLE_FRAMES[sample_index] or 0
    local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then
        pending.bmc = bmc or pending.bmc
        return attachgrab_flow.fail(pending, tostring(preview_err or "PreviewPiece missing during sample"))
    end
    pending.preview = preview
    pending.bmc = bmc or pending.bmc

    local xform, xform_err = actor_world_transform(preview)
    if not xform then
        return attachgrab_flow.fail(pending, "could not read sampled PreviewPiece transform: " .. tostring(xform_err))
    end
    local delta = loc_delta(xform.loc, pending.preview_sample_loc)
    if delta and delta <= attachgrab_flow.config.STABLE_THRESHOLD_CM then
        pending.preview_stable_count = (pending.preview_stable_count or 0) + 1
    else
        pending.preview_stable_count = 0
    end
    pending.preview_sample_loc = copy_loc(xform.loc)
    print(string.format(
        "[RSDWTools.oculus.proxy.attachgrab] sample target=%s frame=%s preview=%s loc=(%.1f,%.1f,%.1f) rot=(P%.1f,Y%.1f,R%.1f) moved=%.2f stable=%d",
        tostring(pending.target_name),
        tostring(sample_frame),
        tostring(safe_short_name(preview)),
        xform.loc and xform.loc.X or 0,
        xform.loc and xform.loc.Y or 0,
        xform.loc and xform.loc.Z or 0,
        xform.rot and xform.rot.Pitch or 0,
        xform.rot and xform.rot.Yaw or 0,
        xform.rot and xform.rot.Roll or 0,
        delta or 0,
        pending.preview_stable_count or 0))

    if sample_index < #attachgrab_flow.config.SAMPLE_FRAMES then
        local next_frame = attachgrab_flow.config.SAMPLE_FRAMES[sample_index + 1]
        local delay = math.max(1, (next_frame or sample_frame + 1) - sample_frame)
        pending.preview_sample_index = sample_index + 1
        attachgrab_flow.schedule_frames(delay, function() attachgrab_flow.sample_preview(token) end)
        return
    end

    pending.phase = "attach_wait"
    attachgrab_flow.schedule_frames(attachgrab_flow.config.ATTACH_DELAY_FRAMES, function() attachgrab_flow.attach_preview(token) end)
end

function attachgrab_flow.attach_preview(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    local entry = pending.proxy_entry
    if not entry or not is_valid(entry.actor) then
        return attachgrab_flow.fail(pending, "proxy actor lost before attach")
    end
    local preview, bmc, _pc, preview_err = feature_build_preview.current_preview_piece()
    if not is_valid(preview) then
        pending.bmc = bmc or pending.bmc
        return attachgrab_flow.fail(pending, tostring(preview_err or "PreviewPiece missing before attach"))
    end
    pending.preview = preview
    pending.bmc = bmc or pending.bmc
    pending.phase = "attach_preview"

    local synced, sync_detail = sync_proxy_to_preview_once(pending)
    if not synced then
        return attachgrab_flow.fail(pending, "proxy move-to-preview failed: " .. tostring(sync_detail))
    end
    local attached, attach_detail = attach_proxy_to_preview(entry, preview, true)
    if not attached then
        return attachgrab_flow.fail(pending, "proxy attach failed: " .. tostring(attach_detail))
    end
    make_proxy_renderable(entry.actor, entry.component)
    pending.attach_detail = attach_detail
    pending.phase = "hide_target"
    local hidden_ok = set_actor_hidden(pending.target, true)
    if not hidden_ok then
        return attachgrab_flow.fail(pending, "could not hide original target actor after attach")
    end
    pending.target_hidden = true
    print("[RSDWTools.oculus.proxy.attachgrab] attached target=" .. tostring(pending.target_name)
        .. " proxy=" .. tostring(entry.proxy_name)
        .. " preview=" .. tostring(safe_short_name(preview))
        .. " attach=" .. tostring(attach_detail))
    attachgrab_flow.schedule_frames(attachgrab_flow.config.FINALIZE_DELAY_FRAMES, function() attachgrab_flow.finalize(token) end)
end

function attachgrab_flow.finalize(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    attachgrab = {
        token = pending.token,
        target = pending.target,
        target_name = pending.target_name,
        source = pending.source,
        host_piece = pending.host_piece,
        piece_detail = pending.piece_detail,
        preview = pending.preview,
        bmc = pending.bmc,
        proxy_entry = pending.proxy_entry,
        attach_detail = pending.attach_detail,
        original_hidden = pending.original_hidden == true,
        target_hidden = pending.target_hidden == true,
        original_actor_loc = copy_loc(pending.original_actor_loc),
        original_actor_rot = copy_rot(pending.original_actor_rot),
        original_actor_scale = copy_scale(pending.original_actor_scale),
        root_from_mesh_offset = pending.root_from_mesh_offset,
        root_from_mesh_rotation = pending.root_from_mesh_rotation,
        phase = "active",
        started_at = pending.started_at,
    }
    pending.proxy_entry = nil
    attachgrab_flow.starting = nil
    print("[RSDWTools.oculus.proxy.attachgrab] active " .. attachgrab_flow.label(attachgrab))
end

function attachgrab_flow.start_for_actor(actor, source, args_str)
    if attachgrab or attachgrab_flow.starting then
        return false, "attachgrab already active or starting ; confirm/cancel it first"
    end
    if feature_grab.is_active and feature_grab.is_active() then
        return false, "release the current grab before starting attachgrab"
    end
    if not is_valid(actor) then return false, "invalid attachgrab target" end
    local safe_ok, safe_detail = feature_grab.validate_target_safety(actor, "attachgrab")
    if not safe_ok then return false, tostring(safe_detail) end

    local requested_host = trim(args_str)
    local using_default_host = requested_host == ""
    local host_piece = using_default_host and DEFAULT_PLACE_HOST_PIECE or requested_host
    local target_root = actor_world_transform(actor) or actor_transform(actor)

    attachgrab_flow.token = attachgrab_flow.token + 1
    local token = attachgrab_flow.token
    attachgrab_flow.starting = {
        token = token,
        target = actor,
        target_name = safe_short_name(actor),
        source = source or "reticle",
        host_piece = host_piece,
        using_default_host = using_default_host,
        original_hidden = read_actor_hidden(actor),
        target_hidden = false,
        original_actor_loc = copy_loc(target_root.loc),
        original_actor_rot = copy_rot(target_root.rot),
        original_actor_scale = copy_scale(target_root.scale),
        phase = "queued",
        started_at = os.clock(),
    }

    print("[RSDWTools.oculus.proxy.attachgrab] start queued target="
        .. tostring(attachgrab_flow.starting.target_name)
        .. " source=" .. tostring(source)
        .. " host=" .. tostring(host_piece)
        .. " safety=" .. tostring(safe_detail))
    attachgrab_flow.schedule_frames(attachgrab_flow.config.START_DELAY_FRAMES, function() attachgrab_flow.start_spawn(token) end)
    return true, "start queued target=" .. tostring(attachgrab_flow.starting.target_name)
        .. " host=" .. tostring(host_piece)
end

function attachgrab_flow.finish_pretarget_pick(token)
    local pending = attachgrab_flow.pending(token)
    if not pending then return end
    pending.phase = "pretarget_pick"
    print("[RSDWTools.oculus.proxy.attachgrab] pretarget pick begin")

    local pick = feature_grab.pick_trace_target_under_reticle or feature_grab.pick_target_under_reticle
    local actor, _loc, source, err = pick()
    if not is_valid(actor) then
        return attachgrab_flow.fail(pending, tostring(err or "no actor under reticle"))
    end

    local safe_ok, safe_detail = feature_grab.validate_target_safety(actor, "attachgrab")
    if not safe_ok then return attachgrab_flow.fail(pending, tostring(safe_detail)) end

    local target_root = actor_world_transform(actor) or actor_transform(actor)
    if not target_root or not target_root.loc or not target_root.rot or not target_root.scale then
        return attachgrab_flow.fail(pending, "could not read target transform after pretarget pick")
    end

    pending.target = actor
    pending.target_name = safe_short_name(actor)
    pending.source = source or "reticle"
    pending.original_hidden = read_actor_hidden(actor)
    pending.target_hidden = false
    pending.original_actor_loc = copy_loc(target_root.loc)
    pending.original_actor_rot = copy_rot(target_root.rot)
    pending.original_actor_scale = copy_scale(target_root.scale)
    pending.phase = "queued"

    print("[RSDWTools.oculus.proxy.attachgrab] start queued target="
        .. tostring(pending.target_name)
        .. " source=" .. tostring(pending.source)
        .. " host=" .. tostring(pending.host_piece)
        .. " safety=" .. tostring(safe_detail))
    attachgrab_flow.schedule_frames(attachgrab_flow.config.START_DELAY_FRAMES, function() attachgrab_flow.start_spawn(token) end)
end

function M.attachgrab_start(args_str)
    if attachgrab or attachgrab_flow.starting then
        return false, "attachgrab already active or starting ; confirm/cancel it first"
    end
    if feature_grab.is_active and feature_grab.is_active() then
        return false, "release the current grab before starting attachgrab"
    end
    local ok_freeze, freeze_detail = attachgrab_flow.freeze_start("pretarget")
    if not ok_freeze then
        return false, "could not freeze world for grab: " .. tostring(freeze_detail)
    end

    local requested_host = trim(args_str)
    local using_default_host = requested_host == ""
    local host_piece = using_default_host and DEFAULT_PLACE_HOST_PIECE or requested_host
    attachgrab_flow.token = attachgrab_flow.token + 1
    local token = attachgrab_flow.token
    attachgrab_flow.starting = {
        token = token,
        target = nil,
        target_name = "<reticle>",
        source = "reticle",
        host_piece = host_piece,
        using_default_host = using_default_host,
        original_hidden = false,
        target_hidden = false,
        phase = "pretarget_wait",
        started_at = os.clock(),
    }
    local delay_frames = tonumber(attachgrab_flow.config.PRETARGET_DELAY_FRAMES) or 8
    print("[RSDWTools.oculus.proxy.attachgrab] pretarget wait frames=" .. tostring(delay_frames)
        .. " host=" .. tostring(host_piece))
    attachgrab_flow.schedule_frames(delay_frames, function() attachgrab_flow.finish_pretarget_pick(token) end)
    return true, "start queued reticle host=" .. tostring(host_piece)
        .. " pretarget_delay_frames=" .. tostring(delay_frames)
end

function M.attachgrab_start_actor(actor, source, args_str)
    if attachgrab or attachgrab_flow.starting then
        return false, "attachgrab already active or starting ; confirm/cancel it first"
    end
    if feature_grab.is_active and feature_grab.is_active() then
        return false, "release the current grab before starting attachgrab"
    end
    local ok_freeze, freeze_detail = attachgrab_flow.freeze_start("pretarget")
    if not ok_freeze then
        return false, "could not freeze world for grab: " .. tostring(freeze_detail)
    end
    local ok, detail = attachgrab_flow.start_for_actor(actor, source or "actor", args_str or "")
    if not ok then
        attachgrab_flow.freeze_stop("attachgrab.start_actor_failed")
    end
    return ok, detail
end

function M.attachgrab_confirm()
    if attachgrab_flow.starting then
        return true, "attachgrab still starting " .. attachgrab_flow.label(attachgrab_flow.starting)
    end
    local session = attachgrab
    if not session then return false, "no active attachgrab" end
    if not is_valid(session.target) then
        attachgrab = nil
        attachgrab_flow.cleanup(session, false)
        return false, "target actor is no longer valid"
    end

    local xform, source = target_transform_from_proxy(session)
    if not xform then
        attachgrab = nil
        attachgrab_flow.cleanup(session, true)
        return false, "could not read final PreviewPiece/proxy transform: " .. tostring(source)
    end

    attachgrab = nil
    destroy_proxy_entry(session.proxy_entry)
    exit_build_preview(session)
    local moved, move_detail = move_target_once(session.target, xform)
    if is_valid(session.target) then
        pcall(function() set_actor_hidden(session.target, session.original_hidden == true) end)
    end
    mark_preview_swap_settle("attachgrab.confirm")
    if not moved then
        local ok_freeze, freeze_detail = attachgrab_flow.freeze_stop("attachgrab.confirm.failed")
        if not ok_freeze then
            print("[RSDWTools.oculus.proxy.attachgrab] confirm failed freeze restore warning: " .. tostring(freeze_detail))
        end
        return false, tostring(move_detail)
    end
    local freeze_detail = attachgrab_flow.schedule_confirm_freeze_stop(session)

    print(string.format(
        "[RSDWTools.oculus.proxy.attachgrab] confirm target=%s host=%s source=%s loc=(%.1f,%.1f,%.1f) rot=(P%.1f,Y%.1f,R%.1f)",
        tostring(session.target_name),
        tostring(session.host_piece),
        tostring(source),
        xform.loc and xform.loc.X or 0,
        xform.loc and xform.loc.Y or 0,
        xform.loc and xform.loc.Z or 0,
        xform.rot and xform.rot.Pitch or 0,
        xform.rot and xform.rot.Yaw or 0,
        xform.rot and xform.rot.Roll or 0))
    return true, "placed target=" .. tostring(session.target_name)
        .. " host=" .. tostring(session.host_piece)
        .. " source=" .. tostring(source)
        .. " " .. tostring(move_detail)
        .. " freeze=" .. tostring(freeze_detail)
end

function M.attachgrab_cancel()
    if attachgrab_flow.starting then
        local pending = attachgrab_flow.starting
        attachgrab_flow.starting = nil
        pending.cancelled = true
        attachgrab_flow.cleanup(pending, true)
        mark_preview_swap_settle("attachgrab.cancel_starting")
        print("[RSDWTools.oculus.proxy.attachgrab] cancel starting target=" .. tostring(pending.target_name))
        return true, "cancelled starting target=" .. tostring(pending.target_name)
    end
    local session = attachgrab
    attachgrab = nil
    if not session then return true, "no active attachgrab" end
    attachgrab_flow.cleanup(session, true)
    mark_preview_swap_settle("attachgrab.cancel")
    print("[RSDWTools.oculus.proxy.attachgrab] cancel target=" .. tostring(session.target_name))
    return true, "cancelled target=" .. tostring(session.target_name)
end

function M.attachgrab_status()
    local session = attachgrab_flow.starting or attachgrab
    local function detail_for(prefix)
        if not session then return prefix .. " active=0" end
        local detail = prefix .. " " .. attachgrab_flow.label(session)
        local proxy_actor = session.proxy_entry and session.proxy_entry.actor or nil
        local preview = session.preview
        local proxy_xform = nil
        local preview_xform = nil
        if is_valid(proxy_actor) then
            local ok_proxy, value = pcall(function() return actor_world_transform(proxy_actor) end)
            if ok_proxy then
                proxy_xform = value
            else
                detail = detail .. " proxy_xform_error=" .. compact_probe_error(value)
            end
        end
        if is_valid(preview) then
            local ok_preview, value = pcall(function() return actor_world_transform(preview) end)
            if ok_preview then
                preview_xform = value
            else
                detail = detail .. " preview_xform_error=" .. compact_probe_error(value)
            end
        end
        if proxy_xform and preview_xform then
            detail = detail .. string.format(
                " proxy_loc=(%.1f,%.1f,%.1f) proxy_scale=(%.2f,%.2f,%.2f) preview_loc=(%.1f,%.1f,%.1f) preview_scale=(%.2f,%.2f,%.2f) delta=%.2f",
                proxy_xform.loc and proxy_xform.loc.X or 0,
                proxy_xform.loc and proxy_xform.loc.Y or 0,
                proxy_xform.loc and proxy_xform.loc.Z or 0,
                proxy_xform.scale and proxy_xform.scale.X or 1,
                proxy_xform.scale and proxy_xform.scale.Y or 1,
                proxy_xform.scale and proxy_xform.scale.Z or 1,
                preview_xform.loc and preview_xform.loc.X or 0,
                preview_xform.loc and preview_xform.loc.Y or 0,
                preview_xform.loc and preview_xform.loc.Z or 0,
                preview_xform.scale and preview_xform.scale.X or 1,
                preview_xform.scale and preview_xform.scale.Y or 1,
                preview_xform.scale and preview_xform.scale.Z or 1,
                loc_delta(proxy_xform.loc, preview_xform.loc) or 0)
        end
        local entry = session.proxy_entry
        if entry and is_valid(entry.source_component) then
            detail = detail .. " src_" .. render_flag_summary(entry.source_component)
        end
        if entry and is_valid(entry.component) then
            detail = detail .. " proxy_" .. render_flag_summary(entry.component)
        end
        if is_valid(proxy_actor) then
            local ok_summary, value = pcall(function() return attachment_summary(proxy_actor) end)
            detail = detail .. " proxy_"
                .. tostring(ok_summary and value or ("attach_summary_error=" .. compact_probe_error(value)))
        end
        if is_valid(preview) then
            local ok_summary, value = pcall(function() return attachment_summary(preview) end)
            detail = detail .. " preview_"
                .. tostring(ok_summary and value or ("attach_summary_error=" .. compact_probe_error(value)))
        end
        return detail
    end
    if attachgrab_flow.starting then
        return true, detail_for("attachgrab starting=1")
    end
    if attachgrab then
        return true, detail_for("attachgrab active=1")
    end
    return true, "attachgrab active=0"
end

local function place_start_for_actor(actor, source, args_str)
    if placement or placement_starting then
        return false, "proxy placement already active or starting ; confirm or cancel it first"
    end

    if not is_valid(actor) then return false, "invalid proxy placement target" end
    local requested_host = trim(args_str)
    local using_default_host = requested_host == ""
    local host_piece = using_default_host and DEFAULT_PLACE_HOST_PIECE or requested_host
    local target_name = safe_short_name(actor)

    placement_start_token = placement_start_token + 1
    local token = placement_start_token
    placement_starting = {
        token = token,
        target = actor,
        target_name = target_name,
        source = source,
        host_piece = host_piece,
        using_default_host = using_default_host,
        original_hidden = read_actor_hidden(actor),
        original_actor_loc = feature_actor.actor_location(actor),
        original_actor_rot = feature_actor.actor_rotation(actor),
        phase = "queued",
        started_at = os.clock(),
    }

    print(string.format("[RSDWTools.oculus.proxy.place] start queued target=%s source=%s host=%s",
        tostring(target_name), tostring(source), tostring(host_piece)))
    schedule_frames(PLACE_ARM_DELAY_FRAMES, function() place_start_spawn(token) end)
    return true, string.format("start queued target=%s host=%s", tostring(target_name), tostring(host_piece))
end

function M.place_start(args_str)
    local actor, _loc, source, err = feature_grab.pick_target_under_reticle()
    if not is_valid(actor) then return false, tostring(err or "no actor under reticle") end
    return place_start_for_actor(actor, source or "reticle", args_str)
end

function M.place_start_actor(actor, source, args_str)
    return place_start_for_actor(actor, source or "actor", args_str)
end

function M.place_toggle()
    if placement then return M.place_confirm() end
    return M.place_start("")
end

function M.place_confirm()
    if attachgrab_flow.starting or attachgrab then
        return M.attachgrab_confirm()
    end
    if preview_move then
        return M.preview_move_confirm()
    end
    if preview_swap_starting or preview_swap then
        return M.preview_swap_confirm()
    end
    local session = placement
    if not session and placement_starting then
        return true, "proxy placement still starting phase=" .. tostring(placement_starting.phase or "queued")
    end
    if not session then return false, "no active proxy placement" end

    local _preview_xform, xform_err = current_preview_transform(session)
    local xform, proxy_source = target_transform_from_proxy(session)
    if not xform then
        placement = nil
        restore_target_visibility(session)
        cleanup_placement(session, true)
        return false, "could not read final proxy transform: " .. tostring(proxy_source or xform_err)
    end

    restore_target_visibility(session)
    placement = nil
    cleanup_placement(session, false)
    local moved, move_detail = move_target_once(session.target, xform)
    if not moved then
        return false, tostring(move_detail)
    end

    print(string.format(
        "[RSDWTools.oculus.proxy.place] confirm target=%s source=%s loc=(%.1f,%.1f,%.1f) rot=(P%.1f,Y%.1f,R%.1f)",
        tostring(session.target_name),
        tostring(proxy_source),
        xform.loc.X or 0,
        xform.loc.Y or 0,
        xform.loc.Z or 0,
        xform.rot.Pitch or 0,
        xform.rot.Yaw or 0,
        xform.rot.Roll or 0))
    pcall(function() feature_umg.toast("Proxy Placed: " .. tostring(session.target_name), 1.3) end)
    return true, string.format("placed target=%s host=%s %s",
        tostring(session.target_name),
        tostring(session.host_piece),
        tostring(move_detail))
end

function M.place_cancel()
    if attachgrab_flow.starting or attachgrab then
        return M.attachgrab_cancel()
    end
    if preview_move then
        return M.preview_move_cancel()
    end
    if preview_swap_starting or preview_swap then
        return M.preview_swap_cancel()
    end
    if placement_starting then
        local pending = placement_starting
        placement_starting = nil
        pending.cancelled = true
        destroy_proxy_entry(pending.proxy_entry)
        exit_build_preview(pending)
        print("[RSDWTools.oculus.proxy.place] cancel starting target=" .. tostring(pending.target_name))
        return true, "cancelled starting target=" .. tostring(pending.target_name)
    end
    local session = placement
    if not session then return true, "no active proxy placement" end
    placement = nil
    restore_target_visibility(session)
    cleanup_placement(session, true)
    print("[RSDWTools.oculus.proxy.place] cancel target=" .. tostring(session.target_name))
    pcall(function() feature_umg.toast("Proxy Placement Cancelled", 1.2) end)
    return true, "cancelled target=" .. tostring(session.target_name)
end

function M.place_status()
    if attachgrab_flow.starting or attachgrab then
        return M.attachgrab_status()
    end
    if preview_move then
        return M.preview_move_status()
    end
    if preview_swap_starting or preview_swap then
        return M.preview_swap_status()
    end
    if placement_starting then
        return true, string.format(
            "proxy placement starting=1 phase=%s target=%s host=%s preview_valid=%s target_valid=%s",
            tostring(placement_starting.phase or "queued"),
            tostring(placement_starting.target_name),
            tostring(placement_starting.host_piece),
            tostring(is_valid(placement_starting.preview)),
            tostring(is_valid(placement_starting.target)))
    end
    if not placement then
        return true, "proxy placement active=0"
    end
    local session = placement
    return true, string.format(
        "proxy placement active=1 target=%s proxy=%s host=%s preview_valid=%s target_valid=%s attach=%s",
        tostring(session.target_name),
        tostring(session.proxy_entry and session.proxy_entry.proxy_name or "<proxy>"),
        tostring(session.host_piece),
        tostring(is_valid(session.preview)),
        tostring(is_valid(session.target)),
        tostring(session.attach_detail))
end

function M.is_active()
    return attachgrab ~= nil or attachgrab_flow.starting ~= nil
        or preview_move ~= nil or preview_swap ~= nil or preview_swap_starting ~= nil
        or placement ~= nil or placement_starting ~= nil
end

function M.is_modal_active()
    return M.is_active()
end

function M.current_actor()
    if attachgrab and is_valid(attachgrab.target) then
        return attachgrab.target, attachgrab.target_name, "proxy.attachgrab"
    end
    if attachgrab_flow.starting and is_valid(attachgrab_flow.starting.target) then
        return attachgrab_flow.starting.target, attachgrab_flow.starting.target_name, "proxy.attachgrab.starting"
    end
    if preview_move and is_valid(preview_move.target) then
        return preview_move.target, preview_move.target_name, "preview.move"
    end
    if preview_swap and is_valid(preview_swap.target) then
        return preview_swap.target, preview_swap.target_name, "preview.swap"
    end
    if preview_swap_starting and is_valid(preview_swap_starting.target) then
        return preview_swap_starting.target, preview_swap_starting.target_name, "preview.swap.starting"
    end
    if placement and is_valid(placement.target) then
        return placement.target, placement.target_name, "proxy.place"
    end
    if placement_starting and is_valid(placement_starting.target) then
        return placement_starting.target, placement_starting.target_name, "proxy.place.starting"
    end
    return nil
end

function M.help_details()
    if attachgrab_flow.starting then return "Starting Build Preview grab" end
    if attachgrab then return "Move actor with Build Preview" end
    if preview_move then
        if preview_move.phase ~= "active" then return "Starting Build Preview grab" end
        return "Move actor with triangle preview"
    end
    if preview_swap_starting then return "Starting Build Preview grab" end
    if preview_swap then return "Move actor with Build Preview" end
    if placement_starting then return "Starting Build Preview placement" end
    if not placement then return "" end
    return "Move actor with Build Preview"
end

function M.status()
    local live = 0
    local parts = {}
    for i, entry in ipairs(proxies) do
        if entry and is_valid(entry.actor) then
            live = live + 1
            parts[#parts + 1] = string.format("#%d %s -> %s [%s]",
                i,
                tostring(safe_short_name(entry.actor)),
                tostring(entry.target_name or "<target>"),
                tostring(entry.kind or "?"))
        end
    end
    if #parts == 0 then
        if attachgrab_flow.starting or attachgrab then
            local ok, detail = M.attachgrab_status()
            return ok, tostring(detail) .. " ; detached proxies live=0"
        end
        if preview_move then
            local ok, detail = M.preview_move_status()
            return ok, tostring(detail) .. " ; detached proxies live=0"
        end
        if preview_swap_starting or preview_swap then
            local ok, detail = M.preview_swap_status()
            return ok, tostring(detail) .. " ; detached proxies live=0"
        end
        if placement_starting then
            local ok, detail = M.place_status()
            return ok, tostring(detail) .. " ; detached proxies live=0"
        end
        if placement then
            local ok, detail = M.place_status()
            return ok, tostring(detail) .. " ; detached proxies live=0"
        end
        return true, "detached proxies live=0"
    end
    local prefix = ""
    if attachgrab_flow.starting or attachgrab then
        local _ok, detail = M.attachgrab_status()
        prefix = tostring(detail) .. " ; "
    end
    if preview_swap_starting or preview_swap then
        local _ok, detail = M.preview_swap_status()
        prefix = tostring(detail) .. " ; "
    end
    if placement_starting or placement then
        local _ok, detail = M.place_status()
        prefix = tostring(detail) .. " ; "
    end
    return true, prefix .. "detached proxies live=" .. tostring(live) .. " " .. table.concat(parts, "; ")
end

return M
