[CmdletBinding()]
param
(
    [string]
    $DocsDirectory = 'pages'
)

. (Join-Path $Global:BrownserveRepoRootDirectory 'tasks' 'ReleaseLifecycle.tasks.ps1') `
    -BranchName 'feature/astro-docs-test' `
    -DefaultBranch 'main' `
    -GitHubRepoOwner 'Brownserve-UK' `
    -GitHubRepoName 'PSBuildTasks'

. (Join-Path $Global:BrownserveRepoRootDirectory 'tasks' 'AstroDocs.tasks.ps1') -DocsDirectory $DocsDirectory
