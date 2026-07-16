# Upstream IOMMUFD status (siderolabs)

Confidential VFIO passthrough needs the kernel IOMMUFD cdev interface
(`/dev/vfio/devices/vfioN`): Kata refuses the legacy VFIO group node for
confidential guests — `ConfidentialGuest needs IOMMUFD - cannot use
/dev/vfio/<group>` (`src/runtime/virtcontainers/qemu.go`). No released Talos
kernel enabled it, so this repo builds a custom kernel + imager for GPU nodes.

**That is now fixed upstream** (both halves merged to siderolabs `main`):

| PR | What | Merged |
| --- | --- | --- |
| [siderolabs/pkgs#1608](https://github.com/siderolabs/pkgs/pull/1608) | `CONFIG_IOMMUFD=m` + `CONFIG_VFIO_DEVICE_CDEV=y` (amd64 + arm64) | 2026-07-14 |
| [siderolabs/talos#13765](https://github.com/siderolabs/talos/pull/13765) | adds `iommufd.ko` to `hack/modules-{amd64,arm64}.txt` | 2026-07-15 |

The maintainer (smira) chose `=m` over the `=y` originally requested, and opened
the companion talos allowlist PR himself. As a module, `iommufd` **auto-loads
via depmod as a dependency of vfio** — no `machine.kernel.modules` entry is
needed. This `=m` + allowlist configuration was validated on hardware
(gpu-02, SEV-SNP + H200 NVL): `/dev/vfio/devices/vfio0` present, GPU CVM
`nvidia-smi` green.

## What this repo still needs

- **Released Talos does not carry it yet** (checked through v1.13.6). It is on
  `main` → ships in **v1.14**. Both PRs are on the "Backports to v1.13" board
  (status *Proposed*, not yet accepted), so a v1.13.x patch is possible but not
  confirmed.
- Until a release includes it, the custom `imager` (`GPU_IMAGER` in the
  Makefile) stays required for GPU nodes. CPU/SNP nodes use the stock imager
  already — they need no kernel change.

**Trigger to drop the custom imager:** when the target Talos release's
`hack/modules-amd64.txt` contains `iommufd.ko` and its pkgs kernel config has
`CONFIG_IOMMUFD`. Then point `TALOS_VERSION` at that release and delete the
`installer-gpu` custom-imager path; `installer-cpu`'s stock flow already works.
