# Stats Compact integration

The fork tracks upstream while keeping its publishing and identity-specific code separate.

- `.github/workflows/fork-build.yaml` owns builds, public releases and build tags. Both direct pushes and `sync-upstream.yaml` use it.
- The upstream `build.yaml` only adds a repository guard. Its concurrency group must stay different from the fork publisher's group.
- `Kit/scripts/uninstall.sh` is the upstream version. The Xcode resource reference selects `Kit/scripts/compact/uninstall.sh` for the fork, packaged under the unchanged name `Contents/Resources/Scripts/uninstall.sh`. Review relevant upstream uninstall improvements when syncing; do not replace fork identifiers with upstream ones.
- `ForkSettingsView` owns sidebar identity, Remote filtering and selection of the Fork page. `SettingsWindow` keeps a small integration hook and owns reader visibility. The Fork page clears the active module and hides module controls; it must not publish a second, legacy `openWindow` notification.

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

`Fork/verify-release.sh` enforces the bundle contract before packaging and publication. `ruby Fork/tests/integration_test.rb` tests the publisher wiring, rejects mismatched synthetic bundles, and checks the fork uninstaller using an explicit dry run. Tests only create temporary fixtures inside this repository; they never inspect an installed app or user data.

This reduces conflict-prone edits; it cannot guarantee conflict-free merges when upstream changes the surrounding APIs or lifecycle. After a merge, also check CPU → Fork → closed/minimized settings and the combined popup's reader visibility.
