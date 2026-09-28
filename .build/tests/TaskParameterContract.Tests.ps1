#requires -Modules Pester

BeforeDiscovery {
    $TasksDirectory = Join-Path $Global:BrownserveRepoRootDirectory 'tasks'
    $ReadmePath = Join-Path $Global:BrownserveRepoRootDirectory 'README.md'
    $ReadmeContent = Get-Content -Path $ReadmePath -Raw

    function Get-DocumentedParameterNames
    {
        param
        (
            [string]$Content,
            [string]$Heading
        )
        $Pattern = "(?ms)^### $([regex]::Escape($Heading))\s*$.*?(?=^## |^### |\z)"
        $Match = [regex]::Match($Content, $Pattern)
        if (!$Match.Success)
        {
            throw "Could not find a '### $Heading' section in README.md"
        }
        $Section = $Match.Value
        $Names = [regex]::Matches($Section, '^\|\s*`(\w+)`\s*\|', 'Multiline') |
            ForEach-Object { $_.Groups[1].Value }
        return @($Names)
    }

    $TaskFiles = @(
        Get-ChildItem -Path $TasksDirectory -Filter '*.tasks.ps1' -File -Force | ForEach-Object {
            @{
                FileName         = $_.Name
                FilePath         = $_.FullName
                DocumentedParams = Get-DocumentedParameterNames -Content $ReadmeContent -Heading $_.Name
            }
        }
    )
}

Describe 'Task file parameter contracts' {
    It 'found task files to check' -ForEach @{ TaskFileCount = $TaskFiles.Count } {
        $TaskFileCount | Should -BeGreaterThan 0
    }

    Context '<_.FileName>' -ForEach $TaskFiles {
        BeforeAll {
            $Errors = $null
            $Tokens = $null
            $Ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$Tokens, [ref]$Errors)
            $ParamBlock = $Ast.ParamBlock
        }

        It 'has a param() block' {
            $ParamBlock | Should -Not -BeNullOrEmpty
        }

        It 'documents at least one parameter in the README' {
            $DocumentedParams.Count | Should -BeGreaterThan 0
        }

        It 'declares exactly the parameters documented in the README' {
            $DeclaredParams = @($ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $MissingFromReadme = @($DeclaredParams | Where-Object { $_ -notin $DocumentedParams })
            $MissingFromCode = @($DocumentedParams | Where-Object { $_ -notin $DeclaredParams })
            $MissingFromReadme.Count | Should -Be 0 -Because "these params aren't documented in README.md: $($MissingFromReadme -join ', ')"
            $MissingFromCode.Count | Should -Be 0 -Because "these README params aren't declared in the file: $($MissingFromCode -join ', ')"
        }
    }
}
