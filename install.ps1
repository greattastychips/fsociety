
param(
    [Parameter(Position = 0)]
    [string]$Command = 'install',

    [Parameter(Position = 1)]
    [string]$Value,

    [switch]$Daemon
)

$ErrorActionPreference = 'Stop'

$RepoOwner = 'greattastychips'
$RepoName = 'fsociety'
$Branch = 'main'

$InstallDir = Join-Path $env:LOCALAPPDATA '1234'
$ScriptPath = Join-Path $InstallDir 'install.ps1'
$WallpaperPath = Join-Path $InstallDir '1234.png'
$ConfigPath = Join-Path $InstallDir 'config.json'
$ShimPath = Join-Path $InstallDir 'fsociety.cmd'

$RunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName = 'fsociety'

$MutexName = 'Local\fsociety_1234_mutex'
$StopEventName = 'Local\fsociety_1234_stop'

$ScriptUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/install.ps1"
$WallpaperUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/1234.png"

$PowerShellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path $PowerShellExe)) {
    $PowerShellExe = (Get-Process -Id $PID).Path
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

function Write-Step {
    param(
        [string]$Message,
        [int]$Percent
    )

    Write-Progress -Activity 'fsociety' -Status $Message -PercentComplete $Percent
    Write-Host "[$Percent%] $Message" -ForegroundColor Cyan
}

function Get-Config {
    if (Test-Path $ConfigPath) {
        try {
            $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

            $interval = [int]$config.IntervalSeconds
            if ($interval -lt 1 -or $interval -gt 3600) {
                $interval = 1
            }

            return @{
                IntervalSeconds = $interval
                Enabled = [bool]$config.Enabled
            }
        } catch {}
    }

    return @{
        IntervalSeconds = 1
        Enabled = $true
    }
}

function Save-Config {
    param(
        [int]$IntervalSeconds,
        [bool]$Enabled
    )

    if ($IntervalSeconds -lt 1 -or $IntervalSeconds -gt 3600) {
        throw 'The interval must be between 1 and 3600 seconds.'
    }

    $config = @{
        IntervalSeconds = $IntervalSeconds
        Enabled = $Enabled
    }

    $config | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Test-PngFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $stream = $null

    try {
        $stream = [System.IO.File]::OpenRead($Path)

        if ($stream.Length -lt 8) {
            return $false
        }

        $signature = New-Object byte[] 8
        [void]$stream.Read($signature, 0, 8)

        $expected = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)

        for ($i = 0; $i -lt 8; $i++) {
            if ($signature[$i] -ne $expected[$i]) {
                return $false
            }
        }

        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Test-PowerShellFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $contents = Get-Content -LiteralPath $Path -Raw

        if ($contents.Length -lt 1000) {
            return $false
        }

        if ($contents -match '(?i)^\s*<!DOCTYPE html|^\s*<html') {
            return $false
        }

        if ($contents -match 'YOUR_GITHUB_USERNAME') {
            return $false
        }

        if ($contents -notmatch 'function Install-Utility') {
            return $false
        }

        if ($contents -notmatch 'function Start-DaemonProcess') {
            return $false
        }

        return $true
    } catch {
        return $false
    }
}

function Download-VerifiedFiles {
    param(
        [string]$DestinationScript,
        [string]$DestinationWallpaper
    )

    if ($RepoOwner -eq 'YOUR_GITHUB_USERNAME') {
        throw 'Edit install.ps1 and replace YOUR_GITHUB_USERNAME before running it.'
    }

    Write-Step 'Downloading installer from GitHub' 15

    Invoke-WebRequest -Uri $ScriptUrl -OutFile $DestinationScript -UseBasicParsing -ErrorAction Stop

    if (-not (Test-PowerShellFile $DestinationScript)) {
        throw 'The downloaded installer failed validation. Check the repository and install.ps1.'
    }

    Write-Step 'Downloading wallpaper from GitHub' 35

    Invoke-WebRequest -Uri $WallpaperUrl -OutFile $DestinationWallpaper -UseBasicParsing -ErrorAction Stop

    if (-not (Test-PngFile $DestinationWallpaper)) {
        throw 'The wallpaper download is not a valid PNG. Upload the wallpaper as 1234.png to the repository main branch.'
    }
}

