#requires -Modules Pester, InvokeBuild

BeforeAll {
    $script:TaskFile = Join-Path $Global:BrownserveRepoTestsDirectory 'Fixtures' 'RustBinaryOnly.tasks.ps1'
    $script:CollectorDir = Join-Path $Global:BrownserveRepoTempDirectory 'rust-collector-source'

    function global:Get-RBFlattenedArgs
    {
        param($ArgList)
        if (($ArgList.Count -eq 1) -and ($ArgList[0] -is [array]))
        {
            return $ArgList[0]
        }
        return $ArgList
    }

    function global:cargo
    {
        $FlatArgs = Get-RBFlattenedArgs -ArgList $args
        $Global:RBCargoCalls += , @($FlatArgs)
        if ($FlatArgs -contains 'build')
        {
            $TargetIndex = [array]::IndexOf($FlatArgs, '--target')
            $BinDir = if ($TargetIndex -ge 0)
            {
                Join-Path $Global:BrownserveRepoBuildOutputDirectory $FlatArgs[$TargetIndex + 1] 'release'
            }
            else
            {
                Join-Path $Global:BrownserveRepoBuildOutputDirectory 'release'
            }
            New-Item -Path $BinDir -ItemType Directory -Force | Out-Null
            New-Item -Path (Join-Path $BinDir 'testbin') -ItemType File -Force | Out-Null
        }
        $Global:LASTEXITCODE = 0
    }

    function global:tar
    {
        $FlatArgs = Get-RBFlattenedArgs -ArgList $args
        $Global:RBCargoCalls += , @($FlatArgs)
        $ArchivePathIndex = [array]::IndexOf($FlatArgs, '-czf')
        New-Item -Path $FlatArgs[$ArchivePathIndex + 1] -ItemType File -Force | Out-Null
        $Global:LASTEXITCODE = 0
    }

    function global:rustc
    {
        return 'host: x86_64-unknown-linux-gnu'
    }

    function global:git
    {
        return 'deadbeefcafef00dfeedfacecafebeef00000000'
    }
}

AfterAll {
    Remove-Item -ErrorAction 'SilentlyContinue' -Path @('Function:\cargo', 'Function:\tar', 'Function:\rustc', 'Function:\git', 'Function:\Get-RBFlattenedArgs')
    Remove-Variable -Scope 'Global' -ErrorAction 'SilentlyContinue' -Name @('RBCargoCalls', 'RBReleases', 'RBReleaseVersion', 'BrownserveRustBinaryPath')
    Remove-Item -ErrorAction 'SilentlyContinue' -Recurse -Path $script:CollectorDir
}

