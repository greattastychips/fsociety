$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoOwner = 'greattastychips'
$RepoName = 'ty-wallpaper'
$RepoUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/main"

$Root = Join-Path $env:LOCALAPPDATA '1234'
$ScriptPath = Join-Path $Root 'ty.ps1'
$WallpaperPath = Join-Path $Root '1234.png'
$ConfigPath = Join-Path $Root 'config.json'
$PidPath = Join-Path $Root 'daemon.pid'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$DaemonMode = $args -contains '-Daemon'
$CliArgs = @($args | Where-Object { $_ -ne '-Daemon' })
$Command = 'help'
if ($CliArgs.Count -gt 0) { $Command = [string]$CliArgs[0] }

function Get-Config {
    $c = @{ intervalSeconds = 1; updateMinutes = 2; enabled = $true }

    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $saved = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            if ($null -ne $saved.intervalSeconds) {
                $c.intervalSeconds = [Math]::Max(1, [int]$saved.intervalSeconds)
            }
            if ($null -ne $saved.updateMinutes) {
                $c.updateMinutes = [Math]::Max(1, [int]$saved.updateMinutes)
            }
            if ($null -ne $saved.enabled) {
                $c.enabled = [bool]$saved.enabled
            }
        } catch {}
    }

    return $c
}

