param(
    # UE4SS's GenerateLuaTypes() output directory. When omitted we derive it
    # from $PSScriptRoot assuming this script is deployed at
    # <modRoot>\tools\Generate-Catalog.ps1 (which is what Sync-ModPayload.ps1
    # produces) ; the types live at <modRoot>\..\shared\types.
    # Override when running against a stashed snapshot or non-default layout.
    [string]$TypesDir = "",

    # Where to write the catalog. Default lands inside the live RSDWTools
    # mod's ipc/ folder so the WPF picks it up without further wiring.
    # When omitted, derived as <modRoot>\ipc\catalog from $PSScriptRoot.
    [string]$OutDir   = "",

    # When set, also write the legacy per-class JSON tree under <OutDir>\classes\
    # so users can grep individual files. Default off to keep the deploy lean.
    [switch]$EmitPerClass,

    # When set (default), emit only classes the runtime can reach via
    # `safe' roots: the engine singletons (pawn / controller / playerstate /
    # gamemode / gamestate / gameinstance / localplayer / hud / world /
    # worldsettings) and `subsystem:<X>'. Both are O(1) pointer fetches
    # from UEngine/UWorld with no GUObjectArray walk and no name-to-UClass
    # resolution, which is what made `find:<X>' the dominant crash vector
    # for bulk probes. A class qualifies as safe-reachable when its own
    # rootKind is singleton/subsystem OR the BFS produced at least one
    # reachPath into it (BFS only seeds from those roots, so any reachPath
    # is a chain that bottoms out at a safe root).
    #
    # Pass -SafeOnly:$false to emit the full catalog including classes
    # that have no static reach path and would only be probable via
    # `find:<X>'.
    [bool]$SafeOnly = $true,

    # (Round 32) Static type-shape blacklist. Any field whose ue_type
    # matches one of these regexes is forced to `writable=false` and
    # tagged with note="unsafe ue_type (static blacklist)". This is the
    # generator-side complement to feature_probe's runtime crash-log
    # skip: the runtime catches whatever AVs the static list misses, and
    # this list catches whatever shapes we KNOW have crashed before so we
    # don't even surface a Read button on those rows. Keep entries shape-
    # based (regex on ue_type), never name-based on the field itself --
    # field names crash because of WHO they belong to (offset drift),
    # not the name itself, so a name list would either over- or under-
    # block. Default seeds are types historically observed to AV during
    # raw property reads through UE4SS reflection.
    [string[]]$UnsafeUeTypePatterns = @(
        '^FPointerToUberGraphFrame$',
        '^FInstancedStruct$',
        '^FBlueprintFunctionReference$'
    )
)

# Generate-Catalog.ps1
# -------------------
# Parses UE4SS's "Generate Lua Types" EmmyLua dump into a single uniform
# catalog the WPF consumes directly. No live-game inspection, no curation,
# no per-subsystem config; every UClass with at least one field becomes a
# catalog entry.
#
# Output:
#   <OutDir>\catalog.jsonl   one JSON object per line, one line per class
#   <OutDir>\_meta.json      small summary (class count, bucket counts,
#                            generated timestamp, source path)
#   <OutDir>\classes\*.json  optional per-class breakout (-EmitPerClass)
#
# JSONL is chosen over a single JSON array because:
#   * Streaming parse (no need to load 60+ MB into memory at once).
#   * Append-friendly (future incremental rebuilds).
#   * Trivial to grep/inspect on disk without a JSON tool.
#
# This script replaces the per-system Lua dumpers under
# Mods\RSDWTools\Scripts\dumpers\*.lua. Those probes wrote one curated
# subsystem catalog at a time from the live UObject graph; this script
# emits everything from the schema in one shot, no game running required.

$ErrorActionPreference = "Stop"
$startTime = Get-Date

