-- feature_oculus_config.lua
--
-- Reads ipc\oculus.json for Oculus-specific command sections. Kept
-- separate from feature_oculus.lua so the native state/service layer does
-- not require the command router and create a circular dependency.

local mod_paths = require("mod_paths")
local feature_umg = require("feature_umg")
local feature_oculus = require("feature_oculus")
local feature_oculus_input_guard = require("feature_oculus_input_guard")
local feature_oculus_async = require("feature_oculus_async")

local M = {}

local DEFERRED_HELP_REFRESH_MS = 300
local ACTIVE_WATCHDOG_MS = 1000
local INIT_FREEZE_WORLD_DELAY_MS = 120
local oculus_command_state = {}
local hotkey_help_enabled = true
local last_help_text = nil
local last_help_mode_text = nil
local last_gate_mode = "inactive"
local last_rendered_help_mode = "inactive"
local exit_dispatch = nil
local exit_armed = false
local active_watchdog_started = false
local active_watchdog_generation = 0
local active_watchdog_tick_pending = false

local function json_skip_ws(s, i)
    while i <= #s do
        local c = s:sub(i, i)
        if c ~= " " and c ~= "\t" and c ~= "\n" and c ~= "\r" then return i end
        i = i + 1
    end
    return i
end

local json_decode_value

