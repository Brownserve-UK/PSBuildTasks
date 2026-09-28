# PSBuildTasks

Invoke-Build task files shared across Brownserve repositories.

This is not a PowerShell module. It publishes a NuGet package, `Brownserve.PSBuildTasks`, containing
a `tasks/` directory of `*.tasks.ps1` files. Consuming repositories restore it with paket into
`packages/Brownserve.PSBuildTasks/tasks/` and dot-source the files they need from their own
`build_tasks.ps1`, passing each file's parameters explicitly:

```powershell
$TasksDir = Join-Path $Global:BrownserveRepoNugetPackagesDirectory 'Brownserve.PSBuildTasks' 'tasks'

. (Join-Path $TasksDir 'ReleaseLifecycle.tasks.ps1') -BranchName $BranchName -DefaultBranch $DefaultBranch -GitHubRepoOwner $GitHubRepoOwner -GitHubRepoName $GitHubRepoName
. (Join-Path $TasksDir 'NuGetPackage.tasks.ps1') -PackageId $PackageId -PackageDescription $PackageDescription -GitHubRepoOwner $GitHubRepoOwner -GitHubRepoName $GitHubRepoName
```

`ReleaseLifecycle.tasks.ps1` must always be dot-sourced first: every other task file depends on the
tasks, script variables and the `Invoke-BrownserveRetry` helper it defines.

This repository is itself a consumer, dot-sourcing `tasks/` from its own working tree (rather than a
restored package) so it can release the tasks it's currently changing; see
[`.build/tasks/build_tasks.ps1`](.build/tasks/build_tasks.ps1).

## Task files

### ReleaseLifecycle.tasks.ps1

Defines the fixed meta tasks and anchor tasks every build composes, plus the changelog, versioning and
GitHub staging/release plumbing shared by every component. Must always be loaded; every other task file
depends on it.

Parameters:

| Parameter | Required | Description |
| --- | --- | --- |
| `ReleaseType` | For `StageRelease` | `major`, `minor` or `patch` |
| `BranchName` | Yes | The branch being built |
| `DefaultBranch` | Yes | This repository's default branch |
| `PublishTo` | No | Publish destinations. This file only acts on `GitHub`; other values are for other task files to interpret |
| `GitHubRepoOwner` | Yes | GitHub organisation/account |
| `GitHubRepoName` | No (defaults to `$Global:BrownserveRepoName`) | GitHub repository name |
| `GitHubStageReleaseToken` | For `StageRelease` | PAT with pull request read/write and issue read permissions |
| `GitHubReleaseToken` | For `Release` | PAT with release read/write permissions |

### NuGetPackage.tasks.ps1

Packs this repository's own content into a NuGet package and publishes it. Attaches its packaging task
to the `Package` anchor and its publish tasks to the `Publish` anchor.

Parameters:

| Parameter | Required | Description |
| --- | --- | --- |
| `PackageId` | Yes | The NuGet package id |
| `PackageDescription` | Yes | The package description |
| `PackageAuthor` | No (defaults to `Brownserve UK`) | The package author |
| `PackageTags` | No (defaults to `brownserve-UK`) | Tags applied to the package |
| `PublishTo` | No | Any of `nuget`, `GitHub`, `CustomNugetFeeds` |
| `GitHubRepoOwner` | Yes | GitHub organisation/account |
| `GitHubRepoName` | No (defaults to `$Global:BrownserveRepoName`) | GitHub repository name |
| `GitHubReleaseToken` | If `GitHub` is in `PublishTo` | PAT used to upload the `.nupkg` as a release asset |
| `NugetFeedApiKey` | If `nuget` is in `PublishTo` | API key for nuget.org |
| `CustomNugetFeeds` | If `CustomNugetFeeds` is in `PublishTo` | Array of hashtables with `Name`, `Url` and `Credential` |

## Anchors

`ReleaseLifecycle.tasks.ps1` defines a fixed set of empty anchor tasks that component task files attach
their own tasks to using Invoke-Build's `-Before`/`-After` parameters (e.g.
`task PackNuGetPackage -Before Package { ... }`). The generated `build_tasks.ps1` only ever chooses which
task files to dot-source; it never defines meta or anchor tasks itself.

