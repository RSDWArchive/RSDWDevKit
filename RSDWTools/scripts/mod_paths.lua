-- mod_paths.lua
--
-- Centralized resolver for filesystem paths owned by the RSDWTools mod.
-- Lifted out of feature_ui.lua so feature_probe (and any future
-- diagnostics) can write sentinel/log files to the same `ipc/` folder
-- without duplicating the IterateGameDirectories dance.
--
-- All paths returned use Windows backslash separators because the host
-- game is Win64 ; UE4SS exposes absolute paths in the same form.

local M = {}

local function get_win64_base()
    if not IterateGameDirectories then return nil end
    local ok, dirs = pcall(IterateGameDirectories)
    if not ok or type(dirs) ~= "table" then return nil end
    if type(dirs.Game) == "table" and dirs.Game.Binaries and dirs.Game.Binaries.Win64 then
        local p = dirs.Game.Binaries.Win64.__absolute_path
        if type(p) == "string" and #p > 0 then return p end
    end
    -- Fallback: scan all top-level entries for the first non-Engine
    -- Win64 binaries directory. Mirrors the original feature_ui logic.
    for _, e in pairs(dirs) do
        if type(e) == "table" and e.Binaries and e.Binaries.Win64 then
            local p = e.Binaries.Win64.__absolute_path
            if type(p) == "string" and #p > 0 and not p:find("\\Engine\\", 1, true) then
                return p
            end
        end
    end
    return nil
end

-- Mod root: <Win64>\ue4ss\Mods\RSDWTools
function M.mod_root()
    local base = get_win64_base()
    if not base then return nil end
    return base .. "\\ue4ss\\Mods\\RSDWTools"
end

-- IPC folder where transient probe state and outbound JSON live.
function M.ipc_dir()
    local root = M.mod_root()
    if not root then return nil end
    return root .. "\\ipc"
end

-- ipc\building subfolder; one .json per saved building export.
-- Best-effort mkdir so callers can write immediately. Returns nil if
-- the parent ipc dir cannot be resolved (game not loaded yet).
function M.buildings_dir()
    local d = M.ipc_dir(); if not d then return nil end
    local path = d .. "\\building"
    -- `mkdir` errors on Windows if the directory exists ; the
    -- `if not exist` guard keeps the call silent in the common case.
    pcall(os.execute, ('if not exist "%s" mkdir "%s"'):format(path, path))
    return path
end

-- ipc\assets subfolder; dumps from world.assets.* verbs land here so
-- they stay isolated from the building-specific outputs.
function M.assets_dir()
    local d = M.ipc_dir(); if not d then return nil end
    local path = d .. "\\assets"
    pcall(os.execute, ('if not exist "%s" mkdir "%s"'):format(path, path))
    return path
end

-- ipc\cvars subfolder; cvars.dump writes a marker + (eventually) parsed
-- runtime CVar JSON here. The actual UE log it triggers a write into
-- lives under %LOCALAPPDATA%\<Project>\Saved\Logs\ ; the offline Python
-- parser is what populates the structured JSON.
function M.cvars_dir()
    local d = M.ipc_dir(); if not d then return nil end
    local path = d .. "\\cvars"
    pcall(os.execute, ('if not exist "%s" mkdir "%s"'):format(path, path))
    return path
end

-- Specific files we care about. Returning nil signals "couldn't resolve
-- the mod root" ; callers should treat that as a soft failure (no disk
-- I/O this session) rather than crashing.
function M.sentinel_file()
    local d = M.ipc_dir(); if not d then return nil end
    return d .. "\\probe_sentinel.txt"
end

function M.crash_log_file()
    local d = M.ipc_dir(); if not d then return nil end
    return d .. "\\probe_crash_log.txt"
end

-- Atomic write helper. Writes `body` to `path.tmp` then renames. Removes
-- any stale destination first because `os.rename` will not overwrite on
-- Windows. Returns (true, path) or (false, reason).
function M.write_atomic(path, body)
    if not path then return false, "no path" end
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return false, "open tmp failed: " .. tostring(err) end
    local ok = pcall(function() f:write(body); f:close() end)
    if not ok then return false, "write tmp failed" end
    os.remove(path)
    if not os.rename(tmp, path) then return false, "rename failed" end
    return true, path
end

-- Append a single line (newline-terminated) to `path`. Creates the file
-- if missing. No atomicity needed for an append-only diagnostics log.
function M.append_line(path, line)
    if not path then return false, "no path" end
    local f, err = io.open(path, "ab")
    if not f then return false, "open append failed: " .. tostring(err) end
    local ok = pcall(function() f:write(line); f:write("\n"); f:close() end)
    if not ok then return false, "append write failed" end
    return true, path
end

-- Best-effort delete. Used to clear the sentinel after a clean probe.
-- Missing file is not an error.
function M.remove_file(path)
    if not path then return false end
    return os.remove(path) ~= nil
end

-- Best-effort read. Returns nil if the file is missing.
function M.read_file(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    return body
end

return M
