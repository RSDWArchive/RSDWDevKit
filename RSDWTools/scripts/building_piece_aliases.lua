-- Explicit pre-1.0 -> 1.0 BuildingPieceData renames. These mappings were
-- verified against the 1.0 UE4SS object dump; the resolver never guesses.
local root = "/Game/Gameplay/BaseBuilding_New/BuildingPieces/Decorations/"

-- In 1.0 these assets gained a BUILDPIECE_ prefix without moving folders.
-- Keep the legacy leaves enumerated so an unrelated DA_ asset cannot be
-- silently remapped by a broad naming rule.
local prefixed = {
    AncientDragonkin = {
        "DA_BaseBuilding_Decoration_Dragonkin_Gargoyle_01",
        "DA_BaseBuilding_Decoration_Dragonkin_Gargoyle_02",
        "DA_BaseBuilding_Decoration_Dragonkin_Gargoyle_03",
        "DA_BaseBuilding_Decoration_Dragonkin_Obelisk_01",
        "DA_BaseBuilding_Decoration_Dragonkin_Obelisk_02",
        "DA_BaseBuilding_Decoration_Dragonkin_Obelisk_03",
        "DA_BaseBuilding_Decoration_Dragonkin_Statue_01v1",
        "DA_BaseBuilding_Decoration_Dragonkin_Statue_02v1",
    },
    Garou = {
        "DA_BaseBuilding_Decoration_Garou_Banner_Wall",
        "DA_BaseBuilding_Decoration_Garou_Drum",
        "DA_BaseBuilding_Decoration_Garou_Hanging_Ornament_01",
        "DA_BaseBuilding_Decoration_Garou_Hanging_Ornament_02",
        "DA_BaseBuilding_Decoration_Garou_Hanging_Ornament_03",
        "DA_BaseBuilding_Decoration_Garou_Hanging_Ornament_04",
        "DA_BaseBuilding_Decoration_Garou_Hanging_Pelt_01",
        "DA_BaseBuilding_Decoration_Garou_Stool",
        "DA_BaseBuilding_Decoration_Garou_Trophy_01",
        "DA_BaseBuilding_Decoration_Garou_Trophy_02",
        "DA_BaseBuilding_Decoration_Garou_Trophy_03",
        "DA_BaseBuilding_Decoration_Garou_Trophy_04",
        "DA_BaseBuilding_Decoration_Garou_Tusks_01",
        "DA_BaseBuilding_Decoration_Garou_Tusks_02",
        "DA_BaseBuilding_Decoration_Garou_Tusks_03",
    },
    General = {
        "DA_BaseBuilding_Decoration_General_Wood_Barrel_01",
        "DA_BaseBuilding_Decoration_General_Wood_Barrel_02",
        "DA_BaseBuilding_Decoration_General_Wood_Barrel_Keg",
        "DA_BaseBuilding_Decoration_General_Wood_Barrel_Pile",
        "DA_BaseBuilding_Decoration_General_Wood_Bin_Empty_Stack",
        "DA_BaseBuilding_Decoration_General_Wood_Bin_Empty",
        "DA_BaseBuilding_Decoration_General_Wood_Crate_Broken",
        "DA_BaseBuilding_Decoration_General_Wood_Crate_Sealed_Stack",
        "DA_BaseBuilding_Decoration_General_Wood_Crate_Sealed",
    },
    Literature = {
        "DA_BaseBuilding_Decoration_Literature_Book_Tome_Artisan_Standing",
        "DA_BaseBuilding_Decoration_Literature_Book_Tome_Attack_Standing",
        "DA_BaseBuilding_Decoration_Literature_Book_Tome_Construction_Standing",
        "DA_BaseBuilding_Decoration_Literature_Book_Tome_Generic_Laying",
        "DA_BaseBuilding_Decoration_Literature_Book_Tome_Generic_Open",
        "DA_BaseBuilding_Decoration_Literature_Book_Tome_Mining_Standing",
        "DA_BaseBuilding_Decoration_Literature_Book_Tome_Ranged_Standing",
        "DA_BaseBuilding_Decoration_Literature_Book_Tome_Runecrafting_Standing",
        "DA_BaseBuilding_Decoration_Literature_Book_Tome_Woodcutting_Standing",
    },
    ["Materials/Basic"] = {
        "DA_BaseBuilding_Decoration_Material_Basic_Barrel_Granite",
        "DA_BaseBuilding_Decoration_Material_Basic_Barrel_Sandstone",
        "DA_BaseBuilding_Decoration_Material_Basic_Barrel_Stone",
        "DA_BaseBuilding_Decoration_Material_Basic_Clay_Bin_01",
    },
    Plants = {
        "DA_BaseBuilding_Decoration_Plants_Potted_Dwellberry",
        "DA_BaseBuilding_Decoration_Plants_Potted_Onion",
        "DA_BaseBuilding_Decoration_Plants_Potted_Redberry",
    },
}

-- These three assets also shortened Decoration to Decor in 1.0.
local target_overrides = {
    ["Literature/DA_BaseBuilding_Decoration_Literature_Book_Tome_Construction_Standing"] =
        "BUILDPIECE_DA_BaseBuilding_Decor_Literature_Book_Tome_Construction_Standing",
    ["Literature/DA_BaseBuilding_Decoration_Literature_Book_Tome_Runecrafting_Standing"] =
        "BUILDPIECE_DA_BaseBuilding_Decor_Literature_Book_Tome_Runecrafting_Standing",
    ["Literature/DA_BaseBuilding_Decoration_Literature_Book_Tome_Woodcutting_Standing"] =
        "BUILDPIECE_DA_BaseBuilding_Decor_Literature_Book_Tome_Woodcutting_Standing",
}

local aliases = {}
for folder_name, leaves in pairs(prefixed) do
    local folder = root .. folder_name .. "/"
    for _, old_leaf in ipairs(leaves) do
        local new_leaf = target_overrides[folder_name .. "/" .. old_leaf]
            or ("BUILDPIECE_" .. old_leaf)
        aliases[folder .. old_leaf .. "." .. old_leaf] =
            folder .. new_leaf .. "." .. new_leaf
    end
end

return aliases
