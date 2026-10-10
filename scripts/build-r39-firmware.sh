#!/usr/bin/env bash
# build-r39-firmware.sh — build the JetPack r39 GA10B firmware Talos system extension
#
#   nvidia-firmware-ext:<FIRMWARE_EXT_TAG>   the 17 GA10B files of nvidia-l4t-firmware
#
# The deb comes from NVIDIA's apt repository, component "som" of dist r39.2
# (https://repo.download.nvidia.com/jetson/som; r39 has no "t234" component, and
# "jetson/common" only carries a few L4T packages). Version and SHA-256 are pinned below
# (from dists/r39.2/main/binary-arm64/Packages). The userspace libraries are not part of the
# image: manifests/gpu/cdi-setup-r39.yaml downloads them on the node, like r36 does.
#
# Usage:
#   JETPACK=r39 scripts/build-r39-firmware.sh              assemble + verify (+ image check if docker is there)
#   JETPACK=r39 PUSH=1 REGISTRY_DOCKER=ghcr.io/<owner> scripts/build-r39-firmware.sh
# Env: WORK (default /tmp/r39-firmware), PUSH (default 0), APT_BASE / L4T_REL / FW_DEB_SHA256 (pins).
set -euo pipefail
source "$(dirname "$0")/common.sh"

[[ "${JETPACK}" == "r39" ]] || error "This script builds the JetPack r39 extension; run it with JETPACK=r39."

WORK="${WORK:-/tmp/r39-firmware}"
PUSH="${PUSH:-0}"
APT_BASE="${APT_BASE:-https://repo.download.nvidia.com/jetson/som}"
L4T_REL="${L4T_REL:-39.2.1-20260806224157}"
FW_DEB_SHA256="${FW_DEB_SHA256:-ab95bcddebe7e49accb1a951a32052ec4cf3bb5e54c13407c9f0a89894f58178}"
DEB="nvidia-l4t-firmware_${L4T_REL}_arm64.deb"
X="${WORK}/x"
OUT="${WORK}/out"

rm -rf "${X}" "${OUT}"
mkdir -p "${WORK}" "${X}" "${OUT}"

info "r39 firmware extension: ${FIRMWARE_EXT_TAG} from ${DEB}"

# ── 1. the deb ───────────────────────────────────────────────────────────────
if [[ ! -f "${WORK}/${DEB}" ]]; then
  curl -fsSL --retry 3 -o "${WORK}/${DEB}" "${APT_BASE}/pool/main/n/nvidia-l4t-firmware/${DEB}"
fi
GOT=$(sha256sum "${WORK}/${DEB}" | cut -d' ' -f1)
[[ "${GOT}" == "${FW_DEB_SHA256}" ]] \
  || error "${DEB} checksum mismatch: got ${GOT}, expected ${FW_DEB_SHA256}"
dpkg-deb -x "${WORK}/${DEB}" "${X}"
info "  ${DEB}: checksum OK"

# ── 2. firmware ──────────────────────────────────────────────────────────────
FW_SRC="${X}/lib/firmware/nvidia/ga10b"
[[ -d "${FW_SRC}" ]] || error "ga10b firmware directory not found in nvidia-l4t-firmware"
FW_OUT="${OUT}/firmware/rootfs/usr/lib/firmware"
mkdir -p "${FW_OUT}"
# same layout as the r36 extension: /usr/lib/firmware/ga10b (nvgpu asks for nvidia/ga10b/<file>,
# then ga10b/<file>; firmware_class.path=/usr/lib/firmware is on the kernel command line)
cp -a "${FW_SRC}" "${FW_OUT}/ga10b"
for must in gpmu_ucode_next_prod_image.bin pmu_pkc_prod_sig.bin fecs_encrypt_prod.bin gpccs_encrypt_prod.bin; do
  [[ -s "${FW_OUT}/ga10b/${must}" ]] || error "firmware file missing or empty: ${must}"
done
info "firmware: $(find "${FW_OUT}/ga10b" -type f | wc -l) files, $(du -sh "${FW_OUT}/ga10b" | cut -f1)"

# ── 3. extension manifest and build context ──────────────────────────────────
# The Talos imager parses manifest.yaml strictly; an unquoted ": " in a description once broke an
# extension, so quote it and parse the result.
check_yaml() { # check_yaml <file>
  if command -v yq >/dev/null 2>&1; then yq '.' "$1" >/dev/null
  elif python3 -c 'import yaml' 2>/dev/null; then python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$1"
  else warn "no YAML parser available, ${1} not checked"; fi
}
CTX="${OUT}/firmware"
printf 'version: v1alpha1\nmetadata:\n  name: nvidia-firmware-ext\n  version: %s\n  author: custom-build\n  description: "NVIDIA GA10B firmware from JetPack 7.2 (Jetson Linux %s)"\n  compatibility:\n    talos:\n      version: ">= 1.12.6"\n' \
  "${FIRMWARE_EXT_TAG}" "${L4T_REL}" > "${CTX}/manifest.yaml"
check_yaml "${CTX}/manifest.yaml" || error "invalid YAML in ${CTX}/manifest.yaml"
printf 'FROM scratch\nCOPY manifest.yaml /manifest.yaml\nCOPY rootfs /rootfs\n' > "${CTX}/Dockerfile"

# ── 4. image ─────────────────────────────────────────────────────────────────
if [[ "${PUSH}" == "1" ]]; then
  [[ -n "${REGISTRY_DOCKER:-}" ]] || error "PUSH=1 needs REGISTRY_DOCKER (e.g. ghcr.io/<owner>)"
  docker buildx build --platform linux/arm64 \
    -t "${REGISTRY_DOCKER}/nvidia-firmware-ext:${FIRMWARE_EXT_TAG}" --push "${CTX}/"
  info "pushed ${REGISTRY_DOCKER}/nvidia-firmware-ext:${FIRMWARE_EXT_TAG}"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker buildx build --platform linux/arm64 --output "type=local,dest=${OUT}/image-firmware" "${CTX}/" >/dev/null
  info "image check: $(find "${OUT}/image-firmware" -type f | wc -l) files in the image"
else
  info "no docker: skipped the image build (assembly and verification done)"
fi
info "done"
