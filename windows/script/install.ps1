<#
.SYNOPSIS
    Adds "Clean up temp and cache folders" to the Explorer folder context menus.

.DESCRIPTION
    Copies the worker scripts to %LOCALAPPDATA%\TempFileEraserTool and registers
    per-user (HKCU) context menu entries for right-clicking a folder and for
    right-clicking the empty area inside one. No administrator rights are required.
    Safe to run again: it overwrites the previous installation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$toolDir     = Join-Path $env:LOCALAPPDATA 'TempFileEraserTool'
$worker      = Join-Path $toolDir 'Clear-TempFolders.ps1'
$workerFiles = 'Clear-TempFolders.ps1', 'TempFolderRules.ps1', 'TempFolderScanner.ps1', 'TempFolderRemover.ps1', 'rules.json'
$menuVerb    = 'Clean up temp and cache folders'
$menuIcon    = '%SystemRoot%\System32\cleanmgr.exe,0'
# Explorer passes the clicked folder as %1, and the folder being browsed as %V
$menuEntries = @{
    'Software\Classes\Directory\shell\TempFileEraserTool'            = '%1'
    'Software\Classes\Directory\Background\shell\TempFileEraserTool' = '%V'
}
# Must match AppId in installer\TempFileEraserTool.iss
$installerEditionKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{1B36309B-F347-4709-98CD-45D80C17AB47}_is1'

if (Test-Path -LiteralPath $installerEditionKey) {
    throw 'The Installer edition of TempFileEraserTool is already installed. Keep using it, or uninstall it from Settings > Apps before installing the Script edition.'
}

# Release zip: every file sits next to this script. Repository clone: the workers
# are in ..\src and the rule table in ..\rules
$searchDirs = @($PSScriptRoot, (Join-Path $PSScriptRoot '..\src'), (Join-Path $PSScriptRoot '..\..\rules'))

function Resolve-SourceFile {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($dir in $searchDirs) {
        $candidate = Join-Path $dir $Name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw "$Name was not found next to install.ps1, in ..\src or in ..\..\rules."
}

New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
foreach ($file in $workerFiles) {
    $target = Join-Path $toolDir $file
    Copy-Item -LiteralPath (Resolve-SourceFile $file) -Destination $target -Force
    # Files extracted from a downloaded zip carry the "downloaded from the internet" mark
    Unblock-File -LiteralPath $target
}

foreach ($menuSubKey in $menuEntries.Keys) {
    # conhost --headless runs PowerShell without the console window flashing on screen
    $command = "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA " +
               "-File `"$worker`" -Path `"$($menuEntries[$menuSubKey])`""

    # The .NET API creates any missing parent keys, which New-Item does not do reliably
    $menuKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($menuSubKey)
    try {
        $menuKey.SetValue('MUIVerb', $menuVerb)
        $menuKey.SetValue('Icon', $menuIcon, [Microsoft.Win32.RegistryValueKind]::ExpandString)

        $commandKey = $menuKey.CreateSubKey('command')
        try {
            $commandKey.SetValue('', $command)
        } finally {
            $commandKey.Close()
        }
    } finally {
        $menuKey.Close()
    }
}

Write-Host "Installed to $toolDir"
Write-Host "Right-click a folder, or an empty area inside one (Show more options on Windows 11), and choose `"$menuVerb`"."