# Round 44: derive defaults from $PSScriptRoot when caller didn't pass them.
# After Sync-ModPayload.ps1 deploy, this script lives at
# <modRoot>\tools\Generate-Catalog.ps1, so:
#   <modRoot>           = Split-Path -Parent $PSScriptRoot
#   <modsRoot>          = Split-Path -Parent <modRoot>     (== ue4ss\Mods)
#   <typesDir default>  = <modsRoot>\shared\types
#   <outDir default>    = <modRoot>\ipc\catalog
# The EXE's "Generate Catalog" button always passes both args explicitly,
# so this only matters when someone runs the script standalone.
if ([string]::IsNullOrWhiteSpace($TypesDir) -or [string]::IsNullOrWhiteSpace($OutDir)) {
    $modRoot  = Split-Path -Parent $PSScriptRoot
    $modsRoot = Split-Path -Parent $modRoot
    if ([string]::IsNullOrWhiteSpace($TypesDir)) {
        $TypesDir = Join-Path $modsRoot "shared\types"
    }
    if ([string]::IsNullOrWhiteSpace($OutDir)) {
        $OutDir = Join-Path $modRoot "ipc\catalog"
    }
}

if (-not (Test-Path -LiteralPath $TypesDir)) {
    throw "Types dump not found: $TypesDir`nRun GenerateLuaTypes() in-game first (Lua verb: dump.types)."
}

# ----- Parser --------------------------------------------------------------

$classes = @{}
$enums   = @{}

$reClass = [regex]::new('^---@class\s+([A-Za-z0-9_]+)(?:\s*:\s*([A-Za-z0-9_]+))?\s*$')
$reField = [regex]::new('^---@field\s+(\S+)\s+(.+?)\s*$')
$reEnum  = [regex]::new('^---@enum\s+([A-Za-z0-9_]+)\s*$')
# Round 34: capture function declarations + their preceding ---@param /
# ---@return annotations so we can surface UFUNCTIONs as a "Call" row
# kind in the catalog browser. EmmyLua emits them as:
#   ---@param Foo int32
#   ---@param Bar boolean
#   ---@return float
#   function ClassName:MethodName(Foo, Bar) end
# The colon discriminates instance methods (the ones we can dispatch
# through reflection) from helpers ; we only catch the colon form.
$reFunc  = [regex]::new('^function\s+([A-Za-z0-9_]+):([A-Za-z0-9_]+)\s*\(([^)]*)\)\s*end\s*$')
$reParam = [regex]::new('^---@param\s+(\S+)\s+(.+?)\s*$')
$reRet   = [regex]::new('^---@return\s+(.+?)\s*$')

function Parse-File {
    param([string]$Path)
    $lines = Get-Content -LiteralPath $Path
    $currentClass = $null
    $currentEnum  = $null
    # Per-file accumulator for the @param / @return annotations that
    # precede the next `function` line. Cleared on every @class line so
    # leftover annotations from the previous block can't bleed in.
    $pendingParams = New-Object System.Collections.Generic.List[object]
    $pendingReturn = $null
    foreach ($line in $lines) {
        $m = $reClass.Match($line)
        if ($m.Success) {
            $currentClass = $m.Groups[1].Value
            $parent = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $null }
            if (-not $classes.ContainsKey($currentClass)) {
                $classes[$currentClass] = @{
                    parent  = $parent
                    fields  = [System.Collections.Generic.List[object]]::new()
                    methods = [System.Collections.Generic.List[object]]::new()
                }
            } elseif ($parent -and -not $classes[$currentClass].parent) {
                # Same class restated in a sibling file with parent info we
                # didn't have yet -- fill it in instead of clobbering.
                $classes[$currentClass].parent = $parent
            }
            # Defensive backfill for entries inserted before round 34.
            if (-not $classes[$currentClass].ContainsKey('methods')) {
                $classes[$currentClass].methods = [System.Collections.Generic.List[object]]::new()
            }
            $pendingParams = New-Object System.Collections.Generic.List[object]
            $pendingReturn = $null
            continue
        }
        $m = $reField.Match($line)
        if ($m.Success -and $currentClass) {
            $classes[$currentClass].fields.Add(@{
                name = $m.Groups[1].Value
                type = $m.Groups[2].Value
            })
            continue
        }
        $m = $reParam.Match($line)
        if ($m.Success) {
            $pendingParams.Add(@{
                name = $m.Groups[1].Value
                type = $m.Groups[2].Value
            })
            continue
        }
        $m = $reRet.Match($line)
        if ($m.Success) {
            $pendingReturn = $m.Groups[1].Value
            continue
        }
        $m = $reFunc.Match($line)
        if ($m.Success -and $currentClass) {
            # Match the EmmyLua "ClassName" the function was bound to
            # against the @class we are tracking. The dump uses the bare
            # `local UFooClass = {}` identifier, which is the SAME as the
            # @class name above ; mismatches mean the function belongs to
            # an unrelated synthetic table, skip those quietly.
            $boundTo = $m.Groups[1].Value
            if ($boundTo -ne $currentClass) {
                $pendingParams = New-Object System.Collections.Generic.List[object]
                $pendingReturn = $null
                continue
            }
            $methodName = $m.Groups[2].Value
            $rawArgs    = $m.Groups[3].Value.Trim()
            # Build a typed signature out of the @param annotations we
            # accumulated. Falls back to "untyped" for params with no
            # annotation so the row still shows the call shape.
            $sigParams = New-Object System.Collections.Generic.List[object]
            if ($rawArgs -ne '') {
                $argNames = $rawArgs -split '\s*,\s*'
                foreach ($n in $argNames) {
                    $typed = ($pendingParams | Where-Object { $_.name -eq $n } | Select-Object -First 1)
                    if ($typed) {
                        $sigParams.Add(@{ name = $typed.name; type = $typed.type })
                    } else {
                        $sigParams.Add(@{ name = $n; type = 'unknown' })
                    }
                }
            }
            $classes[$currentClass].methods.Add(@{
                name    = $methodName
                params  = $sigParams
                returns = $pendingReturn
            })
            $pendingParams = New-Object System.Collections.Generic.List[object]
            $pendingReturn = $null
            continue
        }
        $m = $reEnum.Match($line)
        if ($m.Success) {
            $currentEnum = $m.Groups[1].Value
            if (-not $enums.ContainsKey($currentEnum)) { $enums[$currentEnum] = $true }
            $pendingParams = New-Object System.Collections.Generic.List[object]
            $pendingReturn = $null
            continue
        }
        if ($currentEnum -and $line -match '^\s*}') { $currentEnum = $null }
    }
}

