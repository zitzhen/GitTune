<#
.SYNOPSIS
    Builds the GitTune Windows installers: an MSIX (Store / sideload) and an MSI.

.DESCRIPTION
    This script is the single source of truth for Windows packaging. Both
    workflows call it, so CI cannot pass while a release would fail:

      .github/workflows/build.yml    -> run on every push/PR with -Verify
      .github/workflows/release.yml  -> run to produce the released files

    It needs a Windows SDK (makeappx.exe, signtool.exe) and, for the MSI, the
    WiX toolset; WiX v5 is installed on demand as a dotnet global tool.

.PARAMETER Version
    Product version. Defaults to the `version` field of Cargo.toml. Must be a
    3-part numeric version (major.minor.patch): MSI rejects a fourth field, so
    the MSIX version is derived as "<version>.0".

.PARAMETER Verify
    Round-trip the packages after building them: unpack the MSIX and re-read
    its manifest, read the MSI's property table through the Windows Installer
    COM API, and perform an administrative install (msiexec /a) to prove the
    payload really contains GitTune.exe.

.PARAMETER PfxBase64
    Base64 of a .pfx code-signing certificate. Defaults to $env:MSIX_PFX_BASE64.
    When empty (the default) both installers are left unsigned, which is what
    the Microsoft Store expects - it re-signs MSIX during ingestion.

.EXAMPLE
    pwsh -File scripts/package-windows.ps1 -Verify
#>
[CmdletBinding()]
param(
    [string] $Version,
    [string] $OutputDir = (Join-Path $PWD 'dist'),
    [string] $SourceExe = (Join-Path $PWD 'target\release\GitTune.exe'),
    [string] $Manifest = (Join-Path $PWD 'AppxManifest.xml'),
    [string] $AssetsDir = (Join-Path $PWD 'Assets'),
    [string] $IconFile = (Join-Path $PWD 'Assets\gittune.ico'),
    [string] $WixSource = (Join-Path $PWD 'wix\GitTune.wxs'),
    [string] $CargoToml = (Join-Path $PWD 'Cargo.toml'),
    [switch] $Verify,
    [string] $PfxBase64 = $env:MSIX_PFX_BASE64,
    [string] $PfxPassword = $env:MSIX_PFX_PASSWORD
)

$ErrorActionPreference = 'Stop'

# Assets the Appx manifest points at. makeappx would fail on a missing one, but
# this fails earlier with a message that names the file.
$requiredAssets = @(
    'StoreLogo.png',
    'Square44x44Logo.png',
    'Square71x71Logo.png',
    'Square150x150Logo.png',
    'Square310x310Logo.png',
    'Wide310x150Logo.png',
    'SplashScreen.png'
)

function Get-SdkTool {
    param([Parameter(Mandatory)][string] $Name)
    $tool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\$Name" -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Parent.Name -match '^\d+(\.\d+)+' } |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
        Select-Object -First 1
    if (-not $tool) { throw "$Name was not found under '${env:ProgramFiles(x86)}\Windows Kits\10\bin'" }
    return $tool.FullName
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string] $Exe,
        [Parameter(Mandatory)][string[]] $Arguments
    )
    Write-Host "> $([IO.Path]::GetFileName($Exe)) $($Arguments -join ' ')"
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$([IO.Path]::GetFileName($Exe)) failed with exit code $LASTEXITCODE"
    }
}

