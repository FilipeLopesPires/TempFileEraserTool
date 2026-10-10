<#
.SYNOPSIS
    Rules that decide which folders and files are regenerable temp, cache or build output.

.DESCRIPTION
    Dot-sourced by Clear-TempFolders.ps1 and by the scanner's background runspace.
    A rule matches by name, optionally only when "marker" files sit next to the
    candidate (e.g. bin/obj only beside a *.csproj). Markers is a list of
    alternatives; an alternative that is itself a list needs all of its entries.
    Uncertain rules only apply when no Certain rule matched, and their rows start
    unchecked in the review window.

    The table itself lives in rules.json, shared with the Linux edition so one
    change updates both. Rule order matters, see Get-TempMatch.
#>

function New-TempRule {
    param(
        [Parameter(Mandatory)][ValidateSet('Folder', 'File')][string]$Kind,
        [Parameter(Mandatory)][string]$Category,
        [string[]]$Names = @(),
        [object[]]$Markers = @(),
        [string[]]$InnerMarkers = @(),
        [ValidateSet('Certain', 'Uncertain')][string]$Confidence = 'Certain'
    )

    [pscustomobject]@{
        Kind         = $Kind
        Category     = $Category
        Names        = $Names
        Markers      = $Markers
        InnerMarkers = $InnerMarkers
        Confidence   = $Confidence
    }
}

function Resolve-TempRulesPath {
    # rules.json sits next to this script once installed, and in ..\..\rules in a clone
    param([string]$ScriptRoot = $PSScriptRoot)

    foreach ($candidate in (Join-Path $ScriptRoot 'rules.json'), (Join-Path $ScriptRoot '..\..\rules\rules.json')) {
        $full = [System.IO.Path]::GetFullPath($candidate)
        if ([System.IO.File]::Exists($full)) { return $full }
    }
    throw "rules.json was not found next to TempFolderRules.ps1 or in ..\..\rules."
}

function ConvertTo-RuleNames {
    # A missing key reads as $null, and a one-entry array as a bare string
    param($Value)

    if ($null -eq $Value) { return @() }
    return [string[]]@($Value)
}

function ConvertTo-RuleMarkers {
    # Keeps the nesting New-TempRule expects: an alternative is one pattern, or a
    # list of patterns that must all be present
    param($Value)

    $markers = [System.Collections.Generic.List[object]]::new()
    foreach ($alternative in @($Value)) {
        if ($null -eq $alternative) { continue }
        if ($alternative -is [string]) { $markers.Add($alternative) }
        else { $markers.Add([string[]]@($alternative)) }
    }
    return , $markers.ToArray()
}

function Import-TempRules {
    <#
    .SYNOPSIS
        Reads the rule table from rules.json.
    .DESCRIPTION
        Omitted keys take their defaults: no names, no markers, no inner markers,
        and Certain confidence.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $document = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    $rules = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $document.rules) {
        $confidence = if ($entry.confidence) { $entry.confidence } else { 'Certain' }
        $rules.Add((New-TempRule -Kind $entry.kind -Category $entry.category `
                    -Names (ConvertTo-RuleNames $entry.names) `
                    -Markers (ConvertTo-RuleMarkers $entry.markers) `
                    -InnerMarkers (ConvertTo-RuleNames $entry.innerMarkers) `
                    -Confidence $confidence))
    }
    return , $rules.ToArray()
}

$TempRules = Import-TempRules (Resolve-TempRulesPath)

function New-TempRuleIndex {
    # Sorts each rule name into the cheapest lookup that can find it: exact names and
    # "*.ext" patterns use dictionaries, the rest are checked by literal prefix first.
    # Scans visit every file outside matched folders, so -like on each one would be slow.
    param([Parameter(Mandatory)][object[]]$Rules)

    $index = @{}
    foreach ($kind in 'Folder', 'File') {
        $index[$kind] = [pscustomobject]@{
            Exact     = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
            Extension = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
            Prefixed  = [System.Collections.Generic.List[object]]::new()
            Inner     = [System.Collections.Generic.List[object]]::new()
        }
    }

    foreach ($rule in $Rules) {
        $entry = $index[$rule.Kind]
        if ($rule.InnerMarkers.Count -gt 0) { $entry.Inner.Add($rule) }
        foreach ($name in $rule.Names) {
            if ($name -notmatch '[*?]') {
                $bucket = $entry.Exact; $key = $name
            } elseif ($name -match '^\*(\.[^*?]+)$') {
                $bucket = $entry.Extension; $key = $Matches[1]
            } else {
                $entry.Prefixed.Add([pscustomobject]@{ Prefix = ($name -split '[*?]', 2)[0]; Pattern = $name; Rule = $rule })
                continue
            }
            if (-not $bucket.ContainsKey($key)) { $bucket[$key] = [System.Collections.Generic.List[object]]::new() }
            $bucket[$key].Add($rule)
        }
    }
    return $index
}