Write-Host "[catalog] Parsing $TypesDir ..."
$typeFiles = Get-ChildItem -LiteralPath $TypesDir -Filter "*.lua" -File -ErrorAction Stop
if ($typeFiles.Count -eq 0) {
    throw "No .lua files in $TypesDir. Did GenerateLuaTypes() run?"
}
foreach ($f in $typeFiles) { Parse-File -Path $f.FullName }
Write-Host "[catalog] Parsed $($typeFiles.Count) files; $($classes.Count) classes; $($enums.Count) enums."

# ----- Helpers -------------------------------------------------------------

# Strip leading U/A/F prefix to match the runtime "short name" the live
# write router uses. Falls back to stripping a trailing _C for blueprints.
function Get-ShortName {
    param([string]$ClassName)
    if ($ClassName -match '^[UAF]([A-Z].+)$') { return $matches[1] }
    if ($ClassName -match '^(.+)_C$')         { return $matches[1] }
    return $ClassName
}

# Walk parent chain via Get-Bucket below. Capped at 64 to avoid pathological
# cycles in malformed input.
function Walk-Chain {
    param([string]$ClassName)
    $out = New-Object System.Collections.Generic.List[string]
    $cursor = $ClassName
    $guard  = 0
    while ($cursor -and $classes.ContainsKey($cursor) -and $guard -lt 64) {
        $out.Add($cursor) | Out-Null
        $cursor = $classes[$cursor].parent
        $guard++
    }
    return ,$out
}

# Bucket assignment is parent-chain based, NOT name-based, so a Blueprint
# subclass of UActorComponent still lands in components/. The WPF can
# ignore buckets and search/filter however it likes; they exist purely
# to give the default tree view a sane top-level grouping.

# Centralized struct-shape predicate. Used by Get-Bucket, Classify-RootKind,
# Build-EdgeGraph (skip struct-typed UPROPERTYs as reach edges), and the
# emission loop (don't emit reachPaths for struct-shaped class names).
# Materializing a struct-typed UPROPERTY through UE4SS reflection routes
# through native data layout that has been observed to AV without a
# minidump (FRepAttachment, FRawCurveTracks, FMovementProperties, etc.).
# Shape-based, not a name deny list.
function Test-IsStructShape {
    param([string]$ClassName)
    if ($ClassName -match '^F[A-Z]') { return $true }
    if ($ClassName -match '^AnimNode_') { return $true }
    if ($ClassName -match '^MaterialExpression') { return $true }
    if ($ClassName -match '^MovieScene') { return $true }
    return $false
}

