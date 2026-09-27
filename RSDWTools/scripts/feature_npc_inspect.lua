-- Feature: fixed-screen NPC inspector.
--
-- Data comes from feature_debug_watch.describe_actor(), the same discovery
-- and evaluator path used by debug.watch.snap. Rendering uses a transient UMG
-- viewport widget because AHUD::ReceiveDrawHUD does not fire in the live HUD.

local M = {}

local feature_actor = require("feature_actor")
local feature_debug_watch = require("feature_debug_watch")
local feature_field = require("feature_field")
local feature_grab = require("feature_grab")
local feature_npc_drive = require("feature_npc_drive")
local feature_oculus = require("feature_oculus")
local feature_scan = require("feature_scan")
local feature_umg = require("feature_umg")
local mod_paths = require("mod_paths")

local DATA_REFRESH_SECONDS = 0.25
local PANEL_EXPIRY_GRACE_MS = 100
local HUD_TOGGLE_DEFER_MS = 16
local INPUT_REPAIR_DEFER_MS = 100
local TEARDOWN_SETTLE_MS = 400
local OVERLAY_REFRESH_DEFER_MS = 180
local PUPPET_DEFER_MS = 450
local SNAP_DUR = 8.0
local PANEL_ONLY_DUR = 5.0
local DEFAULT_CAMERA = "orbit 520 180"
local STATE_FILE = "npc_inspect_state.json"
local INSPECT_HELP_ENABLED = true
local INSPECT_HELP_TEXT = "Mouse Move: Orbit | Wheel: Zoom | X: Exit | 1: Toggle HUD | 2: Toggle UMG | 3: Nudge"
local INSPECT_HELP_MODE = ""
local PANEL_WIDTH = 410.0
local PANEL_HEIGHT = 390.0
local HP_WIDTH = 356.0

local Visibility_HIDDEN = 2
local Visibility_SELF_HIT_TEST_INVISIBLE = 4

RSDWTOOLS_NPC_INSPECT_TOKEN = (RSDWTOOLS_NPC_INSPECT_TOKEN or 0) + 1
local module_token = RSDWTOOLS_NPC_INSPECT_TOKEN

local state = {
    actor = nil,
    source = nil,
    overlay = false,
    snap_until = nil,
    expr = nil,
    panel_text = nil,
    panel_ok = false,
    panel_err = nil,
    last_refresh = 0,
    umg_pending = false,
    umg_ok = false,
    umg_err = nil,
    umg_loop = false,
    umg_expiry_generation = 0,
    umg_updates = 0,
    umg_visible = false,
    umg_hidden = false,
    hud_visible = true,
    camera_view_enabled = true,
    teardown_busy = false,
    teardown_generation = 0,
    overlay_generation = 0,
    overlay_settle_until = nil,
    puppet_generation = 0,
    widget = {},
}

local hotkeys_registered = false

local function run_on_game_thread(fn)
    if ExecuteInGameThread then
        local ok_sched, err = pcall(function() ExecuteInGameThread(fn) end)
        return ok_sched, err
    end
    return pcall(fn)
end

local function defer_on_game_thread(delay_ms, fn)
    if LoopAsync then
        local ok_loop, err = pcall(function()
            LoopAsync(delay_ms or 1, function()
                local ok_run, run_err = run_on_game_thread(function()
                    local ok_action, action_err = pcall(fn)
                    if not ok_action then
                        print("[RSDWTools.npc.inspect] deferred game-thread action failed: " .. tostring(action_err))
                    end
                end)
                if not ok_run then
                    print("[RSDWTools.npc.inspect] deferred game-thread schedule failed: " .. tostring(run_err))
                end
                return true
            end)
        end)
        if ok_loop then return true, "scheduled" end
        print("[RSDWTools.npc.inspect] deferred schedule failed: " .. tostring(err))
    end
    return run_on_game_thread(function()
        local ok_action, action_err = pcall(fn)
        if not ok_action then
            print("[RSDWTools.npc.inspect] deferred game-thread action failed: " .. tostring(action_err))
        end
    end)
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function is_valid(object)
    return feature_actor.is_valid_object(object)
end

local function bool_word(value)
    return value and "on" or "off"
end

local function same_object(first, second)
    if not is_valid(first) or not is_valid(second) then return false end
    if first == second then return true end
    return tostring(first) == tostring(second)
end

local function inspect_log(message)
    print("[RSDWTools.npc.inspect] " .. tostring(message or ""))
end

local function show_inspect_help()
    if not INSPECT_HELP_ENABLED then return end
    if state.camera_view_enabled == false then return end
    if state.umg_hidden or not is_valid(state.actor) then return end
    if LoopAsync then
        LoopAsync(350, function()
            if not state.umg_hidden and is_valid(state.actor) then
                pcall(function() feature_umg.oculus_help(INSPECT_HELP_TEXT, INSPECT_HELP_MODE) end)
            end
            return true
        end)
        return
    end
    pcall(function() feature_umg.oculus_help(INSPECT_HELP_TEXT, INSPECT_HELP_MODE) end)
end

local function hide_inspect_help()
    if not INSPECT_HELP_ENABLED then return end
    pcall(function() feature_umg.oculus_help_hide() end)
end

local function parse_onoff(value)
    local text = trim(value):lower()
    if text == "" or text == "toggle" then return nil end
    if text == "on" or text == "1" or text == "true" or text == "yes" then return true end
    if text == "off" or text == "0" or text == "false" or text == "no" then return false end
    return "invalid"
end

local function FLinearColor(r, g, b, a)
    return { R = r, G = g, B = b, A = a }
end

local function FSlateColor(r, g, b, a)
    return { SpecifiedColor = FLinearColor(r, g, b, a), ColorUseRule = 0 }
end

local function umg_object_name(name)
    return tostring(name or "RSDWToolsNPCInspect") .. "_" .. tostring(module_token)
end

local C_BG = FLinearColor(0.030, 0.026, 0.020, 0.86)
local C_BG_2 = FLinearColor(0.070, 0.060, 0.046, 0.72)
local C_BAR_BG = FLinearColor(0.040, 0.038, 0.034, 0.92)
local C_ACCENT = FLinearColor(0.90, 0.70, 0.38, 0.95)
local C_ACCENT_DIM = FLinearColor(0.36, 0.25, 0.12, 0.92)
local C_HP = FLinearColor(0.42, 0.78, 0.36, 0.96)
local C_BAD = FLinearColor(0.95, 0.30, 0.22, 0.95)

local function slate(color)
    return { SpecifiedColor = color, ColorUseRule = 0 }
end

local function object_label(object)
    if not is_valid(object) then return "-" end
    local short = feature_actor.short_name_of(object)
    if short and short ~= "" then return short end
    return feature_field.class_name_of(object) or tostring(object)
end

local function safe_call(object, method)
    if not is_valid(object) then return nil end
    local ok_method, fn = pcall(function() return object[method] end)
    if not ok_method or type(fn) ~= "function" then return nil end
    local ok_value, value = pcall(function() return fn(object) end)
    if ok_value then return value end
    return nil
end

