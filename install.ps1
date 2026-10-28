
param(
    [Parameter(Position = 0)]
    [string]$Command = 'install',

    [Parameter(Position = 1)]
    [string]$Value
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
$LogPath = Join-Path $env:TEMP 'fsociety-install.log'

$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName = 'fsociety'
$MutexName = 'Local\fsociety_1234_mutex'
$StopEventName = 'Local\fsociety_1234_stop'

$ScriptUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/install.ps1"
$WallpaperUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/1234.png"

$PowerShellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Log {
    param([string]$Message)

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"

    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {}

    Write-Host $Message
}

function Step {
    param([string]$Message, [int]$Percent)

    Write-Progress -Activity 'fsociety' -Status $Message -PercentComplete $Percent
    Log "[$Percent%] $Message"
}

function Ensure-Repo {
    if ($RepoOwner -eq 'YOUR_GITHUB_USERNAME') {
        throw 'Set $RepoOwner in install.ps1 to your GitHub username before uploading it.'
    }
}

function Test-Png {
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

        $sig = New-Object byte[] 8
        [void]$stream.Read($sig, 0, 8)

        $expected = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)

        for ($i = 0; $i -lt 8; $i++) {
            if ($sig[$i] -ne $expected[$i]) {
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

function Read-Config {
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $c = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            $interval = [int]$c.IntervalSeconds

            if ($interval -lt 1 -or $interval -gt 3600) {
                $interval = 1
            }

            return @{
                IntervalSeconds = $interval
                Enabled = [bool]$c.Enabled
            }
        } catch {}
    }

    return @{ IntervalSeconds = 1; Enabled = $true }
}

function Write-Config {
    param([int]$IntervalSeconds, [bool]$Enabled)

    if ($IntervalSeconds -lt 1 -or $IntervalSeconds -gt 3600) {
        throw 'Interval must be between 1 and 3600 seconds.'
    }

    @{
        IntervalSeconds = $IntervalSeconds
        Enabled = $Enabled
    } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Stop-Daemon {
    try {
        $ev = [System.Threading.EventWaitHandle]::OpenExisting($StopEventName)
        [void]$ev.Set()
        $ev.Dispose()
    } catch {}

    for ($i = 0; $i -lt 30; $i++) {
        $m = $null

        try {
            $m = [System.Threading.Mutex]::OpenExisting($MutexName)
            $acquired = $false

            try {
                $acquired = $m.WaitOne(100)
            } catch [System.Threading.AbandonedMutexException] {
                $acquired = $true
            }

            if ($acquired) {
                $m.ReleaseMutex()
                return
            }
        } catch [System.Threading.WaitHandleCannotBeOpenedException] {
            return
        } catch {
        } finally {
            if ($null -ne $m) {
                $m.Dispose()
            }
        }

        Start-Sleep -Milliseconds 100
    }

    Log 'Warning: background process did not confirm shutdown in time.'
}

function Apply-Wallpaper {
    if (-not (Test-Png $WallpaperPath)) {
        throw 'Wallpaper file is missing or invalid. Run fsociety update.'
    }

    if (-not ('FsocietyNative' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public class FsocietyNative {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern bool SystemParametersInfo(int action, int param, string path, int flags);
}
"@
    }

    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $WallpaperPath

    if (-not [FsocietyNative]::SystemParametersInfo(20, 0, $WallpaperPath, 3)) {
        throw 'Windows could not apply the wallpaper.'
    }
}

function Register-Startup {
    if (-not (Test-Path $RunKey)) {
        New-Item -Path $RunKey -Force | Out-Null
    }

    $cmd = '"' + $PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Daemon'

    Set-ItemProperty -Path $RunKey -Name $RunName -Value $cmd
}

function Unregister-Startup {
    if (Test-Path $RunKey) {
        Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
    }
}

function Add-PathEntry {
    $entries = @(
        [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' |
        Where-Object { $_ }
    )

    if (-not ($entries | Where-Object {
        $_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\')
    })) {
        $entries += $InstallDir
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    }

    $env:Path = "$InstallDir;$env:Path"
}

function Remove-PathEntry {
    $userEntries = @(
        [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' |
        Where-Object {
            $_ -and $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\')
        }
    )

    [Environment]::SetEnvironmentVariable('Path', ($userEntries -join ';'), 'User')

    $env:Path = (@(
        $env:Path -split ';' |
        Where-Object {
            $_ -and $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\')
        }
    ) -join ';')
}

function Download-Files {
    param([string]$TempScript, [string]$TempPng)

    Ensure-Repo

    Step 'Downloading wallpaper from GitHub' 20
    Invoke-WebRequest -Uri $WallpaperUrl -OutFile $TempPng -UseBasicParsing -ErrorAction Stop

    if (-not (Test-Png $TempPng)) {
        throw 'GitHub did not return a valid PNG. Upload 1234.png to the repository root on the main branch.'
    }

    Step 'Downloading installer from GitHub' 40
    Invoke-WebRequest -Uri $ScriptUrl -OutFile $TempScript -UseBasicParsing -ErrorAction Stop

    $source = Get-Content -LiteralPath $TempScript -Raw

    if ($source -notmatch 'function Install-Fsociety') {
        throw 'The repository install.ps1 is not the expected installer. Check the uploaded file and branch.'
    }

    if ($source -match 'YOUR_GITHUB_USERNAME') {
        throw 'Replace YOUR_GITHUB_USERNAME in the repository copy before installing.'
    }
}

function Start-Daemon {
    Stop-Daemon

    $args = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Daemon'
    Start-Process -FilePath $PowerShellExe -ArgumentList $args -WindowStyle Hidden
}

function Install-Fsociety {
    $temp = Join-Path $env:TEMP ('fsociety-' + [guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $temp -Force | Out-Null

        $tempScript = Join-Path $temp 'install.ps1'
        $tempPng = Join-Path $temp '1234.png'

        Step 'Checking configuration' 5
        Download-Files -TempScript $tempScript -TempPng $tempPng

        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

        Step 'Stopping old background process' 50
        Stop-Daemon

        Step 'Installing files' 65
        Copy-Item -LiteralPath $tempScript -Destination $ScriptPath -Force
        Copy-Item -LiteralPath $tempPng -Destination $WallpaperPath -Force

        Write-Config -IntervalSeconds 1 -Enabled $true

        @(
            '@echo off'
            '"' + $PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" %*'
        ) | Set-Content -LiteralPath $ShimPath -Encoding ASCII

        Add-PathEntry

        try {
            $folder = Get-Item -LiteralPath $InstallDir -Force
            $folder.Attributes = $folder.Attributes -bor [System.IO.FileAttributes]::Hidden
        } catch {}

        Step 'Registering sign-in startup' 80
        Register-Startup

        Step 'Applying wallpaper' 90
        Apply-Wallpaper

        Step 'Starting wallpaper enforcement' 97
        Start-Daemon

        Write-Progress -Activity 'fsociety' -Completed
        Log 'Installation completed successfully.'
        Write-Host 'Open a new PowerShell window to use the fsociety command.'
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Update-Fsociety {
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        throw 'fsociety is not installed. Run fsociety install.'
    }

    $temp = Join-Path $env:TEMP ('fsociety-update-' + [guid]::NewGuid().ToString('N'))

    try {
        New-Item -ItemType Directory -Path $temp -Force | Out-Null

        $tempScript = Join-Path $temp 'install.ps1'
        $tempPng = Join-Path $temp '1234.png'

        Download-Files -TempScript $tempScript -TempPng $tempPng
        $config = Read-Config

        Stop-Daemon

        Copy-Item -LiteralPath $tempScript -Destination $ScriptPath -Force
        Copy-Item -LiteralPath $tempPng -Destination $WallpaperPath -Force

        Write-Config -IntervalSeconds $config.IntervalSeconds -Enabled $config.Enabled

        if ($config.Enabled) {
            Apply-Wallpaper
            Register-Startup
            Start-Daemon
        } else {
            Unregister-Startup
        }

        Log 'Update completed; settings preserved.'
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Set-FsocietyEnabled {
    param([bool]$Enabled)

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw 'fsociety is not installed. Run fsociety install.'
    }

    $c = Read-Config
    Write-Config -IntervalSeconds $c.IntervalSeconds -Enabled $Enabled

    if ($Enabled) {
        Register-Startup
        Apply-Wallpaper
        Start-Daemon
        Log 'Enforcement enabled.'
    } else {
        Unregister-Startup
        Stop-Daemon
        Log 'Enforcement disabled.'
    }
}

function Show-FsocietyStatus {
    $c = Read-Config

    Write-Host "Installed: $(Test-Path -LiteralPath $ScriptPath)"
    Write-Host "Wallpaper valid: $(Test-Png $WallpaperPath)"
    Write-Host "Enabled: $($c.Enabled)"
    Write-Host "Interval: $($c.IntervalSeconds) second(s)"
}

function Uninstall-Fsociety {
    Unregister-Startup
    Stop-Daemon
    Remove-PathEntry

    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }

    Log 'fsociety has been uninstalled.'
}

function Run-FsocietyDaemon {
    $mutex = [System.Threading.Mutex]::new($false, $MutexName)
    $owns = $false
    $event = $null

    try {
        try {
            $owns = $mutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $owns = $true
        }

        if (-not $owns) {
            return
        }

        $event = [System.Threading.EventWaitHandle]::new(
            $false,
            [System.Threading.EventResetMode]::AutoReset,
            $StopEventName
        )

        while ($true) {
            $c = Read-Config

            if (-not $c.Enabled) {
                break
            }

            try {
                $current = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper

                if ($current -ine $WallpaperPath) {
                    Apply-Wallpaper
                }
            } catch {}

            if ($event.WaitOne([int]($c.IntervalSeconds * 1000))) {
                break
            }
        }
    } finally {
        if ($null -ne $event) {
            $event.Dispose()
        }

        if ($owns) {
            try { $mutex.ReleaseMutex() } catch {}
        }

        $mutex.Dispose()
    }
}

try {
    if ($Command -eq '-Daemon') {
        Run-FsocietyDaemon
        return
    }

    switch ($Command.ToLowerInvariant()) {
        'install' {
            Install-Fsociety
        }

        'on' {
            Set-FsocietyEnabled -Enabled $true
        }

        'off' {
            Set-FsocietyEnabled -Enabled $false
        }

        'status' {
            Show-FsocietyStatus
        }

        'set' {
            if ($Value) {
                if (-not (Test-Png $Value)) {
                    throw 'The specified file is not a valid PNG.'
                }

                Copy-Item -LiteralPath $Value -Destination $WallpaperPath -Force
            }

            Apply-Wallpaper
            Log 'Wallpaper applied.'
        }

        'time' {
            $seconds = 0

            if (-not [int]::TryParse($Value, [ref]$seconds)) {
                throw 'Usage: fsociety time <seconds>'
            }

            if ($seconds -lt 1 -or $seconds -gt 3600) {
                throw 'Interval must be between 1 and 3600 seconds.'
            }

            $c = Read-Config
            Write-Config -IntervalSeconds $seconds -Enabled $c.Enabled

            if ($c.Enabled) {
                Start-Daemon
            }

            Log "Interval set to $seconds second(s)."
        }

        'update' {
            Update-Fsociety
        }

        'uninstall' {
            Uninstall-Fsociety
        }

        'help' {
            Write-Host 'fsociety install'
            Write-Host 'fsociety on'
            Write-Host 'fsociety off'
            Write-Host 'fsociety status'
            Write-Host 'fsociety set'
            Write-Host 'fsociety set "C:\path\image.png"'
            Write-Host 'fsociety time 20'
            Write-Host 'fsociety update'
            Write-Host 'fsociety uninstall'
            Write-Host 'fsociety help'
        }

        default {
            throw "Unknown command '$Command'. Use fsociety help."
        }
    }
} catch {
    Write-Progress -Activity 'fsociety' -Completed
    Log "ERROR: $($_.Exception.Message)"
    Write-Host "Log file: $LogPath" -ForegroundColor Yellow
}
