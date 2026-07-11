# Draft: siderolabs/pkgs issue — enable CONFIG_IOMMUFD + CONFIG_VFIO_DEVICE_CDEV

Status: DRAFT — not yet filed. File against https://github.com/siderolabs/pkgs
(kernel config lives at `kernel/build/config-amd64`). No existing issue or PR
mentions IOMMUFD anywhere in the siderolabs org (searched 2026-07-11).

If accepted, GPU-capable Confidential Containers work on the stock Talos
kernel/imager and the custom-imager step in this repo disappears.

---

**Title**: kernel: enable CONFIG_IOMMUFD and CONFIG_VFIO_DEVICE_CDEV

**Body**:

## Feature request

Enable two kernel config options on amd64:

```
CONFIG_IOMMUFD=y
CONFIG_VFIO_DEVICE_CDEV=y
```

Current state in `kernel/build/config-amd64`: `# CONFIG_IOMMUFD is not set`;
`CONFIG_VFIO_DEVICE_CDEV` is not emitted (it depends on IOMMUFD).

## Use case

VFIO device passthrough into **confidential VMs** (AMD SEV-SNP, and TDX on the
Intel side) requires the VFIO IOMMUFD character-device interface
(`/dev/vfio/devices/vfioN`). The Kata Containers runtime refuses the legacy
VFIO group interface for confidential guests
(`src/runtime/virtcontainers/qemu.go`):

```
ConfidentialGuest needs IOMMUFD - cannot use /dev/vfio/<group>
```

Concretely: Kata Containers / Confidential Containers pods with GPU
passthrough (`kata-qemu-nvidia-gpu-snp` runtime class, NVIDIA Hopper GPUs in
confidential-computing mode) cannot start on Talos today. With only these two
config changes on an otherwise stock Talos kernel, the full stack works — we
run SEV-SNP guests with NVIDIA H100/H200 VFIO passthrough (GPU driver inside
the guest) on Talos v1.13 with a custom-built kernel that differs from stock
by exactly these two lines.

## Impact on existing users

None expected:

- The legacy VFIO group interface remains available and default
  (`VFIO_GROUP=y` stays); userspace that opens `/dev/vfio/<group>` is
  unaffected. The cdev interface is additive.
- `VFIO_DEVICE_CDEV` is a bool compiled into the existing `vfio` module;
  `IOMMUFD=y` adds the iommufd core. Size cost is small.
- iommufd is the kernel's designated successor to the legacy VFIO container
  API and is required by QEMU for confidential-guest passthrough.

Happy to send the PR if this is acceptable.
