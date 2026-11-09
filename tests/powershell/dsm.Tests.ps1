# Pester tests for docker-stacks-manager.ps1. No Docker needed: unit tests mock
# the docker wrappers, end-to-end tests replay recorded docker output.
#
#   Invoke-Pester ./tests/powershell
#
# End-to-end tests run the script under every PowerShell found (pwsh, and on
# Windows also Windows PowerShell 5.1).

BeforeDiscovery {
    $script:Shells = @('pwsh')
    if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6) {
        if (Get-Command powershell.exe -ErrorAction SilentlyContinue) { $script:Shells += 'powershell' }
    }
}

BeforeAll {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $Script = Join-Path $Root 'docker-stacks-manager.ps1'
    . $Script          # loads the functions without running anything
    Set-DsmColors $false
}

Describe 'Formatting helpers' {
    It 'formats uptimes' -ForEach @(
        @{ Secs = 59; Want = '0m' }, @{ Secs = 125; Want = '2m' }, @{ Secs = 7260; Want = '2h 1m' }, @{ Secs = 270000; Want = '3d 3h' }
    ) {
        Format-Uptime $Secs | Should -Be $Want
    }
    It 'formats durations' -ForEach @(
        @{ Secs = 86400; Want = '24h' }, @{ Secs = 5400; Want = '1h 30m' }, @{ Secs = 300; Want = '5m' }
    ) {
        Format-Duration $Secs | Should -Be $Want
    }
    It 'derives Compose project names' {
        Get-ComposeProjectName 'My Stack.v2' | Should -Be 'mystackv2'
    }
    It 'reads Docker timestamps as UTC, with 9 fractional digits' {
        (ConvertFrom-DockerTime '2026-01-01T00:00:00.123456789Z').ToUnixTimeSeconds() | Should -Be 1767225600
    }
    It 'treats the zero time as no time' {
        ConvertFrom-DockerTime '0001-01-01T00:00:00Z' | Should -BeNullOrEmpty
    }
    It 'reads Watchtower log times with their offset' {
        (ConvertFrom-WatchtowerTime '2026-11-09 04:00:00 +0100 CET').ToUnixTimeSeconds() | Should -Be 1794193200
    }
    It 'parses decimal and binary sizes' {
        ConvertFrom-Size '5.5MB' | Should -Be 5500000
        ConvertFrom-Size '2KiB' | Should -Be 2048
        ConvertFrom-Size '88B' | Should -Be 88
    }
    It 'quotes Windows command-line arguments' {
        ConvertTo-ArgString @('logs', 'a b', 'say "hi"', '') | Should -Be 'logs "a b" "say \"hi\"" ""'
    }
}

