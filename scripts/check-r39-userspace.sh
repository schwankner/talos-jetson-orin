#!/usr/bin/env bash
# check-r39-userspace.sh — run the restore-libs.sh of manifests/gpu/cdi-setup-r39.yaml (the very
# script the node's init container runs) against NVIDIA's apt repository and verify the result:
# AArch64 ELF files, libcuda.so.1 present and large, the two libraries libcuda dlopen()s at cuInit,
# and the DT_NEEDED closure complete inside the directory (system libraries excepted).
#
# Usage: scripts/check-r39-userspace.sh [workdir]     (needs curl, dpkg-deb, readelf, yq)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${ROOT}/manifests/gpu/cdi-setup-r39.yaml"
WORK="${1:-$(mktemp -d)}"
DEST="${WORK}/tegra"
mkdir -p "${WORK}"

yq -N 'select(.kind == "ConfigMap").data."restore-libs.sh"' "${MANIFEST}" > "${WORK}/restore-libs.sh"
[[ -s "${WORK}/restore-libs.sh" ]] || { echo "[ERROR] restore-libs.sh not found in ${MANIFEST}" >&2; exit 1; }
sh -n "${WORK}/restore-libs.sh"

DEST="${DEST}" sh "${WORK}/restore-libs.sh"
echo "--- second run must skip"
DEST="${DEST}" sh "${WORK}/restore-libs.sh" | grep -q "already present" \
  || { echo "[ERROR] second run did not skip" >&2; exit 1; }

fail=0
is_system_lib() {
  case "$1" in
    libc.so*|libm.so*|libdl.so*|librt.so*|libpthread.so*|libgcc_s.so*|libstdc++.so*|libutil.so*|libresolv.so*|ld-linux-aarch64.so*) return 0 ;;
  esac
  return 1
}
for f in "${DEST}"/*; do
  [[ -L "${f}" ]] && continue
  readelf -h "${f}" | grep -q AArch64 || { echo "[ERROR] not an AArch64 ELF: ${f##*/}" >&2; fail=1; }
  while IFS= read -r n; do
    is_system_lib "${n}" && continue
    [[ -e "${DEST}/${n}" ]] || { echo "[ERROR] ${f##*/} needs ${n}, not in the output" >&2; fail=1; }
  done < <(readelf -d "${f}" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
done
size=$(stat -c %s "${DEST}/libcuda.so.1.1" 2>/dev/null || echo 0)
(( size > 50000000 )) || { echo "[ERROR] libcuda.so.1.1 is only ${size} bytes" >&2; fail=1; }
for l in libcuda.so.1 libcuda.so libnvcucompat.so libnvcuextend.so libnvrm_gpu.so libnvsciipc.so; do
  [[ -e "${DEST}/${l}" ]] || { echo "[ERROR] ${l} missing" >&2; fail=1; }
done
(( fail == 0 )) || exit 1
echo "[OK] r39 userspace: $(find "${DEST}" -maxdepth 1 -type f ! -name '.*' | wc -l) libraries, libcuda.so.1.1 ${size} bytes, closure complete"