local function json_decode_string(s, i)
    local out = {}
    local n = #s
    while i <= n do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(out), i + 1
        elseif c == '\\' then
            local nx = s:sub(i + 1, i + 1)
            if nx == '"' or nx == '\\' or nx == '/' then out[#out + 1] = nx; i = i + 2
            elseif nx == 'n' then out[#out + 1] = '\n'; i = i + 2
            elseif nx == 't' then out[#out + 1] = '\t'; i = i + 2
            elseif nx == 'r' then out[#out + 1] = '\r'; i = i + 2
            elseif nx == 'b' then out[#out + 1] = '\b'; i = i + 2
            elseif nx == 'f' then out[#out + 1] = '\f'; i = i + 2
            elseif nx == 'u' then
                local hex = s:sub(i + 2, i + 5)
                local cp = tonumber(hex, 16) or 0
                if cp < 0x80 then
                    out[#out + 1] = string.char(cp)
                elseif cp < 0x800 then
                    out[#out + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
                else
                    out[#out + 1] = string.char(
                        0xE0 + math.floor(cp / 0x1000),
                        0x80 + math.floor(cp / 0x40) % 0x40,
                        0x80 + (cp % 0x40))
                end
                i = i + 6
            else
                return nil, "bad escape \\" .. tostring(nx)
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return nil, "unterminated string"
end

local function json_decode_number(s, i)
    local start = i
    local n = #s
    if s:sub(i, i) == '-' then i = i + 1 end
    while i <= n do
        local c = s:sub(i, i)
        if (c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-' then
            i = i + 1
        else
            break
        end
    end
    local num = tonumber(s:sub(start, i - 1))
    if not num then return nil, "bad number" end
    return num, i
end

local function json_decode_array(s, i)
    local out = {}
    i = json_skip_ws(s, i)
    if s:sub(i, i) == ']' then return out, i + 1 end
    while true do
        local value, j, err = json_decode_value(s, i)
        if value == nil and err then return nil, err end
        out[#out + 1] = value
        i = json_skip_ws(s, j)
        local c = s:sub(i, i)
        if c == ',' then
            i = json_skip_ws(s, i + 1)
        elseif c == ']' then
            return out, i + 1
        else
            return nil, "expected ',' or ']' in array"
        end
    end
end

local function json_decode_object(s, i)
    local out = {}
    i = json_skip_ws(s, i)
    if s:sub(i, i) == '}' then return out, i + 1 end
    while true do
        if s:sub(i, i) ~= '"' then return nil, "expected key string in object" end
        local key, j, err = json_decode_string(s, i + 1)
        if not key then return nil, err end
        i = json_skip_ws(s, j)
        if s:sub(i, i) ~= ':' then return nil, "expected ':' after key" end
        i = json_skip_ws(s, i + 1)
        local value, k, verr = json_decode_value(s, i)
        if value == nil and verr then return nil, verr end
        out[key] = value
        i = json_skip_ws(s, k)
        local c = s:sub(i, i)
        if c == ',' then
            i = json_skip_ws(s, i + 1)
        elseif c == '}' then
            return out, i + 1
        else
            return nil, "expected ',' or '}' in object"
        end
    end
end

json_decode_value = function(s, i)
    i = json_skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '{' then return json_decode_object(s, i + 1) end
    if c == '[' then return json_decode_array(s, i + 1) end
    if c == '"' then return json_decode_string(s, i + 1) end
    if c == 't' and s:sub(i, i + 3) == 'true' then return true, i + 4 end
    if c == 'f' and s:sub(i, i + 4) == 'false' then return false, i + 5 end
    if c == 'n' and s:sub(i, i + 3) == 'null' then return nil, i + 4 end
    if c == '-' or (c >= '0' and c <= '9') then return json_decode_number(s, i) end
    return nil, "unexpected character at position " .. tostring(i) .. ": '" .. tostring(c) .. "'"
end

local function json_decode(text)
    if type(text) ~= "string" or #text == 0 then return nil, "empty" end
    local value, _, err = json_decode_value(text, 1)
    if value == nil and err then return nil, err end
    return value
end

local function read_oculus_doc()
    local dir = mod_paths.ipc_dir()
    if not dir then return nil, "ipc dir unresolved" end
    local path = dir .. "\\oculus.json"
    local f, err = io.open(path, "rb")
    if not f then return nil, "open failed: " .. tostring(err) end
    local body = f:read("*a")
    f:close()
    if not body or #body == 0 then return nil, "file empty" end
    local doc, derr = json_decode(body)
    if not doc then return nil, "parse failed: " .. tostring(derr) end
    return doc
end

local function trim_text(text)
    return tostring(text or ""):match("^%s*(.-)%s*$") or ""
end

local function lower(text)
    return trim_text(text):lower()
end

local function parse_help_visibility(raw)
    local text = lower(raw)
    if text == "" or text == "on" or text == "show" or text == "visible" or text == "enable" or text == "enabled" or text == "1" or text == "true" then
        return true
    end
    if text == "off" or text == "hide" or text == "hidden" or text == "disable" or text == "disabled" or text == "0" or text == "false" then
        return false
    end
    if text == "toggle" then return "toggle" end
    return nil
end

local function is_init_section(section)
    local gate = lower(section.gate)
    if gate == "init" then return true end
    local name = lower(section.name)
    return name == "init" or name == "initialization" or name == "startup" or name == "start up"
end

local function is_exit_section(section)
    local gate = lower(section.gate)
    if gate == "exit" then return true end
    local name = lower(section.name)
    return name == "exit" or name == "shutdown" or name == "cleanup"
end

local function is_recursive_init_verb(line)
    local text = lower(line):match("^%s*(.-)%s*$") or ""
    return text == "camera.oculus.init" or text == "camera.oculus.start"
end

local function is_recursive_exit_verb(line)
    local text = lower(line):match("^%s*(.-)%s*$") or ""
    return text == "camera.oculus.exit" or text == "camera.oculus.stop" or text == "camera.oculus.toggle"
end

local function remember_exit_dispatch(dispatch)
    if type(dispatch) == "function" then exit_dispatch = dispatch end
end

local function grab_active()
    return false
end

local function refresh_gate_mode()
    local active_ok = feature_oculus.require_state("active")
    if not active_ok then last_gate_mode = "inactive"; return last_gate_mode end
    exit_armed = true
    local repair_ok = feature_oculus.require_state("repair")
    if repair_ok then last_gate_mode = "repair"; return last_gate_mode end
    local preview_ok = feature_oculus.require_state("preview")
    if preview_ok then last_gate_mode = "preview"; return last_gate_mode end
    last_gate_mode = "active"
    return last_gate_mode
end

local function current_help_mode()
    return refresh_gate_mode()
end

local function section_help_bucket(section)
    local gate = lower(section.gate)
    local name = lower(section.name)
    if gate == "repair" or name == "repair" then return "repair" end
    if gate == "preview" or name == "build" or name == "build preview" or name == "preview" then return "preview" end
    if gate == "active" or name == "active" then return "active" end
    return nil
end

local function section_in_help(section, mode)
    local bucket = section_help_bucket(section)
    if bucket == "active" then return mode == "active" or mode == "preview" or mode == "repair" end
    return bucket ~= nil and bucket == mode
end

local function pretty_key(raw)
    local value = tostring(raw or "")
    if value == "" then return "" end
    local gamepad = {
        Gamepad_FaceButton_Bottom = "A",
        Gamepad_FaceButton_Right = "B",
        Gamepad_FaceButton_Left = "X",
        Gamepad_FaceButton_Top = "Y",
        Gamepad_LeftShoulder = "LB",
        Gamepad_RightShoulder = "RB",
        Gamepad_LeftTrigger = "LT",
        Gamepad_RightTrigger = "RT",
        Gamepad_LeftThumbstick = "L3",
        Gamepad_RightThumbstick = "R3",
        Gamepad_DPad_Up = "DPad Up",
        Gamepad_DPad_Down = "DPad Down",
        Gamepad_DPad_Left = "DPad Left",
        Gamepad_DPad_Right = "DPad Right",
        Gamepad_Special_Right = "Start",
        Gamepad_Special_Left = "Back",
    }
    if gamepad[value] then return gamepad[value] end
    local keys = {
        LEFT_CONTROL = "Ctrl",
        RIGHT_CONTROL = "Ctrl",
        LEFT_SHIFT = "Shift",
        RIGHT_SHIFT = "Shift",
        LEFT_ALT = "Alt",
        RIGHT_ALT = "Alt",
        ZERO = "0",
        ONE = "1",
        TWO = "2",
        THREE = "3",
        FOUR = "4",
        FIVE = "5",
        SIX = "6",
        SEVEN = "7",
        EIGHT = "8",
        NINE = "9",
        INS = "Insert",
        DEL = "Delete",
        RETURN = "Enter",
        ESCAPE = "Esc",
        SPACE = "Space",
        PAGE_UP = "PgUp",
        PAGE_DOWN = "PgDn",
        LEFT_ARROW = "Left",
        RIGHT_ARROW = "Right",
        UP_ARROW = "Up",
        DOWN_ARROW = "Down",
        LEFT_MOUSE_BUTTON = "Left Click",
        RIGHT_MOUSE_BUTTON = "Right Click",
        MIDDLE_MOUSE_BUTTON = "Wheel Click",
        WHEEL_UP = "Wheel Up",
        WHEEL_DOWN = "Wheel Down",
    }
    return keys[value] or value
end

local function mode_help_label(mode)
    if mode == "repair" then return "Actor Mode" end
    if mode == "preview" then return "Build Mode" end
    return "Oculus Mode"
end

local function format_chord(primary, modifiers)
    if not primary or primary == "" then return "" end
    local parts = {}
    if type(modifiers) == "table" then
        for _, mod in ipairs(modifiers) do
            if mod and mod ~= "" then parts[#parts + 1] = pretty_key(mod) end
        end
    end
    parts[#parts + 1] = pretty_key(primary)
    return table.concat(parts, "+")
end

local function command_hotkey_label(command)
    local kb = format_chord(command.hotkey, command.modifiers)
    local gp = format_chord(command.gamepad_hotkey, command.gamepad_modifiers)
    if kb ~= "" and gp ~= "" then return kb .. " / " .. gp end
    if kb ~= "" then return kb end
    return gp
end

local function compact(text, limit)
    if #text <= limit then return text end
    return text:sub(1, math.max(1, limit - 3)) .. "..."
end

local function command_state_key(section_index, command_index)
    return tostring(section_index) .. ":" .. tostring(command_index)
end

local function command_lines(command, off)
    local list = off and command.verbs_off or command.verbs
    local fallback = off and command.verb_off or command.verb
    local lines = {}
    if type(list) == "table" then
        for _, line in ipairs(list) do
            local text = trim_text(line)
            if text ~= "" then lines[#lines + 1] = text end
        end
    end
    if #lines == 0 then
        local text = trim_text(fallback)
        if text ~= "" then lines[#lines + 1] = text end
    end
    return lines
end

local function command_primary_verb(command)
    local lines = command_lines(command, false)
    return lines[1] or ""
end

local function grab_only_help_command(command)
    local gate = lower(command.help_gate or command.umg_gate or command.display_gate)
    if gate == "grab" or gate == "grabbed" or gate == "camera.grab" or gate == "camera.grab.active" then
        return true
    end

    local verb = lower(command_primary_verb(command))
    return verb:find("^camera%.grab%.cancel") ~= nil
        or verb:find("^camera%.grab%.rotate") ~= nil
        or verb:find("^camera%.grab%.lift") ~= nil
        or verb:find("^camera%.grab%.delta") ~= nil
        or verb:find("^camera%.grab%.scale") ~= nil
end

local function command_help_visible(command)
    local gate = lower(command.help_gate or command.umg_gate or command.display_gate)
    if gate == "hidden" or gate == "hide" or gate == "off" or gate == "none" or gate == "no_help" then
        return false
    end
    if gate == "not_grab" or gate == "not_grabbed" or gate == "no_grab" then
        return grab_active() ~= true
    end
    if grab_only_help_command(command) then
        return grab_active() == true
    end
    return true
end

local function command_tracks_grab_state(command)
    return lower(command_primary_verb(command)):find("^camera%.grab%.toggle") ~= nil
end

local function is_oculus_pawn_time_dilation_line(line)
    return lower(line):find("^player%.field%.set%s+pawn%.oculuscomponent%.oculuspawn%s+customtimedilation%s+") ~= nil
end

local function is_world_time_dilation_line(line)
    local text = lower(line)
    return text:find("^player%.field%.set%s+worldsettings%s+timedilation%s+") ~= nil
        or text:find("^player%.field%.set%s+world%.persistentlevel%.worldsettings%s+timedilation%s+") ~= nil
end

local function schedule_delayed_dispatch(dispatch, verb, delay_ms, label)
    feature_oculus_async.schedule_game_thread(delay_ms, function()
        local ok, detail = dispatch(verb)
        if not ok then
            print("[RSDWTools.oculus] delayed " .. tostring(label or "dispatch") .. " failed: " .. tostring(detail))
        end
    end)
end

local function command_state_text(state_key, command)
    if command_tracks_grab_state(command) then
        if grab_active() == true then return trim_text(command.umg_text) end
        return trim_text(command.umg_text_off)
    end
    local state = oculus_command_state[state_key] or 0
    if state == 1 then return trim_text(command.umg_text) end
    return trim_text(command.umg_text_off)
end

local function format_help_item(command, state_key, label)
    local name = trim_text(command.name)
    local verb = command_primary_verb(command)
    if name == "" then name = verb end
    local state_text = command_state_text(state_key, command)
    if state_text ~= "" then
        return compact(name, 24) .. ": " .. compact(state_text, 24) .. " (" .. label .. ")"
    end
    return compact(name, 30) .. " (" .. label .. ")"
end

local function modifiers_signature(modifiers)
    if type(modifiers) ~= "table" or #modifiers == 0 then return "" end
    local parts = {}
    for _, modifier in ipairs(modifiers) do
        local text = trim_text(modifier):upper()
        if text ~= "" then parts[#parts + 1] = text end
    end
    return table.concat(parts, "+")
end

local function wheel_key(command)
    local key = trim_text(command and command.hotkey):upper()
    if key == "WHEEL_UP" or key == "WHEEL_DOWN" then return key end
    return nil
end

local function wheel_pair_base_name(name)
    local text = trim_text(name)
    local lowered = text:lower()
    if lowered:find("^move ") then
        if lowered:sub(-3) == " up" or lowered:sub(-5) == " down" then return "Move UP/DN" end
        if lowered:sub(-8) == " forward" or lowered:sub(-5) == " back" or lowered:sub(-9) == " backward" then return "Move FWD/BCK" end
    end
    for _, suffix in ipairs({ " up", " down", " left", " right", " forward", " back", " backward" }) do
        if lowered:sub(-#suffix) == suffix then
            return trim_text(text:sub(1, #text - #suffix))
        end
    end
    return text
end

local function wheel_pair_label(command)
    local parts = {}
    if type(command.modifiers) == "table" then
        for _, modifier in ipairs(command.modifiers) do
            if modifier and modifier ~= "" then parts[#parts + 1] = pretty_key(modifier) end
        end
    end
    parts[#parts + 1] = "Scroll Wheel"
    return table.concat(parts, "+")
end

local function wheel_pair_help_item(command, state_key)
    local name = wheel_pair_base_name(command.name)
    if name == "" then name = command_primary_verb(command) end
    local state_text = command_state_text(state_key, command)
    local label = wheel_pair_label(command)
    if state_text ~= "" then
        return compact(name, 24) .. ": " .. compact(state_text, 24) .. " (" .. label .. ")"
    end
    return compact(name, 30) .. " (" .. label .. ")"
end

local function set_help_text(text, mode_text, force)
    mode_text = mode_text or ""
    if force ~= true and text == last_help_text and mode_text == last_help_mode_text then return end
    last_help_text = text
    last_help_mode_text = mode_text
    feature_umg.oculus_help(text, mode_text)
end

local function hide_help_widget()
    last_help_text = nil
    last_help_mode_text = nil
    last_rendered_help_mode = "inactive"
    feature_umg.oculus_help_hide()
end

local function stop_modal_modes_for_inactive(reason)
    if feature_oculus_input_guard.release_all then
        pcall(function() feature_oculus_input_guard.release_all(reason or "oculus.inactive") end)
    end
    if feature_oculus.freeze_stop then
        pcall(function() feature_oculus.freeze_stop(reason or "oculus.inactive") end)
    end
end

local function hide_oculus_overlays()
    hide_help_widget()
    pcall(function() feature_umg.oculus_rotation_overlay(false, "__hide", "", "hide") end)
end

local function stop_active_watchdog()
    active_watchdog_generation = active_watchdog_generation + 1
    active_watchdog_started = false
    active_watchdog_tick_pending = false
end

local function handle_inactive_watchdog()
    print("[RSDWTools.oculus] active watchdog detected inactive Oculus; tearing down overlays.")
    stop_modal_modes_for_inactive("oculus.inactive.watchdog")
    if type(exit_dispatch) == "function" then
        pcall(function() M.run_exit(exit_dispatch, false) end)
    else
        exit_armed = false
    end
    last_gate_mode = "inactive"
    hide_oculus_overlays()
end

local function ensure_active_watchdog()
    if active_watchdog_started then return true, "active watchdog running" end
    if not LoopAsync then return true, "active watchdog skipped: LoopAsync unavailable" end
    active_watchdog_generation = active_watchdog_generation + 1
    local my_generation = active_watchdog_generation
    active_watchdog_started = true
    LoopAsync(ACTIVE_WATCHDOG_MS, function()
        if my_generation ~= active_watchdog_generation then return true end
        if active_watchdog_tick_pending then return false end

        active_watchdog_tick_pending = true
        local function run_watchdog_tick()
            active_watchdog_tick_pending = false
            if my_generation ~= active_watchdog_generation then return end

            if not exit_armed and last_gate_mode == "inactive" then
                stop_active_watchdog()
                return
            end

            local active_ok = feature_oculus.require_state("active")
            if not active_ok then
                handle_inactive_watchdog()
                stop_active_watchdog()
                return
            end

            local mode = refresh_gate_mode()
            if feature_oculus.pause_sync then
                local ok_pause, pause_err = pcall(function() return feature_oculus.pause_sync(mode) end)
                if not ok_pause then
                    print("[RSDWTools.oculus] active watchdog pause sync failed: " .. tostring(pause_err))
                end
            end
            if hotkey_help_enabled and mode ~= last_rendered_help_mode then
                local ok_refresh, refresh_err = pcall(function() M.refresh_hotkey_help(true) end)
                if not ok_refresh then
                    print("[RSDWTools.oculus] active watchdog help refresh failed: " .. tostring(refresh_err))
                end
            end
        end

        if ExecuteInGameThread then
            ExecuteInGameThread(function()
                local ok_tick, tick_err = pcall(run_watchdog_tick)
                if not ok_tick then
                    active_watchdog_tick_pending = false
                    print("[RSDWTools.oculus] active watchdog tick failed: " .. tostring(tick_err))
                end
            end)
        else
            local ok_tick, tick_err = pcall(run_watchdog_tick)
            if not ok_tick then
                active_watchdog_tick_pending = false
                print("[RSDWTools.oculus] active watchdog tick failed: " .. tostring(tick_err))
            end
        end
        return false
    end)
    return true, "active watchdog started"
end

function M.reset_command_states()
    oculus_command_state = {}
    last_help_text = nil
    last_help_mode_text = nil
    last_gate_mode = "inactive"
    last_rendered_help_mode = "inactive"
    exit_armed = false
    stop_active_watchdog()
end

function M.can_attempt_cached_gate(gate)
    local gate_name = lower(gate)
    if gate_name == "" or gate_name == "init" then gate_name = "active" end
    if gate_name == "inactive" then return true end
    local mode = refresh_gate_mode()
    if mode == "inactive" then return false end
    if gate_name == "active" then return true end
    return mode == gate_name
end

function M.cached_gate_mode()
    return last_gate_mode or "inactive"
end

function M.next_command_lines(state_key, command)
    if type(command) ~= "table" then return {}, 0 end
    local mode = lower(command.hotkey_mode)
    local current = oculus_command_state[state_key] or 0
    if mode == "toggle" then
        if current == 0 then return command_lines(command, false), 1 end
        local off_lines = command_lines(command, true)
        if #off_lines > 0 then return off_lines, 0 end
        return command_lines(command, false), 0
    end
    return command_lines(command, false), 1
end

function M.next_command_line(state_key, command)
    local lines, state = M.next_command_lines(state_key, command)
    return lines[1], state
end

function M.commit_command_state(state_key, state)
    if not state_key or state_key == "" then return end
    oculus_command_state[state_key] = state == 1 and 1 or 0
end

local function run_section_commands(doc, dispatch, section_predicate, recursive_predicate, phase)
    local count = 0
    local previous_init_pawn_dilation = false
    local scheduled = 0
    for _, section in ipairs(doc.sections or {}) do
        if section_predicate(section) then
            for _, command in ipairs(section.commands or {}) do
                for _, verb in ipairs(command_lines(command, false)) do
                    if not recursive_predicate(verb) then
                        count = count + 1
                        if phase == "init" and previous_init_pawn_dilation and is_world_time_dilation_line(verb) then
                            schedule_delayed_dispatch(dispatch, verb, INIT_FREEZE_WORLD_DELAY_MS, "world freeze")
                            scheduled = scheduled + 1
                            previous_init_pawn_dilation = false
                        else
                            local ok, detail = dispatch(verb)
                            if not ok then
                                return false, string.format("%s failed at %s: %s",
                                    phase, tostring(command.name or verb), tostring(detail))
                            end
                            previous_init_pawn_dilation = phase == "init" and is_oculus_pawn_time_dilation_line(verb) == true
                        end
                    end
                end
            end
        end
    end
    local suffix = scheduled > 0 and (" scheduled=" .. tostring(scheduled)) or ""
    return true, phase .. " commands=" .. tostring(count) .. suffix
end

function M.run_init(dispatch)
    if type(dispatch) ~= "function" then return false, "no dispatcher" end
    local doc, err = read_oculus_doc()
    if not doc then return true, "init skipped: " .. tostring(err) end
    local ok, detail = run_section_commands(doc, dispatch, is_init_section, is_recursive_init_verb, "init")
    if ok then exit_armed = true end
    return ok, detail
end

function M.run_exit(dispatch, force)
    remember_exit_dispatch(dispatch)
    if type(dispatch) ~= "function" then return false, "no dispatcher" end
    if not force and not exit_armed then return true, "exit skipped: already inactive" end
    exit_armed = false

    local doc, err = read_oculus_doc()
    if not doc then return true, "exit skipped: " .. tostring(err) end
    return run_section_commands(doc, dispatch, is_exit_section, is_recursive_exit_verb, "exit")
end

local function help_items_for_bucket(doc, bucket)
    local items = {}
    for section_index, section in ipairs(doc.sections or {}) do
        local section_bucket = section_help_bucket(section)
        if section_bucket == bucket or bucket == "grab" then
            local paired = {}
            for command_index, command in ipairs(section.commands or {}) do
                local include_command = section_bucket == bucket
                if bucket == "grab" and not include_command then
                    include_command = grab_only_help_command(command) or command_tracks_grab_state(command)
                end
                if include_command and not paired[command_index] then
                    local label = command_hotkey_label(command)
                    local verb = command_primary_verb(command)
                    if label ~= "" and verb ~= "camera.oculus.status" and command_help_visible(command) then
                        local state_key = command_state_key(section_index, command_index)
                        local key = wheel_key(command)
                        local paired_index = nil
                        if key then
                            local base_name = wheel_pair_base_name(command.name):lower()
                            local signature = modifiers_signature(command.modifiers)
                            local opposite = key == "WHEEL_UP" and "WHEEL_DOWN" or "WHEEL_UP"
                            for other_index = command_index + 1, #(section.commands or {}) do
                                local other = section.commands[other_index]
                                if not paired[other_index]
                                    and wheel_key(other) == opposite
                                    and wheel_pair_base_name(other.name):lower() == base_name
                                    and modifiers_signature(other.modifiers) == signature then
                                    paired_index = other_index
                                    break
                                end
                            end
                        end
                        if paired_index then
                            paired[paired_index] = true
                            items[#items + 1] = wheel_pair_help_item(command, state_key)
                        else
                            items[#items + 1] = format_help_item(command, state_key, label)
                        end
                    end
                end
            end
        end
    end
    return items
end

local function help_line(label, items)
    if #items == 0 then return label end
    return compact(label .. ": " .. table.concat(items, "  |  "), 260)
end

local function help_block(label, items)
    if #items == 0 then return label end
    local lines = { label .. ":" }
    for _, item in ipairs(items) do
        lines[#lines + 1] = item
    end
    return table.concat(lines, "\n")
end

local function append_detail_line(lines, detail)
    local text = trim_text(detail)
    if text ~= "" then lines[#lines + 1] = text end
end

function M.hotkey_help_text(mode)
    mode = mode or current_help_mode()
    if mode == "inactive" then return nil, "help hidden: inactive" end

    local doc, err = read_oculus_doc()
    if not doc then return nil, "help skipped: " .. tostring(err) end

    local active_items = help_items_for_bucket(doc, "active")
    local primary = help_line(mode_help_label("active"), active_items)
    local secondary = ""
    local mode_items_count = 0
    if mode == "preview" or mode == "repair" then
        local mode_items = help_items_for_bucket(doc, mode)
        mode_items_count = #mode_items
        local mode_label = mode_help_label(mode)
        secondary = help_block(mode_label, mode_items)
    end

    return primary,
        "help active_entries=" .. tostring(#active_items) .. " mode_entries=" .. tostring(mode_items_count) .. " mode=" .. tostring(mode),
        secondary
end

function M.refresh_hotkey_help(force)
    local mode = current_help_mode()
    if mode == "inactive" then
        hide_help_widget()
        return true, "help hidden: inactive"
    end
    if not hotkey_help_enabled then
        hide_help_widget()
        return true, "help hidden: disabled mode=" .. tostring(mode)
    end
    local text, detail, mode_text = M.hotkey_help_text(mode)
    if not text then return true, detail end
    set_help_text(text, mode_text, force == true)
    last_rendered_help_mode = mode
    return true, detail
end

function M.start_hotkey_help_loop(dispatch)
    remember_exit_dispatch(dispatch)
    refresh_gate_mode()
    local _, watchdog_detail = ensure_active_watchdog()
    return true, "help event-driven; " .. tostring(watchdog_detail)
end

function M.schedule_deferred_help_refresh(delay_ms)
    if not LoopAsync then return true, "deferred help skipped: LoopAsync unavailable" end
    local ms = tonumber(delay_ms) or DEFERRED_HELP_REFRESH_MS
    if ms < 1 then ms = 1 end
    LoopAsync(math.floor(ms + 0.5), function()
        if ExecuteInGameThread then
            ExecuteInGameThread(function()
                pcall(function() M.refresh_hotkey_help() end)
            end)
        else
            pcall(function() M.refresh_hotkey_help() end)
        end
        return true
    end)
    return true, "deferred help refresh " .. tostring(math.floor(ms + 0.5)) .. "ms"
end

function M.show_hotkey_help(dispatch)
    remember_exit_dispatch(dispatch)
    local _, refresh_detail = M.refresh_hotkey_help(true)
    pcall(function() feature_umg.oculus_rotation_overlay(false) end)
    local _, loop_detail = M.start_hotkey_help_loop(dispatch)
    local _, deferred_detail = M.schedule_deferred_help_refresh()
    local _, deferred_late_detail = M.schedule_deferred_help_refresh(DEFERRED_HELP_REFRESH_MS * 3)
    local _, deferred_settle_detail = M.schedule_deferred_help_refresh(DEFERRED_HELP_REFRESH_MS * 6)
    return true, tostring(refresh_detail)
        .. "; " .. tostring(loop_detail)
        .. "; " .. tostring(deferred_detail)
        .. "; " .. tostring(deferred_late_detail)
        .. "; " .. tostring(deferred_settle_detail)
end

function M.set_hotkey_help_visibility(args_text)
    local action = parse_help_visibility(args_text)
    if action == nil then
        return false, "usage: camera.oculus.umg <on|off|toggle> or camera.oculus.help [on|off|toggle]"
    end
    if action == "toggle" then action = not hotkey_help_enabled end

    hotkey_help_enabled = action == true
    if hotkey_help_enabled then
        return M.show_hotkey_help()
    end

    hide_oculus_overlays()
    return true, "help hidden; help event-driven"
end

function M.hide_hotkey_help()
    stop_active_watchdog()
    last_gate_mode = "inactive"
    hide_oculus_overlays()
    return true, "help hidden"
end

return M
