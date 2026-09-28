[CmdletBinding()]
param()

$script:AllTaskFilesDummyValues = @{
    ReleaseType             = 'minor'
    BranchName              = 'feature/all-task-files-test'
    DefaultBranch           = 'main'
    GitHubRepoOwner         = 'Brownserve-UK'
    GitHubRepoName          = 'PSBuildTasks'
    GitHubStageReleaseToken = 'fake-stage-token'
    GitHubReleaseToken      = 'fake-release-token'
    PackageId               = 'Test.Package'
    PackageDescription      = 'A test package'
    ModuleName               = 'TestModule'
    ModuleGUID               = [guid]::NewGuid()
    ModuleDescription        = 'A test module'
    BinaryName               = 'testbin'
    ImageName                = 'test-image'
    Path                     = '.'
    ArchiveName               = 'test-archive'
    DocsDirectory             = 'pages'
}

$TasksDirectory = Join-Path $Global:BrownserveRepoRootDirectory 'tasks'
$AllTaskFiles = Get-ChildItem -Path $TasksDirectory -Filter '*.tasks.ps1' -File -Force |
    Sort-Object -Property { $_.Name -ne 'ReleaseLifecycle.tasks.ps1' }, Name

foreach ($TaskFile in $AllTaskFiles)
{
    $Errors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($TaskFile.FullName, [ref]$null, [ref]$Errors)
    $ParamNames = @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $CallParams = @{}
    foreach ($ParamName in $ParamNames)
    {
        if ($script:AllTaskFilesDummyValues.ContainsKey($ParamName))
        {
            $CallParams[$ParamName] = $script:AllTaskFilesDummyValues[$ParamName]
        }
    }
    . $TaskFile.FullName @CallParams
}
