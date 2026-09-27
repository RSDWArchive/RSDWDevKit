local M = {}

local core = require("feature_player_core")

local COMBAT_MAGIC_ALIASES = { "BP_Components_PlayerCombatMagic", "PlayerCombatMagicComponent" }
local UTILITY_MAGIC_ALIASES = { "BP_Components_PlayerUtilityMagic", "PlayerUtilityMagicComponent" }

local spell_unlock_cache = {}
local spell_cd_cache = {}
local spell_cont_cache = {}
local spell_unlock_added = {}

function M.cancel_spell()
    local pawn = core.get_pawn(); if not pawn then return false, "no local pawn" end
    local fired = 0
    for _, aliases in ipairs({ COMBAT_MAGIC_ALIASES, UTILITY_MAGIC_ALIASES }) do
        local comp, alias = core.get_component(pawn, aliases)
        if comp then
            local ok = core.call_comp_method(comp, alias, "Server_CancelSpell")
            if ok then fired = fired + 1 end
        end
    end
    if fired == 0 then return false, "no magic component resolved" end
    return true, tostring(fired) .. " cancel(s) dispatched"
end

function M.set_spells_unlock(value_str)
    local b = core.parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = core.get_pawn(); if not pawn then return false, "no local pawn" end
    local sc, sc_err, pc = core.get_spellcasting_component(pawn)
    if not sc then return false, sc_err end

    local ok_sel, selected = pcall(function() return sc.SelectedSpells end)
    if not ok_sel or not selected then return false, "SelectedSpells unreadable" end
    local ok_n, n = pcall(function() return #selected end)
    if not ok_n or type(n) ~= "number" then return false, "SelectedSpells len unreadable" end

    local sunlocked = nil
    if pc then
        local prok, prog = pcall(function() return pc.ProgressComponent end)
        if prok and type(prog) == "userdata" then
            local sok, su = pcall(function() return prog.SpellsUnlocked end)
            if sok and type(su) == "userdata" then sunlocked = su end
        end
    end

    local written, errs, set_added, set_removed = 0, 0, 0, 0
    if b then
        spell_unlock_cache = {}
        spell_unlock_added = {}
        for i = 1, n do
            local eok, entry = pcall(function() return selected[i] end)
            if eok and entry ~= nil and type(entry) == "userdata" then
                local rok, orig = pcall(function() return entry.bNeedsUnlocking end)
                spell_unlock_cache[i] = (rok and orig) or true
                local wok = pcall(function() entry.bNeedsUnlocking = false end)
                if wok then written = written + 1 else errs = errs + 1 end

                if sunlocked then
                    local already = false
                    local cok, hit = pcall(function()
                        if sunlocked.Contains then return sunlocked:Contains(entry) end
                        return false
                    end)
                    if cok and hit == true then already = true end
                    if not already then
                        local aok = pcall(function() sunlocked:Add(entry) end)
                        if aok then
                            set_added = set_added + 1
                            spell_unlock_added[#spell_unlock_added + 1] = entry
                        end
                    end
                end
            end
        end
    else
        for i = 1, n do
            local eok, entry = pcall(function() return selected[i] end)
            if eok and entry ~= nil and type(entry) == "userdata" then
                local orig = spell_unlock_cache[i]
                if orig ~= nil then
                    local wok = pcall(function() entry.bNeedsUnlocking = orig end)
                    if wok then written = written + 1 else errs = errs + 1 end
                end
            end
        end
        if sunlocked then
            for _, entry in ipairs(spell_unlock_added) do
                if type(entry) == "userdata" then
                    local rok = pcall(function()
                        if sunlocked.Remove then sunlocked:Remove(entry) end
                    end)
                    if rok then set_removed = set_removed + 1 end
                end
            end
        end
        spell_unlock_cache = {}
        spell_unlock_added = {}
    end
    return true, string.format("%s %d/%d (TSet %s %d)",
        b and "unlocked" or "relocked", written, n,
        b and "added" or "removed",
        b and set_added or set_removed)
end

function M.set_spells_zerocooldown(value_str)
    local b = core.parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = core.get_pawn(); if not pawn then return false, "no local pawn" end
    local sc, sc_err = core.get_spellcasting_component(pawn)
    if not sc then return false, sc_err end

    local ok_sel, selected = pcall(function() return sc.SelectedSpells end)
    if not ok_sel or not selected then return false, "SelectedSpells unreadable" end
    local ok_n, n = pcall(function() return #selected end)
    if not ok_n or type(n) ~= "number" then return false, "SelectedSpells len unreadable" end

    local written, errs = 0, 0
    if b then
        spell_cd_cache = {}
        for i = 1, n do
            local eok, entry = pcall(function() return selected[i] end)
            if eok and entry ~= nil and type(entry) == "userdata" then
                local rok, orig = pcall(function() return entry.CooldownDuration end)
                spell_cd_cache[i] = (rok and type(orig) == "number") and orig or 0
                local wok = pcall(function() entry.CooldownDuration = 0 end)
                if wok then written = written + 1 else errs = errs + 1 end
            end
        end
    else
        for i = 1, n do
            local eok, entry = pcall(function() return selected[i] end)
            if eok and entry ~= nil and type(entry) == "userdata" then
                local orig = spell_cd_cache[i]
                if orig ~= nil then
                    local wok = pcall(function() entry.CooldownDuration = orig end)
                    if wok then written = written + 1 else errs = errs + 1 end
                end
            end
        end
        spell_cd_cache = {}
    end
    return true, string.format("%s %d/%d spells (%d errs)",
        b and "zeroed" or "restored", written, n, errs)
end

function M.set_spells_continuouscast(value_str)
    local b = core.parse_bool(value_str)
    if b == nil then return false, "expected on|off" end
    local pawn = core.get_pawn(); if not pawn then return false, "no local pawn" end
    local sc, sc_err = core.get_spellcasting_component(pawn)
    if not sc then return false, sc_err end

    local ok_sel, selected = pcall(function() return sc.SelectedSpells end)
    if not ok_sel or not selected then return false, "SelectedSpells unreadable" end
    local ok_n, n = pcall(function() return #selected end)
    if not ok_n or type(n) ~= "number" then return false, "SelectedSpells len unreadable" end

    local written, errs = 0, 0
    if b then
        spell_cont_cache = {}
        for i = 1, n do
            local eok, entry = pcall(function() return selected[i] end)
            if eok and entry ~= nil and type(entry) == "userdata" then
                local rok, orig = pcall(function() return entry.bContinuouslyCast end)
                spell_cont_cache[i] = (rok and type(orig) == "boolean") and orig or false
                local wok = pcall(function() entry.bContinuouslyCast = true end)
                if wok then written = written + 1 else errs = errs + 1 end
            end
        end
    else
        for i = 1, n do
            local eok, entry = pcall(function() return selected[i] end)
            if eok and entry ~= nil and type(entry) == "userdata" then
                local orig = spell_cont_cache[i]
                if orig ~= nil then
                    local wok = pcall(function() entry.bContinuouslyCast = orig end)
                    if wok then written = written + 1 else errs = errs + 1 end
                end
            end
        end
        spell_cont_cache = {}
    end
    return true, string.format("%s %d/%d spells (%d errs)",
        b and "continuous" or "restored", written, n, errs)
end

return M