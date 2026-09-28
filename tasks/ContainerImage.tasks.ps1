<#
.SYNOPSIS
    Invoke-Build tasks for building, testing and publishing a Docker container image.
.DESCRIPTION
    Attaches to the anchors defined in ReleaseLifecycle.tasks.ps1: building the image attaches to 'Build',
    and pushing it to the configured registries attaches to 'Publish'. Also defines the public dotted
    target 'ContainerImage.Check' (build the image and run its Pester checks), used directly by CI for
    pull request validation. ReleaseLifecycle.tasks.ps1 must be dot-sourced first, as this file depends on
    tasks, script variables and the Invoke-BrownserveRetry helper it defines. Native 'docker' calls are not
    routed through Invoke-BrownserveRetry, as it can't classify their failures.
#>
[CmdletBinding()]
param
(
    # The Docker image name (without tag)
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $ImageName = $Global:BrownserveRepoName,

    # Path (relative to the repository root) to the directory containing the Dockerfile and its build
    # context
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $DockerContextPath = '.',

    # The various places to publish to
    [Parameter(
        Mandatory = $false
    )]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('DockerHub', 'GHCR')]
    [string[]]
    $PublishTo,

    # The GitHub organisation/account that owns this repository, used to build the GHCR image path
    [Parameter(
        Mandatory = $true
    )]
    [ValidateNotNullOrEmpty()]
    [string]
    $GitHubRepoOwner,

    # DockerHub username, required when publishing to DockerHub
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $DockerHubUsername,

    # DockerHub access token, required when publishing to DockerHub
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $DockerHubToken,

    # Token used to authenticate with GitHub Container Registry (ghcr.io), required when publishing to
    # GHCR. Requires packages:write scope, typically the workflow's GITHUB_TOKEN
    [Parameter(
        Mandatory = $false
    )]
    [string]
    $GHCRToken
)
# Docker requires image names to be lowercase
$ImageName = $ImageName.ToLower()
$script:DockerContext = Join-Path $Global:BrownserveRepoRootDirectory $DockerContextPath
$Global:BrownserveRepoDockerImageName = $ImageName

<#
.SYNOPSIS
    Checks that all the required parameters for publishing this image have been provided.
#>
task CheckContainerPublishingParameters {
    if ('DockerHub' -in $PublishTo)
    {
        if (!$DockerHubUsername)
        {
            throw 'DockerHubUsername not provided'
        }
        if (!$DockerHubToken)
        {
            throw 'DockerHubToken not provided'
        }
    }
    if ('GHCR' -in $PublishTo)
    {
        if (!$GHCRToken)
        {
            throw 'GHCRToken not provided'
        }
    }
}

<#
.SYNOPSIS
    Builds the Docker image, tagging it '<image>:latest'.
#>
task BuildImage {
    Write-Build White "Building Docker image '$ImageName' from context '$script:DockerContext'"
    try
    {
        exec { docker build -t "${ImageName}:latest" $script:DockerContext }
    }
    catch
    {
        throw "Docker build failed.`n$($_.Exception.Message)"
    }
} -Before Build

<#
.SYNOPSIS
    Pushes the image to DockerHub and/or GHCR, tagged with both the release version and 'latest'.
.DESCRIPTION
    Uses '--password-stdin' rather than '-p' so credentials never appear in the process list. A push is
    naturally idempotent (re-pushing the same tag just overwrites the manifest), so a resumed Release can
    safely re-run this task.
#>
task PublishContainerImage CheckContainerPublishingParameters, BuildImage, SetVersion, {
    if ('DockerHub' -in $PublishTo)
    {
        Write-Build White 'Publishing to DockerHub'
        try
        {
            exec { $DockerHubToken | docker login --username $DockerHubUsername --password-stdin }
            exec { docker tag "${ImageName}:latest" "${DockerHubUsername}/${ImageName}:$Global:BuildVersion" }
            exec { docker tag "${ImageName}:latest" "${DockerHubUsername}/${ImageName}:latest" }
            exec { docker push "${DockerHubUsername}/${ImageName}:$Global:BuildVersion" }
            exec { docker push "${DockerHubUsername}/${ImageName}:latest" }
        }
        catch
        {
            throw "Failed to publish to DockerHub.`n$($_.Exception.Message)"
        }
    }
    else
    {
        Write-Verbose 'DockerHub not targeted, skipping...'
    }

    if ('GHCR' -in $PublishTo)
    {
        Write-Build White 'Publishing to GitHub Container Registry'
        $GHCRImage = "ghcr.io/$($GitHubRepoOwner.ToLower())/${ImageName}"
        try
        {
            exec { $GHCRToken | docker login ghcr.io --username $GitHubRepoOwner --password-stdin }
            exec { docker tag "${ImageName}:latest" "${GHCRImage}:$Global:BuildVersion" }
            exec { docker tag "${ImageName}:latest" "${GHCRImage}:latest" }
            exec { docker push "${GHCRImage}:$Global:BuildVersion" }
            exec { docker push "${GHCRImage}:latest" }
        }
        catch
        {
            throw "Failed to publish to GHCR.`n$($_.Exception.Message)"
        }
    }
    else
    {
        Write-Verbose 'GHCR not targeted, skipping...'
    }
} -Before Publish

<#
.SYNOPSIS
    Public target: build the image and run its Pester checks, without pushing anything.
.DESCRIPTION
    Used directly by CI for pull request validation. The Pester checks (e.g. container starts, is still
    running after startup) key off $Global:BrownserveRepoDockerImageName.
#>
task ContainerImage.Check BuildImage, Tests, {}
