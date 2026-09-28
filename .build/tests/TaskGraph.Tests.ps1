#requires -Modules Pester, InvokeBuild

BeforeAll {
    $script:BuildTasksFile = Join-Path $Global:BrownserveRepoBuildTasksDirectory 'build_tasks.ps1'
    $TasksArray = Invoke-Build ? -File $script:BuildTasksFile `
        -PackageId 'Test.Package' `
        -PackageDescription 'Test' `
        -BranchName 'feature/test' `
        -DefaultBranch 'main' `
        -GitHubRepoOwner 'Brownserve-UK' `
        -GitHubRepoName 'PSBuildTasks'
    $script:Tasks = @{}
    foreach ($Task in $TasksArray)
    {
        $script:Tasks[$Task.Name] = $Task
    }
}

Describe 'Composed task graph' {
    It 'loads without executing any task body' {
        $script:Tasks | Should -Not -BeNullOrEmpty
    }

    Context 'anchor tasks' {
        It 'defines the <_> anchor' -ForEach @('Build', 'Test', 'Check', 'Package', 'Stage', 'Publish') {
            $script:Tasks.Keys | Should -Contain $_
        }
    }

    Context 'meta tasks' {
        It 'defines the <_> meta task' -ForEach @('BuildAndTest', 'BuildTestAndCheck', 'StageRelease', 'DryRun', 'Release') {
            $script:Tasks.Keys | Should -Contain $_
        }
    }

    It 'attaches the generic Tests task to the Test anchor' {
        $script:Tasks['Test'].Jobs | Should -Contain 'Tests'
    }

    It 'attaches NuGet packaging to the Package anchor' {
        $script:Tasks['Package'].Jobs | Should -Contain 'PackNuGetPackage'
    }

    It 'attaches NuGet publishing to the Publish anchor' {
        $script:Tasks['Publish'].Jobs | Should -Contain 'PublishToNuGet'
        $script:Tasks['Publish'].Jobs | Should -Contain 'UploadNuGetPackageReleaseAsset'
    }

    It 'runs CreateDraftRelease before Publish, and Publish before FinaliseRelease, in Release' {
        $Jobs = @($script:Tasks['Release'].Jobs)
        $DraftIndex = $Jobs.IndexOf('CreateDraftRelease')
        $PublishIndex = $Jobs.IndexOf('Publish')
        $FinaliseIndex = $Jobs.IndexOf('FinaliseRelease')
        $DraftIndex | Should -BeGreaterThan -1
        $PublishIndex | Should -BeGreaterThan $DraftIndex
        $FinaliseIndex | Should -BeGreaterThan $PublishIndex
    }

    It 'does not run CreateDraftRelease, Publish or FinaliseRelease as part of DryRun' {
        $Jobs = @($script:Tasks['DryRun'].Jobs)
        $Jobs | Should -Not -Contain 'CreateDraftRelease'
        $Jobs | Should -Not -Contain 'Publish'
        $Jobs | Should -Not -Contain 'FinaliseRelease'
    }
}

Describe 'Every component task file composed together' {
    AfterAll {
        Remove-Variable -Scope 'Global' -ErrorAction 'SilentlyContinue' -Name @('BrownserveRepoDockerImageName', 'BrownserveRustBinaryPath')
    }

    BeforeAll {
        $script:AllFixtureFile = Join-Path $Global:BrownserveRepoTestsDirectory 'Fixtures' 'AllTaskFiles.tasks.ps1'
        $AllTasksArray = Invoke-Build ? -File $script:AllFixtureFile
        $script:AllTasks = @{}
        foreach ($Task in $AllTasksArray)
        {
            $script:AllTasks[$Task.Name] = $Task
        }
        $script:ComponentTaskFileCount = @(
            Get-ChildItem -Path (Join-Path $Global:BrownserveRepoRootDirectory 'tasks') -Filter '*.tasks.ps1' -File -Force
        ).Count
    }

    It 'loads every task file without duplicate task names or bad references' {
        $script:AllTasks.Count | Should -BeGreaterThan 0
    }

    It 'discovered more than one task file' {
        $script:ComponentTaskFileCount | Should -BeGreaterThan 1
    }

    Context 'public dotted targets' {
        It 'defines the <_> target' -ForEach @('RustBinary.Check', 'RustBinary.Package', 'ContainerImage.Check') {
            $script:AllTasks.Keys | Should -Contain $_
        }
    }

    Context 'PowerShellModule convenience targets' {
        It 'defines the <_> target' -ForEach @('BuildAndImport', 'BuildWithDocs') {
            $script:AllTasks.Keys | Should -Contain $_
        }
    }

    It 'attaches PowerShellModule, RustBinary, ContainerImage, DirectoryArchive and AstroDocs contributions to Build' {
        $Jobs = @($script:AllTasks['Build'].Jobs)
        $Jobs | Should -Contain 'CreateModuleManifest'
        $Jobs | Should -Contain 'CargoBuild'
        $Jobs | Should -Contain 'BuildImage'
        $Jobs | Should -Contain 'BuildAstroDocs'
    }

    It 'attaches RustBinary CargoTest to Test' {
        $script:AllTasks['Test'].Jobs | Should -Contain 'CargoTest'
    }

    It 'loads the PowerShellModule working copy before the release history is read' {
        @($script:AllTasks['GetReleaseHistory'].Jobs)[0] | Should -Be 'UseWorkingCopy'
    }

    It 'attaches component archiving/packaging contributions to Package' {
        $Jobs = @($script:AllTasks['Package'].Jobs)
        $Jobs | Should -Contain 'PackNuGetPackage'
        $Jobs | Should -Contain 'PackModuleNuGetPackage'
        $Jobs | Should -Contain 'CreateBinaryArchive'
        $Jobs | Should -Contain 'CopyCollectedArchives'
        $Jobs | Should -Contain 'CreateDirectoryArchive'
    }

    It 'attaches component publishing contributions to Publish' {
        $Jobs = @($script:AllTasks['Publish'].Jobs)
        $Jobs | Should -Contain 'PublishModuleToNuGet'
        $Jobs | Should -Contain 'PublishModuleToPSGallery'
        $Jobs | Should -Contain 'PublishBinaryReleaseAssets'
        $Jobs | Should -Contain 'PublishContainerImage'
        $Jobs | Should -Contain 'UploadDirectoryArchiveReleaseAsset'
    }

    It 'attaches PowerShellModule documentation and RustBinary version bump to Stage' {
        $Jobs = @($script:AllTasks['Stage'].Jobs)
        $Jobs | Should -Contain 'UpdateModuleDocumentation'
        $Jobs | Should -Contain 'UpdateCargoVersion'
    }

    It 'runs the PowerShellModule documentation chain before the generic Tests task' {
        $script:AllTasks['Tests'].Jobs | Should -Contain 'CreateModuleHelp'
    }
}