function Add-UserPath {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $entries = @($userPath -split ';' | Where-Object { $_ })
    }

    $alreadyExists = $false

    foreach ($entry in $entries) {
        if ($entry.TrimEnd('\') -ieq $InstallDir.TrimEnd('\')) {
            $alreadyExists = $true
            break
        }
    }

    if (-not $alreadyExists) {
        $entries += $InstallDir
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    }

    if (($env:Path -split ';' | Where-Object { $_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\') }).Count -eq 0) {
        $env:Path = "$InstallDir;$env:Path"
    }
}

function Remove-UserPath {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    if ([string]::IsNullOrWhiteSpace($userPath)) {
        return
    }

    $entries = @(
        $userPath -split ';' |
        Where-Object {
            $_ -and $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\')
        }
    )

    [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')

    $processEntries = @(
        $env:Path -split ';' |
        Where-Object {
            $_ -and $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\')
        }
    )

    $env:Path = $processEntries -join ';'
}

function Register-Startup {
    if (-not (Test-Path $RunKeyPath)) {
        New-Item -Path $RunKeyPath -Force | Out-Null
    }

    $runCommand = '"' + $PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Daemon'

    Set-ItemProperty -Path $RunKeyPath -Name $RunValueName -Value $runCommand
}

function Unregister-Startup {
    if (Test-Path $RunKeyPath) {
        Remove-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue
    }
}

function Stop-Daemon {
    try {
        $stopEvent = [System.Threading.EventWaitHandle]::OpenExisting($StopEventName)
        [void]$stopEvent.Set()
        $stopEvent.Dispose()
    } catch {}

    for ($i = 0; $i -lt 30; $i++) {
        $mutex = $null

        try {
            $mutex = [System.Threading.Mutex]::OpenExisting($MutexName)

            $acquired = $false

            try {
                $acquired = $mutex.WaitOne(100)
            } catch [System.Threading.AbandonedMutexException] {
                $acquired = $true
            }

            if ($acquired) {
                $mutex.ReleaseMutex()
                $mutex.Dispose()
                return
            }
        } catch [System.Threading.WaitHandleCannotBeOpenedException] {
            return
        } catch {
        } finally {
            if ($null -ne $mutex) {
                $mutex.Dispose()
            }
        }

        Start-Sleep -Milliseconds 100
    }
}

function Start-DaemonProcess {
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw 'The installed script is missing. Run fsociety install.'
    }

    Stop-Daemon

    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Daemon'

    Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -WindowStyle Hidden
}

function Set-WallpaperNow {
    if (-not (Test-PngFile $WallpaperPath)) {
        throw 'The wallpaper is missing or invalid. Run fsociety update.'
    }

    if (-not ('FsocietyWallpaperNative' -as [type])) {
        $nativeCode = @"
using System;
using System.Runtime.InteropServices;

public class FsocietyWallpaperNative
{
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool SystemParametersInfo(int action, int parameter, string path, int flags);
}
"@

        Add-Type -TypeDefinition $nativeCode
    }

    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $WallpaperPath

    $success = [FsocietyWallpaperNative]::SystemParametersInfo(20, 0, $WallpaperPath, 3)

    if (-not $success) {
        throw 'Windows could not apply the wallpaper.'
    }
}

function Set-Enabled {
    param([bool]$Enabled)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw 'fsociety is not installed. Run fsociety install first.'
    }

    $config = Get-Config
    Save-Config -IntervalSeconds $config.IntervalSeconds -Enabled $Enabled

    if ($Enabled) {
        Register-Startup
        Start-DaemonProcess
        Write-Host 'fsociety enforcement is enabled.' -ForegroundColor Green
    } else {
        Unregister-Startup
        Stop-Daemon
        Write-Host 'fsociety enforcement is disabled.' -ForegroundColor Yellow
    }
}

function Install-Utility {
    $tempDir = Join-Path $env:TEMP ('fsociety-' + [guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $tempScript = Join-Path $tempDir 'install.ps1'
        $tempWallpaper = Join-Path $tempDir '1234.png'

        Write-Step 'Preparing installation' 5

        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

        Download-VerifiedFiles -DestinationScript $tempScript -DestinationWallpaper $tempWallpaper

        Write-Step 'Stopping any existing wallpaper daemon' 50
        Stop-Daemon

        Write-Step 'Installing verified files' 65

        Copy-Item -LiteralPath $tempScript -Destination $ScriptPath -Force
        Copy-Item -LiteralPath $tempWallpaper -Destination $WallpaperPath -Force

        Save-Config -IntervalSeconds 1 -Enabled $true

        Set-Content -LiteralPath $ShimPath -Encoding ASCII -Value @(
            '@echo off'
            '"' + $PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" %*'
        )

        Add-UserPath

        try {
            (Get-Item -LiteralPath $InstallDir -Force).Attributes = 'Hidden'
        } catch {}

        Write-Step 'Registering sign-in startup' 80
        Register-Startup

        Write-Step 'Applying wallpaper' 90
        Set-WallpaperNow

        Write-Step 'Starting background enforcement' 97
        Start-DaemonProcess

        Write-Progress -Activity 'fsociety' -Completed

        Write-Host ''
        Write-Host 'fsociety installed successfully.' -ForegroundColor Green
        Write-Host "Installation folder: $InstallDir"
        Write-Host 'Open a new PowerShell window if the fsociety command is not recognized.'
        Write-Host 'Run fsociety help to see all commands.'
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Update-Utility {
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        throw 'fsociety is not installed. Run the installation command first.'
    }

    $tempDir = Join-Path $env:TEMP ('fsociety-update-' + [guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $tempScript = Join-Path $tempDir 'install.ps1'
        $tempWallpaper = Join-Path $tempDir '1234.png'

        Write-Step 'Downloading the latest version' 15
        Download-VerifiedFiles -DestinationScript $tempScript -DestinationWallpaper $tempWallpaper

        $config = Get-Config

        Write-Step 'Stopping background enforcement' 50
        Stop-Daemon

        Write-Step 'Replacing application and wallpaper files' 70
        Copy-Item -LiteralPath $tempScript -Destination $ScriptPath -Force
        Copy-Item -LiteralPath $tempWallpaper -Destination $WallpaperPath -Force

        Save-Config -IntervalSeconds $config.IntervalSeconds -Enabled $config.Enabled

        if ($config.Enabled) {
            Write-Step 'Reapplying wallpaper and restarting enforcement' 90
            Set-WallpaperNow
            Register-Startup
            Start-DaemonProcess
        } else {
            Write-Step 'Preserving disabled state' 90
            Unregister-Startup
        }

        Write-Progress -Activity 'fsociety' -Completed
        Write-Host 'fsociety updated successfully. Your settings were preserved.' -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-Status {
    $config = Get-Config

    $daemonRunning = $false
    $mutex = $null

    try {
        $mutex = [System.Threading.Mutex]::OpenExisting($MutexName)

        try {
            $acquired = $mutex.WaitOne(0)

            if ($acquired) {
                $mutex.ReleaseMutex()
            } else {
                $daemonRunning = $true
            }
        } catch [System.Threading.AbandonedMutexException] {
            $mutex.ReleaseMutex()
        }
    } catch {
        $daemonRunning = $false
    } finally {
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }

    Write-Host 'fsociety status'
    Write-Host "Installed: $(Test-Path -LiteralPath $ScriptPath)"
    Write-Host "Wallpaper file valid: $(Test-PngFile $WallpaperPath)"
    Write-Host "Enforcement enabled: $($config.Enabled)"
    Write-Host "Daemon running: $daemonRunning"
    Write-Host "Check interval: $($config.IntervalSeconds) second(s)"
}

function Uninstall-Utility {
    Write-Host 'Stopping background enforcement...' -ForegroundColor Cyan
    Unregister-Startup
    Stop-Daemon

    Write-Host 'Removing user PATH entry...' -ForegroundColor Cyan
    Remove-UserPath

    Write-Host 'Removing installed files...' -ForegroundColor Cyan

    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }

    Write-Host 'fsociety has been uninstalled.' -ForegroundColor Green
}

function Run-Daemon {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return
    }

    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
    $ownsMutex = $false
    $stopEvent = $null

    try {
        try {
            $ownsMutex = $mutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $ownsMutex = $true
        }

        if (-not $ownsMutex) {
            return
        }

        $stopEvent = New-Object System.Threading.EventWaitHandle(
            $false,
            [System.Threading.EventResetMode]::AutoReset,
            $StopEventName
        )

        while ($true) {
            $config = Get-Config

            if (-not $config.Enabled) {
                break
            }

            if ($stopEvent.WaitOne(0)) {
                break
            }

            try {
                $currentWallpaper = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper

                if ($currentWallpaper -ine $WallpaperPath) {
                    Set-WallpaperNow
                }
            } catch {}

            if ($stopEvent.WaitOne([int]($config.IntervalSeconds * 1000))) {
                break
            }
        }
    } finally {
        if ($null -ne $stopEvent) {
            $stopEvent.Dispose()
        }

        if ($ownsMutex) {
            try {
                $mutex.ReleaseMutex()
            } catch {}
        }

        $mutex.Dispose()
    }
}

if ($Daemon) {
    Run-Daemon
    exit
}

try {
    switch ($Command.ToLowerInvariant()) {
        'install' {
            Install-Utility
        }

        'on' {
            Set-Enabled -Enabled $true
        }

        'off' {
            Set-Enabled -Enabled $false
        }

        'status' {
            Show-Status
        }

        'set' {
            if ($Value) {
                if (-not (Test-PngFile $Value)) {
                    throw 'The supplied file is not a valid PNG.'
                }

                Copy-Item -LiteralPath $Value -Destination $WallpaperPath -Force
            }

            Set-WallpaperNow
            Write-Host 'Wallpaper applied.' -ForegroundColor Green
        }

        'time' {
            $seconds = 0

            if (-not [int]::TryParse($Value, [ref]$seconds)) {
                throw 'Usage: fsociety time <seconds>'
            }

            if ($seconds -lt 1 -or $seconds -gt 3600) {
                throw 'The interval must be between 1 and 3600 seconds.'
            }

            if (-not (Test-Path -LiteralPath $ConfigPath)) {
                throw 'fsociety is not installed. Run fsociety install first.'
            }

            $config = Get-Config
            Save-Config -IntervalSeconds $seconds -Enabled $config.Enabled

            Write-Host "Wallpaper check interval set to $seconds second(s)." -ForegroundColor Green
        }

        'update' {
            Update-Utility
        }

        'help' {
            Write-Host 'fsociety commands'
            Write-Host '  fsociety install       Install or reinstall'
            Write-Host '  fsociety on            Enable enforcement'
            Write-Host '  fsociety off           Disable enforcement'
            Write-Host '  fsociety status        Show current status'
            Write-Host '  fsociety set           Reapply the installed wallpaper'
            Write-Host '  fsociety set <png>     Replace the wallpaper with a PNG'
            Write-Host '  fsociety time <seconds> Set the check interval'
            Write-Host '  fsociety update        Update files and wallpaper'
            Write-Host '  fsociety uninstall     Remove fsociety completely'
            Write-Host '  fsociety help          Show this help'
        }

        'uninstall' {
            Uninstall-Utility
        }

        default {
            throw "Unknown command '$Command'. Run fsociety help."
        }
    }
} catch {
    Write-Progress -Activity 'fsociety' -Completed
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
