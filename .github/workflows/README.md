# MonoGame automation shell

This directory holds the new automation shell described in the automation baseline report, built in
stages beside the legacy `main.yml`. The legacy workflow is disabled (manual dispatch only) for the
length of the staged test so that nothing but the new lanes runs.

## Lanes

| Workflow | Trigger | Runners | What it does |
|---|---|---|---|
| `pr.yml` | pull requests to `develop` and `release/**`, manual | hosted only | Change classification, actionlint, full build on three images, arm64 natives when relevant, fast and windowed test tiers. One aggregate `PR` check. |
| `ci.yml` | push to `develop` and `release/**`, manual | hosted; self-hosted only when enabled | Same as the PR lane plus macOS tests and package artifacts. Hardware tier and pack block behind stage toggles. |
| `nightly.yml` | manual (cron commented out) | hosted; self-hosted when enabled | Merge lane plus the pack block; placeholders for the expensive Phase D checks. |
| `release.yml` | manual with `version`, `commit`, `dry-run` | hosted | Validates inputs and prints the plan. Refuses a non-dry-run until Phase E. |
| `main.yml` | manual only (was push and pull_request) | hosted and self-hosted | The legacy pipeline, kept intact for side-by-side comparison. |
| `pullrequest_default.yml` | manual only (was pull_request_target) | hosted | Legacy label and milestone defaults, paused with the rest. |

## Building blocks

| Block | Purpose |
|---|---|
| `reusable-build.yml` | Reusable build job. Inputs: `runner`, `profile` (`full` or `natives`), `run-tools-tests`, `upload-packages`, `retention-days`, `timeout-minutes`. Uploads one artifact per output family: `native-*`, `managed-*`, `nuget-*`, `vsix-*`, `tests-<backend>-*`. |
| `reusable-test.yml` | Reusable test job, one per backend. Inputs: `runner`, `runner-class`, `tiers` (JSON array), `backends` (JSON array), `payload-suffix`. Downloads the payload, runs `.github/scripts/run-tests.sh`, uploads results and captured frames. |
| `reusable-pack.yml` | Reusable packaging job. Gathers build outputs and writes a manifest today; packs and validates from Phase D. |
| `../actions/setup-toolchain` | The one place the toolchain is pinned: .NET SDK and workloads, Java, Premake, Vulkan SDK, MSBuild, Xcode, with NuGet and Premake caches. Every component is opt-in. It uses `monogame/monogame-actions/install-android-dependencies` rather than reimplementing it. Local during the fork test; candidate to move into `monogame/monogame-actions` once stable. |
| `monogame/monogame-actions` | Wine, fonts and Android dependencies come from the shared actions repository, pinned by SHA. Nothing there is reimplemented here. |
| `../scripts/classify-changes.sh` | Classifies a PR diff into docs, managed, native, build and templates. |
| `../scripts/run-tests.sh` | Runs the suites that the manifest assigns to a backend, tier set and runner class. |
| `../../Tests/ci-manifest.json` | Test placement: backend × tier × runner class, with the reason for every placement. |

## Test tiers and runner classes

| Tier | Requirement | Runs on |
|---|---|---|
| `fast` | nothing beyond the .NET runtime | hosted Linux, Linux arm64, Windows, macOS |
| `windowed` | a window and a software renderer (xvfb + Mesa, WARP) | hosted Linux, Linux arm64, Windows, macOS |
| `software-gpu` | Mesa llvmpipe or lavapipe | empty until the Phase C measurement pass |
| `hardware` | a real GPU driver or audio device | self-hosted Windows and macOS, merge and nightly lanes only |
| `quarantine` | known broken | never; listed so it is not forgotten |

Runner classes: `hosted-linux`, `hosted-linux-arm64`, `hosted-windows`, `hosted-macos`,
`selfhosted-windows`, `selfhosted-macos`. On hosted Linux every suite is wrapped in `xvfb-run`.

Two placements are deliberately wider than `main.yml` and should be watched in the first shadow runs:
`framework-core` and `gametest` now run on hosted Windows, which the legacy workflow skipped.

## Stage toggles

Repository variables (Settings, Secrets and variables, Actions, Variables). Unset means off.

| Variable | Effect |
|---|---|
| `MG_ENABLE_HARDWARE_TIER=true` | `ci.yml` and `nightly.yml` also run the hardware tier on `windows-selfhosted-latest` and `macos-selfhosted-15`. The self-hosted machines need `bash` and `jq` on PATH. |
| `MG_ENABLE_PACK=true` | `ci.yml` also runs `reusable-pack.yml`. |

## Staged test plan

1. Hosted agents, build and test: open a PR in the fork and run `ci.yml` by hand. Record job durations
   and any suite that fails here but passed in `main.yml` (a placement error until proven otherwise).
2. Hardware tier: set `MG_ENABLE_HARDWARE_TIER`, dispatch `ci.yml`, compare with the legacy runs.
3. Packaging: set `MG_ENABLE_PACK`, then move packing out of the build jobs (Phase D).
4. Release dry run through `release.yml`, then the publish path behind a GitHub Environment (Phase E).

## Re-enabling the legacy workflow

Restore the triggers at the top of `main.yml` to `on: [push, pull_request]` and the
`pull_request_target` block in `pullrequest_default.yml`. Both files are otherwise unchanged.
