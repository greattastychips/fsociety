$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoOwner = 'greattastychips'
$RepoUrl = "https://raw.githubusercontent.com/$RepoOwner/ty-wallpaper/main"
$Root = Join-Path $env:LOCALAPPDATA '1234'
$ScriptPath = Join-Path $Root 'ty.ps1'
$WallpaperPath = Join-Path $Root '1234.png'
$ConfigPath = Join-Path $Root 'config.json'
$PidPath = Join-Path $Root 'daemon.pid'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$DaemonMode = $args -contains '-Daemon'
$CommandArgs = @($args | Where-Object { $_ -ne '-Daemon' })
$Command = if ($CommandArgs.Count) { [string]$CommandArgs[0] } else { 'help' }

function Get-Config {
    $defaults = @{ wallpaperMinutes = 1; updateMinutes = 2; enabled = $true }

    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $saved = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            $defaults.wallpaperMinutes = [Math]::Max(1, [int]$saved.wallpaperMinutes)
            $defaults.updateMinutes = [Math]::Max(1, [int]$saved.updateMinutes)
            $defaults.enabled = [bool]$saved.enabled
        } catch {}
    }

    return $defaults
}

function Save-Config {
    param($Config)

    $Config | ConvertTo-Json |
        Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Test-Png {
    param([string]$Path)

    try {
        $b = [System.IO.File]::ReadAllBytes($Path)
        return ($b.Length -ge 8 -and
            $b[0] -eq 137 -and $b[1] -eq 80 -and
            $b[2] -eq 78 -and $b[3] -eq 71 -and
            $b[4] -eq 13 -and $b[5] -eq 10 -and
            $b[6] -eq 26 -and $b[7] -eq 10)
    } catch {
        return $false
    }
}

function Download-Assets {
    param([switch]$Update)

    if ($RepoOwner -eq 'YOUR_GITHUB_USERNAME') {
        throw 'Set your GitHub username in install.ps1 first.'
    }

    $tempScript = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.ps1')
    $tempImage = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.png')

    try {
        Invoke-WebRequest "$RepoUrl/install.ps1" -OutFile $tempScript -UseBasicParsing
        Invoke-WebRequest "$RepoUrl/1234.png" -OutFile $tempImage -UseBasicParsing

        $source = Get-Content -LiteralPath $tempScript -Raw
        if ($source -notmatch 'function\s+Run-Daemon') {
            throw 'The downloaded script failed validation.'
        }
        if ($source -match "(?m)^\s*\`$RepoOwner\s*=\s*'YOUR_GITHUB_USERNAME'\s*$") {
            throw 'The GitHub script still has the placeholder username.'
        }
        if (!(Test-Png $tempImage)) {
            throw 'The downloaded wallpaper is not a valid PNG.'
        }

        New-Item -Path $Root -ItemType Directory -Force | Out-Null

        $scriptChanged = !(Test-Path $ScriptPath)
        $imageChanged = !(Test-Path $WallpaperPath)

        if (!$scriptChanged) {
            $scriptChanged = (Get-FileHash $ScriptPath).Hash -ne
                (Get-FileHash $tempScript).Hash
        }
        if (!$imageChanged) {
            $imageChanged = (Get-FileHash $WallpaperPath).Hash -ne
                (Get-FileHash $tempImage).Hash
        }

        if (!$Update -or $scriptChanged) {
            Copy-Item $tempScript $ScriptPath -Force
        }
        if (!$Update -or $imageChanged) {
            Copy-Item $tempImage $WallpaperPath -Force
        }

        return @{
            scriptChanged = $scriptChanged
            imageChanged = $imageChanged
        }
    } finally {
        Remove-Item $tempScript, $tempImage -Force -ErrorAction SilentlyContinue
    }
}

function Set-Wallpaper {
    if (!(Test-Png $WallpaperPath)) {
        throw 'Wallpaper is missing or invalid. Run ty update.'
    }

    Set-ItemProperty 'HKCU:\Control Panel\Desktop' Wallpaper $WallpaperPath
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' WallpaperStyle '10'
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' TileWallpaper '0'

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
    if (Test-Path $PidPath) {
        try {
            $oldPid = [int](Get-Content $PidPath -Raw).Trim()
            if ($oldPid -ne $PID) {
                Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            }
        } catch {}

        Remove-Item $PidPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-Startup {
    New-Item $RunKey -Force | Out-Null
    $startup = "`"$PowerShellExe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Daemon"
    Set-ItemProperty $RunKey -Name 'ty' -Value $startup
}

function Remove-Startup {
    Remove-ItemProperty $RunKey -Name 'ty' -ErrorAction SilentlyContinue
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

    $p = Start-Process -FilePath $PowerShellExe -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$ScriptPath`"", '-Daemon'
    )

    Start-Sleep -Milliseconds 800
    if ($p.HasExited) {
        throw 'The background process failed to start.'
    }
}

function Update-Remote {
    try {
        $assets = Download-Assets -Update

        if ($assets.imageChanged) {
            try { Set-Wallpaper } catch {}
        }

        if ($assets.scriptChanged) {
            Start-Process -FilePath $PowerShellExe -WindowStyle Hidden -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive',
                '-ExecutionPolicy', 'Bypass',
                '-File', "`"$ScriptPath`"", '-Daemon'
            )
            return $true
        }
    } catch {}

    return $false
}

