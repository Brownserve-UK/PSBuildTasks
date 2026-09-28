[CmdletBinding()]
param
(
    [string]
    $Path,

    [string]
    $ArchiveName = 'test-archive',

    [string[]]
    $PublishTo,

    [string]
    $GitHubReleaseToken
)

. (Join-Path $Global:BrownserveRepoRootDirectory 'tasks' 'ReleaseLifecycle.tasks.ps1') `
    -BranchName 'main' `
    -DefaultBranch 'main' `
    -GitHubRepoOwner 'Brownserve-UK' `
    -GitHubRepoName 'PSBuildTasks' `
    -PublishTo $PublishTo `
    -GitHubReleaseToken $GitHubReleaseToken

. (Join-Path $Global:BrownserveRepoRootDirectory 'tasks' 'DirectoryArchive.tasks.ps1') `
    -Path $Path `
    -ArchiveName $ArchiveName `
    -PublishTo $PublishTo `
    -GitHubRepoOwner 'Brownserve-UK' `
    -GitHubRepoName 'PSBuildTasks' `
    -GitHubReleaseToken $GitHubReleaseToken
