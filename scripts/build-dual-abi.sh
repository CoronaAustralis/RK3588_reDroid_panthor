#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_ARCH=arm64 STEPS="fetch nativeclc" bash "$HERE/build-all.sh"
for arch in arm64 arm; do
  TARGET_ARCH="$arch" STEPS="sysroot libdrm mesa package verify" bash "$HERE/build-all.sh"
done
