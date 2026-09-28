<#
.SYNOPSIS
    Shared Invoke-Build tasks for versioning, changelog management, staging and releasing a Brownserve
    repository via the GitHub API.
.DESCRIPTION
    This file defines the fixed meta tasks (Build, BuildAndTest, BuildTestAndCheck, StageRelease, DryRun,
    Release) and the empty anchor tasks that component task files attach to using Invoke-Build's
    -Before/-After parameters: Build, Test, Check, Package, Stage, Publish.
    It is dot-sourced by a consuming repository's build_tasks.ps1 alongside whichever component task files
    that repository needs (e.g. NuGetPackage.tasks.ps1).
#>
[CmdletBinding()]
param
(
    # The type of changes that this version of the release contains, used to determine the version number
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

    # The various places this build might publish to.
    # Component task files decide which of these values they care about.
    [Parameter(
        Mandatory = $false
    )]
    [string[]]
    $PublishTo,

    # The GitHub organisation/account this repository lives in
    [Parameter(
        Mandatory = $true
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepoOwner,

    # The GitHub repo name, used for the staging pull request and the release
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
    $GitHubReleaseToken
)
# Just in case...
if (!$GitHubRepoName)
{
    throw 'GitHubRepoName not set'
}
# Set up a bunch of variables that we'll use through the build, some of these are global as they're used in our tests too
$script:ChangelogPath = Join-Path $Global:BrownserveRepoRootDirectory -ChildPath 'CHANGELOG.md'
$script:GitHubRepoURI = "https://github.com/$GitHubRepoOwner/$GitHubRepoName"
$script:TrackedFiles = @()
$script:ExpectedReleaseAssets = @()

<#
    Work out if this is a production release depending on the branch we're building from
    We default to $true unless we detect that we're running on the default branch, as anything that is in the default
    branch should be the one to build shipped versions of the code.
    This should ensure that:
        * Main can never be used a prerelease tag
        * Feature branches cannot ever create a production release
    NOTE: this does not affect releases - there is different logic for that later on.
#>
$script:PreRelease = $true
if ($DefaultBranch -eq $BranchName)
{
    $script:PreRelease = $false
}

# BuildTask is a variable that is set by Invoke-Build to indicate the build task that has been called
# it might be useful to have specific logic for certain tasks
switch ($BuildTask)
{
    default {}
}

<#
.SYNOPSIS
    Retries a script block on transient failures with exponential backoff.
.DESCRIPTION
    Publisher tasks route their network calls through this helper. Timeouts, HTTP 5xx responses and rate
    limiting (honouring a Retry-After header, if present) are retried up to $MaxAttempts times with an
    exponential backoff delay. Authentication (401/403) and validation (400/422) errors are not retried.
    $SleepScriptBlock is injectable so tests can exercise the retry/backoff behaviour without waiting.
#>
function Invoke-BrownserveRetry
{
    [CmdletBinding()]
    param
    (
        # The script block to invoke
        [Parameter(
            Mandatory = $true
        )]
        [scriptblock]
        $ScriptBlock,

        # The maximum number of attempts to make before giving up
        [Parameter(
            Mandatory = $false
        )]
        [int]
        $MaxAttempts = 3,

        # The base delay (in seconds) used for the exponential backoff between attempts
        [Parameter(
            Mandatory = $false
        )]
        [int]
        $BaseDelaySeconds = 2,

        # The sleep implementation to use between attempts, injectable so tests run quickly
        [Parameter(
            Mandatory = $false
        )]
        [scriptblock]
        $SleepScriptBlock = { param($Seconds) Start-Sleep -Seconds $Seconds }
    )
    $Attempt = 0
    while ($true)
    {
        $Attempt++
        try
        {
            return & $ScriptBlock
        }
        catch
        {
            $StatusCode = $null
            $RetryAfter = $null
            $Response = $_.Exception.Response
            if ($Response)
            {
                try
                {
                    $StatusCode = [int]$Response.StatusCode
                }
                catch {}
                try
                {
                    $RetryAfterHeader = $Response.Headers['Retry-After']
                    if ($RetryAfterHeader)
                    {
                        $RetryAfter = [int]$RetryAfterHeader
                    }
                }
                catch {}
            }
            $IsTimeout = ($_.Exception -is [System.Net.WebException]) -and
                ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)
            $IsTransient = $IsTimeout -or ($StatusCode -eq 429) -or (($StatusCode -ge 500) -and ($StatusCode -le 599))
            if ($StatusCode -in @(400, 401, 403, 422))
            {
                $IsTransient = $false
            }
            if ((-not $IsTransient) -or ($Attempt -ge $MaxAttempts))
            {
                throw
            }
            $DelaySeconds = if ($RetryAfter) { $RetryAfter } else { $BaseDelaySeconds * [Math]::Pow(2, $Attempt - 1) }
            Write-Warning "Attempt $Attempt of $MaxAttempts failed, retrying in $DelaySeconds second(s). $($_.Exception.Message)"
            & $SleepScriptBlock $DelaySeconds
        }
    }
}

<#
.SYNOPSIS
    Checks that all the required parameters for publishing a release have been provided.
#>
task CheckPublishingParameters {
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
    Ensures all the parameters required to stage a release have been provided
#>
task CheckStagingParameters {
    if (!$GitHubStageReleaseToken)
    {
        throw 'GitHubStageReleaseToken must be set when performing a release'
    }
}

<#
.SYNOPSIS
    Sets up additional parameters required for staging a release
.DESCRIPTION
    This task should only be called as part of the StageRelease pipeline
#>
task SetStagingVariables {
    Write-Verbose 'Setting staging variables'
    $script:Stage = $true
}

<#
.SYNOPSIS
    Special task for setting up any release specific variables.
.DESCRIPTION
    This task should only be called as part of the release pipeline
#>
task SetReleaseVariables {
    Write-Verbose 'Setting release variables'
    $script:Release = $true
}

<#
.SYNOPSIS
    Reads information about the current release from the changelog
.DESCRIPTION
    This task will read the changelog and extract the version history.
    When staging a release this will be used to determine what the next version number should be.
    When performing a release this will be used to set the release notes and version for the release.
#>
task GetReleaseHistory {
    Write-Build White 'Getting release history'
    # Store the changelog object - we'll use it when updating the changelog later on
    $script:Changelog = Read-BrownserveChangelog `
        -ChangelogPath $script:ChangelogPath
    <#
        There may be times where our last release was a pre-release but we don't want to select this as our "latest" version.
        For example, say 1.0.0 is our current stable version, but we last released 2.0.0-rc1 so it's at the top of our changelog.
        If we select 2.0.0-rc1 then when we try to promote 2.0.0 to a stable release the version number would get incremented.
        automatically as part of the build (so for example 2.0.0-rc1 -> 2.0.1)
        Also if we had to do an emergency release of the latest stable version (e.g 1.0.0 -> 1.1.0) to patch a security
        issue then we wouldn't want to select our 2.0.0-rc1 pre-release version to base the new patch release off of.
        Therefore we select the last "stable" release which should always be what we want to work with.
        The exception to this is when we're performing a release, in which case we want to use the latest version regardless
    #>
    if ($script:Release -ne $true)
    {
        $script:LastRelease = $script:Changelog.VersionHistory |
            Where-Object { $_.PreRelease -eq $false } |
                Select-Object -First 1
    }
    else
    {
        $script:LastRelease = $script:Changelog.VersionHistory |
            Select-Object -First 1
    }
}
<#
.SYNOPSIS
    Sets the correct version number for a release
.DESCRIPTION
    This is done by looking at the last release and determining the next version number based on the type of release
    we're doing.
    We use the changelog as that _should_ be the greatest source of truth for determining the currently released version.
    There are some fail-safes later on in the build to ensure we don't accidentally release a version that already exists.
#>
task SetVersion GetReleaseHistory, {
    Write-Build White 'Setting version information'
    $script:CurrentCommitHash = (& git rev-parse HEAD).Trim()
    $script:CurrentVersion = $script:LastRelease |
        Select-Object -ExpandProperty Version
    if (!$script:CurrentVersion)
    {
        throw 'Unable to determine current version from changelog'
    }
    <#
        When we're performing a release we don't actually want to update the version number as with our workflows
        the version is set in the changelog prior to the build and we'll want to use that version number for the release.
        Also occasionally we may want to republish a version that we've already released.
        For example if we add another release endpoint or if we failed to release to one of our current endpoints
        due to an api key issue etc.
    #>
    if ($script:Release -eq $true)
    {
        Write-Verbose 'Release flag set, skipping updating version number'
        $script:NewVersion = $script:CurrentVersion
        $NugetPackageVersion = $script:CurrentVersion
        <#
            When performing releases we always do so from the main branch so the $PreRelease flag will always be false.
            However we do want to ensure that if we're releasing a pre-release version that we set the $PreRelease flag
            so we check for the pre-release label and set the flag accordingly.
        #>
        if ($script:NewVersion.PreReleaseLabel)
        {
            $script:PreRelease = $true
        }
    }
    else
    {
        # The ReleaseType parameter is technically optional but we do need it to determine the new version number
        if (!$ReleaseType)
        {
            throw '-ReleaseType not provided'
        }
        $UpdateVersionParams = @{
            Version     = $CurrentVersion
            ReleaseType = $ReleaseType
        }
        if ($script:PreRelease)
        {
            $UpdateVersionParams.Add('PreReleaseString', $BranchName)
        }
        # TODO: Add build number support
        $script:NewVersion = Update-Version @UpdateVersionParams -ErrorAction 'Stop'

        <#
            NuGet has a very specific version format that we need to adhere to.
        #>
        $NugetPackageVersionParams = @{
            Version         = $script:NewVersion
            # We use SemVer 1.0.0 as while NuGet has supported SemVer 2.0.0 since 4.3.0 we want to ensure we're compatible with older versions (for now)
            SemanticVersion = '1.0.0'
        }
        $NugetPackageVersion = Format-NuGetPackageVersion @NugetPackageVersionParams
        Write-Debug "NugetPackageVersion: $NugetPackageVersion"
    }
    <#
        We use the NugetPackageVersion for our release version as currently this is the most restrictive in terms
        of supported format.
        This should mean everything stays consistent.
    #>
    $Global:BuildVersion = $NugetPackageVersion
    # For GitHub releases and the changelog we prefix the version with a 'v'
    $script:PrefixedVersion = "v$($Global:BuildVersion)"
    Write-Build Magenta "Building version $script:PrefixedVersion of $GitHubRepoName"
}

<#
.SYNOPSIS
    Creates a new changelog entry.
.DESCRIPTION
    This task creates a new changelog entry for the current release.
    It will check for:
        * Merged PRs since the last release
        * Issues closed since the last release
        * Issues opened since the last release
#>
task CreateChangelogEntry SetVersion, {
    # In theory we should never be able to get here but just in case...
    if ($script:CurrentVersion -eq $script:NewVersion)
    {
        throw 'Current version and new version are the same, cannot create changelog entry'
    }
    Write-Build White "Creating new changelog entry for '$script:NewVersion'"
    $NewChangelogEntryParams = @{
        Version         = $script:NewVersion
        RepositoryOwner = $GitHubRepoOwner
        RepositoryName  = $GitHubRepoName
        ChangelogObject = $script:Changelog
        SinceVersion    = $script:CurrentVersion
    }
    if ($GitHubStageReleaseToken)
    {
        $NewChangelogEntryParams.Add('Auto', $true)
        $NewChangelogEntryParams.Add('GitHubToken', $GitHubStageReleaseToken)
    }
    else
    {
        # TODO: in future it might be nice to have a provision for providing manual release notes
        throw 'GitHub token not provided, cannot generate release notes'
    }
    try
    {
        $script:NewReleaseNotes = New-BrownserveChangelogEntry @NewChangelogEntryParams
    }
    catch
    {
        throw "Failed to update changelog. `n$($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Updates the changelog with the new release notes.
.DESCRIPTION
    This task should only be run as part of the StageRelease task.
#>
task UpdateChangelog CreateChangelogEntry, {
    Write-Build White 'Updating changelog'
    try
    {
        $script:Changelog | Add-BrownserveChangelogEntry `
            -NewContent $script:NewReleaseNotes `
            -ErrorAction 'Stop'
    }
    catch
    {
        throw "Failed to update changelog. `n$($_.Exception.Message)"
    }
    $script:TrackedFiles += ($script:ChangelogPath | Convert-Path)
}

<#
.SYNOPSIS
    Removes characters from the release notes that may make things sad
.DESCRIPTION
    A previous run of the StageRelease task will have generated the release notes and stored them in the changelog which
    we will have read in to the $script:LastRelease.ReleaseNotes variable at the beginning of the build.
    This task will remove any characters that may cause issues with our various endpoints.
#>
task FormatReleaseNotes SetVersion, {
    Write-Build White 'Formatting release notes.'
    $script:ReleaseNotes = $script:LastRelease.ReleaseNotes | Out-String
    if (!$script:ReleaseNotes)
    {
        throw 'Release notes missing'
    }
    try
    {
        $script:CleanReleaseNotes = Remove-Markdown -String $script:ReleaseNotes -ErrorAction 'Stop'
    }
    catch
    {
        throw "Failed to remove markdown from release notes. `n$($_.Exception.Message)"
    }
    # Filter out characters that'll break the XML and/or just generally look horrible in NuGet
    $script:CleanReleaseNotes = $script:CleanReleaseNotes -replace '"', '\"' -replace '`', '' -replace '\*', ''
    Write-Debug "Release notes for $($Global:BuildVersion):`n$script:CleanReleaseNotes"
}

<#
.SYNOPSIS
    Creates a new branch for staging the release
.DESCRIPTION
    Before we perform a release we need to ensure the changelog is updated.
    As we can't push to the main branch we need to create a new branch to stage the release and submit a PR.
    This is helpful as we can review everything before we actually release it.
    The branch name is determined by the version number.
    For example if we're releasing version 1.0.0 then the branch name will be 'release/1.0.0'
#>
task CreateStagingBranch SetVersion, {
    $Script:StagingBranchName = "release/$script:PrefixedVersion"
    Write-Build White "Creating branch: $Script:StagingBranchName"
    try
    {
        New-GitHubBranch `
            -RepositoryOwner $GitHubRepoOwner `
            -RepositoryName $GitHubRepoName `
            -BranchName $Script:StagingBranchName `
            -SHA $script:CurrentCommitHash `
            -Token $GitHubStageReleaseToken `
            -ErrorAction 'Stop'
    }
    catch
    {
        throw "Failed to create branch '$Script:StagingBranchName'.`n$($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Commits any (expected) changes made during the build
.DESCRIPTION
    Sometimes we expect some files to get modified during certain builds.
    For example when we update the changelog before a release.
    We want to commit those changes so they get included in the release. (and don't fail the build later on)
#>
task CommitTrackedChanges UpdateChangelog, CreateStagingBranch, Stage, {
    $CommitMessage = "docs: Prepare for $script:PrefixedVersion`n`nThis commit was automatically generated."
    if ($script:TrackedFiles.Count -gt 0)
    {
        Write-Build White 'Committing tracked changes'
        try
        {
            $Files = $script:TrackedFiles | ForEach-Object {
                @{
                    Path    = [System.IO.Path]::GetRelativePath($Global:BrownserveRepoRootDirectory, $_).Replace('\', '/')
                    Content = Get-Content -Path $_ -Raw
                }
            }
            New-GitHubCommit `
                -RepositoryOwner $GitHubRepoOwner `
                -RepositoryName $GitHubRepoName `
                -BranchName $Script:StagingBranchName `
                -CommitMessage $CommitMessage `
                -Files $Files `
                -Token $GitHubStageReleaseToken `
                -ErrorAction 'Stop'
        }
        catch
        {
            throw $_.Exception.Message
        }
    }
    else
    {
        Write-Verbose 'No tracked files to commit.'
    }
}

<#
.Synopsis
    Checks for uncommitted changes and fails the build if any are found
.DESCRIPTION
    As part of the build process we create/modify several files, including the changelog.
    We want to make sure that we don't end up with any of these files ending up not being committed to the
    repository, so we check for them.
    !! WARNING this task doesn't have any dependencies as it would potentially trigger running tasks on builds
    !! where they should not be running, therefore placement of this task in the pipeline needs to be carefully considered
#>
task CheckForUncommittedChanges {
    Write-Build White 'Checking for uncommitted changes'
    $Status = Get-GitChanges
    if ($Status)
    {
        throw "The build has resulted in uncommitted changes being produced: `n$($Status.Source -join "`n")"
    }
}

<#
.SYNOPSIS
    Creates a PR for merging the staging release branch into the default branch
.DESCRIPTION
    When staging a release we'll need to create a pull request with our staged changelog changes to bring
    them into main ready for release.
#>
task CreatePullRequest CommitTrackedChanges, {
    Write-Build White 'Creating pull request'
    try
    {
        $Body = @'
This PR was automatically generated.
Please review the changes and merge if they look good.
'@
        $PullRequestParams = @{
            BaseBranch      = $DefaultBranch
            HeadBranch      = $script:StagingBranchName
            Title           = "Prepare for $script:PrefixedVersion"
            Body            = $Body
            GitHubToken     = $GitHubStageReleaseToken
            RepositoryName  = $GitHubRepoName
            RepositoryOwner = $GitHubRepoOwner
        }
        $PRDetails = New-GitHubPullRequest @PullRequestParams
        $script:PRLink = $PRDetails.html_url
        Write-Debug "PRLink: $script:PRLink"
    }
    catch
    {
        throw "Failed to create pull request.`n$($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Creates (or reuses) a draft GitHub release for the version being released.
.DESCRIPTION
    We create the release as a draft, and component publisher tasks upload their assets to it, so that if
    anything fails part way through we're left with a mutable draft rather than a locked, published release.
    Re-running the build for the same commit reuses the existing draft rather than failing, so a partially
    completed release can be resumed. If the draft was created for a different commit, or a published
    (non-draft) release already exists for this version, the build fails before anything is published.
#>
task CreateDraftRelease SetVersion, FormatReleaseNotes, {
    if ('GitHub' -notin $PublishTo)
    {
        Write-Verbose 'GitHub not targeted, skipping draft release creation...'
        return
    }
    Write-Build White 'Checking for existing GitHub releases'
    $ExistingReleases = Invoke-BrownserveRetry -ScriptBlock {
        Get-GitHubRelease `
            -GitHubToken $GitHubReleaseToken `
            -RepoName $GitHubRepoName `
            -GitHubOrg $GitHubRepoOwner
    }
    $ExistingRelease = $ExistingReleases | Where-Object { $_.tag_name -eq $script:PrefixedVersion }
    if ($ExistingRelease)
    {
        if ($ExistingRelease.draft -eq $false)
        {
            throw "There already appears to be a published $script:PrefixedVersion release!"
        }
        if ($ExistingRelease.target_commitish -and ($ExistingRelease.target_commitish -ne $script:CurrentCommitHash))
        {
            $Message = "The existing draft release for $script:PrefixedVersion targets commit '$($ExistingRelease.target_commitish)' but this build is running from '$script:CurrentCommitHash'. Refusing to continue as this looks like a different set of changes."
            throw $Message
        }
        Write-Build White "Reusing existing draft release for $script:PrefixedVersion"
        $script:ReleaseResponse = $ExistingRelease
    }
    else
    {
        Write-Build White "Creating draft GitHub release $script:PrefixedVersion"
        $script:ReleaseResponse = Invoke-BrownserveRetry -ScriptBlock {
            New-GitHubRelease `
                -Name $script:PrefixedVersion `
                -Tag $script:PrefixedVersion `
                -Description $script:CleanReleaseNotes `
                -GitHubToken $GitHubReleaseToken `
                -RepositoryName $GitHubRepoName `
                -RepositoryOwner $GitHubRepoOwner `
                -TargetCommit $script:CurrentCommitHash `
                -Prerelease:$script:PreRelease `
                -Draft
        }
    }
}

<#
.SYNOPSIS
    Verifies every expected release asset was published, then marks the release as no longer a draft.
.DESCRIPTION
    This is the last task to run as part of a release. It only runs after every Publish contribution has
    succeeded, so a failed publisher will have already stopped the build before we get here. It re-checks
    the release's assets against $script:ExpectedReleaseAssets (populated by publisher task files) before
    publishing, so we never mark a release live with assets missing.
#>
task FinaliseRelease SetVersion, {
    if ('GitHub' -notin $PublishTo)
    {
        Write-Verbose 'GitHub not targeted, skipping release finalisation...'
        return
    }
    if (!$script:ReleaseResponse)
    {
        throw 'No draft release found to finalise. Did CreateDraftRelease run?'
    }
    Write-Build White "Verifying release assets for $script:PrefixedVersion"
    $CurrentReleases = Invoke-BrownserveRetry -ScriptBlock {
        Get-GitHubRelease `
            -GitHubToken $GitHubReleaseToken `
            -RepoName $GitHubRepoName `
            -GitHubOrg $GitHubRepoOwner
    }
    $CurrentRelease = $CurrentReleases | Where-Object { $_.tag_name -eq $script:PrefixedVersion }
    if (!$CurrentRelease)
    {
        throw "Unable to find the draft release for $script:PrefixedVersion"
    }
    $UploadedAssetNames = @($CurrentRelease.assets | Select-Object -ExpandProperty name)
    $MissingAssets = @($script:ExpectedReleaseAssets | Where-Object { $_ -notin $UploadedAssetNames })
    if ($MissingAssets.Count -gt 0)
    {
        throw "Release $script:PrefixedVersion is missing expected asset(s): $($MissingAssets -join ', ')"
    }
    Write-Build White "Publishing release $script:PrefixedVersion"
    Invoke-BrownserveRetry -ScriptBlock {
        Update-GitHubRelease `
            -ReleaseId $CurrentRelease.id `
            -RepositoryName $GitHubRepoName `
            -RepositoryOwner $GitHubRepoOwner `
            -Token $GitHubReleaseToken `
            -Draft $false `
            -ErrorAction 'Stop'
    } | Out-Null
}

<#
.SYNOPSIS
    Performs tests on the repository
.DESCRIPTION
    We use Pester to test that every task file parses cleanly and passes PSScriptAnalyzer, along with any other
    tests in the 'tests' directory. This task will fail the build if any of them fail.
#>
task Tests -Before Test {
    Write-Build Yellow 'Performing unit testing, this may take a while...'
    $Results = Invoke-Pester -Path $Global:BrownserveRepoTestsDirectory -PassThru
    assert ($results.FailedCount -eq 0) "$($results.FailedCount) test(s) failed."
}

<#
    Below are the anchor and meta tasks that compose a build.
    Anchor tasks (Build, Test, Check, Package, Stage, Publish) are intentionally empty; component task files
    attach their own tasks to them with Invoke-Build's -Before/-After parameters.
    Meta tasks are the tasks that build.ps1 passes to Invoke-Build via -Task.
    !! BE VERY CAREFUL WITH THE ORDERING !!
#>

<#
.SYNOPSIS
    Anchor and meta task for building the repository.
.DESCRIPTION
    Component build tasks attach themselves here (e.g. `task CargoBuild -Before Build`).
    There is nothing to build in this repository itself, so this task is just the anchor.
#>
task Build {}

<#
.SYNOPSIS
    Anchor task for running tests.
.DESCRIPTION
    Component test tasks attach themselves here. The generic 'Tests' task (Pester over
    $Global:BrownserveRepoTestsDirectory) always attaches to this anchor.
#>
task Test {}

<#
.SYNOPSIS
    Anchor task for static/validation checks (e.g. linting) that aren't covered by 'Test'.
.DESCRIPTION
    Component task files attach any additional validation they need here.
#>
task Check {}

<#
.SYNOPSIS
    Anchor task for producing publishable artifacts (e.g. a NuGet package, a container image).
.DESCRIPTION
    Component task files attach their packaging tasks here (e.g. `task PackNuGetPackage -Before Package`).
#>
task Package {}

<#
.SYNOPSIS
    Anchor task for contributions that need to happen before a release is staged (e.g. bumping a version
    file that lives outside the changelog).
.DESCRIPTION
    Component task files attach their staging tasks here. Everything attached to this anchor completes
    before CommitTrackedChanges runs, so their changes are included in the staging commit.
#>
task Stage {}

<#
.SYNOPSIS
    Anchor task for publishing artifacts to their destinations.
.DESCRIPTION
    Component task files attach their publish tasks here (e.g. `task PublishToNuGet -Before Publish`).
    This runs between CreateDraftRelease and FinaliseRelease, so publishers can upload assets to the
    draft release before it's marked live.
#>
task Publish {}

<#
.SYNOPSIS
    Meta task for building and testing the repository.
.DESCRIPTION
    This task performs the same actions as the previous task but also performs unit tests.
    This task is best used to thoroughly test any changes before committing them.
#>
task BuildAndTest Build, Test, {}

<#
.SYNOPSIS
    Meta task for building and testing the repository, then finally confirming there are no uncommitted changes.
.DESCRIPTION
    This is the build we use for our pull_request CI pipeline and as such must pass before we can merge any changes.
#>
task BuildTestAndCheck BuildAndTest, Check, CheckForUncommittedChanges, {}

<#
.SYNOPSIS
    Meta task that prepares the package for release.
.DESCRIPTION
    This task will update the changelog with the new version, run any component staging contributions,
    commit those changes to a new branch and then create a pull request for merging the changes into the
    default branch. This allows us to review the changes and make any adjustments before we actually
    release them. We use this task in the stage_release CI pipeline.
#>
task StageRelease CheckStagingParameters, SetStagingVariables, CreateChangelogEntry, UpdateChangelog, CreateStagingBranch, CommitTrackedChanges, CreatePullRequest, {
    $BuildMessage = @"
The release has been successfully staged and a pull request has been created.
Please review the changes at $script:PRLink and merge if they look good.
If you need to make any changes please do so on the $script:StagingBranchName branch.
"@
    Write-Build Green $BuildMessage
}

<#
.SYNOPSIS
    Meta task that stops just short of actually pushing a release
.DESCRIPTION
    This task will perform all the tasks required to release the package (including packaging) but will not
    publish or otherwise change any remote release state. This is useful for testing the release process
    without actually releasing anything.
#>
task DryRun SetReleaseVariables, CheckPublishingParameters, BuildAndTest, Package, CheckForUncommittedChanges, {}

<#
.SYNOPSIS
    Meta task that performs a release of the package.
.DESCRIPTION
    For a release the package is built, tested, packaged and then published to the various endpoints via
    the Publish anchor, with the GitHub release only marked live once every publisher has succeeded.
    Unlike other tasks the version number is not updated as part of the build as we expect it to already be
    set in the changelog. We use this task in the release CI pipeline.
    Re-running this task for the same commit resumes a partially completed release: the draft is reused,
    already-published endpoints are skipped by their own idempotency checks, and only missing assets are
    uploaded.
#>
task Release CheckPublishingParameters, SetReleaseVariables, BuildAndTest, Package, CheckForUncommittedChanges, CreateDraftRelease, Publish, FinaliseRelease, {}
