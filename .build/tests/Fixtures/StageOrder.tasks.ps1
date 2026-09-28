[CmdletBinding()]
param
(
    [string]
    $ReleaseType = 'minor',

    [string]
    $BranchName = 'feature/stage-order-test',

    [string]
    $DefaultBranch = 'main',

    [string]
    $GitHubRepoOwner = 'Brownserve-UK',

    [string]
    $GitHubRepoName = 'PSBuildTasks',

    [string]
    $GitHubStageReleaseToken = 'fake-stage-token'
)

. (Join-Path $Global:BrownserveRepoRootDirectory 'tasks' 'ReleaseLifecycle.tasks.ps1') `
    -ReleaseType $ReleaseType `
    -BranchName $BranchName `
    -DefaultBranch $DefaultBranch `
    -GitHubRepoOwner $GitHubRepoOwner `
    -GitHubRepoName $GitHubRepoName `
    -GitHubStageReleaseToken $GitHubStageReleaseToken

task RecordStageOrderContribution -Before Stage {
    $Global:StageOrderLog += 'StageContribution'
    $script:TrackedFiles += (Join-Path $Global:BrownserveRepoRootDirectory 'CHANGELOG.md')
}
