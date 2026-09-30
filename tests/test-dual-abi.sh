#!/usr/bin/env bash
# Real ELF32/ELF64 fixtures. No Android runtime or GPU execution is claimed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
TARGET_ARCH=arm64 CC="${CC_ARM64:-gcc}" TEST_FIXTURE_OUT="$T/arm64" bash "$ROOT/tests/test-image-layout.sh"
TARGET_ARCH=arm CC="${CC_ARM:-arm-linux-gnueabihf-gcc}" TEST_FIXTURE_OUT="$T/arm" bash "$ROOT/tests/test-image-layout.sh"
for arch in arm64 arm; do
  bash "$ROOT/redroid-image/inject-mesa.sh" "$T/$arch" "$T/overlay" "$ROOT/redroid-image/gpu_config.sh" "$arch" > "$T/inject-$arch.log"
done
bash "$ROOT/redroid-image/verify-image.sh" "$T/overlay/vendor" > "$T/verify.log" || { cat "$T/verify.log"; exit 1; }
echo 'PASS: dual-ABI injection preserves both library trees'
expect_failure() {
  local pattern="$1"; shift
  if "$@" > "$T/failure.log" 2>&1; then echo 'FAIL: invalid ABI layout accepted'; exit 1; fi
  grep -F "$pattern" "$T/failure.log" >/dev/null || { cat "$T/failure.log"; exit 1; }
}
expect_failure 'Wrong ABI' bash "$ROOT/redroid-image/inject-mesa.sh" "$T/arm64" "$T/overlay" "$ROOT/redroid-image/gpu_config.sh" arm
# Rejected input must not destroy an existing overlay.
bash "$ROOT/redroid-image/verify-image.sh" "$T/overlay/vendor" > "$T/verify.log"
echo 'PASS: injector rejects ARM64 libraries for ARM32 before modifying overlay'
cp "$T/overlay/vendor/lib64/libc++_shared.so" "$T/overlay/vendor/lib/libc++_shared.so"
expect_failure 'libc++_shared.so' bash "$ROOT/redroid-image/verify-image.sh" "$T/overlay/vendor"
echo 'PASS: verifier rejects wrong-ABI ARM32 runtime'
rm -rf "$T/overlay/vendor/lib"
expect_failure 'Missing vendor/lib (arm)' bash "$ROOT/redroid-image/verify-image.sh" "$T/overlay/vendor"
echo 'PASS: default image verification rejects missing ARM32 tree'
