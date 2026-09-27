-- Command-line router.
-- Supported commands:
--   tele <x> <y> <z>
--   tele.dir <left|right|forward|backward|up|down> [step]
--   player.loc
--   scan <name_part> [radius|all]
--   actor.goto <name>
--   actor.bring <name>
--   actor.del <name>
--   actor.vis <name> [on|off]         (no arg = toggle)
--   actor.col <name> [on|off]         (no arg = toggle)
--   actor.scale <name> [value]        (no value = report current uniform scale)
--   player.time <scale>               (CustomTimeDilation on pawn)
--   player.jump.count <int>           (JumpMaxCount on pawn)
--   player.jump.hold <sec>            (JumpMaxHoldTime on pawn)
--   player.buildings <on|off>         (Server_SetCanDamageBuildings)
--   player.invisible <on|off>         (HideCharacter(on, locker=pawn))
--   player.soulrift <on|off>          (Server_SetSoulRiftImmunity)
--   player.tp.delay <sec>             (TeleportLoadingScreenDelay)
--   player.tp.vfx <sec>               (TeleportBeginVFXDelay)
--   player.tp.timeout <sec>           (TeleportTimeout)
--   player.invincible <on|off>        (DamageComponent.SetCanTakeDamage(!on))
--   player.immortal <on|off>          (HealthComponent.SetCanDie(!on))
--   player.health <n>                 (HealthComponent.SetHealth(n, "rsdw.set"))
--   player.health.heal                (sets current to max)
--   player.health.damage <n>          (HealthComponent.DecreaseHealth(n, ...))
--   player.fall_immune <on|off>       (CharacterMovement.SetFallDamageImmune)
--   player.walkspeed <n>              (CharacterMovement.MaxWalkSpeed)
--   player.jumpvel <n>                (CharacterMovement.JumpZVelocity)
--   player.gravity <n>                (CharacterMovement.GravityScale)
--   player.aircontrol <n>             (CharacterMovement.AirControl)
--   player.speedmult <n>              (DominionMovementComponent.MovementSpeedMultiplier)
--   player.flyspeed <n>               (CharacterMovement.MaxFlySpeed)
--   player.acceleration <n>           (CharacterMovement.MaxAcceleration)
--   player.movemode <walk|fly|fall|custom|none>  (SetMovementMode)
--   player.noclip <on|off>            (bCheatFlying + SetActorEnableCollision + SetMovementMode)
--   player.hydration <n>              (HydrationComponent.CurrentHydration)
--   player.hydration.refill           (tops up to max)
--   player.sustenance <n>             (SustenanceComponent.CurrentSustenance)
--   player.sustenance.refill          (tops up to max)
--   player.endurance <n>              (EnduranceComponent.CurrentEndurance)
--   player.endurance.refill           (tops up to max)
--   player.toxicity <n>               (ToxicityComponent.CurrentToxicity)
--   player.toxicity.clear             (sets toxicity to 0)
--   player.stealth <on|off>           (PlayerStealthComponent.Multicast_EnterStealth/Exit)
--   player.stamina.refill             (StaminaComponent.DecreaseStamina(-max) + ResetRegen)
--   player.wakeup                     (PlayerRestComponent.Server_RequestWakeUp)
--   player.durabilityloss <on|off>    (ItemDurabilityComponent.DurabilityLossRate +
--                                      DamageComponent.DamagedByDurabilityMultiplier)
--   player.magnet <n>                 (ItemMagnet.MagnetRange)
--   player.fov <n>                    (PlayerController.FOV -> PlayerCameraManager.DefaultFOV)
--   player.silent <on|off>            (NoiseEmitter.* loudness fields -> 0)
--   player.surge <on|off>             (PlayerEvadeComponent.EnableSurge + SurgeEffectMaxUsages
--                                      + SurgeEffectDuration)
--   player.parrywindow <ms>           (PlayerBlockingComponent.ParryWindowLength)
--   player.blockangle <deg>           (PlayerBlockingComponent.BlockingAngle)
--   player.lockon <scale>             (scales LockOnTargetingComponent's 4 distance fields)
--   player.respawninvul <sec>         (PlayerDamageComponent.RespawnInvulnerabilityLength)
--   player.wellrested <sec>           (PlayerRestComponent.WellRestedDurationSeconds)
--   player.poise <on|off>             (HitReactionsComponent.*ForceThreshold -> 1e9)
--   player.perfectaim <on|off>        (PlayerRangedAttackComponent.{Base,Minimum}Inaccuracy -> 0)
--   player.ge.apply  <ClassName>      (UDominionGameplayEffectsComponent.InstantiateGameplayEffect +
--                                      ApplyGameplayEffect; caches the returned handle so a later
--                                      player.ge.remove hits the exact instance we spawned)
--   player.ge.remove <ClassName>      (BP_RemoveAllGameplayEffectsWithData + cached-handle fallback)
--   player.ge.toggle <ClassName> <on|off>  (thin wrapper around apply/remove)
--   player.ge.has    <ClassName>      (true|false using HasGameplayEffect on the cached handle)
--   player.ge.list                    (returns "N applied: A, B, ..." inline in the ack body;
--                                      diagnostic for reconciling UI state after a reload)
--   player.attr.set <ClassName> <value>  (Round 22: writes the live UDominionAttributesComponent
--                                         AttributeValues[i] / SharedAttributeValues[i] slot for
--                                         the matching UFloatAttribute subclass. New path
--                                         distinct from ??5/??13/??17/??18/??23/??12 attempts.
--                                         Known broken: MaxCarryWeight (??26 -- cached threshold
--                                         on EncumbranceComponent, write lands but no recompute).)
--   player.attr.get <ClassName>          (Round 22: reads the same slot for diagnostics.)
--   player.mounts.unlockall [on|off]  (MountComponent.SetAllMountsUnlocked; no arg = unlock)
--   player.mount.invincible <on|off>  (MountComponent.bDamageForcesDismount + bIgnoreSurvivalDamage)
--   player.aimpitch <on|off>          (RangedAttack min/target pitch angles unlocked to -90)
--   player.arrowrange <cm>            (RangedAttack.MaxProjectileTraceDistance; clamp 1000..100000)
--   player.revivedelay <sec>          (PlayerRespawnComponent.SelfReviveDelay; clamp 2..60)
--   player.anim.play <path>           (infers attack-data vs AnimMontage path)
--   player.anim.montage <path>        (raw UAnimMontage playback on player anim instance)
--   player.anim.stop [path|blend]     (stops player montage playback)
--   player.attack <ClassPath>         (UPlayerAttackData through player attack component)
--   player.attack.perform <current|last|action|attack> [combo#|quick|full] [fresh|reset|chain]  (experimental: real melee/ranged action instance)
--   player.attack.state               (diagnostic: component/equipment/action state)
--   player.attack.data <ClassPath>    (diagnostic: attack data CDO and collection membership)
--   player.attack.trace <on|off>      (diagnostic: log real combat hook events)
--   player.emote <slot|name|stop>     (PlayerEmotesComponent slot playback)
--   world.class.load <ClassPath>      (diagnostic: Kismet soft-class load without spawning)
--   world.spawn.safe <ClassPath>      (spawn first, fall back to native summon)
--   world.spawn.transform <ClassPath> {"loc":[x,y,z],"rot":[pitch,yaw,roll],"scale":[x,y,z]}
--   world.wave <event_token> [auto|count] [single|mixed] [tracked|untracked] confirm
--   world.dragon <meteors|poison|imaru|token> confirm
--   world.encounter.stop [all|events|spawned] confirm
--   player.critchance (removed in 11.5; see cheats-to-revisit.md section 13)
--   player.foliagerange (removed in 11.5; see cheats-to-revisit.md section 14)
--   player.spell.cancel               (PlayerMagicComponent.Server_CancelSpell on both magic components)
--   actor.spectate <name>             (PlayerController.SetViewTargetWithBlend to named actor)
--   actor.spectate.reset              (SetViewTargetWithBlend back to the local pawn)
--   npc.drive.select [name|look]      (select a driveable Dominion AI actor)
--   npc.drive.status|clear
--   npc.drive.camera [on|off|toggle] [front|frontright|frontleft|left|right|back|orbit] [distance_cm height_cm]
--   npc.drive.hideplayer [on|off|toggle]
--   npc.drive.quiet [on|off|toggle]
--   npc.drive.probe
--   npc.drive.tune [on|off|toggle] | npc.drive.tune root <scale>
--   npc.drive.aimove [on|off|toggle]       (global AI movement gate)
--   npc.drive.roamdata [off|on|toggle|probe|defaults]
--   npc.drive.roamdata set <on|off> <minDist> <maxDist> <minWait> <maxWait> [run walk]
--   npc.drive.puppet [on|off|toggle|native|anim|slide]
--   npc.drive.hold [on|off|toggle|lock|pin]
--   npc.drive.move [input|direct|slide|anim|native] <forward|back|left|right|reticle> [distance_cm]
--   npc.drive.face [reticle]
--   npc.drive.jump [launch] [z_velocity]
--   npc.drive.repairinput [reason]
--   npc.drive.brain [stop|start|toggle]
--   npc.drive.attack <AiAttackDataClassPath>
--   npc.drive.action <DominionAIActionClassPath>
--   npc.inspect.on [look|name] [front|frontright|frontleft|left|right|back|orbit] [distance_cm height_cm]
--   npc.inspect.off|status|state|snap|select
--   npc.inspect.scan [query|*] [radius|all] [limit]
--   npc.inspect.orbit [left|right|front|frontright|frontleft|back|profile-left|profile-right|yaw <deg>|pitch <deg>|<delta_deg>] [amount]
--   npc.inspect.mouse [on|off|toggle] [yaw_sensitivity pitch_sensitivity]  (also enables scroll-wheel zoom)
--   npc.inspect.focus [bounds|aim|up <cm>|down <cm>|z <offset>|reset]
--   npc.inspect.hud [on|off|toggle] ; npc.inspect.umg [on|off|toggle] ; npc.inspect.nudge [reticle]
--   camera.debug.force_restore
--   camera.debug.speed <scale>
--   camera.rig.start [speed]
--   camera.rig.stop
--   camera.rig.capture <name>
--   camera.rig.pose.set <name> <x> <y> <z> <pitch> <yaw> <roll> <fov>
--   camera.rig.poses.file <filename>
--   camera.rig.delete <name>
--   camera.rig.clear
--   camera.rig.list
--   camera.rig.goto <name> [seconds]
--   camera.rig.goto.file <filename> <name> [seconds]
--   camera.rig.play <from> <to> [seconds]
--   camera.rig.play.file <filename>
--   camera.rig.fov <degrees>
--   camera.rig.roll.add <degrees>
--   camera.rig.roll.set <degrees>
--   camera.rig.roll.reset
--   camera.rig.roll.step <degrees>
--   camera.rig.roll.status
--   camera.rig.lookat <actorName|off>
--   camera.oculus.status
--   camera.oculus.start|stop|toggle
--   camera.oculus.init
--   camera.oculus.help [on|off|toggle]
--   camera.oculus.umg <on|off|toggle>
--   camera.oculus.require <active|inactive|preview|repair|rotation|scale>
--   camera.oculus.speed [<maxSpeed> [acceleration] [deceleration]]
--   camera.oculus.distance [<maxDistance> [falloffThreshold]]
--   camera.oculus.vignette <off|on> [duration] [r,g,b,a]
--   camera.oculus.watermark <off|on|toggle>
--   camera.oculus.clone
--   camera.grab.item
--   camera.lookat.item
--   player.get <key>                  (reads one of: time, jump.count, jump.hold, buildings,
--                                                 tp.delay, tp.vfx, tp.timeout,
--                                                 health, maxhealth, walkspeed, jumpvel,
--                                                 gravity, aircontrol, speedmult,
--                                                 flyspeed, acceleration,
--                                                 hydration, sustenance, endurance, toxicity,
--                                                 stamina, maxstamina, stealth,
--                                                 durabilityloss, magnet,
--                                                 fov, silent, surge,
--                                                 parrywindow, blockangle, lockon,
--                                                 respawninvul, wellrested, poise,
--                                                 perfectaim)
--   dump.types                        (Round 29: invokes UE4SS GenerateLuaTypes()
--                                      to regenerate the EmmyLua type stubs under
--                                      <ue4ss>/Mods/shared/types/. Step 1 of the
--                                      static catalog pipeline; the WPF Catalog tab
--                                      then runs Generate-Catalog.ps1 to produce
--                                      ipc/catalog/catalog.jsonl. Replaces every
--                                      former player.dump.* probe verb.)
--   player.spells.unlock              (writes bNeedsUnlocking=false on every live
--                                      UUtilitySpellData in SelectedSpells AND inserts
--                                      each into pc.ProgressComponent.SpellsUnlocked TSet
--                                      -- the actual runtime gate the cast code reads.
--                                      on=unlock+TSet add, off=restore + TSet remove)
--   player.spells.zerocooldown        (writes CooldownDuration=0 on every live
--                                      UUtilitySpellData in SelectedSpells; on=zero all,
--                                      off=restore cached originals)
--   player.spells.continuouscast      (EXPERIMENTAL: flips bContinuouslyCast=true on
--                                      every UUtilitySpellData -- hypothesis is the
--                                      caster auto-recasts buffs like Tempest Shield /
--                                      Enchant Weapon. Behaviour on placement spells
--                                      may be chaotic. Off restores cached originals.)
--   world.time <hour>                 (DayNightCycleVarsSourceActor.ForcedDayTime overlay; visual only.
--                                      Round 25: StoredTime no longer written here -- see world.storedtime.)
--   world.time.release                (clear ForcedDayTime override on all DayNight actors)
--   world.time.probe                  (read-only dump : InGameTimeActor + DayNight actors + IsDayOrNight)
--   world.time.pause <on|off>         (AInGameTimeActor.bIsTimePaused)
--   world.time.speed <minutes>        (AInGameTimeActor.RealTimeMinutesPerInGameDay)
--   world.dawn <hour>                 (AInGameTimeActor.TimeOfDawn; vanilla 4.5)
--   world.dusk <hour>                 (AInGameTimeActor.TimeOfDusk; vanilla 22)
--   world.storedtime <hour>           (Round 25 EXPERIMENTAL: writes the persistent
--                                      AInGameTimeActor.StoredTime accumulator. Preserves
--                                      day counter (recomputes today's day floor + offsets
--                                      by hour). Round 22 disabled this path on the safe
--                                      slider due to corruption risk on bigger jumps.)
--   world.weather <type>              (WeatherSubsystem.TrySetWeather; 0-8 or name)
--   world.weather.pause <on|off>      (WeatherSubsystem.PauseWeather)
--   world.weather.probe               (read-only dump : subsystem + RegionSpecific actors + RegionalWeather)
--   world.weather.where               (WeatherSubsystem.GetWeatherAtLocation at player)
--   world.weather.list                (enumerate every accepted EWeatherType value + alias ; pipe-delimited)
--   world.weather.regional <type>     (RAW : write WeatherType on every UDynamicRegionalWeather +
--                                      UStaticRegionalWeather. Bypasses TrySetWeather to test if
--                                      regional state is overriding it. Fires OnRep_WeatherType.)
--   world.weather.region_priority <n> (RAW : write Priority on every ARegionSpecificGlobalWeatherActor.
--                                      Higher wins when overlapping ; useful to test biome routing.)
--   enemy.aggro.scan [limit] [all]    (safe active Dominion AI candidates via known AI classes ; writes ipc/enemy_aggro_scan.*)
--   enemy.aggro.discover [query|*] [radius|all]
--                                      (NPC Inspect-style BP_AI_*Character name scan ; writes ipc/scan_results.json)
--   enemy.aggro.status <look|nearest|actor_name>
--   enemy.aggro.target|clear <look|nearest|actor_name> confirm
--   enemy.aggro.draw <look|nearest|actor_name> [range_cm] confirm
--   enemy.aggro.force <look|nearest|actor_name> [range_cm] confirm
--   enemy.aggro.restore <look|nearest|actor_name> confirm
--                                      (draw/force probe DominionAiFunctionLibrary aggro/threat wake paths)
--   world.event.list [limit]          (startable event definitions + startlive tokens ; writes ipc/world_event_list.*)
--   world.event.probe [limit]         (WorldEventManager definitions ; writes ipc/world_event_probe.*)
--   world.event.def <index>           (one WorldEventDefinition summary)
--   world.event.defstate <index|id>   (read manager DefinitionsJSONData state for one event ; writes ipc/world_event_defstate.*)
--   world.event.triggers <index>      (safe definition trigger-field diagnostic ; direct TArray enumeration disabled)
--   world.event.triggerscan [limit] [light|fields|value|full]
--                                      (FindAllOf trigger object scan ; writes ipc/world_event_triggerscan.*)
--   world.event.triggervalue <scan_index>
--   world.event.fireobject <scan_index> <on|off> confirm
--   world.event.resetobject <scan_index> confirm
--   world.event.firetrigger/resettrigger are guarded off after direct Triggers TArray AV
--   world.event.start <alias|path> [groupTag|none] confirm
--   world.event.startdef <index> [groupTag|none] confirm
--                                      (starts using the manager definition's own WorldEventClass soft ref)
--   world.event.startprobe <index|id> [groupTag|none] confirm
--                                      (tries StartEvent argument variants ; writes ipc/world_event_startprobe.*)
--   world.event.spawnprobe <index|id> [keep|destroy] confirm
--                                      (direct SpawnActor probe ; writes ipc/world_event_spawnprobe.*)
--   world.event.active [limit]        (live WorldEvent/BaseRaidEvent actor scan)
--   world.event.eventstate [limit]    (detailed live event actor snapshots ; writes ipc/world_event_eventstate.*)
--   world.event.aicomponent <latest|index|name>
--                                      (inspect live event AIWaveSpawnComponent wiring ; writes ipc/world_event_aicomponent.*)
--   world.event.aicomponent.link <latest|index|name> confirm
--                                      (confirm-gated owner/director/register/activate wake probe ; writes ipc/world_event_aicomponent_link.*)
--   world.event.waves <latest|index|name> [light|fields|full]
--                                      (read live event wave budgets/spawn classes ; writes ipc/world_event_waves.*)
--   world.event.spawnwave <latest|index|name> [count|auto] confirm
--                                      (fallback-spawn a sample/full count from the live event's wave data ; writes ipc/world_event_spawnwave.*)
--   world.event.startwave <index|id|alias> [count|auto] confirm
--                                      (start live event + spawn configured wave ; writes ipc/world_event_startwave.*)
--   world.event.kick <latest|index|name> <auto|start|fields|timer|beginplay|all> confirm
--                                      (tries to wake a spawned live event actor ; writes ipc/world_event_kick.*)
--   world.event.startlive <index|id|alias> confirm
--                                      (direct spawn + timer/start wake path ; writes ipc/world_event_startlive.*)
--   world.event.destroy <latest|index|name|all> confirm
--                                      (destroy direct-spawned live event actors ; writes ipc/world_event_destroy.*)
--   world.event.clientflag <hunted|base|dragon> <on|off> confirm
--                                      (client UI/audio flag only, not a full event start)
--   world.dungeon.probe [limit]       (read-only dungeon subsystem/actor inventory ; writes ipc/dungeon_probe.*)
--   world.dungeon.scan [limit]        (alias for world.dungeon.probe)
--   world.dungeon.list [limit]        (indexed loaded ADungeon list ; writes ipc/dungeon_list.*)
--   world.dungeon.goto <index> [entrance|exit|center]
--   world.dungeon.where               (DominionRuntimeBlueprintLibrary.IsLocationInsideDungeon at player)
--   world.dungeon.proc.probe [limit]  (read-only /Script/Dungeon procedural inventory ; writes ipc/dungeon_proc_probe.*)
--   world.dungeon.proc.scan [limit]   (alias for world.dungeon.proc.probe)
--   world.dungeon.proc.models [limit] (minimal live ADungeonModel/BP_DungeonModel_C actor list ; writes ipc/dungeon_proc_models.*)
--   world.dungeon.proc.status         (live model/teleport/spawn-manager counts + spawn hints ; writes ipc/dungeon_proc_status.*)
--   world.dungeon.proc.spawnmanagers [limit] (live UDungeonSpawnManager SpawnedDungeons count/sample ; writes ipc/dungeon_proc_spawnmanagers.*)
--   world.dungeon.proc.managers [limit] (metadata-only live manager/helper object scan ; writes ipc/dungeon_proc_managers.*)
--   world.dungeon.proc.generated [limit] (metadata-only live generated dungeon actors/objects scan ; writes ipc/dungeon_proc_generated.*)
--   world.dungeon.proc.generated.state [limit] (FindAllOf scan plus Actor.IsActorBeingDestroyed state and unique actor summary ; useful after cleanup ; writes ipc/dungeon_proc_generated_state.*)
--   world.dungeon.proc.generated.spawners [limit] confirm
--                                      (metadata-only DungeonSpawner inventory: enemy/chest/miniboss split from UObject names only ; no reflected field reads and no method lookup or invocation ; writes ipc/dungeon_proc_generated_spawners.*)
--   world.dungeon.proc.generated.populationplan [latest] confirm
--                                      (read-only projected enemy/chest/resource marker map from archive-authored room child transforms cached by spawnconnected ; no live spawner reflection or spawn calls ; writes ipc/dungeon_proc_generated_populationplan.*)
--   world.dungeon.proc.generated.entrance.probe [latest] confirm
--                                      (read-only entrance-room runtime probe: latest layout edge targets, reviewed special connector anchors, authored Teleport/door/fence positions, component inventory, and nearby teleport/door candidates ; writes ipc/dungeon_proc_generated_entrance_probe.*)
--   world.dungeon.proc.generated.entrance.patchprobe [latest] [closures|hubvisual|west|lower|north|upper|all|<candidate>] confirm
--                                      (read-only entrance-room closure probe: reviewed west/lower-north/upper-north patch candidate transforms plus WallISM/WallDoorISM/WideDoorISM/FloorISM nearest-instance/method surface ; writes ipc/dungeon_proc_generated_entrance_patchprobe.*)
--   world.dungeon.proc.generated.entrance.patchtest [latest] [closures|hubvisual|west|lower|north|upper|all|<candidate>] [z_offset_cm] confirm
--                                      (mutating entrance visual patch test: spawns reviewed temporary cap/marker actors, including west and lower-north BP_DectructibleDungeonWall_C candidates, cached for generator.spawnclear cleanup ; writes ipc/dungeon_proc_generated_entrance_patchtest.*)
--   world.dungeon.proc.generated.bossroom.probe [latest] confirm
--                                      (read-only boss-room runtime probe: latest layout edge, method-name surface, component inventory, and nearby/keyword gate/chest/trigger candidates ; no spawner field reads or method calls ; writes ipc/dungeon_proc_generated_bossroom_probe.*)
--   world.dungeon.proc.generated.bossroom.snapshot [latest] confirm
--                                      (read-only focused boss-room gate/chest snapshot: treasure gate components, boss spawn point, boss chest spawner, nearby chest/door/trigger objects ; writes ipc/dungeon_proc_generated_bossroom_snapshot.*)
--   world.dungeon.proc.generated.bossroom.death [latest] confirm
--                                      (mutating boss-room action test: snapshots, calls BP_BossRoom_C:OnBossIsDead once even when UE4SS exposes it as userdata, snapshots immediate gate/chest deltas ; run snapshot again after a few seconds ; writes ipc/dungeon_proc_generated_bossroom_death.*)
--   world.dungeon.proc.generated.bossroom.unlock [latest] confirm
--                                      (mutating fallback boss-room gate-open test: hides/collision-disables SM_TreasureGate01/02 only, snapshots immediate deltas ; use after native death call does not open reward gates ; writes ipc/dungeon_proc_generated_bossroom_unlock.*)
--   world.dungeon.proc.generated.bossroom.spawnboss [latest] [skeletal|thane|razlem|<ClassPath>] [z_offset_cm] confirm
--                                      (mutating boss encounter bridge: spawns a test boss at BossSpawnPoint, default skeletal/+0cm, starts a health/destroy watcher, and calls native OnBossIsDead when the boss dies ; writes ipc/dungeon_proc_generated_bossroom_spawnboss.* and *_watch.*)
--   world.dungeon.proc.generated.bossroom.bossstatus [latest] confirm
--                                      (read-only latest generated boss encounter status: spawned boss health/destroy state, watcher state, and last gate-open call result ; writes ipc/dungeon_proc_generated_bossroom_bossstatus.*)
--   world.dungeon.proc.generated.bossroom.killboss [latest] confirm
--                                      (mutating test-only shortcut for the latest spawned boss: SetHealth(0), DecreaseHealth fallback, then destroy fallback so the watcher can prove the gate-open bridge ; writes ipc/dungeon_proc_generated_bossroom_killboss.*)
--   world.dungeon.proc.generated.surface <room|hallway> [index] confirm
--                                      (safe generated BP actor surface probe: method presence, whitelisted fields, root/components, ISM counts/transforms ; no Init/CreateRoom/teleport calls ; writes ipc/dungeon_proc_generated_surface_* )
--   world.dungeon.proc.generated.wallprobe <room_index> [limit|all] confirm
--                                      (read-only WallISM instance transform dump for one generated room ; writes ipc/dungeon_proc_generated_wallprobe_room.*)
--   world.dungeon.proc.generated.wallremove <room_index> <x> <y> <z> [max_distance] confirm
--                                      (mutating one-wall probe: removes nearest WallISM instance within max_distance ; writes ipc/dungeon_proc_generated_wallremove_room.*)
--   world.dungeon.proc.generated.openwalls [latest] [max_distance] confirm
--                                      (mutating smart-spawn opener: removes nearest WallISM at each cached connector endpoint from the latest spawnconnected smart/smartdirect run in this Lua session ; writes ipc/dungeon_proc_generated_openwalls.*)
--   world.dungeon.proc.generated.floorcell [room_index] [dimension] [x y height] confirm
--                                      (primitive GenerateFloorCell probe on a procedural room actor ; snapshots cell/door-related counts before/after ; writes ipc/dungeon_proc_generated_floorcell*)
--   world.dungeon.proc.generator.fieldone <index> <algo|grid|room_subclass|hallway_subclass> confirm
--                                      (disabled: direct private generator field reads can crash)
--   world.dungeon.proc.generator.classrefs [cdo|generator_index] confirm
--                                      (read generator RoomSpawnSubclass/HallwaySpawnSubclass class refs with per-field attempt markers ; writes ipc/dungeon_proc_generator_classrefs*)
--   world.dungeon.proc.generator.spawnref [cdo|generator_index] <room|hallway> [deferred_place|deferred|world_place|world] [dx dy dz] confirm
--                                      (spawn the class returned by a generator class ref near player ; no Init/CreateRoom/teleport lifecycle calls ; writes ipc/dungeon_proc_generator_spawnref*)
--   world.dungeon.proc.generator.spawnlayout [cdo|generator_index] [pair|line3|line5|cross|grid3] [step] [dx dy dz] confirm
--                                      (spawn a simple room/hallway layout from generator BP class refs ; no Init/CreateRoom/teleport lifecycle calls ; writes ipc/dungeon_proc_generator_spawnlayout*)
--   world.dungeon.proc.generator.spawnconnected [cdo|generator_index] [room_count] [tile_step] [branch_percent] [seed] [smartdirect|smart|prefabs|base] [origin_x origin_y origin_z] confirm
--                                      (spawn a large connected dungeon test layout ; smartdirect center-aligns catalog WallISM spans in world XYZ, keeps direct rooms clear of unrelated neighbors, and uses no hallway actors ; smart keeps one-tile hallway cells ; defaults to origin 0,0,100000 ; no native dungeon lifecycle calls ; writes ipc/dungeon_proc_generator_spawnconnected*)
--   world.dungeon.proc.generator.spawnclear [latest|all] [destroy|hard|quarantine] confirm
--                                      (cleanup cached actors spawned by generator.spawnref/spawnlayout/spawnconnected/spawnoptions ; reports accepted vs verified inactive ; hard hides/collision-off/tick-off/lifespan+destroy ; writes ipc/dungeon_proc_generator_spawnclear*)
--   world.dungeon.proc.generator.spawnoptions [cdo|generator_index] [start_option end_option] [step] [dx dy dz] confirm
--                                      (spawn room BP actors from selected source GetRoomsOptions coords/type/rotation using CDO RoomSpawnSubclass ; no Init/CreateRoom/teleport lifecycle calls ; writes ipc/dungeon_proc_generator_spawnoptions*)
--   world.dungeon.proc.generator.autowire <model_index> confirm
--                                      (construct and wire BP_DungeonGenerator_C only; no private field reads/calls ; writes ipc/dungeon_proc_generator_autowire*)
--   world.dungeon.proc.generator.callone <index> rooms_options confirm
--                                      (call BP GetRoomsOptions once; auto-constructs from model[index] if no generator exists ; writes ipc/dungeon_proc_generator_callone*)
--   world.dungeon.proc.generator.roomoption [cdo|generator_index] <option_index> <coords|shape_slots|rotation|type|height|max_count> confirm
--                                      (call selected source GetRoomsOptions and read one field from one returned FDungeonRoomOptions ; writes ipc/dungeon_proc_generator_roomoption*)
--   world.dungeon.proc.generator.roomoptions.summary [cdo|generator_index] <start_option> <end_option> confirm
--                                      (call selected source GetRoomsOptions once and read type/coords/shape_slots/height/max_count for up to 8 options ; writes ipc/dungeon_proc_generator_roomoptions_summary_##_##*)
--   world.dungeon.proc.manager.construct <model_index> <generator|items|doors|doors_native|characters|replication|minimap> confirm
--                                      (construct one manager UObject with model as Outer ; no injection/calls ; writes ipc/dungeon_proc_manager_construct*)
--   world.dungeon.proc.manager.constructwire <model_index> <generator|items|doors|doors_native|characters|replication|minimap> [current] confirm
--                                      (construct and immediately write model/backref fields ; no readback/generation ; writes ipc/dungeon_proc_manager_constructwire*)
--   world.dungeon.proc.manager.constructgraph <model_index> confirm
--                                      (construct and wire generator/items/doors_native/characters/replication/minimap ; sets current to generator ; no generation calls ; writes ipc/dungeon_proc_manager_constructgraph*)
--   world.dungeon.proc.spawn.bootstrap [depth] [seed] [biome:0|1|2] [graph|nograph] confirm
--                                      (fresh-launch helper: spawn BP_DungeonTeleport_C near player, spawn.linked a model, and by default construct manager graph ; no teleport interaction ; writes ipc/dungeon_proc_spawn_bootstrap*)
--   world.dungeon.proc.entry.surface <model_index> [interesting|all|keyword] confirm
--                                      (read-only ForEachFunction enumeration over model + cached manager graph; no field reads/calls ; writes ipc/dungeon_proc_entry_surface*)
--   world.dungeon.proc.manager.assign <model_index> <generator|items|doors|doors_native|characters|replication|minimap> [cache_index|latest] confirm
--                                      (write ADungeonModel manager pointer from cached constructed manager ; no field readback ; writes ipc/dungeon_proc_manager_assign*)
--   world.dungeon.proc.manager.backref <model_index> <items|doors|doors_native|characters|replication> [cache_index|latest] confirm
--                                      (write manager.Model backref where known ; no method calls ; writes ipc/dungeon_proc_manager_backref*)
--   world.dungeon.proc.manager.current <model_index> <generator|items|doors|doors_native|characters|replication|minimap> [cache_index|latest] confirm
--                                      (write ADungeonModel.CurrentChainComponent from cached manager ; no generation calls ; writes ipc/dungeon_proc_manager_current*)
--   world.dungeon.proc.spawnmanager.adopt.model <manager_index> <model_index> confirm
--                                      (unsafe: append model to SpawnedDungeons if missing ; writes ipc/dungeon_proc_spawnmanager_adopt_model*)
--   world.dungeon.proc.bridge.model <manager_index> <teleport_index> <model_index> confirm
--                                      (unsafe: append model + assign teleport DungeonInterface ; writes ipc/dungeon_proc_bridge_model*)
--   world.dungeon.proc.model.callone <index> <onrep|build_blocker|show_loading_on|show_loading_off|receive_tick|beginplay|construction|respawn_resources> confirm
--                                      (one ADungeonModel/Actor native or BP event call with attempt marker ; respawn_resources requires danger ; writes ipc/dungeon_proc_model_callone*)
--   world.dungeon.proc.model.callscan <index> <onrep|build_blocker|show_loading_on|show_loading_off|receive_tick|beginplay|construction|respawn_resources> confirm
--                                      (one ADungeonModel call plus generated-count/context before-after scan ; respawn_resources requires danger ; writes ipc/dungeon_proc_model_callscan*)
--   world.dungeon.proc.model.contextone <index> <doors|walls|replicated_rooms|replicated_hallways|rooms|hallways|players|center|levels|level_height> confirm
--                                      (read one safe FDungeonDataContext count/value/vector field with attempt marker ; object/interface fields are disabled after crash ; writes ipc/dungeon_proc_model_contextone*)
--   world.dungeon.proc.model.fieldone <index> <client_seed|listener> confirm
--                                      (unsafe: one whitelisted model field read ; writes ipc/dungeon_proc_model_fieldone*)
--   world.dungeon.proc.teleports [limit] (metadata-only live ADungeonTeleport actor list ; writes ipc/dungeon_proc_teleports.*)
--   world.dungeon.proc.teleport.callcheck <index>  (metadata-only after live crash ; writes ipc/dungeon_proc_teleport_callcheck.*)
--   world.dungeon.proc.teleport.callone <index> <fullname|location|authority|name|class|netmode|displayname> confirm
--                                      (unsafe: one native-call probe with attempt marker ; writes ipc/dungeon_proc_teleport_callone*)
--   world.dungeon.proc.teleport.configure <index> [depth] [seed] [biome:0|1|2]
--                                      (configure explicit dungeon spawn location ; writes ipc/dungeon_proc_teleport_configure.*)
--   world.dungeon.proc.teleport.surface <index> [interesting|all|keyword]
--                                      (method lookup plus read-only ForEachFunction enumeration ; writes ipc/dungeon_proc_teleport_surface.*)
--   world.dungeon.proc.teleport.bring <index> [distance] [up] confirm
--                                      (move selected live DungeonTeleport in front of local pawn for detector testing ; no interaction/generation call ; writes ipc/dungeon_proc_teleport_bring*)
--   world.dungeon.proc.teleport.interaction.surface <teleport_index> [interesting|all|keyword] confirm
--                                      (read teleport.InteractionComponent, snapshot player detector + InteractionManager, enumerate component UFunctions ; no interaction/delegate calls ; writes ipc/dungeon_proc_teleport_interaction_surface*)
--   world.dungeon.proc.teleport.interaction.guard <teleport_index> <on|off> confirm
--                                      (toggle InteractionComponent.bDisabledLocally on a spawned test portal ; no interaction/delegate calls ; writes ipc/dungeon_proc_teleport_interaction_guard*)
--   world.dungeon.proc.teleport.interaction.request <teleport_index> [primary|secondary] [press|release] danger
--                                      (preflight only: Server_RequestInteraction is a confirmed UE4SS crash boundary ; writes ipc/dungeon_proc_teleport_interaction_request*)
--   world.dungeon.proc.postinteract <teleport_index> <model_index> confirm
--                                      (read-only snapshot after real in-game interact key: generated counts, model context, detector ; writes ipc/dungeon_proc_postinteract*)
--   world.dungeon.proc.teleport.assign.model <teleport_index> <model_index> confirm
--                                      (unsafe: write teleport DungeonInterface to model ; writes ipc/dungeon_proc_teleport_assign_model*)
--   world.dungeon.proc.teleport.notify.model <teleport_index> <model_index> danger
--                                      (known crash boundary: OnDungeonLoaded takes an interface param ; writes ipc/dungeon_proc_teleport_notify_model*)
--   world.dungeon.proc.teleport.callscan <teleport_index> <model_index> <notify_model|interact> danger
--                                      (one teleport lifecycle call plus generated-count/context before-after scan ; writes ipc/dungeon_proc_teleport_callscan_*)
--   world.dungeon.proc.teleport.interact <index> danger
--                                      (known crash boundary: calls ADungeonTeleport:OnInteraction(local pawn) ; writes ipc/dungeon_proc_teleport_interact*)
--   world.dungeon.proc.manual.spawnunit <procedural_room|room_unit|hallway_unit|spawner|chest_spawner|blocker|lighting> [deferred_place|deferred|world_place|world] [dx dy dz] confirm
--                                      (manual actor spawn near player, optional post-spawn placement/direct UWorld fallback, no Init/CreateRoom/teleport lifecycle calls ; writes ipc/dungeon_proc_manual_spawnunit*)
--   world.dungeon.proc.class [status|scan|load|load.asset|load.unsafe]
--                                      (inspect/load MapGenerationSettings.DungeonGeneratorV2 ; writes ipc/dungeon_proc_class.*)
--   world.progress.probe              (locate AWorldProgressManager and count defeated boss flags)
--   world.progress.has <InternalName>       (membership check for boss defeated flag)
--   world.progress.defeat <InternalName>    (SaveGame TSet<FString>, e.g. ai_boss_velgar)
--   world.progress.undefeat <InternalName>  (remove that boss flag again)
--   world.progress.value.list               (known TaggedWorldProgressValues aliases)
--   world.progress.value.get <Alias>        (GetWorldProgressValue for known aliases)
--   world.progress.value.set <Alias> <Num>  (SetWorldProgressValue for known aliases)
--   world.progress.hook.has <AssetPath>     (UWorldHook triggered membership check)
--   world.progress.hook.probe <AssetPath>   (UWorldHook state diagnostics)
--   world.progress.hook.trigger <AssetPath> (EXPERIMENTAL UWorldHook trigger)
--   world.progress.hook.fire <AssetPath>    (EXPERIMENTAL direct OnTriggered call)
--   world.progress.hook.mark <AssetPath>    (directly add to WorldHooksTriggered)
--   world.progress.hook.reset <AssetPath>   (safe direct remove from WorldHooksTriggered)
--   world.resource.probe [reachSpec]        (placed UResourceRespawnComponent SaveGame state)
--   world.resource.set [reachSpec] <amount> (SetResourceAmount on placed resource)
--   world.resource.pause [reachSpec] <on|off>
--   world.resource.take [reachSpec]         (TakeResource on placed resource)
--   world.chest.probe [reachSpec]           (placed AWorldChest SaveGame state)
--   world.chest.state [reachSpec] <state>   (unopened|opened|emptied|0|1|2)
--   world.chest.respawn_disabled [reachSpec] <on|off>
--   world.spud.persist <reachSpec> <stableName>  (EXPERIMENTAL AddPersistentGlobalObjectWithName)
--   world.spud.unpersist <reachSpec>             (EXPERIMENTAL RemovePersistentGlobalObject)
--
-- Round 26 round A -- Generic uniform-schema write verbs. See
-- docs/MODS_CATALOG_METHODOLOGY.md section 5. These four verbs back every
-- editable row produced by the new uniform JSON catalog, replacing the
-- per-category writers (player.attr.set / player.comp.set) over time.
--   player.field.set        <pawn|world> <path> <value>
--   player.field.set_index  <pawn|world> <containerPath> <index> <value>
--   player.field.set_key    <pawn|world> <containerPath> <key>   <value>
--   player.field.call       <pawn|world> <path> [args...]
-- REMOVED (see NOTES/cheats-to-revisit.md):
--   player.damageable, player.ai.attacks, player.ai.movement
--   player.fly, player.ghost, player.walk
--   player.revive, player.health.max
--   player.swimspeed, player.movemode swim
--   player.interact (InteractionRanges is a TMap<enum,float> we can't edit cleanly)
--   player.potion.slots (MaxPotionSlots write round-trips but consume-potion
--                        overwrites the single active slot rather than appending;
--                        would need BP-level changes to actually expand the belt)
--   player.instantdraw (PreChargeUpDuration / ChargeUpDuration write cleanly but
--                       damage-vs-draw-time curve lives on the per-weapon
--                       PlayerRangedAttackData asset, not the component)
--   player.castmoving  (bShouldBlockMovement write cleanly but spell-cast montages
--                       carry Root Motion Enabled on the anim asset itself, which
--                       overrides the component flag)
--   player.alwayssprint, player.envimmunity, player.meleeassist, player.inputbuffer
--                      (round 8 component-field cheats; all four removed after writes
--                       landed but behaviour didn't change -- see cheats-to-revisit.md ??11.
--                       Re-attempt via the GE system, not component fields.)
--   player.unlock.corruptionshot (round 11; bCorruptionShotUnlockedSimProxy
--                                 write didn't survive server replication.
--                                 See cheats-to-revisit.md ??16.)
-- Round 12 rolled back entirely (see NOTES/cheats-to-revisit.md ??16):
--   player.spells.nomagiccost, player.spells.noutilcd, player.spells.unlockall
--   dev.* (UDominionCheatManager dom* wrappers -- every one was a no-op in
--          the shipping build; cheat-manager method bodies are stripped).
--   ui.tab <player|teleport|scan|settings>  (legacy "home" accepted as alias of player)

local function lazy_feature(module_name)
    local module = nil
    return setmetatable({}, {
        __index = function(_, key)
            if not module then
                module = require(module_name)
            end
            return module[key]
        end
    })
end

local router_navigation = lazy_feature("router_navigation")
local router_actor = lazy_feature("router_actor")
local router_player = lazy_feature("router_player")
local router_world = lazy_feature("router_world")
local router_camera = lazy_feature("router_camera")
local router_npc = lazy_feature("router_npc")
local router_probe = lazy_feature("router_probe")
local router_cvars = lazy_feature("router_cvars")
local router_ui = lazy_feature("router_ui")
local router_debug = lazy_feature("router_debug")
local router_build = lazy_feature("router_build")
local router_enemy_events = lazy_feature("router_enemy_events")

-- Round 30: when true the probe.* verbs print failure detail to the
-- UE4SS console (in addition to the ack going back to the WPF). Useful
-- for chasing "why is this chip not live" without having to hover the
-- WPF chip's tooltip. Set to false once the resolver is stable.
RSDWTOOLS_PROBE_DEBUG = true

local M = {}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.handle_line(raw_line)
    local line = trim(raw_line)
    if line == "" then
        return false, "empty command"
    end

    local ok, ok_cmd, msg = pcall(function() return M._dispatch(line) end)
    if not ok then
        return false, "router error : " .. tostring(ok_cmd)
    end
    return ok_cmd, msg
end

function M._dispatch(line)
    local handled_navigation, ok_navigation, navigation_result = router_navigation.try_handle(line)
    if handled_navigation then
        return ok_navigation, navigation_result
    end

    local handled_player, ok_player, player_result = router_player.try_handle(line)
    if handled_player then
        return ok_player, player_result
    end

    local handled_ui, ok_ui, ui_result = router_ui.try_handle(line)
    if handled_ui then
        return ok_ui, ui_result
    end

    local handled_probe, ok_probe, probe_result = router_probe.try_handle(line)
    if handled_probe then
        return ok_probe, probe_result
    end

    local handled_cvars, ok_cvars, cvars_result = router_cvars.try_handle(line)
    if handled_cvars then
        return ok_cvars, cvars_result
    end

    local handled_enemy_events, ok_enemy_events, enemy_events_result = router_enemy_events.try_handle(line)
    if handled_enemy_events then
        return ok_enemy_events, enemy_events_result
    end

    local handled_world, ok_world, world_result = router_world.try_handle(line)
    if handled_world then
        return ok_world, world_result
    end

    local handled_actor, ok_actor, actor_result = router_actor.try_handle(line)
    if handled_actor then
        return ok_actor, actor_result
    end

    local handled_npc, ok_npc, npc_result = router_npc.try_handle(line)
    if handled_npc then
        return ok_npc, npc_result
    end

    local handled_camera, ok_camera, camera_result = router_camera.try_handle(line, M.handle_line)
    if handled_camera then
        return ok_camera, camera_result
    end

    local handled_build, ok_build, build_result = router_build.try_handle(line)
    if handled_build then
        return ok_build, build_result
    end

    local handled_debug, ok_debug, debug_result = router_debug.try_handle(line)
    if handled_debug then
        return ok_debug, debug_result
    end

    return false, "unknown command"
end

return M
