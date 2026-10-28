param([switch]$Update)

$ErrorActionPreference = 'Stop'

# Replace YOUR_GITHUB_USERNAME before publishing this repository.
$RepoOwner = 'YOUR_GITHUB_USERNAME'
$RepoName = 'fsociety'
if ($RepoOwner -eq 'YOUR_GITHUB_USERNAME') {
    throw "Edit install.ps1 and replace YOUR_GITHUB_USERNAME with your GitHub username before publishing."
}
$RawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/main"

$Base = Join-Path $env:LOCALAPPDATA '1234'
$Bin = Join-Path $Base 'bin'
$Image = Join-Path $Base '1234.png'
$State = Join-Path $Base 'enabled.txt'
$Monitor = Join-Path $Base 'monitor.ps1'
$Control = Join-Path $Base 'control.ps1'
$Shim = Join-Path $Bin 'fsociety.cmd'

New-Item -ItemType Directory -Path $Base, $Bin -Force | Out-Null
# Keep the application folder out of normal File Explorer views.
try { & attrib.exe +h $Base } catch {}

if (-not (Test-Path $State)) {
    Set-Content -LiteralPath $State -Value 'on' -Encoding ASCII
}

if (-not (Test-Path $Image)) {
    $ImageUrl = 'https://rare-gallery.com/thumbs/4501587-elliot-mr-robot-face-mr.-robot-tv-fsociety-simple-background-black-background-monochrome.png'
    Invoke-WebRequest -Uri $ImageUrl -OutFile $Image
    $bytes = [System.IO.File]::ReadAllBytes($Image)
    $signature = '89504E470D0A1A0A'
    $actual = ([BitConverter]::ToString($bytes[0..7])).Replace('-', '')
    if ($bytes.Length -lt 1000 -or $actual -ne $signature) {
        Remove-Item -LiteralPath $Image -Force -ErrorAction SilentlyContinue
        throw 'Wallpaper download did not return a valid PNG. Check the image URL and try again.'
    }
}

$monitorText = @'
$ErrorActionPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA '1234'
$image = Join-Path $root '1234.png'
$state = Join-Path $root 'enabled.txt'

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class FsocietyWallpaperNative {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SystemParametersInfo(uint action, uint param, StringBuilder value, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SystemParametersInfo(uint action, uint param, string value, uint flags);
    public static string GetWallpaper() {
        StringBuilder b = new StringBuilder(1024);
        SystemParametersInfo(0x0073, (uint)b.Capacity, b, 0);
        return b.ToString();
    }
    public static bool SetWallpaper(string path) {
        return SystemParametersInfo(20, 0, path, 3);
    }
}
"@

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\Fsociety1234Monitor', [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit
}

try {
    while ($true) {
        if (-not (Test-Path $state) -or (Get-Content -LiteralPath $state -Raw).Trim() -ne 'on') {
            break
        }
        if (Test-Path $image) {
            $current = [FsocietyWallpaperNative]::GetWallpaper()
            if (-not [string]::Equals($current, $image, [StringComparison]::OrdinalIgnoreCase)) {
                [FsocietyWallpaperNative]::SetWallpaper($image) | Out-Null
            }
        }
        Start-Sleep -Seconds 1
    }
} finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
'@

$controlText = @'
param([string]$Action = 'status')
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA '1234'
$state = Join-Path $root 'enabled.txt'
$rawBase = '__RAW_BASE__'
$monitor = Join-Path $root 'monitor.ps1'

switch ($Action.ToLowerInvariant()) {
    'on' {
        Set-Content -LiteralPath $state -Value 'on' -Encoding ASCII
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$monitor`"")
        Write-Output 'fsociety enabled.'
    }
    'off' {
        Set-Content -LiteralPath $state -Value 'off' -Encoding ASCII
        Write-Output 'fsociety disabled.'
    }
    'status' {
        if (Test-Path $state) { Get-Content -LiteralPath $state } else { Write-Output 'not installed' }
    }
    'set' {
        Set-Content -LiteralPath $state -Value 'on' -Encoding ASCII
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$monitor`"")
    }
    'update' {
        $temp = Join-Path $env:TEMP 'fsociety-install-update.ps1'
        Invoke-WebRequest -Uri "$rawBase/install.ps1" -OutFile $temp
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $temp -Update
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
    'uninstall' {
        Set-Content -LiteralPath $state -Value 'off' -Encoding ASCII -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name '1234Wallpaper' -ErrorAction SilentlyContinue
        $bin = Join-Path $root 'bin'
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath) {
            $newPath = (($userPath -split ';' | Where-Object { $_.TrimEnd('\') -ne $bin.TrimEnd('\') }) -join ';')
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        }
        Start-Sleep -Milliseconds 1200
        Remove-Item -LiteralPath $root -Recurse -Force
        Write-Output 'fsociety uninstalled. Open a new Terminal window.'
    }
    default {
        Write-Output 'Usage: fsociety on|off|status|set|update|uninstall'
    }
}
'@

$controlText = $controlText.Replace('__RAW_BASE__', $RawBase)
Set-Content -LiteralPath $Monitor -Value $monitorText -Encoding UTF8
Set-Content -LiteralPath $Control -Value $controlText -Encoding UTF8

@'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\1234\control.ps1" %*
'@ | Set-Content -LiteralPath $Shim -Encoding ASCII

# Register per-user startup; no administrator privileges are required.
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-Item -Path $runKey -Force | Out-Null
Set-ItemProperty -Path $runKey -Name '1234Wallpaper' -Value "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Monitor`""

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathParts = @()
if ($userPath) { $pathParts = @($userPath -split ';' | Where-Object { $_ }) }
if ($pathParts -notcontains $Bin) {
    $pathParts += $Bin
    [Environment]::SetEnvironmentVariable('Path', ($pathParts -join ';'), 'User')
}

Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$Monitor`"")
if ($Update) {
    Write-Output 'fsociety updated. Existing enabled/disabled setting was preserved.'
} else {
    Write-Output 'fsociety installed and enabled. Open a NEW Terminal window, then use: fsociety on/off/status/update/uninstall'
}