local function format_value(value)
    if value == nil then return "-" end
    local kind = type(value)
    if kind == "number" then
        if value == math.floor(value) then return string.format("%d", value) end
        return string.format("%.1f", value)
    end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "string" then return value end
    if type(value) == "userdata" then
        local ok_text, text = pcall(function() return value:ToString() end)
        if ok_text and type(text) == "string" and text ~= "" then return text end
        local ok_name, fname = pcall(function() return value:GetFName() end)
        if ok_name and fname then
            local ok_string, string_name = pcall(function() return fname:ToString() end)
            if ok_string and type(string_name) == "string" and string_name ~= "" then return string_name end
        end
    end
    return tostring(value)
end

local function user_value(value)
    local text = trim(value)
    if text == "" or text == "-" or text:lower() == "nil" or text:lower() == "none" then return "None" end
    return text
end

local function friendly_value(value)
    local text = user_value(format_value(value))
    text = text:gsub("^%w+::", "")
    text = text:gsub("_", " ")
    return text
end

local function display_name(actor)
    local readable = safe_call(actor, "GetUserReadableName")
    local text = format_value(readable)
    if text ~= "-" and text ~= "" then return text end
    return object_label(actor)
end

local function safe_number_call(object, method)
    local value = safe_call(object, method)
    if type(value) == "number" then return value end
    return tonumber(value)
end

local function health_component(actor)
    local comp = safe_call(actor, "GetAiHealthComponent")
    if is_valid(comp) then return comp end
    for _, field_name in ipairs({ "HealthComponent", "AiHealthComponent", "Health", "HealthComp" }) do
        local ok_field, field_value = pcall(function() return actor[field_name] end)
        if ok_field and is_valid(field_value) then return field_value end
    end
    return nil
end

local function health_summary(actor)
    local comp = health_component(actor)
    if not is_valid(comp) then return nil end
    local current = safe_number_call(comp, "GetLocalHealth") or safe_number_call(comp, "GetAuthoritativeHealth")
    local max_health = safe_number_call(comp, "GetMaxHealth")
    local normalized = safe_number_call(comp, "GetNormalizedHealth")
    if (not normalized) and current and max_health and max_health > 0 then normalized = current / max_health end
    if normalized then
        if normalized > 1.0 then normalized = normalized / 100.0 end
        normalized = math.max(0.0, math.min(normalized, 1.0))
    end
    return { current = current, max = max_health, normalized = normalized }
end

local function safe_string_method(object, method)
    local value = safe_call(object, method)
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

local function actor_full_name(actor)
    return safe_string_method(actor, "GetFullName")
end

local function has_callable(object, method)
    if not is_valid(object) then return false end
    local ok_method, fn = pcall(function() return object[method] end)
    return ok_method and type(fn) == "function"
end

local function inspectable_reason(actor)
    if not is_valid(actor) then return false, "invalid target" end
    local class_name = feature_field.class_name_of(actor) or ""
    local full_name = actor_full_name(actor) or object_label(actor)
    local identity = (class_name .. " " .. full_name):lower()
    if identity:find("npc", 1, true) or identity:find("dominionai", 1, true) or identity:find("bp_ai", 1, true) or identity:find("_ai_", 1, true) or identity:find("ai_", 1, true) then
        return true, "identity"
    end
    if has_callable(actor, "GetAIPowerLevel") or has_callable(actor, "GetCurrentAlertnessState") or has_callable(actor, "GetAIAimPoint") or has_callable(actor, "GetAiHealthComponent") then
        return true, "ai surface"
    end
    if feature_npc_drive.is_driveable_actor then
        local ok_drive, surface = feature_npc_drive.is_driveable_actor(actor)
        if ok_drive then return true, tostring(surface or "drive surface") end
    end
    if is_valid(health_component(actor)) and (has_callable(actor, "GetController") or has_callable(actor, "GetAIController")) then
        return true, "health/controller surface"
    end
    return false, "target does not expose NPC/AI inspection surfaces"
end

local function is_inspectable_npc(actor)
    local ok = inspectable_reason(actor)
    return ok and true or false
end

local function starts_with_bp_ai(text)
    text = tostring(text or ""):lower()
    return text:sub(1, 6) == "bp_ai_"
end

local function is_bp_ai_actor(actor)
    if not is_valid(actor) then return false end
    if starts_with_bp_ai(feature_actor.short_name_of(actor)) then return true end
    if starts_with_bp_ai(feature_field.class_name_of(actor)) then return true end
    return false
end

local function resolve_hud()
    if FindFirstOf then
        local ok_debug, debug_hud = pcall(function() return FindFirstOf("DebugCameraHUD") end)
        if ok_debug and is_valid(debug_hud) then return debug_hud end
        local ok_hud, hud = pcall(function() return FindFirstOf("HUD") end)
        if ok_hud and is_valid(hud) then return hud end
    end
    return nil
end

local function clear_actor_text(actor)
    if not is_valid(actor) then return end
    local hud = resolve_hud()
    if is_valid(hud) then pcall(function() hud:RemoveDebugText(actor, false) end) end
end

local function set_game_hud_visible(visible)
    local desired = visible and true or false
    if state.hud_visible == desired then return true, "hud=" .. (desired and "on" or "off") end
    state.hud_visible = desired
    local ok_defer, detail = defer_on_game_thread(HUD_TOGGLE_DEFER_MS, function()
        local ok_field, field_detail = feature_field.call("hud ShowHUD")
        if not ok_field then
            print("[RSDWTools.npc.inspect] ShowHUD failed: " .. tostring(field_detail))
        end
    end)
    if not ok_defer then
        state.hud_visible = not desired
        return false, "ShowHUD failed: " .. tostring(detail)
    end
    return true, "hud=" .. (desired and "on" or "off") .. " ShowHUD " .. tostring(detail or "scheduled")
end

local function resolve_player_damage_component()
    local pawn = feature_actor.get_local_pawn and feature_actor.get_local_pawn() or nil
    if not is_valid(pawn) then return nil end
    local component = nil
    pcall(function() component = pawn.PlayerDamageComponent end)
    if is_valid(component) then return component end
    pcall(function()
        if pawn.GetPlayerDamageComponent then component = pawn:GetPlayerDamageComponent() end
    end)
    if is_valid(component) then return component end
    return nil
end

local function set_player_damage_enabled(enabled)
    local component = resolve_player_damage_component()
    if not is_valid(component) then return false, "damage component unavailable" end
    local ok_write, err = pcall(function() component.bCanTakeDamage = enabled and true or false end)
    if ok_write then return true, "damage=" .. (enabled and "on" or "off") end
    return false, "damage set failed: " .. tostring(err)
end

local function set_watermark_visible(visible)
    local desired = visible and true or false
    local ok_defer, detail = defer_on_game_thread(HUD_TOGGLE_DEFER_MS, function()
        local ok_watermark, watermark_detail = feature_oculus.watermark(desired and "on" or "off")
        if not ok_watermark then
            print("[RSDWTools.npc.inspect] watermark failed: " .. tostring(watermark_detail))
        end
    end)
    if not ok_defer then return false, "watermark failed: " .. tostring(detail) end
    return true, "watermark=" .. (desired and "on" or "off") .. " " .. tostring(detail or "scheduled")
end

