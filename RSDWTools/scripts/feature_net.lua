-- feature_net.lua
--
-- Multiplayer-aware local-player resolution.
--
-- Background : older code resolved "the local player" by trusting
-- UEHelpers.GetPlayerController() and falling back to a FindAllOf-then-
-- IsPlayerControlled() walk. In multiplayer that fallback is wrong ;
-- IsPlayerControlled() is true for *any* human-driven pawn (local or
-- remote), so the loop could return another player's controller and
-- every cheat would silently target them. The canonical engine answer
-- is APlayerController::IsLocalController() ; this module makes that
-- the only ground truth and exposes a small, stable API the rest of
-- the mod consumes.
--
-- Scope is intentionally narrow : every command this app can send is
-- routed to the local player. There is no remote-targeting path. The
-- Multi tab in the WPF is a passive roster viewer ; it does not
-- mutate anyone else's state.
--
-- Public API :
--   M.local_controller()        --> the local APlayerController, or nil
--   M.local_pawn()              --> Pawn of the local controller, or nil
--   M.net_mode_int()            --> 0 Standalone, 1 DedicatedServer,
--                                   2 ListenServer, 3 Client, -1 unknown
--   M.net_mode()                --> human-readable string of the above
--   M.is_host()                 --> true on Standalone or ListenServer
--   M.local_player_name()       --> string (best-effort)
--   M.list_players()            --> array of roster entry tables
--   M.json_roster()             --> compact JSON array for the WPF Multi tab
--   M.log_session_once()        --> one-shot UE4SS console line
--
-- All native calls are pcall-guarded ; nothing here will escape into
-- the UE4SS callback site as an unhandled error.

local M = {}

-- ---------- safety helpers ----------

local function is_valid(obj)
    if type(obj) ~= "userdata" then return false end
    if not obj.IsValid then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v and true or false
end

