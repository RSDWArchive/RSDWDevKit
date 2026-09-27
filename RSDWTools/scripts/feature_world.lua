-- World-level cheats: time-of-day, day length, weather.
--
-- Time of day: dual-write strategy.
--   1. Write StoredTime on AInGameTimeActor (drives the game clock that
--      IInGameTimeProvider::GetInGameTime reads).
--   2. Write ForcedDayTime + bForceDayTime on ADayNightCycleVarsSourceActor
--      (overrides the visual sky/lighting pipeline).
--   Together these ensure both gameplay systems and visuals update.
--   The game's own `domSetTime(Hours)` cheat likely does the same two-step.
--
-- Weather: call TrySetWeather / PauseWeather directly on the live
--   UWeatherSubsystem instance (FindAllOf picks the live world instance,
--   not the CDO). The previous attempt via UWeatherFunctionLibrary failed
--   because static BP function libraries have no findable instances.
--
-- Design contract matches feature_player.lua: called from game thread,
-- pcall-guarded, returns (ok, detail_or_error).

local M = {}

local feature_actor = require("feature_actor")

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function parse_bool(v)
    if type(v) == "boolean" then return v end
    local s = tostring(v or ""):lower()
    if s == "on" or s == "1" or s == "true" or s == "yes" then return true end
    if s == "off" or s == "0" or s == "false" or s == "no" then return false end
    return nil
end

local function parse_number(v)
    return tonumber(v)
end

