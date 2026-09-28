#requires -Modules Pester, InvokeBuild

BeforeAll {
    $script:TaskFile = Join-Path $Global:BrownserveRepoTestsDirectory 'Fixtures' 'PowerShellModuleOnly.tasks.ps1'
    $script:SavedModuleDirectory = $Global:BrownserveModuleDirectory
    $script:SavedDocsDirectory = $Global:BrownserveRepoDocsDirectory
    $Global:BrownserveModuleDirectory = Join-Path $Global:BrownserveRepoTestsDirectory 'Fixtures' 'FakeModule' 'Module'
    $Global:BrownserveRepoDocsDirectory = Join-Path $Global:BrownserveRepoTempDirectory 'module-docs-test'
    New-Item -Path $Global:BrownserveRepoDocsDirectory -ItemType Directory -Force | Out-Null

    function global:git
    {
        return 'deadbeefcafef00dfeedfacecafebeef00000000'
    }

    function Get-PMFlattenedArgs
    {
        param($ArgList)
        if (($ArgList.Count -eq 1) -and ($ArgList[0] -is [array])) { return $ArgList[0] }
        return $ArgList
    }

    function global:mono
    {
        $FlatArgs = Get-PMFlattenedArgs -ArgList $args
        $Global:PMNugetCalls += , @($FlatArgs)
        if ($FlatArgs -contains 'pack')
        {
            $PackIndex = [array]::IndexOf($FlatArgs, 'pack')
            $NuspecPath = $FlatArgs[$PackIndex + 1]
            $VersionIndex = [array]::IndexOf($FlatArgs, '-Version')
            $Version = $FlatArgs[$VersionIndex + 1]
            $OutputIndex = [array]::IndexOf($FlatArgs, '-OutputDirectory')
            $OutputDir = $FlatArgs[$OutputIndex + 1]
            $PackageId = [System.IO.Path]::GetFileNameWithoutExtension($NuspecPath)
            New-Item -ItemType File -Path (Join-Path $OutputDir "$PackageId.$Version.nupkg") -Force | Out-Null
        }
        $Global:LASTEXITCODE = 0
    }

    function Invoke-PMTestBuild
    {
        param(
            [Parameter(Mandatory = $true)] [string]$Task,
            [Parameter(Mandatory = $true)] [hashtable]$BuildParams
        )
        Get-ChildItem -Path $Global:BrownserveRepoBuildOutputDirectory -ErrorAction 'SilentlyContinue' |
            Remove-Item -Recurse -Force -ErrorAction 'SilentlyContinue'
        Invoke-Build $Task @BuildParams
    }

    function Get-PMCommonBuildParams
    {
        param([string[]]$PublishTo = @('GitHub'))
        return @{
            File               = $script:TaskFile
            PublishTo          = $PublishTo
            GitHubReleaseToken = 'fake-release-token'
            NugetFeedApiKey    = 'fake-nuget-key'
            PSGalleryAPIKey    = 'fake-psgallery-key'
        }
    }
}

AfterAll {
    $Global:BrownserveModuleDirectory = $script:SavedModuleDirectory
    $Global:BrownserveRepoDocsDirectory = $script:SavedDocsDirectory
    Remove-Item -ErrorAction 'SilentlyContinue' -Path @('Function:\git', 'Function:\mono', 'Function:\Get-PMFlattenedArgs')
    Remove-Variable -Scope 'Global' -ErrorAction 'SilentlyContinue' -Name @('PMNugetCalls', 'PMReleases', 'PMReleaseVersion', 'PMOrderLog', 'PMPSGalleryHasVersion', 'PMAssetUploadShouldFail')
    Remove-Item -ErrorAction 'SilentlyContinue' -Recurse -Path (Join-Path $Global:BrownserveRepoTempDirectory 'module-docs-test') -Force
}

