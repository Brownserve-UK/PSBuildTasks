[CmdletBinding()]
param
(
    [string]
    $BinaryName = 'testbin',

    [string]
    $Target,

    [string[]]
    $Targets,

    [string]
    $ArchiveSourceDirectory,

    [string[]]
    $PublishTo,

    [string]
    $GitHubReleaseToken,

    [string]
    $ReleaseType
)
$RequestedPublishTo = $PublishTo
$RequestedGitHubReleaseToken = $GitHubReleaseToken

$ReleaseLifecycleParams = @{
    BranchName              = 'main'
    DefaultBranch           = 'main'
    GitHubRepoOwner         = 'Brownserve-UK'
    GitHubRepoName          = 'PSBuildTasks'
    GitHubStageReleaseToken = 'fake-stage-token'
}
if ($ReleaseType) { $ReleaseLifecycleParams.Add('ReleaseType', $ReleaseType) }
if ($RequestedPublishTo) { $ReleaseLifecycleParams.Add('PublishTo', $RequestedPublishTo) }
if ($RequestedGitHubReleaseToken) { $ReleaseLifecycleParams.Add('GitHubReleaseToken', $RequestedGitHubReleaseToken) }
. (Join-Path $Global:BrownserveRepoRootDirectory 'tasks' 'ReleaseLifecycle.tasks.ps1') @ReleaseLifecycleParams

$RustBinaryParams = @{
    BinaryName      = $BinaryName
    GitHubRepoOwner = 'Brownserve-UK'
    GitHubRepoName  = 'PSBuildTasks'
}
if ($Target) { $RustBinaryParams.Add('Target', $Target) }
if ($Targets) { $RustBinaryParams.Add('Targets', $Targets) }
if ($ArchiveSourceDirectory) { $RustBinaryParams.Add('ArchiveSourceDirectory', $ArchiveSourceDirectory) }
if ($RequestedPublishTo) { $RustBinaryParams.Add('PublishTo', $RequestedPublishTo) }
if ($RequestedGitHubReleaseToken) { $RustBinaryParams.Add('GitHubReleaseToken', $RequestedGitHubReleaseToken) }

. (Join-Path $Global:BrownserveRepoRootDirectory 'tasks' 'RustBinary.tasks.ps1') @RustBinaryParams
