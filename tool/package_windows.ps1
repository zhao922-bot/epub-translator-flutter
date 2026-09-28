#Requires -Version 5.1
<#
.SYNOPSIS
    Build the Windows release and package a portable ZIP that runs on clean
    Windows 10/11 machines.

.DESCRIPTION
    `flutter build windows` does NOT bundle the Visual C++ runtime DLLs
    (msvcp140.dll, vcruntime140.dll, ...), so the app dies on startup with a
    missing-DLL error on machines without Visual Studio or the VC++
    Redistributable installed. This script:

      1. Runs `flutter build windows --release` (unless -SkipBuild).
      2. Finds the VC++ runtime DLLs on this machine and copies them next to
         the exe. Aborts with a clear message if they cannot be found.
      3. Validates the release folder (exe, data folder, flutter_windows.dll,
         the copied runtime DLLs).
      4. Creates dist\epub-translator-flutter-v<version>-windows-x64.zip and
         validates the zip contents.

.PARAMETER Version
    Version string for the zip file name. Defaults to `version:` in
    pubspec.yaml (build-number suffix stripped).

.PARAMETER OutDir
    Directory for the zip file. Defaults to <repo>\dist.

.PARAMETER SkipBuild
    Skip the flutter build and package the existing Release output.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$OutDir = '',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The VC++ runtime DLLs we bundle are x64-only, and a 32-bit PowerShell
# would resolve %SystemRoot%\System32 to SysWOW64 (filesystem redirection),
# silently picking 32-bit DLLs. Fail fast with the exact re-run command.
# NOTE: from a 32-bit process the 64-bit System32 is reachable as Sysnative.
if (-not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    throw ('This script must run in 64-bit PowerShell, but the current process is 32-bit. ' +
        'Re-run with: ' + $ps64 + ' -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
}

$RepoRoot = Split-Path -Parent $PSScriptRoot

# Shallow-path guard (before Set-Location/build): Compress-Archive on
# PowerShell 5.1 has no longPathAware support, so a repo nested ~200+
# characters deep fails the build/zip with cryptic errors. Fail fast with
# an actionable message instead.
if ($RepoRoot.Length -gt 200) {
    throw ('Repository path is ' + $RepoRoot.Length + ' characters long, which exceeds the ' +
        '200-character limit for reliable packaging on PowerShell 5.1. Move the repository ' +
        'to a shallow directory, e.g. C:\\src\\epub-translator-flutter, and re-run this script.')
}

Set-Location -Path $RepoRoot

function Get-PubspecVersion {
    foreach ($line in (Get-Content -Path (Join-Path $RepoRoot 'pubspec.yaml'))) {
        if ($line -match '^\s*version\s*:\s*(\S+)') {
            $raw = $Matches[1].Trim().Trim('"').Trim("'")
            return ($raw -split '\+')[0]
        }
    }
    throw 'Could not read "version:" from pubspec.yaml.'
}

function Get-BinaryName {
    $cmakeLists = Join-Path $RepoRoot 'windows\CMakeLists.txt'
    foreach ($line in (Get-Content -Path $cmakeLists)) {
        if ($line -match 'set\s*\(\s*BINARY_NAME\s+"([^"]+)"') {
            return $Matches[1]
        }
    }
    throw 'Could not read BINARY_NAME from windows\CMakeLists.txt.'
}

function Get-MsvcVersion {
    param([string]$Path)
    $m = [regex]::Match($Path, '\\MSVC\\([^\\]+)\\')
    if ($m.Success) {
        try {
            return [version]$m.Groups[1].Value
        } catch {
        }
    }
    return [version]'0.0'
}

function Test-DllSetPresent {
    param([string]$Dir, [string[]]$Names)
    foreach ($n in $Names) {
        if (-not (Test-Path -Path (Join-Path $Dir $n) -PathType Leaf)) {
            return $false
        }
    }
    return $true
}

function Test-DllIsAmd64 {
    param([string]$Path)
    # A 32-bit (x86) DLL next to the exe would fail at startup with a
    # confusing loader error, so verify the PE Machine field is
    # IMAGE_FILE_MACHINE_AMD64 (0x8664) instead of only checking the file
    # exists. Reads the DOS header e_lfanew at 0x3C, then the 2-byte
    # Machine field right after the "PE`0`0" signature.
    # PowerShell 5.1 compatible (no ternary, no using statement).
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            if ($stream.Length -lt 0x40) {
                return $false
            }
            $reader = New-Object System.IO.BinaryReader($stream)
            $stream.Position = 0x3C
            $peOffset = $reader.ReadInt32()
            if ($peOffset -lt 0 -or ($peOffset + 6) -gt $stream.Length) {
                return $false
            }
            $stream.Position = $peOffset
            $signature = $reader.ReadUInt32()
            if ($signature -ne 0x00004550) {
                return $false
            }
            $machine = $reader.ReadUInt16()
            return $machine -eq 0x8664
        } finally {
            $stream.Close()
        }
    } catch {
        return $false
    }
}

