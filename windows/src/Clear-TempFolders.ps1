<#
.SYNOPSIS
    Finds regenerable temp, cache and build folders below a folder and lets the user erase them.

.DESCRIPTION
    Launched from the Explorer folder context menus (see install.ps1). Scans the
    folder recursively in the background and fills a review window as matches
    arrive: node_modules, Unity Library, Unreal Intermediate, __pycache__, stray
    temp files and so on. The user unchecks what to keep and picks Move to Recycle
    Bin or Erase permanently. No administrator rights are required.

.PARAMETER Path
    Folder to scan. Explorer passes it through %1 or %V.
#>
[CmdletBinding()]
param(
    [string]$Path
)

. (Join-Path $PSScriptRoot 'TempFolderRules.ps1')
. (Join-Path $PSScriptRoot 'TempFolderScanner.ps1')
. (Join-Path $PSScriptRoot 'TempFolderRemover.ps1')

$DialogTitle    = 'Temp File Eraser'
$MaxListedNames = 15
$MaxTypeNames   = 3
# Non-ASCII characters are built from code points: Windows PowerShell 5.1 reads
# script files without a BOM as ANSI
$Separator      = " $([char]0x00B7) "
$Ellipsis       = [string][char]0x2026

function ConvertTo-NormalizedFolderPath {
    # Explorer passes a drive root as "E:\" and PowerShell's -File parsing turns
    # the trailing \" into an escaped quote, so the script receives E:"
    param([Parameter(Mandatory)][string]$RawPath)

    $normalized = $RawPath.Trim().TrimEnd('"')
    if ($normalized -match '^[A-Za-z]:$') { $normalized += '\' }
    return $normalized
}

function Resolve-ScanRoot {
    param([Parameter(Mandatory)][string]$RawPath)

    $folder = ConvertTo-NormalizedFolderPath $RawPath
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "Folder not found: $folder" }
    $folder = [System.IO.Path]::GetFullPath($folder)
    if ($folder -notmatch '^[A-Za-z]:\\$') { $folder = $folder.TrimEnd('\') }
    return $folder
}

function Format-Count {
    param([int]$Count, [string]$Singular, [string]$Plural = "${Singular}s")

    if ($Count -eq 1) { return "1 $Singular" }
    return "$Count $Plural"
}

function Format-ByteSize {
    param([Parameter(Mandatory)][long]$Bytes)

    $units = 'bytes', 'KB', 'MB', 'GB', 'TB'
    $value = [double]$Bytes
    $unit = 0
    while ($value -ge 1024 -and $unit -lt $units.Count - 1) {
        $value /= 1024
        $unit++
    }
    if ($unit -eq 0) { return "$Bytes bytes" }
    return '{0:N1} {1}' -f $value, $units[$unit]
}

function Format-NameList {
    param([string[]]$Names)

    $shown = @($Names | Select-Object -First $MaxListedNames | ForEach-Object { "   - $_" })
    if ($Names.Count -gt $MaxListedNames) {
        $shown += "   ... and $($Names.Count - $MaxListedNames) more"
    }
    return $shown -join "`n"
}

function Format-RowType {
    param([Parameter(Mandatory)]$Row)

    if ($Row.Kind -eq 'Files') {
        $noun = if ($Row.Confidence -eq 'Certain') { 'temp file' } else { 'possible temp file' }
        $names = @($Row.Files | Select-Object -First $MaxTypeNames) -join ', '
        if ($Row.Files.Count -gt $MaxTypeNames) { $names += ", $Ellipsis" }
        return "$(Format-Count $Row.Files.Count $noun): $names"
    }
    if ($Row.Confidence -eq 'Uncertain') { return "$($Row.Category) (no project file found)" }
    return $Row.Category
}

function Get-SelectionSummary {
    # Rows: objects with Checked and Bytes ($null while the size is unknown)
    param([object[]]$Rows = @())

    $summary = [pscustomobject]@{ Total = $Rows.Count; Selected = 0; Bytes = [long]0; Unsized = 0 }
    foreach ($row in $Rows) {
        if (-not $row.Checked) { continue }
        $summary.Selected++
        if ($null -eq $row.Bytes) { $summary.Unsized++ } else { $summary.Bytes += $row.Bytes }
    }
    return $summary
}

function Format-SelectionSummary {
    param([Parameter(Mandatory)]$Summary, [switch]$StillScanning)

    $text = "Selected $($Summary.Selected) of $(Format-Count $Summary.Total 'item')"
    if ($Summary.Selected -eq 0) { return $text }

    $size = Format-ByteSize $Summary.Bytes
    if ($Summary.Unsized -eq 0) { return "$text$Separator$size" }
    $reason = if ($StillScanning) { 'still calculating' } else { 'some sizes unknown' }
    return "$text${Separator}at least $size ($reason)"
}

function Format-EraseSummary {
    # Returns @{ Text; Icon } for the dialog shown after erasing
    param(
        [object[]]$Results = @(),
        [Parameter(Mandatory)][ValidateSet('Recycle', 'Permanent')][string]$Mode,
        [string[]]$Errors = @()
    )

    $removed = @($Results | Where-Object { $_.Success })
    $failed = @($Results | Where-Object { -not $_.Success })
    $bytes = [long]0
    foreach ($result in $removed) { if ($null -ne $result.Bytes) { $bytes += $result.Bytes } }
    $size = Format-ByteSize $bytes

    $text = if ($removed.Count -eq 0) {
        'Nothing was removed.'
    } elseif ($Mode -eq 'Recycle') {
        "Moved $(Format-Count $removed.Count 'item') to the Recycle Bin ($size).`nEmpty the Recycle Bin to free the space."
    } else {
        "Erased $(Format-Count $removed.Count 'item'), freeing $size."
    }
    if ($failed.Count -gt 0) {
        $text += "`n`nCould not remove $(Format-Count $failed.Count 'item'):`n"
        $text += Format-NameList @($failed | ForEach-Object { "$($_.Path): $($_.Error)" })
    }
    foreach ($message in $Errors) { $text += "`n`nError: $message" }

    $icon = if ($failed.Count -gt 0 -or $Errors.Count -gt 0) { 'Warning' } else { 'Information' }
    return [pscustomobject]@{ Text = $text; Icon = $icon }
}

function Show-Message {
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('Information', 'Warning', 'Error')][string]$Icon = 'Information'
    )

    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($Text, $DialogTitle, 'OK', $Icon) | Out-Null
}