local function pcall_get(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

-- Coerce an FName / FString / FText / userdata to a Lua string. Returns
-- "" when the value is missing or not coercible. Used for player names
-- and net-id reads where the engine surface varies between FString and
-- FUniqueNetIdRepl wrappers.
local function to_string(v)
    if v == nil then return "" end
    if type(v) == "string" then return v end
    if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
    if type(v) == "userdata" then
        local s = pcall_get(function() return v:ToString() end)
        if type(s) == "string" and s ~= "" then return s end
        local s2 = pcall_get(function() return tostring(v) end)
        if type(s2) == "string" then return s2 end
    end
    return ""
end

-- ---------- local PC resolution ----------

local _cached_pc = nil

-- Walks every PlayerController in the world and returns the first one
-- that reports IsLocalController() == true. This is the engine's own
-- "is this controller owned by my client" answer ; it is the only
-- reliable signal in a networked game.
local function find_local_via_isLocal()
    local list = FindAllOf and FindAllOf("PlayerController") or nil
    if type(list) ~= "table" then return nil end
    for _, pc in pairs(list) do
        if is_valid(pc) and pc.IsLocalController then
            local ok, mine = pcall(function() return pc:IsLocalController() end)
            if ok and mine then
                return pc
            end
        end
    end
    return nil
end

-- Fallback : trust UEHelpers, which under the hood asks the World for
-- GetFirstPlayerController(). On a client UE4SS instance this is the
-- local PC. On a listen server it's also the local (host) PC. Only
-- used when the strict scan above returns nothing -- which can happen
-- briefly during world swap or before the first PC has finished
-- replicating.
local function find_local_via_uehelpers()
    local ok_req, ue = pcall(require, "UEHelpers")
    if not ok_req or type(ue) ~= "table" or not ue.GetPlayerController then
        return nil
    end
    local pc = pcall_get(function() return ue.GetPlayerController() end)
    if is_valid(pc) then return pc end
    return nil
end

function M.local_controller()
    -- Validate the cache before re-using it. A cached PC can become
    -- stale on map change ; IsLocalController() will either error out
    -- (caught by pcall) or return false on a torn-down controller, in
    -- which case we re-resolve.
    local cached = _cached_pc
    if is_valid(cached) then
        local ok, mine = pcall(function()
            if not cached.IsLocalController then return false end
            return cached:IsLocalController()
        end)
        if ok and mine then
            return cached
        end
    end
    _cached_pc = find_local_via_isLocal() or find_local_via_uehelpers()
    return _cached_pc
end

function M.local_pawn()
    local pc = M.local_controller()
    if not is_valid(pc) then return nil end
    local pawn = pcall_get(function() return pc.Pawn end)
    if is_valid(pawn) then return pawn end
    return nil
end

-- Public for tests / introspection.
function M.invalidate_cache()
    _cached_pc = nil
end

-- ---------- net mode ----------

local NET_MODE_NAMES = {
    [0] = "Standalone",
    [1] = "DedicatedServer",
    [2] = "ListenServer",
    [3] = "Client",
}

function M.net_mode_int()
    -- Primary : ask the local PC. In rare cases (TEnumAsByte wrapper,
    -- partially-initialized PC during world swap) GetNetMode returns
    -- a userdata wrapper or fails ; fall back through the pawn and
    -- finally through the UWorld which is always authoritative.
    local pc = M.local_controller()
    if is_valid(pc) and pc.GetNetMode then
        local nm = pcall_get(function() return pc:GetNetMode() end)
        if type(nm) == "number" then return nm end
        if type(nm) == "userdata" then
            local v = pcall_get(function() return nm:get() end)
            if type(v) == "number" then return v end
        end
    end

    -- Try via the pawn (same vtable path, sometimes succeeds when PC
    -- is mid-replication).
    local pawn = M.local_pawn()
    if is_valid(pawn) and pawn.GetNetMode then
        local nm = pcall_get(function() return pawn:GetNetMode() end)
        if type(nm) == "number" then return nm end
    end

    -- Last resort : grab the world via UEHelpers and ask it directly.
    local ok_req, ue = pcall(require, "UEHelpers")
    if ok_req and type(ue) == "table" and ue.GetWorld then
        local w = pcall_get(function() return ue.GetWorld() end)
        if is_valid(w) and w.GetNetMode then
            local nm = pcall_get(function() return w:GetNetMode() end)
            if type(nm) == "number" then return nm end
        end
    end

    return -1
end

function M.net_mode()
    return NET_MODE_NAMES[M.net_mode_int()] or "Unknown"
end

function M.is_host()
    local n = M.net_mode_int()
    return n == 0 or n == 1 or n == 2
end

-- ---------- per-PC identity ----------

local function pc_player_name(pc)
    if not is_valid(pc) then return "" end
    local ps = pcall_get(function() return pc.PlayerState end)
    if is_valid(ps) then
        if ps.GetPlayerName then
            local n = pcall_get(function() return ps:GetPlayerName() end)
            local s = to_string(n)
            if s ~= "" then return s end
        end
        local n2 = pcall_get(function() return ps.PlayerNamePrivate end)
        local s2 = to_string(n2)
        if s2 ~= "" then return s2 end
    end
    return ""
end

local function pc_has_authority(pc)
    if not is_valid(pc) or not pc.HasAuthority then return false end
    local ok, a = pcall(function() return pc:HasAuthority() end)
    return (ok and a) and true or false
end

function M.local_player_name()
    return pc_player_name(M.local_controller())
end

-- ---------- roster ----------

-- Returns an array of plain Lua tables (no userdata) suitable for
-- JSON serialization. Each entry :
--   { name, is_local, has_authority, alive, pawn_class,
--     x, y (world cm, optional), distance (cm, optional) }
-- Z is omitted ; the Map view is 2D and the Multi tab does not need it.
function M.list_players()
    local out = {}
    local local_pc = M.local_controller()
    local local_pawn = is_valid(local_pc) and pcall_get(function() return local_pc.Pawn end) or nil
    local local_loc = nil
    if is_valid(local_pawn) and local_pawn.K2_GetActorLocation then
        local_loc = pcall_get(function() return local_pawn:K2_GetActorLocation() end)
    end

    local list = FindAllOf and FindAllOf("PlayerController") or nil
    if type(list) ~= "table" then return out end

    for _, pc in pairs(list) do
        if is_valid(pc) then
            local entry = {
                name = pc_player_name(pc),
                is_local = false,
                has_authority = pc_has_authority(pc),
                alive = false,
                pawn_class = "",
            }
            if pc.IsLocalController then
                local ok, mine = pcall(function() return pc:IsLocalController() end)
                if ok and mine then entry.is_local = true end
            end
            local pawn = pcall_get(function() return pc.Pawn end)
            if is_valid(pawn) then
                entry.alive = true
                local nm = pcall_get(function() return pawn:GetName() end)
                local nstr = to_string(nm)
                if nstr == "" then
                    local fn = pcall_get(function() return pawn:GetFullName() end)
                    local fstr = to_string(fn)
                    if fstr ~= "" then
                        nstr = fstr:match("%.([^%.]+)$") or fstr:match("^(%S+)") or fstr
                    end
                end
                entry.pawn_class = nstr
                if pawn.K2_GetActorLocation then
                    local loc = pcall_get(function() return pawn:K2_GetActorLocation() end)
                    if loc then
                        entry.x = loc.X or 0
                        entry.y = loc.Y or 0
                        if local_loc then
                            local dx = entry.x - (local_loc.X or 0)
                            local dy = entry.y - (local_loc.Y or 0)
                            local dz = (loc.Z or 0) - (local_loc.Z or 0)
                            entry.distance = math.sqrt(dx * dx + dy * dy + dz * dz)
                        end
                    end
                end
            end
            table.insert(out, entry)
        end
    end
    return out
end

-- ---------- one-shot session log ----------

local _logged = false

function M.log_session_once()
    if _logged then return end
    local pc = M.local_controller()
    if not is_valid(pc) then return end
    _logged = true
    print(string.format(
        "[RSDWTools][net] session : netmode=%s name=%q",
        M.net_mode(),
        M.local_player_name()))
end

-- ---------- JSON serialization for the WPF Multi tab ----------

local function json_escape(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
    s = s:gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    -- Strip remaining control chars to keep the wire payload safe.
    s = s:gsub('[%z\1-\31]', '')
    return '"' .. s .. '"'
end

local function json_num(n)
    if type(n) ~= "number" or n ~= n then return "null" end
    if n == math.huge or n == -math.huge then return "null" end
    return string.format("%.6g", n)
end

local function json_bool(b) return b and "true" or "false" end

-- Compact JSON array of roster entries. Wraps M.list_players(). The
-- WPF Multi tab also derives its "You" card from this : the entry
-- with is_local=true is the local player, no separate self lookup.
function M.json_roster()
    local rows = M.list_players()
    local out = {}
    for _, r in ipairs(rows) do
        local parts = {
            '"name":'          .. json_escape(r.name or ""),
            '"is_local":'      .. json_bool(r.is_local),
            '"has_authority":' .. json_bool(r.has_authority),
            '"alive":'         .. json_bool(r.alive),
            '"pawn_class":'    .. json_escape(r.pawn_class or ""),
            '"netmode":'       .. json_escape(M.net_mode()),
        }
        if r.distance then table.insert(parts, '"distance":' .. json_num(r.distance)) end
        if r.x then
            table.insert(parts, '"x":' .. json_num(r.x))
            table.insert(parts, '"y":' .. json_num(r.y))
        end
        out[#out + 1] = "{" .. table.concat(parts, ",") .. "}"
    end
    return "[" .. table.concat(out, ",") .. "]"
end

return M
