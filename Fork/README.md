# Stats Compact integration

The fork tracks upstream while keeping its publishing and identity-specific code separate.

- `.github/workflows/fork-build.yaml` owns builds, public releases and build tags. Both direct pushes and `sync-upstream.yaml` use it.
- The upstream `build.yaml` and `release.yaml` only add a repository guard. Their concurrency groups must stay different from the fork publisher's group. The upstream signing/notarization workflow must never publish in the fork.
- `Kit/scripts/updater.sh` and `Kit/scripts/uninstall.sh` are the upstream versions. The Xcode resource references select `Kit/scripts/compact/` for the fork, packaged under the unchanged names `Contents/Resources/Scripts/updater.sh` and `Contents/Resources/Scripts/uninstall.sh`. Review relevant upstream script improvements when syncing; do not replace fork identifiers with upstream ones.
- `ForkSettingsView` owns sidebar identity, Remote filtering and selection of the Fork page. `SettingsWindow` keeps a small integration hook and owns reader visibility. The Fork page clears the active module and hides module controls; it must not publish a second, legacy `openWindow` notification.

## Weekly merge policy

`Fork/sync-upstream.sh` performs a real two-parent merge of upstream source. It keeps the entire `.github/workflows/` directory exactly as it was on the fork before that merge, including when upstream adds, removes or conflicts with a workflow. Application source conflicts still fail; there is no global "ours" strategy.

This keeps executable CI configuration under the fork's control and avoids asking the weekly `GITHUB_TOKEN` to modify workflows. Changed upstream workflows are listed with a notice for separate review. They remain available in upstream history, but their new versions are not automatically activated in the fork. During a manual sync, review those changes explicitly and retain the fork publisher and repository guards.

The sync requires a clean checkout, preserves merge ancestry and does not create a commit if upstream is already integrated. A rejected push stops the build/release and publishes Git's reason in the run annotations. `ruby Fork/tests/upstream_sync_test.rb` covers the policy using disposable local repositories only, on both the weekly job and the macOS build.

## Auto-update contract

Existing installations use the latest public release in `tovam/stats-macos`. They do not depend on `build.yaml`.

Preserve all of these when changing builds:

- Release asset: `Stats-Compact.app.zip`, with a GitHub SHA-256 digest.
- Top-level bundle: `Stats Compact.app`; executable: `Stats Compact`.
- Bundle identifier: `com.tovam.StatsCompact`.
- Tag format: `v<upstream version>-statscompact.<GitHub run ID>`.
- `CompactReleaseRepository`, `CompactReleaseTag`, `CompactBuildSHA` and `CompactBuildDate` in the app's Info.plist.
- The release target is the full SHA actually checked out and built, including merges performed by the weekly workflow.
- `Contents/Resources/Scripts/updater.sh` is the fork updater. Do not replace it with the upstream DMG updater.
- Keep `sync-upstream.yaml` named as-is: installed apps query its scheduled runs for weekly health. A newer public release supersedes an earlier weekly failure.

`Fork/verify-release.sh` enforces the bundle contract before packaging and publication, including byte-for-byte comparison with both fork scripts. `ruby Fork/tests/integration_test.rb` tests the publisher wiring, rejects mismatched synthetic bundles, and checks the fork uninstaller using an explicit dry run. The publisher also requires upstream's `make test-smc` to pass before building; the separate, path-filtered SMC workflow alone is not a release gate. Tests only create temporary fixtures inside this repository; they never inspect an installed app or user data.

This reduces conflict-prone edits; it cannot guarantee conflict-free merges when upstream changes the surrounding APIs or lifecycle. After a merge, also check CPU → Fork → closed/minimized settings and the combined popup's reader visibility.
