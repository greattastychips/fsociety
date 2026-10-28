$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoOwner = 'greattastychips'
$RepoUrl = "https://raw.githubusercontent.com/$RepoOwner/fsociety/main"
$InstallRoot = Join-Path $env:LOCALAPPDATA '1234'
$ScriptPath = Join-Path $InstallRoot 'install.ps1'
$WallpaperPath = Join-Path $InstallRoot '1234.png'
$ConfigPath = Join-Path $InstallRoot 'config.json'
$PidPath = Join-Path $InstallRoot 'daemon.pid'
$LogPath = Join-Path $env:TEMP 'fsociety-install.log'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName = 'fsociety'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$ScriptArgs = @($args)
$IsDaemon = $ScriptArgs -contains '-Daemon'
$Command = 'install'
$Value = $null

if ($ScriptArgs.Count -gt 0) {
    $NormalArgs = @($ScriptArgs | Where-Object { $_ -ne '-Daemon' })
    if ($NormalArgs.Count -gt 0) {
        $Command = [string]$NormalArgs[0]
    }
    if ($NormalArgs.Count -gt 1) {
        $Value = [string]$NormalArgs[1]
    }
}

try {
    if (!(Test-Path $env:TEMP)) {
        throw 'The temporary directory is unavailable.'
    }
    if (!(Test-Path $LogPath)) {
        New-Item -Path $LogPath -ItemType File -Force | Out-Null
    }
}
catch {
    Write-Host "Could not initialize logging: $($_.Exception.Message)" -ForegroundColor Red
}

function Write-Log {
    param([string]$Message)

    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Write-Host $Line

    try {
        Add-Content -LiteralPath $LogPath -Value $Line -ErrorAction Stop
    }
    catch {
        Write-Host "Could not write to log: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Get-Config {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $Data = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            $Interval = [int]$Data.interval
            if ($Interval -lt 1) {
                $Interval = 1
            }

            return @{
                interval = $Interval
                enabled = [bool]$Data.enabled
            }
        }
        catch {
            Write-Log "Configuration could not be read: $($_.Exception.Message)"
        }
    }

    return @{
        interval = 1
        enabled = $true
    }
}

