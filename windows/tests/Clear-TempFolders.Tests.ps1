#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\Clear-TempFolders.ps1')

    function New-Row {
        param([string]$Kind = 'Folder', [string]$Confidence = 'Certain', $Bytes = $null, [string[]]$Files = @())
        [pscustomobject]@{
            Id = 1; Kind = $Kind; Path = 'D:\Projects\web\node_modules'; Files = $Files
            Category = 'Node.js dependencies'; Confidence = $Confidence; Bytes = $Bytes
        }
    }
}

Describe 'ConvertTo-NormalizedFolderPath' {
    It 'repairs a drive root mangled by -File argument parsing' {
        ConvertTo-NormalizedFolderPath 'E:"' | Should -Be 'E:\'
    }

    It 'leaves a normal folder path unchanged' {
        ConvertTo-NormalizedFolderPath 'C:\Some Folder\Projects' | Should -Be 'C:\Some Folder\Projects'
    }
}

Describe 'Resolve-ScanRoot' {
    It 'returns the full path without a trailing backslash' {
        Resolve-ScanRoot "$TestDrive\" | Should -Be $TestDrive.TrimEnd('\')
    }

    It 'keeps the backslash of a drive root' {
        Resolve-ScanRoot 'C:"' | Should -Be 'C:\'
    }

    It 'throws for a missing folder' {
        { Resolve-ScanRoot "$TestDrive\missing" } | Should -Throw '*not found*'
    }
}

Describe 'Format-ByteSize' {
    It 'formats <Bytes> as <Expected>' -ForEach @(
        @{ Bytes = 0; Expected = '0 bytes' },
        @{ Bytes = 512; Expected = '512 bytes' },
        @{ Bytes = 1536; Expected = ('{0:N1} KB' -f 1.5) },
        @{ Bytes = 5GB; Expected = ('{0:N1} GB' -f 5) }
    ) {
        Format-ByteSize $Bytes | Should -Be $Expected
    }
}

Describe 'Format-RowType' {
    It 'shows the category of a certain folder' {
        Format-RowType (New-Row) | Should -Be 'Node.js dependencies'
    }

    It 'explains an uncertain folder' {
        Format-RowType (New-Row -Confidence Uncertain) | Should -Be 'Node.js dependencies (no project file found)'
    }

    It 'lists the first file names of a file group' {
        $text = Format-RowType (New-Row -Kind Files -Files 'a.tmp', 'b.tmp', 'c.tmp', 'd.tmp')
        $text | Should -BeLike '4 temp files: a.tmp, b.tmp, c.tmp*'
        $text | Should -Not -BeLike '*d.tmp*'
    }

    It 'words an uncertain file group carefully' {
        Format-RowType (New-Row -Kind Files -Confidence Uncertain -Files 'server.log') |
            Should -Be '1 possible temp file: server.log'
    }
}

Describe 'Get-SelectionSummary and Format-SelectionSummary' {
    BeforeAll {
        $rows = @(
            [pscustomobject]@{ Checked = $true; Bytes = 1024 },
            [pscustomobject]@{ Checked = $true; Bytes = $null },
            [pscustomobject]@{ Checked = $false; Bytes = 4096 })
    }

    It 'counts the selected rows and their known bytes' {
        $summary = Get-SelectionSummary $rows
        $summary.Total | Should -Be 3
        $summary.Selected | Should -Be 2
        $summary.Bytes | Should -Be 1024
        $summary.Unsized | Should -Be 1
    }

    It 'says the size is a lower bound while sizes are missing' {
        Format-SelectionSummary (Get-SelectionSummary $rows) -StillScanning | Should -BeLike 'Selected 2 of 3 items*at least*still calculating*'
    }

    It 'shows the exact size once every selected row is sized' {
        $text = Format-SelectionSummary (Get-SelectionSummary @($rows[0], $rows[2]))
        $text | Should -BeLike "Selected 1 of 2 items*$(Format-ByteSize 1024)"
        $text | Should -Not -BeLike '*at least*'
    }
}