function Confirm-Message {
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('Question', 'Warning')][string]$Icon = 'Question'
    )

    Add-Type -AssemblyName System.Windows.Forms
    # Default to No: the question is always "go ahead with something big?"
    $answer = [System.Windows.Forms.MessageBox]::Show($Text, $DialogTitle, 'YesNo', $Icon, 'Button2')
    return $answer -eq 'Yes'
}

function Enable-DpiAwareness {
    # Without this, Windows stretches the window as a bitmap on scaled displays and
    # the text looks blurry
    if (-not ('TempFileEraser.NativeMethods' -as [type])) {
        Add-Type -Namespace TempFileEraser -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
'@
    }
    [TempFileEraser.NativeMethods]::SetProcessDPIAware() | Out-Null
}

function New-ReviewForm {
    # Builds the review window without showing it, so tests can inspect it
    param([Parameter(Mandatory)][string]$Root)

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing

    $graphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try { $scale = $graphics.DpiX / 96 } finally { $graphics.Dispose() }
    $px = { param([int]$Value) [int]($Value * $scale) }

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = $DialogTitle
    $form.StartPosition = 'CenterScreen'
    $form.Font = [System.Drawing.Font]::new('Segoe UI', 9)
    $form.ClientSize = [System.Drawing.Size]::new((& $px 960), (& $px 600))
    $form.MinimumSize = [System.Drawing.Size]::new((& $px 640), (& $px 400))
    try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\cleanmgr.exe") } catch { }

    $layout = [System.Windows.Forms.TableLayoutPanel]::new()
    $layout.Dock = 'Fill'
    $layout.ColumnCount = 1
    $layout.Padding = [System.Windows.Forms.Padding]::new((& $px 10))
    foreach ($style in 'AutoSize', 'AutoSize', 'Percent', 'AutoSize', 'AutoSize', 'AutoSize') {
        $layout.RowStyles.Add([System.Windows.Forms.RowStyle]::new($style, 100)) | Out-Null
    }

    $header = [System.Windows.Forms.Label]::new()
    $header.Text = "Scanning $Root$Ellipsis"
    $header.Dock = 'Fill'
    $header.AutoEllipsis = $true
    $header.Height = & $px 24
    $header.Font = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

    $selectAll = [System.Windows.Forms.CheckBox]::new()
    $selectAll.Text = 'Select all'
    $selectAll.AutoSize = $true
    $selectAll.AutoCheck = $false   # the click handler decides, so mixed selections work

    $listView = [System.Windows.Forms.ListView]::new()
    $listView.Dock = 'Fill'
    $listView.View = 'Details'
    $listView.CheckBoxes = $true
    $listView.FullRowSelect = $true
    $listView.ShowItemToolTips = $true
    $listView.HideSelection = $false
    $listView.ShowGroups = $true
    [void]$listView.Columns.Add('Folder', (& $px 560))
    [void]$listView.Columns.Add('Type', (& $px 250))
    [void]$listView.Columns.Add('Size', (& $px 100), 'Right')
    $folderGroup = [System.Windows.Forms.ListViewGroup]::new('folders', 'Folders')
    $fileGroup = [System.Windows.Forms.ListViewGroup]::new('files', 'Temp files')
    [void]$listView.Groups.Add($folderGroup)
    [void]$listView.Groups.Add($fileGroup)

    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    $openItem = $menu.Items.Add('Open in Explorer')
    $listView.ContextMenuStrip = $menu

    $total = [System.Windows.Forms.Label]::new()
    $total.AutoSize = $true
    $total.Font = [System.Drawing.Font]::new('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $total.Margin = [System.Windows.Forms.Padding]::new(0, (& $px 8), 0, (& $px 4))
    $total.Text = 'Selected 0 of 0 items'

    $options = [System.Windows.Forms.FlowLayoutPanel]::new()
    $options.AutoSize = $true
    $options.WrapContents = $false
    $recycle = [System.Windows.Forms.RadioButton]::new()
    $recycle.Text = 'Move to Recycle Bin'
    $recycle.AutoSize = $true
    $recycle.Checked = $true
    $permanent = [System.Windows.Forms.RadioButton]::new()
    $permanent.Text = 'Erase permanently'
    $permanent.AutoSize = $true
    $modeNote = [System.Windows.Forms.Label]::new()
    $modeNote.AutoSize = $true
    $modeNote.ForeColor = [System.Drawing.SystemColors]::GrayText
    $modeNote.Margin = [System.Windows.Forms.Padding]::new((& $px 12), (& $px 6), 0, 0)
    $modeNote.Text = 'Space is freed when the Recycle Bin is emptied.'
    $options.Controls.AddRange(@($recycle, $permanent, $modeNote))

    $buttons = [System.Windows.Forms.FlowLayoutPanel]::new()
    $buttons.Dock = 'Fill'
    $buttons.AutoSize = $true
    $buttons.FlowDirection = 'RightToLeft'
    $buttonSize = [System.Drawing.Size]::new((& $px 96), (& $px 30))
    $erase = [System.Windows.Forms.Button]::new()
    $erase.Text = 'Erase'
    $erase.Enabled = $false
    $cancel = [System.Windows.Forms.Button]::new()
    $cancel.Text = 'Cancel'
    $stop = [System.Windows.Forms.Button]::new()
    $stop.Text = 'Stop scan'
    foreach ($button in $erase, $cancel, $stop) {
        $button.MinimumSize = $buttonSize
        $button.AutoSize = $true
    }
    $buttons.Controls.AddRange(@($erase, $cancel, $stop))
    $form.CancelButton = $cancel

    $layout.Controls.Add($header, 0, 0)
    $layout.Controls.Add($selectAll, 0, 1)
    $layout.Controls.Add($listView, 0, 2)
    $layout.Controls.Add($total, 0, 3)
    $layout.Controls.Add($options, 0, 4)
    $layout.Controls.Add($buttons, 0, 5)

    $statusStrip = [System.Windows.Forms.StatusStrip]::new()
    $statusStrip.SizingGrip = $false
    $status = [System.Windows.Forms.ToolStripStatusLabel]::new()
    $status.Spring = $true
    $status.TextAlign = 'MiddleLeft'
    $status.Text = 'Starting scan'
    $progress = [System.Windows.Forms.ToolStripProgressBar]::new()
    $progress.Visible = $false
    [void]$statusStrip.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@($status, $progress))

    # The status strip is added last so the docked layout fills the space above it
    $form.Controls.Add($layout)
    $form.Controls.Add($statusStrip)

    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 100

    [pscustomobject]@{
        Form        = $form
        Header      = $header
        SelectAll   = $selectAll
        ListView    = $listView
        FolderGroup = $folderGroup
        FileGroup   = $fileGroup
        OpenItem    = $openItem
        Total       = $total
        Recycle     = $recycle
        Permanent   = $permanent
        ModeNote    = $modeNote
        Erase       = $erase
        Cancel      = $cancel
        Stop        = $stop
        Status      = $status
        Progress    = $progress
        Timer       = $timer
    }
}

