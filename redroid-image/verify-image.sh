#!/usr/bin/env bash
# =============================================================================
# verify-image.sh —— 校验“注入 Mesa 后”的 reDroid 镜像 /vendor 目录（从构建好的镜像
#                    docker cp 出来），出具 PASS/FAIL 汇总。高信号、低噪声。
# =============================================================================
# 用法：verify-image.sh <exported_vendor_dir>
#   exported_vendor_dir : 镜像内 /vendor 的导出副本（含 lib64/ 与 bin/gpu_config.sh）
#
# 校验项：
#   1. 必需文件存在（egl/libEGL_mesa.so、dri/libgallium_dri.so、hw/vulkan.panfrost.so、
#      libgbm.so.1、libdrm.so、libc++_shared.so）
#   2. ARM64 为 ELF64/AArch64，ARM32 为 ELF32/ARM（还需板上验证 Bionic 加载）
#   3. Panthor KMD 证据：libgallium_dri.so 与 vulkan.panfrost.so 含 "panthor" 与 panthor_kmod*
#   4. libgbm.so.1 的 SONAME 恰为 libgbm.so.1（patchelf 生效）；libdrm.so SONAME=libdrm.so
#   5. gpu_config.sh 含 panthor 检测
#   6. 【关键】上游保留二进制(gralloc.gbm.so / hwcomposer.redroid.so / gralloc.cros.so)的
#      DT_NEEDED 中，凡属 Mesa/libdrm/GBM/LLVM 家族者，必须能在本 /vendor/$LIBDIR 树里按名解析到；
#      这直接验证“drop-in 替换”前提是否成立（命名/版本对齐）。
#   7. 我们的 Mesa 库不得 DT_NEED libLLVM*（确认 LLVM-free）
# =============================================================================
set -uo pipefail

V="${1:-}"
if [ "$#" -lt 2 ]; then
  rc=0
  for arch in arm64 arm; do
    echo "=== Verify $arch ==="
    bash "${BASH_SOURCE[0]}" "$V" "$arch" || rc=1
  done
  exit "$rc"
fi
source "$(dirname "${BASH_SOURCE[0]}")/abi.sh" "$2"
[ -n "$V" ] && [ -d "$V/$LIBDIR" ] || { echo "Missing vendor/$LIBDIR ($2)" >&2; exit 2; }
VLIB="$V/$LIBDIR"

READELF="$(command -v readelf || command -v llvm-readelf || true)"
[ -n "$READELF" ] || { echo "缺 readelf" >&2; exit 2; }

PASS=0; FAIL=0
ok()   { echo -e "  \033[1;32mPASS\033[0m $*"; PASS=$((PASS+1)); }
bad()  { echo -e "  \033[1;31mFAIL\033[0m $*"; FAIL=$((FAIL+1)); }
info() { echo      "      $*"; }

# 裸 DT_NEEDED 只在 lib64 根目录检查，不把任意子目录误当成链接器搜索路径。
# 带子目录的参数仅用于下面显式指定的文件检查；这不是完整的 Android namespace 模拟。
resolve_in_vendor() {
  local need="$1"
  [ -f "$VLIB/$need" ] && { echo "$VLIB/$need"; return 0; }
  return 1
}
needed_list() { $READELF -d "$1" 2>/dev/null | sed -nE 's/.*\(NEEDED\).*\[(.+)\]/\1/p'; }
soname_of()   { $READELF -d "$1" 2>/dev/null | sed -nE 's/.*\(SONAME\).*\[(.+)\]/\1/p' | head -1; }