function Save-Config {
    param(
        [int]$Interval,
        [bool]$Enabled
    )

    if ($Interval -lt 1) {
        throw 'The interval must be at least one second.'
    }

    $Data = @{
        interval = $Interval
        enabled = $Enabled
    }

    $Data | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Download-Files {
    Write-Log 'Downloading installer and wallpaper from GitHub.'

    $TempScript = Join-Path $env:TEMP "fsociety-$([guid]::NewGuid().ToString('N')).ps1"
    $TempWallpaper = Join-Path $env:TEMP "fsociety-$([guid]::NewGuid().ToString('N')).png"

    try {
        Invoke-WebRequest -Uri "$RepoUrl/install.ps1" -OutFile $TempScript -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri "$RepoUrl/1234.png" -OutFile $TempWallpaper -UseBasicParsing -ErrorAction Stop

        $Source = Get-Content -LiteralPath $TempScript -Raw
        if ($Source -notmatch '(?m)^\s*\$RepoOwner\s*=\s*''[^'']+''\s*$') {
            throw 'The downloaded installer has no valid RepoOwner assignment.'
        }

        if ($Source -match "(?m)^\s*`$RepoOwner\s*=\s*'YOUR_GITHUB_USERNAME'\s*$") {
            throw 'Replace YOUR_GITHUB_USERNAME in install.ps1, commit the change, and try again.'
        }

        $Bytes = [System.IO.File]::ReadAllBytes($TempWallpaper)
        $Signature = @(137, 80, 78, 71, 13, 10, 26, 10)

        if ($Bytes.Length -lt 8) {
            throw 'The downloaded wallpaper is empty or incomplete.'
        }

        for ($i = 0; $i -lt 8; $i++) {
            if ($Bytes[$i] -ne $Signature[$i]) {
                throw 'GitHub did not return a valid PNG. Check that 1234.png exists at the repository root.'
            }
        }

        if (!(Test-Path -LiteralPath $InstallRoot)) {
            New-Item -Path $InstallRoot -ItemType Directory -Force | Out-Null
        }

        Move-Item -LiteralPath $TempScript -Destination $ScriptPath -Force
        Move-Item -LiteralPath $TempWallpaper -Destination $WallpaperPath -Force

        Write-Log 'Installer and wallpaper downloaded successfully.'
    }
    finally {
        Remove-Item -LiteralPath $TempScript, $TempWallpaper -Force -ErrorAction SilentlyContinue
    }
}

function Set-HiddenFolder {
    if (Test-Path -LiteralPath $InstallRoot) {
        $Item = Get-Item -LiteralPath $InstallRoot -Force
        $Item.Attributes = $Item.Attributes -bor [System.IO.FileAttributes]::Hidden
    }
}

function Set-UserPath {
    $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $Parts = @($UserPath -split ';' | Where-Object { $_ })

    if (!($Parts | Where-Object { $_.TrimEnd('\') -ieq $InstallRoot.TrimEnd('\') })) {
        $NewPath = (($Parts + $InstallRoot) -join ';')
        [Environment]::SetEnvironmentVariable('Path', $NewPath, 'User')
    }

    if (!($env:Path -split ';' | Where-Object { $_.TrimEnd('\') -ieq $InstallRoot.TrimEnd('\') })) {
        $env:Path = "$InstallRoot;$env:Path"
    }
}

function Remove-UserPath {
    $UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $Parts = @($UserPath -split ';' | Where-Object {
        $_ -and $_.TrimEnd('\') -ine $InstallRoot.TrimEnd('\')
    })

    [Environment]::SetEnvironmentVariable('Path', ($Parts -join ';'), 'User')
}

function Write-CommandShim {
    $ShimPath = Join-Path $InstallRoot 'fsociety.cmd'
    $Shim = "@echo off`r`n`"$PowerShellExe`" -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" %*`r`n"
    Set-Content -LiteralPath $ShimPath -Value $Shim -Encoding ASCII
}

function Set-Startup {
    if (!(Test-Path $RunKey)) {
        New-Item -Path $RunKey -Force | Out-Null
    }

    $StartupCommand = '"' + $PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Daemon'
    Set-ItemProperty -Path $RunKey -Name $RunName -Value $StartupCommand
}

function Remove-Startup {
    if (Test-Path $RunKey) {
        Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
    }
}

function Set-WallpaperNow {
    if (!(Test-Path -LiteralPath $WallpaperPath)) {
        throw "Wallpaper not found: $WallpaperPath"
    }

    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $WallpaperPath
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'

    $NativeCode = @'
using System;
using System.Runtime.InteropServices;
public static class FsocietyWallpaperNative {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool SystemParametersInfo(int action, int param, string path, int flags);
}
'@

    if (!('FsocietyWallpaperNative' -as [type])) {
        Add-Type -TypeDefinition $NativeCode -ErrorAction Stop
    }

    $Result = [FsocietyWallpaperNative]::SystemParametersInfo(20, 0, $WallpaperPath, 3)

    if (!$Result) {
        throw "Windows rejected the wallpaper update. Win32 error: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}

function Stop-Daemon {
    if (Test-Path -LiteralPath $PidPath) {
        try {
            $DaemonId = [int](Get-Content -LiteralPath $PidPath -Raw).Trim()
            $Process = Get-Process -Id $DaemonId -ErrorAction SilentlyContinue

            if ($Process -and $DaemonId -ne $PID) {
                Stop-Process -Id $DaemonId -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 300
            }
        }
        catch {
            Write-Log "Could not stop the previous daemon: $($_.Exception.Message)"
        }

        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    }
}

function Start-Daemon {
    Stop-Daemon

    $StartupCommand = '"' + $PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Daemon'
    $Process = Start-Process -FilePath $PowerShellExe -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        "`"$ScriptPath`"",
        '-Daemon'
    ) -PassThru -WindowStyle Hidden

    Start-Sleep -Milliseconds 700

    if ($Process.HasExited) {
        throw "The background daemon exited immediately. Check $LogPath for details."
    }

    Write-Log "Background daemon started with PID $($Process.Id)."
}

function Run-Daemon {
    Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
    Write-Log "Daemon started. PID: $PID"

    try {
        while ($true) {
            $Config = Get-Config

            if (!$Config.enabled) {
                Write-Log 'Enforcement is disabled; daemon is stopping.'
                break
            }

            try {
                $CurrentWallpaper = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper

                if ($CurrentWallpaper -ine $WallpaperPath) {
                    Set-WallpaperNow
                    Write-Log 'Wallpaper restored.'
                }
            }
            catch {
                Write-Log "Wallpaper enforcement error: $($_.Exception.Message)"
            }

            Start-Sleep -Seconds ([Math]::Max(1, [int]$Config.interval))
        }
    }
    finally {
        if (Test-Path -LiteralPath $PidPath) {
            $StoredPid = (Get-Content -LiteralPath $PidPath -Raw -ErrorAction SilentlyContinue).Trim()
            if ($StoredPid -eq [string]$PID) {
                Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Log 'Daemon stopped.'
    }
}

function Install-Fsociety {
    Write-Log 'Starting installation.'

    if ($RepoOwner -eq 'YOUR_GITHUB_USERNAME') {
        throw 'Edit install.ps1 on GitHub and replace YOUR_GITHUB_USERNAME with your GitHub username.'
    }

    New-Item -Path $InstallRoot -ItemType Directory -Force | Out-Null
    Download-Files

    if (!(Test-Path -LiteralPath $ConfigPath)) {
        Save-Config -Interval 1 -Enabled $true
    }

    Write-CommandShim
    Set-UserPath
    Set-Startup
    Set-HiddenFolder
    Set-WallpaperNow
    Start-Daemon

    Write-Log 'Installation completed.'
    Write-Host "Type fsociety status to check the installation."
    Write-Host "Log file: $LogPath"
}

function Show-Status {
    $Config = Get-Config
    $WallpaperExists = Test-Path -LiteralPath $WallpaperPath
    $DaemonRunning = $false

    if (Test-Path -LiteralPath $PidPath) {
        try {
            $DaemonId = [int](Get-Content -LiteralPath $PidPath -Raw).Trim()
            $DaemonRunning = [bool](Get-Process -Id $DaemonId -ErrorAction SilentlyContinue)
        }
        catch {
            $DaemonRunning = $false
        }
    }

    Write-Host "Enabled: $($Config.enabled)"
    Write-Host "Interval: $($Config.interval) second(s)"
    Write-Host "Daemon running: $DaemonRunning"
    Write-Host "Wallpaper exists: $WallpaperExists"
    Write-Host "Install folder: $InstallRoot"
    Write-Host "Log file: $LogPath"
}

function Update-Fsociety {
    Write-Log 'Updating installer and wallpaper.'
    $Config = Get-Config

    Download-Files
    Write-CommandShim
    Set-Startup
    Set-HiddenFolder

    if ($Config.enabled) {
        Set-WallpaperNow
        Start-Daemon
    }

    Write-Log 'Update completed. Configuration preserved.'
}

function Uninstall-Fsociety {
    Write-Log 'Uninstalling fsociety.'

    Stop-Daemon
    Remove-Startup
    Remove-UserPath

    if (Test-Path -LiteralPath $InstallRoot) {
        $Item = Get-Item -LiteralPath $InstallRoot -Force
        $Item.Attributes = [System.IO.FileAttributes]::Directory
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    }

    Write-Log 'Uninstall completed.'
    Write-Host 'The fsociety files, startup entry, and user PATH entry have been removed.'
}

try {
    if ($IsDaemon) {
        Run-Daemon
    }
    else {
        switch ($Command.ToLowerInvariant()) {
            'install' {
                Install-Fsociety
            }
            'on' {
                if (!(Test-Path -LiteralPath $ScriptPath)) {
                    throw 'fsociety is not installed. Run the installer first.'
                }

                $Config = Get-Config
                Save-Config -Interval $Config.interval -Enabled $true
                Set-Startup
                Set-WallpaperNow
                Start-Daemon
                Write-Log 'Enforcement enabled.'
            }
            'off' {
                $Config = Get-Config
                Save-Config -Interval $Config.interval -Enabled $false
                Stop-Daemon
                Remove-Startup
                Write-Log 'Enforcement disabled.'
            }
            'status' {
                Show-Status
            }
            'set' {
                Set-WallpaperNow
                Write-Log 'Wallpaper applied.'
            }
            'time' {
                if (!$Value) {
                    throw 'Usage: fsociety time <seconds>'
                }

                $Seconds = 0
                if (![int]::TryParse($Value, [ref]$Seconds) -or $Seconds -lt 1) {
                    throw 'The interval must be a whole number of at least 1 second.'
                }

                $Config = Get-Config
                Save-Config -Interval $Seconds -Enabled $Config.enabled

                if ($Config.enabled) {
                    Start-Daemon
                }

                Write-Log "Enforcement interval set to $Seconds second(s)."
            }
            'update' {
                Update-Fsociety
            }
            'help' {
                Write-Host 'fsociety install'
                Write-Host 'fsociety on'
                Write-Host 'fsociety off'
                Write-Host 'fsociety status'
                Write-Host 'fsociety set'
                Write-Host 'fsociety time <seconds>'
                Write-Host 'fsociety update'
                Write-Host 'fsociety help'
                Write-Host 'fsociety uninstall'
            }
            'uninstall' {
                Uninstall-Fsociety
            }
            default {
                throw "Unknown command: $Command. Run fsociety help."
            }
        }
    }
}
catch {
    $Message = $_.Exception.Message
    Write-Log "ERROR: $Message"
    Write-Host ''
    Write-Host "INSTALL/COMMAND FAILED: $Message" -ForegroundColor Red
    Write-Host "Log location: $LogPath" -ForegroundColor Yellow

    if (!$IsDaemon) {
        Read-Host 'Press Enter to return to PowerShell'
    }
}
