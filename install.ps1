
param(
    [switch]$Update,
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
$StartupDir = [Environment]::GetFolderPath('Startup')
$StartupPath = Join-Path $StartupDir 'fsociety.cmd'

function Write-Info([string]$Message) {
    Write-Host "[fsociety] $Message"
}

function Get-Config {
    $defaults = @{
        Enabled = $true
        Interval = 1
    }

    if (Test-Path $ConfigPath) {
        try {
            $saved = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            if ($null -ne $saved.Enabled) {
                $defaults.Enabled = [bool]$saved.Enabled
            }
            if ($null -ne $saved.Interval) {
                $defaults.Interval = [Math]::Max(1, [int]$saved.Interval)
            }
        } catch {}
    }

    return $defaults
}

function Save-Config($Config) {
    $Config | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Set-Wallpaper([string]$Path) {
    if (-not (Test-Path $Path)) {
        throw "Wallpaper file not found: $Path"
    }

    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class WallpaperApi {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern int SystemParametersInfo(
        int action, int param, string path, int flags
    );
}
'@ -ErrorAction SilentlyContinue

    $result = [WallpaperApi]::SystemParametersInfo(20, 0, $Path, 3)
    if ($result -eq 0) {
        throw 'Windows could not apply the wallpaper.'
    }
}

function Get-CurrentWallpaper {
    try {
        Get-ItemPropertyValue -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper
    } catch {
        return ''
    }
}

function Download-Wallpaper {
    Invoke-WebRequest -Uri $WallpaperUrl -OutFile $WallpaperPath -UseBasicParsing

    if (-not (Test-Path $WallpaperPath) -or (Get-Item $WallpaperPath).Length -lt 1024) {
        throw 'Wallpaper download failed or returned an invalid file.'
    }
}

function Install-Utility {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

    $folder = Get-Item $InstallDir
    $folder.Attributes = $folder.Attributes -bor [IO.FileAttributes]::Hidden

    if (-not (Test-Path $WallpaperPath)) {
        Download-Wallpaper
    }

    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $ScriptPath -Force
    }

    $config = Get-Config
    Save-Config $config

    @'
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%LOCALAPPDATA%\1234\fsociety.ps1" -Daemon
'@ | Set-Content -Path $StartupPath -Encoding ASCII

    @'
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\1234\fsociety.ps1" %*
'@ | Set-Content -Path $CommandPath -Encoding ASCII

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $InstallDir) {
        $newPath = (@($userPath.TrimEnd(';'), $InstallDir) | Where-Object { $_ }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }

    Set-Wallpaper $WallpaperPath

    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$ScriptPath`"",
        '-Daemon'
    )

    Write-Info 'Installed.'
}

function Start-Daemon {
    $mutex = New-Object Threading.Mutex($false, 'Local\fsociety-wallpaper-daemon')
    if (-not $mutex.WaitOne(0)) {
        return
    }

    try {
        while ($true) {
            $config = Get-Config

            if ($config.Enabled) {
                try {
                    if ((Get-CurrentWallpaper) -ne $WallpaperPath) {
                        Set-Wallpaper $WallpaperPath
                    }
                } catch {}
            }

            Start-Sleep -Seconds ([Math]::Max(1, $config.Interval))
        }
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
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
        Write-Info 'Enabled.'
    }

    'off' {
        $config = Get-Config
        $config.Enabled = $false
        Save-Config $config
        Write-Info 'Disabled.'
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
            Write-Output 'Usage: fsociety time <seconds>'
            exit 1
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
        $temp = Join-Path $env:TEMP 'fsociety-update.ps1'
        Invoke-WebRequest -Uri "$RawBase/install.ps1" -OutFile $temp -UseBasicParsing

        if (-not (Test-Path $temp) -or (Get-Item $temp).Length -lt 1000) {
            throw 'Update download failed.'
        }

        Copy-Item -LiteralPath $temp -Destination $ScriptPath -Force
        Remove-Item -LiteralPath $temp -Force
        Write-Info 'Updated.'
    }

    'help' {
        Show-Help
    }

    'uninstall' {
        Remove-Item -LiteralPath $StartupPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info 'Uninstalled.'
    }

    default {
        Show-Help
    }
}
