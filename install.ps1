
param(
    [Parameter(Position = 0)]
    [string]$Command = 'install',

    [Parameter(Position = 1)]
    [string]$Value,

    [switch]$Daemon
)

$ErrorActionPreference = 'Stop'

$RepoOwner = 'YOUR_GITHUB_USERNAME'
$RepoName = 'fsociety'
$Branch = 'main'

$InstallDir = Join-Path $env:LOCALAPPDATA '1234'
$ScriptPath = Join-Path $InstallDir 'install.ps1'
$WallpaperPath = Join-Path $InstallDir '1234.png'
$ConfigPath = Join-Path $InstallDir 'config.json'
$ShimPath = Join-Path $InstallDir 'fsociety.cmd'
$LogPath = Join-Path $env:TEMP 'fsociety-install.log'

$RunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName = 'fsociety'

$MutexName = 'Local\fsociety_1234_mutex'
$StopEventName = 'Local\fsociety_1234_stop'

$ScriptUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/install.ps1"
$WallpaperUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/1234.png"

$PowerShellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $PowerShellExe)) {
    $PowerShellExe = (Get-Process -Id $PID).Path
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

function Write-Log {
    param([string]$Message)

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"

    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {}

    Write-Host $Message
}

function Write-Step {
    param(
        [string]$Message,
        [int]$Percent
    )

    Write-Progress -Activity 'fsociety installation' -Status $Message -PercentComplete $Percent
    Write-Log "[$Percent%] $Message"
}

function Get-Config {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $data = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            $interval = [int]$data.IntervalSeconds

            if ($interval -lt 1 -or $interval -gt 3600) {
                $interval = 1
            }

            return @{
                IntervalSeconds = $interval
                Enabled = [bool]$data.Enabled
            }
        } catch {
            Write-Log "Config read failed; using defaults: $($_.Exception.Message)"
        }
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
        throw 'Interval must be between 1 and 3600 seconds.'
    }

    @{
        IntervalSeconds = $IntervalSeconds
        Enabled = $Enabled
    } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Test-PngFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $stream = $null

    try {
        $stream = [System.IO.File]::OpenRead($Path)

        if ($stream.Length -lt 100) {
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

        if ($contents -notmatch 'function Run-Daemon') {
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

    if ([string]::IsNullOrWhiteSpace($RepoOwner) -or $RepoOwner -eq 'YOUR_GITHUB_USERNAME') {
        throw 'Edit install.ps1 and set $RepoOwner to your GitHub username.'
    }

    Write-Step 'Downloading installer from GitHub' 15

    Invoke-WebRequest -Uri $ScriptUrl -OutFile $DestinationScript -UseBasicParsing -ErrorAction Stop

    if (-not (Test-PowerShellFile $DestinationScript)) {
        throw 'The installer downloaded from GitHub failed validation. Check the repository, branch, and username.'
    }

    Write-Step 'Downloading wallpaper from GitHub' 35

    Invoke-WebRequest -Uri $WallpaperUrl -OutFile $DestinationWallpaper -UseBasicParsing -ErrorAction Stop

    if (-not (Test-PngFile $DestinationWallpaper)) {
        throw '1234.png is missing or is not a valid PNG. Upload the actual image to the repository root on the main branch.'
    }
}

function Add-UserPath {
    $entries = @(
        [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' |
        Where-Object { $_ }
    )

    $exists = $false

    foreach ($entry in $entries) {
        if ($entry.TrimEnd('\') -ieq $InstallDir.TrimEnd('\')) {
            $exists = $true
        }
    }

    if (-not $exists) {
        $entries += $InstallDir
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    }

    if (-not (($env:Path -split ';') | Where-Object {
        $_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\')
    })) {
        $env:Path = "$InstallDir;$env:Path"
    }
}

function Remove-UserPath {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    $entries = @(
        $userPath -split ';' |
        Where-Object {
            $_ -and $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\')
        }
    )

    [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')

    $env:Path = (@(
        $env:Path -split ';' |
        Where-Object {
            $_ -and $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\')
        }
    ) -join ';')
}

function Register-Startup {
    if (-not (Test-Path $RunKeyPath)) {
        New-Item -Path $RunKeyPath -Force | Out-Null
    }

    $startupCommand = '"' + $PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Daemon'

    Set-ItemProperty -Path $RunKeyPath -Name $RunValueName -Value $startupCommand
}

function Unregister-Startup {
    if (Test-Path $RunKeyPath) {
        Remove-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue
    }
}

function Stop-Daemon {
    try {
        $eventHandle = [System.Threading.EventWaitHandle]::OpenExisting($StopEventName)
        [void]$eventHandle.Set()
        $eventHandle.Dispose()
    } catch {}

    for ($i = 0; $i -lt 50; $i++) {
        $mutexHandle = $null

        try {
            $mutexHandle = [System.Threading.Mutex]::OpenExisting($MutexName)

            $acquired = $false

            try {
                $acquired = $mutexHandle.WaitOne(100)
            } catch [System.Threading.AbandonedMutexException] {
                $acquired = $true
            }

            if ($acquired) {
                $mutexHandle.ReleaseMutex()
                return
            }
        } catch [System.Threading.WaitHandleCannotBeOpenedException] {
            return
        } catch {
        } finally {
            if ($null -ne $mutexHandle) {
                $mutexHandle.Dispose()
            }
        }

        Start-Sleep -Milliseconds 100
    }

    Write-Log 'Warning: timed out waiting for the background process to stop.'
}

function Start-DaemonProcess {
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw 'Installed script not found.'
    }

    Stop-Daemon

    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Daemon'
    Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -WindowStyle Hidden
}

function Set-WallpaperNow {
    if (-not (Test-PngFile $WallpaperPath)) {
        throw 'Wallpaper file is missing or invalid. Run fsociety update.'
    }

    if (-not ('FsocietyWallpaperNative' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class FsocietyWallpaperNative
{
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool SystemParametersInfo(int action, int parameter, string path, int flags);
}
"@
    }

    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $WallpaperPath

    $success = [FsocietyWallpaperNative]::SystemParametersInfo(20, 0, $WallpaperPath, 3)

    if (-not $success) {
        throw 'Windows failed to apply the wallpaper.'
    }
}

function Install-Utility {
    $tempDir = Join-Path $env:TEMP ('fsociety-' + [guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $tempScript = Join-Path $tempDir 'install.ps1'
        $tempWallpaper = Join-Path $tempDir '1234.png'

        Write-Step 'Preparing installation' 5

        Download-VerifiedFiles -DestinationScript $tempScript -DestinationWallpaper $tempWallpaper

        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

        Write-Step 'Stopping previous background process' 50
        Stop-Daemon

        Write-Step 'Installing application files' 65
        Copy-Item -LiteralPath $tempScript -Destination $ScriptPath -Force
        Copy-Item -LiteralPath $tempWallpaper -Destination $WallpaperPath -Force

        Save-Config -IntervalSeconds 1 -Enabled $true

        @(
            '@echo off'
            '"' + $PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" %*'
        ) | Set-Content -LiteralPath $ShimPath -Encoding ASCII

        Add-UserPath

        try {
            $folder = Get-Item -LiteralPath $InstallDir -Force
            $folder.Attributes = $folder.Attributes -bor [System.IO.FileAttributes]::Hidden
        } catch {}

        Write-Step 'Registering sign-in startup' 80
        Register-Startup

        Write-Step 'Applying wallpaper' 90
        Set-WallpaperNow

        Write-Step 'Starting wallpaper enforcement' 97
        Start-DaemonProcess

        Write-Progress -Activity 'fsociety installation' -Completed
        Write-Log 'Installation completed successfully.'
        Write-Host "Install folder: $InstallDir"
        Write-Host 'Open a new PowerShell window to use the fsociety command.'
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Update-Utility {
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        throw 'fsociety is not installed. Run fsociety install first.'
    }

    $tempDir = Join-Path $env:TEMP ('fsociety-update-' + [guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $tempScript = Join-Path $tempDir 'install.ps1'
        $tempWallpaper = Join-Path $tempDir '1234.png'

        Download-VerifiedFiles -DestinationScript $tempScript -DestinationWallpaper $tempWallpaper

        $config = Get-Config

        Write-Step 'Stopping background process' 50
        Stop-Daemon

        Write-Step 'Updating application and wallpaper' 70
        Copy-Item -LiteralPath $tempScript -Destination $ScriptPath -Force
        Copy-Item -LiteralPath $tempWallpaper -Destination $WallpaperPath -Force

        Save-Config -IntervalSeconds $config.IntervalSeconds -Enabled $config.Enabled

        if ($config.Enabled) {
            Set-WallpaperNow
            Register-Startup
            Start-DaemonProcess
        } else {
            Unregister-Startup
        }

        Write-Progress -Activity 'fsociety update' -Completed
        Write-Log 'Update completed; configuration preserved.'
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
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
        Set-WallpaperNow
        Start-DaemonProcess
        Write-Log 'Wallpaper enforcement enabled.'
    } else {
        Unregister-Startup
        Stop-Daemon
        Write-Log 'Wallpaper enforcement disabled.'
    }
}

function Show-Status {
    $config = Get-Config
    $running = $false
    $mutexHandle = $null

    try {
        $mutexHandle = [System.Threading.Mutex]::OpenExisting($MutexName)

        try {
            $acquired = $mutexHandle.WaitOne(0)

            if ($acquired) {
                $mutexHandle.ReleaseMutex()
            } else {
                $running = $true
            }
        } catch [System.Threading.AbandonedMutexException] {
            $mutexHandle.ReleaseMutex()
        }
    } catch {
        $running = $false
    } finally {
        if ($null -ne $mutexHandle) {
            $mutexHandle.Dispose()
        }
    }

    Write-Host "Installed: $(Test-Path -LiteralPath $ScriptPath)"
    Write-Host "Wallpaper valid: $(Test-PngFile $WallpaperPath)"
    Write-Host "Enforcement enabled: $($config.Enabled)"
    Write-Host "Background process running: $running"
    Write-Host "Interval: $($config.IntervalSeconds) second(s)"
}

function Uninstall-Utility {
    Write-Log 'Stopping wallpaper enforcement...'
    Unregister-Startup
    Stop-Daemon
    Remove-UserPath

    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }

    Write-Log 'fsociety was uninstalled.'
}

function Run-Daemon {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return
    }

    $mutexHandle = [System.Threading.Mutex]::new($false, $MutexName)
    $ownsMutex = $false
    $eventHandle = $null

    try {
        try {
            $ownsMutex = $mutexHandle.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $ownsMutex = $true
        }

        if (-not $ownsMutex) {
            return
        }

        $eventHandle = [System.Threading.EventWaitHandle]::new(
            $false,
            [System.Threading.EventResetMode]::AutoReset,
            $StopEventName
        )

        while ($true) {
            $config = Get-Config

            if (-not $config.Enabled) {
                break
            }

            try {
                $current = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper

                if ($current -ine $WallpaperPath) {
                    Set-WallpaperNow
                }
            } catch {}

            if ($eventHandle.WaitOne([int]($config.IntervalSeconds * 1000))) {
                break
            }
        }
    } finally {
        if ($null -ne $eventHandle) {
            $eventHandle.Dispose()
        }

        if ($ownsMutex) {
            try {
                $mutexHandle.ReleaseMutex()
            } catch {}
        }

        $mutexHandle.Dispose()
    }
}

if ($Daemon) {
    try {
        Run-Daemon
    } catch {
        Write-Log "Background process error: $($_.Exception.Message)"
    }

    return
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
            Write-Log 'Wallpaper applied.'
        }

        'time' {
            $seconds = 0

            if (-not [int]::TryParse($Value, [ref]$seconds)) {
                throw 'Usage: fsociety time <seconds>'
            }

            if ($seconds -lt 1 -or $seconds -gt 3600) {
                throw 'Interval must be between 1 and 3600 seconds.'
            }

            $config = Get-Config
            Save-Config -IntervalSeconds $seconds -Enabled $config.Enabled

            if ($config.Enabled) {
                Start-DaemonProcess
            }

            Write-Log "Interval set to $seconds second(s)."
        }

        'update' {
            Update-Utility
        }

        'uninstall' {
            Uninstall-Utility
        }

        'help' {
            Write-Host 'fsociety commands:'
            Write-Host '  fsociety install'
            Write-Host '  fsociety on'
            Write-Host '  fsociety off'
            Write-Host '  fsociety status'
            Write-Host '  fsociety set'
            Write-Host '  fsociety set "C:\path\image.png"'
            Write-Host '  fsociety time 20'
            Write-Host '  fsociety update'
            Write-Host '  fsociety uninstall'
            Write-Host '  fsociety help'
        }

        default {
            throw "Unknown command '$Command'. Run fsociety help."
        }
    }
} catch {
    Write-Progress -Activity 'fsociety' -Completed

    $message = $_.Exception.Message
    Write-Log "ERROR: $message"
    Write-Host "Full error log: $LogPath" -ForegroundColor Yellow
}