Describe 'PowerShellModule build behaviour' {
    BeforeEach {
        $Global:PMNugetCalls = [System.Collections.Generic.List[object]]::new()
        $Global:PMReleaseVersion = '1.1.0'
        $Global:PMReleases = [System.Collections.Generic.List[psobject]]::new()
        $Global:PMOrderLog = [System.Collections.Generic.List[string]]::new()
        $Global:PMPSGalleryHasVersion = $false
        $Global:PMAssetUploadShouldFail = $false

        Mock -CommandName Read-BrownserveChangelog -MockWith {
            [PSCustomObject]@{
                VersionHistory = @(
                    [PSCustomObject]@{ Version = '1.0.0'; PreRelease = $false; ReleaseNotes = 'Test release notes' }
                )
            }
        }
        Mock -CommandName Remove-Markdown -MockWith { param($String) $String }
        Mock -CommandName Get-GitChanges -MockWith { return $null }
        Mock -CommandName Invoke-Pester -MockWith {
            $Global:PMOrderLog.Add('Tests')
            return [PSCustomObject]@{ FailedCount = 0 }
        }
        Mock -CommandName Build-ModuleDocumentation -MockWith {
            $Global:PMOrderLog.Add('Build-ModuleDocumentation')
            New-Item -Path (Join-Path $Global:BrownserveRepoDocsDirectory 'Commands.md') -ItemType File -Force | Out-Null
        }
        Mock -CommandName Add-ModuleHelp -MockWith { $Global:PMOrderLog.Add('Add-ModuleHelp') }
        Mock -CommandName Find-Module -MockWith {
            if ($Global:PMPSGalleryHasVersion) { return [PSCustomObject]@{ Version = $Global:PMReleaseVersion } }
            return $null
        }
        Mock -CommandName Find-Package -MockWith { return $null }
        Mock -CommandName Publish-Module -MockWith { $Global:PMOrderLog.Add('Publish-Module') }

        Mock -CommandName Get-GitHubRelease -MockWith { return @($Global:PMReleases) }
        Mock -CommandName New-GitHubRelease -MockWith {
            param($Name, $Tag, $Description, $RepositoryName, $RepositoryOwner, $Token, [switch]$Prerelease, $TargetCommit, [switch]$Draft)
            $Release = [PSCustomObject]@{
                id = $Global:PMReleases.Count + 1; tag_name = $Tag; draft = [bool]$Draft
                target_commitish = $TargetCommit; upload_url = "https://uploads.example.invalid/$Tag"
                assets = [System.Collections.Generic.List[psobject]]::new()
            }
            $Global:PMReleases.Add($Release)
            return $Release
        }
        Mock -CommandName Update-GitHubRelease -MockWith {
            param($ReleaseId, $RepositoryName, $RepositoryOwner, $Token, $Draft)
            ($Global:PMReleases | Where-Object { $_.id -eq $ReleaseId }).draft = $Draft
        }
        Mock -CommandName Add-GitHubReleaseAsset -MockWith {
            param($FilePath, $UploadUrl, $Token)
            if ($Global:PMAssetUploadShouldFail) { throw 'Simulated asset upload failure' }
            $Release = $Global:PMReleases | Where-Object { $_.upload_url -eq $UploadUrl }
            $Release.assets.Add([PSCustomObject]@{ name = (Split-Path $FilePath -Leaf); size = (Get-Item $FilePath).Length })
        }
    }

    It 'plain Build does not run the documentation chain' {
        Invoke-PMTestBuild -Task 'Build' -BuildParams @{ File = $script:TaskFile } | Out-Null
        Should -Invoke -CommandName Build-ModuleDocumentation -Times 0
        Should -Invoke -CommandName Add-ModuleHelp -Times 0
    }

    It 'runs documentation regeneration before the generic Tests task' {
        Invoke-PMTestBuild -Task 'BuildAndTest' -BuildParams @{ File = $script:TaskFile } | Out-Null
        $Global:PMOrderLog | Should -Contain 'Build-ModuleDocumentation'
        $Global:PMOrderLog | Should -Contain 'Add-ModuleHelp'
        $Global:PMOrderLog | Should -Contain 'Tests'
        $DocIndex = $Global:PMOrderLog.IndexOf('Add-ModuleHelp')
        $TestIndex = $Global:PMOrderLog.IndexOf('Tests')
        $DocIndex | Should -BeLessThan $TestIndex
    }

    It 'DryRun publishes nothing' {
        $BuildParams = Get-PMCommonBuildParams
        Invoke-PMTestBuild -Task 'DryRun' -BuildParams $BuildParams | Out-Null
        Should -Invoke -CommandName Publish-Module -Times 0
        Should -Invoke -CommandName New-GitHubRelease -Times 0
        Should -Invoke -CommandName Add-GitHubReleaseAsset -Times 0
        $Global:PMNugetCalls | Where-Object { $_ -contains 'push' } | Should -BeNullOrEmpty
    }

    It 'a rerun of Release skips a publisher that already succeeded (PSGallery) and finalises' {
        $Global:PMPSGalleryHasVersion = $false
        $Global:PMAssetUploadShouldFail = $true
        $BuildParams = Get-PMCommonBuildParams -PublishTo @('PSGallery', 'GitHub')
        { Invoke-PMTestBuild -Task 'Release' -BuildParams $BuildParams } | Should -Throw
        Should -Invoke -CommandName Publish-Module -Times 1

        $Global:PMPSGalleryHasVersion = $true
        $Global:PMAssetUploadShouldFail = $false
        { Invoke-PMTestBuild -Task 'Release' -BuildParams $BuildParams } | Should -Not -Throw
        Should -Invoke -CommandName Publish-Module -Times 1 -Because 'the version was already on the PSGallery, so the resumed run should skip publishing again'
        $Global:PMReleases[0].draft | Should -Be $false
    }
}
