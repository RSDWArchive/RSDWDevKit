-- Scan feature: actor search, writes structured results to ipc/scan_results.json.
--
-- NOTE: the output folder is called `ipc/` for historical reasons (first build
-- targeted a dedicated IPC folder). Functionally it's just a scratch cache --
-- the command itself is delivered via the shared-memory bridge, and this file
-- is only the bulk result payload that the bridge line can't carry. We keep
-- the path as-is so we don't have to create new directories at runtime, which
-- would require spawning cmd.exe from the game thread (known crash risk).
--
-- Command shape from router:
--   scan <name_part>            -> mode = "all" (no radius filter)
--   scan <name_part> <radius>   -> mode = "radius"
--   scan <name_part> all        -> mode = "all" (explicit)
--
-- Result schema (cache/scan_results.json):
--   {
--     "ok": true,
--     "query": "BP_OreNode",
--     "mode": "all" | "radius",
--     "radius": 5000,           -- present only when mode == "radius"
--     "count": 42,
--     "generated_unix": 1700000000,
--     "results": {
--       "1": { "name": "BP_OreNode_Prefab_C_12", "distance": 432.5 },
--       "2": { "name": "BP_OreNode_Prefab_C_7",  "distance": 1128.0 },
--       ...
--     }
--   }
--
-- Entries are keyed by stringified 1-based index because json_min does not
-- support arrays. WPF parses this as a dictionary and iterates in numeric order.
-- `distance` is omitted in "all" mode.
--
-- IMPORTANT: `name` is the actor's short name (GetName()), not GetFullName().
-- No spaces, unique per instance, matches what feature_actor looks up.

local M = {}

local DEFAULT_RADIUS = 5000

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function get_win64_base()
    if not IterateGameDirectories then
        return nil
    end
    local ok, dirs = pcall(IterateGameDirectories)
    if not ok or type(dirs) ~= "table" then
        return nil
    end
    if type(dirs.Game) == "table" and dirs.Game.Binaries and dirs.Game.Binaries.Win64 then
        local p = dirs.Game.Binaries.Win64.__absolute_path
        if type(p) == "string" and #p > 0 then
            return p
        end
    end
    for _, entry in pairs(dirs) do
        if type(entry) == "table" and entry.Binaries and entry.Binaries.Win64 then
            local p = entry.Binaries.Win64.__absolute_path
            if type(p) == "string" and #p > 0 and not p:find("\\Engine\\", 1, true) then
                return p
            end
        end
    end
    return nil
end

local function join_path(a, b)
    if a:sub(-1) == "\\" or a:sub(-1) == "/" then
        return a .. b
    end
    return a .. "\\" .. b
end

local function get_scan_results_paths()
    local base = get_win64_base()
    if not base then
        return nil, nil
    end
    local dir = join_path(join_path(join_path(join_path(base, "ue4ss"), "Mods"), "RSDWTools"), "ipc")
    local out_path = join_path(dir, "scan_results.json")
    local tmp_path = join_path(dir, "scan_results.json.tmp")
    return out_path, tmp_path
end

local feature_net = require("feature_net")
local function get_local_player_controller()
    return feature_net.local_controller()
end

local function actor_location(actor)
    if actor and actor.IsValid and actor:IsValid() then
        if actor.K2_GetActorLocation then
            local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
            if ok and loc then
                return loc
            end
        end
        if actor.GetActorLocation then
            local ok, loc = pcall(function() return actor:GetActorLocation() end)
            if ok and loc then
                return loc
            end
        end
    end
    return nil
end

local function get_player_location()
    local pc = get_local_player_controller()
    if not pc or not pc.IsValid or not pc:IsValid() then
        return nil
    end
    local ok_pawn, pawn = pcall(function() return pc.Pawn end)
    if not ok_pawn or not pawn or not pawn.IsValid or not pawn:IsValid() then
        return nil
    end
    return actor_location(pawn)
end

-- Short, instance-unique name with no spaces. Matches what feature_actor.lua
-- uses to resolve actors in action verbs.
local function actor_short_name(actor)
    if not actor or not actor.IsValid or not actor:IsValid() then
        return nil
    end
    if actor.GetName then
        local ok, n = pcall(function() return actor:GetName() end)
        if ok and type(n) == "string" and n ~= "" then
            return n
        end
    end
    return nil
end

