-- feature_oculus.lua
--
-- Thin service layer for Dominion's native Oculus freecam/build modes.

local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local feature_ge = require("feature_ge")
local feature_net = require("feature_net")
local feature_ui = require("feature_ui")

local OCULUS_GE_CLASS = "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C"
local Visibility_VISIBLE = 0
local Visibility_COLLAPSED = 1
local Visibility_SELF_HIT_TEST_INVISIBLE = 4
local watermark_visible = nil

local DEFAULT_FREEZE_ENABLED = true
local DEFAULT_WORLD_DILATION = 0.000001
local DEFAULT_OCULUS_DILATION = 1000000.0
local FAST_OCULUS_DILATION = 3000000.0

local freeze_settings = {
    enabled = DEFAULT_FREEZE_ENABLED,
    world_dilation = DEFAULT_WORLD_DILATION,
    default_pawn_dilation = DEFAULT_OCULUS_DILATION,
    fast_pawn_dilation = FAST_OCULUS_DILATION,
}

local freeze_session = {
    active = false,
    original_world_dilation = nil,
    original_pawn_dilation = nil,
    pawn = nil,
    profile = "default",
}
local pause_policy = {
    manual_override = nil, -- nil=mode default, "paused"=force freeze, "live"=force unfreeze
    last_mode = nil,
    last_desired = nil,
}
local last_speed_args = "1200 4000 8000"

local MODE_NAMES = {
    [0] = "None",
    [1] = "Selection",
    [2] = "Placement",
    [3] = "RepairAndEdit",
}

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function trim(text)
    return tostring(text or ""):match("^%s*(.-)%s*$") or ""
end

