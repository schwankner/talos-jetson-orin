#!/usr/bin/env bash
# r39-compile-check.sh — fast compile check of nvidia-tegra-nvgpu-r39/pkg.yaml, no BuildKit.
#
# The full package build compiles the whole Talos kernel first (about 80 min) just to get a
# kernel build tree. The module compile itself needs far less: the kernel headers, the
# generated files and the Talos .config, which `make modules_prepare` produces in minutes.
# This script prepares that tree with the distro Clang, then runs the package's own
# prepare/build scripts (taken straight from pkg.yaml, so the two cannot drift) against it.
#
# What it catches: source pins and checksums, patch failures, conftest problems, and C
# compile errors in the module set. What it does not catch: link-time symbol resolution
# against the real vmlinux (modpost undefined symbols are only warned about here), signing,
# install paths, and differences between the distro Clang and the Talos LLVM toolchain.
# The full BuildKit build in the workflow stays the authority.
#
# The package's conftest step probes which symbols the kernel exports, so it needs the real
# Module.symvers of the Talos kernel (only a full kernel build makes one). Pass it in
# R39_SYMVERS; the workflow's full BuildKit job exports it into the Actions cache.
#
# Needs: Ubuntu-like host with sudo, apt, curl, python3. Writes /src, /oot-src, /pkg.
# Usage: R39_SYMVERS=/path/to/Module.symvers scripts/r39-compile-check.sh [workdir]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/scripts/common.sh"

PKG_DIR="${REPO_ROOT}/nvidia-tegra-nvgpu-r39"
PKG_YAML="${PKG_DIR}/pkg.yaml"
WORK="${1:-/tmp/r39-fast}"
LOG="${WORK}/build.log"
mkdir -p "${WORK}"

[ -n "${R39_SYMVERS:-}" ] && [ -s "${R39_SYMVERS}" ] \
  || { echo "R39_SYMVERS must point to the Talos kernel's Module.symvers (see header)" >&2; exit 2; }

echo "=== r39 compile check: Talos ${TALOS_VERSION}, kernel ${KERNEL_VERSION}, pkgs ${PKGS_COMMIT} ==="

# ── tools ────────────────────────────────────────────────────────────────────
if ! yq --version 2>/dev/null | grep -q mikefarah; then
  sudo curl -fsSL -o /usr/local/bin/yq \
    https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64
  sudo chmod +x /usr/local/bin/yq
fi
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  clang lld llvm flex bison bc libssl-dev libelf-dev make patch xz-utils >/dev/null
clang --version | head -1

# ── fixed paths the package scripts use ──────────────────────────────────────
for d in /src /oot-src /pkg; do
  sudo rm -rf "${d}"
  sudo mkdir -p "${d}"
  sudo chown "$(id -u):$(id -g)" "${d}"
done
cp -r "${PKG_DIR}/." /pkg/

# ── kernel build tree: Talos config + modules_prepare ────────────────────────
KTAR="${WORK}/linux-${KERNEL_VERSION}.tar.xz"
[ -f "${KTAR}" ] || curl -fsSL -o "${KTAR}" \
  "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
tar xf "${KTAR}" -C /src --strip-components=1
curl -fsSL "https://raw.githubusercontent.com/siderolabs/pkgs/${PKGS_COMMIT}/kernel/build/config-arm64" \
  -o /src/.config

cd /src
# Module signing needs the key material; it does not change what compiles.
scripts/config --disable MODULE_SIG --disable MODULE_SIG_FORCE --disable MODULE_SIG_ALL \
  --set-str MODULE_SIG_KEY "" --set-str SYSTEM_TRUSTED_KEYS "" --disable DEBUG_INFO_BTF
KMAKE=(make -C /src ARCH=arm64 LLVM=1 -j"$(nproc)")
"${KMAKE[@]}" olddefconfig
"${KMAKE[@]}" modules_prepare
test -f /src/include/config/kernel.release
echo "kernel.release: $(cat /src/include/config/kernel.release)"
cp "${R39_SYMVERS}" /src/Module.symvers
echo "Module.symvers: $(wc -l < /src/Module.symvers) symbols"
# modpost only sees the kernel's own exports here, not the other out-of-tree modules' and not
# the Talos build's vmlinux, so warn instead of failing on unresolved symbols
export KBUILD_MODPOST_WARN=1
# the distro Clang is not the Talos LLVM; conftest compares compiler version strings
export IGNORE_CC_MISMATCH=1

# ── package environment, sources, prepare and build scripts from pkg.yaml ─────
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  export "${line%%=*}=${line#*=}"
done < <(yq '.steps[0].env // {} | to_entries | .[] | .key + "=" + (.value | tostring)' "${PKG_YAML}")

SRCDIR="${WORK}/sources"
mkdir -p "${SRCDIR}"
while IFS=$'\t' read -r url dest sha; do
  [ -f "${SRCDIR}/${dest}" ] || curl -fsSL -o "${SRCDIR}/${dest}" "${url}"
  echo "${sha}  ${SRCDIR}/${dest}" | sha256sum -c -
done < <(yq '.steps[0].sources[] | .url + "\t" + .destination + "\t" + .sha256' "${PKG_YAML}")

run_scripts() { # run_scripts <yq path> <workdir>
  local n i
  n=$(yq "${1} | length" "${PKG_YAML}")
  for ((i = 0; i < n; i++)); do
    yq "${1}[${i}]" "${PKG_YAML}" > "${WORK}/step-${1//[^a-z]/}-${i}.sh"
    echo "--- ${1}[${i}]"
    (cd "${2}" && bash -eou pipefail "${WORK}/step-${1//[^a-z]/}-${i}.sh")
  done
}

{
  run_scripts '.steps[0].prepare' "${SRCDIR}"
  run_scripts '.steps[0].build' "${SRCDIR}"
} 2>&1 | tee "${LOG}"

echo "=== modules built ==="
find /oot-src -name '*.ko' | sort
for mod in host1x host1x-fence host1x-nvhost nvhwpm tegra-drm nvmap mc-utils nvgpu tegra_hv ivc_ext; do
  find /oot-src -name "${mod}.ko" | grep -q . && echo "  ✓ ${mod}.ko" || { echo "  ✗ ${mod}.ko MISSING"; exit 1; }
done
echo "✓ r39 compile check passed"