function Get-Bucket {
    param([string]$ClassName)
    foreach ($c in (Walk-Chain -ClassName $ClassName)) {
        switch ($c) {
            'UActorComponent'             { return 'components' }
            'USceneComponent'             { return 'components' }
            'AActor'                      { return 'actors' }
            'UGameInstanceSubsystem'      { return 'subsystems' }
            'UWorldSubsystem'             { return 'subsystems' }
            'ULocalPlayerSubsystem'       { return 'subsystems' }
            'UEngineSubsystem'            { return 'subsystems' }
            'USubsystem'                  { return 'subsystems' }
            'UDataAsset'                  { return 'data' }
            'UPrimaryDataAsset'           { return 'data' }
            'UDataTable'                  { return 'data' }
            'UGameplayEffect'             { return 'gameplay' }
            'UGameplayAbility'            { return 'gameplay' }
            'UAttributeSet'               { return 'gameplay' }
            'UDominionGameplayEffectData' { return 'gameplay' }
            'IInterface'                  { return 'interfaces' }
        }
    }
    if (Test-IsStructShape -ClassName $ClassName) { return 'structs' }
    return 'other'
}

# ---------------------------------------------------------------------------
# Root classification + reach-path inference (Round 30)
# ---------------------------------------------------------------------------
#
# Every class falls into one of these categories, based purely on its parent
# chain. The catalog records this so the UI never has to ask the user "is
# this a pawn-rooted thing or a world-rooted thing?" -- the dumper has
# already answered that question for every class in the game.
#
#   singleton   -- there is exactly one live instance of this class kind in
#                  a running game and a fixed engine API to fetch it
#                  (GetPlayerPawn, GetGameMode, etc.). The `spec` is the
#                  short root key (pawn, controller, gamemode, ...).
#   subsystem   -- USubsystem subclass; identity = class name. `spec` is
#                  "subsystem:<ShortName>".
#   component   -- UActorComponent / USceneComponent. Reachable from a
#                  singleton via a UPROPERTY chain ; not a root itself.
#   actor_multi -- AActor subclass not classified as singleton. Many can
#                  exist simultaneously ; needs a target picker, no static
#                  root spec. May still appear in reachPaths if some
#                  singleton holds a hard ref.
#   data        -- UDataAsset / UPrimaryDataAsset / UDataTable. Asset-style
#                  config objects ; usually loaded on demand.
#   gameplay    -- GAS / Dominion gameplay-effect data classes. Not runtime
#                  instances per se ; live ones are spawned via the GE system.
#   struct      -- UStruct / FName-prefixed types.
#   interface   -- IInterface-prefixed types.
#   other       -- everything that didn't match.
#
# `reachPaths` is a list of arrays, each starting with the rootSpec and
# followed by hard-ref UPROPERTY field names that walk to the class.
# Example for UHealthComponent reached from BP_PlayerCharacter_C via the
# `HealthComp` property: ["pawn", "HealthComp"]
# Multiple paths are kept (capped at 4) ; the runtime probe picks live ones.
function Classify-RootKind {
    param([string]$ClassName)
    $shortName = Get-ShortName -ClassName $ClassName
    foreach ($c in (Walk-Chain -ClassName $ClassName)) {
        switch ($c) {
            'AHUD'                       { return @{ kind='singleton'; spec='hud'           } }
            'APlayerController'          { return @{ kind='singleton'; spec='controller'    } }
            'APlayerState'               { return @{ kind='singleton'; spec='playerstate'   } }
            'AGameModeBase'              { return @{ kind='singleton'; spec='gamemode'      } }
            'AGameMode'                  { return @{ kind='singleton'; spec='gamemode'      } }
            'AGameStateBase'             { return @{ kind='singleton'; spec='gamestate'     } }
            'AGameState'                 { return @{ kind='singleton'; spec='gamestate'     } }
            'AWorldSettings'             { return @{ kind='singleton'; spec='worldsettings' } }
            'UGameInstance'              { return @{ kind='singleton'; spec='gameinstance'  } }
            'ULocalPlayer'               { return @{ kind='singleton'; spec='localplayer'   } }
            'UWorld'                     { return @{ kind='singleton'; spec='world'         } }
            'ACharacter'                 { return @{ kind='singleton'; spec='pawn'          } }
            'APawn'                      { return @{ kind='singleton'; spec='pawn'          } }
            'UEngineSubsystem'           { return @{ kind='subsystem';  spec="subsystem:$shortName" } }
            'UGameInstanceSubsystem'     { return @{ kind='subsystem';  spec="subsystem:$shortName" } }
            'UWorldSubsystem'            { return @{ kind='subsystem';  spec="subsystem:$shortName" } }
            'ULocalPlayerSubsystem'      { return @{ kind='subsystem';  spec="subsystem:$shortName" } }
            'UTickableWorldSubsystem'    { return @{ kind='subsystem';  spec="subsystem:$shortName" } }
            'USubsystem'                 { return @{ kind='subsystem';  spec="subsystem:$shortName" } }
            'UActorComponent'            { return @{ kind='component';   spec=$null } }
            'USceneComponent'            { return @{ kind='component';   spec=$null } }
            'UPrimaryDataAsset'          { return @{ kind='data';        spec=$null } }
            'UDataAsset'                 { return @{ kind='data';        spec=$null } }
            'UDataTable'                 { return @{ kind='data';        spec=$null } }
            'UGameplayEffect'            { return @{ kind='gameplay';    spec=$null } }
            'UGameplayAbility'           { return @{ kind='gameplay';    spec=$null } }
            'UAttributeSet'              { return @{ kind='gameplay';    spec=$null } }
            'AActor'                     { return @{ kind='actor_multi'; spec=$null } }
        }
    }
    if (Test-IsStructShape -ClassName $ClassName) { return @{ kind='struct';    spec=$null } }
    if ($ClassName -match '^I[A-Z]') { return @{ kind='interface'; spec=$null } }
    return @{ kind='other'; spec=$null }
}

