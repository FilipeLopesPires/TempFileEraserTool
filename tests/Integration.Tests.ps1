#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeDiscovery {
    # Installer edition tests need a built installer: .\build\build.ps1
    $setupMissing = -not (Test-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\TempFileEraserTool-Setup.exe'))
}

# These tests install and uninstall the real tool on this machine.
# Excluded locally with: Invoke-Pester -Path tests -ExcludeTagFilter Integration

BeforeAll {
    $repo                  = Split-Path $PSScriptRoot -Parent
    $folderMenuKey         = 'HKCU:\Software\Classes\Directory\shell\TempFileEraserTool'
    $backgroundMenuKey     = 'HKCU:\Software\Classes\Directory\Background\shell\TempFileEraserTool'
    $scriptDir             = Join-Path $env:LOCALAPPDATA 'TempFileEraserTool'
    $installerDir          = Join-Path $env:LOCALAPPDATA 'Programs\TempFileEraserTool'
    $installerUninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{1B36309B-F347-4709-98CD-45D80C17AB47}_is1'
    $workerFiles           = 'Clear-TempFolders.ps1', 'TempFolderRules.ps1', 'TempFolderScanner.ps1', 'TempFolderRemover.ps1'

    function Wait-Condition {
        param([Parameter(Mandatory)][scriptblock]$Condition, [int]$TimeoutSeconds = 30)
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not (& $Condition)) {
            if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutSeconds s waiting for: $Condition" }
            Start-Sleep -Milliseconds 250
        }
    }

    function Get-MenuCommand {
        param([Parameter(Mandatory)][string]$MenuKey)
        (Get-Item -LiteralPath "$MenuKey\command").GetValue('')
    }

    # Removes both editions, so every Describe block starts from a clean machine
    function Reset-TempFileEraserTool {
        $uninstaller = Join-Path $installerDir 'unins000.exe'
        if (Test-Path -LiteralPath $uninstaller) {
            Start-Process $uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES' -Wait
            # The Inno uninstaller relaunches itself from %TEMP%, so -Wait can return early
            Wait-Condition { -not (Test-Path -LiteralPath $installerUninstallKey) }
        }
        Remove-Item -LiteralPath $installerUninstallKey -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $folderMenuKey -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backgroundMenuKey -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $scriptDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Script edition' -Tag Integration {
    BeforeAll { Reset-TempFileEraserTool }
    AfterAll { Reset-TempFileEraserTool }

    It 'installs from a repository clone' {
        & (Join-Path $repo 'script\install.ps1') | Out-Null

        foreach ($file in $workerFiles) { Join-Path $scriptDir $file | Should -Exist }
        Get-MenuCommand $folderMenuKey | Should -BeLike "*-File `"$scriptDir\Clear-TempFolders.ps1`" -Path `"%1`""
        Get-MenuCommand $backgroundMenuKey | Should -BeLike "*-File `"$scriptDir\Clear-TempFolders.ps1`" -Path `"%V`""
    }

    It 'uninstalls completely' {
        & (Join-Path $repo 'script\uninstall.ps1') | Out-Null

        $folderMenuKey | Should -Not -Exist
        $backgroundMenuKey | Should -Not -Exist
        $scriptDir | Should -Not -Exist
    }

    It 'installs from the flat release zip layout' {
        $flat = Join-Path $TestDrive 'flat'
        New-Item -ItemType Directory $flat | Out-Null
        Copy-Item (Join-Path $repo 'script\install.ps1') $flat
        foreach ($file in $workerFiles) { Copy-Item (Join-Path $repo "src\$file") $flat }

        & (Join-Path $flat 'install.ps1') | Out-Null

        foreach ($file in $workerFiles) { Join-Path $scriptDir $file | Should -Exist }
    }

    Context 'when the Installer edition is installed' {
        BeforeAll { New-Item -Path $installerUninstallKey -Force | Out-Null }
        AfterAll { Remove-Item -LiteralPath $installerUninstallKey -Recurse -Force }

        It 'install.ps1 refuses to run' {
            { & (Join-Path $repo 'script\install.ps1') } | Should -Throw '*Installer edition*'
        }

        It 'uninstall.ps1 refuses to remove the installer''s menu entries' {
            { & (Join-Path $repo 'script\uninstall.ps1') } | Should -Throw '*Installer edition*'
        }
    }
}

Describe 'Installer edition' -Tag Integration -Skip:$setupMissing {
    BeforeAll {
        Reset-TempFileEraserTool
        $setup = Join-Path $repo 'dist\TempFileEraserTool-Setup.exe'

        function Invoke-Setup {
            Start-Process $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
        }
    }
    AfterAll { Reset-TempFileEraserTool }

    It 'takes over an existing Script edition install' {
        & (Join-Path $repo 'script\install.ps1') | Out-Null

        Invoke-Setup

        $scriptDir | Should -Not -Exist
        Get-MenuCommand $folderMenuKey | Should -BeLike "*-File `"$installerDir\Clear-TempFolders.ps1`" -Path `"%1`""
        Get-MenuCommand $backgroundMenuKey | Should -BeLike "*-File `"$installerDir\Clear-TempFolders.ps1`" -Path `"%V`""
    }

    It 'installs the workers and registers both menu entries' {
        foreach ($file in $workerFiles) { Join-Path $installerDir $file | Should -Exist }
        foreach ($menuKey in $folderMenuKey, $backgroundMenuKey) {
            $menu = Get-Item -LiteralPath $menuKey
            $menu.GetValue('MUIVerb') | Should -Be 'Clean up temp and cache folders'
            $menu.GetValue('Icon', $null, 'DoNotExpandEnvironmentNames') | Should -Be '%SystemRoot%\System32\cleanmgr.exe,0'
            Get-MenuCommand $menuKey | Should -BeLike 'conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File *'
        }
    }

    It 'appears in Installed apps' {
        (Get-ItemProperty -LiteralPath $installerUninstallKey).DisplayName | Should -Be 'TempFileEraserTool'
    }

    It 'uninstalls completely' {
        Start-Process (Join-Path $installerDir 'unins000.exe') -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES' -Wait
        Wait-Condition { -not (Test-Path -LiteralPath $installerUninstallKey) }
        Wait-Condition { -not (Test-Path -LiteralPath $installerDir) }

        $folderMenuKey | Should -Not -Exist
        $backgroundMenuKey | Should -Not -Exist
    }
}
