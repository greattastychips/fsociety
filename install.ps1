
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
$MutexName = 'Local\fsociety-wallpaper-daemon'
$StopEventName = 'Local\fsociety-wallpaper-stop'

function Show-Stage([string]$Message, [int]$Percent) {
    Write-Progress -Activity 'fsociety setup' -Status $Message -PercentComplete $Percent
    Write-Host "[$Percent%] $Message"
}

function Get-Config {
    $config = @{
        Enabled = $true
        Interval = 1
    }

    if (Test-Path $ConfigPath) {
        try {
            $saved = Get-Content $ConfigPath -Raw | ConvertFrom-Json

            if ($null -ne $saved.Enabled) {
                $config.Enabled = [bool]$saved.Enabled
            }

            if ($null -ne $saved.Interval) {
                $config.Interval = [Math]::Max(1, [int]$saved.Interval)
            }
        } catch {}
    }

    return $config
}

function Save-Config($Config) {
    $Config | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Download-File([string]$Url, [string]$Destination) {
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing

    if (-not (Test-Path $Destination) -or (Get-Item $Destination).Length -lt 1000) {
        throw "Download failed or returned an invalid file: $Url"
    }
}

function Test-PowerShellFile([string]$Path) {
    $tokens = $null
    $parseErrors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -gt 0) {
        throw 'The downloaded script contains PowerShell syntax errors.'
    }

    $contents = Get-Content -LiteralPath $Path -Raw

    if ($contents -match "(?m)^\s*\`$RepoOwner\s*=\s*'YOUR_GITHUB_USERNAME'\s*$") {
        throw 'Set your GitHub username in the published install.ps1 first.'
    }
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

function Stop-Daemon {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)

    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $event = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
            $null = $event.Set()
            $event.Dispose()
        } catch {}

        $mutex = $null
        $acquired = $false

        try {
            $mutex = [Threading.Mutex]::OpenExisting($MutexName)

            try {
                $acquired = $mutex.WaitOne(0)
            } catch [Threading.AbandonedMutexException] {
                $acquired = $true
            }

            if ($acquired) {
                $mutex.ReleaseMutex()
                return
            }
        } catch [Threading.WaitHandleCannotBeOpenedException] {
            return
        } finally {
            if ($null -ne $mutex) {
                $mutex.Dispose()
            }
        }

        Start-Sleep -Milliseconds 200
    }

    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^powershell(\.exe)?$' -and
            $_.CommandLine -and
            $_.CommandLine.Contains($ScriptPath) -and
            $_.CommandLine -match '(?i)-Daemon'
        }

    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds 300
}

