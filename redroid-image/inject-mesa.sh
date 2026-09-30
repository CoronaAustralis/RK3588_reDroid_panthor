#!/usr/bin/env bash
# =============================================================================
# inject-mesa.sh —— 把交叉构建的 Mesa/PanVK/GBM 预编译产物排布成一个 /vendor
#                   overlay，用于 drop-in 替换上游 reDroid arm64 镜像里的 Mesa 栈，
#                   命名/路径严格对齐 device_redroid-prebuilts/Android.mk。
# =============================================================================
# 用法：inject-mesa.sh <prebuilts_arch_dir> <overlay_out_dir> [gpu_config.sh] [arm64|arm]
#   prebuilts_arch_dir  : 含 lib/{egl,dri,hw}、lib/libgbm_mesa.so*、lib/libdrm.so、
#                         lib/libc++_shared.so、share/vulkan/icd.d/（即 run #9 tarball 解出的
#                         prebuilts/arm64 目录）
#   overlay_out_dir     : 产出 overlay，overlay/vendor/... 对应镜像内 /vendor/...
#                         （Dockerfile 用 `COPY overlay/ /`）
#
# 命名对齐（依据：移植清单 6.2/6.3 + device_redroid-prebuilts/Android.mk + 实测 SONAME）：
#   * EGL/GLES : libEGL_mesa.so* / libGLESv*_mesa.so*  -> /vendor/$LIBDIR/egl/  （原样；ro.hardware.egl=mesa）
#   * DRI      : libgallium_dri.so(+ *_dri.so 软链)    -> /vendor/$LIBDIR/dri/   （原样；含 panfrost+panthor KMD）
#   * Vulkan   : libvulkan_panfrost.so                 -> /vendor/$LIBDIR/hw/vulkan.panfrost.so
#                【改名】Android Vulkan loader 按路径 dlopen /vendor/$LIBDIR/hw/vulkan.<ro.hardware.vulkan>.so，
#                ro.hardware.vulkan=panfrost(见 gpu_config.sh) => vulkan.panfrost.so。SONAME 不参与按路径加载。
#   * GBM      : libgbm_mesa.so.1.0.0(SONAME=libgbm_mesa.so.1)
#                -> /vendor/$LIBDIR/libgbm.so.1.0.0，并用 patchelf 把 SONAME 改为 libgbm.so.1，
#                   再建软链 libgbm.so.1 / libgbm.so。上游 gralloc.gbm.so DT_NEEDED=libgbm.so.1；
#                   dri_gbm.so 的 DT_NEEDED 也必须同步改名。mesa 因 platform-sdk-version>=30 把 gbm 命名为 gbm_mesa
#                   （src/gbm/meson.build:20-22），API33 无法回避，故在此对齐上游 libgbm.so.1。
#   * libdrm   : libdrm.so(SONAME=libdrm.so，Android 约定无版本号) -> /vendor/$LIBDIR/libdrm.so，
#                另建别名软链 libdrm.so.2 -> libdrm.so（上游保留二进制可能 DT_NEED libdrm.so.2）。
#                Bionic 按 realpath 去重，两个名字解析到同一 soinfo，单实例，无双份全局态。
#   * libc++   : libc++_shared.so -> /vendor/$LIBDIR/libc++_shared.so（原样；NDK 运行时）
#   * gpu_config.sh(panthor 版) -> /vendor/bin/gpu_config.sh（覆盖上游只认 panfrost 的版本）
#   * Vulkan ICD json(可选)     -> /vendor/etc/vulkan/icd.d/
#
# 绝不触碰 reDroid 自身的 gralloc.gbm.so / hwcomposer.redroid.so / audio.primary.redroid.so /
# uinputd / vncserver / VA 系列（清单 6.3：gralloc/HWC 走上游不重建）。本脚本只覆盖 Mesa/libdrm 派生库。
# =============================================================================
set -euo pipefail

