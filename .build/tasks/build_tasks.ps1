<#
.SYNOPSIS
    This contains the build tasks for Invoke-Build to use.
#>
[CmdletBinding()]
param
(
    # The id of the NuGet package being built
    [Parameter(
        Mandatory = $true
    )]
    [string]
    $PackageId,

    # The description of the package
    [Parameter(
        Mandatory = $true
    )]
    [string]
    $PackageDescription,

    # The author of the package
    [Parameter(
        Mandatory = $False
    )]
    [string]
    $PackageAuthor = 'Brownserve UK',

    # Any tags to add to the package
    [Parameter(Mandatory = $false)]
    [string[]]
    $PackageTags = 'brownserve-UK',

    # The type of changes that this version of the package contains
    # this is used to determine the version number
    [Parameter(
        Mandatory = $false
    )]
    [ValidateSet(
        'major',
        'minor',
        'patch'
    )]
    [string]
    $ReleaseType,

    # The branch this is being built from
    [Parameter(
        Mandatory = $true
    )]
    [string]
    $BranchName,

    # The default branch for this repository
    [Parameter(
        Mandatory = $true
    )]
    [string]
    $DefaultBranch,

    # The various places to publish to
    [Parameter(
        Mandatory = $False
    )]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('nuget', 'GitHub', 'CustomNugetFeeds')]
    [string[]]
    $PublishTo,

    # The GitHub organisation/account to publish the release to
    [Parameter(
        Mandatory = $true
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepoOwner,

    # The GitHub repo to publish the release to and used to fill in release details for NuGet
    [Parameter(
        Mandatory = $false
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepoName = $Global:BrownserveRepoName,

    # GitHub token used during the StageRelease build, must have the following permissions:
    #   * Read/Write pull requests
    #   * Read issues
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $GitHubStageReleaseToken,

    # GitHub token used during the Release build, must have the following permissions:
    #   * Read/write releases
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $GitHubReleaseToken,

    # The API key to use when publishing to a NuGet feed
    [Parameter(
        Mandatory = $False
    )]
    [string] $NugetFeedApiKey,

    # Any custom/private NuGet feeds to publish to
    [Parameter(
        Mandatory = $False
    )]
    [hashtable[]]
    $CustomNugetFeeds
)
# Just in case...
if (!$GitHubRepoName)
{
    throw 'GitHubRepoName not set'
}
# Depending on how we got the branch name we may need to remove the full ref
$BranchName = $BranchName -replace 'refs\/heads\/', ''

$TasksDirectory = Join-Path $Global:BrownserveRepoRootDirectory 'tasks'

$ReleaseLifecycleParams = @{
    BranchName       = $BranchName
    DefaultBranch    = $DefaultBranch
    GitHubRepoOwner  = $GitHubRepoOwner
    GitHubRepoName   = $GitHubRepoName
}
if ($ReleaseType) { $ReleaseLifecycleParams.Add('ReleaseType', $ReleaseType) }
if ($PublishTo) { $ReleaseLifecycleParams.Add('PublishTo', $PublishTo) }
if ($GitHubStageReleaseToken) { $ReleaseLifecycleParams.Add('GitHubStageReleaseToken', $GitHubStageReleaseToken) }
if ($GitHubReleaseToken) { $ReleaseLifecycleParams.Add('GitHubReleaseToken', $GitHubReleaseToken) }
. (Join-Path $TasksDirectory 'ReleaseLifecycle.tasks.ps1') @ReleaseLifecycleParams

$NuGetPackageParams = @{
    PackageId          = $PackageId
    PackageDescription = $PackageDescription
    PackageAuthor      = $PackageAuthor
    PackageTags        = $PackageTags
    GitHubRepoOwner    = $GitHubRepoOwner
    GitHubRepoName     = $GitHubRepoName
}
if ($PublishTo) { $NuGetPackageParams.Add('PublishTo', $PublishTo) }
if ($GitHubReleaseToken) { $NuGetPackageParams.Add('GitHubReleaseToken', $GitHubReleaseToken) }
if ($NugetFeedApiKey) { $NuGetPackageParams.Add('NugetFeedApiKey', $NugetFeedApiKey) }
if ($CustomNugetFeeds) { $NuGetPackageParams.Add('CustomNugetFeeds', $CustomNugetFeeds) }
. (Join-Path $TasksDirectory 'NuGetPackage.tasks.ps1') @NuGetPackageParams

. (Join-Path $Global:BrownserveRepoBuildTasksDirectory 'custom.tasks.ps1')