-- Full object path, e.g. "BP_Foo_C /Game/Maps/MainMap.MainMap:PersistentLevel.BP_Foo_C_12".
-- We use this as the primary text to match the query against, to mirror what
-- the legacy RSDTools `list` command did (it was stable on this game build).
local function actor_full_name(actor)
    if actor.GetFullName then
        local ok, n = pcall(function() return actor:GetFullName() end)
        if ok and type(n) == "string" and n ~= "" then
            return n
        end
    end
    return nil
end

-- Extracts the per-instance short name from a full name, e.g.
-- "BP_Foo_C /Game/.../PersistentLevel.BP_Foo_C_12" -> "BP_Foo_C_12".
-- This lets us derive the action identifier without a second native call,
-- which would double our exposure to AVs on bad objects.
local function short_name_from_full(full_name)
    if type(full_name) ~= "string" or full_name == "" then
        return nil
    end
    local after_dot = full_name:match("%.([^%.]+)$")
    if after_dot and after_dot ~= "" then
        return after_dot
    end
    -- Fallback: everything after the last space, then after the last dot.
    local tail = full_name:match("([^%s]+)$") or full_name
    local piece = tail:match("%.([^%.]+)$")
    return piece and piece ~= "" and piece or tail
end

-- Handrolled JSON writer because json_min doesn't support arrays. We emit a
-- dictionary keyed by stringified index so both producer and consumer stay
-- flat. Values are small objects of the shape { "name": "...", "distance": N }.
local function encode_number(n)
    if type(n) ~= "number" or n ~= n or n == math.huge or n == -math.huge then
        return "null"
    end
    return string.format("%.6g", n)
end

local function encode_string(s)
    local escaped = tostring(s or "")
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
    return '"' .. escaped .. '"'
end

local function encode_entry(entry)
    if entry.distance then
        return '{"name":' .. encode_string(entry.name) .. ',"distance":' .. encode_number(entry.distance) .. '}'
    end
    return '{"name":' .. encode_string(entry.name) .. '}'
end

