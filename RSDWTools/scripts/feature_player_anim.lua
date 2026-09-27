local M = {}

local core = require("feature_player_core")

local PLAYER_EMOTE_ALIASES = { "BP_Components_PlayerEmotes", "PlayerEmotesComponent" }

local EMOTE_INDEX_BY_NAME = {
    celebrate = 0,
    cheer = 0,
    noway = 1,
    no_way = 1,
    no = 2,
    point = 3,
    wave = 4,
    yes = 5,
}

local attack_mod = nil

local function attacks()
    if not attack_mod then
        attack_mod = require("feature_player_attack")
    end
    return attack_mod
end

local function trim_animation_arg(value_str)
    return value_str and tostring(value_str):match("^%s*(.-)%s*$") or ""
end

local function split_animation_arg(value_str)
    local text = trim_animation_arg(value_str)
    local first, rest = text:match("^(%S+)%s*(.-)%s*$")
    return first or "", rest or ""
end

local function strip_animation_prefix(value_str, prefix)
    local text = trim_animation_arg(value_str)
    local lower = text:lower()
    if lower:sub(1, #prefix + 1) == prefix .. ":" then
        return trim_animation_arg(text:sub(#prefix + 2))
    end
    return text
end

local function normalize_montage_path(value_str)
    local path = trim_animation_arg(value_str)
    local quoted = path:match("^[%w_]+%'(.+)'$")
    if quoted and quoted ~= "" then path = quoted end
    path = path:gsub("^RSDragonwilds/Content/", "/Game/")
    path = path:gsub("^Game/", "/Game/")
    path = path:gsub("^/?Game/Plugins/GameFeatures/([^/]+)/Content/", "/%1/")
    path = path:gsub("^/?RSDragonwilds/Plugins/GameFeatures/([^/]+)/Content/", "/%1/")
    path = path:gsub("^/?Plugins/GameFeatures/([^/]+)/Content/", "/%1/")

    if path:sub(1, 1) == "/" and not path:find("%.") then
        local leaf = path:match("([^/]+)$")
        if leaf and leaf ~= "" then
            path = path:gsub("_C$", "") .. "." .. leaf:gsub("_C$", "")
        end
    end
    path = path:gsub("(/AM_PlayerM_[^/.]+)_C(%.AM_PlayerM_[^./]+)$", "%1%2")
    path = path:gsub("(%.AM_PlayerM_[^./]+)_C$", "%1")
    return path
end

local function resolve_uobject_path(object_path)
    local normalized = normalize_montage_path(object_path)
    if normalized == "" then return nil, "empty object path", normalized end

    if StaticFindObject then
        local ok_find, found = pcall(StaticFindObject, normalized)
        if ok_find and core.is_valid_uobject(found) then return found, "StaticFindObject", normalized end
    end
    if LoadObject then
        local ok_load, loaded = pcall(LoadObject, normalized)
        if ok_load and core.is_valid_uobject(loaded) then return loaded, "LoadObject", normalized end
    end
    if LoadAsset then
        local ok_asset, asset = pcall(LoadAsset, normalized)
        if ok_asset and core.is_valid_uobject(asset) then return asset, "LoadAsset", normalized end
    end

    if StaticFindObject then
        local package_path = normalized:match("^(.-)%.[^./]+$")
        if package_path and package_path ~= "" and package_path:sub(1, 1) == "/" then
            local feature_net = require("feature_net")
            local pc = feature_net.local_controller()
            local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
            if pc and ksl and ksl.IsValid and ksl:IsValid() then
                pcall(function() ksl:ExecuteConsoleCommand(pc, "obj load name=" .. package_path, pc) end)
                local ok_find, found = pcall(StaticFindObject, normalized)
                if ok_find and core.is_valid_uobject(found) then return found, "obj load", normalized end
            end
        end
    end

    return nil, "object not found", normalized
end

function M.play_montage(value_str)
    local first, rest = split_animation_arg(strip_animation_prefix(value_str, "montage"))
    if first == "" then return false, "usage: player.anim.montage <AnimMontagePath> [play_rate]" end

    local play_rate = tonumber(rest)
    if not play_rate then play_rate = 1.0 end
    if play_rate <= 0 then play_rate = 1.0 end
    if play_rate > 10.0 then play_rate = 10.0 end

    local montage, route, normalized = resolve_uobject_path(first)
    if not montage then return false, tostring(route) .. " (normalized: " .. tostring(normalized) .. ")" end

    local anim, anim_err = core.get_player_anim_instance()
    if not anim then return false, anim_err end

    local ok_play, result = pcall(function()
        return anim:Montage_Play(montage, play_rate, 0, 0.0, true)
    end)
    if not ok_play then return false, "Montage_Play failed: " .. tostring(result) end

    print(string.format("[RSDWTools] player.anim.montage %s via %s", normalized, route))
    return true, string.format("%s rate=%.2f result=%s", core.animation_short_name(normalized), play_rate, tostring(result))
end

function M.stop_montage(value_str)
    local anim, anim_err = core.get_player_anim_instance()
    if not anim then return false, anim_err end

    local first, rest = split_animation_arg(value_str)
    local blend_out = tonumber(rest)
    if not blend_out then blend_out = tonumber(first) or 0.2 end
    if blend_out < 0 then blend_out = 0 end
    if blend_out > 5.0 then blend_out = 5.0 end

    local montage = nil
    local normalized = "all"
    if first ~= "" and not tonumber(first) then
        montage, _, normalized = resolve_uobject_path(first)
        if not montage then return false, "montage not found (normalized: " .. tostring(normalized) .. ")" end
    end

    local ok_stop, stop_err = pcall(function() anim:Montage_Stop(blend_out, montage) end)
    if not ok_stop then return false, "Montage_Stop failed: " .. tostring(stop_err) end
    print(string.format("[RSDWTools] player.anim.stop %s", normalized))
    return true, normalized
end

local function parse_emote_index(value_str)
    local token = trim_animation_arg(value_str):lower():gsub("[%s%-]+", "_")
    if token == "" then return nil, "usage: player.emote <slot|name|stop>" end
    if token == "stop" or token == "off" then return "stop", nil end

    local numeric = tonumber(token)
    if numeric then
        local index = math.floor(numeric)
        if index < 0 or index > 127 then return nil, "emote index must be 0..127" end
        return index, nil
    end
    local named = EMOTE_INDEX_BY_NAME[token]
    if named ~= nil then return named, nil end
    return nil, "unknown emote name; use slot 0..5 or celebrate|noway|no|point|wave|yes"
end

function M.play_emote(value_str)
    local parsed, parse_err = parse_emote_index(strip_animation_prefix(value_str, "emote"))
    if parsed == nil then return false, parse_err end

    local pawn = core.get_pawn()
    if not pawn then return false, "no local pawn" end
    local comp, alias = core.get_component(pawn, PLAYER_EMOTE_ALIASES)
    if not comp then return false, alias end

    if parsed == "stop" then
        if not comp.StopCurrentEmote then return false, "StopCurrentEmote missing" end
        local ok_stop, stop_err = pcall(function() comp:StopCurrentEmote() end)
        if not ok_stop then return false, "StopCurrentEmote failed: " .. tostring(stop_err) end
        print("[RSDWTools] player.emote stop")
        return true, "stop"
    end

    if not comp.PlayEmote then return false, "PlayEmote missing" end
    local ok_play, play_err = pcall(function() comp:PlayEmote(parsed) end)
    if not ok_play then return false, "PlayEmote failed: " .. tostring(play_err) end
    print(string.format("[RSDWTools] player.emote %d via %s", parsed, alias))
    return true, tostring(parsed)
end

function M.play_animation(value_str)
    local text = trim_animation_arg(value_str)
    if text == "" then return false, "usage: player.anim.play <path|attack:path|montage:path|emote:name>" end

    local lower = text:lower()
    if lower == "stop" or lower:sub(1, 5) == "stop " then
        return M.stop_montage(text:sub(6))
    end
    if lower:sub(1, 21) == "player.attack.perform" then
        return attacks().attack_perform(text:sub(22))
    end
    if lower:sub(1, 13) == "player.attack" then
        return attacks().play_attack(text:sub(14))
    end
    if lower:sub(1, 19) == "player.anim.montage" then
        return M.play_montage(text:sub(20))
    end
    if lower:sub(1, 12) == "player.emote" then
        return M.play_emote(text:sub(13))
    end
    if lower:sub(1, 6) == "emote:" then
        return M.play_emote(text)
    end
    if lower:sub(1, 7) == "attack:" then
        return attacks().play_attack(text)
    end
    if lower:sub(1, 8) == "montage:" then
        return M.play_montage(text)
    end
    if lower:find("/gameplay/character/player/attacks/", 1, true) or lower:find("bp_player_", 1, true) then
        return attacks().play_attack(text)
    end
    return M.play_montage(text)
end

return M