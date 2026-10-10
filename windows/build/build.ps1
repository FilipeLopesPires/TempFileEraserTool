<#
.SYNOPSIS
    Builds the TempFileEraserTool release assets.

.DESCRIPTION
    Produces TempFileEraserTool-Script.zip (Script edition) and, unless -SkipInstaller
    is given, TempFileEraserTool-Setup.exe (Installer edition, needs Inno Setup 6).
    Asset names carry no version so README links to releases/latest/download keep working.

.PARAMETER Version
    Version stamped into the installer, e.g. 1.2.0. Defaults to the VERSION file.

.PARAMETER OutputDir
    Folder that receives the assets. It is emptied first.

.PARAMETER SkipInstaller
    Only build the zip, so Inno Setup is not required.
#>
[CmdletBinding()]
param(
    [string]$Version = (Get-Content (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'VERSION') -TotalCount 1).Trim(),

    [string]$OutputDir = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'dist'),

    [switch]$SkipInstaller
)

$ErrorActionPreference = 'Stop'
# $windows holds the Windows edition; $root also holds rules\ and VERSION, which
# the Linux edition shares
$windows = Split-Path $PSScriptRoot -Parent
$root = Split-Path $windows -Parent

# Checked here rather than with ValidatePattern, which skips default values
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version '$Version' must be x.y.z, e.g. 1.2.0 (no 'v' prefix)."
}

if (Test-Path -LiteralPath $OutputDir) { Remove-Item -LiteralPath $OutputDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutputDir | Out-Null

# Script edition: a flat zip, where install.ps1 finds the workers next to itself
$staging = Join-Path $OutputDir 'script-staging'
New-Item -ItemType Directory -Path $staging | Out-Null
Copy-Item -Destination $staging -LiteralPath (@(
        (Join-Path $windows 'script\install.ps1'),
        (Join-Path $windows 'script\uninstall.ps1'),
        (Join-Path $root 'rules\rules.json')) +
    @(Get-ChildItem -LiteralPath (Join-Path $windows 'src') -Filter '*.ps1' | ForEach-Object FullName))
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath (Join-Path $OutputDir 'TempFileEraserTool-Script.zip')
Remove-Item -LiteralPath $staging -Recurse -Force
Write-Host "Built $(Join-Path $OutputDir 'TempFileEraserTool-Script.zip')"

if ($SkipInstaller) { return }

$iscc = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source,
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 was not found. Install it with: winget install JRSoftware.InnoSetup' }

& $iscc "/DAppVersion=$Version" "/O$OutputDir" (Join-Path $windows 'installer\TempFileEraserTool.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compiler failed with exit code $LASTEXITCODE" }
Write-Host "Built $(Join-Path $OutputDir 'TempFileEraserTool-Setup.exe')"
