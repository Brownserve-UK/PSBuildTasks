<#
.SYNOPSIS
    Invoke-Build tasks for building, testing, packaging and releasing a Rust binary.
.DESCRIPTION
    Attaches to the anchors defined in ReleaseLifecycle.tasks.ps1: compiling the binary attaches to
    'Build', 'cargo test' attaches to 'Test', archiving the compiled binary attaches to 'Package', and
    uploading release archives as assets attaches to 'Publish'. Also defines the public dotted targets
    'RustBinary.Check' (cargo build + cargo test + the binary smoke tests) and 'RustBinary.Package'
    (build and archive for a single -Target), used directly by CI matrix jobs.
    Supports a collector mode: when -ArchiveSourceDirectory is supplied, cargo is never invoked. Instead
    the archives already built by the matrix jobs are copied into the build output directory and uploaded
    to the draft GitHub release. This lets a Linux job with no Rust toolchain run the Release meta task.
    ReleaseLifecycle.tasks.ps1 must be dot-sourced first, as this file depends on tasks, script variables
    and the Invoke-BrownserveRetry helper it defines.
#>
[CmdletBinding()]
param
(
    # The name of the binary to build and package (without extension)
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $BinaryName = $Global:BrownserveRepoName,

    # The Rust target triple to build for, defaults to the host
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $Target,

    # Every target triple being released, required when publishing to GitHub
    [Parameter(
        Mandatory = $false
    )]
    [string[]]
    $Targets,

    # Directory of pre-built archives to publish instead of building with cargo
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $ArchiveSourceDirectory,

    # The various places to publish to
    [Parameter(
        Mandatory = $false
    )]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('GitHub')]
    [string[]]
    $PublishTo,

    # The GitHub organisation/account to publish the release to
    [Parameter(
        Mandatory = $true
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepoOwner,

    # The GitHub repo name
    [Parameter(
        Mandatory = $false
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepoName = $Global:BrownserveRepoName,

    # GitHub token used during the Release build, needed to upload release archives, must have the
    # following permissions:
    #   * Read/write releases
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $GitHubReleaseToken
)
if (!$script:ExpectedReleaseAssets)
{
    $script:ExpectedReleaseAssets = @()
}
$script:EffectiveTarget = $Target

<#
.SYNOPSIS
    Checks that all the required parameters for publishing this binary have been provided.
#>
task CheckRustPublishingParameters {
    if ('GitHub' -in $PublishTo)
    {
        if (!$GitHubReleaseToken)
        {
            throw 'GitHubReleaseToken not provided'
        }
        if (!$Targets)
        {
            throw 'Targets not provided'
        }
    }
}

<#
.SYNOPSIS
    Registers the archive names expected for every released target so FinaliseRelease refuses to publish
    a release that's missing an archive from the matrix.
.DESCRIPTION
    The extension is inferred from the target triple: any triple containing 'windows' produces a .zip
    archive name, everything else a .tar.gz, matching how Package names the archive it creates.
#>
task RegisterExpectedRustAssets SetVersion, {
    if (!$Targets)
    {
        return
    }
    foreach ($OneTarget in $Targets)
    {
        $Extension = if ($OneTarget -match 'windows') { 'zip' } else { 'tar.gz' }
        $script:ExpectedReleaseAssets += "$BinaryName-$script:PrefixedVersion-$OneTarget.$Extension"
    }
} -Before Package

<#
.SYNOPSIS
    Writes the new version into the root Cargo.toml [workspace.package] table and regenerates Cargo.lock.
.DESCRIPTION
    Requires the root Cargo.toml to contain a [workspace.package] section with a version field. The
    version written is the plain semver string (e.g. 1.2.0) without the 'v' prefix, as required by Cargo.
    Both Cargo.toml and the regenerated Cargo.lock are added to $script:TrackedFiles so they're committed
    to the staging branch alongside CHANGELOG.md. Requires Rust/Cargo to be available on the runner, as it
    calls 'cargo generate-lockfile'; the stage-release workflow installs Rust before calling the build.
#>
task UpdateCargoVersion SetVersion, {
    Write-Build White 'Updating Cargo.toml version'
    $CargoTomlPath = Join-Path $Global:BrownserveRepoRootDirectory 'Cargo.toml' | Convert-Path
    $CargoContent = Get-Content -Path $CargoTomlPath -Raw
    $NewSemver = "$($script:NewVersion.Major).$($script:NewVersion.Minor).$($script:NewVersion.Patch)"
    $CargoVersionPattern = '(?ms)(\[workspace\.package\].*?^version\s*=\s*")[^"]*(")'
    if (-not [regex]::IsMatch($CargoContent, $CargoVersionPattern))
    {
        throw "Failed to update version in Cargo.toml. Ensure the root Cargo.toml has a [workspace.package] section containing a version = '...' field."
    }
    $Updated = $CargoContent -replace $CargoVersionPattern, "`${1}$NewSemver`${2}"
    Set-Content -Path $CargoTomlPath -Value $Updated -NoNewline
    $script:TrackedFiles += $CargoTomlPath
    Write-Verbose "Cargo.toml version updated to $NewSemver"
    Write-Build White 'Regenerating Cargo.lock'
    try
    {
        exec { cargo generate-lockfile }
    }
    catch
    {
        throw "Failed to regenerate Cargo.lock.`n$($_.Exception.Message)"
    }
    $CargoLockPath = Join-Path $Global:BrownserveRepoRootDirectory 'Cargo.lock' | Convert-Path
    $script:TrackedFiles += $CargoLockPath
} -Before Stage

<#
.SYNOPSIS
    Compiles the Rust application in release mode.
.DESCRIPTION
    Sets CARGO_TARGET_DIR to the build output directory so the compiled binary lands in .tmp/output, and
    records its path in $Global:BrownserveRustBinaryPath for the binary smoke tests to pick up. Skipped
    entirely in collector mode (-ArchiveSourceDirectory), where $Global:BrownserveRustBinaryPath is left
    unset so the smoke tests know to skip themselves.
#>
task CargoBuild -If { -not $ArchiveSourceDirectory } {
    Write-Build White "Building '$BinaryName'"
    $env:CARGO_TARGET_DIR = $Global:BrownserveRepoBuildOutputDirectory
    $CargoArgs = @('build', '--release')
    if ($Target)
    {
        $CargoArgs += '--target'
        $CargoArgs += $Target
    }
    try
    {
        exec { & cargo $CargoArgs }
    }
    catch
    {
        throw "Cargo build failed.`n$($_.Exception.Message)"
    }
    $BinDir = if ($Target) { Join-Path $Global:BrownserveRepoBuildOutputDirectory $Target 'release' } else { Join-Path $Global:BrownserveRepoBuildOutputDirectory 'release' }
    $BinaryFileName = if ($IsWindows) { "$BinaryName.exe" } else { $BinaryName }
    $Global:BrownserveRustBinaryPath = Join-Path $BinDir $BinaryFileName
} -Before Build

<#
.SYNOPSIS
    Runs all Cargo tests for the workspace. Skipped in collector mode.
#>
task CargoTest -If { -not $ArchiveSourceDirectory } {
    Write-Build White 'Running Cargo tests'
    try
    {
        exec { cargo test --workspace }
    }
    catch
    {
        throw "Cargo tests failed.`n$($_.Exception.Message)"
    }
} -Before Test

<#
.SYNOPSIS
    Archives the compiled binary for the current platform and target.
.DESCRIPTION
    The archive is written to the build output directory using the naming convention
    <binary>-v<version>-<target-triple>.tar.gz (Linux/macOS) or .zip (Windows). Skipped in collector mode.
#>
task CreateBinaryArchive -If { -not $ArchiveSourceDirectory } SetVersion, CargoBuild, {
    if (!$script:EffectiveTarget)
    {
        $RustcOutput = & rustc -vV 2>&1
        $HostLine = $RustcOutput | Select-String 'host: (.+)'
        $script:EffectiveTarget = if ($HostLine) { $HostLine.Matches[0].Groups[1].Value.Trim() } else { 'unknown-target' }
    }
    Write-Build White "Packaging '$BinaryName' for target '$script:EffectiveTarget'"
    $BinDir = if ($Target) { Join-Path $Global:BrownserveRepoBuildOutputDirectory $Target 'release' } else { Join-Path $Global:BrownserveRepoBuildOutputDirectory 'release' }
    $BinaryFileName = if ($IsWindows) { "$BinaryName.exe" } else { $BinaryName }
    $BinaryPath = Join-Path $BinDir $BinaryFileName
    if (!(Test-Path $BinaryPath))
    {
        throw "Compiled binary not found at '$BinaryPath'. Ensure the Build task ran successfully."
    }
    if ($IsWindows)
    {
        $ArchiveName = "$BinaryName-$script:PrefixedVersion-$script:EffectiveTarget.zip"
        $ArchivePath = Join-Path $Global:BrownserveRepoBuildOutputDirectory $ArchiveName
        Write-Build White "Creating zip archive '$ArchiveName'"
        Compress-Archive -Path $BinaryPath -DestinationPath $ArchivePath -Force
    }
    else
    {
        $ArchiveName = "$BinaryName-$script:PrefixedVersion-$script:EffectiveTarget.tar.gz"
        $ArchivePath = Join-Path $Global:BrownserveRepoBuildOutputDirectory $ArchiveName
        Write-Build White "Creating tar archive '$ArchiveName'"
        exec { tar -czf $ArchivePath -C $BinDir $BinaryFileName }
    }
    Write-Build Green "Archive created: $ArchivePath"
} -Before Package

<#
.SYNOPSIS
    Copies pre-built archives from -ArchiveSourceDirectory into the build output directory.
.DESCRIPTION
    Only runs in collector mode. This is where the archives uploaded by the RustBinary.Package matrix
    jobs, and downloaded by the collector job as GitHub Actions artifacts, are brought into the build
    output directory ready for PublishBinaryReleaseAssets to upload.
#>
task CopyCollectedArchives -If { $ArchiveSourceDirectory } {
    Write-Build White "Copying release archives from '$ArchiveSourceDirectory'"
    Get-ChildItem -Path $ArchiveSourceDirectory -File | Copy-Item -Destination $Global:BrownserveRepoBuildOutputDirectory -Force
} -Before Package

<#
.SYNOPSIS
    Uploads every release archive in the build output directory as an asset on the draft GitHub release.
.DESCRIPTION
    Skips an archive already present on the draft with a matching name and size, so a resumed Release
    doesn't fail or duplicate assets. Network calls are routed through Invoke-BrownserveRetry.
#>
task PublishBinaryReleaseAssets CheckRustPublishingParameters, CreateDraftRelease, CreateBinaryArchive, CopyCollectedArchives, {
    if ('GitHub' -notin $PublishTo)
    {
        Write-Verbose 'GitHub not targeted, skipping release asset upload...'
        return
    }
    if (!$script:ReleaseResponse)
    {
        throw 'No draft release found to upload archives to.'
    }
    $Archives = Get-ChildItem -Path $Global:BrownserveRepoBuildOutputDirectory -File |
        Where-Object { $_.Name -like "$BinaryName-*" -and ($_.Extension -eq '.zip' -or $_.Name -like '*.tar.gz') }
    foreach ($Archive in $Archives)
    {
        $ExistingAsset = $script:ReleaseResponse.assets | Where-Object { $_.name -eq $Archive.Name }
        if ($ExistingAsset -and ($ExistingAsset.size -eq $Archive.Length))
        {
            Write-Verbose "Asset '$($Archive.Name)' already uploaded with a matching size, skipping."
            continue
        }
        Write-Build White "Uploading '$($Archive.Name)' as release asset"
        Invoke-BrownserveRetry -ScriptBlock {
            Add-GitHubReleaseAsset `
                -UploadUrl $script:ReleaseResponse.upload_url `
                -Token $GitHubReleaseToken `
                -FilePath $Archive.FullName `
                -ErrorAction 'Stop'
        } | Out-Null
    }
} -Before Publish

<#
.SYNOPSIS
    Public target: build, test and archive check for one target triple.
.DESCRIPTION
    Runs the Cargo build, the Cargo test suite and the Pester smoke tests (which key off
    $Global:BrownserveRustBinaryPath), then fails if the build left uncommitted changes behind.
    Used directly by CI for pull request validation.
#>
task RustBinary.Check CargoBuild, CargoTest, Tests, CheckForUncommittedChanges, {}

<#
.SYNOPSIS
    Public target: build and archive the binary for a single -Target.
.DESCRIPTION
    Run once per entry in a CI package matrix. The resulting archive is uploaded as a GitHub Actions
    artifact by the workflow, then collected by a later Release run using -ArchiveSourceDirectory.
#>
task RustBinary.Package SetReleaseVariables, SetVersion, CargoBuild, CreateBinaryArchive, {}
