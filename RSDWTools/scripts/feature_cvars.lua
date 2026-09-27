-- feature_cvars.lua
--
-- Runtime CVar / console command dumper.
--
-- UE4SS Lua does not expose IConsoleManager directly, so the practical
-- way to enumerate every live CVar without touching C++ is to ask the
-- engine itself : the stock `Help`, `DumpConsoleCommands` and
-- `DumpConsoleVariables` console commands all walk IConsoleManager and
-- emit complete listings :
--
--   Help                  -> writes <Saved>\HelpConsoleCommands.html
--                            (one row per CVar/cmd, with help text)
--   DumpConsoleCommands   -> dumps every cmd to the game log
--   DumpConsoleVariables  -> dumps every CVar (name + current value)
--                            to the game log, prefixed "LogConsoleResponse:"
--
-- We dispatch all three through KismetSystemLibrary::ExecuteConsoleCommand
-- (the same path feature_player.summon uses, since the bare
-- APlayerController::ConsoleCommand reflection call traps with
-- "UObject instance is nullptr" - this is a plain C++ method, not a
-- UFunction, so UE4SS can't bind a real `this`).
--
-- We do NOT try to read or parse the log from Lua. The log path is
--   %LOCALAPPDATA%\<Project>\Saved\Logs\<Project>.log
-- which lives outside the game install tree, and the engine flushes
-- asynchronously - polling for the dump output from Lua is fragile.
--
-- Instead we drop a small marker JSON into ipc\cvars\ recording :
--   - timestamp the dump was dispatched
--   - the three commands we issued
--   - the expected log path (so the offline Python parser knows where
--     to look)
--   - the expected Help.html path
--
-- The companion offline tool tools\Parse-RuntimeCVars.py reads those
-- two files, parses them into structured JSON, and merges with the
-- shipped-defaults database from Scrape-ShippedDefaults.py.
--
-- Verbs exposed (wired in command_line_router.lua) :
--   cvars.dump       - dispatch Help + DumpConsoleCommands + DumpConsoleVariables
--                      and write the marker file
--   cvars.set        - dispatch one raw CVar assignment
--   cvars.filming    - apply/restore a high-distance filming preset
--
-- Marker JSON shape :
--   {
--     "schema_version": 1,
--     "dispatched_at_unix": 1715000000,
--     "dispatched_at_iso":  "2026-05-13T23:55:00",
--     "commands": ["Help", "DumpConsoleCommands", "DumpConsoleVariables"],
--     "expected_log_hint":  "%LOCALAPPDATA%\\<Project>\\Saved\\Logs\\<Project>.log",
--     "expected_help_html": "%LOCALAPPDATA%\\<Project>\\Saved\\HelpConsoleCommands.html"
--   }

local M = {}

local mod_paths = require("mod_paths")

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_valid(obj)
    if type(obj) ~= "userdata" then return false end
    if not obj.IsValid then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v and true or false
end

-- The trio of console commands we fire. Order matters only for log
-- readability ; Help writes the HTML, the two Dump* dump to the log.
local DUMP_COMMANDS = {
    "Help",
    "DumpConsoleCommands",
    "DumpConsoleVariables",
}

-- Local clone of feature_player's KismetSystemLibrary trick.  We avoid
-- requiring feature_player here because it pulls a heavy dependency
-- chain (and we only need the CDO + ExecuteConsoleCommand call).
local function get_ksl_cdo()
    if not StaticFindObject then return nil end
    local ok, cdo = pcall(StaticFindObject, "/Script/Engine.Default__KismetSystemLibrary")
    if ok and is_valid(cdo) then return cdo end
    return nil
end

local function get_local_pc()
    -- Mirror feature_player.summon : prefer the IsLocalController()
    -- resolver in feature_net so we always pick the local PC even when
    -- a multiplayer host is in scope.
    local ok_req, feature_net = pcall(require, "feature_net")
    if ok_req and feature_net and feature_net.local_controller then
        local ok_pc, pc = pcall(function() return feature_net.local_controller() end)
        if ok_pc and is_valid(pc) then return pc end
    end
    return nil
end

local function execute_console(command)
    command = trim(command)
    if command == "" then return false, "empty console command" end
    local pc = get_local_pc()
    if not pc then return false, "no local player controller" end

    if pc.SendToConsole then
        local ok = pcall(function() pc:SendToConsole(command) end)
        if ok then return true, "SendToConsole" end
    end

    local ksl = get_ksl_cdo()
    if ksl and ksl.ExecuteConsoleCommand then
        local ok = pcall(function() ksl:ExecuteConsoleCommand(pc, command, pc) end)
        if ok then return true, "ExecuteConsoleCommand" end
    end

    return false, "no console execution path"
end

local FILMING_ON = {
    "sg.ViewDistanceQuality 4",
    "sg.FoliageQuality 4",
    "sg.LandscapeQuality 4",
    "sg.TextureQuality 4",
    "r.ViewDistanceScale 8",
    "r.StaticMeshLODDistanceScale 0.1",
    "r.SkeletalMeshLODBias -2",
    "r.SkeletalMeshLODRadiusScale 2",
    "foliage.LODDistanceScale 6",
    "foliage.CullDistanceScale 4",
    "grass.CullDistanceScale 4",
    "r.HLOD.DistanceScale 4",
    "r.Shadow.DistanceScale 3",
    "r.Streaming.Boost 4",
    "r.Streaming.FramesForFullUpdate 1",
    "r.Streaming.UseAllMips 1",
    "r.Streaming.FullyLoadUsedTextures 1",
    "wp.Runtime.OverrideRuntimeSpatialHashLoadingRange 307200",
}

local FILMING_EXTREME = {
    "sg.ViewDistanceQuality 4",
    "sg.FoliageQuality 4",
    "sg.LandscapeQuality 4",
    "sg.TextureQuality 4",
    "r.ViewDistanceScale 12",
    "r.StaticMeshLODDistanceScale 0.05",
    "r.SkeletalMeshLODBias -3",
    "r.SkeletalMeshLODRadiusScale 3",
    "foliage.LODDistanceScale 10",
    "foliage.CullDistanceScale 8",
    "grass.CullDistanceScale 8",
    "foliage.ForceLOD 0",
    "r.ForceLOD 0",
    "r.HLOD.DistanceScale 8",
    "r.Shadow.DistanceScale 4",
    "r.Streaming.Boost 6",
    "r.Streaming.FramesForFullUpdate 1",
    "r.Streaming.UseAllMips 1",
    "r.Streaming.FullyLoadUsedTextures 1",
    "wp.Runtime.OverrideRuntimeSpatialHashLoadingRange 614400",
}

local FILMING_OFF = {
    "sg.ViewDistanceQuality 3",
    "sg.FoliageQuality 3",
    "sg.LandscapeQuality 3",
    "sg.TextureQuality 3",
    "r.ViewDistanceScale 1",
    "r.StaticMeshLODDistanceScale 1",
    "r.SkeletalMeshLODBias 0",
    "r.SkeletalMeshLODRadiusScale 1",
    "foliage.LODDistanceScale 1",
    "foliage.CullDistanceScale 1",
    "grass.CullDistanceScale 1",
    "foliage.ForceLOD -1",
    "r.ForceLOD -1",
    "r.HLOD.DistanceScale 1",
    "r.Shadow.DistanceScale 1",
    "r.Streaming.Boost 1",
    "r.Streaming.FramesForFullUpdate 5",
    "r.Streaming.UseAllMips 0",
    "r.Streaming.FullyLoadUsedTextures 0",
    "wp.Runtime.OverrideRuntimeSpatialHashLoadingRange -1",
}

local function apply_commands(commands, label)
    local via_counts = {}
    for i, cmd in ipairs(commands) do
        local ok, via = execute_console(cmd)
        if not ok then
            return false, string.format("%s failed after %d/%d: %s", label, i - 1, #commands, tostring(via))
        end
        via_counts[via] = (via_counts[via] or 0) + 1
    end
    local vias = {}
    for via, count in pairs(via_counts) do vias[#vias + 1] = via .. "=" .. tostring(count) end
    table.sort(vias)
    return true, string.format("%s applied %d cvars (%s)", label, #commands, table.concat(vias, ", "))
end

-- Minimal JSON encoder for the marker file. Hand-rolled to avoid
-- pulling a dependency just for a 6-key flat object.  Strings escape
-- backslash, double-quote and the standard control chars.
local function json_escape(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"',  '\\"')
    s = s:gsub("\b", "\\b")
    s = s:gsub("\f", "\\f")
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return s
end

local function encode_json_marker(t)
    -- Stable key order for diffability.
    local keys = {
        "schema_version", "dispatched_at_unix", "dispatched_at_iso",
        "commands", "expected_log_hint", "expected_help_html",
    }
    local parts = { "{" }
    for i, k in ipairs(keys) do
        local v = t[k]
        if v ~= nil then
            local enc
            if type(v) == "number" then
                enc = string.format("%d", v)
            elseif type(v) == "table" then
                local arr = { "[" }
                for j, item in ipairs(v) do
                    arr[#arr + 1] = '"' .. json_escape(item) .. '"'
                    if j < #v then arr[#arr + 1] = "," end
                end
                arr[#arr + 1] = "]"
                enc = table.concat(arr)
            else
                enc = '"' .. json_escape(v) .. '"'
            end
            parts[#parts + 1] = '"' .. k .. '":' .. enc
            if i < #keys then parts[#parts + 1] = "," end
        end
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

-- Public : dispatch the trio of dump commands and drop a marker.
function M.dump()
    local ksl = get_ksl_cdo()
    if not ksl then return false, "KismetSystemLibrary CDO not found" end
    local pc = get_local_pc()
    if not pc then return false, "no local player controller" end

    local issued = {}
    for _, cmd in ipairs(DUMP_COMMANDS) do
        local ok, err = pcall(function() ksl:ExecuteConsoleCommand(pc, cmd, pc) end)
        if not ok then
            return false, ("ExecuteConsoleCommand(%s) failed: %s"):format(cmd, tostring(err))
        end
        issued[#issued + 1] = cmd
    end

    local dir = mod_paths.cvars_dir()
    if not dir then
        -- Commands still fired ; just no marker.
        return true, ("dispatched %d commands (no ipc dir)"):format(#issued)
    end

    local now = os.time()
    local marker = {
        schema_version     = 1,
        dispatched_at_unix = now,
        dispatched_at_iso  = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
        commands           = issued,
        -- Path hints are documentation for the offline parser ; we
        -- don't try to expand env vars from Lua because the parser
        -- runs under powershell where %LOCALAPPDATA% is trivially
        -- resolvable.
        expected_log_hint  = "%LOCALAPPDATA%\\<Project>\\Saved\\Logs\\<Project>.log",
        expected_help_html = "%LOCALAPPDATA%\\<Project>\\Saved\\HelpConsoleCommands.html",
    }
    local body = encode_json_marker(marker)
    local path = dir .. "\\cvars-dump-marker.json"
    local ok, detail = mod_paths.write_atomic(path, body)
    if not ok then
        return true, ("dispatched %d commands (marker write failed: %s)"):format(#issued, tostring(detail))
    end
    return true, ("dispatched %d commands -> marker %s"):format(#issued, path)
end

function M.set(args)
    local body = trim(args)
    local name, value = body:match("^(%S+)%s+(.+)$")
    if not name or trim(value) == "" then
        return false, "usage: cvars.set <name> <value>"
    end
    local cmd = name .. " " .. trim(value)
    local ok, via = execute_console(cmd)
    if not ok then return false, tostring(via) end
    return true, cmd .. " via " .. tostring(via)
end

function M.filming(args)
    local raw = trim(args):lower()
    if raw == "" or raw == "on" or raw == "1" or raw == "true" or raw == "cine" or raw == "cinematic" then
        return apply_commands(FILMING_ON, "filming-on")
    end
    if raw == "extreme" or raw == "ultra" or raw == "max" then
        return apply_commands(FILMING_EXTREME, "filming-extreme")
    end
    if raw == "off" or raw == "0" or raw == "false" or raw == "default" or raw == "defaults" or raw == "restore" then
        return apply_commands(FILMING_OFF, "filming-off")
    end
    return false, "usage: cvars.filming <on|off>"
end

return M
