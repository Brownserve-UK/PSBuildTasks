<#
.SYNOPSIS
    Builds, tests and releases the Brownserve.PSBuildTasks NuGet package via Invoke-Build and Pester.
#>
[CmdletBinding()]
param
(
    # The id of the NuGet package being built
    [Parameter(
        Mandatory = $False
    )]
    [string]
    $PackageId = 'Brownserve.PSBuildTasks',

    # The description of the package
    [Parameter(
        Mandatory = $False
    )]
    [string]
    $PackageDescription = 'Invoke-Build task files shared across Brownserve repositories, restored via paket.',

    # The author of the package
    [Parameter(
        Mandatory = $False
    )]
    [string]
    $PackageAuthor = 'Brownserve UK',

    # Any tags to add to the package
    [Parameter(Mandatory = $false)]
    [string[]]
    $PackageTags = @('brownserve-UK', 'CI', 'CD'),

    # The name of the default branch
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $DefaultBranch = 'main',

    # The name of the branch you are running on
    # this is used to work out if the release is production or pre-release
    [Parameter(
        Mandatory = $false
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $BranchName,

    # The build to run, defaults to build whereby the package is built but no testing is performed
    [Parameter(
        Mandatory = $false
    )]
    [ValidateSet(
        'Build',
        'BuildAndTest',
        'BuildTestAndCheck',
        'StageRelease',
        'DryRun',
        'Release'
    )]
    [AllowEmptyString()]
    [string]
    $Build = 'Build',

    # When preparing a release this denotes the type of changes that have been made.
    # This is used to determine the version number to use for the release.
    # For more information check the RELEASING.md file.
    [Parameter(
        Mandatory = $false
    )]
    [ValidateSet(
        'major',
        'minor',
        'patch'
    )]
    [string]
    $ReleaseType = 'minor',

    # The various places to publish to
    [Parameter(
        Mandatory = $False
    )]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('nuget', 'GitHub', 'CustomNugetFeeds')]
    [string[]]
    $PublishTo,

    # The GitHub organisation/account that owns this package
    [Parameter(
        Mandatory = $false
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepoOwner = 'Brownserve-UK',

    # The GitHub repo that contains this package
    [Parameter(
        Mandatory = $false
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepoName,

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

    # The API key to use when publishing to a NuGet feed, this is always needed but may not always be used
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $NugetFeedApiKey,

    # Any custom/private NuGet feeds to publish to
    [Parameter(
        Mandatory = $False
    )]
    [hashtable[]]
    $CustomNugetFeeds
)
# Always stop on errors
$ErrorActionPreference = 'Stop'
# If we don't have a branch name then try to work it out automatically
if (!$BranchName)
{
    $BranchName = & git rev-parse --abbrev-ref HEAD
}
# If we still don't have a branch name then set it to something sensible
if (!$BranchName)
{
    $BranchName = 'preview'
}
# Depending on how we got the branch name we may need to remove the full ref
$BranchName = $BranchName -replace 'refs\/heads\/', ''

# Run the init script
try
{
    Write-Verbose 'Starting build script'
    $initScriptPath = Join-Path $PSScriptRoot -ChildPath '_init.ps1' | Convert-Path
    . $initScriptPath
}
catch
{
    Write-Error "Failed to init repo.`n$($_.Exception.Message)"
}

# Invoke our build task
try
{
    $BuildParams = @{
        File                = (Join-Path -Path $global:BrownserveRepoBuildTasksDirectory -ChildPath 'build_tasks.ps1' | Convert-Path)
        Task                = $Build
        BranchName          = $BranchName
        DefaultBranch       = $DefaultBranch
        PackageId           = $PackageId
        PackageDescription  = $PackageDescription
        PackageAuthor       = $PackageAuthor
        PackageTags         = $PackageTags
    }
    if ($ReleaseType)
    {
        $BuildParams.Add('ReleaseType', $ReleaseType)
    }
    if ($GitHubRepoOwner)
    {
        $BuildParams.Add('GitHubRepoOwner', $GitHubRepoOwner)
    }
    if ($GitHubRepoName)
    {
        $BuildParams.Add('GitHubRepoName', $GitHubRepoName)
    }
    if ($NugetFeedApiKey)
    {
        $BuildParams.Add('NugetFeedApiKey', $NugetFeedApiKey)
    }
    if ($GitHubStageReleaseToken)
    {
        $BuildParams.Add('GitHubStageReleaseToken', $GitHubStageReleaseToken)
    }
    if ($GitHubReleaseToken)
    {
        $BuildParams.Add('GitHubReleaseToken', $GitHubReleaseToken)
    }
    if ($CustomNugetFeeds)
    {
        $BuildParams.Add('CustomNugetFeeds', $CustomNugetFeeds)
    }
    if ($PublishTo)
    {
        $BuildParams.Add('PublishTo', $PublishTo)
    }
    Write-Verbose "Invoking build: $Build"
    Invoke-Build @BuildParams -Verbose:($PSBoundParameters['Verbose'] -eq $true)
}
catch
{
    Write-Error $_.Exception.Message
}
