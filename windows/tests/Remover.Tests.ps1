#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\TempFolderScanner.ps1')
    . (Join-Path $PSScriptRoot '..\src\TempFolderRemover.ps1')

    function New-TestFile {
        # \\?\ paths so fixtures can be longer than 260 characters
        param([string]$Path, [int]$Bytes = 10)
        $long = "\\?\$Path"
        [System.IO.Directory]::CreateDirectory($long.Substring(0, $long.LastIndexOf('\'))) | Out-Null
        [System.IO.File]::WriteAllBytes($long, [byte[]]::new($Bytes))
    }
}

Describe 'Remove-TempFolder -Mode Permanent' {
    It 'removes the whole tree, including read-only and hidden files' {
        $target = "$TestDrive\perm\node_modules"
        New-TestFile "$target\a\b\c.js"
        New-TestFile "$target\readonly.txt"
        New-TestFile "$target\hidden.txt"
        Set-ItemProperty -LiteralPath "$target\readonly.txt" -Name IsReadOnly -Value $true
        (Get-Item -LiteralPath "$target\hidden.txt").Attributes = 'Hidden'

        $result = Remove-TempFolder -Path $target -Mode Permanent

        $result.Success | Should -BeTrue
        $target | Should -Not -Exist
        "$TestDrive\perm" | Should -Exist
    }

    It 'removes a junction inside the tree without touching its target' {
        $outside = "$TestDrive\keep-me"
        New-TestFile "$outside\precious.txt"
        $target = "$TestDrive\junction\node_modules"
        New-TestFile "$target\pkg\index.js"
        New-Item -ItemType Junction -Path "$target\pkg\linked" -Target $outside | Out-Null

        $result = Remove-TempFolder -Path $target -Mode Permanent

        $result.Success | Should -BeTrue
        $target | Should -Not -Exist
        "$outside\precious.txt" | Should -Exist
    }

    It 'removes trees deeper than 260 characters' {
        $target = "$TestDrive\long\node_modules"
        $deep = "$target\" + (@('x' * 80) * 4 -join '\')
        New-TestFile "$deep\file.js"

        (Remove-TempFolder -Path $target -Mode Permanent).Success | Should -BeTrue
        [System.IO.Directory]::Exists("\\?\$target") | Should -BeFalse
    }

    It 'reports a locked file as a failure and removes everything else' {
        $target = "$TestDrive\locked\node_modules"
        New-TestFile "$target\locked.bin"
        New-TestFile "$target\other\free.js"
        $lock = [System.IO.File]::Open("$target\locked.bin", 'Open', 'Read', 'None')
        try {
            $result = Remove-TempFolder -Path $target -Mode Permanent
        } finally {
            $lock.Dispose()
        }

        $result.Success | Should -BeFalse
        $result.Error | Should -BeLike '*locked.bin*'
        $result.Error | Should -Not -BeLike '*\\?\*'
        "$target\other" | Should -Not -Exist
    }

    It 'treats a folder that is already gone as removed' {
        (Remove-TempFolder -Path "$TestDrive\does-not-exist" -Mode Permanent).Success | Should -BeTrue
    }
}

Describe 'Remove-TempFolder -Mode Recycle' {
    It 'moves the folder out of place' {
        $target = "$TestDrive\recycle\TempFileEraserTool-test-node_modules"
        New-TestFile "$target\index.js"

        $result = Remove-TempFolder -Path $target -Mode Recycle

        $result.Success | Should -BeTrue
        $target | Should -Not -Exist
    }
}

Describe 'Remove-TempFiles' {
    BeforeEach {
        $folder = "$TestDrive\files-$([guid]::NewGuid().ToString('N'))"
        New-TestFile "$folder\Thumbs.db"
        New-TestFile "$folder\npm-debug.log"
        New-TestFile "$folder\keep.txt"
    }

    It 'deletes only the listed files (<Mode>)' -ForEach @(@{ Mode = 'Permanent' }, @{ Mode = 'Recycle' }) {
        $result = Remove-TempFiles -Folder $folder -Files 'Thumbs.db', 'npm-debug.log' -Mode $Mode

        $result.Success | Should -BeTrue
        "$folder\Thumbs.db" | Should -Not -Exist
        "$folder\npm-debug.log" | Should -Not -Exist
        "$folder\keep.txt" | Should -Exist
    }

    It 'deletes read-only files permanently' {
        Set-ItemProperty -LiteralPath "$folder\Thumbs.db" -Name IsReadOnly -Value $true
        (Remove-TempFiles -Folder $folder -Files 'Thumbs.db' -Mode Permanent).Success | Should -BeTrue
        "$folder\Thumbs.db" | Should -Not -Exist
    }

    It 'reports a locked file and still deletes the others' {
        $lock = [System.IO.File]::Open("$folder\Thumbs.db", 'Open', 'Read', 'None')
        try {
            $result = Remove-TempFiles -Folder $folder -Files 'Thumbs.db', 'npm-debug.log' -Mode Permanent
        } finally {
            $lock.Dispose()
        }

        $result.Success | Should -BeFalse
        $result.Error | Should -BeLike '*Thumbs.db*'
        "$folder\npm-debug.log" | Should -Not -Exist
    }
}

Describe 'Start-TempRemoval' {
    It 'removes items in the background and reports a result for each' {
        New-TestFile "$TestDrive\bg\node_modules\x.js"
        New-TestFile "$TestDrive\bg\Thumbs.db"
        $items = @(
            @{ Id = 1; Kind = 'Folder'; Path = "$TestDrive\bg\node_modules"; Bytes = 10 },
            @{ Id = 2; Kind = 'Files'; Path = "$TestDrive\bg"; Files = @('Thumbs.db'); Bytes = 10 })

        $job = Start-TempRemoval -Items $items -Mode Permanent
        try {
            $deadline = (Get-Date).AddSeconds(30)
            $messages = [System.Collections.Generic.List[object]]::new()
            do {
                $message = $null
                while ($job.Queue.TryDequeue([ref]$message)) { $messages.Add($message) }
                if ((Get-Date) -gt $deadline) { throw 'Background removal timed out' }
                Start-Sleep -Milliseconds 50
            } until ($messages.Count -and $messages[-1].Type -eq 'Done')
        } finally {
            Stop-BackgroundJob $job
        }

        $results = @($messages | Where-Object Type -eq 'Result')
        $results.Count | Should -Be 2
        $results.Success | Should -Not -Contain $false
        "$TestDrive\bg\node_modules" | Should -Not -Exist
        "$TestDrive\bg\Thumbs.db" | Should -Not -Exist
    }
}
