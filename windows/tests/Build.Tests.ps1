#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    $root = Split-Path $repo -Parent
    $out  = Join-Path $TestDrive 'dist'
    & (Join-Path $repo 'build\build.ps1') -OutputDir $out -SkipInstaller
    $zip  = Join-Path $out 'TempFileEraserTool-Script.zip'
}

Describe 'build.ps1 -SkipInstaller' {
    It 'creates the Script edition zip' {
        $zip | Should -Exist
    }

    It 'puts the install scripts and every worker script at the zip root' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try { $names = @($archive.Entries.FullName | Sort-Object) } finally { $archive.Dispose() }

        $names | Should -Be @(@(
                'install.ps1', 'uninstall.ps1', 'Clear-TempFolders.ps1',
                'TempFolderRules.ps1', 'TempFolderScanner.ps1', 'TempFolderRemover.ps1',
                'rules.json') | Sort-Object)
    }

    It 'does not build the installer' {
        Join-Path $out 'TempFileEraserTool-Setup.exe' | Should -Not -Exist
    }

    It 'leaves no staging folder behind' {
        @(Get-ChildItem $out -Directory).Count | Should -Be 0
    }
}

Describe 'Versioning' {
    It 'keeps a plain x.y.z version in the VERSION file' {
        (Get-Content (Join-Path $root 'VERSION') -TotalCount 1).Trim() | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'rejects a version that is not x.y.z' {
        { & (Join-Path $repo 'build\build.ps1') -Version 'v1.0' -OutputDir (Join-Path $TestDrive 'bad') -SkipInstaller } |
            Should -Throw '*x.y.z*'
    }
}