function Find-VcRuntimeDir {
    # 1) Visual Studio / Build Tools redist layout (guaranteed x64 binaries,
    #    newest MSVC version first).
    foreach ($pfVar in @('ProgramFiles', 'ProgramFiles(x86)')) {
        $pf = [Environment]::GetEnvironmentVariable($pfVar)
        if ([string]::IsNullOrEmpty($pf)) {
            continue
        }
        $vsDir = Join-Path $pf 'Microsoft Visual Studio'
        if (-not (Test-Path -Path $vsDir -PathType Container)) {
            continue
        }
        $pattern = Join-Path $vsDir '*\*\VC\Redist\MSVC\*\x64\Microsoft.VC1*.CRT'
        $crtDirs = Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue |
            Sort-Object { Get-MsvcVersion $_.FullName } -Descending
        foreach ($d in $crtDirs) {
            if (Test-DllSetPresent -Dir $d.FullName -Names $RequiredDlls) {
                return $d.FullName
            }
        }
    }
    # 2) System32: present on any machine with the redistributable installed.
    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
    if (-not [string]::IsNullOrEmpty($systemRoot)) {
        $system32 = Join-Path $systemRoot 'System32'
        if (Test-DllSetPresent -Dir $system32 -Names $RequiredDlls) {
            return $system32
        }
    }
    throw ('Could not find the Visual C++ runtime DLLs (' + ($RequiredDlls -join ', ') + '). ' +
        'Install "Microsoft Visual C++ Redistributable (x64)" and re-run this script: ' +
        'https://aka.ms/vs/17/release/vc_redist.x64.exe')
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ''
    Write-Host "==> $Name" -ForegroundColor Cyan
    & $Body
}

# --- Configuration -----------------------------------------------------------

$RequiredDlls = @('msvcp140.dll', 'msvcp140_1.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
$OptionalDlls = @('msvcp140_2.dll', 'concrt140.dll', 'vcomp140.dll')

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Get-PubspecVersion
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $RepoRoot 'dist'
}
$BinaryName = Get-BinaryName
$ExeName = "$BinaryName.exe"
$ReleaseDir = Join-Path $RepoRoot 'build\windows\x64\runner\Release'

Write-Host "Repository : $RepoRoot"
Write-Host "Version    : $Version"
Write-Host "Binary     : $ExeName"

# --- 1. Build ----------------------------------------------------------------

Invoke-Step 'flutter build windows --release' {
    if ($SkipBuild) {
        if (-not (Test-Path -Path $ReleaseDir -PathType Container)) {
            throw "-SkipBuild was given but the Release folder does not exist: $ReleaseDir"
        }
        Write-Host 'Skipped (using existing Release output).'
    } else {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) {
            throw "flutter build windows --release failed (exit code $LASTEXITCODE)."
        }
    }
}

# --- 2. Bundle the VC++ runtime ----------------------------------------------

Invoke-Step 'Copy VC++ runtime DLLs next to the exe' {
    $vcDir = Find-VcRuntimeDir
    Write-Host "Using VC++ runtime from: $vcDir"
    foreach ($dll in ($RequiredDlls + $OptionalDlls)) {
        $src = Join-Path $vcDir $dll
        if (Test-Path -Path $src -PathType Leaf) {
            if (-not (Test-DllIsAmd64 -Path $src)) {
                throw ("VC++ runtime DLL is not a 64-bit (x64) binary: $src. " +
                    'Refusing to bundle it — an x86 DLL next to the exe would crash on startup.')
            }
            Copy-Item -Path $src -Destination (Join-Path $ReleaseDir $dll) -Force
            Write-Host "  copied $dll"
        } elseif ($RequiredDlls -contains $dll) {
            throw "Required DLL is missing in ${vcDir}: $dll"
        } else {
            Write-Host "  optional $dll not present, skipped" -ForegroundColor DarkGray
        }
    }
}

# --- 3. Validate the release folder -------------------------------------------

Invoke-Step 'Validate release folder' {
    $missing = @()
    foreach ($req in @($ExeName, 'flutter_windows.dll')) {
        if (-not (Test-Path -Path (Join-Path $ReleaseDir $req) -PathType Leaf)) {
            $missing += $req
        }
    }
    if (-not (Test-Path -Path (Join-Path $ReleaseDir 'data') -PathType Container)) {
        $missing += 'data\'
    }
    foreach ($dll in $RequiredDlls) {
        if (-not (Test-Path -Path (Join-Path $ReleaseDir $dll) -PathType Leaf)) {
            $missing += $dll
        }
    }
    if ($missing.Count -gt 0) {
        throw "Release folder validation failed, missing: $($missing -join ', ')"
    }
    if (-not (Test-Path -Path (Join-Path $ReleaseDir 'plugins') -PathType Container)) {
        Write-Warning 'plugins\ folder not found in the Release output.'
    }
    Write-Host 'Release folder OK.'
}

# --- 4. Zip and validate -------------------------------------------------------

Invoke-Step 'Create portable zip' {
    if (-not (Test-Path -Path $OutDir -PathType Container)) {
        New-Item -Path $OutDir -ItemType Directory | Out-Null
    }
    $zipName = "epub-translator-flutter-v$Version-windows-x64.zip"
    $zipPath = Join-Path $OutDir $zipName
    if (Test-Path -Path $zipPath -PathType Leaf) {
        Remove-Item -Path $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $ReleaseDir '*') -DestinationPath $zipPath -Force

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entries = @($zip.Entries | ForEach-Object { $_.FullName })
        $missing = @()
        foreach ($req in @($ExeName, 'flutter_windows.dll')) {
            if (-not ($entries -contains $req)) {
                $missing += $req
            }
        }
        if (-not ($entries | Where-Object { $_ -like 'data/*' })) {
            $missing += 'data\*'
        }
        foreach ($dll in $RequiredDlls) {
            if (-not ($entries -contains $dll)) {
                $missing += $dll
            }
        }
        if ($missing.Count -gt 0) {
            throw "Zip validation failed, missing: $($missing -join ', ')"
        }
    } finally {
        $zip.Dispose()
    }
    $sizeMb = '{0:N1}' -f ((Get-Item $zipPath).Length / 1MB)
    Write-Host "Portable package ready: $zipPath ($sizeMb MB)" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done. The zip runs on clean Windows 10/11 (no Visual Studio / VC++ redist needed).' -ForegroundColor Green
