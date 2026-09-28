[CmdletBinding()]
param()

. (Join-Path $Global:BrownserveRepoRootDirectory 'tasks' 'ReleaseLifecycle.tasks.ps1') `
    -BranchName 'feature/retry-helper-tests' `
    -DefaultBranch 'main' `
    -GitHubRepoOwner 'Brownserve-UK' `
    -GitHubRepoName 'PSBuildTasks'

task RetryHarness {
    $Global:RetryHarnessResult = $null
    $Global:RetryHarnessError = $null
    try
    {
        $RetryParams = @{
            ScriptBlock       = $Global:RetryHarnessScriptBlock
            SleepScriptBlock  = $Global:RetryHarnessSleepScriptBlock
            MaxAttempts       = $Global:RetryHarnessMaxAttempts
            BaseDelaySeconds  = $Global:RetryHarnessBaseDelaySeconds
        }
        $Global:RetryHarnessResult = Invoke-BrownserveRetry @RetryParams
    }
    catch
    {
        $Global:RetryHarnessError = $_
    }
}