# Builds a directed edge graph (ownerClass -> [(propName, targetClass)...])
# from every UPROPERTY whose declared ue_type is itself a known class.
# Wrapper containers (TArray/TMap/TWeakObjectPtr/TSubclassOf/...) are skipped
# on purpose: traversing them at runtime requires choosing an index/key, so
# they aren't usable as static reach steps. Hard refs are.
function Build-EdgeGraph {
    Write-Host "[catalog] Building reach-edge graph..."
    $edges = @{}
    $count = 0
    $skippedStruct = 0
    foreach ($className in $classes.Keys) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($f in (Get-ChainFields -ClassName $className)) {
            $t = $f.type
            # Strip optional pointer trailing star (some EmmyLua dumps include).
            if ($t.EndsWith('*')) { $t = $t.TrimEnd('*') }
            if ($classes.ContainsKey($t) -and $t -ne $className) {
                if (Test-IsStructShape -ClassName $t) { $skippedStruct++; continue }
                $list.Add(@{ name=$f.name; target=$t }) | Out-Null
                $count++
            }
        }
        if ($list.Count -gt 0) { $edges[$className] = $list }
    }
    Write-Host "[catalog] Edge graph: $count hard-ref edges across $($edges.Count) classes (skipped $skippedStruct struct edges)."
    return $edges
}

# Multi-source BFS from every (rootSpec, startClass) pair. Per-target cap
# of 4 reach paths keeps JSONL bloat bounded. Depth limit keeps runtime
# bounded ; 4 hops past the root covers every component-on-pawn,
# subsystem-holds-data, controller-has-state shape we actually need.
function Compute-ReachPaths {
    param($edges, $classifications, [int]$MaxDepth = 4, [int]$MaxPathsPerTarget = 4)
    Write-Host "[catalog] Running multi-source BFS for reach paths..."

    $reach = @{}
    $reachKeys = @{}
    foreach ($className in $classes.Keys) {
        $reach[$className] = New-Object System.Collections.Generic.List[object]
        # Per-target set of chain-string keys we've already recorded ; lets
        # the BFS reject duplicate paths (multiple pawn classes producing
        # the same "pawn -> HealthComp" chain) without inflating the cap.
        $reachKeys[$className] = @{}
    }

    # Seed the queue with one entry per root candidate. Each item:
    #   @{ cls = <className>; chain = [<rootSpec>, ...] }
    $queue = New-Object System.Collections.Generic.Queue[object]
    $rootCount = 0
    foreach ($className in $classes.Keys) {
        $cls = $classifications[$className]
        if ($cls.kind -eq 'singleton' -or $cls.kind -eq 'subsystem') {
            $queue.Enqueue(@{ cls = $className; chain = @($cls.spec) })
            $rootCount++
        }
    }
    Write-Host "[catalog] BFS seeded with $rootCount root candidates."

    $visits = 0
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        $cls   = $node.cls
        $chain = $node.chain
        $visits++

        # Record this chain as a reach path for the current class, unless
        # we've already hit the cap or seen the same chain. BFS pops in
        # insertion order so the paths recorded first are the globally
        # shortest, and dedupe-by-string keeps multi-pawn collisions out.
        $existing = $reach[$cls]
        $chainKey = $chain -join "`u{2192}"
        if ($existing.Count -lt $MaxPathsPerTarget -and -not $reachKeys[$cls].ContainsKey($chainKey)) {
            $chainCopy = [string[]]$chain
            [void]$existing.Add($chainCopy)
            $reachKeys[$cls][$chainKey] = $true
        }

        # Don't expand past depth limit. Chain length includes rootSpec, so
        # MaxDepth=4 means rootSpec + 4 hops.
        if (($chain.Count - 1) -ge $MaxDepth) { continue }

        $nbrs = $edges[$cls]
        if (-not $nbrs) { continue }
        foreach ($edge in $nbrs) {
            # Early exit: if the target is already saturated, no point pushing.
            if ($reach[$edge.target].Count -ge $MaxPathsPerTarget) { continue }
            $newChain = $chain + @($edge.name)
            $queue.Enqueue(@{ cls = $edge.target; chain = $newChain })
        }
    }
    Write-Host "[catalog] BFS complete: $visits visits."
    return $reach
}


