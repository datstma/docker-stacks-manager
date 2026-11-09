<#
.SYNOPSIS
    Install, update or uninstall Docker Stack Manager on Windows.

    This file is plain ASCII without a byte order mark on purpose: it runs
    through `irm | iex`, and Windows PowerShell 5.1 mis-decodes a BOM there.

.DESCRIPTION
    One line, in PowerShell:

        irm https://raw.githubusercontent.com/datstma/docker-stacks-manager/main/install.ps1 | iex

    Installs docker-stacks-manager.ps1 and a `dsm` command into
    %LOCALAPPDATA%\Programs\docker-stacks-manager and adds that folder to your
    user PATH. Running it again updates an existing install, as does
    `dsm -Update`. Run from a clone (.\install.ps1), it installs the clone's own
    script instead of downloading one.

    To pass options through irm | iex, run it as a script block:

        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/datstma/docker-stacks-manager/main/install.ps1))) -Uninstall

.PARAMETER Ref
    Release tag or branch to install (default: the latest release). Also $env:DSM_REF.

.PARAMETER Destination
    Folder to install into. Also $env:DSM_INSTALL_DIR.

.PARAMETER Uninstall
    Remove an installed copy and take its folder off your PATH.
#>
param(
    [string]$Ref = $env:DSM_REF,
    [string]$Destination = $env:DSM_INSTALL_DIR,
    [switch]$Uninstall
)

# Everything runs in its own scope: with irm | iex this file runs in your
# session, which shouldn't keep its settings or helper functions afterwards.
& {
    $ErrorActionPreference = 'Stop'
    $repo = 'datstma/docker-stacks-manager'
    $scriptName = 'docker-stacks-manager.ps1'
    if (-not $Destination) {
        $localAppData = $env:LOCALAPPDATA
        if (-not $localAppData) { $localAppData = Join-Path $HOME '.local/share' }
        $Destination = Join-Path (Join-Path $localAppData 'Programs') 'docker-stacks-manager'
    }
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

    function Write-Step([string]$Text) { Write-Host '==> ' -ForegroundColor Green -NoNewline; Write-Host $Text }
    function Write-Warn([string]$Text) { Write-Host 'Warning: ' -ForegroundColor Yellow -NoNewline; Write-Host $Text }

    # User PATH from the registry, untouched by this session's changes
    function Get-UserPath { return [Environment]::GetEnvironmentVariable('Path', 'User') }
    function Set-UserPath([string]$Value) { [Environment]::SetEnvironmentVariable('Path', $Value, 'User') }
    function Test-OnPath([string]$PathList, [string]$Dir) {
        return @($PathList -split ';' | Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }).Count -gt 0
    }

    if ($Uninstall) {
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
            Write-Step "Removed $Destination"
        } else {
            Write-Warn "nothing installed in $Destination"
        }
        if ($onWindows) {
            $userPath = Get-UserPath
            if ($userPath -and (Test-OnPath $userPath $Destination)) {
                Set-UserPath ((@($userPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $Destination.TrimEnd('\') })) -join ';')
                Write-Step "Removed $Destination from your PATH"
            }
        }
        return
    }

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    # Download as UTF-8 whatever the server says (5.1 may guess another encoding)
    function Get-RemoteText([string]$Url) {
        $params = @{ Uri = $Url }
        if ($PSVersionTable.PSVersion.Major -lt 6) { $params.UseBasicParsing = $true }
        $bytes = (Invoke-WebRequest @params).RawContentStream.ToArray()
        return [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    }

    # A clone's own script, or a download
    $local = $null
    if ($PSCommandPath) {
        $candidate = Join-Path (Split-Path -Parent $PSCommandPath) $scriptName
        if (-not $Ref -and (Test-Path -LiteralPath $candidate)) { $local = $candidate }
    }
    if ($local) {
        Write-Step "Installing from $(Split-Path -Parent $local)"
        $text = [IO.File]::ReadAllText($local).TrimStart([char]0xFEFF)
    } else {
        if (-not $Ref) {
            try { $Ref = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name } catch { }
            if (-not $Ref) { $Ref = 'main' }
        }
        $url = "https://raw.githubusercontent.com/$repo/$Ref/$scriptName"
        Write-Step "Downloading $scriptName ($Ref)"
        try { $text = Get-RemoteText $url } catch { throw "Download failed: $url ($($_.Exception.Message))" }
    }

    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0 -or $text -notmatch "(?m)^\`$script:DsmVersion = '([^']+)'") {
        throw "The downloaded file is not a valid $scriptName"
    }
    $newVersion = $Matches[1]

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $target = Join-Path $Destination $scriptName
    $oldVersion = $null
    if (Test-Path -LiteralPath $target) {
        if ((Get-Content -LiteralPath $target -Raw) -match "(?m)^\`$script:DsmVersion = '([^']+)'") { $oldVersion = $Matches[1] }
    }
    # UTF-8 with BOM, so Windows PowerShell 5.1 reads the symbols right
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [IO.File]::WriteAllText($target, $text, $utf8Bom)

    if ($onWindows) {
        # `dsm` works from cmd, PowerShell and Windows Terminal alike, uses
        # PowerShell 7 when it's installed, and isn't blocked by the execution policy
        $cmd = @(
            '@echo off'
            'where pwsh >nul 2>nul'
            'if %errorlevel%==0 ('
            '    pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0docker-stacks-manager.ps1" %*'
            ') else ('
            '    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0docker-stacks-manager.ps1" %*'
            ')'
            'exit /b %errorlevel%'
        ) -join "`r`n"
        [IO.File]::WriteAllText((Join-Path $Destination 'dsm.cmd'), $cmd + "`r`n", (New-Object System.Text.ASCIIEncoding))
    }

    if ($oldVersion -eq $newVersion) { Write-Step "Reinstalled $target ($newVersion)" }
    elseif ($oldVersion) { Write-Step "Updated ${target}: $oldVersion -> $newVersion" }
    else { Write-Step "Installed $target ($newVersion)" }

    if ($onWindows) {
        $userPath = Get-UserPath
        if (-not $userPath -or -not (Test-OnPath $userPath $Destination)) {
            $parts = @(@($userPath -split ';') + $Destination | Where-Object { $_ })
            Set-UserPath ($parts -join ';')
            Write-Step "Added $Destination to your PATH (new terminals pick it up)"
        }
        if (-not (Test-OnPath $env:Path $Destination)) { $env:Path = "$env:Path;$Destination" }
        Write-Step 'Command: dsm'
    } else {
        Write-Warn "on Linux and macOS, install.sh is the supported installer; the script is in $Destination"
    }

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Warn 'docker was not found. Install Docker Desktop: https://docs.docker.com/desktop/setup/install/windows-install/'
    }

    Write-Host ''
    Write-Host 'Get started' -ForegroundColor White
    Write-Host '  cd C:\docker-stacks; dsm -Interactive   ' -NoNewline; Write-Host '# interactive TUI, run from your stacks folder' -ForegroundColor DarkGray
    Write-Host '  dsm -Dir C:\docker-stacks               ' -NoNewline; Write-Host '# ...or point it at the folder' -ForegroundColor DarkGray
    Write-Host '  dsm -Update                             ' -NoNewline; Write-Host '# update to the latest release' -ForegroundColor DarkGray
    Write-Host ''
}
