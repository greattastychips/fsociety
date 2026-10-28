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

$Arguments = @($args)
$DaemonMode = $Arguments -contains '-Daemon'
$NormalArgs = @($Arguments | Where-Object { $_ -ne '-Daemon' })
$Command = 'install'
$Value = $null

if ($NormalArgs.Count -gt 0) { $Command = [string]$NormalArgs[0] }
if ($NormalArgs.Count -gt 1) { $Value = [string]$NormalArgs[1] }

function Get-Config {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $c = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            return @{
                interval = [Math]::Max(1, [int]$c.interval)
                enabled = [bool]$c.enabled
            }
        } catch {}
    }

    return @{ interval = 1; enabled = $true }
}

function Save-Config {
    param([int]$Interval, [bool]$Enabled)

    if ($Interval -lt 1) {
        throw 'The interval must be at least one second.'
    }

    @{ interval = $Interval; enabled = $Enabled } |
        ConvertTo-Json |
        Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Test-Png {
    param([string]$Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $signature = @(137,80,78,71,13,10,26,10)

        if ($bytes.Length -lt 8) { return $false }

        for ($i = 0; $i -lt 8; $i++) {
            if ($bytes[$i] -ne $signature[$i]) { return $false }
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
        Invoke-WebRequest -Uri "$RepoUrl/install.ps1" -OutFile $tempScript -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri "$RepoUrl/1234.png" -OutFile $tempImage -UseBasicParsing -ErrorAction Stop

        $source = Get-Content -LiteralPath $tempScript -Raw

        if ($source -match "(?m)^\s*\`$RepoOwner\s*=\s*'YOUR_GITHUB_USERNAME'\s*$") {
            throw 'The GitHub installer still contains the placeholder username.'
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
            $scriptChanged = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $tempScript -Algorithm SHA256).Hash
        }

        if (Test-Path -LiteralPath $WallpaperPath) {
            $imageChanged = (Get-FileHash -LiteralPath $WallpaperPath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $tempImage -Algorithm SHA256).Hash
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

    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $WallpaperPath
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'

    if (!('FsWallpaperNative' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class FsWallpaperNative {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern bool SystemParametersInfo(int action, int param, string path, int flags);
}
'@
    }

    $result = [FsWallpaperNative]::SystemParametersInfo(20, 0, $WallpaperPath, 3)

    if (!$result) {
        throw "Windows could not apply the wallpaper. Win32 error: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}

function Stop-Daemon {
    if (Test-Path -LiteralPath $PidPath) {
        try {
            $oldPid = [int](Get-Content -LiteralPath $PidPath -Raw).Trim()

            if ($oldPid -ne $PID) {
                $p = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
                if ($p) {
                    Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {}

        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-Startup {
    New-Item -Path $RunKey -Force | Out-Null

    $startup = '"' + $PowerShellExe + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Daemon'

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

    if ($p.HasExited) {
        throw 'The background process exited during startup.'
    }
}

function Update-InBackground {
    $tempScript = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.ps1')
    $tempImage = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.png')

    try {
        Invoke-WebRequest -Uri "$RepoUrl/install.ps1" -OutFile $tempScript -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri "$RepoUrl/1234.png" -OutFile $tempImage -UseBasicParsing -ErrorAction Stop

        $source = Get-Content -LiteralPath $tempScript -Raw

        if ($source -match "(?m)^\s*\`$RepoOwner\s*=\s*'YOUR_GITHUB_USERNAME'\s*$") {
            return $false
        }

        if ($source -notmatch 'function\s+Run-Daemon' -or !(Test-Png -Path $tempImage)) {
            return $false
        }

        $scriptChanged = $true
        $imageChanged = $true

        if (Test-Path -LiteralPath $ScriptPath) {
            $scriptChanged = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $tempScript -Algorithm SHA256).Hash
        }

        if (Test-Path -LiteralPath $WallpaperPath) {
            $imageChanged = (Get-FileHash -LiteralPath $WallpaperPath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $tempImage -Algorithm SHA256).Hash
        }

        if ($imageChanged) {
            Copy-Item -LiteralPath $tempImage -Destination $WallpaperPath -Force
            try { Set-Wallpaper } catch {}
        }

        if ($scriptChanged) {
            Copy-Item -LiteralPath $tempScript -Destination $ScriptPath -Force

            Start-Process -FilePath $PowerShellExe -WindowStyle Hidden -ArgumentList @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                "`"$ScriptPath`"",
                '-Daemon'
            )

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
    $updateInterval = 21600

    try {
        while ($true) {
            $c = Get-Config
            if (!$c.enabled) { break }

            if (Test-Png -Path $WallpaperPath) {
                try {
                    $current = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper

                    if ($current -ine $WallpaperPath) {
                        Set-Wallpaper
                    }
                } catch {}
            }

            if (((Get-Date) - $lastUpdateCheck).TotalSeconds -ge $updateInterval) {
                $lastUpdateCheck = Get-Date
                if (Update-InBackground) { break }
            }

            Start-Sleep -Seconds ([Math]::Max(1, [int]$c.interval))
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

function Install-Fs {
    if ($RepoOwner -eq 'YOUR_GITHUB_USERNAME') {
        throw 'Replace YOUR_GITHUB_USERNAME in the GitHub installer.'
    }

    New-Item -Path $Root -ItemType Directory -Force | Out-Null
    Download-Assets

    if (!(Test-Path -LiteralPath $ConfigPath)) {
        Save-Config -Interval 1 -Enabled $true
    }

    Set-Command
    Set-Startup
    Set-Wallpaper

    $item = Get-Item -LiteralPath $Root -Force
    $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden

    Start-Daemon
    Write-Host 'Installation complete. Run fs status to check.'
}

function Update-Fs {
    $c = Get-Config
    Download-Assets -ForUpdate
    Set-Command
    Set-Startup

    if ($c.enabled) {
        Set-Wallpaper
        Start-Daemon
    }

    $item = Get-Item -LiteralPath $Root -Force
    $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden

    Write-Host 'Update complete.'
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

    Write-Host 'fs has been uninstalled.'
}

try {
    if ($DaemonMode) {
        Run-Daemon
    } else {
        switch ($Command.ToLowerInvariant()) {
            'install' {
                Install-Fs
            }
            'on' {
                $c = Get-Config
                Save-Config -Interval $c.interval -Enabled $true
                Set-Startup
                Set-Wallpaper
                Start-Daemon
                Write-Host 'Enforcement enabled.'
            }
            'off' {
                $c = Get-Config
                Save-Config -Interval $c.interval -Enabled $false
                Stop-Daemon
                Remove-Startup
                Write-Host 'Enforcement disabled.'
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
                Write-Host "Interval: $($c.interval) second(s)"
                Write-Host "Background process running: $running"
                Write-Host "Wallpaper exists: $(Test-Png -Path $WallpaperPath)"
            }
            'set' {
                Set-Wallpaper
                Write-Host 'Wallpaper applied.'
            }
            'time' {
                $seconds = 0

                if (!$Value -or ![int]::TryParse($Value, [ref]$seconds) -or $seconds -lt 1) {
                    throw 'Usage: fs time <seconds>, with a whole number of at least 1.'
                }

                $c = Get-Config
                Save-Config -Interval $seconds -Enabled $c.enabled
                if ($c.enabled) { Start-Daemon }

                Write-Host "Interval set to $seconds second(s)."
            }
            'update' {
                Update-Fs
            }
            'help' {
                Write-Host 'fs install'
                Write-Host 'fs on'
                Write-Host 'fs off'
                Write-Host 'fs status'
                Write-Host 'fs set'
                Write-Host 'fs time <seconds>'
                Write-Host 'fs update'
                Write-Host 'fs help'
                Write-Host 'fs uninstall'
            }
            'uninstall' {
                Uninstall-Fs
            }
            default {
                throw "Unknown command '$Command'. Run fs help."
            }
        }
    }
} catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red

    if (!$DaemonMode) {
        Read-Host 'Press Enter to return to PowerShell'
    }
}