Describe 'RustBinary build behaviour' {
    BeforeEach {
        $Global:RBCargoCalls = [System.Collections.Generic.List[object]]::new()
        $Global:RBReleaseVersion = '1.0.0'
        $Global:RBReleases = [System.Collections.Generic.List[psobject]]::new()

        Mock -CommandName Read-BrownserveChangelog -MockWith {
            [PSCustomObject]@{
                VersionHistory = @(
                    [PSCustomObject]@{
                        Version      = $Global:RBReleaseVersion
                        PreRelease   = $false
                        ReleaseNotes = 'Test release notes'
                    }
                )
            }
        }
        Mock -CommandName Remove-Markdown -MockWith { param($String) $String }
        Mock -CommandName Get-GitChanges -MockWith { return $null }
        Mock -CommandName Invoke-Pester -MockWith { return [PSCustomObject]@{ FailedCount = 0 } }

        Mock -CommandName Get-GitHubRelease -MockWith { return @($Global:RBReleases) }
        Mock -CommandName New-GitHubRelease -MockWith {
            param($Name, $Tag, $Description, $RepositoryName, $RepositoryOwner, $Token, [switch]$Prerelease, $TargetCommit, [switch]$Draft)
            $Release = [PSCustomObject]@{
                id               = $Global:RBReleases.Count + 1
                tag_name         = $Tag
                draft            = [bool]$Draft
                target_commitish = $TargetCommit
                upload_url       = "https://uploads.example.invalid/$Tag"
                assets           = [System.Collections.Generic.List[psobject]]::new()
            }
            $Global:RBReleases.Add($Release)
            return $Release
        }
        Mock -CommandName Update-GitHubRelease -MockWith {
            param($ReleaseId, $RepositoryName, $RepositoryOwner, $Token, $Draft)
            ($Global:RBReleases | Where-Object { $_.id -eq $ReleaseId }).draft = $Draft
        }
        Mock -CommandName Add-GitHubReleaseAsset -MockWith {
            param($FilePath, $UploadUrl, $Token)
            $Release = $Global:RBReleases | Where-Object { $_.upload_url -eq $UploadUrl }
            $Release.assets.Add([PSCustomObject]@{ name = (Split-Path $FilePath -Leaf); size = (Get-Item $FilePath).Length })
        }
    }

    It 'RustBinary.Package archives the released version without a ReleaseType' {
        Invoke-Build 'RustBinary.Package' -File $script:TaskFile -BinaryName 'testbin' -Target 'x86_64-unknown-linux-gnu' | Out-Null
        $ExpectedArchive = Join-Path $Global:BrownserveRepoBuildOutputDirectory 'testbin-v1.0.0-x86_64-unknown-linux-gnu.tar.gz'
        $ExpectedArchive | Should -Exist
    }

    It 'RustBinary.Check builds and tests without archiving' {
        { Invoke-Build 'RustBinary.Check' -File $script:TaskFile -BinaryName 'testbin' } | Should -Not -Throw
        $Global:RBCargoCalls | Where-Object { $_ -contains 'build' } | Should -Not -BeNullOrEmpty
        $Global:RBCargoCalls | Where-Object { $_ -contains 'test' } | Should -Not -BeNullOrEmpty
    }

    Context 'collector mode' {
        BeforeEach {
            New-Item -Path $script:CollectorDir -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $script:CollectorDir 'testbin-v1.0.0-x86_64-unknown-linux-gnu.tar.gz') -Value 'fake archive'
        }
        AfterEach {
            Remove-Item -ErrorAction 'SilentlyContinue' -Recurse -Path $script:CollectorDir
        }

        It 'makes no cargo calls and uploads the supplied archives' {
            $BuildParams = @{
                File                   = $script:TaskFile
                BinaryName             = 'testbin'
                ArchiveSourceDirectory = $script:CollectorDir
                Targets                = @('x86_64-unknown-linux-gnu')
                PublishTo              = @('GitHub')
                GitHubReleaseToken     = 'fake-release-token'
            }
            { Invoke-Build Release @BuildParams } | Should -Not -Throw
            $Global:RBCargoCalls.Count | Should -Be 0
            $Global:RBReleases[0].assets.name | Should -Contain 'testbin-v1.0.0-x86_64-unknown-linux-gnu.tar.gz'
            $Global:RBReleases[0].draft | Should -Be $false
        }

        It 'fails FinaliseRelease and leaves the release as a draft when a target archive is missing' {
            $BuildParams = @{
                File                   = $script:TaskFile
                BinaryName             = 'testbin'
                ArchiveSourceDirectory = $script:CollectorDir
                Targets                = @('x86_64-unknown-linux-gnu', 'aarch64-apple-darwin')
                PublishTo              = @('GitHub')
                GitHubReleaseToken     = 'fake-release-token'
            }
            { Invoke-Build Release @BuildParams } | Should -Throw
            Should -Invoke -CommandName Update-GitHubRelease -Times 0
            $Global:RBReleases[0].draft | Should -Be $true
        }
    }

    Context 'StageRelease' {
        BeforeEach {
            $Global:RBCargoTomlPath = Join-Path $Global:BrownserveRepoRootDirectory 'Cargo.toml'
            $Global:RBCargoLockPath = Join-Path $Global:BrownserveRepoRootDirectory 'Cargo.lock'
            $script:CargoTomlPath = $Global:RBCargoTomlPath
            $script:CargoLockPath = $Global:RBCargoLockPath
            Set-Content -Path $script:CargoTomlPath -Value "[workspace.package]`nversion = `"1.0.0`"`n"

            function global:cargo
            {
                $FlatArgs = Get-RBFlattenedArgs -ArgList $args
                if ($FlatArgs -contains 'generate-lockfile')
                {
                    Set-Content -Path $Global:RBCargoLockPath -Value 'lockfile'
                    $Global:RBStageOrderLog += 'UpdateCargoVersion'
                }
                $Global:LASTEXITCODE = 0
            }

            function global:New-BrownserveChangelogEntry
            {
                [CmdletBinding()]
                param(
                    [Parameter(ValueFromPipeline = $true)] $ChangelogObject,
                    $Version, $RepositoryOwner, $RepositoryName, $SinceVersion,
                    [switch]$Auto, $GitHubToken
                )
                return 'Test release notes'
            }
            function global:Add-BrownserveChangelogEntry
            {
                [CmdletBinding()]
                param(
                    [Parameter(ValueFromPipeline = $true)] $ChangelogObject,
                    $NewContent, $ChangelogPath
                )
                process {}
            }
            Mock -CommandName New-GitHubBranch -MockWith {}
            Mock -CommandName New-GitHubCommit -MockWith {
                $Global:RBStageOrderLog += 'CommitTrackedChanges'
            }
            Mock -CommandName New-GitHubPullRequest -MockWith {
                return [PSCustomObject]@{ html_url = 'https://github.invalid/pr/1' }
            }
        }
        AfterEach {
            Remove-Item -ErrorAction 'SilentlyContinue' -Path $script:CargoTomlPath
            Remove-Item -ErrorAction 'SilentlyContinue' -Path $script:CargoLockPath
            Remove-Item -ErrorAction 'SilentlyContinue' -Path @('Function:\New-BrownserveChangelogEntry', 'Function:\Add-BrownserveChangelogEntry')
            Remove-Variable -Scope 'Global' -ErrorAction 'SilentlyContinue' -Name @('RBStageOrderLog', 'RBCargoTomlPath', 'RBCargoLockPath')
        }

        It 'updates Cargo.toml/Cargo.lock and commits them before CommitTrackedChanges finishes' {
            $Global:RBStageOrderLog = @()
            $BuildParams = @{
                File                    = $script:TaskFile
                BinaryName              = 'testbin'
                ReleaseType             = 'minor'
                GitHubReleaseToken      = 'fake-release-token'
            }
            { Invoke-Build StageRelease @BuildParams } | Should -Not -Throw
            Get-Content $script:CargoTomlPath -Raw | Should -Match 'version = "1.1.0"'
            $script:CargoLockPath | Should -Exist
            @($Global:RBStageOrderLog) | Should -Be @('UpdateCargoVersion', 'CommitTrackedChanges')
        }
    }
}
