# Stand-in for the docker CLI used by tests/powershell (put this directory first
# on PATH; PowerShell then runs docker.ps1 instead of docker.exe).
#
#   $env:DSM_FAKE_DOCKER = 'replay'  answer from tests/powershell/fixtures (no Docker needed)
#   $env:DSM_FAKE_DOCKER = 'record'  call the real docker ($env:DSM_REAL_DOCKER) and save the answer
#
# Each call is keyed on the current directory name plus the exact arguments,
# because "docker compose ..." answers differently in each stack directory.

$fixtures = Join-Path (Split-Path -Parent $PSScriptRoot) 'fixtures'
$sep = [string][char]0x1f
$flat = @(foreach ($a in $args) { $a })
$keyText = (Split-Path -Leaf (Get-Location).ProviderPath) + $sep + ($flat -join $sep)
$sha = [System.Security.Cryptography.SHA256]::Create()
$hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($keyText))
$key = (-join ($hash[0..7] | ForEach-Object { $_.ToString('x2') }))
$base = Join-Path $fixtures $key
$utf8 = New-Object System.Text.UTF8Encoding $false

if ($env:DSM_FAKE_DOCKER -eq 'record') {
    $joined = $flat -join ' '
    if ($joined -like 'ps --filter name=watchtower*') {
        # Keep the recording machine's Watchtower out of the fixtures
        $out = @()
    } else {
        $out = @(& $env:DSM_REAL_DOCKER @flat 2>$null)
    }
    $rc = $LASTEXITCODE
    if ($null -eq $rc) { $rc = 0 }
    # Only the demo stacks' own objects, with the recording machine's path replaced
    $demoIds = @($env:DSM_DEMO_IDS -split ',' | Where-Object { $_ })
    if ($joined -like 'ps -a --filter label=com.docker.compose.project*' -or $joined -like 'stats --no-stream*') {
        $out = @($out | Where-Object { $line = $_; @($demoIds | Where-Object { $line.Contains($_) }).Count -gt 0 })
    } elseif ($joined -like 'system df -v*') {
        $volumes = @(foreach ($v in (ConvertFrom-Json -InputObject ($out -join ''))) { if ($v.Name -match '^(web-app|monitoring|backup)_') { $v } })
        $out = @(ConvertTo-Json -InputObject $volumes -Compress -Depth 5)
    }
    if ($env:DSM_RECORD_ROOT) {
        $escaped = $env:DSM_RECORD_ROOT.Replace('\', '\\')
        $out = @($out | ForEach-Object { $_.Replace($escaped, 'C:\\recorded').Replace($env:DSM_RECORD_ROOT, 'C:\recorded') })
    }
    [IO.File]::WriteAllLines("$base.out", [string[]]$out, $utf8)
    [IO.File]::WriteAllText("$base.rc", "$rc", $utf8)
    [IO.File]::WriteAllText("$base.args", "$(Split-Path -Leaf (Get-Location).ProviderPath) | $joined", $utf8)
    $out
    exit $rc
}

if (Test-Path -LiteralPath "$base.out") {
    [IO.File]::ReadAllLines("$base.out", $utf8)
    exit ([int][IO.File]::ReadAllText("$base.rc"))
}
$missing = "fake docker: no fixture for: ($(Split-Path -Leaf (Get-Location).ProviderPath)) $($flat -join ' ')"
if ($env:DSM_FAKE_MISSING) { Add-Content -LiteralPath $env:DSM_FAKE_MISSING -Value $missing } else { [Console]::Error.WriteLine($missing) }
exit 1
