<#
.SYNOPSIS
    Invoke-Build tasks for packaging and publishing a content-only NuGet package.
.DESCRIPTION
    Attaches to the anchors defined in ReleaseLifecycle.tasks.ps1: packing attaches to 'Package', and
    publishing (pushing to NuGet feeds and uploading the .nupkg as a GitHub release asset) attaches to
    'Publish'. ReleaseLifecycle.tasks.ps1 must be dot-sourced first, as this file depends on tasks, script
    variables (e.g. $script:PrefixedVersion, $script:ExpectedReleaseAssets) and the Invoke-BrownserveRetry
    helper it defines.
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

    # GitHub token used during the Release build, needed to upload the nupkg as a release asset, must have
    # the following permissions:
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
# Set up a bunch of variables that we'll use through the build
$script:TasksSourceDirectory = Join-Path $Global:BrownserveRepoRootDirectory 'tasks' | Convert-Path
$script:NugetPackageDirectory = Join-Path $global:BrownserveRepoBuildOutputDirectory 'NuGetPackage'
$script:NuspecPath = Join-Path $script:NugetPackageDirectory "$PackageId.nuspec"
if (!$script:ExpectedReleaseAssets)
{
    $script:ExpectedReleaseAssets = @()
}

# On non-windows platforms mono is required to run NuGet 🤢
$NugetCommand = 'nuget'
if (-not $isWindows)
{
    $NugetCommand = 'mono'
}

<#
.SYNOPSIS
    Checks that all the required parameters for publishing to NuGet feeds have been provided.
