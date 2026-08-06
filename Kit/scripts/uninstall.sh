#!/bin/sh

set -u

HELPER_LABEL="com.tovam.StatsCompact.SMC.Helper"

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    HOME=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')
fi

run_as_user() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" "$@"
    else
        "$@"
    fi
}

echo "Uninstalling Stats Compact..."

run_as_user osascript -e 'quit app "Stats Compact"' >/dev/null 2>&1 || true

echo "Removing the SMC helper (administrator privileges are required)..."
sudo launchctl bootout "system/$HELPER_LABEL" 2>/dev/null || true
sudo launchctl unload "/Library/LaunchDaemons/$HELPER_LABEL.plist" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$HELPER_LABEL.plist"
sudo rm -f "/Library/PrivilegedHelperTools/$HELPER_LABEL"

for app in "/Applications/Stats Compact.app" "$HOME/Applications/Stats Compact.app"; do
    if [ -d "$app" ]; then
        echo "Removing $app..."
        sudo rm -rf "$app"
    fi
done

echo "Removing application data and preferences..."
rm -rf "$HOME/Library/Application Support/Stats Compact"
rm -rf "$HOME/Library/Containers/com.tovam.StatsCompact.Widgets"
rm -rf "$HOME/Library/Group Containers/"*.com.tovam.StatsCompact.widgets
run_as_user defaults delete com.tovam.StatsCompact >/dev/null 2>&1 || true
run_as_user defaults delete com.tovam.StatsCompact.Widgets >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/com.tovam.StatsCompact.plist"
rm -f "$HOME/Library/Preferences/com.tovam.StatsCompact.Widgets.plist"

echo "Stats Compact has been uninstalled."
echo "If fan speeds were controlled manually, they will return to automatic control after a reboot."
