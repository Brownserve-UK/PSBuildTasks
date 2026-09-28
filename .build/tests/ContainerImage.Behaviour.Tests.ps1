#requires -Modules Pester, InvokeBuild

BeforeAll {
    $script:TaskFile = Join-Path $Global:BrownserveRepoTestsDirectory 'Fixtures' 'ContainerImageOnly.tasks.ps1'

    function global:docker
    {
        $Global:CIDockerCalls += , @($args)
        if ($args -contains 'login')
        {
            $Global:CIDockerLoginStdin += , @($input)
        }
        $Global:LASTEXITCODE = 0
    }

    function Get-CICommonBuildParams
    {
        param([string[]]$PublishTo = @('DockerHub', 'GHCR'))
        return @{
            File               = $script:TaskFile
            ImageName          = 'test-image'
            PublishTo          = $PublishTo
            DockerHubUsername  = 'fake-dh-user'
            DockerHubToken     = 'fake-dh-token'
            GHCRToken          = 'fake-ghcr-token'
        }
    }
}

AfterAll {
    Remove-Item -ErrorAction 'SilentlyContinue' -Path 'Function:\docker'
    Remove-Variable -Scope 'Global' -ErrorAction 'SilentlyContinue' -Name @('CIDockerCalls', 'CIDockerLoginStdin', 'CIReleaseVersion', 'BrownserveRepoDockerImageName')
}

Describe 'ContainerImage build behaviour' {
    BeforeEach {
        $Global:CIDockerCalls = [System.Collections.Generic.List[object]]::new()
        $Global:CIDockerLoginStdin = [System.Collections.Generic.List[object]]::new()
        $Global:CIReleaseVersion = '1.2.3'

        Mock -CommandName Read-BrownserveChangelog -MockWith {
            [PSCustomObject]@{
                VersionHistory = @(
                    [PSCustomObject]@{
                        Version      = $Global:CIReleaseVersion
                        PreRelease   = $false
                        ReleaseNotes = 'Test release notes'
                    }
                )
            }
        }
        Mock -CommandName Get-GitChanges -MockWith { return $null }
        Mock -CommandName Invoke-Pester -MockWith { return [PSCustomObject]@{ FailedCount = 0 } }
    }

    It 'ContainerImage.Check builds the image without pushing anything' {
        Invoke-Build ContainerImage.Check -File $script:TaskFile | Out-Null
        $BuildCalls = @($Global:CIDockerCalls | Where-Object { $_ -contains 'build' })
        $PushCalls = @($Global:CIDockerCalls | Where-Object { $_ -contains 'push' })
        $BuildCalls.Count | Should -Be 1
        $PushCalls.Count | Should -Be 0
    }

    It 'Release pushes the version tag and latest to each configured registry' {
        $BuildParams = Get-CICommonBuildParams
        Invoke-Build Release @BuildParams | Out-Null
        $PushCalls = @($Global:CIDockerCalls | Where-Object { $_ -contains 'push' } | ForEach-Object { $_ -join ' ' })
        $PushCalls | Where-Object { $_ -like "*fake-dh-user/test-image:$Global:CIReleaseVersion*" } | Should -Not -BeNullOrEmpty
        $PushCalls | Where-Object { $_ -like '*fake-dh-user/test-image:latest*' } | Should -Not -BeNullOrEmpty
        $PushCalls | Where-Object { $_ -like "*ghcr.io/brownserve-uk/test-image:$Global:CIReleaseVersion*" } | Should -Not -BeNullOrEmpty
        $PushCalls | Where-Object { $_ -like '*ghcr.io/brownserve-uk/test-image:latest*' } | Should -Not -BeNullOrEmpty
    }

    It 'logs in using --password-stdin rather than passing the token on the command line' {
        $BuildParams = Get-CICommonBuildParams -PublishTo @('DockerHub')
        Invoke-Build Release @BuildParams | Out-Null
        $LoginCalls = @($Global:CIDockerCalls | Where-Object { $_ -contains 'login' })
        $LoginCalls.Count | Should -Be 1
        $LoginCalls[0] | Should -Contain '--password-stdin'
        $LoginCalls[0] -join ' ' | Should -Not -Match 'fake-dh-token'
        $Global:CIDockerLoginStdin[0] | Should -Contain 'fake-dh-token'
    }

    It 'DryRun pushes nothing' {
        $BuildParams = Get-CICommonBuildParams
        Invoke-Build DryRun @BuildParams | Out-Null
        $PushCalls = @($Global:CIDockerCalls | Where-Object { $_ -contains 'push' })
        $LoginCalls = @($Global:CIDockerCalls | Where-Object { $_ -contains 'login' })
        $PushCalls.Count | Should -Be 0
        $LoginCalls.Count | Should -Be 0
    }
}