local function apply_inspect_lifecycle(active)
    local details = {}
    local input_ok, input_detail = true, "input_lock=unavailable"
    if feature_npc_drive.set_player_input_locked then
        input_ok, input_detail = feature_npc_drive.set_player_input_locked(active, "npc.inspect")
    end
    details[#details + 1] = (input_ok and "" or "!") .. tostring(input_detail)
    local damage_ok, damage_detail = set_player_damage_enabled(not active)
    details[#details + 1] = (damage_ok and "" or "!") .. tostring(damage_detail)
    local hud_ok, hud_detail = set_game_hud_visible(not active)
    details[#details + 1] = (hud_ok and "" or "!") .. tostring(hud_detail)
    local watermark_ok, watermark_detail = set_watermark_visible(not active)
    details[#details + 1] = (watermark_ok and "" or "!") .. tostring(watermark_detail)
    return true, table.concat(details, "; ")
end

local function resolve_target(value_str, allow_current)
    local text = trim(value_str)
    if text == "" and allow_current then
        local current = feature_npc_drive.current_actor and feature_npc_drive.current_actor() or nil
        if is_valid(current) then return current, "drive" end
    end
    if text == "" then text = "look" end
    local low = text:lower()
    if low == "@" or low == "look" or low == "reticle" or low == "@look" then
        local actor, source = feature_grab.pick_actor_under_reticle()
        if not is_valid(actor) then return nil, tostring(source or "no actor under reticle") end
        return actor, "reticle:" .. tostring(source or "hit")
    end
    local actor = feature_actor.resolve_actor_by_name(text)
    if not is_valid(actor) then return nil, "actor not found: " .. text end
    return actor, "name"
end

local function select_for_drive(actor, source_hint)
    if not is_valid(actor) then return false, "invalid target" end
    local selector = (source_hint and source_hint:match("^reticle")) and "look" or object_label(actor)
    local ok_select, select_detail = feature_npc_drive.select(selector)
    if ok_select then return true, select_detail end
    if selector ~= object_label(actor) then
        ok_select, select_detail = feature_npc_drive.select(object_label(actor))
    end
    return ok_select, select_detail
end

local function split_lines(text)
    local lines = {}
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    if text == "" then return lines end
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    return lines
end

local function limit_lines(text, max_lines)
    local lines = split_lines(text)
    max_lines = tonumber(max_lines) or 12
    if #lines <= max_lines then return table.concat(lines, "\n") end
    local out = {}
    for i = 1, max_lines - 1 do out[#out + 1] = lines[i] end
    out[#out + 1] = string.format("+%d more", #lines - #out)
    return table.concat(out, "\n")
end

local function panel_line_map(text)
    local values = {}
    for _, line in ipairs(split_lines(text)) do
        local label, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
        if label and value then values[trim(label)] = trim(value) end
    end
    return values
end

local function display_name_from_panel_text(text)
    local values = panel_line_map(text)
    local name = user_value(values.Name)
    if name ~= "None" then return name end
    return nil
end

local function display_number(value)
    value = tonumber(value)
    if not value then return nil end
    if math.abs(value - math.floor(value)) < 0.01 then return string.format("%d", value) end
    return string.format("%.1f", value)
end

local function parse_health_value(value)
    local text = user_value(value)
    if text == "None" or text:sub(1, 1) == "<" then return nil end
    local current_text, max_text = text:match("^%s*([%-%d%.,]+)%s*/%s*([%-%d%.,]+)%s*$")
    if current_text and max_text then
        local current = tonumber((current_text:gsub(",", "")))
        local max_health = tonumber((max_text:gsub(",", "")))
        if current and max_health then
            local normalized = nil
            if max_health > 0 then normalized = math.max(0.0, math.min(current / max_health, 1.0)) end
            return {
                current = current,
                max = max_health,
                normalized = normalized,
                label = string.format("HP %s / %s", display_number(current) or current_text, display_number(max_health) or max_text),
            }
        end
    end
    local percent_text = text:match("([%-%d%.]+)%s*%%")
    if percent_text then
        local percent = tonumber(percent_text)
        if percent then
            return { normalized = math.max(0.0, math.min(percent / 100.0, 1.0)), label = "HP " .. text }
        end
    end
    return { label = "HP " .. text }
end

local function health_summary_from_panel_text(text)
    local values = panel_line_map(text)
    return parse_health_value(values.HP)
end

local function build_detail_text(text)
    local values = panel_line_map(text)
    local ordered = {
        { key = "Tags", label = "Tags" },
        { key = "Wk", label = "Weakness" },
        { key = "Res", label = "Resistance" },
        { key = "Imm", label = "Immunity" },
    }
    local lines = {}
    for _, item in ipairs(ordered) do
        if values[item.key] ~= nil then
            lines[#lines + 1] = item.label .. ": " .. user_value(values[item.key])
        end
    end
    if #lines > 0 then return table.concat(lines, "\n") end
    return limit_lines(text, 10)
end

local function json_string(value)
    local escaped = tostring(value or "")
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
    return '"' .. escaped .. '"'
end

local function json_number(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then return "null" end
    return string.format("%.6g", number)
end

local function json_bool(value)
    return value and "true" or "false"
end

local function json_value(value)
    local kind = type(value)
    if value == nil then return "null" end
    if kind == "number" then return json_number(value) end
    if kind == "boolean" then return json_bool(value) end
    return json_string(value)
end

local function json_kv(key, value)
    return json_string(key) .. ":" .. json_value(value)
end

local function write_ipc_json(file_name, body)
    local dir = mod_paths.ipc_dir()
    if not dir or dir == "" then return false, "ipc dir unavailable" end
    return mod_paths.write_atomic(dir .. "\\" .. file_name, body)
end

local umg_status_word
local refresh_panel_text

local function write_state_json()
    local actor = state.actor
    local active = is_valid(actor)
    if active then refresh_panel_text(true) end
    local panel_values = active and panel_line_map(state.panel_text or "") or {}
    local health = active and health_summary_from_panel_text(state.panel_text or "") or nil
    local camera_input = feature_npc_drive.camera_input_status and feature_npc_drive.camera_input_status() or ""
    local parts = {
        json_kv("ok", true),
        json_kv("active", active),
        json_kv("target", active and object_label(actor) or nil),
        json_kv("display_name", active and (display_name_from_panel_text(state.panel_text or "") or display_name(actor)) or nil),
        json_kv("class", active and (feature_field.class_name_of(actor) or "") or nil),
        json_kv("source", state.source),
        json_kv("overlay", state.overlay),
        json_kv("camera_view_enabled", state.camera_view_enabled ~= false),
        json_kv("umg_hidden", state.umg_hidden),
        json_kv("hud_visible", state.hud_visible),
        json_kv("snap", state.snap_until and os.clock() <= state.snap_until),
        json_kv("renderer", "umg"),
        json_kv("umg", umg_status_word and umg_status_word() or "idle"),
        json_kv("updates", state.umg_updates or 0),
        json_kv("panel_ok", state.panel_ok),
        json_kv("panel_error", state.panel_err),
        json_kv("power", panel_values.Power),
        json_kv("state", panel_values.State),
        json_kv("tags", panel_values.Tags),
        json_kv("weakness", panel_values.Wk),
        json_kv("resistance", panel_values.Res),
        json_kv("immunity", panel_values.Imm),
        json_kv("hp_label", health and health.label or nil),
        json_kv("hp_current", health and health.current or nil),
        json_kv("hp_max", health and health.max or nil),
        json_kv("hp_normalized", health and health.normalized or nil),
        json_kv("camera", camera_input),
        json_kv("panel_text", state.panel_text or ""),
        json_kv("generated_unix", os.time()),
    }
    return write_ipc_json(STATE_FILE, "{" .. table.concat(parts, ",") .. "}")
end

local function drive_inspect_mode_active(actor)
    if feature_npc_drive.inspect_active then return feature_npc_drive.inspect_active(actor) end
    return true
end

local function panel_active()
    if not is_valid(state.actor) then return false end
    if state.snap_until and os.clock() <= state.snap_until then return true end
    if state.overlay and state.camera_view_enabled == false then
        state.overlay = false
        state.snap_until = nil
        return false
    end
    if state.overlay and drive_inspect_mode_active(state.actor) then return true end
    state.snap_until = nil
    return false
end

refresh_panel_text = function(force)
    if not is_valid(state.actor) then
        state.panel_text = "No inspected NPC"
        state.panel_ok = false
        state.panel_err = "invalid actor"
        return false
    end
    local now = os.clock()
    if not force and state.panel_text and (now - state.last_refresh) < DATA_REFRESH_SECONDS then
        return true
    end
    local text, ok, expr, err = feature_debug_watch.describe_actor(state.actor, state.expr)
    if not text or text == "" then
        text = "Name: " .. display_name(state.actor) .. "\nClass: " .. (feature_field.class_name_of(state.actor) or "-")
        ok = false
        err = err or "debug.watch formatter returned no text"
    end
    state.panel_text = text
    state.panel_ok = ok ~= false
    state.panel_err = err
    state.expr = expr or state.expr
    state.last_refresh = now
    return true
end

local function widget_ready()
    return is_valid(state.widget.canvas) and is_valid(state.widget.panel_border) and is_valid(state.widget.body_text)
end

local function get_game_instance()
    local ok_helpers, UEHelpers = pcall(require, "UEHelpers")
    if not ok_helpers or type(UEHelpers) ~= "table" or not UEHelpers.GetGameInstance then return nil, "UEHelpers.GetGameInstance unavailable" end
    local game_instance = nil
    local ok_gi, err = pcall(function() game_instance = UEHelpers.GetGameInstance() end)
    if not ok_gi or not game_instance then return nil, "GameInstance unavailable: " .. tostring(err) end
    return game_instance, nil
end

local function add_canvas_child(canvas, child, anchors, alignment, position, size, autosize)
    local slot = canvas:AddChildToCanvas(child)
    pcall(function() slot:SetAutoSize(autosize and true or false) end)
    if anchors then slot:SetAnchors(anchors) end
    if alignment then slot:SetAlignment(alignment) end
    if position then slot:SetPosition(position) end
    if size then pcall(function() slot:SetSize(size) end) end
    return slot
end

local function construct_text(text_block_cls, outer, name, size, color)
    local text = StaticConstructObject(text_block_cls, outer, FName(umg_object_name(name)))
    text.Font.Size = size
    text:SetText(FText(""))
    text:SetColorAndOpacity(slate(color or FLinearColor(0.9, 0.96, 1.0, 1.0)))
    text:SetShadowOffset({ X = 1, Y = 1 })
    text:SetShadowColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 0.72))
    pcall(function() text:SetAutoWrapText(true) end)
    return text
end

local function construct_border(border_cls, outer, name, color)
    local border = StaticConstructObject(border_cls, outer, FName(umg_object_name(name)))
    border:SetBrushColor(color)
    border:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
    return border
end

local function create_umg_panel()
    if widget_ready() then return true, "umg=ready" end
    if not (StaticFindObject and StaticConstructObject and FName and FText) then return false, "UMG construction functions unavailable" end
    local game_instance, gi_err = get_game_instance()
    if not game_instance then return false, gi_err end

    local user_widget_cls = StaticFindObject("/Script/UMG.UserWidget")
    local widget_tree_cls = StaticFindObject("/Script/UMG.WidgetTree")
    local canvas_panel_cls = StaticFindObject("/Script/UMG.CanvasPanel")
    local border_cls = StaticFindObject("/Script/UMG.Border")
    local text_block_cls = StaticFindObject("/Script/UMG.TextBlock")
    if not (user_widget_cls and widget_tree_cls and canvas_panel_cls and border_cls and text_block_cls) then
        return false, "required UMG classes not found"
    end

    local hud = StaticConstructObject(user_widget_cls, game_instance, FName(umg_object_name("RSDWToolsNPCInspectHUD")))
    hud.WidgetTree = StaticConstructObject(widget_tree_cls, hud, FName(umg_object_name("RSDWToolsNPCInspectTree")))
    local canvas = StaticConstructObject(canvas_panel_cls, hud.WidgetTree, FName(umg_object_name("RSDWToolsNPCInspectCanvas")))
    hud.WidgetTree.RootWidget = canvas

    local panel_border = construct_border(border_cls, canvas, "RSDWToolsNPCInspectPanel", C_BG)
    panel_border:SetPadding({ Left = 14, Top = 12, Right = 14, Bottom = 12 })
    local panel_canvas = StaticConstructObject(canvas_panel_cls, panel_border, FName(umg_object_name("RSDWToolsNPCInspectPanelCanvas")))
    panel_border:SetContent(panel_canvas)
    add_canvas_child(
        canvas,
        panel_border,
        { Minimum = { X = 1.0, Y = 0.5 }, Maximum = { X = 1.0, Y = 0.5 } },
        { X = 1.0, Y = 0.5 },
        { X = -32, Y = -8 },
        { X = PANEL_WIDTH, Y = PANEL_HEIGHT },
        false
    )

    local accent = construct_border(border_cls, panel_canvas, "RSDWToolsNPCInspectAccent", C_ACCENT)
    add_canvas_child(panel_canvas, accent, nil, nil, { X = 0, Y = 0 }, { X = PANEL_WIDTH - 28, Y = 3 }, false)
    local body_bg = construct_border(border_cls, panel_canvas, "RSDWToolsNPCInspectBodyBg", C_BG_2)
    add_canvas_child(panel_canvas, body_bg, nil, nil, { X = 0, Y = 114 }, { X = PANEL_WIDTH - 28, Y = 236 }, false)

    local title_text = construct_text(text_block_cls, panel_canvas, "RSDWToolsNPCInspectTitle", 15, C_ACCENT)
    pcall(function() title_text:SetJustification(0) end)
    add_canvas_child(panel_canvas, title_text, nil, nil, { X = 0, Y = 16 }, { X = PANEL_WIDTH - 28, Y = 24 }, false)

    local name_text = construct_text(text_block_cls, panel_canvas, "RSDWToolsNPCInspectName", 20, FLinearColor(0.95, 0.98, 1.0, 1.0))
    add_canvas_child(panel_canvas, name_text, nil, nil, { X = 0, Y = 42 }, { X = PANEL_WIDTH - 28, Y = 30 }, false)

    local meta_text = construct_text(text_block_cls, panel_canvas, "RSDWToolsNPCInspectMeta", 13, FLinearColor(0.62, 0.72, 0.76, 1.0))
    add_canvas_child(panel_canvas, meta_text, nil, nil, { X = 0, Y = 72 }, { X = PANEL_WIDTH - 28, Y = 22 }, false)

    local hp_back = construct_border(border_cls, panel_canvas, "RSDWToolsNPCInspectHPBack", C_BAR_BG)
    add_canvas_child(panel_canvas, hp_back, nil, nil, { X = 0, Y = 96 }, { X = HP_WIDTH, Y = 8 }, false)
    local hp_fill = construct_border(border_cls, panel_canvas, "RSDWToolsNPCInspectHPFill", C_HP)
    local hp_fill_slot = add_canvas_child(panel_canvas, hp_fill, nil, nil, { X = 0, Y = 96 }, { X = HP_WIDTH, Y = 8 }, false)

    local body_text = construct_text(text_block_cls, panel_canvas, "RSDWToolsNPCInspectBody", 14, FLinearColor(0.86, 0.94, 0.96, 1.0))
    add_canvas_child(panel_canvas, body_text, nil, nil, { X = 12, Y = 128 }, { X = PANEL_WIDTH - 52, Y = 204 }, false)

    canvas.Visibility = Visibility_HIDDEN
    panel_border.Visibility = Visibility_HIDDEN
    hud:AddToViewport(198 + module_token)

    state.widget = {
        hud = hud,
        canvas = canvas,
        panel_border = panel_border,
        title_text = title_text,
        name_text = name_text,
        meta_text = meta_text,
        body_text = body_text,
        hp_fill = hp_fill,
        hp_fill_slot = hp_fill_slot,
    }
    state.umg_ok = true
    state.umg_err = nil
    return true, "umg=ready"
end

local function set_umg_visible(show)
    local vis = show and Visibility_SELF_HIT_TEST_INVISIBLE or Visibility_HIDDEN
    if is_valid(state.widget.canvas) then state.widget.canvas:SetVisibility(vis) end
    if is_valid(state.widget.panel_border) then state.widget.panel_border:SetVisibility(vis) end
    state.umg_visible = show and true or false
end

local function destroy_umg_panel_inline()
    local widget = state.widget or {}
    if is_valid(widget.hud) then
        pcall(function() widget.hud:RemoveFromParent() end)
    end
    state.widget = {}
    state.umg_visible = false
    state.umg_ok = false
    state.umg_pending = false
    state.umg_err = nil
end

local function update_umg_panel(force_refresh)
    if state.overlay_settle_until and os.clock() < state.overlay_settle_until then return true end
    if not panel_active() then
        destroy_umg_panel_inline()
        return true
    end
    if state.umg_hidden then
        destroy_umg_panel_inline()
        return true
    end
    local ok_create, create_detail = create_umg_panel()
    if not ok_create then
        state.umg_ok = false
        state.umg_err = create_detail
        return false
    end
    refresh_panel_text(force_refresh == true)

    local actor = state.actor
    local panel_values = panel_line_map(state.panel_text or "")
    local health = health_summary_from_panel_text(state.panel_text or "") or (is_valid(actor) and health_summary(actor) or nil)
    local power = panel_values.Power ~= nil and panel_values.Power or (is_valid(actor) and safe_call(actor, "GetAIPowerLevel") or nil)
    local alert = panel_values.State ~= nil and panel_values.State or (is_valid(actor) and safe_call(actor, "GetCurrentAlertnessState") or nil)
    local hp_label = "HP None"
    local hp_percent = health and health.normalized or nil
    if health and health.label then
        hp_label = health.label
    elseif health and health.current and health.max then
        hp_label = string.format("HP %.0f / %.0f", health.current, health.max)
    elseif hp_percent then
        hp_label = string.format("HP %.0f%%", hp_percent * 100.0)
    end
    local meta_parts = {}
    meta_parts[#meta_parts + 1] = hp_label
    if power ~= nil then meta_parts[#meta_parts + 1] = "Power " .. friendly_value(power) end
    if alert ~= nil then meta_parts[#meta_parts + 1] = "State " .. friendly_value(alert) end

    state.widget.title_text:SetText(FText("NPC DETAILS"))
    local panel_name = display_name_from_panel_text(state.panel_text or "") or (is_valid(actor) and display_name(actor) or "No target")
    state.widget.name_text:SetText(FText(panel_name))
    state.widget.meta_text:SetText(FText(table.concat(meta_parts, "  |  ")))
    state.widget.body_text:SetText(FText(build_detail_text(state.panel_text or "")))
    inspect_log("umg applied target=" .. tostring(panel_name) .. " actor=" .. object_label(actor))

    local fill_width = 0.0
    if hp_percent then fill_width = math.max(0.0, math.min(HP_WIDTH, HP_WIDTH * hp_percent)) end
    if is_valid(state.widget.hp_fill) then
        state.widget.hp_fill:SetBrushColor((hp_percent and hp_percent <= 0.25) and C_BAD or C_HP)
    end
    if state.widget.hp_fill_slot then pcall(function() state.widget.hp_fill_slot:SetSize({ X = fill_width, Y = 8 }) end) end
    set_umg_visible(true)
    state.umg_updates = (state.umg_updates or 0) + 1
    return true
end

local function ensure_umg_panel()
    if widget_ready() then return true, "umg=ready" end
    if state.overlay_settle_until and os.clock() < state.overlay_settle_until then return true, "umg=settling" end
    if state.umg_pending then return true, "umg=pending" end
    state.umg_pending = true
    local ok_sched, err = run_on_game_thread(function()
        local ok_create, detail = create_umg_panel()
        state.umg_pending = false
        state.umg_ok = ok_create
        state.umg_err = ok_create and nil or detail
        if ok_create then update_umg_panel(true) end
    end)
    if not ok_sched then
        state.umg_pending = false
        state.umg_ok = false
        state.umg_err = tostring(err)
        return false, "umg schedule failed: " .. tostring(err)
    end
    return true, widget_ready() and "umg=ready" or "umg=pending"
end

local function schedule_umg_update()
    return run_on_game_thread(function() update_umg_panel() end)
end

local function destroy_umg_panel()
    run_on_game_thread(function() destroy_umg_panel_inline() end)
end

local start_umg_loop

local function inspect_hotkeys_active()
    return RSDWTOOLS_NPC_INSPECT_TOKEN == module_token
        and state.overlay == true
    and state.camera_view_enabled ~= false
        and is_valid(state.actor)
        and drive_inspect_mode_active(state.actor)
end

local function set_inspect_umg_visible(visible)
    if not inspect_hotkeys_active() then return false, "no active NPC Inspect target" end
    local show = visible and true or false
    state.umg_hidden = not show
    if not show then
        hide_inspect_help()
        destroy_umg_panel()
        return true, "umg=hidden"
    end
    ensure_umg_panel()
    if start_umg_loop then start_umg_loop() end
    schedule_umg_update()
    show_inspect_help()
    return true, "umg=visible"
end

local function toggle_inspect_hud(visible)
    if not inspect_hotkeys_active() then return false, "no active NPC Inspect target" end
    local show = visible and true or false
    local hud_ok, hud_detail = set_game_hud_visible(show)
    local watermark_ok, watermark_detail = set_watermark_visible(show)
    if hud_ok and watermark_ok then
        return true, tostring(hud_detail) .. "; " .. tostring(watermark_detail)
    end
    return false, tostring(hud_detail) .. "; " .. tostring(watermark_detail)
end

local function resolve_key_any(names)
    local key_table = rawget(_G, "Key")
    if not key_table then return nil end
    for _, key_name in ipairs(names) do
        local key_value = key_table[key_name]
        if key_value ~= nil then return key_value end
    end
    return nil
end

local function register_inspect_hotkey(names, callback)
    if not RegisterKeyBindAsync then return false, "RegisterKeyBindAsync unavailable" end
    local key_value = resolve_key_any(names)
    if key_value == nil then return false, "key unavailable" end
    local ok_register, err = pcall(function()
        RegisterKeyBindAsync(key_value, function()
            if not inspect_hotkeys_active() then return end
            local ok_callback, callback_err = pcall(callback)
            if not ok_callback then print("[RSDWTools.npc.inspect] hotkey failed: " .. tostring(callback_err)) end
        end)
    end)
    if not ok_register then return false, tostring(err) end
    return true, "registered"
end

local function ensure_inspect_hotkeys_registered()
    if hotkeys_registered then return end
    hotkeys_registered = true
    local registrations = {
        { { "X" }, function() M.off() end, "X" },
        { { "ONE", "One", "NumOne" }, function() M.hud("toggle") end, "1" },
        { { "TWO", "Two", "NumTwo" }, function() M.umg("toggle") end, "2" },
        { { "THREE", "Three", "NumThree" }, function() M.nudge("") end, "3" },
    }
    for _, item in ipairs(registrations) do
        local ok_register, detail = register_inspect_hotkey(item[1], item[2])
        if not ok_register then
            print("[RSDWTools.npc.inspect] hotkey " .. tostring(item[3]) .. " unavailable: " .. tostring(detail))
        end
    end
end

local function clear_inactive_panel_state()
    hide_inspect_help()
    state.umg_expiry_generation = (state.umg_expiry_generation or 0) + 1
    state.umg_hidden = false
    state.overlay = false
    state.snap_until = nil
    state.actor = nil
    state.source = nil
    state.panel_text = nil
    state.panel_ok = false
    state.panel_err = nil
end

start_umg_loop = function()
    state.umg_loop = false
    if not LoopAsync or not state.snap_until then return end

    state.umg_expiry_generation = (state.umg_expiry_generation or 0) + 1
    local generation = state.umg_expiry_generation
    local delay_ms = math.floor(((state.snap_until - os.clock()) * 1000.0) + PANEL_EXPIRY_GRACE_MS)
    if delay_ms < 1 then delay_ms = 1 end
    LoopAsync(delay_ms, function()
        if generation ~= state.umg_expiry_generation then return true end
        if RSDWTOOLS_NPC_INSPECT_TOKEN ~= module_token then return true end
        if not panel_active() then
            destroy_umg_panel()
            clear_inactive_panel_state()
        end
        return true
    end)
end

local function split_words(value_str)
    local words = {}
    for word in string.gmatch(trim(value_str), "%S+") do words[#words + 1] = word end
    return words
end

local function parse_target_and_camera(value_str)
    local words = split_words(value_str)
    local camera_words = {}
    local target_words = {}
    local camera_enabled = true
    local camera_terms = {
        front = true, face = true, inspect = true, orbit = true,
        frontright = true, ["front-right"] = true, rightfront = true,
        frontleft = true, ["front-left"] = true, leftfront = true,
        right = true, left = true, back = true, behind = true, follow = true,
    }
    local no_camera_terms = {
        nocamera = true, ["no-camera"] = true, no_camera = true,
        panel = true, panelonly = true, ["panel-only"] = true,
        info = true, umg = true,
    }
    for _, word in ipairs(words) do
        local low = word:lower()
        if no_camera_terms[low] then
            camera_enabled = false
        elseif camera_terms[low] or tonumber(word) then
            camera_words[#camera_words + 1] = word
        else
            target_words[#target_words + 1] = word
        end
    end
    local target = table.concat(target_words, " ")
    local camera = table.concat(camera_words, " ")
    if camera == "" then camera = DEFAULT_CAMERA end
    return target, camera, camera_enabled
end

local function finish_teardown_settle(teardown_generation)
    if LoopAsync then
        local ok_loop = pcall(function()
            LoopAsync(TEARDOWN_SETTLE_MS, function()
                if state.teardown_generation == teardown_generation then state.teardown_busy = false end
                return true
            end)
        end)
        if ok_loop then return end
    end
    state.teardown_busy = false
end

local function repair_input_after_teardown(teardown_generation)
    defer_on_game_thread(INPUT_REPAIR_DEFER_MS, function()
        if state.teardown_generation ~= teardown_generation or state.overlay then return end
        local ok_repair, repair_detail = feature_npc_drive.repair_player_input("npc.inspect.off")
        if not ok_repair then
            print("[RSDWTools.npc.inspect] player input repair failed: " .. tostring(repair_detail))
        end
    end)
end

local function perform_inspect_teardown(teardown_generation, actor, had_camera_view)
    if state.teardown_generation ~= teardown_generation then return end
    if is_valid(actor) then clear_actor_text(actor) end
    hide_inspect_help()
    destroy_umg_panel()
    if had_camera_view then
        pcall(function() feature_npc_drive.camera_mouse("off") end)
        pcall(function() feature_npc_drive.puppet("off") end)
        pcall(function() feature_npc_drive.camera("off") end)
        apply_inspect_lifecycle(false)
        repair_input_after_teardown(teardown_generation)
    end
end

local function schedule_overlay_refresh(actor, generation)
    local ok_defer, detail = defer_on_game_thread(OVERLAY_REFRESH_DEFER_MS, function()
        if state.overlay_generation ~= generation or state.overlay ~= true then return end
        if not same_object(state.actor, actor) then
            inspect_log("overlay deferred stale gen=" .. tostring(generation))
            return
        end
        state.overlay_settle_until = nil
        if not panel_active() then
            inspect_log("overlay deferred inactive gen=" .. tostring(generation))
            return
        end
        if state.umg_hidden then return end
        inspect_log("overlay deferred refresh begin gen=" .. tostring(generation))
        refresh_panel_text(true)
        inspect_log("overlay deferred refresh ok gen=" .. tostring(generation))
        inspect_log("overlay deferred umg begin gen=" .. tostring(generation))
        local ok_update = update_umg_panel(true)
        inspect_log("overlay deferred umg " .. (ok_update and "ok" or "failed") .. " gen=" .. tostring(generation) .. " detail=" .. tostring(state.umg_err or ""))
        start_umg_loop()
        show_inspect_help()
    end)
    if not ok_defer then return false, tostring(detail) end
    return true, "overlay=deferred " .. tostring(OVERLAY_REFRESH_DEFER_MS) .. "ms"
end

local function schedule_inspect_puppet(actor)
    state.puppet_generation = (state.puppet_generation or 0) + 1
    local generation = state.puppet_generation
    local ok_defer, detail = defer_on_game_thread(PUPPET_DEFER_MS, function()
        if state.puppet_generation ~= generation or state.overlay ~= true or state.camera_view_enabled == false then return end
        if not same_object(state.actor, actor) or not drive_inspect_mode_active(actor) then return end
        inspect_log("puppet begin gen=" .. tostring(generation))
        local ok_puppet, puppet_detail = feature_npc_drive.puppet("on")
        inspect_log("puppet " .. (ok_puppet and "ok " or "failed ") .. tostring(puppet_detail))
    end)
    if not ok_defer then return false, tostring(detail) end
    return true, "puppet=deferred " .. tostring(PUPPET_DEFER_MS) .. "ms"
end

local function set_overlay(enabled)
    local actor = state.actor
    if not is_valid(actor) then return false, "no inspected NPC" end
    state.overlay_generation = (state.overlay_generation or 0) + 1
    local generation = state.overlay_generation
    if not enabled then
        state.overlay = false
        state.snap_until = nil
        state.umg_expiry_generation = (state.umg_expiry_generation or 0) + 1
        state.overlay_settle_until = nil
        hide_inspect_help()
        destroy_umg_panel()
        return true, "overlay=off renderer=umg"
    end
    state.overlay = true
    state.snap_until = nil
    state.overlay_settle_until = os.clock() + (OVERLAY_REFRESH_DEFER_MS / 1000.0)
    local ok_refresh, refresh_detail = schedule_overlay_refresh(actor, generation)
    if not ok_refresh then return false, refresh_detail end
    return true, "overlay=on renderer=umg " .. tostring(refresh_detail)
end

function M.on(value_str)
    ensure_inspect_hotkeys_registered()
    if state.teardown_busy then
        return false, "inspect teardown settling; retry shortly"
    end
    local target_text, camera_text, camera_enabled = parse_target_and_camera(value_str)
    if state.overlay and state.camera_view_enabled ~= false and camera_enabled == false then
        return false, "inspect camera active; run npc.inspect.off before entering panel-only mode"
    end
    local actor, source = resolve_target(target_text, true)
    if not actor then return false, source end
    if tostring(source or ""):match("^reticle") and not is_bp_ai_actor(actor) then
        return false, "reticle target blocked by NPC safety: " .. object_label(actor) .. " is not BP_AI_*"
    end
    inspect_log("resolved target " .. object_label(actor) .. " camera_view=" .. bool_word(camera_enabled ~= false))
    local inspectable, reason = inspectable_reason(actor)
    if not inspectable then return false, tostring(reason) .. ": " .. object_label(actor) end

    state.overlay_generation = (state.overlay_generation or 0) + 1
    state.overlay_settle_until = os.clock() + (OVERLAY_REFRESH_DEFER_MS / 1000.0)
    if feature_npc_drive.release_puppet_for_retarget then
        local ok_release, release_detail = feature_npc_drive.release_puppet_for_retarget()
        if ok_release and release_detail ~= "puppet=idle" then inspect_log("puppet release " .. tostring(release_detail)) end
    end

    inspect_log("select begin " .. object_label(actor))
    local ok_select, select_detail = select_for_drive(actor, source)
    if not ok_select then return false, "select failed: " .. tostring(select_detail) end
    inspect_log("select ok " .. tostring(select_detail))
    state.actor = feature_npc_drive.current_actor and feature_npc_drive.current_actor() or actor
    state.source = source
    state.expr = nil
    state.panel_text = nil
    state.umg_hidden = false
    state.camera_view_enabled = camera_enabled ~= false

    if not state.camera_view_enabled then
        hide_inspect_help()
        local ok_overlay, overlay_detail = set_overlay(true)
        if not ok_overlay then return false, "overlay failed: " .. tostring(overlay_detail) end
        state.snap_until = os.clock() + PANEL_ONLY_DUR
        start_umg_loop()
        return true, "inspecting " .. object_label(state.actor) .. " camera_view=off panel_timeout=" .. tostring(PANEL_ONLY_DUR) .. "s " .. tostring(overlay_detail)
    end

    inspect_log("lifecycle begin")
    local _, lifecycle_detail = apply_inspect_lifecycle(true)
    inspect_log("lifecycle ok " .. tostring(lifecycle_detail))

    inspect_log("camera begin " .. tostring(camera_text))
    local ok_camera, camera_detail = feature_npc_drive.camera("on " .. camera_text)
    if not ok_camera then
        pcall(function() feature_npc_drive.camera("off") end)
        apply_inspect_lifecycle(false)
        return false, "camera failed: " .. tostring(camera_detail)
    end
    inspect_log("camera ok " .. tostring(camera_detail))
    inspect_log("mouse begin")
    local ok_mouse, mouse_detail = feature_npc_drive.camera_mouse("on")
    if not ok_mouse then mouse_detail = "mouse=unavailable:" .. tostring(mouse_detail) end
    inspect_log("mouse " .. tostring(mouse_detail))
    inspect_log("overlay begin")
    local ok_overlay, overlay_detail = set_overlay(true)
    if not ok_overlay then
        pcall(function() feature_npc_drive.camera_mouse("off") end)
        pcall(function() feature_npc_drive.puppet("off") end)
        pcall(function() feature_npc_drive.camera("off") end)
        apply_inspect_lifecycle(false)
        return false, "overlay failed: " .. tostring(overlay_detail)
    end
    inspect_log("overlay ok " .. tostring(overlay_detail))
    local ok_puppet_defer, puppet_detail = schedule_inspect_puppet(state.actor)
    if not ok_puppet_defer then puppet_detail = "puppet schedule failed: " .. tostring(puppet_detail) end
    return true, "inspecting " .. object_label(state.actor) .. " " .. tostring(camera_detail) .. " " .. tostring(mouse_detail) .. " " .. tostring(overlay_detail) .. " " .. tostring(puppet_detail) .. " " .. tostring(lifecycle_detail)
end

function M.off()
    if state.teardown_busy then
        return true, "inspect=off settling"
    end
    local actor = state.actor
    local had_camera_view = state.camera_view_enabled ~= false
    state.teardown_generation = (state.teardown_generation or 0) + 1
    state.puppet_generation = (state.puppet_generation or 0) + 1
    state.overlay_generation = (state.overlay_generation or 0) + 1
    local teardown_generation = state.teardown_generation
    state.teardown_busy = true
    state.overlay = false
    state.snap_until = nil
    state.overlay_settle_until = nil
    state.umg_hidden = false
    state.actor = nil
    state.source = nil
    state.panel_text = nil
    state.panel_ok = false
    state.panel_err = nil
    state.camera_view_enabled = true
    local ok_defer = defer_on_game_thread(1, function()
        perform_inspect_teardown(teardown_generation, actor, had_camera_view)
    end)
    if not ok_defer then perform_inspect_teardown(teardown_generation, actor, had_camera_view) end
    finish_teardown_settle(teardown_generation)
    return true, "inspect=off renderer=umg scheduled"
end

function M.forceoff()
    local actor = state.actor
    state.teardown_generation = (state.teardown_generation or 0) + 1
    state.puppet_generation = (state.puppet_generation or 0) + 1
    state.overlay_generation = (state.overlay_generation or 0) + 1
    state.teardown_busy = false
    state.overlay = false
    state.snap_until = nil
    state.overlay_settle_until = nil
    state.umg_hidden = false

    local notes = {}
    if is_valid(actor) then pcall(function() clear_actor_text(actor) end) end
    pcall(hide_inspect_help)
    pcall(destroy_umg_panel_inline)
    local ok_mouse_call, ok_mouse, mouse_detail = pcall(function() return feature_npc_drive.camera_mouse("off") end)
    notes[#notes + 1] = (ok_mouse_call and ok_mouse) and tostring(mouse_detail) or "mouse_failed=" .. tostring(mouse_detail or ok_mouse)
    local ok_puppet_call, ok_puppet, puppet_detail = pcall(function() return feature_npc_drive.puppet("off") end)
    notes[#notes + 1] = (ok_puppet_call and ok_puppet) and tostring(puppet_detail) or "puppet_failed=" .. tostring(puppet_detail or ok_puppet)
    local ok_camera_call, ok_camera, camera_detail = pcall(function() return feature_npc_drive.camera("off") end)
    notes[#notes + 1] = (ok_camera_call and ok_camera) and tostring(camera_detail) or "camera_failed=" .. tostring(camera_detail or ok_camera)
    local ok_clear_call, ok_clear, clear_detail = pcall(function() return feature_npc_drive.clear() end)
    notes[#notes + 1] = (ok_clear_call and ok_clear) and tostring(clear_detail) or "clear_failed=" .. tostring(clear_detail or ok_clear)
    local _, lifecycle_detail = apply_inspect_lifecycle(false)
    notes[#notes + 1] = tostring(lifecycle_detail)
    local ok_repair, repair_detail = feature_npc_drive.repair_player_input("npc.inspect.forceoff")
    notes[#notes + 1] = ok_repair and tostring(repair_detail) or "repair_failed=" .. tostring(repair_detail)

    clear_inactive_panel_state()
    state.camera_view_enabled = true
    return true, "inspect=forceoff " .. table.concat(notes, "; ")
end

function M.snap(value_str)
    local actor, source = resolve_target(value_str, true)
    if not actor then return false, source end
    if tostring(source or ""):match("^reticle") and not is_bp_ai_actor(actor) then
        return false, "reticle target blocked by NPC safety: " .. object_label(actor) .. " is not BP_AI_*"
    end
    local inspectable, reason = inspectable_reason(actor)
    if not inspectable then return false, tostring(reason) .. ": " .. object_label(actor) end
    state.actor = actor
    state.source = source
    state.expr = nil
    state.snap_until = os.clock() + SNAP_DUR
    refresh_panel_text(true)
    clear_actor_text(actor)
    local ok_umg, umg_detail = ensure_umg_panel()
    if not ok_umg then return false, umg_detail end
    start_umg_loop()
    schedule_umg_update()
    return true, "umg snap " .. object_label(actor) .. " for " .. tostring(SNAP_DUR) .. "s " .. tostring(umg_detail)
end

function M.overlay(value_str)
    local parsed = parse_onoff(value_str)
    if parsed == "invalid" then return false, "usage: npc.inspect.overlay [on|off|toggle]" end
    if not is_valid(state.actor) then
        local current = feature_npc_drive.current_actor and feature_npc_drive.current_actor() or nil
        if is_valid(current) then state.actor = current end
    end
    local next_enabled = parsed
    if next_enabled == nil then next_enabled = not state.overlay end
    return set_overlay(next_enabled)
end

function M.orbit(value_str)
    local ok_orbit, detail = feature_npc_drive.camera_orbit(value_str)
    if not ok_orbit then return false, detail end
    return true, detail
end

function M.mouse(value_str)
    local ok_mouse, detail = feature_npc_drive.camera_mouse(value_str)
    if not ok_mouse then return false, detail end
    return true, detail
end

function M.focus(value_str)
    local ok_focus, detail = feature_npc_drive.camera_focus(value_str)
    if not ok_focus then return false, detail end
    return true, detail
end

function M.hud(value_str)
    local parsed = parse_onoff(value_str)
    if parsed == "invalid" then return false, "usage: npc.inspect.hud [on|off|toggle]" end
    local visible = parsed
    if visible == nil then visible = not state.hud_visible end
    return toggle_inspect_hud(visible)
end

function M.umg(value_str)
    local parsed = parse_onoff(value_str)
    if parsed == "invalid" then return false, "usage: npc.inspect.umg [on|off|toggle]" end
    local visible = parsed
    if visible == nil then visible = state.umg_hidden end
    return set_inspect_umg_visible(visible)
end

function M.nudge(value_str)
    if not inspect_hotkeys_active() then return false, "no active NPC Inspect target" end
    local arg = trim(value_str)
    if arg == "" then arg = "reticle" end
    local ok_face, detail = feature_npc_drive.face(arg)
    if not ok_face then return false, detail end
    return true, "nudge " .. tostring(detail)
end

local function npc_inspect_scan_filter(short_name)
    local text = tostring(short_name or ""):lower()
    return text:sub(1, 6) == "bp_ai_" and text:find("character", 1, true) ~= nil
end

function M.scan(value_str)
    local words = split_words(value_str)
    local query = words[1] or "BP_AI_"
    local mode = words[2] or "all"
    local ok_scan, detail = feature_scan.run_scan(query, mode, npc_inspect_scan_filter)
    if not ok_scan then return false, detail end
    return true, tostring(detail or ("scan " .. tostring(query) .. " " .. tostring(mode)))
end

function M.state()
    local ok_write, path_or_err = write_state_json()
    if not ok_write then return false, tostring(path_or_err) end
    local actor = state.actor
    if not is_valid(actor) then return true, "state idle -> " .. tostring(path_or_err) end
    return true, "state " .. object_label(actor) .. " -> " .. tostring(path_or_err)
end

function umg_status_word()
    if widget_ready() then return state.umg_visible and "visible" or "ready" end
    if state.umg_pending then return "pending" end
    if state.umg_err then return "failed" end
    return "idle"
end

function M.status()
    local actor = state.actor
    if not is_valid(actor) then return true, "idle renderer=umg umg=" .. umg_status_word() end
    local camera_input = feature_npc_drive.camera_input_status and feature_npc_drive.camera_input_status() or "mouse=?"
    local err_text = (umg_status_word() == "failed" and state.umg_err) and (" err=" .. tostring(state.umg_err)) or ""
    return true, string.format(
        "target=%s class=%s source=%s overlay=%s snap=%s hud=%s umg_hidden=%s renderer=umg umg=%s updates=%d expr=%s %s%s",
        object_label(actor), feature_field.class_name_of(actor) or "-", tostring(state.source or "unknown"),
        bool_word(state.overlay), state.snap_until and "on" or "off", bool_word(state.hud_visible), bool_word(state.umg_hidden), umg_status_word(),
        state.umg_updates or 0, tostring(state.expr or "auto"), tostring(camera_input),
        err_text
    )
end

function M.select(value_str)
    local actor, source = resolve_target(value_str, false)
    if not actor then return false, source end
    local inspectable, reason = inspectable_reason(actor)
    if not inspectable then return false, tostring(reason) .. ": " .. object_label(actor) end
    local ok_select, detail = select_for_drive(actor, source)
    if not ok_select then return false, detail end
    state.actor = feature_npc_drive.current_actor and feature_npc_drive.current_actor() or actor
    state.source = source
    state.expr = nil
    state.panel_text = nil
    refresh_panel_text(true)
    schedule_umg_update()
    return true, "selected " .. object_label(state.actor)
end

M.is_inspectable_npc = is_inspectable_npc

return M
