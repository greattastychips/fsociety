
param(
    [switch]$Daemon
)

$ErrorActionPreference = 'Stop'

$RepoOwner = 'greattastychips'
$RepoName = 'fsociety'
$RawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/main"
$WallpaperUrl = 'https://rare-gallery.com/thumbs/4501587-elliot-mr-robot-face-mr.-robot-tv-fsociety-simple-background-black-background-monochrome.png'

$InstallDir = Join-Path $env:LOCALAPPDATA '1234'
$WallpaperPath = Join-Path $InstallDir '1234.png'
$ScriptPath = Join-Path $InstallDir 'fsociety.ps1'
$ConfigPath = Join-Path $InstallDir 'config.json'
$CommandPath = Join-Path $InstallDir 'fsociety.cmd'
$StartupPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'fsociety-startup.cmd'
$DaemonMutexName = 'Local\fsociety-wallpaper-daemon'
$StopEventName = 'Local\fsociety-wallpaper-stop'

function Write-Info([string]$Message) {
    Write-Output "[fsociety] $Message"
}

function Get-Config {
    $config = @{ Enabled = $true; Interval = 1 }

    if (Test-Path $ConfigPath) {
        try {
            $saved = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            $config.Enabled = [bool]$saved.Enabled
            $config.Interval = [Math]::Max(1, [int]$saved.Interval)
        } catch {}
    }

    return $config
}