echo "==================== 1. 注入文件存在性 ===================="
declare -A REQ=(
  ["egl/libEGL_mesa.so"]=1 ["egl/libGLESv1_CM_mesa.so"]=1 ["egl/libGLESv2_mesa.so"]=1
  ["dri/libgallium_dri.so"]=1 ["dri/panfrost_dri.so"]=1
  ["libgallium_dri.so"]=1 ["gbm/dri_gbm.so"]=1
  ["hw/vulkan.panfrost.so"]=1
  ["libgbm.so.1"]=1 ["libgbm.so.1.0.0"]=1 ["libdrm.so"]=1 ["libc++_shared.so"]=1
)
for f in "${!REQ[@]}"; do
  if [ -e "$VLIB/$f" ]; then ok "存在 $f"; else bad "缺失 $f"; fi
done

echo "==================== 2. ELF ABI（必须 $2/Bionic）===================="
for f in egl/libEGL_mesa.so egl/libGLESv1_CM_mesa.so egl/libGLESv2_mesa.so dri/libgallium_dri.so gbm/dri_gbm.so hw/vulkan.panfrost.so libgbm.so.1.0.0 libdrm.so libc++_shared.so; do
  p="$(resolve_in_vendor "$f" || true)"; [ -n "$p" ] || continue
  if check_abi "$p"; then ok "$f: ${ELF_CLASS}/${ELF_MACHINE}"; else bad "$f: 非 ${ELF_CLASS}/${ELF_MACHINE}（误入宿主库？）"; fi
done

echo "==================== 3. Panthor KMD（核心）===================="
for f in dri/libgallium_dri.so hw/vulkan.panfrost.so; do
  p="$(resolve_in_vendor "$f" || true)"; [ -n "$p" ] || { bad "$f 不存在，无法验 panthor"; continue; }
  n_panthor="$(strings -a "$p" 2>/dev/null | grep -cw 'panthor' || true)"
  n_kmod="$(strings -a "$p" 2>/dev/null | grep -c 'panthor_kmod' || true)"
  if [ "${n_panthor:-0}" -ge 1 ]; then ok "$f: 含独立字符串 \"panthor\" x$n_panthor"; else bad "$f: 未见 \"panthor\""; fi
  if [ "${n_kmod:-0}" -ge 1 ]; then ok "$f: 含 panthor_kmod* x$n_kmod"; else bad "$f: 未见 panthor_kmod*"; fi
done

echo "==================== 4. SONAME 对齐 ===================="
if [ -e "$VLIB/libgbm.so.1.0.0" ]; then
  s="$(soname_of "$VLIB/libgbm.so.1.0.0")"
  if [ "$s" = "libgbm.so.1" ]; then ok "libgbm.so.1.0.0 SONAME=libgbm.so.1（上游 gralloc.gbm.so 可解析）"; else bad "libgbm SONAME=$s（期望 libgbm.so.1）"; fi
fi
if [ -e "$VLIB/libdrm.so" ]; then
  s="$(soname_of "$VLIB/libdrm.so")"
  if [ "$s" = "libdrm.so" ]; then ok "libdrm.so SONAME=libdrm.so"; else bad "libdrm SONAME=$s（期望 libdrm.so）"; fi
fi

echo "==================== 5. gpu_config.sh panthor 检测 ===================="
if [ -f "$V/bin/gpu_config.sh" ]; then
  if grep -q 'panthor' "$V/bin/gpu_config.sh"; then ok "/vendor/bin/gpu_config.sh 含 panthor 检测"; else bad "gpu_config.sh 不含 panthor"; fi
  if grep -Eq 'ro\.hardware\.egl[[:space:]]+mesa' "$V/bin/gpu_config.sh"; then ok "gpu_config.sh 设 ro.hardware.egl=mesa"; else bad "gpu_config.sh 未设 egl=mesa"; fi
else
  bad "/vendor/bin/gpu_config.sh 缺失"
fi

