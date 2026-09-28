#requires -Modules Pester, InvokeBuild

BeforeAll {
    $script:TaskFile = Join-Path $Global:BrownserveRepoTestsDirectory 'Fixtures' 'AstroDocsOnly.tasks.ps1'
    $script:DocsDirRelative = '.tmp-astro-docs-test'
    $script:DocsDir = Join-Path $Global:BrownserveRepoRootDirectory $script:DocsDirRelative
    New-Item -Path $script:DocsDir -ItemType Directory -Force | Out-Null

    function global:npm
    {
        $Global:ADNpmCalls += , @($args)
        $Global:LASTEXITCODE = 0
    }
}

AfterAll {
    Remove-Item -ErrorAction 'SilentlyContinue' -Path 'Function:\npm'
    Remove-Variable -Scope 'Global' -ErrorAction 'SilentlyContinue' -Name 'ADNpmCalls'
    Remove-Item -ErrorAction 'SilentlyContinue' -Recurse -Path $script:DocsDir
}

Describe 'AstroDocs build behaviour' {
    BeforeEach {
        $Global:ADNpmCalls = [System.Collections.Generic.List[object]]::new()
    }

    It 'runs npm ci and npm run build from the configured docs directory' {
        Invoke-Build Build -File $script:TaskFile -DocsDirectory $script:DocsDirRelative | Out-Null
        $Global:ADNpmCalls.Count | Should -Be 2
        $Global:ADNpmCalls[0] -join ' ' | Should -Be 'ci'
        $Global:ADNpmCalls[1] -join ' ' | Should -Be 'run build'
    }
}
