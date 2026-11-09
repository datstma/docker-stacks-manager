<#
.SYNOPSIS
    Docker Stack Manager: status and control for the Docker Compose stacks in a directory.

.DESCRIPTION
    The PowerShell edition of docker-stacks-manager, for Windows (Docker Desktop).
    Runs on Windows PowerShell 5.1 and PowerShell 7+.

    A stack is a directory holding compose.yaml, compose.yml, docker-compose.yaml or
    docker-compose.yml: the base directory itself and its direct subdirectories. The
    base directory is the current one unless -Dir or $env:DSM_DIR says otherwise.

.EXAMPLE
    dsm -Interactive
    Interactive TUI for the stacks in the current directory.

.EXAMPLE
    dsm -Dir C:\docker-stacks -Detailed
    Status of every stack in C:\docker-stacks, with CPU/memory, ports and images.

.LINK
    https://github.com/datstma/docker-stacks-manager
#>
param(
    # Interactive TUI (recommended)
    [Alias('I', 'tui')][switch]$Interactive,
    # Status with CPU/memory, ports and images
    [Alias('v')][switch]$Detailed,
    # Status with CPU/memory
    [Alias('s')][switch]$Stats,
    # Status with port mappings
    [Alias('p')][switch]$Ports,
    # Status with image versions
    [switch]$Images,
    # Redraw the status every 5 seconds
    [Alias('w')][switch]$Watch,
    # Networks and the containers on them
    [Alias('n')][switch]$Network,
    # Directory holding your stacks
    [Alias('d')][string]$Dir,
    # Update this script to the latest release
    [Alias('U')][switch]$Update,
    # Print the version
    [switch]$Version,
    # Show the help
    [Alias('h')][switch]$Help
)

$script:DsmVersion = '1.1.0'
$script:DsmRepo = 'datstma/docker-stacks-manager'
$script:ComposeFileNames = @('compose.yaml', 'compose.yml', 'docker-compose.yaml', 'docker-compose.yml')
$script:RefreshSecs = 5
if ($env:DSM_REFRESH -match '^\d+$' -and [int]$env:DSM_REFRESH -gt 0) { $script:RefreshSecs = [int]$env:DSM_REFRESH }

# ============================================================================
# Output helpers
# ============================================================================

function Set-DsmColors([bool]$Enabled) {
    $e = [char]27
    $names = 'cGreen', 'cRed', 'cYellow', 'cBlue', 'cCyan', 'cMagenta', 'cReset', 'cBold', 'cDim', 'cRev'
    $codes = "$e[0;32m", "$e[0;31m", "$e[1;33m", "$e[0;34m", "$e[0;36m", "$e[0;35m", "$e[0m", "$e[1m", "$e[2m", "$e[7m"
    for ($i = 0; $i -lt $names.Count; $i++) {
        if ($Enabled) { $v = $codes[$i] } else { $v = '' }
        Set-Variable -Scope Script -Name $names[$i] -Value $v
    }
}
Set-DsmColors (-not [Console]::IsOutputRedirected -and -not $env:NO_COLOR)

# Remove ANSI escape sequences (to measure or compare text)
function Remove-Ansi([string]$Text) {
    return ($Text -replace "$([char]27)\[[0-9;?]*[a-zA-Z]", '')
}

# ============================================================================
# Docker access
# ============================================================================

# Every docker call goes through here, so tests can replace docker. Returns
# stdout lines; stderr is discarded.
function Invoke-Docker {
    $flat = foreach ($a in $args) { $a }   # unroll array arguments (lists of IDs)
    & docker @flat 2>$null
}

# Same, with stderr merged in (docker logs writes to both)
function Invoke-DockerAll {
    $flat = foreach ($a in $args) { $a }
    & docker @flat 2>&1 | ForEach-Object { "$_" }
}

# Parse docker output where each line is a JSON array (from --format
# '[{{json .A}},{{json .B}}]'). Templates contain no double quotes on purpose:
# Windows PowerShell 5.1 does not escape them when calling native programs.
function ConvertFrom-JsonLines($Lines) {
    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { , (ConvertFrom-Json -InputObject $line) } catch { }
    }
}

# Elements of a JSON array (Windows PowerShell 5.1 returns the whole array as
# one object, PowerShell 7 enumerates it)
function ConvertFrom-JsonArray([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    try { $parsed = ConvertFrom-Json -InputObject $Text } catch { return }
    foreach ($item in $parsed) { $item }
}

function Test-Requirements {
    $missing = @()
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        $missing += 'docker'
    } elseif (-not (Invoke-Docker compose version)) {
        $missing += 'docker compose (v2 plugin)'
    }
    if ($missing.Count -gt 0) {
        [Console]::Error.WriteLine("Error: Missing required commands: $($missing -join ', ')")
        if ($missing -contains 'docker') {
            [Console]::Error.WriteLine('Install Docker Desktop: https://docs.docker.com/desktop/setup/install/windows-install/')
        }
        return $false
    }
    return $true
}

# ============================================================================
# Small utilities
# ============================================================================