function ConvertTo-ReviewRow {
    param([Parameter(Mandatory)]$Message)

    $kind = if ($Message.Type -eq 'FileGroup') { 'Files' } else { 'Folder' }
    $bytes = if ($kind -eq 'Files') { [long]$Message.Bytes } else { $null }
    [pscustomobject]@{
        Id         = $Message.Id
        Kind       = $kind
        Path       = $Message.Path
        Files      = @($Message.Files)
        Category   = $Message.Category
        Confidence = $Message.Confidence
        Bytes      = $bytes
    }
}

function New-ResultListItem {
    param([Parameter(Mandatory)]$Row)

    $item = [System.Windows.Forms.ListViewItem]::new($Row.Path)
    [void]$item.SubItems.Add((Format-RowType $Row))
    $sizeText = if ($null -ne $Row.Bytes) { Format-ByteSize $Row.Bytes } else { "Calculating$Ellipsis" }
    [void]$item.SubItems.Add($sizeText)
    $item.Checked = $Row.Confidence -eq 'Certain'
    if ($Row.Confidence -ne 'Certain') { $item.ForeColor = [System.Drawing.SystemColors]::GrayText }
    $item.ToolTipText = if ($Row.Kind -eq 'Files') { "Files in this folder:`n" + ($Row.Files -join "`n") } else { $Row.Path }
    $item.Tag = $Row
    return $item
}

