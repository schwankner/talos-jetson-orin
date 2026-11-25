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
| Installer image | `custom-installer:<talos>-<kernel>-nvgpu5.13.0-drm-noshim` | `custom-installer-jp7:<talos>-<kernel>-nvgpu39.2.1-jp7` |
| Extension tag | `5.13.0-drm-noshim-<kernel>-talos` | `39.2.1-jp7-<kernel>-talos` |
| Firmware extension | `nvidia-firmware-ext:v5` (r36 apt, component `t234`) | `nvidia-firmware-ext:r39-v1` (`scripts/build-r39-firmware.sh`) |
| Userspace libraries | downloaded on the node (`t234` apt) | downloaded on the node (`som` apt, `manifests/gpu/cdi-setup.yaml`) |
| Board firmware (QSPI) | JetPack 6 (also ran on r39.2.0) | JetPack 7 (r39.2.0) or JetPack 6 (r36.5); both tested on Orin NX and AGX Orin, see [Firmware and image combinations](#firmware-and-image-combinations) |

The kernel, the in-tree modules (`kernel-modules-clang`) and the base installer are shared by both lines. With
`JETPACK=r39` the build reuses them when they are already in the registry.

## Using it

```bash
# CI: a release (tag push, or the auto-tag dispatch after a Talos bump) builds both lines in one run:
#     r36 first, then r39, which reuses the shared kernel / kernel-modules-clang / base installer.
#     "Build USB Image" -> jetpack = both (default) | r36 | r39 builds one or both by hand;
#     "Build Extensions" builds a single line (jetpack = r36 | r39).
# local: JETPACK=r39 make build-extensions
```

Each line publishes its installer to its own repository, so the two never share a tag: r36 keeps
`custom-installer`, r39 goes to `custom-installer-jp7`. The release notes list both images.

Besides the compound tag (`<talos>-<kernel>-nvgpu<nvgpu>`) every full installer also gets the plain Talos version as an
alias tag in its own repository, for example `custom-installer-jp7:v1.14.2`. Upgrade controllers such as
[tuppr](https://github.com/home-operations/tuppr) take the node's current install image, swap the tag for the target
Talos version and verify the node against that version, so a node can follow its line with
`image: ghcr.io/<owner>/custom-installer-jp7:<talos>` and never cross to the other line. The alias is mutable (the latest
build of that Talos version); the compound tag stays the build's identity.

On the node: flash the board's QSPI (below), install the r39 installer image, and apply
`manifests/gpu/cdi-setup.yaml` instead of `cdi-setup-r36.yaml`. The machine config's kernel module list for
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
`https://repo.download.nvidia.com/jetson/som`, dist `r39.2`. `manifests/gpu/cdi-setup.yaml` downloads three
debs (`nvidia-l4t-core`, `nvidia-l4t-cuda-nvgpu`, `nvidia-l4t-cuda`, 26 MB, version and SHA-256 pinned in the
script) once per version and installs the closure of `libcuda.so.1` into `/var/lib/nvidia-tegra-libs/tegra`.
It also takes `libnvidia-ptxjitcompiler` from the `cuda-compat-13-2` package of the **`common`** component (88 MB
download, 32 MB kept). Three things that are easy to miss:

- `libcuda` `dlopen()`s `libnvcucompat.so` and `libnvcuextend.so` at `cuInit` (they are not in its `DT_NEEDED`
  list; both are in `nvidia-l4t-cuda`). Without `libnvcucompat.so`, `cuInit` returns 999 and nothing else is
  logged.
- `libnvidia-ptxjitcompiler` is not in any L4T deb. `libcuda` loads it for every kernel that has no native code
  for the GPU (sm_87), which includes the CUDA 13 build of Ollama and the PyTorch and vLLM wheels (they carry
  sm_80 code and PTX). Without it the first kernel aborts with `CUDA error: PTX JIT compiler library not
  found`, although GPU discovery succeeded and all layers were offloaded. The manifest installs it from
  `cuda-compat-13-2` (version 595.71.05, the newest 595.x in the repository; the JetPack 7.2 driver is 595.78 and
  the difference caused no problem) and uses only that one file, never that package's own `libcuda`. Tested on
  an Orin NX 16 GB (Talos v1.14.2): stock Ollama v0.40.2 (`cuda_v13`) with `qwen2.5:0.5b` and `qwen3:4b` runs
  100% on the GPU at 89 and 17.6 tok/s decode (`llama-bench` on the same files: 89.7 and 16.7 tok/s). llama.cpp
  builds with native sm_87 code do not need the library.
- The GA10B firmware must match the driver. The CDI setup copies the firmware to `/var/fw-fresh` and points
  `firmware_class.path` there; `/var` survives node upgrades, so a copy made once keeps older firmware in front
  of the new one. With the r36 PMU firmware the r39 `nvgpu` does not boot the PMU (`pwr_falcon_exterrstat
  0xbadf....`) and then dereferences NULL in its stall interrupt thread, which hard-resets the node on GPU
  power-on, with no panic record. The r39 manifest syncs the files on every start.
- **GPU clock after boot.** The r39 `nvgpu` creates its devfreq node only at the first GPU use, and its default
  maximum is 1173 MHz (the Super clock). `manifests/gpu/power-mode.yaml` looks for the node every second and applies
  the power-mode cap (918 MHz in MAXN) as soon as it appears, so the GPU does not run above it. The cap used to come
  from the 60-second re-assert loop, which left up to a minute without it after the first GPU use. The log line is
  `GPU devfreq appeared, capped at ... Hz`.

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

**First boot after the flash: use a cold boot.** On a reComputer J401 with UEFI r39.2.0, the warm reboot that ends
`l4t_initrd_flash.sh` came up without the NVMe: UEFI tried HTTP boot and dropped to the UEFI shell. After a full
power cycle (recovery jumper and USB cable removed, then power off and on) the NVMe booted directly, with no boot
entry set by hand. If the board lands in the UEFI shell after the flash, power-cycle it before looking at the boot
entries.

## Firmware and image combinations

The QSPI firmware line and the image line do not have to match. On the AGX Orin 64 GB devkit (P3701-0005) all four
combinations below ran on Talos v1.14.7 / kernel 6.18.65 (release `v1.14.7-nvgpu5.13.0-drm-noshim`), with the
`power-mode` DaemonSet active (MAXN, GPU 1300.5 MHz, EMC 3199 MHz). Ollama 0.20.5, 200 tokens, `temperature` 0,
two runs each:

| QSPI firmware | Image | CUDA driver | qwen2.5:0.5b | qwen3:4b | qwen3.6:35b | gemma4:31b |
|---|---|---|---|---|---|---|
| r36.5 (UEFI 36.5.0) | r36 | 12.6 | 145.0–145.2 | 37.6–37.8 | 25.3 | 7.2 |
| r39.2.0 | r36 | 12.6 | 145.2–145.5 | 37.7 | 25.3–25.4 | 7.1–7.2 |
| r36.5 (UEFI 36.5.0) | r39 | 13.2 | 143.8–144.5 | 37.5–37.7 | 25.1–25.2 | 7.1–7.2 |
| r39.2.0 | r39 | 13.2 | see note | | | |

- In every combination, all modules load, `/dev/dri/renderD128`, `/dev/host1x-fence` and `/dev/nvmap` are
  present, and the node comes back on the GPU after `talosctl reboot`. There were no GPU faults in dmesg.
- The QSPI line makes no measurable difference. The r39 image is within 1 % of the r36 image.
- Note on the last row: r39 on r39 QSPI was measured earlier on v1.14.4 without the `power-mode` DaemonSet
  (qwen2.5:0.5b 108–116, qwen3:4b 27.5, qwen3.6:35b 18, gemma4:31b 6.5 tok/s at 1300.5 MHz). Those numbers are
  lower because EMC and the CPU governor were not set, not because of the firmware.
- `tegra_se` fails to load with `Unknown symbol host1x_*` on both image lines, because the out-of-tree `host1x`
  replaces the in-tree one. It is not needed for the GPU.
- The CDI setup DaemonSet syncs the GPU firmware into `/var/fw-fresh` on every start. When a node changes image
  lines, it replaces the other line's files there (`firmware: updating fecs_encrypt_prod.bin` and so on).

Switching lines on a running node: scale GPU workloads to 0, delete the `nvidia-cdi-setup` DaemonSet, stage the
machine config with the other line's module list and installer (`talosctl apply-config --mode=staged -f <full
config>`; JSON 6902 patches are rejected for a multi-document config, and a strategic merge patch would append to
the module list rather than replace it), run `talosctl upgrade --image <other installer>`, then apply the other
line's CDI manifest. Flashing the QSPI does not touch the NVMe, so the installed image keeps booting after it.

**Orin NX 16 GB** (Seeed reComputer J401, P3767-0000), same Talos v1.14.7 release, GPU at 918 MHz from the
`power-mode` DaemonSet, same Ollama settings:

| QSPI firmware | Image | CUDA driver | qwen2.5:0.5b | qwen3:4b |
|---|---|---|---|---|
| r36.5 (UEFI 36.5.0) | r39 | 13.2 | 64.6–65.9 | 16.5–16.6 |
| r39.2.0 | r39 | 13.2 | 65.7–65.8 | not measured |

The r39 image on r36.5 QSPI loads all 11 modules, survives `talosctl reboot`, and shows no GPU faults in dmesg.
The r36 image on r36 QSPI gives 64.6 and 16.4 tok/s on this board (README), so the speed is the same. Earlier, the
r36 stack (Talos v1.15.0-alpha.2, kernel 7.3) also ran on the r39.2.0 QSPI (qwen2.5:0.5b 66.2 tok/s, qwen3:4b
16.6 tok/s).

Flashing the J401 back to r36.5 (Seeed `Linux_for_Tegra` branch `r36.5.0` on top of NVIDIA's r36.5 BSP, config
`recomputer-orin-j401`, the same `--qspi-only` command as above):
- The branch ships prebuilt DTBs, but `recomputer-orin-j401.conf` also lists the camera overlay
  `tegra234-p3767-camera-p3768-imx219-dual-seeed.dtbo`, which is only in the branch as source. The flash fails
  with `FileNotFoundError` before it writes anything. I removed that overlay from `OVERLAY_DTB_FILE`; it only adds
  the IMX219 camera nodes.
- A `--no-flash` dry run without a board fails with `No Board Spec. and no target connected`. With the board in
  recovery mode, a normal run reads the board spec from it.
- After the flash I did a cold boot (recovery jumper and USB cable removed, power off and on). The board booted
  the NVMe directly.

## Upgrade pitfalls seen on a Jetson with these images

- **Stale boot entry** (see `BUGS.md`, Bug 25): on an upgrade from Talos v1.14.4 or older, a failed kexec makes
  Talos revert to the old UKI; disable kexec first (`kernel.kexec_load_disabled: "1"`). Fixed from v1.14.5 on.
  After an install, check what runs (`talosctl get extensions`); the version tag alone can be identical.
- **ESP space:** each UKI is about 575 MB (the initramfs carries the kernel modules). A 2 GB ESP holds three at
  most; the installer fails with `no space left on device` when it is full.
- **Same tag, new image:** `talosctl upgrade --image <tag>` reuses an image the node already pulled under that
  tag. Use a new tag or `--image repo@sha256:<digest>`.
- **Moving a node from r36 to r39: take the r36 CDI setup away first.** Before the node boots the r39 driver for the
  first time, delete the r36 `nvidia-cdi-setup` DaemonSet and scale the GPU workloads to 0. Otherwise the r36
  DaemonSet points `firmware_class.path` at the stale r36 GA10B firmware in `/var/fw-fresh`, which is the
  hard-reset case described under "Userspace and firmware". After the upgrade apply
  `manifests/gpu/cdi-setup.yaml`: it replaces the firmware files in `/var/fw-fresh` and installs the r39
  userspace libraries, then start the workloads again.
- **One JetPack line per cluster.** `cdi-setup.yaml` uses the same names as `cdi-setup-r36.yaml` (namespace
  `nvidia-system`, ConfigMap `nvidia-cdi-setup-scripts`, DaemonSet `nvidia-cdi-setup`, host directory
  `/var/lib/nvidia-tegra-libs`), so applying one replaces the other. A cluster runs one line at a time, and the CDI
  manifest must match it: nothing stops the r39 DaemonSet from landing on an r36 node.

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
