# JetPack 7.2 (Jetson Linux r39 / CUDA 13) on Orin — opt-in build line

`JETPACK=r39` selects a second build line. The default stays `r36` (JetPack 6.x, OE4T r36.5 sources) and
nothing about the r36 line changes. The r39 line builds the GPU driver from NVIDIA's own r39.2.1 sources and
uses the r39 userspace, which provides the CUDA 13 driver libraries.

**Status.** Tested on an Orin NX 16 GB (Seeed reComputer J401) with Talos v1.14.2 / kernel 6.18.54: the board's
QSPI flashed to r39.2.0, all modules load, `cuInit` succeeds, llama.cpp (a CUDA 12.6 container image) runs on the
GPU at about 22 tok/s generation for an 8B MoE model, a 2-hour mixed-prompt load test ran without errors or
kernel faults, and the node cold-booted cleanly after a power loss. CUDA 13 *container* images were not tried.

## What is different from r36

| | r36 (default) | r39 (`JETPACK=r39`) |
|---|---|---|
| nvgpu package | `nvidia-tegra-nvgpu/` (OE4T `patches-r36.5`) | `nvidia-tegra-nvgpu-r39/` (NVIDIA gitlab, tag `jetson_39.2.1`) |
| Extension tag | `5.13.0-drm-noshim-<kernel>-talos` | `39.2.1-jp7-<kernel>-talos` |
| Firmware extension | `nvidia-firmware-ext:v5` (r36 apt, component `t234`) | `nvidia-firmware-ext:r39-v1` (`scripts/build-r39-firmware.sh`) |
| Userspace libraries | downloaded on the node (`t234` apt) | downloaded on the node (`som` apt, `manifests/gpu/cdi-setup-r39.yaml`) |
| Board firmware (QSPI) | JetPack 6 | **JetPack 7 (r39.2.0) must be flashed**, see below |

The kernel, the in-tree modules (`kernel-modules-clang`) and the base installer are shared by both lines. With
`JETPACK=r39` the build reuses them when they are already in the registry.

## Using it

```bash
# CI: Actions -> "Build Extensions" or "Build USB Image" -> choose jetpack = r39
# local: JETPACK=r39 make build-extensions
```

On the node: flash the board's QSPI (below), install the r39 installer image, and apply
`manifests/gpu/cdi-setup-r39.yaml` instead of `cdi-setup.yaml`. The machine config's kernel module list for
r39 is, in this order: `ivc_ext`, `tegra_hv`, `host1x`, `host1x_nvhost`, `host1x_fence`, `nvhwpm`, `tegra_drm`,
`nvmap`, `mc_utils`, `nvgpu`, `governor_pod_scaling` (the `modprobe.d` softdeps in the extension also make
`modprobe` pull the dependencies in).

## Sources and pins

The r39 sources are not on OE4T (it has no r39 branch of `linux-nvgpu`, and `linux-nv-oot` only has r38.x
branches for Thor). They come from NVIDIA's gitlab; use the commit SHA, not the tag object SHA, in tarball URLs.

| Repo (`gitlab.com/nvidia/nv-tegra/...`) | `jetson_39.2.1` (used) | `jetson_39.2.0` (fallback) |
|---|---|---|
| `linux-nv-oot` | `e71bacb7c611f880c5f341263967f13de54de3a9` | `2385c9c5cb99c44636cb5b738bfad5572b38386b` |
| `linux-hwpm` | `80b966b1bdc20f896cc9625a84708cbbe4638e38` | `80b966b1bdc20f896cc9625a84708cbbe4638e38` |
| `tegra/kernel-src/linux-nvgpu` | `fc23d33512d3bf1361b201e31406c47762102429` | `74a58d0f4dc6f0a1e6137cb0be9b95599cdb1fd6` |

r39.2.1 over r39.2.0: the `nvgpu` source is the same, and `linux-nv-oot` has one commit with three nvmap
out-of-bounds fixes (offset/length checks in `nvmap_handle.c` and `nvmap_ioctl.c`). The GPU, host1x and memory
controller device-tree nodes are the same in both, so r39.2.1 modules run on r39.2.0 firmware. To fall back,
replace the three URLs and checksums in `nvidia-tegra-nvgpu-r39/pkg.yaml`.

## What the r39 package needs beyond r36 (all in `nvidia-tegra-nvgpu-r39/`)

- `CONFIG_DRM_TEGRA_HAVE_DISPLAY` and `CONFIG_HOST1X_HAVE_SYNCPT_BASE`, both as `-D` flags and as exported make
  variables (the modules are built per directory, so the top-level Kconfig is not seen; without the first one
  `host1x/dev.c` misses a struct field, without the second modpost reports `tegra_mipi_driver` as undefined).
- Two extra modules: `tegra_hv` and `ivc_ext`. NVIDIA's kernel has these symbols built in; the Talos kernel does
  not. Both stay inert on bare metal.