function Add-ReviewRow {
    param([Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Row)

    $item = New-ResultListItem $Row
    [void]$Ui.ListView.Items.Add($item)
    $item.Group = if ($Row.Kind -eq 'Files') { $Ui.FileGroup } else { $Ui.FolderGroup }
    $Context.Rows[$Row.Id] = $item
}

function Update-ReviewTotals {
    param([Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Context)

    $rows = foreach ($item in $Ui.ListView.Items) {
        [pscustomobject]@{ Checked = $item.Checked; Bytes = $item.Tag.Bytes }
    }
    $summary = Get-SelectionSummary @($rows)
    $Ui.Total.Text = Format-SelectionSummary $summary -StillScanning:($Context.Phase -eq 'Scanning')

    $Ui.SelectAll.CheckState = if ($summary.Selected -eq 0) { 'Unchecked' }
    elseif ($summary.Selected -eq $summary.Total) { 'Checked' }
    else { 'Indeterminate' }
    $Ui.Erase.Enabled = $Context.Phase -eq 'Ready' -and $summary.Selected -gt 0
}

function Set-AllRowsChecked {
    param([Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Context)

    $check = $Ui.ListView.CheckedItems.Count -lt $Ui.ListView.Items.Count
    $Context.Bulk = $true
    $Ui.ListView.BeginUpdate()
    try {
        foreach ($item in $Ui.ListView.Items) { $item.Checked = $check }
    } finally {
        $Ui.ListView.EndUpdate()
        $Context.Bulk = $false
    }
    Update-ReviewTotals $Ui $Context
}

function Set-ReviewSortOrder {
    param([Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][int]$Column)

    if ($Context.SortColumn -eq $Column) {
        $Context.SortDescending = -not $Context.SortDescending
    } else {
        $Context.SortColumn = $Column
        $Context.SortDescending = $Column -eq 2   # biggest first is the useful order for sizes
    }
    $key = switch ($Column) {
        0 { { $_.Text } }
        1 { { $_.SubItems[1].Text } }
        default { { [long]$_.Tag.Bytes } }
    }

    $items = @(foreach ($item in $Ui.ListView.Items) { $item })
    $sorted = @($items | Sort-Object -Property $key -Descending:$Context.SortDescending)
    $Context.Bulk = $true
    $Ui.ListView.BeginUpdate()
    try {
        $Ui.ListView.Items.Clear()
        foreach ($item in $sorted) {
            [void]$Ui.ListView.Items.Add($item)
            $item.Group = if ($item.Tag.Kind -eq 'Files') { $Ui.FileGroup } else { $Ui.FolderGroup }
        }
    } finally {
        $Ui.ListView.EndUpdate()
        $Context.Bulk = $false
    }
}

function Complete-Scan {
    param([Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Context, [bool]$Cancelled)

    foreach ($item in $Ui.ListView.Items) {
        if ($null -eq $item.Tag.Bytes) { $item.SubItems[2].Text = 'Unknown' }
    }

    if ($Ui.ListView.Items.Count -eq 0) {
        $Context.Phase = 'Finished'
        $Ui.Timer.Stop()
        $text = if ($Cancelled) { "Scan stopped before anything was found in:`n$($Context.Root)" }
        else { "No temp, cache or build folders or files were found in:`n$($Context.Root)" }
        foreach ($message in $Context.Errors) { $text += "`n`nError: $message" }
        Show-Message $text
        $Ui.Form.Close()
        return
    }

    $Context.Phase = 'Ready'
    $Ui.Stop.Visible = $false
    $Ui.Header.Text = "Found $(Format-Count $Ui.ListView.Items.Count 'item') in $($Context.Root)"
    $Ui.Status.Text = if ($Context.Errors.Count -gt 0) { "Scan ended with an error: $($Context.Errors[0])" }
    elseif ($Cancelled) { 'Scan stopped. Items found so far are listed; some sizes are unknown.' }
    else { 'Scan complete. Uncheck anything you want to keep, then choose Erase.' }
    Update-ReviewTotals $Ui $Context
}

function Start-Erase {
    param([Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Context)

    $items = @(foreach ($listItem in $Ui.ListView.CheckedItems) {
            $row = $listItem.Tag
            @{ Id = $row.Id; Kind = $row.Kind; Path = $row.Path; Files = $row.Files; Bytes = $row.Bytes }
        })
    if ($items.Count -eq 0) { return }

    $mode = if ($Ui.Permanent.Checked) { 'Permanent' } else { 'Recycle' }
    if ($mode -eq 'Permanent') {
        $summary = Get-SelectionSummary @(foreach ($item in $items) { [pscustomobject]@{ Checked = $true; Bytes = $item.Bytes } })
        $question = "Permanently erase $(Format-Count $items.Count 'item') ($(Format-ByteSize $summary.Bytes))?`n`nThey will not go to the Recycle Bin. This cannot be undone."
        if (-not (Confirm-Message $question 'Warning')) { return }
    }

    $Context.Mode = $mode
    $Context.Phase = 'Erasing'
    foreach ($control in $Ui.ListView, $Ui.SelectAll, $Ui.Recycle, $Ui.Permanent, $Ui.Erase, $Ui.Cancel) {
        $control.Enabled = $false
    }
    $Ui.Header.Text = "Removing $(Format-Count $items.Count 'item')$Ellipsis"
    $Ui.Progress.Maximum = $items.Count
    $Ui.Progress.Value = 0
    $Ui.Progress.Visible = $true
    $Context.Job = Start-TempRemoval -Items $items -Mode $mode
}

function Complete-Erase {
    param([Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Context)

    $Context.Phase = 'Finished'
    $Ui.Timer.Stop()
    $Ui.Progress.Value = $Ui.Progress.Maximum
    $summary = Format-EraseSummary -Results $Context.Results.ToArray() -Mode $Context.Mode -Errors $Context.Errors.ToArray()
    Show-Message $summary.Text $summary.Icon
    $Ui.Form.Close()
}

function Receive-JobMessages {
    # Timer tick: moves queued background messages into the window. Capped per tick
    # so a burst of matches never freezes the UI
    param([Parameter(Mandatory)]$Ui, [Parameter(Mandatory)]$Context)

    $job = $Context.Job
    if (-not $job) { return }

    $message = $null
    $done = $null
    $count = 0
    $Context.Bulk = $true
    $Ui.ListView.BeginUpdate()
    try {
        while ($count -lt 500 -and $job.Queue.TryDequeue([ref]$message)) {
            $count++
            switch ($message.Type) {
                'Progress' {
                    $Ui.Status.Text = $message.Text
                    # Indexed on purpose: $message.Count would be the hashtable's own key count
                    if ($null -ne $message['Step']) { $Ui.Progress.Value = [Math]::Min($message['Step'] - 1, $Ui.Progress.Maximum) }
                }
                'Match' { Add-ReviewRow $Ui $Context (ConvertTo-ReviewRow $message) }
                'FileGroup' { Add-ReviewRow $Ui $Context (ConvertTo-ReviewRow $message) }
                'Size' {
                    $item = $Context.Rows[$message.Id]
                    if ($item) {
                        $item.Tag.Bytes = [long]$message.Bytes
                        $item.SubItems[2].Text = Format-ByteSize $message.Bytes
                    }
                }
                'Result' { $Context.Results.Add($message) }
                'Error' { $Context.Errors.Add($message.Message) }
                'Done' { $done = $message }
            }
            if ($done) { break }
        }
    } finally {
        $Ui.ListView.EndUpdate()
        $Context.Bulk = $false
    }

    if ($count -gt 0 -and $Context.Phase -ne 'Erasing') { Update-ReviewTotals $Ui $Context }
    if ($done) {
        Stop-BackgroundJob $job
        $Context.Job = $null
        if ($Context.Phase -eq 'Scanning') { Complete-Scan $Ui $Context ([bool]$done.Cancelled) }
        else { Complete-Erase $Ui $Context }
    }
}

function Show-ReviewWindow {
    param([Parameter(Mandatory)][string]$Root)

    $ui = New-ReviewForm -Root $Root
    # Event handlers run in child scopes, so all shared state lives in this hashtable
    $context = @{
        Phase          = 'Scanning'
        Root           = $Root
        Job            = $null
        Rows           = @{}
        Bulk           = $false
        Results        = [System.Collections.Generic.List[object]]::new()
        Errors         = [System.Collections.Generic.List[string]]::new()
        Mode           = 'Recycle'
        SortColumn     = -1
        SortDescending = $false
    }

    $ui.Form.Add_Shown({
            $ui.Form.Activate()
            $context.Job = Start-TempScan -Root $Root
            $ui.Timer.Start()
        })
    $ui.Form.Add_FormClosing({
            param($source, $e)
            if ($context.Phase -eq 'Erasing') { $e.Cancel = $true; return }
            $ui.Timer.Stop()
            if ($context.Job) {
                Stop-BackgroundJob $context.Job
                $context.Job = $null
            }
        })
    $ui.Timer.Add_Tick({ Receive-JobMessages $ui $context })
    $ui.ListView.Add_ItemChecked({ if (-not $context.Bulk) { Update-ReviewTotals $ui $context } })
    $ui.ListView.Add_ColumnClick({ param($source, $e) Set-ReviewSortOrder $ui $context $e.Column })
    $ui.SelectAll.Add_Click({ if ($context.Phase -ne 'Erasing') { Set-AllRowsChecked $ui $context } })
    $ui.Permanent.Add_CheckedChanged({
            $ui.ModeNote.Text = if ($ui.Permanent.Checked) { 'Erased items cannot be recovered.' }
            else { 'Space is freed when the Recycle Bin is emptied.' }
        })
    $ui.ListView.ContextMenuStrip.Add_Opening({
            param($source, $e)
            if ($ui.ListView.SelectedItems.Count -eq 0) { $e.Cancel = $true }
        })
    $ui.OpenItem.Add_Click({
            $path = $ui.ListView.SelectedItems[0].Tag.Path
            Start-Process explorer.exe -ArgumentList "`"$path`""
        })
    $ui.Stop.Add_Click({
            if ($context.Job) { $context.Job.State.Cancel = $true }
            $ui.Stop.Enabled = $false
            $ui.Status.Text = "Stopping$Ellipsis"
        })
    $ui.Erase.Add_Click({ Start-Erase $ui $context })
    $ui.Cancel.Add_Click({ $ui.Form.Close() })

    try {
        [void]$ui.Form.ShowDialog()
    } finally {
        $ui.Timer.Dispose()
        $ui.Form.Dispose()
    }
}

# Main. Skipped when the file is dot-sourced (e.g. by the Pester tests).
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Enable-DpiAwareness
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()

        if (-not $Path) { throw 'No folder path was given.' }
        $folder = Resolve-ScanRoot $Path

        $zone = Get-ProtectedZone -Path $folder
        if ($zone) {
            Show-Message ("$folder is inside a protected location ($zone).`n`n" +
                'Folders there belong to Windows or to installed apps, and removing them could break things. ' +
                'Choose a folder that holds your own projects instead.') 'Error'
            return
        }
        if ((Test-LargeScanRoot $folder) -and -not (Confirm-Message (
                    "Scanning $folder may take a long time.`n`n" +
                    'Windows, Program Files, ProgramData and AppData folders are skipped. Continue?'))) {
            return
        }

        Show-ReviewWindow -Root $folder
    } catch {
        Show-Message "Temp File Eraser stopped because of an error:`n$($_.Exception.Message)" 'Error'
    }
}
