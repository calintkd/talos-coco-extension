# Talos CoCo NVIDIA Add-on — GPU Confidential Containers

Add-on system extension for [the base CoCo extension](../coco/README.md) that provides the
`kata-qemu-nvidia-gpu-snp` runtime handler: AMD SEV-SNP confidential VMs with NVIDIA
GPU VFIO passthrough. The NVIDIA driver and NVRC (NVIDIA's Rust init) run **inside the
encrypted guest** — the host never loads a GPU driver.

**Proven end-to-end 2026-07-09** on H200 NVL + AMD EPYC (Turin) under Talos v1.13.5:
`nvidia-smi` in the SNP guest in ~30 s (`conf-compute`: CC ON / ready / PRODUCTION),
CUDA vectorAdd `Test PASSED`, vLLM v0.24.0 offline inference green in 4m35s
(10 GB image pulled inside the guest). Re-validated same day on **Kata 3.32.0 /
QEMU 11.0.0** (`nvidia-smi` + vectorAdd). See the validation ladder below.

## Why a separate extension

The base extension (`coco-kata-containers`) is proven in production use.
GPU support is isolated here so:

- the base artifact stays **byte-identical** — `kata-clh` / `kata-qemu-coco-dev` /
  `kata-qemu-snp` carry zero new risk from GPU work;
- non-GPU nodes (control planes, CPU workers) don't carry the NVIDIA guest kernel +
  Ubuntu-with-CUDA guest image payload;
- node roles compose cleanly at installer build time: base everywhere, add-on only
  in the GPU node's installer.

This mirrors how Talos itself packages NVIDIA support (separate, version-paired
`nvidia-*` extensions composed per node).

**Dependency**: requires the base extension **from the same release** (same
version, same Kata — guest assets must match the base's QEMU/shim) on the same
node — it provides `qemu-system-x86_64-snp-experimental`, `virtiofsd`, and the
statically linked `containerd-shim-kata-v2` that this add-on's runtime handler
uses. Talos extensions cannot declare dependencies on each other, so the
pairing is enforced by `make check-versions` at build time and by a boot-time
check in the `nvidia-vfio-cdi` service (a missing/mismatched base fails the
service loudly in `talosctl services` instead of failing pods obscurely).

## Contents

| Path | Size | Description |
| --- | --- | --- |
| `/usr/local/share/kata-containers/configuration-qemu-nvidia-gpu-snp.toml` | 34 K | Kata config for SNP + GPU passthrough (path-rewritten, guest-pull enabled, dm-verity hash inline) |
| `/usr/local/share/kata-containers/vmlinuz-nvidia-gpu.container` | ~8 M | NVIDIA guest kernel (version tracks the Kata release) |
| `/usr/local/share/kata-containers/kata-containers-nvidia-gpu-confidential.img` | ~533 M | Ubuntu-noble guest rootfs with NVIDIA driver + NVRC (595.58.03 in Kata 3.30–3.32; the 3.30 image was ~1.1 G) |
| `/etc/cri/conf.d/30-coco-nvidia.part` | — | containerd CRI handler drop-in (merges after the base's `20-coco.part`) |
| `/usr/local/etc/containers/nvidia-vfio-cdi.yaml` | — | Extension service: VFIO CDI spec generator (runs every boot) + base-extension presence guard |
| `/usr/local/lib/containers/nvidia-vfio-cdi/{busybox,nvidia-vfio-cdi-gen.sh}` | ~1 M | The service's container rootfs: static busybox runner + generator script |

Filenames verified against the `kata-static-3.32.0-amd64.tar.zst` listing (2026-07-09).
The TOML references the base extension's QEMU (`qemu-system-x86_64-snp-experimental`)
and OVMF (`/usr/local/share/ovmf/AMDSEV.fd`) — hence the base dependency.

> ⚠️ Upstream ships `nvrc.smi.srs=1` in the TOML's `kernel_params` — NVRC marks the
> GPU ready **without** GPU attestation (dev shortcut). Review before production
> use.

## Host requirements (hard prerequisites)

### 1. Custom Talos kernel with IOMMUFD

Confidential guests require the VFIO **IOMMUFD cdev** interface
(`/dev/vfio/devices/vfioN`) — the Kata runtime refuses the legacy group node with
`ConfidentialGuest needs IOMMUFD - cannot use /dev/vfio/<group>`
(`virtcontainers/qemu.go`). **No stock Talos kernel enables IOMMUFD.** Build a
custom kernel with exactly two config changes on `siderolabs/pkgs` — check out
the `PKGS` ref pinned in the Talos release's Makefile (e.g. Talos v1.13.5 pins
`v1.13.0-36-g6b315f7`; there is no per-patch-release pkgs tag):

```
CONFIG_IOMMUFD=y            # must be =y (VFIO_DEVICE_CDEV is bool, depends on it)
CONFIG_VFIO_DEVICE_CDEV=y
```

```bash
# 1. kernel (in siderolabs/pkgs, config edited, then):
make kernel REGISTRY=ghcr.io USERNAME=<org> PUSH=true PLATFORM=linux/amd64
# 2. imager carrying that kernel (in siderolabs/talos at the matching tag).
#    NOTE: the kernel lives in the IMAGER's install artifacts — building
#    installer-base with PKG_KERNEL is NOT sufficient (it has no kernel).
make imager PKG_KERNEL=ghcr.io/<org>/kernel:<tag> \
  INSTALLER_ARCH=amd64 PLATFORM=linux/amd64 PUSH=true REGISTRY=ghcr.io USERNAME=<org>
```

Build tip: the Talos kernel uses ThinLTO — cap the builder's CPUs (e.g.
`--cpuset-cpus=0-31`) or the `vmlinux.o` link can OOM on many-core hosts.

Verify on the node after upgrade: `/proc/config.gz` shows both flags `=y`, and
`/dev/vfio/devices/` exists once the GPU is bound.

### 2. GPU Confidential Computing mode ON

**A CC-capable GPU (H100/H200) with CC mode OFF makes confidential guests stall
silently forever** — QEMU runs, the guest driver handshake never completes, the Kata
agent never answers, and the sandbox times out (~4 min) with no useful error. Check
and set CC mode from the host with
[NVIDIA gpu-admin-tools](https://github.com/NVIDIA/gpu-admin-tools) (works while the
GPU is bound to vfio-pci; on Talos run it in a privileged pod with `/sys` + `/dev`
host mounts):

```bash
python3 nvidia_gpu_tools.py --gpu-bdf=<bdf> --query-cc-mode
python3 nvidia_gpu_tools.py --gpu-bdf=<bdf> --set-cc-mode=on --reset-after-cc-mode-switch
```

CC mode is a **persistent per-GPU setting** (survives reboot/reinstall). Note the
inverse: a CC-ON GPU will not work with the standard host-driver pattern — flip it
back with `--set-cc-mode=off` if the node leaves confidential duty.

## Build

```bash
make nvidia            # from the repo root (add PUSH=true to publish)
```

Manual build (context = this directory):

```bash
docker buildx build --platform linux/amd64 \
  --build-arg KATA_VERSION=3.32.0 \
  -f extensions/coco-nvidia/Dockerfile \
  -t ghcr.io/<your-org>/talos-coco-nvidia:v<VERSION> \
  --push extensions/coco-nvidia/
```

## Installer composition (per node role)

```bash
make installer-gpu     # GPU worker — custom IOMMUFD imager + base + add-on
make installer-cpu     # CP / CPU worker — base only, stock imager/kernel
```

> The custom imager image (`GPU_IMAGER`) must be pullable by your Docker
> daemon — make the package public or `docker login` to its registry first.

Equivalent manual GPU-worker invocation:

```bash
docker run --rm -t -v /var/run/docker.sock:/var/run/docker.sock -v $(pwd)/_out:/out \
  ghcr.io/<your-org>/imager:<talos-version> installer --arch amd64 \
  --base-installer-image ghcr.io/siderolabs/installer-base:<talos-version> \
  --system-extension-image ghcr.io/<your-org>/talos-coco-extension:v<VERSION> \
  --system-extension-image ghcr.io/<your-org>/talos-coco-nvidia:v<VERSION>
```

## Deploy (GPU node)

1. BIOS: SEV-SNP recipe **plus ACS enabled** (IOMMU isolation for passthrough).
2. GPU: **CC mode ON** (see host requirements above).
3. Machine config: `patches/machine-config-gpu-worker.yaml` — binds the GPU via
   `machine.kernel.modules` `vfio_pci` `ids=<vendor:device>` parameter (**verify the
   PCI ID against `lspci -nn`**; H100 PCIe `10de:2331`, H200 NVL `10de:233b`).
   Do NOT use `install.extraKernelArgs` — ignored/rejected on UKI boot.
4. `kubectl apply -f deploy/runtime-classes.yaml` (all classes, once per cluster)
5. NVIDIA GPU Operator with `deploy/gpu-operator-values-talos.yaml` — pins the CDI-aware
   `nvidia-sandbox-device-plugin` (`P_GPU_ALIAS=pgpu`); the operator default plugin
   injects the legacy group node and breaks confidential guests.
6. CDI: **automatic** — the `nvidia-vfio-cdi` extension service writes
   `/run/cdi/nvidia-vfio.yaml` (IOMMUFD cdev, kind `nvidia.com/pgpu`) on every boot.
   Check with `talosctl services` (`ext-nvidia-vfio-cdi` should reach Finished).
7. Pod spec: `runtimeClassName: kata-qemu-nvidia-gpu-snp`, resource
   `nvidia.com/pgpu: "1"`, annotation `io.containerd.cri.v1.images/unpack: "false"`.

### Guest sizing for real workloads

Guest-pull unpacks container images into guest tmpfs — size the VM for the image:

```yaml
# vLLM-class image (~10 GB): 96 GiB guest RAM + 8 vCPUs
io.katacontainers.config.hypervisor.default_memory: "98304"
io.katacontainers.config.hypervisor.default_vcpus: "8"
```

Small images run fine with the 8 GiB / 1 vCPU TOML defaults. The shipped
`create_container_timeout = 1200` covers multi-minute in-guest pulls.

## Validation ladder

| Stage | Hardware | Proves | Status |
| --- | --- | --- | --- |
| Inert wiring | any cluster, no GPU | extension installs, `.part` merges, handler registered in containerd, RuntimeClass applies, GPU pod → **Pending** (not crash) | ✅ 2026-06-12 |
| Handler fire | SNP-less node, labelled | containerd resolves handler, TOML parses, QEMU launch fails at the expected hardware boundary (no `/dev/sev`) — config plumbing proven | ✅ 2026-06-12 |
| SNP no GPU | SNP node | full SNP launch path of the GPU config minus the VFIO device (`kata-qemu-snp` guest boots) | ✅ 2026-07-09 |
| Full | SNP + H200 NVL | VFIO bind (IOMMUFD), NVRC driver injection, `nvidia-smi` in-guest, `conf-compute` CC ON/ready/PRODUCTION, CUDA vectorAdd, vLLM v0.24.0 inference | ✅ 2026-07-09 |
| Guard service (v1.3.0-rc3) | any node with both extensions | `nvidia-vfio-cdi` still reaches Finished with the base-presence check + read-only `/usr/local` mount in place | ⬜ pending — gates rc3 → v1.3.0 promotion |
| GPU attestation | SNP + GPU + KBS | remove `nvrc.smi.srs=1`, full GPU evidence chain | ⬜ open |

**Release status**: `v1.3.0-rc3` = the proven `v1.3.0-rc1` content plus the
base-presence guard in the CDI service (rc2), with the guard's `/usr/local`
mount made non-recursive (`bind`, not `rbind`) so the container gets no
writable alias of its own rootfs (rc3). No changes to the runtime handler,
config, or guest assets. Promote to `v1.3.0` after the guard row above goes
green on a live node.
