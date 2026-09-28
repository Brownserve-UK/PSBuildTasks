#requires -Modules Pester, InvokeBuild

BeforeAll {
    $script:TaskFile = Join-Path $Global:BrownserveRepoTestsDirectory 'Fixtures' 'DirectoryArchiveOnly.tasks.ps1'
    $script:ArchiveSourceDir = Join-Path $Global:BrownserveRepoTempDirectory 'directory-archive-source'
    New-Item -Path $script:ArchiveSourceDir -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path $script:ArchiveSourceDir 'file.txt') -Value 'hello'

    function global:git
    {
        return 'deadbeefcafef00dfeedfacecafebeef00000000'
    }

    function Get-DACommonBuildParams
    {
        return @{
            File         = $script:TaskFile
            Path         = $script:ArchiveSourceDir
            ArchiveName  = 'test-archive'
            PublishTo    = @('GitHub')
            GitHubReleaseToken = 'fake-release-token'
        }
    }
}

AfterAll {
    Remove-Item -ErrorAction 'SilentlyContinue' -Path 'Function:\git'
    Remove-Item -ErrorAction 'SilentlyContinue' -Recurse -Path $script:ArchiveSourceDir
    Remove-Variable -Scope 'Global' -ErrorAction 'SilentlyContinue' -Name @('DAReleases', 'DAAssetUploadShouldFail', 'DAReleaseVersion', 'DAFinaliseAttempts')
}

Describe 'DirectoryArchive build behaviour' {
    BeforeEach {
        $Global:DAReleaseVersion = '1.2.3'
        $Global:DAReleases = [System.Collections.Generic.List[psobject]]::new()
        $Global:DAAssetUploadShouldFail = $false

        Mock -CommandName Read-BrownserveChangelog -MockWith {
            [PSCustomObject]@{
                VersionHistory = @(
                    [PSCustomObject]@{
                        Version      = $Global:DAReleaseVersion
                        PreRelease   = $false
                        ReleaseNotes = 'Test release notes'
                    }
                )
            }
        }
        Mock -CommandName Remove-Markdown -MockWith { param($String) $String }
        Mock -CommandName Get-GitChanges -MockWith { return $null }
        Mock -CommandName Invoke-Pester -MockWith { return [PSCustomObject]@{ FailedCount = 0 } }

        Mock -CommandName Get-GitHubRelease -MockWith { return @($Global:DAReleases) }
        Mock -CommandName New-GitHubRelease -MockWith {
            param($Name, $Tag, $Description, $RepositoryName, $RepositoryOwner, $Token, [switch]$Prerelease, $TargetCommit, [switch]$Draft)
            $Release = [PSCustomObject]@{
                id               = $Global:DAReleases.Count + 1
                tag_name         = $Tag
                draft            = [bool]$Draft
                target_commitish = $TargetCommit
                upload_url       = "https://uploads.example.invalid/$Tag"
                assets           = [System.Collections.Generic.List[psobject]]::new()
            }
            $Global:DAReleases.Add($Release)
            return $Release
        }
        Mock -CommandName Update-GitHubRelease -MockWith {
            param($ReleaseId, $RepositoryName, $RepositoryOwner, $Token, $Draft)
            ($Global:DAReleases | Where-Object { $_.id -eq $ReleaseId }).draft = $Draft
        }
        Mock -CommandName Add-GitHubReleaseAsset -MockWith {
            param($FilePath, $UploadUrl, $Token)
            if ($Global:DAAssetUploadShouldFail)
            {
                throw 'Simulated asset upload failure'
            }
            $Release = $Global:DAReleases | Where-Object { $_.upload_url -eq $UploadUrl }
            $Release.assets.Add([PSCustomObject]@{ name = (Split-Path $FilePath -Leaf); size = (Get-Item $FilePath).Length })
        }
    }

    It 'creates and uploads the archive, and the release ends up published' {
        $BuildParams = Get-DACommonBuildParams
        { Invoke-Build Release @BuildParams } | Should -Not -Throw
        $Global:DAReleases[0].assets.name | Should -Contain "test-archive-v$Global:DAReleaseVersion.zip"
        $Global:DAReleases[0].draft | Should -Be $false
    }

    It 'skips uploading the archive on a rerun when already present with a matching size' {
        $Global:DAFinaliseAttempts = 0
        Mock -CommandName Update-GitHubRelease -MockWith {
            param($ReleaseId, $RepositoryName, $RepositoryOwner, $Token, $Draft)
            $Global:DAFinaliseAttempts++
            if ($Global:DAFinaliseAttempts -eq 1)
            {
                throw 'Simulated finalise failure'
            }
            ($Global:DAReleases | Where-Object { $_.id -eq $ReleaseId }).draft = $Draft
        }

        $BuildParams = Get-DACommonBuildParams
        { Invoke-Build Release @BuildParams } | Should -Throw
        Should -Invoke -CommandName Add-GitHubReleaseAsset -Times 1

        { Invoke-Build Release @BuildParams } | Should -Not -Throw
        Should -Invoke -CommandName Add-GitHubReleaseAsset -Times 1 -Because 'the archive was already uploaded with a matching size'
        $Global:DAReleases[0].draft | Should -Be $false
    }

    It 'is expected by FinaliseRelease: a failed upload leaves the release as an unpublished draft' {
        $Global:DAAssetUploadShouldFail = $true
        $BuildParams = Get-DACommonBuildParams
        { Invoke-Build Release @BuildParams } | Should -Throw
        Should -Invoke -CommandName Update-GitHubRelease -Times 0
        $Global:DAReleases[0].draft | Should -Be $true
    }
}
