#!/usr/bin/env bash
# Static packaging regression tests. Run on Linux arm64 with gcc, binutils, patchelf.
# Tiny ELF fixtures exercise real DT_NEEDED/SONAME rewriting, not GPU execution.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
source "$ROOT/redroid-image/abi.sh" "$TARGET_ARCH"
CC="${CC:-gcc}"
for tool in "$CC" readelf patchelf; do command -v "$tool" >/dev/null; done
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
SRC="$T/prebuilts"
mkdir -p "$SRC/lib/egl" "$SRC/lib/dri" "$SRC/lib/gbm" "$SRC/lib/hw"
cat > "$T/drm.c" <<'EOF'
int drm_fixture(void) { return 1; }
EOF
"$CC" -shared -fPIC -nostdlib -Wl,-soname,libdrm.so -o "$SRC/lib/libdrm.so" "$T/drm.c"
cat > "$T/gallium.c" <<'EOF'
extern int drm_fixture(void);
const char driver[] = "panthor";
const char kmod[] = "panthor_kmod_fixture";
int gallium_fixture(void) { return drm_fixture(); }
EOF
"$CC" -shared -fPIC -nostdlib -Wl,-soname,libgallium_dri.so -o "$SRC/lib/dri/libgallium_dri.so" "$T/gallium.c" -L"$SRC/lib" -l:libdrm.so
ln -s libgallium_dri.so "$SRC/lib/dri/panfrost_dri.so"
"$CC" -shared -fPIC -nostdlib -Wl,-soname,libvulkan_panfrost.so -o "$SRC/lib/hw/libvulkan_panfrost.so" "$T/gallium.c" -L"$SRC/lib" -l:libdrm.so
cat > "$T/egl.c" <<'EOF'
extern int gallium_fixture(void);
int egl_fixture(void) { return gallium_fixture(); }
EOF
for lib in libEGL_mesa libGLESv1_CM_mesa libGLESv2_mesa; do
  "$CC" -shared -fPIC -nostdlib -Wl,-soname,"$lib.so" -o "$SRC/lib/egl/$lib.so" "$T/egl.c" -L"$SRC/lib/dri" -l:libgallium_dri.so
done
cat > "$T/gbm.c" <<'EOF'
int gbm_create_device(void) { return 1; }
EOF
"$CC" -shared -fPIC -nostdlib -Wl,-soname,libgbm_mesa.so.1 -o "$SRC/lib/libgbm_mesa.so.1.0.0" "$T/gbm.c"
cat > "$T/backend.c" <<'EOF'
extern int gbm_create_device(void);
extern int gallium_fixture(void);
int gbmint_get_backend(void) { return gbm_create_device() + gallium_fixture(); }
EOF
"$CC" -shared -fPIC -nostdlib -Wl,-soname,dri_gbm.so -o "$SRC/lib/gbm/dri_gbm.so" "$T/backend.c" -L"$SRC/lib" -l:libgbm_mesa.so.1.0.0 -L"$SRC/lib/dri" -l:libgallium_dri.so
"$CC" -shared -fPIC -nostdlib -Wl,-soname,libc++_shared.so -o "$SRC/lib/libc++_shared.so" "$T/drm.c"

if [ -n "${TEST_FIXTURE_OUT:-}" ]; then
  mkdir -p "$TEST_FIXTURE_OUT"
  cp -a "$SRC/." "$TEST_FIXTURE_OUT/"
fi
bash "$ROOT/redroid-image/inject-mesa.sh" "$SRC" "$T/overlay" "$ROOT/redroid-image/gpu_config.sh" "$TARGET_ARCH" > "$T/inject.log"
L64="$T/overlay/vendor/$LIBDIR"
test "$(readlink "$L64/libgallium_dri.so")" = dri/libgallium_dri.so
needed="$(patchelf --print-needed "$L64/gbm/dri_gbm.so")"
grep -Fxq libgbm.so.1 <<< "$needed"
if grep -Fq libgbm_mesa <<< "$needed"; then echo 'Old GBM dependency survived' >&2; exit 1; fi
# Injection must not change the source prebuilts.
patchelf --print-needed "$SRC/lib/gbm/dri_gbm.so" | grep -Fx libgbm_mesa.so.1 >/dev/null
bash "$ROOT/redroid-image/verify-image.sh" "$T/overlay/vendor" "$TARGET_ARCH" > "$T/verify.log" || { cat "$T/verify.log"; exit 1; }
echo 'PASS: complete backend, Gallium lookup and rewritten GBM dependency'

# Base-image ANGLE is retained, not injected Mesa. Its sibling dependency in egl/
# must not be mistaken for a missing Mesa library at the vendor root.
"$CC" -shared -fPIC -nostdlib -Wl,-soname,libGLESv2_angle.so -o "$L64/egl/libGLESv2_angle.so" "$T/drm.c"
for lib in libEGL_angle libGLESv1_CM_angle; do
  "$CC" -shared -fPIC -nostdlib -Wl,-soname,"$lib.so" -Wl,--no-as-needed -o "$L64/egl/$lib.so" "$T/drm.c" -L"$L64/egl" -l:libGLESv2_angle.so
done
bash "$ROOT/redroid-image/verify-image.sh" "$T/overlay/vendor" "$TARGET_ARCH" > "$T/angle.log" || { cat "$T/angle.log"; exit 1; }
echo 'PASS: retained ANGLE sibling dependencies are outside Mesa validation'

expect_failure() {
  local label="$1" pattern="$2"; shift 2
  if "$@" > "$T/negative.log" 2>&1; then echo "FAIL: accepted $label" >&2; exit 1; fi
  grep -F "$pattern" "$T/negative.log" >/dev/null || { cat "$T/negative.log"; exit 1; }
  echo "PASS: rejects $label"
}
rm "$L64/libgallium_dri.so"
expect_failure 'Gallium only in dri/' 'libgallium_dri.so' bash "$ROOT/redroid-image/verify-image.sh" "$T/overlay/vendor" "$TARGET_ARCH"
ln -s dri/libgallium_dri.so "$L64/libgallium_dri.so"
patchelf --replace-needed libgbm.so.1 libgbm_mesa.so.1 "$L64/gbm/dri_gbm.so"
expect_failure 'unresolved original GBM SONAME' 'libgbm_mesa.so.1' bash "$ROOT/redroid-image/verify-image.sh" "$T/overlay/vendor" "$TARGET_ARCH"
patchelf --replace-needed libgbm_mesa.so.1 libgbm.so.1 "$L64/gbm/dri_gbm.so"
cp "$L64/libdrm.so" "$L64/gbm/dri_gbm.so"
expect_failure 'wrong library used as GBM backend' 'gbmint_get_backend' bash "$ROOT/redroid-image/verify-image.sh" "$T/overlay/vendor" "$TARGET_ARCH"
rm "$L64/gbm/dri_gbm.so"
expect_failure 'missing installed backend' 'gbm/dri_gbm.so' bash "$ROOT/redroid-image/verify-image.sh" "$T/overlay/vendor" "$TARGET_ARCH"
rm "$SRC/lib/gbm/dri_gbm.so"
expect_failure 'old Mesa release without backend' 'Mesa workflow' bash "$ROOT/redroid-image/inject-mesa.sh" "$SRC" "$T/rejected"
