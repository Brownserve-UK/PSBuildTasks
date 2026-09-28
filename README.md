# PSBuildTasks

Invoke-Build task files shared across Brownserve repositories.

This is not a PowerShell module. It publishes a NuGet package, `Brownserve.PSBuildTasks`, containing
a `tasks/` directory of `*.tasks.ps1` files. Consuming repositories restore it with paket into
`packages/Brownserve.PSBuildTasks/tasks/` and dot-source the files they need from their own
`build_tasks.ps1`.

This repository follows the same conventions as every other Brownserve repository (see
[`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md)): Paket for dependencies, an `Invoke-Build`
based build under `.build/`, and the standard `StageRelease`/`Release` flow.

## Tasks

The `tasks/` directory is currently empty; task files are added in a later change.

## Releases

This repository uses the standard Brownserve `StageRelease`/`Release` flow:

1. Run the `stage-release` workflow (`workflow_dispatch`), which bumps the version and updates
   `CHANGELOG.md` from merged PR labels, then opens a `release/vX.Y.Z` pull request via the GitHub
   API.
2. Review and merge that pull request.
3. Run the `release` workflow (`workflow_dispatch`), which packs the `tasks/` directory into a
   `.nupkg`, publishes it to nuget.org, and publishes a GitHub release with the package attached.
