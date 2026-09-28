#requires -Modules Pester, PSScriptAnalyzer

BeforeDiscovery {
    $FilesToCheck = @(Get-ChildItem -Path $Global:BrownserveRepoBuildDirectory -Filter '*.ps1' -Recurse -File -Force)
    $TasksDirectory = Join-Path $Global:BrownserveRepoRootDirectory 'tasks'
    if (Test-Path $TasksDirectory)
    {
        $FilesToCheck += @(Get-ChildItem -Path $TasksDirectory -Filter '*.ps1' -Recurse -File -Force)
    }
}

Describe 'Task and build script files' {
    It 'finds the build scripts to check' {
        @(Get-ChildItem -Path $Global:BrownserveRepoBuildDirectory -Filter '*.ps1' -Recurse -File -Force).Count | Should -BeGreaterThan 0
    }

    Context '<_.Name>' -ForEach $FilesToCheck {
        It 'parses without errors' {
            $Errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$Errors) | Out-Null
            $Errors.Count | Should -Be 0 -Because ($Errors | Out-String)
        }

        It 'has no PSScriptAnalyzer errors' {
            $Findings = Invoke-ScriptAnalyzer -Path $_.FullName -Severity 'Error'
            $Findings.Count | Should -Be 0 -Because ($Findings | Out-String)
        }
    }
}
