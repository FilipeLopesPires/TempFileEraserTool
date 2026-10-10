<#
.SYNOPSIS
    Walks a folder tree, reports regenerable folders and temp files, then sizes them.

.DESCRIPTION
    Dot-sourced by Clear-TempFolders.ps1. Invoke-TempScan runs in a background
    runspace (Start-TempScan) and reports through a ConcurrentQueue, so the review
    window can show matches while the scan is still going. Message shapes:
        @{ Type = 'Progress';  Text }
        @{ Type = 'Match';     Id; Path; Category; Confidence }
        @{ Type = 'FileGroup'; Id; Path; Files; Bytes; Category; Confidence }
        @{ Type = 'Size';      Id; Bytes; Files }
        @{ Type = 'Error';     Message }
        @{ Type = 'Done';      Cancelled }
#>

$TempSourceDir = $PSScriptRoot

# Never descended into, wherever they appear
$SkippedFolderNames = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('.git', '.hg', '.svn', '$Recycle.Bin', 'System Volume Information'),
    [StringComparer]::OrdinalIgnoreCase)

function ConvertTo-LongPath {
    # The \\?\ prefix lifts the 260-character limit in .NET Framework's System.IO
    param([Parameter(Mandatory)][string]$Path)

    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function ConvertFrom-LongPath {
    param([Parameter(Mandatory)][string]$Path)

    if ($Path.StartsWith('\\?\UNC\')) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

function Join-ChildPath {
    # Plain concatenation: Join-Path would treat brackets in names as wildcards
    param([string]$Parent, [string]$Name)

    if ($Parent.EndsWith('\')) { return "$Parent$Name" }
    return "$Parent\$Name"
}

function Get-ProtectedZones {
    # Installed software lives here; its node_modules, bin or Temp folders are not
    # the user's to regenerate. Wildcards cover every user profile's AppData.
    $profilesDir = Split-Path $env:USERPROFILE -Parent
    @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramData,
        (Join-Path $profilesDir '*\AppData')) |
        Where-Object { $_ } |
        ForEach-Object { $_.TrimEnd('\') } |
        Select-Object -Unique
}

function Get-ProtectedZone {
    # Returns the zone that contains Path (or is Path), else $null
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Zones = (Get-ProtectedZones)
    )

    $normalized = $Path.TrimEnd('\')
    foreach ($zone in $Zones) {
        if ($normalized -like $zone -or $normalized -like "$zone\*") { return $zone }
    }
    return $null
}

function Test-LargeScanRoot {
    # Drive roots and profile folders hold so much that a scan can take minutes
    param([Parameter(Mandatory)][string]$Path)

    $normalized = $Path.TrimEnd('\')
    if ($normalized -match '^[A-Za-z]:$') { return $true }
    $profilesDir = Split-Path $env:USERPROFILE -Parent
    return ($normalized -eq $env:USERPROFILE.TrimEnd('\')) -or ($normalized -eq $profilesDir)
}

function Get-FolderSize {
    # Returns @{ Bytes; Files }, or $null when cancelled. Reparse points are not
    # followed: pnpm's node_modules is full of junctions that would be counted twice
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$State)

    $bytes = [long]0
    $files = 0
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push((ConvertTo-LongPath $Path))
    while ($pending.Count -gt 0) {
        if ($State.Cancel) { return $null }
        try {
            $entries = [System.IO.DirectoryInfo]::new($pending.Pop()).GetFileSystemInfos()
        } catch {
            continue
        }
        foreach ($entry in $entries) {
            if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($entry -is [System.IO.DirectoryInfo]) {
                $pending.Push($entry.FullName)
            } else {
                $bytes += $entry.Length
                $files++
            }
        }
    }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files }
}

function Invoke-TempScan {
    <#
    .SYNOPSIS
        Scans everything below Root (never Root itself) and reports through Queue.
    .PARAMETER State
        Synchronized hashtable; setting Cancel to $true stops the scan.
    .PARAMETER Zones
        Protected zones to skip, see Get-ProtectedZones. Tests pass their own.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)]$Queue,
        [Parameter(Mandatory)]$State,
        [string[]]$Zones = (Get-ProtectedZones)
    )

    $cancelled = $false
    try {
        $found = [System.Collections.Generic.List[object]]::new()
        $nextId = 0
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $pending = [System.Collections.Generic.Stack[string]]::new()
        $pending.Push($Root)

        # Phase 1: find matches. Matched folders are not descended into, which also
        # keeps this phase fast because the heavy trees are skipped
        while ($pending.Count -gt 0) {
            if ($State.Cancel) { $cancelled = $true; break }
            $dir = $pending.Pop()
            if ($clock.ElapsedMilliseconds -ge 100) {
                $Queue.Enqueue(@{ Type = 'Progress'; Text = "Scanning $dir" })
                $clock.Restart()
            }

            try {
                $entries = [System.IO.DirectoryInfo]::new((ConvertTo-LongPath $dir)).GetFileSystemInfos()
            } catch {
                continue   # access denied or vanished: skip this folder, keep scanning
            }

            $siblings = New-SiblingSet ([string[]]@(foreach ($entry in $entries) { $entry.Name }))
            $subfolders = [System.Collections.Generic.List[string]]::new()
            $fileGroups = [ordered]@{ Certain = $null; Uncertain = $null }

            foreach ($entry in $entries) {
                $attributes = $entry.Attributes
                if ($attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $path = Join-ChildPath $dir $entry.Name

                if ($entry -is [System.IO.DirectoryInfo]) {
                    if ($SkippedFolderNames.Contains($entry.Name)) { continue }
                    if (($attributes -band [System.IO.FileAttributes]::Hidden) -and
                        ($attributes -band [System.IO.FileAttributes]::System)) { continue }
                    if (Get-ProtectedZone -Path $path -Zones $Zones) { continue }

                    $match = Get-TempMatch -Kind Folder -Name $entry.Name -Siblings $siblings -Path (ConvertTo-LongPath $path)
                    if (-not $match) { $subfolders.Add($path); continue }

                    $item = @{ Type = 'Match'; Id = $nextId++; Path = $path; Category = $match.Category; Confidence = $match.Confidence }
                    $found.Add($item)
                    $Queue.Enqueue($item)
                } else {
                    $match = Get-TempMatch -Kind File -Name $entry.Name -Siblings $siblings
                    if (-not $match) { continue }

                    $group = $fileGroups[$match.Confidence]
                    if (-not $group) {
                        $group = @{ Files = [System.Collections.Generic.List[string]]::new(); Bytes = [long]0; Categories = [System.Collections.Generic.List[string]]::new() }
                        $fileGroups[$match.Confidence] = $group
                    }
                    $group.Files.Add($entry.Name)
                    $group.Bytes += $entry.Length
                    if (-not $group.Categories.Contains($match.Category)) { $group.Categories.Add($match.Category) }
                }
            }

            foreach ($confidence in @($fileGroups.Keys)) {
                $group = $fileGroups[$confidence]
                if (-not $group) { continue }
                $Queue.Enqueue(@{
                        Type       = 'FileGroup'
                        Id         = $nextId++
                        Path       = $dir
                        Files      = $group.Files.ToArray()
                        Bytes      = $group.Bytes
                        Category   = $group.Categories -join ', '
                        Confidence = $confidence
                    })
            }

            # Reverse push so folders are visited in their listed order
            for ($i = $subfolders.Count - 1; $i -ge 0; $i--) { $pending.Push($subfolders[$i]) }
        }

        # Phase 2: size each matched folder
        if (-not $cancelled) {
            $count = 0
            foreach ($item in $found) {
                $count++
                $Queue.Enqueue(@{ Type = 'Progress'; Text = "Calculating sizes ($count of $($found.Count))" })
                $size = Get-FolderSize -Path $item.Path -State $State
                if (-not $size) { $cancelled = $true; break }
                $Queue.Enqueue(@{ Type = 'Size'; Id = $item.Id; Bytes = $size.Bytes; Files = $size.Files })
            }
        }
    } catch {
        $Queue.Enqueue(@{ Type = 'Error'; Message = $_.Exception.Message })
    } finally {
        $Queue.Enqueue(@{ Type = 'Done'; Cancelled = $cancelled })
    }
}

function Start-BackgroundJob {
    <#
    .SYNOPSIS
        Runs Command in its own runspace and returns @{ Queue; State; ... }.
    .DESCRIPTION
        A runspace starts empty, so SourceFiles are dot-sourced there first.
        Command receives Parameters plus -Queue and -State.
    #>
    param(
        [Parameter(Mandatory)][string[]]$SourceFiles,
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Parameters = @{}
    )

    $queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $state = [hashtable]::Synchronized(@{ Cancel = $false })

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $sessionState.ExecutionPolicy = 'Bypass'
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($sessionState)
    # The shell's Recycle Bin operation expects a single-threaded apartment
    $runspace.ApartmentState = 'STA'
    $runspace.Open()

    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    $script = {
        param($SourceFiles, $Command, $Parameters, $Queue, $State)
        try {
            foreach ($file in $SourceFiles) { . $file }
            & $Command @Parameters -Queue $Queue -State $State
        } catch {
            $Queue.Enqueue(@{ Type = 'Error'; Message = $_.Exception.Message })
            $Queue.Enqueue(@{ Type = 'Done'; Cancelled = $true })
        }
    }
    [void]$shell.AddScript($script.ToString()).
        AddArgument($SourceFiles).AddArgument($Command).AddArgument($Parameters).
        AddArgument($queue).AddArgument($state)

    [pscustomobject]@{
        PowerShell = $shell
        Handle     = $shell.BeginInvoke()
        Queue      = $queue
        State      = $state
    }
}

function Stop-BackgroundJob {
    param([Parameter(Mandatory)]$Job)

    $Job.State.Cancel = $true
    if (-not $Job.Handle.AsyncWaitHandle.WaitOne(5000)) { $Job.PowerShell.Stop() }
    $Job.PowerShell.Runspace.Dispose()
    $Job.PowerShell.Dispose()
}

function Start-TempScan {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$Zones
    )

    $parameters = @{ Root = $Root }
    if ($PSBoundParameters.ContainsKey('Zones')) { $parameters.Zones = $Zones }
    Start-BackgroundJob -Command 'Invoke-TempScan' -Parameters $parameters -SourceFiles @(
        (Join-Path $TempSourceDir 'TempFolderRules.ps1'),
        (Join-Path $TempSourceDir 'TempFolderScanner.ps1'))
}
