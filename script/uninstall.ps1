<#
.SYNOPSIS
    Removes the "Clean up temp and cache folders" context menu entries and the tool files.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$toolDir     = Join-Path $env:LOCALAPPDATA 'TempFileEraserTool'
$menuSubKeys = 'Software\Classes\Directory\shell\TempFileEraserTool',
               'Software\Classes\Directory\Background\shell\TempFileEraserTool'
# Must match AppId in installer\TempFileEraserTool.iss
$installerEditionKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{1B36309B-F347-4709-98CD-45D80C17AB47}_is1'

# Both editions share the menu keys; removing them here would break the Installer edition
if (Test-Path -LiteralPath $installerEditionKey) {
    throw 'The Installer edition of TempFileEraserTool is installed. Uninstall it from Settings > Apps instead.'
}

foreach ($menuSubKey in $menuSubKeys) {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($menuSubKey, $false)
}

if (Test-Path -LiteralPath $toolDir) {
    Remove-Item -LiteralPath $toolDir -Recurse -Force
}

Write-Host 'Context menu entries and tool files removed.'