local function encode_results_map(entries)
    local parts = {}
    for i, entry in ipairs(entries) do
        if #parts > 0 then parts[#parts + 1] = "," end
        parts[#parts + 1] = '"' .. tostring(i) .. '":' .. encode_entry(entry)
    end
    return "{" .. table.concat(parts) .. "}"
end

local function encode_payload(query, mode, radius, entries)
    local parts = {}
    parts[#parts + 1] = '"ok":true'
    parts[#parts + 1] = '"query":' .. encode_string(query)
    parts[#parts + 1] = '"mode":' .. encode_string(mode)
    if mode == "radius" and radius then
        parts[#parts + 1] = '"radius":' .. encode_number(radius)
    end
    parts[#parts + 1] = '"count":' .. tostring(#entries)
    parts[#parts + 1] = '"generated_unix":' .. tostring(os.time())
    parts[#parts + 1] = '"results":' .. encode_results_map(entries)
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Write the JSON result file. Pure Lua io only -- no os.execute / mkdir, since
-- spawning cmd.exe from the game thread has been observed to crash the
-- process. The ipc/ folder is guaranteed to exist at install time (it ships
-- with the mod payload), so opening the file directly is safe.
local function write_json_atomic(body)
    local out_path, tmp_path = get_scan_results_paths()
    if not out_path then
        return false, "scan results path unavailable"
    end

    local f, open_err = io.open(tmp_path, "wb")
    if not f then
        return false, "open tmp file failed: " .. tostring(open_err)
    end
    local ok_write, write_err = pcall(function()
        f:write(body)
        f:close()
    end)
    if not ok_write then
        return false, "write tmp file failed: " .. tostring(write_err)
    end
    os.remove(out_path)
    local ok_rename = os.rename(tmp_path, out_path)
    if not ok_rename then
        return false, "rename into place failed"
    end
    return true, out_path
end

function M.run_scan(query, mode, accept_entry)
    local needle = trim(query)
    if needle == "" then
        return false, "usage: scan <name_part> [radius|all]"
    end
    local accept = type(accept_entry) == "function" and accept_entry or nil

    local use_all = false
    local radius = DEFAULT_RADIUS
    local normalized_mode = trim(mode):lower()
    if normalized_mode == "all" or normalized_mode == "" then
        -- Default is "all" now. Radius is only applied when an explicit number is given.
        use_all = true
        radius = nil
    else
        local parsed = tonumber(normalized_mode)
        if not parsed then
            return false, "second arg must be radius number or 'all'"
        end
        radius = parsed
    end

    local actors
    local ok_find = pcall(function()
        actors = FindAllOf and FindAllOf("Actor") or nil
        if type(actors) ~= "table" then
            actors = FindAllOf and FindAllOf("AActor") or nil
        end
    end)
    if not ok_find or type(actors) ~= "table" then
        return false, "actor enumeration unavailable"
    end

    print(string.format("[RSDWTools] scan: enumerating %d actors (q='%s', mode=%s)",
        #actors, needle, use_all and "all" or "radius"))

    local radius_sq = radius and (radius * radius) or nil
    local my_loc = nil
    if radius_sq then
        my_loc = get_player_location()
        if not my_loc then
            return false, "radius mode requires player location"
        end
    end

    -- Per-object work is pcall-wrapped so a single bad UObject can't abort
    -- the whole scan. pcall can't stop a native AV, but it catches every
    -- Lua-level error that UE4SS property accesses can raise.
    --
    -- Matching uses GetFullName() to mirror the legacy RSDTools `list`
    -- command, which was stable on this game build. The identifier we emit
    -- for actor.* verbs is the short instance name extracted from the full
    -- name (no second native call needed).
    --
    -- Progress is printed every PROGRESS_STEP actors so if we still crash on
    -- a specific object, the log tells us which bucket it was in.
    local PROGRESS_STEP = 500
    local q = needle:lower()
    local hits = {}
    local skipped = 0
    local total = #actors
    for i, obj in ipairs(actors) do
        if (i % PROGRESS_STEP) == 0 then
            print(string.format("[RSDWTools] scan: progress %d/%d (hits=%d, skipped=%d)",
                i, total, #hits, skipped))
        end

        local ok_iter, err_iter = pcall(function()
            if type(obj) ~= "userdata" then
                return
            end
            if not obj.IsValid then
                return
            end
            local ok_valid, valid = pcall(function() return obj:IsValid() end)
            if not ok_valid or not valid then
                return
            end

            local full = actor_full_name(obj)
            if not full then
                return
            end
            if not full:lower():find(q, 1, true) then
                return
            end

            local short = short_name_from_full(full)
            if not short or short == "" then
                return
            end
            if accept then
                local ok_accept, accepted = pcall(accept, short, full, obj)
                if not ok_accept or not accepted then
                    return
                end
            end

            if radius_sq then
                local loc = actor_location(obj)
                if not loc then
                    return
                end
                local dx = loc.X - my_loc.X
                local dy = loc.Y - my_loc.Y
                local dz = loc.Z - my_loc.Z
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 <= radius_sq then
                    hits[#hits + 1] = { name = short, d2 = d2 }
                end
            else
                hits[#hits + 1] = { name = short, d2 = nil }
            end
        end)
        if not ok_iter then
            skipped = skipped + 1
            if skipped <= 5 then
                print(string.format("[RSDWTools] scan: skipped actor #%d (err=%s)", i, tostring(err_iter)))
            end
        end
    end

    print(string.format("[RSDWTools] scan: iteration complete (hits=%d, skipped=%d of %d)",
        #hits, skipped, total))

    if radius_sq then
        table.sort(hits, function(a, b) return a.d2 < b.d2 end)
    else
        -- Stable alpha order for "all" mode so the list isn't random each run.
        table.sort(hits, function(a, b) return a.name < b.name end)
    end

    local entries = {}
    for _, r in ipairs(hits) do
        if r.d2 then
            entries[#entries + 1] = { name = r.name, distance = math.sqrt(r.d2) }
        else
            entries[#entries + 1] = { name = r.name }
        end
    end

    print(string.format("[RSDWTools] scan: %d match(es) -> writing results file", #entries))

    local mode_str = use_all and "all" or "radius"
    local body = encode_payload(needle, mode_str, radius, entries)
    local ok_write, path_or_err = write_json_atomic(body)
    if not ok_write then
        print("[RSDWTools] scan: write failed: " .. tostring(path_or_err))
        return false, path_or_err
    end

    if use_all then
        return true, string.format("scan '%s' all -> %d matches", needle, #entries)
    end
    return true, string.format("scan '%s' within %.0fuu -> %d matches", needle, radius, #entries)
end

return M