local function split_args(text)
    local args = {}
    for token in trim(text):gmatch("%S+") do
        args[#args + 1] = token
    end
    return args
end

local function parse_enabled(raw)
    local text = trim(raw):lower()
    if text == "on" or text == "1" or text == "true" or text == "enable" or text == "enabled" then return true end
    if text == "off" or text == "0" or text == "false" or text == "disable" or text == "disabled" then return false end
    return nil
end

local function read_field(obj, field_name)
    if not is_valid(obj) then return nil end
    local ok, value = pcall(function() return obj[field_name] end)
    if ok then return value end
    return nil
end

local function write_field(obj, field_name, value)
    if not is_valid(obj) then return false, "invalid target for " .. tostring(field_name) end
    local ok, err = pcall(function() obj[field_name] = value end)
    if ok then return true end
    return false, tostring(err)
end

local function as_lua_float(value)
    local n = tonumber(value)
    if not n then return nil end
    -- UE4SS/Lua can preserve an integer-shaped number differently than a
    -- decimal-shaped one. Parse back from a decimal string so float UE fields
    -- receive a float-shaped Lua number even when config text says 1000000.0.
    return tonumber(string.format("%.6f", n)) or n
end

local function call0(obj, method_name)
    if not is_valid(obj) then return nil end
    local method = obj[method_name]
    if not method then return nil end
    local ok, value = pcall(function() return obj[method_name](obj) end)
    if ok then return value end
    return nil
end

local function label(obj)
    if not is_valid(obj) then return "<nil>" end
    local ok_name, name = pcall(function() return obj:GetName() end)
    if ok_name and type(name) == "string" and name ~= "" then return name end
    return tostring(obj)
end

local function full_name(obj)
    if not is_valid(obj) then return "" end
    local ok_name, name = pcall(function() return obj:GetFullName() end)
    if ok_name and type(name) == "string" then return name end
    return ""
end

local function is_live_instance(obj)
    if not is_valid(obj) then return false end
    local name = full_name(obj)
    return name ~= "" and not name:find("Default__", 1, true)
end

local function deref_weak(weak)
    if weak == nil then return nil end
    if is_valid(weak) then return weak end
    if type(weak) == "userdata" and weak.Get then
        local ok, resolved = pcall(function() return weak:Get() end)
        if ok and is_valid(resolved) then return resolved end
    end
    return nil
end

local function get_pawn()
    local pawn = feature_net.local_pawn()
    if is_valid(pawn) then return pawn, nil end
    return nil, "no local pawn"
end

local function get_controller()
    local controller = feature_net.local_controller()
    if is_valid(controller) then return controller, nil end
    return nil, "no local player controller"
end

local function get_oculus_component(pawn)
    local component = call0(pawn, "GetOculusComponent")
    if not is_valid(component) then component = read_field(pawn, "OculusComponent") end
    if is_valid(component) then return component, nil end
    return nil, "no OculusComponent"
end

local function get_oculus_pawn_from_component(component)
    local oculus_pawn = call0(component, "GetOculusPawn")
    if not is_valid(oculus_pawn) then oculus_pawn = read_field(component, "OculusPawn") end
    if is_valid(oculus_pawn) then return oculus_pawn end
    return nil
end

local function get_oculus_pawn(pawn, component)
    local oculus_pawn = get_oculus_pawn_from_component(component)
    if is_valid(oculus_pawn) then return oculus_pawn end

    local ok, resolved = pcall(function()
        local root = feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
        return root
    end)
    if ok and is_valid(resolved) then return resolved end
    return nil
end

local function oculus_active_detail()
    local pawn, pawn_err = get_pawn()
    if not pawn then return false, pawn_err, nil, nil, nil end

    if pawn.IsOculusActive then
        local ok_active, active = pcall(function() return pawn:IsOculusActive() end)
        if ok_active and type(active) == "boolean" then
            local component = get_oculus_component(pawn)
            local oculus_pawn = get_oculus_pawn(pawn, component)
            return active, "pawn:IsOculusActive", pawn, component, oculus_pawn
        end
    end

    local component, component_err = get_oculus_component(pawn)
    if component and component.IsOculusActive then
        local ok_component, active = pcall(function() return component:IsOculusActive() end)
        if ok_component and type(active) == "boolean" then
            return active, "OculusComponent:IsOculusActive", pawn, component, get_oculus_pawn(pawn, component)
        end
    end

    local oculus_pawn = get_oculus_pawn(pawn, component)
    if is_valid(oculus_pawn) then
        local ok_flag, active = pcall(function() return oculus_pawn.bOculusActive end)
        if ok_flag then return active == true, "OculusPawn.bOculusActive", pawn, component, oculus_pawn end
    end

    return false, component_err or "oculus state unavailable", pawn, component, oculus_pawn
end

local function get_build_mode_component()
    local controller, controller_err = get_controller()
    if not controller then return nil, controller_err, nil end

    local build_mode_component = read_field(controller, "BuildModeComponent")
    if not is_valid(build_mode_component) then
        build_mode_component = call0(controller, "GetBuildModeComponent")
    end
    if is_valid(build_mode_component) then return build_mode_component, nil, controller end
    return nil, "no BuildModeComponent on player controller", controller
end

local function coerce_build_mode(value)
    if type(value) == "number" then return math.floor(value) end
    local text = tostring(value or "")
    local numeric = tonumber(text)
    if numeric then return math.floor(numeric) end
    local lowered = text:lower()
    for mode_id, mode_name in pairs(MODE_NAMES) do
        if lowered:find(mode_name:lower(), 1, true) then return mode_id end
    end
    return nil
end

local function read_build_mode(build_mode_component)
    local raw_mode = read_field(build_mode_component, "CurrentBuildMode")
    local mode_id = coerce_build_mode(raw_mode)
    if mode_id == nil and build_mode_component and build_mode_component.GetCurrentBuildMode then
        local ok_mode, getter_mode = pcall(function() return build_mode_component:GetCurrentBuildMode() end)
        if ok_mode then
            raw_mode = getter_mode
            mode_id = coerce_build_mode(getter_mode)
        end
    end
    return mode_id, MODE_NAMES[mode_id] or tostring(raw_mode or "Unknown")
end

local function input_mode_name(controller)
    local current_input_mode = read_field(controller, "CurrentInputMode")
    if not is_valid(current_input_mode) then return "<nil>" end

    local known_modes = {
        { field = "OculusRepairModeInputMode", name = "OculusRepairMode" },
        { field = "OculusBuildModeInputMode", name = "OculusBuildMode" },
        { field = "OculusBuildMenuInputMode", name = "OculusBuildMenu" },
        { field = "RepairModeInputMode", name = "RepairMode" },
        { field = "BuildModeInputMode", name = "BuildMode" },
        { field = "BuildMenuInputMode", name = "BuildMenu" },
        { field = "GameplayInputMode", name = "Gameplay" },
    }

    for _, known_mode in ipairs(known_modes) do
        local candidate = read_field(controller, known_mode.field)
        if is_valid(candidate) and candidate == current_input_mode then return known_mode.name end
    end
    return label(current_input_mode)
end

local function build_state()
    local build_mode_component, build_err, controller = get_build_mode_component()
    if not build_mode_component then
        return {
            available = false,
            error = build_err,
            controller = controller,
            mode_id = nil,
            mode = "Unavailable",
            preview = false,
            repair = false,
            input_mode = input_mode_name(controller),
        }
    end

    local mode_id, mode_name = read_build_mode(build_mode_component)
    local preview_piece = deref_weak(read_field(build_mode_component, "PreviewPiece"))
    local placing_piece_data = deref_weak(read_field(build_mode_component, "CurrentlyPlacingPieceData"))
    -- Placement can use a lightweight piece in 1.0, with no PreviewPiece actor.
    local preview_active = mode_id == 2
    local repair_active = mode_id == 3

    return {
        available = true,
        controller = controller,
        build_mode_component = build_mode_component,
        mode_id = mode_id,
        mode = mode_name,
        preview = preview_active,
        repair = repair_active,
        selection = mode_id == 1,
        idle = mode_id == 0,
        preview_piece = preview_piece,
        placing_piece_data = placing_piece_data,
        input_mode = input_mode_name(controller),
    }
end

local function current_state()
    local active, active_source, pawn, component, oculus_pawn = oculus_active_detail()
    local state = build_state()
    state.oculus = active == true
    state.oculus_source = active_source
    state.pawn = pawn
    state.oculus_component = component
    state.oculus_pawn = oculus_pawn
    return state
end

local function state_line(state)
    return string.format(
        "oculus=%s source=%s mode=%s mode_id=%s preview=%s repair=%s input=%s preview_piece=%s oculus_pawn=%s",
        tostring(state.oculus == true),
        tostring(state.oculus_source or "unknown"),
        tostring(state.mode or "Unknown"),
        tostring(state.mode_id or "?"),
        tostring(state.preview == true),
        tostring(state.repair == true),
        tostring(state.input_mode or "<nil>"),
        label(state.preview_piece),
        label(state.oculus_pawn)
    )
end

local function require_active_state()
    local state = current_state()
    if state.oculus then return state, nil end
    return state, "oculus inactive; " .. state_line(state)
end

local function get_movement_component(oculus_pawn)
    local movement = read_field(oculus_pawn, "MovementComponent")
    if is_valid(movement) then return movement, nil end
    return nil, "no Oculus MovementComponent"
end

local function worldsettings()
    local ws, err = feature_field.resolve_root("worldsettings")
    if is_valid(ws) then return ws, nil end
    return nil, tostring(err or "worldsettings not live")
end

local function read_world_dilation()
    local ws, err = worldsettings()
    if not ws then return nil, err end
    local ok, value = pcall(function() return ws.TimeDilation end)
    if ok and tonumber(value) ~= nil then return tonumber(value), nil end
    return nil, "could not read WorldSettings.TimeDilation"
end

local function write_world_dilation(value)
    local n = as_lua_float(value)
    if not n or n <= 0 then return false, "WorldSettings.TimeDilation must be positive" end
    local value_text = string.format("%.6f", n)
    local ok, detail = feature_field.set("worldsettings TimeDilation " .. value_text)
    if ok then return true, n .. " via player.field.set worldsettings TimeDilation " .. value_text end

    local ok_world_path, path_detail = feature_field.set("world.PersistentLevel.WorldSettings TimeDilation " .. value_text)
    if ok_world_path then
        return true, n .. " via player.field.set world.PersistentLevel.WorldSettings TimeDilation " .. value_text
    end
    return false, "WorldSettings.TimeDilation write failed: worldsettings=" .. tostring(detail) .. "; world.PersistentLevel.WorldSettings=" .. tostring(path_detail)
end

local function read_pawn_dilation(oculus_pawn)
    if not is_valid(oculus_pawn) then return nil, "no Oculus pawn" end
    local ok, value = pcall(function() return oculus_pawn.CustomTimeDilation end)
    if ok and tonumber(value) ~= nil then return tonumber(value), nil end
    return nil, "could not read OculusPawn.CustomTimeDilation"
end

local function write_pawn_dilation(oculus_pawn, value)
    local n = as_lua_float(value)
    if not n or n <= 0 then return false, "OculusPawn.CustomTimeDilation must be positive" end
    if not is_valid(oculus_pawn) then return false, "no Oculus pawn" end
    local value_text = string.format("%.6f", n)
    local ok, detail = feature_field.set("pawn.OculusComponent.OculusPawn CustomTimeDilation " .. value_text)
    if ok then return true, n .. " via player.field.set pawn.OculusComponent.OculusPawn CustomTimeDilation " .. value_text end

    local ok_direct, werr = pcall(function() oculus_pawn.CustomTimeDilation = n end)
    if ok_direct then return true, n .. " via direct fallback; field_set=" .. tostring(detail) end
    return false, "OculusPawn.CustomTimeDilation write failed: " .. tostring(detail) .. "; direct=" .. tostring(werr)
end

local function dilation_for_profile(profile)
    if profile == "fast" then return freeze_settings.fast_pawn_dilation, "fast" end
    return freeze_settings.default_pawn_dilation, "default"
end

local function freeze_line()
    return string.format(
        "enabled=%s active=%s world=%.6g default=%.6g fast=%.6g profile=%s override=%s original_world=%s original_pawn=%s",
        tostring(freeze_settings.enabled == true),
        tostring(freeze_session.active == true),
        tonumber(freeze_settings.world_dilation) or DEFAULT_WORLD_DILATION,
        tonumber(freeze_settings.default_pawn_dilation) or DEFAULT_OCULUS_DILATION,
        tonumber(freeze_settings.fast_pawn_dilation) or FAST_OCULUS_DILATION,
        tostring(freeze_session.profile or "default"),
        tostring(pause_policy.manual_override or "auto"),
        tostring(freeze_session.original_world_dilation or "<nil>"),
        tostring(freeze_session.original_pawn_dilation or "<nil>")
    )
end

local function normalize_pause_mode(mode)
    local text = trim(mode):lower()
    if text == "" then return "active" end
    if text == "build" or text == "buildpreview" or text == "build_preview" then return "preview" end
    return text
end

local function mode_default_paused(mode)
    return false
end

local function pause_desired_for_mode(mode)
    if pause_policy.manual_override == "paused" then return "paused", "manual" end
    if pause_policy.manual_override == "live" then return "live", "manual" end
    if mode_default_paused(mode) then return "paused", "auto" end
    return "live", "auto"
end

local function parse_positive_number(raw, label_text)
    local value = tonumber(raw)
    if not value or value <= 0 then return nil, label_text .. " must be a positive number" end
    return value, nil
end

local function parse_onoff(raw)
    local text = trim(raw):lower()
    if text == "off" or text == "0" or text == "false" or text == "hide" or text == "hidden" or text == "disable" or text == "disabled" then return false end
    if text == "on" or text == "1" or text == "true" or text == "show" or text == "visible" or text == "enable" or text == "enabled" then return true end
    return nil
end

local function parse_color(raw)
    if not raw or raw == "" then return { R = 0, G = 0, B = 0, A = 0 } end
    local r, g, b, a = raw:match("^(%d+),(%d+),(%d+),(%d+)$")
    if not r then r, g, b = raw:match("^(%d+),(%d+),(%d+)$") end
    if not r then return nil, "color must be r,g,b or r,g,b,a" end
    local function clamp(v)
        v = tonumber(v) or 0
        if v < 0 then v = 0 end
        if v > 255 then v = 255 end
        return math.floor(v)
    end
    return { R = clamp(r), G = clamp(g), B = clamp(b), A = a and clamp(a) or 255 }, nil
end

local function get_vignette_api()
    local api, err = feature_field.resolve_root("subsystem:HUDUISubsystem.VignetteAPI")
    if is_valid(api) then return api, nil end

    local subsystem, subsystem_err = feature_field.resolve_root("subsystem:HUDUISubsystem")
    if not is_valid(subsystem) then return nil, err or subsystem_err or "HUDUISubsystem unavailable" end

    if subsystem.GetVignetteAPI then
        local ok, resolved = pcall(function() return subsystem:GetVignetteAPI() end)
        if ok and is_valid(resolved) then return resolved, nil end
    end

    local direct = read_field(subsystem, "VignetteAPI")
    if is_valid(direct) then return direct, nil end
    return nil, err or "VignetteAPI unavailable"
end

local function set_widget_visual_state(widget, visible)
    if not is_valid(widget) then return false end
    local changed = false
    local visibility = visible and Visibility_SELF_HIT_TEST_INVISIBLE or Visibility_COLLAPSED
    local opacity = visible and 1.0 or 0.0

    local ok_vis = pcall(function() widget:SetVisibility(visibility) end)
    if ok_vis then changed = true end
    local ok_opacity = pcall(function() widget.RenderOpacity = opacity end)
    if ok_opacity then changed = true end
    local ok_set_opacity = pcall(function()
        if widget.SetRenderOpacity then widget:SetRenderOpacity(opacity) end
    end)
    if ok_set_opacity then changed = true end
    return changed
end

local function read_widget_visible(widget)
    if not is_valid(widget) then return nil end
    local visibility = read_field(widget, "Visibility")
    if type(visibility) == "number" then
        return visibility == Visibility_VISIBLE or visibility == 3 or visibility == 4
    end
    local opacity = read_field(widget, "RenderOpacity")
    if type(opacity) == "number" then return opacity > 0.01 end
    return nil
end

local function current_watermark_visible()
    local gi_widget = feature_field.resolve_root("gameinstance.WatermarkWidget")
    local visible = read_widget_visible(gi_widget)
    if visible ~= nil then return visible end
    return watermark_visible
end

local function force_oculus_vignette_widget(visible)
    if not FindAllOf then return false, "FindAllOf unavailable" end

    local touched = 0
    local failures = {}
    for _, class_name in ipairs({ "WBP_HUD_OculusVignette_C", "OculusVignetteWidget" }) do
        local ok_find, widgets = pcall(FindAllOf, class_name)
        if not ok_find or not widgets then
            failures[#failures + 1] = class_name .. ": " .. tostring(widgets)
        else
            local count = 0
            pcall(function() count = #widgets end)
            if count == 0 then
                local ok_num, num = pcall(function() return widgets:Num() end)
                if ok_num and type(num) == "number" then count = num end
            end
            for i = 1, count do
                local ok_entry, widget = pcall(function() return widgets[i] end)
                if ok_entry and is_live_instance(widget) then
                    if set_widget_visual_state(widget, visible) then touched = touched + 1 end
                    for _, field in ipairs({ "HazeImage", "VignetteImage", "FlashImage" }) do
                        local child = read_field(widget, field)
                        if set_widget_visual_state(child, visible) then touched = touched + 1 end
                    end
                end
            end
        end
    end

    if touched > 0 then return true, "widgets=" .. tostring(touched) end
    return false, table.concat(failures, "; ")
end

local function force_watermark_widget(visible)
    local touched = 0
    local failures = {}
    local seen = {}

    local function touch(widget)
        if not is_valid(widget) then return end
        local name = full_name(widget)
        if name:find("Default__", 1, true) then return end
        local key = name ~= "" and name or tostring(widget)
        if seen[key] then return end
        seen[key] = true
        if set_widget_visual_state(widget, visible) then touched = touched + 1 end
    end

    local gi_widget, gi_err = feature_field.resolve_root("gameinstance.WatermarkWidget")
    if is_valid(gi_widget) then
        touch(gi_widget)
        touch(read_field(gi_widget, "VersionText"))
    else
        failures[#failures + 1] = "gameinstance.WatermarkWidget: " .. tostring(gi_err or "unavailable")
    end

    if FindAllOf then
        for _, class_name in ipairs({ "WBP_Watermark_C", "WatermarkWidget" }) do
            local ok_find, widgets = pcall(FindAllOf, class_name)
            if not ok_find or not widgets then
                failures[#failures + 1] = class_name .. ": " .. tostring(widgets)
            else
                local count = 0
                pcall(function() count = #widgets end)
                if count == 0 then
                    local ok_num, num = pcall(function() return widgets:Num() end)
                    if ok_num and type(num) == "number" then count = num end
                end
                for i = 1, count do
                    local ok_entry, widget = pcall(function() return widgets[i] end)
                    if ok_entry and is_live_instance(widget) then
                        touch(widget)
                        touch(read_field(widget, "VersionText"))
                    end
                end
            end
        end
    else
        failures[#failures + 1] = "FindAllOf unavailable"
    end

    if touched > 0 then return true, "watermark widgets=" .. tostring(touched) end
    return false, table.concat(failures, "; ")
end

local function read_motion_line(movement)
    return string.format(
        "speed=%s accel=%s decel=%s distance=%s falloff=%s",
        tostring(read_field(movement, "MaxSpeed") or "?"),
        tostring(read_field(movement, "Acceleration") or "?"),
        tostring(read_field(movement, "Deceleration") or "?"),
        tostring(read_field(movement, "MaxDistanceFromPlayer") or "?"),
        tostring(read_field(movement, "DistanceFromPlayerSpeedFalloffThreshold") or "?")
    )
end

function M.status()
    return true, state_line(current_state())
end

function M.freeze_settings(args_text)
    local args = split_args(args_text)
    if #args == 0 then return true, freeze_line() end

    local enabled = parse_enabled(args[1])
    if enabled == nil then
        return false, "usage: camera.oculus.freeze.settings <on|off> [worldDilation] [defaultPawnDilation] [fastPawnDilation]"
    end

    local world_dilation = args[2] and tonumber(args[2]) or freeze_settings.world_dilation
    local default_pawn = args[3] and tonumber(args[3]) or freeze_settings.default_pawn_dilation
    local fast_pawn = args[4] and tonumber(args[4]) or freeze_settings.fast_pawn_dilation
    if not world_dilation or world_dilation <= 0 then return false, "worldDilation must be positive" end
    if not default_pawn or default_pawn <= 0 then return false, "defaultPawnDilation must be positive" end
    if not fast_pawn or fast_pawn <= 0 then return false, "fastPawnDilation must be positive" end

    freeze_settings.enabled = enabled
    freeze_settings.world_dilation = world_dilation
    freeze_settings.default_pawn_dilation = default_pawn
    freeze_settings.fast_pawn_dilation = fast_pawn

    if not enabled and freeze_session.active then
        local ok_stop, stop_detail = M.freeze_stop("settings.off")
        if not ok_stop then return false, "settings saved; restore failed: " .. tostring(stop_detail) end
        return true, "settings saved; " .. tostring(stop_detail)
    elseif enabled and freeze_session.active then
        local state = current_state()
        local oculus_pawn = is_valid(state.oculus_pawn) and state.oculus_pawn or freeze_session.pawn
        local pawn_dilation = dilation_for_profile(freeze_session.profile)
        local ok_pawn, pawn_detail = write_pawn_dilation(oculus_pawn, pawn_dilation)
        local ok_speed, speed_detail = M.reapply_speed("freeze.settings")
        local ok_world, world_detail = write_world_dilation(world_dilation)
        return ok_world and ok_pawn,
            "settings saved; reapplied pawn=" .. tostring(pawn_detail) .. " speed=" .. tostring(ok_speed) .. ":" .. tostring(speed_detail) .. " world=" .. tostring(world_detail)
    end

    return true, "settings saved; " .. freeze_line()
end

function M.freeze_start(args_text)
    local args = split_args(args_text)
    local requested_profile = trim(args[1] or "")
    if requested_profile == "fast" or requested_profile == "default" then
        freeze_session.profile = requested_profile
    end

    if not freeze_settings.enabled then
        return true, "disabled; " .. freeze_line()
    end

    local state, state_err = require_active_state()
    if state_err then return false, state_err end
    local oculus_pawn = state.oculus_pawn
    if not is_valid(oculus_pawn) then return false, "no Oculus pawn; " .. state_line(state) end

    if not freeze_session.active then
        freeze_session.original_world_dilation = read_world_dilation() or 1.0
        freeze_session.original_pawn_dilation = read_pawn_dilation(oculus_pawn) or 1.0
        freeze_session.pawn = oculus_pawn
        freeze_session.profile = freeze_session.profile or "default"
        freeze_session.active = true
    end

    local pawn_dilation, profile = dilation_for_profile(freeze_session.profile)
    freeze_session.profile = profile
    local ok_pawn, pawn_detail = write_pawn_dilation(oculus_pawn, pawn_dilation)
    if not ok_pawn then return false, tostring(pawn_detail) end

    local speed_note = ""
    if type(M.reapply_speed) == "function" then
        local ok_speed, speed_detail = M.reapply_speed("freeze.start")
        speed_note = " speed=" .. tostring(ok_speed) .. ":" .. tostring(speed_detail)
    end

    local ok_world, world_detail = write_world_dilation(freeze_settings.world_dilation)
    if not ok_world then return false, tostring(world_detail) end

    return true, string.format("active=true world=%.6g pawn=%.6g profile=%s original_world=%s original_pawn=%s%s world_detail=%s pawn_detail=%s",
        tonumber(freeze_settings.world_dilation) or 0,
        tonumber(pawn_dilation) or 0,
        tostring(profile),
        tostring(freeze_session.original_world_dilation or "<nil>"),
        tostring(freeze_session.original_pawn_dilation or "<nil>"),
        speed_note,
        tostring(world_detail),
        tostring(pawn_detail)
    )
end

local function fmt_number(value)
    local n = tonumber(value)
    if not n then return tostring(value) end
    return string.format("%.15g", n)
end

local function reset_controller_input_locks()
    local controller = feature_net.local_controller()
    if not is_valid(controller) then return false, "no local controller" end

    if controller.SetIgnoreMoveInput then
        pcall(function() controller:SetIgnoreMoveInput(false) end)
    end
    if controller.ResetIgnoreMoveInput then
        pcall(function() controller:ResetIgnoreMoveInput() end)
    end
    if controller.SetIgnoreLookInput then
        pcall(function() controller:SetIgnoreLookInput(false) end)
    end
    if controller.ResetIgnoreLookInput then
        pcall(function() controller:ResetIgnoreLookInput() end)
    end

    return true, "input locks reset"
end

function M.freeze_stop(_args_text)
    if not freeze_session.active then
        return true, "already inactive; " .. freeze_line()
    end

    local notes = {}
    local restore_world = tonumber(freeze_session.original_world_dilation) or 1.0
    local ok_world, world_detail = write_world_dilation(restore_world)
    notes[#notes + 1] = "world=" .. tostring(ok_world) .. ":" .. tostring(world_detail)

    local state = current_state()
    local oculus_pawn = is_valid(state.oculus_pawn) and state.oculus_pawn or freeze_session.pawn
    local restore_pawn = tonumber(freeze_session.original_pawn_dilation) or 1.0
    local ok_pawn, pawn_detail = write_pawn_dilation(oculus_pawn, restore_pawn)
    notes[#notes + 1] = "pawn=" .. tostring(ok_pawn) .. ":" .. tostring(pawn_detail)

    freeze_session.active = false
    freeze_session.original_world_dilation = nil
    freeze_session.original_pawn_dilation = nil
    freeze_session.pawn = nil
    freeze_session.profile = "default"

    if ok_world and ok_pawn then return true, "restored " .. table.concat(notes, " ; ") end
    return false, "restore partial " .. table.concat(notes, " ; ")
end

function M.freeze_speed(args_text)
    local arg = trim(args_text)
    if arg == "" then return true, "profile=" .. tostring(freeze_session.profile or "default") .. "; " .. freeze_line() end

    local profile = nil
    local dilation = tonumber(arg)
    if arg:lower() == "fast" then
        profile = "fast"
        dilation = freeze_settings.fast_pawn_dilation
    elseif arg:lower() == "default" or arg:lower() == "normal" then
        profile = "default"
        dilation = freeze_settings.default_pawn_dilation
    elseif dilation and dilation > 0 then
        profile = "custom"
    else
        return false, "usage: camera.oculus.freeze.speed <default|fast|positiveCustomDilation>"
    end

    freeze_session.profile = profile
    if not freeze_session.active then return true, "queued profile=" .. profile .. " dilation=" .. tostring(dilation) end

    local state, state_err = require_active_state()
    if state_err then return false, state_err end
    local ok_pawn, pawn_detail = write_pawn_dilation(state.oculus_pawn, dilation)
    if not ok_pawn then return false, tostring(pawn_detail) end
    return true, "profile=" .. profile .. " pawn=" .. tostring(pawn_detail)
end

function M.freeze_status()
    local world = read_world_dilation() or "<nil>"
    local state = current_state()
    local pawn = read_pawn_dilation(state.oculus_pawn) or "<nil>"
    return true, freeze_line() .. " current_world=" .. tostring(world) .. " current_pawn=" .. tostring(pawn)
end

function M.pause_sync(args_text)
    local mode = normalize_pause_mode(split_args(args_text)[1] or "active")
    if pause_policy.last_mode ~= nil and pause_policy.last_mode ~= mode and pause_policy.manual_override == "live" then
        pause_policy.manual_override = nil
    end
    pause_policy.last_mode = mode

    local desired, source = pause_desired_for_mode(mode)
    pause_policy.last_desired = desired

    if desired == "paused" then
        if freeze_session.active == true then
            return true, "already paused mode=" .. tostring(mode) .. " source=" .. tostring(source) .. "; " .. freeze_line()
        end
        local ok, detail = M.freeze_start("fast")
        return ok, "pause sync mode=" .. tostring(mode) .. " source=" .. tostring(source) .. " ; " .. tostring(detail)
    end

    if freeze_session.active ~= true then
        return true, "already live mode=" .. tostring(mode) .. " source=" .. tostring(source) .. "; " .. freeze_line()
    end
    local ok, detail = M.freeze_stop("pause.sync." .. tostring(mode))
    return ok, "pause sync mode=" .. tostring(mode) .. " source=" .. tostring(source) .. " ; " .. tostring(detail)
end

function M.pause(args_text)
    local arg = trim(args_text):lower()
    if arg == "" or arg == "toggle" then
        if freeze_session.active == true or pause_policy.last_desired == "paused" then
            pause_policy.manual_override = "live"
            pause_policy.last_desired = "live"
            local ok, detail = M.freeze_stop("pause.toggle.live")
            return ok, "manual live ; " .. tostring(detail)
        end
        pause_policy.manual_override = "paused"
        pause_policy.last_desired = "paused"
        local ok, detail = M.freeze_start("fast")
        return ok, "manual paused ; " .. tostring(detail)
    end
    if arg == "on" or arg == "pause" or arg == "paused" then
        pause_policy.manual_override = "paused"
        pause_policy.last_desired = "paused"
        local ok, detail = M.freeze_start("fast")
        return ok, "manual paused ; " .. tostring(detail)
    end
    if arg == "off" or arg == "live" or arg == "resume" then
        pause_policy.manual_override = "live"
        pause_policy.last_desired = "live"
        local ok, detail = M.freeze_stop("pause.live")
        return ok, "manual live ; " .. tostring(detail)
    end
    if arg == "auto" or arg == "default" then
        pause_policy.manual_override = nil
        return M.pause_sync(pause_policy.last_mode or "active")
    end
    if arg == "status" then
        return M.pause_status()
    end
    return false, "usage: camera.oculus.pause [toggle|on|off|auto|status]"
end

function M.pause_status()
    local mode = pause_policy.last_mode or "active"
    local desired, source = pause_desired_for_mode(mode)
    return true, "mode=" .. tostring(mode)
        .. " desired=" .. tostring(desired)
        .. " source=" .. tostring(source)
        .. " ; " .. freeze_line()
end

function M.start()
    local active = current_state()
    if active.oculus then return true, "already active; " .. state_line(active) end

    local ok_apply, detail = feature_ge.apply_ge(OCULUS_GE_CLASS)
    if not ok_apply then return false, detail end

    local after = current_state()
    return true, tostring(detail) .. "; " .. state_line(after)
end

function M.stop()
    local state = current_state()
    if not state.oculus then return true, "already inactive; " .. state_line(state) end

    local component = state.oculus_component
    if not is_valid(component) then return false, "no OculusComponent; " .. state_line(state) end
    if not component.RequestExitOculusMode then return false, "OculusComponent has no RequestExitOculusMode" end

    local ok_stop, stop_err = pcall(function() component:RequestExitOculusMode() end)
    if not ok_stop then return false, "RequestExitOculusMode errored: " .. tostring(stop_err) end

    return true, "exit requested; " .. state_line(current_state())
end

function M.toggle()
    local state = current_state()
    if state.oculus then return M.stop() end
    return M.start()
end

function M.require_state(args_text)
    local args = split_args(args_text)
    local target = (args[1] or ""):lower()
    local state = current_state()
    local ok = false

    if target == "active" then
        ok = state.oculus == true
    elseif target == "inactive" then
        ok = state.oculus ~= true
    elseif target == "preview" then
        ok = state.preview == true
    elseif target == "repair" then
        ok = state.repair == true
    else
        return false, "usage: camera.oculus.require <active|inactive|preview|repair>"
    end

    if ok then return true, "required " .. target .. " satisfied; " .. state_line(state) end
    return false, "requires " .. target .. "; " .. state_line(state)
end

function M.speed(args_text)
    local state, state_err = require_active_state()
    if state_err then return false, state_err end
    local movement, movement_err = get_movement_component(state.oculus_pawn)
    if not movement then return false, movement_err end

    local args = split_args(args_text)
    if #args == 0 then return true, read_motion_line(movement) end

    local parse_err
    local max_speed, acceleration, deceleration
    max_speed, parse_err = parse_positive_number(args[1], "maxSpeed")
    if parse_err then return false, "usage: camera.oculus.speed <maxSpeed> [acceleration] [deceleration]" end
    acceleration = args[2] and tonumber(args[2]) or nil
    deceleration = args[3] and tonumber(args[3]) or nil
    if args[2] and (not acceleration or acceleration <= 0) then return false, "acceleration must be a positive number" end
    if args[3] and (not deceleration or deceleration <= 0) then return false, "deceleration must be a positive number" end

    local ok_speed, speed_err = write_field(movement, "MaxSpeed", max_speed)
    if not ok_speed then return false, "MaxSpeed write failed: " .. tostring(speed_err) end
    if acceleration then
        local ok_accel, accel_err = write_field(movement, "Acceleration", acceleration)
        if not ok_accel then return false, "Acceleration write failed: " .. tostring(accel_err) end
    end
    if deceleration then
        local ok_decel, decel_err = write_field(movement, "Deceleration", deceleration)
        if not ok_decel then return false, "Deceleration write failed: " .. tostring(decel_err) end
    end

    last_speed_args = table.concat({
        fmt_number(max_speed),
        fmt_number(acceleration or read_field(movement, "Acceleration") or 4000),
        fmt_number(deceleration or read_field(movement, "Deceleration") or 8000),
    }, " ")

    local freeze_note = ""
    if freeze_session.active == true then
        local profile = max_speed >= 3000 and "fast" or "default"
        freeze_session.profile = profile
        local pawn_dilation = dilation_for_profile(profile)
        local ok_pawn, pawn_detail = write_pawn_dilation(state.oculus_pawn, pawn_dilation)
        freeze_note = " freeze_pawn=" .. tostring(ok_pawn) .. ":" .. tostring(pawn_detail)
    end

    return true, read_motion_line(movement) .. freeze_note
end

function M.reapply_speed(_args_text)
    local state = current_state()
    if state.oculus ~= true then return true, "inactive; speed skipped" end
    return M.speed(last_speed_args)
end

function M.repair_camera_after_modal(reason)
    local notes = {}

    local ok_input, input_detail = reset_controller_input_locks()
    notes[#notes + 1] = "input=" .. tostring(ok_input) .. ":" .. tostring(input_detail)

    local state = current_state()
    if state.oculus == true then
        if freeze_session.active == true and freeze_settings.enabled == true then
            local ok_freeze, freeze_detail = M.freeze_start(freeze_session.profile or "default")
            notes[#notes + 1] = "freeze=" .. tostring(ok_freeze) .. ":" .. tostring(freeze_detail)
        else
            local ok_speed, speed_detail = M.reapply_speed(reason)
            notes[#notes + 1] = "speed=" .. tostring(ok_speed) .. ":" .. tostring(speed_detail)
        end
    else
        notes[#notes + 1] = "oculus=inactive"
    end

    return true, table.concat(notes, " ; ")
end

function M.distance(args_text)
    local state, state_err = require_active_state()
    if state_err then return false, state_err end
    local movement, movement_err = get_movement_component(state.oculus_pawn)
    if not movement then return false, movement_err end

    local args = split_args(args_text)
    if #args == 0 then return true, read_motion_line(movement) end

    local parse_err
    local max_distance, falloff
    max_distance, parse_err = parse_positive_number(args[1], "maxDistance")
    if parse_err then return false, "usage: camera.oculus.distance <maxDistance> [falloffThreshold]" end
    falloff = args[2] and tonumber(args[2]) or nil
    if args[2] and (not falloff or falloff <= 0) then return false, "falloffThreshold must be a positive number" end

    local ok_distance, distance_err = write_field(movement, "MaxDistanceFromPlayer", max_distance)
    if not ok_distance then return false, "MaxDistanceFromPlayer write failed: " .. tostring(distance_err) end
    if falloff then
        local ok_falloff, falloff_err = write_field(movement, "DistanceFromPlayerSpeedFalloffThreshold", falloff)
        if not ok_falloff then return false, "DistanceFromPlayerSpeedFalloffThreshold write failed: " .. tostring(falloff_err) end
    end

    return true, read_motion_line(movement)
end

function M.vignette(args_text)
    local args = split_args(args_text)
    local visible = parse_onoff(args[1] or "off")
    if visible == nil then
        return false, "usage: camera.oculus.vignette <off|on> [duration] [r,g,b,a]"
    end

    local duration = args[2] and tonumber(args[2]) or 0.0
    if not duration or duration < 0 then return false, "duration must be 0 or greater" end
    local color, color_err = parse_color(args[3])
    if not color then return false, color_err end

    local widget_ok, widget_detail = force_oculus_vignette_widget(visible)

    local api, api_err = get_vignette_api()
    local direct_err = api_err or "VignetteAPI unresolved"
    if is_valid(api) and api.SetOculusVision then
        local ok, err = pcall(function() api:SetOculusVision(visible, duration, color) end)
        if ok and widget_ok then
            return true, string.format("SetOculusVision(%s, %.3g, %d,%d,%d,%d)",
                visible and "on" or "off", duration, color.R, color.G, color.B, color.A)
                .. "; " .. tostring(widget_detail)
        elseif ok then
            return true, string.format("SetOculusVision(%s, %.3g, %d,%d,%d,%d); widget direct skipped: %s",
                visible and "on" or "off", duration, color.R, color.G, color.B, color.A, tostring(widget_detail))
        end
        direct_err = tostring(err)
    end

    if widget_ok then
        return true, tostring(widget_detail) .. "; SetOculusVision failed: " .. tostring(direct_err)
    end

    local fallback_code = visible and 0 or 1
    local ok_fallback, fallback_ok, fallback_detail = pcall(function()
        return feature_ui.set_widget_vis("17 " .. tostring(fallback_code))
    end)
    if ok_fallback and fallback_ok then
        return true, "widget fallback " .. tostring(fallback_detail) .. "; direct failed: " .. tostring(direct_err) .. "; widget direct failed: " .. tostring(widget_detail)
    end
    return false, "SetOculusVision failed: " .. tostring(direct_err) .. "; widget direct failed: " .. tostring(widget_detail) .. "; widget fallback failed: " .. tostring(fallback_detail or fallback_ok)
end

function M.watermark(args_text)
    local args = split_args(args_text)
    local mode = trim(args[1] or "off"):lower()
    local visible = nil
    if mode == "toggle" then
        visible = not (current_watermark_visible() == true)
    else
        visible = parse_onoff(mode)
    end
    if visible == nil then
        return false, "usage: camera.oculus.watermark <off|on|toggle>"
    end

    local ok, detail = force_watermark_widget(visible)
    watermark_visible = visible
    if ok then return true, tostring(detail) end
    return true, "watermark unchanged: " .. tostring(detail)
end

return M
