-- feature_skills.lua
--
-- Skill XP / level RPC verbs. Backs the Skill Service pane in the
-- WPF UI.
--
-- Verbs:
--   world.skills.dump
--       -> ok world.skills.dump count=N|asset=SKILL_X;lvl=L;xp=C;max=M;next=T|...
--   world.skills.add_xp <SkillAssetName> <amount>
--   world.skills.set_level <SkillAssetName> <targetLevel>
--
-- Strategy:
--   * Resolve the live USkillData via FindFirstOf -> AssetRegistry sweep
--     (mirrors feature_inventory.resolve_asset).
--   * Locate the player's USkillComponent on the PlayerController
--     (field `SkillComponent`, fallback `GetPlayerSkillComponent()`).
--   * For mutation, walk `comp.Skills` (TArray<FSkill>) and write the
--     `CurrentXP` field on the matching entry. If the level changed,
--     call SkillPerkComponent:HandleSkillLevelIncreased so perks /
--     unlocks fire normally.
--
-- Notes:
--   * USkillData lives at /Game/Gameplay/Character/Player/Skills/SKILL_*
--     (10 active) plus a few in /DeprecatedSkills/ that we leave alone.
--   * The struct write through a TArray<FStruct> wrapper relies on
--     UE4SS exposing a setter on the wrapped element ; if the
--     environment doesn't support that the verb returns a clear error
--     so the user can fall back to AddXpFromEvent later.

local M = {}

local feature_actor = require("feature_actor")

-- ---------------------------------------------------------------------------
-- Helpers (local copies of the patterns in feature_inventory.lua).
-- ---------------------------------------------------------------------------
local function is_valid(o)
    return feature_actor.is_valid_object(o)
end

local function get_pawn()
    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return nil, "no local pawn" end
    return pawn
end

local function get_pc()
    local pawn, err = get_pawn()
    if not pawn then return nil, err end
    local ok, pc = pcall(function() return pawn:GetController() end)
    if ok and is_valid(pc) then return pc end
    ok, pc = pcall(function() return pawn.Controller end)
    if ok and is_valid(pc) then return pc end
    return nil, "no player controller"
end

local function get_skill_component()
    local pc, err = get_pc()
    if not pc then return nil, err end
    local ok, comp = pcall(function() return pc:GetPlayerSkillComponent() end)
    if ok and is_valid(comp) then return comp end
    ok, comp = pcall(function() return pc.SkillComponent end)
    if ok and is_valid(comp) then return comp end
    return nil, "no SkillComponent on PlayerController"
end

local function get_perk_component()
    local pawn, err = get_pawn()
    if not pawn then return nil, err end
    local ok, comp = pcall(function() return pawn:GetSkillPerkComponent() end)
    if ok and is_valid(comp) then return comp end
    ok, comp = pcall(function() return pawn.SkillPerkComponent end)
    if ok and is_valid(comp) then return comp end
    return nil, "no SkillPerkComponent on pawn"
end

-- ---------------------------------------------------------------------------
-- AssetRegistry sweep (SkillData) -- minimal copy of feature_inventory
-- internals so this module stays self-contained.
-- ---------------------------------------------------------------------------
local function unwrap_param(v)
    if type(v) ~= "userdata" then return v end
    for _ = 1, 2 do
        local has_get = false
        pcall(function() has_get = (type(v.get) == "function") end)
        if not has_get then return v end
        local ok, inner = pcall(function() return v:get() end)
        if not ok or inner == nil then return v end
        v = inner
        if type(v) ~= "userdata" then return v end
    end
    return v
end