| Anchor | Purpose |
| --- | --- |
| `Build` | Compiling/building a component. Also the meta task for a plain build, so it doubles as its own anchor |
| `Test` | Running a component's tests. The generic `Tests` task (Pester over `.build/tests/`) always attaches here |
| `Check` | Static/validation checks that don't belong under `Test` (e.g. linting). Empty until a component needs it |
| `Package` | Producing a publishable artifact (e.g. a `.nupkg`, a container image) |
| `Stage` | Contributions that must complete before the staging commit (e.g. bumping a version file). Everything attached here finishes before `CommitTrackedChanges` runs |
| `Publish` | Publishing artifacts to their destinations. Runs between `CreateDraftRelease` and `FinaliseRelease` |

Meta tasks compose the anchors:

- `BuildAndTest` = `Build`, `Test`
- `BuildTestAndCheck` = `BuildAndTest`, `Check`, `CheckForUncommittedChanges`
- `StageRelease` = staging parameter checks, changelog update, `CreateStagingBranch`, `CommitTrackedChanges`
  (which itself depends on `Stage`), `CreatePullRequest`
- `DryRun` = `BuildAndTest`, `Package`, `CheckForUncommittedChanges` (no publication or remote release-state
  changes)
- `Release` = `BuildAndTest`, `Package`, `CheckForUncommittedChanges`, `CreateDraftRelease`, `Publish`,
  `FinaliseRelease`

## Shared state contract

Task files share state through script-scoped variables set by `ReleaseLifecycle.tasks.ps1` (since every
task file is dot-sourced into the same script scope):

| Variable | Set by | Description |
| --- | --- | --- |
| `$script:Changelog` | `GetReleaseHistory` | The parsed changelog object |
| `$script:CurrentVersion` / `$script:NewVersion` | `SetVersion` | The current and to-be-released version |
| `$script:PrefixedVersion` | `SetVersion` | `$script:NewVersion` prefixed with `v`, used for tags/branches |
| `$script:PreRelease` | Top level / `SetVersion` | Whether this is a pre-release build |
| `$script:CurrentCommitHash` | `SetVersion` | The commit being built, used for the release's `target_commitish` |
| `$script:TrackedFiles` | `UpdateChangelog` and component `Stage` contributions | Files to include in the staging commit |
| `$script:ReleaseNotes` / `$script:CleanReleaseNotes` | `FormatReleaseNotes` | Raw and markdown-stripped release notes |
| `$Global:BuildVersion` | `SetVersion` | The NuGet-compatible version string used across every publisher |
| `$script:ReleaseResponse` | `CreateDraftRelease` | The GitHub API response for the draft release (`.id`, `.upload_url`, `.assets`, ...) |
| `$script:ExpectedReleaseAssets` | Initialised by `ReleaseLifecycle.tasks.ps1`, appended to by publisher tasks | Asset file names `FinaliseRelease` requires to be present before publishing the release |

A shared retry helper, `Invoke-BrownserveRetry`, is also defined by `ReleaseLifecycle.tasks.ps1`. Publisher
tasks route their network calls through it: transient failures (timeouts, HTTP 5xx, rate limiting, honouring
`Retry-After`) are retried up to 3 times with exponential backoff; authentication (401/403) and validation
(400/422) errors fail immediately.

## Release policy

`Release` is resumable. `CreateDraftRelease` creates the GitHub release as a draft and reuses an existing
draft for the same tag rather than failing, provided it targets the same commit; a draft targeting a
different commit, or a published (non-draft) release for the tag, fails the build before anything is
published. Every `Publish` contribution is expected to be idempotent (`PublishToNuGet` uses
`-SkipDuplicate`/`--skip-duplicate`; `UploadNuGetPackageReleaseAsset` skips an asset already present with
the same name and size). `FinaliseRelease` runs last, only once every configured publisher has succeeded,
verifies every name in `$script:ExpectedReleaseAssets` is present on the release, and only then marks it as
no longer a draft.

## Releases

This repository uses the standard Brownserve `StageRelease`/`Release` flow:

1. Run the `stage-release` workflow (`workflow_dispatch`), which bumps the version and updates
   `CHANGELOG.md` from merged PR labels, then opens a `release/vX.Y.Z` pull request via the GitHub
   API.
2. Review and merge that pull request.
3. Run the `release` workflow (`workflow_dispatch`), which packs the `tasks/` directory into a
   `.nupkg`, publishes it to nuget.org, and publishes a GitHub release with the package attached.