Describe 'Find-ComposeFiles' {
    It 'finds one file per stack, preferring the name docker compose would pick' {
        foreach ($d in 'a', 'b b', 'c', 'd\nested', 'e') { New-Item -ItemType Directory -Path (Join-Path $TestDrive $d) -Force | Out-Null }
        foreach ($f in 'a\compose.yaml', 'b b\docker-compose.yml', 'c\docker-compose.yml', 'c\compose.yml', 'd\nested\compose.yaml', 'e\notes.txt') {
            New-Item -ItemType File -Path (Join-Path $TestDrive $f) -Force | Out-Null
        }
        $got = @(Find-ComposeFiles $TestDrive | ForEach-Object { $_.Substring($TestDrive.Length + 1).Replace('\', '/') })
        $got | Should -Be @('a/compose.yaml', 'b b/docker-compose.yml', 'c/compose.yml')
    }
}

Describe 'Watchtower' {
    BeforeAll {
        $script:WtEnv = '[]'
        $script:WtLogs = @()
        Mock Invoke-Docker { $script:WtEnv }
        Mock Invoke-DockerAll { $script:WtLogs }
        $Now = [DateTimeOffset]::Parse('2026-11-09T12:00:00Z')
    }
    It 'uses the logged next run when it is in the future' {
        Get-WatchtowerNextCheck 'wt' @('msg="Scheduled next run: 2099-01-01 04:00:00 +0100 CET"') $Now | Should -Be '2099-01-01 04:00 CET'
    }
    It 'ignores a stale logged run and resolves a daily cron' {
        $script:WtEnv = '["WATCHTOWER_SCHEDULE=0 0 4 * * *","TZ=UTC"]'
        Get-WatchtowerNextCheck 'wt' @('msg="Scheduled next run: 2020-01-01 04:00:00 +0100 CET"') $Now | Should -Be '2026-11-10 04:00 UTC (daily)'
    }
    It 'resolves a daily cron in the container time zone' {
        $script:WtEnv = '["WATCHTOWER_SCHEDULE=\"0 30 4 * * *\"","TZ=Asia/Tokyo"]'
        $got = Get-WatchtowerNextCheck 'wt' @() $Now
        # 12:00 UTC is 21:00 in Tokyo, so the next 04:30 there is tomorrow
        if ($got -like '*local time*') { Set-ItResult -Skipped -Because 'this .NET cannot resolve IANA time zones' }
        $got | Should -Be '2026-11-10 04:30 Asia/Tokyo (daily)'
    }
    It 'shows other cron schedules as they are' {
        $script:WtEnv = '["WATCHTOWER_SCHEDULE=0 */5 * * * *"]'
        Get-WatchtowerNextCheck 'wt' @() $Now | Should -Be 'schedule: 0 */5 * * * *'
    }
    It 'counts a poll interval from the first run' {
        $script:WtEnv = '["WATCHTOWER_POLL_INTERVAL=3600"]'
        $script:WtLogs = @('time="2026-11-09T00:00:00Z" level=info msg="Scheduling first run: 2026-11-09 00:00:00 +0000 UTC"')
        Get-WatchtowerNextCheck 'wt' @() $Now | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:00 \(every 1h\)$'
    }
    It 'defaults to a 24h poll interval' {
        $script:WtEnv = '[]'; $script:WtLogs = @()
        Get-WatchtowerNextCheck 'wt' @() $Now | Should -Be 'every 24h'
    }

    Context 'last session' {
        BeforeAll {
            $SessionLogs = @(
                'time="2026-11-07T04:00:00+01:00" level=info msg="Session done" Failed=0 Scanned=3 Updated=0 notify=no'
                'time="2026-11-08T04:01:19+01:00" level=info msg="Unable to update container \"/app-db\": Error response from daemon: failed to resolve reference"'
                'time="2026-11-08T04:01:24+01:00" level=info msg="Found new example/web:latest image (44a82caf5b86)"'
                'time="2026-11-08T04:02:08+01:00" level=info msg="Creating /web"'
                'time="2026-11-08T04:02:09+01:00" level=info msg="Creating /web-worker"'
                'time="2026-11-08T04:02:12+01:00" level=info msg="Session done" Failed=0 Scanned=3 Updated=2 notify=no'
            )
        }
        It 'summarises the most recent session' {
            $text = (Get-WatchtowerLastSession $SessionLogs) -join "`n"
            $text | Should -Match 'Last check: 2026-11-08 04:02 \(3 scanned, 2 updated\)'
            $text | Should -Match 'New images: example/web:latest'
            $text | Should -Match 'Recreated: web, web-worker'
            $text | Should -Match 'Could not check: app-db '
        }
        It 'says when no updates were needed' {
            (Get-WatchtowerLastSession $SessionLogs[0]) -join "`n" | Should -Match 'No updates needed'
        }
    }
}

Describe 'Get-Snapshot' {
    BeforeAll {
        foreach ($d in 'app', 'My Stack', 'jobs', 'empty') {
            New-Item -ItemType Directory -Path (Join-Path $TestDrive "snap\$d") -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $TestDrive "snap\$d\compose.yaml") -Force | Out-Null
        }
        $script:BaseDir = Join-Path $TestDrive 'snap'
        $appDir = (Join-Path $script:BaseDir 'app').Replace('\', '\\')
        function Row($Id, $Name, $Project, $WorkDir, $Service, $State, $Extra) {
            $labels = '{"com.docker.compose.project":"' + $Project + '","com.docker.compose.project.working_dir":"' + $WorkDir + '","com.docker.compose.service":"' + $Service + '"' + $Extra + '}'
            return '["' + $Id + 'ffff","/' + $Name + '",' + $labels + ',"img:1",' + $State
        }
        $script:PsOut = @(
            '["aaaaaaaaaaa1","Up 2 hours (healthy)"]', '["aaaaaaaaaaa2","Up 2 hours (unhealthy)"]',
            '["bbbbbbbbbbb1","Up 5 minutes"]', '["bbbbbbbbbbb2","Exited (1) 1 hour ago"]',
            '["ccccccccccc1","Exited (0) 3 days ago"]', '["ddddddddddd1","Up 1 minute"]'
        )
        $up = '{"Status":"running","ExitCode":0,"StartedAt":"2026-01-01T00:00:00Z","Health":{"Status":"healthy"}}'
        $sick = '{"Status":"running","ExitCode":0,"StartedAt":"2026-01-01T00:00:00Z","Health":{"Status":"unhealthy"}}'
        $plain = '{"Status":"running","ExitCode":0,"StartedAt":"2026-01-01T00:00:00Z"}'
        $crashed = '{"Status":"exited","ExitCode":1,"StartedAt":"0001-01-01T00:00:00Z"}'
        $finished = '{"Status":"exited","ExitCode":0,"StartedAt":"0001-01-01T00:00:00Z"}'
        $script:InspectOut = @(
            (Row 'aaaaaaaaaaa1' 'app-web-1' 'app' $appDir 'web' $up ',"com.centurylinklabs.watchtower.enable":"true"') + ',0,"bridge","unless-stopped",{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}],"443/tcp":null},{"app_default":{"IPAddress":"172.20.0.2"}}]'
            (Row 'aaaaaaaaaaa2' 'app-db-1' 'app' $appDir 'db' $sick '') + ',3,"bridge","unless-stopped",{},{"app_default":{"IPAddress":"172.20.0.3"}}]'
            (Row 'bbbbbbbbbbb1' 'mystack-api-1' 'mystack' 'D:\\elsewhere\\My Stack' 'api' $plain '') + ',0,"container:aaaaaaaaaaa1ffff","always",{},{}]'
            (Row 'bbbbbbbbbbb2' 'mystack-cron-1' 'mystack' 'D:\\elsewhere\\My Stack' 'cron' $crashed '') + ',0,"bridge","unless-stopped",{},{}]'
            (Row 'ccccccccccc1' 'jobs-seed-1' 'jobs' 'D:\\x\\jobs' 'seed' $finished '') + ',0,"bridge","no",{},{}]'
            (Row 'ddddddddddd1' 'other-x-1' 'other' 'D:\\not\\a\\stack' 'x' $plain '') + ',0,"bridge","no",{},{}]'
        )
        Mock Invoke-Docker {
            switch ($args[0]) { 'ps' { $script:PsOut } 'inspect' { $script:InspectOut } }
        }
        Get-Snapshot
        function Stack($Name) { $script:Snap.Stacks | Where-Object Name -EQ $Name }
    }
    It 'matches containers by working directory' {
        (Stack 'app').Ids | Should -Be @('aaaaaaaaaaa2', 'aaaaaaaaaaa1')   # sorted by service: db, web
    }
    It 'matches by project name when the directory differs' {
        (Stack 'My Stack').Ids.Count | Should -Be 2
    }
    It 'ignores containers outside the stacks' {
        $script:Snap.C.ContainsKey('ddddddddddd1') | Should -BeFalse
    }
    It 'classifies stacks' {
        $app = Stack 'app'
        "$($app.Status) $($app.Up)/$($app.Total) $($app.Unhealthy)" | Should -Be 'unhealthy 2/2 1'
        (Stack 'My Stack').Status | Should -Be 'partial'
        (Stack 'jobs').Status | Should -Be 'stopped'
        (Stack 'empty').Total | Should -Be 0
    }
    It 'classifies containers' {
        $script:Snap.C['ccccccccccc1'].Kind | Should -Be 'done'
        $script:Snap.C['bbbbbbbbbbb2'].Kind | Should -Be 'down'
    }
    It 'reads ports, networks and the Watchtower label' {
        $c = $script:Snap.C['aaaaaaaaaaa1']
        $c.Ports | Should -Be '80/tcp -> 8080'
        "$($c.Nets[0].Name)=$($c.Nets[0].IP)" | Should -Be 'app_default=172.20.0.2'
        $c.Auto | Should -BeTrue
    }
    It 'resolves a shared network to its host container' {
        Get-SharedNetworkHost $script:Snap.C['bbbbbbbbbbb1'] | Should -Be 'app-web-1'
    }
    It 'builds badges and summaries' {
        Get-StackBadge (Stack 'My Stack') | Should -Be '◐ 1/2 running'
        $now = [DateTimeOffset]::Parse('2026-01-01T02:00:00Z')
        Get-ContainerSummary $script:Snap.C['aaaaaaaaaaa2'] $now | Should -Be '2h 0m unhealthy ↻3'
        Get-ContainerSummary $script:Snap.C['aaaaaaaaaaa1'] $now | Should -Match '\[auto\]$'
    }
}

Describe 'Import: docker run commands' {
    BeforeAll {
        function Get-Yaml([string]$Command) {
            ConvertFrom-RunCommand $Command
            return ((ConvertTo-ComposeYaml) -join "`n")
        }
    }
    It 'splits words like a POSIX shell, keeping Windows paths' {
        $w = Split-ShellWords "docker run -e `"A=b c`" -e 'D=`$E' \`n  --name x\ y -v C:\data:/d img # comment"
        ($w | ForEach-Object { "[$_]" }) -join '' | Should -Be '[docker][run][-e][A=b c][-e][D=$E][--name][x y][-v][C:\data:/d][img]'
    }
    It 'follows PowerShell and cmd line continuations' {
        (Split-ShellWords "docker run ```n -d img").Count | Should -Be 4
        (Split-ShellWords "docker run ^`r`n -d img").Count | Should -Be 4
    }
    It 'rejects an unclosed quote' {
        { Split-ShellWords 'docker run "oops' } | Should -Throw '*unclosed quote*'
    }
    It 'converts a full command' {
        $y = Get-Yaml 'sudo docker run -dit --name=Web_1 --restart unless-stopped -p 8080:80 -p127.0.0.1:8443:443 -v /srv/html:/usr/share/nginx/html:ro -v cache:/var/cache --mount type=tmpfs,target=/tmp,tmpfs-size=64m -e TZ=Europe/Stockholm --env "MSG=hello \"world\"" --network proxy --ip 172.20.0.5 --network-alias www --ulimit nofile=1024:2048 --health-cmd "curl -f http://localhost || exit 1" --gpus all --rm nginx:1.27 nginx -g "daemon off;" | tee log'
        $y | Should -Match '(?m)^  web_1:$'
        $y | Should -Match 'container_name: "Web_1"'
        $y | Should -Match ([regex]::Escape('command: ["nginx", "-g", "daemon off;"]'))
        $y | Should -Match '- "8080:80"'
        $y | Should -Match '- "127\.0\.0\.1:8443:443"'
        $y | Should -Match ([regex]::Escape('- "MSG=hello \"world\""'))
        $y | Should -Match '(?m)^  "cache":\n    external: true'
        $y | Should -Match '- "/tmp:size=64m"'
        $y | Should -Match 'ipv4_address: "172\.20\.0\.5"'
        $y | Should -Match ([regex]::Escape('aliases: ["www"]'))
        $y | Should -Match 'tty: true'
        $y | Should -Match 'stdin_open: true'
        $y | Should -Match 'hard: 2048'
        $y | Should -Match ([regex]::Escape('test: ["CMD-SHELL", "curl -f http://localhost || exit 1"]'))
        $y | Should -Match 'count: all'
        $y | Should -Match '#   - --rm has no compose equivalent'
        $y | Should -Match 'Stopped at "\|"'
    }
    It 'leaves $VARIABLES for compose and says so' {
        $y = Get-Yaml 'docker run -e PASS=$SECRET alpine'
        $y | Should -Match ([regex]::Escape('- "PASS=$SECRET"'))
        $y | Should -Match 'Compose fills in'
        $y | Should -Match '(?m)^  alpine:$'
    }
    It 'refuses what is not a docker run command' {
        { ConvertFrom-RunCommand 'docker ps -a' } | Should -Throw 'not a docker run command'
        { ConvertFrom-RunCommand 'docker run -d -p 80:80' } | Should -Throw 'no image in the command'
    }
}

Describe 'Import: containers' {
    BeforeAll {
        $script:ImportDir = Join-Path $Root 'tests/import'
        Mock Invoke-Docker {
            $flat = @($args | ForEach-Object { $_ })
            if ($flat[0] -eq 'inspect' -and $flat[1] -eq '--type') {
                $f = Join-Path $script:ImportDir "$($flat[-1]).json"
                if (Test-Path $f) { Get-Content -Raw $f }
            } elseif ($flat[0] -eq 'image' -and $flat[1] -eq 'inspect') {
                foreach ($f in Get-ChildItem $script:ImportDir -Filter '*.image.json') {
                    $text = Get-Content -Raw $f.FullName
                    if ($text.Contains($flat[-1])) { return $text }
                }
            }
        }
        function Get-ImportYaml([string]$Name) {
            ConvertFrom-Container $Name
            return ((ConvertTo-ComposeYaml) -join "`n")
        }
    }
    It 'keeps what was set with docker run and leaves out image defaults' {
        $y = Get-ImportYaml 'web'
        $y | Should -Not -Match 'PATH=|maintainer'
        $y | Should -Match ([regex]::Escape('- "PRICE=$$5"'))
        $y | Should -Match 'restart: "unless-stopped"'
        $y | Should -Match '- "127\.0\.0\.1:8443:443"'
        $y | Should -Match '(?m)^  "webdata":\n    external: true'
        $y | Should -Match '- "/srv/html:/srv:ro"'
        $y | Should -Match 'ipv4_address: "172\.30\.0\.50"'
        $y | Should -Match ([regex]::Escape('aliases: ["www"]'))
        $y | Should -Match 'mem_limit: "256m"'
        $y | Should -Match '(?m)^    cpus: 0\.5$'
        $y | Should -Match 'interval: "30s"'
        $y | Should -Match 'com\.centurylinklabs\.watchtower\.enable=true'
        $y | Should -Not -Match 'hostname:'
    }
    It 'keeps entrypoint and command together' {
        $y = Get-ImportYaml 'job'
        $y | Should -Match ([regex]::Escape('entrypoint: ["sh"]'))
        $y | Should -Match ([regex]::Escape('command: ["-c", "echo hi > /data/x; sleep 3600"]'))
    }
    It 'keeps an anonymous volume by its ID' {
        $y = Get-ImportYaml 'anon'
        $y | Should -Match '- "[0-9a-f]{64}:/data"'
        $y | Should -Match 'anonymous volume at /data'
    }
    It 'refuses a container compose already manages' {
        { ConvertFrom-Container 'managed' } | Should -Throw '*already part of the compose stack conv1'
    }
    It 'reports a missing container' {
        { ConvertFrom-Container 'nosuch' } | Should -Throw 'no such container: nosuch'
    }
}

Describe 'End to end (recorded docker output) under <_>' -ForEach $Shells {
    BeforeAll {
        $Shell = $_
        $Stacks = Join-Path $Root 'demo/stacks'
        function Invoke-Dsm([string[]]$Arguments) {
            $missing = Join-Path $TestDrive 'missing.txt'
            Remove-Item $missing -ErrorAction SilentlyContinue
            $saved = @{ PATH = $env:PATH; F = $env:DSM_FAKE_DOCKER; M = $env:DSM_FAKE_MISSING; NC = $env:NO_COLOR }
            $env:PATH = (Join-Path $PSScriptRoot 'bin') + [IO.Path]::PathSeparator + $env:PATH
            $env:DSM_FAKE_DOCKER = 'replay'; $env:DSM_FAKE_MISSING = $missing; $env:NO_COLOR = '1'
            try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
            Push-Location $Stacks
            # Windows PowerShell 5.1 turns a native program's stderr into error
            # records; they must not stop the test when the script reports an error
            $ErrorActionPreference = 'Continue'
            try {
                $out = @(& $Shell -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | ForEach-Object { "$_" })
                $rc = $LASTEXITCODE
            } finally {
                Pop-Location
                $env:PATH = $saved.PATH; $env:DSM_FAKE_DOCKER = $saved.F; $env:DSM_FAKE_MISSING = $saved.M; $env:NO_COLOR = $saved.NC
            }
            $unrecorded = ''
            if (Test-Path $missing) { $unrecorded = (Get-Content $missing) -join "`n" }
            return [pscustomobject]@{ Text = ($out -join "`n"); Rc = $rc; Missing = $unrecorded }
        }
    }

    Context 'status' {
        BeforeAll { $R = Invoke-Dsm @() }
        It 'runs cleanly, with every docker call recorded' {
            $R.Missing | Should -BeNullOrEmpty
            $R.Rc | Should -Be 0
        }
        It 'shows stopped, partial and running stacks' {
            $R.Text | Should -Match '✗ backup \(stopped\)'
            $R.Text | Should -Match '⚠ monitoring \(1/2 running\)'
            $R.Text | Should -Match '✓ web-app \(3 containers\)'
        }
        It 'shows a stopped service with Docker''s status' { $R.Text | Should -Match 'alerts ● Exited \(137\)' }
        It 'shows a finished one-shot job as done' { $R.Text | Should -Match 'migrate ✓ done \(Exited \(0\)' }
        It 'draws the tree' { $R.Text | Should -Match '└─ worker ●' }
        It 'shows the Watchtower label' { $R.Text | Should -Match 'frontend ● .*\[auto\]' }
        It 'counts stacks and containers' {
            $R.Text | Should -Match 'Stacks: 3 total, 1 running, 1 with issues, 1 stopped'
            $R.Text | Should -Match 'Containers: 4 running, 0 unhealthy, 2 stopped'
        }
        It 'writes no escape codes with NO_COLOR' { $R.Text | Should -Not -Match ([regex]::Escape([string][char]27)) }
    }

    Context 'convert' {
        BeforeAll { $R = Invoke-Dsm @('-Print', '-Convert', 'docker run -d --name app -p 8080:80 nginx:1.27') }
        It 'prints the compose file' {
            $R.Rc | Should -Be 0
            $R.Text | Should -Match 'container_name: "app"'
            $R.Text | Should -Match '- "8080:80"'
        }
    }

    Context 'detailed' {
        BeforeAll { $R = Invoke-Dsm @('-Detailed') }
        It 'runs cleanly' { $R.Missing | Should -BeNullOrEmpty; $R.Rc | Should -Be 0 }
        It 'shows CPU and memory' { $R.Text | Should -Match 'CPU: [0-9.]+%  MEM: [0-9.]+[KMG]i?B' }
        It 'shows ports and images' {
            $R.Text | Should -Match 'Ports: 8080/tcp -> 18080'
            $R.Text | Should -Match 'Image: busybox:1.36'
        }
        It 'sorts volumes largest first' {
            $vols = @($R.Text -split "`n" | Select-String -Pattern '^\s+\S+\s+(web-app_\w+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
            $vols | Should -Be @('web-app_uploads', 'web-app_cache')
        }
    }

    Context 'network' {
        BeforeAll { $R = Invoke-Dsm @('-Network') }
        It 'runs cleanly' { $R.Missing | Should -BeNullOrEmpty; $R.Rc | Should -Be 0 }
        It 'lists custom networks with container IPs' {
            $R.Text | Should -Match 'web-app_app-net'
            $R.Text | Should -Match 'web-app-frontend-1 \([0-9.]+\) \[web-app\]'
        }
        It 'shows a shared-network container via its host' {
            $R.Text | Should -Match 'web-app-sidecar-1 → via web-app-frontend-1 \[web-app\]'
        }
    }

    Context 'options' {
        It 'prints its version' { (Invoke-Dsm @('-Version')).Text | Should -Match '^docker-stacks-manager \d+\.\d+\.\d+$' }
        It 'prints help' { (Invoke-Dsm @('-Help')).Text | Should -Match '-Interactive, -I' }
        It 'fails on a missing stacks directory' {
            $r = Invoke-Dsm @('-Dir', (Join-Path $TestDrive 'nonexistent'))
            $r.Rc | Should -Be 1
            $r.Text | Should -Match 'stacks directory not found'
        }
        It 'refuses the TUI without a terminal' {
            $r = Invoke-Dsm @('-Interactive')
            $r.Rc | Should -Be 1
            $r.Text | Should -Match 'needs a terminal'
        }
    }
}