$TempRuleIndex = New-TempRuleIndex $TempRules

function New-SiblingSet {
    # The names of everything in one folder, used to check markers for its children
    param([string[]]$Names = @())

    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Names) { [void]$set.Add($name) }
    [pscustomobject]@{ Names = $set; PatternCache = @{} }
}

function Test-SiblingPattern {
    param([Parameter(Mandatory)]$Siblings, [Parameter(Mandatory)][string]$Pattern)

    if ($Pattern -notmatch '[*?]') { return $Siblings.Names.Contains($Pattern) }
    if (-not $Siblings.PatternCache.ContainsKey($Pattern)) {
        $found = $false
        foreach ($name in $Siblings.Names) {
            if ($name -like $Pattern) { $found = $true; break }
        }
        $Siblings.PatternCache[$Pattern] = $found
    }
    return $Siblings.PatternCache[$Pattern]
}

function Test-RuleMarkers {
    param([Parameter(Mandatory)]$Rule, [Parameter(Mandatory)]$Siblings)

    if ($Rule.Markers.Count -eq 0) { return $true }
    foreach ($alternative in $Rule.Markers) {
        $all = $true
        foreach ($pattern in @($alternative)) {
            if (-not (Test-SiblingPattern $Siblings $pattern)) { $all = $false; break }
        }
        if ($all) { return $true }
    }
    return $false
}

function Get-CandidateRules {
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Name)

    $rules = [System.Collections.Generic.List[object]]::new()
    $found = $null
    if ($Entry.Exact.TryGetValue($Name, [ref]$found)) { $rules.AddRange($found) }
    $dot = $Name.LastIndexOf('.')
    if ($dot -ge 0 -and $Entry.Extension.TryGetValue($Name.Substring($dot), [ref]$found)) { $rules.AddRange($found) }
    foreach ($candidate in $Entry.Prefixed) {
        if ($Name.StartsWith($candidate.Prefix, [StringComparison]::OrdinalIgnoreCase) -and
            $Name -like $candidate.Pattern) {
            $rules.Add($candidate.Rule)
        }
    }
    return , $rules
}

function Get-TempMatch {
    <#
    .SYNOPSIS
        Returns @{ Category; Confidence } when the folder or file is regenerable, else $null.
    .PARAMETER Siblings
        New-SiblingSet of the parent folder's entries (the candidate included).
    .PARAMETER Path
        Full path of a folder candidate, needed for rules that look inside it.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Folder', 'File')][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Siblings,
        [string]$Path
    )

    $entry = $TempRuleIndex[$Kind]
    $uncertain = $null
    foreach ($rule in (Get-CandidateRules $entry $Name)) {
        if ($rule.Confidence -eq 'Uncertain') {
            if (-not $uncertain) { $uncertain = $rule }
        } elseif (Test-RuleMarkers $rule $Siblings) {
            return [pscustomobject]@{ Category = $rule.Category; Confidence = 'Certain' }
        }
    }

    if ($Path) {
        foreach ($rule in $entry.Inner) {
            $all = $true
            foreach ($marker in $rule.InnerMarkers) {
                if (-not [System.IO.File]::Exists("$Path\$marker")) { $all = $false; break }
            }
            if ($all) { return [pscustomobject]@{ Category = $rule.Category; Confidence = 'Certain' } }
        }
    }

    if ($uncertain) { return [pscustomobject]@{ Category = $uncertain.Category; Confidence = 'Uncertain' } }
    return $null
}
