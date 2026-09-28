<#
.SYNOPSIS
    This contains the build tasks for Invoke-Build to use.
    Each task is documented with a synopsis and description to explain what it does.
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
# Set up a bunch of variables that we'll use through the build, some of these are global as they're used in our tests too
$script:TasksSourceDirectory = Join-Path $Global:BrownserveRepoRootDirectory 'tasks' | Convert-Path
# Depending on how we got the branch name we may need to remove the full ref
$BranchName = $BranchName -replace 'refs\/heads\/', ''
$script:CurrentCommitHash = & git rev-parse HEAD
$script:ChangelogPath = Join-Path $Global:BrownserveRepoRootDirectory -ChildPath 'CHANGELOG.md'
$script:NugetPackageDirectory = Join-Path $global:BrownserveRepoBuildOutputDirectory 'NuGetPackage'
$script:NuspecPath = Join-Path $script:NugetPackageDirectory "$PackageId.nuspec"
$script:GitHubRepoURI = "https://github.com/$GitHubRepoOwner/$GitHubRepoName"
$script:TrackedFiles = @()

<#
    Work out if this is a production release depending on the branch we're building from
    We default to $true unless we detect that we're running on the default branch, as anything that is in the default
    branch should be the one to build shipped versions of the code.
    This should ensure that:
        * Main can never be used a prerelease tag
        * Feature branches cannot ever create a production release
    NOTE: this does not affect releases - there is different logic for that later on.
#>
$PreRelease = $true
if ($DefaultBranch -eq $BranchName)
{
    $PreRelease = $false
}

# On non-windows platforms mono is required to run NuGet 🤢
$NugetCommand = 'nuget'
if (-not $isWindows)
{
    $NugetCommand = 'mono'
}

# BuildTask is a variable that is set by Invoke-Build to indicate the build task that has been called
# it might be useful to have specific logic for certain tasks
switch ($BuildTask)
{
    default {}
}

<#
.SYNOPSIS
    Checks that all the required parameters for publishing a release have been provided.
