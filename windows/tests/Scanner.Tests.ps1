#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\TempFolderRules.ps1')
    . (Join-Path $PSScriptRoot '..\src\TempFolderScanner.ps1')

    function New-TestFile {
        # \\?\ paths so fixtures can be longer than 260 characters
        param([string]$Path, [int]$Bytes = 10)
        $long = "\\?\$Path"
        [System.IO.Directory]::CreateDirectory($long.Substring(0, $long.LastIndexOf('\'))) | Out-Null
        [System.IO.File]::WriteAllBytes($long, [byte[]]::new($Bytes))
    }

    function Invoke-Scan {
        param([string]$Root, [string[]]$Zones = @(), [hashtable]$State = [hashtable]::Synchronized(@{ Cancel = $false }))
        $queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Invoke-TempScan -Root $Root -Queue $queue -State $State -Zones $Zones
        $message = $null
        $messages = while ($queue.TryDequeue([ref]$message)) { $message }
        return , @($messages)
    }
}

Describe 'Invoke-TempScan' {
    BeforeAll {
        $root = Join-Path $TestDrive 'root'
        $outside = Join-Path $TestDrive 'outside'

        New-TestFile "$root\web\package.json"
        New-TestFile "$root\web\node_modules\left-pad\index.js" 100
        New-TestFile "$root\web\node_modules\left-pad\node_modules\inner\index.js" 50
        New-TestFile "$root\web\dist\app.js" 30
        New-TestFile "$root\web\src\main.js"
        New-TestFile "$root\web\npm-debug.log" 7
        New-TestFile "$root\web\Thumbs.db" 3
        New-TestFile "$root\web\server.log" 5
        New-TestFile "$root\.git\objects\node_modules\x"
        New-TestFile "$root\docs\build\page.html"
        New-TestFile "$root\py\.venv\pyvenv.cfg"
        New-TestFile "$root\py\__pycache__\a.pyc"
        New-TestFile "$root\My [Brackets] Folder\node_modules\x.js"
        New-TestFile "$root\fakezone\node_modules\x.js"
        New-TestFile "$root\Users\someone\AppData\Local\Programs\app\node_modules\x.js"

        # A junction inside a match must not be counted, and one outside must not be scanned
        New-TestFile "$outside\node_modules\big.bin" 5000
        New-Item -ItemType Junction -Path "$root\web\node_modules\linked" -Target $outside | Out-Null
        New-Item -ItemType Junction -Path "$root\link-to-outside" -Target $outside | Out-Null

        $longParent = "$root\" + (@('d' * 60) * 4 -join '\')
        New-TestFile "$longParent\node_modules\deep.js" 20

        $messages = Invoke-Scan $root -Zones @("$root\fakezone", "$root\Users\*\AppData")
        $found = @($messages | Where-Object Type -eq 'Match')
        $groups = @($messages | Where-Object Type -eq 'FileGroup')
        $sizes = @{}
        foreach ($m in ($messages | Where-Object Type -eq 'Size')) { $sizes[$m.Id] = $m }

        function Get-Found([string]$RelativePath) {
            $found | Where-Object Path -eq (Join-Path $root $RelativePath)
        }
    }

    It 'finds the expected folders' {
        @($found.Path | Sort-Object) | Should -Be @(@(
                "$longParent\node_modules",
                "$root\docs\build",
                "$root\My [Brackets] Folder\node_modules",
                "$root\py\.venv",
                "$root\py\__pycache__",
                "$root\web\dist",
                "$root\web\node_modules") | Sort-Object)
    }

    It 'marks a generic name without a project file as uncertain' {
        (Get-Found 'docs\build').Confidence | Should -Be 'Uncertain'
        (Get-Found 'web\dist').Confidence | Should -Be 'Certain'
    }

    It 'does not look inside a matched folder' {
        $found.Path | Should -Not -Contain "$root\web\node_modules\left-pad\node_modules"
    }

    It 'skips .git, reparse points and protected zones' {
        $found.Path | Should -Not -BeLike "$root\.git*"
        $found.Path | Should -Not -BeLike "$root\link-to-outside*"
        $found.Path | Should -Not -BeLike "$root\fakezone*"
        $found.Path | Should -Not -BeLike "$root\Users*"
    }

    It 'sizes a folder without following junctions' {
        $sizes[(Get-Found 'web\node_modules').Id].Bytes | Should -Be 150
        $sizes[(Get-Found 'web\node_modules').Id].Files | Should -Be 2
    }

    It 'sizes every match' {
        foreach ($m in $found) { $sizes.ContainsKey($m.Id) | Should -BeTrue }
        $sizes[(Get-Found 'web\dist').Id].Bytes | Should -Be 30
    }

    It 'handles paths longer than 260 characters' {
        "$longParent\node_modules".Length | Should -BeGreaterThan 260
        $sizes[($found | Where-Object Path -eq "$longParent\node_modules").Id].Bytes | Should -Be 20
    }

    It 'groups temp files per folder, split by confidence' {
        $web = @($groups | Where-Object Path -eq "$root\web")
        $web.Count | Should -Be 2

        $certain = $web | Where-Object Confidence -eq 'Certain'
        @($certain.Files | Sort-Object) | Should -Be @('npm-debug.log', 'Thumbs.db')
        $certain.Bytes | Should -Be 10

        $uncertain = $web | Where-Object Confidence -eq 'Uncertain'
        $uncertain.Files | Should -Be @('server.log')
        $uncertain.Bytes | Should -Be 5
    }

    It 'does not report files inside a matched folder' {
        $groups.Path | Should -Not -BeLike "$root\py\__pycache__*"
    }

    It 'gives every row a unique id' {
        $ids = @($found.Id) + @($groups.Id)
        @($ids | Select-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'ends with a Done message' {
        $messages[-1].Type | Should -Be 'Done'
        $messages[-1].Cancelled | Should -BeFalse
    }
}

Describe 'Invoke-TempScan edge cases' {
    It 'never lists the scanned folder itself' {
        New-TestFile "$TestDrive\self\node_modules\pkg\index.js"
        $messages = Invoke-Scan "$TestDrive\self\node_modules"
        @($messages | Where-Object Type -eq 'Match').Count | Should -Be 0
    }

    It 'stops when cancelled' {
        New-TestFile "$TestDrive\cancel\node_modules\x.js"
        $state = [hashtable]::Synchronized(@{ Cancel = $true })
        $messages = Invoke-Scan "$TestDrive\cancel" -State $state
        @($messages | Where-Object Type -eq 'Match').Count | Should -Be 0
        $messages[-1].Cancelled | Should -BeTrue
    }
}

Describe 'Start-TempScan' {
    It 'runs the scan in the background and reports through the queue' {
        New-TestFile "$TestDrive\bg\node_modules\x.js" 42
        $job = Start-TempScan -Root "$TestDrive\bg" -Zones @()
        try {
            $deadline = (Get-Date).AddSeconds(30)
            $messages = [System.Collections.Generic.List[object]]::new()
            do {
                $message = $null
                while ($job.Queue.TryDequeue([ref]$message)) { $messages.Add($message) }
                if ((Get-Date) -gt $deadline) { throw 'Background scan timed out' }
                Start-Sleep -Milliseconds 50
            } until ($messages.Count -and $messages[-1].Type -eq 'Done')
        } finally {
            Stop-BackgroundJob $job
        }

        ($messages | Where-Object Type -eq 'Match').Path | Should -Be "$TestDrive\bg\node_modules"
        ($messages | Where-Object Type -eq 'Size').Bytes | Should -Be 42
        $messages | Where-Object Type -eq 'Error' | Should -BeNullOrEmpty
    }
}

Describe 'Get-ProtectedZone' {
    BeforeAll {
        $zones = @('C:\Windows', 'C:\Program Files', 'C:\Users\*\AppData')
    }

    It 'flags <Path>' -ForEach @(
        @{ Path = 'C:\Windows' }, @{ Path = 'C:\Windows\System32' }, @{ Path = 'c:\program files\nodejs' },
        @{ Path = 'C:\Users\fp\AppData' }, @{ Path = 'C:\Users\fp\AppData\Local\Programs' }
    ) {
        Get-ProtectedZone -Path $Path -Zones $zones | Should -Not -BeNullOrEmpty
    }

    It 'allows <Path>' -ForEach @(
        @{ Path = 'C:\Users\fp\Projects' }, @{ Path = 'C:\Program Files Backup' }, @{ Path = 'D:\Windows Stuff' },
        @{ Path = 'C:\' }
    ) {
        Get-ProtectedZone -Path $Path -Zones $zones | Should -BeNullOrEmpty
    }

    It 'includes the system folders and every profile''s AppData by default' {
        $default = Get-ProtectedZones
        $default | Should -Contain $env:SystemRoot
        $default | Should -Contain $env:ProgramData
        $default | Should -Contain (Join-Path (Split-Path $env:USERPROFILE -Parent) '*\AppData')
    }
}

Describe 'Test-LargeScanRoot' {
    It 'flags <Path>' -ForEach @(@{ Path = 'C:\' }, @{ Path = 'E:\' }, @{ Path = $env:USERPROFILE }) {
        Test-LargeScanRoot $Path | Should -BeTrue
    }

    It 'does not flag an ordinary folder' {
        Test-LargeScanRoot 'D:\Projects' | Should -BeFalse
    }
}

Describe 'Long path helpers' {
    It 'adds and removes the \\?\ prefix' {
        ConvertTo-LongPath 'C:\a' | Should -Be '\\?\C:\a'
        ConvertTo-LongPath '\\server\share\a' | Should -Be '\\?\UNC\server\share\a'
        ConvertFrom-LongPath '\\?\C:\a' | Should -Be 'C:\a'
        ConvertFrom-LongPath '\\?\UNC\server\share\a' | Should -Be '\\server\share\a'
    }
}
