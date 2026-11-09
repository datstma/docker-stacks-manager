# Re-record tests/powershell/fixtures from the demo stacks. Needs a real Docker.
# Run this after changing which docker commands docker-stacks-manager.ps1 calls.
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$realDocker = (Get-Command docker -CommandType Application | Select-Object -First 1).Source

& (Join-Path $root 'demo\demo.ps1') up *> $null
# Give the volumes different sizes so the size sort is exercised
docker exec web-app-worker-1 sh -c 'head -c 3000000 /dev/zero > /uploads/big; head -c 20000 /dev/zero > /cache/small'
foreach ($i in 1..30) {
    if ((docker inspect -f '{{.State.Health.Status}}' web-app-frontend-1) -eq 'healthy') { break }
    Start-Sleep -Seconds 1
}
$demoIds = @(docker ps -aq --filter label=com.docker.compose.project | ForEach-Object {
    $wd = docker inspect -f '{{index .Config.Labels `com.docker.compose.project.working_dir`}}' $_
    if ("$wd" -like '*\demo\stacks\*' -or "$wd" -like '*/demo/stacks/*') { $_ }
})

$fixtures = Join-Path $PSScriptRoot 'fixtures'
Remove-Item -Recurse -Force $fixtures -ErrorAction SilentlyContinue
New-Item -ItemType Directory $fixtures | Out-Null

$env:DSM_FAKE_DOCKER = 'record'
$env:DSM_REAL_DOCKER = $realDocker
$env:DSM_DEMO_IDS = $demoIds -join ','
$env:DSM_RECORD_ROOT = [string]$root
$savedPath = $env:PATH
$env:PATH = (Join-Path $PSScriptRoot 'bin') + [IO.Path]::PathSeparator + $env:PATH
Push-Location (Join-Path $root 'demo\stacks')
try {
    foreach ($opts in @(@{}, @{ Detailed = $true }, @{ Network = $true })) {
        & (Join-Path $root 'docker-stacks-manager.ps1') @opts | Out-Null
    }
} finally {
    Pop-Location
    $env:PATH = $savedPath
    Remove-Item Env:DSM_FAKE_DOCKER, Env:DSM_REAL_DOCKER, Env:DSM_DEMO_IDS, Env:DSM_RECORD_ROOT
}
& (Join-Path $root 'demo\demo.ps1') down *> $null
"Recorded $(@(Get-ChildItem $fixtures -Filter *.out).Count) docker calls into $fixtures"
