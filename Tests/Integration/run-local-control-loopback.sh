#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run from the OpenDisplay repository root. Synthetic display system only.
set -euo pipefail
scratch=$(mktemp -d /tmp/opendisplay-loopback.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="$scratch/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/swift"
swift test --scratch-path "$scratch/build" --filter LocalHTTPControlTests
build=$(swift build --scratch-path "$scratch/build" --show-bin-path)
objects=("$build"/{AutomationSchema,DisplayDomain,ProviderInterfaces,SceneEngine,SimulatorProvider,TopologyCore}.build/*.swift.o)
swiftc -swift-version 6 -parse-as-library -module-cache-path "$scratch/clang" \
    -I "$build/Modules" Apps/OpenDisplay/Sources/LocalControlServer.swift \
    Tests/Integration/LocalControlLoopback.swift "${objects[@]}" -o "$scratch/loopback"
"$scratch/loopback"