- `patches/nvidia-oot/0001-tegra-drm-headless-no-fbdev.patch` (same idea as the r36 patch: no fbdev emulation)
  and `0002-nvmap-ivc-stubs-without-sciipc.patch` (nvmap calls IVC functions that need NvSciIpc, which is not
  built; no-op stubs, no inter-VM sharing). `CONFIG_*_SCIIPC` is off.
- `KBUILD_MODPOST_WARN=1` plus an own final unresolved-symbol check (cross-module `nvhost_*` references resolve
  only once all modules are built), and `llvm-strip --strip-debug` before signing (`nvgpu.ko` is 12 MB instead
  of 414 MB).

## Userspace and firmware

r39 has no `t234` apt component. The Orin packages are in the **`som`** component:
`https://repo.download.nvidia.com/jetson/som`, dist `r39.2`. `manifests/gpu/cdi-setup-r39.yaml` downloads three
debs (`nvidia-l4t-core`, `nvidia-l4t-cuda-nvgpu`, `nvidia-l4t-cuda`, 26 MB, version and SHA-256 pinned in the
script) once per version and installs the closure of `libcuda.so.1` into `/var/lib/nvidia-tegra-libs/tegra`.
Two things that are easy to miss:

- `libcuda` `dlopen()`s `libnvcucompat.so` and `libnvcuextend.so` at `cuInit` (they are not in its `DT_NEEDED`
  list; both are in `nvidia-l4t-cuda`). Without `libnvcucompat.so`, `cuInit` returns 999 and nothing else is
  logged.
- The GA10B firmware must match the driver. The CDI setup copies the firmware to `/var/fw-fresh` and points
  `firmware_class.path` there; `/var` survives node upgrades, so a copy made once keeps older firmware in front
  of the new one. With the r36 PMU firmware the r39 `nvgpu` does not boot the PMU (`pwr_falcon_exterrstat
  0xbadf....`) and then dereferences NULL in its stall interrupt thread, which hard-resets the node on GPU
  power-on, with no panic record. The r39 manifest syncs the files on every start.

`scripts/check-r39-userspace.sh` (workflow "Check r39 userspace", weekly and on changes) runs the manifest's own
download script and verifies the checksums and the library closure; `scripts/build-r39-firmware.sh` builds the
firmware extension.

## Flashing the board (JetPack 7 firmware)

The device tree comes from the board's SPI flash, not from the Talos image, so the QSPI firmware has to be
JetPack 7. For Seeed boards use their `Linux_for_Tegra` branch `r39.2.0` (board DTS and flash configs) on top of
NVIDIA's r39.2.0 BSP, config `recomputer-orin-j401` for the standard J401. To write only the QSPI:

```sh
sudo ./tools/kernel_flash/l4t_initrd_flash.sh --qspi-only \
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml --no-systemimg" \
  --showlogs --network usb0 recomputer-orin-j401 external
```

Without `--qspi-only` the tool also generates and flashes GPT, ESP and rootfs images for the NVMe. Run it once
with `--no-flash` first, check that `images/external` is not created and that `tegra234-carveouts.dtbo` is in the
overlay list. The flash host needs an x86-64 Ubuntu 22.04/24.04 (it serves NFS to the board over USB).

r36 modules also loaded on the r39 firmware and device tree in a test (the media engines log `failed to
register host1x actmon`), so flashing does not immediately break an r36 image, but do not rely on it.

## Upgrade pitfalls seen on a Jetson with these images

- **Stale boot entry** (see `BUGS.md`, Bug 25): the Jetson UEFI keeps the old UKI as default. After an install,
  check what runs (`talosctl get extensions`); the version tag alone can be identical.
- **ESP space:** each UKI is about 575 MB (the initramfs carries the kernel modules). A 2 GB ESP holds three at
  most; the installer fails with `no space left on device` when it is full.
- **Same tag, new image:** `talosctl upgrade --image <tag>` reuses an image the node already pulled under that
  tag. Use a new tag or `--image repo@sha256:<digest>`.

## CI

| Workflow | What |
|---|---|
| `validate-r39-build.yaml` | package build against the Talos kernel: fast compile check, then the full BuildKit job; checks the `.ko` files, signatures, vermagic and paths. About 85 min, needs the signing key secrets |
| `check-r39-userspace.yaml` | library download and closure check, firmware assembly (about 2 min, weekly) |
| `build-extensions.yaml` / `release.yaml` | `jetpack` input; r39 reuses the shared kernel images |

## Not covered

- CUDA 13 container images (the driver libraries are CUDA 13.2; a CUDA 12.6 image ran fine on top).
- MAXN Super (needs a carrier board with the cooling for it).
- NvSciIpc (`nvsciipc.ko`) is not built; `libnvsciipc.so` works without `/dev/nvsciipc` for compute.
- Licensing: the packages are NVIDIA's (NVIDIA Driver License Agreement). The libraries are downloaded by the
  node; the firmware extension and the installer image contain NVIDIA's firmware, as the r36 firmware extension
  already does.