# Pure syntactic mapping from a UE type string to a catalog (entryType,
# writable) tuple. Validated against live runtime output -- agreed on
# 95/95 writable flags and 92/95 type tags in the health POC. The 3
# mismatches were enum-as-int32 (correct) vs live's float reading (bug).
function Map-Type {
    param([string]$UeType)
    # (Round 32) Static blacklist applied first so a known-unsafe shape
    # always demotes to read-only with a clear note, regardless of how
    # the type would otherwise classify. Drives the WPF to render the
    # row without a Read button so the user can't trip the AV.
    foreach ($pat in $UnsafeUeTypePatterns) {
        if ($UeType -match $pat) {
            return @{ type='info'; writable=$false; unsafe=$true }
        }
    }
    switch -Regex ($UeType) {
        '^boolean$'                                              { return @{ type='bool';   writable=$true  } }
        '^(int8|int16|int32|int64|uint8|uint16|uint32|uint64)$'  { return @{ type='int32';  writable=$true  } }
        '^float$'                                                { return @{ type='float';  writable=$true  } }
        '^double$'                                               { return @{ type='double'; writable=$true  } }
        '^F(String|Name|Text)$'                                  { return @{ type='text';   writable=$true  } }
        '^TArray<.+>$'                                           { return @{ type='info';   writable=$false } }
        '^TMap<.+>$'                                             { return @{ type='info';   writable=$false } }
        '^TSet<.+>$'                                             { return @{ type='info';   writable=$false } }
        '^TSubclassOf<.+>$'                                      { return @{ type='info';   writable=$false } }
        '^TSoftObjectPtr<.+>$'                                   { return @{ type='info';   writable=$false } }
        '^TSoftClassPtr<.+>$'                                    { return @{ type='info';   writable=$false } }
        '^TWeakObjectPtr<.+>$'                                   { return @{ type='info';   writable=$false } }
        default {
            if ($enums.ContainsKey($UeType)) { return @{ type='int32'; writable=$true } }
            return @{ type='info'; writable=$false }
        }
    }
}

# Walk parent chain depth-first, accumulating fields with most-derived
# definitions winning on name collisions.
function Get-ChainFields {
    param([string]$ClassName)
    $stack = New-Object System.Collections.Generic.List[string]
    $cursor = $ClassName
    while ($cursor -and $classes.ContainsKey($cursor)) {
        $stack.Insert(0, $cursor)
        $cursor = $classes[$cursor].parent
    }
    $seen = @{}
    $out  = New-Object System.Collections.Generic.List[object]
    foreach ($c in $stack) {
        foreach ($f in $classes[$c].fields) {
            if (-not $seen.ContainsKey($f.name)) {
                $seen[$f.name] = $true
                $out.Add(@{ name=$f.name; type=$f.type; declared_in=$c })
            }
        }
    }
    return ,$out
}

