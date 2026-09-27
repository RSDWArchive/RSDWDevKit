-- RSDWTools — UE4SS Lua mod entrypoint.

do
    local raw_sort = table.sort
    table.sort = function(list, comparator)
        if type(list) ~= "table" then
            local trace = ""
            if debug and type(debug.traceback) == "function" then
                local ok_trace, value = pcall(function() return debug.traceback("", 2) end)
                if ok_trace and value then trace = tostring(value):gsub("%s+", " "):sub(1, 260) end
            end
            if print then
                print("[RSDWTools] table.sort skipped non-table: " .. tostring(type(list)) .. " " .. trace)
            end
            return
        end
        return raw_sort(list, comparator)
    end
end

local feature_teleport = require("feature_teleport")
local feature_umg = require("feature_umg")
local feature_hotkeys = require("feature_hotkeys")
local bridge_shm = require("bridge_shm")
local command_line_router = require("command_line_router")
local feature_buildings = require("feature_buildings")

local UEHelpers = nil
do
    local ok, mod = pcall(require, "UEHelpers")
    if ok and type(mod) == "table" then
        UEHelpers = mod
    end
end

-- Round 51: the Insert-key UMG toggle was removed. The UMG layer is
-- now a transient on-screen toast fired by mod rows of kind "umg" (see
-- feature_umg.lua). No background key polling, no debounce, no PC
-- lookup loop -- the SHM bridge + hotkey loader are the only inputs.

local SHM_POLL_MS = 10

local function should_log_bridge_line(line)
    if line == "player.loc" then return false end
    if line == "camera.rig.clear" then return false end
    if tostring(line or ""):sub(1, 19) == "camera.rig.pose.set" then return false end
    return true
end

