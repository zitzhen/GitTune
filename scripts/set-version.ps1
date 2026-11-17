<#
.SYNOPSIS
    GitTune version synchronizer (Windows / PowerShell).

.DESCRIPTION
    Sets every packaging version declaration to the version passed as an
    argument. The version must have three numeric fields: major.minor.patch.

    Files kept in sync:
      Cargo.toml                 version = "X.Y.Z"
      Cargo.lock                 version of the [[package]] named "GitTune"
      snap/snapcraft.yaml        version: 'X.Y.Z'
      debian/changelog           first line: git-tune (X.Y.Z-<debian revision>)
      AppxManifest.xml           Identity Version="X.Y.Z.0" plus the doc comment
      Package.appxmanifest       same as above (kept byte-identical)
      wix/GitTune.wxs            version in the documented build command

    MSIX requires a four-part version, so "X.Y.Z.0" is derived automatically.
    README.md's "Version 1.0.0 - first release" is a historical note, not the
    current version, and is intentionally left alone.

.EXAMPLE
    .\scripts\set-version.ps1 1.7.0
    Set every version declaration to 1.7.0.

.EXAMPLE
    .\scripts\set-version.ps1 1.7.0 -Check
    Verify that all files are at 1.7.0 without changing them.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Version,

    [switch] $Check
)

$ErrorActionPreference = 'Stop'

if (-not $Version) {
    throw 'A version argument is required, e.g. .\scripts\set-version.ps1 1.7.0'
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must be three numeric fields (major.minor.patch), got: $Version"
}
$v = $Version
$v4 = "$v.0"

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$paths = @{
    Cargo       = Join-Path $root 'Cargo.toml'
    Lock        = Join-Path $root 'Cargo.lock'
    Snapcraft   = Join-Path $root 'snap\snapcraft.yaml'
    Changelog   = Join-Path $root 'debian\changelog'
    Appx        = Join-Path $root 'AppxManifest.xml'
    AppxPackage = Join-Path $root 'Package.appxmanifest'
    Wix         = Join-Path $root 'wix\GitTune.wxs'
}
foreach ($path in $paths.Values) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing file: $path" }
}

function Read-Text([string] $Path) {
    return [IO.File]::ReadAllText($Path)
}

# Write the original text back as-is (line endings are preserved because the
# content is never split into lines). Skip writes when nothing changed.
function Write-TextIfChanged([string] $Path, [string] $Content) {
    $old = [IO.File]::ReadAllText($Path)
    if ([string]::Equals($old, $Content, [StringComparison]::Ordinal)) { return $false }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
    return $true
}

# ---- Check mode ----------------------------------------------------------
if ($Check) {
    Write-Host "Checking version $v (MSIX: $v4):"
    $script:checkOk = $true

    function Assert-Contains([string] $Path, [string] $Text, [string] $Label) {
        if ((Read-Text $Path).Contains($Text)) {
            Write-Host "  [OK]   $Label"
        } else {
            Write-Host "  [FAIL] $Label  expected: $Text"
            $script:checkOk = $false
        }
    }

    Assert-Contains $paths.Cargo     ('version = "{0}"' -f $v)     'Cargo.toml'
    Assert-Contains $paths.Snapcraft ("version: '{0}'" -f $v)      'snap/snapcraft.yaml'

    $lockMatch = [regex]::Match(
        (Read-Text $paths.Lock),
        '(?ms)\[\[package\]\]\r?\nname[ \t]*=[ \t]*"GitTune"\r?\nversion[ \t]*=[ \t]*"([^"]+)"'
    )
    if ($lockMatch.Success -and [string]::Equals($lockMatch.Groups[1].Value, $v, [StringComparison]::Ordinal)) {
        Write-Host '  [OK]   Cargo.lock'
    } else {
        Write-Host "  [FAIL] Cargo.lock  expected $v"
        $script:checkOk = $false
    }

    if ([regex]::IsMatch((Read-Text $paths.Changelog), '(?m)^git-tune \(' + [regex]::Escape("$v-"))) {
        Write-Host '  [OK]   debian/changelog'
    } else {
        Write-Host "  [FAIL] debian/changelog  first line should be git-tune ($v-<revision>)"
        $script:checkOk = $false
    }

    foreach ($key in @('Appx', 'AppxPackage')) {
        $label = Split-Path -Leaf $paths[$key]
        Assert-Contains $paths[$key] ('Version="{0}"' -f $v4)    "Identity Version @ $label"
        Assert-Contains $paths[$key] ('Cargo.toml {0}' -f $v)    "version comment @ $label"
    }

    Assert-Contains $paths.Wix ('-d Version={0}' -f $v)  'wix/GitTune.wxs build example'
    Assert-Contains $paths.Wix ('GitTune-{0}-x64' -f $v) 'wix/GitTune.wxs output filename example'

    if ($script:checkOk) {
        Write-Host 'All files are in sync.'
        exit 0
    }
    Write-Host "Out of sync. Run .\scripts\set-version.ps1 $v to fix it."
    exit 1
}