function Save-Config {
    param(
        [int]$IntervalSeconds,
        [int]$UpdateMinutes,
        [bool]$Enabled
    )

    @{
        intervalSeconds = [Math]::Max(1, $IntervalSeconds)
        updateMinutes = [Math]::Max(1, $UpdateMinutes)
        enabled = $Enabled
    } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Test-Png {
    param([string]$Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    try {
        $b = [IO.File]::ReadAllBytes($Path)
        $sig = @(137,80,78,71,13,10,26,10)
        if ($b.Length -lt 8) { return $false }

        for ($i = 0; $i -lt 8; $i++) {
            if ($b[$i] -ne $sig[$i]) { return $false }
        }

        return $true
    } catch {
        return $false
    }
}

function Clean-LegacyFiles {
    if (!(Test-Path -LiteralPath $Root)) { return }

    Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            (($_.Extension -in @('.cmd', '.bat')) -and $_.Name -ine 'ty.cmd') -or
            (($_.Extension -ieq '.ps1') -and $_.Name -ine 'ty.ps1')
        } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Download-Assets {
    param([switch]$ForUpdate)

    $tmpScript = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.tmp')
    $tmpImage = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.tmp')

    try {
        Invoke-WebRequest -Uri "$RepoUrl/install.ps1" -OutFile $tmpScript -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri "$RepoUrl/1234.png" -OutFile $tmpImage -UseBasicParsing -ErrorAction Stop

        $source = Get-Content -LiteralPath $tmpScript -Raw

        if ($source -notmatch 'function\s+Run-Daemon' -or
            $source -notmatch 'function\s+Download-Assets' -or
            !(Test-Png -Path $tmpImage)) {
            throw 'Downloaded files failed validation.'
        }

        New-Item -Path $Root -ItemType Directory -Force | Out-Null

        $scriptChanged = $true
        $imageChanged = $true

        if (Test-Path -LiteralPath $ScriptPath) {
            $scriptChanged = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $tmpScript -Algorithm SHA256).Hash
        }

        if (Test-Path -LiteralPath $WallpaperPath) {
            $imageChanged = (Get-FileHash -LiteralPath $WallpaperPath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $tmpImage -Algorithm SHA256).Hash
        }

        if (!$ForUpdate -or $scriptChanged) {
            Copy-Item -LiteralPath $tmpScript -Destination $ScriptPath -Force
        }

        if (!$ForUpdate -or $imageChanged) {
            Copy-Item -LiteralPath $tmpImage -Destination $WallpaperPath -Force
        }

        return @{
            scriptChanged = $scriptChanged
            imageChanged = $imageChanged
        }
    } finally {
        Remove-Item -LiteralPath $tmpScript, $tmpImage -Force -ErrorAction SilentlyContinue
    }
}

function Set-Wallpaper {
    if (!(Test-Png -Path $WallpaperPath)) {
        throw 'Wallpaper file is missing or invalid.'
    }

    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $WallpaperPath
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'

    if (!('TyWallpaperNative' -as [type])) {
        Add-Type @'
using System.Runtime.InteropServices;
public static class TyWallpaperNative {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern bool SystemParametersInfo(int action, int param, string path, int flags);
}
'@
    }

    if (![TyWallpaperNative]::SystemParametersInfo(20, 0, $WallpaperPath, 3)) {
        throw "Windows could not apply the wallpaper. Error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
    }
}

function Stop-Daemon {
    $oldPid = 0

    if (Test-Path -LiteralPath $PidPath) {
        try { $oldPid = [int](Get-Content -LiteralPath $PidPath -Raw).Trim() } catch {}

        if ($oldPid -gt 0 -and $oldPid -ne $PID) {
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            for ($i = 0; $i -lt 20; $i++) {
                if (!(Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) { break }
                Start-Sleep -Milliseconds 100
            }
        }

        try {
            $savedPid = (Get-Content -LiteralPath $PidPath -Raw -ErrorAction SilentlyContinue).Trim()
            if ($savedPid -eq [string]$oldPid) {
                Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

function Set-Startup {
    New-Item -Path $RunKey -Force | Out-Null

    $startup = '"' + $PowerShellExe +
        '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
        $ScriptPath + '" -Daemon'

    Set-ItemProperty -Path $RunKey -Name 'ty' -Value $startup

    $properties = (Get-ItemProperty -Path $RunKey).PSObject.Properties
    foreach ($p in $properties) {
        if ($p.Name -notlike 'PS*' -and $p.Name -ine 'ty' -and
            [string]$p.Value -like "*$Root*") {
            Remove-ItemProperty -Path $RunKey -Name $p.Name -ErrorAction SilentlyContinue
        }
    }
}

function Remove-Startup {
    $properties = (Get-ItemProperty -Path $RunKey -ErrorAction SilentlyContinue).PSObject.Properties

    foreach ($p in $properties) {
        if ($p.Name -notlike 'PS*' -and
            ($p.Name -ieq 'ty' -or [string]$p.Value -like "*$Root*")) {
            Remove-ItemProperty -Path $RunKey -Name $p.Name -ErrorAction SilentlyContinue
        }
    }
}

function Set-Command {
    $shimPath = Join-Path $Root 'ty.cmd'
    $shim = "@echo off`r`n`"$PowerShellExe`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" %*`r`n"
    Set-Content -LiteralPath $shimPath -Value $shim -Encoding ASCII

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { $_ })

    if (!($parts | Where-Object { $_.TrimEnd('\') -ieq $Root.TrimEnd('\') })) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $Root) -join ';'), 'User')
    }

    if (!($env:Path -split ';' | Where-Object { $_.TrimEnd('\') -ieq $Root.TrimEnd('\') })) {
        $env:Path = "$Root;$env:Path"
    }
}

function Remove-CommandPath {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object {
        $_ -and $_.TrimEnd('\') -ine $Root.TrimEnd('\')
    })

    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

function Start-Daemon {
    Stop-Daemon

    $argLine = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
        $ScriptPath + '" -Daemon'

    $p = Start-Process -FilePath $PowerShellExe -ArgumentList $argLine -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 800

    if ($p.HasExited) {
        throw 'Background process failed to start.'
    }
}

function Update-InBackground {
    $tmpScript = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.tmp')
    $tmpImage = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.tmp')

    try {
        Invoke-WebRequest -Uri "$RepoUrl/install.ps1" -OutFile $tmpScript -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri "$RepoUrl/1234.png" -OutFile $tmpImage -UseBasicParsing -ErrorAction Stop

        $source = Get-Content -LiteralPath $tmpScript -Raw
        if ($source -notmatch 'function\s+Run-Daemon' -or
            $source -notmatch 'function\s+Download-Assets' -or
            !(Test-Png -Path $tmpImage)) {
            return $false
        }

        $scriptChanged = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $tmpScript -Algorithm SHA256).Hash

        $imageChanged = (Get-FileHash -LiteralPath $WallpaperPath -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $tmpImage -Algorithm SHA256).Hash

        if ($imageChanged) {
            Copy-Item -LiteralPath $tmpImage -Destination $WallpaperPath -Force
            try { Set-Wallpaper } catch {}
        }

        if ($scriptChanged) {
            Copy-Item -LiteralPath $tmpScript -Destination $ScriptPath -Force

            $argLine = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
                $ScriptPath + '" -Daemon'

            Start-Process -FilePath $PowerShellExe -ArgumentList $argLine -WindowStyle Hidden
            return $true
        }

        return $false
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $tmpScript, $tmpImage -Force -ErrorAction SilentlyContinue
    }
}

function Run-Daemon {
    Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
    $lastUpdateCheck = Get-Date

    try {
        while ($true) {
            $c = Get-Config
            if (!$c.enabled) { break }

            try {
                $current = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper
                if ($current -ine $WallpaperPath) {
                    Set-Wallpaper
                }
            } catch {}

            if (((Get-Date) - $lastUpdateCheck).TotalMinutes -ge $c.updateMinutes) {
                $lastUpdateCheck = Get-Date
                if (Update-InBackground) { break }
            }

            Start-Sleep -Seconds ([Math]::Max(1, [int]$c.intervalSeconds))
        }
    } finally {
        try {
            $savedPid = (Get-Content -LiteralPath $PidPath -Raw -ErrorAction SilentlyContinue).Trim()
            if ($savedPid -eq [string]$PID) {
                Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

function Install-Ty {
    Write-Host 'LOADING' -ForegroundColor Red

    if ($RepoOwner -eq 'YOUR_GITHUB_USERNAME') {
        throw 'Set YOUR_GITHUB_USERNAME in the installer.'
    }

    New-Item -Path $Root -ItemType Directory -Force | Out-Null
    Download-Assets
    Clean-LegacyFiles

    if (!(Test-Path -LiteralPath $ConfigPath)) {
        Save-Config -IntervalSeconds 1 -UpdateMinutes 2 -Enabled $true
    }

    Set-Command
    Set-Startup
    Set-Wallpaper

    $folder = Get-Item -LiteralPath $Root -Force
    $folder.Attributes = $folder.Attributes -bor [IO.FileAttributes]::Hidden

    Start-Daemon
    Write-Host 'DONE' -ForegroundColor Red
}

function Update-Ty {
    $c = Get-Config
    Download-Assets -ForUpdate
    Clean-LegacyFiles
    Set-Command
    Set-Startup

    if ($c.enabled) {
        Set-Wallpaper
        Start-Daemon
    }

    $folder = Get-Item -LiteralPath $Root -Force
    $folder.Attributes = $folder.Attributes -bor [IO.FileAttributes]::Hidden
}

function Uninstall-Ty {
    Stop-Daemon
    Remove-Startup
    Remove-CommandPath

    if (Test-Path -LiteralPath $Root) {
        Get-ChildItem -LiteralPath $Root -Force -Recurse |
            ForEach-Object {
                try { $_.Attributes = [IO.FileAttributes]::Normal } catch {}
            }

        try {
            $folder = Get-Item -LiteralPath $Root -Force
            $folder.Attributes = [IO.FileAttributes]::Directory
        } catch {}

        Remove-Item -LiteralPath $Root -Recurse -Force
    }
}

try {
    if ($DaemonMode) {
        Run-Daemon
        return
    }

    if ($Command -ieq 'install' -or $env:TY_BOOTSTRAP_INSTALL -eq '1') {
        Install-Ty
        return
    }

    switch ($Command.ToLowerInvariant()) {
        'help' {
            Write-Host 'ty install'
            Write-Host 'ty on'
            Write-Host 'ty off'
            Write-Host 'ty status'
            Write-Host 'ty set'
            Write-Host 'ty time <seconds>'
            Write-Host 'ty update'
            Write-Host 'ty update time <minutes>'
            Write-Host 'ty uninstall'
        }

        'on' {
            $c = Get-Config
            Save-Config -IntervalSeconds $c.intervalSeconds -UpdateMinutes $c.updateMinutes -Enabled $true
            Set-Startup
            Set-Wallpaper
            Start-Daemon
        }

        'off' {
            $c = Get-Config
            Save-Config -IntervalSeconds $c.intervalSeconds -UpdateMinutes $c.updateMinutes -Enabled $false
            Stop-Daemon
            Remove-Startup
        }

        'status' {
            $c = Get-Config
            $running = $false

            if (Test-Path -LiteralPath $PidPath) {
                try {
                    $id = [int](Get-Content -LiteralPath $PidPath -Raw).Trim()
                    $running = [bool](Get-Process -Id $id -ErrorAction SilentlyContinue)
                } catch {}
            }

            Write-Host "Enabled: $($c.enabled)"
            Write-Host "Wallpaper interval: $($c.intervalSeconds) second(s)"
            Write-Host "Update interval: $($c.updateMinutes) minute(s)"
            Write-Host "Background process running: $running"
        }

        'set' {
            Set-Wallpaper
        }

        'time' {
            $seconds = 0
            if ($CliArgs.Count -lt 2 -or
                ![int]::TryParse([string]$CliArgs[1], [ref]$seconds) -or $seconds -lt 1) {
                throw 'Usage: ty time <seconds>'
            }

            $c = Get-Config
            Save-Config -IntervalSeconds $seconds -UpdateMinutes $c.updateMinutes -Enabled $c.enabled
            if ($c.enabled) { Start-Daemon }
        }

        'update' {
            if ($CliArgs.Count -ge 2 -and $CliArgs[1] -ieq 'time') {
                $minutes = 0
                if ($CliArgs.Count -lt 3 -or
                    ![int]::TryParse([string]$CliArgs[2], [ref]$minutes) -or $minutes -lt 1) {
                    throw 'Usage: ty update time <minutes>'
                }

                $c = Get-Config
                Save-Config -IntervalSeconds $c.intervalSeconds -UpdateMinutes $minutes -Enabled $c.enabled
                if ($c.enabled) { Start-Daemon }
            } else {
                Update-Ty
            }
        }

        'uninstall' {
            Uninstall-Ty
        }

        default {
            Write-Host 'Unknown command. Type ty for help.' -ForegroundColor DarkRed
        }
    }
} catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor DarkRed
}
