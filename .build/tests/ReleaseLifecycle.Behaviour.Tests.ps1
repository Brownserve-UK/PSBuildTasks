#requires -Modules Pester, InvokeBuild

BeforeAll {
    $script:BuildTasksFile = Join-Path $Global:BrownserveRepoBuildTasksDirectory 'build_tasks.ps1'
    $script:StageOrderFile = Join-Path $Global:BrownserveRepoTestsDirectory 'Fixtures' 'StageOrder.tasks.ps1'
    $script:PackageId = 'Test.Package'
    $script:ReleaseVersion = '1.2.3'
    $script:NupkgName = "$script:PackageId.$script:ReleaseVersion.nupkg"
    $Global:BTReleaseVersion = $script:ReleaseVersion

    function global:git
    {
        return 'deadbeefcafef00dfeedfacecafebeef00000000'
    }

    function Get-CommonBuildParams
    {
        param
        (
            [string[]]$PublishTo = @('GitHub')
        )
        return @{
            File                = $script:BuildTasksFile
            PackageId           = $script:PackageId
            PackageDescription  = 'A test package'
            BranchName          = 'main'
            DefaultBranch       = 'main'
            GitHubRepoOwner     = 'Brownserve-UK'
            GitHubRepoName      = 'PSBuildTasks'
            GitHubReleaseToken  = 'fake-release-token'
            PublishTo           = $PublishTo
        }
    }

    function global:mono
    {
        $ArgList = if (($args.Count -eq 1) -and ($args[0] -is [array]))
        {
            $args[0]
        }
        else
        {
            $args
        }
        if ($ArgList -contains 'pack')
        {
            $OutputIndex = [array]::IndexOf($ArgList, '-OutputDirectory')
            $OutputDir = $ArgList[$OutputIndex + 1]
            New-Item -ItemType File -Path (Join-Path $OutputDir $Global:BTNupkgName) -Force | Out-Null
        }
        $global:LASTEXITCODE = 0
    }
    $Global:BTNupkgName = $script:NupkgName

    function Invoke-TestBuild
    {
        param
        (
            [Parameter(Mandatory = $true)]
            [string]$Task,

            [Parameter(Mandatory = $true)]
            [hashtable]$BuildParams
        )
        $NuGetOutputDir = Join-Path $Global:BrownserveRepoBuildOutputDirectory 'NuGetPackage'
        if (Test-Path $NuGetOutputDir)
        {
            Remove-Item -Path $NuGetOutputDir -Recurse -Force
        }
        Invoke-Build $Task @BuildParams
    }
}

AfterAll {
    Remove-Item -ErrorAction 'SilentlyContinue' -Path @(
        'Function:\git',
        'Function:\mono',
        'Function:\New-BrownserveChangelogEntry',
        'Function:\Add-BrownserveChangelogEntry'
    )
    Remove-Variable -Scope 'Global' -ErrorAction 'SilentlyContinue' -Name @(
        'BTReleaseVersion',
        'BTNupkgName',
        'BTReleases',
        'BTAssetUploadShouldFail',
        'BTFinaliseAttempts',
        'StageOrderLog'
    )
}

