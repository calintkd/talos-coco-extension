# Upstream siderolabs/pkgs — enable CONFIG_IOMMUFD + CONFIG_VFIO_DEVICE_CDEV

Status: **FILED 2026-07-13 as https://github.com/siderolabs/pkgs/pull/1608**
(OPEN, awaiting maintainer). Strategy used: single self-contained PR against
`main`, no separate issue. On filing: 10/11 conform checks green
(`conform/commit/gpg` PASS via our own key); `conform/commit/gpg-identity`
FAIL and GitHub "Verified" badge false (`bad_email`, noreply+GPG limitation) —
both expected for an external PR and cleared when a maintainer re-signs at
merge (matches precedent #1396/#1356/#1508). Nothing to action our side; watch
the PR for the "can we make this a module?" question (pre-answered in the body).

If accepted, GPU-capable Confidential Containers work on the stock Talos
kernel/imager and the custom-imager step in this repo disappears.

## Pre-verified against their gates (2026-07-12)

- **CI `check-dirty`**: byte-clean — the proposed `config-amd64` was verified
  by running their `make kernel-olddefconfig` (their kernel container,
  pkgs@main) with zero resulting diff.
- **Hardening gate**: their kernel build runs `kernel-hardening-checker` with
  an enforcing filter as a build step; kernels with these options enabled
  build through it (verified empirically, both `=y` and `=m` variants).
  Neither that tool nor KSPP has any IOMMUFD rule.
- **Size**: `=y` costs +48 KiB compressed vmlinuz (+0.24%); measured against
  the same pkgs base commit.
- **`=m` mechanism** (why built-in): `iommufd.ko` builds and lands in the
  kernel package, but the Talos rootfs installs only allowlisted modules
  (`hack/modules-amd64.txt` — carries the four vfio modules, no iommufd), so
  `vfio.ko` fails with `Unknown symbol iommufd_*`. `=m` therefore needs a
  companion siderolabs/talos allowlist change; `=y` is one file in pkgs.
  Proven on hardware 2026-07-12 (deploy + rollback).
- **Conform policy**: commit must be conventional-commit (`feat:` — `kernel:`
  fails their type list), ≤89-char lowercase imperative header, body, real DCO
  `Signed-off-by`, and GPG/SSH-signed with the author's own verified key.
  `gpg-identity` may show red while open — maintainers amend + re-sign at
  merge (observed on merged external PRs); keep "allow edits by maintainers"
  on. Do NOT mention this in the PR.

## Filing steps (requires the author's signing key — manual)

1. Fork siderolabs/pkgs; branch from `main`.
2. Apply the config change: set `CONFIG_IOMMUFD=y` + `CONFIG_VFIO_DEVICE_CDEV=y`
   and regenerate with `make kernel-olddefconfig` (net delta = 5 symbols:
   the two set + auto-selected `IOMMUFD_DRIVER`, `IOMMUFD_DRIVER_CORE`,
   `INTERVAL_TREE_SPAN_ITER`). Touch only `kernel/build/config-amd64`.
3. Commit with the message below (GPG-signed, real `Signed-off-by`), push,
   open the PR with the body below.

---

## Commit message

```
feat: enable CONFIG_IOMMUFD and CONFIG_VFIO_DEVICE_CDEV

Enable the VFIO IOMMUFD character-device interface
(/dev/vfio/devices/vfioN), required for VFIO device passthrough into
confidential VMs (AMD SEV-SNP / Intel TDX). The Kata Containers runtime
refuses the legacy VFIO group interface for confidential guests
("ConfidentialGuest needs IOMMUFD - cannot use /dev/vfio/<group>"), so
device passthrough into a confidential guest cannot start without it.

IOMMUFD is built in (=y): as a module, vfio.ko gains a hard dependency
on iommufd.ko, which is not in the Talos rootfs module allowlist, so
=m would additionally require a siderolabs/talos change
(hack/modules-{amd64,arm64}.txt). Built-in keeps this a single-file
change; the legacy VFIO group interface is unchanged.

Enabling IOMMUFD=y auto-selects IOMMUFD_DRIVER, IOMMUFD_DRIVER_CORE,
and INTERVAL_TREE_SPAN_ITER.

Signed-off-by: <REAL NAME> <REAL EMAIL>
```

## PR body

```markdown
Enables the VFIO IOMMUFD character-device interface
(`/dev/vfio/devices/vfioN`) so VFIO device passthrough into confidential VMs
works on the stock Talos kernel. The Kata Containers runtime refuses the
legacy VFIO group interface for confidential guests
(`src/runtime/virtcontainers/qemu.go`):

    ConfidentialGuest needs IOMMUFD - cannot use /dev/vfio/<group>

This extends the Kata-on-Talos pattern — already shipped as the in-catalog
`kata-containers` extension (non-confidential today) — to confidential guests
with device passthrough, e.g. an NVIDIA GPU passed into an SEV-SNP guest,
continuing the confidential-computing enablement from #1396 (SEV-SNP) and
#1276 (AMD_MEM_ENCRYPT). Rebinding devices to `vfio-pci` is already
first-class in Talos via `PCIDriverRebindConfig`; for confidential guests the
kernel-side cdev interface is the missing piece.

### Config delta

`config-amd64` regenerated with `make kernel-olddefconfig` after setting
`CONFIG_IOMMUFD=y` + `CONFIG_VFIO_DEVICE_CDEV=y`; the net change is 5 symbols:
`VFIO_DEVICE_CDEV` and `IOMMUFD` (set), plus auto-selected `IOMMUFD_DRIVER`,
`IOMMUFD_DRIVER_CORE`, and `INTERVAL_TREE_SPAN_ITER`. `VFIO_GROUP=y` and the
legacy container path are unchanged, and `IOMMUFD_VFIO_CONTAINER` stays off
(it depends on `!VFIO_CONTAINER`). `/dev/iommu` is a root-only 0660 misc
device — stricter than the 0666 `/dev/vfio/vfio` already enabled — and the
build's `kernel-hardening-checker` gate still passes (neither it nor KSPP has
a rule against IOMMUFD).

### Why `=y` rather than `=m`

Tested both on Talos v1.13.5. With `=m`, `vfio.ko` is built with the iommufd
glue (`drivers/vfio/iommufd.c`) and hard-depends on iommufd's exported
symbols, but `iommufd.ko` is not in the Talos rootfs module allowlist
(`hack/modules-amd64.txt` carries the vfio stack, no iommufd entry) — so the
vfio modules fail to load with `Unknown symbol iommufd_*`. `=m` therefore
needs a companion siderolabs/talos allowlist change (after which depmod would
auto-load it), while `=y` is this single file. Happy to switch this PR to the
`=m` + allowlist pair if you prefer modular.

### Testing

Built this kernel and ran it on a Talos v1.13.5 bare-metal AMD SEV-SNP node
with an NVIDIA H200 passed through to a Kata confidential guest:
`/dev/vfio/devices/vfio0` present, guest boots, `nvidia-smi` works inside the
CVM. A stock kernel reproduces the `ConfidentialGuest needs IOMMUFD` failure.
Cost: +48 KiB compressed vmlinuz (+0.24%).

amd64 only — the validated confidential-VM stack is SEV-SNP; arm64 (SMMUv3
supports iommufd) can follow identically if you want parity. If this is
eligible for a `release-1.13` cherry-pick that would be welcome, but no
urgency.
```
