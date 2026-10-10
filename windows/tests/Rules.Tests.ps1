#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\TempFolderRules.ps1')

    function Get-Match {
        param([string]$Kind, [string]$Name, [string[]]$Siblings = @(), [string]$Path)
        Get-TempMatch -Kind $Kind -Name $Name -Siblings (New-SiblingSet $Siblings) -Path $Path
    }
}

Describe 'Folder rules without markers' {
    It 'matches <Name> anywhere' -ForEach @(
        @{ Name = 'node_modules' }, @{ Name = '__pycache__' }, @{ Name = '.pytest_cache' },
        @{ Name = '.next' }, @{ Name = '.gradle' }, @{ Name = '.vs' }, @{ Name = '.idea' },
        @{ Name = '.terraform' }, @{ Name = 'CMakeFiles' }, @{ Name = '.dart_tool' }
    ) {
        $match = Get-Match Folder $Name
        $match.Confidence | Should -Be 'Certain'
    }

    It 'matches case-insensitively' {
        (Get-Match Folder 'Node_Modules').Confidence | Should -Be 'Certain'
    }

    It 'matches wildcard names' {
        (Get-Match Folder 'my_package.egg-info').Confidence | Should -Be 'Certain'
    }

    It 'returns nothing for an ordinary folder' {
        Get-Match Folder 'src' | Should -BeNullOrEmpty
    }
}

Describe 'Folder rules with markers' {
    It 'matches <Name> next to <Marker>' -ForEach @(
        @{ Name = 'dist'; Marker = 'package.json' },
        @{ Name = 'bin'; Marker = 'App.csproj' },
        @{ Name = 'obj'; Marker = 'Solution.sln' },
        @{ Name = 'target'; Marker = 'Cargo.toml' },
        @{ Name = 'target'; Marker = 'pom.xml' },
        @{ Name = 'build'; Marker = 'build.gradle.kts' },
        @{ Name = 'cmake-build-debug'; Marker = 'CMakeLists.txt' },
        @{ Name = 'Intermediate'; Marker = 'Game.uproject' },
        @{ Name = 'Saved'; Marker = 'Game.uproject' },
        @{ Name = 'Binaries'; Marker = 'MyPlugin.uplugin' },
        @{ Name = '.godot'; Marker = 'project.godot' },
        @{ Name = 'vendor'; Marker = 'composer.json' },
        @{ Name = '_build'; Marker = 'mix.exs' }
    ) {
        (Get-Match Folder $Name @($Marker, 'README.md')).Confidence | Should -Be 'Certain'
    }

    It 'needs both Unity markers' {
        (Get-Match Folder 'Library' @('Assets', 'ProjectSettings')).Confidence | Should -Be 'Certain'
        Get-Match Folder 'Library' @('Assets') | Should -BeNullOrEmpty
    }

    It 'reports a moderately generic name without a marker as uncertain: <Name>' -ForEach @(
        @{ Name = 'bin' }, @{ Name = 'obj' }, @{ Name = 'build' }, @{ Name = 'dist' },
        @{ Name = 'out' }, @{ Name = 'target' }, @{ Name = 'Temp' }, @{ Name = 'Intermediate' },
        @{ Name = 'DerivedDataCache' }
    ) {
        (Get-Match Folder $Name @('notes.txt')).Confidence | Should -Be 'Uncertain'
    }

    It 'ignores a very generic name without a marker: <Name>' -ForEach @(
        @{ Name = 'Library' }, @{ Name = 'Logs' }, @{ Name = 'Saved' }, @{ Name = 'Binaries' },
        @{ Name = 'deps' }, @{ Name = 'vendor' }, @{ Name = 'Pods' }, @{ Name = 'coverage' },
        @{ Name = 'Builds' }
    ) {
        Get-Match Folder $Name @('notes.txt') | Should -BeNullOrEmpty
    }

    It 'prefers a certain match over an uncertain one' {
        $match = Get-Match Folder 'build' @('package.json')
        $match.Confidence | Should -Be 'Certain'
        $match.Category | Should -Be 'Node.js build output'
    }
}

Describe 'Python virtual environments' {
    It 'detects a venv by its pyvenv.cfg, whatever its name' {
        $venv = Join-Path $TestDrive 'my-env'
        New-Item -ItemType Directory $venv | Out-Null
        Set-Content -LiteralPath (Join-Path $venv 'pyvenv.cfg') -Value 'home = C:\Python'

        (Get-Match Folder 'my-env' -Path $venv).Category | Should -Be 'Python virtual environment'
    }

    It 'does not treat a folder without pyvenv.cfg as a venv' {
        $plain = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory $plain | Out-Null

        Get-Match Folder 'plain' -Path $plain | Should -BeNullOrEmpty
    }
}

Describe 'File rules' {
    It 'matches <Name>' -ForEach @(
        @{ Name = 'Thumbs.db' }, @{ Name = '.DS_Store' }, @{ Name = '~$Report.docx' },
        @{ Name = '~$Budget.xlsx' }, @{ Name = 'setup.tmp' }, @{ Name = '.main.py.swp' },
        @{ Name = '._photo.jpg' }, @{ Name = '.~lock.notes.odt#' }, @{ Name = 'stray.pyc' },
        @{ Name = '.eslintcache' }, @{ Name = 'tsconfig.tsbuildinfo' }, @{ Name = 'npm-debug.log' },
        @{ Name = 'npm-debug.log.12345' }, @{ Name = 'yarn-error.log' }, @{ Name = 'hs_err_pid42.log' },
        @{ Name = 'crash.dmp' }, @{ Name = 'bash.exe.stackdump' }
    ) {
        (Get-Match File $Name).Confidence | Should -Be 'Certain'
    }

    It 'reports a plain .log file as uncertain' {
        (Get-Match File 'server.log').Confidence | Should -Be 'Uncertain'
    }

    It 'never matches <Name>' -ForEach @(
        @{ Name = 'desktop.ini' }, @{ Name = 'notes.bak' }, @{ Name = 'file.orig' },
        @{ Name = 'patch.rej' }, @{ Name = 'draft.txt~' }, @{ Name = 'Report.docx' }
    ) {
        Get-Match File $Name | Should -BeNullOrEmpty
    }

    It 'matches Unity project files only inside a Unity project' {
        (Get-Match File 'Game.csproj' @('Assets', 'ProjectSettings', 'Game.csproj')).Confidence | Should -Be 'Certain'
        Get-Match File 'Game.csproj' @('Game.csproj', 'Program.cs') | Should -BeNullOrEmpty
    }

    It 'matches Unreal solution files only next to a .uproject' {
        (Get-Match File 'Game.sln' @('Game.uproject', 'Game.sln')).Confidence | Should -Be 'Certain'
        Get-Match File 'Game.sln' @('Game.sln') | Should -BeNullOrEmpty
    }
}