Describe 'Composed release build behaviour' {
    BeforeEach {
        $Global:BTReleases = [System.Collections.Generic.List[psobject]]::new()
        $Global:BTAssetUploadShouldFail = $false
        $Global:StageOrderLog = @()

        Mock -CommandName Get-GitHubRelease -MockWith {
            return @($Global:BTReleases)
        }
        Mock -CommandName New-GitHubRelease -MockWith {
            param($Name, $Tag, $Description, $RepositoryName, $RepositoryOwner, $Token, [switch]$Prerelease, $TargetCommit, [switch]$Draft)
            $Release = [PSCustomObject]@{
                id               = $Global:BTReleases.Count + 1
                tag_name         = $Tag
                draft            = [bool]$Draft
                target_commitish = $TargetCommit
                upload_url       = "https://uploads.example.invalid/$Tag"
                assets           = [System.Collections.Generic.List[psobject]]::new()
            }
            $Global:BTReleases.Add($Release)
            return $Release
        }
        Mock -CommandName Update-GitHubRelease -MockWith {
            param($ReleaseId, $RepositoryName, $RepositoryOwner, $Token, $Draft)
            $Release = $Global:BTReleases | Where-Object { $_.id -eq $ReleaseId }
            $Release.draft = $Draft
        }
        Mock -CommandName Add-GitHubReleaseAsset -MockWith {
            param($FilePath, $AssetName, $AssetLabel, $UploadUrl, $Token)
            if ($Global:BTAssetUploadShouldFail)
            {
                throw 'Simulated asset upload failure'
            }
            $Name = if ($AssetName) { $AssetName } else { Split-Path $FilePath -Leaf }
            $Release = $Global:BTReleases | Where-Object { $_.upload_url -eq $UploadUrl }
            $Release.assets.Add([PSCustomObject]@{ name = $Name; size = (Get-Item $FilePath).Length })
        }

        Mock -CommandName Remove-Markdown -MockWith { param($String) $String }
        Mock -CommandName Get-GitChanges -MockWith { return $null }
        Mock -CommandName Invoke-Pester -MockWith { return [PSCustomObject]@{ FailedCount = 0 } }
    }

    Context 'DryRun' {
        BeforeEach {
            Mock -CommandName Read-BrownserveChangelog -MockWith {
                [PSCustomObject]@{
                    VersionHistory = @(
                        [PSCustomObject]@{
                            Version      = $Global:BTReleaseVersion
                            PreRelease   = $false
                            ReleaseNotes = 'Test release notes'
                        }
                    )
                }
            }
        }

        It 'performs no publication or remote release-state changes' {
            $BuildParams = Get-CommonBuildParams
            { Invoke-TestBuild -Task 'DryRun' -BuildParams $BuildParams } | Should -Not -Throw
            Should -Invoke -CommandName New-GitHubRelease -Times 0
            Should -Invoke -CommandName Get-GitHubRelease -Times 0
            Should -Invoke -CommandName Update-GitHubRelease -Times 0
            Should -Invoke -CommandName Add-GitHubReleaseAsset -Times 0
        }
    }

    Context 'Release' {
        BeforeEach {
            Mock -CommandName Read-BrownserveChangelog -MockWith {
                [PSCustomObject]@{
                    VersionHistory = @(
                        [PSCustomObject]@{
                            Version      = $Global:BTReleaseVersion
                            PreRelease   = $false
                            ReleaseNotes = 'Test release notes'
                        }
                    )
                }
            }
        }

        It 'creates a draft release, uploads the nupkg, then finalises the release' {
            $BuildParams = Get-CommonBuildParams
            { Invoke-TestBuild -Task 'Release' -BuildParams $BuildParams } | Should -Not -Throw
            Should -Invoke -CommandName New-GitHubRelease -Times 1
            Should -Invoke -CommandName Add-GitHubReleaseAsset -Times 1
            Should -Invoke -CommandName Update-GitHubRelease -Times 1
            $Global:BTReleases[0].draft | Should -Be $false
            $Global:BTReleases[0].assets.name | Should -Contain $script:NupkgName
        }

        It 'does not finalise the release when a publisher fails' {
            $Global:BTAssetUploadShouldFail = $true
            $BuildParams = Get-CommonBuildParams
            { Invoke-TestBuild -Task 'Release' -BuildParams $BuildParams } | Should -Throw
            Should -Invoke -CommandName Update-GitHubRelease -Times 0
            $Global:BTReleases[0].draft | Should -Be $true
        }

        It 'resumes on a rerun for the same commit: reuses the draft, uploads only missing assets, and finalises' {
            $Global:BTAssetUploadShouldFail = $true
            $BuildParams = Get-CommonBuildParams
            { Invoke-TestBuild -Task 'Release' -BuildParams $BuildParams } | Should -Throw
            $Global:BTReleases.Count | Should -Be 1
            $Global:BTReleases[0].assets.Count | Should -Be 0

            $Global:BTAssetUploadShouldFail = $false
            { Invoke-TestBuild -Task 'Release' -BuildParams $BuildParams } | Should -Not -Throw
            $Global:BTReleases.Count | Should -Be 1 -Because 'the existing draft should be reused, not duplicated'
            Should -Invoke -CommandName New-GitHubRelease -Times 1 -Because 'only the first run should have created the draft'
            Should -Invoke -CommandName Add-GitHubReleaseAsset -Times 2 -Because 'once for the failed attempt and once for the retry'
            $Global:BTReleases[0].draft | Should -Be $false
        }

        It 'skips a release asset that is already uploaded with a matching size, on a resumed run' {
            $Global:BTFinaliseAttempts = 0
            Mock -CommandName Update-GitHubRelease -MockWith {
                param($ReleaseId, $RepositoryName, $RepositoryOwner, $Token, $Draft)
                $Global:BTFinaliseAttempts++
                if ($Global:BTFinaliseAttempts -eq 1)
                {
                    throw 'Simulated finalise failure'
                }
                $Release = $Global:BTReleases | Where-Object { $_.id -eq $ReleaseId }
                $Release.draft = $Draft
            }

            $BuildParams = Get-CommonBuildParams
            { Invoke-TestBuild -Task 'Release' -BuildParams $BuildParams } | Should -Throw
            Should -Invoke -CommandName Add-GitHubReleaseAsset -Times 1

            { Invoke-TestBuild -Task 'Release' -BuildParams $BuildParams } | Should -Not -Throw
            Should -Invoke -CommandName Add-GitHubReleaseAsset -Times 1 -Because 'the asset was already uploaded with a matching size, so the resumed run should not upload it again'
            $Global:BTReleases[0].draft | Should -Be $false
        }

        It 'fails before publishing anything when a rerun targets a different commit' {
            $Global:BTAssetUploadShouldFail = $true
            $BuildParams = Get-CommonBuildParams
            { Invoke-TestBuild -Task 'Release' -BuildParams $BuildParams } | Should -Throw

            $Global:BTReleases[0].target_commitish = 'a-completely-different-commit-sha'

            $Global:BTAssetUploadShouldFail = $false
            { Invoke-TestBuild -Task 'Release' -BuildParams $BuildParams } | Should -Throw
            Should -Invoke -CommandName Add-GitHubReleaseAsset -Times 1 -Because 'the second run should fail before uploading anything else'
            $Global:BTReleases[0].draft | Should -Be $true
        }

        It 'fails when a published (non-draft) release already exists for this version' {
            $Global:BTReleases.Add([PSCustomObject]@{
                    id               = 1
                    tag_name         = "v$script:ReleaseVersion"
                    draft            = $false
                    target_commitish = 'deadbeefcafef00dfeedfacecafebeef00000000'
                    upload_url       = 'https://uploads.example.invalid/already-published'
                    assets           = [System.Collections.Generic.List[psobject]]::new()
                })
            $BuildParams = Get-CommonBuildParams
            { Invoke-TestBuild -Task 'Release' -BuildParams $BuildParams } | Should -Throw
            Should -Invoke -CommandName Add-GitHubReleaseAsset -Times 0
            Should -Invoke -CommandName New-GitHubRelease -Times 0
        }
    }

    Context 'StageRelease' {
        It 'completes every Stage anchor contribution before committing tracked changes' {
            function global:New-BrownserveChangelogEntry
            {
                [CmdletBinding()]
                param
                (
                    [Parameter(ValueFromPipeline = $true)]
                    $ChangelogObject,
                    [Parameter()]
                    $Version,
                    [Parameter()]
                    $RepositoryOwner,
                    [Parameter()]
                    $RepositoryName,
                    [Parameter()]
                    $SinceVersion,
                    [Parameter()]
                    [switch]$Auto,
                    [Parameter()]
                    $GitHubToken
                )
                return 'Test release notes'
            }
            function global:Add-BrownserveChangelogEntry
            {
                [CmdletBinding()]
                param
                (
                    [Parameter(ValueFromPipeline = $true)]
                    $ChangelogObject,
                    [Parameter()]
                    $NewContent,
                    [Parameter()]
                    $ChangelogPath
                )
                process {}
            }
            Mock -CommandName New-GitHubBranch -MockWith {}
            Mock -CommandName New-GitHubCommit -MockWith {
                $Global:StageOrderLog += 'CommitTrackedChanges'
            }
            Mock -CommandName New-GitHubPullRequest -MockWith {
                return [PSCustomObject]@{ html_url = 'https://github.invalid/pr/1' }
            }

            $BuildParams = @{
                File                    = $script:StageOrderFile
                ReleaseType             = 'minor'
                BranchName              = 'main'
                DefaultBranch           = 'main'
                GitHubRepoOwner         = 'Brownserve-UK'
                GitHubRepoName          = 'PSBuildTasks'
                GitHubStageReleaseToken = 'fake-stage-token'
            }
            { Invoke-TestBuild -Task 'StageRelease' -BuildParams $BuildParams } | Should -Not -Throw

            @($Global:StageOrderLog) | Should -Be @('StageContribution', 'CommitTrackedChanges')
        }
    }
}