function Start-DaemonProcess {
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$ScriptPath`"",
        '-Daemon'
    )
}

function Register-Commands {
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

    if (-not ($paths | Where-Object {
        $_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\')
    })) {
        $paths += $InstallDir
        [Environment]::SetEnvironmentVariable('Path', ($paths -join ';'), 'User')
    }
}

function Remove-CommandRegistration {
    Remove-Item -LiteralPath $StartupPath -Force -ErrorAction SilentlyContinue

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $paths = @($userPath -split ';' | Where-Object {
        $_ -and $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\')
    })

    [Environment]::SetEnvironmentVariable('Path', ($paths -join ';'), 'User')
}

function Install-Utility {
    if ($RepoOwner -eq 'YOUR_GITHUB_USERNAME') {
        throw 'Replace YOUR_GITHUB_USERNAME before publishing install.ps1.'
    }

    $tempScript = Join-Path $env:TEMP 'fsociety-install.ps1'
    $tempWallpaper = Join-Path $env:TEMP 'fsociety-wallpaper.png'

    try {
        Show-Stage 'Creating the installation directory' 10
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

        Show-Stage 'Downloading the latest program' 25
        Download-File "$RawBase/install.ps1" $tempScript
        Test-PowerShellFile $tempScript

        Show-Stage 'Downloading the wallpaper' 40
        Download-File $WallpaperUrl $tempWallpaper

        Show-Stage 'Stopping any previous fsociety instance' 50
        Stop-Daemon

        $folder = Get-Item $InstallDir
        $folder.Attributes = $folder.Attributes -bor [IO.FileAttributes]::Hidden

        Show-Stage 'Installing program files' 65
        Copy-Item $tempScript $ScriptPath -Force
        Copy-Item $tempWallpaper $WallpaperPath -Force

        if (-not (Test-Path $ConfigPath)) {
            Save-Config @{
                Enabled = $true
                Interval = 1
            }
        }

        Show-Stage 'Registering commands and sign-in startup' 80
        Register-Commands

        Show-Stage 'Applying wallpaper' 90
        $config = Get-Config

        if ($config.Enabled) {
            Set-Wallpaper $WallpaperPath
        }

        Show-Stage 'Starting background checker' 100
        Start-DaemonProcess

        Write-Progress -Activity 'fsociety setup' -Completed
        Write-Host 'fsociety installation completed.'
        Write-Host 'Open a new terminal to use the fsociety command.'
    } finally {
        Remove-Item $tempScript, $tempWallpaper -Force -ErrorAction SilentlyContinue
        Write-Progress -Activity 'fsociety setup' -Completed
    }
}

function Update-Utility {
    if ($RepoOwner -eq 'YOUR_GITHUB_USERNAME') {
        throw 'Replace YOUR_GITHUB_USERNAME before updating.'
    }

    $tempScript = Join-Path $env:TEMP 'fsociety-update.ps1'
    $tempWallpaper = Join-Path $env:TEMP 'fsociety-update.png'
    $backupScript = Join-Path $env:TEMP 'fsociety-backup.ps1'
    $backupWallpaper = Join-Path $env:TEMP 'fsociety-backup.png'

    $hadScript = Test-Path $ScriptPath
    $hadWallpaper = Test-Path $WallpaperPath
    $daemonStopped = $false

    try {
        Show-Stage 'Downloading the new program' 15
        Download-File "$RawBase/install.ps1" $tempScript
        Test-PowerShellFile $tempScript

        Show-Stage 'Downloading the current wallpaper' 30
        Download-File $WallpaperUrl $tempWallpaper

        if ($hadScript) {
            Copy-Item $ScriptPath $backupScript -Force
        }

        if ($hadWallpaper) {
            Copy-Item $WallpaperPath $backupWallpaper -Force
        }

        Show-Stage 'Stopping the background checker' 45
        Stop-Daemon
        $daemonStopped = $true

        Show-Stage 'Replacing program files' 65
        Copy-Item $tempScript $ScriptPath -Force
        Copy-Item $tempWallpaper $WallpaperPath -Force

        Show-Stage 'Refreshing command and startup registration' 80
        Register-Commands

        $config = Get-Config

        if ($config.Enabled) {
            Show-Stage 'Applying updated wallpaper' 90
            Set-Wallpaper $WallpaperPath
        }

        Show-Stage 'Restarting background checker' 100
        Start-DaemonProcess

        Write-Progress -Activity 'fsociety setup' -Completed
        Write-Host 'fsociety update completed. Your settings were preserved.'
    } catch {
        if ($hadScript -and (Test-Path $backupScript)) {
            Copy-Item $backupScript $ScriptPath -Force
        }

        if ($hadWallpaper -and (Test-Path $backupWallpaper)) {
            Copy-Item $backupWallpaper $WallpaperPath -Force
        }

        if ($daemonStopped -and (Test-Path $ScriptPath)) {
            Start-DaemonProcess
        }

        throw
    } finally {
        Remove-Item $tempScript, $tempWallpaper, $backupScript, $backupWallpaper `
            -Force -ErrorAction SilentlyContinue
        Write-Progress -Activity 'fsociety setup' -Completed
    }
}

function Start-Daemon {
    $mutex = New-Object Threading.Mutex($false, $MutexName)
    $ownsMutex = $false
    $stopEvent = $null

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

        while ($true) {
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
        if ($null -ne $stopEvent) {
            $stopEvent.Dispose()
        }

        if ($ownsMutex) {
            $mutex.ReleaseMutex()
        }

        $mutex.Dispose()
    }
}

function Show-Help {
    @'
fsociety commands:
  fsociety install
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

$command = if ($args.Count -gt 0) {
    [string]$args[0]
} else {
    'install'
}

switch ($command.ToLowerInvariant()) {
    'install' {
        Install-Utility
    }

    'on' {
        $config = Get-Config
        $config.Enabled = $true
        Save-Config $config
        Set-Wallpaper $WallpaperPath
        Write-Host 'Wallpaper enforcement enabled.'
    }

    'off' {
        $config = Get-Config
        $config.Enabled = $false
        Save-Config $config
        Write-Host 'Wallpaper enforcement disabled.'
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
        Write-Host 'Wallpaper applied.'
    }

    'time' {
        if ($args.Count -lt 2) {
            throw 'Usage: fsociety time <seconds>'
        }

        $seconds = 0

        if (-not [int]::TryParse([string]$args[1], [ref]$seconds) -or
            $seconds -lt 1 -or $seconds -gt 86400) {
            throw 'Enter a whole number from 1 to 86400.'
        }

        $config = Get-Config
        $config.Interval = $seconds
        Save-Config $config
        Write-Host "Interval set to $seconds second(s)."
    }

    'update' {
        Update-Utility
    }

    'help' {
        Show-Help
    }

    'uninstall' {
        Write-Host 'Stopping fsociety...'
        Stop-Daemon

        Write-Host 'Removing startup registration and command path...'
        Remove-CommandRegistration

        Write-Host 'Removing fsociety files...'
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue

        Write-Host 'Uninstall completed. The current wallpaper was left unchanged.'
        Write-Host 'Open a new terminal to refresh its PATH.'
    }

    default {
        Show-Help
    }
}
