# Kernel patches

Patches for the Talos kernel (`siderolabs/pkgs`, `kernel/build/patches/`) that the GPU stack needs and that are not
upstream yet. They are not applied by the regular builds of this repository, which use the Talos 1.14 kernel (6.18).

| Patch | Needed for | Upstream status | Discussion |
|---|---|---|---|
| [`0001-soc-tegra-fuse-platform-from-hidrev-on-tf-a-socs.patch`](0001-soc-tegra-fuse-platform-from-hidrev-on-tf-a-socs.patch) | Linux 7.2 and newer: since [8b8ee2e56f95](https://github.com/torvalds/linux/commit/8b8ee2e56f951ccf41d98eebe73195cea487cd48) Orin is reported as pre-silicon ("Asim QT") and the GPU runs about 7x slower | Not submitted to linux-tegra; carried in siderolabs/pkgs as `kernel/build/patches/0020-soc-tegra-fuse-read-the-platform-from-HIDREV-on-TF-A.patch` | [siderolabs/pkgs#1767](https://github.com/siderolabs/pkgs/pull/1767), `BUGS.md` Bug 28 |

Tested on Linux 7.3 (Talos v1.15.0-beta.0) on an Orin NX 16 GB and an AGX Orin 64 GB, and independently on an AGX Orin
64 GB with Linux 7.3.4. With the patch, `/sys/devices/soc0/revision` reads `Silicon A01` and the GPU runs at the same
speed as on 6.18.