# ---- Sync mode -----------------------------------------------------------
$script:changed = [Collections.Generic.List[string]]::new()

function Apply-Regex {
    param(
        [string] $Key,
        [string] $Path,
        [string] $Pattern,
        [string] $Replacement
    )
    $new = [regex]::Replace((Read-Text $Path), $Pattern, $Replacement)
    if ((Write-TextIfChanged $Path $new) -and (-not $script:changed.Contains($Key))) {
        $script:changed.Add($Key)
    }
}

Apply-Regex 'Cargo.toml' $paths.Cargo '(?m)^version[ \t]*=[ \t]*"[^"]*"' ('version = "{0}"' -f $v)

# Only the GitTune package entry in Cargo.lock is touched; dependency versions
# are managed by Cargo and must not be rewritten here.
$lockPattern = '(?m)(\[\[package\]\]\r?\nname[ \t]*=[ \t]*"GitTune"\r?\nversion[ \t]*=[ \t]*")[^"]*(")'
$lockNew = [regex]::Replace((Read-Text $paths.Lock), $lockPattern, {
    param($m)
    return $m.Groups[1].Value + $v + $m.Groups[2].Value
})
if (Write-TextIfChanged $paths.Lock $lockNew) { $script:changed.Add('Cargo.lock') }

Apply-Regex 'snap/snapcraft.yaml' $paths.Snapcraft "(?m)^version:[ \t]*'[^']*'" ("version: '{0}'" -f $v)

# Keep the existing Debian revision (the "-1" suffix) when replacing the version.
$changeNew = [regex]::Replace((Read-Text $paths.Changelog), '(?m)^git-tune \(([^)]*)\)', {
    param($m)
    $spec = $m.Groups[1].Value
    $revMatch = [regex]::Match($spec, '-([^-]+)$')
    $rev = if ($revMatch.Success) { $revMatch.Groups[1].Value } else { '1' }
    return ('git-tune ({0}-{1})' -f $v, $rev)
})
if (Write-TextIfChanged $paths.Changelog $changeNew) { $script:changed.Add('debian/changelog') }

# The Identity Version is four-part; MinVersion/MaxVersionTested are not matched
# because the pattern requires whitespace immediately before "Version=".
foreach ($key in @('Appx', 'AppxPackage')) {
    $path = $paths[$key]
    $new = [regex]::Replace(
        (Read-Text $path),
        '(?m)([ \t])Version="\d+\.\d+\.\d+\.0"',
        '${1}Version="' + $v4 + '"'
    )
    $new = [regex]::Replace($new, '(?m)Cargo\.toml[ \t]+\d+\.\d+\.\d+', ('Cargo.toml {0}' -f $v))
    if (Write-TextIfChanged $path $new) { $script:changed.Add((Split-Path -Leaf $path)) }
}

Apply-Regex 'wix/GitTune.wxs' $paths.Wix '(?m)-d[ \t]+Version=\d+\.\d+\.\d+' ('-d Version={0}' -f $v)
Apply-Regex 'wix/GitTune.wxs' $paths.Wix '(?m)GitTune-\d+\.\d+\.\d+-x64'  ('GitTune-{0}-x64' -f $v)

Write-Host "Version set to $v (MSIX: $v4)"
if ($script:changed.Count -eq 0) {
    Write-Host 'All files already at the target version; nothing to change.'
} else {
    Write-Host ("Updated {0} files:" -f $script:changed.Count)
    foreach ($name in $script:changed) { Write-Host "  - $name" }
}
