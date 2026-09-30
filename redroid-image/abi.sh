#!/usr/bin/env bash
# Source with the architecture in $1.
case "${1:-arm64}" in
  arm64) LIBDIR=lib64; ELF_CLASS=ELF64; ELF_MACHINE=AArch64 ;;
  arm) LIBDIR=lib; ELF_CLASS=ELF32; ELF_MACHINE=ARM ;;
  *) echo "Unsupported ABI: $1" >&2; exit 2 ;;
esac
check_abi() {
  local header
  header="$(LC_ALL=C "${READELF:-readelf}" -h "$1")" || return 1
  grep -Eq "Class:[[:space:]]+$ELF_CLASS[[:space:]]*$" <<< "$header" &&
    grep -Eq "Machine:[[:space:]]+$ELF_MACHINE[[:space:]]*$" <<< "$header"
}
