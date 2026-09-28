#!/bin/bash
set -euo pipefail

# Fork identity is defined here once. The upstream uninstall.sh stays untouched.
APP_NAME="Stats Compact"
BUNDLE_ID="com.tovam.StatsCompact"
HELPER_LABEL="${BUNDLE_ID}.SMC.Helper"
WIDGET_ID="${BUNDLE_ID}.Widgets"
GROUP_ID="${BUNDLE_ID}.widgets"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" && "$#" == 2 ]]; then
    # An explicit synthetic home makes this mode independent of local user data.
    DRY_RUN=1
    UNINSTALL_HOME="$2"
    GUI_UID=501
elif [[ "$#" == 0 ]]; then
    UNINSTALL_HOME="${HOME:?Missing home directory}"
    GUI_UID="$(id -u)"
    if [[ "$GUI_UID" == 0 ]]; then
        test -n "${SUDO_USER:-}" || { echo "Run as the app's user, or through sudo." >&2; exit 1; }
        GUI_UID="$(id -u "$SUDO_USER")"
        UNINSTALL_HOME="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')"
    fi
else
    echo 'Usage: uninstall.sh [--dry-run /absolute/synthetic/home]' >&2
    exit 1
fi

case "$UNINSTALL_HOME" in
    /*/*) ;;
    *) echo "Invalid home directory" >&2; exit 1 ;;
esac
case "$UNINSTALL_HOME" in
    */../*|*/..|*/./*|*/.|*/) echo "Invalid home directory" >&2; exit 1 ;;
esac
[[ "$GUI_UID" =~ ^[0-9]+$ && "$GUI_UID" != 0 ]] || exit 1

run() {
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

run_as_user() {
    if [[ "$DRY_RUN" == 1 ]]; then
        run "$@"
    elif [[ "$(id -u)" == 0 ]]; then
        run sudo -u "$SUDO_USER" "$@"
    else
        run "$@"
    fi
}

remove_path() {
    local target="$1" privileged="${2:-0}"
    if [[ "$DRY_RUN" == 0 ]]; then
        [[ ! -L "$target" ]] || { echo "Refusing symlink: $target" >&2; exit 1; }
        [[ -e "$target" ]] || return 0
        [[ -d "$target" || -f "$target" ]] || { echo "Unexpected file type: $target" >&2; exit 1; }
    fi
    echo "Removing $target..."
    if [[ "$privileged" == 1 ]]; then
        run sudo rm -rf -- "$target"
    else
        run rm -rf -- "$target"
    fi
}

echo "Uninstalling $APP_NAME..."
run_as_user osascript -e "quit app id \"$BUNDLE_ID\"" || true
run_as_user launchctl bootout "gui/$GUI_UID/$BUNDLE_ID" || true
remove_path "$UNINSTALL_HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

run sudo launchctl bootout "system/$HELPER_LABEL" || true
run sudo launchctl unload "/Library/LaunchDaemons/$HELPER_LABEL.plist" || true
remove_path "/Library/LaunchDaemons/$HELPER_LABEL.plist" 1
remove_path "/Library/PrivilegedHelperTools/$HELPER_LABEL" 1

for app in "/Applications/$APP_NAME.app" "$UNINSTALL_HOME/Applications/$APP_NAME.app"; do
    if [[ "$DRY_RUN" == 0 && -e "$app" ]]; then
        [[ ! -L "$app" && -d "$app" ]] || exit 1
        app_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")"
        [[ "$app_id" == "$BUNDLE_ID" ]] || { echo "Unexpected app identity: $app" >&2; exit 1; }
    fi
    remove_path "$app" 1
done

run_as_user security delete-generic-password -s "$BUNDLE_ID.remote" -a access_token || true
run_as_user security delete-generic-password -s "$BUNDLE_ID.remote" -a refresh_token || true
remove_path "$UNINSTALL_HOME/Library/Application Support/$APP_NAME"
remove_path "$UNINSTALL_HOME/Library/Containers/$WIDGET_ID"

if [[ "$DRY_RUN" == 1 ]]; then
    remove_path "$UNINSTALL_HOME/Library/Group Containers/TEAMID1234.$GROUP_ID"
else
    for group in "$UNINSTALL_HOME/Library/Group Containers/"*".$GROUP_ID"; do
        [[ -e "$group" || -L "$group" ]] || continue
        group_name="${group##*/}"
        group_team="${group_name%.$GROUP_ID}"
        [[ "$group_team" =~ ^[A-Z0-9]{10}$ ]] || { echo "Unexpected group: $group" >&2; exit 1; }
        [[ -d "$group" && ! -L "$group" ]] || exit 1
        remove_path "$group"
    done
fi
remove_path "$UNINSTALL_HOME/Library/Group Containers/$GROUP_ID"
run_as_user defaults delete "$BUNDLE_ID" || true
run_as_user defaults delete "$WIDGET_ID" || true
remove_path "$UNINSTALL_HOME/Library/Preferences/$BUNDLE_ID.plist"
remove_path "$UNINSTALL_HOME/Library/Preferences/$WIDGET_ID.plist"

if [[ "$DRY_RUN" == 1 ]]; then
    echo "Dry run complete; no files or services were changed."
else
    echo "$APP_NAME has been uninstalled."
    echo "If fan speeds were controlled manually, they will return to automatic control after a reboot."
fi
