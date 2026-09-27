local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local feature_net = require("feature_net")

local cached_gameplay_statics = nil
local cached_widget_blueprint_library = nil
local cached_script_classes = {}

function M.trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

function M.is_valid(object)
    return feature_actor.is_valid_object(object)
end

function M.bool_word(value)
    return value and "on" or "off"
end

function M.parse_camera_view(value)
    local text = M.trim(value):lower()
    if text == "front" or text == "face" or text == "inspect" then return "front" end
    if text == "frontright" or text == "front-right" or text == "rightfront" then return "frontright" end
    if text == "frontleft" or text == "front-left" or text == "leftfront" then return "frontleft" end
    if text == "right" or text == "profile-right" then return "right" end
    if text == "left" or text == "profile-left" then return "left" end
    if text == "back" or text == "behind" or text == "follow" then return "back" end
    if text == "orbit" or text == "orbital" or text == "inspect-orbit" then return "orbit" end
    return nil
end

function M.normalize_yaw(yaw)
    yaw = tonumber(yaw) or 0.0
    while yaw > 180.0 do yaw = yaw - 360.0 end
    while yaw < -180.0 do yaw = yaw + 360.0 end
    return yaw
end

function M.parse_onoff(value)
    local text = M.trim(value):lower()
    if text == "" or text == "toggle" then return nil end
    if text == "on" or text == "1" or text == "true" or text == "yes" then return true end
    if text == "off" or text == "0" or text == "false" or text == "no" then return false end
    return "invalid"
end

function M.object_label(object)
    if not M.is_valid(object) then return "<invalid>" end
    local short_name = feature_actor.short_name_of(object)
    if short_name and short_name ~= "" then return short_name end
    local class_name = feature_field.class_name_of(object)
    return class_name or "<unnamed>"
end

function M.object_friendly_name(object)
    if not M.is_valid(object) then return "<invalid>" end
    if object.GetFName then
        local ok_name, fname = pcall(function() return object:GetFName() end)
        if ok_name and fname and fname.ToString then
            local ok_string, text = pcall(function() return fname:ToString() end)
            if ok_string and type(text) == "string" and text ~= "" then return text end
        end
    end
    return M.object_label(object)
end

function M.get_local_pawn()
    return feature_net.local_pawn()
end

function M.get_local_controller()
    return feature_net.local_controller()
end

function M.get_gameplay_statics()
    if M.is_valid(cached_gameplay_statics) then return cached_gameplay_statics end
    if not StaticFindObject then return nil end
    local ok_find, object = pcall(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
    if ok_find and M.is_valid(object) then
        cached_gameplay_statics = object
        return cached_gameplay_statics
    end
    return nil
end

function M.resolve_script_class(class_path)
    if cached_script_classes[class_path] and M.is_valid(cached_script_classes[class_path]) then
        return cached_script_classes[class_path]
    end
    if not StaticFindObject then return nil end
    local ok_find, class_object = pcall(StaticFindObject, class_path)
    if ok_find and M.is_valid(class_object) then
        cached_script_classes[class_path] = class_object
        return class_object
    end
    return nil
end

function M.get_controller(actor)
    if not M.is_valid(actor) then return nil end
    if actor.GetController then
        local ok_controller, controller = pcall(function() return actor:GetController() end)
        if ok_controller and M.is_valid(controller) then return controller end
    end
    local ok_field, controller = pcall(function() return actor.Controller end)
    if ok_field and M.is_valid(controller) then return controller end
    return nil
end

function M.get_brain_component(actor)
    local controller = M.get_controller(actor)
    if not M.is_valid(controller) then return nil end
    local ok_brain, brain = pcall(function() return controller.BrainComponent end)
    if ok_brain and M.is_valid(brain) then return brain end
    return nil
end

function M.get_movement_component(actor)
    if not M.is_valid(actor) then return nil end
    if actor.GetMovementComponent then
        local ok_component, component = pcall(function() return actor:GetMovementComponent() end)
        if ok_component and M.is_valid(component) then return component end
    end
    for unused_index, field_name in ipairs({ "AiMovementComponent", "AIMovementComponent", "CharacterMovement", "MovementComponent" }) do
        local ok_field, component = pcall(function() return actor[field_name] end)
        if ok_field and M.is_valid(component) then return component end
    end
    return nil
end

function M.get_actions_component(actor)
    if not M.is_valid(actor) then return nil end
    for unused_index, field_name in ipairs({ "DominionAIActionsComponent", "AIActionsComponent", "ActionsComponent" }) do
        local ok_field, component = pcall(function() return actor[field_name] end)
        if ok_field and M.is_valid(component) then return component end
    end
    return nil
end

function M.get_path_following_component(actor)
    local controller = M.get_controller(actor)
    if not M.is_valid(controller) then return nil end
    local ok_get, component = pcall(function() return controller:GetPathFollowingComponent() end)
    if ok_get and M.is_valid(component) then return component end
    local ok_field, field_component = pcall(function() return controller.PathFollowingComponent end)
    if ok_field and M.is_valid(field_component) then return field_component end
    return nil
end

function M.get_widget_blueprint_library()
    if M.is_valid(cached_widget_blueprint_library) then return cached_widget_blueprint_library end
    if not StaticFindObject then return nil end
    local ok_find, object = pcall(StaticFindObject, "/Script/UMG.Default__WidgetBlueprintLibrary")
    if ok_find and M.is_valid(object) then
        cached_widget_blueprint_library = object
        return cached_widget_blueprint_library
    end
    return nil
end

return M