#>
task CheckNuGetPublishingParameters {
    if ('nuget' -in $PublishTo)
    {
        if (!$NugetFeedApiKey)
        {
            throw 'NugetFeedApiKey not provided'
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
    Creates a temporary nuget.config that contains any custom feeds we want to publish to
.DESCRIPTION
    In case we want to publish the package to any custom/private NuGet feeds we need to create a temporary nuget.config file.
    This stops us from polluting the nuget.config file in the repo and avoids any potential issues with committing secrets.
#>
task CreateTemporaryNugetConfig {
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
    Checks for a previously published stable NuGet release that would conflict with a pre-release.
.DESCRIPTION
    Pre-releases must be published before their stable counterpart, so we still fail the whole run if we're
    about to publish a pre-release for a version that already has a stable release on NuGet.
    Whether an exact version has already been published is no longer checked here: that's handled per
    publisher (PublishToNuGet skips a version that's already there instead of failing the run).
#>
task CheckPreviousReleases SetVersion, {
    if (('nuget' -in $PublishTo) -and ($script:PreRelease -eq $true))
    {
        Write-Verbose 'Checking pre-release/stable ordering on NuGet'
        $CurrentReleases = Invoke-BrownserveRetry -ScriptBlock {
            Find-Package `
                -Name $PackageId `
                -Source 'https://nuget.org/api/v2' `
                -AllVersions `
                -AllowPrereleaseVersions `
                -ErrorAction SilentlyContinue # We don't care if this fails, we'll just assume there's no previous release
        }
        $semver = [semver]$Global:BuildVersion
        $StableBaseVersion = "$($semver.Major).$($semver.Minor).$($semver.Patch)"
        if ($CurrentReleases.Version -contains $StableBaseVersion)
        {
            throw "Cannot publish pre-release '$Global:BuildVersion' to NuGet: stable version '$StableBaseVersion' already exists. Pre-releases must be published before their stable counterpart."
        }
    }
} -Before Package

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
} -Before Package

<#
.SYNOPSIS
    Pushes the NuGet package to nuget.org and/or any configured custom NuGet feeds.
.DESCRIPTION
    Both pushes are idempotent: nuget.org uses '-SkipDuplicate' and custom feeds use '--skip-duplicate', so
    re-running a Release that already pushed successfully doesn't fail the second time round.
    Network calls go through Invoke-BrownserveRetry so transient failures (timeouts, HTTP 5xx, rate limiting)
    are retried automatically.
#>
task PublishToNuGet CheckNuGetPublishingParameters, CreateTemporaryNugetConfig, PackNuGetPackage, {
    # Only push to nuget if we want to
    if ('nuget' -in $PublishTo)
    {
        $NugetArguments = @(
            'push',
            $script:nupkgPath,
            '-Source',
            'nuget',
            '-ApiKey',
            $NugetFeedApiKey,
            '-SkipDuplicate'
        )
        if (-not $isWindows)
        {
            $NugetArguments = @($Global:BrownserveNugetPath) + $NugetArguments
        }
        Write-Build White 'Pushing to nuget'
        # Be careful - Invoke-BuildExec requires curly braces to be on the same line!
        Invoke-BrownserveRetry -ScriptBlock { exec { & $NugetCommand $NugetArguments } }
    }
    else
    {
        Write-Verbose 'nuget not targetted, skipping...'
    }

    if ('CustomNugetFeeds' -in $PublishTo)
    {
        Write-Build White 'Pushing to custom NuGet feeds'
        $CustomNugetFeeds | ForEach-Object {
            $FeedName = $_.Name
            Write-Verbose "Pushing to custom NuGet feed $FeedName"
            $NugetArguments = @(
                'nuget',
                'push',
                '--source',
                $FeedName,
                '--api-key',
                'AnyRandomString',
                '--skip-duplicate',
                $script:nupkgPath
            )
            # Rather stupidly `nuget push` doesn't support the `-configfile` parameter so we need to change into the directory
            # where our nuget.config file is stored
            # https://github.com/NuGet/Home/issues/4879
            try
            {
                Push-Location
                Set-Location $Global:BrownserveRepoBuildOutputDirectory

                Invoke-BrownserveRetry -ScriptBlock {
                    & dotnet $NugetArguments
                    if ($LASTEXITCODE -ne 0)
                    {
                        throw "Failed to push to custom NuGet feed $FeedName."
                    }
                }
            }
            catch
            {
                throw "Failed to push to custom NuGet feed $FeedName.`n$($_.Exception.Message)"
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
} -Before Publish

<#
.SYNOPSIS
    Uploads the .nupkg as an asset on the draft GitHub release.
.DESCRIPTION
    Registers the .nupkg as an expected release asset so FinaliseRelease refuses to publish the release
    without it. Skips the upload if an asset with the same name and size is already present on the draft,
    so re-running a Release that already uploaded the asset doesn't fail or duplicate it.
#>
task UploadNuGetPackageReleaseAsset CreateDraftRelease, PackNuGetPackage, {
    if ('GitHub' -notin $PublishTo)
    {
        Write-Verbose 'GitHub not targeted, skipping release asset upload...'
        return
    }
    if (!$script:ReleaseResponse)
    {
        throw 'No draft release to upload the NuGet package to.'
    }
    if (!$script:nupkgPath)
    {
        Write-Verbose 'No nupkg was built, skipping release asset upload...'
        return
    }
    $AssetName = Split-Path $script:nupkgPath -Leaf
    $script:ExpectedReleaseAssets += $AssetName
    $ExistingAsset = $script:ReleaseResponse.assets | Where-Object { $_.name -eq $AssetName }
    $LocalSize = (Get-Item $script:nupkgPath).Length
    if ($ExistingAsset -and ($ExistingAsset.size -eq $LocalSize))
    {
        Write-Verbose "Asset '$AssetName' already uploaded with a matching size, skipping."
        return
    }
    Write-Build White "Uploading '$AssetName' as release asset"
    Invoke-BrownserveRetry -ScriptBlock {
        Add-GitHubReleaseAsset `
            -UploadUrl $script:ReleaseResponse.upload_url `
            -Token $GitHubReleaseToken `
            -FilePath $script:nupkgPath `
            -ErrorAction 'Stop'
    } | Out-Null
} -Before Publish
