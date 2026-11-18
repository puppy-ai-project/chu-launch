#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_binary="$(mktemp -t nova-tests)"
trap 'rm -f "$test_binary"' EXIT
swiftc -module-cache-path /tmp/swift-module-cache -swift-version 6 Sources/NovaLaunchpad/Core/AppIndex.swift Tests/Regression.swift -o "$test_binary"
"$test_binary"

swiftc -module-cache-path /tmp/swift-module-cache -swift-version 6 Sources/NovaLaunchpad/Core/Wallpaper.swift Tests/BackgroundRegression.swift -o "$test_binary"
"$test_binary"
