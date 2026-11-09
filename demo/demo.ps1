# Spin up a few throwaway stacks so you can try docker-stacks-manager without
# touching your real setup (PowerShell version of demo.sh).
#
#   .\demo\demo.ps1 up             # start the demo stacks
#   .\demo\demo.ps1 run            # status overview of the demo stacks
#   .\demo\demo.ps1 run -Interactive   # ...or any other options, e.g. the TUI
#   .\demo\demo.ps1 down           # remove everything again
# Not an advanced script on purpose: options after "run" land in $args, and
# splatting @args passes them on with their names intact.
param([string]$Command)
$ErrorActionPreference = 'Stop'
$stacks = Join-Path $PSScriptRoot 'stacks'
$manager = Join-Path (Split-Path -Parent $PSScriptRoot) 'docker-stacks-manager.ps1'

function Invoke-InStack([string]$Stack, [string[]]$Arguments) {
    Push-Location (Join-Path $stacks $Stack)
    try {
        & docker compose @Arguments
        if ($LASTEXITCODE -ne 0) { throw "docker compose $($Arguments -join ' ') failed in $Stack" }
    } finally { Pop-Location }
}

switch ($Command) {
    'up' {
        Invoke-InStack 'web-app' @('up', '-d')
        Invoke-InStack 'monitoring' @('up', '-d')
        Invoke-InStack 'monitoring' @('stop', '-t', '1', 'alerts')
        # Create but don't start, so it shows as stopped
        Invoke-InStack 'backup' @('create')
    }
    'run' {
        Push-Location $stacks
        try { & $manager @args } finally { Pop-Location }
    }
    'down' {
        foreach ($s in 'web-app', 'monitoring', 'backup') { Invoke-InStack $s @('down', '--volumes') }
    }
    default { Write-Output 'Usage: demo.ps1 up | run [options] | down' }
}
