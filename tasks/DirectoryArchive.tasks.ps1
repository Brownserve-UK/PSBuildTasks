<#
.SYNOPSIS
    Invoke-Build tasks for zipping a directory and publishing it as a GitHub release asset.
.DESCRIPTION
    Attaches to the anchors defined in ReleaseLifecycle.tasks.ps1: zipping the directory attaches to
    'Package', and uploading the resulting archive attaches to 'Publish'. ReleaseLifecycle.tasks.ps1 must
    be dot-sourced first, as this file depends on tasks, script variables (e.g. $script:PrefixedVersion,
    $script:ExpectedReleaseAssets) and the Invoke-BrownserveRetry helper it defines.
#>
[CmdletBinding()]
param
(
    # The directory (relative to the repository root, or absolute) to archive
    [Parameter(
        Mandatory = $true
    )]
    [string]
    $Path,

    # The base name of the archive, e.g. 'skills' produces 'skills-v1.2.3.zip'
    [Parameter(
        Mandatory = $true
    )]
    [string]
    $ArchiveName,

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

    # GitHub token used during the Release build, needed to upload the archive as a release asset, must
    # have the following permissions:
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

<#
.SYNOPSIS
    Checks that all the required parameters for publishing this archive have been provided.
#>
task CheckDirectoryArchivePublishingParameters {
    if ('GitHub' -in $PublishTo)
    {
        if (!$GitHubReleaseToken)
        {
            throw 'GitHubReleaseToken not provided'
        }
    }
}

<#
.SYNOPSIS
    Zips the contents of -Path into the build output directory.
.DESCRIPTION
    The archive is named '<ArchiveName>-<version>.zip', where the version is the version being built
    (from SetVersion).
#>
task CreateDirectoryArchive SetVersion, {
    $SourcePath = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Global:BrownserveRepoRootDirectory $Path }
    $ResolvedPath = Resolve-Path $SourcePath -ErrorAction 'Stop'
    if (!(Get-ChildItem -Path $ResolvedPath))
    {
        throw "No files found in '$ResolvedPath'"
    }
    $script:DirectoryArchivePath = Join-Path $Global:BrownserveRepoBuildOutputDirectory "$ArchiveName-$script:PrefixedVersion.zip"
    Write-Build White "Packaging '$ResolvedPath' into '$script:DirectoryArchivePath'"
    try
    {
        Get-ChildItem -Path $Global:BrownserveRepoBuildOutputDirectory -Filter "$ArchiveName-*.zip" -ErrorAction 'SilentlyContinue' |
            Remove-Item -Force
        Compress-Archive `
            -Path (Join-Path $ResolvedPath '*') `
            -DestinationPath $script:DirectoryArchivePath `
            -Force `
            -ErrorAction 'Stop'
    }
    catch
    {
        throw "Failed to package '$ResolvedPath'.`n$($_.Exception.Message)"
    }
    Write-Build Green "Archive created: $script:DirectoryArchivePath"
} -Before Package

<#
.SYNOPSIS
    Uploads the archive as an asset on the draft GitHub release.
.DESCRIPTION
    Registers the archive as an expected release asset so FinaliseRelease refuses to publish the release
    without it. Skips the upload if an asset with the same name and size is already present on the draft,
    so re-running a Release that already uploaded the archive doesn't fail or duplicate it.
#>
task UploadDirectoryArchiveReleaseAsset CheckDirectoryArchivePublishingParameters, CreateDraftRelease, CreateDirectoryArchive, {
    if ('GitHub' -notin $PublishTo)
    {
        Write-Verbose 'GitHub not targeted, skipping release asset upload...'
        return
    }
    if (!$script:ReleaseResponse)
    {
        throw 'No draft release to upload the archive to.'
    }
    $AssetName = Split-Path $script:DirectoryArchivePath -Leaf
    $script:ExpectedReleaseAssets += $AssetName
    $ExistingAsset = $script:ReleaseResponse.assets | Where-Object { $_.name -eq $AssetName }
    $LocalSize = (Get-Item $script:DirectoryArchivePath).Length
    if ($ExistingAsset -and ($ExistingAsset.size -eq $LocalSize))
    {
        Write-Verbose "Asset '$AssetName' already uploaded with a matching size, skipping."
        return
    }
    Write-Build White "Uploading '$AssetName' as release asset"
    Invoke-BrownserveRetry -ScriptBlock {
        Add-GitHubReleaseAsset `
            -UploadUrl $script:ReleaseResponse.upload_url `
            -Token $GitHubReleaseToken `
            -FilePath $script:DirectoryArchivePath `
            -ErrorAction 'Stop'
    } | Out-Null
} -Before Publish