function Save-Config($Config) {
    $Config | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Set-Wallpaper([string]$Path) {
    if (-not (Test-Path $Path)) {
        throw "Wallpaper file not found: $Path"
    }

    if (-not ('FsocietyWallpaperApi' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public class FsocietyWallpaperApi {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern int SystemParametersInfo(
        int action, int param, string path, int flags
    );
}
'@
    }

    $result = [FsocietyWallpaperApi]::SystemParametersInfo(20, 0, $Path, 3)

    if ($result -eq 0) {
        throw 'Windows could not apply the wallpaper.'
    }
}

function Get-CurrentWallpaper {
    try {
        return Get-ItemPropertyValue -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper
    } catch {
        return ''
    }
}

function Download-File([string]$Url, [string]$Destination) {
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing

    if (-not (Test-Path $Destination) -or (Get-Item $Destination).Length -lt 1000) {
        throw "Download failed: $Url"
    }
}

function Stop-Daemon {
    try {
        $event = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
        $null = $event.Set()
        $event.Dispose()
    } catch {}

    Start-Sleep -Milliseconds 500
}

function Start-Daemon {
    $mutex = New-Object Threading.Mutex($false, $DaemonMutexName)
    $ownsMutex = $false

    try {
        try {
            $ownsMutex = $mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $ownsMutex = $true
        }

        if (-not $ownsMutex) {
            return
        }

        $stopEvent = New-Object Threading.EventWaitHandle(
            $false,
            [Threading.EventResetMode]::ManualReset,
            $StopEventName
        )
        $stopEvent.Reset()

        try {
            while ($true) {
                if (Test-Path (Join-Path $InstallDir 'stop.flag')) {
                    break
                }

                $config = Get-Config

                if ($config.Enabled) {
                    try {
                        if ((Get-CurrentWallpaper) -ne $WallpaperPath) {
                            Set-Wallpaper $WallpaperPath
                        }
                    } catch {}
                }

                if ($stopEvent.WaitOne([Math]::Max(1, $config.Interval) * 1000)) {
                    break
                }
            }
        } finally {
            $stopEvent.Dispose()
        }
    } finally {
        if ($ownsMutex) {
            $mutex.ReleaseMutex()
        }

        $mutex.Dispose()
    }
}

function Install-Utility {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Remove-Item (Join-Path $InstallDir 'stop.flag') -Force -ErrorAction SilentlyContinue

    $folder = Get-Item $InstallDir
    $folder.Attributes = $folder.Attributes -bor [IO.FileAttributes]::Hidden

    $tempScript = Join-Path $env:TEMP 'fsociety-install.ps1'
    $tempWallpaper = Join-Path $env:TEMP 'fsociety-wallpaper.png'

    Download-File "$RawBase/install.ps1" $tempScript
    Download-File $WallpaperUrl $tempWallpaper

    Copy-Item $tempScript $ScriptPath -Force
    Copy-Item $tempWallpaper $WallpaperPath -Force

    Remove-Item $tempScript, $tempWallpaper -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $ConfigPath)) {
        Save-Config @{ Enabled = $true; Interval = 1 }
    }

    @'
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\1234\fsociety.ps1" %*
'@ | Set-Content -Path $CommandPath -Encoding ASCII

    @'
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%LOCALAPPDATA%\1234\fsociety.ps1" -Daemon
'@ | Set-Content -Path $StartupPath -Encoding ASCII

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $paths = @($userPath -split ';' | Where-Object { $_ })

    if (-not ($paths | Where-Object { $_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\') })) {
        $paths += $InstallDir
        [Environment]::SetEnvironmentVariable('Path', ($paths -join ';'), 'User')
    }

    Set-Wallpaper $WallpaperPath

    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$ScriptPath`"",
        '-Daemon'
    )

    Write-Info 'Installed successfully.'
}

function Update-Utility {
    $temp = Join-Path $env:TEMP 'fsociety-update.ps1'

    try {
        Download-File "$RawBase/install.ps1" $temp

        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $temp,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null

        if ($parseErrors.Count -gt 0) {
            throw 'The downloaded update contains PowerShell syntax errors.'
        }

        Copy-Item -LiteralPath $temp -Destination $ScriptPath -Force
        Write-Info 'Update installed. Your settings were preserved.'
    } finally {
        Remove-Item $temp -Force -ErrorAction SilentlyContinue
    }
}

function Show-Help {
    @'
fsociety commands:
  fsociety on
  fsociety off
  fsociety status
  fsociety set
  fsociety time <seconds>
  fsociety update
  fsociety help
  fsociety uninstall
'@ | Write-Output
}

if ($Daemon) {
    Start-Daemon
    exit
}

$command = if ($args.Count -gt 0) { [string]$args[0] } else { 'install' }

switch ($command.ToLowerInvariant()) {
    'install' {
        Install-Utility
    }

    'on' {
        $config = Get-Config
        $config.Enabled = $true
        Save-Config $config
        Set-Wallpaper $WallpaperPath
        Write-Info 'Wallpaper enforcement enabled.'
    }

    'off' {
        $config = Get-Config
        $config.Enabled = $false
        Save-Config $config
        Write-Info 'Wallpaper enforcement disabled.'
    }

    'status' {
        $config = Get-Config
        Write-Output "Enabled: $($config.Enabled)"
        Write-Output "Interval: $($config.Interval) second(s)"
        Write-Output "Wallpaper: $WallpaperPath"
        Write-Output "Current wallpaper: $(Get-CurrentWallpaper)"
    }

    'set' {
        Set-Wallpaper $WallpaperPath
        Write-Info 'Wallpaper applied.'
    }

    'time' {
        if ($args.Count -lt 2) {
            throw 'Usage: fsociety time <seconds>'
        }

        $seconds = 0
        if (-not [int]::TryParse([string]$args[1], [ref]$seconds) -or $seconds -lt 1 -or $seconds -gt 86400) {
            throw 'Enter a whole number from 1 to 86400.'
        }

        $config = Get-Config
        $config.Interval = $seconds
        Save-Config $config
        Write-Info "Interval set to $seconds second(s)."
    }

    'update' {
        Update-Utility
    }

    'help' {
        Show-Help
    }

    'uninstall' {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $InstallDir 'stop.flag') -Force | Out-Null
        Stop-Daemon

        Remove-Item -LiteralPath $StartupPath -Force -ErrorAction SilentlyContinue

        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $paths = @($userPath -split ';' | Where-Object {
            $_ -and $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\')
        })
        [Environment]::SetEnvironmentVariable('Path', ($paths -join ';'), 'User')

        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info 'Uninstalled. The current wallpaper was left unchanged.'
    }

    default {
        Show-Help
    }
}