function Run-Daemon {
    Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII

    $lastWallpaper = [DateTime]::MinValue
    $lastUpdate = Get-Date

    try {
        while ($true) {
            $c = Get-Config
            if (!$c.enabled) { break }

            $now = Get-Date

            if (($now - $lastWallpaper).TotalMinutes -ge $c.wallpaperMinutes) {
                try {
                    $current = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name Wallpaper).Wallpaper
                    if ($current -ine $WallpaperPath) {
                        Set-Wallpaper
                    }
                } catch {}

                $lastWallpaper = $now
            }

            if (($now - $lastUpdate).TotalMinutes -ge $c.updateMinutes) {
                $lastUpdate = $now
                if (Update-Remote) { break }
            }

            Start-Sleep -Seconds 5
        }
    } finally {
        try {
            if ((Get-Content $PidPath -Raw -ErrorAction SilentlyContinue).Trim() -eq [string]$PID) {
                Remove-Item $PidPath -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

function Install-Ty {
    Write-Host 'LOADING' -ForegroundColor Red

    Download-Assets
    if (!(Test-Path $ConfigPath)) {
        Save-Config ([pscustomobject]@{
            wallpaperMinutes = 1
            updateMinutes = 2
            enabled = $true
        })
    }

    Set-Command
    Set-Startup
    Set-Wallpaper

    $item = Get-Item $Root -Force
    $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden

    Start-Daemon
    Write-Host 'DONE' -ForegroundColor Red
}

function Update-Ty {
    Download-Assets -Update | Out-Null
    Set-Command
    Set-Startup

    $c = Get-Config
    if ($c.enabled) {
        Set-Wallpaper
        Start-Daemon
    }

    $item = Get-Item $Root -Force
    $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
    Write-Host 'DONE' -ForegroundColor Red
}

function Uninstall-Ty {
    Stop-Daemon
    Remove-Startup
    Remove-CommandPath

    if (Test-Path $Root) {
        $item = Get-Item $Root -Force
        $item.Attributes = [System.IO.FileAttributes]::Directory
        Remove-Item $Root -Recurse -Force
    }

    Write-Host 'DONE' -ForegroundColor Red
}

try {
    if ($env:TY_BOOTSTRAP_INSTALL -eq '1') {
        Install-Ty
    } elseif ($DaemonMode) {
        Run-Daemon
    } else {
        $c = Get-Config
        $sub = if ($CommandArgs.Count -gt 1) { [string]$CommandArgs[1] } else { '' }
        $value = if ($CommandArgs.Count -gt 2) { [string]$CommandArgs[2] } else { '' }

        switch ($Command.ToLowerInvariant()) {
            'install' { Install-Ty }
            'help' {
                Write-Host 'ty install'
                Write-Host 'ty on'
                Write-Host 'ty off'
                Write-Host 'ty status'
                Write-Host 'ty set'
                Write-Host 'ty time <minutes>'
                Write-Host 'ty wallpaper time <minutes>'
                Write-Host 'ty update'
                Write-Host 'ty update time <minutes>'
                Write-Host 'ty uninstall'
            }
            'on' {
                $c.enabled = $true
                Save-Config $c
                Set-Startup
                Set-Wallpaper
                Start-Daemon
                Write-Host 'DONE' -ForegroundColor Red
            }
            'off' {
                $c.enabled = $false
                Save-Config $c
                Stop-Daemon
                Remove-Startup
                Write-Host 'DONE' -ForegroundColor Red
            }
            'status' {
                Write-Host "Enabled: $($c.enabled)"
                Write-Host "Wallpaper interval: $($c.wallpaperMinutes) minute(s)"
                Write-Host "Update interval: $($c.updateMinutes) minute(s)"
                Write-Host "Wallpaper file valid: $(Test-Png $WallpaperPath)"
            }
            'set' {
                Set-Wallpaper
                Write-Host 'DONE' -ForegroundColor Red
            }
            'time' {
                if ($sub -eq 'wallpaper') {
                    $n = 0
                    if ($CommandArgs.Count -lt 3 -or ![int]::TryParse($value, [ref]$n) -or $n -lt 1) {
                        throw 'Use: ty wallpaper time <minutes>'
                    }
                } else {
                    $n = 0
                    if ($CommandArgs.Count -lt 2 -or ![int]::TryParse($sub, [ref]$n) -or $n -lt 1) {
                        throw 'Use: ty time <minutes>'
                    }
                }

                $c.wallpaperMinutes = $n
                Save-Config $c
                if ($c.enabled) { Start-Daemon }
                Write-Host 'DONE' -ForegroundColor Red
            }
            'wallpaper' {
                if ($sub -ne 'time') { throw 'Use: ty wallpaper time <minutes>' }
                $n = 0
                if (![int]::TryParse($value, [ref]$n) -or $n -lt 1) {
                    throw 'Use: ty wallpaper time <minutes>'
                }

                $c.wallpaperMinutes = $n
                Save-Config $c
                if ($c.enabled) { Start-Daemon }
                Write-Host 'DONE' -ForegroundColor Red
            }
            'update' {
                if ($sub -eq 'time') {
                    $n = 0
                    if (![int]::TryParse($value, [ref]$n) -or $n -lt 1) {
                        throw 'Use: ty update time <minutes>'
                    }

                    $c.updateMinutes = $n
                    Save-Config $c
                    if ($c.enabled) { Start-Daemon }
                    Write-Host 'DONE' -ForegroundColor Red
                } else {
                    Update-Ty
                }
            }
            'uninstall' { Uninstall-Ty }
            default { Write-Host 'Unknown command. Run ty for help.' -ForegroundColor DarkRed }
        }
    }
} catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor DarkRed
    if (!$DaemonMode) {
        Read-Host 'Press Enter'
    }
}