local function fname_to_string(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    if type(v) == "userdata" then
        for _ = 1, 2 do
            if type(v) == "userdata" then
                local has_get = false
                pcall(function() has_get = (type(v.get) == "function") end)
                if has_get then
                    local ok, inner = pcall(function() return v:get() end)
                    if ok and inner ~= nil then v = inner else break end
                else
                    break
                end
            else
                break
            end
        end
        if type(v) == "string" then return v end
        if type(v) == "userdata" then
            for _, m in ipairs({ "ToString", "GetName", "GetPlainNameString" }) do
                local ok, s = pcall(function() return v[m](v) end)
                if ok and type(s) == "string" and s ~= "" then return s end
            end
        end
    end
    return nil
end

local _lut, _lut_ci, _swept = nil, nil, false

local function build_lookup()
    if not StaticFindObject then return nil, nil, "StaticFindObject unavailable" end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not is_valid(helpers) then return nil, nil, "UAssetRegistryHelpers CDO not found" end
    local ok, registry = pcall(function() return helpers:GetAssetRegistry() end)
    if not ok or not is_valid(registry) then return nil, nil, "GetAssetRegistry failed" end

    local class_path = { PackageName = FName("/Script/Dominion"), AssetName = FName("SkillData") }
    local out = {}
    local sweep_ok, serr = pcall(function()
        registry:GetAssetsByClass(class_path, out, true)
    end)
    if not sweep_ok then return nil, nil, "GetAssetsByClass errored: " .. tostring(serr) end

    local lut, lut_ci = {}, {}
    for _, raw in ipairs(out) do
        local entry = unwrap_param(raw)
        if entry then
            local pkg = fname_to_string(entry.PackageName)
            local name = fname_to_string(entry.AssetName)
            if pkg and name and not pkg:find("/DeprecatedSkills/", 1, true) then
                lut[name] = pkg
                lut_ci[name:lower()] = pkg
            end
        end
    end
    return lut, lut_ci, nil
end

local function ensure_lookup()
    if _swept and _lut then return _lut, _lut_ci, nil end
    local lut, lut_ci, err = build_lookup()
    if not lut then return nil, nil, err end
    _lut, _lut_ci, _swept = lut, lut_ci, true
    return _lut, _lut_ci, nil
end

local function resolve_skill(short_name)
    if not short_name or short_name == "" then return nil, "empty asset name" end

    if FindFirstOf then
        local ok, obj = pcall(FindFirstOf, short_name)
        if ok and is_valid(obj) then return obj end
    end

    local lut, lut_ci, err = ensure_lookup()
    if not lut then return nil, err end

    local pkg = lut[short_name]
    if not pkg then pkg = lut_ci[short_name:lower()] end
    if not pkg then
        -- one re-sweep in case a plugin loaded after our cache.
        _swept = false
        lut, lut_ci, err = ensure_lookup()
        if not lut then return nil, err end
        pkg = lut[short_name] or lut_ci[short_name:lower()]
    end
    if not pkg then return nil, "skill asset not found: " .. short_name end

    if LoadAsset then pcall(LoadAsset, pkg) end
    local canonical = pkg:match("([^/]+)$") or short_name
    local obj_path = pkg .. "." .. canonical
    local ok, obj = pcall(StaticFindObject, obj_path)
    if not ok or not is_valid(obj) then
        return nil, "StaticFindObject failed for " .. obj_path
    end
    return obj
end

-- ---------------------------------------------------------------------------
-- Internal: walk comp.Skills, return (entry, index) for a given USkillData,
-- or nil. Compares by GetFullName since wrapped userdata equality is flaky.
-- ---------------------------------------------------------------------------
local function find_skill_entry(comp, skill)
    local target_name
    pcall(function() target_name = skill:GetFullName() end)
    if not target_name then return nil, "could not read skill FullName" end

    local skills = comp.Skills
    local n = 0
    pcall(function() n = #skills end)
    for i = 1, n do
        local entry = skills[i]
        if entry then
            local sd_name
            pcall(function() sd_name = entry.SkillData:GetFullName() end)
            if sd_name == target_name then
                return entry, i
            end
        end
    end
    return nil, "skill not present in player's Skills array"
end

-- ---------------------------------------------------------------------------
-- world.skills.dump
-- ---------------------------------------------------------------------------
function M.dump(_args_str)
    local comp, cerr = get_skill_component()
    if not comp then return false, cerr end

    local skills = comp.Skills
    local n = 0
    pcall(function() n = #skills end)

    local parts = { "count=" .. tostring(n) }
    for i = 1, n do
        local entry = skills[i]
        if entry then
            local sd = entry.SkillData
            local short = "?"
            if is_valid(sd) then
                -- Note: USkillData has a UFunction GetName() that returns FText
                -- (display name), shadowing UObject::GetName(). Use the FName
                -- of the asset object instead so we get "SKILL_Construction" etc.
                local fn
                pcall(function() fn = sd:GetFName():ToString() end)
                if fn and fn ~= "" then short = fn end
            end
            local lvl, xp, maxlvl, nextxp = 0, 0, 0, 0
            pcall(function() xp = entry.CurrentXP end)
            pcall(function() lvl = comp:GetSkillLevel(sd) end)
            pcall(function() maxlvl = sd.MaxLevel end)
            pcall(function() nextxp = comp:GetTotalXPNeededForNextLevel(sd) end)
            parts[#parts + 1] = string.format(
                "asset=%s;lvl=%s;xp=%s;max=%s;next=%s",
                tostring(short), tostring(lvl), tostring(xp), tostring(maxlvl), tostring(nextxp))
        end
    end
    return true, table.concat(parts, "|")
end

-- ---------------------------------------------------------------------------
-- world.skills.add_xp <asset> <amount>
-- ---------------------------------------------------------------------------
function M.add_xp(args_str)
    local s = tostring(args_str or ""):match("^%s*(.-)%s*$")
    local name, amt_str = s:match("^(%S+)%s+(%S+)$")
    local amount = tonumber(amt_str)
    if not name or not amount then
        return false, "usage: world.skills.add_xp <SkillAssetName> <amount>"
    end

    local skill, rerr = resolve_skill(name)
    if not skill then return false, rerr end

    local comp, cerr = get_skill_component()
    if not comp then return false, cerr end

    local entry, ferr = find_skill_entry(comp, skill)
    if not entry then return false, ferr end

    local prev_lvl = 0
    pcall(function() prev_lvl = comp:GetSkillLevel(skill) end)

    local cur = 0
    pcall(function() cur = entry.CurrentXP end)
    local new_xp = cur + amount
    if new_xp < 0 then new_xp = 0 end

    local ok, werr = pcall(function() entry.CurrentXP = new_xp end)
    if not ok then
        return false, "could not write FSkill.CurrentXP (UE4SS TArray write rejected): " .. tostring(werr)
    end

    local new_lvl = prev_lvl
    pcall(function() new_lvl = comp:GetSkillLevel(skill) end)

    -- Fire the BP-side notifies the game's HUD listens to. Without these
    -- the raw CurrentXP write is invisible until the next natural XP gain.
    pcall(function() comp:BP_OnSkillXPChanged(skill, new_xp, cur) end)
    if new_lvl ~= prev_lvl then
        pcall(function() comp:BP_OnSkillLevelIncreased(skill, new_lvl, prev_lvl) end)
        -- Multicast delegate broadcast (UI widgets / perk component subscribe to this).
        pcall(function() comp.OnSkillLevelIncreasedDynamic:Broadcast(skill, new_lvl, prev_lvl) end)
        local perk = get_perk_component()
        if perk then
            pcall(function() perk:HandleSkillLevelIncreased(skill, new_lvl, prev_lvl) end)
        end
    end

    print(string.format("[RSDWTools] skills.add_xp %s +%d -> xp=%d lvl=%d (prev lvl=%d)",
        name, amount, new_xp, new_lvl, prev_lvl))
    return true, string.format("asset=%s;xp=%d;lvl=%d;prev=%d", name, new_xp, new_lvl, prev_lvl)
end

-- ---------------------------------------------------------------------------
-- world.skills.set_level <asset> <targetLevel>
-- ---------------------------------------------------------------------------
function M.set_level(args_str)
    local s = tostring(args_str or ""):match("^%s*(.-)%s*$")
    local name, lvl_str = s:match("^(%S+)%s+(%S+)$")
    local target = tonumber(lvl_str)
    if not name or not target then
        return false, "usage: world.skills.set_level <SkillAssetName> <level>"
    end
    if target < 1 then return false, "level must be >= 1" end

    local skill, rerr = resolve_skill(name)
    if not skill then return false, rerr end

    local comp, cerr = get_skill_component()
    if not comp then return false, cerr end

    local entry, ferr = find_skill_entry(comp, skill)
    if not entry then return false, ferr end

    local max_lvl = 99
    pcall(function() max_lvl = skill.MaxLevel end)
    if target > max_lvl then target = max_lvl end

    -- GetTotalXPNeededForLevel is on USkillComponent, takes the target level.
    local target_xp = nil
    pcall(function() target_xp = comp:GetTotalXPNeededForLevel(target) end)
    if not target_xp then
        return false, "GetTotalXPNeededForLevel call failed"
    end

    local prev_lvl = 0
    pcall(function() prev_lvl = comp:GetSkillLevel(skill) end)
    local prev_xp = 0
    pcall(function() prev_xp = entry.CurrentXP end)

    local ok, werr = pcall(function() entry.CurrentXP = target_xp end)
    if not ok then
        return false, "could not write FSkill.CurrentXP (UE4SS TArray write rejected): " .. tostring(werr)
    end

    local new_lvl = prev_lvl
    pcall(function() new_lvl = comp:GetSkillLevel(skill) end)

    pcall(function() comp:BP_OnSkillXPChanged(skill, target_xp, prev_xp) end)
    if new_lvl ~= prev_lvl then
        pcall(function() comp:BP_OnSkillLevelIncreased(skill, new_lvl, prev_lvl) end)
        pcall(function() comp.OnSkillLevelIncreasedDynamic:Broadcast(skill, new_lvl, prev_lvl) end)
        local perk = get_perk_component()
        if perk then
            pcall(function() perk:HandleSkillLevelIncreased(skill, new_lvl, prev_lvl) end)
        end
    end

    print(string.format("[RSDWTools] skills.set_level %s -> lvl=%d xp=%d (prev lvl=%d)",
        name, new_lvl, target_xp, prev_lvl))
    return true, string.format("asset=%s;xp=%d;lvl=%d;prev=%d", name, target_xp, new_lvl, prev_lvl)
end

return M