log()  { echo "[inject-mesa] $*"; }
die()  { echo "[inject-mesa] ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

SRC="${1:-}"; OUT="${2:-}"; GPUCFG="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gpu_config.sh}"
[ -n "$SRC" ] && [ -n "$OUT" ] || die "用法：inject-mesa.sh <prebuilts_arch_dir> <overlay_out_dir> [gpu_config.sh] [arm64|arm]"
[ -d "$SRC/lib" ] || die "源目录无 lib/：$SRC"
[ -f "$SRC/lib/gbm/dri_gbm.so" ] || die "Mesa 产物缺 lib/gbm/dri_gbm.so；请先用修复后的 Mesa workflow 重新构建，不能使用旧 Release"
have patchelf || die "缺 patchelf（apt-get install patchelf / brew install patchelf）"

source "$(dirname "${BASH_SOURCE[0]}")/abi.sh" "${4:-arm64}"
# Validate input before changing the overlay. ARM64 files cannot serve ARM32 processes.
while IFS= read -r -d '' f; do
  check_abi "$f" || die "Wrong ABI: $f (expected $ELF_CLASS/$ELF_MACHINE)"
done < <(find "$SRC/lib" -type f -name '*.so*' -print0)
VLIB="$OUT/vendor/$LIBDIR"
# Only reset this ABI; the other ABI may already be staged in the same overlay.
rm -rf "$VLIB"
mkdir -p "$VLIB/egl" "$VLIB/dri" "$VLIB/gbm" "$VLIB/hw" "$OUT/vendor/bin" "$OUT/vendor/etc/vulkan/icd.d"

# --- 1) EGL / GLES：原样连软链一起拷（-a 保留相对软链） ------------------------
for f in "$SRC"/lib/egl/*; do [ -e "$f" ] || continue; cp -a "$f" "$VLIB/egl/"; done
log "EGL/GLES -> /vendor/$LIBDIR/egl : $(ls "$VLIB/egl" | tr '\n' ' ')"
[ -e "$VLIB/egl/libEGL_mesa.so" ] || die "未产出 libEGL_mesa.so（源 EGL 缺失？）"

# --- 2) DRI：libgallium_dri.so + *_dri.so 软链，原样拷 ------------------------
for f in "$SRC"/lib/dri/*; do [ -e "$f" ] || continue; cp -a "$f" "$VLIB/dri/"; done
log "DRI -> /vendor/$LIBDIR/dri : $(ls "$VLIB/dri" | tr '\n' ' ')"
[ -e "$VLIB/dri/libgallium_dri.so" ] || die "未产出 libgallium_dri.so"
# sphal 的按名依赖搜索不会递归进入 dri/；保留一个可在 lib64 根目录解析的入口。
ln -s dri/libgallium_dri.so "$VLIB/libgallium_dri.so"

# --- 3) Vulkan HAL：libvulkan_panfrost.so -> vulkan.panfrost.so（改名） ---------
VK_SRC="$(find "$SRC/lib/hw" -maxdepth 1 -name 'libvulkan_*.so' -type f | head -1)"
[ -n "$VK_SRC" ] || die "源无 libvulkan_*.so（PanVK 缺失？）"
VK_NAME="$(basename "$VK_SRC")"                 # libvulkan_panfrost.so
VK_DRV="${VK_NAME#libvulkan_}"; VK_DRV="${VK_DRV%.so}"   # panfrost
cp -a "$VK_SRC" "$VLIB/hw/vulkan.${VK_DRV}.so"
log "Vulkan -> /vendor/$LIBDIR/hw/vulkan.${VK_DRV}.so （源 $VK_NAME，ro.hardware.vulkan=${VK_DRV}）"

# --- 4) GBM：改 SONAME 为 libgbm.so.1，落成 libgbm.so.1.0.0 + 软链 -------------
GBM_REAL="$(find "$SRC/lib" -maxdepth 1 -name 'libgbm*.so.*.*' -type f | head -1)"
[ -n "$GBM_REAL" ] || GBM_REAL="$(find "$SRC/lib" -maxdepth 1 -name 'libgbm*.so*' -type f | head -1)"
[ -n "$GBM_REAL" ] || die "源无 libgbm 实体库"
OLD_SONAME="$(patchelf --print-soname "$GBM_REAL" 2>/dev/null || echo '(none)')"
cp -a "$GBM_REAL" "$VLIB/libgbm.so.1.0.0"
patchelf --set-soname libgbm.so.1 "$VLIB/libgbm.so.1.0.0"
ln -sf libgbm.so.1.0.0 "$VLIB/libgbm.so.1"
ln -sf libgbm.so.1.0.0 "$VLIB/libgbm.so"
log "GBM  -> /vendor/$LIBDIR/libgbm.so.1.0.0  SONAME: $OLD_SONAME -> $(patchelf --print-soname "$VLIB/libgbm.so.1.0.0") (+ libgbm.so.1, libgbm.so)"

# 动态后端与 libgbm/Gallium 必须来自同一份构建产物。
for f in "$SRC"/lib/gbm/*_gbm.so; do
  [ -e "$f" ] || continue
  cp -a "$f" "$VLIB/gbm/"
done
# 改 libgbm 的 SONAME 后，更新所有注入 ELF 的旧依赖，不能只改库文件名。
if [ -n "$OLD_SONAME" ] && [ "$OLD_SONAME" != '(none)' ] && [ "$OLD_SONAME" != libgbm.so.1 ]; then
  while IFS= read -r -d '' f; do
    needed="$(patchelf --print-needed "$f")"
    if grep -Fxq "$OLD_SONAME" <<< "$needed"; then
      patchelf --replace-needed "$OLD_SONAME" libgbm.so.1 "$f"
    fi
  done < <(find "$VLIB" -type f -name '*.so*' -print0)
fi
log "GBM backend -> /vendor/$LIBDIR/gbm/dri_gbm.so（依赖已对齐 libgbm.so.1）"

# --- 5) libdrm：libdrm.so(SONAME=libdrm.so) + 别名 libdrm.so.2 ----------------
DRM_REAL="$(find "$SRC/lib" -maxdepth 1 -name 'libdrm.so*' -type f | head -1)"
[ -n "$DRM_REAL" ] || die "源无 libdrm.so"
cp -a "$DRM_REAL" "$VLIB/libdrm.so"
ln -sf libdrm.so "$VLIB/libdrm.so.2"     # 供上游保留二进制 DT_NEED libdrm.so.2；realpath 去重
log "libdrm -> /vendor/$LIBDIR/libdrm.so  SONAME=$(patchelf --print-soname "$VLIB/libdrm.so") (+ 别名 libdrm.so.2)"

# --- 6) libc++_shared（NDK 运行时）-------------------------------------------
if [ -e "$SRC/lib/libc++_shared.so" ]; then
  cp -a "$SRC/lib/libc++_shared.so" "$VLIB/libc++_shared.so"
  log "libc++_shared.so -> /vendor/$LIBDIR/"
else
  log "WARN: 源无 libc++_shared.so（将依赖镜像内已有的 NDK 运行时）"
fi

# --- 7) Vulkan ICD json（可选；Android 主要靠 ro.hardware.vulkan） -------------
if compgen -G "$SRC/share/vulkan/icd.d/*.json" >/dev/null 2>&1; then
  cp -a "$SRC"/share/vulkan/icd.d/*.json "$OUT/vendor/etc/vulkan/icd.d/" 2>/dev/null || true
  log "Vulkan ICD json -> /vendor/etc/vulkan/icd.d : $(ls "$OUT/vendor/etc/vulkan/icd.d" | tr '\n' ' ')"
fi

# --- 8) gpu_config.sh（panthor 检测版）----------------------------------------
[ -f "$GPUCFG" ] || die "缺 gpu_config.sh：$GPUCFG"
cp -a "$GPUCFG" "$OUT/vendor/bin/gpu_config.sh"
chmod 0755 "$OUT/vendor/bin/gpu_config.sh"
grep -q 'panthor' "$OUT/vendor/bin/gpu_config.sh" || die "gpu_config.sh 不含 panthor 检测（用错版本？）"
log "gpu_config.sh(panthor) -> /vendor/bin/gpu_config.sh (0755)"

# --- 汇总 ---------------------------------------------------------------------
echo ""
log "overlay 就绪：$OUT"
find "$OUT" -maxdepth 4 \( -type f -o -type l \) | sort | sed "s#$OUT#  overlay#"
log "下一步：Dockerfile 用 'COPY overlay/ /' 覆盖到 base 镜像（见 build-image.sh）"