Describe 'Format-EraseSummary' {
    It 'reports space moved to the Recycle Bin' {
        $summary = Format-EraseSummary -Mode Recycle -Results @(
            @{ Path = 'a'; Success = $true; Bytes = 1024 },
            @{ Path = 'b'; Success = $true; Bytes = 1024 })
        $summary.Text | Should -BeLike "Moved 2 items to the Recycle Bin ($(Format-ByteSize 2048))*Empty the Recycle Bin*"
        $summary.Icon | Should -Be 'Information'
    }

    It 'lists failures and warns' {
        $summary = Format-EraseSummary -Mode Permanent -Results @(
            @{ Path = 'a'; Success = $true; Bytes = 10 },
            @{ Path = 'D:\x\node_modules'; Success = $false; Error = 'in use'; Bytes = 99 })
        $summary.Text | Should -BeLike "Erased 1 item, freeing $(Format-ByteSize 10)*Could not remove 1 item*D:\x\node_modules: in use*"
        $summary.Icon | Should -Be 'Warning'
    }
}

Describe 'New-ReviewForm' {
    BeforeAll {
        $ui = New-ReviewForm -Root 'D:\Projects'
    }
    AfterAll {
        $ui.Timer.Dispose()
        $ui.Form.Dispose()
    }

    It 'has a checkbox list with path, type and size columns' {
        $ui.ListView.CheckBoxes | Should -BeTrue
        @($ui.ListView.Columns | ForEach-Object Text) | Should -Be @('Folder', 'Type', 'Size')
        @($ui.ListView.Groups | ForEach-Object Header) | Should -Be @('Folders', 'Temp files')
    }

    It 'defaults to the Recycle Bin and keeps Erase disabled' {
        $ui.Recycle.Checked | Should -BeTrue
        $ui.Permanent.Checked | Should -BeFalse
        $ui.Erase.Enabled | Should -BeFalse
    }
}

Describe 'Receive-JobMessages' {
    BeforeEach {
        $ui = New-ReviewForm -Root 'D:\Projects'
        $context = @{
            Phase = 'Scanning'; Root = 'D:\Projects'; Rows = @{}; Bulk = $false
            Results = [System.Collections.Generic.List[object]]::new()
            Errors = [System.Collections.Generic.List[string]]::new()
            Job = [pscustomobject]@{ Queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new() }
        }
    }
    AfterEach {
        $ui.Timer.Dispose()
        $ui.Form.Dispose()
    }

    It 'adds rows, fills in sizes and shows scan progress' {
        $context.Job.Queue.Enqueue(@{ Type = 'Progress'; Text = 'Calculating sizes (1 of 1)' })
        $context.Job.Queue.Enqueue(@{ Type = 'Match'; Id = 0; Path = 'D:\Projects\web\node_modules'; Category = 'Node.js dependencies'; Confidence = 'Certain' })
        $context.Job.Queue.Enqueue(@{ Type = 'FileGroup'; Id = 1; Path = 'D:\Projects\web'; Files = @('Thumbs.db'); Bytes = 5; Category = 'System thumbnail cache'; Confidence = 'Certain' })
        $context.Job.Queue.Enqueue(@{ Type = 'Size'; Id = 0; Bytes = 2048; Files = 3 })

        Receive-JobMessages $ui $context

        $ui.Status.Text | Should -Be 'Calculating sizes (1 of 1)'
        $ui.ListView.Items.Count | Should -Be 2
        $context.Rows[0].SubItems[2].Text | Should -Be (Format-ByteSize 2048)
        $context.Rows[1].Group | Should -Be $ui.FileGroup
        $ui.Total.Text | Should -BeLike 'Selected 2 of 2 items*'
    }

    It 'moves the progress bar while erasing' {
        $context.Phase = 'Erasing'
        $ui.Progress.Maximum = 4
        $context.Job.Queue.Enqueue(@{ Type = 'Progress'; Text = 'Removing 3 of 4: x'; Step = 3; Steps = 4 })

        Receive-JobMessages $ui $context

        $ui.Progress.Value | Should -Be 2
    }
}

Describe 'New-ResultListItem' {
    It 'checks a certain row' {
        $item = New-ResultListItem (New-Row -Bytes 2048)
        $item.Checked | Should -BeTrue
        $item.SubItems[2].Text | Should -Be (Format-ByteSize 2048)
    }

    It 'leaves an uncertain row unchecked and greyed' {
        $item = New-ResultListItem (New-Row -Confidence Uncertain)
        $item.Checked | Should -BeFalse
        $item.ForeColor | Should -Be ([System.Drawing.SystemColors]::GrayText)
    }

    It 'lists every file of a group in its tooltip' {
        $item = New-ResultListItem (New-Row -Kind Files -Files 'a.tmp', 'b.tmp', 'c.tmp', 'd.tmp' -Bytes 4)
        $item.ToolTipText | Should -BeLike '*d.tmp*'
    }
}