# Round 34: same dedup walk for methods so a Blueprint subclass inherits
# its parent's UFUNCTIONs in the catalog. Most-derived definition wins
# on name collisions, matching the field policy.
function Get-ChainMethods {
    param([string]$ClassName)
    $stack = New-Object System.Collections.Generic.List[string]
    $cursor = $ClassName
    while ($cursor -and $classes.ContainsKey($cursor)) {
        $stack.Insert(0, $cursor)
        $cursor = $classes[$cursor].parent
    }
    $seen = @{}
    $out  = New-Object System.Collections.Generic.List[object]
    foreach ($c in $stack) {
        $methodList = $classes[$c].methods
        if (-not $methodList) { continue }
        foreach ($mm in $methodList) {
            if (-not $seen.ContainsKey($mm.name)) {
                $seen[$mm.name] = $true
                $out.Add(@{
                    name        = $mm.name
                    params      = $mm.params
                    returns     = $mm.returns
                    declared_in = $c
                })
            }
        }
    }
    return ,$out
}

# ----- Emit ----------------------------------------------------------------

# Wipe and recreate so deleted classes between runs don't linger.
if (Test-Path -LiteralPath $OutDir) {
    Remove-Item -LiteralPath $OutDir -Recurse -Force
}
$null = New-Item -ItemType Directory -Force -Path $OutDir

$jsonlPath = Join-Path $OutDir "catalog.jsonl"
$metaPath  = Join-Path $OutDir "_meta.json"

$bucketCounts = @{}
$emitted      = 0
$generated    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# ----- Round 30: classify every class + compute reach paths ----------------
# Precomputed once before the emit loop because reach computation walks the
# whole graph and we want the result available per-class at write time.
$classifications = @{}
foreach ($cn in $classes.Keys) {
    $classifications[$cn] = Classify-RootKind -ClassName $cn
}
$rootKindCounts = @{}
foreach ($cn in $classes.Keys) {
    $k = $classifications[$cn].kind
    if (-not $rootKindCounts.ContainsKey($k)) { $rootKindCounts[$k] = 0 }
    $rootKindCounts[$k]++
}
foreach ($k in ($rootKindCounts.Keys | Sort-Object)) {
    Write-Host ("[catalog] rootKind={0,-12} {1,6}" -f $k, $rootKindCounts[$k])
}

$edgeGraph  = Build-EdgeGraph
$reachPaths = Compute-ReachPaths -edges $edgeGraph -classifications $classifications

