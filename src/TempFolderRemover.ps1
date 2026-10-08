<#
.SYNOPSIS
    Moves folders and files to the Recycle Bin, or erases them permanently.

.DESCRIPTION
    Dot-sourced by Clear-TempFolders.ps1; needs TempFolderScanner.ps1 for the long
    path and background job helpers. Invoke-TempRemoval runs in a background
    runspace (Start-TempRemoval) and reports through a ConcurrentQueue:
        @{ Type = 'Progress'; Text; Step; Steps }
        @{ Type = 'Result';   Id; Path; Success; Error; Bytes }
        @{ Type = 'Error';    Message }
        @{ Type = 'Done';     Cancelled }
#>

function Remove-LongPathPrefix {
    # .NET error messages repeat the \\?\ form of the path, which reads as noise
    param([string]$Text)

    return $Text.Replace('\\?\UNC\', '\\').Replace('\\?\', '')
}

function Format-RemovalErrors {
    param([Parameter(Mandatory)][System.Collections.Generic.List[string]]$Errors)

    $text = $Errors[0]
    if ($Errors.Count -gt 1) { $text += " (and $($Errors.Count - 1) more)" }
    return $text
}

function Remove-DirectoryTree {
    # Deletes Path and everything below it. Remove-Item -Recurse is avoided: in
    # PowerShell 5.1 it struggles with long paths and can descend into junctions.
    # Here junctions and symlinks are deleted as links, so their targets survive.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors
    )

    $readOnly = [System.IO.FileAttributes]::ReadOnly
    $root = [System.IO.DirectoryInfo]::new((ConvertTo-LongPath $Path))
    $folders = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    $folders.Add($root)
    $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $pending.Push($root)

    while ($pending.Count -gt 0) {
        $dir = $pending.Pop()
        try {
            $entries = $dir.GetFileSystemInfos()
        } catch {
            $Errors.Add((Remove-LongPathPrefix $_.Exception.Message))
            continue
        }
        foreach ($entry in $entries) {
            try {
                if ($entry.Attributes -band $readOnly) { $entry.Attributes = $entry.Attributes -bxor $readOnly }
                if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    if ($entry -is [System.IO.DirectoryInfo]) {
                        [System.IO.Directory]::Delete($entry.FullName, $false)
                    } else {
                        [System.IO.File]::Delete($entry.FullName)
                    }
                } elseif ($entry -is [System.IO.DirectoryInfo]) {
                    $folders.Add($entry)
                    $pending.Push($entry)
                } else {
                    $entry.Delete()
                }
            } catch {
                $Errors.Add("$(Remove-LongPathPrefix $entry.FullName): $(Remove-LongPathPrefix $_.Exception.Message)")
            }
        }
    }

    # Deepest folders first, once their contents are gone
    for ($i = $folders.Count - 1; $i -ge 0; $i--) {
        $folder = $folders[$i]
        try {
            if ($folder.Attributes -band $readOnly) { $folder.Attributes = $folder.Attributes -bxor $readOnly }
            $folder.Delete()
        } catch {
            # A folder left non-empty by an earlier failure is already explained
            if ($Errors.Count -eq 0) { $Errors.Add((Remove-LongPathPrefix $_.Exception.Message)) }
        }
    }
}

function New-RemovalResult {
    param([string]$Path, [bool]$Success, [string]$ErrorText)
    [pscustomobject]@{ Path = $Path; Success = $Success; Error = $ErrorText }
}

function Remove-TempFolder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Recycle', 'Permanent')][string]$Mode
    )

    try {
        if (-not [System.IO.Directory]::Exists((ConvertTo-LongPath $Path))) {
            return New-RemovalResult $Path $true
        }
        if ($Mode -eq 'Recycle') {
            Add-Type -AssemblyName Microsoft.VisualBasic
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        } else {
            $errors = [System.Collections.Generic.List[string]]::new()
            Remove-DirectoryTree -Path $Path -Errors $errors
            if ($errors.Count -gt 0) { return New-RemovalResult $Path $false (Format-RemovalErrors $errors) }
        }
        return New-RemovalResult $Path $true
    } catch [System.IO.PathTooLongException] {
        return New-RemovalResult $Path $false 'The path is too long for the Recycle Bin. Try Erase permanently instead.'
    } catch {
        return New-RemovalResult $Path $false (Remove-LongPathPrefix $_.Exception.Message)
    }
}

function Remove-TempFiles {
    # Deletes the named files in Folder, never the folder itself
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][ValidateSet('Recycle', 'Permanent')][string]$Mode
    )

    if ($Mode -eq 'Recycle') { Add-Type -AssemblyName Microsoft.VisualBasic }
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Files) {
        $path = Join-ChildPath $Folder $name
        $longPath = ConvertTo-LongPath $path
        try {
            if (-not [System.IO.File]::Exists($longPath)) { continue }
            if ($Mode -eq 'Recycle') {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
            } else {
                [System.IO.File]::SetAttributes($longPath, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Delete($longPath)
            }
        } catch {
            $errors.Add("${name}: $(Remove-LongPathPrefix $_.Exception.Message)")
        }
    }

    if ($errors.Count -gt 0) { return New-RemovalResult $Folder $false (Format-RemovalErrors $errors) }
    return New-RemovalResult $Folder $true
}

function Invoke-TempRemoval {
    <#
    .SYNOPSIS
        Removes each item and reports a Result message per item through Queue.
    .PARAMETER Items
        Hashtables @{ Id; Kind = 'Folder' | 'Files'; Path; Files; Bytes }.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][ValidateSet('Recycle', 'Permanent')][string]$Mode,
        [Parameter(Mandatory)]$Queue,
        [Parameter(Mandatory)]$State
    )

    $cancelled = $false
    try {
        $index = 0
        foreach ($item in $Items) {
            if ($State.Cancel) { $cancelled = $true; break }
            $index++
            $Queue.Enqueue(@{ Type = 'Progress'; Text = "Removing $index of $($Items.Count): $($item.Path)"; Step = $index; Steps = $Items.Count })

            $result = if ($item.Kind -eq 'Files') {
                Remove-TempFiles -Folder $item.Path -Files $item.Files -Mode $Mode
            } else {
                Remove-TempFolder -Path $item.Path -Mode $Mode
            }
            $Queue.Enqueue(@{ Type = 'Result'; Id = $item.Id; Path = $item.Path; Success = $result.Success; Error = $result.Error; Bytes = $item.Bytes })
        }
    } catch {
        $Queue.Enqueue(@{ Type = 'Error'; Message = $_.Exception.Message })
    } finally {
        $Queue.Enqueue(@{ Type = 'Done'; Cancelled = $cancelled })
    }
}

function Start-TempRemoval {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][ValidateSet('Recycle', 'Permanent')][string]$Mode
    )

    Start-BackgroundJob -Command 'Invoke-TempRemoval' -Parameters @{ Items = $Items; Mode = $Mode } -SourceFiles @(
        (Join-Path $TempSourceDir 'TempFolderScanner.ps1'),
        (Join-Path $TempSourceDir 'TempFolderRemover.ps1'))
}
