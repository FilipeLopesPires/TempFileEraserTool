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

$UnityMarker   = , @('Assets', 'ProjectSettings')
$DotNetMarkers = @('*.csproj', '*.fsproj', '*.vbproj', '*.sln')
$GradleMarkers = @('build.gradle', 'build.gradle.kts', 'settings.gradle', 'settings.gradle.kts')

$TempRules = @(
    # Folders that are generated wherever they appear
    New-TempRule Folder 'Node.js dependencies' 'node_modules'
    New-TempRule Folder 'Web framework cache' '.next', '.nuxt', '.svelte-kit', '.parcel-cache', '.turbo', '.angular', '.docusaurus', '.expo', '.nx', '.wrangler', '.sass-cache'
    New-TempRule Folder 'Test coverage output' '.nyc_output'
    New-TempRule Folder 'Deployment build output' '.serverless', '.aws-sam', 'storybook-static'
    New-TempRule Folder 'Python cache' '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', '.hypothesis', '.ipynb_checkpoints'
    New-TempRule Folder 'Python test environments' '.tox', '.nox'
    New-TempRule Folder 'Python package metadata' '*.egg-info'
    New-TempRule Folder 'Gradle cache' '.gradle'
    New-TempRule Folder 'CMake cache' 'CMakeFiles'
    New-TempRule Folder 'Dart tool cache' '.dart_tool'
    New-TempRule Folder 'Haskell build output' '.stack-work', 'dist-newstyle'
    New-TempRule Folder 'Zig cache' '.zig-cache', 'zig-cache'
    New-TempRule Folder 'Terraform providers' '.terraform'
    New-TempRule Folder 'Jekyll cache' '.jekyll-cache'
    New-TempRule Folder 'Swift package cache' '.swiftpm'
    New-TempRule Folder 'IDE settings and cache' '.vs', '.idea'
    New-TempRule Folder 'Python virtual environment' -InnerMarkers 'pyvenv.cfg'

    # Folders that only count as generated inside a recognised project
    New-TempRule Folder 'Node.js build output' 'dist', 'build', 'out', '.cache', '.output' -Markers 'package.json'
    New-TempRule Folder 'Test coverage output' 'coverage' -Markers 'package.json'
    New-TempRule Folder 'Python build output' 'build', 'dist' -Markers 'setup.py', 'setup.cfg', 'pyproject.toml'
    New-TempRule Folder 'Unity generated files' 'Library', 'Temp', 'Obj', 'Logs' -Markers $UnityMarker
    New-TempRule Folder 'Unity player build' 'Build', 'Builds' -Markers $UnityMarker
    New-TempRule Folder 'Unreal generated files' 'Binaries', 'Intermediate', 'Saved', 'DerivedDataCache' -Markers '*.uproject', '*.uplugin'
    New-TempRule Folder 'Godot import cache' '.godot', '.import' -Markers 'project.godot'
    New-TempRule Folder '.NET build output' 'bin', 'obj' -Markers $DotNetMarkers
    New-TempRule Folder 'Gradle build output' 'build', '.cxx', '.externalNativeBuild' -Markers $GradleMarkers
    New-TempRule Folder 'Maven build output' 'target' -Markers 'pom.xml'
    New-TempRule Folder 'Rust build output' 'target' -Markers 'Cargo.toml'
    New-TempRule Folder 'CMake build output' 'cmake-build-*', 'build', 'out' -Markers 'CMakeLists.txt'
    New-TempRule Folder 'Flutter build output' 'build' -Markers 'pubspec.yaml'
    New-TempRule Folder 'Elixir build output' '_build', 'deps' -Markers 'mix.exs'
    New-TempRule Folder 'PHP Composer dependencies' 'vendor' -Markers 'composer.json'
    New-TempRule Folder 'Zig build output' 'zig-out' -Markers 'build.zig'
    New-TempRule Folder 'Swift build output' '.build' -Markers 'Package.swift'
    New-TempRule Folder 'CocoaPods dependencies' 'Pods' -Markers 'Podfile'
    New-TempRule Folder 'Jekyll site output' '_site' -Markers '_config.yml'

    # Generic names listed unchecked when no project file explains them
    New-TempRule Folder 'Possible build output' 'bin', 'obj', 'build', 'dist', 'out', 'target', 'Intermediate' -Confidence Uncertain
    New-TempRule Folder 'Possible temp folder' 'Temp' -Confidence Uncertain
    New-TempRule Folder 'Possible cache' 'DerivedDataCache' -Confidence Uncertain

    # Files. desktop.ini and backups (*.bak, *.orig, *.rej, *~) are left alone on purpose
    New-TempRule File 'System thumbnail cache' 'Thumbs.db', 'ehthumbs.db', '.DS_Store', '._*'
    New-TempRule File 'Editor lock or swap file' '~$*.doc*', '~$*.xls*', '~$*.ppt*', '*.swp', '*.swo', '.~lock.*#'
    New-TempRule File 'Temporary file' '*.tmp'
    New-TempRule File 'Tool cache file' '*.pyc', '*.pyo', '.eslintcache', '.stylelintcache', '*.tsbuildinfo', '.coverage', '.phpunit.result.cache'
    New-TempRule File 'Debug log or crash dump' 'npm-debug.log*', 'yarn-error.log', 'pnpm-debug.log*', 'hs_err_pid*.log', '*.dmp', '*.stackdump'
    New-TempRule File 'Unity generated project file' '*.sln', '*.csproj' -Markers $UnityMarker
    New-TempRule File 'Unreal generated project file' '*.sln', '.vsconfig' -Markers '*.uproject'
    New-TempRule File 'Log file' '*.log' -Confidence Uncertain
)

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
