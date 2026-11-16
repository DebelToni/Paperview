#!/usr/bin/env bash
# Space's engine remains a separately licensed build input, never copied into Paperview.
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
source="${1:?Usage: scripts/build-native-engine.sh /path/to/space [--archives-only]}"
source="$(cd -- "$source" && pwd)"
[[ -f "$source/engine/Cargo.toml" && -f "$source/native/module.modulemap" ]] || { echo 'Expected Space engine source and C ABI headers.' >&2; exit 1; }
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
    cargo rustc --manifest-path "$source/engine/Cargo.toml" --locked --release --lib --crate-type staticlib --target "$target"
done
if [[ "${2:-}" == --archives-only ]]; then exit 0; fi
[[ "$(uname -s)" == Darwin ]] || { echo 'Archives built. XCFramework packaging requires Xcode on macOS.' >&2; exit 1; }
output="$root/Vendor/SpaceEngine.xcframework"
[[ ! -e "$output" ]] || { echo "Remove or move the previous generated framework before rebuilding: $output" >&2; exit 1; }
mkdir -p "$root/Vendor" "$root/build/native-engine/headers"
cp "$source/native/space_engine.h" "$source/native/module.modulemap" "$root/build/native-engine/headers/"
xcrun lipo -create \
    "$source/engine/target/aarch64-apple-ios-sim/release/libspace_engine.a" \
    "$source/engine/target/x86_64-apple-ios/release/libspace_engine.a" \
    -output "$root/build/native-engine/libspace_engine.a"
xcodebuild -create-xcframework \
    -library "$source/engine/target/aarch64-apple-ios/release/libspace_engine.a" -headers "$root/build/native-engine/headers" \
    -library "$root/build/native-engine/libspace_engine.a" -headers "$root/build/native-engine/headers" \
    -output "$output"
