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

### PowerShellModule.tasks.ps1

Builds, documents and releases a Brownserve PowerShell module. Attaches its manifest build to `Build`,
its documentation regeneration to `Stage` (and, via `CreateModuleHelp`, ahead of the generic `Tests`
task, regardless of dot-source order), and its publishers to `Publish`. Ships its own NuGet packaging
tasks under distinct names; it does not reuse `NuGetPackage.tasks.ps1`. Also defines the convenience
targets `BuildAndImport` and `BuildWithDocs`.

Parameters:

| Parameter | Required | Description |
| --- | --- | --- |
| `ModuleName` | Yes | The name of the PowerShell module being built |
| `ModuleGUID` | Yes | The GUID of the module |
| `ModuleDescription` | Yes | The description of the module |
| `ModuleAuthor` | No (defaults to `Brownserve UK`) | The author of the module |
| `ModuleTags` | No (defaults to `brownserve-UK`) | Tags applied to the module |
| `PublishTo` | No | Any of `nuget`, `PSGallery`, `GitHub`, `CustomNugetFeeds` |
| `GitHubRepoOwner` | Yes | GitHub organisation/account |
| `GitHubRepoName` | No (defaults to `$Global:BrownserveRepoName`) | GitHub repository name |
| `GitHubReleaseToken` | If `GitHub` is in `PublishTo` | PAT used to upload release assets |
| `NugetFeedApiKey` | If `nuget` is in `PublishTo` | API key for nuget.org |
| `PSGalleryAPIKey` | If `PSGallery` is in `PublishTo` | API key for the PowerShell Gallery |
| `CustomNugetFeeds` | If `CustomNugetFeeds` is in `PublishTo` | Array of hashtables with `Name`, `Url`, `Credential` and `PublishAs` (`NugetPackage` or `ModulePackage`) |
| `UseWorkingCopy` | No | Loads the working copy of the module from the module directory instead of the stable version restored by `_init.ps1` |

### RustBinary.tasks.ps1

Builds, tests, packages and releases a Rust binary. Attaches `cargo build` to `Build`, `cargo test` to
`Test`, archiving to `Package`, and uploading release archives to `Publish`. Defines the public dotted
targets `RustBinary.Check` (build, test, the Pester binary smoke tests and `CheckForUncommittedChanges`)
and `RustBinary.Package` (build and archive for a single `-Target`), used directly by CI matrix jobs.

Supports a collector mode: when `-ArchiveSourceDirectory` is supplied, no `cargo` commands are invoked.
Instead the archives already built by the `RustBinary.Package` matrix jobs are copied into the build
output directory and uploaded to the draft GitHub release, so a Linux job with no Rust toolchain can run
`Release`.

Parameters:

| Parameter | Required | Description |
| --- | --- | --- |
| `BinaryName` | No (defaults to `$Global:BrownserveRepoName`) | The name of the binary to build and package (without extension) |
| `Target` | No | The Rust target triple to build for, used by `RustBinary.Package`. Defaults to the host target |
| `Targets` | If `GitHub` is in `PublishTo` | Every target triple being released, used to determine the archive names expected on the release |
| `ArchiveSourceDirectory` | No | Directory of pre-built archives to copy into the build output directory and publish. Enables collector mode |
| `PublishTo` | No | Only `GitHub` |
| `GitHubRepoOwner` | Yes | GitHub organisation/account |
| `GitHubRepoName` | No (defaults to `$Global:BrownserveRepoName`) | GitHub repository name |
| `GitHubReleaseToken` | If `GitHub` is in `PublishTo` | PAT used to upload release archives |

### ContainerImage.tasks.ps1

Builds and publishes a Docker container image. Attaches the image build to `Build` and publishing to
`Publish`. Defines the public dotted target `ContainerImage.Check` (build the image, run its Pester
checks and `CheckForUncommittedChanges`, without pushing).

Parameters:

| Parameter | Required | Description |
| --- | --- | --- |
| `ImageName` | No (defaults to `$Global:BrownserveRepoName`) | The Docker image name (without tag), lower-cased automatically |
| `DockerContextPath` | No (defaults to `.`) | Path (relative to the repository root) to the directory containing the Dockerfile and its build context |
| `PublishTo` | No | Any of `DockerHub`, `GHCR` |
| `GitHubRepoOwner` | Yes | GitHub organisation/account, used to build the GHCR image path |
| `DockerHubUsername` | If `DockerHub` is in `PublishTo` | DockerHub username |
| `DockerHubToken` | If `DockerHub` is in `PublishTo` | DockerHub access token |
| `GHCRToken` | If `GHCR` is in `PublishTo` | Token for GitHub Container Registry, needs `packages:write` |

### DirectoryArchive.tasks.ps1

Zips a directory and publishes it as a GitHub release asset. Attaches archiving to `Package` and
uploading to `Publish`.

Parameters:

| Parameter | Required | Description |
| --- | --- | --- |
| `Path` | Yes | The directory to archive, relative to the repository root or absolute |
| `ArchiveName` | Yes | The base name of the archive, e.g. `skills` produces `skills-v1.2.3.zip` |
| `PublishTo` | No | Only `GitHub` |
| `GitHubRepoOwner` | Yes | GitHub organisation/account |
| `GitHubRepoName` | No (defaults to `$Global:BrownserveRepoName`) | GitHub repository name |
| `GitHubReleaseToken` | If `GitHub` is in `PublishTo` | PAT used to upload the archive as a release asset |

### AstroDocs.tasks.ps1

Builds an Astro documentation site with `npm ci` and `npm run build`. Attaches to `Build`. Deployment of
the built site is handled by a separate `deploy-docs` workflow, not by this file.

Parameters:

| Parameter | Required | Description |
| --- | --- | --- |
| `DocsDirectory` | No (defaults to `pages`) | The directory (relative to the repository root) containing the Astro site |

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
| `$Global:BrownserveRustBinaryPath` | `RustBinary.tasks.ps1`'s `CargoBuild` | The path to the compiled binary, unset in collector mode. Binary smoke tests skip when it's unset and fail when it's set but the file is missing |

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
