<#
.SYNOPSIS
    Invoke-Build tasks for building, documenting and releasing a Brownserve PowerShell module.
.DESCRIPTION
    Attaches to the anchors defined in ReleaseLifecycle.tasks.ps1: the module manifest build attaches to
    'Build', documentation regeneration attaches to 'Stage' (and, via CreateModuleHelp, runs before the
    generic 'Tests' task), and the NuGet/PSGallery/GitHub/custom feed publishers attach to 'Publish'.
    This file ships its own NuGet packaging tasks under distinct names; it does not reuse
    NuGetPackage.tasks.ps1. ReleaseLifecycle.tasks.ps1 must be dot-sourced first, as this file depends on
    tasks, script variables (e.g. $script:PrefixedVersion, $script:ExpectedReleaseAssets) and the
    Invoke-BrownserveRetry helper it defines.
#>
[CmdletBinding()]
param
(
    # The name of the PowerShell module being built
    [Parameter(
        Mandatory = $true
    )]
    [string]
    $ModuleName,

    # The GUID of the module
    [Parameter(
        Mandatory = $true
    )]
    [guid]
    $ModuleGUID,

    # The description of the module
    [Parameter(
        Mandatory = $true
    )]
    [string]
    $ModuleDescription,

    # The author of the module
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $ModuleAuthor = 'Brownserve UK',

    # Any tags to add to the module
    [Parameter(
        Mandatory = $false
    )]
    [string[]]
    $ModuleTags = 'brownserve-UK',

    # The various places to publish to
    [Parameter(
        Mandatory = $false
    )]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('nuget', 'PSGallery', 'GitHub', 'CustomNugetFeeds')]
    [string[]]
    $PublishTo,

    # The GitHub organisation/account to publish the release to
    [Parameter(
        Mandatory = $true
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepoOwner,

    # The GitHub repo to publish the release to
    [Parameter(
        Mandatory = $false
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepoName = $Global:BrownserveRepoName,

    # GitHub token used during the Release build, needed to upload release assets, must have the
    # following permissions:
    #   * Read/write releases
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $GitHubReleaseToken,

    # The API key to use when publishing to a NuGet feed
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $NugetFeedApiKey,

    # The API key to use when publishing to the PSGallery
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $PSGalleryAPIKey,

    # Any custom/private NuGet feeds to publish to. Each hashtable needs Name, Url, Credential and
    # PublishAs (either 'NugetPackage' or 'ModulePackage')
    [Parameter(
        Mandatory = $false
    )]
    [hashtable[]]
    $CustomNugetFeeds,

    # If set, loads the working copy of the module from the module directory at the start of the build
    # instead of the stable version restored by _init.ps1
    [Parameter(
        Mandatory = $false
    )]
    [switch]
    $UseWorkingCopy
)
$global:BrownserveBuiltModuleDirectory = Join-Path $global:BrownserveRepoBuildOutputDirectory $ModuleName
$script:NugetPackageDirectory = Join-Path $global:BrownserveRepoBuildOutputDirectory 'ModuleNuGetPackage'
$script:NuspecPath = Join-Path $script:NugetPackageDirectory "$ModuleName.nuspec"
$script:ModulePackageDirectory = Join-Path $global:BrownserveRepoBuildOutputDirectory 'ModulePackage'
$Script:ModuleNuspecPath = Join-Path $script:ModulePackageDirectory "$ModuleName.nuspec"
$Script:BuiltModulePath = Join-Path $global:BrownserveBuiltModuleDirectory "$ModuleName.psd1"
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
    Loads the working copy of the module from the module directory.
.DESCRIPTION
    By default we pull in the latest _stable_ copy of the build modules from NuGet via the _init.ps1
    script to run this build, however if we make changes to any of the cmdlets used in this build we
    won't get the changes until a new release is pushed.
    This task allows us to unload the stable version and reload the working copy of this module from the
    local copy of the repo.
#>
task UseWorkingCopy {
    if ($UseWorkingCopy -eq $true)
    {
        Write-Build White "Loading working copy of module from $Global:BrownserveModuleDirectory"
        if ((Get-Module $ModuleName))
        {
            Write-Warning "The current version of $ModuleName has been unloaded and replaced with the working copy from $Global:BrownserveModuleDirectory. `nFunctionality may be unstable"
            Remove-Module $ModuleName -Force -ErrorAction 'Stop' -Verbose:$false
        }
        Import-Module (Join-Path $Global:BrownserveModuleDirectory "$ModuleName.psm1") -Force -ErrorAction 'Stop' -Verbose:$false
    }
} -Before GetReleaseHistory, Build

<#
.SYNOPSIS
    Checks that all the required parameters for publishing this module have been provided.
#>
task CheckModulePublishingParameters {
    if ('PSGallery' -in $PublishTo)
    {
        if (!$PSGalleryAPIKey)
        {
            throw 'PSGalleryAPIKey not provided'
        }
    }
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
            if ((-not $_.Name) -or (-not $_.Url) -or (-not $_.Credential) -or (-not $_.PublishAs))
            {
                throw 'CustomNugetFeeds must contain Name, Url, Credential and PublishAs'
            }
            if (($_.PublishAs -ne 'NugetPackage') -and ($_.PublishAs -ne 'ModulePackage'))
            {
                throw 'CustomNugetFeeds PublishAs must be either NugetPackage or ModulePackage'
            }
            if ($_.PublishAs -eq 'NugetPackage')
            {
                $script:CustomNugetFeedNugetPackage = $true
            }
            else
            {
                $script:CustomNugetFeedModulePackage = $true
            }
        }
    }
}

<#
.SYNOPSIS
    Creates a temporary nuget.config that contains any custom feeds we want to publish to.
.DESCRIPTION
    In case we want to publish the module to any custom/private NuGet feeds we need to create a temporary
    nuget.config file. This stops us from polluting the nuget.config file in the repo and avoids any
    potential issues with committing secrets.
#>
task CreateModuleNugetConfig CheckModulePublishingParameters, {
    if ('CustomNugetFeeds' -in $PublishTo)
    {
        Write-Build White 'Creating temporary nuget.config for custom feeds'
        $newNugetConfig = @(
            'new',
            'nugetconfig',
            '-o',
            $Global:BrownserveRepoBuildOutputDirectory
        )
        exec {
            & dotnet $newNugetConfig
        }
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
    Checks for a previously published stable release that would conflict with a pre-release.
.DESCRIPTION
    Pre-releases must be published before their stable counterpart, so we fail the whole run if we're
    about to publish a pre-release for a version that already has a stable release on NuGet or the
    PSGallery. Whether an exact version has already been published is handled per publisher instead
    (PublishModuleToNuGet and PublishModuleToPSGallery each skip a version that's already there).
#>
task CheckPreviousModuleReleases SetVersion, CreateModuleNugetConfig, {
    if ($script:PreRelease -ne $true)
    {
        return
    }
    $semver = [semver]$Global:BuildVersion
    $StableBaseVersion = "$($semver.Major).$($semver.Minor).$($semver.Patch)"
    if ('nuget' -in $PublishTo)
    {
        Write-Verbose 'Checking pre-release/stable ordering on NuGet'
        $CurrentReleases = Invoke-BrownserveRetry -ScriptBlock {
            Find-Package `
                -Name $ModuleName `
                -Source 'https://nuget.org/api/v2' `
                -AllVersions `
                -AllowPrereleaseVersions `
                -ErrorAction SilentlyContinue
        }
        if ($CurrentReleases.Version -contains $StableBaseVersion)
        {
            throw "Cannot publish pre-release '$Global:BuildVersion' to NuGet: stable version '$StableBaseVersion' already exists. Pre-releases must be published before their stable counterpart."
        }
    }
    if ('PSGallery' -in $PublishTo)
    {
        Write-Verbose 'Checking pre-release/stable ordering on the PSGallery'
        $CurrentReleases = Invoke-BrownserveRetry -ScriptBlock {
            Find-Module `
                -Name $ModuleName `
                -Repository PSGallery `
                -AllVersions `
                -AllowPrerelease `
                -ErrorAction SilentlyContinue
        }
        if ($CurrentReleases.Version -contains $StableBaseVersion)
        {
            throw "Cannot publish pre-release '$Global:BuildVersion' to the PSGallery: stable version '$StableBaseVersion' already exists. Pre-releases must be published before their stable counterpart."
        }
    }
} -Before Package

<#
.SYNOPSIS
    Copies the module files over to the build directory.
.DESCRIPTION
    We copy the base module files over to the build directory so they can be compiled into a proper
    PowerShell module.
#>
task CopyModule {
    Write-Build White 'Copying files to build output directory'
    Copy-Item -Path $Global:BrownserveModuleDirectory -Destination $global:BrownserveBuiltModuleDirectory -Recurse -Force
}

<#
.SYNOPSIS
    Creates the PowerShell module manifest.
.DESCRIPTION
    We create the module manifest as part of every build rather than storing it permanently, as
    Update-ModuleManifest is somewhat limited for overwriting/updating options later on.
#>
task CreateModuleManifest SetVersion, FormatReleaseNotes, CopyModule, {
    Write-Build White 'Creating PowerShell module manifest'
    $PublicScripts = Get-ChildItem (Join-Path $global:BrownserveBuiltModuleDirectory 'Public') -Filter '*.ps1' -Recurse
    $PublicFunctions = $PublicScripts | ForEach-Object {
        $_.Name -replace '.ps1', ''
    }
    $ModuleManifest = @{
        Path              = $Script:BuiltModulePath
        Guid              = $ModuleGUID
        Author            = $ModuleAuthor
        Copyright         = "$(Get-Date -Format yyyy) $ModuleAuthor"
        CompanyName       = 'Brownserve UK'
        RootModule        = "$ModuleName.psm1"
        ModuleVersion     = $script:NewVersion
        Description       = $ModuleDescription
        PowerShellVersion = '6.0'
        ReleaseNotes      = $script:CleanReleaseNotes
        LicenseUri        = "$script:GitHubRepoURI/blob/main/LICENSE"
        ProjectUri        = "$script:GitHubRepoURI"
        FunctionsToExport = $PublicFunctions
    }
    if ($ModuleTags)
    {
        $ModuleManifest.Add('Tags', $ModuleTags)
    }
    if ($script:PreRelease -eq $true)
    {
        $ModuleManifest.Add('Prerelease', (([semver]$Global:BuildVersion).PreReleaseLabel))
    }
    New-ModuleManifest @ModuleManifest -ErrorAction 'Stop'
} -Before Build

<#
.SYNOPSIS
    Imports the module after building it.
.DESCRIPTION
    Once the module has been built we import it, this is needed for the tests to be able to run and to
    perform local development. We overwrite the module if it is already loaded in the current session, but
    warn the user if this happens outside of CI.
#>
task ImportModule CreateModuleManifest, {
    Write-Build White 'Importing built module'
    if ((Get-Module $ModuleName))
    {
        if (!$env:CI)
        {
            $WarningMessage = @"
The PowerShell module '$ModuleName' has been reloaded using the version built by this script.
This may mean that functionality has changed.
You may wish to run _init.ps1 again to reload the current stable version of this module.
"@
            Write-Warning $WarningMessage
        }
        Remove-Module $ModuleName -Force -Confirm:$false -Verbose:$false
    }
    Import-Module $Script:BuiltModulePath -Force -Verbose:$false
}

<#
.SYNOPSIS
    Removes stale documentation files that do not correspond to a cmdlet in this module.
.DESCRIPTION
    When two modules share the same cmdlet names, PlatyPS can pick up the wrong module from the docs
    directory and generate docs for all cmdlets in that module, polluting the docs directory with files
    that belong to the other module. This task removes any .md files in the docs directory that do not
    match a public cmdlet in this module or the module landing page (Commands.md).
#>
task CleanDocs ImportModule, {
    Write-Build White 'Cleaning documentation directory'
    $ExpectedCmdlets = Get-ChildItem -Path $Global:BrownserveModuleDirectory -Filter '*.ps1' -Recurse |
        Select-Object -ExpandProperty BaseName
    $ExpectedFiles = @('Commands.md') + ($ExpectedCmdlets | ForEach-Object { "$_.md" })
    $Stale = Get-ChildItem -Path $Global:BrownserveRepoDocsDirectory -Filter '*.md' |
        Where-Object { $_.Name -notin $ExpectedFiles }
    if ($Stale)
    {
        Write-Build Yellow "Removing $($Stale.Count) stale documentation file(s): $($Stale.Name -join ', ')"
        $Stale | Remove-Item -Force -Confirm:$false
    }
    else
    {
        Write-Build White 'Documentation directory is clean'
    }
}

<#
.SYNOPSIS
    Uses PlatyPS to generate the markdown documentation for the module.
.DESCRIPTION
    We store our modules help information in markdown files in the docs directory of the repo. This task
    also attaches to the Stage anchor and adds its output to $script:TrackedFiles, so the staging commit
    includes regenerated docs.
#>
task UpdateModuleDocumentation CleanDocs, {
    Write-Build White 'Updating markdown documentation'
    $DocsParams = @{
        ModuleName           = $ModuleName
        ModulePath           = $Script:BuiltModulePath
        DocumentationPath    = $Global:BrownserveRepoDocsDirectory
        ModuleGUID           = $ModuleGUID
        NoModuleSubdirectory = $true
    }
    if ($script:Stage -eq $true)
    {
        $DocsParams.Add('HelpVersion', $script:NewVersion)
    }
    Build-ModuleDocumentation @DocsParams | Out-Null
    $Script:ModulePagePath = Join-Path $Global:BrownserveRepoDocsDirectory 'Commands.md' | Resolve-Path
    if ($script:Stage -eq $true)
    {
        $script:TrackedFiles += ($Script:ModulePagePath | Convert-Path)
    }
} -Before Stage

<#
.SYNOPSIS
    Updates the module's MAML help.
.DESCRIPTION
    PlatyPS reads in the markdown files in the docs directory and generates a MAML help file for the
    module. This needs to be shipped with the module so PowerShell can display help for it, so we create
    it in the built module directory. Attaching -Before Tests here pulls the whole documentation chain
    (ImportModule, CleanDocs, UpdateModuleDocumentation, CreateModuleHelp) in ahead of the generic Tests
    task, regardless of which order the task files were dot-sourced in.
#>
task CreateModuleHelp UpdateModuleDocumentation, {
    Write-Build White 'Creating module MAML help'
    New-Item (Join-Path $global:BrownserveBuiltModuleDirectory 'en-US') -ItemType Directory -Force | Out-Null
    $HelpParams = @{
        ModuleDirectory   = $global:BrownserveBuiltModuleDirectory
        DocumentationPath = $global:BrownserveRepoDocsDirectory
    }
    Add-ModuleHelp @HelpParams | Out-Null
} -Before Tests

<#
.SYNOPSIS
    Compresses the module so it can be uploaded to GitHub.
.DESCRIPTION
    We don't use Compress-Archive as it doesn't behave consistently across platforms: on Linux it ignores
    "hidden" dot files and on Windows it includes them.
#>
task CompressModule CreateModuleHelp, {
    if ('GitHub' -in $PublishTo)
    {
        $script:CompressedModule = Join-Path $global:BrownserveRepoBuildOutputDirectory "$ModuleName-$($Global:BuildVersion).tgz"
        Write-Build White 'Compressing PowerShell module'
        try
        {
            [System.IO.Compression.ZipFile]::CreateFromDirectory($global:BrownserveBuiltModuleDirectory, $script:CompressedModule)
        }
        catch
        {
            throw "Failed to compress module.`n$($_.Exception.Message)"
        }
    }
    else
    {
        Write-Verbose 'GitHub not targeted, skipping creation of compressed module asset'
    }
}

<#
.SYNOPSIS
    Prepares the files required to ship a NuGet (and, for custom feeds, a module) package.
.DESCRIPTION
    We upload the standard NuGet package to both nuget.org and GitHub, so we build it if either is
    targeted. Custom feeds may additionally want the module packaged directly (module manifest at the
    package root) rather than under 'tools', so a second package is prepared when any custom feed asks
    for that via PublishAs = 'ModulePackage'.
#>
task PrepareModuleNuGetPackage SetVersion, CreateModuleManifest, FormatReleaseNotes, CreateModuleHelp, {
    $ItemsToCopy = @(
        (Join-Path $Global:BrownserveRepoRootDirectory 'CHANGELOG.md'),
        (Join-Path $Global:BrownserveRepoRootDirectory 'LICENSE'),
        (Join-Path $Global:BrownserveRepoRootDirectory 'README.md')
    )
    $Nuspec = @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2011/08/nuspec.xsd">
  <metadata>
    <id>$ModuleName</id>
    <version>$Global:BuildVersion</version>
    <authors>$ModuleAuthor</authors>
    <owners>Brownserve UK</owners>
    <license type="file">LICENSE</license>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <summary>$ModuleDescription</summary>
    <description>$ModuleDescription</description>
    <projectUrl>$script:GitHubRepoURI</projectUrl>
    <releaseNotes>$script:CleanReleaseNotes</releaseNotes>
    <readme>README.md</readme>
    <copyright>Copyright $(Get-Date -Format yyyy) Brownserve UK.</copyright>
    <tags>$($ModuleTags -join ' ')</tags>
    <dependencies />
  </metadata>
</package>
"@
    if (('nuget' -in $PublishTo) -or ('GitHub' -in $PublishTo) -or ($script:CustomNugetFeedNugetPackage -eq $true))
    {
        Write-Build White "Copying built module to $script:NugetPackageDirectory"
        Copy-Item $global:BrownserveBuiltModuleDirectory -Destination (Join-Path $script:NugetPackageDirectory 'tools') -Recurse
        Copy-Item $ItemsToCopy -Destination $script:NugetPackageDirectory -Force
        New-Item $script:NuspecPath -Value $Nuspec -Force | Out-Null
        $script:NuspecPath = $script:NuspecPath | Convert-Path
    }
    else
    {
        Write-Verbose 'No standard NuGet feeds targeted, skipping...'
    }
    if ($script:CustomNugetFeedModulePackage -eq $true)
    {
        Write-Build White "Copying built module to $script:ModulePackageDirectory"
        Copy-Item $global:BrownserveBuiltModuleDirectory -Destination $script:ModulePackageDirectory -Recurse
        Copy-Item $ItemsToCopy -Destination $script:ModulePackageDirectory -Force
        New-Item $Script:ModuleNuspecPath -Value $Nuspec -Force | Out-Null
        $script:ModuleNuspecPath = $script:ModuleNuspecPath | Convert-Path
    }
    else
    {
        Write-Verbose 'No custom feeds require a module package, skipping...'
    }
}

<#
.SYNOPSIS
    Packs the NuGet package(s) ready for shipping off to nuget.org, the PSGallery or a private feed.
#>
task PackModuleNuGetPackage PrepareModuleNuGetPackage, {
    if (('nuget' -in $PublishTo) -or ('GitHub' -in $PublishTo) -or ($script:CustomNugetFeedNugetPackage -eq $true))
    {
        Write-Build White 'Packing module as standard NuGet package'
        exec {
            $NugetArguments = @(
                'pack',
                "$script:NuspecPath",
                '-NoPackageAnalysis',
                '-Version',
                "$Global:BuildVersion",
                '-OutputDirectory',
                "$script:NugetPackageDirectory"
            )
            if (-not $isWindows)
            {
                $NugetArguments = @($Global:BrownserveNugetPath) + $NugetArguments
            }
            & $NugetCommand $NugetArguments
        }
        $script:nupkgPath = Join-Path $script:NugetPackageDirectory "$ModuleName.$global:BuildVersion.nupkg" | Convert-Path
    }
    else
    {
        Write-Verbose 'No feeds require a standard NuGet package, skipping...'
    }
    if ($script:CustomNugetFeedModulePackage -eq $true)
    {
        Write-Build White 'Packing module as PowerShell module package'
        exec {
            $NugetArguments = @(
                'pack',
                "$script:ModuleNuspecPath",
                '-NoPackageAnalysis',
                '-Version',
                "$Global:BuildVersion",
                '-OutputDirectory',
                "$script:ModulePackageDirectory"
            )
            if (-not $isWindows)
            {
                $NugetArguments = @($Global:BrownserveNugetPath) + $NugetArguments
            }
            & $NugetCommand $NugetArguments
        }
        $script:ModulePackagePath = Join-Path $script:ModulePackageDirectory "$ModuleName.$global:BuildVersion.nupkg" | Convert-Path
    }
    else
    {
        Write-Verbose 'No custom feeds require a module package, skipping...'
    }
} -Before Package

<#
.SYNOPSIS
    Pushes the standard NuGet package to nuget.org.
.DESCRIPTION
    Idempotent via '-SkipDuplicate', so re-running a Release that already pushed successfully doesn't fail
    the second time round. Routed through Invoke-BrownserveRetry so transient failures are retried.
#>
task PublishModuleToNuGet CheckModulePublishingParameters, PackModuleNuGetPackage, {
    if ('nuget' -notin $PublishTo)
    {
        Write-Verbose 'nuget not targeted, skipping...'
        return
    }
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
    Write-Build White 'Pushing module to nuget'
    Invoke-BrownserveRetry -ScriptBlock { exec { & $NugetCommand $NugetArguments } }
} -Before Publish

<#
.SYNOPSIS
    Publishes the module to the PSGallery.
.DESCRIPTION
    Idempotent: skips publishing when Find-Module locates this exact version already on the PSGallery, so
    a resumed Release doesn't fail on a version that published successfully last time.
#>
task PublishModuleToPSGallery CheckModulePublishingParameters, ImportModule, {
    if ('PSGallery' -notin $PublishTo)
    {
        Write-Verbose 'PSGallery not targeted, skipping...'
        return
    }
    $Existing = Invoke-BrownserveRetry -ScriptBlock {
        Find-Module -Name $ModuleName -Repository PSGallery -RequiredVersion $Global:BuildVersion -AllowPrerelease -ErrorAction SilentlyContinue
    }
    if ($Existing)
    {
        Write-Verbose "Version $Global:BuildVersion already published to the PSGallery, skipping."
        return
    }
    Write-Build White 'Pushing to PSGallery'
    $PSGalleryParams = @{
        Path              = $global:BrownserveBuiltModuleDirectory
        NuGetAPIKey       = $PSGalleryAPIKey
        SkipAutomaticTags = $true
    }
    Invoke-BrownserveRetry -ScriptBlock { Publish-Module @PSGalleryParams }
} -Before Publish

<#
.SYNOPSIS
    Pushes the module to any configured custom/private NuGet feeds.
.DESCRIPTION
    Uses '--skip-duplicate' so a resumed Release doesn't fail on a feed it already pushed to.
#>
task PublishModuleToCustomFeeds CheckModulePublishingParameters, CreateModuleNugetConfig, PackModuleNuGetPackage, {
    if ('CustomNugetFeeds' -notin $PublishTo)
    {
        Write-Verbose 'Custom NuGet feeds not targeted, skipping...'
        return
    }
    Write-Build White 'Pushing to custom NuGet feeds'
    $CustomNugetFeeds | ForEach-Object {
        $PackagePath = if ($_.PublishAs -eq 'ModulePackage') { $script:ModulePackagePath } else { $script:nupkgPath }
        Write-Verbose "Pushing to custom NuGet feed $($_.Name)"
        $NugetArguments = @(
            'nuget',
            'push',
            '--source',
            $_.Name,
            '--api-key',
            'AnyRandomString',
            '--skip-duplicate',
            $PackagePath
        )
        try
        {
            Push-Location
            Set-Location $Global:BrownserveRepoBuildOutputDirectory
            Invoke-BrownserveRetry -ScriptBlock {
                & dotnet $NugetArguments
                if ($LASTEXITCODE -ne 0)
                {
                    throw "Failed to push to custom NuGet feed $($_.Name)."
                }
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
} -Before Publish

<#
.SYNOPSIS
    Uploads the compressed module and the nupkg as assets on the draft GitHub release.
.DESCRIPTION
    Registers both assets as expected on the release so FinaliseRelease refuses to publish without them.
    Skips an upload if an asset with the same name and size is already present, so a resumed Release
    doesn't fail or duplicate assets.
#>
task UploadModuleReleaseAssets CreateDraftRelease, CompressModule, PackModuleNuGetPackage, {
    if ('GitHub' -notin $PublishTo)
    {
        Write-Verbose 'GitHub not targeted, skipping release asset upload...'
        return
    }
    if (!$script:ReleaseResponse)
    {
        throw 'No draft release found to upload assets to.'
    }
    $AssetsToUpload = @($script:CompressedModule, $script:nupkgPath) | Where-Object { $_ }
    foreach ($AssetPath in $AssetsToUpload)
    {
        $AssetName = Split-Path $AssetPath -Leaf
        $script:ExpectedReleaseAssets += $AssetName
        $ExistingAsset = $script:ReleaseResponse.assets | Where-Object { $_.name -eq $AssetName }
        $LocalSize = (Get-Item $AssetPath).Length
        if ($ExistingAsset -and ($ExistingAsset.size -eq $LocalSize))
        {
            Write-Verbose "Asset '$AssetName' already uploaded with a matching size, skipping."
            continue
        }
        Write-Build White "Uploading '$AssetName' as release asset"
        Invoke-BrownserveRetry -ScriptBlock {
            Add-GitHubReleaseAsset `
                -UploadUrl $script:ReleaseResponse.upload_url `
                -Token $GitHubReleaseToken `
                -FilePath $AssetPath `
                -ErrorAction 'Stop'
        } | Out-Null
    }
} -Before Publish

<#
.SYNOPSIS
    Meta task for building the module and importing it.
.DESCRIPTION
    Builds the module (manifest and copy only) and imports it, without generating documentation or
    running tests. Best used when developing new features locally.
#>
task BuildAndImport Build, ImportModule, {}

<#
.SYNOPSIS
    Meta task for building the module along with its documentation.
.DESCRIPTION
    Builds and imports the module, then regenerates its documentation. Best run after local changes have
    largely been finalised.
#>
task BuildWithDocs BuildAndImport, CreateModuleHelp, {}