-- ---------------------------------------------------------------------------
-- FindAllOf helper (same pattern the probe uses — gets ALL instances
-- and returns the first valid one, avoiding CDO issues).
-- ---------------------------------------------------------------------------
local function find_first_valid(class_name)
    if not FindAllOf then
        -- Fallback to FindFirstOf if FindAllOf isn't available
        local ok, obj = pcall(FindFirstOf, class_name)
        if ok and type(obj) == "userdata" and is_valid(obj) then return obj end
        return nil
    end
    local ok, list = pcall(FindAllOf, class_name)
    if not ok or not list then return nil end
    local n = 0
    pcall(function() n = #list end)
    if n == 0 then
        local ok_num, num_val = pcall(function() return list:Num() end)
        if ok_num and type(num_val) == "number" then n = num_val end
    end
    for i = 1, n do
        local eok, entry = pcall(function() return list[i] end)
        if eok and type(entry) == "userdata" and is_valid(entry) then
            return entry
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Cached actor lookups. Re-validated on each call.
-- ---------------------------------------------------------------------------
local _time_actor = nil

local function get_time_actor()
    if _time_actor and is_valid(_time_actor) then return _time_actor end
    _time_actor = find_first_valid("InGameTimeActor")
    return _time_actor
end

local _daynight_actors = nil

--- Find ALL DayNightCycleVarsSourceActor instances (there can be per-biome
--- variants: _Dowdun, _FH, _UMS, each with CompositeGroupPriority). We must
--- write ForcedDayTime on every one to ensure the active-priority actor is hit.
local function get_all_daynight_actors()
    if _daynight_actors then
        -- re-validate cached list
        local still_valid = true
        for i = 1, #_daynight_actors do
            if not is_valid(_daynight_actors[i]) then still_valid = false; break end
        end
        if still_valid and #_daynight_actors > 0 then return _daynight_actors end
    end

    _daynight_actors = {}
    if not FindAllOf then return _daynight_actors end

    -- Try the BP subclass first (covers all variants), then the C++ base
    for _, class_name in ipairs({
        "BP_Ambience_Day_Night_Cycle_C",
        "DayNightCycleVarsSourceActor",
    }) do
        local ok, list = pcall(FindAllOf, class_name)
        if ok and list then
            local n = 0
            pcall(function() n = #list end)
            if n == 0 then
                local ok_num, num_val = pcall(function() return list:Num() end)
                if ok_num and type(num_val) == "number" then n = num_val end
            end
            for i = 1, n do
                local eok, entry = pcall(function() return list[i] end)
                if eok and type(entry) == "userdata" and is_valid(entry) then
                    -- avoid duplicates if BP class already found some
                    local dup = false
                    for j = 1, #_daynight_actors do
                        if _daynight_actors[j] == entry then dup = true; break end
                    end
                    if not dup then
                        _daynight_actors[#_daynight_actors + 1] = entry
                    end
                end
            end
        end
    end
    return _daynight_actors
end

local _weather_sub = nil

local function get_weather_subsystem()
    if _weather_sub and is_valid(_weather_sub) then return _weather_sub end
    _weather_sub = find_first_valid("WeatherSubsystem")
    return _weather_sub
end

-- ---------------------------------------------------------------------------
-- Time of Day
-- ---------------------------------------------------------------------------

--- Set the in-game hour via dual write:
---   1. StoredTime on InGameTimeActor (game clock)
---   2. ForcedDayTime + bForceDayTime on DayNightCycleVarsSourceActor (visuals)
--- value_str is a float 0..24 representing the desired hour.
---
--- Round 25: the StoredTime write is split into its own verb
--- (M.set_storedtime / world.storedtime). This function now ONLY drives
--- the visual override (ForcedDayTime + bForceDayTime). That keeps the
--- safe path one click away and exposes the experimental clock-mutation
--- path under a separate slider so the user can poke it independently.
function M.set_time(value_str)
    local hour = parse_number(value_str)
    if not hour then return false, "time must be a number (0-24)" end
    if hour < 0 then hour = 0 end
    if hour > 24 then hour = 24 end

    local results = {}

    -- Round 25: StoredTime no longer touched here — see M.set_storedtime.
    -- Keep the actor lookup so the ack still reports whether the time
    -- actor is reachable (useful for diagnosing the day-length slider).
    local ta = get_time_actor()
    if ta then
        results[#results + 1] = "TimeActor=ok"
    else
        results[#results + 1] = "no-time-actor"
    end

    -- 2. Write ForcedDayTime on ALL visual driver actors (per-biome variants)
    local dn_list = get_all_daynight_actors()
    if #dn_list > 0 then
        local wrote = 0
        for _, dn in ipairs(dn_list) do
            local ok1, err1 = pcall(function() dn.ForcedDayTime = hour end)
            local ok2, err2 = pcall(function() dn.bForceDayTime = true end)
            if ok1 and ok2 then wrote = wrote + 1 end
        end
        results[#results + 1] = string.format("ForcedDayTime=%.1f(%d/%d actors)", hour, wrote, #dn_list)
    else
        results[#results + 1] = "no-daynight-actors"
    end

    local detail = table.concat(results, " ")
    print(string.format("[RSDWTools] world.time %.1f: %s", hour, detail))
    return true, string.format("%.1f (%s)", hour, detail)
end

--- Release the forced time override — visual time returns to the live
--- game clock. Called when the user hits "Reset" on the time slider.
function M.release_time()
    local dn_list = get_all_daynight_actors()
    for _, dn in ipairs(dn_list) do
        pcall(function() dn.bForceDayTime = false end)
    end
    print("[RSDWTools] world.time: released forced override")
    return true, "released"
end

--- Round 25: experimental — write the persistent game-clock accumulator
--- (AInGameTimeActor.StoredTime) so the in-game hour-of-day flips
--- without touching the visual override. StoredTime is stored as real
--- seconds since the game started; current day = floor(StoredTime /
--- sec_per_day). We preserve the day counter by recomputing
---     new_StoredTime = floor(StoredTime / sec_per_day) * sec_per_day
---                    + (hour / 24) * sec_per_day
--- so the player stays on the same in-game day while the hour shifts.
---
--- WARNING: this is the path round 22 disabled because larger jumps
--- risked save corruption. Exposed here under a dedicated verb so the
--- user can experiment; the "safe" visual override (M.set_time) stays
--- the default.
function M.set_storedtime(value_str)
    local hour = parse_number(value_str)
    if not hour then return false, "storedtime hour must be a number (0-24)" end
    if hour < 0 then hour = 0 end
    if hour > 24 then hour = 24 end

    local actor = get_time_actor()
    if not actor then return false, "InGameTimeActor not found" end

    -- RealTimeMinutesPerInGameDay drives the seconds-per-day conversion.
    -- Default 24 -> 1440 sec/day. Read live so a customised day length
    -- maps cleanly.
    local mins_per_day = 24
    pcall(function() mins_per_day = actor.RealTimeMinutesPerInGameDay or 24 end)
    if mins_per_day <= 0 then mins_per_day = 24 end
    local sec_per_day = mins_per_day * 60

    local current = 0
    pcall(function() current = actor.StoredTime or 0 end)
    local day_floor = math.floor(current / sec_per_day) * sec_per_day
    local new_st = day_floor + (hour / 24) * sec_per_day

    local ok_w, err = pcall(function() actor.StoredTime = new_st end)
    if not ok_w then return false, "write StoredTime failed: " .. tostring(err) end

    print(string.format("[RSDWTools] world.storedtime %.1f -> StoredTime=%.2f (sec_per_day=%.0f, day_floor=%.0f)",
        hour, new_st, sec_per_day, day_floor))
    return true, string.format("%.1f (StoredTime=%.0f)", hour, new_st)
end

--- Pause or resume the game clock (AInGameTimeActor.bIsTimePaused).
function M.pause_time(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "pause must be on/off" end

    local actor = get_time_actor()
    if not actor then return false, "InGameTimeActor not found" end

    local ok_w, err = pcall(function() actor.bIsTimePaused = b end)
    if not ok_w then return false, "write bIsTimePaused failed: " .. tostring(err) end

    print(string.format("[RSDWTools] world.time.pause: %s", tostring(b)))
    return true, b and "on" or "off"
end

--- Set the in-game hour at which dawn begins (vanilla = 4.5).
--- Drives sunrise tinting / wildlife spawn windows on AInGameTimeActor.
function M.set_dawn(value_str)
    local hour = parse_number(value_str)
    if not hour then return false, "dawn must be a number (0-24)" end
    if hour < 0 then hour = 0 end
    if hour > 24 then hour = 24 end

    local actor = get_time_actor()
    if not actor then return false, "InGameTimeActor not found" end

    local ok_w, err = pcall(function() actor.TimeOfDawn = hour end)
    if not ok_w then return false, "write TimeOfDawn failed: " .. tostring(err) end

    print(string.format("[RSDWTools] world.dawn: %.2f", hour))
    return true, string.format("%.2f", hour)
end

--- Set the in-game hour at which dusk begins (vanilla = 22).
function M.set_dusk(value_str)
    local hour = parse_number(value_str)
    if not hour then return false, "dusk must be a number (0-24)" end
    if hour < 0 then hour = 0 end
    if hour > 24 then hour = 24 end

    local actor = get_time_actor()
    if not actor then return false, "InGameTimeActor not found" end

    local ok_w, err = pcall(function() actor.TimeOfDusk = hour end)
    if not ok_w then return false, "write TimeOfDusk failed: " .. tostring(err) end

    print(string.format("[RSDWTools] world.dusk: %.2f", hour))
    return true, string.format("%.2f", hour)
end

--- Set the real-time minutes per in-game day (vanilla = 24).
function M.set_day_speed(value_str)
    local n = parse_number(value_str)
    if not n then return false, "speed must be a number (minutes)" end
    n = math.floor(n + 0.5)
    if n < 1 then n = 1 end
    if n > 1440 then n = 1440 end

    local actor = get_time_actor()
    if not actor then return false, "InGameTimeActor not found" end

    local ok_w, err = pcall(function() actor.RealTimeMinutesPerInGameDay = n end)
    if not ok_w then return false, "write RealTimeMinutesPerInGameDay failed: " .. tostring(err) end

    print(string.format("[RSDWTools] world.time.speed: %d min/day", n))
    return true, tostring(n)
end

-- ---------------------------------------------------------------------------
-- Weather
-- ---------------------------------------------------------------------------

-- EWeatherType enum values (from CXXHeaderDump):
--   Default=0, Sunny=1, Rain_Light=2, Rain_Heavy=3, Rain_Storm=4,
--   Rain_LightningStorm=5, Fog=6, Cloudy=7, Velgar_BossFight=8, Sandstorm=9
local WEATHER_NAMES = {
    ["default"] = 0, ["sunny"] = 1, ["rain_light"] = 2, ["rain_heavy"] = 3,
    ["rain_storm"] = 4, ["rain_lightningstorm"] = 5, ["fog"] = 6, ["cloudy"] = 7,
    ["velgar_bossfight"] = 8, ["velgar"] = 8, ["sandstorm"] = 9,
    -- short aliases
    ["sun"] = 1, ["light"] = 2, ["heavy"] = 3, ["storm"] = 4,
    ["lightning"] = 5, ["clear"] = 1,
}

--- Set weather via the live UWeatherSubsystem instance.
function M.set_weather(value_str)
    local idx = tonumber(value_str)
    if not idx then
        local name = tostring(value_str or ""):lower():gsub("%s+", "")
        idx = WEATHER_NAMES[name]
    end
    if not idx or idx ~= math.floor(idx) or idx < 0 or idx > 9 then
        return false, "weather must be 0-9 or a name (sunny, rain_light, sandstorm, etc.)"
    end
    idx = math.floor(idx)

    local sub = get_weather_subsystem()
    if not sub then return false, "WeatherSubsystem not found" end

    local ok, err = pcall(function() sub:TrySetWeather(idx) end)
    if not ok then return false, "TrySetWeather failed: " .. tostring(err) end

    print(string.format("[RSDWTools] world.weather: set to %d", idx))
    return true, tostring(idx)
end

--- Pause or resume weather transitions.
function M.pause_weather(value_str)
    local b = parse_bool(value_str)
    if b == nil then return false, "pause must be on/off" end

    local sub = get_weather_subsystem()
    if not sub then return false, "WeatherSubsystem not found" end

    local ok, err = pcall(function() sub:PauseWeather(b) end)
    if not ok then return false, "PauseWeather failed: " .. tostring(err) end

    print(string.format("[RSDWTools] world.weather.pause: %s", tostring(b)))
    return true, b and "on" or "off"
end

-- ---------------------------------------------------------------------------
-- DISCOVERY / PROBE VERBS  (raw -- read-only ; logs to UE4SS console)
-- ---------------------------------------------------------------------------
-- The user has tried surface-level weather/time controls before and found
-- they don't reliably manipulate the live state. These probes dump the
-- next layer down so we can see exactly what's overriding what.
-- ---------------------------------------------------------------------------

local WEATHER_TYPE_NAMES = {
    [0] = "Default", [1] = "Sunny", [2] = "Rain_Light", [3] = "Rain_Heavy",
    [4] = "Rain_Storm", [5] = "Rain_LightningStorm", [6] = "Fog",
    [7] = "Cloudy", [8] = "Velgar_BossFight", [9] = "Sandstorm",
}

local function weather_name(idx)
    if type(idx) ~= "number" then return tostring(idx) end
    return WEATHER_TYPE_NAMES[idx] or ("idx=" .. tostring(idx))
end

local function obj_name(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    if type(n) ~= "string" or n == "" then
        pcall(function() n = obj:GetName() end)
    end
    return n or "<unnamed>"
end

local function find_all(class_name)
    if not FindAllOf then return {} end
    local ok, list = pcall(FindAllOf, class_name)
    if not ok or not list then return {} end
    local out = {}
    local n = 0
    pcall(function() n = #list end)
    if n == 0 then
        pcall(function() n = list:Num() end)
    end
    for i = 1, (n or 0) do
        local eok, entry = pcall(function() return list[i] end)
        if eok and type(entry) == "userdata" and is_valid(entry) then
            out[#out + 1] = entry
        end
    end
    return out
end

--- world.time.probe -- comprehensive read-only dump of clock + visual
--- override state. Use this BEFORE and AFTER mutations to see what
--- actually moved.
function M.probe_time()
    local lines = { "[RSDWTools] world.time.probe --" }

    local ta = get_time_actor()
    if not is_valid(ta) then
        lines[#lines + 1] = "  InGameTimeActor : <not found>"
    else
        local stored, mins, dawn, dusk, paused, init
        pcall(function() stored = ta.StoredTime end)
        pcall(function() mins = ta.RealTimeMinutesPerInGameDay end)
        pcall(function() dawn = ta.TimeOfDawn end)
        pcall(function() dusk = ta.TimeOfDusk end)
        pcall(function() paused = ta.bIsTimePaused end)
        pcall(function() init = ta.InitialTime end)
        local sec_per_day = (mins or 24) * 60
        local hour_now, day_now = 0, 0
        if type(stored) == "number" and sec_per_day > 0 then
            day_now = math.floor(stored / sec_per_day)
            hour_now = (stored / sec_per_day - day_now) * 24
        end
        lines[#lines + 1] = string.format("  InGameTimeActor : %s", obj_name(ta))
        lines[#lines + 1] = string.format("    StoredTime         = %s (=> day %d, hour %.2f)",
            tostring(stored), day_now, hour_now)
        lines[#lines + 1] = string.format("    MinsPerInGameDay   = %s (sec/day=%d)",
            tostring(mins), sec_per_day)
        lines[#lines + 1] = string.format("    TimeOfDawn / Dusk  = %s / %s",
            tostring(dawn), tostring(dusk))
        lines[#lines + 1] = string.format("    bIsTimePaused      = %s", tostring(paused))
        lines[#lines + 1] = string.format("    InitialTime (raw)  = %s", tostring(init))
    end

    local dn = get_all_daynight_actors()
    lines[#lines + 1] = string.format("  DayNightCycle actors : %d", #dn)
    for i = 1, #dn do
        local a = dn[i]
        local force, forced
        pcall(function() force = a.bForceDayTime end)
        pcall(function() forced = a.ForcedDayTime end)
        lines[#lines + 1] = string.format("    [%d] %s  bForce=%s ForcedDayTime=%s",
            i, obj_name(a), tostring(force), tostring(forced))
    end

    -- Subsystem (Day/Night classification)
    local subsys = find_first_valid("InGameTimeSubsystem")
    if subsys then
        local cat
        pcall(function() cat = subsys:IsDayOrNight() end)
        lines[#lines + 1] = string.format("  InGameTimeSubsystem : IsDayOrNight=%s", tostring(cat))
    else
        lines[#lines + 1] = "  InGameTimeSubsystem : <not found>"
    end

    for i = 1, #lines do print(lines[i]) end
    return true, "see UE4SS log"
end

--- world.weather.probe -- comprehensive read-only dump of weather state.
--- Surfaces every layer : subsystem, regional actors, regional weather
--- objects, and current weather at the player.
function M.probe_weather()
    local lines = { "[RSDWTools] world.weather.probe --" }

    -- 1. Subsystem + GetWeatherAtLocation(player)
    local sub = get_weather_subsystem()
    if not is_valid(sub) then
        lines[#lines + 1] = "  WeatherSubsystem : <not found>"
    else
        lines[#lines + 1] = string.format("  WeatherSubsystem : %s", obj_name(sub))
        local pawn = feature_actor.get_local_pawn()
        if pawn then
            local loc = feature_actor.actor_location(pawn)
            if loc then
                local current
                local ok, err = pcall(function()
                    current = sub:GetWeatherAtLocation({ X = loc.X, Y = loc.Y, Z = loc.Z })
                end)
                if ok then
                    lines[#lines + 1] = string.format("    GetWeatherAtLocation(player) = %d (%s)",
                        current or -1, weather_name(current))
                else
                    lines[#lines + 1] = "    GetWeatherAtLocation errored: " .. tostring(err)
                end
            end
        end
    end

    -- 2. Region-specific global weather actors (the ARegionSpecificGlobalWeatherActor
    --    Priority + Weathers list ; higher priority wins when overlapping).
    local region_actors = find_all("RegionSpecificGlobalWeatherActor")
    if #region_actors == 0 then
        -- Fallback to BP class names
        for _, c in ipairs({ "BP_WeatherActor_C", "BP_WeatherSystemSource_DR_C",
                              "BP_WeatherSystemSource_FH_C", "BP_WeatherSystemSource_GF_C" }) do
            local more = find_all(c)
            for j = 1, #more do region_actors[#region_actors + 1] = more[j] end
        end
    end
    lines[#lines + 1] = string.format("  RegionSpecificGlobalWeatherActor : %d", #region_actors)
    for i = 1, #region_actors do
        local a = region_actors[i]
        local prio
        pcall(function() prio = a.Priority end)
        local n_weathers
        pcall(function() n_weathers = #a.Weathers end)
        lines[#lines + 1] = string.format("    [%d] %s  Priority=%s Weathers=%s",
            i, obj_name(a), tostring(prio), tostring(n_weathers))
    end

    -- 3. UDynamicRegionalWeather instances (mutable WeatherType, replicated).
    local dyn = find_all("DynamicRegionalWeather")
    lines[#lines + 1] = string.format("  DynamicRegionalWeather : %d", #dyn)
    for i = 1, #dyn do
        local r = dyn[i]
        local wt, persist
        pcall(function() wt = r.WeatherType end)
        pcall(function() persist = r.PersistenceName end)
        lines[#lines + 1] = string.format("    [%d] %s  WeatherType=%d (%s)  Persist=%s",
            i, obj_name(r), wt or -1, weather_name(wt), tostring(persist))
    end

    -- 4. UStaticRegionalWeather instances (fixed WeatherType, but writable
    --    for experimentation).
    local sta = find_all("StaticRegionalWeather")
    lines[#lines + 1] = string.format("  StaticRegionalWeather : %d", #sta)
    for i = 1, #sta do
        local r = sta[i]
        local wt
        pcall(function() wt = r.WeatherType end)
        lines[#lines + 1] = string.format("    [%d] %s  WeatherType=%d (%s)",
            i, obj_name(r), wt or -1, weather_name(wt))
    end

    for i = 1, #lines do print(lines[i]) end
    return true, "see UE4SS log"
end

--- world.weather.list -- enumerates every accepted EWeatherType value
--- (canonical name + idx) and the short aliases. Designed to be parsed
--- by the UI : pipe-delimited, so it can populate a dropdown without
--- the WPF side needing its own copy of the enum.
---
--- Detail format:
---   types=0:Default,1:Sunny,...|aliases=sun:1,clear:1,light:2,...
function M.weather_list()
    local types = {}
    local sorted = {}
    for k, _ in pairs(WEATHER_TYPE_NAMES) do sorted[#sorted + 1] = k end
    table.sort(sorted)
    for _, idx in ipairs(sorted) do
        types[#types + 1] = string.format("%d:%s", idx, WEATHER_TYPE_NAMES[idx])
    end

    local aliases = {}
    -- Distinguish canonical lowercase names (already in WEATHER_TYPE_NAMES)
    -- from extra short aliases the user can also type.
    local canonical = {}
    for _, name in pairs(WEATHER_TYPE_NAMES) do
        canonical[name:lower()] = true
    end
    local alias_keys = {}
    for k, _ in pairs(WEATHER_NAMES) do
        if not canonical[k] then alias_keys[#alias_keys + 1] = k end
    end
    table.sort(alias_keys)
    for _, k in ipairs(alias_keys) do
        aliases[#aliases + 1] = string.format("%s:%d", k, WEATHER_NAMES[k])
    end

    local detail = "types=" .. table.concat(types, ",") ..
        "|aliases=" .. table.concat(aliases, ",")
    print("[RSDWTools] world.weather.list: " .. detail)
    return true, detail
end

--- world.weather.where -- one-shot : just GetWeatherAtLocation(player).
function M.weather_where()
    local sub = get_weather_subsystem()
    if not sub then return false, "WeatherSubsystem not found" end
    local pawn = feature_actor.get_local_pawn()
    if not pawn then return false, "no local pawn" end
    local loc = feature_actor.actor_location(pawn)
    if not loc then return false, "no pawn location" end
    local current
    local ok, err = pcall(function()
        current = sub:GetWeatherAtLocation({ X = loc.X, Y = loc.Y, Z = loc.Z })
    end)
    if not ok then return false, "GetWeatherAtLocation failed: " .. tostring(err) end
    return true, string.format("%d (%s)", current or -1, weather_name(current))
end

--- world.weather.regional <type> -- raw mutation : write WeatherType
--- directly onto every UDynamicRegionalWeather and UStaticRegionalWeather.
--- This bypasses TrySetWeather and lets us see whether the surface
--- subsystem call is actually getting blocked by something downstream
--- (a regional override, a profile-driven simulator, etc.).
---
--- For UDynamicRegionalWeather, also fires OnRep_WeatherType so the
--- replicated visual gets a chance to refresh client-side.
function M.set_regional_weather(value_str)
    local idx = tonumber(value_str)
    if not idx then
        local name = tostring(value_str or ""):lower():gsub("%s+", "")
        idx = WEATHER_NAMES[name]
    end
    if type(idx) ~= "number" or idx ~= math.floor(idx) or idx < 0 or idx > 9 then
        return false, "weather must be 0-9 or a name (sunny, rain_light, sandstorm, ...)"
    end
    idx = math.floor(idx)

    local dyn = find_all("DynamicRegionalWeather")
    local sta = find_all("StaticRegionalWeather")
    local wrote_dyn, wrote_sta = 0, 0

    for i = 1, #dyn do
        local r = dyn[i]
        local ok = pcall(function() r.WeatherType = idx end)
        if ok then
            wrote_dyn = wrote_dyn + 1
            -- Fire OnRep manually so listeners refresh on the local
            -- client without waiting for the next replication tick.
            pcall(function() r:OnRep_WeatherType() end)
        end
    end
    for i = 1, #sta do
        local r = sta[i]
        local ok = pcall(function() r.WeatherType = idx end)
        if ok then wrote_sta = wrote_sta + 1 end
    end

    print(string.format(
        "[RSDWTools] world.weather.regional: WeatherType=%d (%s)  dyn=%d/%d  static=%d/%d",
        idx, weather_name(idx), wrote_dyn, #dyn, wrote_sta, #sta))
    return true, string.format("dyn=%d/%d static=%d/%d type=%d (%s)",
        wrote_dyn, #dyn, wrote_sta, #sta, idx, weather_name(idx))
end

--- world.weather.region_priority <int> -- raw mutation : write Priority
--- on every ARegionSpecificGlobalWeatherActor. The composite priority
--- system picks "highest wins", so cranking this on a chosen actor (or
--- all of them) lets us experiment with which region's weather is
--- authoritative at the player's spot.
function M.set_region_priority(value_str)
    local p = tonumber(value_str)
    if not p then return false, "priority must be an integer" end
    p = math.floor(p)

    local actors = find_all("RegionSpecificGlobalWeatherActor")
    if #actors == 0 then
        for _, c in ipairs({ "BP_WeatherActor_C", "BP_WeatherSystemSource_DR_C",
                              "BP_WeatherSystemSource_FH_C", "BP_WeatherSystemSource_GF_C" }) do
            local more = find_all(c)
            for j = 1, #more do actors[#actors + 1] = more[j] end
        end
    end
    if #actors == 0 then return false, "no RegionSpecificGlobalWeatherActor found" end

    local wrote = 0
    for i = 1, #actors do
        local a = actors[i]
        local ok = pcall(function() a.Priority = p end)
        if ok then wrote = wrote + 1 end
    end
    print(string.format("[RSDWTools] world.weather.region_priority: Priority=%d  %d/%d actors",
        p, wrote, #actors))
    return true, string.format("Priority=%d (%d/%d)", p, wrote, #actors)
end

return M
