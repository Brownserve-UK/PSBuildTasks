[CmdletBinding()]
param
(
    [string]
    $ImageName = 'test-image',

    [string]
    $DockerContextPath = '.',

    [string[]]
    $PublishTo,

    [string]
    $DockerHubUsername,

    [string]
    $DockerHubToken,

    [string]
    $GHCRToken
)

$RequestedPublishTo = $PublishTo

. (Join-Path $Global:BrownserveRepoRootDirectory 'tasks' 'ReleaseLifecycle.tasks.ps1') `
    -BranchName 'main' `
    -DefaultBranch 'main' `
    -GitHubRepoOwner 'Brownserve-UK' `
    -GitHubRepoName 'PSBuildTasks'

$ContainerImageParams = @{
    ImageName          = $ImageName
    DockerContextPath  = $DockerContextPath
    GitHubRepoOwner    = 'Brownserve-UK'
    DockerHubUsername  = $DockerHubUsername
    DockerHubToken     = $DockerHubToken
    GHCRToken          = $GHCRToken
}
if ($RequestedPublishTo)
{
    $ContainerImageParams.Add('PublishTo', $RequestedPublishTo)
}
. (Join-Path $Global:BrownserveRepoRootDirectory 'tasks' 'ContainerImage.tasks.ps1') @ContainerImageParams