local function register_console()
    if not RegisterConsoleCommandHandler then
        print("[RSDWTools] RegisterConsoleCommandHandler unavailable.")
        return
    end
    RegisterConsoleCommandHandler("rsdwt_help", function()
        print(
            "[RSDWTools] rsdwt_umg_text <text> | rsdwt_bridge_status | rsdwt_cmd <line> | tele <x> <y> <z> | scan <name_part> [radius|all] | rsdwt_hotkeys_reload"
        )
        return true
    end)
    feature_teleport.register_console()
    feature_umg.register_console()

    RegisterConsoleCommandHandler("rsdwt_bridge_status", function()
        print(string.format("[RSDWTools] bridge_shm available=%s err=%s", tostring(bridge_shm.is_available()), tostring(bridge_shm.last_error())))
        return true
    end)

    -- Toggle the probe.* console debug printer at runtime so users can
    -- silence it once they're past the resolver-stabilization phase.
    RegisterConsoleCommandHandler("rsdwt_probe_debug", function(_, parts)
        local arg = ""
        if type(parts) == "table" and parts[2] then arg = tostring(parts[2]):lower() end
        if arg == "on" or arg == "1" or arg == "true" then
            RSDWTOOLS_PROBE_DEBUG = true
        elseif arg == "off" or arg == "0" or arg == "false" then
            RSDWTOOLS_PROBE_DEBUG = false
        else
            RSDWTOOLS_PROBE_DEBUG = not RSDWTOOLS_PROBE_DEBUG
        end
        print("[RSDWTools] probe debug = " .. tostring(RSDWTOOLS_PROBE_DEBUG))
        return true
    end)

    local function run_line_and_print(line)
        local ok_cmd, result_or_err = command_line_router.handle_line(line)
        if ok_cmd then
            print("[RSDWTools] cmd ok: " .. tostring(result_or_err or "ok"))
        else
            print("[RSDWTools] cmd err: " .. tostring(result_or_err))
        end
        return ok_cmd
    end

    -- Unified manual command surface for present/future EXE line commands.
    RegisterConsoleCommandHandler("rsdwt_cmd", function(Cmd, CommandParts)
        local rest = ""
        if type(CommandParts) == "table" then
            local chunks = {}
            for i = 2, #CommandParts do
                chunks[#chunks + 1] = tostring(CommandParts[i])
            end
            rest = table.concat(chunks, " ")
        end
        if rest == "" and type(Cmd) == "string" then
            rest = Cmd:match("rsdwt_cmd%s*(.*)") or ""
        end
        if type(rest) == "string" then
            rest = rest:match("^%s*(.-)%s*$") or ""
        end
        if rest == "" then
            print("[RSDWTools] usage: rsdwt_cmd <line>  (examples: rsdwt_cmd tele 0 0 300 | rsdwt_cmd scan goblin all)")
            return true
        end
        run_line_and_print(rest)
        return true
    end)

    -- Direct user-friendly commands (same path as EXE line commands).
    RegisterConsoleCommandHandler("tele", function(Cmd, CommandParts)
        local rest = ""
        if type(CommandParts) == "table" then
            local chunks = {}
            for i = 2, #CommandParts do
                chunks[#chunks + 1] = tostring(CommandParts[i])
            end
            rest = table.concat(chunks, " ")
        end
        if rest == "" and type(Cmd) == "string" then
            rest = Cmd:match("tele%s*(.*)") or ""
        end
        run_line_and_print("tele " .. rest)
        return true
    end)

    RegisterConsoleCommandHandler("scan", function(Cmd, CommandParts)
        local rest = ""
        if type(CommandParts) == "table" then
            local chunks = {}
            for i = 2, #CommandParts do
                chunks[#chunks + 1] = tostring(CommandParts[i])
            end
            rest = table.concat(chunks, " ")
        end
        if rest == "" and type(Cmd) == "string" then
            rest = Cmd:match("scan%s*(.*)") or ""
        end
        if rest == "" then
            print("[RSDWTools] usage: scan <name_part> [radius|all]")
            return true
        end
        run_line_and_print("scan " .. rest)
        return true
    end)
end

local function start_shm_command_loop()
    local ok = bridge_shm.start()
    if not ok then
        print("[RSDWTools] bridge_shm unavailable: " .. tostring(bridge_shm.last_error()))
        return
    end
    if not LoopAsync then
        print("[RSDWTools] LoopAsync missing; bridge_shm loop not started.")
        return
    end
    feature_buildings.set_delivery_external_pump(true)
    LoopAsync(SHM_POLL_MS, function()
        local line = bridge_shm.poll_request()
        if line and line ~= "" then
            -- Dispatch on the game thread (required for any UObject work).
            -- The body is pcall'd so a Lua error inside a router handler can't
            -- escape into UE4SS's callback site, and the client always gets an
            -- ack so it doesn't spin on `ack timeout`.
            ExecuteInGameThread(function()
                local ok, ok_cmd, result_or_err = pcall(function()
                    return command_line_router.handle_line(line)
                end)
                if not ok then
                    bridge_shm.write_ack("err lua: " .. tostring(ok_cmd))
                    print("[RSDWTools] bridge_shm handler error: " .. tostring(ok_cmd))
                    return
                end
                if ok_cmd then
                    bridge_shm.write_ack(tostring(result_or_err or "ok"))
                else
                    bridge_shm.write_ack("err " .. tostring(result_or_err))
                end
            end)
            if line then
                -- Suppress chatty high-frequency polls (e.g. the WPF Map
                -- tab calls player.loc at 2 Hz) so the UE4SS console stays
                -- usable for debugging other features. Add more verbs to
                -- this set as polling clients are added.
                if should_log_bridge_line(line) then
                    print("[RSDWTools] bridge_shm recv: " .. tostring(line))
                end
            end
        end
        if not line then
            feature_buildings.delivery_pump(SHM_POLL_MS)
        end
        return false
    end)
    print(string.format("[RSDWTools] bridge_shm poll loop ~%dms", SHM_POLL_MS))
end

print("[RSDWTools] Loading features (UMG toast + Teleport + Scan + Bridge).")
register_console()
feature_hotkeys.load_and_register()
if RegisterConsoleCommandHandler then
    RegisterConsoleCommandHandler("rsdwt_hotkeys_reload", function()
        feature_hotkeys.reload()
        return true
    end)
    -- Smoke-test logger for gamepad input. `rsdwt_gamepad_log on|off|toggle`.
    -- Prints every controller press (with held buttons) to the UE4SS
    -- console so you can verify XInput is wired without binding any
    -- chord first.
    RegisterConsoleCommandHandler("rsdwt_gamepad_log", function(_, parts)
        local arg = ""
        if type(parts) == "table" and parts[2] then arg = tostring(parts[2]):lower() end
        local cur = false
        if arg == "on" or arg == "1" or arg == "true" then cur = true
        elseif arg == "off" or arg == "0" or arg == "false" then cur = false
        else
            -- toggle: read previous state from the module
            cur = not (rawget(_G, "RSDWTOOLS_GAMEPAD_LOG") == true)
        end
        rawset(_G, "RSDWTOOLS_GAMEPAD_LOG", cur)
        feature_hotkeys.set_gamepad_log(cur)
        return true
    end)
    -- Round 55 diagnostics: dump the currently-registered gamepad chord
    -- table so the user can verify "the chord I bound is actually what
    -- the tick loop is looking up". Also live-pings XInput once.
    RegisterConsoleCommandHandler("rsdwt_gamepad_status", function()
        feature_hotkeys.dump_gamepad_status()
        return true
    end)
end

start_shm_command_loop()

if RegisterHook then
    local ok, pre_id, post_id = pcall(function()
        return RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
            feature_umg.on_player_ready()
            feature_hotkeys.on_player_ready()
        end)
    end)
    if ok then
        print("[RSDWTools] UMG ClientRestart hook registered. pre=" .. tostring(pre_id) .. " post=" .. tostring(post_id))
    else
        print("[RSDWTools] UMG ClientRestart hook failed; widget will appear on first toggle.")
    end
end
