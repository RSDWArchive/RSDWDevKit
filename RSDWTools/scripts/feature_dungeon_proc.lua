-- feature_dungeon_proc.lua
-- Read-only probes for the /Script/Dungeon procedural dungeon surface.

local M = {}

local dungeon_room_catalog = require("dungeon_room_prefab_catalog")
local feature_actor = require("feature_actor")
local mod_paths = require("mod_paths")
local player_core = require("feature_player_core")
local safety = require("safety")

local DEFAULT_SAMPLE_LIMIT = 6
local MAX_SAMPLE_LIMIT = 25
local FIELD_SAMPLE_LIMIT = 4
local MAX_ROOMOPTIONS_SUMMARY_SPAN = 8

local SETTINGS_PATH = "/Script/Dungeon.Default__MapGenerationSettings"
local ASSET_SEARCH_ROOT = "/Game"
local MAX_ASSET_CANDIDATES = 12

local KNOWN_GENERATOR_CLASS_PATHS = {
    "/Game/Gameplay/World/Dungeon/DungeonGeneration/Blueprints/Core/BP_DungeonModel.BP_DungeonModel_C",
}

local KNOWN_TELEPORT_CLASS_PATH = "/Game/Gameplay/World/Dungeon/BP_DungeonTeleport.BP_DungeonTeleport_C"
local GENERATED_BOSSROOM_DEFAULT_BOSS_ALIAS = "skeletal"
local GENERATED_BOSSROOM_BOSS_SPAWN_Z_OFFSET_CM = 0
local GENERATED_BOSSROOM_BOSS_WATCH_TICK_MS = 500
local GENERATED_BOSSROOM_BOSS_WATCH_MAX_TICKS = 3600
local GENERATED_BOSSROOM_BOSS_CLASS_ALIASES = {
    skeletal = {
        label = "BP_AI_SkeletalWarrior_Character",
        class_path = "/FutureMajorVersion/Gameplay/AI/SkeletonFaction/MeleeSkeleton/OneHandSwordVariant/BP_AI_SkeletalWarrior_Character.BP_AI_SkeletalWarrior_Character_C",
    },
    warrior = {
        label = "BP_AI_SkeletalWarrior_Character",
        class_path = "/FutureMajorVersion/Gameplay/AI/SkeletonFaction/MeleeSkeleton/OneHandSwordVariant/BP_AI_SkeletalWarrior_Character.BP_AI_SkeletalWarrior_Character_C",
    },
    thane = {
        label = "BP_AI_ThaneBeast_MiniBoss_Character",
        class_path = "/Game/Gameplay/AI/BeastFaction/ThaneBeast/MiniBossVariant/BP_AI_ThaneBeast_MiniBoss_Character.BP_AI_ThaneBeast_MiniBoss_Character_C",
    },
    thanebeast = {
        label = "BP_AI_ThaneBeast_MiniBoss_Character",
        class_path = "/Game/Gameplay/AI/BeastFaction/ThaneBeast/MiniBossVariant/BP_AI_ThaneBeast_MiniBoss_Character.BP_AI_ThaneBeast_MiniBoss_Character_C",
    },
    razlem = {
        label = "BP_AI_SkeletalNecromancer_Razlem_Character",
        class_path = "/FutureMajorVersion/Gameplay/AI/SkeletonFaction/MagicSkeleton/Razlem/BP_AI_SkeletalNecromancer_Razlem_Character.BP_AI_SkeletalNecromancer_Razlem_Character_C",
    },
}

local MODEL_FIELDONE_FIELDS = {
    client_seed = { field = "Client_DungeonSeed", mode = "value" },
    listener = { field = "LoadListener", mode = "object" },
}

local MODEL_FIELDONE_ORDER = {
    "client_seed",
    "listener",
}

local MODEL_FIELDONE_DISABLED_FIELDS = {
    generator = "DungeonGenerator",
    items = "ItemSpawnManager",
    doors = "DungeonDoorsManager",
    characters = "CharacterManager",
    replication = "DungeonReplicationManager",
    minimap = "MiniMapManager",
    lighting = "LightingSwitcher",
    audio_volume = "AudioZoneVolume",
    audio_trigger = "AudioZoneTriggerBox",
    blocker = "BuildingBlocker",
}

local MANAGER_OBJECT_SPECS = {
    { key = "DungeonGenerator", queries = { "DungeonGenerator", "BP_DungeonGenerator_C" } },
    { key = "DungeonEntitySpawnManager", queries = { "DungeonEntitySpawnManager", "BP_DungeonEntitySpawnManager_C" } },
    { key = "DoorsManager", queries = { "DoorsManager", "BP_DoorsManager_C" } },
    { key = "DungeonReplicationManager", queries = { "DungeonReplicationManager", "BP_DungeonReplicationManager_C" } },
    { key = "MiniMapManager", queries = { "MiniMapManager", "BP_MiniMapManager_C" } },
    { key = "DungeonCharacterManager", queries = { "DungeonCharacterManager" } },
    { key = "DungeonLightingSwitcher", queries = { "DungeonLightingSwitcher", "BP_Dungeon_LightingSwitcher_C" } },
    { key = "DungeonBuildingBlocker", queries = { "DungeonBuildingBlocker", "BP_DungeonBuildingBlocker_C" } },
    { key = "AudioZone_TriggerBox", queries = { "AudioZone_TriggerBox", "BP_AudioZone_Volume_Resizable_C" } },
    { key = "DungeonTriggerBox", queries = { "DungeonTriggerBox" } },
}

local CONSTRUCTABLE_MANAGER_SPECS = {
    generator = {
        label = "DungeonGenerator",
        class_path = "/Game/Gameplay/World/Dungeon/DungeonGeneration/Blueprints/Core/BP_DungeonGenerator.BP_DungeonGenerator_C",
        model_field = "DungeonGenerator",
    },
    items = {
        label = "DungeonEntitySpawnManager",
        class_path = "/Game/Gameplay/World/Dungeon/Spawners/BP_DungeonEntitySpawnManager.BP_DungeonEntitySpawnManager_C",
        model_field = "ItemSpawnManager",
        backref_field = "Model",
    },
    doors = {
        label = "DoorsManager",
        class_path = "/Game/Gameplay/World/Dungeon/Doors/BP_DoorsManager.BP_DoorsManager_C",
        model_field = "DungeonDoorsManager",
        backref_field = "Model",
    },
    doors_native = {
        label = "DoorsManagerNative",
        class_path = "/Script/Dungeon.DoorsManager",
        model_field = "DungeonDoorsManager",
        backref_field = "Model",
    },
    characters = {
        label = "DungeonCharacterManager",
        class_path = "/Script/Dungeon.DungeonCharacterManager",
        model_field = "CharacterManager",
        backref_field = "Model",
    },
    replication = {
        label = "DungeonReplicationManager",
        class_path = "/Game/Gameplay/World/Dungeon/Multiplayer/BP_DungeonReplicationManager.BP_DungeonReplicationManager_C",
        model_field = "DungeonReplicationManager",
        backref_field = "Model",
    },
    minimap = {
        label = "MiniMapManager",
        class_path = "/Game/Gameplay/World/Dungeon/MiniMap/BP_MiniMapManager.BP_MiniMapManager_C",
        model_field = "MiniMapManager",
    },
}

local CONSTRUCTABLE_MANAGER_ORDER = { "generator", "items", "doors", "doors_native", "characters", "replication", "minimap" }
local MANAGER_GRAPH_ROLES = { "generator", "items", "doors_native", "characters", "replication", "minimap" }
local constructed_manager_cache = {}
local generated_spawn_cache = { next_batch = 0, latest_batch = 0, entries = {} }
local generated_bossroom_encounter_cache = { next_id = 0, latest = nil, encounters = {} }

local MANUAL_SPAWN_UNIT_SPECS = {
    procedural_room = { label = "DungeonProceduralRoomUnit", class_path = "/Script/Dungeon.DungeonProceduralRoomUnit" },
    room_unit = { label = "DungeonRoomUnit", class_path = "/Script/Dungeon.DungeonRoomUnit" },
    hallway_unit = { label = "DungeonHallwayUnit", class_path = "/Script/Dungeon.DungeonHallwayUnit" },
    spawner = { label = "DungeonSpawner", class_path = "/Script/Dungeon.DungeonSpawner" },
    chest_spawner = { label = "DungeonChestSpawner", class_path = "/Script/Dungeon.DungeonChestSpawner" },
    blocker = { label = "DungeonBuildingBlocker", class_path = "/Script/Dungeon.DungeonBuildingBlocker" },
    lighting = { label = "DungeonLightingSwitcher", class_path = "/Script/Dungeon.DungeonLightingSwitcher" },
}

local MANUAL_SPAWN_UNIT_ORDER = { "procedural_room", "room_unit", "hallway_unit", "spawner", "chest_spawner", "blocker", "lighting" }

local MANUAL_SPAWN_METHOD_ALIASES = {
    deferred = "deferred",
    deferred_place = "deferred_place",
    place = "deferred_place",
    world = "world",
    direct = "world",
    world_place = "world_place",
    direct_place = "world_place",
}

local MANUAL_SPAWN_METHOD_ORDER = { "deferred_place", "deferred", "world_place", "world" }

local MODEL_CALLONE_ORDER = { "onrep", "build_blocker", "show_loading_on", "show_loading_off", "receive_tick", "beginplay", "construction", "respawn_resources" }

local GENERATOR_FIELDONE_FIELDS = {
    algo = { field = "Algo", mode = "object" },
    grid = { field = "Grid", mode = "object" },
    room_subclass = { field = "RoomSpawnSubclass", mode = "object" },
    hallway_subclass = { field = "HallwaySpawnSubclass", mode = "object" },
}

local GENERATOR_FIELDONE_ORDER = { "algo", "grid", "room_subclass", "hallway_subclass" }
local GENERATOR_CLASSREF_FIELDS = {
    room = { field = "RoomSpawnSubclass", label = "RoomSpawnSubclass" },
    hallway = { field = "HallwaySpawnSubclass", label = "HallwaySpawnSubclass" },
}

local GENERATOR_CLASSREF_ORDER = { "room", "hallway" }
local GENERATOR_CALLONE_ORDER = { "rooms_options" }

local DUNGEON_TILE_SIZE_CM = 600
local CONNECTED_DUNGEON_MAX_ROOMS = 200
local CONNECTED_ROOM_PREFAB_SPECS = {
    { key = "boss", label = "BP_BossRoom_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/PrefabRooms/BP_BossRoom.BP_BossRoom_C" },
    { key = "treasure", label = "BP_TreasureRoomPrefab_02_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/PrefabRooms/BP_TreasureRoomPrefab_02.BP_TreasureRoomPrefab_02_C" },
    { key = "jump_01", label = "BP_RoomJump_01_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomJump_01.BP_RoomJump_01_C" },
    { key = "jump_02", label = "BP_RoomJump_02_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomJump_02.BP_RoomJump_02_C" },
    { key = "jump_03", label = "BP_RoomJump_03_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomJump_03.BP_RoomJump_03_C" },
    { key = "large_01", label = "BP_RoomLarge_01_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomLarge_01.BP_RoomLarge_01_C" },
    { key = "large_02", label = "BP_RoomLarge_02_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomLarge_02.BP_RoomLarge_02_C" },
    { key = "large_03", label = "BP_RoomLarge_03_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomLarge_03.BP_RoomLarge_03_C" },
    { key = "prison_01", label = "BP_RoomPrison_01_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomPrison_01.BP_RoomPrison_01_C" },
    { key = "puzzle_01", label = "BP_RoomPuzzle_01_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomPuzzle_01.BP_RoomPuzzle_01_C" },
    { key = "resources_01", label = "BP_RoomResources_01_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomResources_01.BP_RoomResources_01_C" },
    { key = "stealth_01", label = "BP_RoomStealth_01_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomStealth_01.BP_RoomStealth_01_C" },
    { key = "stealth_02", label = "BP_RoomStealth_02_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomStealth_02.BP_RoomStealth_02_C" },
    { key = "trap_01", label = "BP_RoomTrap_01_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomTrap_01.BP_RoomTrap_01_C" },
    { key = "vault_01", label = "BP_RoomVault_01_C", path = "/Game/Gameplay/World/Dungeon/Rooms/Refactor/SimplePrefabs/BP_RoomVault_01.BP_RoomVault_01_C" },
}

local CONNECTED_DUNGEON_MAX_LINKS_PER_ROOM = 3
local CONNECTED_DUNGEON_LINE_SAMPLE_LIMIT = 80
local GENERATED_SPAWNER_DEFAULT_LIMIT = 80
local GENERATED_SPAWNER_MAX_LIMIT = 200
local CONNECTED_SMART_USAGE_PENALTY = 100000
local CONNECTED_SMART_NATIVE_CAP_PENALTY = 250000
local CONNECTED_SMART_CATEGORY_USAGE_PENALTY = 12000
local CONNECTED_SMART_SAME_PARENT_PENALTY = 10000
local CONNECTED_SMART_REQUIRED_VARIETY_BONUS = 2000000
local CONNECTED_SMART_ENEMY_DIRECT_ACTOR_SPAWN_Z_OFFSET_CM = 300
local CONNECTED_ROOM_MODE_ALIASES = {
    base = "base",
    generic = "base",
    classref = "base",
    classrefs = "base",
    prefab = "prefabs",
    prefabs = "prefabs",
    varied = "prefabs",
    concrete = "prefabs",
    smart = "smart",
    slots = "smart",
    catalog = "smart",
    topology = "smart",
    smartdirect = "smartdirect",
    direct = "smartdirect",
    rooms = "smartdirect",
    nohallway = "smartdirect",
    nohallways = "smartdirect",
    smarthallways = "smart",
    smarthall = "smart",
}
local CONNECTED_LAYOUT_DIRECTIONS = {
    { key = "e", x = 1, y = 0, hallway_yaw = 0 },
    { key = "w", x = -1, y = 0, hallway_yaw = 0 },
    { key = "n", x = 0, y = 1, hallway_yaw = 90 },
    { key = "s", x = 0, y = -1, hallway_yaw = 90 },
}

local CONNECTED_SMART = {
    default_origin = { X = 0, Y = 0, Z = 100000 },
    sides = { "N", "E", "S", "W" },
    side_index = { N = 1, E = 2, S = 3, W = 4 },
    side_delta = { N = { x = 0, y = -1 }, E = { x = 1, y = 0 }, S = { x = 0, y = 1 }, W = { x = -1, y = 0 } },
    opposite = { N = "S", E = "W", S = "N", W = "E" },
    terminal_reservation_window = 8,
    terminal_reservation_bonus = 1000000,
    required_variety_attempts = 64,
    terminal_attach_backbone_nodes = 14,
    entrance_root_min_links = 3,
    entrance_hub_connector_order = {
        "special_entrance_south_dungeon_door",
        "special_entrance_west_destructible_wall",
        "special_entrance_top_north",
    },
    reserved_terminal_keys = {
        bossroom = true,
        roomstealth_01 = true,
        roomstealth_02 = true,
        roomtrap_01 = true,
    },
    special_connector_overrides = {
        entranceroom_v6 = {
            reason = "reviewed_entrance_hub_three_exit_candidate",
            max_connections = 3,
            openings = {
                N = {
                    {
                        x = 5,
                        y = 0,
                        source_x = 5,
                        source_y = 0,
                        wall = "EntranceRoomSpecialConnector",
                        wall_index = -2003,
                        wall_z_cm = 600,
                        wall_yaw = -180,
                        connector_kind = "special_entrance_top_north",
                        visual_anchor = "top north reviewed anchor approx 2684,24,100668",
                        openwalls_skip = true,
                        openwalls_skip_reason = "entranceroom top-north special connector uses authored visible opening, not normal CDO Walls/WallISM; neighbor wall is removed only",
                    },
                },
                S = {
                    {
                        x = 4,
                        y = 7,
                        source_x = 4,
                        source_y = 6,
                        wall = "EntranceRoomSpecialConnector",
                        wall_index = -2001,
                        wall_z_cm = 0,
                        wall_yaw = 0,
                        connector_kind = "special_entrance_south_dungeon_door",
                        openwalls_skip = true,
                        openwalls_skip_reason = "entranceroom special connector uses SM_DungeonDoor/CurtainVolume, not normal CDO Walls/WallISM; neighbor wall is removed only",
                    },
                },
                W = {
                    {
                        x = 1,
                        y = 5,
                        source_x = 1,
                        source_y = 5,
                        wall = "EntranceRoomSpecialConnector",
                        wall_index = -2002,
                        wall_z_cm = 300,
                        wall_yaw = 90,
                        connector_kind = "special_entrance_west_destructible_wall",
                        visual_anchor = "west reviewed anchor approx 850,3700,100200",
                        child_target_local = { X = 850.388, Y = 3700.359, Z = 200.383 },
                        openwalls_skip = true,
                        openwalls_skip_reason = "entranceroom west special connector uses BP_DectructibleDungeonWall/Teleport visual gap, not normal CDO Walls/WallISM; neighbor wall is removed only",
                    },
                },
            },
        },
        bossroom = {
            reason = "reviewed_bossroom_west_arcade_slot",
            openings = {
                W = {
                    {
                        x = 0,
                        y = 4,
                        source_x = 0,
                        source_y = 4,
                        wall = "BossRoomSpecialConnector",
                        wall_index = -1001,
                        wall_z_cm = 0,
                        wall_yaw = 90,
                        connector_kind = "special_bossroom_west",
                        openwalls_skip = true,
                        openwalls_skip_reason = "bossroom special connector has no normal CDO Walls/WallISM slot; parent wall is removed only",
                    },
                },
            },
        },
    },
    structural_role_plan = {
        { role = "entrance", key = "entranceroom_v6", status = "required_special_hub_root", reason = "reviewed_south_west_top_north_special_connectors_without_normal_cdo_walls", connector_hint = "special:S@4,7 z=0;special:W@1,5 z=300 child_target=850,3700,100200;special:N@5,0 z=600 anchor=2684,24,100668;lower-north destructible=3003,1202,99705 yaw=180" },
        { role = "lever", key = "leverroom_v2", status = "deferred_empty_actor", reason = "no_visible_room_content_in_manual_test", connector_hint = "row:N@2,0:Wall" },
        { role = "boss", key = "bossroom", status = "required_special_terminal", reason = "reviewed_west_arcade_slot_without_normal_cdo_walls", connector_hint = "row:W@0,4:Wall;special_wall_z_cm=0" },
        { role = "puzzle", key = "roompuzzle_01", status = "quarantined", reason = "reviewed_slots_not_traversable" },
    },
}

local GENERATOR_ROOMOPTION_FIELDS = {
    coords = { field = "Coordinates", mode = "intvec" },
    shape_slots = { field = "ShapeSlotsOptions", mode = "count" },
    rotation = { field = "Rotation", mode = "value" },
    type = { field = "Type", mode = "shape_type" },
    prefab = { field = "Prefab", mode = "object", disabled = "disabled after option 8 crashed at about_to_read_Prefab; use type/coords/shape_slots/height/max_count instead" },
    height = { field = "Height", mode = "value" },
    max_count = { field = "MaxCount", mode = "value" },
}

local GENERATOR_ROOMOPTION_ORDER = { "coords", "shape_slots", "rotation", "type", "height", "max_count" }
local GENERATOR_ROOMOPTIONS_SUMMARY_ORDER = { "type", "coords", "shape_slots", "height", "max_count" }

local DUNGEON_SHAPE_TYPE_NAMES = {
    [0] = "None",
    [1] = "Entrance",
    [2] = "MiniBoss",
    [3] = "Treasure",
    [4] = "Lever",
    [5] = "Simple",
    [6] = "Puzzle",
    [7] = "BattleArena",
    [8] = "Resource",
    [9] = "Hallway",
}

local SETTINGS_FIELDS = {
    { name = "OneMeterSize", mode = "value" },
    { name = "OneTileSize", mode = "value" },
    { name = "DungeonDepth", mode = "value" },
    { name = "DungeonDeleteDelay", mode = "value" },
    { name = "GenerationSequence", mode = "count_sample" },
    { name = "DungeonGeneratorV2", mode = "soft" },
}

local MODEL_CDO_FIELDS = {
    { name = "DungeonGeneratorClass", mode = "soft" },
    { name = "DungeonEntitySpawnManagerClass", mode = "soft" },
    { name = "DungeonDoorsManagerClass", mode = "soft" },
    { name = "DungeonReplicationManagerClass", mode = "soft" },
    { name = "MiniMapManagerClass", mode = "soft" },
    { name = "LightingSwitcherClass", mode = "object" },
    { name = "BuildingBlockerClass", mode = "object" },
    { name = "AudioZoneVolumeClass", mode = "object" },
    { name = "AudioZoneTriggerBoxClass", mode = "object" },
}

local MODEL_METHOD_SURFACE = {
    "ShowLoadingScreenEvent",
    "OnTimeToRespawnResources",
    "OnTimeToDeleteDungeon",
    "OnRep_DataContext",
    "CreateAndSpawnBuildBlocker",
    "ReceiveTick",
    "ExecuteUbergraph_BP_DungeonModel",
    "K2_DestroyActor",
    "K2_GetActorLocation",
    "GetClass",
    "GetName",
}

local TELEPORT_METHOD_SURFACE = {
    "UpdatePendingTimer",
    "StopPendingTimer",
    "StartPendingTimer",
    "ShowLoading",
    "SetIsExitTeleport",
    "OnRep_ClientDungeonSeed",
    "OnRep_CharactersWithFailedTeleport",
    "OnInteraction",
    "OnDungeonLoaded",
    "DeleteDungeon",
    "ReceiveBeginPlay",
    "UserConstructionScript",
    "GetDisplayName",
    "BndEvt__BP_DungeonTeleport_InteractionComponent_K2Node_ComponentBoundEvent_1_OnInteraction__DelegateSignature",
    "K2_DestroyActor",
    "K2_GetActorLocation",
    "GetClass",
    "GetName",
}

local PROCEDURAL_CLASS_SPECS = {
    {
        key = "DungeonSpawnManager",
        queries = { "DungeonSpawnManager" },
        fields = {
            { name = "SpawnedDungeons", mode = "count_sample" },
        },
    },
    {
        key = "DungeonModel",
        queries = { "DungeonModel", "BP_DungeonModel_C" },
        fields = {
            { name = "Client_DungeonSeed", mode = "value" },
            { name = "DungeonGenerator", mode = "object" },
            { name = "ItemSpawnManager", mode = "object" },
            { name = "DungeonDoorsManager", mode = "object" },
            { name = "CharacterManager", mode = "object" },
            { name = "DungeonReplicationManager", mode = "object" },
            { name = "MiniMapManager", mode = "object" },
            { name = "LightingSwitcher", mode = "object" },
            { name = "AudioZoneVolume", mode = "object" },
            { name = "AudioZoneTriggerBox", mode = "object" },
            { name = "BuildingBlocker", mode = "object" },
            { name = "DungeonContext", mode = "context" },
        },
    },
    {
        key = "DungeonTeleport",
        queries = { "DungeonTeleport" },
        fields = {
            { name = "DungeonState", mode = "value" },
            { name = "BiomeType", mode = "value" },
            { name = "CustomSeed", mode = "value" },
            { name = "Client_DungeonSeed", mode = "value" },
            { name = "bIsExitTeleport", mode = "value" },
            { name = "bUseTeleportLocation", mode = "value" },
            { name = "DungeonSpawnLocation", mode = "vec" },
            { name = "DungeonInterface", mode = "object" },
            { name = "ExitPointComponent", mode = "object" },
        },
    },
    {
        key = "DungeonTeleportBossGym",
        queries = { "DungeonTeleportBossGym" },
        fields = {
            { name = "TargetToTeleport", mode = "object" },
            { name = "TargetToSpawnBoss", mode = "object" },
            { name = "BossActorClass", mode = "object" },
            { name = "bIsSpawnBossOnEnterGym", mode = "value" },
        },
    },
    {
        key = "DungeonRoomUnit",
        queries = { "DungeonRoomUnit" },
        fields = {
            { name = "RoomType", mode = "value" },
            { name = "RoomEnemySpawners", mode = "count_sample" },
            { name = "TreasureSpawners", mode = "count_sample" },
            { name = "ResourceVolumeSpawners", mode = "count_sample" },
            { name = "DoorsTransform", mode = "count" },
            { name = "ExitFromDungeonDoorTransform", mode = "count" },
        },
    },
    {
        key = "DungeonProceduralRoomUnit",
        queries = { "DungeonProceduralRoomUnit" },
        fields = {
            { name = "bIsPrefab", mode = "value" },
            { name = "HeightUnit", mode = "value" },
            { name = "CellPositions", mode = "count" },
            { name = "CellUnits", mode = "count" },
            { name = "RoomLights", mode = "count_sample" },
            { name = "WallPositions", mode = "count" },
            { name = "TorchPositions", mode = "count" },
        },
    },
    {
        key = "DungeonHallwayUnit",
        queries = { "DungeonHallwayUnit" },
        fields = {
            { name = "EnemySpawners", mode = "count_sample" },
            { name = "ResourceVolumeSpawners", mode = "count_sample" },
            { name = "HallwayOptions", mode = "value" },
        },
    },
    {
        key = "DoorsManager",
        queries = { "DoorsManager" },
        fields = {
            { name = "DungeonDoorsClass", mode = "object" },
            { name = "ExitFromDungeonDoorClass", mode = "object" },
            { name = "DungeonTeleportClass", mode = "object" },
            { name = "SpawnedActors", mode = "count_sample" },
            { name = "SpawnedCurtain", mode = "object" },
            { name = "Model", mode = "object" },
        },
    },
    {
        key = "DungeonEntitySpawnManager",
        queries = { "DungeonEntitySpawnManager" },
        fields = {
            { name = "RoomEnemySpawners", mode = "count_sample" },
            { name = "CorridorEnemySpawners", mode = "count_sample" },
            { name = "TreasureRoomSpawners", mode = "count_sample" },
            { name = "ResourceSpawners", mode = "count_sample" },
            { name = "BossSpawner", mode = "object" },
            { name = "BossActor", mode = "object" },
            { name = "bBossIsDead", mode = "value" },
            { name = "Model", mode = "object" },
        },
    },
    { key = "DungeonGenerator", queries = { "DungeonGenerator" }, fields = {} },
    { key = "DungeonReplicationManager", queries = { "DungeonReplicationManager" }, fields = {} },
    { key = "DungeonCharacterManager", queries = { "DungeonCharacterManager" }, fields = {} },
    { key = "MiniMapManager", queries = { "MiniMapManager" }, fields = {} },
    { key = "DungeonSpawner", queries = { "DungeonSpawner" }, fields = {} },
    { key = "DungeonChestSpawner", queries = { "DungeonChestSpawner" }, fields = {} },
    { key = "Door", queries = { "Door" }, fields = {
        { name = "DoorType", mode = "value" },
        { name = "bIsDoorOpen", mode = "value" },
    } },
    { key = "DestructibleWall", queries = { "DestructibleWall" }, fields = {
        { name = "RelatedRoom", mode = "object" },
    } },
    { key = "CurtainVolume", queries = { "CurtainVolume" }, fields = {
        { name = "Destination", mode = "object" },
        { name = "bIsAccessible", mode = "value" },
        { name = "BossActor", mode = "object" },
    } },
    { key = "Lever", queries = { "Lever" }, fields = {} },
    { key = "DungeonTriggerBox", queries = { "DungeonTriggerBox" }, fields = {} },
    { key = "ResourceSpawnVolume", queries = { "ResourceSpawnVolume" }, fields = {} },
}

local GENERATED_OBJECT_SPECS = {
    { key = "DungeonModel", queries = { "DungeonModel", "BP_DungeonModel_C" } },
    { key = "DungeonTeleport", queries = { "DungeonTeleport", "BP_DungeonTeleport_C" } },
    { key = "DungeonRoomUnit", queries = { "DungeonRoomUnit" } },
    { key = "DungeonProceduralRoomUnit", queries = { "DungeonProceduralRoomUnit" } },
    { key = "DungeonHallwayUnit", queries = { "DungeonHallwayUnit" } },
    { key = "DungeonRoom", queries = { "DungeonRoom" } },
    { key = "DungeonHallway", queries = { "DungeonHallway" } },
    { key = "DungeonAlgo", queries = { "DungeonAlgo", "BP_DungeonAlgo_C" } },
    { key = "DungeonGrid", queries = { "DungeonGrid", "BP_DungeonGrid_C" } },
    { key = "DungeonSeed", queries = { "DungeonSeed", "BP_DungeonSeed_C" } },
    { key = "BiomeConfig", queries = { "BiomeConfig", "SummerBiomeConfig", "WinterBiomeConfig" } },
    { key = "DungeonSpawner", queries = { "DungeonSpawner" } },
    { key = "DungeonChestSpawner", queries = { "DungeonChestSpawner" } },
    { key = "DungeonChest", queries = { "DungeonChest" } },
    { key = "Door", queries = { "Door" } },
    { key = "DestructibleWall", queries = { "DestructibleWall" } },
    { key = "CurtainVolume", queries = { "CurtainVolume" } },
    { key = "Lever", queries = { "Lever" } },
    { key = "ResourceSpawnVolume", queries = { "ResourceSpawnVolume" } },
    { key = "DungeonBuildingBlocker", queries = { "DungeonBuildingBlocker", "BP_DungeonBuildingBlocker_C" } },
    { key = "DungeonLightingSwitcher", queries = { "DungeonLightingSwitcher", "BP_Dungeon_LightingSwitcher_C" } },
    { key = "DungeonTriggerBox", queries = { "DungeonTriggerBox" } },
}

local GENERATED_BOSSROOM_PROBE = {
    near_distance_cm = 9000,
    object_sample_limit = 80,
    component_sample_limit = 64,
    snapshot_component_names = {
        "SM_TreasureGate01",
        "SM_TreasureGate02",
        "BossSpawnPoint",
        "Niagara",
        "SM_Statue",
        "BlindArcadeISM",
        "ArcadeWallISM",
        "WallSmallISM",
    },
    keywords = {
        "boss", "chest", "treasure", "gate", "door", "trigger", "curtain", "lever",
        "destruct", "wall", "arcade", "blind", "small", "open", "close", "unlock",
        "dead", "death", "reward",
    },
    object_specs = {
        { key = "BossRoom", queries = { "BP_BossRoom_C", "BossRoom" }, always_sample = true },
        { key = "BossChestSpawner", queries = { "BP_BossChestSpawner_C", "BossChestSpawner" }, always_sample = true },
        { key = "MiniBossSpawner", queries = { "BP_MiniBossSpawner_C", "MiniBossSpawner" }, always_sample = true },
        { key = "DungeonChestSpawner", queries = { "DungeonChestSpawner" } },
        { key = "DungeonSpawner", queries = { "DungeonSpawner" } },
        { key = "DungeonChest", queries = { "DungeonChest" } },
        { key = "Door", queries = { "Door" } },
        { key = "DungeonTriggerBox", queries = { "DungeonTriggerBox" } },
        { key = "CurtainVolume", queries = { "CurtainVolume" } },
        { key = "Lever", queries = { "Lever" } },
        { key = "DestructibleWall", queries = { "DestructibleWall" } },
    },
    snapshot_object_specs = {
        { key = "BossChestSpawner", queries = { "BP_BossChestSpawner_C", "BossChestSpawner" }, always_sample = true },
        { key = "MiniBossSpawner", queries = { "BP_MiniBossSpawner_C", "MiniBossSpawner" }, always_sample = true },
        { key = "DungeonChestSpawner", queries = { "DungeonChestSpawner" } },
        { key = "DungeonChest", queries = { "DungeonChest" } },
        { key = "DungeonSpawner", queries = { "DungeonSpawner" } },
        { key = "Door", queries = { "Door" } },
        { key = "DungeonTriggerBox", queries = { "DungeonTriggerBox" } },
        { key = "CurtainVolume", queries = { "CurtainVolume" } },
        { key = "DestructibleWall", queries = { "DestructibleWall" } },
    },
    component_specs = {
        { label = "ActorComponent", class_path = "/Script/Engine.ActorComponent" },
        { label = "SceneComponent", class_path = "/Script/Engine.SceneComponent" },
        { label = "StaticMeshComponent", class_path = "/Script/Engine.StaticMeshComponent" },
        { label = "InstancedStaticMeshComponent", class_path = "/Script/Engine.InstancedStaticMeshComponent" },
        { label = "ChildActorComponent", class_path = "/Script/Engine.ChildActorComponent" },
        { label = "BoxComponent", class_path = "/Script/Engine.BoxComponent" },
    },
}

local GENERATED_ENTRANCE_PROBE = {
    near_distance_cm = 9000,
    object_sample_limit = 80,
    component_sample_limit = 64,
    keywords = {
        "entrance", "teleport", "portal", "exit", "spawn", "start", "door", "dungeondoor",
        "fence", "curtain", "gate", "interaction", "lever", "vault", "room",
    },
    authored_anchors = {
        { key = "teleport_property", label = "EntranceRoom Teleport property", local_loc = { X = 850, Y = 3400, Z = 350 }, local_yaw = -90 },
        { key = "south_dungeon_door_mesh", label = "SM_DungeonDoor mesh", local_loc = { X = 2700, Y = 4190, Z = 0 }, local_yaw = -90 },
        { key = "special_connector_parent_slot", label = "special connector parent slot S@4,7", local_loc = { X = 2400, Y = 4200, Z = 0 }, local_yaw = 0 },
        { key = "special_connector_visual_midline", label = "expected doorway midline near S@4.5,7", local_loc = { X = 2700, Y = 4200, Z = 0 }, local_yaw = 0 },
        { key = "west_reviewed_destructible_anchor", label = "reviewed west destructible wall anchor", local_loc = { X = 850.388, Y = 3700.359, Z = 200.383 }, local_yaw = -90 },
        { key = "north_lower_reviewed_cap_anchor", label = "reviewed lower north destructible wall anchor", local_loc = { X = 3003.009, Y = 1201.694, Z = -295.076 }, local_yaw = 180 },
        { key = "north_top_reviewed_connector_anchor", label = "reviewed top north connector anchor", local_loc = { X = 2683.682, Y = 23.775, Z = 667.993 }, local_yaw = 0 },
        { key = "fence_door_cluster_center", label = "SM_FenceDoor cluster center", local_loc = { X = 2607.5, Y = 1276, Z = 594 }, local_yaw = 0 },
    },
    patch_actor_class_path = "/Game/Gameplay/World/Dungeon/Doors/BP_DungeonDoor.BP_DungeonDoor_C",
    patch_actor_frame_relative_yaw = 90,
    patch_actor_frame_offset = { X = 300, Y = 0, Z = 0 },
    patch_instance_sample_limit = 512,
    patch_candidates = {
        { key = "west_destructible_wall", group = "closures", label = "west reviewed destructible wall", local_loc = { X = 850.388, Y = 3700.359, Z = 200.383 }, frame_yaw = 0, actor_mode = "direct", actor_yaw = -90, actor_class_path = "/Game/Gameplay/World/Dungeon/Doors/BP_DectructibleDungeonWall.BP_DectructibleDungeonWall_C", source = "manual visual anchor from 2026-06-02 test; BP_DectructibleDungeonWall fits west hole after hand alignment", notes = "destructible wall closure/possible future breakable side exit; measured actor location replaces earlier rough anchor 810,3348,100334" },
        { key = "north_lower_destructible_wall", group = "closures", label = "lower north reviewed destructible wall cap", local_loc = { X = 3003.009, Y = 1201.694, Z = -295.076 }, frame_yaw = 90, actor_mode = "direct", actor_yaw = 180, actor_class_path = "/Game/Gameplay/World/Dungeon/Doors/BP_DectructibleDungeonWall.BP_DectructibleDungeonWall_C", source = "manual visual anchor from 2026-06-03 test; BP_RoomPrefabBase had no collision/glitched, so replaced with BP_DectructibleDungeonWall", notes = "lower-north cap uses the hand-aligned destructible wall position/yaw 180 to block the no-floor gap without exposing a usable branch" },
        { key = "north_top_connector_marker", group = "upper", label = "top north reviewed connector marker", local_loc = { X = 2683.682, Y = 23.775, Z = 667.993 }, frame_yaw = 90, actor_mode = "direct", actor_yaw = 0, actor_class_path = "/Game/Gameplay/World/Dungeon/Doors/BP_DungeonDoor.BP_DungeonDoor_C", source = "manual visual anchor from 2026-06-02 test; candidate for future top north room connector", notes = "optional marker only; not part of default closures because this opening should become a real branch, not a cap" },
    },
    patch_candidate_groups = {
        closures = { "west_destructible_wall", "north_lower_destructible_wall" },
        hubvisual = { "west_destructible_wall", "north_lower_destructible_wall" },
        west = { "west_destructible_wall" },
        lower = { "north_lower_destructible_wall" },
        north = { "north_lower_destructible_wall", "north_top_connector_marker" },
        upper = { "north_top_connector_marker" },
        all = { "west_destructible_wall", "north_lower_destructible_wall", "north_top_connector_marker" },
    },
    object_specs = {
        { key = "EntranceRoom", queries = { "EntranceRoom_V6_C", "EntranceRoom_V6", "EntranceRoom" }, always_sample = true },
        { key = "DungeonTeleport", queries = { "BP_DungeonTeleport_C", "DungeonTeleport" }, always_sample = true },
        { key = "Door", queries = { "Door", "DungeonDoor" } },
        { key = "CurtainVolume", queries = { "CurtainVolume" } },
        { key = "Lever", queries = { "Lever" } },
        { key = "DungeonTriggerBox", queries = { "DungeonTriggerBox" } },
        { key = "DungeonModel", queries = { "BP_DungeonModel_C", "DungeonModel" } },
    },
    component_specs = {
        { label = "ActorComponent", class_path = "/Script/Engine.ActorComponent" },
        { label = "SceneComponent", class_path = "/Script/Engine.SceneComponent" },
        { label = "StaticMeshComponent", class_path = "/Script/Engine.StaticMeshComponent" },
        { label = "InstancedStaticMeshComponent", class_path = "/Script/Engine.InstancedStaticMeshComponent" },
        { label = "ChildActorComponent", class_path = "/Script/Engine.ChildActorComponent" },
        { label = "BoxComponent", class_path = "/Script/Engine.BoxComponent" },
        { label = "SphereComponent", class_path = "/Script/Engine.SphereComponent" },
    },
}

local GENERATED_ACTOR_PROBE = {
    cleanup_modes = { destroy = true, hard = true, quarantine = true },
    max_option_spawn_span = 12,
    surface_targets = {
        room = { label = "DungeonProceduralRoomUnit", queries = { "DungeonProceduralRoomUnit" } },
        hallway = { label = "DungeonHallwayUnit", queries = { "DungeonHallwayUnit" } },
    },
    surface_methods = {
        room = {
            "GenerateFloorCell", "CreateRoomOnClient", "GetShapeSlotsOptions",
            "GetRandomRoomLight", "GetRandomPillar", "OnBossIsDead",
            "K2_GetRootComponent", "K2_GetComponentsByClass", "K2_DestroyActor",
            "SetLifeSpan", "SetActorHiddenInGame", "SetActorEnableCollision",
        },
        hallway = {
            "CreateHallwayOnClient", "Init", "K2_GetRootComponent", "K2_GetComponentsByClass",
            "K2_DestroyActor", "SetLifeSpan", "SetActorHiddenInGame", "SetActorEnableCollision",
        },
    },
    surface_fields = {
        room = {
            { name = "RoomType", mode = "shape_type" },
            { name = "RoomEnemySpawners", mode = "count_sample" },
            { name = "TreasureSpawners", mode = "count_sample" },
            { name = "ResourceVolumeSpawners", mode = "count_sample" },
            { name = "DoorsTransform", mode = "count" },
            { name = "ObstaclesTransform", mode = "count" },
            { name = "DestructibleWallsTransform", mode = "count" },
            { name = "LeverDoorsTransform", mode = "count" },
            { name = "ExitFromDungeonDoorTransform", mode = "count" },
            { name = "CurtainVolumesTransform", mode = "count" },
            { name = "bIsPrefab", mode = "value" },
            { name = "HeightUnit", mode = "value" },
            { name = "CellPositions", mode = "count" },
            { name = "FloorElements", mode = "count" },
            { name = "FloorElementIndexes", mode = "count" },
            { name = "CellUnits", mode = "count" },
            { name = "RoomLights", mode = "count_sample" },
            { name = "WallPositions", mode = "count" },
            { name = "WideDoorPositions", mode = "count" },
            { name = "AnyDoorPositions", mode = "count" },
            { name = "TorchPositions", mode = "count" },
            { name = "InternalColumnPositions", mode = "count" },
            { name = "BorderColumnPositions", mode = "count" },
        },
        hallway = {
            { name = "EnemySpawners", mode = "count_sample" },
            { name = "ResourceVolumeSpawners", mode = "count_sample" },
        },
    },
    instance_component_fields = {
        room = {
            { name = "WallISM", role = "wall_bp" },
            { name = "WallISMComponent", role = "wall_native" },
            { name = "WallDoorISM", role = "wall_door_bp" },
            { name = "WallDoorISMComponent", role = "wall_door_native" },
            { name = "WideDoorISM", role = "wide_door_bp" },
            { name = "WideDoorISMComponent", role = "wide_door_native" },
            { name = "FloorISM", role = "floor_bp" },
            { name = "FloorISMComponent", role = "floor_native" },
        },
        hallway = {},
    },
    room_snapshot_fields = {
        { name = "CellPositions", mode = "count" },
        { name = "FloorElements", mode = "count" },
        { name = "FloorElementIndexes", mode = "count" },
        { name = "CellUnits", mode = "count" },
        { name = "WallPositions", mode = "count" },
        { name = "WideDoorPositions", mode = "count" },
        { name = "AnyDoorPositions", mode = "count" },
        { name = "TorchPositions", mode = "count" },
        { name = "InternalColumnPositions", mode = "count" },
        { name = "BorderColumnPositions", mode = "count" },
        { name = "RoomLights", mode = "count_sample" },
    },
    entry_surface_keywords = {
        "generate", "generation", "spawn", "room", "hall", "dungeon", "chain", "process",
        "execute", "start", "begin", "init", "build", "create", "prepare", "place", "finish",
        "complete", "state", "tick", "receive", "rep", "load", "context", "data",
    },
}

local MODEL_CONTEXTONE_FIELDS = {
    doors = { field = "DungeonDoors", mode = "count" },
    teleport = { field = "DungeonTeleport", mode = "object", disabled_reason = "object field read crashed after about_to_read_DungeonTeleport on a bootstrapped model" },
    walls = { field = "DestructableWalls", mode = "count" },
    replicated_rooms = { field = "ReplicatedRooms", mode = "count" },
    replicated_hallways = { field = "ReplicatedHallways", mode = "count" },
    rooms = { field = "Rooms", mode = "count" },
    hallways = { field = "Hallways", mode = "count" },
    seed = { field = "Seed", mode = "object", disabled_reason = "TScriptInterface/object context reads are unsafe through UE4SS Lua" },
    player_dungeon_spawn = { field = "PlayerDungeonSpawnPointComp", mode = "object", disabled_reason = "object context reads are unsafe through UE4SS Lua" },
    player_sandbox_spawn = { field = "PlayerSandboxSpawnPointComp", mode = "object", disabled_reason = "object context reads are unsafe through UE4SS Lua" },
    players = { field = "Players", mode = "count" },
    lever = { field = "DungeonLever", mode = "object", disabled_reason = "object context reads are unsafe through UE4SS Lua" },
    curtain = { field = "DungeonCurtainVolume", mode = "object", disabled_reason = "object context reads are unsafe through UE4SS Lua" },
    center = { field = "DungeonCenterLocation", mode = "vec" },
    levels = { field = "NumberOfLevels", mode = "value" },
    level_height = { field = "LevelHeight", mode = "value" },
}

local MODEL_CONTEXTONE_ORDER = {
    "doors", "teleport", "walls", "replicated_rooms", "replicated_hallways", "rooms", "hallways",
    "seed", "player_dungeon_spawn", "player_sandbox_spawn", "players", "lever", "curtain",
    "center", "levels", "level_height",
}

local MODEL_CALLSCAN_CONTEXT_ORDER = {
    "rooms", "hallways", "replicated_rooms", "replicated_hallways", "doors", "walls", "levels", "level_height",
}

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse_limit(args_str)
    local token = trim(args_str):match("^(%S+)")
    local limit = tonumber(token) or DEFAULT_SAMPLE_LIMIT
    limit = math.floor(limit)
    if limit < 1 then limit = 1 end
    if limit > MAX_SAMPLE_LIMIT then limit = MAX_SAMPLE_LIMIT end
    return limit
end

local function first_error_line(value)
    local text = tostring(value or "")
    return text:match("([^\r\n]+)") or text
end

local function is_valid(obj)
    if type(obj) ~= "userdata" then return false end
    local valid_ok, valid_value = pcall(function() return obj:IsValid() end)
    if valid_ok then return valid_value == true end
    return safety.is_uobject(obj)
end

local function safe_full_name(obj)
    if type(obj) ~= "userdata" then return "" end
    local full_ok, full_name = pcall(function() return obj:GetFullName() end)
    if full_ok and type(full_name) == "string" and full_name ~= "" then return full_name end
    local name_ok, short_name = pcall(function() return obj:GetName() end)
    if name_ok and type(short_name) == "string" then return short_name end
    return ""
end

local function safe_name(obj)
    if type(obj) ~= "userdata" then return "" end
    local name_ok, short_name = pcall(function() return obj:GetName() end)
    if name_ok and type(short_name) == "string" and short_name ~= "" then return short_name end
    local full_name = safe_full_name(obj)
    return full_name:match("([^%.%s]+)$") or full_name
end

local function name_from_full_name(full_name)
    local text = tostring(full_name or "")
    return text:match("%.([^%.%s]+)$") or text:match(":([^:%s]+)$") or text:match("([^%s]+)$") or text
end

local function object_key(obj)
    local full_name = safe_full_name(obj)
    if full_name ~= "" then return full_name end
    return tostring(obj)
end

local function is_default_object(obj)
    return safe_full_name(obj):find("Default__", 1, true) ~= nil
end

local function vec_text(loc)
    if not loc then return "" end
    local x_value, y_value, z_value = 0, 0, 0
    pcall(function() x_value = tonumber(loc.X) or 0 end)
    pcall(function() y_value = tonumber(loc.Y) or 0 end)
    pcall(function() z_value = tonumber(loc.Z) or 0 end)
    return string.format("%.1f,%.1f,%.1f", x_value, y_value, z_value)
end

local function intvec_text(loc)
    if not loc then return "" end
    local x_value, y_value, z_value = 0, 0, 0
    pcall(function() x_value = math.floor(tonumber(loc.X) or 0) end)
    pcall(function() y_value = math.floor(tonumber(loc.Y) or 0) end)
    pcall(function() z_value = math.floor(tonumber(loc.Z) or 0) end)
    return string.format("%d,%d,%d", x_value, y_value, z_value)
end

local function object_location_text(obj)
    local loc = nil
    pcall(function() loc = feature_actor.actor_location(obj) end)
    if not loc then return "" end
    return vec_text(loc)
end

local function unwrap(value)
    local unwrap_ok, unwrapped = pcall(player_core.unwrap_param, value)
    if unwrap_ok then return unwrapped end
    return value
end

local function fname_to_string(value)
    value = unwrap(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    if type(value) ~= "userdata" then return tostring(value) end
    for _method_index, method_name in ipairs({ "ToString", "GetName", "GetPlainNameString" }) do
        local method_ok, method_value = pcall(function() return value[method_name] end)
        if method_ok and type(method_value) == "function" then
            local call_ok, text_value = pcall(function() return method_value(value) end)
            if call_ok and type(text_value) == "string" and text_value ~= "" then return text_value end
        end
    end
    return nil
end

local function soft_path_of_safe(value)
    value = unwrap(value)
    if value == nil then return nil end
    local object_id_ok, object_id = pcall(function() return value:GetObjectID() end)
    if not object_id_ok or object_id == nil then return nil end
    local asset_name_ok, asset_name = pcall(function() return object_id:GetAssetPathName() end)
    if not asset_name_ok or asset_name == nil then return nil end
    local string_ok, asset_path = pcall(function() return asset_name:ToString() end)
    if not string_ok or type(asset_path) ~= "string" or asset_path == "" or asset_path == "None" then
        return nil
    end
    local sub_ok, sub_path = pcall(function() return object_id:GetSubPathString() end)
    if sub_ok and sub_path ~= nil then
        local sub_string_ok, sub_string = pcall(function() return sub_path:ToString() end)
        if sub_string_ok and type(sub_string) == "string" and sub_string ~= "" then
            return asset_path .. ":" .. sub_string
        end
    end
    return asset_path
end

local function value_label(value)
    value = unwrap(value)
    local value_type = type(value)
    if value == nil then return "<nil>" end
    if value_type == "boolean" or value_type == "number" then return tostring(value) end
    if value_type == "string" then return value end
    if value_type == "userdata" then
        local soft_path = soft_path_of_safe(value)
        if soft_path then return soft_path end
        if safety.is_uobject(value) then
            local class_name = safety.class_name_of(value) or "UObject"
            local name = safe_name(value)
            if name ~= "" then return class_name .. " '" .. name .. "'" end
            return class_name
        end
        return safety.describe(value)
    end
    return tostring(value)
end

local function container_count(value)
    value = unwrap(value)
    if value == nil then return nil end
    if type(value) == "table" then
        local count = 0
        for _table_key, _entry in pairs(value) do count = count + 1 end
        return count
    end
    local len_ok, len_value = pcall(function() return #value end)
    if len_ok and type(len_value) == "number" then return len_value end
    local num_ok, num_value = pcall(function() return value:Num() end)
    if num_ok and type(num_value) == "number" then return num_value end
    local array_num_ok, array_num_value = pcall(function() return value:GetArrayNum() end)
    if array_num_ok and type(array_num_value) == "number" then return array_num_value end
    local foreach_count = 0
    local foreach_ok = pcall(function()
        value:ForEach(function(_key, _entry)
            foreach_count = foreach_count + 1
        end)
    end)
    if foreach_ok then return foreach_count end
    return nil
end

local function container_item(value, index)
    value = unwrap(value)
    local index_ok, indexed = pcall(function() return value[index] end)
    if index_ok and indexed ~= nil then return unwrap(indexed) end
    local get_zero_ok, got_zero = pcall(function() return value:Get(index - 1) end)
    if get_zero_ok and got_zero ~= nil then return unwrap(got_zero) end
    local get_one_ok, got_one = pcall(function() return value:Get(index) end)
    if get_one_ok and got_one ~= nil then return unwrap(got_one) end
    return nil
end

local function container_sample_labels(value, sample_limit)
    local labels = {}
    local count = container_count(value)
    if count and count > 0 then
        local max_sample = math.min(count, sample_limit)
        for index = 1, max_sample do
            local item = container_item(value, index)
            if item ~= nil then labels[#labels + 1] = value_label(item) end
        end
        return labels
    end
    pcall(function()
        value:ForEach(function(_key, entry)
            if #labels < sample_limit then labels[#labels + 1] = value_label(entry) end
        end)
    end)
    return labels
end

local function count_text(value)
    local count = container_count(value)
    if count ~= nil then return tostring(count) end
    return value_label(value)
end

local function count_sample_text(value)
    local count = container_count(value)
    local labels = container_sample_labels(value, FIELD_SAMPLE_LIMIT)
    if count == nil then
        if #labels > 0 then return "sample=[" .. table.concat(labels, ", ") .. "]" end
        return value_label(value)
    end
    if #labels == 0 then return "count=" .. tostring(count) end
    return "count=" .. tostring(count) .. " sample=[" .. table.concat(labels, ", ") .. "]"
end

local read_field
local find_objects

local function context_value_text(value, mode)
    if mode == "count" then return count_text(value) end
    if mode == "vec" then return vec_text(value) end
    return value_label(value)
end

function read_field(obj, field_name)
    local read_ok, value = pcall(function() return obj[field_name] end)
    if not read_ok then return false, value end
    return true, unwrap(value)
end

local function generated_counts_snapshot()
    local snapshot = {}
    for _spec_index, spec in ipairs(GENERATED_OBJECT_SPECS) do
        local bucket = find_objects(spec.queries)
        snapshot[spec.key] = {
            live = #bucket.live,
            defaults = #bucket.defaults,
            errors = bucket.errors,
        }
    end
    return snapshot
end

local function generated_delta_parts(before_counts, after_counts)
    local parts = {}
    for _spec_index, spec in ipairs(GENERATED_OBJECT_SPECS) do
        local before_entry = before_counts[spec.key] or { live = 0 }
        local after_entry = after_counts[spec.key] or { live = 0 }
        if before_entry.live ~= after_entry.live then
            parts[#parts + 1] = string.format("%s=%d->%d", spec.key, before_entry.live or 0, after_entry.live or 0)
        end
    end
    return parts
end

local function model_context_snapshot(model)
    local snapshot = { ok = false, error = "", fields = {} }
    local context_ok, context = read_field(model, "DungeonContext")
    if not context_ok then
        snapshot.error = first_error_line(context)
        return snapshot
    end
    snapshot.ok = true
    for _index, field_key in ipairs(MODEL_CALLSCAN_CONTEXT_ORDER) do
        local field_spec = MODEL_CONTEXTONE_FIELDS[field_key]
        local entry = { ok = false, value = "", value_type = "", error = "" }
        local read_ok, value = read_field(context, field_spec.field)
        entry.ok = read_ok == true
        if read_ok then
            value = unwrap(value)
            entry.value_type = type(value)
            entry.value = context_value_text(value, field_spec.mode)
        else
            entry.error = first_error_line(value)
        end
        snapshot.fields[field_key] = entry
    end
    return snapshot
end

local function context_snapshot_parts(snapshot)
    if not snapshot or not snapshot.ok then return { "context=<read failed>" } end
    local parts = {}
    for _index, field_key in ipairs(MODEL_CALLSCAN_CONTEXT_ORDER) do
        local entry = snapshot.fields[field_key]
        if entry and entry.ok then
            parts[#parts + 1] = field_key .. "=" .. tostring(entry.value)
        else
            parts[#parts + 1] = field_key .. "=<read failed>"
        end
    end
    return parts
end

local function struct_count_part(context, field_name, label)
    local read_ok, value = read_field(context, field_name)
    if not read_ok then return label .. "=<read failed>" end
    local count = container_count(value)
    if count ~= nil then return label .. "=" .. tostring(count) end
    return label .. "=" .. value_label(value)
end

local function struct_value_part(context, field_name, label)
    local read_ok, value = read_field(context, field_name)
    if not read_ok then return label .. "=<read failed>" end
    return label .. "=" .. value_label(value)
end

local function dungeon_context_text(context)
    if context == nil then return "<nil>" end
    local parts = {
        struct_count_part(context, "DungeonDoors", "doors"),
        struct_count_part(context, "DestructableWalls", "walls"),
        struct_count_part(context, "ReplicatedRooms", "rooms"),
        struct_count_part(context, "ReplicatedHallways", "hallways"),
        struct_count_part(context, "Players", "players"),
        struct_value_part(context, "DungeonTeleport", "teleport"),
        struct_value_part(context, "DungeonLever", "lever"),
        struct_value_part(context, "DungeonCurtainVolume", "curtain"),
        struct_value_part(context, "NumberOfLevels", "levels"),
        struct_value_part(context, "LevelHeight", "level_height"),
    }
    local center_ok, center_value = read_field(context, "DungeonCenterLocation")
    if center_ok then parts[#parts + 1] = "center=" .. vec_text(center_value) end
    return table.concat(parts, " ")
end

local function field_value_text(obj, field_spec)
    local read_ok, value = read_field(obj, field_spec.name)
    if not read_ok then return "<read failed: " .. first_error_line(value) .. ">" end
    if field_spec.mode == "count" then return count_text(value) end
    if field_spec.mode == "count_sample" then return count_sample_text(value) end
    if field_spec.mode == "soft" then return soft_path_of_safe(value) or value_label(value) end
    if field_spec.mode == "vec" then return vec_text(value) end
    if field_spec.mode == "context" then return dungeon_context_text(value) end
    return value_label(value)
end

local function collect_entry(entry, bucket, seen)
    entry = unwrap(entry)
    if not is_valid(entry) then return end
    local key = object_key(entry)
    if seen[key] then return end
    seen[key] = true
    if is_default_object(entry) then
        bucket.defaults[#bucket.defaults + 1] = entry
    else
        bucket.live[#bucket.live + 1] = entry
    end
end

local function collect_from_plain_table(list, bucket, seen)
    for _table_key, entry in pairs(list) do
        collect_entry(entry, bucket, seen)
    end
end

local function collect_from_array_like(list, bucket, seen)
    local count = container_count(list) or 0
    for index = 1, count do
        collect_entry(container_item(list, index), bucket, seen)
    end
end

local function sort_objects(objects)
    table.sort(objects, function(left, right)
        return safe_full_name(left) < safe_full_name(right)
    end)
end

function find_objects(queries)
    local bucket = { live = {}, defaults = {}, errors = {} }
    local seen = {}
    if not FindAllOf then
        bucket.errors[#bucket.errors + 1] = "FindAllOf unavailable"
        return bucket
    end
    for _query_index, class_name in ipairs(queries) do
        local find_ok, list_or_error = pcall(FindAllOf, class_name)
        if not find_ok then
            bucket.errors[#bucket.errors + 1] = tostring(class_name) .. ": " .. tostring(list_or_error)
        elseif list_or_error ~= nil then
            if type(list_or_error) == "table" then
                collect_from_plain_table(list_or_error, bucket, seen)
            else
                collect_from_array_like(list_or_error, bucket, seen)
            end
        end
    end
    sort_objects(bucket.live)
    sort_objects(bucket.defaults)
    return bucket
end

local function json_escape(value)
    local text = tostring(value or "")
    text = text:gsub("\\", "\\\\"):gsub('"', '\\"')
    text = text:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    text = text:gsub("[%z\1-\8\11\12\14-\31]", "")
    return text
end

local function is_array_table(value)
    local max_index = 0
    local item_count = 0
    for key, _entry in pairs(value) do
        if type(key) ~= "number" then return false end
        if key > max_index then max_index = key end
        item_count = item_count + 1
    end
    return max_index == item_count
end

local function json_value(value)
    local value_type = type(value)
    if value == nil then return "null" end
    if value_type == "boolean" then return value and "true" or "false" end
    if value_type == "number" then return tostring(value) end
    if value_type == "string" then return '"' .. json_escape(value) .. '"' end
    if value_type ~= "table" then return '"' .. json_escape(tostring(value)) .. '"' end

    local parts = {}
    if is_array_table(value) then
        parts[#parts + 1] = "["
        for index = 1, #value do
            if index > 1 then parts[#parts + 1] = "," end
            parts[#parts + 1] = json_value(value[index])
        end
        parts[#parts + 1] = "]"
    else
        local keys = {}
        for key, _entry in pairs(value) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        parts[#parts + 1] = "{"
        for index = 1, #keys do
            if index > 1 then parts[#parts + 1] = "," end
            local key = keys[index]
            parts[#parts + 1] = '"' .. json_escape(key) .. '":' .. json_value(value[key])
        end
        parts[#parts + 1] = "}"
    end
    return table.concat(parts)
end

local function static_find(path)
    if not StaticFindObject then return nil, "StaticFindObject unavailable" end
    local find_ok, object_or_error = pcall(StaticFindObject, path)
    if not find_ok then return nil, tostring(object_or_error) end
    if object_or_error == nil or not is_valid(object_or_error) then return nil, "not found" end
    return object_or_error, nil
end

local function resolve_asset_registry()
    if not StaticFindObject then return nil, "StaticFindObject unavailable" end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not is_valid(helpers) then return nil, "UAssetRegistryHelpers CDO not found" end
    local method_ok, get_registry = pcall(function() return helpers["GetAssetRegistry"] end)
    if not method_ok or get_registry == nil then return nil, "GetAssetRegistry missing" end
    local ok, registry = pcall(function() return get_registry(helpers) end)
    if not ok or not is_valid(registry) then return nil, "GetAssetRegistry failed: " .. tostring(registry) end
    return registry, nil
end

local function generator_asset_base(generator_path)
    local leaf = tostring(generator_path or ""):match("([^/%.:]+)$") or tostring(generator_path or "")
    leaf = leaf:gsub("^Default__", "")
    leaf = leaf:gsub("_C$", "")
    return leaf
end

local function generator_target_names(generator_path)
    local base = generator_asset_base(generator_path)
    local names = {}
    if base ~= "" then
        names[base:lower()] = true
        names[(base .. "_C"):lower()] = true
    end
    return base, names
end

local function class_path_from_asset(package_name, asset_name, target_base)
    if not package_name or package_name == "" or not asset_name or asset_name == "" then return "" end
    local base = target_base or asset_name:gsub("_C$", "")
    if asset_name:lower() == (base .. "_C"):lower() then
        return package_name .. "." .. asset_name
    end
    return package_name .. "." .. asset_name .. "_C"
end

local function asset_record(entry, source, target_base)
    local rec = { source = source or "", package_name = "", package_path = "", asset_name = "", asset_class = "", object_path = "", class_path = "" }
    pcall(function() rec.package_name = fname_to_string(entry.PackageName) or "" end)
    pcall(function() rec.package_path = fname_to_string(entry.PackagePath) or "" end)
    pcall(function() rec.asset_name = fname_to_string(entry.AssetName) or "" end)
    pcall(function() rec.asset_class = fname_to_string(entry.AssetClass) or "" end)
    pcall(function()
        local class_name = fname_to_string(entry.AssetClassPath.AssetName)
        if class_name and class_name ~= "" then rec.asset_class = class_name end
    end)
    if rec.package_name ~= "" and rec.asset_name ~= "" then
        rec.object_path = rec.package_name .. "." .. rec.asset_name
        rec.class_path = class_path_from_asset(rec.package_name, rec.asset_name, target_base)
    end
    return rec
end

local function add_asset_candidate(candidates, seen, entry, source, target_base, target_names)
    entry = unwrap(entry)
    if entry == nil then return end
    local rec = asset_record(entry, source, target_base)
    local name_key = rec.asset_name:lower()
    if not target_names[name_key] then return end
    if rec.class_path == "" or seen[rec.class_path] then return end
    seen[rec.class_path] = true
    candidates[#candidates + 1] = rec
end

local function known_asset_record(class_path, target_base)
    local package_name, asset_name = class_path:match("^(.-)%.([^%.]+)$")
    if not package_name or not asset_name then return nil end
    local asset_base = asset_name:gsub("_C$", "")
    if target_base and target_base ~= "" and asset_base:lower() ~= target_base:lower() then return nil end
    return {
        source = "known",
        package_name = package_name,
        package_path = package_name:match("^(.*)/[^/]+$") or "",
        asset_name = asset_base,
        asset_class = "Blueprint",
        object_path = package_name .. "." .. asset_base,
        class_path = class_path,
    }
end

local function add_known_generator_candidates(candidates, seen, target_base)
    for _index, class_path in ipairs(KNOWN_GENERATOR_CLASS_PATHS) do
        local rec = known_asset_record(class_path, target_base)
        if rec and rec.class_path ~= "" and not seen[rec.class_path] then
            seen[rec.class_path] = true
            candidates[#candidates + 1] = rec
        end
    end
end

local function scan_assets_by_class(registry, candidates, seen, target_base, target_names, errors)
    if not FName then
        errors[#errors + 1] = "FName unavailable for GetAssetsByClass"
        return
    end
    local out = {}
    local method_ok, get_assets_by_class = pcall(function() return registry["GetAssetsByClass"] end)
    if not method_ok or get_assets_by_class == nil then
        errors[#errors + 1] = "GetAssetsByClass missing"
        return
    end
    local ok, err = pcall(function()
        get_assets_by_class(registry, { PackageName = FName("/Script/Dungeon"), AssetName = FName("DungeonModel") }, out, true)
    end)
    if not ok then
        errors[#errors + 1] = "GetAssetsByClass DungeonModel failed: " .. tostring(err)
        return
    end
    local count = container_count(out) or 0
    for index = 1, count do
        add_asset_candidate(candidates, seen, container_item(out, index), "class:DungeonModel", target_base, target_names)
    end
end

local function scan_assets_by_path(registry, candidates, seen, target_base, target_names, errors)
    if not FName then
        errors[#errors + 1] = "FName unavailable for GetAssetsByPath"
        return
    end
    local out = {}
    local method_ok, get_assets_by_path = pcall(function() return registry["GetAssetsByPath"] end)
    if not method_ok or get_assets_by_path == nil then
        errors[#errors + 1] = "GetAssetsByPath missing"
        return
    end
    local ok, err = pcall(function()
        get_assets_by_path(registry, FName(ASSET_SEARCH_ROOT), out, true, true)
    end)
    if not ok then
        errors[#errors + 1] = "GetAssetsByPath " .. ASSET_SEARCH_ROOT .. " failed: " .. tostring(err)
        return
    end
    local count = container_count(out) or 0
    for index = 1, count do
        add_asset_candidate(candidates, seen, container_item(out, index), "path:" .. ASSET_SEARCH_ROOT, target_base, target_names)
        if #candidates >= MAX_ASSET_CANDIDATES then return end
    end
end

local function find_generator_asset_candidates(generator_path, include_slow_scan)
    local candidates, errors, seen = {}, {}, {}
    local target_base, target_names = generator_target_names(generator_path)
    if target_base == "" then return candidates, { "empty generator asset name" } end
    add_known_generator_candidates(candidates, seen, target_base)
    if not include_slow_scan then return candidates, errors end
    local registry, registry_error = resolve_asset_registry()
    if not registry then return candidates, { registry_error } end
    scan_assets_by_class(registry, candidates, seen, target_base, target_names, errors)
    if #candidates < MAX_ASSET_CANDIDATES then
        scan_assets_by_path(registry, candidates, seen, target_base, target_names, errors)
    end
    return candidates, errors
end

local function try_load_class_path(class_path, allow_kismet)
    local normalized = player_core.normalize_uclass_path(class_path)
    if normalized == "" then return nil, "empty class path", normalized end
    if normalized:sub(1, 1) ~= "/" then
        return nil, "soft-class load needs a fully qualified /Game or /Script path", normalized
    end

    local attempts = {}
    local function looks_like_class(obj)
        if not is_valid(obj) then return false end
        local full_name = safe_full_name(obj)
        if full_name:find("^BlueprintGeneratedClass%s") or full_name:find("^Class%s") then return true end
        local class_name = safety.class_name_of(obj) or ""
        return class_name == "BlueprintGeneratedClass" or class_name == "Class"
    end
    local function note(route, value)
        attempts[#attempts + 1] = route .. "=" .. tostring(value)
    end
    local function try_direct(route, loader, path)
        if not loader or not path or path == "" then return nil end
        local ok, result = pcall(loader, path)
        if ok and looks_like_class(result) then return result, route, path end
        if ok and is_valid(result) then note(route, "non-class " .. safe_full_name(result)) end
        if not ok then note(route, first_error_line(result)) end
        return nil
    end
    local function try_static(path)
        if not StaticFindObject or not path or path == "" then return nil end
        for _index, candidate_path in ipairs({ path, "BlueprintGeneratedClass " .. path, "Class " .. path }) do
            local ok, result = pcall(StaticFindObject, candidate_path)
            if ok and looks_like_class(result) then return result, "StaticFindObject", candidate_path end
        end
        return nil
    end

    local package_path, asset_name = normalized:match("^(.-)%.([^%.]+)$")
    local object_path = nil
    if package_path and asset_name and asset_name:sub(-2) == "_C" then
        object_path = package_path .. "." .. asset_name:gsub("_C$", "")
    end
    local load_object = rawget(_G, "LoadObject")
    local load_asset = rawget(_G, "LoadAsset")

    local found, route, resolved = try_static(normalized)
    if found then return found, route, resolved end
    found, route, resolved = try_direct("LoadObject(class)", load_object, normalized)
    if found then return found, route, resolved end
    found, route, resolved = try_direct("LoadAsset(class)", load_asset, normalized)
    if found then return found, route, resolved end
    found, route, resolved = try_direct("LoadObject(asset)", load_object, object_path)
    if found then return found, route, resolved end
    found, route, resolved = try_direct("LoadAsset(asset)", load_asset, object_path)
    if found then return found, route, resolved end
    found, route, resolved = try_direct("LoadAsset(package)", load_asset, package_path)
    if found then return found, route, resolved end
    found, route, resolved = try_static(normalized)
    if found then return found, route, resolved end

    if FindAllOf then
        local short_name = normalized:match("([^%.%/]+)$") or normalized
        for _index, container_class in ipairs({ "BlueprintGeneratedClass", "Class" }) do
            local ok_all, candidates = pcall(FindAllOf, container_class)
            if ok_all and type(candidates) == "table" then
                for _candidate_index, candidate in ipairs(candidates) do
                    if looks_like_class(candidate) and safe_name(candidate) == short_name then
                        return candidate, "FindAllOf(" .. container_class .. ")", normalized
                    end
                end
            elseif not ok_all then
                note("FindAllOf(" .. container_class .. ")", first_error_line(candidates))
            end
        end
    end

    local package_path = normalized:match("^(.-)%.[^%.]+$")
    if not allow_kismet then
        local detail = "asset loaders did not find generated class"
        if #attempts > 0 then detail = detail .. "; " .. table.concat(attempts, " | ") end
        return nil, detail, normalized
    end

    local loaded_class, route_or_error, resolved_path = player_core.resolve_uclass_via_kismet_softclass(normalized)
    if loaded_class and is_valid(loaded_class) then return loaded_class, route_or_error, resolved_path or normalized end
    return nil, tostring(route_or_error), resolved_path or normalized
end

local function class_default_object(class_obj)
    if not is_valid(class_obj) then return nil, "class invalid" end
    local cdo_ok, cdo_or_error = pcall(function() return class_obj:GetCDO() end)
    if not cdo_ok then return nil, tostring(cdo_or_error) end
    if not is_valid(cdo_or_error) then return nil, "GetCDO returned invalid" end
    return cdo_or_error, nil
end

local function write_report_files(file_stem, report, lines)
    local ipc_dir = mod_paths.ipc_dir()
    if not ipc_dir then return false, "ipc dir unavailable" end
    pcall(os.execute, ('if not exist "%s" mkdir "%s"'):format(ipc_dir, ipc_dir))

    local json_path = ipc_dir .. "\\" .. file_stem .. ".json"
    local text_path = ipc_dir .. "\\" .. file_stem .. ".txt"
    local json_ok, json_result = mod_paths.write_atomic(json_path, json_value(report))
    local text_ok, text_result = mod_paths.write_atomic(text_path, table.concat(lines, "\n") .. "\n")
    if json_ok and text_ok then return true, json_result .. " ; " .. text_result end
    return false, tostring(json_result) .. " ; " .. tostring(text_result)
end

local function append_field_lines(entry, lines, obj, field_specs, indent)
    for _field_index, field_spec in ipairs(field_specs or {}) do
        local text_value = field_value_text(obj, field_spec)
        entry.fields[field_spec.name] = text_value
        lines[#lines + 1] = string.format("%s%s=%s", indent, field_spec.name, text_value)
    end
end

local function append_object_sample(report_entry, lines, obj, field_specs)
    local sample = {
        name = safe_name(obj),
        class = safety.class_name_of(obj) or "",
        full_name = safe_full_name(obj),
        location = object_location_text(obj),
        fields = {},
    }
    report_entry.samples[#report_entry.samples + 1] = sample

    local header = string.format("    - %s [%s]", sample.name ~= "" and sample.name or "<unnamed>", sample.class)
    if sample.location ~= "" then header = header .. " loc=" .. sample.location end
    lines[#lines + 1] = header
    append_field_lines(sample, lines, obj, field_specs, "        ")
end

local function append_class_report(report, lines, spec, sample_limit)
    local bucket = find_objects(spec.queries)
    local entry = {
        class = spec.key,
        queries = spec.queries,
        live_count = #bucket.live,
        default_count = #bucket.defaults,
        errors = bucket.errors,
        samples = {},
    }
    report.classes[#report.classes + 1] = entry
    lines[#lines + 1] = string.format("  %s: live=%d default=%d", spec.key, #bucket.live, #bucket.defaults)
    for error_index = 1, #bucket.errors do
        lines[#lines + 1] = "    error: " .. tostring(bucket.errors[error_index])
    end
    local max_sample = math.min(#bucket.live, sample_limit)
    for index = 1, max_sample do
        append_object_sample(entry, lines, bucket.live[index], spec.fields)
    end
end

local function settings_report(lines)
    local settings_obj, find_error = static_find(SETTINGS_PATH)
    local entry = {
        path = SETTINGS_PATH,
        found = settings_obj ~= nil,
        error = find_error or "",
        name = settings_obj and safe_name(settings_obj) or "",
        class = settings_obj and (safety.class_name_of(settings_obj) or "") or "",
        fields = {},
        generator_path = "",
    }
    if not settings_obj then
        lines[#lines + 1] = "  MapGenerationSettings: missing (" .. tostring(find_error) .. ")"
        return entry, nil
    end
    lines[#lines + 1] = "  MapGenerationSettings: found class=" .. entry.class
    append_field_lines(entry, lines, settings_obj, SETTINGS_FIELDS, "      ")
    entry.generator_path = entry.fields.DungeonGeneratorV2 or ""
    return entry, settings_obj
end

local function append_cdo_report(entry, lines, class_obj)
    local cdo_obj, cdo_error = class_default_object(class_obj)
    entry.cdo_found = cdo_obj ~= nil
    entry.cdo_error = cdo_error or ""
    entry.cdo_name = cdo_obj and safe_name(cdo_obj) or ""
    entry.cdo_full_name = cdo_obj and safe_full_name(cdo_obj) or ""
    entry.cdo_fields = {}
    if not cdo_obj then
        lines[#lines + 1] = "      CDO: missing (" .. tostring(cdo_error) .. ")"
        return
    end
    lines[#lines + 1] = "      CDO: " .. entry.cdo_name
    local field_entry = { fields = entry.cdo_fields }
    append_field_lines(field_entry, lines, cdo_obj, MODEL_CDO_FIELDS, "          ")
end

local function generator_class_report(lines, generator_path, load_mode, should_search_registry)
    local should_load = load_mode == "asset" or load_mode == "kismet"
    local normalized = ""
    if generator_path and generator_path ~= "" and generator_path ~= "<nil>" then
        normalized = player_core.normalize_uclass_path(generator_path)
    end
    local entry = {
        path = generator_path or "",
        normalized = normalized,
        load_path = normalized,
        load_requested = should_load,
        load_mode = load_mode or "none",
        static_found_before_load = false,
        loaded = false,
        route = "",
        error = "",
        asset_candidates = {},
        asset_errors = {},
        selected_candidate = {},
        class_name = "",
        class_full_name = "",
        cdo_fields = {},
    }
    lines[#lines + 1] = "  DungeonGeneratorV2 class:"
    lines[#lines + 1] = "      path=" .. tostring(entry.path)
    lines[#lines + 1] = "      normalized=" .. tostring(entry.normalized)

    if normalized == "" then
        entry.error = "no DungeonGeneratorV2 soft path"
        lines[#lines + 1] = "      error=" .. entry.error
        return entry
    end

    local class_obj, static_error = static_find(normalized)
    do
        local candidates, asset_errors = find_generator_asset_candidates(generator_path, should_search_registry == true)
        entry.asset_candidates = candidates
        entry.asset_errors = asset_errors
        lines[#lines + 1] = "      asset_candidates=" .. tostring(#candidates)
        for index = 1, math.min(#candidates, 5) do
            local candidate = candidates[index]
            lines[#lines + 1] = string.format("        [%d] %s asset=%s class=%s source=%s",
                index, candidate.package_name, candidate.asset_name, candidate.class_path, candidate.source)
        end
        for error_index = 1, #asset_errors do
            lines[#lines + 1] = "        asset error: " .. tostring(asset_errors[error_index])
        end
        if not class_obj and #candidates > 0 then
            entry.selected_candidate = candidates[1]
            entry.load_path = candidates[1].class_path
            local candidate_obj = static_find(entry.load_path)
            if candidate_obj then
                class_obj = candidate_obj
                entry.static_found_before_load = true
                entry.route = "AssetRegistry+StaticFindObject"
            end
        end
    end
    if class_obj then
        entry.static_found_before_load = true
        entry.loaded = true
        if entry.route == "" then entry.route = "StaticFindObject" end
    elseif load_mode == "asset" then
        entry.error = "load.asset disabled after live crash; use world.spawn then world.dungeon.proc.models, or explicit load.unsafe"
    elseif load_mode == "kismet" then
        local loaded_class, route_or_error, resolved_path = try_load_class_path(entry.load_path, load_mode == "kismet")
        entry.load_path = resolved_path or entry.load_path
        if loaded_class and is_valid(loaded_class) then
            class_obj = loaded_class
            entry.loaded = true
            entry.route = route_or_error or "LoadClassAsset_Blocking"
        else
            entry.error = tostring(route_or_error)
        end
    else
        entry.error = tostring(static_error or "not loaded")
    end

    lines[#lines + 1] = "      static_found_before_load=" .. tostring(entry.static_found_before_load)
    lines[#lines + 1] = "      loaded=" .. tostring(entry.loaded)
    if entry.load_path ~= "" and entry.load_path ~= entry.normalized then lines[#lines + 1] = "      load_path=" .. entry.load_path end
    if entry.route ~= "" then lines[#lines + 1] = "      route=" .. entry.route end
    if entry.error ~= "" then lines[#lines + 1] = "      error=" .. entry.error end

    if class_obj then
        entry.class_name = safe_name(class_obj)
        entry.class_full_name = safe_full_name(class_obj)
        lines[#lines + 1] = "      class=" .. entry.class_full_name
        append_cdo_report(entry, lines, class_obj)
    end
    return entry
end

local function build_probe_report(command, sample_limit, load_mode, should_search_registry)
    local report = {
        command = command,
        sample_limit = sample_limit,
        settings = {},
        generator_class = {},
        classes = {},
    }
    local lines = {
        "[RSDWTools] " .. command .. " --",
        "  procedural surface: /Script/Dungeon",
    }
    report.settings = settings_report(lines)
    report.generator_class = generator_class_report(lines, report.settings.generator_path, load_mode or "none", should_search_registry)
    for _spec_index, spec in ipairs(PROCEDURAL_CLASS_SPECS) do
        append_class_report(report, lines, spec, sample_limit)
    end
    return report, lines
end

local function append_model_summary(report, lines, index, obj)
    local entry = {
        index = index,
        name = safe_name(obj),
        class = safety.class_name_of(obj) or "",
        full_name = safe_full_name(obj),
        location = object_location_text(obj),
    }
    report.models[#report.models + 1] = entry
    lines[#lines + 1] = string.format("  [%d] %s [%s] loc=%s", entry.index, entry.name, entry.class, entry.location)
end

local function live_models()
    local bucket = find_objects({ "DungeonModel", "BP_DungeonModel_C" })
    return bucket.live, bucket.errors
end

local function append_teleport_summary(report, lines, index, obj)
    local entry = {
        index = index,
        name = safe_name(obj),
        class = safety.class_name_of(obj) or "",
        full_name = safe_full_name(obj),
        location = object_location_text(obj),
    }
    report.teleports[#report.teleports + 1] = entry
    lines[#lines + 1] = string.format("  [%d] %s [%s] loc=%s", entry.index, entry.name, entry.class, entry.location)
    return entry
end

local function live_teleports()
    local bucket = find_objects({ "DungeonTeleport", "BP_DungeonTeleport_C" })
    return bucket.live, bucket.errors
end

local function live_spawn_managers()
    local bucket = find_objects({ "DungeonSpawnManager" })
    return bucket.live, bucket.errors
end

local function live_generators()
    local bucket = find_objects({ "DungeonGenerator", "BP_DungeonGenerator_C" })
    return bucket.live, bucket.errors
end

local function model_index_error(count)
    if count <= 0 then
        return "no live DungeonModel actors; spawn one first: world.spawn " .. KNOWN_GENERATOR_CLASS_PATHS[1]
    end
    return string.format("index out of range 1..%d", count)
end

local function teleport_index_error(count)
    if count <= 0 then
        return "no live DungeonTeleport actors; spawn one first: world.spawn " .. KNOWN_TELEPORT_CLASS_PATH
    end
    return string.format("index out of range 1..%d", count)
end

local function generator_index_error(count)
    if count <= 0 then
        return "no live DungeonGenerator objects; construct one first: world.dungeon.proc.manager.constructwire 1 generator current confirm"
    end
    return string.format("index out of range 1..%d", count)
end

local function parse_model_teleport_confirm(args_str, usage)
    local teleport_token, model_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)")
    if not teleport_token or not model_token then return nil, nil, nil, usage end
    local teleport_index = tonumber(teleport_token)
    local model_index = tonumber(model_token)
    if not teleport_index then return nil, nil, nil, "teleport index must be a number" end
    if not model_index then return nil, nil, nil, "model index must be a number" end
    if confirm_token ~= "confirm" then return nil, nil, nil, usage .. " confirm" end
    return math.floor(teleport_index), math.floor(model_index), true, nil
end

local function parse_manager_model_confirm(args_str, usage)
    local manager_token, model_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)")
    if not manager_token or not model_token then return nil, nil, nil, usage end
    local manager_index = tonumber(manager_token)
    local model_index = tonumber(model_token)
    if not manager_index then return nil, nil, nil, "spawn manager index must be a number" end
    if not model_index then return nil, nil, nil, "model index must be a number" end
    if confirm_token ~= "confirm" then return nil, nil, nil, usage .. " confirm" end
    return math.floor(manager_index), math.floor(model_index), true, nil
end

local function resolve_model_and_teleport(teleport_index, model_index)
    local teleports, teleport_errors = live_teleports()
    if teleport_index < 1 or teleport_index > #teleports then
        return nil, nil, teleports, {}, teleport_errors, {}, teleport_index_error(#teleports)
    end
    local models, model_errors = live_models()
    if model_index < 1 or model_index > #models then
        return nil, nil, teleports, models, teleport_errors, model_errors, model_index_error(#models)
    end
    return teleports[teleport_index], models[model_index], teleports, models, teleport_errors, model_errors, nil
end

local function model_teleport_report(command, teleport_index, model_index, teleports, models, teleport_errors, model_errors, teleport, model)
    local report = {
        command = command,
        teleport_index = teleport_index,
        model_index = model_index,
        teleport_count = #teleports,
        model_count = #models,
        errors = { teleports = teleport_errors, models = model_errors },
        confirmed = true,
        teleport = {
            index = teleport_index,
            name = safe_name(teleport),
            class = safety.class_name_of(teleport) or "",
            full_name = safe_full_name(teleport),
            location = object_location_text(teleport),
        },
        model = {
            index = model_index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
        writes = {},
        result = "prepared",
    }
    local lines = {
        "[RSDWTools] " .. command .. " --",
        string.format("  live DungeonTeleport actors: %d", #teleports),
        string.format("  live DungeonModel actors: %d", #models),
        string.format("  teleport[%d] %s [%s] loc=%s", teleport_index, report.teleport.name, report.teleport.class, report.teleport.location),
        string.format("  model[%d] %s [%s] loc=%s", model_index, report.model.name, report.model.class, report.model.location),
    }
    for error_index = 1, #teleport_errors do lines[#lines + 1] = "  teleport error: " .. tostring(teleport_errors[error_index]) end
    for error_index = 1, #model_errors do lines[#lines + 1] = "  model error: " .. tostring(model_errors[error_index]) end
    return report, lines
end

local function runtime_dungeon_depth()
    local settings_obj = static_find(SETTINGS_PATH)
    if settings_obj then
        local read_ok, value = read_field(settings_obj, "DungeonDepth")
        if read_ok then
            local depth = tonumber(unwrap(value))
            if depth then return depth, "MapGenerationSettings.DungeonDepth" end
        end
    end
    return -12000.0, "fallback"
end

local _gameplay_statics_cdo = nil
local function get_gameplay_statics()
    if _gameplay_statics_cdo and _gameplay_statics_cdo.IsValid and _gameplay_statics_cdo:IsValid() then
        return _gameplay_statics_cdo
    end
    if not StaticFindObject then return nil end
    local ok, obj = pcall(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
    if ok and obj and obj.IsValid and obj:IsValid() then
        _gameplay_statics_cdo = obj
        return _gameplay_statics_cdo
    end
    return nil
end

local function get_world_for_spawn(pawn)
    if is_valid(pawn) and pawn.GetWorld then
        local ok, world = pcall(function() return pawn:GetWorld() end)
        if ok and is_valid(world) then return world, "pawn:GetWorld" end
    end
    local ok_req, ue = pcall(require, "UEHelpers")
    if ok_req and type(ue) == "table" and ue.GetWorld then
        local ok, world = pcall(function() return ue.GetWorld() end)
        if ok and is_valid(world) then return world, "UEHelpers.GetWorld" end
    end
    return nil, "unavailable"
end

local function rotator_to_quat(rot)
    rot = rot or {}
    local pitch = (tonumber(rot.Pitch or rot.X) or 0) * math.pi / 360.0
    local yaw   = (tonumber(rot.Yaw   or rot.Y) or 0) * math.pi / 360.0
    local roll  = (tonumber(rot.Roll  or rot.Z) or 0) * math.pi / 360.0

    local sp, cp = math.sin(pitch), math.cos(pitch)
    local sy, cy = math.sin(yaw),   math.cos(yaw)
    local sr, cr = math.sin(roll),  math.cos(roll)

    return {
        X = cr * sp * sy - sr * cp * cy,
        Y = -cr * sp * cy - sr * cp * sy,
        Z = cr * cp * sy - sr * sp * cy,
        W = cr * cp * cy + sr * sp * sy,
    }
end

local function spawn_xform_at_transform(loc, rot, scale)
    scale = scale or { X = 1, Y = 1, Z = 1 }
    return {
        Rotation = rotator_to_quat(rot),
        Translation = { X = tonumber(loc.X) or 0, Y = tonumber(loc.Y) or 0, Z = tonumber(loc.Z) or 0 },
        Scale3D = { X = tonumber(scale.X) or 1, Y = tonumber(scale.Y) or 1, Z = tonumber(scale.Z) or 1 },
    }
end

local function spawn_xform_at_location(loc)
    return spawn_xform_at_transform(loc, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 })
end

local function begin_generated_spawn_batch(label)
    generated_spawn_cache.next_batch = (generated_spawn_cache.next_batch or 0) + 1
    generated_spawn_cache.latest_batch = generated_spawn_cache.next_batch
    generated_spawn_cache.latest_label = tostring(label or "")
    return generated_spawn_cache.next_batch
end

local function remember_generated_spawn_actor(batch_id, actor, label, ref_key)
    if not is_valid(actor) then return nil end
    local entry = {
        batch = batch_id or 0,
        actor = actor,
        label = tostring(label or ""),
        ref = tostring(ref_key or ""),
        name = safe_name(actor),
        full_name = safe_full_name(actor),
        location = object_location_text(actor),
    }
    generated_spawn_cache.entries[#generated_spawn_cache.entries + 1] = entry
    return entry
end

local function destroy_generated_spawn_actor(actor)
    if not is_valid(actor) then return false, "invalid" end
    if actor.K2_DestroyActor then
        local ok, err = pcall(function() actor:K2_DestroyActor() end)
        if ok then return true, "K2_DestroyActor" end
        return false, err
    end
    if actor.DestroyActor then
        local ok, err = pcall(function() actor:DestroyActor() end)
        if ok then return true, "DestroyActor" end
        return false, err
    end
    return false, "no destroy method"
end

local function deferred_spawn_model_at(spawn_loc, pre_finish_fn)
    local uclass = player_core.resolve_uclass(KNOWN_GENERATOR_CLASS_PATHS[1])
    if not uclass then return nil, "could not resolve model class" end

    local feature_net = require("feature_net")
    local pc = feature_net.local_controller()
    if not pc then return nil, "no player controller" end

    local gpl = get_gameplay_statics()
    if not gpl then return nil, "GameplayStatics CDO not found" end

    local spawn_xform = spawn_xform_at_location(spawn_loc)
    local begin_deferred_spawn = gpl["BeginDeferredActorSpawnFromClass"]
    if not begin_deferred_spawn then return nil, "BeginDeferredActorSpawnFromClass missing" end

    local actor = nil
    local begin_ok, begin_error = pcall(function()
        actor = begin_deferred_spawn(gpl, pc, uclass, spawn_xform, 2, pc, 0)
    end)
    if not begin_ok then return nil, "BeginDeferredActorSpawnFromClass trapped: " .. tostring(begin_error) end
    if not is_valid(actor) then return nil, "BeginDeferredActorSpawnFromClass returned invalid model" end

    local spawned_actor = actor
    pcall(function() spawned_actor["bRegisterAsRuntimeSpawned"] = true end)
    if pre_finish_fn then
        local pre_ok, pre_error = pcall(function() pre_finish_fn(spawned_actor) end)
        if not pre_ok then return nil, "pre-finish writes failed: " .. tostring(pre_error) end
    end

    local finish_spawning_actor = gpl["FinishSpawningActor"]
    if not finish_spawning_actor then return nil, "FinishSpawningActor missing" end
    local finish_ok, finish_error = pcall(function()
        finish_spawning_actor(gpl, spawned_actor, spawn_xform, 0)
    end)
    if not finish_ok then return nil, "FinishSpawningActor trapped: " .. tostring(finish_error) end

    pcall(function()
        local feature_field = require("feature_field")
        feature_field.set_last_spawned(spawned_actor)
    end)
    return spawned_actor, "spawned"
end

local function write_actor_field(report, lines, obj, field_name, value, text_value)
    local ok, err = pcall(function() obj[field_name] = value end)
    report.writes[#report.writes + 1] = {
        field = field_name,
        ok = ok == true,
        value = text_value or value_label(value),
        error = ok and "" or tostring(err),
    }
    if ok then
        lines[#lines + 1] = string.format("      %s=%s", field_name, text_value or value_label(value))
    else
        lines[#lines + 1] = string.format("      %s=<write failed: %s>", field_name, first_error_line(err))
    end
    return ok
end

local function raw_value_text(value)
    local unwrap_ok, unwrapped = pcall(unwrap, value)
    if unwrap_ok then value = unwrapped end
    local value_type = type(value)
    if value == nil then return "<nil>" end
    if value_type == "boolean" or value_type == "number" or value_type == "string" then return tostring(value) end
    if value_type == "table" then
        if value.X ~= nil and value.Y ~= nil and value.Z ~= nil then return vec_text(value) end
        return tostring(value)
    end
    return tostring(value)
end

local function append_call_result(report, lines, call_name, call_fn, formatter)
    local entry = { name = call_name, ok = false, value_type = "", value = "", error = "" }
    local ok, value = pcall(call_fn)
    entry.ok = ok == true
    if ok then
        local unwrap_ok, unwrapped = pcall(unwrap, value)
        if unwrap_ok then value = unwrapped end
        entry.value_type = type(value)
        if formatter then
            local format_ok, formatted = pcall(formatter, value)
            entry.value = format_ok and tostring(formatted) or raw_value_text(value)
        else
            entry.value = raw_value_text(value)
        end
        lines[#lines + 1] = string.format("      %s ok type=%s value=%s", entry.name, entry.value_type, entry.value)
    else
        entry.error = first_error_line(value)
        lines[#lines + 1] = string.format("      %s failed: %s", entry.name, entry.error)
    end
    report.calls[#report.calls + 1] = entry
    return entry.ok
end

local function append_common_actor_call_checks(report, lines, obj)
    append_call_result(report, lines, "GetName", function() return obj:GetName() end)
    append_call_result(report, lines, "GetFullName", function() return obj:GetFullName() end)
    append_call_result(report, lines, "GetClass.GetName", function()
        local cls = obj:GetClass()
        if cls then return cls:GetName() end
        return nil
    end)
    append_call_result(report, lines, "K2_GetActorLocation", function() return obj:K2_GetActorLocation() end, vec_text)
    append_call_result(report, lines, "HasAuthority", function() return obj:HasAuthority() end)
    append_call_result(report, lines, "GetNetMode", function() return obj:GetNetMode() end)
end

local function write_callcheck_report(command, file_stem, object_label, objects, errors, index, obj, append_specific_calls)
    local report = {
        command = command,
        index = index,
        count = #objects,
        errors = errors,
        object = {
            index = index,
            label = object_label,
            name = safe_name(obj),
            class = safety.class_name_of(obj) or "",
            full_name = safe_full_name(obj),
            location = object_location_text(obj),
        },
        calls = {},
        note = "benign colon-call smoke test; does not call dungeon generation, interaction, delete, or OnRep methods",
    }
    local lines = {
        "[RSDWTools] " .. command .. " --",
        string.format("  live %s actors: %d", object_label, #objects),
        "  note: benign colon-call smoke test; no dungeon generation, interaction, delete, or OnRep calls",
        string.format("  [%d] %s [%s] loc=%s", index, report.object.name, report.object.class, report.object.location),
        "  calls:",
    }
    for error_index = 1, #errors do
        lines[#lines + 1] = "  error: " .. tostring(errors[error_index])
    end
    append_common_actor_call_checks(report, lines, obj)
    if append_specific_calls then append_specific_calls(report, lines, obj) end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local ok_count = 0
    for call_index = 1, #report.calls do
        if report.calls[call_index].ok then ok_count = ok_count + 1 end
    end
    local detail = string.format("index=%d object=%s calls_ok=%d/%d", index, report.object.name, ok_count, #report.calls)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

local function write_teleport_metadata_callcheck_report(teleports, errors, index, teleport)
    local full_name = safe_full_name(teleport)
    local report = {
        command = "world.dungeon.proc.teleport.callcheck",
        index = index,
        count = #teleports,
        errors = errors,
        object = {
            index = index,
            label = "DungeonTeleport",
            name = name_from_full_name(full_name),
            class = "",
            full_name = full_name,
            location = "",
        },
        calls = {},
        note = "metadata-only after live crash; use world.dungeon.proc.teleport.callone for one explicit native call at a time",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.teleport.callcheck --",
        string.format("  live DungeonTeleport actors: %d", #teleports),
        "  note: metadata-only after live crash; use world.dungeon.proc.teleport.callone for one explicit native call at a time",
        string.format("  [%d] %s loc=<not called>", index, report.object.name),
    }
    for error_index = 1, #errors do
        lines[#lines + 1] = "  error: " .. tostring(errors[error_index])
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_teleport_callcheck", report, lines)
    local detail = string.format("index=%d object=%s metadata_only=true", index, report.object.name)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

local function teleport_callone_spec(call_name)
    local key = tostring(call_name or ""):lower()
    if key == "fullname" then
        return "GetFullName", function(teleport) return teleport:GetFullName() end, nil
    elseif key == "location" then
        return "K2_GetActorLocation", function(teleport) return teleport:K2_GetActorLocation() end, vec_text
    elseif key == "authority" then
        return "HasAuthority", function(teleport) return teleport:HasAuthority() end, nil
    elseif key == "name" then
        return "GetName", function(teleport) return teleport:GetName() end, nil
    elseif key == "class" then
        return "GetClass.GetName", function(teleport)
            local cls = teleport:GetClass()
            if cls then return cls:GetName() end
            return nil
        end, nil
    elseif key == "netmode" then
        return "GetNetMode", function(teleport) return teleport:GetNetMode() end, nil
    elseif key == "displayname" then
        return "GetDisplayName", function(teleport) return teleport:GetDisplayName() end, nil
    end
    return nil, nil, nil
end

local function teleport_callone_options()
    return "fullname|location|authority|name|class|netmode|displayname"
end

local function teleport_callscan_options()
    return "notify_model(danger)|interact(danger)"
end

local function manual_spawnunit_options()
    return table.concat(MANUAL_SPAWN_UNIT_ORDER, "|")
end

local function manual_spawn_method_options()
    return table.concat(MANUAL_SPAWN_METHOD_ORDER, "|")
end

local function model_fieldone_options()
    return table.concat(MODEL_FIELDONE_ORDER, "|")
end

local function model_callone_options()
    return table.concat(MODEL_CALLONE_ORDER, "|")
end

local function model_contextone_options()
    return table.concat(MODEL_CONTEXTONE_ORDER, "|")
end

local function model_contextone_spec(field_token)
    local key = tostring(field_token or ""):lower()
    return MODEL_CONTEXTONE_FIELDS[key], key
end

local function generator_fieldone_options()
    return table.concat(GENERATOR_FIELDONE_ORDER, "|")
end

local function generator_fieldone_spec(field_token)
    local key = tostring(field_token or ""):lower()
    return GENERATOR_FIELDONE_FIELDS[key], key
end

local function generator_classref_options()
    return table.concat(GENERATOR_CLASSREF_ORDER, "|")
end

local function generator_classref_spec(ref_token)
    local key = tostring(ref_token or ""):lower()
    return GENERATOR_CLASSREF_FIELDS[key], key
end

local function generator_callone_options()
    return table.concat(GENERATOR_CALLONE_ORDER, "|")
end

local function generator_roomoption_options()
    return table.concat(GENERATOR_ROOMOPTION_ORDER, "|")
end

local function generator_roomoption_spec(field_token)
    local key = tostring(field_token or ""):lower()
    return GENERATOR_ROOMOPTION_FIELDS[key], key
end

local function room_option_value_text(value, mode)
    if mode == "count" then return count_text(value) end
    if mode == "intvec" then return intvec_text(value) end
    if mode == "shape_type" then
        local number_value = tonumber(value)
        if number_value then
            local type_name = DUNGEON_SHAPE_TYPE_NAMES[number_value]
            if type_name then return tostring(number_value) .. " (" .. type_name .. ")" end
        end
        return value_label(value)
    end
    if mode == "object" then return value_label(value) end
    return value_label(value)
end

function GENERATED_ACTOR_PROBE.value_text(value, mode)
    if mode == "count" then return count_text(value) end
    if mode == "count_sample" then return count_sample_text(value) end
    if mode == "shape_type" then return room_option_value_text(value, "shape_type") end
    if mode == "intvec" then return intvec_text(value) end
    if mode == "vec" then return vec_text(value) end
    return value_label(value)
end

function GENERATED_ACTOR_PROBE.actor_state(actor)
    local state = { valid = false, destroying = nil, text = "invalid", location = "", error = "" }
    if not is_valid(actor) then return state end
    state.valid = true
    state.location = object_location_text(actor)
    if actor.IsActorBeingDestroyed then
        local ok, value = pcall(function() return actor:IsActorBeingDestroyed() end)
        if ok then
            state.destroying = value == true
            state.text = state.destroying and "destroying" or "active"
        else
            state.text = "unknown"
            state.error = first_error_line(value)
        end
    else
        state.text = "unknown"
        state.error = "IsActorBeingDestroyed missing"
    end
    return state
end

function GENERATED_ACTOR_PROBE.cleanup_actor(actor, mode)
    mode = tostring(mode or "destroy"):lower()
    local result = {
        mode = mode,
        before = GENERATED_ACTOR_PROBE.actor_state(actor),
        after = {},
        actions = {},
        accepted = false,
        verified_gone = false,
        destroying_after = false,
        quarantined = false,
        method = "",
        error = "",
    }
    if not result.before.valid then
        result.error = "invalid actor before cleanup"
        result.after = result.before
        return result
    end

    local function append_action(name, call_fn)
        local action = { name = name, ok = false, error = "" }
        local ok, err = pcall(call_fn)
        action.ok = ok == true
        action.error = ok and "" or first_error_line(err)
        result.actions[#result.actions + 1] = action
        if ok then
            result.accepted = true
            result.method = result.method == "" and name or result.method .. "+" .. name
        end
        return ok
    end

    if mode == "hard" or mode == "quarantine" then
        if actor.SetActorHiddenInGame then append_action("SetActorHiddenInGame(true)", function() actor:SetActorHiddenInGame(true) end) end
        if actor.SetActorEnableCollision then append_action("SetActorEnableCollision(false)", function() actor:SetActorEnableCollision(false) end) end
        if actor.SetActorTickEnabled then append_action("SetActorTickEnabled(false)", function() actor:SetActorTickEnabled(false) end) end
        result.quarantined = result.accepted
    end
    if mode == "hard" and actor.SetLifeSpan then
        append_action("SetLifeSpan(0.01)", function() actor:SetLifeSpan(0.01) end)
    end
    if mode == "hard" or mode == "destroy" then
        local k2_destroy_ok = false
        if actor.K2_DestroyActor then k2_destroy_ok = append_action("K2_DestroyActor", function() actor:K2_DestroyActor() end) end
        if not k2_destroy_ok and actor.DestroyActor then append_action("DestroyActor", function() actor:DestroyActor() end) end
    end
    if #result.actions == 0 then result.error = "no cleanup methods available" end
    result.after = GENERATED_ACTOR_PROBE.actor_state(actor)
    result.verified_gone = result.after.valid ~= true
    result.destroying_after = result.after.destroying == true
    return result
end

function GENERATED_ACTOR_PROBE.method_entry(actor, method_name)
    local entry = { name = method_name, present = false, value_type = "", error = "" }
    local ok, value = pcall(function() return actor[method_name] end)
    if ok then
        entry.value_type = type(value)
        entry.present = value ~= nil
    else
        entry.error = first_error_line(value)
    end
    return entry
end

function GENERATED_ACTOR_PROBE.read_field_entry(actor, field_spec)
    local entry = { name = field_spec.name, mode = field_spec.mode, ok = false, value_type = "", value = "", error = "" }
    local read_ok, value = read_field(actor, field_spec.name)
    entry.ok = read_ok == true
    if read_ok then
        value = unwrap(value)
        entry.value_type = type(value)
        entry.value = GENERATED_ACTOR_PROBE.value_text(value, field_spec.mode)
    else
        entry.error = first_error_line(value)
    end
    return entry
end

function GENERATED_ACTOR_PROBE.vector_copy(value)
    if not value then return nil end
    local x_value, y_value, z_value = nil, nil, nil
    pcall(function() x_value = tonumber(value.X) end)
    pcall(function() y_value = tonumber(value.Y) end)
    pcall(function() z_value = tonumber(value.Z) end)
    if x_value == nil or y_value == nil or z_value == nil then return nil end
    return { X = x_value, Y = y_value, Z = z_value }
end

function GENERATED_ACTOR_PROBE.transform_location(value)
    if type(value) == "table" then
        return GENERATED_ACTOR_PROBE.vector_copy(value.Translation)
            or GENERATED_ACTOR_PROBE.vector_copy(value.Location)
            or GENERATED_ACTOR_PROBE.vector_copy(value.Position)
    end
    if type(value) == "userdata" then
        local loc = nil
        local get_ok, get_value = pcall(function() return value:GetLocation() end)
        if get_ok then loc = GENERATED_ACTOR_PROBE.vector_copy(get_value) end
        if loc then return loc end
        pcall(function() loc = GENERATED_ACTOR_PROBE.vector_copy(value.Translation) end)
        if loc then return loc end
    end
    return nil
end

function GENERATED_ACTOR_PROBE.instance_component_entry(actor, field_spec, report, lines, result_line_index, file_stem)
    local entry = {
        name = field_spec.name,
        role = field_spec.role or "",
        ok = false,
        valid = false,
        component = {},
        count = 0,
        samples = {},
        error = "",
    }
    report.result = "about_to_read_instance_component_" .. field_spec.name
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    local read_ok, component_or_error = read_field(actor, field_spec.name)
    if not read_ok then
        entry.error = first_error_line(component_or_error)
        return entry
    end

    local component = unwrap(component_or_error)
    if not is_valid(component) then
        entry.error = "component invalid or nil"
        return entry
    end
    entry.valid = true
    entry.component = {
        name = safe_name(component),
        class = safety.class_name_of(component) or "",
        full_name = safe_full_name(component),
    }

    report.result = "about_to_GetInstanceCount_" .. field_spec.name
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    local count_ok, count_or_error = pcall(function() return component:GetInstanceCount() end)
    if not count_ok then
        entry.error = first_error_line(count_or_error)
        return entry
    end
    local count = tonumber(count_or_error) or 0
    if count < 0 then count = 0 end
    entry.count = math.floor(count)
    entry.ok = true

    local sample_count = math.min(entry.count, FIELD_SAMPLE_LIMIT)
    for index = 0, sample_count - 1 do
        local sample = { index = index, ok = false, location = "", error = "" }
        report.result = "about_to_GetInstanceTransform_" .. field_spec.name .. "_" .. tostring(index)
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local out_transform = {}
        local transform_ok, ret_or_error, extra = pcall(function()
            return component:GetInstanceTransform(index, out_transform, true)
        end)
        if not transform_ok then
            sample.error = first_error_line(ret_or_error)
        elseif ret_or_error == false then
            sample.error = "GetInstanceTransform returned false"
        else
            local loc = GENERATED_ACTOR_PROBE.transform_location(out_transform)
                or GENERATED_ACTOR_PROBE.transform_location(ret_or_error)
                or GENERATED_ACTOR_PROBE.transform_location(extra)
            if loc then
                sample.ok = true
                sample.location = vec_text(loc)
            else
                sample.error = "no transform location"
            end
        end
        entry.samples[#entry.samples + 1] = sample
    end
    return entry
end

function GENERATED_ACTOR_PROBE.instance_component_sample_text(entry)
    local parts = {}
    for sample_index = 1, #entry.samples do
        local sample = entry.samples[sample_index]
        if sample.ok then
            parts[#parts + 1] = tostring(sample.index) .. "@" .. sample.location
        else
            parts[#parts + 1] = tostring(sample.index) .. "=<" .. tostring(sample.error) .. ">"
        end
    end
    if #parts == 0 then return "" end
    return " sample=[" .. table.concat(parts, "; ") .. "]"
end

function GENERATED_ACTOR_PROBE.wall_component(actor)
    local errors = {}
    for _field_index, field_name in ipairs({ "WallISM", "WallISMComponent" }) do
        local read_ok, value = read_field(actor, field_name)
        if read_ok then
            local component = unwrap(value)
            if is_valid(component) then return component, field_name, errors end
            errors[#errors + 1] = field_name .. ": invalid component"
        else
            errors[#errors + 1] = field_name .. ": " .. first_error_line(value)
        end
    end
    return nil, "", errors
end

function GENERATED_ACTOR_PROBE.instance_location(component, index)
    local out_transform = {}
    local transform_ok, ret_or_error, extra = pcall(function()
        return component:GetInstanceTransform(index, out_transform, true)
    end)
    if not transform_ok then return nil, first_error_line(ret_or_error) end
    if ret_or_error == false then return nil, "GetInstanceTransform returned false" end
    local loc = GENERATED_ACTOR_PROBE.transform_location(out_transform)
        or GENERATED_ACTOR_PROBE.transform_location(ret_or_error)
        or GENERATED_ACTOR_PROBE.transform_location(extra)
    if not loc then return nil, "no transform location" end
    return loc, nil
end

function GENERATED_ACTOR_PROBE.distance_sq(left, right)
    if not left or not right then return nil end
    local dx = (tonumber(left.X) or 0) - (tonumber(right.X) or 0)
    local dy = (tonumber(left.Y) or 0) - (tonumber(right.Y) or 0)
    local dz = (tonumber(left.Z) or 0) - (tonumber(right.Z) or 0)
    return dx * dx + dy * dy + dz * dz
end

function GENERATED_ACTOR_PROBE.wall_instances(actor, report, lines, result_line_index, file_stem, limit)
    local result = { ok = false, component_field = "", component = {}, count = 0, sampled = 0, instances = {}, errors = {} }
    report.result = "about_to_read_wall_component"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    local component, component_field, component_errors = GENERATED_ACTOR_PROBE.wall_component(actor)
    result.component_field = component_field or ""
    result.errors = component_errors or {}
    if not is_valid(component) then return result end
    result.component = {
        name = safe_name(component),
        class = safety.class_name_of(component) or "",
        full_name = safe_full_name(component),
    }

    report.result = "about_to_wall_GetInstanceCount"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    local count_ok, count_or_error = pcall(function() return component:GetInstanceCount() end)
    if not count_ok then
        result.errors[#result.errors + 1] = "GetInstanceCount: " .. first_error_line(count_or_error)
        return result
    end
    local count = tonumber(count_or_error) or 0
    if count < 0 then count = 0 end
    result.count = math.floor(count)
    result.ok = true

    local sample_limit = tonumber(limit) or result.count
    if sample_limit < 0 then sample_limit = 0 end
    if sample_limit > 512 then sample_limit = 512 end
    sample_limit = math.min(result.count, math.floor(sample_limit))
    result.sampled = sample_limit

    for index = 0, sample_limit - 1 do
        local entry = { index = index, ok = false, location = "", loc = nil, error = "" }
        report.result = "about_to_wall_GetInstanceTransform_" .. tostring(index)
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local loc, loc_error = GENERATED_ACTOR_PROBE.instance_location(component, index)
        if loc then
            entry.ok = true
            entry.loc = loc
            entry.location = vec_text(loc)
        else
            entry.error = tostring(loc_error or "unknown transform error")
        end
        result.instances[#result.instances + 1] = entry
    end
    return result, component
end

function GENERATED_ACTOR_PROBE.nearest_wall_instance(walls, target)
    local nearest = nil
    for entry_index = 1, #(walls.instances or {}) do
        local entry = walls.instances[entry_index]
        if entry.ok and entry.loc then
            local distance_sq = GENERATED_ACTOR_PROBE.distance_sq(entry.loc, target)
            if distance_sq and (not nearest or distance_sq < nearest.distance_sq) then
                nearest = {
                    index = entry.index,
                    location = entry.location,
                    distance_sq = distance_sq,
                    distance = math.sqrt(distance_sq),
                }
            end
        end
    end
    return nearest
end

function GENERATED_ACTOR_PROBE.remove_nearest_wall_instance(actor, target, max_distance)
    local result = {
        ok = false,
        skipped = false,
        component_field = "",
        component = {},
        count_before = 0,
        count_after = nil,
        target = vec_text(target),
        nearest = nil,
        remove_returned = nil,
        error = "",
        errors = {},
    }
    local component, component_field, component_errors = GENERATED_ACTOR_PROBE.wall_component(actor)
    result.component_field = component_field or ""
    result.errors = component_errors or {}
    if not is_valid(component) then
        result.error = "wall component unavailable"
        return result
    end
    result.component = { name = safe_name(component), class = safety.class_name_of(component) or "", full_name = safe_full_name(component) }

    local count_ok, count_or_error = pcall(function() return component:GetInstanceCount() end)
    if not count_ok then
        result.error = "GetInstanceCount: " .. first_error_line(count_or_error)
        return result
    end
    local count = tonumber(count_or_error) or 0
    if count < 0 then count = 0 end
    result.count_before = math.floor(count)
    local max_count = math.min(result.count_before, 512)

    local nearest = nil
    for index = 0, max_count - 1 do
        local loc, loc_error = GENERATED_ACTOR_PROBE.instance_location(component, index)
        if loc then
            local distance_sq = GENERATED_ACTOR_PROBE.distance_sq(loc, target)
            if distance_sq and (not nearest or distance_sq < nearest.distance_sq) then
                nearest = { index = index, location = vec_text(loc), distance_sq = distance_sq, distance = math.sqrt(distance_sq) }
            end
        elseif loc_error and loc_error ~= "" then
            result.errors[#result.errors + 1] = "wall[" .. tostring(index) .. "]: " .. tostring(loc_error)
        end
    end

    result.nearest = nearest
    if not nearest then
        result.error = "no wall instance found"
        return result
    end
    if nearest.distance > max_distance then
        result.skipped = true
        result.error = string.format("nearest wall %.1f > max_distance %.1f", nearest.distance, max_distance)
        return result
    end

    local remove_ok, remove_return_or_error = pcall(function() return component:RemoveInstance(nearest.index) end)
    result.remove_returned = remove_ok and remove_return_or_error or nil
    if not remove_ok then
        result.error = "RemoveInstance: " .. first_error_line(remove_return_or_error)
        return result
    end
    result.ok = remove_return_or_error ~= false
    if not result.ok then
        result.error = "RemoveInstance returned false"
        return result
    end

    local after_ok, after_count = pcall(function() return component:GetInstanceCount() end)
    if after_ok then result.count_after = tonumber(after_count) or 0 end
    return result
end

function GENERATED_ACTOR_PROBE.target_actor(target_key, index)
    local target_spec = GENERATED_ACTOR_PROBE.surface_targets[target_key]
    if not target_spec then return nil, nil, "unsupported target" end
    local bucket = find_objects(target_spec.queries)
    if index < 1 or index > #bucket.live then
        return nil, bucket, string.format("%s index out of range 1..%d", target_key, #bucket.live)
    end
    local actor = bucket.live[index]
    if not is_valid(actor) then return nil, bucket, "selected generated actor invalid" end
    return actor, bucket, nil
end

function GENERATED_ACTOR_PROBE.function_name(fn)
    if type(fn) ~= "userdata" then return "" end
    local fname_ok, fname = pcall(function() return fn:GetFName() end)
    if fname_ok and fname ~= nil then
        local string_ok, text = pcall(function() return fname:ToString() end)
        if string_ok and type(text) == "string" and text ~= "" then return text end
    end
    return safe_name(fn)
end

function GENERATED_ACTOR_PROBE.function_matches_filter(name, owner_class, filter_mode)
    local mode = tostring(filter_mode or "interesting"):lower()
    if mode == "all" then return true end
    local haystack = tostring(name or ""):lower() .. " " .. tostring(owner_class or ""):lower()
    if mode ~= "" and mode ~= "interesting" then
        return haystack:find(mode, 1, true) ~= nil
    end
    for keyword_index = 1, #GENERATED_ACTOR_PROBE.entry_surface_keywords do
        if haystack:find(GENERATED_ACTOR_PROBE.entry_surface_keywords[keyword_index], 1, true) then return true end
    end
    return false
end

function GENERATED_ACTOR_PROBE.collect_function_surface(obj, filter_mode, method_limit)
    local surface = {
        ok = false,
        filter = tostring(filter_mode or "interesting"),
        total_functions = 0,
        matched_functions = 0,
        omitted_functions = 0,
        class_layers = {},
        methods = {},
        error = "",
    }
    method_limit = math.floor(tonumber(method_limit) or 120)
    if method_limit < 1 then method_limit = 1 end
    if method_limit > 250 then method_limit = 250 end
    if not is_valid(obj) then
        surface.error = "invalid object"
        return surface
    end
    local class_ok, class_obj = pcall(function() return obj:GetClass() end)
    if not class_ok or not is_valid(class_obj) then
        surface.error = class_ok and "GetClass returned invalid" or first_error_line(class_obj)
        return surface
    end
    surface.ok = true
    local seen_layers = {}
    local current = class_obj
    while is_valid(current) and not seen_layers[object_key(current)] do
        seen_layers[object_key(current)] = true
        local owner_class = safe_name(current)
        local layer = { class = owner_class, full_name = safe_full_name(current), function_count = 0, matched_count = 0 }
        surface.class_layers[#surface.class_layers + 1] = layer
        local iter_ok, iter_error = pcall(function()
            current:ForEachFunction(function(fn)
                local method_name = GENERATED_ACTOR_PROBE.function_name(fn)
                if method_name == "" then return end
                layer.function_count = layer.function_count + 1
                surface.total_functions = surface.total_functions + 1
                if GENERATED_ACTOR_PROBE.function_matches_filter(method_name, owner_class, filter_mode) then
                    layer.matched_count = layer.matched_count + 1
                    surface.matched_functions = surface.matched_functions + 1
                    if #surface.methods < method_limit then
                        surface.methods[#surface.methods + 1] = {
                            owner_class = owner_class,
                            name = method_name,
                            full_name = safe_full_name(fn),
                        }
                    else
                        surface.omitted_functions = surface.omitted_functions + 1
                    end
                end
            end)
        end)
        if not iter_ok then
            layer.error = first_error_line(iter_error)
        end
        local next_ok, next_struct = pcall(function() return current:GetSuperStruct() end)
        if not next_ok or not is_valid(next_struct) or next_struct == current then break end
        current = next_struct
    end
    return surface
end

function GENERATED_ACTOR_PROBE.component_sample(actor, class_path, label)
    local entry = { label = label, class_path = class_path, ok = false, count = 0, samples = {}, error = "" }
    local class_obj = player_core.resolve_uclass(class_path)
    if not is_valid(class_obj) then
        entry.error = "class resolve failed"
        return entry
    end
    if not actor.K2_GetComponentsByClass then
        entry.error = "K2_GetComponentsByClass missing"
        return entry
    end
    local ok, value = pcall(function() return actor:K2_GetComponentsByClass(class_obj) end)
    if not ok then
        entry.error = first_error_line(value)
        return entry
    end
    entry.ok = true
    entry.count = container_count(value) or 0
    local max_sample = math.min(entry.count, FIELD_SAMPLE_LIMIT)
    for index = 1, max_sample do
        local component = container_item(value, index)
        entry.samples[#entry.samples + 1] = {
            index = index,
            name = safe_name(component),
            class = safety.class_name_of(component) or "",
            full_name = safe_full_name(component),
        }
    end
    return entry
end

function GENERATED_ACTOR_PROBE.room_snapshot(actor, file_stem, report, lines, result_line_index, phase)
    local snapshot = { phase = phase, fields = {}, parts = {} }
    for _field_index, field_spec in ipairs(GENERATED_ACTOR_PROBE.room_snapshot_fields) do
        report.result = "about_to_read_" .. tostring(phase) .. "_" .. field_spec.name
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local entry = GENERATED_ACTOR_PROBE.read_field_entry(actor, field_spec)
        snapshot.fields[#snapshot.fields + 1] = entry
        if entry.ok then
            snapshot.parts[#snapshot.parts + 1] = entry.name .. "=" .. entry.value
        else
            snapshot.parts[#snapshot.parts + 1] = entry.name .. "=<read failed>"
        end
    end
    return snapshot
end

function GENERATED_ACTOR_PROBE.number_value(value)
    value = unwrap(value)
    local direct = tonumber(value)
    if direct then return direct end
    local label = value_label(value)
    local parsed = tonumber(tostring(label):match("^-?%d+"))
    return parsed
end

function GENERATED_ACTOR_PROBE.rotation_yaw(value)
    local number_value = GENERATED_ACTOR_PROBE.number_value(value) or 0
    if number_value == 1 then return 90 end
    if number_value == 2 then return 180 end
    if number_value == 3 then return 270 end
    return 0
end

local function model_fieldone_spec(field_token)
    local key = tostring(field_token or ""):lower()
    return MODEL_FIELDONE_FIELDS[key], key
end

local function model_fieldone_disabled_reason(field_key)
    local native_field = MODEL_FIELDONE_DISABLED_FIELDS[field_key]
    if not native_field then return nil end
    return native_field .. " direct read disabled after live crash; use world.dungeon.proc.managers instead"
end

local function constructable_manager_options()
    return table.concat(CONSTRUCTABLE_MANAGER_ORDER, "|")
end

local function constructable_manager_spec(role_token)
    local key = tostring(role_token or ""):lower()
    return CONSTRUCTABLE_MANAGER_SPECS[key], key
end

local function manager_object_name(role_key)
    local suffix = tostring(math.floor(os.clock() * 1000000))
    return "RSDWTools_ProcDungeon_" .. tostring(role_key or "manager") .. "_" .. suffix
end

local function ensure_generator_for_probe(index, file_stem)
    local generators, generator_errors = live_generators()
    if index >= 1 and index <= #generators then
        local existing = generators[index]
        if is_valid(existing) then return existing, generators, generator_errors, nil, nil end
        return nil, generators, generator_errors, nil, "selected generator invalid"
    end
    if #generators > 0 then
        return nil, generators, generator_errors, nil, generator_index_error(#generators)
    end

    local models, model_errors = live_models()
    if index < 1 or index > #models then
        return nil, generators, generator_errors, nil,
            "no live DungeonGenerator objects and no matching live model; start with world.dungeon.proc.status, world.spawn " .. KNOWN_TELEPORT_CLASS_PATH .. ", then world.dungeon.proc.spawn.linked 1 1 -12000 12345 0 confirm"
    end
    if not StaticConstructObject then return nil, generators, generator_errors, nil, "StaticConstructObject unavailable" end
    if not FName then return nil, generators, generator_errors, nil, "FName unavailable" end

    local model = models[index]
    if not is_valid(model) then return nil, generators, generator_errors, nil, "selected model invalid" end
    local spec = CONSTRUCTABLE_MANAGER_SPECS.generator
    local object_name = manager_object_name("generator")
    local report = {
        command = "world.dungeon.proc.generator.autowire",
        index = index,
        model_index = index,
        role = "generator",
        class_path = spec.class_path,
        object_name = object_name,
        errors = { generators = generator_errors, models = model_errors },
        result = "about_to_resolve_class",
        writes = {},
        manager = {},
        cache_index = 0,
        warning = "auto-constructs and wires BP_DungeonGenerator_C because no live generator object exists",
        model = {
            index = index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generator.autowire --",
        string.format("  live DungeonGenerator objects: %d", #generators),
        string.format("  model[%d] %s [%s] loc=%s", index, report.model.name, report.model.class, report.model.location),
        "  class=" .. spec.class_path,
        "  object_name=" .. object_name,
        "  warning: auto-constructs generator for one generator probe",
        "  result=" .. report.result,
        "  writes:",
    }
    local result_line_index = 7
    write_report_files(file_stem .. "_autowire_attempt", report, lines)

    local class_obj = player_core.resolve_uclass(spec.class_path)
    if not is_valid(class_obj) then
        report.result = "resolve_class_failed"
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: could not resolve " .. spec.class_path
        for line_index = 1, #lines do print(lines[line_index]) end
        write_report_files(file_stem .. "_autowire", report, lines)
        return nil, generators, generator_errors, report, "could not resolve " .. spec.class_path
    end
    ---@cast class_obj UClass

    report.result = "about_to_StaticConstructObject"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_autowire_attempt", report, lines)

    local manager = nil
    local construct_ok, construct_error = pcall(function()
        manager = StaticConstructObject(class_obj, model, FName(object_name))
    end)
    if not construct_ok or not is_valid(manager) then
        report.result = "construct_failed"
        report.error = construct_ok and "StaticConstructObject returned invalid" or tostring(construct_error)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. tostring(report.error)
        for line_index = 1, #lines do print(lines[line_index]) end
        write_report_files(file_stem .. "_autowire", report, lines)
        return nil, generators, generator_errors, report, report.error
    end

    constructed_manager_cache[#constructed_manager_cache + 1] = {
        object = manager,
        role = "generator",
        label = spec.label,
        model_key = object_key(model),
    }
    report.cache_index = #constructed_manager_cache
    report.manager = {
        cache_index = report.cache_index,
        role = "generator",
        label = spec.label,
        name = safe_name(manager),
        class = safety.class_name_of(manager) or "",
        full_name = safe_full_name(manager),
    }
    lines[#lines + 1] = string.format("  constructed[%d] %s [%s] full=%s", report.cache_index, report.manager.name, report.manager.class, report.manager.full_name)

    local all_ok = true
    report.result = "about_to_write_DungeonGenerator"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_autowire_attempt", report, lines)
    if not write_actor_field(report, lines, model, spec.model_field, manager, report.manager.name) then all_ok = false end

    report.result = "about_to_write_CurrentChainComponent"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_autowire_attempt", report, lines)
    if not write_actor_field(report, lines, model, "CurrentChainComponent", manager, report.manager.name) then all_ok = false end

    report.result = all_ok and "auto_constructed_wired_generator" or "auto_constructed_wired_generator_partial"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    write_report_files(file_stem .. "_autowire", report, lines)
    return manager, { manager }, generator_errors, report, nil
end

local function resolve_generator_ref_source(source_token, file_stem)
    local source_text = tostring(source_token or ""):lower()
    if source_text == "" or source_text == "cdo" or source_text == "default" then
        local class_path = CONSTRUCTABLE_MANAGER_SPECS.generator.class_path
        local class_obj = player_core.resolve_uclass(class_path)
        if not is_valid(class_obj) then return nil, nil, "could not resolve generator class: " .. class_path end
        local cdo, cdo_error = player_core.resolve_class_cdo(class_obj)
        if not is_valid(cdo) then return nil, nil, "could not resolve generator CDO: " .. tostring(cdo_error) end
        return cdo, {
            mode = "cdo",
            index = 0,
            name = safe_name(cdo),
            class = safety.class_name_of(cdo) or "",
            full_name = safe_full_name(cdo),
            class_path = class_path,
            autowire = nil,
        }, nil
    end
    local index = tonumber(source_token)
    if not index then return nil, nil, "source must be cdo or a generator/model index" end
    index = math.floor(index)
    local generator, generators, errors, auto_construct, resolve_error = ensure_generator_for_probe(index, file_stem)
    if resolve_error then return nil, nil, resolve_error end
    if not is_valid(generator) then return nil, nil, "selected generator unavailable" end
    return generator, {
        mode = "live",
        index = index,
        count = #generators,
        errors = errors,
        name = safe_name(generator),
        class = safety.class_name_of(generator) or "",
        full_name = safe_full_name(generator),
        class_path = CONSTRUCTABLE_MANAGER_SPECS.generator.class_path,
        autowire = auto_construct,
    }, nil
end

local function model_callone_callable(action_key, model)
    local key = tostring(action_key or ""):lower()
    if key == "onrep" then
        return "OnRep_DataContext", function() return model:OnRep_DataContext() end, "calls ADungeonModel.OnRep_DataContext once"
    elseif key == "build_blocker" then
        return "CreateAndSpawnBuildBlocker", function() return model:CreateAndSpawnBuildBlocker() end, "calls ADungeonModel.CreateAndSpawnBuildBlocker once"
    elseif key == "show_loading_on" then
        return "ShowLoadingScreenEvent(true)", function() return model:ShowLoadingScreenEvent(true) end, "calls ADungeonModel.ShowLoadingScreenEvent(true) once"
    elseif key == "show_loading_off" then
        return "ShowLoadingScreenEvent(false)", function() return model:ShowLoadingScreenEvent(false) end, "calls ADungeonModel.ShowLoadingScreenEvent(false) once"
    elseif key == "respawn_resources" then
        return "OnTimeToRespawnResources", function() return model:OnTimeToRespawnResources() end, "KNOWN CRASH BOUNDARY unless generated resource spawners exist; calls ADungeonModel.OnTimeToRespawnResources once"
    elseif key == "receive_tick" then
        return "ReceiveTick(0.016)", function() return model:ReceiveTick(0.016) end, "calls Actor.ReceiveTick once with 16ms delta"
    elseif key == "beginplay" then
        return "ReceiveBeginPlay", function() return model:ReceiveBeginPlay() end, "calls Actor.ReceiveBeginPlay once; use only after manager wiring"
    elseif key == "construction" then
        return "UserConstructionScript", function() return model:UserConstructionScript() end, "calls Actor.UserConstructionScript once; may rerun blueprint setup"
    end
    return nil, nil, nil
end

local function cached_manager_usage(command)
    return "usage: " .. command .. " <model_index> <" .. constructable_manager_options() .. "> [cache_index|latest] confirm"
end

local function parse_cached_manager_args(args_str, command)
    local model_token, role_token, third_token, fourth_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)%s*(%S*)")
    if not model_token or not role_token then return nil, nil, nil, cached_manager_usage(command) end
    local model_index = tonumber(model_token)
    if not model_index then return nil, nil, nil, "model index must be a number" end
    model_index = math.floor(model_index)
    local cache_token = "latest"
    local confirm_token = third_token
    if third_token ~= "" and third_token ~= "confirm" then
        cache_token = third_token
        confirm_token = fourth_token
    end
    if confirm_token ~= "confirm" then
        return nil, nil, nil, cached_manager_usage(command)
    end
    local spec, role_key = constructable_manager_spec(role_token)
    if not spec then return nil, nil, nil, "unknown manager role; choose one of: " .. constructable_manager_options() end
    return model_index, role_key, cache_token, nil
end

local function cached_manager_for(model, role_key, cache_token)
    local model_key = object_key(model)
    local token = tostring(cache_token or "latest")
    if token ~= "" and token ~= "latest" then
        local explicit_index = tonumber(token)
        if not explicit_index then return nil, 0, "cache index must be a number or latest" end
        explicit_index = math.floor(explicit_index)
        local entry = constructed_manager_cache[explicit_index]
        if not entry then return nil, explicit_index, "cache index out of range" end
        if entry.role ~= role_key then return nil, explicit_index, "cache index role is " .. tostring(entry.role) .. ", expected " .. tostring(role_key) end
        if entry.model_key ~= model_key then return nil, explicit_index, "cache index belongs to a different model" end
        if not is_valid(entry.object) then return nil, explicit_index, "cached manager object is invalid" end
        return entry, explicit_index, nil
    end
    for index = #constructed_manager_cache, 1, -1 do
        local entry = constructed_manager_cache[index]
        if entry and entry.role == role_key and entry.model_key == model_key then
            if is_valid(entry.object) then return entry, index, nil end
            return nil, index, "latest cached manager object is invalid"
        end
    end
    return nil, 0, "no cached " .. tostring(role_key) .. " manager for this model; run world.dungeon.proc.manager.construct first"
end

local function method_surface_record(obj, method_name)
    local ok, value = pcall(function() return obj[method_name] end)
    local value_type = ok and type(value) or "error"
    local entry = {
        name = method_name,
        ok = ok == true,
        value_type = value_type,
        exposed = ok and value_type == "function",
        callable_candidate = ok and (value_type == "function" or value_type == "userdata"),
        error = ok and "" or first_error_line(value),
    }
    return entry
end

local function append_method_surface(report, lines, obj, method_names)
    for _index, method_name in ipairs(method_names) do
        local entry = method_surface_record(obj, method_name)
        report.methods[#report.methods + 1] = entry
        if entry.ok then
            lines[#lines + 1] = string.format("      %s=%s exposed=%s callable_candidate=%s", entry.name, entry.value_type, tostring(entry.exposed), tostring(entry.callable_candidate))
        else
            lines[#lines + 1] = string.format("      %s=<lookup failed: %s>", entry.name, entry.error)
        end
    end
end

local function write_method_surface_report(command, file_stem, object_label, objects, errors, index, obj, method_names, function_filter)
    local report = {
        command = command,
        index = index,
        count = #objects,
        errors = errors,
        object = {
            index = index,
            label = object_label,
            name = safe_name(obj),
            class = safety.class_name_of(obj) or "",
            full_name = safe_full_name(obj),
            location = object_location_text(obj),
        },
        methods = {},
        function_surface = nil,
        note = "method lookup only; no reflected fields are read and no methods are called; UE4SS UFunctions often appear as userdata",
    }
    local lines = {
        "[RSDWTools] " .. command .. " --",
        string.format("  live %s actors: %d", object_label, #objects),
        "  note: method lookup only; no reflected fields are read and no methods are called; UE4SS UFunctions often appear as userdata",
        string.format("  [%d] %s [%s] loc=%s", index, report.object.name, report.object.class, report.object.location),
        "  methods:",
    }
    for error_index = 1, #errors do
        lines[#lines + 1] = "  error: " .. tostring(errors[error_index])
    end
    append_method_surface(report, lines, obj, method_names)
    if function_filter then
        report.function_surface = GENERATED_ACTOR_PROBE.collect_function_surface(obj, function_filter, 180)
        local surface = report.function_surface or { methods = {} }
        local methods = surface.methods or {}
        lines[#lines + 1] = string.format(
            "  function_surface filter=%s matched=%d/%d omitted=%d",
            tostring(function_filter),
            surface.matched_functions or 0,
            surface.total_functions or 0,
            surface.omitted_functions or 0)
        if surface.error and surface.error ~= "" then lines[#lines + 1] = "    error: " .. surface.error end
        local max_lines = math.min(#methods, 32)
        for method_index = 1, max_lines do
            local method = methods[method_index]
            lines[#lines + 1] = string.format("    %s::%s", method.owner_class or "", method.name or "")
        end
        if #methods > max_lines then
            lines[#lines + 1] = string.format("    ... %d more in JSON", #methods - max_lines)
        end
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local exposed = 0
    for method_index = 1, #report.methods do
        if report.methods[method_index].exposed then exposed = exposed + 1 end
    end
    local detail = string.format("index=%d object=%s exposed=%d/%d", index, report.object.name, exposed, #report.methods)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.probe(args_str)
    local sample_limit = parse_limit(args_str)
    local report, lines = build_probe_report("world.dungeon.proc.probe", sample_limit, "none", false)
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_probe", report, lines)
    if write_ok then return true, "wrote " .. tostring(write_detail) end
    return true, "see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.models(args_str)
    local sample_limit = parse_limit(args_str)
    if trim(args_str) == "" then sample_limit = MAX_SAMPLE_LIMIT end
    local models, errors = live_models()
    local report = {
        command = "world.dungeon.proc.models",
        count = #models,
        sample_limit = sample_limit,
        errors = errors,
        models = {},
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.models --",
        string.format("  live DungeonModel actors: %d", #models),
    }
    for error_index = 1, #errors do
        lines[#lines + 1] = "  error: " .. tostring(errors[error_index])
    end
    local max_sample = math.min(#models, sample_limit)
    for index = 1, max_sample do
        append_model_summary(report, lines, index, models[index])
    end
    if #models > max_sample then
        lines[#lines + 1] = string.format("  ... +%d more; pass a larger limit up to %d", #models - max_sample, MAX_SAMPLE_LIMIT)
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_models", report, lines)
    if write_ok then return true, "count=" .. tostring(#models) .. " wrote " .. tostring(write_detail) end
    return true, "count=" .. tostring(#models) .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.status(_args_str)
    local models, model_errors = live_models()
    local teleports, teleport_errors = live_teleports()
    local managers, manager_errors = live_spawn_managers()
    local report = {
        command = "world.dungeon.proc.status",
        counts = {
            models = #models,
            teleports = #teleports,
            spawn_managers = #managers,
        },
        errors = {
            models = model_errors,
            teleports = teleport_errors,
            spawn_managers = manager_errors,
        },
        hints = {
            model_spawn = "world.spawn " .. KNOWN_GENERATOR_CLASS_PATHS[1],
            teleport_spawn = "world.spawn " .. KNOWN_TELEPORT_CLASS_PATH,
        },
        spawn_managers = {},
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.status --",
        string.format("  live DungeonModel actors: %d", #models),
        string.format("  live DungeonTeleport actors: %d", #teleports),
        string.format("  live DungeonSpawnManager objects: %d", #managers),
    }
    if #models == 0 then lines[#lines + 1] = "  hint: " .. report.hints.model_spawn end
    if #teleports == 0 then lines[#lines + 1] = "  hint: " .. report.hints.teleport_spawn end
    for error_index = 1, #model_errors do lines[#lines + 1] = "  model error: " .. tostring(model_errors[error_index]) end
    for error_index = 1, #teleport_errors do lines[#lines + 1] = "  teleport error: " .. tostring(teleport_errors[error_index]) end
    for error_index = 1, #manager_errors do lines[#lines + 1] = "  spawnmanager error: " .. tostring(manager_errors[error_index]) end
    local manager_limit = math.min(#managers, 5)
    for index = 1, manager_limit do
        local manager = managers[index]
        local entry = {
            index = index,
            name = safe_name(manager),
            class = safety.class_name_of(manager) or "",
            full_name = safe_full_name(manager),
            spawned_dungeons = "",
        }
        local read_ok, spawned = read_field(manager, "SpawnedDungeons")
        if read_ok then
            entry.spawned_dungeons = count_sample_text(spawned)
        else
            entry.spawned_dungeons = "<read failed: " .. first_error_line(spawned) .. ">"
        end
        report.spawn_managers[#report.spawn_managers + 1] = entry
        lines[#lines + 1] = string.format("  spawnmanager[%d] %s spawned_dungeons=%s", index, entry.name, entry.spawned_dungeons)
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_status", report, lines)
    local detail = string.format("models=%d teleports=%d spawnmanagers=%d", #models, #teleports, #managers)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.spawn_managers(args_str)
    local sample_limit = parse_limit(args_str)
    if trim(args_str) == "" then sample_limit = MAX_SAMPLE_LIMIT end
    local managers, errors = live_spawn_managers()
    local report = {
        command = "world.dungeon.proc.spawnmanagers",
        count = #managers,
        sample_limit = sample_limit,
        errors = errors,
        managers = {},
        note = "reads only UDungeonSpawnManager.SpawnedDungeons count/sample",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.spawnmanagers --",
        string.format("  live DungeonSpawnManager objects: %d", #managers),
        "  note: reads only UDungeonSpawnManager.SpawnedDungeons count/sample",
    }
    for error_index = 1, #errors do
        lines[#lines + 1] = "  error: " .. tostring(errors[error_index])
    end
    local max_sample = math.min(#managers, sample_limit)
    for index = 1, max_sample do
        local manager = managers[index]
        local entry = {
            index = index,
            name = safe_name(manager),
            class = safety.class_name_of(manager) or "",
            full_name = safe_full_name(manager),
            spawned_dungeons = "",
        }
        local read_ok, spawned = read_field(manager, "SpawnedDungeons")
        if read_ok then
            entry.spawned_dungeons = count_sample_text(spawned)
        else
            entry.spawned_dungeons = "<read failed: " .. first_error_line(spawned) .. ">"
        end
        report.managers[#report.managers + 1] = entry
        lines[#lines + 1] = string.format("  [%d] %s [%s] spawned_dungeons=%s", entry.index, entry.name, entry.class, entry.spawned_dungeons)
    end
    if #managers > max_sample then
        lines[#lines + 1] = string.format("  ... +%d more; pass a larger limit up to %d", #managers - max_sample, MAX_SAMPLE_LIMIT)
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_spawnmanagers", report, lines)
    if write_ok then return true, "count=" .. tostring(#managers) .. " wrote " .. tostring(write_detail) end
    return true, "count=" .. tostring(#managers) .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.manager_objects(args_str)
    local sample_limit = parse_limit(args_str)
    if trim(args_str) == "" then sample_limit = 8 end
    local report = {
        command = "world.dungeon.proc.managers",
        sample_limit = sample_limit,
        classes = {},
        current_class = "",
        note = "metadata-only FindAllOf scan for procedural manager/helper classes; no ADungeonModel manager fields are read",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.managers --",
        "  note: metadata-only FindAllOf scan; no ADungeonModel manager fields are read",
    }
    local total_live = 0
    for _spec_index, spec in ipairs(MANAGER_OBJECT_SPECS) do
        report.current_class = spec.key
        write_report_files("dungeon_proc_managers_attempt", report, lines)
        local bucket = find_objects(spec.queries)
        total_live = total_live + #bucket.live
        local entry = {
            class = spec.key,
            queries = spec.queries,
            live_count = #bucket.live,
            default_count = #bucket.defaults,
            errors = bucket.errors,
            samples = {},
        }
        report.classes[#report.classes + 1] = entry
        lines[#lines + 1] = string.format("  %s: live=%d default=%d", spec.key, #bucket.live, #bucket.defaults)
        for error_index = 1, #bucket.errors do
            lines[#lines + 1] = "    error: " .. tostring(bucket.errors[error_index])
        end
        local max_sample = math.min(#bucket.live, sample_limit)
        for index = 1, max_sample do
            local obj = bucket.live[index]
            local full_name = safe_full_name(obj)
            local sample = {
                index = index,
                name = name_from_full_name(full_name),
                full_name = full_name,
            }
            entry.samples[#entry.samples + 1] = sample
            lines[#lines + 1] = string.format("    [%d] %s full=%s", index, sample.name, sample.full_name)
        end
        if #bucket.live > max_sample then
            lines[#lines + 1] = string.format("    ... +%d more; pass a larger limit up to %d", #bucket.live - max_sample, MAX_SAMPLE_LIMIT)
        end
    end
    report.current_class = "complete"
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_managers", report, lines)
    local detail = string.format("classes=%d live=%d", #MANAGER_OBJECT_SPECS, total_live)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_objects(args_str)
    local sample_limit = parse_limit(args_str)
    if trim(args_str) == "" then sample_limit = 8 end
    local report = {
        command = "world.dungeon.proc.generated",
        sample_limit = sample_limit,
        classes = {},
        current_class = "",
        note = "metadata-only FindAllOf scan for generated dungeon runtime actors/objects; no fields are read",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated --",
        "  note: metadata-only FindAllOf scan; no generated-object fields are read",
    }
    local total_live = 0
    for _spec_index, spec in ipairs(GENERATED_OBJECT_SPECS) do
        report.current_class = spec.key
        write_report_files("dungeon_proc_generated_attempt", report, lines)
        local bucket = find_objects(spec.queries)
        total_live = total_live + #bucket.live
        local entry = {
            class = spec.key,
            queries = spec.queries,
            live_count = #bucket.live,
            default_count = #bucket.defaults,
            errors = bucket.errors,
            samples = {},
        }
        report.classes[#report.classes + 1] = entry
        lines[#lines + 1] = string.format("  %s: live=%d default=%d", spec.key, #bucket.live, #bucket.defaults)
        for error_index = 1, #bucket.errors do
            lines[#lines + 1] = "    error: " .. tostring(bucket.errors[error_index])
        end
        local max_sample = math.min(#bucket.live, sample_limit)
        for index = 1, max_sample do
            local obj = bucket.live[index]
            local full_name = safe_full_name(obj)
            local sample = {
                index = index,
                name = name_from_full_name(full_name),
                full_name = full_name,
            }
            entry.samples[#entry.samples + 1] = sample
            lines[#lines + 1] = string.format("    [%d] %s full=%s", index, sample.name, sample.full_name)
        end
        if #bucket.live > max_sample then
            lines[#lines + 1] = string.format("    ... +%d more; pass a larger limit up to %d", #bucket.live - max_sample, MAX_SAMPLE_LIMIT)
        end
    end
    report.current_class = "complete"
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_generated", report, lines)
    local detail = string.format("classes=%d live=%d", #GENERATED_OBJECT_SPECS, total_live)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_state(args_str)
    local sample_limit = parse_limit(args_str)
    if trim(args_str) == "" then sample_limit = 8 end
    local function actor_state_text(obj)
        local state_ok, destroying = pcall(function()
            if obj.IsActorBeingDestroyed then return obj:IsActorBeingDestroyed() end
            return nil
        end)
        if state_ok and destroying == true then return "destroying" end
        if state_ok and destroying == false then return "active" end
        return "unknown"
    end
    local report = {
        command = "world.dungeon.proc.generated.state",
        sample_limit = sample_limit,
        classes = {},
        unique = {},
        current_class = "",
        note = "FindAllOf plus Actor.IsActorBeingDestroyed; useful after K2_DestroyActor because destroyed actors can remain discoverable briefly",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.state --",
        "  note: FindAllOf scan with IsActorBeingDestroyed state classification",
    }
    local total_active = 0
    local total_destroying = 0
    local unique_by_key = {}
    local unique_order = {}
    for _spec_index, spec in ipairs(GENERATED_OBJECT_SPECS) do
        report.current_class = spec.key
        write_report_files("dungeon_proc_generated_state_attempt", report, lines)
        local bucket = find_objects(spec.queries)
        local entry = {
            class = spec.key,
            queries = spec.queries,
            found_count = #bucket.live,
            default_count = #bucket.defaults,
            active_count = 0,
            destroying_count = 0,
            unknown_state_count = 0,
            errors = bucket.errors,
            samples = {},
        }
        for object_index = 1, #bucket.live do
            local obj = bucket.live[object_index]
            local state_text = actor_state_text(obj)
            if state_text == "destroying" then
                entry.destroying_count = entry.destroying_count + 1
            elseif state_text == "active" then
                entry.active_count = entry.active_count + 1
            else
                entry.unknown_state_count = entry.unknown_state_count + 1
            end
            local key = object_key(obj)
            local unique = unique_by_key[key]
            if not unique then
                unique = { name = safe_name(obj), full_name = safe_full_name(obj), state = state_text, classes = {} }
                unique_by_key[key] = unique
                unique_order[#unique_order + 1] = unique
            elseif unique.state ~= "destroying" then
                if state_text == "destroying" or unique.state == "unknown" then unique.state = state_text end
            end
            unique.classes[#unique.classes + 1] = spec.key
        end
        total_active = total_active + entry.active_count + entry.unknown_state_count
        total_destroying = total_destroying + entry.destroying_count
        report.classes[#report.classes + 1] = entry
        lines[#lines + 1] = string.format("  %s: found=%d active=%d destroying=%d unknown=%d default=%d", spec.key, entry.found_count, entry.active_count, entry.destroying_count, entry.unknown_state_count, entry.default_count)
        for error_index = 1, #bucket.errors do
            lines[#lines + 1] = "    error: " .. tostring(bucket.errors[error_index])
        end
        local max_sample = math.min(#bucket.live, sample_limit)
        for index = 1, max_sample do
            local obj = bucket.live[index]
            local full_name = safe_full_name(obj)
            local state_text = actor_state_text(obj)
            local sample = {
                index = index,
                name = name_from_full_name(full_name),
                full_name = full_name,
                state = state_text,
            }
            entry.samples[#entry.samples + 1] = sample
            lines[#lines + 1] = string.format("    [%d] %s state=%s full=%s", index, sample.name, sample.state, sample.full_name)
        end
        if #bucket.live > max_sample then
            lines[#lines + 1] = string.format("    ... +%d more; pass a larger limit up to %d", #bucket.live - max_sample, MAX_SAMPLE_LIMIT)
        end
    end
    local unique_active = 0
    local unique_destroying = 0
    local unique_unknown = 0
    local unique_samples = {}
    for index = 1, #unique_order do
        local unique = unique_order[index]
        if unique.state == "destroying" then
            unique_destroying = unique_destroying + 1
        elseif unique.state == "active" then
            unique_active = unique_active + 1
        else
            unique_unknown = unique_unknown + 1
        end
        if #unique_samples < sample_limit then
            local sample = { index = index, name = unique.name, full_name = unique.full_name, state = unique.state, classes = unique.classes }
            unique_samples[#unique_samples + 1] = sample
        end
    end
    report.unique = { found_count = #unique_order, active_count = unique_active, destroying_count = unique_destroying, unknown_state_count = unique_unknown, samples = unique_samples }
    lines[#lines + 1] = string.format("  unique: found=%d active=%d destroying=%d unknown=%d", #unique_order, unique_active, unique_destroying, unique_unknown)
    for index = 1, #unique_samples do
        local sample = unique_samples[index]
        lines[#lines + 1] = string.format("    [%d] %s state=%s classes=%s full=%s", sample.index, sample.name, sample.state, table.concat(sample.classes, ","), sample.full_name)
    end
    if #unique_order > #unique_samples then
        lines[#lines + 1] = string.format("    ... +%d more unique actors; pass a larger limit up to %d", #unique_order - #unique_samples, MAX_SAMPLE_LIMIT)
    end
    report.current_class = "complete"
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_generated_state", report, lines)
    local detail = string.format("classes=%d active=%d destroying=%d unique_active=%d unique_destroying=%d", #GENERATED_OBJECT_SPECS, total_active, total_destroying, unique_active, unique_destroying)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_spawners(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.spawners [limit] confirm"
    if #tokens < 1 or #tokens > 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    local sample_limit = GENERATED_SPAWNER_DEFAULT_LIMIT
    if #tokens == 2 then
        sample_limit = tonumber(tokens[1])
        if not sample_limit then return false, "limit must be a number" end
    end
    sample_limit = math.floor(sample_limit)
    if sample_limit < 1 or sample_limit > GENERATED_SPAWNER_MAX_LIMIT then
        return false, string.format("limit must be in range 1..%d", GENERATED_SPAWNER_MAX_LIMIT)
    end

    local bucket = find_objects({ "DungeonSpawner" })
    local sampled_count = math.min(#bucket.live, sample_limit)
    local report = {
        command = "world.dungeon.proc.generated.spawners",
        confirmed = true,
        sample_limit = sample_limit,
        total_count = #bucket.live,
        default_count = #bucket.defaults,
        sampled_count = sampled_count,
        sampled_all = sampled_count == #bucket.live,
        metadata_only = true,
        counts = { enemy = 0, chest = 0, miniboss = 0, other = 0 },
        errors = bucket.errors,
        samples = {},
        current_index = 0,
        note = "Metadata-only DungeonSpawner inventory; UObject names only, with no reflected field reads and no method lookup or invocation",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.spawners --",
        "  note: metadata-only DungeonSpawner inventory; no reflected field reads and no method lookup or invocation",
        string.format("  found=%d default=%d sample_limit=%d", #bucket.live, #bucket.defaults, sample_limit),
    }

    local function spawner_kind(label)
        local lowered = tostring(label or ""):lower()
        if lowered:find("minibossspawner", 1, true) then return "miniboss" end
        if lowered:find("chestspawner", 1, true) then return "chest" end
        if lowered:find("enemyspawner", 1, true) then return "enemy" end
        return "other"
    end

    for error_index = 1, #bucket.errors do
        lines[#lines + 1] = "  error: " .. tostring(bucket.errors[error_index])
    end
    for index, obj in ipairs(bucket.live) do
        report.current_index = index
        write_report_files("dungeon_proc_generated_spawners_attempt", report, lines)
        local full_name = safe_full_name(obj)
        local class_name = tostring(full_name):match("^([^%s]+)") or ""
        local name = name_from_full_name(full_name)
        local kind = spawner_kind(full_name)
        report.counts[kind] = (report.counts[kind] or 0) + 1
        if index <= sampled_count then
            local entry = {
                index = index,
                name = name,
                class = class_name,
                full_name = full_name,
                kind = kind,
            }
            report.samples[#report.samples + 1] = entry
            lines[#lines + 1] = string.format("  [%d] %s [%s] kind=%s full=%s", index, entry.name, entry.class, entry.kind, entry.full_name)
        end
    end
    if #bucket.live > sampled_count then
        lines[#lines + 1] = string.format("  ... +%d more spawners; pass a larger limit up to %d", #bucket.live - sampled_count, GENERATED_SPAWNER_MAX_LIMIT)
    end
    report.current_index = 0
    lines[#lines + 1] = string.format("  summary enemy=%d chest=%d miniboss=%d other=%d sampled=%d/%d", report.counts.enemy, report.counts.chest, report.counts.miniboss, report.counts.other, sampled_count, #bucket.live)
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_generated_spawners", report, lines)
    local detail = string.format("enemy=%d chest=%d miniboss=%d other=%d sampled=%d/%d metadata_only=true", report.counts.enemy, report.counts.chest, report.counts.miniboss, report.counts.other, sampled_count, #bucket.live)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_populationplan(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.populationplan [latest] confirm"
    if #tokens < 1 or #tokens > 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    if #tokens == 2 and tokens[1] ~= "latest" then return false, usage end

    local latest = generated_spawn_cache.latest_connected
    if not latest then
        return false, "no latest smart connected spawn is cached; run world.dungeon.proc.generator.spawnconnected first"
    end

    local function count_map_text(counts)
        local keys = {}
        for key, _count in pairs(counts or {}) do keys[#keys + 1] = key end
        table.sort(keys)
        if #keys == 0 then return "none" end
        local parts = {}
        for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. tostring(counts[key]) end
        return table.concat(parts, " ")
    end

    local markers = latest.population_markers or {}
    local marker_counts = latest.population_marker_counts or {}
    local structural_roles = latest.structural_roles or CONNECTED_SMART.structural_role_plan
    local report = {
        command = "world.dungeon.proc.generated.populationplan",
        confirmed = true,
        scope = "latest",
        batch = latest.batch or 0,
        seed = latest.seed or 0,
        mode = latest.mode or "",
        source = "archive_child_actor_component_projected_by_spawnconnected",
        note = "Static-authored projected world-space marker plan; no live spawner field reads or native spawn calls.",
        marker_counts = marker_counts,
        markers = markers,
        structural_roles = structural_roles,
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.populationplan --",
        string.format("  batch=%s seed=%s mode=%s markers=%s", tostring(report.batch), tostring(report.seed), tostring(report.mode), tostring(#markers)),
        "  marker_counts " .. count_map_text(marker_counts),
        "  source " .. report.source,
        "  note " .. report.note,
        string.format("  direct_actor_spawn_offsets enemy_z_cm=%d", CONNECTED_SMART_ENEMY_DIRECT_ACTOR_SPAWN_Z_OFFSET_CM),
    }
    for _, role in ipairs(structural_roles) do
        lines[#lines + 1] = string.format(
            "  structural_role %s=%s status=%s reason=%s connector_hint=%s",
            role.role or "",
            role.key or "",
            role.status or "",
            role.reason or "",
            role.connector_hint or ""
        )
    end
    for _, marker in ipairs(markers) do
        local direct_actor_spawn = ""
        if marker.direct_actor_spawn_location_text and marker.direct_actor_spawn_location_text ~= "" then
            direct_actor_spawn = string.format(
                " direct_actor_spawn_loc=%s direct_actor_spawn_z_offset_cm=%.1f",
                marker.direct_actor_spawn_location_text or "",
                tonumber(marker.direct_actor_spawn_z_offset_cm) or 0
            )
        end
        lines[#lines + 1] = string.format(
            "  marker[%s] room[%s]=%s kind=%s marker=%s class=%s loc=%s yaw=%.3f%s source=%s",
            tostring(marker.index or ""),
            tostring(marker.room_index or ""),
            marker.room_key or "",
            marker.kind or "",
            marker.marker_name or "",
            marker.class_name or "",
            marker.world_location_text or "",
            tonumber(marker.world_yaw) or 0,
            direct_actor_spawn,
            marker.source or ""
        )
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_generated_populationplan", report, lines)
    local detail = string.format(
        "batch=%s enemy=%s chest=%s resource=%s markers=%s",
        tostring(report.batch),
        tostring(marker_counts.enemy or 0),
        tostring(marker_counts.chest or 0),
        tostring(marker_counts.resource or 0),
        tostring(#markers)
    )
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function GENERATED_BOSSROOM_PROBE.keyword_hits(text)
    local lowered = tostring(text or ""):lower()
    local hits = {}
    for _keyword_index, keyword in ipairs(GENERATED_BOSSROOM_PROBE.keywords) do
        if lowered:find(keyword, 1, true) then hits[#hits + 1] = keyword end
    end
    return hits
end

function GENERATED_BOSSROOM_PROBE.location(obj)
    local loc = nil
    pcall(function() loc = feature_actor.actor_location(obj) end)
    loc = GENERATED_ACTOR_PROBE.vector_copy(loc)
    if not loc then return nil, "" end
    return loc, vec_text(loc)
end

function GENERATED_BOSSROOM_PROBE.distance(left, right)
    local distance_sq = GENERATED_ACTOR_PROBE.distance_sq(left, right)
    if not distance_sq then return nil end
    return math.sqrt(distance_sq)
end

function GENERATED_BOSSROOM_PROBE.component_location(component)
    if not is_valid(component) then return nil, "" end
    local loc = nil
    if component.K2_GetComponentLocation then
        pcall(function() loc = component:K2_GetComponentLocation() end)
    end
    if not loc and component.GetComponentLocation then
        pcall(function() loc = component:GetComponentLocation() end)
    end
    loc = GENERATED_ACTOR_PROBE.vector_copy(loc)
    if not loc then return nil, "" end
    return loc, vec_text(loc)
end

function GENERATED_BOSSROOM_PROBE.component_rotation(component)
    if not is_valid(component) then return nil, "" end
    local rot = nil
    if component.K2_GetComponentRotation then
        pcall(function() rot = component:K2_GetComponentRotation() end)
    end
    if not rot and component.GetComponentRotation then
        pcall(function() rot = component:GetComponentRotation() end)
    end
    rot = GENERATED_BOSSROOM_PROBE.rotation_copy(rot)
    if not rot then return nil, "" end
    return rot, GENERATED_BOSSROOM_PROBE.rotation_text(rot)
end

function GENERATED_BOSSROOM_PROBE.component_sample(actor, class_path, label, sample_limit)
    local entry = { label = label, class_path = class_path, ok = false, count = 0, sampled = 0, keyword_count = 0, samples = {}, keyword_samples = {}, error = "" }
    local class_obj = player_core.resolve_uclass(class_path)
    if not is_valid(class_obj) then
        entry.error = "class resolve failed"
        return entry
    end
    if not actor.K2_GetComponentsByClass then
        entry.error = "K2_GetComponentsByClass missing"
        return entry
    end
    local ok, value = pcall(function() return actor:K2_GetComponentsByClass(class_obj) end)
    if not ok then
        entry.error = first_error_line(value)
        return entry
    end
    entry.ok = true
    entry.count = container_count(value) or 0
    local max_sample = math.min(entry.count, math.floor(tonumber(sample_limit) or GENERATED_BOSSROOM_PROBE.component_sample_limit))
    for index = 1, max_sample do
        local component = container_item(value, index)
        local full_name = safe_full_name(component)
        local name = safe_name(component)
        local class_name = safety.class_name_of(component) or ""
        local _loc, loc_text = GENERATED_BOSSROOM_PROBE.component_location(component)
        local hits = GENERATED_BOSSROOM_PROBE.keyword_hits(name .. " " .. class_name .. " " .. full_name)
        local sample = {
            index = index,
            name = name,
            class = class_name,
            full_name = full_name,
            location = loc_text,
            keyword_hits = hits,
        }
        entry.samples[#entry.samples + 1] = sample
        if #hits > 0 then
            entry.keyword_count = entry.keyword_count + 1
            entry.keyword_samples[#entry.keyword_samples + 1] = sample
        end
    end
    entry.sampled = #entry.samples
    return entry
end

function GENERATED_BOSSROOM_PROBE.opening_text(opening)
    if not opening then return "<none>" end
    local parts = {
        tostring(opening.side or "?"),
        "cell=" .. tostring(opening.cell_x or "?") .. "," .. tostring(opening.cell_y or "?"),
        "src=" .. tostring(opening.source_cell_x or opening.source_x or "?") .. "," .. tostring(opening.source_cell_y or opening.source_y or "?"),
        "wall_z=" .. tostring(opening.wall_z_cm or 0),
        "yaw=" .. tostring(opening.wall_yaw or 0),
    }
    if opening.connector_kind and opening.connector_kind ~= "" then parts[#parts + 1] = "kind=" .. tostring(opening.connector_kind) end
    if opening.openwalls_skip == true then parts[#parts + 1] = "openwalls_skip=true" end
    return table.concat(parts, " ")
end

function GENERATED_BOSSROOM_PROBE.node_summary(node)
    if not node then return {} end
    return {
        index = node.index or 0,
        key = node.key or "",
        category = node.category or "",
        grid = { x = node.cell_x or 0, y = node.cell_y or 0 },
        z_cm = node.z_cm or 0,
        yaw = node.room_yaw or 0,
        parent = node.parent or 0,
        depth = node.depth or 0,
        links = node.links or 0,
        max_links = node.max_links or 0,
        cell_count = node.cell_count or 0,
        opening_count = node.opening_count or 0,
    }
end

function GENERATED_BOSSROOM_PROBE.rotation_copy(value)
    if not value then return nil end
    local pitch_value, yaw_value, roll_value = nil, nil, nil
    pcall(function() pitch_value = tonumber(value.Pitch) end)
    pcall(function() yaw_value = tonumber(value.Yaw) end)
    pcall(function() roll_value = tonumber(value.Roll) end)
    if pitch_value == nil or yaw_value == nil or roll_value == nil then return nil end
    return { Pitch = pitch_value, Yaw = yaw_value, Roll = roll_value }
end

function GENERATED_BOSSROOM_PROBE.rotation_text(rot)
    if not rot then return "" end
    return string.format("%.1f,%.1f,%.1f", tonumber(rot.Pitch) or 0, tonumber(rot.Yaw) or 0, tonumber(rot.Roll) or 0)
end

function GENERATED_BOSSROOM_PROBE.value_text(value)
    local vector = GENERATED_ACTOR_PROBE.vector_copy(value)
    if vector then return vec_text(vector) end
    local rotation = GENERATED_BOSSROOM_PROBE.rotation_copy(value)
    if rotation then return GENERATED_BOSSROOM_PROBE.rotation_text(rotation) end
    if value == nil then return "" end
    return value_label(value)
end

function GENERATED_BOSSROOM_PROBE.optional_call(obj, method_name)
    local entry = { method = method_name, present = false, value_type = "", ok = false, value = "", error = "" }
    if not is_valid(obj) then
        entry.error = "invalid object"
        return entry
    end
    local method_ok, method_or_error = pcall(function() return obj[method_name] end)
    if not method_ok then
        entry.error = first_error_line(method_or_error)
        return entry
    end
    entry.present = true
    entry.value_type = type(method_or_error)
    if entry.value_type ~= "function" and entry.value_type ~= "userdata" then return entry end
    local call_ok, value_or_error = pcall(function() return method_or_error(obj) end)
    entry.ok = call_ok == true
    if call_ok then
        entry.value = GENERATED_BOSSROOM_PROBE.value_text(value_or_error)
    else
        entry.error = first_error_line(value_or_error)
    end
    return entry
end

function GENERATED_BOSSROOM_PROBE.component_state(component)
    local loc, loc_text = GENERATED_BOSSROOM_PROBE.component_location(component)
    local rotation = nil
    if is_valid(component) then
        if component.K2_GetComponentRotation then pcall(function() rotation = component:K2_GetComponentRotation() end) end
        if not rotation and component.GetComponentRotation then pcall(function() rotation = component:GetComponentRotation() end) end
    end
    local scale = nil
    if is_valid(component) then
        if component.K2_GetComponentScale then pcall(function() scale = component:K2_GetComponentScale() end) end
        if not scale and component.GetComponentScale then pcall(function() scale = component:GetComponentScale() end) end
    end
    local relative_loc = GENERATED_BOSSROOM_PROBE.optional_call(component, "K2_GetRelativeLocation")
    if relative_loc.present ~= true then relative_loc = GENERATED_BOSSROOM_PROBE.optional_call(component, "GetRelativeLocation") end
    local relative_rot = GENERATED_BOSSROOM_PROBE.optional_call(component, "K2_GetRelativeRotation")
    if relative_rot.present ~= true then relative_rot = GENERATED_BOSSROOM_PROBE.optional_call(component, "GetRelativeRotation") end
    return {
        name = safe_name(component),
        class = safety.class_name_of(component) or "",
        full_name = safe_full_name(component),
        location = loc_text,
        loc = loc and { x = loc.X, y = loc.Y, z = loc.Z } or nil,
        rotation = GENERATED_BOSSROOM_PROBE.rotation_text(GENERATED_BOSSROOM_PROBE.rotation_copy(rotation)),
        scale = vec_text(GENERATED_ACTOR_PROBE.vector_copy(scale)),
        relative_location = relative_loc.value,
        relative_rotation = relative_rot.value,
        visible = GENERATED_BOSSROOM_PROBE.optional_call(component, "IsVisible"),
        hidden_in_game = GENERATED_BOSSROOM_PROBE.optional_call(component, "IsHiddenInGame"),
        active = GENERATED_BOSSROOM_PROBE.optional_call(component, "IsActive"),
        collision = GENERATED_BOSSROOM_PROBE.optional_call(component, "GetCollisionEnabled"),
    }
end

function GENERATED_BOSSROOM_PROBE.components_of_class(actor, class_path)
    local result = { ok = false, count = 0, components = {}, error = "" }
    local class_obj = player_core.resolve_uclass(class_path)
    if not is_valid(class_obj) then
        result.error = "class resolve failed"
        return result
    end
    if not actor.K2_GetComponentsByClass then
        result.error = "K2_GetComponentsByClass missing"
        return result
    end
    local ok, value = pcall(function() return actor:K2_GetComponentsByClass(class_obj) end)
    if not ok then
        result.error = first_error_line(value)
        return result
    end
    result.ok = true
    result.count = container_count(value) or 0
    for index = 1, math.min(result.count, GENERATED_BOSSROOM_PROBE.component_sample_limit) do
        local component = container_item(value, index)
        if is_valid(component) then result.components[#result.components + 1] = component end
    end
    return result
end

function GENERATED_BOSSROOM_PROBE.focused_components(actor)
    local wanted = {}
    for _index, name in ipairs(GENERATED_BOSSROOM_PROBE.snapshot_component_names) do wanted[tostring(name):lower()] = true end
    local collected = {}
    local seen = {}
    local classes = {
        "/Script/Engine.ActorComponent",
        "/Script/Engine.SceneComponent",
        "/Script/Engine.StaticMeshComponent",
        "/Script/Engine.InstancedStaticMeshComponent",
        "/Script/Engine.ChildActorComponent",
    }
    for _class_index, class_path in ipairs(classes) do
        local bucket = GENERATED_BOSSROOM_PROBE.components_of_class(actor, class_path)
        for _component_index, component in ipairs(bucket.components or {}) do
            local key = object_key(component)
            if not seen[key] then
                local name = safe_name(component)
                local haystack = (name .. " " .. safe_full_name(component)):lower()
                local include = wanted[name:lower()] == true
                if not include then
                    for wanted_name, _enabled in pairs(wanted) do
                        if haystack:find(wanted_name, 1, true) then include = true break end
                    end
                end
                if include then
                    seen[key] = true
                    collected[#collected + 1] = GENERATED_BOSSROOM_PROBE.component_state(component)
                end
            end
        end
    end
    table.sort(collected, function(left, right) return tostring(left.name or "") < tostring(right.name or "") end)
    return collected
end

function GENERATED_BOSSROOM_PROBE.resolve_latest()
    local latest = generated_spawn_cache.latest_connected
    if not latest or not latest.layout then
        return nil, nil, nil, nil, "no latest smart connected spawn is cached; run world.dungeon.proc.generator.spawnconnected first after each game reload"
    end
    local layout = latest.layout
    local boss_node = nil
    for _node_index, node in ipairs(layout.nodes or {}) do
        if tostring(node.key or ""):lower() == "bossroom" then
            boss_node = node
            break
        end
    end
    if not boss_node then return latest, layout, nil, nil, "latest smart layout has no bossroom node; request at least the required-variety room count" end
    local room_state = (latest.rooms or {})[boss_node.index or 0] or {}
    local boss_actor = room_state.actor
    if not is_valid(boss_actor) then
        local bucket = find_objects({ "BP_BossRoom_C", "BossRoom" })
        if #bucket.live > 0 and is_valid(bucket.live[1]) then boss_actor = bucket.live[1] end
    end
    if not is_valid(boss_actor) then return latest, layout, boss_node, nil, "bossroom actor unavailable; run in the same Lua session as spawnconnected" end
    return latest, layout, boss_node, boss_actor, nil
end

function GENERATED_BOSSROOM_PROBE.object_scan(actor_loc, specs)
    local scans = {}
    for _spec_index, spec in ipairs(specs or {}) do
        local bucket = find_objects(spec.queries)
        local scan = { key = spec.key, queries = spec.queries, found = #bucket.live, defaults = #bucket.defaults, matched = 0, sampled = 0, errors = bucket.errors, samples = {} }
        for object_index, obj in ipairs(bucket.live) do
            local full_name = safe_full_name(obj)
            local name = name_from_full_name(full_name)
            local class_name = safety.class_name_of(obj) or (tostring(full_name):match("^([^%s]+)") or "")
            local obj_loc, obj_loc_text = GENERATED_BOSSROOM_PROBE.location(obj)
            local distance = GENERATED_BOSSROOM_PROBE.distance(actor_loc, obj_loc)
            local hits = GENERATED_BOSSROOM_PROBE.keyword_hits(name .. " " .. class_name .. " " .. full_name)
            local include = spec.always_sample == true or #hits > 0 or (distance ~= nil and distance <= GENERATED_BOSSROOM_PROBE.near_distance_cm)
            if include then
                scan.matched = scan.matched + 1
                if scan.sampled < GENERATED_BOSSROOM_PROBE.object_sample_limit then
                    scan.samples[#scan.samples + 1] = {
                        index = object_index,
                        name = name,
                        class = class_name,
                        full_name = full_name,
                        location = obj_loc_text,
                        distance = distance,
                        keyword_hits = hits,
                    }
                    scan.sampled = scan.sampled + 1
                end
            end
        end
        scans[#scans + 1] = scan
    end
    return scans
end

function GENERATED_ENTRANCE_PROBE.keyword_hits(text)
    local lowered = tostring(text or ""):lower()
    local hits = {}
    for _keyword_index, keyword in ipairs(GENERATED_ENTRANCE_PROBE.keywords) do
        if lowered:find(keyword, 1, true) then hits[#hits + 1] = keyword end
    end
    return hits
end

function GENERATED_ENTRANCE_PROBE.world_from_local(room_node, origin, tile_step, local_loc)
    local scale = (tonumber(tile_step) or DUNGEON_TILE_SIZE_CM) / DUNGEON_TILE_SIZE_CM
    local yaw = tonumber(room_node and room_node.room_yaw) or 0
    local radians = math.rad(yaw)
    local cos_yaw = math.cos(radians)
    local sin_yaw = math.sin(radians)
    local local_x = (tonumber(local_loc and local_loc.X) or 0) * scale
    local local_y = (tonumber(local_loc and local_loc.Y) or 0) * scale
    local local_z = (tonumber(local_loc and local_loc.Z) or 0) * scale
    local rotated_x = (local_x * cos_yaw) - (local_y * sin_yaw)
    local rotated_y = (local_x * sin_yaw) + (local_y * cos_yaw)
    local room_z = (tonumber(room_node and room_node.z_cm) or 0) * scale
    return {
        X = (origin.X or 0) + ((room_node and room_node.cell_x) or 0) * (tonumber(tile_step) or DUNGEON_TILE_SIZE_CM) + rotated_x,
        Y = (origin.Y or 0) + ((room_node and room_node.cell_y) or 0) * (tonumber(tile_step) or DUNGEON_TILE_SIZE_CM) + rotated_y,
        Z = (origin.Z or 0) + room_z + local_z,
    }
end

function GENERATED_ENTRANCE_PROBE.component_sample(actor, class_path, label, sample_limit)
    local entry = { label = label, class_path = class_path, ok = false, count = 0, sampled = 0, keyword_count = 0, samples = {}, keyword_samples = {}, error = "" }
    local class_obj = player_core.resolve_uclass(class_path)
    if not is_valid(class_obj) then
        entry.error = "class resolve failed"
        return entry
    end
    if not actor.K2_GetComponentsByClass then
        entry.error = "K2_GetComponentsByClass missing"
        return entry
    end
    local ok, value = pcall(function() return actor:K2_GetComponentsByClass(class_obj) end)
    if not ok then
        entry.error = first_error_line(value)
        return entry
    end
    entry.ok = true
    entry.count = container_count(value) or 0
    local max_sample = math.min(entry.count, math.floor(tonumber(sample_limit) or GENERATED_ENTRANCE_PROBE.component_sample_limit))
    for index = 1, max_sample do
        local component = container_item(value, index)
        local full_name = safe_full_name(component)
        local name = safe_name(component)
        local class_name = safety.class_name_of(component) or ""
        local _loc, loc_text = GENERATED_BOSSROOM_PROBE.component_location(component)
        local hits = GENERATED_ENTRANCE_PROBE.keyword_hits(name .. " " .. class_name .. " " .. full_name)
        local sample = {
            index = index,
            name = name,
            class = class_name,
            full_name = full_name,
            location = loc_text,
            keyword_hits = hits,
        }
        entry.samples[#entry.samples + 1] = sample
        if #hits > 0 then
            entry.keyword_count = entry.keyword_count + 1
            entry.keyword_samples[#entry.keyword_samples + 1] = sample
        end
    end
    entry.sampled = #entry.samples
    return entry
end

function GENERATED_ENTRANCE_PROBE.object_scan(actor_loc, specs)
    local scans = {}
    for _spec_index, spec in ipairs(specs or {}) do
        local bucket = find_objects(spec.queries)
        local scan = { key = spec.key, queries = spec.queries, found = #bucket.live, defaults = #bucket.defaults, matched = 0, sampled = 0, errors = bucket.errors, samples = {} }
        for object_index, obj in ipairs(bucket.live) do
            local full_name = safe_full_name(obj)
            local name = name_from_full_name(full_name)
            local class_name = safety.class_name_of(obj) or (tostring(full_name):match("^([^%s]+)") or "")
            local obj_loc, obj_loc_text = GENERATED_BOSSROOM_PROBE.location(obj)
            local distance = GENERATED_BOSSROOM_PROBE.distance(actor_loc, obj_loc)
            local hits = GENERATED_ENTRANCE_PROBE.keyword_hits(name .. " " .. class_name .. " " .. full_name)
            local include = spec.always_sample == true or #hits > 0 or (distance ~= nil and distance <= GENERATED_ENTRANCE_PROBE.near_distance_cm)
            if include then
                scan.matched = scan.matched + 1
                if scan.sampled < GENERATED_ENTRANCE_PROBE.object_sample_limit then
                    scan.samples[#scan.samples + 1] = {
                        index = object_index,
                        name = name,
                        class = class_name,
                        full_name = full_name,
                        location = obj_loc_text,
                        distance = distance,
                        keyword_hits = hits,
                    }
                    scan.sampled = scan.sampled + 1
                end
            end
        end
        scans[#scans + 1] = scan
    end
    return scans
end

function GENERATED_ENTRANCE_PROBE.midpoint(left, right)
    if not left or not right then return nil end
    return {
        X = ((left.X or 0) + (right.X or 0)) * 0.5,
        Y = ((left.Y or 0) + (right.Y or 0)) * 0.5,
        Z = ((left.Z or 0) + (right.Z or 0)) * 0.5,
    }
end

function GENERATED_ENTRANCE_PROBE.normalize_yaw(yaw)
    return ((tonumber(yaw) or 0) + 180) % 360 - 180
end

function GENERATED_ENTRANCE_PROBE.rotate_xy(x_value, y_value, yaw)
    local radians = math.rad(tonumber(yaw) or 0)
    local cos_yaw = math.cos(radians)
    local sin_yaw = math.sin(radians)
    local x_cm = tonumber(x_value) or 0
    local y_cm = tonumber(y_value) or 0
    return {
        X = (x_cm * cos_yaw) - (y_cm * sin_yaw),
        Y = (x_cm * sin_yaw) + (y_cm * cos_yaw),
    }
end

function GENERATED_ENTRANCE_PROBE.resolve_latest()
    local latest = generated_spawn_cache.latest_connected
    if not latest or not latest.layout then
        return nil, nil, nil, nil, nil, nil, false, "no latest smart connected spawn is cached; run world.dungeon.proc.generator.spawnconnected first after each game reload"
    end
    local layout = latest.layout
    local entrance_node = nil
    for _node_index, node in ipairs(layout.nodes or {}) do
        local key = tostring(node.key or ""):lower()
        local category = tostring(node.category or ""):lower()
        if key == "entranceroom_v6" or category == "entrance" then
            entrance_node = node
            break
        end
    end
    if not entrance_node then
        return latest, layout, nil, nil, latest.origin or CONNECTED_SMART.default_origin, tonumber(latest.tile_step) or DUNGEON_TILE_SIZE_CM, false, "latest smart layout has no entrance node; verify entranceroom_v6 special connector is active and rerun spawnconnected"
    end

    local room_state = (latest.rooms or {})[entrance_node.index or 0] or {}
    local entrance_actor = room_state.actor
    local fallback_used = false
    if not is_valid(entrance_actor) then
        local bucket = find_objects({ "EntranceRoom_V6_C", "EntranceRoom_V6", "EntranceRoom" })
        if #bucket.live > 0 and is_valid(bucket.live[1]) then
            entrance_actor = bucket.live[1]
            fallback_used = true
        end
    end
    if not is_valid(entrance_actor) then
        return latest, layout, entrance_node, nil, latest.origin or CONNECTED_SMART.default_origin, tonumber(latest.tile_step) or DUNGEON_TILE_SIZE_CM, fallback_used, "entrance actor unavailable; run probe in the same Lua session as spawnconnected"
    end
    return latest, layout, entrance_node, entrance_actor, latest.origin or CONNECTED_SMART.default_origin, tonumber(latest.tile_step) or DUNGEON_TILE_SIZE_CM, fallback_used, nil
end

function GENERATED_ENTRANCE_PROBE.candidate_by_key(key)
    local lower = tostring(key or ""):lower()
    for _candidate_index, candidate in ipairs(GENERATED_ENTRANCE_PROBE.patch_candidates or {}) do
        if tostring(candidate.key or ""):lower() == lower then return candidate end
    end
    return nil
end

function GENERATED_ENTRANCE_PROBE.patch_selector_list()
    local values = {}
    for key, _group in pairs(GENERATED_ENTRANCE_PROBE.patch_candidate_groups or {}) do values[#values + 1] = key end
    for _candidate_index, candidate in ipairs(GENERATED_ENTRANCE_PROBE.patch_candidates or {}) do values[#values + 1] = candidate.key or "" end
    table.sort(values)
    return table.concat(values, ", ")
end

function GENERATED_ENTRANCE_PROBE.selected_patch_candidates(selector)
    local key = tostring(selector or ""):lower()
    if key == "" then key = "closures" end
    local selected = {}
    local group = (GENERATED_ENTRANCE_PROBE.patch_candidate_groups or {})[key]
    if group then
        for _group_index, candidate_key in ipairs(group) do
            local candidate = GENERATED_ENTRANCE_PROBE.candidate_by_key(candidate_key)
            if candidate then selected[#selected + 1] = candidate end
        end
        return selected, key, nil
    end
    local candidate = GENERATED_ENTRANCE_PROBE.candidate_by_key(key)
    if candidate then
        selected[#selected + 1] = candidate
        return selected, key, nil
    end
    return nil, key, "unknown entrance patch selector '" .. tostring(selector or "") .. "'; use one of: " .. GENERATED_ENTRANCE_PROBE.patch_selector_list()
end

function GENERATED_ENTRANCE_PROBE.patch_candidate_entry(room_node, origin, tile_step, candidate, z_offset_cm)
    local scale = (tonumber(tile_step) or DUNGEON_TILE_SIZE_CM) / DUNGEON_TILE_SIZE_CM
    local frame_center = GENERATED_ENTRANCE_PROBE.world_from_local(room_node, origin, tile_step, candidate.local_loc)
    frame_center.Z = (frame_center.Z or 0) + (tonumber(z_offset_cm) or 0)
    local world_frame_yaw = GENERATED_ENTRANCE_PROBE.normalize_yaw((tonumber(candidate.frame_yaw) or 0) + (tonumber(room_node and room_node.room_yaw) or 0))
    local actor_class_path = candidate.actor_class_path or GENERATED_ENTRANCE_PROBE.patch_actor_class_path
    local actor_mode = tostring(candidate.actor_mode or "frame_centered")
    local frame_relative_yaw = tonumber(candidate.actor_frame_relative_yaw)
    if frame_relative_yaw == nil then frame_relative_yaw = tonumber(GENERATED_ENTRANCE_PROBE.patch_actor_frame_relative_yaw) or 0 end
    local frame_offset = candidate.actor_frame_offset or GENERATED_ENTRANCE_PROBE.patch_actor_frame_offset or {}
    local actor_yaw = GENERATED_ENTRANCE_PROBE.normalize_yaw(world_frame_yaw - frame_relative_yaw)
    local actor_loc = nil
    if actor_mode == "direct" then
        actor_yaw = GENERATED_ENTRANCE_PROBE.normalize_yaw((tonumber(candidate.actor_yaw) or tonumber(candidate.frame_yaw) or 0) + (tonumber(room_node and room_node.room_yaw) or 0))
        local actor_offset = candidate.actor_offset or {}
        local rotated_actor_offset = GENERATED_ENTRANCE_PROBE.rotate_xy((tonumber(actor_offset.X) or 0) * scale, (tonumber(actor_offset.Y) or 0) * scale, actor_yaw)
        actor_loc = {
            X = (frame_center.X or 0) + (rotated_actor_offset.X or 0),
            Y = (frame_center.Y or 0) + (rotated_actor_offset.Y or 0),
            Z = (frame_center.Z or 0) + ((tonumber(actor_offset.Z) or 0) * scale),
        }
    else
        local rotated_offset = GENERATED_ENTRANCE_PROBE.rotate_xy((tonumber(frame_offset.X) or 0) * scale, (tonumber(frame_offset.Y) or 0) * scale, actor_yaw)
        actor_loc = {
            X = (frame_center.X or 0) - (rotated_offset.X or 0),
            Y = (frame_center.Y or 0) - (rotated_offset.Y or 0),
            Z = (frame_center.Z or 0) - ((tonumber(frame_offset.Z) or 0) * scale),
        }
    end
    local actor_rot = { Pitch = 0, Yaw = actor_yaw, Roll = 0 }
    return {
        key = candidate.key or "",
        group = candidate.group or "",
        label = candidate.label or "",
        source = candidate.source or "",
        notes = candidate.notes or "",
        local_location = vec_text(candidate.local_loc or {}),
        local_frame_yaw = tonumber(candidate.frame_yaw) or 0,
        frame_center = vec_text(frame_center),
        frame_center_loc = frame_center,
        frame_yaw = world_frame_yaw,
        actor_class_path = actor_class_path,
        actor_mode = actor_mode,
        actor_frame_relative_yaw = frame_relative_yaw,
        actor_frame_offset = vec_text(frame_offset),
        actor_offset = vec_text(candidate.actor_offset or {}),
        actor_location = vec_text(actor_loc),
        actor_loc = actor_loc,
        actor_rotation = GENERATED_BOSSROOM_PROBE.rotation_text(actor_rot),
        actor_rot = actor_rot,
        actor_yaw = actor_yaw,
        z_offset_cm = tonumber(z_offset_cm) or 0,
    }
end

function GENERATED_ENTRANCE_PROBE.method_surface_entry(obj, method_name)
    local entry = { name = method_name, present = false, value_type = "", callable = false, error = "" }
    if not is_valid(obj) then
        entry.error = "invalid object"
        return entry
    end
    local ok, value = pcall(function() return obj[method_name] end)
    if not ok then
        entry.error = first_error_line(value)
        return entry
    end
    entry.present = value ~= nil
    entry.value_type = type(value)
    entry.callable = entry.value_type == "function" or entry.value_type == "userdata"
    return entry
end

function GENERATED_ENTRANCE_PROBE.component_instance_patch_probe(actor, candidates, report, lines, result_line_index, file_stem)
    local results = {}
    for _field_index, field_spec in ipairs(GENERATED_ACTOR_PROBE.instance_component_fields.room or {}) do
        local entry = {
            field = field_spec.name or "",
            role = field_spec.role or "",
            ok = false,
            valid = false,
            component = {},
            methods = {},
            count = 0,
            sampled = 0,
            nearest = {},
            errors = {},
        }
        report.result = "about_to_patchprobe_component_" .. tostring(entry.field)
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)

        local read_ok, component_or_error = read_field(actor, field_spec.name)
        if not read_ok then
            entry.errors[#entry.errors + 1] = "read_field: " .. first_error_line(component_or_error)
            results[#results + 1] = entry
        else
            local component = unwrap(component_or_error)
            if not is_valid(component) then
                entry.errors[#entry.errors + 1] = "component invalid or nil"
                results[#results + 1] = entry
            else
                entry.valid = true
                entry.component = {
                    name = safe_name(component),
                    class = safety.class_name_of(component) or "",
                    full_name = safe_full_name(component),
                }
                for _method_index, method_name in ipairs({ "GetInstanceCount", "GetInstanceTransform", "AddInstance", "AddInstanceWorldSpace", "RemoveInstance" }) do
                    entry.methods[#entry.methods + 1] = GENERATED_ENTRANCE_PROBE.method_surface_entry(component, method_name)
                end
                local count_ok, count_or_error = pcall(function() return component:GetInstanceCount() end)
                if not count_ok then
                    entry.errors[#entry.errors + 1] = "GetInstanceCount: " .. first_error_line(count_or_error)
                    results[#results + 1] = entry
                else
                    entry.ok = true
                    local count = tonumber(count_or_error) or 0
                    if count < 0 then count = 0 end
                    entry.count = math.floor(count)
                    local sample_limit = math.min(entry.count, tonumber(GENERATED_ENTRANCE_PROBE.patch_instance_sample_limit) or 512)
                    entry.sampled = sample_limit
                    local nearest_by_key = {}
                    for _candidate_index, candidate_entry in ipairs(candidates or {}) do
                        nearest_by_key[candidate_entry.key or ""] = {
                            key = candidate_entry.key or "",
                            requested_frame_center = candidate_entry.frame_center or "",
                            index = -1,
                            location = "",
                            distance = nil,
                            distance_sq = nil,
                        }
                    end
                    local transform_error_count = 0
                    for instance_index = 0, sample_limit - 1 do
                        local loc, loc_error = GENERATED_ACTOR_PROBE.instance_location(component, instance_index)
                        if loc then
                            for _candidate_index, candidate_entry in ipairs(candidates or {}) do
                                local nearest = nearest_by_key[candidate_entry.key or ""]
                                local distance_sq = GENERATED_ACTOR_PROBE.distance_sq(loc, candidate_entry.frame_center_loc)
                                if nearest and distance_sq and (nearest.distance_sq == nil or distance_sq < nearest.distance_sq) then
                                    nearest.index = instance_index
                                    nearest.location = vec_text(loc)
                                    nearest.distance_sq = distance_sq
                                    nearest.distance = math.sqrt(distance_sq)
                                end
                            end
                        elseif transform_error_count < 6 then
                            entry.errors[#entry.errors + 1] = "GetInstanceTransform(" .. tostring(instance_index) .. "): " .. tostring(loc_error or "unknown")
                            transform_error_count = transform_error_count + 1
                        end
                    end
                    for _candidate_index, candidate_entry in ipairs(candidates or {}) do
                        entry.nearest[#entry.nearest + 1] = nearest_by_key[candidate_entry.key or ""]
                    end
                    results[#results + 1] = entry
                end
            end
        end
    end
    return results
end

function GENERATED_ENTRANCE_PROBE.parse_patch_args(args_str, allow_z_offset)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    if #tokens < 1 or tokens[#tokens] ~= "confirm" then return nil, "missing confirm" end
    local parsed = { selector = "closures", z_offset_cm = 0, scope = "latest", actor_kind = "door" }
    for index = 1, #tokens - 1 do
        local token = tostring(tokens[index] or "")
        local lower = token:lower()
        if lower == "latest" then
            parsed.scope = "latest"
        elseif lower == "door" or lower == "bp_dungeondoor" then
            parsed.actor_kind = "door"
        elseif allow_z_offset == true and tonumber(token) ~= nil then
            parsed.z_offset_cm = tonumber(token) or 0
        elseif token ~= "" then
            parsed.selector = lower
        end
    end
    return parsed, nil
end

function GENERATED_BOSSROOM_PROBE.runtime_snapshot(actor, phase)
    local actor_loc, actor_loc_text = GENERATED_BOSSROOM_PROBE.location(actor)
    return {
        phase = phase or "",
        actor = {
            name = safe_name(actor),
            class = safety.class_name_of(actor) or "",
            full_name = safe_full_name(actor),
            location = actor_loc_text,
            state = GENERATED_ACTOR_PROBE.actor_state(actor),
        },
        focused_components = GENERATED_BOSSROOM_PROBE.focused_components(actor),
        object_scans = GENERATED_BOSSROOM_PROBE.object_scan(actor_loc, GENERATED_BOSSROOM_PROBE.snapshot_object_specs),
    }
end

function GENERATED_BOSSROOM_PROBE.append_snapshot_lines(lines, snapshot, indent)
    indent = indent or "  "
    lines[#lines + 1] = string.format("%ssnapshot[%s] actor=%s loc=%s components=%d object_scans=%d", indent, snapshot.phase or "", (snapshot.actor or {}).name or "", (snapshot.actor or {}).location or "", #(snapshot.focused_components or {}), #(snapshot.object_scans or {}))
    for _component_index, component in ipairs(snapshot.focused_components or {}) do
        lines[#lines + 1] = string.format(
            "%s  comp %-22s loc=%s rel=%s rot=%s scale=%s visible=%s hidden=%s active=%s collision=%s",
            indent,
            component.name or "",
            component.location or "",
            component.relative_location or "",
            component.rotation or "",
            component.scale or "",
            ((component.visible or {}).present and (component.visible.value or "")) or "",
            ((component.hidden_in_game or {}).present and (component.hidden_in_game.value or "")) or "",
            ((component.active or {}).present and (component.active.value or "")) or "",
            ((component.collision or {}).present and (component.collision.value or "")) or "")
    end
    for _scan_index, scan in ipairs(snapshot.object_scans or {}) do
        lines[#lines + 1] = string.format("%s  objects %-20s found=%d matched=%d sampled=%d", indent, scan.key or "", scan.found or 0, scan.matched or 0, scan.sampled or 0)
        for index = 1, math.min(#(scan.samples or {}), 6) do
            local sample = scan.samples[index]
            lines[#lines + 1] = string.format("%s    obj[%03d] %s [%s] loc=%s dist=%s", indent, sample.index or 0, sample.name or "", sample.class or "", sample.location or "", sample.distance and string.format("%.1f", sample.distance) or "")
        end
    end
end

function GENERATED_BOSSROOM_PROBE.component_map(snapshot)
    local map = {}
    for _index, component in ipairs((snapshot or {}).focused_components or {}) do
        map[component.name or ""] = component
    end
    return map
end

function GENERATED_BOSSROOM_PROBE.snapshot_deltas(before, after)
    local deltas = {}
    local before_map = GENERATED_BOSSROOM_PROBE.component_map(before)
    local after_map = GENERATED_BOSSROOM_PROBE.component_map(after)
    for name, after_component in pairs(after_map) do
        local before_component = before_map[name]
        if before_component then
            local changes = {}
            for _field_index, field in ipairs({ "location", "relative_location", "rotation", "scale" }) do
                if tostring(before_component[field] or "") ~= tostring(after_component[field] or "") then
                    changes[#changes + 1] = string.format("%s:%s->%s", field, tostring(before_component[field] or ""), tostring(after_component[field] or ""))
                end
            end
            local before_visible = ((before_component.visible or {}).present and (before_component.visible.value or "")) or ""
            local after_visible = ((after_component.visible or {}).present and (after_component.visible.value or "")) or ""
            if before_visible ~= after_visible then changes[#changes + 1] = "visible:" .. before_visible .. "->" .. after_visible end
            local before_hidden = ((before_component.hidden_in_game or {}).present and (before_component.hidden_in_game.value or "")) or ""
            local after_hidden = ((after_component.hidden_in_game or {}).present and (after_component.hidden_in_game.value or "")) or ""
            if before_hidden ~= after_hidden then changes[#changes + 1] = "hidden:" .. before_hidden .. "->" .. after_hidden end
            local before_collision = ((before_component.collision or {}).present and (before_component.collision.value or "")) or ""
            local after_collision = ((after_component.collision or {}).present and (after_component.collision.value or "")) or ""
            if before_collision ~= after_collision then changes[#changes + 1] = "collision:" .. before_collision .. "->" .. after_collision end
            if #changes > 0 then
                deltas[#deltas + 1] = { name = name, changes = changes }
            end
        else
            deltas[#deltas + 1] = { name = name, changes = { "added" } }
        end
    end
    for name, _before_component in pairs(before_map) do
        if not after_map[name] then deltas[#deltas + 1] = { name = name, changes = { "removed" } } end
    end
    table.sort(deltas, function(left, right) return tostring(left.name or "") < tostring(right.name or "") end)
    return deltas
end

function GENERATED_BOSSROOM_PROBE.named_component_handles(actor, names)
    local wanted = {}
    for _index, name in ipairs(names or {}) do wanted[tostring(name or ""):lower()] = true end
    local found = {}
    local seen = {}
    local classes = {
        "/Script/Engine.StaticMeshComponent",
        "/Script/Engine.SceneComponent",
        "/Script/Engine.ActorComponent",
    }
    for _class_index, class_path in ipairs(classes) do
        local bucket = GENERATED_BOSSROOM_PROBE.components_of_class(actor, class_path)
        for _component_index, component in ipairs(bucket.components or {}) do
            local key = object_key(component)
            local name = safe_name(component)
            if wanted[name:lower()] == true and not seen[key] then
                seen[key] = true
                found[#found + 1] = component
            end
        end
    end
    table.sort(found, function(left, right) return safe_name(left) < safe_name(right) end)
    return found
end

function GENERATED_BOSSROOM_PROBE.component_mutation_action(component, action_name, call_fn)
    local entry = {
        component = safe_name(component),
        component_full_name = safe_full_name(component),
        action = action_name,
        ok = false,
        error = "",
    }
    local ok, err = pcall(call_fn)
    entry.ok = ok == true
    if not ok then entry.error = first_error_line(err) end
    return entry
end

function GENERATED_BOSSROOM_PROBE.unlock_gate_component(component)
    local result = {
        component = safe_name(component),
        class = safety.class_name_of(component) or "",
        full_name = safe_full_name(component),
        actions = {},
        ok_count = 0,
        fail_count = 0,
    }
    local function append(action_name, call_fn)
        local action = GENERATED_BOSSROOM_PROBE.component_mutation_action(component, action_name, call_fn)
        result.actions[#result.actions + 1] = action
        if action.ok then result.ok_count = result.ok_count + 1 else result.fail_count = result.fail_count + 1 end
    end
    if component.SetVisibility then append("SetVisibility(false,true)", function() component:SetVisibility(false, true) end) end
    if component.SetHiddenInGame then append("SetHiddenInGame(true,true)", function() component:SetHiddenInGame(true, true) end) end
    if component.SetCollisionEnabled then append("SetCollisionEnabled(NoCollision=0)", function() component:SetCollisionEnabled(0) end) end
    if component.SetComponentTickEnabled then append("SetComponentTickEnabled(false)", function() component:SetComponentTickEnabled(false) end) end
    if #result.actions == 0 then
        result.fail_count = 1
        result.actions[#result.actions + 1] = {
            component = result.component,
            component_full_name = result.full_name,
            action = "no known component mutation methods",
            ok = false,
            error = "no SetVisibility/SetHiddenInGame/SetCollisionEnabled/SetComponentTickEnabled method surface",
        }
    end
    return result
end

function GENERATED_BOSSROOM_PROBE.actor_entry(actor)
    return {
        name = safe_name(actor),
        class = safety.class_name_of(actor) or "",
        full_name = safe_full_name(actor),
        location = object_location_text(actor),
    }
end

function GENERATED_BOSSROOM_PROBE.actor_rotation(actor)
    if not is_valid(actor) then return nil, "" end
    local rot = nil
    if actor.K2_GetActorRotation then pcall(function() rot = actor:K2_GetActorRotation() end) end
    rot = GENERATED_BOSSROOM_PROBE.rotation_copy(rot)
    if not rot then return nil, "" end
    return rot, GENERATED_BOSSROOM_PROBE.rotation_text(rot)
end

function GENERATED_BOSSROOM_PROBE.resolve_boss_class_spec(value)
    local token = trim(value)
    if token == "" then token = GENERATED_BOSSROOM_DEFAULT_BOSS_ALIAS end
    local lower = token:lower()
    local alias = GENERATED_BOSSROOM_BOSS_CLASS_ALIASES[lower]
    if alias then
        return {
            alias = lower,
            label = alias.label,
            class_path = alias.class_path,
        }, nil
    end
    if token:sub(1, 1) == "/" then
        return {
            alias = "",
            label = name_from_full_name(token),
            class_path = token,
        }, nil
    end
    local aliases = {}
    for alias_key, _alias_value in pairs(GENERATED_BOSSROOM_BOSS_CLASS_ALIASES) do aliases[#aliases + 1] = alias_key end
    table.sort(aliases)
    return nil, "unknown boss class alias '" .. token .. "'; use one of: " .. table.concat(aliases, ", ") .. " ; or pass a full class path"
end

function GENERATED_BOSSROOM_PROBE.boss_spawn_point(actor)
    local points = GENERATED_BOSSROOM_PROBE.named_component_handles(actor, { "BossSpawnPoint" })
    if #points == 0 then return nil, "BossSpawnPoint component not found on bossroom actor" end
    local point = points[1]
    local loc, loc_text = GENERATED_BOSSROOM_PROBE.component_location(point)
    if not loc then return nil, "BossSpawnPoint location unavailable" end
    local rot, rot_text = GENERATED_BOSSROOM_PROBE.component_rotation(point)
    if not rot then
        rot, rot_text = GENERATED_BOSSROOM_PROBE.actor_rotation(actor)
    end
    if not rot then
        rot = { Pitch = 0, Yaw = 180, Roll = 0 }
        rot_text = GENERATED_BOSSROOM_PROBE.rotation_text(rot)
    end
    return {
        component = point,
        name = safe_name(point),
        full_name = safe_full_name(point),
        location = loc,
        location_text = loc_text,
        rotation = rot,
        rotation_text = rot_text,
    }, nil
end

function GENERATED_BOSSROOM_PROBE.spawn_actor_deferred(class_path, spawn_loc, spawn_rot)
    local uclass = player_core.resolve_uclass(class_path)
    if not is_valid(uclass) then return nil, "could not resolve class: " .. tostring(class_path) end

    local feature_net = require("feature_net")
    local pc = feature_net.local_controller()
    if not pc then return nil, "no player controller" end

    local gpl = get_gameplay_statics()
    if not gpl then return nil, "GameplayStatics CDO not found" end
    local begin_deferred_spawn = gpl["BeginDeferredActorSpawnFromClass"]
    if not begin_deferred_spawn then return nil, "BeginDeferredActorSpawnFromClass missing" end
    local finish_spawning_actor = gpl["FinishSpawningActor"]
    if not finish_spawning_actor then return nil, "FinishSpawningActor missing" end

    local spawn_xform = spawn_xform_at_transform(spawn_loc, spawn_rot, { X = 1, Y = 1, Z = 1 })
    local actor = nil
    local begin_ok, begin_error = pcall(function()
        actor = begin_deferred_spawn(gpl, pc, uclass, spawn_xform, 2, pc, 0)
    end)
    if not begin_ok then return nil, "BeginDeferredActorSpawnFromClass trapped: " .. tostring(begin_error) end
    if not is_valid(actor) then return nil, "BeginDeferredActorSpawnFromClass returned invalid actor" end

    pcall(function() actor["bRegisterAsRuntimeSpawned"] = true end)
    local finish_ok, finish_error = pcall(function()
        finish_spawning_actor(gpl, actor, spawn_xform, 0)
    end)
    if not finish_ok then return nil, "FinishSpawningActor trapped: " .. tostring(finish_error) end
    pcall(function() actor["bRegisterAsRuntimeSpawned"] = true end)
    pcall(function()
        local feature_field = require("feature_field")
        feature_field.set_last_spawned(actor)
    end)
    return actor, "spawned"
end

function GENERATED_BOSSROOM_PROBE.method_call(obj, method_name, ...)
    local entry = { method = method_name, present = false, value_type = "", ok = false, value = "", error = "" }
    if not is_valid(obj) then
        entry.error = "invalid object"
        return entry
    end
    local method_ok, method_or_error = pcall(function() return obj[method_name] end)
    if not method_ok then
        entry.error = first_error_line(method_or_error)
        return entry
    end
    entry.present = true
    entry.value_type = type(method_or_error)
    if entry.value_type ~= "function" and entry.value_type ~= "userdata" then return entry end
    local args = { ... }
    local call_ok, value_or_error = pcall(function() return method_or_error(obj, table.unpack(args)) end)
    entry.ok = call_ok == true
    if call_ok then
        entry.value = value_or_error
    else
        entry.error = first_error_line(value_or_error)
    end
    return entry
end

function GENERATED_BOSSROOM_PROBE.number_method(obj, method_name)
    local entry = GENERATED_BOSSROOM_PROBE.method_call(obj, method_name)
    if entry.ok ~= true then return nil, entry end
    local value = unwrap(entry.value)
    return tonumber(value), entry
end

function GENERATED_BOSSROOM_PROBE.boss_health_component(actor)
    local get_entry = GENERATED_BOSSROOM_PROBE.method_call(actor, "GetAiHealthComponent")
    if get_entry.ok and is_valid(get_entry.value) then return get_entry.value, get_entry end
    for _index, field_name in ipairs({ "HealthComponent", "AiHealthComponent", "Health", "HealthComp" }) do
        local ok_field, field_value = pcall(function() return actor[field_name] end)
        if ok_field and is_valid(field_value) then
            return field_value, { method = field_name, present = true, value_type = "field", ok = true, value = field_value, error = "" }
        end
    end
    return nil, get_entry
end

function GENERATED_BOSSROOM_PROBE.actor_destroying(actor)
    if not is_valid(actor) then return nil end
    local destroying = GENERATED_BOSSROOM_PROBE.method_call(actor, "IsActorBeingDestroyed")
    if destroying.ok then
        local value = unwrap(destroying.value)
        return value == true or tostring(value) == "true"
    end
    return nil
end

function GENERATED_BOSSROOM_PROBE.boss_health_snapshot(actor)
    local snapshot = {
        actor_valid = is_valid(actor),
        actor_destroying = false,
        component = {},
        local_health = nil,
        authoritative_health = nil,
        current = nil,
        max = nil,
        normalized = nil,
        is_dead = nil,
        b_is_dead = nil,
    }
    if not snapshot.actor_valid then return snapshot end
    snapshot.actor_destroying = GENERATED_BOSSROOM_PROBE.actor_destroying(actor) == true
    local comp, comp_source = GENERATED_BOSSROOM_PROBE.boss_health_component(actor)
    snapshot.component_source = {
        method = (comp_source or {}).method or "",
        present = (comp_source or {}).present == true,
        ok = (comp_source or {}).ok == true,
        value_type = (comp_source or {}).value_type or "",
        error = (comp_source or {}).error or "",
    }
    if not is_valid(comp) then return snapshot end
    snapshot.component = GENERATED_BOSSROOM_PROBE.actor_entry(comp)
    snapshot.local_health = GENERATED_BOSSROOM_PROBE.number_method(comp, "GetLocalHealth")
    snapshot.authoritative_health = GENERATED_BOSSROOM_PROBE.number_method(comp, "GetAuthoritativeHealth")
    snapshot.max = GENERATED_BOSSROOM_PROBE.number_method(comp, "GetMaxHealth")
    snapshot.normalized = GENERATED_BOSSROOM_PROBE.number_method(comp, "GetNormalizedHealth")
    snapshot.current = snapshot.local_health or snapshot.authoritative_health
    if (not snapshot.normalized) and snapshot.current and snapshot.max and snapshot.max > 0 then
        snapshot.normalized = snapshot.current / snapshot.max
    end
    if snapshot.normalized then
        if snapshot.normalized > 1.0 then snapshot.normalized = snapshot.normalized / 100.0 end
        snapshot.normalized = math.max(0.0, math.min(snapshot.normalized, 1.0))
    end
    local is_dead_entry = GENERATED_BOSSROOM_PROBE.method_call(actor, "IsDead")
    if is_dead_entry.ok then
        local is_dead_value = unwrap(is_dead_entry.value)
        snapshot.is_dead = is_dead_value == true or tostring(is_dead_value) == "true"
    end
    local ok_dead_field, dead_field = pcall(function() return actor["bIsDead"] end)
    if ok_dead_field and dead_field ~= nil then
        local value = unwrap(dead_field)
        snapshot.b_is_dead = value == true or tostring(value) == "true"
    end
    return snapshot
end

function GENERATED_BOSSROOM_PROBE.detect_boss_dead(actor)
    if not is_valid(actor) then
        return true, "actor_invalid", GENERATED_BOSSROOM_PROBE.boss_health_snapshot(actor)
    end
    local health = GENERATED_BOSSROOM_PROBE.boss_health_snapshot(actor)
    if health.actor_destroying == true then return true, "actor_destroying", health end
    if health.is_dead == true then return true, "IsDead", health end
    if health.b_is_dead == true then return true, "bIsDead", health end
    if health.current ~= nil and health.current <= 0 then return true, "health_current_zero", health end
    if health.local_health ~= nil and health.local_health <= 0 then return true, "health_local_zero", health end
    if health.authoritative_health ~= nil and health.authoritative_health <= 0 then return true, "health_authoritative_zero", health end
    if health.normalized ~= nil and health.normalized <= 0 then return true, "health_normalized_zero", health end
    return false, "alive_or_unknown", health
end

function GENERATED_BOSSROOM_PROBE.call_on_boss_dead(boss_actor)
    local result = { method = {}, ok = false, value = "", error = "" }
    if not is_valid(boss_actor) then
        result.error = "bossroom actor invalid"
        return result
    end
    result.method = GENERATED_ACTOR_PROBE.method_entry(boss_actor, "OnBossIsDead")
    local method_type = tostring(result.method.value_type or "")
    if not result.method.present or (method_type ~= "function" and method_type ~= "userdata") then
        result.error = result.method.error ~= "" and result.method.error or "OnBossIsDead not present as a callable UFunction candidate"
        return result
    end
    local call_ok, call_value = pcall(function() return boss_actor:OnBossIsDead() end)
    result.ok = call_ok == true
    if call_ok then
        result.value = GENERATED_BOSSROOM_PROBE.value_text(call_value)
    else
        result.error = first_error_line(call_value)
    end
    return result
end

function GENERATED_BOSSROOM_PROBE.append_health_lines(lines, health, indent)
    indent = indent or "  "
    if not health then
        lines[#lines + 1] = indent .. "health <none>"
        return
    end
    lines[#lines + 1] = string.format(
        "%shealth actor_valid=%s destroying=%s current=%s local=%s authoritative=%s max=%s normalized=%s is_dead=%s b_is_dead=%s comp=%s",
        indent,
        tostring(health.actor_valid == true),
        tostring(health.actor_destroying == true),
        tostring(health.current),
        tostring(health.local_health),
        tostring(health.authoritative_health),
        tostring(health.max),
        tostring(health.normalized),
        tostring(health.is_dead),
        tostring(health.b_is_dead),
        ((health.component or {}).name or ""))
end

function GENERATED_BOSSROOM_PROBE.write_boss_watch_report(encounter, result, reason, health)
    local latest, _layout, boss_node, boss_actor, resolve_error = GENERATED_BOSSROOM_PROBE.resolve_latest()
    if (not is_valid(boss_actor)) and is_valid((encounter or {}).boss_actor) then
        boss_actor = encounter.boss_actor
        boss_node = encounter.boss_node
        resolve_error = nil
    end
    local report = {
        command = "world.dungeon.proc.generated.bossroom.spawnboss.watch",
        encounter_id = (encounter or {}).id or 0,
        batch = (encounter or {}).batch or ((latest or {}).batch or 0),
        seed = (encounter or {}).seed or ((latest or {}).seed or 0),
        mode = (encounter or {}).mode or ((latest or {}).mode or ""),
        result = result or "",
        reason = reason or "",
        boss_node = GENERATED_BOSSROOM_PROBE.node_summary(boss_node),
        bossroom_actor = is_valid(boss_actor) and GENERATED_BOSSROOM_PROBE.actor_entry(boss_actor) or {},
        spawned_boss = is_valid((encounter or {}).actor) and GENERATED_BOSSROOM_PROBE.actor_entry(encounter.actor) or ((encounter or {}).actor_entry or {}),
        health = health or ((encounter or {}).last_health or {}),
        before = {},
        after_immediate = {},
        deltas = {},
        call = { ok = false, value = "", error = "" },
        resolve_error = resolve_error or "",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.bossroom.spawnboss.watch --",
        string.format("  encounter=%s batch=%s seed=%s mode=%s result=%s reason=%s", tostring(report.encounter_id), tostring(report.batch), tostring(report.seed), tostring(report.mode), tostring(report.result), tostring(report.reason)),
        string.format("  spawned_boss=%s [%s] loc=%s", report.spawned_boss.name or "", report.spawned_boss.class or "", report.spawned_boss.location or ""),
    }
    GENERATED_BOSSROOM_PROBE.append_health_lines(lines, report.health, "  ")

    if result == "boss_dead_detected" and is_valid(boss_actor) then
        report.before = GENERATED_BOSSROOM_PROBE.runtime_snapshot(boss_actor, "before_watch_call")
        report.call = GENERATED_BOSSROOM_PROBE.call_on_boss_dead(boss_actor)
        report.after_immediate = GENERATED_BOSSROOM_PROBE.runtime_snapshot(boss_actor, "after_watch_call_immediate")
        report.deltas = GENERATED_BOSSROOM_PROBE.snapshot_deltas(report.before, report.after_immediate)
        lines[#lines + 1] = string.format("  OnBossIsDead call_ok=%s return=%s error=%s", tostring(report.call.ok), report.call.value or "", report.call.error or "")
        GENERATED_BOSSROOM_PROBE.append_snapshot_lines(lines, report.before, "  ")
        GENERATED_BOSSROOM_PROBE.append_snapshot_lines(lines, report.after_immediate, "  ")
        if #report.deltas == 0 then
            lines[#lines + 1] = "  deltas none_immediate"
        else
            lines[#lines + 1] = "  deltas"
            for _delta_index, delta in ipairs(report.deltas) do
                lines[#lines + 1] = string.format("    %s %s", delta.name or "", table.concat(delta.changes or {}, " ; "))
            end
        end
    elseif resolve_error ~= nil and resolve_error ~= "" then
        lines[#lines + 1] = "  bossroom resolve_error=" .. tostring(resolve_error)
    end

    if encounter then
        encounter.watch_result = report.result
        encounter.watch_reason = report.reason
        encounter.open_call = report.call
        encounter.completed = result == "boss_dead_detected"
        encounter.last_health = report.health
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    write_report_files("dungeon_proc_generated_bossroom_spawnboss_watch", report, lines)
    return report
end

function GENERATED_BOSSROOM_PROBE.boss_watch_tick(encounter)
    if not encounter or not encounter.watch or encounter.watch.active ~= true then return true end
    encounter.watch.ticks = (encounter.watch.ticks or 0) + 1
    local dead, reason, health = GENERATED_BOSSROOM_PROBE.detect_boss_dead(encounter.actor)
    encounter.last_health = health
    if dead then
        encounter.watch.active = false
        GENERATED_BOSSROOM_PROBE.write_boss_watch_report(encounter, "boss_dead_detected", reason, health)
        return true
    end
    if encounter.watch.ticks >= (encounter.watch.max_ticks or GENERATED_BOSSROOM_BOSS_WATCH_MAX_TICKS) then
        encounter.watch.active = false
        GENERATED_BOSSROOM_PROBE.write_boss_watch_report(encounter, "watch_timeout", "max_ticks", health)
        return true
    end
    return false
end

function GENERATED_BOSSROOM_PROBE.start_boss_watch(encounter)
    if not LoopAsync then return false, "LoopAsync unavailable" end
    if not encounter then return false, "missing encounter" end
    encounter.watch = encounter.watch or {}
    if encounter.watch.started == true then return true, "already_started" end
    encounter.watch.started = true
    encounter.watch.active = true
    encounter.watch.ticks = 0
    encounter.watch.tick_ms = GENERATED_BOSSROOM_BOSS_WATCH_TICK_MS
    encounter.watch.max_ticks = GENERATED_BOSSROOM_BOSS_WATCH_MAX_TICKS
    LoopAsync(GENERATED_BOSSROOM_BOSS_WATCH_TICK_MS, function()
        local ok, stop_or_error = pcall(function() return GENERATED_BOSSROOM_PROBE.boss_watch_tick(encounter) end)
        if not ok then
            encounter.watch.active = false
            encounter.watch.error = first_error_line(stop_or_error)
            GENERATED_BOSSROOM_PROBE.write_boss_watch_report(encounter, "watch_trapped", encounter.watch.error, encounter.last_health)
            return true
        end
        return stop_or_error == true
    end)
    return true, "started"
end

function GENERATED_BOSSROOM_PROBE.latest_encounter()
    local encounter = generated_bossroom_encounter_cache.latest
    if not encounter then return nil, "no generated bossroom encounter is cached; run world.dungeon.proc.generated.bossroom.spawnboss first" end
    return encounter, nil
end

function GENERATED_BOSSROOM_PROBE.kill_boss_actor(actor)
    local result = { actions = {}, ok = false, method = "", error = "" }
    local comp = GENERATED_BOSSROOM_PROBE.boss_health_component(actor)
    if is_valid(comp) then
        local set_entry = GENERATED_BOSSROOM_PROBE.method_call(comp, "SetHealth", 0, "rsdw.dungeon.boss.kill")
        set_entry.value = GENERATED_BOSSROOM_PROBE.value_text(set_entry.value)
        result.actions[#result.actions + 1] = set_entry
        if set_entry.ok then
            result.ok = true
            result.method = "SetHealth"
            return result
        end
        local damage_entry = GENERATED_BOSSROOM_PROBE.method_call(comp, "DecreaseHealth", 999999, "rsdw.dungeon.boss.kill")
        damage_entry.value = GENERATED_BOSSROOM_PROBE.value_text(damage_entry.value)
        result.actions[#result.actions + 1] = damage_entry
        if damage_entry.ok then
            result.ok = true
            result.method = "DecreaseHealth"
            return result
        end
    end
    local destroy_ok, destroy_detail = destroy_generated_spawn_actor(actor)
    result.actions[#result.actions + 1] = { method = "destroy_generated_spawn_actor", present = true, value_type = "function", ok = destroy_ok == true, value = tostring(destroy_detail), error = destroy_ok and "" or tostring(destroy_detail) }
    result.ok = destroy_ok == true
    result.method = destroy_ok and tostring(destroy_detail) or ""
    result.error = destroy_ok and "" or tostring(destroy_detail)
    return result
end

function M.generated_bossroom_snapshot(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.bossroom.snapshot [latest] confirm"
    if #tokens < 1 or #tokens > 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    if #tokens == 2 and tostring(tokens[1] or ""):lower() ~= "latest" then return false, usage end

    local latest, _layout, boss_node, boss_actor, resolve_error = GENERATED_BOSSROOM_PROBE.resolve_latest()
    if resolve_error then return false, resolve_error end
    local file_stem = "dungeon_proc_generated_bossroom_snapshot"
    local report = {
        command = "world.dungeon.proc.generated.bossroom.snapshot",
        confirmed = true,
        scope = "latest",
        batch = latest.batch or 0,
        seed = latest.seed or 0,
        mode = latest.mode or "",
        boss_node = GENERATED_BOSSROOM_PROBE.node_summary(boss_node),
        snapshot = {},
        result = "about_to_snapshot_bossroom",
        note = "read-only focused bossroom snapshot: treasure gates, boss spawn point, boss chest spawner, and nearby gate/chest/door/trigger objects",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.bossroom.snapshot --",
        string.format("  batch=%s seed=%s mode=%s boss_node=%s actor=%s", tostring(report.batch), tostring(report.seed), tostring(report.mode), tostring((boss_node or {}).index or 0), safe_name(boss_actor)),
        "  note: " .. report.note,
        "  result=" .. report.result,
    }
    local result_line_index = 4
    write_report_files(file_stem .. "_attempt", report, lines)
    report.snapshot = GENERATED_BOSSROOM_PROBE.runtime_snapshot(boss_actor, "snapshot")
    report.result = "snapshot_complete"
    lines[result_line_index] = "  result=" .. report.result
    GENERATED_BOSSROOM_PROBE.append_snapshot_lines(lines, report.snapshot, "  ")
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("batch=%s node=%s components=%d object_scans=%d", tostring(report.batch), tostring((boss_node or {}).index or 0), #(report.snapshot.focused_components or {}), #(report.snapshot.object_scans or {}))
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_bossroom_death(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.bossroom.death [latest] confirm"
    if #tokens < 1 or #tokens > 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    if #tokens == 2 and tostring(tokens[1] or ""):lower() ~= "latest" then return false, usage end

    local latest, _layout, boss_node, boss_actor, resolve_error = GENERATED_BOSSROOM_PROBE.resolve_latest()
    if resolve_error then return false, resolve_error end
    local file_stem = "dungeon_proc_generated_bossroom_death"
    local report = {
        command = "world.dungeon.proc.generated.bossroom.death",
        confirmed = true,
        mutating = true,
        action = "OnBossIsDead",
        scope = "latest",
        batch = latest.batch or 0,
        seed = latest.seed or 0,
        mode = latest.mode or "",
        boss_node = GENERATED_BOSSROOM_PROBE.node_summary(boss_node),
        before = {},
        after_immediate = {},
        deltas = {},
        method = {},
        call = { ok = false, value = "", error = "" },
        result = "about_to_snapshot_before",
        note = "mutating focused bossroom test: calls BP_BossRoom_C:OnBossIsDead() once, then snapshots treasure gates/chest state immediately; run snapshot again after a few seconds for timeline completion",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.bossroom.death --",
        string.format("  batch=%s seed=%s mode=%s boss_node=%s actor=%s", tostring(report.batch), tostring(report.seed), tostring(report.mode), tostring((boss_node or {}).index or 0), safe_name(boss_actor)),
        "  note: " .. report.note,
        "  result=" .. report.result,
    }
    local result_line_index = 4
    write_report_files(file_stem .. "_attempt", report, lines)

    report.before = GENERATED_BOSSROOM_PROBE.runtime_snapshot(boss_actor, "before")
    report.result = "about_to_lookup_OnBossIsDead"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    report.method = GENERATED_ACTOR_PROBE.method_entry(boss_actor, "OnBossIsDead")
    local method_type = tostring(report.method.value_type or "")
    if not report.method.present or (method_type ~= "function" and method_type ~= "userdata") then
        report.result = "method_unavailable"
        report.call.error = report.method.error ~= "" and report.method.error or "OnBossIsDead not present as a callable UFunction candidate"
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  call failed: " .. report.call.error
        GENERATED_BOSSROOM_PROBE.append_snapshot_lines(lines, report.before, "  ")
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files(file_stem, report, lines)
        if write_ok then return false, "method_unavailable wrote " .. tostring(write_detail) end
        return false, "method_unavailable see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    report.result = "about_to_call_OnBossIsDead"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    local call_ok, call_value = pcall(function() return boss_actor:OnBossIsDead() end)
    report.call.ok = call_ok == true
    if call_ok then
        report.call.value = GENERATED_BOSSROOM_PROBE.value_text(call_value)
    else
        report.call.error = first_error_line(call_value)
    end

    report.result = call_ok and "about_to_snapshot_after_immediate" or "call_failed"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    report.after_immediate = GENERATED_BOSSROOM_PROBE.runtime_snapshot(boss_actor, "after_immediate")
    report.deltas = GENERATED_BOSSROOM_PROBE.snapshot_deltas(report.before, report.after_immediate)
    report.result = call_ok and "death_call_complete" or "death_call_failed"
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = string.format("  method present=%s type=%s call_ok=%s return=%s error=%s", tostring(report.method.present), report.method.value_type or "", tostring(report.call.ok), report.call.value or "", report.call.error or "")
    GENERATED_BOSSROOM_PROBE.append_snapshot_lines(lines, report.before, "  ")
    GENERATED_BOSSROOM_PROBE.append_snapshot_lines(lines, report.after_immediate, "  ")
    if #report.deltas == 0 then
        lines[#lines + 1] = "  deltas none_immediate"
    else
        lines[#lines + 1] = "  deltas"
        for _delta_index, delta in ipairs(report.deltas) do
            lines[#lines + 1] = string.format("    %s %s", delta.name or "", table.concat(delta.changes or {}, " ; "))
        end
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("batch=%s node=%s call_ok=%s deltas=%d", tostring(report.batch), tostring((boss_node or {}).index or 0), tostring(report.call.ok), #report.deltas)
    if write_ok then return report.call.ok == true, detail .. " wrote " .. tostring(write_detail) end
    return report.call.ok == true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_bossroom_unlock(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.bossroom.unlock [latest] confirm"
    if #tokens < 1 or #tokens > 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    if #tokens == 2 and tostring(tokens[1] or ""):lower() ~= "latest" then return false, usage end

    local latest, _layout, boss_node, boss_actor, resolve_error = GENERATED_BOSSROOM_PROBE.resolve_latest()
    if resolve_error then return false, resolve_error end
    local file_stem = "dungeon_proc_generated_bossroom_unlock"
    local report = {
        command = "world.dungeon.proc.generated.bossroom.unlock",
        confirmed = true,
        mutating = true,
        action = "fallback_hide_disable_treasure_gates",
        scope = "latest",
        batch = latest.batch or 0,
        seed = latest.seed or 0,
        mode = latest.mode or "",
        boss_node = GENERATED_BOSSROOM_PROBE.node_summary(boss_node),
        before = {},
        gate_components = {},
        after_immediate = {},
        deltas = {},
        result = "about_to_snapshot_before",
        note = "fallback bossroom gate-open test: hides and disables collision on SM_TreasureGate01/02 only; use after native bossroom.death does not open the reward gates",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.bossroom.unlock --",
        string.format("  batch=%s seed=%s mode=%s boss_node=%s actor=%s", tostring(report.batch), tostring(report.seed), tostring(report.mode), tostring((boss_node or {}).index or 0), safe_name(boss_actor)),
        "  note: " .. report.note,
        "  result=" .. report.result,
    }
    local result_line_index = 4
    write_report_files(file_stem .. "_attempt", report, lines)

    report.before = GENERATED_BOSSROOM_PROBE.runtime_snapshot(boss_actor, "before")
    report.result = "about_to_find_treasure_gates"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)

    local gates = GENERATED_BOSSROOM_PROBE.named_component_handles(boss_actor, { "SM_TreasureGate01", "SM_TreasureGate02" })
    if #gates == 0 then
        report.result = "gate_components_not_found"
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  gate components not found: SM_TreasureGate01/SM_TreasureGate02"
        GENERATED_BOSSROOM_PROBE.append_snapshot_lines(lines, report.before, "  ")
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files(file_stem, report, lines)
        if write_ok then return false, "gate_components_not_found wrote " .. tostring(write_detail) end
        return false, "gate_components_not_found see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    local total_ok = 0
    local total_fail = 0
    for _gate_index, gate in ipairs(gates) do
        report.result = "about_to_unlock_" .. safe_name(gate)
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local gate_result = GENERATED_BOSSROOM_PROBE.unlock_gate_component(gate)
        report.gate_components[#report.gate_components + 1] = gate_result
        total_ok = total_ok + (gate_result.ok_count or 0)
        total_fail = total_fail + (gate_result.fail_count or 0)
        lines[#lines + 1] = string.format("  gate %s actions_ok=%d actions_failed=%d", gate_result.component or "", gate_result.ok_count or 0, gate_result.fail_count or 0)
        for _action_index, action in ipairs(gate_result.actions or {}) do
            lines[#lines + 1] = string.format("    %s ok=%s error=%s", action.action or "", tostring(action.ok), action.error or "")
        end
    end

    report.result = "about_to_snapshot_after_immediate"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    report.after_immediate = GENERATED_BOSSROOM_PROBE.runtime_snapshot(boss_actor, "after_immediate")
    report.deltas = GENERATED_BOSSROOM_PROBE.snapshot_deltas(report.before, report.after_immediate)
    report.result = (total_ok > 0 and total_fail == 0) and "unlock_fallback_complete" or ((total_ok > 0) and "unlock_fallback_partial" or "unlock_fallback_failed")
    lines[result_line_index] = "  result=" .. report.result
    GENERATED_BOSSROOM_PROBE.append_snapshot_lines(lines, report.before, "  ")
    GENERATED_BOSSROOM_PROBE.append_snapshot_lines(lines, report.after_immediate, "  ")
    if #report.deltas == 0 then
        lines[#lines + 1] = "  deltas none_immediate"
    else
        lines[#lines + 1] = "  deltas"
        for _delta_index, delta in ipairs(report.deltas) do
            lines[#lines + 1] = string.format("    %s %s", delta.name or "", table.concat(delta.changes or {}, " ; "))
        end
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("batch=%s node=%s gates=%d action_ok=%d action_failed=%d deltas=%d", tostring(report.batch), tostring((boss_node or {}).index or 0), #gates, total_ok, total_fail, #report.deltas)
    if write_ok then return total_ok > 0, detail .. " wrote " .. tostring(write_detail) end
    return total_ok > 0, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_bossroom_spawnboss(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.bossroom.spawnboss [latest] [skeletal|thane|razlem|<ClassPath>] [z_offset_cm] confirm"
    if #tokens < 1 or #tokens > 4 or tokens[#tokens] ~= "confirm" then return false, usage end

    local args = {}
    for index = 1, #tokens - 1 do args[#args + 1] = tokens[index] end
    if #args > 0 and tostring(args[1] or ""):lower() == "latest" then table.remove(args, 1) end

    local class_token = GENERATED_BOSSROOM_DEFAULT_BOSS_ALIAS
    local z_offset = GENERATED_BOSSROOM_BOSS_SPAWN_Z_OFFSET_CM
    if #args > 0 then
        local numeric_first = tonumber(args[1])
        if numeric_first then
            z_offset = numeric_first
        else
            class_token = args[1]
        end
        table.remove(args, 1)
    end
    if #args > 0 then
        local parsed_z = tonumber(args[1])
        if not parsed_z then return false, usage end
        z_offset = parsed_z
        table.remove(args, 1)
    end
    if #args > 0 then return false, usage end

    local class_spec, class_error = GENERATED_BOSSROOM_PROBE.resolve_boss_class_spec(class_token)
    if class_error then return false, class_error end

    local latest, _layout, boss_node, boss_actor, resolve_error = GENERATED_BOSSROOM_PROBE.resolve_latest()
    if resolve_error then return false, resolve_error end

    local spawn_point, spawn_point_error = GENERATED_BOSSROOM_PROBE.boss_spawn_point(boss_actor)
    if spawn_point_error then return false, spawn_point_error end
    local spawn_loc = {
        X = (tonumber(spawn_point.location.X) or 0),
        Y = (tonumber(spawn_point.location.Y) or 0),
        Z = (tonumber(spawn_point.location.Z) or 0) + z_offset,
    }
    local spawn_rot = spawn_point.rotation or { Pitch = 0, Yaw = 180, Roll = 0 }

    local file_stem = "dungeon_proc_generated_bossroom_spawnboss"
    local report = {
        command = "world.dungeon.proc.generated.bossroom.spawnboss",
        confirmed = true,
        mutating = true,
        scope = "latest",
        batch = latest.batch or 0,
        seed = latest.seed or 0,
        mode = latest.mode or "",
        boss_node = GENERATED_BOSSROOM_PROBE.node_summary(boss_node),
        bossroom_actor = GENERATED_BOSSROOM_PROBE.actor_entry(boss_actor),
        class_alias = class_spec.alias or "",
        class_label = class_spec.label or "",
        class_path = class_spec.class_path or "",
        z_offset_cm = z_offset,
        spawn_point = {
            name = spawn_point.name,
            full_name = spawn_point.full_name,
            location = spawn_point.location_text,
            rotation = spawn_point.rotation_text,
        },
        spawn_location = vec_text(spawn_loc),
        spawn_rotation = GENERATED_BOSSROOM_PROBE.rotation_text(spawn_rot),
        actor = {},
        health = {},
        cache_entry = {},
        watch = { started = false, active = false, detail = "" },
        result = "about_to_spawn_boss",
        error = "",
        note = "spawns a test boss at BossSpawnPoint with the configured Z offset, starts a watcher, and calls BP_BossRoom_C:OnBossIsDead when the spawned boss dies",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.bossroom.spawnboss --",
        string.format("  batch=%s seed=%s mode=%s boss_node=%s actor=%s", tostring(report.batch), tostring(report.seed), tostring(report.mode), tostring((boss_node or {}).index or 0), safe_name(boss_actor)),
        string.format("  class=%s alias=%s path=%s", report.class_label, report.class_alias, report.class_path),
        string.format("  spawn_point=%s loc=%s rot=%s z_offset=%.1f spawn=%s", report.spawn_point.name or "", report.spawn_point.location or "", report.spawn_point.rotation or "", z_offset, report.spawn_location),
        "  result=" .. report.result,
    }
    local result_line_index = 5
    write_report_files(file_stem .. "_attempt", report, lines)

    local actor, spawn_error = GENERATED_BOSSROOM_PROBE.spawn_actor_deferred(class_spec.class_path, spawn_loc, spawn_rot)
    if not is_valid(actor) then
        report.result = "spawn_failed"
        report.error = first_error_line(spawn_error)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. report.error
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files(file_stem, report, lines)
        if write_ok then return false, "spawn_failed wrote " .. tostring(write_detail) end
        return false, "spawn_failed see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    report.actor = GENERATED_BOSSROOM_PROBE.actor_entry(actor)
    local cache_entry = remember_generated_spawn_actor(latest.batch or generated_spawn_cache.latest_batch or 0, actor, "bossroom_spawnboss", "bossroom_boss")
    if cache_entry then
        report.cache_entry = { batch = cache_entry.batch, label = cache_entry.label, ref = cache_entry.ref, name = cache_entry.name, full_name = cache_entry.full_name, location = cache_entry.location }
    end

    generated_bossroom_encounter_cache.next_id = (generated_bossroom_encounter_cache.next_id or 0) + 1
    local encounter = {
        id = generated_bossroom_encounter_cache.next_id,
        batch = latest.batch or 0,
        seed = latest.seed or 0,
        mode = latest.mode or "",
        boss_node = boss_node,
        boss_actor = boss_actor,
        actor = actor,
        actor_entry = report.actor,
        class_spec = class_spec,
        spawn_point = report.spawn_point,
        spawn_location = report.spawn_location,
        z_offset_cm = z_offset,
        completed = false,
        watch = {},
    }
    generated_bossroom_encounter_cache.latest = encounter
    generated_bossroom_encounter_cache.encounters[encounter.id] = encounter

    report.health = GENERATED_BOSSROOM_PROBE.boss_health_snapshot(actor)
    encounter.last_health = report.health
    local watch_ok, watch_detail = GENERATED_BOSSROOM_PROBE.start_boss_watch(encounter)
    report.watch = {
        started = watch_ok == true,
        active = watch_ok == true,
        detail = tostring(watch_detail or ""),
        tick_ms = GENERATED_BOSSROOM_BOSS_WATCH_TICK_MS,
        max_ticks = GENERATED_BOSSROOM_BOSS_WATCH_MAX_TICKS,
    }
    report.encounter_id = encounter.id
    report.result = watch_ok and "spawned_boss_watch_started" or "spawned_boss_watch_unavailable"
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = string.format("  spawned_boss=%s [%s] loc=%s encounter=%s", report.actor.name or "", report.actor.class or "", report.actor.location or "", tostring(encounter.id))
    GENERATED_BOSSROOM_PROBE.append_health_lines(lines, report.health, "  ")
    lines[#lines + 1] = string.format("  watch started=%s detail=%s tick_ms=%s max_ticks=%s", tostring(report.watch.started), report.watch.detail, tostring(report.watch.tick_ms), tostring(report.watch.max_ticks))

    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("encounter=%s actor=%s watch=%s spawn=%s", tostring(encounter.id), report.actor.name or "", tostring(report.watch.started), report.spawn_location)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_bossroom_bossstatus(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.bossroom.bossstatus [latest] confirm"
    if #tokens < 1 or #tokens > 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    if #tokens == 2 and tostring(tokens[1] or ""):lower() ~= "latest" then return false, usage end

    local encounter, encounter_error = GENERATED_BOSSROOM_PROBE.latest_encounter()
    if encounter_error then return false, encounter_error end
    local dead, reason, health = GENERATED_BOSSROOM_PROBE.detect_boss_dead(encounter.actor)
    encounter.last_health = health
    local report = {
        command = "world.dungeon.proc.generated.bossroom.bossstatus",
        confirmed = true,
        encounter_id = encounter.id or 0,
        batch = encounter.batch or 0,
        seed = encounter.seed or 0,
        mode = encounter.mode or "",
        boss_node = GENERATED_BOSSROOM_PROBE.node_summary(encounter.boss_node),
        actor = is_valid(encounter.actor) and GENERATED_BOSSROOM_PROBE.actor_entry(encounter.actor) or (encounter.actor_entry or {}),
        health = health,
        dead = dead == true,
        reason = reason,
        watch = encounter.watch or {},
        watch_result = encounter.watch_result or "",
        watch_reason = encounter.watch_reason or "",
        open_call = encounter.open_call or {},
        result = "status_complete",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.bossroom.bossstatus --",
        string.format("  encounter=%s batch=%s seed=%s mode=%s result=%s", tostring(report.encounter_id), tostring(report.batch), tostring(report.seed), tostring(report.mode), report.result),
        string.format("  actor=%s [%s] loc=%s", report.actor.name or "", report.actor.class or "", report.actor.location or ""),
        string.format("  dead=%s reason=%s watch_active=%s watch_ticks=%s watch_result=%s watch_reason=%s open_call_ok=%s", tostring(report.dead), tostring(report.reason), tostring((report.watch or {}).active == true), tostring((report.watch or {}).ticks or 0), report.watch_result or "", report.watch_reason or "", tostring((report.open_call or {}).ok == true)),
    }
    GENERATED_BOSSROOM_PROBE.append_health_lines(lines, report.health, "  ")
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_generated_bossroom_bossstatus", report, lines)
    local detail = string.format("encounter=%s dead=%s reason=%s watch_active=%s", tostring(report.encounter_id), tostring(report.dead), tostring(report.reason), tostring((report.watch or {}).active == true))
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_bossroom_killboss(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.bossroom.killboss [latest] confirm"
    if #tokens < 1 or #tokens > 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    if #tokens == 2 and tostring(tokens[1] or ""):lower() ~= "latest" then return false, usage end

    local encounter, encounter_error = GENERATED_BOSSROOM_PROBE.latest_encounter()
    if encounter_error then return false, encounter_error end
    local before_health = GENERATED_BOSSROOM_PROBE.boss_health_snapshot(encounter.actor)
    local kill_result = GENERATED_BOSSROOM_PROBE.kill_boss_actor(encounter.actor)
    local after_health = GENERATED_BOSSROOM_PROBE.boss_health_snapshot(encounter.actor)
    encounter.last_health = after_health

    local report = {
        command = "world.dungeon.proc.generated.bossroom.killboss",
        confirmed = true,
        mutating = true,
        encounter_id = encounter.id or 0,
        batch = encounter.batch or 0,
        seed = encounter.seed or 0,
        mode = encounter.mode or "",
        actor = is_valid(encounter.actor) and GENERATED_BOSSROOM_PROBE.actor_entry(encounter.actor) or (encounter.actor_entry or {}),
        before_health = before_health,
        after_health = after_health,
        kill = kill_result,
        result = kill_result.ok and "kill_signal_sent" or "kill_signal_failed",
        note = "test-only shortcut: asks the spawned boss health component to die, falling back to actor destroy; the spawnboss watcher should call OnBossIsDead on the next tick",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.bossroom.killboss --",
        string.format("  encounter=%s batch=%s seed=%s mode=%s result=%s", tostring(report.encounter_id), tostring(report.batch), tostring(report.seed), tostring(report.mode), report.result),
        string.format("  actor=%s [%s] loc=%s method=%s ok=%s error=%s", report.actor.name or "", report.actor.class or "", report.actor.location or "", kill_result.method or "", tostring(kill_result.ok == true), kill_result.error or ""),
    }
    GENERATED_BOSSROOM_PROBE.append_health_lines(lines, before_health, "  before_")
    GENERATED_BOSSROOM_PROBE.append_health_lines(lines, after_health, "  after_")
    for _action_index, action in ipairs(kill_result.actions or {}) do
        lines[#lines + 1] = string.format("  action %s present=%s ok=%s value=%s error=%s", action.method or "", tostring(action.present == true), tostring(action.ok == true), tostring(action.value or ""), tostring(action.error or ""))
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_generated_bossroom_killboss", report, lines)
    local detail = string.format("encounter=%s ok=%s method=%s", tostring(report.encounter_id), tostring(kill_result.ok == true), kill_result.method or "")
    if write_ok then return kill_result.ok == true, detail .. " wrote " .. tostring(write_detail) end
    return kill_result.ok == true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_entrance_probe(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.entrance.probe [latest] confirm"
    if #tokens < 1 or #tokens > 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    if #tokens == 2 and tostring(tokens[1] or ""):lower() ~= "latest" then return false, usage end

    local latest = generated_spawn_cache.latest_connected
    if not latest or not latest.layout then
        return false, "no latest smart connected spawn is cached; run world.dungeon.proc.generator.spawnconnected first after each game reload"
    end

    local layout = latest.layout
    local origin = latest.origin or CONNECTED_SMART.default_origin
    local tile_step = tonumber(latest.tile_step) or DUNGEON_TILE_SIZE_CM
    local file_stem = "dungeon_proc_generated_entrance_probe"
    local entrance_node = nil
    for _node_index, node in ipairs(layout.nodes or {}) do
        local key = tostring(node.key or ""):lower()
        local category = tostring(node.category or ""):lower()
        if key == "entranceroom_v6" or category == "entrance" then
            entrance_node = node
            break
        end
    end
    if not entrance_node then return false, "latest smart layout has no entrance node; verify entranceroom_v6 special connector is active and rerun spawnconnected" end

    local room_state = (latest.rooms or {})[entrance_node.index or 0] or {}
    local entrance_actor = room_state.actor
    local fallback_used = false
    if not is_valid(entrance_actor) then
        local bucket = find_objects({ "EntranceRoom_V6_C", "EntranceRoom_V6", "EntranceRoom" })
        if #bucket.live > 0 and is_valid(bucket.live[1]) then
            entrance_actor = bucket.live[1]
            fallback_used = true
        end
    end
    if not is_valid(entrance_actor) then return false, "entrance actor unavailable; run probe in the same Lua session as spawnconnected" end

    local expected_loc = {
        X = (origin.X or 0) + (entrance_node.cell_x or 0) * tile_step,
        Y = (origin.Y or 0) + (entrance_node.cell_y or 0) * tile_step,
        Z = (origin.Z or 0) + ((entrance_node.z_cm or 0) * (tile_step / DUNGEON_TILE_SIZE_CM)),
    }
    local actor_loc, actor_loc_text = GENERATED_BOSSROOM_PROBE.location(entrance_actor)
    local rot = nil
    pcall(function() rot = feature_actor.actor_rotation(entrance_actor) end)
    local actor_yaw = tonumber(rot and rot.Yaw) or 0
    local loc_delta = actor_loc and {
        x = (actor_loc.X or 0) - expected_loc.X,
        y = (actor_loc.Y or 0) - expected_loc.Y,
        z = (actor_loc.Z or 0) - expected_loc.Z,
    } or nil

    local report = {
        command = "world.dungeon.proc.generated.entrance.probe",
        confirmed = true,
        scope = "latest",
        batch = latest.batch or 0,
        seed = latest.seed or 0,
        mode = latest.mode or "",
        origin = vec_text(origin),
        tile_step = tile_step,
        entrance_node = GENERATED_BOSSROOM_PROBE.node_summary(entrance_node),
        actor = {
            name = safe_name(entrance_actor),
            class = safety.class_name_of(entrance_actor) or "",
            full_name = safe_full_name(entrance_actor),
            location = actor_loc_text,
            expected_location = vec_text(expected_loc),
            location_delta = loc_delta,
            yaw = actor_yaw,
            fallback_used = fallback_used,
            state = GENERATED_ACTOR_PROBE.actor_state(entrance_actor),
        },
        openings = {},
        edges = {},
        authored_anchors = {},
        teleport_exitpoint_relative = "0,550,-120",
        root_component = {},
        component_sets = {},
        object_scans = {},
        function_surface = {},
        result = "about_to_collect_entrance_openings",
        note = "read-only entrance probe: layout edge targets, authored Teleport/door connector anchors, method-name surface, component inventory, and nearby/keyword teleport/door candidates only; no lifecycle calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.entrance.probe --",
        string.format("  batch=%s seed=%s mode=%s origin=%s tile_step=%.1f", tostring(report.batch), tostring(report.seed), tostring(report.mode), report.origin, tile_step),
        string.format("  entrance node=%d key=%s grid=%s,%s z_cm=%.1f yaw=%.1f actor=%s [%s]", entrance_node.index or 0, entrance_node.key or "", tostring(entrance_node.cell_x or 0), tostring(entrance_node.cell_y or 0), entrance_node.z_cm or 0, entrance_node.room_yaw or 0, report.actor.name, report.actor.class),
        string.format("  loc actual=%s expected=%s delta=%s,%s,%s fallback=%s", report.actor.location, report.actor.expected_location, tostring(loc_delta and loc_delta.x or ""), tostring(loc_delta and loc_delta.y or ""), tostring(loc_delta and loc_delta.z or ""), tostring(fallback_used)),
        "  note: " .. report.note,
        "  result=" .. report.result,
    }
    local result_line_index = 6
    write_report_files(file_stem .. "_attempt", report, lines)

    for opening_index, opening in ipairs(entrance_node.openings or {}) do
        local target = CONNECTED_SMART.wall_target(entrance_node, opening, origin, tile_step)
        local entry = {
            index = opening_index,
            opening = CONNECTED_SMART.opening_copy(opening),
            target = target and vec_text(target) or "",
        }
        report.openings[#report.openings + 1] = entry
        lines[#lines + 1] = string.format("  opening[%02d] target=%s %s", opening_index, entry.target, GENERATED_BOSSROOM_PROBE.opening_text(opening))
    end

    report.result = "about_to_collect_entrance_edges"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    for _edge_index, edge in ipairs(layout.edges or {}) do
        if edge.parent == entrance_node.index or edge.child == entrance_node.index then
            local other_index = edge.parent == entrance_node.index and edge.child or edge.parent
            local other_node = (layout.nodes or {})[other_index or 0]
            local other_state = (latest.rooms or {})[other_index or 0] or {}
            local parent_node = (layout.nodes or {})[edge.parent or 0]
            local child_node = (layout.nodes or {})[edge.child or 0]
            local parent_target = parent_node and edge.parent_opening and CONNECTED_SMART.wall_target(parent_node, edge.parent_opening, origin, tile_step) or nil
            local child_target = child_node and edge.child_opening and CONNECTED_SMART.wall_target(child_node, edge.child_opening, origin, tile_step) or nil
            local midpoint = GENERATED_ENTRANCE_PROBE.midpoint(parent_target, child_target)
            local entry = {
                index = edge.index or 0,
                role = edge.parent == entrance_node.index and "parent" or "child",
                direct = edge.direct == true,
                loop = edge.loop == true,
                dir = edge.dir or "",
                parent = GENERATED_BOSSROOM_PROBE.node_summary(parent_node),
                child = GENERATED_BOSSROOM_PROBE.node_summary(child_node),
                other = GENERATED_BOSSROOM_PROBE.node_summary(other_node),
                other_actor = {
                    name = other_state.name or "",
                    full_name = other_state.full_name or "",
                },
                parent_opening = CONNECTED_SMART.opening_copy(edge.parent_opening),
                child_opening = CONNECTED_SMART.opening_copy(edge.child_opening),
                parent_target = parent_target and vec_text(parent_target) or "",
                child_target = child_target and vec_text(child_target) or "",
                connector_midpoint = midpoint and vec_text(midpoint) or "",
            }
            report.edges[#report.edges + 1] = entry
            lines[#lines + 1] = string.format(
                "  edge[%03d] entrance_role=%s other=%d:%s actor=%s direct=%s dir=%s parent_target=%s child_target=%s midpoint=%s",
                entry.index,
                entry.role,
                other_index or 0,
                other_node and other_node.key or "",
                entry.other_actor.name,
                tostring(entry.direct),
                entry.dir,
                entry.parent_target,
                entry.child_target,
                entry.connector_midpoint)
            lines[#lines + 1] = "    parent_opening " .. GENERATED_BOSSROOM_PROBE.opening_text(edge.parent_opening)
            lines[#lines + 1] = "    child_opening  " .. GENERATED_BOSSROOM_PROBE.opening_text(edge.child_opening)
        end
    end

    for _anchor_index, anchor in ipairs(GENERATED_ENTRANCE_PROBE.authored_anchors) do
        local world_loc = GENERATED_ENTRANCE_PROBE.world_from_local(entrance_node, origin, tile_step, anchor.local_loc)
        local world_yaw = ((tonumber(anchor.local_yaw) or 0) + (tonumber(entrance_node.room_yaw) or 0) + 180) % 360 - 180
        local entry = {
            key = anchor.key or "",
            label = anchor.label or "",
            local_location = vec_text(anchor.local_loc or {}),
            world_location = vec_text(world_loc),
            local_yaw = tonumber(anchor.local_yaw) or 0,
            world_yaw = world_yaw,
        }
        report.authored_anchors[#report.authored_anchors + 1] = entry
        lines[#lines + 1] = string.format("  anchor %-34s local=%s world=%s yaw=%.1f", entry.key, entry.local_location, entry.world_location, entry.world_yaw)
    end
    lines[#lines + 1] = "  BP_DungeonTeleport ExitPoint relative_to_teleporter=" .. report.teleport_exitpoint_relative

    report.result = "about_to_collect_function_surface"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    local function_surface = GENERATED_ACTOR_PROBE.collect_function_surface(entrance_actor, "all", 250)
    function_surface.keyword_methods = {}
    for _method_index, method in ipairs(function_surface.methods or {}) do
        local hits = GENERATED_ENTRANCE_PROBE.keyword_hits((method.name or "") .. " " .. (method.owner_class or "") .. " " .. (method.full_name or ""))
        if #hits > 0 then
            function_surface.keyword_methods[#function_surface.keyword_methods + 1] = {
                owner_class = method.owner_class or "",
                name = method.name or "",
                full_name = method.full_name or "",
                keyword_hits = hits,
            }
        end
    end
    report.function_surface = function_surface
    lines[#lines + 1] = string.format("  functions total=%d sampled=%d keyword_matches=%d omitted=%d", function_surface.total_functions or 0, #(function_surface.methods or {}), #(function_surface.keyword_methods or {}), function_surface.omitted_functions or 0)
    for index = 1, math.min(#(function_surface.keyword_methods or {}), 24) do
        local method = function_surface.keyword_methods[index]
        lines[#lines + 1] = string.format("    fn[%02d] %s::%s hits=%s", index, method.owner_class or "", method.name or "", table.concat(method.keyword_hits or {}, ","))
    end

    if entrance_actor.K2_GetRootComponent then
        report.result = "about_to_K2_GetRootComponent"
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local root_ok, root_or_error = pcall(function() return entrance_actor:K2_GetRootComponent() end)
        if root_ok and is_valid(root_or_error) then
            local _root_loc, root_loc_text = GENERATED_BOSSROOM_PROBE.component_location(root_or_error)
            report.root_component = { ok = true, name = safe_name(root_or_error), class = safety.class_name_of(root_or_error) or "", full_name = safe_full_name(root_or_error), location = root_loc_text }
            lines[#lines + 1] = string.format("  root %s [%s] loc=%s full=%s", report.root_component.name, report.root_component.class, report.root_component.location, report.root_component.full_name)
        else
            report.root_component = { ok = false, error = root_ok and "invalid root" or first_error_line(root_or_error) }
            lines[#lines + 1] = "  root <failed: " .. tostring(report.root_component.error) .. ">"
        end
    end

    for _component_index, component_spec in ipairs(GENERATED_ENTRANCE_PROBE.component_specs) do
        report.result = "about_to_components_" .. component_spec.label
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local entry = GENERATED_ENTRANCE_PROBE.component_sample(entrance_actor, component_spec.class_path, component_spec.label, GENERATED_ENTRANCE_PROBE.component_sample_limit)
        report.component_sets[#report.component_sets + 1] = entry
        if entry.ok then
            lines[#lines + 1] = string.format("  components %-28s count=%d sampled=%d keyword_samples=%d", entry.label, entry.count, entry.sampled, entry.keyword_count)
            for index = 1, math.min(#entry.keyword_samples, 18) do
                local sample = entry.keyword_samples[index]
                lines[#lines + 1] = string.format("    comp[%02d] %s [%s] loc=%s hits=%s", sample.index or 0, sample.name or "", sample.class or "", sample.location or "", table.concat(sample.keyword_hits or {}, ","))
            end
            if #entry.keyword_samples == 0 and #entry.samples > 0 then
                local sample_parts = {}
                for index = 1, math.min(#entry.samples, 4) do
                    local sample = entry.samples[index]
                    sample_parts[#sample_parts + 1] = (sample.name or "") .. "[" .. (sample.class or "") .. "]"
                end
                lines[#lines + 1] = "    sample=" .. table.concat(sample_parts, ", ")
            end
        else
            lines[#lines + 1] = string.format("  components %-28s <failed: %s>", entry.label, entry.error)
        end
    end

    report.result = "about_to_scan_entrance_objects"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    report.object_scans = GENERATED_ENTRANCE_PROBE.object_scan(actor_loc, GENERATED_ENTRANCE_PROBE.object_specs)
    for _scan_index, scan in ipairs(report.object_scans or {}) do
        lines[#lines + 1] = string.format("  objects %-22s found=%d defaults=%d matched=%d sampled=%d", scan.key, scan.found, scan.defaults, scan.matched, scan.sampled)
        for index = 1, math.min(#scan.samples, 12) do
            local sample = scan.samples[index]
            lines[#lines + 1] = string.format("    obj[%03d] %s [%s] loc=%s dist=%s hits=%s", sample.index or 0, sample.name or "", sample.class or "", sample.location or "", sample.distance and string.format("%.1f", sample.distance) or "", table.concat(sample.keyword_hits or {}, ","))
        end
    end

    report.result = "entrance_probe_complete"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("batch=%s node=%s openings=%d edges=%d anchors=%d components=%d object_scans=%d functions=%d", tostring(report.batch), tostring(entrance_node.index or 0), #report.openings, #report.edges, #report.authored_anchors, #report.component_sets, #report.object_scans, #(function_surface.keyword_methods or {}))
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_entrance_patchprobe(args_str)
    local usage = "usage: world.dungeon.proc.generated.entrance.patchprobe [latest] [closures|hubvisual|west|lower|north|upper|all|<candidate>] confirm"
    local parsed, parse_error = GENERATED_ENTRANCE_PROBE.parse_patch_args(args_str, false)
    if not parsed then return false, usage .. " (" .. tostring(parse_error) .. ")" end
    local selected, selector, selector_error = GENERATED_ENTRANCE_PROBE.selected_patch_candidates(parsed.selector)
    if selector_error then return false, selector_error end

    local latest, _layout, entrance_node, entrance_actor, origin, tile_step, fallback_used, resolve_error = GENERATED_ENTRANCE_PROBE.resolve_latest()
    if resolve_error then return false, resolve_error end

    local file_stem = "dungeon_proc_generated_entrance_patchprobe"
    local actor_loc, actor_loc_text = GENERATED_BOSSROOM_PROBE.location(entrance_actor)
    local report = {
        command = "world.dungeon.proc.generated.entrance.patchprobe",
        confirmed = true,
        scope = "latest",
        selector = selector,
        batch = latest.batch or 0,
        seed = latest.seed or 0,
        mode = latest.mode or "",
        origin = vec_text(origin),
        tile_step = tile_step,
        entrance_node = GENERATED_BOSSROOM_PROBE.node_summary(entrance_node),
        actor = {
            name = safe_name(entrance_actor),
            class = safety.class_name_of(entrance_actor) or "",
            full_name = safe_full_name(entrance_actor),
            location = actor_loc_text,
            fallback_used = fallback_used,
            state = GENERATED_ACTOR_PROBE.actor_state(entrance_actor),
        },
        patch_actor_class_path = GENERATED_ENTRANCE_PROBE.patch_actor_class_path,
        patch_actor_frame_relative_yaw = GENERATED_ENTRANCE_PROBE.patch_actor_frame_relative_yaw,
        patch_actor_frame_offset = vec_text(GENERATED_ENTRANCE_PROBE.patch_actor_frame_offset),
        candidates = {},
        instance_component_probe = {},
        result = "about_to_collect_patch_candidates",
        note = "read-only entrance patch probe: calculates reviewed closure/optional connector candidate transforms and inspects room ISM method/nearest-instance surfaces; no actor spawns or instance mutation",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.entrance.patchprobe --",
        string.format("  batch=%s seed=%s mode=%s selector=%s origin=%s tile_step=%.1f", tostring(report.batch), tostring(report.seed), tostring(report.mode), selector, report.origin, tile_step),
        string.format("  entrance node=%d key=%s actor=%s [%s] loc=%s fallback=%s", entrance_node.index or 0, entrance_node.key or "", report.actor.name, report.actor.class, report.actor.location, tostring(fallback_used)),
        string.format("  patch_actor=%s frame_relative_yaw=%.1f frame_offset=%s", report.patch_actor_class_path, tonumber(report.patch_actor_frame_relative_yaw) or 0, report.patch_actor_frame_offset),
        "  note: " .. report.note,
        "  result=" .. report.result,
    }
    local result_line_index = 6
    write_report_files(file_stem .. "_attempt", report, lines)

    for _candidate_index, candidate in ipairs(selected or {}) do
        local entry = GENERATED_ENTRANCE_PROBE.patch_candidate_entry(entrance_node, origin, tile_step, candidate, 0)
        report.candidates[#report.candidates + 1] = entry
        lines[#lines + 1] = string.format(
            "  candidate %-24s group=%s mode=%s class=%s local=%s anchor=%s frame_yaw=%.1f actor_offset=%s actor_loc=%s actor_rot=%s",
            entry.key,
            entry.group,
            entry.actor_mode or "",
            entry.actor_class_path or "",
            entry.local_location,
            entry.frame_center,
            entry.frame_yaw,
            entry.actor_offset or "",
            entry.actor_location,
            entry.actor_rotation)
        lines[#lines + 1] = "    source=" .. tostring(entry.source or "")
        lines[#lines + 1] = "    notes=" .. tostring(entry.notes or "")
    end

    report.result = "about_to_probe_entrance_instance_components"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    report.instance_component_probe = GENERATED_ENTRANCE_PROBE.component_instance_patch_probe(entrance_actor, report.candidates, report, lines, result_line_index, file_stem)
    for _component_index, component in ipairs(report.instance_component_probe or {}) do
        local method_parts = {}
        for _method_index, method in ipairs(component.methods or {}) do
            method_parts[#method_parts + 1] = string.format("%s:%s/%s", method.name or "", tostring(method.present == true), method.value_type or "")
        end
        lines[#lines + 1] = string.format(
            "  component %-22s role=%s ok=%s valid=%s count=%d sampled=%d component=%s[%s] methods=%s",
            component.field or "",
            component.role or "",
            tostring(component.ok == true),
            tostring(component.valid == true),
            component.count or 0,
            component.sampled or 0,
            (component.component or {}).name or "",
            (component.component or {}).class or "",
            table.concat(method_parts, ", "))
        for error_index = 1, #(component.errors or {}) do
            lines[#lines + 1] = "    error: " .. tostring(component.errors[error_index])
        end
        for _nearest_index, nearest in ipairs(component.nearest or {}) do
            lines[#lines + 1] = string.format(
                "    nearest %-24s requested=%s index=%s loc=%s dist=%s",
                nearest.key or "",
                nearest.requested_frame_center or "",
                tostring(nearest.index or ""),
                nearest.location or "",
                nearest.distance and string.format("%.1f", nearest.distance) or "")
        end
    end

    report.result = "entrance_patchprobe_complete"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("batch=%s selector=%s candidates=%d components=%d", tostring(report.batch), selector, #report.candidates, #report.instance_component_probe)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_entrance_patchtest(args_str)
    local usage = "usage: world.dungeon.proc.generated.entrance.patchtest [latest] [closures|hubvisual|west|lower|north|upper|all|<candidate>] [z_offset_cm] confirm"
    local parsed, parse_error = GENERATED_ENTRANCE_PROBE.parse_patch_args(args_str, true)
    if not parsed then return false, usage .. " (" .. tostring(parse_error) .. ")" end
    local selected, selector, selector_error = GENERATED_ENTRANCE_PROBE.selected_patch_candidates(parsed.selector)
    if selector_error then return false, selector_error end

    local latest, _layout, entrance_node, entrance_actor, origin, tile_step, fallback_used, resolve_error = GENERATED_ENTRANCE_PROBE.resolve_latest()
    if resolve_error then return false, resolve_error end

    local file_stem = "dungeon_proc_generated_entrance_patchtest"
    local actor_loc, actor_loc_text = GENERATED_BOSSROOM_PROBE.location(entrance_actor)
    local report = {
        command = "world.dungeon.proc.generated.entrance.patchtest",
        confirmed = true,
        scope = "latest",
        selector = selector,
        z_offset_cm = tonumber(parsed.z_offset_cm) or 0,
        batch = latest.batch or generated_spawn_cache.latest_batch or 0,
        seed = latest.seed or 0,
        mode = latest.mode or "",
        origin = vec_text(origin),
        tile_step = tile_step,
        entrance_node = GENERATED_BOSSROOM_PROBE.node_summary(entrance_node),
        actor = {
            name = safe_name(entrance_actor),
            class = safety.class_name_of(entrance_actor) or "",
            full_name = safe_full_name(entrance_actor),
            location = actor_loc_text,
            fallback_used = fallback_used,
            state = GENERATED_ACTOR_PROBE.actor_state(entrance_actor),
        },
        patch_actor_class_path = GENERATED_ENTRANCE_PROBE.patch_actor_class_path,
        patch_actor_frame_relative_yaw = GENERATED_ENTRANCE_PROBE.patch_actor_frame_relative_yaw,
        patch_actor_frame_offset = vec_text(GENERATED_ENTRANCE_PROBE.patch_actor_frame_offset),
        candidates = {},
        spawns = {},
        spawned = 0,
        failed = 0,
        result = "about_to_spawn_entrance_patch_actors",
        note = "mutating entrance visual patch test: spawns temporary reviewed entrance cap/marker actors at selected gaps; cached with generated batch for spawnclear cleanup",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.entrance.patchtest --",
        string.format("  batch=%s seed=%s mode=%s selector=%s z_offset_cm=%.1f origin=%s tile_step=%.1f", tostring(report.batch), tostring(report.seed), tostring(report.mode), selector, report.z_offset_cm, report.origin, tile_step),
        string.format("  entrance node=%d key=%s actor=%s [%s] loc=%s fallback=%s", entrance_node.index or 0, entrance_node.key or "", report.actor.name, report.actor.class, report.actor.location, tostring(fallback_used)),
        string.format("  patch_actor=%s frame_relative_yaw=%.1f frame_offset=%s", report.patch_actor_class_path, tonumber(report.patch_actor_frame_relative_yaw) or 0, report.patch_actor_frame_offset),
        "  note: " .. report.note,
        "  result=" .. report.result,
    }
    local result_line_index = 6
    write_report_files(file_stem .. "_attempt", report, lines)

    for _candidate_index, candidate in ipairs(selected or {}) do
        local entry = GENERATED_ENTRANCE_PROBE.patch_candidate_entry(entrance_node, origin, tile_step, candidate, report.z_offset_cm)
        report.candidates[#report.candidates + 1] = entry
        local spawn_entry = {
            candidate_key = entry.key,
            frame_center = entry.frame_center,
            frame_yaw = entry.frame_yaw,
            actor_class_path = entry.actor_class_path,
            actor_mode = entry.actor_mode,
            actor_offset = entry.actor_offset,
            actor_location = entry.actor_location,
            actor_rotation = entry.actor_rotation,
            ok = false,
            actor = {},
            cache_entry = {},
            error = "",
        }
        report.result = "about_to_spawn_patch_" .. tostring(entry.key)
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local patch_actor, spawn_detail = GENERATED_BOSSROOM_PROBE.spawn_actor_deferred(entry.actor_class_path, entry.actor_loc, entry.actor_rot)
        if is_valid(patch_actor) then
            spawn_entry.ok = true
            spawn_entry.actor = {
                name = safe_name(patch_actor),
                class = safety.class_name_of(patch_actor) or "",
                full_name = safe_full_name(patch_actor),
                location = object_location_text(patch_actor),
                state = GENERATED_ACTOR_PROBE.actor_state(patch_actor),
            }
            local cache_entry = remember_generated_spawn_actor(report.batch, patch_actor, "entrance_patchtest_" .. tostring(entry.key), "entrance_patch_" .. tostring(entry.key))
            spawn_entry.cache_entry = cache_entry and {
                batch = cache_entry.batch or 0,
                label = cache_entry.label or "",
                ref = cache_entry.ref or "",
                name = cache_entry.name or "",
                full_name = cache_entry.full_name or "",
                location = cache_entry.location or "",
            } or {}
            report.spawned = report.spawned + 1
            lines[#lines + 1] = string.format("  spawn %-24s ok=true mode=%s class=%s anchor=%s actor_offset=%s actor=%s [%s] loc=%s rot=%s", entry.key, entry.actor_mode or "", entry.actor_class_path or "", entry.frame_center, entry.actor_offset or "", spawn_entry.actor.name or "", spawn_entry.actor.class or "", spawn_entry.actor.location or "", entry.actor_rotation)
        else
            spawn_entry.error = tostring(spawn_detail or "spawn failed")
            report.failed = report.failed + 1
            lines[#lines + 1] = string.format("  spawn %-24s ok=false mode=%s class=%s anchor=%s actor_offset=%s actor_loc=%s rot=%s error=%s", entry.key, entry.actor_mode or "", entry.actor_class_path or "", entry.frame_center, entry.actor_offset or "", entry.actor_location, entry.actor_rotation, spawn_entry.error)
        end
        report.spawns[#report.spawns + 1] = spawn_entry
    end

    report.result = "entrance_patchtest_complete"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("batch=%s selector=%s spawned=%d failed=%d z_offset_cm=%.1f", tostring(report.batch), selector, report.spawned, report.failed, report.z_offset_cm)
    if write_ok then return report.failed == 0, detail .. " wrote " .. tostring(write_detail) end
    return report.failed == 0, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_bossroom_probe(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.bossroom.probe [latest] confirm"
    if #tokens < 1 or #tokens > 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    if #tokens == 2 and tostring(tokens[1] or ""):lower() ~= "latest" then return false, usage end

    local latest = generated_spawn_cache.latest_connected
    if not latest or not latest.layout then
        return false, "no latest smart connected spawn is cached; run world.dungeon.proc.generator.spawnconnected first after each game reload"
    end

    local layout = latest.layout
    local origin = latest.origin or CONNECTED_SMART.default_origin
    local tile_step = tonumber(latest.tile_step) or DUNGEON_TILE_SIZE_CM
    local file_stem = "dungeon_proc_generated_bossroom_probe"
    local boss_node = nil
    for _node_index, node in ipairs(layout.nodes or {}) do
        if tostring(node.key or ""):lower() == "bossroom" then
            boss_node = node
            break
        end
    end
    if not boss_node then return false, "latest smart layout has no bossroom node; request at least the required-variety room count" end

    local room_state = (latest.rooms or {})[boss_node.index or 0] or {}
    local boss_actor = room_state.actor
    local fallback_used = false
    if not is_valid(boss_actor) then
        local bucket = find_objects({ "BP_BossRoom_C", "BossRoom" })
        if #bucket.live > 0 and is_valid(bucket.live[1]) then
            boss_actor = bucket.live[1]
            fallback_used = true
        end
    end
    if not is_valid(boss_actor) then return false, "bossroom actor unavailable; run probe in the same Lua session as spawnconnected" end

    local expected_loc = {
        X = (origin.X or 0) + (boss_node.cell_x or 0) * tile_step,
        Y = (origin.Y or 0) + (boss_node.cell_y or 0) * tile_step,
        Z = (origin.Z or 0) + ((boss_node.z_cm or 0) * (tile_step / DUNGEON_TILE_SIZE_CM)),
    }
    local actor_loc, actor_loc_text = GENERATED_BOSSROOM_PROBE.location(boss_actor)
    local rot = nil
    pcall(function() rot = feature_actor.actor_rotation(boss_actor) end)
    local actor_yaw = tonumber(rot and rot.Yaw) or 0
    local loc_delta = actor_loc and {
        x = (actor_loc.X or 0) - expected_loc.X,
        y = (actor_loc.Y or 0) - expected_loc.Y,
        z = (actor_loc.Z or 0) - expected_loc.Z,
    } or nil

    local report = {
        command = "world.dungeon.proc.generated.bossroom.probe",
        confirmed = true,
        scope = "latest",
        batch = latest.batch or 0,
        seed = latest.seed or 0,
        mode = latest.mode or "",
        origin = vec_text(origin),
        tile_step = tile_step,
        boss_node = GENERATED_BOSSROOM_PROBE.node_summary(boss_node),
        actor = {
            name = safe_name(boss_actor),
            class = safety.class_name_of(boss_actor) or "",
            full_name = safe_full_name(boss_actor),
            location = actor_loc_text,
            expected_location = vec_text(expected_loc),
            location_delta = loc_delta,
            yaw = actor_yaw,
            fallback_used = fallback_used,
            state = GENERATED_ACTOR_PROBE.actor_state(boss_actor),
        },
        edges = {},
        root_component = {},
        component_sets = {},
        object_scans = {},
        function_surface = {},
        result = "about_to_collect_boss_edges",
        note = "read-only bossroom probe: layout edge summary, method-name surface, component names/locations, and nearby/keyword dungeon objects only; no reflected spawner field reads and no method invocation",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.bossroom.probe --",
        string.format("  batch=%s seed=%s mode=%s origin=%s tile_step=%.1f", tostring(report.batch), tostring(report.seed), tostring(report.mode), report.origin, tile_step),
        string.format("  boss node=%d key=%s grid=%d,%d z_cm=%.1f yaw=%.1f actor=%s [%s]", boss_node.index or 0, boss_node.key or "", boss_node.cell_x or 0, boss_node.cell_y or 0, boss_node.z_cm or 0, boss_node.room_yaw or 0, report.actor.name, report.actor.class),
        string.format("  loc actual=%s expected=%s delta=%s,%s,%s fallback=%s", report.actor.location, report.actor.expected_location, tostring(loc_delta and loc_delta.x or ""), tostring(loc_delta and loc_delta.y or ""), tostring(loc_delta and loc_delta.z or ""), tostring(fallback_used)),
        "  note: " .. report.note,
        "  result=" .. report.result,
    }
    local result_line_index = 6
    write_report_files(file_stem .. "_attempt", report, lines)

    for _edge_index, edge in ipairs(layout.edges or {}) do
        if edge.parent == boss_node.index or edge.child == boss_node.index then
            local other_index = edge.parent == boss_node.index and edge.child or edge.parent
            local other_node = (layout.nodes or {})[other_index or 0]
            local other_state = (latest.rooms or {})[other_index or 0] or {}
            local parent_node = (layout.nodes or {})[edge.parent or 0]
            local child_node = (layout.nodes or {})[edge.child or 0]
            local parent_target = parent_node and edge.parent_opening and CONNECTED_SMART.wall_target(parent_node, edge.parent_opening, origin, tile_step) or nil
            local child_target = child_node and edge.child_opening and CONNECTED_SMART.wall_target(child_node, edge.child_opening, origin, tile_step) or nil
            local entry = {
                index = edge.index or 0,
                role = edge.parent == boss_node.index and "parent" or "child",
                direct = edge.direct == true,
                loop = edge.loop == true,
                dir = edge.dir or "",
                parent = GENERATED_BOSSROOM_PROBE.node_summary(parent_node),
                child = GENERATED_BOSSROOM_PROBE.node_summary(child_node),
                other = GENERATED_BOSSROOM_PROBE.node_summary(other_node),
                other_actor = {
                    name = other_state.name or "",
                    full_name = other_state.full_name or "",
                },
                parent_opening = CONNECTED_SMART.opening_copy(edge.parent_opening),
                child_opening = CONNECTED_SMART.opening_copy(edge.child_opening),
                parent_target = parent_target and vec_text(parent_target) or "",
                child_target = child_target and vec_text(child_target) or "",
            }
            report.edges[#report.edges + 1] = entry
            lines[#lines + 1] = string.format(
                "  edge[%03d] boss_role=%s other=%d:%s actor=%s direct=%s dir=%s parent_target=%s child_target=%s",
                entry.index,
                entry.role,
                other_index or 0,
                other_node and other_node.key or "",
                entry.other_actor.name,
                tostring(entry.direct),
                entry.dir,
                entry.parent_target,
                entry.child_target)
            lines[#lines + 1] = "    parent_opening " .. GENERATED_BOSSROOM_PROBE.opening_text(edge.parent_opening)
            lines[#lines + 1] = "    child_opening  " .. GENERATED_BOSSROOM_PROBE.opening_text(edge.child_opening)
        end
    end

    report.result = "about_to_collect_function_surface"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    local function_surface = GENERATED_ACTOR_PROBE.collect_function_surface(boss_actor, "all", 250)
    function_surface.keyword_methods = {}
    for _method_index, method in ipairs(function_surface.methods or {}) do
        local hits = GENERATED_BOSSROOM_PROBE.keyword_hits((method.name or "") .. " " .. (method.owner_class or "") .. " " .. (method.full_name or ""))
        if #hits > 0 then
            function_surface.keyword_methods[#function_surface.keyword_methods + 1] = {
                owner_class = method.owner_class or "",
                name = method.name or "",
                full_name = method.full_name or "",
                keyword_hits = hits,
            }
        end
    end
    report.function_surface = function_surface
    lines[#lines + 1] = string.format("  functions total=%d sampled=%d keyword_matches=%d omitted=%d", function_surface.total_functions or 0, #(function_surface.methods or {}), #(function_surface.keyword_methods or {}), function_surface.omitted_functions or 0)
    for index = 1, math.min(#(function_surface.keyword_methods or {}), 24) do
        local method = function_surface.keyword_methods[index]
        lines[#lines + 1] = string.format("    fn[%02d] %s::%s hits=%s", index, method.owner_class or "", method.name or "", table.concat(method.keyword_hits or {}, ","))
    end

    if boss_actor.K2_GetRootComponent then
        report.result = "about_to_K2_GetRootComponent"
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local root_ok, root_or_error = pcall(function() return boss_actor:K2_GetRootComponent() end)
        if root_ok and is_valid(root_or_error) then
            local _root_loc, root_loc_text = GENERATED_BOSSROOM_PROBE.component_location(root_or_error)
            report.root_component = { ok = true, name = safe_name(root_or_error), class = safety.class_name_of(root_or_error) or "", full_name = safe_full_name(root_or_error), location = root_loc_text }
            lines[#lines + 1] = string.format("  root %s [%s] loc=%s full=%s", report.root_component.name, report.root_component.class, report.root_component.location, report.root_component.full_name)
        else
            report.root_component = { ok = false, error = root_ok and "invalid root" or first_error_line(root_or_error) }
            lines[#lines + 1] = "  root <failed: " .. tostring(report.root_component.error) .. ">"
        end
    end

    for _component_index, component_spec in ipairs(GENERATED_BOSSROOM_PROBE.component_specs) do
        report.result = "about_to_components_" .. component_spec.label
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local entry = GENERATED_BOSSROOM_PROBE.component_sample(boss_actor, component_spec.class_path, component_spec.label, GENERATED_BOSSROOM_PROBE.component_sample_limit)
        report.component_sets[#report.component_sets + 1] = entry
        if entry.ok then
            lines[#lines + 1] = string.format("  components %-28s count=%d sampled=%d keyword_samples=%d", entry.label, entry.count, entry.sampled, entry.keyword_count)
            for index = 1, math.min(#entry.keyword_samples, 18) do
                local sample = entry.keyword_samples[index]
                lines[#lines + 1] = string.format("    comp[%02d] %s [%s] loc=%s hits=%s", sample.index or 0, sample.name or "", sample.class or "", sample.location or "", table.concat(sample.keyword_hits or {}, ","))
            end
            if #entry.keyword_samples == 0 and #entry.samples > 0 then
                local sample_parts = {}
                for index = 1, math.min(#entry.samples, 4) do
                    local sample = entry.samples[index]
                    sample_parts[#sample_parts + 1] = (sample.name or "") .. "[" .. (sample.class or "") .. "]"
                end
                lines[#lines + 1] = "    sample=" .. table.concat(sample_parts, ", ")
            end
        else
            lines[#lines + 1] = string.format("  components %-28s <failed: %s>", entry.label, entry.error)
        end
    end

    for _spec_index, spec in ipairs(GENERATED_BOSSROOM_PROBE.object_specs) do
        report.result = "about_to_scan_" .. spec.key
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local bucket = find_objects(spec.queries)
        local scan = { key = spec.key, queries = spec.queries, found = #bucket.live, defaults = #bucket.defaults, matched = 0, sampled = 0, errors = bucket.errors, samples = {} }
        for object_index, obj in ipairs(bucket.live) do
            local full_name = safe_full_name(obj)
            local name = name_from_full_name(full_name)
            local class_name = safety.class_name_of(obj) or (tostring(full_name):match("^([^%s]+)") or "")
            local obj_loc, obj_loc_text = GENERATED_BOSSROOM_PROBE.location(obj)
            local distance = GENERATED_BOSSROOM_PROBE.distance(actor_loc, obj_loc)
            local hits = GENERATED_BOSSROOM_PROBE.keyword_hits(name .. " " .. class_name .. " " .. full_name)
            local include = spec.always_sample == true or #hits > 0 or (distance ~= nil and distance <= GENERATED_BOSSROOM_PROBE.near_distance_cm)
            if include then
                scan.matched = scan.matched + 1
                if scan.sampled < GENERATED_BOSSROOM_PROBE.object_sample_limit then
                    scan.samples[#scan.samples + 1] = {
                        index = object_index,
                        name = name,
                        class = class_name,
                        full_name = full_name,
                        location = obj_loc_text,
                        distance = distance,
                        keyword_hits = hits,
                    }
                    scan.sampled = scan.sampled + 1
                end
            end
        end
        report.object_scans[#report.object_scans + 1] = scan
        lines[#lines + 1] = string.format("  objects %-22s found=%d defaults=%d matched=%d sampled=%d", scan.key, scan.found, scan.defaults, scan.matched, scan.sampled)
        for index = 1, math.min(#scan.samples, 12) do
            local sample = scan.samples[index]
            lines[#lines + 1] = string.format("    obj[%03d] %s [%s] loc=%s dist=%s hits=%s", sample.index or 0, sample.name or "", sample.class or "", sample.location or "", sample.distance and string.format("%.1f", sample.distance) or "", table.concat(sample.keyword_hits or {}, ","))
        end
    end

    report.result = "bossroom_probe_complete"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("batch=%s node=%s edges=%d components=%d object_scans=%d functions=%d", tostring(report.batch), tostring(boss_node.index or 0), #report.edges, #report.component_sets, #report.object_scans, #(function_surface.keyword_methods or {}))
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_surface(args_str)
    local target_token, index_token, confirm_token = trim(args_str):match("^(%S*)%s*(%S*)%s*(%S*)")
    local target_key = tostring(target_token or ""):lower()
    local target_spec = GENERATED_ACTOR_PROBE.surface_targets[target_key]
    if not target_spec then
        return false, "usage: world.dungeon.proc.generated.surface <room|hallway> [index] confirm"
    end
    local index = 1
    if index_token == "confirm" or index_token == "" then
        confirm_token = index_token == "confirm" and "confirm" or confirm_token
    else
        local parsed_index = tonumber(index_token)
        if not parsed_index then return false, "index must be a number" end
        index = math.floor(parsed_index)
    end
    if confirm_token ~= "confirm" then
        return false, "usage: world.dungeon.proc.generated.surface <room|hallway> [index] confirm"
    end

    local bucket = find_objects(target_spec.queries)
    if index < 1 or index > #bucket.live then
        return false, string.format("%s index out of range 1..%d", target_key, #bucket.live)
    end
    local actor = bucket.live[index]
    if not is_valid(actor) then return false, "selected generated actor invalid" end

    local file_stem = "dungeon_proc_generated_surface_" .. target_key
    local report = {
        command = "world.dungeon.proc.generated.surface",
        target = target_key,
        index = index,
        count = #bucket.live,
        errors = bucket.errors,
        confirmed = true,
        actor = {
            index = index,
            name = safe_name(actor),
            class = safety.class_name_of(actor) or "",
            full_name = safe_full_name(actor),
            location = object_location_text(actor),
            state = GENERATED_ACTOR_PROBE.actor_state(actor),
        },
        methods = {},
        fields = {},
        instance_components = {},
        root_component = {},
        component_sets = {},
        result = "about_to_lookup_methods",
        note = "safe surface probe: method lookup, whitelisted field counts/values, root/component inventory, ISM count/transform samples only; no Init/CreateRoom/CreateHallway/teleport lifecycle calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.surface --",
        string.format("  target=%s index=%d count=%d", target_key, index, #bucket.live),
        string.format("  actor %s [%s] loc=%s state=%s", report.actor.name, report.actor.class, report.actor.location, report.actor.state.text),
        "  note: " .. report.note,
        "  result=" .. report.result,
    }
    local result_line_index = 5
    for error_index = 1, #bucket.errors do lines[#lines + 1] = "  error: " .. tostring(bucket.errors[error_index]) end

    for _method_index, method_name in ipairs(GENERATED_ACTOR_PROBE.surface_methods[target_key] or {}) do
        report.result = "about_to_lookup_method_" .. method_name
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local entry = GENERATED_ACTOR_PROBE.method_entry(actor, method_name)
        report.methods[#report.methods + 1] = entry
        lines[#lines + 1] = string.format("  method %-32s present=%s type=%s", method_name, tostring(entry.present), entry.value_type)
        if entry.error ~= "" then lines[#lines + 1] = "    error: " .. entry.error end
    end

    for _field_index, field_spec in ipairs(GENERATED_ACTOR_PROBE.surface_fields[target_key] or {}) do
        report.result = "about_to_read_field_" .. field_spec.name
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local entry = GENERATED_ACTOR_PROBE.read_field_entry(actor, field_spec)
        report.fields[#report.fields + 1] = entry
        if entry.ok then
            lines[#lines + 1] = string.format("  field %-32s %s", field_spec.name, entry.value)
        else
            lines[#lines + 1] = string.format("  field %-32s <read failed: %s>", field_spec.name, entry.error)
        end
    end

    for _instance_index, field_spec in ipairs(GENERATED_ACTOR_PROBE.instance_component_fields[target_key] or {}) do
        local entry = GENERATED_ACTOR_PROBE.instance_component_entry(actor, field_spec, report, lines, result_line_index, file_stem)
        report.instance_components[#report.instance_components + 1] = entry
        if entry.ok then
            lines[#lines + 1] = string.format(
                "  ism %-32s role=%s count=%d component=%s[%s]%s",
                field_spec.name,
                tostring(entry.role),
                entry.count,
                entry.component.name or "",
                entry.component.class or "",
                GENERATED_ACTOR_PROBE.instance_component_sample_text(entry))
        else
            lines[#lines + 1] = string.format("  ism %-32s role=%s <read failed: %s>", field_spec.name, tostring(entry.role), entry.error)
        end
    end

    if actor.K2_GetRootComponent then
        report.result = "about_to_K2_GetRootComponent"
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local root_ok, root_or_error = pcall(function() return actor:K2_GetRootComponent() end)
        if root_ok and is_valid(root_or_error) then
            report.root_component = { ok = true, name = safe_name(root_or_error), class = safety.class_name_of(root_or_error) or "", full_name = safe_full_name(root_or_error) }
            lines[#lines + 1] = string.format("  root %s [%s] full=%s", report.root_component.name, report.root_component.class, report.root_component.full_name)
        else
            report.root_component = { ok = false, error = root_ok and "invalid root" or first_error_line(root_or_error) }
            lines[#lines + 1] = "  root <failed: " .. tostring(report.root_component.error) .. ">"
        end
    end

    local component_specs = {
        { label = "ActorComponent", class_path = "/Script/Engine.ActorComponent" },
        { label = "SceneComponent", class_path = "/Script/Engine.SceneComponent" },
        { label = "StaticMeshComponent", class_path = "/Script/Engine.StaticMeshComponent" },
        { label = "InstancedStaticMeshComponent", class_path = "/Script/Engine.InstancedStaticMeshComponent" },
    }
    for _component_index, component_spec in ipairs(component_specs) do
        report.result = "about_to_components_" .. component_spec.label
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local entry = GENERATED_ACTOR_PROBE.component_sample(actor, component_spec.class_path, component_spec.label)
        report.component_sets[#report.component_sets + 1] = entry
        if entry.ok then
            local sample_parts = {}
            for sample_index = 1, #entry.samples do
                sample_parts[#sample_parts + 1] = entry.samples[sample_index].name .. "[" .. entry.samples[sample_index].class .. "]"
            end
            lines[#lines + 1] = string.format("  components %-28s count=%d sample=%s", entry.label, entry.count, table.concat(sample_parts, ", "))
        else
            lines[#lines + 1] = string.format("  components %-28s <failed: %s>", entry.label, entry.error)
        end
    end

    report.result = "surface_complete"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("target=%s index=%d methods=%d fields=%d ism=%d components=%d", target_key, index, #report.methods, #report.fields, #report.instance_components, #report.component_sets)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_wallprobe(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.wallprobe <room_index> [limit|all] confirm"
    if #tokens < 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    local room_index = tonumber(tokens[1])
    if not room_index then return false, "room_index must be a number" end
    room_index = math.floor(room_index)
    if room_index < 1 then return false, "room_index must be >= 1" end
    local limit = 128
    if #tokens >= 3 then
        local limit_token = tostring(tokens[2] or ""):lower()
        if limit_token == "all" then
            limit = 512
        else
            limit = tonumber(limit_token)
            if not limit then return false, "limit must be a number or all" end
            limit = math.floor(limit)
        end
    end
    if limit < 1 then return false, "limit must be >= 1" end

    local actor, bucket, target_error = GENERATED_ACTOR_PROBE.target_actor("room", room_index)
    if not actor then return false, target_error end
    local file_stem = "dungeon_proc_generated_wallprobe_room"
    local report = {
        command = "world.dungeon.proc.generated.wallprobe",
        target = "room",
        index = room_index,
        count = bucket and #bucket.live or 0,
        confirmed = true,
        limit = limit,
        actor = {
            index = room_index,
            name = safe_name(actor),
            class = safety.class_name_of(actor) or "",
            full_name = safe_full_name(actor),
            location = object_location_text(actor),
            state = GENERATED_ACTOR_PROBE.actor_state(actor),
        },
        walls = {},
        result = "about_to_probe_wall_instances",
        note = "read-only WallISM/WallISMComponent instance transform dump; no RemoveInstance or room lifecycle calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.wallprobe --",
        string.format("  target=room index=%d count=%d limit=%d", room_index, report.count, limit),
        string.format("  actor %s [%s] loc=%s state=%s", report.actor.name, report.actor.class, report.actor.location, report.actor.state.text),
        "  note: " .. report.note,
        "  result=" .. report.result,
    }
    local result_line_index = 5
    local walls = GENERATED_ACTOR_PROBE.wall_instances(actor, report, lines, result_line_index, file_stem, limit)
    report.walls = walls
    lines[result_line_index] = "  result=wallprobe_complete"
    lines[#lines + 1] = string.format(
        "  wall_component field=%s component=%s[%s] count=%d sampled=%d",
        walls.component_field or "",
        walls.component and walls.component.name or "",
        walls.component and walls.component.class or "",
        walls.count or 0,
        walls.sampled or 0)
    for error_index = 1, #(walls.errors or {}) do
        lines[#lines + 1] = "  error: " .. tostring(walls.errors[error_index])
    end
    for instance_index = 1, #(walls.instances or {}) do
        local instance = walls.instances[instance_index]
        if instance.ok then
            lines[#lines + 1] = string.format("  wall[%03d] loc=%s", instance.index, instance.location)
        else
            lines[#lines + 1] = string.format("  wall[%03d] <read failed: %s>", instance.index, instance.error)
        end
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("room_index=%d walls=%d sampled=%d", room_index, walls.count or 0, walls.sampled or 0)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_wallremove(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.wallremove <room_index> <x> <y> <z> [max_distance] confirm"
    if #tokens < 5 or tokens[#tokens] ~= "confirm" then return false, usage end
    local room_index = tonumber(tokens[1])
    local target_x = tonumber(tokens[2])
    local target_y = tonumber(tokens[3])
    local target_z = tonumber(tokens[4])
    if not room_index then return false, "room_index must be a number" end
    if not target_x or not target_y or not target_z then return false, "x y z must be numbers" end
    room_index = math.floor(room_index)
    if room_index < 1 then return false, "room_index must be >= 1" end
    local max_distance = 150.0
    if #tokens >= 6 then
        max_distance = tonumber(tokens[5])
        if not max_distance then return false, "max_distance must be a number" end
    end
    if max_distance <= 0 then return false, "max_distance must be > 0" end
    local target = { X = target_x, Y = target_y, Z = target_z }

    local actor, bucket, target_error = GENERATED_ACTOR_PROBE.target_actor("room", room_index)
    if not actor then return false, target_error end
    local file_stem = "dungeon_proc_generated_wallremove_room"
    local report = {
        command = "world.dungeon.proc.generated.wallremove",
        target = "room",
        index = room_index,
        count = bucket and #bucket.live or 0,
        confirmed = true,
        requested_location = vec_text(target),
        max_distance = max_distance,
        actor = {
            index = room_index,
            name = safe_name(actor),
            class = safety.class_name_of(actor) or "",
            full_name = safe_full_name(actor),
            location = object_location_text(actor),
            state = GENERATED_ACTOR_PROBE.actor_state(actor),
        },
        walls_before = {},
        nearest = nil,
        remove = { ok = false, returned = nil, error = "" },
        count_after = nil,
        result = "about_to_find_nearest_wall",
        note = "mutating probe: removes one nearest WallISM instance only after explicit coordinate match; no room lifecycle calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.wallremove --",
        string.format("  target=room index=%d count=%d requested=%s max_distance=%.1f", room_index, report.count, report.requested_location, max_distance),
        string.format("  actor %s [%s] loc=%s state=%s", report.actor.name, report.actor.class, report.actor.location, report.actor.state.text),
        "  note: " .. report.note,
        "  result=" .. report.result,
    }
    local result_line_index = 5
    local walls, component = GENERATED_ACTOR_PROBE.wall_instances(actor, report, lines, result_line_index, file_stem, 512)
    report.walls_before = walls
    local nearest = GENERATED_ACTOR_PROBE.nearest_wall_instance(walls, target)
    report.nearest = nearest
    if not nearest then
        report.result = "no_wall_instance_found"
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  nearest=<none>"
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files(file_stem, report, lines)
        if write_ok then return false, "no wall instance found wrote " .. tostring(write_detail) end
        return false, "no wall instance found; file write failed: " .. tostring(write_detail)
    end
    lines[#lines + 1] = string.format("  nearest index=%d loc=%s distance=%.1f", nearest.index, nearest.location, nearest.distance)
    if nearest.distance > max_distance then
        report.result = "nearest_wall_out_of_range"
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = string.format("  skipped: nearest distance %.1f > max_distance %.1f", nearest.distance, max_distance)
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files(file_stem, report, lines)
        if write_ok then return false, "nearest wall out of range wrote " .. tostring(write_detail) end
        return false, "nearest wall out of range; file write failed: " .. tostring(write_detail)
    end

    report.result = "about_to_RemoveInstance_" .. tostring(nearest.index)
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    local remove_ok, remove_return_or_error = pcall(function() return component:RemoveInstance(nearest.index) end)
    report.remove.ok = remove_ok == true and remove_return_or_error ~= false
    report.remove.returned = remove_ok and remove_return_or_error or nil
    report.remove.error = remove_ok and "" or first_error_line(remove_return_or_error)

    report.result = report.remove.ok and "wallremove_complete" or "wallremove_failed"
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = string.format("  RemoveInstance(%d) ok=%s returned=%s", nearest.index, tostring(report.remove.ok), tostring(report.remove.returned))
    if report.remove.error ~= "" then lines[#lines + 1] = "  error: " .. report.remove.error end

    report.result = "about_to_after_GetInstanceCount"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    local count_ok, count_or_error = pcall(function() return component:GetInstanceCount() end)
    if count_ok then
        report.count_after = tonumber(count_or_error) or 0
        lines[#lines + 1] = string.format("  wall_count %d -> %d", walls.count or 0, report.count_after)
    else
        lines[#lines + 1] = "  wall_count_after <failed: " .. first_error_line(count_or_error) .. ">"
    end

    report.result = report.remove.ok and "wallremove_complete" or "wallremove_failed"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("room_index=%d removed=%s nearest=%d distance=%.1f count=%d->%s", room_index, tostring(report.remove.ok), nearest.index, nearest.distance, walls.count or 0, tostring(report.count_after))
    if write_ok then return report.remove.ok, detail .. " wrote " .. tostring(write_detail) end
    return report.remove.ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_openwalls(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.openwalls [latest] [max_distance] confirm"
    if #tokens < 1 or tokens[#tokens] ~= "confirm" then return false, usage end
    local scope = "latest"
    local max_distance = 150.0
    local arg_limit = #tokens - 1
    if arg_limit >= 1 then
        local first = tostring(tokens[1] or ""):lower()
        if first == "latest" then
            scope = first
            if arg_limit >= 2 then
                max_distance = tonumber(tokens[2])
                if not max_distance then return false, "max_distance must be a number" end
            end
        else
            max_distance = tonumber(tokens[1])
            if not max_distance then return false, usage end
        end
    end
    if scope ~= "latest" then return false, "only latest is supported for now" end
    if max_distance <= 0 then return false, "max_distance must be > 0" end

    local latest = generated_spawn_cache.latest_connected
    if not latest or not (latest.mode == "smart" or latest.mode == "smartdirect") or not latest.layout then
        return false, "no latest smart connected spawn in this Lua session; run generator.spawnconnected smart first after each game reload"
    end
    local layout = latest.layout
    local origin = latest.origin or CONNECTED_SMART.default_origin
    local tile_step = tonumber(latest.tile_step) or DUNGEON_TILE_SIZE_CM
    local file_stem = "dungeon_proc_generated_openwalls"
    local report = {
        command = "world.dungeon.proc.generated.openwalls",
        confirmed = true,
        scope = scope,
        batch = latest.batch or 0,
        max_distance = max_distance,
        origin = vec_text(origin),
        tile_step = tile_step,
        edge_count = #(layout.edges or {}),
        endpoints = {},
        removed = 0,
        skipped = 0,
        failed = 0,
        result = "about_to_open_latest_smart_walls",
        note = "mutating pass: removes nearest WallISM instance at each cached smart connector endpoint; requires same Lua session as spawnconnected",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.openwalls --",
        string.format("  scope=%s batch=%d edges=%d max_distance=%.1f origin=%s tile_step=%.1f", scope, report.batch, report.edge_count, max_distance, report.origin, tile_step),
        "  note: " .. report.note,
        "  result=" .. report.result,
    }
    local result_line_index = 4

    local function process_endpoint(edge, endpoint_role, room_index, opening)
        local node = (layout.nodes or {})[room_index]
        local room_state = (latest.rooms or {})[room_index]
        local entry = {
            edge = edge.index or 0,
            role = endpoint_role,
            room = room_index or 0,
            actor = room_state and room_state.name or "",
            opening = CONNECTED_SMART.opening_copy(opening),
            target = "",
            height = 0,
            result = nil,
            status = "pending",
            error = "",
        }
        if not node or not opening then
            entry.status = "failed"
            entry.error = "missing node/opening metadata"
            report.failed = report.failed + 1
            report.endpoints[#report.endpoints + 1] = entry
            return entry
        end
        if not room_state or not is_valid(room_state.actor) then
            entry.status = "failed"
            entry.error = "room actor unavailable"
            report.failed = report.failed + 1
            report.endpoints[#report.endpoints + 1] = entry
            return entry
        end
        local target, height = CONNECTED_SMART.wall_target(node, opening, origin, tile_step)
        entry.target = vec_text(target)
        entry.height = height or 0
        if opening.openwalls_skip == true then
            entry.status = "skipped"
            entry.error = opening.openwalls_skip_reason or "special connector endpoint skipped"
            entry.result = { ok = false, skipped = true, error = entry.error, special_connector = opening.connector_kind or "" }
            report.skipped = report.skipped + 1
            report.endpoints[#report.endpoints + 1] = entry
            return entry
        end
        report.result = "about_to_remove_edge_" .. tostring(entry.edge) .. "_" .. endpoint_role .. "_room_" .. tostring(room_index)
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local remove = GENERATED_ACTOR_PROBE.remove_nearest_wall_instance(room_state.actor, target, max_distance)
        entry.result = remove
        if remove.ok then
            entry.status = "removed"
            report.removed = report.removed + 1
        elseif remove.skipped then
            entry.status = "skipped"
            entry.error = remove.error or "skipped"
            report.skipped = report.skipped + 1
        else
            entry.status = "failed"
            entry.error = remove.error or "failed"
            report.failed = report.failed + 1
        end
        report.endpoints[#report.endpoints + 1] = entry
        return entry
    end

    for _edge_index, edge in ipairs(layout.edges or {}) do
        local parent_entry = process_endpoint(edge, "parent", edge.parent or 0, edge.parent_opening)
        local child_entry = process_endpoint(edge, "child", edge.child or 0, edge.child_opening)
        for _entry_index, entry in ipairs({ parent_entry, child_entry }) do
            local nearest = entry.result and entry.result.nearest or nil
            local nearest_text = nearest and string.format("nearest=%d %s dist=%.1f", nearest.index or -1, nearest.location or "", nearest.distance or -1) or "nearest=<none>"
            lines[#lines + 1] = string.format(
                "  edge[%03d] %-6s room=%d actor=%s opening=%s:%s target=%s status=%s %s",
                entry.edge or 0,
                entry.role or "",
                entry.room or 0,
                entry.actor or "",
                tostring(entry.opening and entry.opening.cell_x or "?"),
                tostring(entry.opening and entry.opening.cell_y or "?"),
                entry.target or "",
                entry.status or "",
                nearest_text)
            if entry.error ~= "" then lines[#lines + 1] = "    note: " .. entry.error end
        end
    end

    report.result = report.failed == 0 and "openwalls_complete" or "openwalls_partial"
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = string.format("  openwalls_summary removed=%d skipped=%d failed=%d endpoints=%d", report.removed, report.skipped, report.failed, #report.endpoints)
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("batch=%d edges=%d removed=%d skipped=%d failed=%d", report.batch, report.edge_count, report.removed, report.skipped, report.failed)
    if write_ok then return report.failed == 0, detail .. " wrote " .. tostring(write_detail) end
    return report.failed == 0, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generated_floorcell(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generated.floorcell [room_index] [dimension] [x y height] confirm"
    if #tokens < 1 or tokens[#tokens] ~= "confirm" then return false, usage end
    local arg_count = #tokens - 1
    local room_index, dimension, loc_x, loc_y, height = 1, 1, 0, 0, 1
    if arg_count == 1 then
        room_index = tonumber(tokens[1]) or room_index
    elseif arg_count == 2 then
        room_index = tonumber(tokens[1]) or room_index
        dimension = tonumber(tokens[2]) or dimension
    elseif arg_count == 5 then
        room_index = tonumber(tokens[1]) or room_index
        dimension = tonumber(tokens[2]) or dimension
        loc_x = tonumber(tokens[3]) or loc_x
        loc_y = tonumber(tokens[4]) or loc_y
        height = tonumber(tokens[5]) or height
    elseif arg_count ~= 0 then
        return false, usage
    end
    room_index = math.floor(room_index)
    dimension = math.floor(dimension)
    height = math.floor(height)
    if room_index < 1 then return false, "room_index must be >= 1" end
    if dimension < 1 then return false, "dimension must be >= 1" end
    if height < 1 then return false, "height must be >= 1" end

    local bucket = find_objects({ "DungeonProceduralRoomUnit" })
    if room_index > #bucket.live then return false, string.format("room index out of range 1..%d", #bucket.live) end
    local room = bucket.live[room_index]
    if not is_valid(room) then return false, "selected procedural room invalid" end
    if not room.GenerateFloorCell then return false, "selected room has no GenerateFloorCell method" end

    local file_stem = "dungeon_proc_generated_floorcell"
    local report = {
        command = "world.dungeon.proc.generated.floorcell",
        room_index = room_index,
        count = #bucket.live,
        errors = bucket.errors,
        confirmed = true,
        args = { dimension = dimension, x = loc_x, y = loc_y, height = height },
        room = { name = safe_name(room), class = safety.class_name_of(room) or "", full_name = safe_full_name(room), location = object_location_text(room), state = GENERATED_ACTOR_PROBE.actor_state(room) },
        before = {},
        after = {},
        result = "about_to_snapshot_before",
        error = "",
        warning = "calls only ADungeonProceduralRoomUnit.GenerateFloorCell with primitive args; no Init/CreateRoom/teleport lifecycle calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generated.floorcell --",
        string.format("  room[%d/%d] %s [%s] loc=%s state=%s", room_index, #bucket.live, report.room.name, report.room.class, report.room.location, report.room.state.text),
        string.format("  args dimension=%d x=%.1f y=%.1f height=%d", dimension, loc_x, loc_y, height),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    local result_line_index = 5
    for error_index = 1, #bucket.errors do lines[#lines + 1] = "  error: " .. tostring(bucket.errors[error_index]) end

    report.before = GENERATED_ACTOR_PROBE.room_snapshot(room, file_stem, report, lines, result_line_index, "before")
    lines[#lines + 1] = "  before " .. table.concat(report.before.parts, " ")
    report.result = "about_to_call_GenerateFloorCell"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    local call_ok, call_error = pcall(function() return room:GenerateFloorCell(dimension, loc_x, loc_y, height) end)
    local call_result = call_ok and "called_GenerateFloorCell" or "GenerateFloorCell_failed"
    report.result = call_result
    report.error = call_ok and "" or first_error_line(call_error)
    lines[result_line_index] = "  result=" .. report.result
    if not call_ok then lines[#lines + 1] = "  call error: " .. report.error end
    report.after = GENERATED_ACTOR_PROBE.room_snapshot(room, file_stem, report, lines, result_line_index, "after")
    report.result = call_result
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = "  after " .. table.concat(report.after.parts, " ")

    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("room=%d dimension=%d height=%d result=%s", room_index, dimension, height, report.result)
    if write_ok then return call_ok, detail .. " wrote " .. tostring(write_detail) end
    return call_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generator_fieldone(args_str)
    local index_token, field_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)")
    if not index_token or not field_token then
        return false, "usage: world.dungeon.proc.generator.fieldone <index> <" .. generator_fieldone_options() .. "> confirm"
    end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    if confirm_token ~= "confirm" then
        return false, "single generator field probe requires: world.dungeon.proc.generator.fieldone <index> <" .. generator_fieldone_options() .. "> confirm"
    end
    local field_spec, field_key = generator_fieldone_spec(field_token)
    if not field_spec then return false, "unknown field; choose one of: " .. generator_fieldone_options() end

    return false, "disabled: direct UDungeonGenerator." .. tostring(field_spec.field) .. " reflected reads can crash; use world.dungeon.proc.generator.autowire <model_index> confirm, then world.dungeon.proc.managers/generated, then optionally world.dungeon.proc.generator.callone <index> rooms_options confirm"
end

function M.generator_classrefs(args_str)
    local first_token, second_token = trim(args_str):match("^(%S*)%s*(%S*)")
    local source_token = first_token
    local confirm_token = second_token
    if source_token == "confirm" then
        source_token = "cdo"
        confirm_token = "confirm"
    end
    if source_token == "" then source_token = "cdo" end
    if confirm_token ~= "confirm" then
        return false, "usage: world.dungeon.proc.generator.classrefs [cdo|generator_index] confirm"
    end

    local file_stem = "dungeon_proc_generator_classrefs"
    local generator, source, resolve_error = resolve_generator_ref_source(source_token, file_stem)
    if resolve_error then return false, resolve_error end
    if not source then return false, "generator source metadata unavailable" end
    if not is_valid(generator) then return false, "generator source unavailable" end

    local report = {
        command = "world.dungeon.proc.generator.classrefs",
        source = source,
        current_field = "",
        result = "about_to_read_classrefs",
        refs = {},
        warning = "reads only UDungeonGenerator RoomSpawnSubclass/HallwaySpawnSubclass class refs; attempt file marks the exact field before each read",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generator.classrefs --",
        string.format("  source=%s index=%d %s [%s] full=%s", source.mode, source.index or 0, source.name or "", source.class or "", source.full_name or ""),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    local result_line_index = 4

    for _ref_index, ref_key in ipairs(GENERATOR_CLASSREF_ORDER) do
        local ref_spec = GENERATOR_CLASSREF_FIELDS[ref_key]
        report.current_field = ref_spec.field
        report.result = "about_to_read_" .. ref_spec.field
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local read_ok, value = read_field(generator, ref_spec.field)
        local entry = {
            key = ref_key,
            field = ref_spec.field,
            ok = read_ok == true,
            value_type = type(value),
            value = read_ok and value_label(value) or "",
            name = read_ok and safe_name(value) or "",
            class = read_ok and (safety.class_name_of(value) or "") or "",
            full_name = read_ok and safe_full_name(value) or "",
            valid = read_ok and is_valid(value) or false,
            error = read_ok and "" or first_error_line(value),
        }
        report.refs[#report.refs + 1] = entry
        if read_ok then
            lines[#lines + 1] = string.format("  %s ok valid=%s type=%s value=%s full=%s", ref_spec.field, tostring(entry.valid), entry.value_type, entry.value, entry.full_name)
        else
            lines[#lines + 1] = string.format("  %s failed: %s", ref_spec.field, entry.error)
        end
    end

    report.current_field = "complete"
    report.result = "complete"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("source=%s refs=%d", source.mode or "", #report.refs)
    if file_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generator_spawnref(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generator.spawnref [cdo|generator_index] <" .. generator_classref_options() .. "> [" .. manual_spawn_method_options() .. "] [dx dy dz] confirm"
    if #tokens < 2 then return false, usage end

    local source_token = "cdo"
    local ref_token = tokens[1]
    local arg_index = 2
    if not GENERATOR_CLASSREF_FIELDS[tostring(ref_token or ""):lower()] then
        source_token = tokens[1]
        ref_token = tokens[2]
        arg_index = 3
    end
    local ref_spec, ref_key = generator_classref_spec(ref_token)
    if not ref_spec then return false, "unknown generator class ref; choose one of: " .. generator_classref_options() end

    local method_key = "world_place"
    local maybe_method = tokens[arg_index] and tostring(tokens[arg_index]):lower() or ""
    if MANUAL_SPAWN_METHOD_ALIASES[maybe_method] then
        method_key = MANUAL_SPAWN_METHOD_ALIASES[maybe_method]
        arg_index = arg_index + 1
    end

    local dx, dy, dz = 300, 0, 0
    local confirm_token = tokens[arg_index]
    local remaining = #tokens - arg_index + 1
    if remaining == 4 then
        local parsed_dx = tonumber(tokens[arg_index])
        local parsed_dy = tonumber(tokens[arg_index + 1])
        local parsed_dz = tonumber(tokens[arg_index + 2])
        confirm_token = tokens[arg_index + 3]
        if not parsed_dx or not parsed_dy or not parsed_dz then return false, "dx/dy/dz must be numbers" end
        dx, dy, dz = parsed_dx, parsed_dy, parsed_dz
    elseif remaining ~= 1 then
        return false, usage
    end
    if confirm_token ~= "confirm" then return false, usage end

    local use_world_spawn = method_key == "world" or method_key == "world_place"
    local place_after_spawn = method_key == "deferred_place" or method_key == "world_place"
    local file_stem = "dungeon_proc_generator_spawnref"

    local generator, source, resolve_error = resolve_generator_ref_source(source_token, file_stem)
    if resolve_error then return false, resolve_error end
    if not source then return false, "generator source metadata unavailable" end
    if not is_valid(generator) then return false, "generator source unavailable" end

    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return false, "local pawn unavailable" end
    local base_loc = nil
    pcall(function() base_loc = feature_actor.actor_location(pawn) end)
    if not base_loc then return false, "local pawn location unavailable" end
    local spawn_loc = {
        X = (tonumber(base_loc.X) or 0) + dx,
        Y = (tonumber(base_loc.Y) or 0) + dy,
        Z = (tonumber(base_loc.Z) or 0) + dz,
    }
    local cache_batch = begin_generated_spawn_batch("spawnref:" .. ref_key)

    local report = {
        command = "world.dungeon.proc.generator.spawnref",
        confirmed = true,
        cache_batch = cache_batch,
        source = source,
        ref = { key = ref_key, field = ref_spec.field },
        method = method_key,
        base = { name = safe_name(pawn), class = safety.class_name_of(pawn) or "", full_name = safe_full_name(pawn), location = vec_text(base_loc) },
        offset = { x = dx, y = dy, z = dz },
        spawn_location = vec_text(spawn_loc),
        class_ref = {},
        actor = {},
        placement = { requested = place_after_spawn, attempted = false, ok = false, before = "", after = "", error = "" },
        before_counts = generated_counts_snapshot(),
        after_counts = {},
        generated_deltas = {},
        result = "about_to_read_" .. ref_spec.field,
        error = "",
        world_route = "",
        warning = "reads one generator class ref, then spawns that returned class; no Init/CreateRoom/CreateHallway/teleport lifecycle calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generator.spawnref --",
        string.format("  source=%s index=%d %s [%s]", source.mode, source.index or 0, source.name or "", source.class or ""),
        "  ref=" .. ref_key .. " field=" .. ref_spec.field .. " method=" .. method_key,
        string.format("  base pawn %s [%s] loc=%s", report.base.name, report.base.class, report.base.location),
        string.format("  offset=%.1f,%.1f,%.1f spawn=%s", dx, dy, dz, report.spawn_location),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    local result_line_index = 7
    write_report_files(file_stem .. "_attempt", report, lines)

    local read_ok, class_obj = read_field(generator, ref_spec.field)
    if not read_ok or not is_valid(class_obj) then
        report.result = read_ok and "class_ref_invalid" or "class_ref_read_failed"
        report.error = read_ok and "invalid class ref" or tostring(class_obj)
        report.after_counts = generated_counts_snapshot()
        report.generated_deltas = generated_delta_parts(report.before_counts, report.after_counts)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. first_error_line(report.error)
        for line_index = 1, #lines do print(lines[line_index]) end
        local file_ok, write_detail = write_report_files(file_stem, report, lines)
        local detail = string.format("source=%s ref=%s result=%s", source.mode or "", ref_key, report.result)
        if file_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end
    report.class_ref = {
        name = safe_name(class_obj),
        class = safety.class_name_of(class_obj) or "",
        full_name = safe_full_name(class_obj),
        value = value_label(class_obj),
    }
    lines[#lines + 1] = string.format("  class_ref %s [%s] full=%s", report.class_ref.name, report.class_ref.class, report.class_ref.full_name)

    local actor = nil
    local spawn_ok = false
    if use_world_spawn then
        local world, world_route = get_world_for_spawn(pawn)
        report.world_route = world_route or ""
        if not world then return false, "UWorld unavailable for SpawnActor" end
        if not world.SpawnActor then return false, "UWorld:SpawnActor missing in this UE4SS build" end
        report.result = "about_to_WorldSpawnActor"
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  world_route=" .. tostring(report.world_route)
        write_report_files(file_stem .. "_attempt", report, lines)
        local world_obj = world
        local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
        local spawn_error = nil
        spawn_ok, spawn_error = pcall(function()
            actor = world_obj:SpawnActor(class_obj, spawn_loc, rot)
        end)
        if not spawn_ok or not is_valid(actor) then
            report.result = spawn_ok and "WorldSpawnActor_returned_invalid" or "WorldSpawnActor_failed"
            report.error = spawn_ok and "invalid actor" or tostring(spawn_error)
        else
            report.result = "spawned_generator_ref"
        end
    else
        local feature_net = require("feature_net")
        local pc = feature_net.local_controller()
        if not pc then return false, "no player controller" end
        local gpl = get_gameplay_statics()
        if not gpl then return false, "GameplayStatics CDO not found" end
        local begin_fn = gpl["BeginDeferredActorSpawnFromClass"]
        if not begin_fn then return false, "BeginDeferredActorSpawnFromClass missing" end
        local finish_fn = gpl["FinishSpawningActor"]
        if not finish_fn then return false, "FinishSpawningActor missing" end
        local spawn_xform = spawn_xform_at_location(spawn_loc)
        report.result = "about_to_BeginDeferredActorSpawnFromClass"
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local begin_error = nil
        spawn_ok, begin_error = pcall(function()
            actor = begin_fn(gpl, pc, class_obj, spawn_xform, 2, pc, 0)
        end)
        if not spawn_ok or not is_valid(actor) then
            report.result = spawn_ok and "BeginDeferredActorSpawnFromClass_returned_invalid" or "BeginDeferredActorSpawnFromClass_failed"
            report.error = spawn_ok and "invalid actor" or tostring(begin_error)
        else
            pcall(function() actor["bRegisterAsRuntimeSpawned"] = true end)
            report.actor = { name = safe_name(actor), class = safety.class_name_of(actor) or "", full_name = safe_full_name(actor), location = object_location_text(actor) }
            report.result = "about_to_FinishSpawningActor"
            lines[result_line_index] = "  result=" .. report.result
            lines[#lines + 1] = string.format("  actor %s [%s] full=%s", report.actor.name, report.actor.class, report.actor.full_name)
            write_report_files(file_stem .. "_attempt", report, lines)
            local finish_ok, finish_error = pcall(function()
                finish_fn(gpl, actor, spawn_xform, 0)
            end)
            spawn_ok = finish_ok
            report.result = finish_ok and "spawned_generator_ref" or "FinishSpawningActor_failed"
            report.error = finish_ok and "" or tostring(finish_error)
        end
    end

    if not spawn_ok or not is_valid(actor) then
        report.after_counts = generated_counts_snapshot()
        report.generated_deltas = generated_delta_parts(report.before_counts, report.after_counts)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. first_error_line(report.error)
        if #report.generated_deltas > 0 then
            lines[#lines + 1] = "  generated_deltas " .. table.concat(report.generated_deltas, " ")
        else
            lines[#lines + 1] = "  generated_deltas none"
        end
        for line_index = 1, #lines do print(lines[line_index]) end
        local file_ok, write_detail = write_report_files(file_stem, report, lines)
        local detail = string.format("source=%s ref=%s method=%s result=%s", source.mode or "", ref_key, method_key, report.result)
        if file_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    pcall(function() actor["bRegisterAsRuntimeSpawned"] = true end)
    report.actor = { name = safe_name(actor), class = safety.class_name_of(actor) or "", full_name = safe_full_name(actor), location = object_location_text(actor) }
    local cache_entry = remember_generated_spawn_actor(cache_batch, actor, ref_key, ref_key)
    if cache_entry then
        report.cache_entry = { batch = cache_entry.batch, label = cache_entry.label, ref = cache_entry.ref, name = cache_entry.name, full_name = cache_entry.full_name, location = cache_entry.location }
    end
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = string.format("  final_actor %s [%s] loc=%s", report.actor.name, report.actor.class, report.actor.location)
    if place_after_spawn then
        report.placement.attempted = true
        report.placement.before = report.actor.location
        report.result = "about_to_place_actor"
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        pcall(function() feature_actor.force_actor_movable(actor) end)
        local move_ok, move_error = feature_actor.move_actor(actor, spawn_loc)
        report.placement.ok = move_ok == true
        report.placement.error = move_ok and "" or tostring(move_error)
        report.placement.after = object_location_text(actor)
        report.actor.location = report.placement.after
        report.result = move_ok and "spawned_generator_ref_placed" or "spawned_generator_ref_place_failed"
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = string.format("  place ok=%s before=%s after=%s", tostring(move_ok == true), report.placement.before, report.placement.after)
        if not move_ok then lines[#lines + 1] = "  place error: " .. first_error_line(move_error) end
    end
    report.after_counts = generated_counts_snapshot()
    local delta_parts = generated_delta_parts(report.before_counts, report.after_counts)
    report.generated_deltas = delta_parts
    if #delta_parts > 0 then
        lines[#lines + 1] = "  generated_deltas " .. table.concat(delta_parts, " ")
    else
        lines[#lines + 1] = "  generated_deltas none"
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("source=%s ref=%s method=%s actor=%s result=%s deltas=%d place=%s", source.mode or "", ref_key, method_key, report.actor.name or "", report.result, #delta_parts, tostring(report.placement.ok == true))
    if file_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

local function make_connected_rng(seed)
    local state = math.floor(math.abs(tonumber(seed) or 1)) % 2147483647
    if state <= 0 then state = 1 end
    return function(max_value)
        state = (state * 48271) % 2147483647
        if state <= 0 then state = state + 2147483646 end
        if max_value and max_value > 0 then return (state % max_value) + 1 end
        return state
    end
end

function CONNECTED_SMART.cell_key(x, y)
    return tostring(math.floor(tonumber(x) or 0)) .. "," .. tostring(math.floor(tonumber(y) or 0))
end

function CONNECTED_SMART.hallway_yaw(side)
    return (side == "E" or side == "W") and 0 or 90
end

function CONNECTED_SMART.rotate_side(side, steps)
    local index = CONNECTED_SMART.side_index[side] or 1
    return CONNECTED_SMART.sides[((index + (steps or 0) - 1) % 4) + 1]
end

function CONNECTED_SMART.rotate_xy(x, y, steps)
    steps = (steps or 0) % 4
    x = math.floor(tonumber(x) or 0)
    y = math.floor(tonumber(y) or 0)
    if steps == 1 then return -y, x end
    if steps == 2 then return -x, -y end
    if steps == 3 then return y, -x end
    return x, y
end

function CONNECTED_SMART.rotate_offset_cm(x, y, steps)
    steps = (steps or 0) % 4
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    if steps == 1 then return -y, x end
    if steps == 2 then return -x, -y end
    if steps == 3 then return y, -x end
    return x, y
end

function CONNECTED_SMART.population_marker_world(node, marker, origin, tile_step)
    local relative = (marker and marker.relative_location) or {}
    local offset_x, offset_y = CONNECTED_SMART.rotate_offset_cm(relative.x, relative.y, node and node.rot_steps or 0)
    local room_z = (tonumber(node and node.z_cm) or 0) * ((tonumber(tile_step) or DUNGEON_TILE_SIZE_CM) / DUNGEON_TILE_SIZE_CM)
    return {
        X = (tonumber(origin and origin.X) or 0) + ((tonumber(node and node.cell_x) or 0) * tile_step) + offset_x,
        Y = (tonumber(origin and origin.Y) or 0) + ((tonumber(node and node.cell_y) or 0) * tile_step) + offset_y,
        Z = (tonumber(origin and origin.Z) or 0) + room_z + (tonumber(relative.z) or 0),
    }
end

function CONNECTED_SMART.population_marker_direct_actor_spawn_world(marker_kind, world_location)
    if marker_kind ~= "enemy" then return nil, 0 end
    local z_offset = CONNECTED_SMART_ENEMY_DIRECT_ACTOR_SPAWN_Z_OFFSET_CM
    return {
        X = tonumber(world_location and world_location.X) or 0,
        Y = tonumber(world_location and world_location.Y) or 0,
        Z = (tonumber(world_location and world_location.Z) or 0) + z_offset,
    }, z_offset
end

function CONNECTED_SMART.rotated_wall_yaw(yaw, steps)
    local value = (tonumber(yaw) or 0) + (((tonumber(steps) or 0) % 4) * 90)
    return ((value + 180) % 360) - 180
end

function CONNECTED_SMART.wall_center_offset(yaw)
    local quarter = math.floor((((tonumber(yaw) or 0) % 360) + 45) / 90) % 4
    if quarter == 0 then return 0.5, 0 end
    if quarter == 1 then return 0, 0.5 end
    if quarter == 2 then return -0.5, 0 end
    return 0, -0.5
end

function CONNECTED_SMART.entry_max_links(entry)
    local max_links = math.floor(tonumber(entry and entry.max_connections) or CONNECTED_DUNGEON_MAX_LINKS_PER_ROOM)
    local opening_count = math.floor(tonumber(entry and entry.opening_count) or max_links)
    if max_links < 1 then max_links = 1 end
    if max_links > CONNECTED_DUNGEON_MAX_LINKS_PER_ROOM then max_links = CONNECTED_DUNGEON_MAX_LINKS_PER_ROOM end
    if opening_count > 0 and max_links > opening_count then max_links = opening_count end
    return max_links
end

function CONNECTED_SMART.table_copy(value)
    if type(value) ~= "table" then return value end
    local copied = {}
    for key, child in pairs(value) do
        copied[key] = CONNECTED_SMART.table_copy(child)
    end
    return copied
end

function CONNECTED_SMART.apply_special_connector_override(spec)
    local key = spec and spec.key or ""
    local override = CONNECTED_SMART.special_connector_overrides[key]
    if not override then return spec end
    local copied_spec = CONNECTED_SMART.table_copy(spec or {})
    local entry = CONNECTED_SMART.table_copy((spec or {}).catalog or {})
    entry.usable_for_smart_chain = true
    entry.openings = CONNECTED_SMART.table_copy(override.openings or {})
    entry.opening_count = 0
    entry.passable_sides = {}
    for _side_index, side in ipairs(CONNECTED_SMART.sides) do
        local side_openings = ((entry.openings or {})[side]) or {}
        if #side_openings > 0 then entry.passable_sides[#entry.passable_sides + 1] = side end
        entry.opening_count = entry.opening_count + #side_openings
    end
    local override_max = math.floor(tonumber(override.max_connections) or 1)
    if override_max < 1 then override_max = 1 end
    if override_max > CONNECTED_DUNGEON_MAX_LINKS_PER_ROOM then override_max = CONNECTED_DUNGEON_MAX_LINKS_PER_ROOM end
    if entry.opening_count > 0 and override_max > entry.opening_count then override_max = entry.opening_count end
    entry.max_connections = override_max
    entry.special_connector_reason = override.reason or "special_connector_override"
    copied_spec.catalog = entry
    return copied_spec
end

function CONNECTED_SMART.cells_for(entry, rot_steps, tx, ty)
    local cells = {}
    for _cell_index, cell in ipairs(entry.cells or {}) do
        local x_value, y_value = CONNECTED_SMART.rotate_xy(cell.x, cell.y, rot_steps)
        cells[#cells + 1] = { x = x_value + tx, y = y_value + ty, h = tonumber(cell.height) or 0 }
    end
    return cells
end

function CONNECTED_SMART.openings_for(entry, rot_steps, tx, ty)
    local openings = {}
    for _side_index, side in ipairs(CONNECTED_SMART.sides) do
        for _opening_index, opening in ipairs(((entry.openings or {})[side]) or {}) do
            local x_value, y_value = CONNECTED_SMART.rotate_xy(opening.x, opening.y, rot_steps)
            local source_x, source_y = CONNECTED_SMART.rotate_xy(opening.source_x or opening.x, opening.source_y or opening.y, rot_steps)
            openings[#openings + 1] = {
                cell_x = x_value + tx,
                cell_y = y_value + ty,
                side = CONNECTED_SMART.rotate_side(side, rot_steps),
                wall = opening.wall or "",
                source_side = side,
                source_x = opening.x or 0,
                source_y = opening.y or 0,
                source_cell_x = source_x + tx,
                source_cell_y = source_y + ty,
                wall_index = opening.wall_index or 0,
                wall_z_cm = tonumber(opening.wall_z_cm) or 0,
                wall_yaw = CONNECTED_SMART.rotated_wall_yaw(opening.wall_yaw, rot_steps),
                connector_kind = opening.connector_kind or "",
                child_target_local = CONNECTED_SMART.table_copy(opening.child_target_local),
                openwalls_skip = opening.openwalls_skip == true,
                openwalls_skip_reason = opening.openwalls_skip_reason or "",
                used = false,
                blocked = false,
            }
        end
    end
    return openings
end

function CONNECTED_SMART.is_cell_free(occupied, x, y)
    return occupied[CONNECTED_SMART.cell_key(x, y)] == nil
end

function CONNECTED_SMART.cells_are_free(occupied, cells)
    for _cell_index, cell in ipairs(cells or {}) do
        if not CONNECTED_SMART.is_cell_free(occupied, cell.x, cell.y) then return false end
    end
    return true
end

function CONNECTED_SMART.cells_touch_other_occupant(occupied, cells, parent_index)
    local allowed = "room:" .. tostring(parent_index or 0)
    for _cell_index, cell in ipairs(cells or {}) do
        for _side, delta in pairs(CONNECTED_SMART.side_delta) do
            local owner = occupied[CONNECTED_SMART.cell_key(cell.x + delta.x, cell.y + delta.y)]
            if owner and owner ~= allowed then return true end
        end
    end
    return false
end

function CONNECTED_SMART.mark_cells(occupied, cells, value)
    for _cell_index, cell in ipairs(cells or {}) do
        occupied[CONNECTED_SMART.cell_key(cell.x, cell.y)] = value or true
    end
end

function CONNECTED_SMART.available_opening_indices(room)
    local indices = {}
    if not room or (room.links or 0) >= (room.max_links or 1) then return indices end
    for opening_index, opening in ipairs(room.openings or {}) do
        if not opening.used and not opening.blocked then indices[#indices + 1] = opening_index end
    end
    return indices
end

function CONNECTED_SMART.mark_matching_opening(room, side, cell_x, cell_y, wall_index)
    for _opening_index, opening in ipairs(room.openings or {}) do
        local same_wall = not wall_index or wall_index == 0 or opening.wall_index == wall_index
        if opening.side == side and opening.cell_x == cell_x and opening.cell_y == cell_y and same_wall and not opening.used then
            opening.used = true
            return opening
        end
    end
    return nil
end

function CONNECTED_SMART.opening_copy(opening)
    if not opening then return nil end
    return {
        cell_x = opening.cell_x or 0,
        cell_y = opening.cell_y or 0,
        side = opening.side or "",
        wall = opening.wall or "",
        source_cell_x = opening.source_cell_x or opening.cell_x or 0,
        source_cell_y = opening.source_cell_y or opening.cell_y or 0,
        wall_index = opening.wall_index or 0,
        wall_z_cm = opening.wall_z_cm or 0,
        wall_yaw = opening.wall_yaw or 0,
        connector_kind = opening.connector_kind or "",
        child_target_local = CONNECTED_SMART.table_copy(opening.child_target_local),
        openwalls_skip = opening.openwalls_skip == true,
        openwalls_skip_reason = opening.openwalls_skip_reason or "",
    }
end

function CONNECTED_SMART.outside_cell(opening)
    local x_value = opening and opening.cell_x or 0
    local y_value = opening and opening.cell_y or 0
    if opening and opening.side == "W" then return x_value - 1, y_value end
    if opening and opening.side == "N" then return x_value, y_value - 1 end
    return x_value, y_value
end

function CONNECTED_SMART.target_slot_for_hallway(opening)
    local dir = CONNECTED_SMART.side_delta[(opening and opening.side) or ""]
    if not dir then return (opening and opening.cell_x) or 0, (opening and opening.cell_y) or 0 end
    return ((opening and opening.cell_x) or 0) + dir.x, ((opening and opening.cell_y) or 0) + dir.y
end

function CONNECTED_SMART.cell_height(room, cell_x, cell_y)
    for _cell_index, cell in ipairs((room and room.cells) or {}) do
        if cell.x == cell_x and cell.y == cell_y then return tonumber(cell.h) or 0 end
    end
    return 0
end

function CONNECTED_SMART.wall_target(room, opening, origin, tile_step)
    local height = CONNECTED_SMART.cell_height(room, opening and opening.source_cell_x or 0, opening and opening.source_cell_y or 0)
    local room_z_cm = tonumber(room and room.z_cm) or 0
    local z_offset = (room_z_cm + (tonumber(opening and opening.wall_z_cm) or (height * DUNGEON_TILE_SIZE_CM))) * (tile_step / DUNGEON_TILE_SIZE_CM)
    return {
        X = (origin.X or 0) + ((opening and opening.cell_x) or 0) * tile_step,
        Y = (origin.Y or 0) + ((opening and opening.cell_y) or 0) * tile_step,
        Z = (origin.Z or 0) + z_offset,
    }, height
end

function CONNECTED_SMART.child_z_for_slot(parent, parent_opening, child_opening)
    return (tonumber(parent and parent.z_cm) or 0) + (tonumber(parent_opening and parent_opening.wall_z_cm) or 0) - (tonumber(child_opening and child_opening.wall_z_cm) or 0)
end

function CONNECTED_SMART.new_room(index, spec, rot_steps, tx, ty, z_cm, depth, parent_index)
    local entry = spec.catalog or {}
    local cells = CONNECTED_SMART.cells_for(entry, rot_steps, tx, ty)
    local openings = CONNECTED_SMART.openings_for(entry, rot_steps, tx, ty)
    return {
        index = index,
        parent = parent_index or 0,
        depth = depth or 0,
        key = spec.key or entry.key or "",
        label = spec.label or entry.label or "room",
        class_path = spec.class_path or entry.class_path or "",
        category = entry.category or "",
        shape_type = entry.shape_type or "",
        cell_x = tx,
        cell_y = ty,
        z_cm = tonumber(z_cm) or 0,
        room_yaw = (rot_steps % 4) * 90,
        rot_steps = rot_steps % 4,
        cell_count = #cells,
        opening_count = #openings,
        cells = cells,
        openings = openings,
        max_links = CONNECTED_SMART.entry_max_links(entry),
        links = 0,
        prefab = spec,
    }
end

function CONNECTED_SMART.catalog_pool(resolved_specs)
    local pool = {}
    for _spec_index, spec in ipairs(resolved_specs or {}) do
        local pool_spec = CONNECTED_SMART.apply_special_connector_override(spec)
        local entry = pool_spec.catalog or {}
        if entry.usable_for_smart_chain and (entry.cell_count or 0) > 0 and (entry.opening_count or 0) > 0 then
            pool[#pool + 1] = pool_spec
        end
    end
    return pool
end

function CONNECTED_SMART.find_root_spec(pool)
    for _index, spec in ipairs(pool or {}) do
        if spec.catalog and spec.catalog.category == "Entrance" then return spec end
    end
    for _index, spec in ipairs(pool or {}) do
        if spec.catalog and CONNECTED_SMART.entry_max_links(spec.catalog) > 1 then return spec end
    end
    return (pool or {})[1]
end

function CONNECTED_SMART.pool_without_keys(pool, excluded_keys)
    local filtered = {}
    for _, spec in ipairs(pool or {}) do
        if not (excluded_keys or {})[spec.key or ""] then filtered[#filtered + 1] = spec end
    end
    return filtered
end

function CONNECTED_SMART.required_terminal_specs(pool)
    local specs = {}
    for _, spec in ipairs(pool or {}) do
        if CONNECTED_SMART.reserved_terminal_keys[spec.key or ""] == true then specs[#specs + 1] = spec end
    end
    table.sort(specs, function(left, right)
        local left_cells = tonumber(((left or {}).catalog or {}).cell_count) or 0
        local right_cells = tonumber(((right or {}).catalog or {}).cell_count) or 0
        if left_cells ~= right_cells then return left_cells > right_cells end
        return tostring((left or {}).key or "") < tostring((right or {}).key or "")
    end)
    return specs
end

function CONNECTED_SMART.try_place_child(parent, opening, pool, occupied, remaining, rng, use_hallways, usage_counts, category_counts, selection_policy)
    local dir = CONNECTED_SMART.side_delta[opening.side]
    if not dir then return nil, "bad_parent_side" end
    local hallway_x, hallway_y = CONNECTED_SMART.outside_cell(opening)
    if use_hallways and not CONNECTED_SMART.is_cell_free(occupied, hallway_x, hallway_y) then return nil, "hallway_occupied" end
    local child_cell_x = opening.cell_x
    local child_cell_y = opening.cell_y
    if use_hallways then child_cell_x, child_cell_y = CONNECTED_SMART.target_slot_for_hallway(opening) end
    local child_side = CONNECTED_SMART.opposite[opening.side]
    local prefer_branching = remaining > 8
    local entry_start = rng(#pool)
    local clearance_rejection_count = 0

    for phase = 1, 2 do
        local best_candidate = nil
        for entry_offset = 0, #pool - 1 do
            local spec = pool[((entry_start + entry_offset - 1) % #pool) + 1]
            local entry = spec.catalog or {}
            local entry_max_links = CONNECTED_SMART.entry_max_links(entry)
            local is_linear = entry_max_links <= 2
            local usage = tonumber((usage_counts or {})[spec.key or ""]) or 0
            local allow_in_phase = phase == 2 or not (prefer_branching and is_linear)
            if entry.category ~= "Entrance" and allow_in_phase then
                local rot_start = rng(4) - 1
                for rot_offset = 0, 3 do
                    local rot_steps = (rot_start + rot_offset) % 4
                    for _side_index, source_side in ipairs(CONNECTED_SMART.sides) do
                        if CONNECTED_SMART.rotate_side(source_side, rot_steps) == child_side then
                            local source_openings = ((entry.openings or {})[source_side]) or {}
                            local opening_start = (#source_openings > 0) and rng(#source_openings) or 1
                            for source_offset = 0, #source_openings - 1 do
                                local child_opening = source_openings[((opening_start + source_offset - 1) % #source_openings) + 1]
                                local open_x, open_y = CONNECTED_SMART.rotate_xy(child_opening.x, child_opening.y, rot_steps)
                                local tx = child_cell_x - open_x
                                local ty = child_cell_y - open_y
                                local child_wall_yaw = CONNECTED_SMART.rotated_wall_yaw(child_opening.wall_yaw, rot_steps)
                                if not use_hallways then
                                    local parent_center_x, parent_center_y = CONNECTED_SMART.wall_center_offset(opening.wall_yaw)
                                    local child_center_x, child_center_y = CONNECTED_SMART.wall_center_offset(child_wall_yaw)
                                    tx = tx + parent_center_x - child_center_x
                                    ty = ty + parent_center_y - child_center_y
                                    if type(opening.child_target_local) == "table" then
                                        local target_x_cm = tonumber(opening.child_target_local.X or opening.child_target_local.x)
                                        local target_y_cm = tonumber(opening.child_target_local.Y or opening.child_target_local.y)
                                        if target_x_cm and target_y_cm then
                                            local rotated_target = { X = target_x_cm, Y = target_y_cm }
                                            if (tonumber(parent.rot_steps) or 0) ~= 0 then
                                                local rotated_x, rotated_y = CONNECTED_SMART.rotate_offset_cm(target_x_cm, target_y_cm, parent.rot_steps or 0)
                                                rotated_target = { X = rotated_x, Y = rotated_y }
                                            end
                                            local target_cell_x = (tonumber(parent.cell_x) or 0) + ((rotated_target.X or 0) / DUNGEON_TILE_SIZE_CM)
                                            local target_cell_y = (tonumber(parent.cell_y) or 0) + ((rotated_target.Y or 0) / DUNGEON_TILE_SIZE_CM)
                                            tx = tx + target_cell_x - (open_x + tx)
                                            ty = ty + target_cell_y - (open_y + ty)
                                        end
                                    end
                                end
                                local cells = CONNECTED_SMART.cells_for(entry, rot_steps, tx, ty)
                                if CONNECTED_SMART.cells_are_free(occupied, cells) then
                                    local has_clearance = use_hallways or not CONNECTED_SMART.cells_touch_other_occupant(occupied, cells, parent.index)
                                    if has_clearance then
                                        local child_z_cm = use_hallways and 0 or CONNECTED_SMART.child_z_for_slot(parent, opening, child_opening)
                                        if not use_hallways and type(opening.child_target_local) == "table" then
                                            local target_z_cm = tonumber(opening.child_target_local.Z or opening.child_target_local.z)
                                            if target_z_cm then child_z_cm = (tonumber(parent.z_cm) or 0) + target_z_cm - (tonumber(child_opening.wall_z_cm) or 0) end
                                        end
                                        local category_usage = tonumber((category_counts or {})[entry.category or ""]) or 0
                                        local native_max = math.floor(tonumber(entry.native_max_count) or 0)
                                        local diversity_policy = selection_policy == "terminal_reservations_v1"
                                            or selection_policy == "diversity_soft_caps_v2"
                                            or selection_policy == "required_variety_backbone_v1"
                                        local native_cap_penalty = 0
                                        if diversity_policy and native_max > 0 and usage >= native_max then
                                            native_cap_penalty = (usage - native_max + 1) * CONNECTED_SMART_NATIVE_CAP_PENALTY
                                        end
                                        local repeat_penalty = (spec.key or "") == (parent.key or "") and CONNECTED_SMART_SAME_PARENT_PENALTY or 0
                                        local category_penalty = diversity_policy
                                            and (category_usage * CONNECTED_SMART_CATEGORY_USAGE_PENALTY)
                                            or 0
                                        local terminal_reservation_bonus = selection_policy == "terminal_reservations_v1"
                                            and remaining <= CONNECTED_SMART.terminal_reservation_window
                                            and CONNECTED_SMART.reserved_terminal_keys[spec.key or ""] == true
                                            and usage == 0
                                            and CONNECTED_SMART.terminal_reservation_bonus
                                            or 0
                                        local required_variety_bonus = selection_policy == "required_variety_backbone_v1"
                                            and usage == 0
                                            and CONNECTED_SMART_REQUIRED_VARIETY_BONUS
                                            or 0
                                        local score = (usage * CONNECTED_SMART_USAGE_PENALTY)
                                            + native_cap_penalty
                                            + category_penalty
                                            + repeat_penalty
                                            + math.abs(child_z_cm - (tonumber(parent.z_cm) or 0))
                                            - terminal_reservation_bonus
                                            - required_variety_bonus
                                        local result = {
                                            spec = spec,
                                            rot_steps = rot_steps,
                                            tx = tx,
                                            ty = ty,
                                            z_cm = child_z_cm,
                                            score = score,
                                            cells = cells,
                                            hallway = use_hallways and { x = hallway_x, y = hallway_y, side = opening.side, yaw = CONNECTED_SMART.hallway_yaw(opening.side) } or nil,
                                            child_opening = { side = child_side, cell_x = open_x + tx, cell_y = open_y + ty, wall = child_opening.wall or "", wall_index = child_opening.wall_index or 0, wall_z_cm = child_opening.wall_z_cm or 0, wall_yaw = child_wall_yaw },
                                        }
                                        if not best_candidate or result.score < best_candidate.score then best_candidate = result end
                                    else
                                        clearance_rejection_count = clearance_rejection_count + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        if best_candidate then return best_candidate, nil, clearance_rejection_count end
    end
    return nil, clearance_rejection_count > 0 and "no_clearance_fit" or "no_fit", clearance_rejection_count
end

function CONNECTED_SMART.commit_child(layout, occupied, usage_counts, category_counts, parent, opening, child)
    local node_index = #layout.nodes + 1
    local child_room = CONNECTED_SMART.new_room(node_index, child.spec, child.rot_steps, child.tx, child.ty, child.z_cm, (parent.depth or 0) + 1, parent.index)
    child_room.cells = child.cells
    child_room.openings = CONNECTED_SMART.openings_for(child.spec.catalog or {}, child.rot_steps, child.tx, child.ty)
    local matched_child_opening = CONNECTED_SMART.mark_matching_opening(child_room, child.child_opening.side, child.child_opening.cell_x, child.child_opening.cell_y, child.child_opening.wall_index)
    local parent_opening = CONNECTED_SMART.opening_copy(opening)
    local child_opening = CONNECTED_SMART.opening_copy(matched_child_opening or child.child_opening)
    opening.used = true
    opening.blocked = false
    opening.block_reason = nil
    parent.links = (parent.links or 0) + 1
    child_room.links = 1
    layout.nodes[node_index] = child_room
    usage_counts[child_room.key or ""] = (usage_counts[child_room.key or ""] or 0) + 1
    category_counts[child_room.category or ""] = (category_counts[child_room.category or ""] or 0) + 1
    if math.abs((child_room.z_cm or 0) - (parent.z_cm or 0)) > 1.0 then layout.stats.z_adjusted_rooms = layout.stats.z_adjusted_rooms + 1 end
    if (child_room.z_cm or 0) < layout.stats.min_room_z_cm then layout.stats.min_room_z_cm = child_room.z_cm or 0 end
    if (child_room.z_cm or 0) > layout.stats.max_room_z_cm then layout.stats.max_room_z_cm = child_room.z_cm or 0 end
    CONNECTED_SMART.mark_cells(occupied, child_room.cells, "room:" .. tostring(node_index))
    local hallway_index = 0
    if child.hallway then
        occupied[CONNECTED_SMART.cell_key(child.hallway.x, child.hallway.y)] = "hallway:" .. tostring(#layout.hallways + 1)
        hallway_index = #layout.hallways + 1
        layout.hallways[hallway_index] = { index = hallway_index, x = child.hallway.x, y = child.hallway.y, side = child.hallway.side, yaw = child.hallway.yaw, parent = parent.index, child = node_index, loop = false, parent_opening = parent_opening, child_opening = child_opening }
    end
    layout.edges[#layout.edges + 1] = { index = #layout.edges + 1, parent = parent.index, child = node_index, dir = opening.side, loop = false, direct = not child.hallway, hallway_index = hallway_index, parent_opening = parent_opening, child_opening = child_opening }
    return child_room
end

function CONNECTED_SMART.attach_required_terminal(layout, occupied, usage_counts, category_counts, spec, rng, use_hallways)
    local best = nil
    local clearance_rejection_count = 0
    for _, parent in ipairs(layout.nodes or {}) do
        if (parent.links or 0) < (parent.max_links or 1) then
            for _, opening in ipairs(parent.openings or {}) do
                if not opening.used then
                    local child, _reason, rejected = CONNECTED_SMART.try_place_child(parent, opening, { spec }, occupied, 0, rng, use_hallways, usage_counts, category_counts, "required_terminal_attach_v1")
                    clearance_rejection_count = clearance_rejection_count + (rejected or 0)
                    if child then
                        local spare_links = (tonumber(parent.max_links) or 1) - (tonumber(parent.links) or 0)
                        local rank = (spare_links * 1000000) - ((tonumber(parent.depth) or 0) * 1000)
                        if not best or rank > best.rank then best = { rank = rank, parent = parent, opening = opening, child = child } end
                    end
                end
            end
        end
    end
    if not best then return nil, clearance_rejection_count end
    return CONNECTED_SMART.commit_child(layout, occupied, usage_counts, category_counts, best.parent, best.opening, best.child), clearance_rejection_count
end

function CONNECTED_SMART.connector_order_rank(connector_kind)
    local kind_text = tostring(connector_kind or "")
    for order_index, expected_kind in ipairs(CONNECTED_SMART.entrance_hub_connector_order or {}) do
        if kind_text == expected_kind then return order_index end
    end
    return 999
end

function CONNECTED_SMART.entrance_hub_opening_indices(room)
    local ranked = {}
    for _, opening_index in ipairs(CONNECTED_SMART.available_opening_indices(room)) do
        local opening = (room.openings or {})[opening_index] or {}
        ranked[#ranked + 1] = {
            index = opening_index,
            rank = CONNECTED_SMART.connector_order_rank(opening.connector_kind),
            side = tostring(opening.side or ""),
            kind = tostring(opening.connector_kind or ""),
        }
    end
    table.sort(ranked, function(left, right)
        if left.rank ~= right.rank then return left.rank < right.rank end
        if left.side ~= right.side then return left.side < right.side end
        if left.kind ~= right.kind then return left.kind < right.kind end
        return left.index < right.index
    end)
    local indices = {}
    for _, entry in ipairs(ranked) do indices[#indices + 1] = entry.index end
    return indices
end

function CONNECTED_SMART.attach_entrance_hub_links(layout, occupied, active, build_pool, usage_counts, category_counts, rng, use_hallways, placement_policy, backbone_nodes, backbone_target)
    local root = (layout.nodes or {})[1]
    if not root or root.category ~= "Entrance" then return backbone_nodes end

    layout.stats.entrance_hub_enabled = true
    local target_links = math.floor(tonumber(CONNECTED_SMART.entrance_root_min_links) or 1)
    if target_links < 1 then target_links = 1 end
    if target_links > (root.max_links or 1) then target_links = root.max_links or 1 end
    if target_links > math.max(0, (tonumber(backbone_target) or 0) - 1) then target_links = math.max(0, (tonumber(backbone_target) or 0) - 1) end
    layout.stats.entrance_hub_target = target_links

    while backbone_nodes < backbone_target and (root.links or 0) < target_links do
        local available = CONNECTED_SMART.entrance_hub_opening_indices(root)
        if #available == 0 then break end
        local placed = false
        for _, opening_index in ipairs(available) do
            local opening = root.openings[opening_index]
            if opening and not opening.used and not opening.blocked then
                layout.stats.entrance_hub_attempted = (layout.stats.entrance_hub_attempted or 0) + 1
                local child, reason, clearance_rejection_count = CONNECTED_SMART.try_place_child(root, opening, build_pool, occupied, backbone_target - backbone_nodes, rng, use_hallways, usage_counts, category_counts, placement_policy)
                layout.stats.clearance_rejections = layout.stats.clearance_rejections + (clearance_rejection_count or 0)
                if child then
                    local node_index = #layout.nodes + 1
                    local child_room = CONNECTED_SMART.commit_child(layout, occupied, usage_counts, category_counts, root, opening, child)
                    backbone_nodes = backbone_nodes + 1
                    layout.stats.backbone_nodes = backbone_nodes
                    layout.stats.entrance_hub_attached = (layout.stats.entrance_hub_attached or 0) + 1
                    layout.stats.entrance_hub_connectors[#layout.stats.entrance_hub_connectors + 1] = {
                        connector = opening.connector_kind or "",
                        side = opening.side or "",
                        child = child_room.index or node_index,
                        key = child_room.key or "",
                        category = child_room.category or "",
                    }
                    if #CONNECTED_SMART.available_opening_indices(child_room) > 0 and (child_room.links or 0) < (child_room.max_links or 1) then active[#active + 1] = node_index end
                    placed = true
                    break
                else
                    opening.blocked = true
                    opening.block_reason = reason or "no_fit"
                    layout.stats.rejected_openings = layout.stats.rejected_openings + 1
                    layout.stats.entrance_hub_failed[#layout.stats.entrance_hub_failed + 1] = string.format("%s:%s", tostring(opening.connector_kind or opening.side or ""), tostring(opening.block_reason or "no_fit"))
                end
            end
        end
        if not placed then break end
    end
    return backbone_nodes
end

function CONNECTED_SMART.add_loop_edges(layout, occupied, rng, loop_percent, use_hallways)
    if not use_hallways then return 0 end
    local limit = math.floor((#layout.nodes or 0) * 0.15)
    if limit < 1 then return 0 end
    local opening_map = {}
    for _room_index, room in ipairs(layout.nodes or {}) do
        for opening_index, opening in ipairs(room.openings or {}) do
            if not opening.used and not opening.blocked and (room.links or 0) < (room.max_links or 1) then
                opening_map[CONNECTED_SMART.cell_key(opening.cell_x, opening.cell_y) .. ":" .. opening.side] = { room = room, opening = opening, opening_index = opening_index }
            end
        end
    end

    local added = 0
    for _room_index, room in ipairs(layout.nodes or {}) do
        if added >= limit then break end
        for _opening_index, opening in ipairs(room.openings or {}) do
            if added >= limit then break end
            if not opening.used and not opening.blocked and (room.links or 0) < (room.max_links or 1) and rng(100) <= loop_percent then
                local dir = CONNECTED_SMART.side_delta[opening.side]
                local other_side = CONNECTED_SMART.opposite[opening.side]
                local hallway_x = opening.cell_x + dir.x
                local hallway_y = opening.cell_y + dir.y
                local target_key = CONNECTED_SMART.cell_key(opening.cell_x + dir.x * 2, opening.cell_y + dir.y * 2) .. ":" .. other_side
                local other = opening_map[target_key]
                if other and not other.opening.used and other.room.index ~= room.index and CONNECTED_SMART.is_cell_free(occupied, hallway_x, hallway_y) and (other.room.links or 0) < (other.room.max_links or 1) then
                    local parent_opening = CONNECTED_SMART.opening_copy(opening)
                    local child_opening = CONNECTED_SMART.opening_copy(other.opening)
                    opening.used = true
                    other.opening.used = true
                    room.links = (room.links or 0) + 1
                    other.room.links = (other.room.links or 0) + 1
                    occupied[CONNECTED_SMART.cell_key(hallway_x, hallway_y)] = "loop"
                    added = added + 1
                    local edge_index = #layout.edges + 1
                    layout.edges[edge_index] = { index = edge_index, parent = room.index, child = other.room.index, dir = opening.side, loop = true, hallway_index = #layout.hallways + 1, parent_opening = parent_opening, child_opening = child_opening }
                    layout.hallways[#layout.hallways + 1] = { index = #layout.hallways + 1, x = hallway_x, y = hallway_y, side = opening.side, yaw = CONNECTED_SMART.hallway_yaw(opening.side), parent = room.index, child = other.room.index, loop = true, parent_opening = parent_opening, child_opening = child_opening }
                end
            end
        end
    end
    return added
end

function CONNECTED_SMART.build(room_count, branch_percent, seed, resolved_specs, use_hallways, selection_policy)
    use_hallways = use_hallways ~= false
    selection_policy = selection_policy or "diversity_soft_caps_v2"
    local rng = make_connected_rng(seed)
    local pool = CONNECTED_SMART.catalog_pool(resolved_specs)
    local required_terminal_specs = selection_policy == "required_variety_v1" and CONNECTED_SMART.required_terminal_specs(pool) or {}
    local build_pool = selection_policy == "required_variety_v1" and CONNECTED_SMART.pool_without_keys(pool, CONNECTED_SMART.reserved_terminal_keys) or pool
    local backbone_target = math.max(1, room_count - #required_terminal_specs)
    if selection_policy ~= "required_variety_v1" then backbone_target = room_count end
    local placement_policy = selection_policy == "required_variety_v1" and "required_variety_backbone_v1" or selection_policy
    local layout = { nodes = {}, edges = {}, hallways = {}, use_hallways = use_hallways, stats = { pool = #pool, backbone_pool = #build_pool, backbone_target = backbone_target, backbone_nodes = 0, layout_seed = seed, rejected_openings = 0, clearance_rejections = 0, z_adjusted_rooms = 0, min_room_z_cm = 0, max_room_z_cm = 0, unique_prefabs = 0, prefab_counts = {}, category_counts = {}, native_cap_overages = {}, native_cap_overage_total = 0, required_prefab_counts = {}, required_prefab_missing = {}, reserved_terminal_counts = {}, reserved_terminal_missing = {}, terminal_attach_attempted = #required_terminal_specs, terminal_attach_attached = 0, terminal_attach_failed = {}, terminal_attach_staged_at = 0, entrance_hub_enabled = false, entrance_hub_target = 0, entrance_hub_attempted = 0, entrance_hub_attached = 0, entrance_hub_failed = {}, entrance_hub_connectors = {}, selection_policy = selection_policy, loops_added = 0 } }
    if #pool == 0 then
        layout.result = "catalog_empty"
        return layout
    end
    if #build_pool == 0 then
        layout.result = "backbone_catalog_empty"
        return layout
    end

    local occupied = {}
    local root_spec = CONNECTED_SMART.find_root_spec(build_pool)
    local root_rot_steps = rng(4) - 1
    if ((root_spec or {}).catalog or {}).category == "Entrance" then root_rot_steps = 0 end
    local root = CONNECTED_SMART.new_room(1, root_spec, root_rot_steps, 0, 0, 0, 0, 0)
    layout.nodes[1] = root
    CONNECTED_SMART.mark_cells(occupied, root.cells, "room:1")
    local usage_counts = { [root.key or ""] = 1 }
    local category_counts = { [root.category or ""] = 1 }
    local active = { 1 }
    local backbone_nodes = 1
    local terminal_attached_keys = {}
    local terminal_attach_staged = false
    layout.stats.backbone_nodes = backbone_nodes

    local function attach_pending_terminals()
        if #required_terminal_specs == 0 then return end
        if not terminal_attach_staged then
            terminal_attach_staged = true
            layout.stats.terminal_attach_staged_at = backbone_nodes
        end
        for _, terminal_spec in ipairs(required_terminal_specs) do
            if not terminal_attached_keys[terminal_spec.key or ""] then
                local attached, clearance_rejection_count = CONNECTED_SMART.attach_required_terminal(layout, occupied, usage_counts, category_counts, terminal_spec, rng, use_hallways)
                layout.stats.clearance_rejections = layout.stats.clearance_rejections + (clearance_rejection_count or 0)
                if attached then
                    terminal_attached_keys[terminal_spec.key or ""] = true
                    layout.stats.terminal_attach_attached = layout.stats.terminal_attach_attached + 1
                end
            end
        end
    end

    backbone_nodes = CONNECTED_SMART.attach_entrance_hub_links(layout, occupied, active, build_pool, usage_counts, category_counts, rng, use_hallways, placement_policy, backbone_nodes, backbone_target)

    while backbone_nodes < backbone_target and #active > 0 do
        local parent_pos = #active
        if branch_percent > 0 and rng(100) <= branch_percent then parent_pos = rng(#active) end
        local parent = layout.nodes[active[parent_pos]]
        local available = CONNECTED_SMART.available_opening_indices(parent)
        if #available == 0 then
            table.remove(active, parent_pos)
        else
            local opening_start = rng(#available)
            local placed = false
            for opening_offset = 0, #available - 1 do
                local opening_index = available[((opening_start + opening_offset - 1) % #available) + 1]
                local opening = parent.openings[opening_index]
                local child, reason, clearance_rejection_count = CONNECTED_SMART.try_place_child(parent, opening, build_pool, occupied, backbone_target - backbone_nodes, rng, use_hallways, usage_counts, category_counts, placement_policy)
                layout.stats.clearance_rejections = layout.stats.clearance_rejections + (clearance_rejection_count or 0)
                if child then
                    local node_index = #layout.nodes + 1
                    local child_room = CONNECTED_SMART.commit_child(layout, occupied, usage_counts, category_counts, parent, opening, child)
                    backbone_nodes = backbone_nodes + 1
                    layout.stats.backbone_nodes = backbone_nodes
                    if #CONNECTED_SMART.available_opening_indices(child_room) > 0 and (child_room.links or 0) < (child_room.max_links or 1) then active[#active + 1] = node_index end
                    placed = true
                    break
                else
                    opening.blocked = true
                    opening.block_reason = reason or "no_fit"
                    layout.stats.rejected_openings = layout.stats.rejected_openings + 1
                end
            end
            if not placed or #CONNECTED_SMART.available_opening_indices(parent) == 0 or (parent.links or 0) >= (parent.max_links or 1) then
                table.remove(active, parent_pos)
            end
        end
        if terminal_attach_staged or backbone_nodes >= math.min(CONNECTED_SMART.terminal_attach_backbone_nodes, backbone_target) then
            attach_pending_terminals()
        end
    end

    if selection_policy == "required_variety_v1" then
        attach_pending_terminals()
        for _, terminal_spec in ipairs(required_terminal_specs) do
            if not terminal_attached_keys[terminal_spec.key or ""] then
                layout.stats.terminal_attach_failed[#layout.stats.terminal_attach_failed + 1] = terminal_spec.key or ""
            end
        end
    end

    local loop_percent = math.max(0, math.min(25, math.floor((tonumber(branch_percent) or 0) / 3)))
    layout.stats.loops_added = CONNECTED_SMART.add_loop_edges(layout, occupied, rng, loop_percent, use_hallways)
    layout.stats.occupied_cells = 0
    for _key, _value in pairs(occupied) do layout.stats.occupied_cells = layout.stats.occupied_cells + 1 end
    for key, count in pairs(usage_counts) do
        layout.stats.prefab_counts[key] = count
        layout.stats.unique_prefabs = layout.stats.unique_prefabs + 1
    end
    for category, count in pairs(category_counts) do
        layout.stats.category_counts[category] = count
    end
    for key, _enabled in pairs(CONNECTED_SMART.reserved_terminal_keys) do
        local count = usage_counts[key] or 0
        layout.stats.reserved_terminal_counts[key] = count
        if count == 0 then layout.stats.reserved_terminal_missing[#layout.stats.reserved_terminal_missing + 1] = key end
    end
    table.sort(layout.stats.reserved_terminal_missing)
    for _, spec in ipairs(pool) do
        local key = spec.key or ""
        local count = usage_counts[key] or 0
        layout.stats.required_prefab_counts[key] = count
        if count == 0 then layout.stats.required_prefab_missing[#layout.stats.required_prefab_missing + 1] = key end
    end
    table.sort(layout.stats.required_prefab_missing)
    for _, spec in ipairs(pool) do
        local key = spec.key or ""
        local count = usage_counts[key] or 0
        local native_max = math.floor(tonumber((spec.catalog or {}).native_max_count) or 0)
        if native_max > 0 and count > native_max then
            local overage = count - native_max
            layout.stats.native_cap_overages[key] = overage
            layout.stats.native_cap_overage_total = layout.stats.native_cap_overage_total + overage
        end
    end
    if #layout.nodes >= room_count and #(layout.stats.required_prefab_missing or {}) == 0 then
        layout.result = "complete"
    elseif #layout.nodes >= room_count then
        layout.result = "complete_required_missing"
    else
        layout.result = "frontier_exhausted"
    end
    return layout
end

local function build_connected_dungeon_layout(room_count, branch_percent, seed)
    local rng = make_connected_rng(seed)
    local occupied = { ["0,0"] = 1 }
    local nodes = { { index = 1, x = 0, y = 0, parent = 0, depth = 0, links = 0, from_dir = "", room_yaw = (rng(4) - 1) * 90 } }
    local edges = {}
    local active = { 1 }

    local function cell_key(x, y)
        return tostring(x) .. "," .. tostring(y)
    end

    local function has_free_neighbor(node)
        if not node or (node.links or 0) >= CONNECTED_DUNGEON_MAX_LINKS_PER_ROOM then return false end
        for _dir_index, dir in ipairs(CONNECTED_LAYOUT_DIRECTIONS) do
            if not occupied[cell_key(node.x + dir.x, node.y + dir.y)] then return true end
        end
        return false
    end

    while #nodes < room_count and #active > 0 do
        local parent_pos = #active
        if branch_percent > 0 and rng(100) <= branch_percent then parent_pos = rng(#active) end
        local parent = nodes[active[parent_pos]]
        if not has_free_neighbor(parent) then
            table.remove(active, parent_pos)
        else
            local start_dir = rng(#CONNECTED_LAYOUT_DIRECTIONS)
            local chosen_dir = nil
            for offset = 0, #CONNECTED_LAYOUT_DIRECTIONS - 1 do
                local dir = CONNECTED_LAYOUT_DIRECTIONS[((start_dir + offset - 1) % #CONNECTED_LAYOUT_DIRECTIONS) + 1]
                if not occupied[cell_key(parent.x + dir.x, parent.y + dir.y)] then
                    chosen_dir = dir
                    break
                end
            end
            if not chosen_dir then
                table.remove(active, parent_pos)
            else
                local node = {
                    index = #nodes + 1,
                    x = parent.x + chosen_dir.x,
                    y = parent.y + chosen_dir.y,
                    parent = parent.index,
                    depth = parent.depth + 1,
                    links = 1,
                    from_dir = chosen_dir.key,
                    room_yaw = (rng(4) - 1) * 90,
                }
                nodes[#nodes + 1] = node
                occupied[cell_key(node.x, node.y)] = node.index
                parent.links = (parent.links or 0) + 1
                edges[#edges + 1] = {
                    index = #edges + 1,
                    parent = parent.index,
                    child = node.index,
                    x = parent.x * 2 + chosen_dir.x,
                    y = parent.y * 2 + chosen_dir.y,
                    dir = chosen_dir.key,
                    yaw = chosen_dir.hallway_yaw,
                }
                if has_free_neighbor(node) then active[#active + 1] = node.index end
                if not has_free_neighbor(parent) then table.remove(active, parent_pos) end
            end
        end
    end

    return nodes, edges, (#nodes >= room_count) and "complete" or "frontier_exhausted"
end

function M.generator_spawnlayout(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generator.spawnlayout [cdo|generator_index] [pair|line3|line5|cross|grid3] [step] [dx dy dz] confirm"
    if #tokens < 1 or tokens[#tokens] ~= "confirm" then return false, usage end

    local source_token = "cdo"
    local layout_key = "line3"
    local step = 450
    local dx, dy, dz = 300, 0, 0
    local arg_index = 1
    local limit = #tokens - 1
    local first_token = tokens[arg_index] and tostring(tokens[arg_index]):lower() or ""
    if first_token == "cdo" or first_token == "default" or tonumber(first_token) then
        source_token = tokens[arg_index]
        arg_index = arg_index + 1
    end
    local layout_token = tokens[arg_index] and tostring(tokens[arg_index]):lower() or ""
    if layout_token ~= "" and not tonumber(layout_token) then
        if layout_token == "line" or layout_token == "chain" then layout_token = "line3" end
        if layout_token == "long" then layout_token = "line5" end
        if layout_token == "grid" then layout_token = "grid3" end
        if layout_token ~= "pair" and layout_token ~= "line3" and layout_token ~= "line5" and layout_token ~= "cross" and layout_token ~= "grid3" then
            return false, "unknown layout; choose pair, line3, line5, cross, or grid3"
        end
        layout_key = layout_token
        arg_index = arg_index + 1
    end
    if arg_index <= limit and tonumber(tokens[arg_index]) then
        step = tonumber(tokens[arg_index]) or step
        arg_index = arg_index + 1
    end
    local remaining = limit - arg_index + 1
    if remaining == 3 then
        local parsed_dx = tonumber(tokens[arg_index])
        local parsed_dy = tonumber(tokens[arg_index + 1])
        local parsed_dz = tonumber(tokens[arg_index + 2])
        if not parsed_dx or not parsed_dy or not parsed_dz then return false, "dx/dy/dz must be numbers" end
        dx, dy, dz = parsed_dx, parsed_dy, parsed_dz
        arg_index = arg_index + 3
    elseif remaining ~= 0 then
        return false, usage
    end
    if arg_index <= limit then return false, usage end

    local file_stem = "dungeon_proc_generator_spawnlayout"
    local generator, source, resolve_error = resolve_generator_ref_source(source_token, file_stem)
    if resolve_error then return false, resolve_error end
    if not source then return false, "generator source metadata unavailable" end
    if not is_valid(generator) then return false, "generator source unavailable" end

    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return false, "local pawn unavailable" end
    local base_loc = nil
    pcall(function() base_loc = feature_actor.actor_location(pawn) end)
    if not base_loc then return false, "local pawn location unavailable" end
    local world, world_route = get_world_for_spawn(pawn)
    if not world then return false, "UWorld unavailable for SpawnActor" end
    if not world.SpawnActor then return false, "UWorld:SpawnActor missing in this UE4SS build" end

    local origin = {
        X = (tonumber(base_loc.X) or 0) + dx,
        Y = (tonumber(base_loc.Y) or 0) + dy,
        Z = (tonumber(base_loc.Z) or 0) + dz,
    }
    local cache_batch = begin_generated_spawn_batch("spawnlayout:" .. layout_key)
    local report = {
        command = "world.dungeon.proc.generator.spawnlayout",
        confirmed = true,
        cache_batch = cache_batch,
        source = source,
        layout = layout_key,
        step = step,
        origin_offset = { x = dx, y = dy, z = dz },
        origin = vec_text(origin),
        base = { name = safe_name(pawn), class = safety.class_name_of(pawn) or "", full_name = safe_full_name(pawn), location = vec_text(base_loc) },
        class_refs = {},
        actors = {},
        before_counts = generated_counts_snapshot(),
        after_counts = {},
        generated_deltas = {},
        result = "about_to_read_classrefs",
        error = "",
        world_route = world_route or "",
        warning = "spawns a simple room/hallway layout from generator BP class refs; no Init/CreateRoom/CreateHallway/teleport lifecycle calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generator.spawnlayout --",
        string.format("  source=%s index=%d %s [%s]", source.mode, source.index or 0, source.name or "", source.class or ""),
        string.format("  layout=%s step=%.1f origin=%s", layout_key, step, report.origin),
        string.format("  base pawn %s [%s] loc=%s", report.base.name, report.base.class, report.base.location),
        "  world_route=" .. tostring(report.world_route),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    local result_line_index = 7

    local class_refs = {}
    for _ref_index, ref_key in ipairs(GENERATOR_CLASSREF_ORDER) do
        local ref_spec = GENERATOR_CLASSREF_FIELDS[ref_key]
        report.result = "about_to_read_" .. ref_spec.field
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local read_ok, class_obj = read_field(generator, ref_spec.field)
        local entry = {
            key = ref_key,
            field = ref_spec.field,
            ok = read_ok == true,
            valid = read_ok and is_valid(class_obj) or false,
            name = read_ok and safe_name(class_obj) or "",
            class = read_ok and (safety.class_name_of(class_obj) or "") or "",
            full_name = read_ok and safe_full_name(class_obj) or "",
            value = read_ok and value_label(class_obj) or "",
            error = read_ok and "" or first_error_line(class_obj),
        }
        report.class_refs[#report.class_refs + 1] = entry
        if not read_ok or not is_valid(class_obj) then
            report.result = read_ok and "class_ref_invalid" or "class_ref_read_failed"
            report.error = ref_spec.field .. ": " .. (entry.error ~= "" and entry.error or "invalid class ref")
            lines[result_line_index] = "  result=" .. report.result
            lines[#lines + 1] = "  error: " .. report.error
            for line_index = 1, #lines do print(lines[line_index]) end
            local file_ok, write_detail = write_report_files(file_stem, report, lines)
            local detail = string.format("source=%s layout=%s result=%s", source.mode or "", layout_key, report.result)
            if file_ok then return false, detail .. " wrote " .. tostring(write_detail) end
            return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
        end
        class_refs[ref_key] = class_obj
        lines[#lines + 1] = string.format("  class_ref %s %s full=%s", ref_key, entry.name, entry.full_name)
    end

    local pieces = {}
    if layout_key == "pair" then
        pieces = {
            { ref = "room", label = "room_a", x = 0, y = 0, yaw = 0 },
            { ref = "hallway", label = "hallway_a", x = step, y = 0, yaw = 0 },
        }
    elseif layout_key == "line3" then
        pieces = {
            { ref = "room", label = "room_a", x = 0, y = 0, yaw = 0 },
            { ref = "hallway", label = "hallway_a", x = step, y = 0, yaw = 0 },
            { ref = "room", label = "room_b", x = step * 2, y = 0, yaw = 0 },
        }
    elseif layout_key == "line5" then
        pieces = {
            { ref = "room", label = "room_a", x = 0, y = 0, yaw = 0 },
            { ref = "hallway", label = "hallway_a", x = step, y = 0, yaw = 0 },
            { ref = "room", label = "room_b", x = step * 2, y = 0, yaw = 0 },
            { ref = "hallway", label = "hallway_b", x = step * 3, y = 0, yaw = 0 },
            { ref = "room", label = "room_c", x = step * 4, y = 0, yaw = 0 },
        }
    elseif layout_key == "grid3" then
        local room_index = 0
        local hallway_index = 0
        for grid_y = 0, 2 do
            for grid_x = 0, 2 do
                room_index = room_index + 1
                pieces[#pieces + 1] = { ref = "room", label = "room_" .. tostring(room_index), x = grid_x * step * 2, y = grid_y * step * 2, yaw = 0 }
            end
        end
        for grid_y = 0, 2 do
            for grid_x = 0, 1 do
                hallway_index = hallway_index + 1
                pieces[#pieces + 1] = { ref = "hallway", label = "hallway_h_" .. tostring(hallway_index), x = (grid_x * 2 + 1) * step, y = grid_y * step * 2, yaw = 0 }
            end
        end
        for grid_x = 0, 2 do
            for grid_y = 0, 1 do
                hallway_index = hallway_index + 1
                pieces[#pieces + 1] = { ref = "hallway", label = "hallway_v_" .. tostring(hallway_index), x = grid_x * step * 2, y = (grid_y * 2 + 1) * step, yaw = 90 }
            end
        end
    else
        pieces = {
            { ref = "room", label = "room_center", x = 0, y = 0, yaw = 0 },
            { ref = "hallway", label = "hallway_e", x = step, y = 0, yaw = 0 },
            { ref = "hallway", label = "hallway_w", x = -step, y = 0, yaw = 0 },
            { ref = "hallway", label = "hallway_n", x = 0, y = step, yaw = 90 },
            { ref = "hallway", label = "hallway_s", x = 0, y = -step, yaw = 90 },
            { ref = "room", label = "room_e", x = step * 2, y = 0, yaw = 0 },
            { ref = "room", label = "room_w", x = -step * 2, y = 0, yaw = 0 },
            { ref = "room", label = "room_n", x = 0, y = step * 2, yaw = 0 },
            { ref = "room", label = "room_s", x = 0, y = -step * 2, yaw = 0 },
        }
    end

    local spawned_count = 0
    local failed_count = 0
    for piece_index, piece in ipairs(pieces) do
        local class_obj = class_refs[piece.ref]
        local loc = { X = origin.X + piece.x, Y = origin.Y + piece.y, Z = origin.Z + (piece.z or 0) }
        local rot = { Pitch = 0, Yaw = piece.yaw or 0, Roll = 0 }
        report.result = "about_to_spawn_" .. tostring(piece_index) .. "_" .. piece.label
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local actor = nil
        local spawn_ok, spawn_error = pcall(function()
            actor = world:SpawnActor(class_obj, loc, rot)
        end)
        local actor_entry = {
            index = piece_index,
            label = piece.label,
            ref = piece.ref,
            requested_location = vec_text(loc),
            yaw = piece.yaw or 0,
            ok = spawn_ok == true and is_valid(actor),
            name = "",
            class = "",
            full_name = "",
            location = "",
            place_ok = false,
            rotation_ok = false,
            error = "",
        }
        if actor_entry.ok then
            spawned_count = spawned_count + 1
            pcall(function() actor["bRegisterAsRuntimeSpawned"] = true end)
            pcall(function() feature_actor.force_actor_movable(actor) end)
            local move_ok, move_error = feature_actor.move_actor(actor, loc)
            actor_entry.place_ok = move_ok == true
            actor_entry.rotation_ok = feature_actor.set_actor_rotation(actor, rot) == true
            actor_entry.name = safe_name(actor)
            actor_entry.class = safety.class_name_of(actor) or ""
            actor_entry.full_name = safe_full_name(actor)
            actor_entry.location = object_location_text(actor)
            actor_entry.error = move_ok and "" or first_error_line(move_error)
            remember_generated_spawn_actor(cache_batch, actor, piece.label, piece.ref)
            lines[#lines + 1] = string.format("  [%d] %s %s actor=%s loc=%s place=%s rot=%s", piece_index, piece.label, piece.ref, actor_entry.name, actor_entry.location, tostring(actor_entry.place_ok), tostring(actor_entry.rotation_ok))
        else
            failed_count = failed_count + 1
            actor_entry.error = spawn_ok and "invalid actor" or first_error_line(spawn_error)
            lines[#lines + 1] = string.format("  [%d] %s %s failed: %s", piece_index, piece.label, piece.ref, actor_entry.error)
        end
        report.actors[#report.actors + 1] = actor_entry
    end

    report.after_counts = generated_counts_snapshot()
    local delta_parts = generated_delta_parts(report.before_counts, report.after_counts)
    report.generated_deltas = delta_parts
    report.result = failed_count == 0 and "spawned_layout" or "spawned_layout_partial"
    lines[result_line_index] = "  result=" .. report.result
    if #delta_parts > 0 then
        lines[#lines + 1] = "  generated_deltas " .. table.concat(delta_parts, " ")
    else
        lines[#lines + 1] = "  generated_deltas none"
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("source=%s layout=%s pieces=%d spawned=%d failed=%d deltas=%d", source.mode or "", layout_key, #pieces, spawned_count, failed_count, #delta_parts)
    if file_ok then return spawned_count > 0, detail .. " wrote " .. tostring(write_detail) end
    return spawned_count > 0, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generator_spawnconnected(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generator.spawnconnected [cdo|generator_index] [room_count] [tile_step] [branch_percent] [seed] [smartdirect|smart|prefabs|base] [origin_x origin_y origin_z] confirm"
    if #tokens < 1 or tokens[#tokens] ~= "confirm" then return false, usage end

    local source_token = "cdo"
    local room_count = 50
    local tile_step = DUNGEON_TILE_SIZE_CM
    local branch_percent = 35
    local seed = 1337
    local room_mode = "smart"
    local origin_x, origin_y, origin_z = CONNECTED_SMART.default_origin.X, CONNECTED_SMART.default_origin.Y, CONNECTED_SMART.default_origin.Z
    local arg_index = 1
    local limit = #tokens - 1
    local first_token = tokens[arg_index] and tostring(tokens[arg_index]):lower() or ""
    if first_token == "cdo" or first_token == "default" or tonumber(first_token) then
        source_token = tokens[arg_index]
        arg_index = arg_index + 1
    end

    local function take_mode()
        local token = tokens[arg_index] and tostring(tokens[arg_index]):lower() or ""
        local mode = CONNECTED_ROOM_MODE_ALIASES[token]
        if mode then
            room_mode = mode
            arg_index = arg_index + 1
            return true
        end
        return false
    end

    take_mode()
    if arg_index <= limit and tonumber(tokens[arg_index]) then
        room_count = tonumber(tokens[arg_index]) or room_count
        arg_index = arg_index + 1
    end
    if arg_index <= limit and tonumber(tokens[arg_index]) then
        tile_step = tonumber(tokens[arg_index]) or tile_step
        arg_index = arg_index + 1
    end
    if arg_index <= limit and tonumber(tokens[arg_index]) then
        branch_percent = tonumber(tokens[arg_index]) or branch_percent
        arg_index = arg_index + 1
    end
    if arg_index <= limit and tonumber(tokens[arg_index]) then
        seed = tonumber(tokens[arg_index]) or seed
        arg_index = arg_index + 1
    end
    take_mode()
    local remaining = limit - arg_index + 1
    if remaining == 3 then
        local parsed_x = tonumber(tokens[arg_index])
        local parsed_y = tonumber(tokens[arg_index + 1])
        local parsed_z = tonumber(tokens[arg_index + 2])
        if not parsed_x or not parsed_y or not parsed_z then return false, "origin_x/origin_y/origin_z must be numbers" end
        origin_x, origin_y, origin_z = parsed_x, parsed_y, parsed_z
        arg_index = arg_index + 3
    elseif remaining ~= 0 then
        return false, usage
    end
    if arg_index <= limit then return false, usage end

    room_count = math.floor(room_count)
    tile_step = tonumber(tile_step) or DUNGEON_TILE_SIZE_CM
    branch_percent = tonumber(branch_percent) or 35
    seed = math.floor(tonumber(seed) or 1337)
    if room_count < 1 then return false, "room_count must be >= 1" end
    if room_count > CONNECTED_DUNGEON_MAX_ROOMS then return false, "room_count capped at " .. tostring(CONNECTED_DUNGEON_MAX_ROOMS) .. " for this first massive-spawn harness" end
    if tile_step < 100 or tile_step > 5000 then return false, "tile_step must be between 100 and 5000 cm" end
    if branch_percent < 0 or branch_percent > 100 then return false, "branch_percent must be 0..100" end
    if seed == 0 then seed = 1 end

    local file_stem = "dungeon_proc_generator_spawnconnected"
    local generator, source, resolve_error = resolve_generator_ref_source(source_token, file_stem)
    if resolve_error then return false, resolve_error end
    if not source then return false, "generator source metadata unavailable" end
    if not is_valid(generator) then return false, "generator source unavailable" end

    local pawn = feature_actor.get_local_pawn()
    local world, world_route = get_world_for_spawn(pawn)
    if not world then return false, "UWorld unavailable for SpawnActor" end
    if not world.SpawnActor then return false, "UWorld:SpawnActor missing in this UE4SS build" end

    local origin = {
        X = tonumber(origin_x) or CONNECTED_SMART.default_origin.X,
        Y = tonumber(origin_y) or CONNECTED_SMART.default_origin.Y,
        Z = tonumber(origin_z) or CONNECTED_SMART.default_origin.Z,
    }
    local cache_batch = begin_generated_spawn_batch("spawnconnected:" .. room_mode)
    local report = {
        command = "world.dungeon.proc.generator.spawnconnected",
        confirmed = true,
        cache_batch = cache_batch,
        source = source,
        requested = { rooms = room_count, tile_step = tile_step, branch_percent = branch_percent, seed = seed, mode = room_mode, origin = { x = origin.X, y = origin.Y, z = origin.Z } },
        config_basis = { one_meter_size_cm = 100, one_tile_size_cm = tile_step, room_spacing_cm = tile_step * 2, max_connections_per_room = CONNECTED_DUNGEON_MAX_LINKS_PER_ROOM, native_max_hallway_length_tiles = 25 },
        origin = vec_text(origin),
        world_context = { name = safe_name(pawn), class = safety.class_name_of(pawn) or "", full_name = safe_full_name(pawn) },
        class_refs = {},
        prefabs = {},
        nodes = {},
        edges = {},
        structural_roles = CONNECTED_SMART.structural_role_plan,
        population_marker_counts = { enemy = 0, chest = 0, resource = 0 },
        population_markers = {},
        actors = {},
        before_counts = generated_counts_snapshot(),
        after_counts = {},
        generated_deltas = {},
        result = "about_to_read_classrefs",
        error = "",
        world_route = world_route or "",
        warning = "spawns a connected room/hallway actor tree from direct BP classes; no Init/CreateRoom/CreateHallway/teleport/session lifecycle calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generator.spawnconnected --",
        string.format("  source=%s index=%d %s [%s]", source.mode, source.index or 0, source.name or "", source.class or ""),
        string.format("  rooms=%d tile_step=%.1f branch=%d seed=%d mode=%s origin=%s", room_count, tile_step, math.floor(branch_percent), seed, room_mode, report.origin),
        string.format("  world_context %s [%s]", report.world_context.name, report.world_context.class),
        "  world_route=" .. tostring(report.world_route),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    local result_line_index = 7

    local class_refs = {}
    for _ref_index, ref_key in ipairs(GENERATOR_CLASSREF_ORDER) do
        local ref_spec = GENERATOR_CLASSREF_FIELDS[ref_key]
        report.result = "about_to_read_" .. ref_spec.field
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local read_ok, class_obj = read_field(generator, ref_spec.field)
        local entry = {
            key = ref_key,
            field = ref_spec.field,
            ok = read_ok == true,
            valid = read_ok and is_valid(class_obj) or false,
            name = read_ok and safe_name(class_obj) or "",
            class = read_ok and (safety.class_name_of(class_obj) or "") or "",
            full_name = read_ok and safe_full_name(class_obj) or "",
            value = read_ok and value_label(class_obj) or "",
            error = read_ok and "" or first_error_line(class_obj),
        }
        report.class_refs[#report.class_refs + 1] = entry
        if not read_ok or not is_valid(class_obj) then
            report.result = read_ok and "class_ref_invalid" or "class_ref_read_failed"
            report.error = ref_spec.field .. ": " .. (entry.error ~= "" and entry.error or "invalid class ref")
            lines[result_line_index] = "  result=" .. report.result
            lines[#lines + 1] = "  error: " .. report.error
            for line_index = 1, #lines do print(lines[line_index]) end
            local file_ok, write_detail = write_report_files(file_stem, report, lines)
            local detail = string.format("source=%s result=%s", source.mode or "", report.result)
            if file_ok then return false, detail .. " wrote " .. tostring(write_detail) end
            return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
        end
        class_refs[ref_key] = class_obj
        lines[#lines + 1] = string.format("  class_ref %s %s full=%s", ref_key, entry.name, entry.full_name)
    end

    local prefab_classes = {}
    local smart_layout_mode = room_mode == "smart" or room_mode == "smartdirect"
    if smart_layout_mode then
        for catalog_index, catalog_entry in ipairs(dungeon_room_catalog.entries or {}) do
            local raw_catalog_usable = catalog_entry.usable_for_smart_chain == true and (catalog_entry.opening_count or 0) > 0 and (catalog_entry.cell_count or 0) > 0
            local resolved_spec = { key = catalog_entry.key, label = catalog_entry.label, class_path = catalog_entry.class_path, catalog = catalog_entry }
            local layout_spec = CONNECTED_SMART.apply_special_connector_override(resolved_spec)
            local layout_entry = layout_spec.catalog or catalog_entry
            local special_connector_reason = layout_entry.special_connector_reason or ""
            local catalog_usable = (raw_catalog_usable or special_connector_reason ~= "") and (layout_entry.opening_count or 0) > 0 and (layout_entry.cell_count or 0) > 0
            local prefab_entry = {
                index = catalog_index,
                key = catalog_entry.key or "",
                label = catalog_entry.label or "",
                class_path = catalog_entry.class_path or "",
                category = catalog_entry.category or "",
                shape_type = catalog_entry.shape_type or "",
                cell_count = layout_entry.cell_count or 0,
                opening_count = layout_entry.opening_count or 0,
                passable_sides = table.concat(layout_entry.passable_sides or {}, ""),
                usable = catalog_usable,
                special_connector_reason = special_connector_reason,
                ok = false,
                name = "",
                class = "",
                full_name = "",
                error = catalog_usable and "" or "no_usable_edge_openings",
            }
            if catalog_usable then
                report.result = "about_to_resolve_catalog_prefab_" .. tostring(catalog_entry.key or catalog_index)
                lines[result_line_index] = "  result=" .. report.result
                write_report_files(file_stem .. "_attempt", report, lines)
                local prefab_class = player_core.resolve_uclass(catalog_entry.class_path)
                local prefab_ok = is_valid(prefab_class)
                prefab_entry.ok = prefab_ok == true
                prefab_entry.name = prefab_ok and safe_name(prefab_class) or ""
                prefab_entry.class = prefab_ok and (safety.class_name_of(prefab_class) or "") or ""
                prefab_entry.full_name = prefab_ok and safe_full_name(prefab_class) or ""
                prefab_entry.error = prefab_ok and "" or "resolve_failed"
                if prefab_ok then
                    layout_spec.class_obj = prefab_class
                    prefab_classes[#prefab_classes + 1] = layout_spec
                    local special_note = special_connector_reason ~= "" and (" special=" .. special_connector_reason) or ""
                    lines[#lines + 1] = string.format("  catalog_prefab %s ok cells=%d openings=%d sides=%s%s", catalog_entry.key or "", layout_entry.cell_count or 0, layout_entry.opening_count or 0, prefab_entry.passable_sides, special_note)
                else
                    lines[#lines + 1] = string.format("  catalog_prefab %s unresolved", catalog_entry.key or "")
                end
            else
                lines[#lines + 1] = string.format("  catalog_prefab %s skipped: no usable edge openings", catalog_entry.key or "")
            end
            report.prefabs[#report.prefabs + 1] = prefab_entry
        end
        if #prefab_classes == 0 then lines[#lines + 1] = "  warning: no smart catalog prefab classes resolved; nothing will be spawned in smart mode" end
    elseif room_mode == "prefabs" then
        for prefab_index, prefab_spec in ipairs(CONNECTED_ROOM_PREFAB_SPECS) do
            report.result = "about_to_resolve_prefab_" .. prefab_spec.key
            lines[result_line_index] = "  result=" .. report.result
            write_report_files(file_stem .. "_attempt", report, lines)
            local prefab_class = player_core.resolve_uclass(prefab_spec.path)
            local prefab_ok = is_valid(prefab_class)
            local prefab_entry = {
                index = prefab_index,
                key = prefab_spec.key,
                label = prefab_spec.label,
                class_path = prefab_spec.path,
                ok = prefab_ok == true,
                name = prefab_ok and safe_name(prefab_class) or "",
                class = prefab_ok and (safety.class_name_of(prefab_class) or "") or "",
                full_name = prefab_ok and safe_full_name(prefab_class) or "",
                error = prefab_ok and "" or "resolve_failed",
            }
            report.prefabs[#report.prefabs + 1] = prefab_entry
            if prefab_ok then
                prefab_classes[#prefab_classes + 1] = { key = prefab_spec.key, label = prefab_spec.label, class_path = prefab_spec.path, class_obj = prefab_class }
                lines[#lines + 1] = string.format("  prefab %s ok %s", prefab_spec.key, prefab_entry.name)
            else
                lines[#lines + 1] = string.format("  prefab %s unresolved; base room fallback will be used", prefab_spec.key)
            end
        end
        if #prefab_classes == 0 then lines[#lines + 1] = "  warning: no prefab classes resolved; using generator RoomSpawnSubclass for all rooms" end
    end

    local pieces = {}
    local layout_result = ""
    local smart_layout = nil
    if smart_layout_mode then
        local use_hallways = room_mode ~= "smartdirect"
        local function required_missing_count(layout)
            return #((((layout or {}).stats or {}).required_prefab_missing) or {})
        end
        local function reserved_missing_count(layout)
            return #((((layout or {}).stats or {}).reserved_terminal_missing) or {})
        end
        local function entrance_hub_missing_count(layout)
            local stats = ((layout or {}).stats or {})
            local target = math.floor(tonumber(stats.entrance_hub_target) or 0)
            local attached = math.floor(tonumber(stats.entrance_hub_attached) or 0)
            if target <= 0 then return 0 end
            if attached >= target then return 0 end
            return target - attached
        end
        local function layout_rank(layout)
            local stats = (layout or {}).stats or {}
            return - (required_missing_count(layout) * 10000000)
                - (entrance_hub_missing_count(layout) * 5000000)
                - (reserved_missing_count(layout) * 1000000)
                + (#((layout or {}).nodes or {}) * 100000)
                + ((tonumber(stats.unique_prefabs) or 0) * 100)
                + ((tonumber(stats.entrance_hub_attached) or 0) * 10000)
                + (tonumber(stats.terminal_attach_attached) or 0)
        end
        local function fallback_preserves_required(current_layout, candidate_layout)
            if not candidate_layout then return false end
            if not current_layout then return true end
            if reserved_missing_count(candidate_layout) > reserved_missing_count(current_layout) then return false end
            if entrance_hub_missing_count(candidate_layout) > entrance_hub_missing_count(current_layout) then return false end
            if required_missing_count(candidate_layout) > required_missing_count(current_layout) then return false end
            if #((candidate_layout or {}).nodes or {}) > #((current_layout or {}).nodes or {}) then return true end
            return layout_rank(candidate_layout) > layout_rank(current_layout)
        end
        for required_attempt = 1, CONNECTED_SMART.required_variety_attempts do
            local attempt_seed = seed + ((required_attempt - 1) * 7919)
            local candidate_layout = CONNECTED_SMART.build(room_count, branch_percent, attempt_seed, prefab_classes, use_hallways, "required_variety_v1")
            candidate_layout.stats.required_variety_attempt = required_attempt
            candidate_layout.stats.requested_seed = seed
            if not smart_layout or layout_rank(candidate_layout) > layout_rank(smart_layout) then smart_layout = candidate_layout end
            if #(candidate_layout.nodes or {}) >= room_count and #((candidate_layout.stats or {}).required_prefab_missing or {}) == 0 then
                smart_layout = candidate_layout
                break
            end
        end
        if #(smart_layout.nodes or {}) < room_count then
            local diversity_layout = CONNECTED_SMART.build(room_count, branch_percent, seed, prefab_classes, use_hallways, "diversity_soft_caps_v2")
            if fallback_preserves_required(smart_layout, diversity_layout) then
                diversity_layout.stats.fallback_from = {
                    selection_policy = (smart_layout.stats or {}).selection_policy or "",
                    result = smart_layout.result or "",
                    nodes = #(smart_layout.nodes or {}),
                    edges = #(smart_layout.edges or {}),
                }
                smart_layout = diversity_layout
            end
        end
        if #(smart_layout.nodes or {}) < room_count then
            local capacity_layout = CONNECTED_SMART.build(room_count, branch_percent, seed, prefab_classes, use_hallways, "capacity_backbone_v1")
            if fallback_preserves_required(smart_layout, capacity_layout) then
                capacity_layout.stats.fallback_from = {
                    selection_policy = (smart_layout.stats or {}).selection_policy or "",
                    result = smart_layout.result or "",
                    nodes = #(smart_layout.nodes or {}),
                    edges = #(smart_layout.edges or {}),
                }
                smart_layout = capacity_layout
            end
        end
        layout_result = smart_layout.result or "unknown"
        report.layout_result = layout_result
        report.topology = smart_layout.stats or {}
        report.config_basis.room_spacing_cm = use_hallways and "catalog_wall_slots_plus_one_tile_hallway" or "catalog_reviewed_playable_slots_world_z_aligned_centered_wall_span_with_clearance_capacity_backbone_diversity_soft_caps"
        for _node_index, node in ipairs(smart_layout.nodes or {}) do
            report.nodes[#report.nodes + 1] = {
                index = node.index,
                grid = { x = node.cell_x, y = node.cell_y },
                z_cm = node.z_cm or 0,
                parent = node.parent,
                depth = node.depth,
                links = node.links,
                max_links = node.max_links,
                yaw = node.room_yaw,
                key = node.key,
                category = node.category,
                cell_count = node.cell_count,
                opening_count = node.opening_count,
            }
            for marker_index, marker in ipairs((((node.prefab or {}).catalog or {}).population_markers) or {}) do
                local world_location = CONNECTED_SMART.population_marker_world(node, marker, origin, tile_step)
                local marker_kind = marker.kind or "other"
                local direct_actor_spawn_location, direct_actor_spawn_z_offset_cm = CONNECTED_SMART.population_marker_direct_actor_spawn_world(marker_kind, world_location)
                report.population_marker_counts[marker_kind] = (report.population_marker_counts[marker_kind] or 0) + 1
                report.population_markers[#report.population_markers + 1] = {
                    index = #report.population_markers + 1,
                    room_index = node.index,
                    room_key = node.key or "",
                    marker_index = marker_index,
                    marker_name = marker.name or "",
                    kind = marker_kind,
                    class_name = marker.class_name or "",
                    class_path = marker.class_path or "",
                    relative_location = marker.relative_location or {},
                    world_location = { x = world_location.X, y = world_location.Y, z = world_location.Z },
                    world_location_text = vec_text(world_location),
                    world_yaw = ((tonumber(marker.relative_yaw) or 0) + (tonumber(node.room_yaw) or 0)) % 360,
                    direct_actor_spawn_location = direct_actor_spawn_location and { x = direct_actor_spawn_location.X, y = direct_actor_spawn_location.Y, z = direct_actor_spawn_location.Z } or nil,
                    direct_actor_spawn_location_text = direct_actor_spawn_location and vec_text(direct_actor_spawn_location) or "",
                    direct_actor_spawn_z_offset_cm = direct_actor_spawn_z_offset_cm,
                    source = "archive_child_actor_component",
                }
            end
            pieces[#pieces + 1] = {
                ref = "room",
                label = string.format("room_%03d_%s", node.index, node.key or "catalog"),
                node_index = node.index,
                depth = node.depth,
                grid_x = node.cell_x,
                grid_y = node.cell_y,
                x = node.cell_x * tile_step,
                y = node.cell_y * tile_step,
                z = (node.z_cm or 0) * (tile_step / DUNGEON_TILE_SIZE_CM),
                yaw = node.room_yaw or 0,
                prefab = node.prefab,
            }
        end
        for _edge_index, edge in ipairs(smart_layout.edges or {}) do
            local hallway = (smart_layout.hallways or {})[edge.hallway_index or 0] or {}
            report.edges[#report.edges + 1] = { index = edge.index, parent = edge.parent, child = edge.child, grid = { x = hallway.x or 0, y = hallway.y or 0 }, dir = edge.dir, yaw = hallway.yaw or 0, loop = edge.loop == true, direct = edge.direct == true, parent_opening = edge.parent_opening, child_opening = edge.child_opening }
        end
        for _hallway_index, hallway in ipairs(smart_layout.hallways or {}) do
            pieces[#pieces + 1] = {
                ref = "hallway",
                label = string.format("hallway_%03d_%s%s", hallway.index, hallway.side or "", hallway.loop and "_loop" or ""),
                edge_index = hallway.index,
                parent = hallway.parent,
                child = hallway.child,
                grid_x = hallway.x,
                grid_y = hallway.y,
                x = hallway.x * tile_step,
                y = hallway.y * tile_step,
                yaw = hallway.yaw or 0,
            }
        end
        local function count_map_text(counts)
            local keys = {}
            for key, _count in pairs(counts or {}) do keys[#keys + 1] = key end
            table.sort(keys)
            if #keys == 0 then return "none" end
            local parts = {}
            for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. tostring(counts[key]) end
            return table.concat(parts, " ")
        end
        lines[#lines + 1] = string.format("  layout_result=%s nodes=%d edges=%d occupied_cells=%d rejected=%d clearance_rejections=%d z_adjusted_rooms=%d z_range_cm=%.1f..%.1f unique_prefabs=%d loops=%d hallways=%s", layout_result, #(smart_layout.nodes or {}), #(smart_layout.edges or {}), (smart_layout.stats or {}).occupied_cells or 0, (smart_layout.stats or {}).rejected_openings or 0, (smart_layout.stats or {}).clearance_rejections or 0, (smart_layout.stats or {}).z_adjusted_rooms or 0, (smart_layout.stats or {}).min_room_z_cm or 0, (smart_layout.stats or {}).max_room_z_cm or 0, (smart_layout.stats or {}).unique_prefabs or 0, (smart_layout.stats or {}).loops_added or 0, tostring(use_hallways))
        lines[#lines + 1] = string.format("  selection_policy=%s native_cap_overage_total=%d", (smart_layout.stats or {}).selection_policy or "unknown", (smart_layout.stats or {}).native_cap_overage_total or 0)
        if (smart_layout.stats or {}).fallback_from then
            local fallback = smart_layout.stats.fallback_from
            lines[#lines + 1] = string.format("  capacity_fallback from=%s result=%s nodes=%d edges=%d", fallback.selection_policy or "", fallback.result or "", fallback.nodes or 0, fallback.edges or 0)
        end
        lines[#lines + 1] = "  prefab_usage " .. count_map_text((smart_layout.stats or {}).prefab_counts)
        lines[#lines + 1] = "  category_usage " .. count_map_text((smart_layout.stats or {}).category_counts)
        lines[#lines + 1] = "  native_cap_overages " .. count_map_text((smart_layout.stats or {}).native_cap_overages)
        lines[#lines + 1] = "  reserved_terminal_usage " .. count_map_text((smart_layout.stats or {}).reserved_terminal_counts)
        local reserved_terminal_missing = table.concat((smart_layout.stats or {}).reserved_terminal_missing or {}, ",")
        lines[#lines + 1] = "  reserved_terminal_missing " .. (reserved_terminal_missing ~= "" and reserved_terminal_missing or "none")
        local entrance_hub_parts = {}
        for _, connector in ipairs((smart_layout.stats or {}).entrance_hub_connectors or {}) do
            entrance_hub_parts[#entrance_hub_parts + 1] = string.format("%s->%s#%s", connector.connector or connector.side or "", connector.key or "", tostring(connector.child or ""))
        end
        local entrance_hub_failed = table.concat((smart_layout.stats or {}).entrance_hub_failed or {}, ",")
        lines[#lines + 1] = string.format("  entrance_hub enabled=%s attached=%d/%d attempted=%d connectors=%s failed=%s", tostring((smart_layout.stats or {}).entrance_hub_enabled == true), (smart_layout.stats or {}).entrance_hub_attached or 0, (smart_layout.stats or {}).entrance_hub_target or 0, (smart_layout.stats or {}).entrance_hub_attempted or 0, table.concat(entrance_hub_parts, ",") ~= "" and table.concat(entrance_hub_parts, ",") or "none", entrance_hub_failed ~= "" and entrance_hub_failed or "none")
        lines[#lines + 1] = string.format("  required_variety attempt=%d layout_seed=%d backbone=%d/%d terminal_staged_at=%d terminal_attached=%d/%d", (smart_layout.stats or {}).required_variety_attempt or 0, (smart_layout.stats or {}).layout_seed or seed, (smart_layout.stats or {}).backbone_nodes or 0, (smart_layout.stats or {}).backbone_target or 0, (smart_layout.stats or {}).terminal_attach_staged_at or 0, (smart_layout.stats or {}).terminal_attach_attached or 0, (smart_layout.stats or {}).terminal_attach_attempted or 0)
        local required_prefab_missing = table.concat((smart_layout.stats or {}).required_prefab_missing or {}, ",")
        lines[#lines + 1] = "  required_prefab_missing " .. (required_prefab_missing ~= "" and required_prefab_missing or "none")
        local terminal_attach_failed = table.concat((smart_layout.stats or {}).terminal_attach_failed or {}, ",")
        lines[#lines + 1] = "  terminal_attach_failed " .. (terminal_attach_failed ~= "" and terminal_attach_failed or "none")
        lines[#lines + 1] = "  population_markers " .. count_map_text(report.population_marker_counts)
        for _, role in ipairs(CONNECTED_SMART.structural_role_plan) do
            lines[#lines + 1] = string.format("  structural_role %s=%s status=%s reason=%s connector_hint=%s", role.role or "", role.key or "", role.status or "", role.reason or "", role.connector_hint or "")
        end
    else
        local nodes, edges = nil, nil
        nodes, edges, layout_result = build_connected_dungeon_layout(room_count, branch_percent, seed)
        for _node_index, node in ipairs(nodes) do
            report.nodes[#report.nodes + 1] = { index = node.index, grid = { x = node.x, y = node.y }, parent = node.parent, depth = node.depth, links = node.links, from_dir = node.from_dir, yaw = node.room_yaw }
        end
        for _edge_index, edge in ipairs(edges) do
            report.edges[#report.edges + 1] = { index = edge.index, parent = edge.parent, child = edge.child, grid = { x = edge.x, y = edge.y }, dir = edge.dir, yaw = edge.yaw }
        end
        report.layout_result = layout_result
        lines[#lines + 1] = string.format("  layout_result=%s nodes=%d edges=%d", layout_result, #nodes, #edges)

        local seed_abs = math.floor(math.abs(seed))
        local function prefab_for_node(node)
            if room_mode ~= "prefabs" or #prefab_classes == 0 or node.index == 1 then return nil end
            local pick = ((node.index * 7 + node.depth * 11 + seed_abs) % #prefab_classes) + 1
            return prefab_classes[pick]
        end

        for _node_index, node in ipairs(nodes) do
            local prefab = prefab_for_node(node)
            local label = string.format("room_%03d", node.index)
            if prefab then label = label .. "_" .. prefab.key end
            pieces[#pieces + 1] = { ref = "room", label = label, node_index = node.index, depth = node.depth, grid_x = node.x, grid_y = node.y, x = node.x * tile_step * 2, y = node.y * tile_step * 2, yaw = node.room_yaw or 0, prefab = prefab }
        end
        for _edge_index, edge in ipairs(edges) do
            pieces[#pieces + 1] = { ref = "hallway", label = string.format("hallway_%03d_%s", edge.index, edge.dir), edge_index = edge.index, parent = edge.parent, child = edge.child, grid_x = edge.x, grid_y = edge.y, x = edge.x * tile_step, y = edge.y * tile_step, yaw = edge.yaw or 0 }
        end
    end
    report.pieces_requested = #pieces

    local spawned_count = 0
    local spawned_room_count = 0
    local spawned_hallway_count = 0
    local failed_count = 0
    local smart_runtime = { rooms = {}, hallways = {} }
    for piece_index, piece in ipairs(pieces) do
        local class_obj = class_refs[piece.ref]
        local class_key = piece.ref
        local class_path = ""
        if piece.ref == "room" and piece.prefab and is_valid(piece.prefab.class_obj) then
            class_obj = piece.prefab.class_obj
            class_key = piece.prefab.key
            class_path = piece.prefab.class_path
        end
        local loc = { X = origin.X + piece.x, Y = origin.Y + piece.y, Z = origin.Z + (piece.z or 0) }
        local rot = { Pitch = 0, Yaw = piece.yaw or 0, Roll = 0 }
        report.result = "about_to_spawn_" .. tostring(piece_index) .. "_" .. piece.label
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local actor = nil
        local spawn_ok, spawn_error = pcall(function()
            actor = world:SpawnActor(class_obj, loc, rot)
        end)
        local actor_entry = {
            index = piece_index,
            label = piece.label,
            ref = piece.ref,
            class_key = class_key,
            class_path = class_path,
            node_index = piece.node_index or 0,
            edge_index = piece.edge_index or 0,
            parent = piece.parent or 0,
            child = piece.child or 0,
            grid = { x = piece.grid_x or 0, y = piece.grid_y or 0 },
            depth = piece.depth or 0,
            requested_location = vec_text(loc),
            yaw = piece.yaw or 0,
            ok = spawn_ok == true and is_valid(actor),
            name = "",
            class = "",
            full_name = "",
            location = "",
            place_ok = false,
            rotation_ok = false,
            error = "",
        }
        if actor_entry.ok then
            spawned_count = spawned_count + 1
            if piece.ref == "hallway" then spawned_hallway_count = spawned_hallway_count + 1 else spawned_room_count = spawned_room_count + 1 end
            pcall(function() actor["bRegisterAsRuntimeSpawned"] = true end)
            pcall(function() feature_actor.force_actor_movable(actor) end)
            local move_ok, move_error = feature_actor.move_actor(actor, loc)
            actor_entry.place_ok = move_ok == true
            actor_entry.rotation_ok = feature_actor.set_actor_rotation(actor, rot) == true
            actor_entry.name = safe_name(actor)
            actor_entry.class = safety.class_name_of(actor) or ""
            actor_entry.full_name = safe_full_name(actor)
            actor_entry.location = object_location_text(actor)
            actor_entry.error = move_ok and "" or first_error_line(move_error)
            remember_generated_spawn_actor(cache_batch, actor, piece.label, class_key)
            if smart_layout_mode then
                if piece.ref == "room" and (piece.node_index or 0) > 0 then
                    smart_runtime.rooms[piece.node_index] = { actor = actor, name = actor_entry.name, full_name = actor_entry.full_name, label = piece.label }
                elseif piece.ref == "hallway" and (piece.edge_index or 0) > 0 then
                    smart_runtime.hallways[piece.edge_index] = { actor = actor, name = actor_entry.name, full_name = actor_entry.full_name, label = piece.label }
                end
            end
            if piece_index <= CONNECTED_DUNGEON_LINE_SAMPLE_LIMIT then
                lines[#lines + 1] = string.format("  [%d] %s %s class=%s actor=%s loc=%s place=%s rot=%s", piece_index, piece.label, piece.ref, class_key, actor_entry.name, actor_entry.location, tostring(actor_entry.place_ok), tostring(actor_entry.rotation_ok))
            elseif piece_index == CONNECTED_DUNGEON_LINE_SAMPLE_LIMIT + 1 then
                lines[#lines + 1] = string.format("  actor lines truncated after %d entries; full actor list is in json", CONNECTED_DUNGEON_LINE_SAMPLE_LIMIT)
            end
        else
            failed_count = failed_count + 1
            actor_entry.error = spawn_ok and "invalid actor" or first_error_line(spawn_error)
            lines[#lines + 1] = string.format("  [%d] %s %s class=%s failed: %s", piece_index, piece.label, piece.ref, class_key, actor_entry.error)
        end
        report.actors[#report.actors + 1] = actor_entry
    end

    report.after_counts = generated_counts_snapshot()
    local delta_parts = generated_delta_parts(report.before_counts, report.after_counts)
    report.generated_deltas = delta_parts
    report.spawned = { total = spawned_count, rooms = spawned_room_count, hallways = spawned_hallway_count, failed = failed_count }
    if smart_layout_mode and smart_layout then
        generated_spawn_cache.latest_connected = {
            batch = cache_batch,
            mode = room_mode,
            seed = seed,
            origin = { X = origin.X, Y = origin.Y, Z = origin.Z },
            tile_step = tile_step,
            layout = smart_layout,
            rooms = smart_runtime.rooms,
            hallways = smart_runtime.hallways,
            structural_roles = report.structural_roles,
            population_marker_counts = report.population_marker_counts,
            population_markers = report.population_markers,
            created_unix = os.time(),
        }
        report.latest_connected = { batch = cache_batch, rooms_cached = spawned_room_count, hallways_cached = spawned_hallway_count }
    end
    report.result = failed_count == 0 and "spawned_connected" or "spawned_connected_partial"
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = string.format("  spawned rooms=%d hallways=%d failed=%d pieces=%d", spawned_room_count, spawned_hallway_count, failed_count, #pieces)
    if #delta_parts > 0 then
        lines[#lines + 1] = "  generated_deltas " .. table.concat(delta_parts, " ")
    else
        lines[#lines + 1] = "  generated_deltas none"
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("source=%s mode=%s rooms=%d/%d hallways=%d pieces=%d failed=%d layout=%s result=%s", source.mode or "", room_mode, spawned_room_count, room_count, spawned_hallway_count, #pieces, failed_count, layout_result, report.result)
    if file_ok then return spawned_count > 0, detail .. " wrote " .. tostring(write_detail) end
    return spawned_count > 0, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generator_spawnclear(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generator.spawnclear [latest|all] [destroy|hard|quarantine] confirm"
    if #tokens < 1 or tokens[#tokens] ~= "confirm" then return false, usage end
    local scope = "latest"
    local mode = "destroy"
    for index = 1, #tokens - 1 do
        local token = tostring(tokens[index] or ""):lower()
        if token == "latest" or token == "all" then
            scope = token
        elseif GENERATED_ACTOR_PROBE.cleanup_modes[token] then
            mode = token
        else
            return false, usage
        end
    end
    if scope ~= "latest" and scope ~= "all" then return false, "scope must be latest or all" end
    if not GENERATED_ACTOR_PROBE.cleanup_modes[mode] then return false, "mode must be destroy, hard, or quarantine" end

    local target_batch = generated_spawn_cache.latest_batch or 0
    local file_stem = "dungeon_proc_generator_spawnclear"
    local report = {
        command = "world.dungeon.proc.generator.spawnclear",
        confirmed = true,
        scope = scope,
        mode = mode,
        target_batch = scope == "latest" and target_batch or 0,
        cached_entries_before = #generated_spawn_cache.entries,
        before_counts = generated_counts_snapshot(),
        after_counts = {},
        generated_deltas = {},
        cleaned = {},
        kept = {},
        result = "about_to_clear_cached_spawns",
        warning = "targets only actors cached from this Lua session's generator.spawnref/spawnlayout probes; destroy-call acceptance is reported separately from verified inactive state",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generator.spawnclear --",
        string.format("  scope=%s mode=%s target_batch=%d cached=%d", scope, mode, report.target_batch, report.cached_entries_before),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    local result_line_index = 4

    local kept_entries = {}
    local selected_count = 0
    local accepted_count = 0
    local verified_gone_count = 0
    local destroying_count = 0
    local quarantined_count = 0
    local failed_count = 0
    for entry_index, entry in ipairs(generated_spawn_cache.entries) do
        local selected = scope == "all" or entry.batch == target_batch
        if selected then
            selected_count = selected_count + 1
            local valid_before = is_valid(entry.actor)
            local item = {
                cache_index = entry_index,
                batch = entry.batch,
                label = entry.label,
                ref = entry.ref,
                name = entry.name,
                full_name = entry.full_name,
                valid_before = valid_before,
                accepted = false,
                verified_gone = false,
                destroying_after = false,
                quarantined = false,
                method = "",
                before_state = {},
                after_state = {},
                actions = {},
                error = "",
            }
            if valid_before then
                report.result = "about_to_cleanup_" .. tostring(selected_count) .. "_" .. tostring(entry.name or "actor")
                lines[result_line_index] = "  result=" .. report.result
                write_report_files(file_stem .. "_attempt", report, lines)
                local cleanup = GENERATED_ACTOR_PROBE.cleanup_actor(entry.actor, mode)
                item.accepted = cleanup.accepted == true
                item.verified_gone = cleanup.verified_gone == true
                item.destroying_after = cleanup.destroying_after == true
                item.quarantined = cleanup.quarantined == true
                item.method = cleanup.method or ""
                item.before_state = cleanup.before or {}
                item.after_state = cleanup.after or {}
                item.actions = cleanup.actions or {}
                item.error = cleanup.error or ""
                if item.accepted then
                    accepted_count = accepted_count + 1
                    if item.verified_gone then verified_gone_count = verified_gone_count + 1 end
                    if item.destroying_after then destroying_count = destroying_count + 1 end
                    if item.quarantined then quarantined_count = quarantined_count + 1 end
                    lines[#lines + 1] = string.format("  cleanup batch=%d %s ref=%s actor=%s via=%s before=%s after=%s gone=%s destroying=%s", entry.batch or 0, entry.label or "", entry.ref or "", entry.name or "", item.method, item.before_state.text or "", item.after_state.text or "", tostring(item.verified_gone), tostring(item.destroying_after))
                    if not item.verified_gone and not item.destroying_after then
                        kept_entries[#kept_entries + 1] = entry
                    end
                else
                    failed_count = failed_count + 1
                    kept_entries[#kept_entries + 1] = entry
                    lines[#lines + 1] = string.format("  cleanup failed batch=%d actor=%s error=%s", entry.batch or 0, entry.name or "", item.error)
                end
            else
                lines[#lines + 1] = string.format("  stale cached actor batch=%d actor=%s", entry.batch or 0, entry.name or "")
            end
            report.cleaned[#report.cleaned + 1] = item
        else
            kept_entries[#kept_entries + 1] = entry
            report.kept[#report.kept + 1] = { batch = entry.batch, label = entry.label, ref = entry.ref, name = entry.name, full_name = entry.full_name, valid = is_valid(entry.actor) }
        end
    end
    generated_spawn_cache.entries = kept_entries
    report.cached_entries_after = #generated_spawn_cache.entries
    report.after_counts = generated_counts_snapshot()
    local delta_parts = generated_delta_parts(report.before_counts, report.after_counts)
    report.generated_deltas = delta_parts
    if selected_count == 0 then
        report.result = "no_cached_spawns_selected"
    elseif failed_count == 0 and verified_gone_count + destroying_count == selected_count then
        report.result = "cleared_cached_spawns_verified_inactive"
    elseif failed_count == 0 then
        report.result = "cleanup_accepted_but_still_active"
    else
        report.result = "cleared_cached_spawns_partial"
    end
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = string.format("  cleanup_summary selected=%d accepted=%d verified_gone=%d destroying=%d quarantined=%d failed=%d cached_after=%d", selected_count, accepted_count, verified_gone_count, destroying_count, quarantined_count, failed_count, report.cached_entries_after)
    if #delta_parts > 0 then
        lines[#lines + 1] = "  generated_deltas " .. table.concat(delta_parts, " ")
    else
        lines[#lines + 1] = "  generated_deltas none"
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("scope=%s mode=%s selected=%d accepted=%d gone=%d destroying=%d failed=%d cached_after=%d deltas=%d result=%s", scope, mode, selected_count, accepted_count, verified_gone_count, destroying_count, failed_count, report.cached_entries_after, #delta_parts, report.result)
    if file_ok then return failed_count == 0, detail .. " wrote " .. tostring(write_detail) end
    return failed_count == 0, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generator_spawnoptions(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.generator.spawnoptions [cdo|generator_index] [start_option end_option] [step] [dx dy dz] confirm"
    if #tokens < 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    local arg_count = #tokens - 1
    local source_token = tokens[1]
    local source_text = tostring(source_token or ""):lower()
    local generator_index = tonumber(source_token)
    if source_text ~= "cdo" and source_text ~= "default" and not generator_index then return false, "source must be cdo or a generator/model index" end
    generator_index = generator_index and math.floor(generator_index) or 0
    local start_index, end_index, step = 1, 8, 450
    local dx, dy, dz = 300, 0, 0
    if arg_count == 3 then
        start_index = tonumber(tokens[2]) or start_index
        end_index = tonumber(tokens[3]) or end_index
    elseif arg_count == 4 then
        start_index = tonumber(tokens[2]) or start_index
        end_index = tonumber(tokens[3]) or end_index
        step = tonumber(tokens[4]) or step
    elseif arg_count == 7 then
        start_index = tonumber(tokens[2]) or start_index
        end_index = tonumber(tokens[3]) or end_index
        step = tonumber(tokens[4]) or step
        dx = tonumber(tokens[5]) or dx
        dy = tonumber(tokens[6]) or dy
        dz = tonumber(tokens[7]) or dz
    elseif arg_count ~= 1 then
        return false, usage
    end
    start_index = math.floor(start_index)
    end_index = math.floor(end_index)
    if source_text ~= "cdo" and source_text ~= "default" and generator_index < 1 then return false, "generator_index must be >= 1" end
    if start_index < 1 then return false, "start_option must be >= 1" end
    if end_index < start_index then return false, "end_option must be >= start_option" end
    if end_index - start_index + 1 > GENERATED_ACTOR_PROBE.max_option_spawn_span then
        return false, "spawnoptions span capped at " .. tostring(GENERATED_ACTOR_PROBE.max_option_spawn_span) .. " options; run smaller chunks"
    end

    local file_stem = "dungeon_proc_generator_spawnoptions"
    local generator, source, resolve_error = resolve_generator_ref_source(source_token, file_stem)
    if resolve_error then return false, resolve_error end
    if not source then return false, "generator source metadata unavailable" end
    if not generator then return false, "selected generator unavailable" end
    local errors = source.errors or {}
    local auto_construct = source.autowire

    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return false, "local pawn unavailable" end
    local base_loc = nil
    pcall(function() base_loc = feature_actor.actor_location(pawn) end)
    if not base_loc then return false, "local pawn location unavailable" end
    local world, world_route = get_world_for_spawn(pawn)
    if not world then return false, "UWorld unavailable for SpawnActor" end
    if not world.SpawnActor then return false, "UWorld:SpawnActor missing in this UE4SS build" end

    local cdo, cdo_source, cdo_error = resolve_generator_ref_source("cdo", file_stem)
    if cdo_error then return false, cdo_error end
    if not is_valid(cdo) then return false, "generator CDO unavailable for room class ref" end

    local origin = { X = (tonumber(base_loc.X) or 0) + dx, Y = (tonumber(base_loc.Y) or 0) + dy, Z = (tonumber(base_loc.Z) or 0) + dz }
    local cache_batch = begin_generated_spawn_batch("spawnoptions")
    local report = {
        command = "world.dungeon.proc.generator.spawnoptions",
        source = source,
        generator_index = source.index or generator_index,
        count = source.count or 0,
        errors = errors,
        auto_construct = auto_construct,
        confirmed = true,
        cache_batch = cache_batch,
        requested = { start_option = start_index, end_option = end_index, step = step, offset = { x = dx, y = dy, z = dz } },
        origin = vec_text(origin),
        base = { name = safe_name(pawn), class = safety.class_name_of(pawn) or "", full_name = safe_full_name(pawn), location = vec_text(base_loc) },
        generator = { index = source.index or generator_index, name = safe_name(generator), class = safety.class_name_of(generator) or "", full_name = safe_full_name(generator) },
        cdo_source = cdo_source,
        room_class = {},
        options_count = 0,
        rows = {},
        actors = {},
        before_counts = generated_counts_snapshot(),
        after_counts = {},
        generated_deltas = {},
        result = "about_to_read_RoomSpawnSubclass_from_cdo",
        error = "",
        world_route = world_route or "",
        warning = "uses selected generator source GetRoomsOptions for coords/type/rotation and generator CDO RoomSpawnSubclass for spawning; no Init/CreateRoom/teleport lifecycle calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generator.spawnoptions --",
        string.format("  source=%s index=%d %s [%s]", source.mode or "", source.index or 0, report.generator.name, report.generator.class),
        string.format("  requested_options=%d..%d step=%.1f origin=%s", start_index, end_index, step, report.origin),
        "  world_route=" .. tostring(report.world_route),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    local result_line_index = 6
    if auto_construct then lines[#lines + 1] = string.format("  auto_construct=%s cache=%s", tostring(auto_construct.result), tostring(auto_construct.cache_index)) end
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    write_report_files(file_stem .. "_attempt", report, lines)

    local room_ref_spec = GENERATOR_CLASSREF_FIELDS.room
    local class_ok, room_class = read_field(cdo, room_ref_spec.field)
    if not class_ok or not is_valid(room_class) then
        report.result = class_ok and "room_class_invalid" or "room_class_read_failed"
        report.error = class_ok and "invalid RoomSpawnSubclass" or first_error_line(room_class)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. report.error
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files(file_stem, report, lines)
        if write_ok then return false, "room class unavailable wrote " .. tostring(write_detail) end
        return false, "room class unavailable; file write failed: " .. tostring(write_detail)
    end
    report.room_class = { name = safe_name(room_class), class = safety.class_name_of(room_class) or "", full_name = safe_full_name(room_class), value = value_label(room_class) }
    lines[#lines + 1] = string.format("  room_class %s [%s] full=%s", report.room_class.name, report.room_class.class, report.room_class.full_name)

    report.result = "about_to_call_GetRoomsOptions"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files(file_stem .. "_attempt", report, lines)
    local call_ok, options_or_error = pcall(function() return generator:GetRoomsOptions() end)
    if not call_ok then
        report.result = "GetRoomsOptions_failed"
        report.error = first_error_line(options_or_error)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. report.error
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files(file_stem, report, lines)
        if write_ok then return false, "GetRoomsOptions failed wrote " .. tostring(write_detail) end
        return false, "GetRoomsOptions failed; file write failed: " .. tostring(write_detail)
    end
    local options = unwrap(options_or_error)
    local options_count = container_count(options) or 0
    report.options_count = options_count
    lines[#lines + 1] = "  options_count=" .. tostring(options_count)
    if start_index > options_count then
        report.result = "start_option_out_of_range"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files(file_stem, report, lines)
        if write_ok then return false, "start out of range wrote " .. tostring(write_detail) end
        return false, "start out of range; file write failed: " .. tostring(write_detail)
    end

    local actual_end = math.min(end_index, options_count)
    local spawned_count = 0
    local failed_count = 0
    for option_index = start_index, actual_end do
        report.result = "about_to_get_option_" .. tostring(option_index)
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)
        local option = container_item(options, option_index)
        local row = { option_index = option_index, fields = {}, errors = {} }
        report.rows[#report.rows + 1] = row
        if option == nil then
            failed_count = failed_count + 1
            row.errors[#row.errors + 1] = "option_lookup_failed"
            lines[#lines + 1] = string.format("  option[%d] <lookup failed>", option_index)
        else
            for _field_index, field_key in ipairs(GENERATOR_ROOMOPTIONS_SUMMARY_ORDER) do
                local field_spec = GENERATOR_ROOMOPTION_FIELDS[field_key]
                report.result = "about_to_read_option_" .. tostring(option_index) .. "_" .. field_spec.field
                lines[result_line_index] = "  result=" .. report.result
                write_report_files(file_stem .. "_attempt", report, lines)
                local read_ok, value = read_field(option, field_spec.field)
                local field_entry = { key = field_key, field = field_spec.field, ok = read_ok == true, value = "", raw = nil, error = "" }
                if read_ok then
                    value = unwrap(value)
                    field_entry.raw = value
                    field_entry.value = room_option_value_text(value, field_spec.mode)
                else
                    field_entry.error = first_error_line(value)
                    row.errors[#row.errors + 1] = field_key .. ": " .. field_entry.error
                end
                row.fields[field_key] = field_entry
            end
            local coords_entry = row.fields.coords or {}
            local rotation_entry = row.fields.rotation or {}
            local type_entry = row.fields.type or {}
            local height_entry = row.fields.height or {}
            if not coords_entry.ok then
                failed_count = failed_count + 1
                lines[#lines + 1] = string.format("  option[%d] spawn skipped: coords read failed", option_index)
            else
                local coords = coords_entry.raw or {}
                local coord_x, coord_y, coord_z = 0, 0, 0
                pcall(function() coord_x = tonumber(coords.X) or 0 end)
                pcall(function() coord_y = tonumber(coords.Y) or 0 end)
                pcall(function() coord_z = tonumber(coords.Z) or 0 end)
                local height_value = GENERATED_ACTOR_PROBE.number_value(height_entry.raw) or 0
                local loc = { X = origin.X + coord_x * step, Y = origin.Y + coord_y * step, Z = origin.Z + coord_z * step + height_value * step }
                local rot = { Pitch = 0, Yaw = GENERATED_ACTOR_PROBE.rotation_yaw(rotation_entry.raw), Roll = 0 }
                report.result = "about_to_spawn_option_" .. tostring(option_index)
                lines[result_line_index] = "  result=" .. report.result
                write_report_files(file_stem .. "_attempt", report, lines)
                local actor = nil
                local spawn_ok, spawn_error = pcall(function() actor = world:SpawnActor(room_class, loc, rot) end)
                local actor_entry = {
                    option_index = option_index,
                    coords = coords_entry.value or "",
                    rotation = rotation_entry.value or "",
                    type = type_entry.value or "",
                    height = height_entry.value or "",
                    requested_location = vec_text(loc),
                    yaw = rot.Yaw,
                    ok = spawn_ok == true and is_valid(actor),
                    name = "",
                    class = "",
                    full_name = "",
                    location = "",
                    place_ok = false,
                    rotation_ok = false,
                    error = "",
                }
                if actor_entry.ok then
                    spawned_count = spawned_count + 1
                    pcall(function() actor["bRegisterAsRuntimeSpawned"] = true end)
                    pcall(function() feature_actor.force_actor_movable(actor) end)
                    local move_ok, move_error = feature_actor.move_actor(actor, loc)
                    actor_entry.place_ok = move_ok == true
                    actor_entry.rotation_ok = feature_actor.set_actor_rotation(actor, rot) == true
                    actor_entry.name = safe_name(actor)
                    actor_entry.class = safety.class_name_of(actor) or ""
                    actor_entry.full_name = safe_full_name(actor)
                    actor_entry.location = object_location_text(actor)
                    actor_entry.error = move_ok and "" or first_error_line(move_error)
                    remember_generated_spawn_actor(cache_batch, actor, "option_" .. tostring(option_index), "room")
                    lines[#lines + 1] = string.format("  option[%d] type=%s coords=%s rot=%s actor=%s loc=%s place=%s", option_index, actor_entry.type, actor_entry.coords, actor_entry.rotation, actor_entry.name, actor_entry.location, tostring(actor_entry.place_ok))
                else
                    failed_count = failed_count + 1
                    actor_entry.error = spawn_ok and "invalid actor" or first_error_line(spawn_error)
                    lines[#lines + 1] = string.format("  option[%d] spawn failed: %s", option_index, actor_entry.error)
                end
                report.actors[#report.actors + 1] = actor_entry
            end
        end
    end

    report.after_counts = generated_counts_snapshot()
    report.generated_deltas = generated_delta_parts(report.before_counts, report.after_counts)
    report.result = failed_count == 0 and "spawned_options" or "spawned_options_partial"
    lines[result_line_index] = "  result=" .. report.result
    if #report.generated_deltas > 0 then
        lines[#lines + 1] = "  generated_deltas " .. table.concat(report.generated_deltas, " ")
    else
        lines[#lines + 1] = "  generated_deltas none"
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("generator=%s options=%d range=%d..%d spawned=%d failed=%d result=%s", report.generator.name, options_count, start_index, actual_end, spawned_count, failed_count, report.result)
    if write_ok then return spawned_count > 0 and failed_count == 0, detail .. " wrote " .. tostring(write_detail) end
    return spawned_count > 0 and failed_count == 0, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generator_autowire(args_str)
    local index_token, confirm_token = trim(args_str):match("^(%S+)%s*(%S*)")
    if not index_token then return false, "usage: world.dungeon.proc.generator.autowire <model_index> confirm" end
    local index = tonumber(index_token)
    if not index then return false, "model index must be a number" end
    index = math.floor(index)
    if confirm_token ~= "confirm" then return false, "generator autowire requires: world.dungeon.proc.generator.autowire <model_index> confirm" end

    local generators, errors = live_generators()
    if index >= 1 and index <= #generators and is_valid(generators[index]) then
        local generator = generators[index]
        local report = {
            command = "world.dungeon.proc.generator.autowire",
            index = index,
            count = #generators,
            errors = errors,
            result = "existing_generator",
            generator = {
                index = index,
                name = safe_name(generator),
                class = safety.class_name_of(generator) or "",
                full_name = safe_full_name(generator),
            },
            note = "no construction performed because generator[index] already exists",
        }
        local lines = {
            "[RSDWTools] world.dungeon.proc.generator.autowire --",
            string.format("  live DungeonGenerator objects: %d", #generators),
            string.format("  generator[%d] %s [%s]", index, report.generator.name, report.generator.class),
            "  result=" .. report.result,
            "  note: no construction performed because generator already exists",
        }
        for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_generator_autowire", report, lines)
        local detail = string.format("index=%d generator=%s result=%s", index, report.generator.name, report.result)
        if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
        return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    local generator, _resolved_generators, _resolved_errors, auto_construct, resolve_error = ensure_generator_for_probe(index, "dungeon_proc_generator_autowire")
    if resolve_error then return false, resolve_error end
    if not generator then return false, "generator autowire did not return an object" end
    local detail = string.format("model_index=%d generator=%s result=%s", index, safe_name(generator), tostring(auto_construct and auto_construct.result or "autowired"))
    return true, detail .. " wrote dungeon_proc_generator_autowire.*"
end

function M.generator_callone(args_str)
    local index_token, call_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)")
    if not index_token or not call_token then
        return false, "usage: world.dungeon.proc.generator.callone <index> <" .. generator_callone_options() .. "> confirm"
    end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    if confirm_token ~= "confirm" then
        return false, "single generator call probe requires: world.dungeon.proc.generator.callone <index> <" .. generator_callone_options() .. "> confirm"
    end
    local call_key = tostring(call_token or ""):lower()
    if call_key ~= "rooms_options" then return false, "unknown call; choose one of: " .. generator_callone_options() end

    local generator, generators, errors, auto_construct, resolve_error = ensure_generator_for_probe(index, "dungeon_proc_generator_callone")
    if resolve_error then return false, resolve_error end
    if not generator then return false, "selected generator unavailable" end

    local report = {
        command = "world.dungeon.proc.generator.callone",
        index = index,
        count = #generators,
        errors = errors,
        auto_construct = auto_construct,
        confirmed = true,
        call = call_key,
        call_label = "GetRoomsOptions",
        result = "about_to_call_GetRoomsOptions",
        value = "",
        value_type = "",
        error = "",
        warning = "calls BP-implementable UDungeonGenerator:GetRoomsOptions once; reports only returned container count",
        generator = {
            index = index,
            name = safe_name(generator),
            class = safety.class_name_of(generator) or "",
            full_name = safe_full_name(generator),
        },
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generator.callone --",
        string.format("  live DungeonGenerator objects: %d", #generators),
        string.format("  generator[%d] %s [%s]", index, report.generator.name, report.generator.class),
        "  warning: calls UDungeonGenerator:GetRoomsOptions once",
        "  result=" .. report.result,
    }
    if auto_construct then
        lines[#lines + 1] = string.format("  auto_construct=%s cache=%s", tostring(auto_construct.result), tostring(auto_construct.cache_index))
    end
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    write_report_files("dungeon_proc_generator_callone_attempt", report, lines)

    local call_ok, value = pcall(function() return generator:GetRoomsOptions() end)
    report.result = call_ok and "called_GetRoomsOptions" or "GetRoomsOptions_failed"
    lines[5] = "  result=" .. report.result
    if call_ok then
        value = unwrap(value)
        report.value_type = type(value)
        report.value = count_text(value)
        lines[#lines + 1] = string.format("  return type=%s value=%s", report.value_type, report.value)
    else
        report.error = tostring(value)
        lines[#lines + 1] = "  error: " .. first_error_line(value)
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_generator_callone", report, lines)
    local detail = string.format("index=%d generator=%s call=%s result=%s", index, report.generator.name, call_key, report.result)
    if write_ok then return call_ok, detail .. " wrote " .. tostring(write_detail) end
    return call_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generator_roomoption(args_str)
    local generator_token, option_token, field_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s+(%S+)%s*(%S*)")
    if not generator_token or not option_token or not field_token then
        return false, "usage: world.dungeon.proc.generator.roomoption [cdo|generator_index] <option_index> <" .. generator_roomoption_options() .. "> confirm"
    end
    local source_text = tostring(generator_token or ""):lower()
    local generator_index = tonumber(generator_token)
    if source_text ~= "cdo" and source_text ~= "default" and not generator_index then return false, "source must be cdo or a generator/model index" end
    generator_index = generator_index and math.floor(generator_index) or 0
    if source_text ~= "cdo" and source_text ~= "default" and generator_index < 1 then return false, "generator index must be >= 1" end
    local option_index = tonumber(option_token)
    if not option_index then return false, "option index must be a number" end
    option_index = math.floor(option_index)
    if option_index < 1 then return false, "option index must be >= 1" end
    if confirm_token ~= "confirm" then
        return false, "single room-option field probe requires: world.dungeon.proc.generator.roomoption [cdo|generator_index] <option_index> <" .. generator_roomoption_options() .. "> confirm"
    end
    local field_spec, field_key = generator_roomoption_spec(field_token)
    if not field_spec then return false, "unknown field; choose one of: " .. generator_roomoption_options() end
    if field_spec.disabled then return false, tostring(field_spec.disabled) end

    local generator, source, resolve_error = resolve_generator_ref_source(generator_token, "dungeon_proc_generator_roomoption")
    if resolve_error then return false, resolve_error end
    if not source then return false, "generator source metadata unavailable" end
    if not generator then return false, "selected generator unavailable" end
    local errors = source.errors or {}
    local auto_construct = source.autowire

    local report = {
        command = "world.dungeon.proc.generator.roomoption",
        source = source,
        generator_index = source.index or generator_index,
        option_index = option_index,
        count = source.count or 0,
        errors = errors,
        auto_construct = auto_construct,
        confirmed = true,
        field = field_key,
        native_field = field_spec.field,
        mode = field_spec.mode,
        options_count = 0,
        result = "about_to_call_GetRoomsOptions",
        value = "",
        value_type = "",
        error = "",
        warning = "calls GetRoomsOptions, selects one returned FDungeonRoomOptions entry, then reads one whitelisted field",
        generator = {
            index = source.index or generator_index,
            name = safe_name(generator),
            class = safety.class_name_of(generator) or "",
            full_name = safe_full_name(generator),
        },
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generator.roomoption --",
        string.format("  source=%s index=%d %s [%s]", source.mode or "", source.index or 0, report.generator.name, report.generator.class),
        string.format("  option_index=%d field=%s", option_index, field_spec.field),
        "  warning: reads one returned FDungeonRoomOptions field only",
        "  result=" .. report.result,
    }
    if auto_construct then
        lines[#lines + 1] = string.format("  auto_construct=%s cache=%s", tostring(auto_construct.result), tostring(auto_construct.cache_index))
    end
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    local result_line_index = 5
    write_report_files("dungeon_proc_generator_roomoption_attempt", report, lines)

    local call_ok, options_or_error = pcall(function() return generator:GetRoomsOptions() end)
    if not call_ok then
        report.result = "GetRoomsOptions_failed"
        report.error = tostring(options_or_error)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. first_error_line(options_or_error)
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_generator_roomoption", report, lines)
        local detail = string.format("generator=%s option=%d field=%s result=%s", report.generator.name, option_index, field_key, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end
    local options = unwrap(options_or_error)
    local options_count = container_count(options) or 0
    report.options_count = options_count
    lines[#lines + 1] = "  options_count=" .. tostring(options_count)
    if option_index > options_count then
        report.result = "option_index_out_of_range"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_generator_roomoption", report, lines)
        local detail = string.format("generator=%s options=%d option=%d result=%s", report.generator.name, options_count, option_index, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    local option = container_item(options, option_index)
    if option == nil then
        report.result = "option_lookup_failed"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_generator_roomoption", report, lines)
        local detail = string.format("generator=%s option=%d result=%s", report.generator.name, option_index, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    report.result = "about_to_read_" .. field_spec.field
    lines[result_line_index] = "  result=" .. report.result
    write_report_files("dungeon_proc_generator_roomoption_attempt", report, lines)

    local read_ok, value = read_field(option, field_spec.field)
    report.result = read_ok and "read_" .. field_spec.field or "read_failed"
    lines[result_line_index] = "  result=" .. report.result
    if read_ok then
        value = unwrap(value)
        report.value_type = type(value)
        report.value = room_option_value_text(value, field_spec.mode)
        lines[#lines + 1] = string.format("  value type=%s value=%s", report.value_type, report.value)
    else
        report.error = tostring(value)
        lines[#lines + 1] = "  error: " .. first_error_line(value)
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_generator_roomoption", report, lines)
    local detail = string.format("generator=%s options=%d option=%d field=%s result=%s", report.generator.name, options_count, option_index, field_key, report.result)
    if write_ok then return read_ok, detail .. " wrote " .. tostring(write_detail) end
    return read_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.generator_roomoptions_summary(args_str)
    local generator_token, start_token, end_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s+(%S+)%s*(%S*)")
    if not generator_token or not start_token or not end_token then
        return false, "usage: world.dungeon.proc.generator.roomoptions.summary [cdo|generator_index] <start_option> <end_option> confirm"
    end
    local source_text = tostring(generator_token or ""):lower()
    local generator_index = tonumber(generator_token)
    if source_text ~= "cdo" and source_text ~= "default" and not generator_index then return false, "source must be cdo or a generator/model index" end
    generator_index = generator_index and math.floor(generator_index) or 0
    if source_text ~= "cdo" and source_text ~= "default" and generator_index < 1 then return false, "generator index must be >= 1" end
    local start_index = tonumber(start_token)
    if not start_index then return false, "start option must be a number" end
    start_index = math.floor(start_index)
    local end_index = tonumber(end_token)
    if not end_index then return false, "end option must be a number" end
    end_index = math.floor(end_index)
    if start_index < 1 then return false, "start option must be >= 1" end
    if end_index < start_index then return false, "end option must be >= start option" end
    local span = end_index - start_index + 1
    if span > MAX_ROOMOPTIONS_SUMMARY_SPAN then
        return false, "summary span capped at " .. tostring(MAX_ROOMOPTIONS_SUMMARY_SPAN) .. " options; run smaller chunks"
    end
    if confirm_token ~= "confirm" then
        return false, "room-options summary requires: world.dungeon.proc.generator.roomoptions.summary [cdo|generator_index] <start_option> <end_option> confirm"
    end

    local generator, source, resolve_error = resolve_generator_ref_source(generator_token, "dungeon_proc_generator_roomoptions_summary")
    if resolve_error then return false, resolve_error end
    if not source then return false, "generator source metadata unavailable" end
    if not generator then return false, "selected generator unavailable" end
    local errors = source.errors or {}
    local auto_construct = source.autowire
    local file_stem = string.format("dungeon_proc_generator_roomoptions_summary_%02d_%02d", start_index, end_index)

    local report = {
        command = "world.dungeon.proc.generator.roomoptions.summary",
        source = source,
        generator_index = source.index or generator_index,
        start_option = start_index,
        end_option = end_index,
        count = source.count or 0,
        errors = errors,
        auto_construct = auto_construct,
        confirmed = true,
        field_order = GENERATOR_ROOMOPTIONS_SUMMARY_ORDER,
        options_count = 0,
        rows = {},
        current_option = 0,
        current_field = "",
        result = "about_to_call_GetRoomsOptions",
        error = "",
        warning = "calls GetRoomsOptions once, then reads verified non-prefab FDungeonRoomOptions fields for a small option range",
        generator = {
            index = source.index or generator_index,
            name = safe_name(generator),
            class = safety.class_name_of(generator) or "",
            full_name = safe_full_name(generator),
        },
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.generator.roomoptions.summary --",
        string.format("  source=%s index=%d %s [%s]", source.mode or "", source.index or 0, report.generator.name, report.generator.class),
        string.format("  requested_options=%d..%d", start_index, end_index),
        "  fields=" .. table.concat(GENERATOR_ROOMOPTIONS_SUMMARY_ORDER, ","),
        "  warning: reads chunked non-prefab FDungeonRoomOptions fields only",
        "  result=" .. report.result,
    }
    if auto_construct then
        lines[#lines + 1] = string.format("  auto_construct=%s cache=%s", tostring(auto_construct.result), tostring(auto_construct.cache_index))
    end
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    local result_line_index = 6
    write_report_files(file_stem .. "_attempt", report, lines)

    local call_ok, options_or_error = pcall(function() return generator:GetRoomsOptions() end)
    if not call_ok then
        report.result = "GetRoomsOptions_failed"
        report.error = tostring(options_or_error)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. first_error_line(options_or_error)
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files(file_stem, report, lines)
        local detail = string.format("generator=%s result=%s", report.generator.name, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    local options = unwrap(options_or_error)
    local options_count = container_count(options) or 0
    report.options_count = options_count
    lines[#lines + 1] = "  options_count=" .. tostring(options_count)
    if start_index > options_count then
        report.result = "start_option_out_of_range"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files(file_stem, report, lines)
        local detail = string.format("generator=%s options=%d start=%d result=%s", report.generator.name, options_count, start_index, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    local actual_end = math.min(end_index, options_count)
    report.end_option = actual_end
    local any_error = false
    for option_index = start_index, actual_end do
        report.current_option = option_index
        report.current_field = "<option>"
        report.result = "about_to_get_option_" .. tostring(option_index)
        lines[result_line_index] = "  result=" .. report.result
        write_report_files(file_stem .. "_attempt", report, lines)

        local row = { option_index = option_index, values = {}, value_types = {}, errors = {} }
        report.rows[#report.rows + 1] = row
        local option = container_item(options, option_index)
        if option == nil then
            any_error = true
            row.errors[#row.errors + 1] = "option_lookup_failed"
            lines[#lines + 1] = string.format("  option[%d] <lookup failed>", option_index)
        else
            local parts = {}
            for _field_index, field_key in ipairs(GENERATOR_ROOMOPTIONS_SUMMARY_ORDER) do
                local field_spec = GENERATOR_ROOMOPTION_FIELDS[field_key]
                report.current_field = field_key
                report.result = "about_to_read_" .. tostring(option_index) .. "_" .. field_spec.field
                lines[result_line_index] = "  result=" .. report.result
                write_report_files(file_stem .. "_attempt", report, lines)

                local read_ok, value = read_field(option, field_spec.field)
                if read_ok then
                    value = unwrap(value)
                    row.value_types[field_key] = type(value)
                    row.values[field_key] = room_option_value_text(value, field_spec.mode)
                    parts[#parts + 1] = field_key .. "=" .. row.values[field_key]
                else
                    any_error = true
                    local error_text = first_error_line(value)
                    row.errors[#row.errors + 1] = field_key .. ": " .. error_text
                    parts[#parts + 1] = field_key .. "=<read failed>"
                end
            end
            lines[#lines + 1] = string.format("  option[%d] %s", option_index, table.concat(parts, " "))
        end
    end

    report.current_option = 0
    report.current_field = ""
    report.result = any_error and "summary_read_with_errors" or "summary_complete"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("generator=%s options=%d range=%d..%d rows=%d result=%s", report.generator.name, options_count, start_index, actual_end, #report.rows, report.result)
    if write_ok then return not any_error, detail .. " wrote " .. tostring(write_detail) end
    return not any_error, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.manager_construct(args_str)
    local model_token, role_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)")
    if not model_token or not role_token then
        return false, "usage: world.dungeon.proc.manager.construct <model_index> <" .. constructable_manager_options() .. "> confirm"
    end
    local model_index = tonumber(model_token)
    if not model_index then return false, "model index must be a number" end
    model_index = math.floor(model_index)
    if confirm_token ~= "confirm" then
        return false, "UObject construction probe requires: world.dungeon.proc.manager.construct <model_index> <" .. constructable_manager_options() .. "> confirm"
    end
    local spec, role_key = constructable_manager_spec(role_token)
    if not spec then return false, "unknown manager role; choose one of: " .. constructable_manager_options() end
    if not StaticConstructObject then return false, "StaticConstructObject unavailable" end
    if not FName then return false, "FName unavailable" end

    local models, errors = live_models()
    if model_index < 1 or model_index > #models then
        return false, model_index_error(#models)
    end
    local model = models[model_index]
    if not is_valid(model) then return false, "selected model invalid" end

    local object_name = manager_object_name(role_key)
    local report = {
        command = "world.dungeon.proc.manager.construct",
        confirmed = true,
        model_index = model_index,
        role = role_key,
        label = spec.label,
        class_path = spec.class_path,
        object_name = object_name,
        count = #models,
        errors = errors,
        model = {
            index = model_index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
        constructed = {},
        cache_index = 0,
        result = "about_to_resolve_class",
        warning = "constructs one procedural manager UObject with model as Outer; does not write it into ADungeonModel and does not call generation",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.manager.construct --",
        string.format("  model[%d] %s [%s] loc=%s", model_index, report.model.name, report.model.class, report.model.location),
        "  role=" .. role_key .. " label=" .. spec.label,
        "  class=" .. spec.class_path,
        "  object_name=" .. object_name,
        "  warning: constructs manager UObject only; no model injection or generation calls",
        "  result=" .. report.result,
    }
    for error_index = 1, #errors do lines[#lines + 1] = "  model error: " .. tostring(errors[error_index]) end
    local result_line_index = 7
    write_report_files("dungeon_proc_manager_construct_attempt", report, lines)

    local class_obj = player_core.resolve_uclass(spec.class_path)
    if not is_valid(class_obj) then
        report.result = "resolve_class_failed"
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: could not resolve " .. spec.class_path
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_manager_construct", report, lines)
        local detail = string.format("model=%s role=%s result=%s", report.model.name, role_key, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end
    ---@cast class_obj UClass
    report.result = "about_to_StaticConstructObject"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files("dungeon_proc_manager_construct_attempt", report, lines)

    local constructed = nil
    local construct_ok, construct_error = pcall(function()
        constructed = StaticConstructObject(class_obj, model, FName(object_name))
    end)
    if not construct_ok or not is_valid(constructed) then
        report.result = "construct_failed"
        report.error = construct_ok and "StaticConstructObject returned invalid" or tostring(construct_error)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. tostring(report.error)
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_manager_construct", report, lines)
        local detail = string.format("model=%s role=%s result=%s", report.model.name, role_key, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    constructed_manager_cache[#constructed_manager_cache + 1] = {
        object = constructed,
        role = role_key,
        label = spec.label,
        model_key = object_key(model),
    }
    report.cache_index = #constructed_manager_cache
    report.constructed = {
        name = safe_name(constructed),
        class = safety.class_name_of(constructed) or "",
        full_name = safe_full_name(constructed),
    }
    report.result = "constructed_manager"
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = string.format("  constructed[%d] %s [%s] full=%s", report.cache_index, report.constructed.name, report.constructed.class, report.constructed.full_name)
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_manager_construct", report, lines)
    local detail = string.format("model=%s role=%s cache=%d object=%s result=%s", report.model.name, role_key, report.cache_index, report.constructed.name, report.result)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.manager_constructwire(args_str)
    local model_token, role_token, third_token, fourth_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)%s*(%S*)")
    if not model_token or not role_token then
        return false, "usage: world.dungeon.proc.manager.constructwire <model_index> <" .. constructable_manager_options() .. "> [current] confirm"
    end
    local model_index = tonumber(model_token)
    if not model_index then return false, "model index must be a number" end
    model_index = math.floor(model_index)
    local set_current = false
    local confirm_token = third_token
    if third_token == "current" then
        set_current = true
        confirm_token = fourth_token
    end
    if confirm_token ~= "confirm" then
        return false, "construct+wire probe requires: world.dungeon.proc.manager.constructwire <model_index> <" .. constructable_manager_options() .. "> [current] confirm"
    end
    local spec, role_key = constructable_manager_spec(role_token)
    if not spec then return false, "unknown manager role; choose one of: " .. constructable_manager_options() end
    if not StaticConstructObject then return false, "StaticConstructObject unavailable" end
    if not FName then return false, "FName unavailable" end

    local models, errors = live_models()
    if model_index < 1 or model_index > #models then
        return false, model_index_error(#models)
    end
    local model = models[model_index]
    if not is_valid(model) then return false, "selected model invalid" end

    local object_name = manager_object_name(role_key)
    local report = {
        command = "world.dungeon.proc.manager.constructwire",
        confirmed = true,
        model_index = model_index,
        role = role_key,
        label = spec.label,
        class_path = spec.class_path,
        object_name = object_name,
        set_current = set_current,
        count = #models,
        errors = errors,
        model = {
            index = model_index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
        manager = {},
        cache_index = 0,
        result = "about_to_resolve_class",
        writes = {},
        warning = "constructs one manager UObject and immediately writes model/backref fields before a later command can observe cache invalidation",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.manager.constructwire --",
        string.format("  model[%d] %s [%s] loc=%s", model_index, report.model.name, report.model.class, report.model.location),
        "  role=" .. role_key .. " label=" .. spec.label,
        "  class=" .. spec.class_path,
        "  object_name=" .. object_name,
        "  set_current=" .. tostring(set_current),
        "  warning: construct + immediate field writes; no field readback or generation calls",
        "  result=" .. report.result,
        "  writes:",
    }
    for error_index = 1, #errors do lines[#lines + 1] = "  model error: " .. tostring(errors[error_index]) end
    local result_line_index = 8
    write_report_files("dungeon_proc_manager_constructwire_attempt", report, lines)

    local class_obj = player_core.resolve_uclass(spec.class_path)
    if not is_valid(class_obj) then
        report.result = "resolve_class_failed"
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: could not resolve " .. spec.class_path
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_manager_constructwire", report, lines)
        local detail = string.format("model=%s role=%s result=%s", report.model.name, role_key, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end
    ---@cast class_obj UClass
    report.result = "about_to_StaticConstructObject"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files("dungeon_proc_manager_constructwire_attempt", report, lines)

    local manager = nil
    local construct_ok, construct_error = pcall(function()
        manager = StaticConstructObject(class_obj, model, FName(object_name))
    end)
    if not construct_ok or not is_valid(manager) then
        report.result = "construct_failed"
        report.error = construct_ok and "StaticConstructObject returned invalid" or tostring(construct_error)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. tostring(report.error)
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_manager_constructwire", report, lines)
        local detail = string.format("model=%s role=%s result=%s", report.model.name, role_key, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    constructed_manager_cache[#constructed_manager_cache + 1] = {
        object = manager,
        role = role_key,
        label = spec.label,
        model_key = object_key(model),
    }
    report.cache_index = #constructed_manager_cache
    report.manager = {
        cache_index = report.cache_index,
        role = role_key,
        label = spec.label,
        name = safe_name(manager),
        class = safety.class_name_of(manager) or "",
        full_name = safe_full_name(manager),
    }
    lines[#lines + 1] = string.format("  constructed[%d] %s [%s] full=%s", report.cache_index, report.manager.name, report.manager.class, report.manager.full_name)

    local all_ok = true
    report.result = "about_to_write_" .. tostring(spec.model_field)
    lines[result_line_index] = "  result=" .. report.result
    write_report_files("dungeon_proc_manager_constructwire_attempt", report, lines)
    if not write_actor_field(report, lines, model, spec.model_field, manager, report.manager.name) then all_ok = false end

    if spec.backref_field then
        report.result = "about_to_write_" .. tostring(spec.backref_field)
        lines[result_line_index] = "  result=" .. report.result
        write_report_files("dungeon_proc_manager_constructwire_attempt", report, lines)
        if not write_actor_field(report, lines, manager, spec.backref_field, model, report.model.name) then all_ok = false end
    end
    if set_current then
        report.result = "about_to_write_CurrentChainComponent"
        lines[result_line_index] = "  result=" .. report.result
        write_report_files("dungeon_proc_manager_constructwire_attempt", report, lines)
        if not write_actor_field(report, lines, model, "CurrentChainComponent", manager, report.manager.name) then all_ok = false end
    end

    report.result = all_ok and "constructed_wired_manager" or "constructed_wired_manager_partial"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_manager_constructwire", report, lines)
    local detail = string.format("model=%s role=%s cache=%d object=%s result=%s", report.model.name, role_key, report.cache_index, report.manager.name, report.result)
    if write_ok then return all_ok, detail .. " wrote " .. tostring(write_detail) end
    return all_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.manager_constructgraph(args_str)
    local model_token, confirm_token = trim(args_str):match("^(%S+)%s*(%S*)")
    if not model_token then return false, "usage: world.dungeon.proc.manager.constructgraph <model_index> confirm" end
    local model_index = tonumber(model_token)
    if not model_index then return false, "model index must be a number" end
    model_index = math.floor(model_index)
    if confirm_token ~= "confirm" then
        return false, "manager graph staging requires: world.dungeon.proc.manager.constructgraph <model_index> confirm"
    end

    local models, errors = live_models()
    if model_index < 1 or model_index > #models then
        return false, model_index_error(#models)
    end
    local model = models[model_index]
    if not is_valid(model) then return false, "selected model invalid" end

    local report = {
        command = "world.dungeon.proc.manager.constructgraph",
        confirmed = true,
        model_index = model_index,
        roles = MANAGER_GRAPH_ROLES,
        current_role = "",
        errors = errors,
        steps = {},
        before_counts = generated_counts_snapshot(),
        after_counts = {},
        generated_deltas = {},
        result = "prepared",
        warning = "constructs and wires generator/items/doors_native/characters/replication/minimap managers; sets CurrentChainComponent only to generator; no generation calls",
        model = {
            index = model_index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.manager.constructgraph --",
        string.format("  model[%d] %s [%s] loc=%s", model_index, report.model.name, report.model.class, report.model.location),
        "  roles=" .. table.concat(MANAGER_GRAPH_ROLES, ","),
        "  warning: staged manager graph writes only; no generation calls",
        "  result=" .. report.result,
    }
    for error_index = 1, #errors do lines[#lines + 1] = "  model error: " .. tostring(errors[error_index]) end
    local result_line_index = 5
    write_report_files("dungeon_proc_manager_constructgraph_attempt", report, lines)

    local all_ok = true
    for _role_index, role_key in ipairs(MANAGER_GRAPH_ROLES) do
        report.current_role = role_key
        report.result = "about_to_constructwire_" .. role_key
        lines[result_line_index] = "  result=" .. report.result
        write_report_files("dungeon_proc_manager_constructgraph_attempt", report, lines)

        local args = tostring(model_index) .. " " .. role_key .. " confirm"
        if role_key == "generator" then args = tostring(model_index) .. " " .. role_key .. " current confirm" end
        local ok, detail = M.manager_constructwire(args)
        local step = { role = role_key, ok = ok == true, detail = tostring(detail or "") }
        report.steps[#report.steps + 1] = step
        lines[#lines + 1] = string.format("  %s=%s %s", role_key, ok and "ok" or "failed", step.detail)
        if not ok then
            all_ok = false
            break
        end
    end

    report.current_role = ""
    report.after_counts = generated_counts_snapshot()
    report.generated_deltas = generated_delta_parts(report.before_counts, report.after_counts)
    if #report.generated_deltas > 0 then
        lines[#lines + 1] = "  generated_deltas " .. table.concat(report.generated_deltas, " ")
    else
        lines[#lines + 1] = "  generated_deltas none"
    end
    report.result = all_ok and "constructed_manager_graph" or "constructed_manager_graph_partial"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_manager_constructgraph", report, lines)
    local detail = string.format("model=%s steps=%d result=%s", report.model.name, #report.steps, report.result)
    if write_ok then return all_ok, detail .. " wrote " .. tostring(write_detail) end
    return all_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

local function manager_write_probe(args_str, command, file_stem, write_kind)
    local model_index, role_key, cache_token, parse_error = parse_cached_manager_args(args_str, command)
    if parse_error then return false, parse_error end
    local spec = CONSTRUCTABLE_MANAGER_SPECS[role_key]
    if not spec then return false, "unknown manager role; choose one of: " .. constructable_manager_options() end

    local models, errors = live_models()
    if model_index < 1 or model_index > #models then
        return false, model_index_error(#models)
    end
    local model = models[model_index]
    if not is_valid(model) then return false, "selected model invalid" end

    local cache_entry, cache_index, cache_error = cached_manager_for(model, role_key, cache_token)
    if cache_error then return false, cache_error end
    if not cache_entry then return false, "cached manager lookup returned no entry" end
    local manager = cache_entry.object
    if not is_valid(manager) then return false, "cached manager object invalid" end

    local target = nil
    local field_name = nil
    local value = nil
    local value_text = nil
    local target_label = ""
    local warning = ""
    if write_kind == "model" then
        field_name = spec.model_field
        target = model
        value = manager
        value_text = safe_name(manager)
        target_label = "model"
        warning = "writes ADungeonModel." .. tostring(field_name) .. " to a cached constructed manager; does not read the field back"
    elseif write_kind == "backref" then
        field_name = spec.backref_field
        if not field_name then return false, role_key .. " has no known manager-side Model backref field" end
        target = manager
        value = model
        value_text = safe_name(model)
        target_label = "manager"
        warning = "writes manager." .. tostring(field_name) .. " back to the selected ADungeonModel; does not call manager methods"
    elseif write_kind == "current" then
        field_name = "CurrentChainComponent"
        target = model
        value = manager
        value_text = safe_name(manager)
        target_label = "model"
        warning = "writes ADungeonModel.CurrentChainComponent to the cached manager; does not call generation"
    else
        return false, "unknown manager write kind"
    end
    if not field_name or field_name == "" then return false, role_key .. " has no model field configured" end

    local report = {
        command = command,
        confirmed = true,
        model_index = model_index,
        role = role_key,
        label = spec.label,
        cache_token = tostring(cache_token or "latest"),
        cache_index = cache_index,
        count = #models,
        errors = errors,
        write_kind = write_kind,
        target = target_label,
        field = field_name,
        result = "about_to_write_" .. field_name,
        warning = warning,
        model = {
            index = model_index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
        manager = {
            cache_index = cache_index,
            role = role_key,
            label = spec.label,
            name = safe_name(manager),
            class = safety.class_name_of(manager) or "",
            full_name = safe_full_name(manager),
        },
        writes = {},
    }
    local lines = {
        "[RSDWTools] " .. command .. " --",
        string.format("  model[%d] %s [%s] loc=%s", model_index, report.model.name, report.model.class, report.model.location),
        string.format("  manager[%d] role=%s %s [%s] full=%s", cache_index, role_key, report.manager.name, report.manager.class, report.manager.full_name),
        "  warning: " .. warning,
        "  target=" .. target_label .. " field=" .. field_name,
        "  result=" .. report.result,
        "  writes:",
    }
    for error_index = 1, #errors do lines[#lines + 1] = "  model error: " .. tostring(errors[error_index]) end
    local result_line_index = 6
    write_report_files(file_stem .. "_attempt", report, lines)

    local write_ok = write_actor_field(report, lines, target, field_name, value, value_text)
    report.result = write_ok and "wrote_" .. field_name or "write_" .. field_name .. "_failed"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("model=%s role=%s cache=%d field=%s result=%s", report.model.name, role_key, cache_index, field_name, report.result)
    if file_ok then return write_ok, detail .. " wrote " .. tostring(write_detail) end
    return write_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.manager_assign(args_str)
    return manager_write_probe(args_str, "world.dungeon.proc.manager.assign", "dungeon_proc_manager_assign", "model")
end

function M.manager_backref(args_str)
    return manager_write_probe(args_str, "world.dungeon.proc.manager.backref", "dungeon_proc_manager_backref", "backref")
end

function M.manager_current(args_str)
    return manager_write_probe(args_str, "world.dungeon.proc.manager.current", "dungeon_proc_manager_current", "current")
end

function M.spawn_manager_adopt_model(args_str)
    local usage = "usage: world.dungeon.proc.spawnmanager.adopt.model <manager_index> <model_index>"
    local manager_index, model_index, _confirmed, parse_error = parse_manager_model_confirm(args_str, usage)
    if parse_error then return false, parse_error end
    local managers, manager_errors = live_spawn_managers()
    if manager_index < 1 or manager_index > #managers then
        return false, string.format("spawn manager index out of range 1..%d", #managers)
    end
    local models, model_errors = live_models()
    if model_index < 1 or model_index > #models then
        return false, model_index_error(#models)
    end
    local manager = managers[manager_index]
    local model = models[model_index]
    if manager == nil or not is_valid(manager) then return false, "selected spawn manager invalid" end
    if model == nil or not is_valid(model) then return false, "selected model invalid" end

    local manager_full_name = safe_full_name(manager)
    local model_full_name = safe_full_name(model)
    local report = {
        command = "world.dungeon.proc.spawnmanager.adopt.model",
        manager_index = manager_index,
        model_index = model_index,
        manager_count = #managers,
        model_count = #models,
        errors = { spawn_managers = manager_errors, models = model_errors },
        confirmed = true,
        manager = {
            index = manager_index,
            name = name_from_full_name(manager_full_name),
            class = safety.class_name_of(manager) or "",
            full_name = manager_full_name,
        },
        model = {
            index = model_index,
            name = name_from_full_name(model_full_name),
            class = "",
            full_name = model_full_name,
            location = object_location_text(model),
        },
        before = "",
        after = "",
        already_adopted = false,
        route = "",
        result = "prepared",
        warning = "mutates UDungeonSpawnManager.SpawnedDungeons by appending the selected model if missing",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.spawnmanager.adopt.model --",
        string.format("  spawnmanager[%d] %s", manager_index, report.manager.name),
        string.format("  model[%d] %s loc=%s", model_index, report.model.name, report.model.location),
        "  warning: mutates UDungeonSpawnManager.SpawnedDungeons by appending the selected model if missing",
    }
    for error_index = 1, #manager_errors do lines[#lines + 1] = "  spawnmanager error: " .. tostring(manager_errors[error_index]) end
    for error_index = 1, #model_errors do lines[#lines + 1] = "  model error: " .. tostring(model_errors[error_index]) end

    local read_ok, spawned = read_field(manager, "SpawnedDungeons")
    if not read_ok then return false, "SpawnedDungeons read failed: " .. first_error_line(spawned) end
    local before_count = container_count(spawned) or 0
    report.before = count_sample_text(spawned)
    lines[#lines + 1] = "  before=" .. report.before
    report.result = "about_to_adopt_model"
    lines[#lines + 1] = "  result=about_to_adopt_model"
    write_report_files("dungeon_proc_spawnmanager_adopt_model_attempt", report, lines)

    local model_key = object_key(model)
    for index = 1, before_count do
        local item = container_item(spawned, index)
        if item ~= nil and object_key(item) == model_key then
            report.already_adopted = true
            break
        end
    end
    if report.already_adopted then
        report.route = "SpawnedDungeons already contained model"
    else
        local add_ok, add_error = pcall(function() spawned:Add(model) end)
        if add_ok then
            report.route = "SpawnedDungeons:Add(model)"
        else
            local assign_ok, assign_error = pcall(function() spawned[before_count + 1] = model end)
            if assign_ok then
                report.route = "SpawnedDungeons[index]=model"
            else
                report.result = "append_failed"
                report.error = tostring(add_error) .. " / " .. tostring(assign_error)
                lines[#lines] = "  result=" .. report.result
                lines[#lines + 1] = "  error: " .. report.error
                for line_index = 1, #lines do print(lines[line_index]) end
                local file_ok, write_detail = write_report_files("dungeon_proc_spawnmanager_adopt_model", report, lines)
                local detail = string.format("manager=%s model=%s result=%s", report.manager.name, report.model.name, report.result)
                if file_ok then return false, detail .. " wrote " .. tostring(write_detail) end
                return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
            end
        end
    end

    local after_ok, after_spawned = read_field(manager, "SpawnedDungeons")
    report.after = after_ok and count_sample_text(after_spawned) or "<read failed: " .. first_error_line(after_spawned) .. ">"
    report.result = report.already_adopted and "already_adopted_model" or "appended_model"
    lines[#lines] = "  result=" .. report.result
    lines[#lines + 1] = "  route=" .. report.route
    lines[#lines + 1] = "  after=" .. report.after
    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files("dungeon_proc_spawnmanager_adopt_model", report, lines)
    local detail = string.format("manager=%s model=%s result=%s", report.manager.name, report.model.name, report.result)
    if file_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.bridge_model(args_str)
    local manager_token, teleport_token, model_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s+(%S+)%s*(%S*)")
    if not manager_token or not teleport_token or not model_token then
        return false, "usage: world.dungeon.proc.bridge.model <manager_index> <teleport_index> <model_index> confirm"
    end
    local manager_index = tonumber(manager_token)
    local teleport_index = tonumber(teleport_token)
    local model_index = tonumber(model_token)
    if not manager_index then return false, "spawn manager index must be a number" end
    if not teleport_index then return false, "teleport index must be a number" end
    if not model_index then return false, "model index must be a number" end
    manager_index = math.floor(manager_index)
    teleport_index = math.floor(teleport_index)
    model_index = math.floor(model_index)
    if confirm_token ~= "confirm" then
        return false, "unsafe wiring requires: world.dungeon.proc.bridge.model <manager_index> <teleport_index> <model_index> confirm"
    end

    local managers, manager_errors = live_spawn_managers()
    if manager_index < 1 or manager_index > #managers then
        return false, string.format("spawn manager index out of range 1..%d", #managers)
    end
    local teleports, teleport_errors = live_teleports()
    if teleport_index < 1 or teleport_index > #teleports then
        return false, teleport_index_error(#teleports)
    end
    local models, model_errors = live_models()
    if model_index < 1 or model_index > #models then
        return false, model_index_error(#models)
    end
    local manager = managers[manager_index]
    local teleport = teleports[teleport_index]
    local model = models[model_index]
    if manager == nil or not is_valid(manager) then return false, "selected spawn manager invalid" end
    if teleport == nil or not is_valid(teleport) then return false, "selected teleport invalid" end
    if model == nil or not is_valid(model) then return false, "selected model invalid" end

    local manager_full_name = safe_full_name(manager)
    local teleport_full_name = safe_full_name(teleport)
    local model_full_name = safe_full_name(model)
    local report = {
        command = "world.dungeon.proc.bridge.model",
        confirmed = true,
        manager_index = manager_index,
        teleport_index = teleport_index,
        model_index = model_index,
        counts = { spawn_managers = #managers, teleports = #teleports, models = #models },
        errors = { spawn_managers = manager_errors, teleports = teleport_errors, models = model_errors },
        manager = { index = manager_index, name = name_from_full_name(manager_full_name), class = safety.class_name_of(manager) or "", full_name = manager_full_name },
        teleport = { index = teleport_index, name = name_from_full_name(teleport_full_name), class = "", full_name = teleport_full_name, location = object_location_text(teleport) },
        model = { index = model_index, name = name_from_full_name(model_full_name), class = "", full_name = model_full_name, location = object_location_text(model) },
        before = "",
        after = "",
        adopted = false,
        already_adopted = false,
        assigned_interface = false,
        route = "",
        writes = {},
        result = "prepared",
        warning = "mutates SpawnedDungeons and ADungeonTeleport.DungeonInterface; does not call OnDungeonLoaded or OnInteraction",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.bridge.model --",
        string.format("  spawnmanager[%d] %s", manager_index, report.manager.name),
        string.format("  teleport[%d] %s loc=%s", teleport_index, report.teleport.name, report.teleport.location),
        string.format("  model[%d] %s loc=%s", model_index, report.model.name, report.model.location),
        "  warning: mutates SpawnedDungeons and DungeonInterface; no native loaded/interact calls",
    }
    for error_index = 1, #manager_errors do lines[#lines + 1] = "  spawnmanager error: " .. tostring(manager_errors[error_index]) end
    for error_index = 1, #teleport_errors do lines[#lines + 1] = "  teleport error: " .. tostring(teleport_errors[error_index]) end
    for error_index = 1, #model_errors do lines[#lines + 1] = "  model error: " .. tostring(model_errors[error_index]) end

    local read_ok, spawned = read_field(manager, "SpawnedDungeons")
    if not read_ok then return false, "SpawnedDungeons read failed: " .. first_error_line(spawned) end
    local before_count = container_count(spawned) or 0
    report.before = count_sample_text(spawned)
    lines[#lines + 1] = "  before=" .. report.before
    report.result = "about_to_bridge_model"
    lines[#lines + 1] = "  result=about_to_bridge_model"
    local result_line_index = #lines
    write_report_files("dungeon_proc_bridge_model_attempt", report, lines)

    local model_key = object_key(model)
    for index = 1, before_count do
        local item = container_item(spawned, index)
        if item ~= nil and object_key(item) == model_key then
            report.already_adopted = true
            break
        end
    end
    if report.already_adopted then
        report.route = "SpawnedDungeons already contained model"
    else
        local add_ok, add_error = pcall(function() spawned:Add(model) end)
        if add_ok then
            report.route = "SpawnedDungeons:Add(model)"
            report.adopted = true
        else
            local assign_ok, assign_error = pcall(function() spawned[before_count + 1] = model end)
            if assign_ok then
                report.route = "SpawnedDungeons[index]=model"
                report.adopted = true
            else
                report.result = "append_failed"
                report.error = tostring(add_error) .. " / " .. tostring(assign_error)
                lines[result_line_index] = "  result=" .. report.result
                lines[#lines + 1] = "  error: " .. report.error
                for line_index = 1, #lines do print(lines[line_index]) end
                local file_ok, write_detail = write_report_files("dungeon_proc_bridge_model", report, lines)
                local detail = string.format("manager=%s teleport=%s model=%s result=%s", report.manager.name, report.teleport.name, report.model.name, report.result)
                if file_ok then return false, detail .. " wrote " .. tostring(write_detail) end
                return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
            end
        end
    end

    local interface_ok = write_actor_field(report, lines, teleport, "DungeonInterface", model, report.model.name)
    report.assigned_interface = interface_ok == true
    local after_ok, after_spawned = read_field(manager, "SpawnedDungeons")
    report.after = after_ok and count_sample_text(after_spawned) or "<read failed: " .. first_error_line(after_spawned) .. ">"
    report.result = interface_ok and "bridged_model" or "assign_DungeonInterface_failed"
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = "  route=" .. report.route
    lines[#lines + 1] = "  after=" .. report.after
    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files("dungeon_proc_bridge_model", report, lines)
    local detail = string.format("manager=%s teleport=%s model=%s result=%s", report.manager.name, report.teleport.name, report.model.name, report.result)
    if file_ok then return interface_ok, detail .. " wrote " .. tostring(write_detail) end
    return interface_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.spawn_linked(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    if #tokens < 3 or tokens[#tokens] ~= "confirm" then
        return false, "usage: world.dungeon.proc.spawn.linked <manager_index> <teleport_index> [depth] [seed] [biome:0|1|2] confirm"
    end
    local manager_index = tonumber(tokens[1])
    local teleport_index = tonumber(tokens[2])
    if not manager_index then return false, "spawn manager index must be a number" end
    if not teleport_index then return false, "teleport index must be a number" end
    manager_index = math.floor(manager_index)
    teleport_index = math.floor(teleport_index)

    local default_depth, depth_source = runtime_dungeon_depth()
    local depth = tonumber(tokens[3]) or default_depth
    local seed = tonumber(tokens[4])
    if seed then seed = math.floor(seed) end
    local biome = tonumber(tokens[5])
    if biome then
        biome = math.floor(biome)
        if biome < 0 or biome > 2 then return false, "biome must be 0 Default, 1 Summer, or 2 Winter" end
    end

    local managers, manager_errors = live_spawn_managers()
    if manager_index < 1 or manager_index > #managers then
        return false, string.format("spawn manager index out of range 1..%d", #managers)
    end
    local teleports, teleport_errors = live_teleports()
    if teleport_index < 1 or teleport_index > #teleports then
        return false, teleport_index_error(#teleports)
    end
    local manager = managers[manager_index]
    local teleport = teleports[teleport_index]
    if not is_valid(manager) then return false, "selected spawn manager invalid" end
    if not is_valid(teleport) then return false, "selected teleport invalid" end

    local base_loc = nil
    pcall(function() base_loc = feature_actor.actor_location(teleport) end)
    if not base_loc then return false, "selected teleport location unavailable" end
    local spawn_loc = {
        X = tonumber(base_loc.X) or 0,
        Y = tonumber(base_loc.Y) or 0,
        Z = (tonumber(base_loc.Z) or 0) + depth,
    }
    local manager_full_name = safe_full_name(manager)
    local teleport_full_name = safe_full_name(teleport)
    local report = {
        command = "world.dungeon.proc.spawn.linked",
        confirmed = true,
        manager_index = manager_index,
        teleport_index = teleport_index,
        counts = { spawn_managers = #managers, teleports = #teleports },
        errors = { spawn_managers = manager_errors, teleports = teleport_errors },
        manager = { index = manager_index, name = name_from_full_name(manager_full_name), class = safety.class_name_of(manager) or "", full_name = manager_full_name },
        teleport = { index = teleport_index, name = name_from_full_name(teleport_full_name), class = "", full_name = teleport_full_name, location = vec_text(base_loc), dungeon_spawn_location = vec_text(spawn_loc) },
        model = {},
        depth = depth,
        depth_source = depth_source,
        seed = seed,
        biome = biome,
        writes = {},
        adopted = false,
        assigned_interface = false,
        route = "",
        result = "about_to_configure_teleport",
        warning = "deferred-spawns BP_DungeonModel_C with LoadListener assigned before FinishSpawningActor; does not call OnInteraction",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.spawn.linked --",
        string.format("  spawnmanager[%d] %s", manager_index, report.manager.name),
        string.format("  teleport[%d] %s loc=%s", teleport_index, report.teleport.name, report.teleport.location),
        string.format("  model_spawn_location=%s depth=%.1f source=%s", report.teleport.dungeon_spawn_location, depth, depth_source),
        "  warning: linked deferred model spawn; no native interact call",
        "  result=" .. report.result,
        "  writes:",
    }
    local result_line_index = 6
    for error_index = 1, #manager_errors do lines[#lines + 1] = "  spawnmanager error: " .. tostring(manager_errors[error_index]) end
    for error_index = 1, #teleport_errors do lines[#lines + 1] = "  teleport error: " .. tostring(teleport_errors[error_index]) end
    write_report_files("dungeon_proc_spawn_linked_attempt", report, lines)

    write_actor_field(report, lines, teleport, "bIsExitTeleport", false, "false")
    write_actor_field(report, lines, teleport, "bUseTeleportLocation", true, "true")
    write_actor_field(report, lines, teleport, "DungeonSpawnLocation", spawn_loc, vec_text(spawn_loc))
    if seed then
        write_actor_field(report, lines, teleport, "CustomSeed", seed, tostring(seed))
        write_actor_field(report, lines, teleport, "Client_DungeonSeed", seed, tostring(seed))
    end
    if biome then write_actor_field(report, lines, teleport, "BiomeType", biome, tostring(biome)) end

    report.result = "about_to_spawn_deferred_model"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files("dungeon_proc_spawn_linked_attempt", report, lines)

    local spawned_model, spawn_detail = deferred_spawn_model_at(spawn_loc, function(actor)
        write_actor_field(report, lines, actor, "LoadListener", teleport, report.teleport.name)
        if seed then write_actor_field(report, lines, actor, "Client_DungeonSeed", seed, tostring(seed)) end
        report.result = "about_to_finish_linked_model"
        lines[result_line_index] = "  result=" .. report.result
        write_report_files("dungeon_proc_spawn_linked_attempt", report, lines)
    end)
    if not spawned_model then
        report.result = "spawn_failed"
        report.error = tostring(spawn_detail)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. tostring(spawn_detail)
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_spawn_linked", report, lines)
        local detail = string.format("manager=%s teleport=%s result=%s", report.manager.name, report.teleport.name, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    report.model = {
        name = safe_name(spawned_model),
        class = safety.class_name_of(spawned_model) or "",
        full_name = safe_full_name(spawned_model),
        location = object_location_text(spawned_model),
    }
    lines[#lines + 1] = string.format("  model=%s [%s] loc=%s", report.model.name, report.model.class, report.model.location)

    local read_ok, spawned = read_field(manager, "SpawnedDungeons")
    if read_ok then
        local before_count = container_count(spawned) or 0
        local add_ok = pcall(function() spawned:Add(spawned_model) end)
        if add_ok then
            report.route = "SpawnedDungeons:Add(model)"
            report.adopted = true
        else
            local assign_ok = pcall(function() spawned[before_count + 1] = spawned_model end)
            if assign_ok then
                report.route = "SpawnedDungeons[index]=model"
                report.adopted = true
            else
                report.route = "SpawnedDungeons append failed"
            end
        end
    else
        report.route = "SpawnedDungeons read failed: " .. first_error_line(spawned)
    end
    local interface_ok = write_actor_field(report, lines, teleport, "DungeonInterface", spawned_model, report.model.name)
    report.assigned_interface = interface_ok == true
    report.result = (report.adopted and interface_ok) and "spawned_linked_model" or "spawned_with_wiring_errors"
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = "  route=" .. report.route
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_spawn_linked", report, lines)
    local detail = string.format("manager=%s teleport=%s model=%s result=%s", report.manager.name, report.teleport.name, report.model.name, report.result)
    if write_ok then return report.result == "spawned_linked_model", detail .. " wrote " .. tostring(write_detail) end
    return report.result == "spawned_linked_model", detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.spawn_bootstrap(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.spawn.bootstrap [depth] [seed] [biome:0|1|2] [graph|nograph] confirm"
    if #tokens < 1 or tokens[#tokens] ~= "confirm" then return false, usage end

    local numeric_tokens = {}
    local construct_graph = true
    for token_index = 1, #tokens - 1 do
        local token = tostring(tokens[token_index] or "")
        local lower = token:lower()
        if lower == "graph" then
            construct_graph = true
        elseif lower == "nograph" or lower == "no_graph" then
            construct_graph = false
        else
            numeric_tokens[#numeric_tokens + 1] = token
        end
    end
    if #numeric_tokens > 3 then return false, usage end

    local default_depth, depth_source = runtime_dungeon_depth()
    local depth = default_depth
    if numeric_tokens[1] then
        local parsed_depth = tonumber(numeric_tokens[1])
        if not parsed_depth then return false, "depth must be a number" end
        depth = parsed_depth
    end
    local seed = nil
    if numeric_tokens[2] then
        seed = tonumber(numeric_tokens[2])
        if not seed then return false, "seed must be a number" end
        seed = math.floor(seed)
    end
    local biome = nil
    if numeric_tokens[3] then
        biome = tonumber(numeric_tokens[3])
        if not biome then return false, "biome must be 0 Default, 1 Summer, or 2 Winter" end
        biome = math.floor(biome)
        if biome < 0 or biome > 2 then return false, "biome must be 0 Default, 1 Summer, or 2 Winter" end
    end

    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return false, "local pawn unavailable" end
    local base_loc = nil
    pcall(function() base_loc = feature_actor.actor_location(pawn) end)
    if not base_loc then return false, "local pawn location unavailable" end

    local managers, manager_errors = live_spawn_managers()
    if #managers < 1 then return false, "no live DungeonSpawnManager found" end
    local manager_index = 1

    local world, world_route = get_world_for_spawn(pawn)
    if not world then return false, "UWorld unavailable for SpawnActor" end
    if not world.SpawnActor then return false, "UWorld:SpawnActor missing in this UE4SS build" end
    local teleport_class = player_core.resolve_uclass(KNOWN_TELEPORT_CLASS_PATH)
    if not is_valid(teleport_class) then return false, "could not resolve teleport class: " .. KNOWN_TELEPORT_CLASS_PATH end

    local before_teleports = live_teleports()
    local before_teleport_keys = {}
    for index = 1, #before_teleports do before_teleport_keys[object_key(before_teleports[index])] = true end
    local before_models = live_models()
    local before_model_keys = {}
    for index = 1, #before_models do before_model_keys[object_key(before_models[index])] = true end

    local spawn_loc = {
        X = (tonumber(base_loc.X) or 0) + 350,
        Y = tonumber(base_loc.Y) or 0,
        Z = tonumber(base_loc.Z) or 0,
    }
    local report = {
        command = "world.dungeon.proc.spawn.bootstrap",
        confirmed = true,
        depth = depth,
        depth_source = depth_source,
        seed = seed,
        biome = biome,
        construct_graph = construct_graph,
        world_route = world_route or "",
        manager_index = manager_index,
        manager_errors = manager_errors,
        base = { name = safe_name(pawn), class = safety.class_name_of(pawn) or "", full_name = safe_full_name(pawn), location = vec_text(base_loc) },
        teleport_class = KNOWN_TELEPORT_CLASS_PATH,
        teleport_spawn_location = vec_text(spawn_loc),
        teleport = {},
        model = {},
        steps = {},
        before_counts = generated_counts_snapshot(),
        after_counts = {},
        generated_deltas = {},
        result = "about_to_spawn_teleport",
        error = "",
        warning = "fresh-launch helper: spawns BP_DungeonTeleport_C near the player, reuses spawn.linked, and optionally constructs the manager graph; no teleport interaction call",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.spawn.bootstrap --",
        string.format("  base pawn %s [%s] loc=%s", report.base.name, report.base.class, report.base.location),
        string.format("  teleport_spawn=%s class=%s", report.teleport_spawn_location, KNOWN_TELEPORT_CLASS_PATH),
        string.format("  depth=%.1f source=%s seed=%s biome=%s graph=%s", depth, depth_source, tostring(seed or ""), tostring(biome or ""), tostring(construct_graph)),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    local result_line_index = 6
    for error_index = 1, #manager_errors do lines[#lines + 1] = "  spawnmanager error: " .. tostring(manager_errors[error_index]) end
    write_report_files("dungeon_proc_spawn_bootstrap_attempt", report, lines)

    local teleport = nil
    local spawn_ok, spawn_error = pcall(function()
        teleport = world:SpawnActor(teleport_class, spawn_loc, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not spawn_ok or not is_valid(teleport) then
        report.result = spawn_ok and "teleport_spawn_returned_invalid" or "teleport_spawn_failed"
        report.error = spawn_ok and "invalid actor" or tostring(spawn_error)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. first_error_line(report.error)
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_spawn_bootstrap", report, lines)
        if write_ok then return false, report.result .. " wrote " .. tostring(write_detail) end
        return false, report.result .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end
    pcall(function() teleport["bRegisterAsRuntimeSpawned"] = true end)

    local teleports_after, teleport_errors = live_teleports()
    local teleport_index = 0
    local teleport_key = object_key(teleport)
    for index = 1, #teleports_after do
        if object_key(teleports_after[index]) == teleport_key then teleport_index = index; break end
    end
    if teleport_index == 0 then
        for index = 1, #teleports_after do
            if not before_teleport_keys[object_key(teleports_after[index])] then
                teleport_index = index
                teleport = teleports_after[index]
                teleport_key = object_key(teleport)
                break
            end
        end
    end
    report.teleport = {
        index = teleport_index,
        name = safe_name(teleport),
        class = safety.class_name_of(teleport) or "",
        full_name = safe_full_name(teleport),
        location = object_location_text(teleport),
        errors = teleport_errors,
    }
    lines[#lines + 1] = string.format("  teleport[%d] %s [%s] loc=%s", teleport_index, report.teleport.name, report.teleport.class, report.teleport.location)
    if teleport_index < 1 then
        report.result = "teleport_index_not_found"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_spawn_bootstrap", report, lines)
        if write_ok then return false, report.result .. " wrote " .. tostring(write_detail) end
        return false, report.result .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    report.result = "about_to_spawn_linked_model"
    lines[result_line_index] = "  result=" .. report.result
    write_report_files("dungeon_proc_spawn_bootstrap_attempt", report, lines)

    local linked_args = tostring(manager_index) .. " " .. tostring(teleport_index) .. " " .. tostring(depth)
    if seed then linked_args = linked_args .. " " .. tostring(seed) end
    if biome then linked_args = linked_args .. " " .. tostring(biome) end
    linked_args = linked_args .. " confirm"
    local linked_ok, linked_detail = M.spawn_linked(linked_args)
    report.steps[#report.steps + 1] = { name = "spawn.linked", ok = linked_ok == true, args = linked_args, detail = tostring(linked_detail or "") }
    lines[#lines + 1] = string.format("  spawn.linked=%s %s", linked_ok and "ok" or "failed", tostring(linked_detail or ""))

    local models_after, model_errors = live_models()
    local model_index = 0
    local model = nil
    for index = 1, #models_after do
        if not before_model_keys[object_key(models_after[index])] then
            model_index = index
            model = models_after[index]
            break
        end
    end
    if model_index == 0 and #models_after > 0 then
        model_index = #models_after
        model = models_after[model_index]
    end
    report.model = {
        index = model_index,
        name = safe_name(model),
        class = safety.class_name_of(model) or "",
        full_name = safe_full_name(model),
        location = object_location_text(model),
        errors = model_errors,
    }
    lines[#lines + 1] = string.format("  model[%d] %s [%s] loc=%s", model_index, report.model.name, report.model.class, report.model.location)
    if not linked_ok then
        report.result = "linked_model_failed"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_spawn_bootstrap", report, lines)
        local detail = string.format("teleport=%s model=%s result=%s", report.teleport.name, report.model.name, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    local graph_ok = true
    local graph_detail = "skipped"
    if construct_graph then
        report.result = "about_to_construct_manager_graph"
        lines[result_line_index] = "  result=" .. report.result
        write_report_files("dungeon_proc_spawn_bootstrap_attempt", report, lines)
        graph_ok, graph_detail = M.manager_constructgraph(tostring(model_index) .. " confirm")
        report.steps[#report.steps + 1] = { name = "manager.constructgraph", ok = graph_ok == true, args = tostring(model_index) .. " confirm", detail = tostring(graph_detail or "") }
        lines[#lines + 1] = string.format("  manager.constructgraph=%s %s", graph_ok and "ok" or "failed", tostring(graph_detail or ""))
    else
        report.steps[#report.steps + 1] = { name = "manager.constructgraph", ok = true, args = "", detail = "skipped" }
        lines[#lines + 1] = "  manager.constructgraph=skipped"
    end

    report.after_counts = generated_counts_snapshot()
    report.generated_deltas = generated_delta_parts(report.before_counts, report.after_counts)
    if #report.generated_deltas > 0 then
        lines[#lines + 1] = "  generated_deltas " .. table.concat(report.generated_deltas, " ")
    else
        lines[#lines + 1] = "  generated_deltas none"
    end
    report.result = graph_ok and "bootstrapped_linked_model" or "bootstrapped_linked_model_partial"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_spawn_bootstrap", report, lines)
    local detail = string.format("teleport=%s model=%s graph=%s result=%s", report.teleport.name, report.model.name, construct_graph and tostring(graph_ok) or "skipped", report.result)
    if write_ok then return graph_ok, detail .. " wrote " .. tostring(write_detail) end
    return graph_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.entry_surface(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.entry.surface <model_index> [interesting|all|keyword] confirm"
    if #tokens < 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    if #tokens > 3 then return false, usage end
    local model_index = tonumber(tokens[1])
    if not model_index then return false, "model index must be a number" end
    model_index = math.floor(model_index)
    local filter_mode = "interesting"
    if #tokens > 2 then filter_mode = tostring(tokens[2] or "interesting") end

    local models, errors = live_models()
    if model_index < 1 or model_index > #models then
        return false, model_index_error(#models)
    end
    local model = models[model_index]
    if not is_valid(model) then return false, "selected model invalid" end

    local model_key = object_key(model)
    local targets = {
        { role = "model", label = "DungeonModel", cache_index = 0, object = model },
    }
    local cached_roles = {}
    for cache_index = 1, #constructed_manager_cache do
        local cache_entry = constructed_manager_cache[cache_index]
        if cache_entry and cache_entry.model_key == model_key and is_valid(cache_entry.object) then
            targets[#targets + 1] = {
                role = tostring(cache_entry.role or ""),
                label = tostring(cache_entry.label or ""),
                cache_index = cache_index,
                object = cache_entry.object,
            }
            cached_roles[tostring(cache_entry.role or "")] = true
        end
    end
    local missing_roles = {}
    for role_index = 1, #MANAGER_GRAPH_ROLES do
        local role_key = MANAGER_GRAPH_ROLES[role_index]
        if not cached_roles[role_key] then missing_roles[#missing_roles + 1] = role_key end
    end

    local report = {
        command = "world.dungeon.proc.entry.surface",
        confirmed = true,
        model_index = model_index,
        filter = filter_mode,
        count = #models,
        errors = errors,
        missing_cached_roles = missing_roles,
        model = {
            index = model_index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
        current_target = "",
        targets = {},
        result = "prepared",
        warning = "read-only function enumeration using UClass:ForEachFunction; no reflected fields are read and no methods are called",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.entry.surface --",
        string.format("  model[%d] %s [%s] loc=%s", model_index, report.model.name, report.model.class, report.model.location),
        "  filter=" .. tostring(filter_mode),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    local result_line_index = 5
    for error_index = 1, #errors do lines[#lines + 1] = "  model error: " .. tostring(errors[error_index]) end
    if #missing_roles > 0 then lines[#lines + 1] = "  missing_cached_roles=" .. table.concat(missing_roles, ",") end
    write_report_files("dungeon_proc_entry_surface_attempt", report, lines)

    for target_index = 1, #targets do
        local target = targets[target_index]
        report.current_target = target.role
        report.result = "about_to_enumerate_" .. tostring(target.role)
        lines[result_line_index] = "  result=" .. report.result
        write_report_files("dungeon_proc_entry_surface_attempt", report, lines)

        local obj = target.object
        local surface = GENERATED_ACTOR_PROBE.collect_function_surface(obj, filter_mode, 140)
        local entry = {
            role = target.role,
            label = target.label,
            cache_index = target.cache_index,
            name = safe_name(obj),
            class = safety.class_name_of(obj) or "",
            full_name = safe_full_name(obj),
            surface = surface,
        }
        report.targets[#report.targets + 1] = entry
        lines[#lines + 1] = string.format(
            "  target[%d] role=%s cache=%d %s [%s] matched=%d/%d omitted=%d",
            target_index,
            entry.role,
            entry.cache_index,
            entry.name,
            entry.class,
            surface.matched_functions or 0,
            surface.total_functions or 0,
            surface.omitted_functions or 0)
        if surface.error and surface.error ~= "" then lines[#lines + 1] = "    error: " .. surface.error end
        local max_lines = math.min(#surface.methods, 24)
        for method_index = 1, max_lines do
            local method = surface.methods[method_index]
            lines[#lines + 1] = string.format("    %s::%s", method.owner_class or "", method.name or "")
        end
        if #surface.methods > max_lines then
            lines[#lines + 1] = string.format("    ... %d more in JSON", #surface.methods - max_lines)
        end
    end

    report.current_target = ""
    report.result = "enumerated_entry_surface"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_entry_surface", report, lines)
    local detail = string.format("model=%s targets=%d filter=%s", report.model.name, #report.targets, tostring(filter_mode))
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.model_inspect(args_str)
    local args = trim(args_str)
    local index_token = args:match("^(%S+)")
    if not index_token then return false, "usage: world.dungeon.proc.model.inspect <index>" end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)

    local models, errors = live_models()
    if index < 1 or index > #models then
        return false, model_index_error(#models)
    end
    local model = models[index]
    local report = {
        command = "world.dungeon.proc.model.inspect",
        index = index,
        count = #models,
        errors = errors,
        model = {
            index = index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
            fields = {
                note = "reflected model field reads disabled after live crash",
            },
        },
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.model.inspect --",
        string.format("  live DungeonModel actors: %d", #models),
    }
    for error_index = 1, #errors do
        lines[#lines + 1] = "  error: " .. tostring(errors[error_index])
    end
    lines[#lines + 1] = string.format("  [%d] %s [%s] loc=%s", index, report.model.name, report.model.class, report.model.location)
    lines[#lines + 1] = "      note=reflected model field reads disabled after live crash"
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_model_inspect", report, lines)
    local detail = string.format("index=%d model=%s", index, report.model.name)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.model_surface(args_str)
    local args = trim(args_str)
    local index_token = args:match("^(%S+)")
    if not index_token then return false, "usage: world.dungeon.proc.model.surface <index>" end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    local models, errors = live_models()
    if index < 1 or index > #models then
        return false, model_index_error(#models)
    end
    return write_method_surface_report(
        "world.dungeon.proc.model.surface",
        "dungeon_proc_model_surface",
        "DungeonModel",
        models,
        errors,
        index,
        models[index],
        MODEL_METHOD_SURFACE)
end

function M.model_callcheck(args_str)
    local args = trim(args_str)
    local index_token = args:match("^(%S+)")
    if not index_token then return false, "usage: world.dungeon.proc.model.callcheck <index>" end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    local models, errors = live_models()
    if index < 1 or index > #models then
        return false, model_index_error(#models)
    end
    return write_callcheck_report(
        "world.dungeon.proc.model.callcheck",
        "dungeon_proc_model_callcheck",
        "DungeonModel",
        models,
        errors,
        index,
        models[index],
        nil)
end

function M.model_callone(args_str)
    local index_token, action_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)")
    if not index_token or not action_token then
        return false, "usage: world.dungeon.proc.model.callone <index> <" .. model_callone_options() .. "> confirm"
    end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    local action_key = tostring(action_token or ""):lower()
    if action_key == "respawn_resources" and confirm_token ~= "danger" then
        return false, "respawn_resources crashed in a no-generated-resources state; rerun only deliberately as: world.dungeon.proc.model.callone <index> respawn_resources danger"
    end
    if action_key ~= "respawn_resources" and confirm_token ~= "confirm" then
        return false, "single model native/BP call requires: world.dungeon.proc.model.callone <index> <" .. model_callone_options() .. "> confirm"
    end
    local models, errors = live_models()
    if index < 1 or index > #models then
        return false, model_index_error(#models)
    end
    local model = models[index]
    if not is_valid(model) then return false, "selected model invalid" end
    local label, call_fn, warning = model_callone_callable(action_key, model)
    if not label or not call_fn then return false, "unknown call; choose one of: " .. model_callone_options() end

    local report = {
        command = "world.dungeon.proc.model.callone",
        index = index,
        count = #models,
        errors = errors,
        confirmed = true,
        action = action_key,
        call = label,
        result = "about_to_call_" .. label,
        warning = warning,
        value = "",
        value_type = "",
        error = "",
        model = {
            index = index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.model.callone --",
        string.format("  live DungeonModel actors: %d", #models),
        string.format("  model[%d] %s [%s] loc=%s", index, report.model.name, report.model.class, report.model.location),
        "  warning: " .. warning,
        "  action=" .. action_key .. " call=" .. label,
        "  result=" .. report.result,
    }
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    local result_line_index = 6
    write_report_files("dungeon_proc_model_callone_attempt", report, lines)

    local call_ok, call_value = pcall(call_fn)
    report.result = call_ok and "called_" .. label or "call_failed"
    lines[result_line_index] = "  result=" .. report.result
    if call_ok then
        local unwrap_ok, unwrapped = pcall(unwrap, call_value)
        if unwrap_ok then call_value = unwrapped end
        report.value_type = type(call_value)
        report.value = raw_value_text(call_value)
        lines[#lines + 1] = string.format("  return type=%s value=%s", report.value_type, report.value)
    else
        report.error = tostring(call_value)
        lines[#lines + 1] = "  error: " .. first_error_line(call_value)
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_model_callone", report, lines)
    local detail = string.format("index=%d model=%s action=%s result=%s", index, report.model.name, action_key, report.result)
    if write_ok then return call_ok, detail .. " wrote " .. tostring(write_detail) end
    return call_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.model_callscan(args_str)
    local index_token, action_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)")
    if not index_token or not action_token then
        return false, "usage: world.dungeon.proc.model.callscan <index> <" .. model_callone_options() .. "> confirm"
    end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    local action_key = tostring(action_token or ""):lower()
    if action_key == "respawn_resources" and confirm_token ~= "danger" then
        return false, "respawn_resources crashed in a no-generated-resources state; rerun only deliberately as: world.dungeon.proc.model.callscan <index> respawn_resources danger"
    end
    if action_key ~= "respawn_resources" and confirm_token ~= "confirm" then
        return false, "single model lifecycle scan requires: world.dungeon.proc.model.callscan <index> <" .. model_callone_options() .. "> confirm"
    end

    local models, errors = live_models()
    if index < 1 or index > #models then
        return false, model_index_error(#models)
    end
    local model = models[index]
    if not is_valid(model) then return false, "selected model invalid" end
    local label, call_fn, warning = model_callone_callable(action_key, model)
    if not label or not call_fn then return false, "unknown call; choose one of: " .. model_callone_options() end

    local before_counts = generated_counts_snapshot()
    local before_context = model_context_snapshot(model)
    local report = {
        command = "world.dungeon.proc.model.callscan",
        index = index,
        count = #models,
        errors = errors,
        confirmed = true,
        action = action_key,
        call = label,
        result = "about_to_call_" .. label,
        warning = warning .. "; records generated counts and selected DungeonContext fields before/after",
        value = "",
        value_type = "",
        error = "",
        before_counts = before_counts,
        after_counts = {},
        before_context = before_context,
        after_context = {},
        generated_deltas = {},
        model = {
            index = index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.model.callscan --",
        string.format("  live DungeonModel actors: %d", #models),
        string.format("  model[%d] %s [%s] loc=%s", index, report.model.name, report.model.class, report.model.location),
        "  warning: " .. report.warning,
        "  action=" .. action_key .. " call=" .. label,
        "  before_context " .. table.concat(context_snapshot_parts(before_context), " "),
        "  result=" .. report.result,
    }
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    local result_line_index = 7
    write_report_files("dungeon_proc_model_callscan_attempt", report, lines)

    local call_ok, call_value = pcall(call_fn)
    report.result = call_ok and "called_" .. label or "call_failed"
    lines[result_line_index] = "  result=" .. report.result
    if call_ok then
        local unwrap_ok, unwrapped = pcall(unwrap, call_value)
        if unwrap_ok then call_value = unwrapped end
        report.value_type = type(call_value)
        report.value = raw_value_text(call_value)
        lines[#lines + 1] = string.format("  return type=%s value=%s", report.value_type, report.value)
    else
        report.error = tostring(call_value)
        lines[#lines + 1] = "  error: " .. first_error_line(call_value)
    end

    report.after_counts = generated_counts_snapshot()
    report.after_context = model_context_snapshot(model)
    local delta_parts = generated_delta_parts(before_counts, report.after_counts)
    report.generated_deltas = delta_parts
    if #delta_parts > 0 then
        lines[#lines + 1] = "  generated_deltas " .. table.concat(delta_parts, " ")
    else
        lines[#lines + 1] = "  generated_deltas none"
    end
    lines[#lines + 1] = "  after_context " .. table.concat(context_snapshot_parts(report.after_context), " ")

    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_model_callscan", report, lines)
    local detail = string.format("index=%d model=%s action=%s result=%s deltas=%d", index, report.model.name, action_key, report.result, #delta_parts)
    if write_ok then return call_ok, detail .. " wrote " .. tostring(write_detail) end
    return call_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.model_contextone(args_str)
    local index_token, field_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)")
    if not index_token or not field_token then
        return false, "usage: world.dungeon.proc.model.contextone <index> <" .. model_contextone_options() .. "> confirm"
    end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    if confirm_token ~= "confirm" then
        return false, "single DungeonContext field probe requires: world.dungeon.proc.model.contextone <index> <" .. model_contextone_options() .. "> confirm"
    end
    local field_spec, field_key = model_contextone_spec(field_token)
    if not field_spec then return false, "unknown context field; choose one of: " .. model_contextone_options() end
    if field_spec.disabled_reason then
        return false, "context field '" .. field_key .. "' disabled: " .. field_spec.disabled_reason .. "; safe fields are doors,walls,replicated_rooms,replicated_hallways,rooms,hallways,players,center,levels,level_height"
    end

    local models, errors = live_models()
    if index < 1 or index > #models then
        return false, model_index_error(#models)
    end
    local model = models[index]
    if not is_valid(model) then return false, "selected model invalid" end

    local report = {
        command = "world.dungeon.proc.model.contextone",
        index = index,
        count = #models,
        errors = errors,
        confirmed = true,
        field = field_key,
        native_field = field_spec.field,
        mode = field_spec.mode,
        result = "about_to_read_DungeonContext",
        value = "",
        value_type = "",
        error = "",
        warning = "single DungeonContext field read; reads no manager pointers and no other context fields",
        model = {
            index = index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.model.contextone --",
        string.format("  live DungeonModel actors: %d", #models),
        string.format("  model[%d] %s [%s] loc=%s", index, report.model.name, report.model.class, report.model.location),
        "  warning: single DungeonContext field read",
        "  field=" .. field_spec.field,
        "  result=" .. report.result,
    }
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    local result_line_index = 6
    write_report_files("dungeon_proc_model_contextone_attempt", report, lines)

    local context_ok, context = read_field(model, "DungeonContext")
    if not context_ok then
        report.result = "read_DungeonContext_failed"
        report.error = tostring(context)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. first_error_line(context)
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_model_contextone", report, lines)
        local detail = string.format("index=%d model=%s field=%s result=%s", index, report.model.name, field_key, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    report.result = "about_to_read_" .. field_spec.field
    lines[result_line_index] = "  result=" .. report.result
    write_report_files("dungeon_proc_model_contextone_attempt", report, lines)
    local read_ok, value = read_field(context, field_spec.field)
    report.result = read_ok and "read_" .. field_spec.field or "read_failed"
    lines[result_line_index] = "  result=" .. report.result
    if read_ok then
        value = unwrap(value)
        report.value_type = type(value)
        if field_spec.mode == "count" then
            report.value = count_text(value)
        elseif field_spec.mode == "vec" then
            report.value = vec_text(value)
        else
            report.value = value_label(value)
        end
        lines[#lines + 1] = string.format("  value type=%s value=%s", report.value_type, report.value)
    else
        report.error = tostring(value)
        lines[#lines + 1] = "  error: " .. first_error_line(value)
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_model_contextone", report, lines)
    local detail = string.format("index=%d model=%s field=%s result=%s", index, report.model.name, field_key, report.result)
    if write_ok then return read_ok, detail .. " wrote " .. tostring(write_detail) end
    return read_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.model_fieldone(args_str)
    local index_token, field_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)")
    if not index_token or not field_token then
        return false, "usage: world.dungeon.proc.model.fieldone <index> <" .. model_fieldone_options() .. "> confirm"
    end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    if confirm_token ~= "confirm" then
        return false, "single reflected field probe requires: world.dungeon.proc.model.fieldone <index> <" .. model_fieldone_options() .. "> confirm"
    end
    local field_spec, field_key = model_fieldone_spec(field_token)
    if not field_spec then
        local disabled_reason = model_fieldone_disabled_reason(field_key)
        if disabled_reason then return false, disabled_reason end
        return false, "unknown field; choose one of: " .. model_fieldone_options()
    end

    local models, errors = live_models()
    if index < 1 or index > #models then
        return false, model_index_error(#models)
    end
    local model = models[index]
    if not is_valid(model) then return false, "selected model invalid" end

    local report = {
        command = "world.dungeon.proc.model.fieldone",
        index = index,
        count = #models,
        errors = errors,
        confirmed = true,
        field = field_key,
        native_field = field_spec.field,
        result = "about_to_read_" .. field_spec.field,
        value = "",
        value_type = "",
        error = "",
        warning = "single reflected model field read; avoids DungeonContext and reads only one whitelisted field",
        model = {
            index = index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.model.fieldone --",
        string.format("  live DungeonModel actors: %d", #models),
        string.format("  model[%d] %s [%s] loc=%s", index, report.model.name, report.model.class, report.model.location),
        "  warning: single reflected model field read; no DungeonContext read",
        "  field=" .. field_spec.field,
        "  result=" .. report.result,
    }
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    write_report_files("dungeon_proc_model_fieldone_attempt", report, lines)

    local read_ok, value = read_field(model, field_spec.field)
    report.result = read_ok and "read_" .. field_spec.field or "read_failed"
    lines[6] = "  result=" .. report.result
    if read_ok then
        value = unwrap(value)
        report.value_type = type(value)
        report.value = value_label(value)
        lines[#lines + 1] = string.format("  value type=%s value=%s", report.value_type, report.value)
    else
        report.error = tostring(value)
        lines[#lines + 1] = "  error: " .. first_error_line(value)
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_model_fieldone", report, lines)
    local detail = string.format("index=%d model=%s field=%s result=%s", index, report.model.name, field_key, report.result)
    if write_ok then return read_ok, detail .. " wrote " .. tostring(write_detail) end
    return read_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.teleports(args_str)
    local sample_limit = parse_limit(args_str)
    if trim(args_str) == "" then sample_limit = MAX_SAMPLE_LIMIT end
    local teleports, errors = live_teleports()
    local report = {
        command = "world.dungeon.proc.teleports",
        count = #teleports,
        sample_limit = sample_limit,
        errors = errors,
        teleports = {},
        note = "metadata-only; reflected ADungeonTeleport fields are not read",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.teleports --",
        string.format("  live DungeonTeleport actors: %d", #teleports),
        "  note: metadata-only; reflected ADungeonTeleport fields are not read",
    }
    for error_index = 1, #errors do
        lines[#lines + 1] = "  error: " .. tostring(errors[error_index])
    end
    local max_sample = math.min(#teleports, sample_limit)
    for index = 1, max_sample do
        append_teleport_summary(report, lines, index, teleports[index])
    end
    if #teleports > max_sample then
        lines[#lines + 1] = string.format("  ... +%d more; pass a larger limit up to %d", #teleports - max_sample, MAX_SAMPLE_LIMIT)
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_teleports", report, lines)
    if write_ok then return true, "count=" .. tostring(#teleports) .. " wrote " .. tostring(write_detail) end
    return true, "count=" .. tostring(#teleports) .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.teleport_callcheck(args_str)
    local args = trim(args_str)
    local index_token = args:match("^(%S+)")
    if not index_token then return false, "usage: world.dungeon.proc.teleport.callcheck <index>" end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    local teleports, errors = live_teleports()
    if index < 1 or index > #teleports then
        return false, teleport_index_error(#teleports)
    end
    return write_teleport_metadata_callcheck_report(teleports, errors, index, teleports[index])
end

function M.teleport_callone(args_str)
    local index_token, call_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)")
    if not index_token or not call_token then
        return false, "usage: world.dungeon.proc.teleport.callone <index> <" .. teleport_callone_options() .. "> confirm"
    end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    if confirm_token ~= "confirm" then
        return false, "unsafe native-call probe requires: world.dungeon.proc.teleport.callone <index> <" .. teleport_callone_options() .. "> confirm"
    end
    local label, call_fn, formatter = teleport_callone_spec(call_token)
    if not label or not call_fn then return false, "unknown call; choose one of: " .. teleport_callone_options() end

    local teleports, errors = live_teleports()
    if index < 1 or index > #teleports then
        return false, teleport_index_error(#teleports)
    end
    local teleport = teleports[index]
    if teleport == nil or not is_valid(teleport) then return false, "selected teleport invalid" end
    local full_name = safe_full_name(teleport)
    local report = {
        command = "world.dungeon.proc.teleport.callone",
        index = index,
        count = #teleports,
        errors = errors,
        confirmed = true,
        call = tostring(call_token):lower(),
        call_label = label,
        object = {
            index = index,
            label = "DungeonTeleport",
            name = name_from_full_name(full_name),
            class = "",
            full_name = full_name,
        },
        result = "about_to_call_" .. label,
        value_type = "",
        value = "",
        error = "",
        warning = "native-call probe; pcall may not catch engine crashes",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.teleport.callone --",
        string.format("  live DungeonTeleport actors: %d", #teleports),
        string.format("  [%d] %s", index, report.object.name),
        "  warning: native-call probe; pcall may not catch engine crashes",
        "  result=" .. report.result,
    }
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    for line_index = 1, #lines do print(lines[line_index]) end
    write_report_files("dungeon_proc_teleport_callone_attempt", report, lines)

    local call_ok, value = pcall(function() return call_fn(teleport) end)
    report.result = call_ok and "called_" .. label or label .. "_failed"
    lines[#lines - #errors] = "  result=" .. report.result
    if call_ok then
        local unwrap_ok, unwrapped = pcall(unwrap, value)
        if unwrap_ok then value = unwrapped end
        report.value_type = type(value)
        if formatter then
            local format_ok, formatted = pcall(formatter, value)
            report.value = format_ok and tostring(formatted) or raw_value_text(value)
        else
            report.value = raw_value_text(value)
        end
        lines[#lines + 1] = string.format("  value type=%s value=%s", report.value_type, report.value)
    else
        report.error = tostring(value)
        lines[#lines + 1] = "  error: " .. tostring(value)
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_teleport_callone", report, lines)
    local detail = string.format("index=%d object=%s call=%s result=%s", index, report.object.name, report.call, report.result)
    if write_ok then return call_ok, detail .. " wrote " .. tostring(write_detail) end
    return call_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.teleport_interact(args_str)
    local args = trim(args_str)
    local index_token, danger_token = args:match("^(%S+)%s*(%S*)")
    if not index_token then return false, "usage: world.dungeon.proc.teleport.interact <index> danger" end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    if danger_token ~= "danger" then
        return false, "known crash boundary: ADungeonTeleport:OnInteraction(local pawn) crashed after receiving a valid pawn; rerun only deliberately as: world.dungeon.proc.teleport.interact <index> danger"
    end

    local teleports, errors = live_teleports()
    if index < 1 or index > #teleports then
        return false, teleport_index_error(#teleports)
    end
    local teleport = teleports[index]
    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return false, "local pawn unavailable" end

    local method_ok, interaction_method = pcall(function() return teleport.OnInteraction end)
    if not method_ok or interaction_method == nil then
        return false, "OnInteraction UFUNCTION not exposed on selected teleport"
    end

    local report = {
        command = "world.dungeon.proc.teleport.interact",
        index = index,
        count = #teleports,
        errors = errors,
        confirmed = true,
        warning = "calls ADungeonTeleport:OnInteraction(local pawn); this can change game state",
        teleport = {
            index = index,
            name = safe_name(teleport),
            class = safety.class_name_of(teleport) or "",
            full_name = safe_full_name(teleport),
            location = object_location_text(teleport),
        },
        method_value_type = type(interaction_method),
        pawn = {
            name = safe_name(pawn),
            class = safety.class_name_of(pawn) or "",
            full_name = safe_full_name(pawn),
            location = object_location_text(pawn),
        },
        result = "about_to_call_OnInteraction",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.teleport.interact --",
        string.format("  live DungeonTeleport actors: %d", #teleports),
        "  warning: calls ADungeonTeleport:OnInteraction(local pawn); this can change game state",
        string.format("  teleport[%d] %s [%s] loc=%s", index, report.teleport.name, report.teleport.class, report.teleport.location),
        string.format("  pawn %s [%s] loc=%s", report.pawn.name, report.pawn.class, report.pawn.location),
        "  result=about_to_call_OnInteraction",
    }
    write_report_files("dungeon_proc_teleport_interact_attempt", report, lines)

    local call_ok, call_error = pcall(function()
        teleport:OnInteraction(pawn)
    end)
    report.result = call_ok and "called_OnInteraction" or "OnInteraction_failed"
    report.error = call_ok and "" or tostring(call_error)
    lines[#lines] = "  result=" .. report.result
    if not call_ok then lines[#lines + 1] = "  error: " .. tostring(call_error) end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_teleport_interact", report, lines)
    local detail = string.format("index=%d teleport=%s result=%s", index, report.teleport.name, report.result)
    if write_ok then return call_ok, detail .. " wrote " .. tostring(write_detail) end
    return call_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.teleport_configure(args_str)
    local args = trim(args_str)
    local index_token, depth_token, seed_token, biome_token = args:match("^(%S+)%s*(%S*)%s*(%S*)%s*(%S*)")
    if not index_token then
        return false, "usage: world.dungeon.proc.teleport.configure <index> [depth] [seed] [biome:0|1|2]"
    end
    local index = tonumber(index_token)
    if not index then return false, "index must be a number" end
    index = math.floor(index)

    local default_depth, depth_source = runtime_dungeon_depth()
    local depth = tonumber(depth_token)
    if not depth then depth = default_depth end
    local seed = tonumber(seed_token)
    if seed then seed = math.floor(seed) end
    local biome = tonumber(biome_token)
    if biome then
        biome = math.floor(biome)
        if biome < 0 or biome > 2 then return false, "biome must be 0 Default, 1 Summer, or 2 Winter" end
    end

    local teleports, errors = live_teleports()
    if index < 1 or index > #teleports then
        return false, teleport_index_error(#teleports)
    end
    local teleport = teleports[index]
    local base_loc = nil
    pcall(function() base_loc = feature_actor.actor_location(teleport) end)
    if not base_loc then return false, "selected teleport location unavailable" end
    local spawn_loc = {
        X = tonumber(base_loc.X) or 0,
        Y = tonumber(base_loc.Y) or 0,
        Z = (tonumber(base_loc.Z) or 0) + depth,
    }
    local report = {
        command = "world.dungeon.proc.teleport.configure",
        index = index,
        count = #teleports,
        errors = errors,
        depth = depth,
        depth_source = depth_source,
        teleport = {
            index = index,
            name = safe_name(teleport),
            class = safety.class_name_of(teleport) or "",
            full_name = safe_full_name(teleport),
            location = vec_text(base_loc),
            dungeon_spawn_location = vec_text(spawn_loc),
        },
        writes = {},
        note = "sets entrance-style fields; does not create or inspect a DungeonModel",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.teleport.configure --",
        string.format("  live DungeonTeleport actors: %d", #teleports),
        string.format("  [%d] %s [%s] loc=%s", index, report.teleport.name, report.teleport.class, report.teleport.location),
        string.format("  dungeon_spawn_location=%s depth=%.1f source=%s", report.teleport.dungeon_spawn_location, depth, depth_source),
        "  writes:",
    }
    for error_index = 1, #errors do
        lines[#lines + 1] = "  error: " .. tostring(errors[error_index])
    end
    write_actor_field(report, lines, teleport, "bIsExitTeleport", false, "false")
    write_actor_field(report, lines, teleport, "bUseTeleportLocation", true, "true")
    write_actor_field(report, lines, teleport, "DungeonSpawnLocation", spawn_loc, vec_text(spawn_loc))
    if seed then write_actor_field(report, lines, teleport, "CustomSeed", seed, tostring(seed)) end
    if biome then write_actor_field(report, lines, teleport, "BiomeType", biome, tostring(biome)) end

    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_teleport_configure", report, lines)
    local detail = string.format("index=%d teleport=%s spawn=%s", index, report.teleport.name, report.teleport.dungeon_spawn_location)
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.teleport_surface(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.teleport.surface <index> [interesting|all|keyword]"
    if #tokens < 1 or #tokens > 2 then return false, usage end
    local index = tonumber(tokens[1])
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    local function_filter = tokens[2] or "interesting"
    local teleports, errors = live_teleports()
    if index < 1 or index > #teleports then
        return false, teleport_index_error(#teleports)
    end
    return write_method_surface_report(
        "world.dungeon.proc.teleport.surface",
        "dungeon_proc_teleport_surface",
        "DungeonTeleport",
        teleports,
        errors,
        index,
        teleports[index],
        TELEPORT_METHOD_SURFACE,
        function_filter)
end

function M.teleport_bring(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.teleport.bring <index> [distance] [up] confirm"
    if #tokens < 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    if #tokens > 4 then return false, usage end
    local index = tonumber(tokens[1])
    if not index then return false, "index must be a number" end
    index = math.floor(index)
    local distance = 250.0
    if #tokens >= 3 then
        local parsed_distance = tonumber(tokens[2])
        if not parsed_distance then return false, "distance must be a number" end
        distance = parsed_distance
    end
    local up = 0.0
    if #tokens >= 4 then
        local parsed_up = tonumber(tokens[3])
        if not parsed_up then return false, "up must be a number" end
        up = parsed_up
    end

    local teleports, errors = live_teleports()
    if index < 1 or index > #teleports then
        return false, teleport_index_error(#teleports)
    end
    local teleport = teleports[index]
    if teleport == nil or not is_valid(teleport) then return false, "selected teleport invalid" end
    local pawn = feature_actor.get_local_pawn()
    if pawn == nil or not is_valid(pawn) then return false, "local pawn unavailable" end
    local pawn_loc = feature_actor.actor_location(pawn)
    if not pawn_loc then return false, "local pawn location unavailable" end
    local pawn_rot = feature_actor.actor_rotation(pawn)
    local yaw = 0.0
    if pawn_rot then pcall(function() yaw = tonumber(pawn_rot.Yaw) or 0.0 end) end
    local yaw_rad = yaw * math.pi / 180.0
    local dest = {
        X = (tonumber(pawn_loc.X) or 0) + math.cos(yaw_rad) * distance,
        Y = (tonumber(pawn_loc.Y) or 0) + math.sin(yaw_rad) * distance,
        Z = (tonumber(pawn_loc.Z) or 0) + up,
    }
    local report = {
        command = "world.dungeon.proc.teleport.bring",
        confirmed = true,
        index = index,
        count = #teleports,
        errors = errors,
        distance = distance,
        up = up,
        pawn = { name = safe_name(pawn), class = safety.class_name_of(pawn) or "", full_name = safe_full_name(pawn), location = vec_text(pawn_loc), yaw = yaw },
        teleport = { index = index, name = safe_name(teleport), class = safety.class_name_of(teleport) or "", full_name = safe_full_name(teleport), before = object_location_text(teleport), after = "" },
        destination = vec_text(dest),
        rotate_to_face_pawn = true,
        rotation_ok = false,
        result = "about_to_move_teleport",
        error = "",
        warning = "moves selected live DungeonTeleport actor in front of the local pawn to make the player detector test easier; does not call interaction/generation",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.teleport.bring --",
        string.format("  teleport[%d] %s [%s] before=%s", index, report.teleport.name, report.teleport.class, report.teleport.before),
        string.format("  pawn %s [%s] loc=%s yaw=%.1f", report.pawn.name, report.pawn.class, report.pawn.location, yaw),
        string.format("  distance=%.1f up=%.1f destination=%s", distance, up, report.destination),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    local result_line_index = 6
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    write_report_files("dungeon_proc_teleport_bring_attempt", report, lines)

    feature_actor.force_actor_movable(teleport)
    local move_ok, move_error = feature_actor.move_actor(teleport, dest)
    report.teleport.after = object_location_text(teleport)
    local rot_ok = feature_actor.set_actor_rotation(teleport, { Pitch = 0, Yaw = yaw + 180.0, Roll = 0 })
    report.rotation_ok = rot_ok == true
    report.result = move_ok and "moved_teleport" or "move_teleport_failed"
    report.error = move_ok and "" or tostring(move_error or "move failed")
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = "  after=" .. tostring(report.teleport.after)
    lines[#lines + 1] = "  rotation_ok=" .. tostring(report.rotation_ok)
    if not move_ok then lines[#lines + 1] = "  error: " .. first_error_line(report.error) end
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_teleport_bring", report, lines)
    local detail = string.format("teleport=%s result=%s after=%s", report.teleport.name, report.result, report.teleport.after)
    if write_ok then return move_ok, detail .. " wrote " .. tostring(write_detail) end
    return move_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.teleport_interaction_surface(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.teleport.interaction.surface <teleport_index> [interesting|all|keyword] confirm"
    if #tokens < 2 or tokens[#tokens] ~= "confirm" then return false, usage end
    if #tokens > 3 then return false, usage end
    local teleport_index = tonumber(tokens[1])
    if not teleport_index then return false, "teleport index must be a number" end
    teleport_index = math.floor(teleport_index)
    local function_filter = "interesting"
    if #tokens == 3 then function_filter = tostring(tokens[2] or "interesting") end

    local teleports, errors = live_teleports()
    if teleport_index < 1 or teleport_index > #teleports then
        return false, teleport_index_error(#teleports)
    end
    local teleport = teleports[teleport_index]
    if teleport == nil or not is_valid(teleport) then return false, "selected teleport invalid" end

    local report = {
        command = "world.dungeon.proc.teleport.interaction.surface",
        teleport_index = teleport_index,
        count = #teleports,
        errors = errors,
        confirmed = true,
        filter = function_filter,
        teleport = {
            index = teleport_index,
            name = safe_name(teleport),
            class = safety.class_name_of(teleport) or "",
            full_name = safe_full_name(teleport),
            location = object_location_text(teleport),
        },
        component_field = "InteractionComponent",
        component = {},
        detector = { available = false },
        interaction_manager = { available = false },
        methods = {},
        function_surface = nil,
        result = "about_to_read_InteractionComponent",
        error = "",
        warning = "read-only: reads ADungeonTeleport.InteractionComponent, player detector, and player InteractionManager; no interaction/delegate calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.teleport.interaction.surface --",
        string.format("  live DungeonTeleport actors: %d", #teleports),
        string.format("  teleport[%d] %s [%s] loc=%s", teleport_index, report.teleport.name, report.teleport.class, report.teleport.location),
        "  filter=" .. tostring(function_filter),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    local result_line_index = 6
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    write_report_files("dungeon_proc_teleport_interaction_surface_attempt", report, lines)

    local read_ok, component = read_field(teleport, "InteractionComponent")
    if not read_ok then
        report.result = "read_InteractionComponent_failed"
        report.error = tostring(component)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. first_error_line(component)
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_surface", report, lines)
        local detail = string.format("teleport=%s result=%s", report.teleport.name, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    component = unwrap(component)
    if not is_valid(component) then
        report.result = "InteractionComponent_invalid"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_surface", report, lines)
        local detail = string.format("teleport=%s result=%s", report.teleport.name, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    report.component = {
        name = safe_name(component),
        class = safety.class_name_of(component) or "",
        full_name = safe_full_name(component),
    }
    lines[#lines + 1] = string.format("  component %s [%s] full=%s", report.component.name, report.component.class, report.component.full_name)

    local pawn = feature_actor.get_local_pawn()
    if pawn ~= nil and is_valid(pawn) then
        report.detector.pawn = {
            name = safe_name(pawn),
            class = safety.class_name_of(pawn) or "",
            full_name = safe_full_name(pawn),
        }
        local detector = nil
        local ok_field, detector_value = read_field(pawn, "InteractableDetector")
        if ok_field then detector = unwrap(detector_value) end
        if detector ~= nil and is_valid(detector) then
            report.detector.available = true
            report.detector.name = safe_name(detector)
            report.detector.class = safety.class_name_of(detector) or ""
            report.detector.full_name = safe_full_name(detector)
            local ok_world_actor, world_actor = read_field(detector, "CurrentWorldActor")
            if ok_world_actor and is_valid(world_actor) then
                report.detector.current_world_actor = {
                    name = safe_name(world_actor),
                    class = safety.class_name_of(world_actor) or "",
                    full_name = safe_full_name(world_actor),
                    matches_teleport = (world_actor == teleport) or (safe_full_name(world_actor) == report.teleport.full_name),
                }
            end
            local ok_interactable, current_interactable = read_field(detector, "CurrentInteractable")
            if ok_interactable and is_valid(current_interactable) then
                report.detector.current_interactable = {
                    name = safe_name(current_interactable),
                    class = safety.class_name_of(current_interactable) or "",
                    full_name = safe_full_name(current_interactable),
                    matches_component = (current_interactable == component) or (safe_full_name(current_interactable) == report.component.full_name),
                }
            end
            local world_match = false
            if report.detector.current_world_actor then world_match = report.detector.current_world_actor.matches_teleport end
            local interactable_match = false
            if report.detector.current_interactable then interactable_match = report.detector.current_interactable.matches_component end
            lines[#lines + 1] = string.format("  detector %s [%s]", report.detector.name, report.detector.class)
            if report.detector.current_world_actor then
                lines[#lines + 1] = string.format(
                    "    CurrentWorldActor=%s [%s] matches_teleport=%s",
                    report.detector.current_world_actor.name,
                    report.detector.current_world_actor.class,
                    tostring(world_match))
            else
                lines[#lines + 1] = "    CurrentWorldActor=<none>"
            end
            if report.detector.current_interactable then
                lines[#lines + 1] = string.format(
                    "    CurrentInteractable=%s [%s] matches_component=%s",
                    report.detector.current_interactable.name,
                    report.detector.current_interactable.class,
                    tostring(interactable_match))
            else
                lines[#lines + 1] = "    CurrentInteractable=<none>"
            end
        else
            report.detector.error = "local pawn has no valid InteractableDetector"
            lines[#lines + 1] = "  detector unavailable: " .. report.detector.error
        end
    else
        report.detector.error = "no valid local pawn"
        lines[#lines + 1] = "  detector unavailable: " .. report.detector.error
    end

    if pawn ~= nil and is_valid(pawn) then
        local manager = nil
        local ok_manager, manager_value = read_field(pawn, "InteractionManager")
        if ok_manager then manager = unwrap(manager_value) end
        if manager ~= nil and is_valid(manager) then
            report.interaction_manager.available = true
            report.interaction_manager.name = safe_name(manager)
            report.interaction_manager.class = safety.class_name_of(manager) or ""
            report.interaction_manager.full_name = safe_full_name(manager)
            lines[#lines + 1] = string.format("  interaction_manager %s [%s]", report.interaction_manager.name, report.interaction_manager.class)
            lines[#lines + 1] = "    manager_methods:"
            append_method_surface(report, lines, manager, {
                "Server_RequestInteraction",
                "Multicast_AcknowledgeInteractionRequest",
                "Client_DeniedInteraction",
                "GetOwner",
                "GetName",
                "GetClass",
            })
        else
            report.interaction_manager.error = "local pawn has no valid InteractionManager"
            lines[#lines + 1] = "  interaction_manager unavailable: " .. report.interaction_manager.error
        end
    else
        report.interaction_manager.error = "no valid local pawn"
        lines[#lines + 1] = "  interaction_manager unavailable: " .. report.interaction_manager.error
    end

    lines[#lines + 1] = "  component_methods:"
    append_method_surface(report, lines, component, {
        "K2_IsInteractable",
        "K2_ShouldShowInteractionPrompt",
        "K2_ShouldShowSecondaryInteractionPrompt",
        "K2_OnInteraction",
        "K2_OnSecondaryInteraction",
        "K2_OnInteractionStop",
        "K2_OnShowInteractionPrompt",
        "K2_OnHideInteractionPrompt",
        "CanTriggerSecondaryInteraction",
        "ShouldShowSecondaryInteractionPrompt",
        "GetInteractionPrompt",
        "GetSecondaryInteractionPrompt",
        "GetInteractionDistance",
        "GetInteractionType",
        "HasSecondaryInteraction",
        "IsDisabledLocally",
        "GetOwner",
        "GetName",
        "GetClass",
    })

    report.function_surface = GENERATED_ACTOR_PROBE.collect_function_surface(component, function_filter, 180)
    local surface = report.function_surface or { methods = {} }
    local methods = surface.methods or {}
    lines[#lines + 1] = string.format(
        "  function_surface filter=%s matched=%d/%d omitted=%d",
        tostring(function_filter),
        surface.matched_functions or 0,
        surface.total_functions or 0,
        surface.omitted_functions or 0)
    if surface.error and surface.error ~= "" then lines[#lines + 1] = "    error: " .. surface.error end
    local max_lines = math.min(#methods, 32)
    for method_index = 1, max_lines do
        local method = methods[method_index]
        lines[#lines + 1] = string.format("    %s::%s", method.owner_class or "", method.name or "")
    end
    if #methods > max_lines then
        lines[#lines + 1] = string.format("    ... %d more in JSON", #methods - max_lines)
    end

    report.result = "enumerated_interaction_component_surface"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_surface", report, lines)
    local detail = string.format("teleport=%s component=%s filter=%s", report.teleport.name, report.component.name, tostring(function_filter))
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.teleport_interaction_guard(args_str)
    local index_token, mode_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)")
    local usage = "usage: world.dungeon.proc.teleport.interaction.guard <teleport_index> <on|off> confirm"
    if not index_token or not mode_token then return false, usage end
    if confirm_token ~= "confirm" then return false, usage end
    local teleport_index = tonumber(index_token)
    if not teleport_index then return false, "teleport index must be a number" end
    teleport_index = math.floor(teleport_index)
    local guard_on = nil
    if mode_token == "on" or mode_token == "disable" or mode_token == "disabled" or mode_token == "true" or mode_token == "1" then
        guard_on = true
    elseif mode_token == "off" or mode_token == "enable" or mode_token == "enabled" or mode_token == "false" or mode_token == "0" then
        guard_on = false
    else
        return false, "mode must be on or off"
    end

    local teleports, errors = live_teleports()
    if teleport_index < 1 or teleport_index > #teleports then
        return false, teleport_index_error(#teleports)
    end
    local teleport = teleports[teleport_index]
    if teleport == nil or not is_valid(teleport) then return false, "selected teleport invalid" end

    local report = {
        command = "world.dungeon.proc.teleport.interaction.guard",
        teleport_index = teleport_index,
        count = #teleports,
        errors = errors,
        confirmed = true,
        guard_on = guard_on,
        writes = {},
        before = {},
        after = {},
        teleport = {
            index = teleport_index,
            name = safe_name(teleport),
            class = safety.class_name_of(teleport) or "",
            full_name = safe_full_name(teleport),
            location = object_location_text(teleport),
        },
        component = {},
        result = "about_to_read_InteractionComponent",
        error = "",
        warning = "sets InteractionComponent.bDisabledLocally only; avoids interaction/delegate/RPC calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.teleport.interaction.guard --",
        string.format("  teleport[%d] %s [%s] loc=%s", teleport_index, report.teleport.name, report.teleport.class, report.teleport.location),
        "  guard=" .. tostring(guard_on),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
        "  writes:",
    }
    local result_line_index = 5
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    write_report_files("dungeon_proc_teleport_interaction_guard_attempt", report, lines)

    local read_ok, component = read_field(teleport, "InteractionComponent")
    if not read_ok then
        report.result = "read_InteractionComponent_failed"
        report.error = tostring(component)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. first_error_line(component)
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_guard", report, lines)
        local detail = string.format("teleport=%s result=%s", report.teleport.name, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    component = unwrap(component)
    if component == nil or not is_valid(component) then
        report.result = "InteractionComponent_invalid"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local write_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_guard", report, lines)
        local detail = string.format("teleport=%s result=%s", report.teleport.name, report.result)
        if write_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    report.component = {
        name = safe_name(component),
        class = safety.class_name_of(component) or "",
        full_name = safe_full_name(component),
    }
    lines[#lines + 1] = string.format("  component %s [%s]", report.component.name, report.component.class)

    local before_ok, before_value = read_field(component, "bDisabledLocally")
    report.before.bDisabledLocally = before_ok and tostring(unwrap(before_value)) or "<read failed>"
    lines[#lines + 1] = "  before bDisabledLocally=" .. report.before.bDisabledLocally
    write_report_files("dungeon_proc_teleport_interaction_guard_attempt", report, lines)

    write_actor_field(report, lines, component, "bDisabledLocally", guard_on, tostring(guard_on))

    local after_ok, after_value = read_field(component, "bDisabledLocally")
    report.after.bDisabledLocally = after_ok and tostring(unwrap(after_value)) or "<read failed>"
    lines[#lines + 1] = "  after bDisabledLocally=" .. report.after.bDisabledLocally
    report.result = "guard_set"
    lines[result_line_index] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_guard", report, lines)
    local detail = string.format("teleport=%s component=%s guard=%s", report.teleport.name, report.component.name, tostring(guard_on))
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.teleport_interaction_request(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.teleport.interaction.request <teleport_index> [primary|secondary] [press|release] danger"
    if #tokens < 2 or #tokens > 4 or tokens[#tokens] ~= "danger" then return false, usage end
    local teleport_index = tonumber(tokens[1])
    if not teleport_index then return false, "teleport index must be a number" end
    teleport_index = math.floor(teleport_index)
    local mode = "primary"
    local phase = "press"
    if #tokens >= 3 then mode = tostring(tokens[2]) end
    if #tokens >= 4 then phase = tostring(tokens[3]) end
    if mode ~= "primary" and mode ~= "secondary" then return false, "mode must be primary or secondary" end
    if phase ~= "press" and phase ~= "release" then return false, "phase must be press or release" end
    local is_secondary = mode == "secondary"
    local is_release = phase == "release"

    local teleports, errors = live_teleports()
    if teleport_index < 1 or teleport_index > #teleports then
        return false, teleport_index_error(#teleports)
    end
    local teleport = teleports[teleport_index]
    if teleport == nil or not is_valid(teleport) then return false, "selected teleport invalid" end

    local before_counts = generated_counts_snapshot()
    local report = {
        command = "world.dungeon.proc.teleport.interaction.request",
        teleport_index = teleport_index,
        count = #teleports,
        errors = errors,
        danger = true,
        mode = mode,
        phase = phase,
        bIsSecondaryInteraction = is_secondary,
        bIsRelease = is_release,
        before_counts = before_counts,
        after_counts = {},
        generated_deltas = {},
        teleport = {
            index = teleport_index,
            name = safe_name(teleport),
            class = safety.class_name_of(teleport) or "",
            full_name = safe_full_name(teleport),
            location = object_location_text(teleport),
        },
        component = {},
        detector = { available = false },
        interaction_manager = { available = false },
        result = "about_to_resolve_interaction_route",
        error = "",
        warning = "known crash boundary: preflights the player detector route only; Server_RequestInteraction crashed through UE4SS even with a valid target",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.teleport.interaction.request --",
        string.format("  teleport[%d] %s [%s] loc=%s", teleport_index, report.teleport.name, report.teleport.class, report.teleport.location),
        string.format("  mode=%s phase=%s secondary=%s release=%s", mode, phase, tostring(is_secondary), tostring(is_release)),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    local result_line_index = 5
    for error_index = 1, #errors do lines[#lines + 1] = "  error: " .. tostring(errors[error_index]) end
    write_report_files("dungeon_proc_teleport_interaction_request_attempt", report, lines)

    local ok_component, component = read_field(teleport, "InteractionComponent")
    if not ok_component then
        report.result = "read_InteractionComponent_failed"
        report.error = tostring(component)
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. first_error_line(component)
        for line_index = 1, #lines do print(lines[line_index]) end
        local file_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_request", report, lines)
        local detail = string.format("teleport=%s result=%s", report.teleport.name, report.result)
        if file_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end
    component = unwrap(component)
    if component == nil or not is_valid(component) then
        report.result = "InteractionComponent_invalid"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local file_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_request", report, lines)
        local detail = string.format("teleport=%s result=%s", report.teleport.name, report.result)
        if file_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end
    report.component = {
        name = safe_name(component),
        class = safety.class_name_of(component) or "",
        full_name = safe_full_name(component),
    }
    lines[#lines + 1] = string.format("  component %s [%s]", report.component.name, report.component.class)

    local pawn = feature_actor.get_local_pawn()
    if pawn == nil or not is_valid(pawn) then
        report.result = "no_valid_local_pawn"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local file_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_request", report, lines)
        if file_ok then return false, report.result .. " wrote " .. tostring(write_detail) end
        return false, report.result .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end
    report.pawn = { name = safe_name(pawn), class = safety.class_name_of(pawn) or "", full_name = safe_full_name(pawn) }
    lines[#lines + 1] = string.format("  pawn %s [%s]", report.pawn.name, report.pawn.class)

    local detector = nil
    local ok_detector, detector_value = read_field(pawn, "InteractableDetector")
    if ok_detector then detector = unwrap(detector_value) end
    if detector == nil or not is_valid(detector) then
        report.result = "detector_invalid"
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  detector unavailable"
        for line_index = 1, #lines do print(lines[line_index]) end
        local file_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_request", report, lines)
        if file_ok then return false, report.result .. " wrote " .. tostring(write_detail) end
        return false, report.result .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end
    report.detector.available = true
    report.detector.name = safe_name(detector)
    report.detector.class = safety.class_name_of(detector) or ""
    report.detector.full_name = safe_full_name(detector)

    local current_world_actor = nil
    local ok_world_actor, world_actor_value = read_field(detector, "CurrentWorldActor")
    if ok_world_actor then current_world_actor = unwrap(world_actor_value) end
    if current_world_actor ~= nil and is_valid(current_world_actor) then
        report.detector.current_world_actor = {
            name = safe_name(current_world_actor),
            class = safety.class_name_of(current_world_actor) or "",
            full_name = safe_full_name(current_world_actor),
            matches_teleport = (current_world_actor == teleport) or (safe_full_name(current_world_actor) == report.teleport.full_name),
        }
    end
    local current_interactable = nil
    local ok_interactable, interactable_value = read_field(detector, "CurrentInteractable")
    if ok_interactable then current_interactable = unwrap(interactable_value) end
    if current_interactable ~= nil and is_valid(current_interactable) then
        report.detector.current_interactable = {
            name = safe_name(current_interactable),
            class = safety.class_name_of(current_interactable) or "",
            full_name = safe_full_name(current_interactable),
            matches_component = (current_interactable == component) or (safe_full_name(current_interactable) == report.component.full_name),
        }
    end
    local collider = nil
    local ok_collider, collider_value = read_field(detector, "CurrentInteractableCollider")
    if ok_collider then collider = unwrap(collider_value) end
    if collider ~= nil and is_valid(collider) then
        report.detector.current_interactable_collider = {
            name = safe_name(collider),
            class = safety.class_name_of(collider) or "",
            full_name = safe_full_name(collider),
        }
    end
    local matches_component = report.detector.current_interactable and report.detector.current_interactable.matches_component == true
    local matches_teleport = report.detector.current_world_actor and report.detector.current_world_actor.matches_teleport == true
    lines[#lines + 1] = string.format("  detector %s [%s]", report.detector.name, report.detector.class)
    if report.detector.current_world_actor then
        lines[#lines + 1] = string.format("    CurrentWorldActor=%s [%s] matches_teleport=%s", report.detector.current_world_actor.name, report.detector.current_world_actor.class, tostring(matches_teleport))
    else
        lines[#lines + 1] = "    CurrentWorldActor=<none>"
    end
    if report.detector.current_interactable then
        lines[#lines + 1] = string.format("    CurrentInteractable=%s [%s] matches_component=%s", report.detector.current_interactable.name, report.detector.current_interactable.class, tostring(matches_component))
    else
        lines[#lines + 1] = "    CurrentInteractable=<none>"
    end
    if report.detector.current_interactable_collider then
        lines[#lines + 1] = string.format("    CurrentInteractableCollider=%s [%s]", report.detector.current_interactable_collider.name, report.detector.current_interactable_collider.class)
    else
        lines[#lines + 1] = "    CurrentInteractableCollider=<none>"
    end
    if not matches_component then
        report.result = "player_detector_not_targeting_selected_component"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local file_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_request", report, lines)
        if file_ok then return false, report.result .. " wrote " .. tostring(write_detail) end
        return false, report.result .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end
    if collider == nil or not is_valid(collider) then
        report.result = "current_interactable_collider_invalid"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local file_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_request", report, lines)
        if file_ok then return false, report.result .. " wrote " .. tostring(write_detail) end
        return false, report.result .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    local manager = nil
    local ok_manager, manager_value = read_field(pawn, "InteractionManager")
    if ok_manager then manager = unwrap(manager_value) end
    if manager == nil or not is_valid(manager) then
        report.result = "interaction_manager_invalid"
        lines[result_line_index] = "  result=" .. report.result
        for line_index = 1, #lines do print(lines[line_index]) end
        local file_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_request", report, lines)
        if file_ok then return false, report.result .. " wrote " .. tostring(write_detail) end
        return false, report.result .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end
    report.interaction_manager.available = true
    report.interaction_manager.name = safe_name(manager)
    report.interaction_manager.class = safety.class_name_of(manager) or ""
    report.interaction_manager.full_name = safe_full_name(manager)
    lines[#lines + 1] = string.format("  interaction_manager %s [%s]", report.interaction_manager.name, report.interaction_manager.class)

    local method_ok, method_value = pcall(function() return manager.Server_RequestInteraction end)
    report.method_value_type = method_ok and type(method_value) or "error"
    if not method_ok or method_value == nil then
        report.result = "Server_RequestInteraction_not_visible"
        report.error = method_ok and "" or tostring(method_value)
        lines[result_line_index] = "  result=" .. report.result
        if report.error ~= "" then lines[#lines + 1] = "  error: " .. first_error_line(report.error) end
        for line_index = 1, #lines do print(lines[line_index]) end
        local file_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_request", report, lines)
        if file_ok then return false, report.result .. " wrote " .. tostring(write_detail) end
        return false, report.result .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    report.known_crash_boundary = true
    report.result = "Server_RequestInteraction_known_crash_boundary"
    report.error = "disabled after live crash immediately after about_to_call_Server_RequestInteraction attempt marker"
    report.after_counts = before_counts
    report.generated_deltas = {}
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = "  blocked: " .. report.error
    lines[#lines + 1] = "  generated_deltas none (not called)"
    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files("dungeon_proc_teleport_interaction_request", report, lines)
    local detail = string.format("teleport=%s mode=%s phase=%s result=%s", report.teleport.name, mode, phase, report.result)
    if file_ok then return false, detail .. " wrote " .. tostring(write_detail) end
    return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.post_interact(args_str)
    local usage = "usage: world.dungeon.proc.postinteract <teleport_index> <model_index> confirm"
    local teleport_index, model_index, _confirmed, parse_error = parse_model_teleport_confirm(args_str, usage)
    if parse_error then return false, parse_error end
    local teleport, model, teleports, models, teleport_errors, model_errors, resolve_error = resolve_model_and_teleport(teleport_index, model_index)
    if resolve_error then return false, resolve_error end
    if teleport == nil or not is_valid(teleport) then return false, "selected teleport invalid" end
    if model == nil or not is_valid(model) then return false, "selected model invalid" end

    local context_snapshot = model_context_snapshot(model)
    local counts = generated_counts_snapshot()
    local report = {
        command = "world.dungeon.proc.postinteract",
        confirmed = true,
        teleport_index = teleport_index,
        model_index = model_index,
        teleport_count = #teleports,
        model_count = #models,
        errors = { teleports = teleport_errors, models = model_errors },
        generated_counts = counts,
        context = context_snapshot,
        detector = { available = false },
        teleport = {
            index = teleport_index,
            name = safe_name(teleport),
            class = safety.class_name_of(teleport) or "",
            full_name = safe_full_name(teleport),
            location = object_location_text(teleport),
        },
        model = {
            index = model_index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
        result = "post_interact_snapshot",
        warning = "read-only snapshot after using the real in-game interact key; no interaction/generation calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.postinteract --",
        string.format("  teleport[%d] %s [%s] loc=%s", teleport_index, report.teleport.name, report.teleport.class, report.teleport.location),
        string.format("  model[%d] %s [%s] loc=%s", model_index, report.model.name, report.model.class, report.model.location),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    for error_index = 1, #teleport_errors do lines[#lines + 1] = "  teleport error: " .. tostring(teleport_errors[error_index]) end
    for error_index = 1, #model_errors do lines[#lines + 1] = "  model error: " .. tostring(model_errors[error_index]) end

    local generated_parts = {}
    for _spec_index, spec in ipairs(GENERATED_OBJECT_SPECS) do
        local entry = counts[spec.key] or { live = 0 }
        if (entry.live or 0) > 0 then generated_parts[#generated_parts + 1] = string.format("%s=%d", spec.key, entry.live or 0) end
    end
    if #generated_parts > 0 then
        lines[#lines + 1] = "  generated_live " .. table.concat(generated_parts, " ")
    else
        lines[#lines + 1] = "  generated_live none"
    end
    lines[#lines + 1] = "  context " .. table.concat(context_snapshot_parts(context_snapshot), " ")

    local pawn = feature_actor.get_local_pawn()
    if pawn ~= nil and is_valid(pawn) then
        report.pawn = { name = safe_name(pawn), class = safety.class_name_of(pawn) or "", full_name = safe_full_name(pawn), location = object_location_text(pawn) }
        local detector = nil
        local ok_detector, detector_value = read_field(pawn, "InteractableDetector")
        if ok_detector then detector = unwrap(detector_value) end
        if detector ~= nil and is_valid(detector) then
            report.detector.available = true
            report.detector.name = safe_name(detector)
            report.detector.class = safety.class_name_of(detector) or ""
            report.detector.full_name = safe_full_name(detector)
            local ok_world_actor, world_actor = read_field(detector, "CurrentWorldActor")
            if ok_world_actor and world_actor ~= nil and is_valid(world_actor) then
                report.detector.current_world_actor = {
                    name = safe_name(world_actor),
                    class = safety.class_name_of(world_actor) or "",
                    full_name = safe_full_name(world_actor),
                    matches_teleport = (world_actor == teleport) or (safe_full_name(world_actor) == report.teleport.full_name),
                }
            end
            local ok_interactable, interactable = read_field(detector, "CurrentInteractable")
            if ok_interactable and interactable ~= nil and is_valid(interactable) then
                report.detector.current_interactable = {
                    name = safe_name(interactable),
                    class = safety.class_name_of(interactable) or "",
                    full_name = safe_full_name(interactable),
                }
            end
            local ok_collider, collider = read_field(detector, "CurrentInteractableCollider")
            if ok_collider and collider ~= nil and is_valid(collider) then
                report.detector.current_interactable_collider = {
                    name = safe_name(collider),
                    class = safety.class_name_of(collider) or "",
                    full_name = safe_full_name(collider),
                }
            end
            lines[#lines + 1] = string.format("  detector %s [%s]", report.detector.name, report.detector.class)
            if report.detector.current_world_actor then
                lines[#lines + 1] = string.format("    CurrentWorldActor=%s [%s] matches_teleport=%s", report.detector.current_world_actor.name, report.detector.current_world_actor.class, tostring(report.detector.current_world_actor.matches_teleport))
            else
                lines[#lines + 1] = "    CurrentWorldActor=<none>"
            end
            if report.detector.current_interactable then
                lines[#lines + 1] = string.format("    CurrentInteractable=%s [%s]", report.detector.current_interactable.name, report.detector.current_interactable.class)
            else
                lines[#lines + 1] = "    CurrentInteractable=<none>"
            end
            if report.detector.current_interactable_collider then
                lines[#lines + 1] = string.format("    CurrentInteractableCollider=%s [%s]", report.detector.current_interactable_collider.name, report.detector.current_interactable_collider.class)
            else
                lines[#lines + 1] = "    CurrentInteractableCollider=<none>"
            end
        else
            report.detector.error = "local pawn has no valid InteractableDetector"
            lines[#lines + 1] = "  detector unavailable: " .. report.detector.error
        end
    else
        report.detector.error = "no valid local pawn"
        lines[#lines + 1] = "  detector unavailable: " .. report.detector.error
    end

    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_postinteract", report, lines)
    local detail = string.format("teleport=%s model=%s generated=%d context_ok=%s", report.teleport.name, report.model.name, #generated_parts, tostring(context_snapshot.ok == true))
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.teleport_assign_model(args_str)
    local usage = "usage: world.dungeon.proc.teleport.assign.model <teleport_index> <model_index>"
    local teleport_index, model_index, _confirmed, parse_error = parse_model_teleport_confirm(args_str, usage)
    if parse_error then return false, parse_error end
    local teleport, model, teleports, models, teleport_errors, model_errors, resolve_error = resolve_model_and_teleport(teleport_index, model_index)
    if resolve_error then return false, resolve_error end
    if teleport == nil then return false, "selected teleport unavailable" end
    if model == nil then return false, "selected model unavailable" end
    if not is_valid(teleport) then return false, "selected teleport invalid" end
    if not is_valid(model) then return false, "selected model invalid" end
    local report, lines = model_teleport_report("world.dungeon.proc.teleport.assign.model", teleport_index, model_index, teleports, models, teleport_errors, model_errors, teleport, model)
    report.warning = "writes ADungeonTeleport.DungeonInterface to the selected ADungeonModel; this is experimental runtime wiring"
    report.result = "about_to_write_DungeonInterface"
    lines[#lines + 1] = "  warning: writes ADungeonTeleport.DungeonInterface to selected ADungeonModel"
    lines[#lines + 1] = "  writes:"
    write_report_files("dungeon_proc_teleport_assign_model_attempt", report, lines)
    local write_ok = write_actor_field(report, lines, teleport, "DungeonInterface", model, report.model.name)
    report.result = write_ok and "assigned_DungeonInterface" or "assign_DungeonInterface_failed"
    lines[#lines + 1] = "  result=" .. report.result
    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files("dungeon_proc_teleport_assign_model", report, lines)
    local detail = string.format("teleport=%s model=%s result=%s", report.teleport.name, report.model.name, report.result)
    if file_ok then return write_ok, detail .. " wrote " .. tostring(write_detail) end
    return write_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.teleport_notify_model(args_str)
    local usage = "usage: world.dungeon.proc.teleport.notify.model <teleport_index> <model_index> danger"
    local teleport_token, model_token, danger_token = trim(args_str):match("^(%S+)%s+(%S+)%s*(%S*)")
    if not teleport_token or not model_token then return false, usage end
    local teleport_index = tonumber(teleport_token)
    local model_index = tonumber(model_token)
    if not teleport_index then return false, "teleport index must be a number" end
    if not model_index then return false, "model index must be a number" end
    if danger_token ~= "danger" then
        return false, "known crash boundary: OnDungeonLoaded takes TScriptInterface<IDungeonInterface> and crashed through UE4SS when passed a model UObject; rerun only deliberately as: " .. usage
    end
    teleport_index = math.floor(teleport_index)
    model_index = math.floor(model_index)
    local teleport, model, teleports, models, teleport_errors, model_errors, resolve_error = resolve_model_and_teleport(teleport_index, model_index)
    if resolve_error then return false, resolve_error end
    if teleport == nil then return false, "selected teleport unavailable" end
    if model == nil then return false, "selected model unavailable" end
    if not is_valid(teleport) then return false, "selected teleport invalid" end
    if not is_valid(model) then return false, "selected model invalid" end
    local teleport_obj = teleport
    local model_obj = model
    local method_ok, method_value = pcall(function() return teleport_obj.OnDungeonLoaded end)
    if not method_ok or method_value == nil then return false, "OnDungeonLoaded UFUNCTION not visible on selected teleport" end
    local report, lines = model_teleport_report("world.dungeon.proc.teleport.notify.model", teleport_index, model_index, teleports, models, teleport_errors, model_errors, teleport, model)
    report.warning = "calls ADungeonTeleport:OnDungeonLoaded(selected ADungeonModel); this passes a UObject where native expects TScriptInterface<IDungeonInterface>"
    report.method_value_type = type(method_value)
    report.result = "about_to_call_OnDungeonLoaded"
    lines[#lines + 1] = "  warning: calls ADungeonTeleport:OnDungeonLoaded(selected ADungeonModel)"
    lines[#lines + 1] = "  result=about_to_call_OnDungeonLoaded"
    write_report_files("dungeon_proc_teleport_notify_model_attempt", report, lines)
    local call_ok, call_error = pcall(function()
        teleport_obj:OnDungeonLoaded(model_obj)
    end)
    report.result = call_ok and "called_OnDungeonLoaded" or "OnDungeonLoaded_failed"
    report.error = call_ok and "" or tostring(call_error)
    lines[#lines] = "  result=" .. report.result
    if not call_ok then lines[#lines + 1] = "  error: " .. tostring(call_error) end
    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files("dungeon_proc_teleport_notify_model", report, lines)
    local detail = string.format("teleport=%s model=%s result=%s", report.teleport.name, report.model.name, report.result)
    if file_ok then return call_ok, detail .. " wrote " .. tostring(write_detail) end
    return call_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.teleport_callscan(args_str)
    local teleport_token, model_token, action_token, confirm_token = trim(args_str):match("^(%S+)%s+(%S+)%s+(%S+)%s*(%S*)")
    if not teleport_token or not model_token or not action_token then
        return false, "usage: world.dungeon.proc.teleport.callscan <teleport_index> <model_index> <" .. teleport_callscan_options() .. "> danger"
    end
    local teleport_index = tonumber(teleport_token)
    local model_index = tonumber(model_token)
    if not teleport_index then return false, "teleport index must be a number" end
    if not model_index then return false, "model index must be a number" end
    teleport_index = math.floor(teleport_index)
    model_index = math.floor(model_index)
    local action_key = tostring(action_token or ""):lower()
    if action_key == "notify" then action_key = "notify_model" end
    if action_key ~= "notify_model" and action_key ~= "interact" then
        return false, "unknown teleport callscan action; choose one of: " .. teleport_callscan_options()
    end
    if action_key == "notify_model" and confirm_token ~= "danger" then
        return false, "known crash boundary: notify_model calls OnDungeonLoaded(TScriptInterface<IDungeonInterface>) and crashed through UE4SS; use world.dungeon.proc.manual.spawnunit next, or rerun only deliberately as: world.dungeon.proc.teleport.callscan <teleport_index> <model_index> notify_model danger"
    end
    if action_key == "interact" and confirm_token ~= "danger" then
        return false, "known crash boundary: interact calls ADungeonTeleport:OnInteraction(local pawn) and crashed inside native teleport flow; rerun only deliberately as: world.dungeon.proc.teleport.callscan <teleport_index> <model_index> interact danger"
    end

    local teleport, model, teleports, models, teleport_errors, model_errors, resolve_error = resolve_model_and_teleport(teleport_index, model_index)
    if resolve_error then return false, resolve_error end
    if teleport == nil then return false, "selected teleport unavailable" end
    if model == nil then return false, "selected model unavailable" end
    if not is_valid(teleport) then return false, "selected teleport invalid" end
    if not is_valid(model) then return false, "selected model invalid" end

    local call_label = ""
    local call_fn = nil
    local method_value_type = ""
    local pawn_report = nil
    if action_key == "notify_model" then
        local method_ok, method_value = pcall(function() return teleport.OnDungeonLoaded end)
        if not method_ok or method_value == nil then return false, "OnDungeonLoaded UFUNCTION not visible on selected teleport" end
        method_value_type = type(method_value)
        call_label = "OnDungeonLoaded"
        call_fn = function() return teleport:OnDungeonLoaded(model) end
    elseif action_key == "interact" then
        local method_ok, method_value = pcall(function() return teleport.OnInteraction end)
        if not method_ok or method_value == nil then return false, "OnInteraction UFUNCTION not visible on selected teleport" end
        method_value_type = type(method_value)
        local pawn = feature_actor.get_local_pawn()
        if not is_valid(pawn) then return false, "local pawn unavailable" end
        pawn_report = {
            name = safe_name(pawn),
            class = safety.class_name_of(pawn) or "",
            full_name = safe_full_name(pawn),
            location = object_location_text(pawn),
        }
        call_label = "OnInteraction"
        call_fn = function() return teleport:OnInteraction(pawn) end
    end
    if not call_fn then return false, "teleport callscan action did not resolve a call function" end

    local before_counts = generated_counts_snapshot()
    local before_context = model_context_snapshot(model)
    local file_stem = "dungeon_proc_teleport_callscan_" .. action_key
    local report = {
        command = "world.dungeon.proc.teleport.callscan",
        teleport_index = teleport_index,
        model_index = model_index,
        teleport_count = #teleports,
        model_count = #models,
        errors = { teleports = teleport_errors, models = model_errors },
        confirmed = true,
        action = action_key,
        call = call_label,
        method_value_type = method_value_type,
        result = "about_to_call_" .. call_label,
        value = "",
        value_type = "",
        error = "",
        before_counts = before_counts,
        after_counts = {},
        before_context = before_context,
        after_context = {},
        generated_deltas = {},
        warning = "calls one ADungeonTeleport lifecycle function; pcall may not catch engine crashes; records generated counts and selected DungeonContext fields before/after",
        teleport = {
            index = teleport_index,
            name = safe_name(teleport),
            class = safety.class_name_of(teleport) or "",
            full_name = safe_full_name(teleport),
            location = object_location_text(teleport),
        },
        model = {
            index = model_index,
            name = safe_name(model),
            class = safety.class_name_of(model) or "",
            full_name = safe_full_name(model),
            location = object_location_text(model),
        },
        pawn = pawn_report,
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.teleport.callscan --",
        string.format("  live DungeonTeleport actors: %d", #teleports),
        string.format("  live DungeonModel actors: %d", #models),
        string.format("  teleport[%d] %s [%s] loc=%s", teleport_index, report.teleport.name, report.teleport.class, report.teleport.location),
        string.format("  model[%d] %s [%s] loc=%s", model_index, report.model.name, report.model.class, report.model.location),
        "  warning: " .. report.warning,
        "  action=" .. action_key .. " call=" .. call_label,
        "  before_context " .. table.concat(context_snapshot_parts(before_context), " "),
        "  result=" .. report.result,
    }
    if pawn_report then lines[#lines + 1] = string.format("  pawn %s [%s] loc=%s", pawn_report.name, pawn_report.class, pawn_report.location) end
    for error_index = 1, #teleport_errors do lines[#lines + 1] = "  teleport error: " .. tostring(teleport_errors[error_index]) end
    for error_index = 1, #model_errors do lines[#lines + 1] = "  model error: " .. tostring(model_errors[error_index]) end
    local result_line_index = 9
    write_report_files(file_stem .. "_attempt", report, lines)

    local call_ok, call_value = pcall(call_fn)
    report.result = call_ok and "called_" .. call_label or "call_failed"
    lines[result_line_index] = "  result=" .. report.result
    if call_ok then
        local unwrap_ok, unwrapped = pcall(unwrap, call_value)
        if unwrap_ok then call_value = unwrapped end
        report.value_type = type(call_value)
        report.value = raw_value_text(call_value)
        lines[#lines + 1] = string.format("  return type=%s value=%s", report.value_type, report.value)
    else
        report.error = tostring(call_value)
        lines[#lines + 1] = "  error: " .. first_error_line(call_value)
    end

    report.after_counts = generated_counts_snapshot()
    report.after_context = model_context_snapshot(model)
    local delta_parts = generated_delta_parts(before_counts, report.after_counts)
    report.generated_deltas = delta_parts
    if #delta_parts > 0 then
        lines[#lines + 1] = "  generated_deltas " .. table.concat(delta_parts, " ")
    else
        lines[#lines + 1] = "  generated_deltas none"
    end
    lines[#lines + 1] = "  after_context " .. table.concat(context_snapshot_parts(report.after_context), " ")

    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files(file_stem, report, lines)
    local detail = string.format("teleport=%s model=%s action=%s result=%s deltas=%d", report.teleport.name, report.model.name, action_key, report.result, #delta_parts)
    if file_ok then return call_ok, detail .. " wrote " .. tostring(write_detail) end
    return call_ok, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.manual_spawnunit(args_str)
    local tokens = {}
    for token in trim(args_str):gmatch("%S+") do tokens[#tokens + 1] = token end
    local usage = "usage: world.dungeon.proc.manual.spawnunit <" .. manual_spawnunit_options() .. "> [" .. manual_spawn_method_options() .. "] [dx dy dz] confirm"
    local kind_token = tokens[1]
    if not kind_token then return false, usage end
    local kind_key = tostring(kind_token or ""):lower()
    local spec = MANUAL_SPAWN_UNIT_SPECS[kind_key]
    if not spec then return false, "unknown manual spawn unit; choose one of: " .. manual_spawnunit_options() end

    local arg_index = 2
    local method_key = "deferred_place"
    local maybe_method = tokens[arg_index] and tostring(tokens[arg_index]):lower() or ""
    if MANUAL_SPAWN_METHOD_ALIASES[maybe_method] then
        method_key = MANUAL_SPAWN_METHOD_ALIASES[maybe_method]
        arg_index = arg_index + 1
    end

    local dx, dy, dz = 300, 0, 0
    local confirm_token = tokens[arg_index]
    local remaining = #tokens - arg_index + 1
    if remaining == 4 then
        local parsed_dx = tonumber(tokens[arg_index])
        local parsed_dy = tonumber(tokens[arg_index + 1])
        local parsed_dz = tonumber(tokens[arg_index + 2])
        confirm_token = tokens[arg_index + 3]
        if not parsed_dx or not parsed_dy or not parsed_dz then return false, "dx/dy/dz must be numbers" end
        dx, dy, dz = parsed_dx, parsed_dy, parsed_dz
    elseif remaining ~= 1 then
        return false, usage
    end
    if confirm_token ~= "confirm" then return false, usage end

    local use_world_spawn = method_key == "world" or method_key == "world_place"
    local place_after_spawn = method_key == "deferred_place" or method_key == "world_place"

    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return false, "local pawn unavailable" end
    local base_loc = nil
    pcall(function() base_loc = feature_actor.actor_location(pawn) end)
    if not base_loc then return false, "local pawn location unavailable" end
    local spawn_loc = {
        X = (tonumber(base_loc.X) or 0) + dx,
        Y = (tonumber(base_loc.Y) or 0) + dy,
        Z = (tonumber(base_loc.Z) or 0) + dz,
    }

    local uclass = player_core.resolve_uclass(spec.class_path)
    if not uclass then return false, "could not resolve class: " .. tostring(spec.class_path) end
    local feature_net = require("feature_net")
    local pc = feature_net.local_controller()
    if not use_world_spawn and not pc then return false, "no player controller" end
    local gpl = nil
    local begin_deferred_spawn = nil
    local finish_spawning_actor = nil
    local world = nil
    local world_route = ""
    if use_world_spawn then
        world, world_route = get_world_for_spawn(pawn)
        if not world then return false, "UWorld unavailable for SpawnActor" end
        if not world.SpawnActor then return false, "UWorld:SpawnActor missing in this UE4SS build" end
    else
        gpl = get_gameplay_statics()
        if not gpl then return false, "GameplayStatics CDO not found" end
        begin_deferred_spawn = gpl["BeginDeferredActorSpawnFromClass"]
        if not begin_deferred_spawn then return false, "BeginDeferredActorSpawnFromClass missing" end
        finish_spawning_actor = gpl["FinishSpawningActor"]
        if not finish_spawning_actor then return false, "FinishSpawningActor missing" end
    end

    local before_counts = generated_counts_snapshot()
    local report = {
        command = "world.dungeon.proc.manual.spawnunit",
        confirmed = true,
        kind = kind_key,
        method = method_key,
        world_route = world_route,
        label = spec.label,
        class_path = spec.class_path,
        class_full_name = safe_full_name(uclass),
        base = { name = safe_name(pawn), class = safety.class_name_of(pawn) or "", full_name = safe_full_name(pawn), location = vec_text(base_loc) },
        offset = { x = dx, y = dy, z = dz },
        spawn_location = vec_text(spawn_loc),
        result = use_world_spawn and "about_to_WorldSpawnActor" or "about_to_BeginDeferredActorSpawnFromClass",
        error = "",
        before_counts = before_counts,
        after_counts = {},
        generated_deltas = {},
        actor = {},
        placement = { requested = place_after_spawn, attempted = false, ok = false, before = "", after = "", error = "" },
        writes = {},
        warning = "manual actor spawn only; no Init/CreateRoomOnClient/CreateHallwayOnClient/teleport lifecycle calls",
    }
    local lines = {
        "[RSDWTools] world.dungeon.proc.manual.spawnunit --",
        "  kind=" .. kind_key .. " label=" .. tostring(spec.label) .. " method=" .. method_key,
        "  class=" .. tostring(spec.class_path),
        string.format("  base pawn %s [%s] loc=%s", report.base.name, report.base.class, report.base.location),
        string.format("  offset=%.1f,%.1f,%.1f spawn=%s", dx, dy, dz, report.spawn_location),
        "  warning: " .. report.warning,
        "  result=" .. report.result,
    }
    if use_world_spawn then lines[#lines + 1] = "  world_route=" .. tostring(world_route) end
    local result_line_index = 7
    write_report_files("dungeon_proc_manual_spawnunit_attempt", report, lines)

    local spawn_xform = spawn_xform_at_location(spawn_loc)
    local actor = nil
    local spawn_ok = false
    if use_world_spawn then
        local world_obj = world
        if not world_obj then return false, "UWorld unavailable for SpawnActor" end
        local spawn_error = nil
        local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
        spawn_ok, spawn_error = pcall(function()
            actor = world_obj:SpawnActor(uclass, spawn_loc, rot)
        end)
        if not spawn_ok or not is_valid(actor) then
            report.result = spawn_ok and "WorldSpawnActor_returned_invalid" or "WorldSpawnActor_failed"
            report.error = spawn_ok and "invalid actor" or tostring(spawn_error)
        else
            report.result = "spawned_manual_unit"
        end
    else
        local gpl_obj = gpl
        local begin_fn = begin_deferred_spawn
        local finish_fn = finish_spawning_actor
        if not gpl_obj then return false, "GameplayStatics CDO not found" end
        if not begin_fn then return false, "BeginDeferredActorSpawnFromClass missing" end
        if not finish_fn then return false, "FinishSpawningActor missing" end
        local begin_ok, begin_error = pcall(function()
            actor = begin_fn(gpl_obj, pc, uclass, spawn_xform, 2, pc, 0)
        end)
        if not begin_ok or not is_valid(actor) then
            report.result = begin_ok and "BeginDeferredActorSpawnFromClass_returned_invalid" or "BeginDeferredActorSpawnFromClass_failed"
            report.error = begin_ok and "invalid actor" or tostring(begin_error)
        else
            pcall(function() actor["bRegisterAsRuntimeSpawned"] = true end)
            report.actor = { name = safe_name(actor), class = safety.class_name_of(actor) or "", full_name = safe_full_name(actor), location = object_location_text(actor) }
            report.result = "about_to_FinishSpawningActor"
            lines[result_line_index] = "  result=" .. report.result
            lines[#lines + 1] = string.format("  actor %s [%s] full=%s", report.actor.name, report.actor.class, report.actor.full_name)
            write_report_files("dungeon_proc_manual_spawnunit_attempt", report, lines)

            local finish_ok, finish_error = pcall(function()
                finish_fn(gpl_obj, actor, spawn_xform, 0)
            end)
            report.result = finish_ok and "spawned_manual_unit" or "FinishSpawningActor_failed"
            report.error = finish_ok and "" or tostring(finish_error)
            spawn_ok = finish_ok
        end
    end

    if not spawn_ok or not is_valid(actor) then
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = "  error: " .. first_error_line(report.error)
        report.after_counts = generated_counts_snapshot()
        local failure_delta_parts = generated_delta_parts(before_counts, report.after_counts)
        report.generated_deltas = failure_delta_parts
        if #failure_delta_parts > 0 then
            lines[#lines + 1] = "  generated_deltas " .. table.concat(failure_delta_parts, " ")
        else
            lines[#lines + 1] = "  generated_deltas none"
        end
        for line_index = 1, #lines do print(lines[line_index]) end
        local file_ok, write_detail = write_report_files("dungeon_proc_manual_spawnunit", report, lines)
        local detail = string.format("kind=%s method=%s result=%s", kind_key, method_key, report.result)
        if file_ok then return false, detail .. " wrote " .. tostring(write_detail) end
        return false, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
    end

    pcall(function() actor["bRegisterAsRuntimeSpawned"] = true end)
    report.actor = { name = safe_name(actor), class = safety.class_name_of(actor) or "", full_name = safe_full_name(actor), location = object_location_text(actor) }
    if use_world_spawn then
        lines[#lines + 1] = string.format("  actor %s [%s] full=%s", report.actor.name, report.actor.class, report.actor.full_name)
    end
    lines[result_line_index] = "  result=" .. report.result
    lines[#lines + 1] = string.format("  final_actor %s [%s] loc=%s", report.actor.name, report.actor.class, report.actor.location)

    if place_after_spawn then
        report.placement.attempted = true
        report.placement.before = report.actor.location
        report.result = "about_to_place_actor"
        lines[result_line_index] = "  result=" .. report.result
        write_report_files("dungeon_proc_manual_spawnunit_attempt", report, lines)
        pcall(function() feature_actor.force_actor_movable(actor) end)
        local move_ok, move_error = feature_actor.move_actor(actor, spawn_loc)
        report.placement.ok = move_ok == true
        report.placement.error = move_ok and "" or tostring(move_error)
        report.placement.after = object_location_text(actor)
        report.actor = { name = safe_name(actor), class = safety.class_name_of(actor) or "", full_name = safe_full_name(actor), location = report.placement.after }
        report.result = move_ok and "spawned_manual_unit_placed" or "spawned_manual_unit_place_failed"
        lines[result_line_index] = "  result=" .. report.result
        lines[#lines + 1] = string.format("  place ok=%s before=%s after=%s", tostring(move_ok == true), report.placement.before, report.placement.after)
        if not move_ok then lines[#lines + 1] = "  place error: " .. first_error_line(move_error) end
    end

    report.after_counts = generated_counts_snapshot()
    local delta_parts = generated_delta_parts(before_counts, report.after_counts)
    report.generated_deltas = delta_parts
    if #delta_parts > 0 then
        lines[#lines + 1] = "  generated_deltas " .. table.concat(delta_parts, " ")
    else
        lines[#lines + 1] = "  generated_deltas none"
    end
    for line_index = 1, #lines do print(lines[line_index]) end
    local file_ok, write_detail = write_report_files("dungeon_proc_manual_spawnunit", report, lines)
    local detail = string.format("kind=%s method=%s actor=%s result=%s deltas=%d place=%s", kind_key, method_key, report.actor.name or "", report.result, #delta_parts, tostring(report.placement.ok == true))
    if file_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

function M.class_info(args_str)
    local mode = trim(args_str):lower()
    if mode == "" then mode = "status" end
    if mode == "load" then mode = "load.asset" end
    if mode == "unsafe" then mode = "load.unsafe" end
    if mode ~= "status" and mode ~= "scan" and mode ~= "load.asset" and mode ~= "load.unsafe" then
        return false, "usage: world.dungeon.proc.class [status|scan|load|load.asset|load.unsafe]"
    end
    local load_mode = "none"
    if mode == "load.asset" then load_mode = "asset" end
    if mode == "load.unsafe" then load_mode = "kismet" end
    local report, lines = build_probe_report("world.dungeon.proc.class", 1, load_mode, mode == "scan")
    report.mode = mode
    for line_index = 1, #lines do print(lines[line_index]) end
    local write_ok, write_detail = write_report_files("dungeon_proc_class", report, lines)
    local class_report = report.generator_class or {}
    local detail = string.format("mode=%s loaded=%s path=%s", mode, tostring(class_report.loaded), tostring(class_report.load_path or class_report.normalized))
    if write_ok then return true, detail .. " wrote " .. tostring(write_detail) end
    return true, detail .. " see UE4SS log; file write failed: " .. tostring(write_detail)
end

return M