echo "==================== 6. 上游保留二进制的 Mesa 依赖可解析（drop-in 前提）===================="
# 只针对 Mesa/libdrm/GBM/LLVM 家族名做硬校验；系统库(liblog/libutils/...)默认在 /system 存在，不在此校验。
mesa_family() { case "$1" in libgbm*|libdrm*|libLLVM*|libgallium*|libc++_shared*|libEGL_*|libGLESv*|libvulkan_*|vulkan.*|libglapi*) return 0;; *) return 1;; esac; }
KEPT="$(find "$VLIB/hw" -maxdepth 1 \( -name 'gralloc.*.so' -o -name 'hwcomposer.redroid.so' -o -name 'audio.primary.redroid.so' \) -type f 2>/dev/null)"
if [ -z "$KEPT" ]; then
  info "（未在 /vendor/$LIBDIR/hw 找到 gralloc.*/hwcomposer.redroid.so；可能 base 布局不同，跳过）"
else
  for k in $KEPT; do
    kn="$(basename "$k")"; unresolved=""
    while read -r nd; do
      [ -n "$nd" ] || continue
      mesa_family "$nd" || continue
      resolve_in_vendor "$nd" >/dev/null || unresolved="$unresolved $nd"
    done < <(needed_list "$k")
    if [ -z "$unresolved" ]; then ok "$kn 的 Mesa 系依赖均可在 /vendor/$LIBDIR 解析"; else bad "$kn 未解析依赖:$unresolved"; fi
    info "$kn NEEDED(mesa系): $(needed_list "$k" | grep -E 'libgbm|libdrm|libLLVM|libgallium|libc\+\+_shared|libEGL_|libGLESv|vulkan' | tr '\n' ' ')"
  done
fi

echo "==================== 7. 我们的 Mesa 库 LLVM-free ===================="
for f in dri/libgallium_dri.so egl/libEGL_mesa.so hw/vulkan.panfrost.so libgbm.so.1.0.0 gbm/dri_gbm.so; do
  p="$(resolve_in_vendor "$f" || true)"; [ -n "$p" ] || continue
  if needed_list "$p" | grep -q 'libLLVM'; then bad "$f 仍 DT_NEED libLLVM"; else ok "$f 无 libLLVM 依赖"; fi
done

echo "==================== 8. 注入库依赖与 GBM 动态入口 ===================="
# 只检查本次替换的 Mesa 库。上游 ANGLE、VA 驱动等有自己的加载规则，
# 不能因它们仍在 egl/dri 目录就套用本次 Mesa 依赖布局的断言。
INJECTED=(
  egl/libEGL_mesa.so egl/libGLESv1_CM_mesa.so egl/libGLESv2_mesa.so
  dri/libgallium_dri.so gbm/dri_gbm.so
  libgbm.so.1.0.0 hw/vulkan.panfrost.so libdrm.so libc++_shared.so
)
for f in "${INJECTED[@]}"; do
  p="$VLIB/$f"
  [ -f "$p" ] || continue  # 必需文件缺失已由第 1 节报告。
  while IFS= read -r nd; do
    mesa_family "$nd" || continue
    if resolve_in_vendor "$nd" >/dev/null; then
      ok "$f -> $nd"
    else
      bad "$f 的依赖不在 /vendor/$LIBDIR 搜索根目录: $nd"
    fi
  done < <(needed_list "$p")
done
if $READELF --dyn-syms -W "$VLIB/gbm/dri_gbm.so" 2>/dev/null |
    awk '$5 == "GLOBAL" && $6 == "DEFAULT" && $7 != "UND" && $8 ~ /^gbmint_get_backend(@|$)/ { found=1 } END { exit !found }'; then
  ok "dri_gbm.so 导出 gbmint_get_backend"
else
  bad "dri_gbm.so 缺动态后端入口 gbmint_get_backend"
fi

echo "==================== 汇总 ===================="
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  \033[1;32m✅ 静态校验通过：Mesa 系依赖路径和 GBM 后端已检查；仍需在 Panthor 宿主上验证启动与硬件加速。\033[0m"
  exit 0
else
  echo -e "  \033[1;31m❌ 有 $FAIL 项未过；见上。\033[0m"
  exit 1
fi