$writer = [System.IO.StreamWriter]::new($jsonlPath, $false, [System.Text.Encoding]::UTF8)
$skippedUnsafe = 0
$skippedNoWritable = 0
try {
    foreach ($className in ($classes.Keys | Sort-Object)) {
        $info    = $classes[$className]
        $fields  = Get-ChainFields  -ClassName $className
        $methods = Get-ChainMethods -ClassName $className
        if ($fields.Count -eq 0 -and $methods.Count -eq 0) { continue }   # skip empty interfaces / placeholders

        # SafeOnly gate: keep only classes the runtime can resolve via
        # singleton roots or subsystem:<X>. Anything else would have to
        # be probed via `find:<X>', which walks GUObjectArray and is the
        # dominant silent-crash vector. See the param block at the top of
        # this script for the rationale.
        if ($SafeOnly) {
            $kind = $classifications[$className].kind
            $rcount = 0
            if ($reachPaths.ContainsKey($className)) { $rcount = $reachPaths[$className].Count }
            if ($kind -ne 'singleton' -and $kind -ne 'subsystem' -and $rcount -eq 0) {
                $skippedUnsafe++
                continue
            }
        }

        $bucket = Get-Bucket -ClassName $className
        if (-not $bucketCounts.ContainsKey($bucket)) { $bucketCounts[$bucket] = 0 }
        $bucketCounts[$bucket]++

        $shortName = Get-ShortName -ClassName $className
        $entries   = New-Object System.Collections.Generic.List[object]
        $hasWritable = $false
        foreach ($f in $fields) {
            $mapped = Map-Type -UeType $f.type
            if ($mapped.writable) { $hasWritable = $true }
            $entry  = [ordered]@{
                path     = "$shortName.$($f.name)"
                type     = $mapped.type
                value    = $null
                writable = $mapped.writable
                label    = $f.name
                ue_type  = $f.type
            }
            if ($mapped.ContainsKey('unsafe') -and $mapped.unsafe) {
                $entry["note"] = "unsafe ue_type (static blacklist)"
            } elseif ($f.declared_in -ne $className) {
                $entry["note"] = "inherited from $($f.declared_in)"
            }
            $entries.Add($entry)
        }
        # Round 34: append callable methods as catalog entries too. They
        # use type="call" + writable=true so the C# row classifier picks
        # the Call template ; ue_type carries the human-readable
        # signature for the row's ToolTip.
        foreach ($mm in $methods) {
            $hasWritable = $true
            $sigParts = @()
            foreach ($p in $mm.params) { $sigParts += "$($p.name): $($p.type)" }
            $sig = '(' + ($sigParts -join ', ') + ')'
            if ($mm.returns) { $sig += " -> $($mm.returns)" }
            $callEntry = [ordered]@{
                path     = "$shortName.$($mm.name)"
                type     = 'call'
                value    = $null
                writable = $true
                label    = $mm.name
                ue_type  = $sig
                params   = @($mm.params | ForEach-Object { [ordered]@{ name = $_.name; type = $_.type } })
                returns  = $mm.returns
            }
            if ($mm.declared_in -ne $className) {
                $callEntry["note"] = "inherited from $($mm.declared_in)"
            }
            $entries.Add($callEntry)
        }

        # Skip classes whose entire field set is read-only / info-only.
        # Without a writable field there is nothing to cheat ; surfacing
        # them only adds noise to the class list. (Read-only inspection
        # is still possible via the Lua probe directly ; we just stop
        # advertising the class in the WPF catalog browser.)
        if (-not $hasWritable) {
            $skippedNoWritable++
            $bucketCounts[$bucket]--
            continue
        }

        # Materialize reachPaths into a plain array-of-arrays for clean JSON
        # output. The internal storage is a List[object] of string[] which
        # ConvertTo-Json sometimes mis-serializes ; copying through @() avoids
        # the issue and is cheap (4 entries max per class).
        $reachOut = @()
        foreach ($p in $reachPaths[$className]) {
            $reachOut += ,@($p)
        }

        $payload = [ordered]@{
            category   = $className
            short      = $shortName
            bucket     = $bucket
            parent     = $info.parent
            root       = "schema"
            source     = "static"
            rootKind   = $classifications[$className].kind
            rootSpec   = $classifications[$className].spec
            reachPaths = $reachOut
            groups     = @(
                [ordered]@{ name = $shortName; entries = $entries }
            )
        }

        # ConvertTo-Json -Compress flattens to one line which is exactly what
        # JSONL requires; no manual compaction needed.
        $writer.WriteLine(($payload | ConvertTo-Json -Depth 10 -Compress))
        $emitted++

        if ($EmitPerClass) {
            $classDir = Join-Path $OutDir "classes\$bucket"
            if (-not (Test-Path -LiteralPath $classDir)) {
                $null = New-Item -ItemType Directory -Force -Path $classDir
            }
            $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $classDir "$className.json") -Encoding UTF8
        }
    }
}
finally {
    $writer.Dispose()
}

# Meta sidecar -- small enough that the WPF can load it eagerly to populate
# the bucket filter / class count without touching the big JSONL until the
# user opens a class.
$meta = [ordered]@{
    generated         = $generated
    source_types_dir  = $TypesDir
    classes_total     = $classes.Count
    classes_emitted   = $emitted
    enums_total       = $enums.Count
    by_bucket         = $bucketCounts
    by_root_kind      = $rootKindCounts
    catalog_file      = "catalog.jsonl"
    schema_version    = 2
}
$meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metaPath -Encoding UTF8

$elapsed = (Get-Date) - $startTime
$jsonlSize = (Get-Item -LiteralPath $jsonlPath).Length
Write-Host ""
Write-Host "[catalog] Wrote $emitted classes -> $jsonlPath"
if ($SafeOnly) {
    Write-Host "[catalog] SafeOnly mode: skipped $skippedUnsafe classes with no singleton/subsystem reach."
}
Write-Host "[catalog] Skipped $skippedNoWritable classes with no writable fields."
foreach ($k in ($bucketCounts.Keys | Sort-Object)) {
    Write-Host ("            {0,-12} {1,6}" -f $k, $bucketCounts[$k])
}
Write-Host ("[catalog] Catalog size : {0:N1} MB" -f ($jsonlSize / 1MB))
Write-Host ("[catalog] Elapsed      : {0:N1}s" -f $elapsed.TotalSeconds)
