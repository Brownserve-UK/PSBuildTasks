<#
.SYNOPSIS
    Invoke-Build tasks for building an Astro documentation site.
.DESCRIPTION
    Attaches to the anchor defined in ReleaseLifecycle.tasks.ps1: building the site attaches to 'Build'.
    Deployment of the built site is handled by a separate 'deploy-docs' workflow, not by this file.
    ReleaseLifecycle.tasks.ps1 must be dot-sourced first, as this file depends on tasks and script
    variables it defines.
#>
[CmdletBinding()]
param
(
    # The directory (relative to the repository root) containing the Astro site
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $DocsDirectory = 'pages'
)
$script:AstroDocsDirectory = Join-Path $Global:BrownserveRepoRootDirectory $DocsDirectory

<#
.SYNOPSIS
    Builds the Astro documentation site.
.DESCRIPTION
    Installs dependencies with 'npm ci' and then runs the Astro build, both from -DocsDirectory.
#>
task BuildAstroDocs {
    Write-Build White "Building documentation site in '$script:AstroDocsDirectory'"
    Push-Location $script:AstroDocsDirectory
    try
    {
        exec { npm ci }
        exec { npm run build }
    }
    finally
    {
        Pop-Location
    }
} -Before Build