# Docker timestamp ("2026-01-01T00:00:00.123456789Z") to DateTimeOffset, or
# $null for an empty or zero time
function ConvertFrom-DockerTime([string]$Text) {
    if ([string]::IsNullOrEmpty($Text) -or $Text.StartsWith('0001-01-01')) { return $null }
    # .NET parses at most 7 fractional digits; Docker gives 9
    $t = $Text -replace '(\.\d{1,7})\d*', '$1'
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($t, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

# Watchtower log time ("2026-11-09 04:00:00 +0100 CET") to DateTimeOffset
function ConvertFrom-WatchtowerTime([string]$Text) {
    if ($Text -match '^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) ([+-]\d{2})(\d{2})') {
        $iso = '{0}T{1}{2}:{3}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4]
        return [DateTimeOffset]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}

# 86400 -> 24h, 5400 -> 1h 30m, 300 -> 5m
function Format-Duration([long]$Seconds) {
    $h = [math]::Floor($Seconds / 3600); $m = [math]::Floor(($Seconds % 3600) / 60)
    if ($h -gt 0 -and $m -gt 0) { return "${h}h ${m}m" }
    if ($h -gt 0) { return "${h}h" }
    return "${m}m"
}

# Seconds of uptime -> "2d 3h", "4h 12m", "7m"
function Format-Uptime([double]$Seconds) {
    $Seconds = [math]::Floor($Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $d = [math]::Floor($Seconds / 86400)
    $h = [math]::Floor(($Seconds % 86400) / 3600)
    $m = [math]::Floor(($Seconds % 3600) / 60)
    if ($d -gt 0) { return "${d}d ${h}h" }
    if ($h -gt 0) { return "${h}h ${m}m" }
    return "${m}m"
}

# Compose's default project name for a directory: lowercase, only [a-z0-9_-]
function Get-ComposeProjectName([string]$Name) {
    return ($Name.ToLowerInvariant() -replace '[^a-z0-9_-]', '')
}

# Normalised path for comparisons: no trailing separator
function Get-NormalizedPath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $p = $Path.TrimEnd('\', '/')
    if ($p -eq '') { return $Path }
    return $p
}

# The value of a label (labels have dots in their names)
function Get-Label($Labels, [string]$Name) {
    if ($null -eq $Labels) { return $null }
    $prop = $Labels.PSObject.Properties[$Name]
    if ($prop) { return [string]$prop.Value }
    return $null
}

# ============================================================================
# Stack discovery
# ============================================================================

# One compose file per stack directory (the base directory and its direct
# subdirectories), sorted by path. With several in one directory, the one
# docker compose itself would pick wins.
function Find-ComposeFiles([string]$Base) {
    $dirs = @(Get-Item -LiteralPath $Base -Force -ErrorAction SilentlyContinue) +
        @(Get-ChildItem -LiteralPath $Base -Directory -Force -ErrorAction SilentlyContinue | Sort-Object FullName)
    foreach ($d in $dirs) {
        if ($null -eq $d) { continue }
        foreach ($n in $script:ComposeFileNames) {
            $f = Join-Path $d.FullName $n
            if (Test-Path -LiteralPath $f -PathType Leaf) { $f; break }
        }
    }
}

# ============================================================================
# Snapshot: everything the views need, from a handful of docker calls
# ============================================================================
#
# Get-Snapshot loads all stacks and their containers with two docker calls
# (ps and inspect; with -WithStats also docker stats, which takes ~2s).
#
# Containers are matched to stacks by Compose's working-directory label, or
# failing that by project name (stacks started from elsewhere, e.g. Dockge).
# Each container gets a Kind:
#   up    running
#   done  exited 0 with restart policy "no"/"on-failure": a finished one-shot job
#   down  anything else that isn't running (stopped, crashed, restarting, created)
# A stack is "stopped" when nothing is up, "partial" when something is down,
# "unhealthy" when all are up but a healthcheck fails, otherwise "running".

$script:Snap = $null

function Get-Snapshot([switch]$WithStats) {
    $stacks = New-Object System.Collections.Generic.List[object]
    $byDir = @{}; $byProject = @{}
    foreach ($file in @(Find-ComposeFiles $script:BaseDir)) {
        $dir = Split-Path -Parent $file
        $name = Split-Path -Leaf $dir
        $stack = [pscustomobject]@{
            Name = $name; Dir = $dir; Status = 'stopped'
            Ids = (New-Object System.Collections.Generic.List[string])
            Up = 0; Total = 0; Unhealthy = 0
        }
        $byDir[(Get-NormalizedPath $dir)] = $stacks.Count
        $byProject[(Get-ComposeProjectName $name)] = $stacks.Count
        $stacks.Add($stack)
    }

    $containers = @{}; $idByFull = @{}
    $statusById = @{}
    foreach ($row in @(ConvertFrom-JsonLines (Invoke-Docker ps -a --filter label=com.docker.compose.project --format '[{{json .ID}},{{json .Status}}]'))) {
        $statusById[[string]$row[0]] = [string]$row[1]
    }

    if ($statusById.Count -gt 0) {
        $format = '[{{json .Id}},{{json .Name}},{{json .Config.Labels}},{{json .Config.Image}},{{json .State}},' +
            '{{json .RestartCount}},{{json .HostConfig.NetworkMode}},{{json .HostConfig.RestartPolicy.Name}},' +
            '{{json .NetworkSettings.Ports}},{{json .NetworkSettings.Networks}}]'
        $rows = @(ConvertFrom-JsonLines (Invoke-Docker inspect --format $format @($statusById.Keys | Sort-Object)))
        foreach ($r in $rows) {
            $full = [string]$r[0]; $id = $full.Substring(0, [math]::Min(12, $full.Length))
            $labels = $r[2]
            $wdir = Get-NormalizedPath (Get-Label $labels 'com.docker.compose.project.working_dir')
            $project = Get-Label $labels 'com.docker.compose.project'
            $idx = $null
            if ($wdir -and $byDir.ContainsKey($wdir)) { $idx = $byDir[$wdir] }
            elseif ($project -and $byProject.ContainsKey($project)) { $idx = $byProject[$project] }
            if ($null -eq $idx) { continue }

            $state = $r[4]
            $status = [string]$statusById[$id]
            $health = ''
            if ($state.Health) { $health = [string]$state.Health.Status }
            if ($health -eq 'none') { $health = '' }
            $policy = [string]$r[7]

            if ($state.Status -eq 'running') { $kind = 'up' }
            elseif ($state.Status -eq 'exited' -and [int]$state.ExitCode -eq 0 -and
                    ($policy -eq '' -or $policy -eq 'no' -or $policy -eq 'on-failure')) { $kind = 'done' }
            else { $kind = 'down' }

            $portList = @()
            if ($r[8]) {
                foreach ($p in $r[8].PSObject.Properties) {
                    $bindings = @($p.Value)
                    if ($bindings.Count -gt 0 -and $null -ne $bindings[0]) {
                        $portList += '{0} -> {1}' -f $p.Name, $bindings[0].HostPort
                    }
                }
            }
            $nets = @()
            if ($r[9]) {
                foreach ($n in $r[9].PSObject.Properties) {
                    $nets += [pscustomobject]@{ Name = $n.Name; IP = [string]$n.Value.IPAddress }
                }
            }

            $started = $null
            if ($kind -eq 'up') { $started = ConvertFrom-DockerTime ([string]$state.StartedAt) }

            $containers[$id] = [pscustomobject]@{
                Id = $id; FullId = $full
                Service = Get-Label $labels 'com.docker.compose.service'
                Name = ([string]$r[1]).TrimStart('/')
                State = [string]$state.Status; Status = $status; Health = $health; Kind = $kind
                Started = $started; Restarts = [int]$r[5]
                Auto = ((Get-Label $labels 'com.centurylinklabs.watchtower.enable') -eq 'true')
                Image = [string]$r[3]; NetMode = [string]$r[6]
                Ports = ($portList -join ' '); Nets = $nets
                Cpu = ''; Mem = ''; Stack = $idx
            }
            $idByFull[$full] = $id
        }
    }

    if ($WithStats -and $containers.Count -gt 0) {
        foreach ($row in @(ConvertFrom-JsonLines (Invoke-Docker stats --no-stream --format '[{{json .ID}},{{json .CPUPerc}},{{json .MemUsage}}]'))) {
            $id = [string]$row[0]
            if ($containers.ContainsKey($id)) {
                $containers[$id].Cpu = [string]$row[1]
                $containers[$id].Mem = ([string]$row[2] -split ' / ')[0]
            }
        }
    }

    # Containers per stack, by service name
    foreach ($c in @($containers.Values | Sort-Object Service, Name)) {
        $stacks[$c.Stack].Ids.Add($c.Id)
    }
    foreach ($s in $stacks) {
        foreach ($id in $s.Ids) {
            $c = $containers[$id]
            if ($c.Kind -eq 'up') {
                $s.Up++; $s.Total++
                if ($c.Health -eq 'unhealthy') { $s.Unhealthy++ }
            } elseif ($c.Kind -eq 'down') {
                $s.Total++
            }
        }
        if ($s.Up -eq 0) { $s.Status = 'stopped' }
        elseif ($s.Up -lt $s.Total) { $s.Status = 'partial' }
        elseif ($s.Unhealthy -gt 0) { $s.Status = 'unhealthy' }
        else { $s.Status = 'running' }
    }

    $script:Snap = [pscustomobject]@{
        Stacks = $stacks; C = $containers; IdByFull = $idByFull
        Time = (Get-Date).ToString('HH:mm:ss')
    }
}

# Stack state for menus: "● 3/3 running", "◐ 2/3 running", "○ stopped"
function Get-StackBadge($Stack) {
    switch ($Stack.Status) {
        'running'   { return "${cGreen}●${cReset} $($Stack.Up)/$($Stack.Total) running" }
        'unhealthy' { return "${cYellow}●${cReset} $($Stack.Up)/$($Stack.Total) running ${cRed}· $($Stack.Unhealthy) unhealthy${cReset}" }
        'partial'   { return "${cYellow}◐${cReset} $($Stack.Up)/$($Stack.Total) running" }
        default     { return "${cRed}○${cReset} ${cDim}stopped${cReset}" }
    }
}

# Coloured state marker for a container
function Get-ContainerDot($C) {
    if ($C.Kind -eq 'up') {
        if ($C.Health -eq 'unhealthy') { return "${cRed}●${cReset}" }
        if ($C.Health -eq 'starting') { return "${cYellow}●${cReset}" }
        return "${cGreen}●${cReset}"
    }
    if ($C.Kind -eq 'done') { return "${cDim}✓${cReset}" }
    return "${cRed}●${cReset}"
}

# What a container is doing: uptime and badges if up, Docker's status otherwise
function Get-ContainerSummary($C, [DateTimeOffset]$Now = [DateTimeOffset]::Now) {
    if ($C.Kind -eq 'up') {
        $parts = @()
        if ($C.Started) { $parts += "${cDim}$(Format-Uptime ($Now - $C.Started).TotalSeconds)${cReset}" }
        if ($C.Health -eq 'unhealthy') { $parts += "${cRed}unhealthy${cReset}" }
        if ($C.Health -eq 'starting') { $parts += "${cYellow}starting${cReset}" }
        if ($C.Restarts -gt 0) { $parts += "${cYellow}↻$($C.Restarts)${cReset}" }
        if ($C.Auto) { $parts += "${cCyan}[auto]${cReset}" }
        return ($parts -join ' ')
    }
    if ($C.Kind -eq 'done') { return "${cDim}done ($($C.Status))${cReset}" }
    $text = $C.Status
    if (-not $text) { $text = $C.State }
    return "${cRed}${text}${cReset}"
}

# Name of the container whose network a container shares, if any
function Get-SharedNetworkHost($C) {
    if ($C.NetMode -like 'container:*') {
        $full = $C.NetMode.Substring(10)
        if ($script:Snap.IdByFull.ContainsKey($full)) { return $script:Snap.C[$script:Snap.IdByFull[$full]].Name }
        return $full.Substring(0, [math]::Min(12, $full.Length))
    }
    return ''
}

# ============================================================================
# Watchtower
# ============================================================================

# Resolve a container's TZ (IANA name) to a TimeZoneInfo. PowerShell 7 on
# Windows understands IANA names; Windows PowerShell 5.1 may not.
function Get-ContainerTimeZone([string]$Name) {
    if (-not $Name -or $Name -eq 'UTC' -or $Name -eq 'Etc/UTC') { return [TimeZoneInfo]::Utc }
    try { return [TimeZoneInfo]::FindSystemTimeZoneById($Name) } catch { }
    try {
        $winId = $null
        if ([TimeZoneInfo]::TryConvertIanaIdToWindowsId($Name, [ref]$winId)) {
            return [TimeZoneInfo]::FindSystemTimeZoneById($winId)
        }
    } catch { }
    return $null
}

# When Watchtower will next check for updates.
# 1. With WATCHTOWER_DEBUG, Watchtower logs "Scheduled next run: ..." after
#    each session; that is used when it's still in the future.
# 2. Otherwise it's derived from the settings:
#    WATCHTOWER_SCHEDULE      6-field cron (sec min hour dom month dow). Daily
#                             schedules are resolved in the container's TZ;
#                             anything else is shown as-is.
#    WATCHTOWER_POLL_INTERVAL seconds between runs (default 86400), counted
#                             from the "Scheduling first run" line at startup.
function Get-WatchtowerNextCheck([string]$Id, [string[]]$Logs, [DateTimeOffset]$Now = [DateTimeOffset]::Now) {
    $line = $null
    foreach ($l in $Logs) {
        if ($l -match 'Scheduled next run: (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4} [A-Za-z0-9+-]+)') { $line = $Matches[1] }
    }
    if ($line) {
        $when = ConvertFrom-WatchtowerTime $line
        if ($when -and $when -gt $Now) {
            $p = $line -split ' '
            return '{0} {1} {2}' -f $p[0], $p[1].Substring(0, 5), $p[3]
        }
    }

    $envList = @(ConvertFrom-JsonArray (@(Invoke-Docker inspect --format '{{json .Config.Env}}' $Id) -join ''))
    $schedule = ''; $interval = ''; $tzName = ''
    foreach ($e in $envList) {
        if ($e -like 'WATCHTOWER_SCHEDULE=*') { $schedule = $e.Substring(20).Trim('"', "'") }
        elseif ($e -like 'WATCHTOWER_POLL_INTERVAL=*') { $interval = $e.Substring(25) }
        elseif ($e -like 'TZ=*') { $tzName = $e.Substring(3) }
    }

    if ($schedule) {
        if ($schedule -eq '@daily' -or $schedule -eq '@midnight') { $schedule = '0 0 0 * * *' }
        $f = @($schedule -split '\s+')
        if ($f.Count -eq 6 -and $f[0] -match '^\d+$' -and $f[1] -match '^\d+$' -and $f[2] -match '^\d+$' -and
                $f[3] -match '^[*?]$' -and $f[4] -match '^[*?]$' -and $f[5] -match '^[*?]$') {
            $tz = Get-ContainerTimeZone $tzName
            $label = $tzName
            if (-not $label) { $label = 'UTC' }
            if ($null -eq $tz) { $tz = [TimeZoneInfo]::Local; $label = 'local time' }
            $local = [TimeZoneInfo]::ConvertTime($Now, $tz)
            $next = New-Object DateTime ($local.Year, $local.Month, $local.Day, [int]$f[2], [int]$f[1], [int]$f[0])
            if ($next -le $local.DateTime) { $next = $next.AddDays(1) }
            return '{0} {1} (daily)' -f $next.ToString('yyyy-MM-dd HH:mm'), $label
        }
        return "schedule: $schedule"
    }

    $secs = 86400
    if ($interval -match '^\d+$' -and [long]$interval -gt 0) { $secs = [long]$interval }
    $startup = $null
    foreach ($l in @(Invoke-DockerAll logs $Id)) {
        if ($l -match 'Scheduling first run: (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4} [A-Za-z0-9+-]+)') { $startup = $Matches[1] }
    }
    $first = $null
    if ($startup) { $first = ConvertFrom-WatchtowerTime $startup }
    if ($first) {
        $next = $first
        if ($next -le $Now) {
            $periods = [math]::Floor(($Now - $first).TotalSeconds / $secs) + 1
            $next = $first.AddSeconds($periods * $secs)
        }
        return '{0} (every {1})' -f $next.ToLocalTime().ToString('yyyy-MM-dd HH:mm'), (Format-Duration $secs)
    }
    return "every $(Format-Duration $secs)"
}

# Lines summarising Watchtower's most recent session: new images, recreated
# containers, and containers it couldn't check
function Get-WatchtowerLastSession([string[]]$Logs) {
    $session = New-Object System.Collections.Generic.List[string]
    $buf = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Logs) {
        $buf.Add($l)
        if ($l -match 'msg="Session done"') { $session = $buf; $buf = New-Object System.Collections.Generic.List[string] }
    }
    if ($session.Count -eq 0) { return }

    $doneLine = $session[$session.Count - 1]
    $when = 'unknown'; $scanned = '?'; $updated = '0'
    if ($doneLine -match 'time="(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})') { $when = "$($Matches[1]) $($Matches[2])" }
    if ($doneLine -match 'Scanned=(\d+)') { $scanned = $Matches[1] }
    if ($doneLine -match 'Updated=(\d+)') { $updated = $Matches[1] }

    $images = @(); $recreated = @(); $unreachable = @()
    foreach ($l in $session) {
        if ($l -match 'msg="Found new (\S+) image') { if ($images -notcontains $Matches[1]) { $images += $Matches[1] } }
        elseif ($l -match 'msg="Creating /([^"]+)"') { if ($recreated -notcontains $Matches[1]) { $recreated += $Matches[1] } }
        elseif ($l -match 'msg="Unable to update container \\"/([^\\]+)\\"') { if ($unreachable -notcontains $Matches[1]) { $unreachable += $Matches[1] } }
    }

    ''
    "  Last check: $when ${cDim}($scanned scanned, $updated updated)${cReset}"
    if ($images.Count -gt 0) {
        "    ${cGreen}✓${cReset} New images: $($images -join ', ')"
        if ($recreated.Count -gt 0) { "    ${cGreen}↻${cReset} Recreated: $($recreated -join ', ')" }
    } elseif ($unreachable.Count -eq 0) {
        "    ${cDim}No updates needed${cReset}"
    }
    if ($unreachable.Count -gt 0) {
        "    ${cYellow}⚠${cReset} Could not check: $($unreachable -join ', ') ${cDim}(see: docker logs watchtower)${cReset}"
    }
}

function Get-WatchtowerLines {
    $id = @(Invoke-Docker ps --filter name=watchtower --format '{{.ID}}') | Select-Object -First 1
    if (-not $id) {
        "${cYellow}⚠ Watchtower not running${cReset}"
        ''
        return
    }
    "${cBold}${cCyan}Watchtower:${cReset}"
    $startedRaw = @(Invoke-Docker inspect --format '{{json .State.StartedAt}}' $id) -join ''
    if ($startedRaw) {
        $started = ConvertFrom-DockerTime ($startedRaw.Trim('"'))
        if ($started) { "  Running for: $(Format-Uptime ([DateTimeOffset]::Now - $started).TotalSeconds)" }
    }
    # Recent logs only: with debug logging on, the full log can be many MB.
    # 8 days covers daily and weekly schedules.
    $logs = @(Invoke-DockerAll logs --since 192h $id)
    $next = Get-WatchtowerNextCheck $id $logs
    if ($next) { "  Next check: $next" }
    Get-WatchtowerLastSession $logs
    ''
}

# ============================================================================
# Non-interactive views
# ============================================================================

function Get-StatusLines {
    $showStats = $Stats -or $Detailed
    $showPorts = $Ports -or $Detailed
    $showImages = $Images -or $Detailed
    Get-Snapshot -WithStats:$showStats

    "${cBold}=== Docker Compose Stack Status ===${cReset}"
    "${cDim}$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))${cReset}"
    ''
    Get-WatchtowerLines

    $running = 0; $issues = 0; $stopped = 0; $cUp = 0; $cBad = 0; $cDown = 0
    $now = [DateTimeOffset]::Now
    foreach ($s in $script:Snap.Stacks) {
        $count = "$($s.Up) container"
        if ($s.Up -ne 1) { $count += 's' }
        switch ($s.Status) {
            'stopped' {
                $stopped++
                "${cRed}✗${cReset} ${cBold}$($s.Name)${cReset} ${cDim}(stopped)${cReset}"
                ''
                foreach ($id in $s.Ids) { if ($script:Snap.C[$id].Kind -eq 'down') { $cDown++ } }
                continue
            }
            'running' { $running++; "${cGreen}✓${cReset} ${cBold}$($s.Name)${cReset} ${cDim}($count)${cReset}" }
            'unhealthy' { $issues++; "${cYellow}⚠${cReset} ${cBold}$($s.Name)${cReset} ${cYellow}($($s.Unhealthy) unhealthy)${cReset} ${cDim}($count)${cReset}" }
            'partial' { $issues++; "${cYellow}⚠${cReset} ${cBold}$($s.Name)${cReset} ${cYellow}($($s.Up)/$($s.Total) running)${cReset}" }
        }
        if ($s.Status -eq 'stopped') { continue }

        for ($n = 0; $n -lt $s.Ids.Count; $n++) {
            $c = $script:Snap.C[$s.Ids[$n]]
            $tree = '├─'; $pipe = '│ '
            if ($n -eq $s.Ids.Count - 1) { $tree = '└─'; $pipe = '  ' }
            if ($c.Kind -eq 'up') { $cUp++; if ($c.Health -eq 'unhealthy') { $cBad++ } }
            elseif ($c.Kind -eq 'down') { $cDown++ }
            "  ${cDim}${tree}${cReset} $($c.Service) $(Get-ContainerDot $c) $(Get-ContainerSummary $c $now)"
            if ($showStats -and $c.Cpu) { "  ${cDim}${pipe} CPU: $($c.Cpu)  MEM: $($c.Mem)${cReset}" }
            if ($showPorts -and $c.Ports) { "  ${cDim}${pipe} Ports: $($c.Ports)${cReset}" }
            if ($showImages -and $c.Image) { "  ${cDim}${pipe} Image: $($c.Image)${cReset}" }
        }
        ''
    }

    "${cBold}=== Summary ===${cReset}"
    "Stacks: $($script:Snap.Stacks.Count) total, ${cGreen}$running running${cReset}, ${cYellow}$issues with issues${cReset}, ${cRed}$stopped stopped${cReset}"
    "Containers: ${cGreen}$cUp running${cReset}, ${cRed}$cBad unhealthy${cReset}, ${cRed}$cDown stopped${cReset}"

    if ($Detailed) {
        ''
        "${cBold}=== System Resources ===${cReset}"
        $df = @(ConvertFrom-JsonLines (Invoke-Docker system df --format '[{{json .Type}},{{json .Size}},{{json .Reclaimable}}]'))
        foreach ($row in $df) { '{0,-15} {1,-10} {2}' -f "$($row[0]):", $row[1], "${cDim}($($row[2]) reclaimable)${cReset}" }
        ''
        "${cBold}Top 5 volumes by size:${cReset}"
        $volumes = @(ConvertFrom-JsonArray (@(Invoke-Docker system df -v --format '{{json .Volumes}}') -join ''))
        $volumes | Where-Object { $_ } | ForEach-Object {
            $name = [string]$_.Name
            if ($name -match '^[0-9a-f]{64}$') { $name = $name.Substring(0, 12) }
            [pscustomobject]@{ Name = $name; Size = [string]$_.Size; Bytes = (ConvertFrom-Size $_.Size) }
        } | Sort-Object Bytes -Descending | Select-Object -First 5 | ForEach-Object {
            "  ${cDim}$($_.Size.PadRight(10)) $($_.Name)${cReset}"
        }
    }

    if ($issues -gt 0 -or $stopped -gt 0) {
        ''
        "${cYellow}Tip: Run with -Interactive for the TUI or -Detailed for more detail${cReset}"
    }
}

# "5.039MB" / "1.2GiB" / "88B" -> bytes
function ConvertFrom-Size([string]$Text) {
    if ($Text -notmatch '^\s*([\d.]+)\s*([a-zA-Z]*)') { return [double]0 }
    $num = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    $unit = $Matches[2]
    $binary = $unit -match '^.iB$'
    $power = 0
    switch ($unit.Substring(0, [math]::Min(1, $unit.Length)).ToUpperInvariant()) {
        'K' { $power = 1 } 'M' { $power = 2 } 'G' { $power = 3 } 'T' { $power = 4 }
    }
    if ($binary) { return $num * [math]::Pow(1024, $power) }
    return $num * [math]::Pow(1000, $power)
}

function Get-NetworkLines {
    Get-Snapshot
    "${cBold}=== Docker Network Visualization ===${cReset}"
    "${cDim}$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))${cReset}"
    "${cDim}Base directory: $($script:BaseDir)${cReset}"
    ''

    # Members of each network, in stack order
    $members = [ordered]@{}
    foreach ($s in $script:Snap.Stacks) {
        foreach ($id in $s.Ids) {
            $c = $script:Snap.C[$id]
            if ($c.Kind -ne 'up') { continue }
            if ($c.NetMode -like 'container:*') {
                $full = $c.NetMode.Substring(10)
                if (-not $script:Snap.IdByFull.ContainsKey($full)) { continue }
                $hostC = $script:Snap.C[$script:Snap.IdByFull[$full]]
                foreach ($net in $hostC.Nets) {
                    if (-not $members.Contains($net.Name)) { $members[$net.Name] = New-Object System.Collections.Generic.List[object] }
                    $members[$net.Name].Add([pscustomobject]@{ C = $c; IP = ''; Via = $hostC.Name })
                }
                continue
            }
            foreach ($net in $c.Nets) {
                if (-not $members.Contains($net.Name)) { $members[$net.Name] = New-Object System.Collections.Generic.List[object] }
                $members[$net.Name].Add([pscustomobject]@{ C = $c; IP = $net.IP; Via = '' })
            }
        }
    }

    if ($members.Count -eq 0) {
        "${cYellow}No networks found for stacks in $($script:BaseDir)${cReset}"
        return
    }

    # Driver and subnet of every network, in one call
    $info = @{}
    foreach ($row in @(ConvertFrom-JsonLines (Invoke-Docker network inspect --format '[{{json .Name}},{{json .Driver}},{{json .IPAM.Config}}]' @($members.Keys)))) {
        $subnets = @($row[2] | Where-Object { $_ } | ForEach-Object { $_.Subnet }) -join ''
        $info[[string]$row[0]] = [pscustomobject]@{ Driver = [string]$row[1]; Subnet = $subnets }
    }

    $system = @('bridge', 'host', 'none')
    $custom = @($members.Keys | Where-Object { $system -notcontains $_ })
    $builtin = @($members.Keys | Where-Object { $system -contains $_ })
    $unique = @{}
    foreach ($net in ($custom + $builtin)) {
        $driver = ''; $subnet = ''
        if ($info.ContainsKey($net)) { $driver = $info[$net].Driver; $subnet = $info[$net].Subnet }
        $icon = '🌐'; $color = $cCyan
        switch ($driver) {
            'bridge' { $icon = '🔗' }
            'host' { $icon = '🏠'; $color = $cMagenta }
            'overlay' { $icon = '☁️' }
            'macvlan' { $icon = '🔌' }
        }
        "${color}${cBold}$icon $net${cReset}"
        "  ${cDim}Driver: $driver${cReset}"
        if ($subnet) { "  ${cDim}Subnet: $subnet${cReset}" }
        "  ${cDim}Containers:${cReset}"
        $list = $members[$net]
        for ($i = 0; $i -lt $list.Count; $i++) {
            $m = $list[$i]
            $unique[$m.C.Id] = 1
            $tree = '├─'
            if ($i -eq $list.Count - 1) { $tree = '└─' }
            $line = "  ${cDim}$tree${cReset} $(Get-ContainerDot $m.C) $($m.C.Name)"
            if ($m.Via) { $line += " ${cYellow}→ via $($m.Via)${cReset}" }
            elseif ($m.IP) { $line += " ${cDim}($($m.IP))${cReset}" }
            $line += " ${cBlue}[$($script:Snap.Stacks[$m.C.Stack].Name)]${cReset}"
            $line
        }
        ''
    }

    "${cBold}=== Network Summary ===${cReset}"
    "Networks: $($members.Count) total ($($custom.Count) custom, $($builtin.Count) system)"
    "Containers: $($unique.Count) connected to networks"
    ''
    "${cDim}Legend: 🔗 bridge  🏠 host  ☁️ overlay  🔌 macvlan  🌐 other${cReset}"
    "${cDim}Containers on the same network can communicate directly${cReset}"
}

# ============================================================================
# Terminal UI helpers
# ============================================================================

$script:TuiActive = $false

function Start-Tui {
    $e = [char]27
    [Console]::Write("$e[?1049h$e[?25l")
    $script:TuiActive = $true
    # Ctrl+C arrives as a key instead of stopping the script
    [Console]::TreatControlCAsInput = $true
}

function Stop-Tui {
    if ($script:TuiActive) {
        $e = [char]27
        [Console]::Write("$e[?25h$e[?1049l")
        $script:TuiActive = $false
        try { [Console]::TreatControlCAsInput = $false } catch { }
    }
}

function Get-TuiRows {
    try { $h = [Console]::WindowHeight } catch { $h = 24 }
    if ($h -lt 5) { $h = 24 }
    return $h
}

# Draw a frame over the previous one without clearing the screen first, so
# nothing flickers
function Write-Frame([string[]]$Lines) {
    $e = [char]27
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$e[H$e[?25l")
    foreach ($l in $Lines) { [void]$sb.Append($l).Append("$e[K`n") }
    [void]$sb.Append("$e[J")
    [Console]::Write($sb.ToString())
}

# Start a full-screen sub-view: clear and show the cursor
function Start-View {
    $e = [char]27
    [Console]::Write("$e[H$e[2J$e[?25h")
}

function Write-Line([string]$Text = '') { [Console]::WriteLine($Text) }

function Test-CtrlC($Key) {
    return (($Key.Modifiers -band [ConsoleModifiers]::Control) -and $Key.Key -eq [ConsoleKey]::C)
}

function Wait-AnyKey([string]$Message = 'Press any key to continue...') {
    [Console]::Write("${cDim}$Message${cReset}")
    [void][Console]::ReadKey($true)
    Write-Line
}

# Ask a yes/no question with one keypress; only y/Y confirms
function Confirm-Action([string]$Question) {
    [Console]::Write("${cYellow}$Question (y/N)${cReset} ")
    $k = [Console]::ReadKey($true)
    Write-Line
    return ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y')
}

# Read one key for a menu: up, down, enter, esc, backspace, quit (Ctrl+C), a
# character, or refresh (no key within RefreshSecs)
function Read-MenuKey {
    $deadline = [DateTime]::UtcNow.AddSeconds($script:RefreshSecs)
    while (-not [Console]::KeyAvailable) {
        if ([DateTime]::UtcNow -ge $deadline) { return 'refresh' }
        Start-Sleep -Milliseconds 40
    }
    $k = [Console]::ReadKey($true)
    if (Test-CtrlC $k) { return 'quit' }
    switch ($k.Key) {
        'UpArrow' { return 'up' }
        'DownArrow' { return 'down' }
        'Enter' { return 'enter' }
        'Escape' { return 'esc' }
        'Backspace' { return 'backspace' }
    }
    $ch = [string]$k.KeyChar
    if ($ch -ceq 'k') { return 'up' }
    if ($ch -ceq 'j') { return 'down' }
    return $ch
}

# Quote one argument for a Windows command line
function ConvertTo-ArgString([string[]]$Arguments) {
    $quoted = foreach ($a in $Arguments) {
        if ($a -eq '') { '""' }
        elseif ($a -notmatch '[\s"]') { $a }
        else { '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }
    return ($quoted -join ' ')
}

function Get-DockerExe {
    $cmd = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return 'docker'
}

# Run docker attached to the console. With -Live, q, Esc or Ctrl+C stops it
# and returns to the menu; otherwise wait for it to finish (interactive shells).
function Invoke-DockerAttached([string[]]$Arguments, [string]$WorkDir = '', [switch]$Live) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-DockerExe
    $psi.Arguments = ConvertTo-ArgString $Arguments
    $psi.UseShellExecute = $false
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    try { $p = [System.Diagnostics.Process]::Start($psi) } catch { Write-Line "${cRed}Could not run docker: $_${cReset}"; return 1 }
    if ($Live) {
        while (-not $p.HasExited) {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ((Test-CtrlC $k) -or $k.Key -eq 'Escape' -or $k.KeyChar -eq 'q') {
                    try { $p.Kill() } catch { }
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        }
    }
    $p.WaitForExit()
    return $p.ExitCode
}

# Run a docker command (output straight to the console) and wait for it
function Invoke-DockerVisible([string[]]$Arguments, [string]$WorkDir = '') {
    [void](Invoke-DockerAttached $Arguments $WorkDir)
}

# ============================================================================
# Interactive menus
# ============================================================================

function Get-StackIndex([string]$Dir) {
    for ($i = 0; $i -lt $script:Snap.Stacks.Count; $i++) {
        if ($script:Snap.Stacks[$i].Dir -eq $Dir) { return $i }
    }
    return -1
}

function Show-StackMenu {
    $selected = 0; $top = 0; $filter = ''; $editing = $false
    while ($true) {
        $stacks = $script:Snap.Stacks
        $view = @()
        for ($i = 0; $i -lt $stacks.Count; $i++) {
            if (-not $filter -or $stacks[$i].Name.ToLowerInvariant().Contains($filter.ToLowerInvariant())) { $view += $i }
        }
        if ($selected -ge $view.Count) { $selected = $view.Count - 1 }
        if ($selected -lt 0) { $selected = 0 }

        $rows = Get-TuiRows
        $frame = New-Object System.Collections.Generic.List[string]
        $frame.Add("${cBold}Docker Stack Manager${cReset}  ${cDim}$($script:BaseDir) · updated $($script:Snap.Time)${cReset}")
        if ($editing) {
            $frame.Add("${cYellow}Filter: $filter${cReset}${cRev} ${cReset} ${cDim}($($view.Count) of $($stacks.Count) · Enter keep · Esc clear)${cReset}")
        } elseif ($filter) {
            $frame.Add("${cYellow}Filter: $filter${cReset} ${cDim}($($view.Count) of $($stacks.Count) · / change · Esc clear)${cReset}")
        } else {
            $frame.Add('')
        }
        $avail = $rows - $frame.Count - 4
        if ($avail -lt 3) { $avail = 3 }
        if ($selected -lt $top) { $top = $selected }
        if ($selected -ge $top + $avail) { $top = $selected - $avail + 1 }
        if ($top -gt 0 -and $top + $avail -gt $view.Count) { $top = [math]::Max(0, $view.Count - $avail) }

        $w = 4
        foreach ($i in $view) { if ($stacks[$i].Name.Length -gt $w) { $w = $stacks[$i].Name.Length } }
        for ($n = $top; $n -lt $view.Count -and $n -lt $top + $avail; $n++) {
            $s = $stacks[$view[$n]]
            $name = $s.Name.PadRight($w)
            $badge = Get-StackBadge $s
            if ($n -eq $selected) { $frame.Add("${cRev}> $name ${cReset}  $badge") }
            else { $frame.Add("  $name   $badge") }
        }
        if ($view.Count -eq 0) { $frame.Add("  ${cDim}(no stacks match)${cReset}") }
        if ($top + $avail -lt $view.Count) { $frame.Add("  ${cDim}↓ $($view.Count - $top - $avail) more${cReset}") }
        $frame.Add('')
        $frame.Add("${cCyan}[L]ogs [R]estart [S]top [U]p [D]own [N]etwork [T]raffic${cReset}")
        $frame.Add("${cDim}↑/↓ j/k move · Enter containers · / filter · q quit · refreshes every $($script:RefreshSecs)s${cReset}")
        Write-Frame $frame.ToArray()

        $key = Read-MenuKey
        if ($editing) {
            # Typing a filter: the list narrows as you type
            switch ($key) {
                'quit' { return }
                'refresh' { Get-Snapshot }
                'enter' { $editing = $false }
                'esc' { $editing = $false; $filter = '' }
                'backspace' { if ($filter.Length -gt 0) { $filter = $filter.Substring(0, $filter.Length - 1) } }
                'up' { if ($view.Count -gt 0) { $selected = ($selected - 1 + $view.Count) % $view.Count } }
                'down' { if ($view.Count -gt 0) { $selected = ($selected + 1) % $view.Count } }
                default { if ($key.Length -eq 1 -and -not [char]::IsControl($key[0])) { $filter += $key; $selected = 0; $top = 0 } }
            }
            continue
        }
        $sel = $null
        if ($view.Count -gt 0) { $sel = $stacks[$view[$selected]] }
        switch -CaseSensitive ($key) {
            { $_ -eq 'quit' -or $_ -eq 'q' -or $_ -eq 'Q' } { return }
            'refresh' { Get-Snapshot }
            'up' { if ($view.Count -gt 0) { $selected = ($selected - 1 + $view.Count) % $view.Count } }
            'down' { if ($view.Count -gt 0) { $selected = ($selected + 1) % $view.Count } }
            'esc' { $filter = ''; $selected = 0; $top = 0 }
            '/' { $editing = $true; $selected = 0; $top = 0 }
        }
        if ($null -eq $sel) { continue }
        switch ($key) {
            'l' { Show-StackLogs $sel }
            'r' { Invoke-StackAction $sel 'restart'; Get-Snapshot }
            's' { Invoke-StackAction $sel 'stop'; Get-Snapshot }
            'u' { Invoke-StackAction $sel 'up'; Get-Snapshot }
            'd' { Invoke-StackAction $sel 'down'; Get-Snapshot }
            'n' { Show-AllNetworks }
            't' { Show-Traffic; Get-Snapshot }
            'enter' { Show-ContainerMenu $sel.Dir; Get-Snapshot }
        }
    }
}

function Show-ContainerMenu([string]$StackDir) {
    $selected = 0
    while ($true) {
        $si = Get-StackIndex $StackDir
        if ($si -lt 0) { return }
        $s = $script:Snap.Stacks[$si]
        $ids = @($s.Ids)
        if ($ids.Count -eq 0) {
            Start-View
            Write-Line "${cBold}=== $($s.Name) ===${cReset}"
            Write-Line
            Write-Line "${cYellow}⚠ This stack has no containers${cReset}"
            Write-Line
            Write-Line "${cDim}It has never been started, or was removed with [D]own.${cReset}"
            Write-Line "${cDim}Start it from the stack menu with [U]p.${cReset}"
            Write-Line
            Wait-AnyKey
            return
        }
        if ($selected -ge $ids.Count) { $selected = $ids.Count - 1 }

        $now = [DateTimeOffset]::Now
        $frame = New-Object System.Collections.Generic.List[string]
        $frame.Add("${cBold}$($s.Name)${cReset}  $(Get-StackBadge $s)  ${cDim}$StackDir · updated $($script:Snap.Time)${cReset}")
        $frame.Add('')
        $w = 4
        foreach ($id in $ids) { $l = ([string]$script:Snap.C[$id].Service).Length; if ($l -gt $w) { $w = $l } }
        for ($n = 0; $n -lt $ids.Count; $n++) {
            $c = $script:Snap.C[$ids[$n]]
            $name = ([string]$c.Service).PadRight($w)
            $dot = Get-ContainerDot $c
            $summary = Get-ContainerSummary $c $now
            if ($n -eq $selected) {
                $frame.Add("${cRev}> $name ${cReset} $dot $summary")
                $frame.Add("    ${cDim}Container: $($c.Name) ($($c.Id))${cReset}")
                $frame.Add("    ${cDim}Image:     $($c.Image)${cReset}")
                $via = Get-SharedNetworkHost $c
                if ($via) {
                    $frame.Add("    ${cDim}Network:   via $via${cReset}")
                } elseif ($c.Nets.Count -gt 0) {
                    $text = @($c.Nets | ForEach-Object { if ($_.IP) { "$($_.Name) ($($_.IP))" } else { $_.Name } }) -join ', '
                    $frame.Add("    ${cDim}Networks:  $text${cReset}")
                }
                if ($c.Ports) { $frame.Add("    ${cDim}Ports:     $($c.Ports)${cReset}") }
            } else {
                $frame.Add("  $name  $dot $summary")
            }
        }
        $frame.Add('')
        $frame.Add("${cCyan}[L]ogs [R]estart [S]top [T]op [N]etwork [F]low${cReset}")
        $frame.Add("${cDim}↑/↓ j/k move · Enter more actions · q back · refreshes every $($script:RefreshSecs)s${cReset}")
        Write-Frame $frame.ToArray()

        $key = Read-MenuKey
        $c = $script:Snap.C[$ids[$selected]]
        switch -CaseSensitive ($key) {
            { $_ -in 'quit', 'q', 'Q', 'esc' } { return }
            'refresh' { Get-Snapshot }
            'up' { $selected = ($selected - 1 + $ids.Count) % $ids.Count }
            'down' { $selected = ($selected + 1) % $ids.Count }
        }
        switch ($key) {
            'l' { Show-ContainerLogs $c -Follow }
            'r' { Invoke-ServiceAction $StackDir $c.Service 'restart'; Get-Snapshot }
            's' { Invoke-ServiceAction $StackDir $c.Service 'stop'; Get-Snapshot }
            't' { Show-ContainerTop $c }
            'n' { Show-ContainerNetwork $c }
            'f' { Show-ContainerStats $c }
            'enter' { Show-ContainerActions $StackDir $c; Get-Snapshot }
        }
    }
}

function Show-ContainerActions([string]$StackDir, $C) {
    while ($true) {
        Start-View
        Write-Line "${cBold}=== Actions: $($C.Service) ===${cReset}"
        Write-Line
        Write-Line "1. View logs (live) ${cDim}[q to stop]${cReset}"
        Write-Line '2. View logs (last 100 lines)'
        Write-Line '3. Restart container'
        Write-Line '4. Stop container'
        Write-Line '5. Start container'
        Write-Line "6. Execute shell (bash) ${cDim}['exit' to leave]${cReset}"
        Write-Line "7. Execute shell (sh) ${cDim}['exit' to leave]${cReset}"
        Write-Line '8. View top processes'
        Write-Line "9. View stats (live) ${cDim}[q to stop]${cReset}"
        Write-Line 'n. View network/ports'
        Write-Line 'q. Back'
        Write-Line
        $k = [Console]::ReadKey($true)
        if (Test-CtrlC $k) { return }
        switch ([string]$k.KeyChar) {
            '1' { Show-ContainerLogs $C -Follow }
            '2' { Show-ContainerLogs $C }
            '3' { Invoke-ServiceAction $StackDir $C.Service 'restart' }
            '4' { Invoke-ServiceAction $StackDir $C.Service 'stop' }
            '5' { Invoke-ServiceAction $StackDir $C.Service 'start' }
            '6' { Enter-ContainerShell $C 'bash' }
            '7' { Enter-ContainerShell $C 'sh' }
            '8' { Show-ContainerTop $C }
            '9' { Show-ContainerStats $C }
            'n' { Show-ContainerNetwork $C }
            'q' { return }
        }
        if ($k.Key -eq 'Escape') { return }
    }
}

# ============================================================================
# Stack and container operations
# ============================================================================

function Show-StackLogs($Stack) {
    Start-View
    Write-Line "${cBold}${cCyan}=== Live Logs: $($Stack.Name) ===${cReset}"
    Write-Line "${cYellow}Press q, Esc or Ctrl+C to stop following logs${cReset}"
    Write-Line
    [void](Invoke-DockerAttached @('compose', 'logs', '-f', '--tail=100') $Stack.Dir -Live)
    Write-Line
    Write-Line "${cDim}Log streaming ended${cReset}"
    Wait-AnyKey
}

# restart / stop / up / down for a whole stack
function Invoke-StackAction($Stack, [string]$Action) {
    Start-View
    switch ($Action) {
        'restart' { if (-not (Confirm-Action "Restart all containers in $($Stack.Name)?")) { return }; Write-Line "${cYellow}Restarting stack: $($Stack.Name)${cReset}" }
        'stop' { if (-not (Confirm-Action "Stop all containers in $($Stack.Name)?")) { return }; Write-Line "${cRed}Stopping stack: $($Stack.Name)${cReset}" }
        'up' { Write-Line "${cGreen}Starting stack: $($Stack.Name)${cReset}" }
        'down' {
            Write-Line "${cRed}WARNING: This will stop and remove the containers of $($Stack.Name)!${cReset}"
            if (-not (Confirm-Action 'Run docker compose down?')) { return }
        }
    }
    Write-Line
    $dockerArgs = @('compose', $Action)
    if ($Action -eq 'up') { $dockerArgs += '-d' }
    Invoke-DockerVisible $dockerArgs $Stack.Dir
    Write-Line
    Write-Line "${cGreen}Done!${cReset}"
    Wait-AnyKey
}

# restart / stop / start for one service of a stack
function Invoke-ServiceAction([string]$StackDir, [string]$Service, [string]$Action) {
    Start-View
    switch ($Action) {
        'restart' { if (-not (Confirm-Action "Restart $Service?")) { return }; Write-Line "${cYellow}Restarting $Service...${cReset}" }
        'stop' { if (-not (Confirm-Action "Stop $Service?")) { return }; Write-Line "${cRed}Stopping $Service...${cReset}" }
        'start' { Write-Line "${cGreen}Starting $Service...${cReset}" }
    }
    Write-Line
    Invoke-DockerVisible @('compose', $Action, $Service) $StackDir
    Write-Line
    Write-Line "${cGreen}Done!${cReset}"
    Wait-AnyKey
}

function Show-ContainerLogs($C, [switch]$Follow) {
    Start-View
    if ($Follow) {
        Write-Line "${cBold}${cCyan}=== Live Logs: $($C.Service) ===${cReset}"
        Write-Line "${cYellow}Press q, Esc or Ctrl+C to stop following logs${cReset}"
        Write-Line
        [void](Invoke-DockerAttached @('logs', '-f', '--tail=100', $C.Id) -Live)
        Write-Line
        Write-Line "${cDim}Log streaming ended${cReset}"
    } else {
        Write-Line "${cBold}${cCyan}=== Last 100 Lines: $($C.Service) ===${cReset}"
        Write-Line
        Invoke-DockerVisible @('logs', '--tail=100', $C.Id)
    }
    Wait-AnyKey
}

function Show-ContainerTop($C) {
    Start-View
    Write-Line "${cBold}${cCyan}=== Process List: $($C.Service) ===${cReset}"
    Write-Line
    Invoke-DockerVisible @('top', $C.Id)
    Write-Line
    Write-Line "${cDim}Snapshot taken${cReset}"
    Wait-AnyKey
}

function Show-ContainerStats($C) {
    Start-View
    Write-Line "${cBold}${cCyan}=== Live Stats: $($C.Service) ===${cReset}"
    Write-Line "${cYellow}Press q, Esc or Ctrl+C to stop monitoring${cReset}"
    Write-Line
    [void](Invoke-DockerAttached @('stats', $C.Id, '--format', "table {{.Name}}`t{{.CPUPerc}}`t{{.MemUsage}}`t{{.NetIO}}`t{{.BlockIO}}") -Live)
    Write-Line
    Write-Line "${cDim}Monitoring stopped${cReset}"
    Wait-AnyKey
}

function Enter-ContainerShell($C, [string]$Shell) {
    Start-View
    Write-Line "${cBold}${cCyan}=== Interactive Shell ($Shell): $($C.Service) ===${cReset}"
    Write-Line "${cYellow}Type 'exit' to close the shell${cReset}"
    Write-Line
    $rc = Invoke-DockerAttached @('exec', '-it', $C.Id, $Shell)
    if ($rc -ne 0) { Write-Line "${cRed}$Shell is not available in this container (or it exited with $rc)${cReset}" }
    Wait-AnyKey
}

function Show-ContainerNetwork($C) {
    Start-View
    Write-Line "${cBold}${cCyan}=== Network View: $($C.Service) ===${cReset}"
    Write-Line
    $row = @(ConvertFrom-JsonLines (Invoke-Docker inspect --format '[{{json .State.Status}},{{json .HostConfig.NetworkMode}},{{json .NetworkSettings.Networks}},{{json .NetworkSettings.Ports}}]' $C.Id)) | Select-Object -First 1
    if ($null -eq $row) { Write-Line "${cRed}Could not inspect the container${cReset}"; Wait-AnyKey; return }
    $color = $cGreen
    if ($row[0] -ne 'running') { $color = $cRed }
    Write-Line "Status: ${color}$($row[0])${cReset}"
    Write-Line
    Write-Line "${cBold}Network Mode:${cReset} $($row[1])"
    if ([string]$row[1] -like 'container:*') { Write-Line "  ${cYellow}→ Shares network stack with: $(([string]$row[1]).Substring(10))${cReset}" }
    Write-Line
    Write-Line "${cBold}Networks:${cReset}"
    $any = $false
    if ($row[2]) {
        foreach ($n in $row[2].PSObject.Properties) {
            $any = $true
            Write-Line "  ${cCyan}$($n.Name)${cReset}"
            if ($n.Value.IPAddress) { Write-Line "    IP Address: ${cGreen}$($n.Value.IPAddress)${cReset}" }
            if ($n.Value.Gateway) { Write-Line "    Gateway:    ${cDim}$($n.Value.Gateway)${cReset}" }
            if ($n.Value.MacAddress) { Write-Line "    MAC:        ${cDim}$($n.Value.MacAddress)${cReset}" }
        }
    }
    if (-not $any) { Write-Line "  ${cDim}(no networks)${cReset}" }
    Write-Line
    Write-Line "${cBold}Port Mappings:${cReset}"
    $any = $false
    if ($row[3]) {
        foreach ($p in $row[3].PSObject.Properties) {
            $bindings = @($p.Value | Where-Object { $_ } | ForEach-Object { "$($_.HostIp):$($_.HostPort)" })
            if ($bindings.Count -eq 0) { continue }
            $any = $true
            Write-Line "  ${cGreen}$($p.Name)${cReset} → $($bindings -join ', ')"
        }
    }
    if (-not $any) { Write-Line "  ${cDim}(no ports exposed)${cReset}" }
    Write-Line
    Wait-AnyKey
}

# Network view for all stacks (TUI): straight from the snapshot
function Show-AllNetworks {
    Start-View
    Write-Line "${cBold}${cCyan}=== Network View: All Stacks ===${cReset}"
    Write-Line "${cDim}Snapshot from $($script:Snap.Time) · $($script:BaseDir)${cReset}"
    Write-Line
    $found = $false
    foreach ($s in $script:Snap.Stacks) {
        if ($s.Up -eq 0) { continue }
        $found = $true
        Write-Line "${cBold}${cBlue}[$($s.Name)]${cReset}"
        foreach ($id in $s.Ids) {
            $c = $script:Snap.C[$id]
            if ($c.Kind -ne 'up') { continue }
            Write-Line "  $(Get-ContainerDot $c) ${cBold}$($c.Service)${cReset}"
            $via = Get-SharedNetworkHost $c
            if ($via) {
                Write-Line "    ${cYellow}Network: via $via${cReset}"
            } else {
                foreach ($net in $c.Nets) {
                    if ($net.IP) { Write-Line "    Network: ${cCyan}$($net.Name)${cReset} (${cGreen}$($net.IP)${cReset})" }
                    else { Write-Line "    Network: ${cCyan}$($net.Name)${cReset} ${cDim}(host network)${cReset}" }
                }
            }
            if ($c.Ports) { Write-Line "    Ports: ${cDim}$($c.Ports)${cReset}" }
        }
        Write-Line
    }
    if (-not $found) { Write-Line "${cYellow}No running stacks found${cReset}" }
    Wait-AnyKey
}

function Format-Rate([double]$BytesPerSec) {
    if ($BytesPerSec -ge 1073741824) { return '{0:N1} GB/s' -f ($BytesPerSec / 1073741824) }
    if ($BytesPerSec -ge 1048576) { return '{0:N1} MB/s' -f ($BytesPerSec / 1048576) }
    if ($BytesPerSec -ge 1024) { return '{0:N1} KB/s' -f ($BytesPerSec / 1024) }
    return '{0:N0} B/s' -f $BytesPerSec
}

# Live traffic for all running containers, as per-second averages
function Show-Traffic {
    $ids = @($script:Snap.C.Values | Where-Object { $_.Kind -eq 'up' } | ForEach-Object { $_.Id })
    if ($ids.Count -eq 0) {
        Start-View
        Write-Line "${cBold}${cCyan}=== Live Traffic: All Stacks ===${cReset}"
        Write-Line "${cYellow}No running containers found${cReset}"
        Wait-AnyKey
        return
    }
    $interval = 10
    $prev = @{}; $prevTime = $null; $cycle = 0
    while ($true) {
        $start = [DateTime]::UtcNow
        $rows = @(ConvertFrom-JsonLines (Invoke-Docker stats --no-stream --format '[{{json .Name}},{{json .NetIO}},{{json .CPUPerc}},{{json .MemUsage}}]' @ids))
        $elapsed = $interval
        if ($prevTime) { $elapsed = [math]::Max(1, ($start - $prevTime).TotalSeconds) }

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("${cBold}${cCyan}=== Live Traffic: All Stacks ===${cReset}")
        $lines.Add("${cYellow}Press q, Esc or Ctrl+C to stop${cReset}")
        $lines.Add("${cDim}Cycle: $cycle | Refresh: ${interval}s | Showing: avg/s${cReset}")
        $lines.Add('')
        $lines.Add(("${cBold}{0,-25} {1,12} {2,12} {3,10} {4,15}${cReset}" -f 'CONTAINER', 'RX/s (avg)', 'TX/s (avg)', 'CPU %', 'MEM USAGE'))
        $lines.Add('─' * 78)
        $current = @{}
        foreach ($r in $rows) {
            $name = [string]$r[0]
            $io = ([string]$r[1]) -split ' / '
            $rx = ConvertFrom-Size $io[0]; $tx = 0
            if ($io.Count -gt 1) { $tx = ConvertFrom-Size $io[1] }
            $current[$name] = @($rx, $tx)
            $rxText = '--'; $txText = '--'
            if ($cycle -gt 0 -and $prev.ContainsKey($name)) {
                $rxText = Format-Rate ([math]::Max(0, $rx - $prev[$name][0]) / $elapsed)
                $txText = Format-Rate ([math]::Max(0, $tx - $prev[$name][1]) / $elapsed)
            }
            $display = $name
            if ($display.Length -gt 24) { $display = $display.Substring(0, 21) + '...' }
            $rxColor = ''; $txColor = ''
            if ($rxText -ne '--' -and $rxText -ne '0 B/s') { $rxColor = $cGreen }
            if ($txText -ne '--' -and $txText -ne '0 B/s') { $txColor = $cCyan }
            $lines.Add(('{0,-25} ' -f $display) + $rxColor + ('{0,12}' -f $rxText) + $cReset + ' ' + $txColor + ('{0,12}' -f $txText) + $cReset +
                (' {0,10} {1,15}' -f $r[2], (([string]$r[3]) -split ' / ')[0]))
        }
        $lines.Add('')
        $lines.Add("${cDim}Containers: $($ids.Count) | Next refresh in ${interval}s${cReset}")
        Write-Frame $lines.ToArray()
        $prev = $current; $prevTime = $start; $cycle++

        $deadline = $start.AddSeconds($interval)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ((Test-CtrlC $k) -or $k.Key -eq 'Escape' -or $k.KeyChar -eq 'q') {
                    Write-Line
                    Write-Line "${cDim}Monitoring stopped${cReset}"
                    return
                }
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

# ============================================================================
# Watch mode
# ============================================================================

function Start-Watch {
    $interactive = -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected
    if ($interactive) { Start-Tui }
    try {
        while ($true) {
            $lines = @(Get-StatusLines)
            if ($interactive) {
                Write-Frame ($lines + @('', "${cDim}Refreshing every 5s · q or Ctrl+C to quit${cReset}"))
                $deadline = [DateTime]::UtcNow.AddSeconds(5)
                while ([DateTime]::UtcNow -lt $deadline) {
                    if ([Console]::KeyAvailable) {
                        $k = [Console]::ReadKey($true)
                        if ((Test-CtrlC $k) -or $k.KeyChar -eq 'q' -or $k.Key -eq 'Escape') { return }
                    }
                    Start-Sleep -Milliseconds 100
                }
            } else {
                $lines; ''
                Start-Sleep -Seconds 5
            }
        }
    } finally {
        Stop-Tui
    }
}

# ============================================================================
# Self-update (-Update)
# ============================================================================

function Get-RemoteText([string]$Url) {
    $params = @{ Uri = $Url; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $params.UseBasicParsing = $true }
    return (Invoke-WebRequest @params).Content
}

# Replace this script with the latest release (or $env:DSM_UPDATE_REF: a tag
# or branch). A git clone of the project is updated with git pull instead.
function Update-Self {
    $self = $PSCommandPath
    $dir = Split-Path -Parent $self
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    if (Get-Command git -ErrorAction SilentlyContinue) {
        $origin = & git -C $dir remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0 -and $origin -match 'docker-stacks-manager(\.git)?/?$') {
            Write-Output "Updating the git clone in $dir"
            & git -C $dir pull --ff-only
            if ($LASTEXITCODE -ne 0) { return 1 }
            return 0
        }
    }

    $ref = $env:DSM_UPDATE_REF
    if (-not $ref) {
        try { $ref = (Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:DsmRepo)/releases/latest" -ErrorAction Stop).tag_name } catch { }
        if (-not $ref) { $ref = 'main' }
    }
    $url = "https://raw.githubusercontent.com/$($script:DsmRepo)/$ref/docker-stacks-manager.ps1"
    Write-Output "Checking $ref for a new version..."
    try { $text = Get-RemoteText $url } catch {
        [Console]::Error.WriteLine("Error: could not download $url ($($_.Exception.Message))")
        return 1
    }
    if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
    $text = $text.TrimStart([char]0xFEFF)

    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    $newVersion = $null
    if ($text -match "(?m)^\`$script:DsmVersion = '([^']+)'") { $newVersion = $Matches[1] }
    if ($errors.Count -gt 0 -or -not $newVersion) {
        [Console]::Error.WriteLine("Error: the download from $url is not a valid docker-stacks-manager script")
        return 1
    }
    if (-not $env:DSM_UPDATE_REF -and [version]$newVersion -le [version]$script:DsmVersion) {
        Write-Output "Already up to date ($($script:DsmVersion))"
        return 0
    }
    $tmp = "$self.new"
    try {
        # UTF-8 with BOM, so Windows PowerShell 5.1 reads the symbols right
        [IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding $true))
        Move-Item -LiteralPath $tmp -Destination $self -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        [Console]::Error.WriteLine("Error: could not replace $self ($($_.Exception.Message))")
        return 1
    }
    Write-Output "Updated ${self}: $($script:DsmVersion) -> $newVersion"
    return 0
}

# ============================================================================
# Main
# ============================================================================

function Show-Help {
    @"
Docker Stack Manager $($script:DsmVersion) - status and control for Docker Compose stacks

Usage: dsm [options]

Stacks are the compose files in the base directory and its direct
subdirectories. The base directory is the current one unless -Dir or
`$env:DSM_DIR says otherwise.

Views:
  -Interactive, -I   Interactive TUI (recommended)
  -Detailed, -v      Status with CPU/memory, ports and images
  -Stats, -s         Status with CPU/memory
  -Ports, -p         Status with port mappings
  -Images            Status with image versions
  -Watch, -w         Redraw the status every 5 seconds
  -Network, -n       Networks and the containers on them

Options:
  -Dir, -d DIR       Directory holding your stacks (default: current directory)
  -Update, -U        Update this script to the latest release
  -Version           Print the version
  -Help, -h          Show this help

Environment:
  DSM_DIR            Default for -Dir
  DSM_REFRESH        TUI refresh interval in seconds (default 5)

https://github.com/$($script:DsmRepo)
"@
}

function Invoke-Main {
    if ($Help) { Show-Help; return 0 }
    if ($Version) { "docker-stacks-manager $($script:DsmVersion)"; return 0 }
    if ($Update) { return (Update-Self) }

    $base = $Dir
    if (-not $base) { $base = $env:DSM_DIR }
    if (-not $base) { $base = (Get-Location).ProviderPath }
    $item = Get-Item -LiteralPath $base -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.PSIsContainer) {
        [Console]::Error.WriteLine("Error: stacks directory not found: $base")
        return 1
    }
    $script:BaseDir = $item.FullName.TrimEnd('\', '/')
    if ($script:BaseDir -eq '') { $script:BaseDir = $item.FullName }

    if ($Interactive -and ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) {
        # The TUI reads single keypresses; without a terminal it can't work
        [Console]::Error.WriteLine('Error: interactive mode (-Interactive) needs a terminal')
        return 1
    }
    if (-not (Test-Requirements)) { return 1 }

    if ($Interactive) {
        Start-Tui
        try {
            Get-Snapshot
            Show-StackMenu
        } catch {
            # Leave the alternate screen first, so the error stays visible
            Stop-Tui
            [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
            [Console]::Error.WriteLine("  at $($_.InvocationInfo.PositionMessage -replace "`n", "`n  ")")
            return 1
        } finally {
            Stop-Tui
        }
    } elseif ($Network) {
        Get-NetworkLines
    } elseif ($Watch) {
        Start-Watch
    } else {
        Get-StatusLines
    }
    return 0
}

# Dot-sourcing the script (as the tests do) only loads the functions
if ($MyInvocation.InvocationName -ne '.') {
    # Symbols and box drawing need UTF-8 output (Windows defaults to an OEM code page)
    $savedEncoding = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
    $OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $script:ExitCode = 0
    try {
        Invoke-Main | ForEach-Object {
            if ($_ -is [int]) { $script:ExitCode = $_ } else { $_ }
        }
    } finally {
        try { [Console]::OutputEncoding = $savedEncoding } catch { }
    }
    exit $script:ExitCode
}