#>
task CheckPublishingParameters {
    if ('nuget' -in $PublishTo)
    {
        if (!$NugetFeedApiKey)
        {
            throw 'NugetFeedApiKey not provided'
        }
    }

    if ('GitHub' -in $PublishTo)
    {
        if (!$GitHubReleaseToken)
        {
            throw 'GitHubReleaseToken not provided'
        }
    }

    if ('CustomNugetFeeds' -in $PublishTo)
    {
        if (!$CustomNugetFeeds)
        {
            throw 'CustomNugetFeeds not provided'
        }
        $CustomNugetFeeds | ForEach-Object {
            if ((-not $_.Name) -or (-not $_.Url) -or (-not $_.Credential))
            {
                throw 'CustomNugetFeeds must contain Name, Url and Credential'
            }
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
        if ($PreRelease)
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
    Write-Build Magenta "Building version $script:PrefixedVersion of $PackageId"
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
    Creates a temporary nuget.config that contains any custom feeds we want to publish to
.DESCRIPTION
    In case we want to publish the package to any custom/private NuGet feeds we need to create a temporary nuget.config file.
    This stops us from polluting the nuget.config file in the repo and avoids any potential issues with committing secrets.
#>
task CreateTemporaryNugetConfig CheckPublishingParameters, {
    if ('CustomNugetFeeds' -in $PublishTo)
    {
        Write-Build White 'Creating temporary nuget.config for custom feeds'

        # First create the nuget.config file in the build output directory, we don't want to commit this to the repo as we'll be storing the password in it
        $newNugetConfig = @(
            'new',
            'nugetconfig',
            '-o',
            $Global:BrownserveRepoBuildOutputDirectory
        )
        # N.B. 'dotnet' must be a string while the params must be an array
        exec {
            & dotnet $newNugetConfig
        }

        # Then go through and add the feeds to the nuget.config file
        $CustomNugetFeeds | ForEach-Object {
            $nugetConfigPath = Join-Path $Global:BrownserveRepoBuildOutputDirectory 'nuget.config'
            $FeedUrl = $_.Url
            $FeedName = $_.Name
            $FeedUsername = $_.Credential.UserName
            $FeedPassword = $_.Credential.GetNetworkCredential().Password
            $addFeedParams = @(
                'nuget',
                'add',
                'source',
                $FeedUrl,
                '-n',
                $FeedName,
                '-u',
                $FeedUsername,
                '-p',
                $FeedPassword,
                '--configfile',
                $nugetConfigPath
            )
            # Encryption is only supported on Windows 😭
            if ($IsWindows -eq $false)
            {
                $addFeedParams += '--store-password-in-clear-text'
            }

            exec {
                & dotnet $addFeedParams
            }
        }
    }
}

<#
.SYNOPSIS
    Checks for previous releases to ensure we're not trying to release a version that already exists
.DESCRIPTION
    This task will check for previous releases in GitHub and NuGet.
    If a release is found with the same version number as the one we're trying to release then the build will fail.
    Even if only one of the endpoints has a release with the same version number the build will fail.
    We should be consistent across all endpoints after all.
    Checks are performed only against the endpoints defined in $PublishTo so if a new endpoint is added or you want to
    publish to an endpoint that previously failed simply exclude the others.
#>
task CheckPreviousReleases SetVersion, CreateTemporaryNugetConfig, {
    Write-Build White 'Checking for previous releases'
    if ('GitHub' -in $PublishTo)
    {
        Write-Verbose 'Checking for previous releases in GitHub'
        $CurrentReleases = Get-GitHubRelease `
            -GitHubToken $GitHubReleaseToken `
            -RepoName $GitHubRepoName `
            -GitHubOrg $GitHubRepoOwner
        if ($CurrentReleases.tag_name -contains "$script:PrefixedVersion")
        {
            throw "There already appears to be a $script:PrefixedVersion release!"
        }
    }
    if ('nuget' -in $PublishTo)
    {
        Write-Verbose 'Checking for previous releases to NuGet'
        $CurrentReleases = Find-Package `
            -Name $PackageId `
            -Source 'https://nuget.org/api/v2' `
            -AllVersions `
            -AllowPrereleaseVersions `
            -ErrorAction SilentlyContinue # We don't care if this fails, we'll just assume there's no previous release
        if ($CurrentReleases.Version -contains $Global:BuildVersion)
        {
            throw "There already appears to be a $Global:BuildVersion release!"
        }
        if ($script:PreRelease -eq $true)
        {
            $semver = [semver]$Global:BuildVersion
            $StableBaseVersion = "$($semver.Major).$($semver.Minor).$($semver.Patch)"
            if ($CurrentReleases.Version -contains $StableBaseVersion)
            {
                throw "Cannot publish pre-release '$Global:BuildVersion' to NuGet: stable version '$StableBaseVersion' already exists. Pre-releases must be published before their stable counterpart."
            }
        }
    }
    if ('CustomFeeds' -in $PublishTo)
    {
        Write-Verbose 'Checking for previous releases to custom feeds'
        $CustomNugetFeeds | ForEach-Object {
            Write-Verbose "Checking for previous releases to $($_.Name)"
            $CurrentReleases = Find-Package `
                -Name $PackageId `
                -Source $_.Url `
                -AllVersions `
                -AllowPrereleaseVersions `
                -ErrorAction SilentlyContinue # We don't care if this fails, we'll just assume there's no previous release
            if ($CurrentReleases.Version -contains $Global:BuildVersion)
            {
                throw "There already appears to be a $Global:BuildVersion release!"
            }
        }
    }
}

<#
.SYNOPSIS
    Prepares the files required to ship a NuGet package containing this repo's 'tasks' directory.
.DESCRIPTION
    Unlike a PowerShell module package, this package has no 'tools' directory. The 'tasks' directory is copied to
    the root of the package so it restores to 'packages/Brownserve.PSBuildTasks/tasks/*.tasks.ps1', which is where
    consuming repositories dot-source it from.
#>
task PrepareNuGetPackage SetVersion, FormatReleaseNotes, {
    # Each of these items will be copied to the root of the NuGet package
    $ItemsToCopy = @(
        (Join-Path $Global:BrownserveRepoRootDirectory 'CHANGELOG.md'),
        (Join-Path $Global:BrownserveRepoRootDirectory 'LICENSE'),
        (Join-Path $Global:BrownserveRepoRootDirectory 'README.md')
    )
    # Build up the nuspec file
    # PowerShell doesn't handle object -> XML very well so we'll use a here-string to build it reliably
    $Nuspec = @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2011/08/nuspec.xsd">
  <metadata>
    <id>$PackageId</id>
    <version>$Global:BuildVersion</version>
    <authors>$PackageAuthor</authors>
    <owners>Brownserve UK</owners>
    <license type="file">LICENSE</license>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <summary>$PackageDescription</summary>
    <description>$PackageDescription</description>
    <projectUrl>$script:GitHubRepoURI</projectUrl>
    <releaseNotes>$script:CleanReleaseNotes</releaseNotes>
    <readme>README.md</readme>
    <copyright>Copyright $(Get-Date -Format yyyy) Brownserve UK.</copyright>
    <tags>$($PackageTags -join ' ')</tags>
    <dependencies />
  </metadata>
</package>
"@
    if (('nuget' -in $PublishTo) -or ('GitHub' -in $PublishTo) -or ('CustomNugetFeeds' -in $PublishTo))
    {
        Write-Build White "Copying 'tasks' directory to $script:NugetPackageDirectory"
        Copy-Item $script:TasksSourceDirectory -Destination (Join-Path $script:NugetPackageDirectory 'tasks') -Recurse
        Copy-Item $ItemsToCopy -Destination $script:NugetPackageDirectory -Force
        New-Item $script:NuspecPath -Value $Nuspec -Force | Out-Null
        $script:NuspecPath = $script:NuspecPath | Convert-Path
    }
    else
    {
        Write-Verbose 'No feeds targetted, skipping...'
    }
}

<#
.SYNOPSIS
    Packs the nuget package ready for shipping off to nuget.org (or a private feed)
.DESCRIPTION
    Runs `nuget pack` to create a NuGet package of the 'tasks' directory.
    We upload this to both nuget.org _and_ GitHub as a release asset so we need to make sure we do this if either is
    targetted
#>
task PackNuGetPackage PrepareNuGetPackage, {
    if (('nuget' -in $PublishTo) -or ('GitHub' -in $PublishTo) -or ('CustomNugetFeeds' -in $PublishTo))
    {
        Write-Build White 'Packing NuGet package'
        exec {
            # Note: the paths must be a separate index to the switch in the array
            $NugetArguments = @(
                'pack',
                "$script:NuspecPath",
                '-NoPackageAnalysis',
                '-Version',
                "$Global:BuildVersion",
                '-OutputDirectory',
                "$script:NugetPackageDirectory"
            )
            # On *nix we need to use mono to invoke nuget, so fudge the arguments a bit
            if (-not $isWindows)
            {
                # Mono won't have access to our NuGet PowerShell alias, so set the path using our env var
                $NugetArguments = @($Global:BrownserveNugetPath) + $NugetArguments
            }
            & $NugetCommand $NugetArguments
        }
        $script:nupkgPath = Join-Path $script:NugetPackageDirectory "$PackageId.$global:BuildVersion.nupkg" | Convert-Path
    }
    else
    {
        Write-Verbose 'No feeds require a NuGet package, skipping...'
    }
}

<#
.SYNOPSIS
    Publishes the new release to the various endpoints
.DESCRIPTION
    This task pushes the release up to the various endpoints we target.
    Endpoints can be configured in the $PublishTo parameter
#>
task PublishRelease CheckPreviousReleases, Tests, PackNuGetPackage, CheckForUncommittedChanges, {
    # Only push to nuget if we want to
    if ('nuget' -in $PublishTo)
    {
        $NugetArguments = @(
            'push',
            $script:nupkgPath,
            '-Source',
            'nuget',
            '-ApiKey',
            $NugetFeedApiKey
        )
        if (-not $isWindows)
        {
            $NugetArguments = @($Global:BrownserveNugetPath) + $NugetArguments
        }
        Write-Build White 'Pushing to nuget'
        # Be careful - Invoke-BuildExec requires curly braces to be on the same line!
        exec { & $NugetCommand $NugetArguments }
    }
    else
    {
        Write-Verbose 'nuget not targetted, skipping...'
    }

    if ('CustomNugetFeeds' -in $PublishTo)
    {
        Write-Build White 'Pushing to custom NuGet feeds'
        $CustomNugetFeeds | ForEach-Object {
            Write-Verbose "Pushing to custom NuGet feed $($_.Name)"
            $NugetArguments = @(
                'nuget',
                'push',
                '--source',
                $_.Name,
                '--api-key',
                'AnyRandomString',
                $script:nupkgPath
            )
            # Rather stupidly `nuget push` doesn't support the `-configfile` parameter so we need to change into the directory
            # where our nuget.config file is stored
            # https://github.com/NuGet/Home/issues/4879
            try
            {
                Push-Location
                Set-Location $Global:BrownserveRepoBuildOutputDirectory

                & dotnet $NugetArguments
                if ($LASTEXITCODE -ne 0)
                {
                    throw "Failed to push to custom NuGet feed $($_.Name)."
                }
            }
            catch
            {
                throw "Failed to push to custom NuGet feed $($_.Name).`n$($_.Exception.Message)"
            }
            finally
            {
                Pop-Location
            }
        }
    }
    else
    {
        Write-Verbose 'Custom NuGet feeds not targeted, skipping...'
    }

    if ('GitHub' -in $PublishTo)
    {
        Write-Build White "Creating GitHub release for $Global:BuildVersion"
        $ReleaseParams = @{
            Name        = $script:PrefixedVersion
            Tag         = $script:PrefixedVersion
            Description = $script:ReleaseNotes
            GitHubToken = $GitHubReleaseToken
            RepoName    = $GitHubRepoName
            GitHubOrg   = $GitHubRepoOwner
        }
        if ($PreRelease -eq $true)
        {
            $ReleaseParams.Add('Prerelease', $true)
            $ReleaseParams.Add('TargetCommit', $script:CurrentCommitHash)
        }
        $ReleaseResponse = New-GitHubRelease @ReleaseParams

        if ($script:nupkgPath)
        {
            Write-Build White 'Uploading nupkg as release asset'
            Add-GitHubReleaseAsset `
                -UploadUrl $ReleaseResponse.upload_url `
                -Token $GitHubReleaseToken `
                -FilePath $script:nupkgPath `
                -ErrorAction 'Stop'
        }
    }
    else
    {
        Write-Verbose 'GitHub not targetted, skipping...'
    }
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
task CommitTrackedChanges UpdateChangelog, CreateStagingBranch, {
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
    Performs tests on the repository
.DESCRIPTION
    We use Pester to test that every task file parses cleanly and passes PSScriptAnalyzer, along with any other
    tests in the 'tests' directory. This task will fail the build if any of them fail.
#>
task Tests {
    Write-Build Yellow 'Performing unit testing, this may take a while...'
    $Results = Invoke-Pester -Path $Global:BrownserveRepoTestsDirectory -PassThru
    assert ($results.FailedCount -eq 0) "$($results.FailedCount) test(s) failed."
}

<#
    Below are the meta tasks that we use to build the package.
    These are the tasks that we'll actually call run this script via Invoke-Build.
    Dependent tasks will be run in the order they're defined.
    !! BE VERY CAREFUL WITH THE ORDERING !!
#>

<#
.SYNOPSIS
    Meta task for building the repository.
.DESCRIPTION
    There is no compilation step for this repository, so this task is a base for other tasks to depend on.
#>
task Build {}

<#
.SYNOPSIS
    Meta task for building and testing the repository.
.DESCRIPTION
    This task performs the same actions as the previous task but also performs unit tests.
    This task is best used to thoroughly test any changes before committing them.
#>
task BuildAndTest Build, Tests, {}

<#
.SYNOPSIS
    Meta task for building and testing the repository, then finally confirming there are no uncommitted changes.
.DESCRIPTION
    This is the build we use for our pull_request CI pipeline and as such must pass before we can merge any changes.
#>
task BuildTestAndCheck BuildAndTest, CheckForUncommittedChanges, {}

<#
.SYNOPSIS
    Meta task that prepares the package for release.
.DESCRIPTION
    This task will update the changelog with the new version, commit those changes to a
    new branch and then create a pull request for merging the changes into the default branch.
    This allows us to review the changes and make any adjustments before we actually release them.
    We use this task in the stage_release CI pipeline.
#>
task StageRelease CheckStagingParameters, SetStagingVariables, CreateChangelogEntry, UpdateChangelog, CreatePullRequest, {
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
    This task will perform all the tasks required to release the package but will not actually push the release to the
    various endpoints.
    This is useful for testing the release process without actually releasing anything.
#>
task DryRun SetReleaseVariables, CheckPublishingParameters, CheckPreviousReleases, Tests, PackNuGetPackage, CheckForUncommittedChanges, {}

<#
.SYNOPSIS
    Meta task that performs a release of the package.
.DESCRIPTION
    For a release the package is built, tested and then published to the various endpoints.
    Unlike other tasks the version number is not updated as part of the build as we expect it to already be set in the
    changelog.
    We use this task in the release CI pipeline.
#>
task Release CheckPublishingParameters, SetReleaseVariables, BuildAndTest, PublishRelease, {}
