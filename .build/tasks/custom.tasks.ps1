<#
.SYNOPSIS
    Repository-specific build tasks for this repo.
.DESCRIPTION
    Tasks that are specific to this repository and don't belong in a shared Brownserve.PSBuildTasks task
    file go here, attached to the anchors defined in ReleaseLifecycle.tasks.ps1 (Build, Test, Check, Package,
    Stage, Publish) using Invoke-Build's -Before/-After parameters.
#>