# --- inputs ---------------------------------------------------------------
if (-not $Version) {
    $Version = (Select-String -Path $CargoToml -Pattern '^version\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version '$Version' is not a 3-part numeric version; MSI and MSIX cannot be built from it."
}
$msixVersion = "$Version.0"

if ([IO.Path]::GetFileName($Manifest) -ne 'AppxManifest.xml') {
    throw "The MSIX layout manifest must be named AppxManifest.xml (got $([IO.Path]::GetFileName($Manifest)))."
}
foreach ($required in @($SourceExe, $Manifest, $IconFile, $WixSource, $CargoToml)) {
    if (-not (Test-Path $required)) { throw "Required file not found: $required" }
}
foreach ($asset in $requiredAssets) {
    if (-not (Test-Path (Join-Path $AssetsDir $asset))) { throw "Required package asset not found: $asset" }
}

Write-Host "Packaging GitTune $Version (MSIX $msixVersion)"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ("gittune-package-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    # --- MSIX -------------------------------------------------------------
    # The layout is: AppxManifest.xml + GitTune.exe + Assets\ side by side, and
    # it must contain exactly one manifest, hence the AppxManifest.xml check.
    $layout = Join-Path $work 'msix-layout'
    New-Item -ItemType Directory -Force -Path (Join-Path $layout 'Assets') | Out-Null
    Copy-Item $Manifest $layout
    Copy-Item $SourceExe $layout
    Copy-Item (Join-Path $AssetsDir '*.png') (Join-Path $layout 'Assets')

    # Keep the packaged version in lock-step with Cargo.toml.
    # This must be case-sensitive (-creplace) and anchored to the <Identity> tag:
    # a plain -replace is case-insensitive and would also rewrite the lowercase
    # "version" in the XML declaration (<?xml version="1.0"?>), producing a
    # manifest that is no longer valid XML.
    $stagedManifest = Join-Path $layout 'AppxManifest.xml'
    $content = (Get-Content $stagedManifest -Raw) -creplace '(<Identity\b[^>]*?\bVersion=")\d+(\.\d+){1,3}(")', ('${1}' + $msixVersion + '${3}')
    [xml] $staged = $content
    $stagedIdentity = $staged.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']")
    if ($stagedIdentity.GetAttribute('Version') -ne $msixVersion) {
        throw "Failed to stamp version $msixVersion into the Appx manifest"
    }
    Set-Content -Path $stagedManifest -Value $content -Encoding UTF8 -NoNewline

    $makeappx = Get-SdkTool 'makeappx.exe'
    $msixPath = Join-Path $OutputDir "GitTune-$Version-x64.msix"
    Invoke-Native $makeappx @('pack', '/d', $layout, '/p', $msixPath, '/o')

    # --- MSI --------------------------------------------------------------
    $wix = Join-Path $env:USERPROFILE '.dotnet\tools\wix.exe'
    if (-not (Test-Path $wix)) {
        Write-Host 'Installing the WiX toolset as a dotnet global tool...'
        Invoke-Native 'dotnet' @('tool', 'install', '--global', 'wix', '--version', '5.*')
    }

    $msiPath = Join-Path $OutputDir "GitTune-$Version-x64.msi"
    Invoke-Native $wix @(
        'build', $WixSource,
        '-arch', 'x64',
        '-d', "Version=$Version",
        '-d', "SourceDir=$(Split-Path -Parent $SourceExe)",
        '-d', "IconFile=$IconFile",
        '-o', $msiPath
    )

    # --- verification -----------------------------------------------------
    if ($Verify) {
        Write-Host 'Verifying the packages...'

        $unpacked = Join-Path $work 'msix-unpacked'
        Invoke-Native $makeappx @('unpack', '/p', $msixPath, '/d', $unpacked, '/o')
        foreach ($inner in @('AppxManifest.xml', 'GitTune.exe')) {
            if (-not (Test-Path (Join-Path $unpacked $inner))) {
                throw "The MSIX does not contain $inner"
            }
        }
        [xml] $packed = Get-Content (Join-Path $unpacked 'AppxManifest.xml')
        $identity = $packed.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']")
        if ($identity.GetAttribute('Name') -ne 'OliverLin.gittune') {
            throw "Unexpected MSIX identity name: $($identity.GetAttribute('Name'))"
        }
        if ($identity.GetAttribute('Version') -ne $msixVersion) {
            throw "MSIX version $($identity.GetAttribute('Version')) does not match $msixVersion"
        }

        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.OpenDatabase($msiPath, 0)
        $view = $database.OpenView('SELECT `Property`, `Value` FROM `Property`')
        $view.Execute()
        $properties = @{}
        while ($record = $view.Fetch()) {
            $properties[$record.StringData(1)] = $record.StringData(2)
        }
        $view.Close()
        if ($properties['ProductName'] -ne 'GitTune') {
            throw "Unexpected MSI ProductName: $($properties['ProductName'])"
        }
        if ($properties['ProductVersion'] -ne $Version) {
            throw "MSI ProductVersion $($properties['ProductVersion']) does not match $Version"
        }

        # Administrative install: extracts the payload without touching the
        # machine, which proves the MSI (and its embedded cab) is usable.
        $extract = Join-Path $work 'msi-extract'
        $msi = Start-Process msiexec.exe -ArgumentList @('/a', "`"$msiPath`"", '/qn', "TARGETDIR=`"$extract`"") -Wait -PassThru
        if ($msi.ExitCode -ne 0) { throw "msiexec /a failed with exit code $($msi.ExitCode)" }
        if (-not (Get-ChildItem $extract -Recurse -Filter 'GitTune.exe')) {
            throw 'GitTune.exe was not extracted from the MSI'
        }

        Write-Host 'Verification passed.'
    }

    # --- optional signing -------------------------------------------------
    if ($PfxBase64) {
        $signtool = Get-SdkTool 'signtool.exe'
        $pfx = Join-Path $work 'signing.pfx'
        [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($PfxBase64))

        foreach ($file in @($msixPath, $msiPath)) {
            $signArgs = @('sign', '/fd', 'SHA256', '/f', $pfx, '/tr', 'http://timestamp.digicert.com', '/td', 'SHA256')
            if ($PfxPassword) { $signArgs += @('/p', $PfxPassword) }
            $signArgs += $file
            Invoke-Native $signtool $signArgs
        }

        # Ship the public certificate so users can trust the publisher.
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, $PfxPassword)
        [IO.File]::WriteAllBytes((Join-Path $OutputDir 'GitTune.cer'), $cert.Export('Cert'))
        Write-Host 'Signed the installers and exported GitTune.cer.'
    }
    else {
        Write-Host 'No signing certificate supplied - installers stay unsigned (expected for Store ingestion).'
    }

    if ($env:GITHUB_OUTPUT) {
        "version=$Version" >> $env:GITHUB_OUTPUT
        "msix=$msixPath" >> $env:GITHUB_OUTPUT
        "msi=$msiPath" >> $env:GITHUB_OUTPUT
    }
    Write-Host "Done: $msixPath"
    Write-Host "Done: $msiPath"
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
