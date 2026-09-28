[CmdletBinding()]
param
(
    [string]
    $ModuleName = 'TestModule',

    [guid]
    $ModuleGUID = [guid]::NewGuid(),

    [string]
    $ModuleDescription = 'A test module',

    [string[]]
    $PublishTo,

    [string]
    $GitHubReleaseToken,

    [string]
    $NugetFeedApiKey,

    [string]
    $PSGalleryAPIKey,

    [hashtable[]]
    $CustomNugetFeeds,

    [switch]
    $UseWorkingCopy,

    [string]
    $ReleaseType = 'minor'
)
$RequestedPublishTo = $PublishTo
$RequestedGitHubReleaseToken = $GitHubReleaseToken

$ReleaseLifecycleParams = @{
    ReleaseType             = $ReleaseType
    BranchName              = 'main'
    DefaultBranch           = 'main'
    GitHubRepoOwner         = 'Brownserve-UK'
    GitHubRepoName          = 'PSBuildTasks'
    GitHubStageReleaseToken = 'fake-stage-token'
}
if ($RequestedPublishTo) { $ReleaseLifecycleParams.Add('PublishTo', $RequestedPublishTo) }
if ($RequestedGitHubReleaseToken) { $ReleaseLifecycleParams.Add('GitHubReleaseToken', $RequestedGitHubReleaseToken) }
. (Join-Path $Global:BrownserveRepoRootDirectory 'tasks' 'ReleaseLifecycle.tasks.ps1') @ReleaseLifecycleParams

$ModuleParams = @{
    ModuleName        = $ModuleName
    ModuleGUID        = $ModuleGUID
    ModuleDescription = $ModuleDescription
    GitHubRepoOwner   = 'Brownserve-UK'
    GitHubRepoName    = 'PSBuildTasks'
    UseWorkingCopy    = $UseWorkingCopy
}
if ($RequestedPublishTo) { $ModuleParams.Add('PublishTo', $RequestedPublishTo) }
if ($RequestedGitHubReleaseToken) { $ModuleParams.Add('GitHubReleaseToken', $RequestedGitHubReleaseToken) }
if ($NugetFeedApiKey) { $ModuleParams.Add('NugetFeedApiKey', $NugetFeedApiKey) }
if ($PSGalleryAPIKey) { $ModuleParams.Add('PSGalleryAPIKey', $PSGalleryAPIKey) }
if ($CustomNugetFeeds) { $ModuleParams.Add('CustomNugetFeeds', $CustomNugetFeeds) }

. (Join-Path $Global:BrownserveRepoRootDirectory 'tasks' 'PowerShellModule.tasks.ps1') @ModuleParams
