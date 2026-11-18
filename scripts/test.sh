#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_binary="$(mktemp -t chu-tests)"
trap 'rm -f "$test_binary"' EXIT
swiftc -module-cache-path /tmp/swift-module-cache -swift-version 6 Sources/ChuLaunchpad/Core/AppIndex.swift Tests/Regression.swift -o "$test_binary"
"$test_binary"

swiftc -module-cache-path /tmp/swift-module-cache -swift-version 6 Sources/ChuLaunchpad/Core/Wallpaper.swift Tests/BackgroundRegression.swift -o "$test_binary"
"$test_binary"

swiftc -module-cache-path /tmp/swift-module-cache -swift-version 6 Sources/ChuLaunchpad/Core/HotKey.swift Sources/ChuLaunchpad/Core/LaunchAtLogin.swift Tests/SettingsRegression.swift -o "$test_binary"
"$test_binary"

swiftc -module-cache-path /tmp/swift-module-cache -swift-version 6 Sources/ChuLaunchpad/Settings/GitHubRelease.swift Sources/ChuLaunchpad/Settings/UpdateManager.swift Tests/UpdateRegression.swift -o "$test_binary"
"$test_binary"

swiftc -module-cache-path /tmp/swift-module-cache -swift-version 6 scripts/entry/DockPin.swift Tests/DockPinRegression.swift -o "$test_binary"
"$test_binary"
