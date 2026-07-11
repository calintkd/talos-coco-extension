# `coco-kata-containers` — base CoCo extension

The base Talos system extension: Kata Containers with AMD SEV-SNP confidential
computing. Product-level overview, quick start, and RuntimeClasses live in the
[repo README](../../README.md); this page covers the extension itself.

## Runtime handlers

| Runtime Handler      | Use Case                  | Hypervisor              | Confidential   |
| -------------------- | ------------------------- | ----------------------- | -------------- |
| `kata-qemu-snp`      | AMD SEV-SNP production    | QEMU (SNP-experimental) | ✅             |
| `kata-qemu-coco-dev` | CoCo dev/test (no TEE HW) | QEMU                    | ✅ (simulated) |
| `kata-clh`           | Standard VM isolation     | Cloud Hypervisor        | ❌ (named `kata` before v1.3.0) |

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Talos Linux Host (immutable)                                   │
│                                                                 │
│  containerd ──► containerd-shim-kata-v2 ──► QEMU / CLH          │
│       │                    │                    │               │
│  CRI config          Kata config         Guest VM               │
│  (20-coco.part)   (configuration-*.toml)  ┌────────────┐        │
│                                           │ Guest      │        │
│                                           │ Kernel     │        │
│                                           │ + initrd   │        │
│  /opt/kata → /usr/local (symlink)         │ + OVMF     │        │
│                                           │ (SEV-SNP)  │        │
│                                           └────────────┘        │
└─────────────────────────────────────────────────────────────────┘
```

## Build

```bash
make base              # from the repo root (add PUSH=true to publish)
```

Manual build (context = this directory):

```bash
docker buildx build --platform linux/amd64 \
  --build-arg KATA_VERSION=3.32.0 \
  -f extensions/coco/Dockerfile \
  -t ghcr.io/<org>/talos-coco-extension:v<VERSION> --push extensions/coco/
```

## Extension contents

| Path                                                 | Description                                 |
| ---------------------------------------------------- | ------------------------------------------- |
| `/usr/local/bin/containerd-shim-kata-v2`             | Kata shim (static, built from source)       |
| `/usr/local/bin/cloud-hypervisor`                    | Cloud Hypervisor (for `kata-clh`)           |
| `/usr/local/bin/qemu-system-x86_64`                  | Standard QEMU (for `kata-qemu-coco-dev`)    |
| `/usr/local/bin/qemu-system-x86_64-snp-experimental` | SNP QEMU (for `kata-qemu-snp`)              |
| `/usr/local/libexec/virtiofsd`                       | virtiofsd daemon                            |
| `/usr/local/share/kata-containers/`                  | Guest kernels, images, initrd, config files |
| `/usr/local/share/ovmf/AMDSEV.fd`                    | OVMF firmware for SEV-SNP                   |
| `/usr/local/share/kata-qemu/`                        | Standard QEMU firmware/ROM files            |
| `/usr/local/share/kata-qemu-snp-experimental/`       | SNP QEMU firmware/ROM files                 |
| `/opt/kata`                                          | Symlink → `/usr/local`                      |
| `/etc/cri/conf.d/20-coco.part`                       | Containerd runtime handler config           |

Configuration TOML files are extracted from the official Kata release tarball
during the build, with paths rewritten from `/opt/kata/` to `/usr/local/`,
guest-pull enabled, and `create_container_timeout` raised to 1200 s.

## Key design decisions

### Statically linked shim

`containerd-shim-kata-v2` is rebuilt from source with `CGO_ENABLED=0
BUILDFLAGS="-buildmode=exe"` because Talos has no glibc. The pre-built shim in
the kata-static tarball is dynamically linked and won't start. The build hard-
gates on `ldd` reporting a static binary.

### SNP-experimental QEMU

`kata-qemu-snp` uses `qemu-system-x86_64-snp-experimental` — the standard QEMU
in the tarball does not support SEV-SNP VM launch. The config is patched at
build time to reference it.

### /opt/kata symlink

Both QEMU binaries have `/opt/kata/` data-directory paths compiled in (ROM
files like `kvmvapic.bin`). Extensions install to `/usr/local/`, so the
extension ships a symlink `/opt/kata → /usr/local`.

### Guest-pull mode

`kata-qemu-snp` and `kata-qemu-coco-dev` use `shared_fs = "none"` with
`experimental_force_guest_pull = true`: container images are pulled inside the
guest VM, never shared from the host. Pods must carry the
`io.containerd.cri.v1.images/unpack: "false"` annotation. Because the image is
pulled AND unpacked inside the guest during CreateContainerRequest,
`create_container_timeout` is raised to 1200 s (kata's 60 s default times out
on multi-GB images).

## Bare-metal AMD SEV-SNP deployment

### BIOS requirements

| Setting                               | Required Value |
| ------------------------------------- | -------------- |
| SVM (Secure Virtual Machine)          | Enabled        |
| SEV (Secure Encrypted Virtualization) | Enabled        |
| SEV-ES                                | Enabled        |
| SEV-SNP                               | Enabled        |
| SMEE (Secure Memory Encryption)       | Enabled        |
| IOMMU                                 | Enabled        |
| NX Mode                               | Enabled        |

### Verified kernel output

After installing, verify SEV-SNP with `talosctl dmesg`:

```
SEV-SNP: RMP table physical range [0x... - 0x...]
AMD-Vi: IOMMU SNP support enabled
ccp: sev enabled, psp enabled
SEV-SNP API:1.55 build:61
kvm_amd: SEV enabled (ASIDs 1006 - 1006)
kvm_amd: SEV-ES enabled (ASIDs 1 - 1005)
kvm_amd: SEV-SNP enabled (ASIDs 1 - 1005)
```

> **Bare-metal tips:** Check the Talos maintenance console to identify the
> correct install disk (often `/dev/nvme0n1`, not `/dev/sda`) and network
> interface name (e.g. `enp129s0f1np1`, not `eth0`).

## Verify SEV-SNP attestation

Deploy an Ubuntu pod on `kata-qemu-snp` (annotation
`io.containerd.cri.v1.images/unpack: "false"`, command `sleep infinity`),
exec in, then:

```bash
# SEV-SNP active in the guest kernel?
dmesg | grep -i sev
# Expected: "Memory Encryption Features active: AMD SEV SEV-ES SEV-SNP"
# Expected: "SEV: SNP running at VMPL0."

# Create the SEV guest device node
SNP_MAJOR=$(cat /sys/devices/virtual/misc/sev-guest/dev | awk -F: '{print $1}')
SNP_MINOR=$(cat /sys/devices/virtual/misc/sev-guest/dev | awk -F: '{print $2}')
mknod -m 600 /dev/sev-guest c "${SNP_MAJOR}" "${SNP_MINOR}"

# Fetch snpguest and verify the report against the AMD certificate chain
apt-get update && apt-get install -y curl ca-certificates
curl -LO https://github.com/virtee/snpguest/releases/download/v0.10.0/snpguest
chmod +x snpguest
./snpguest report report.bin request-file.txt --random
./snpguest fetch ca -r report.bin pem ./
./snpguest fetch vcek pem ./ ./report.bin
./snpguest verify certs ./
./snpguest verify attestation ./ ./report.bin
```

Expected: the ARK/ASK/VCEK chain validates and `VEK signed the Attestation
Report!`. For full attestation-gated secret delivery (KBS/AS/RVPS), deploy the
[trustee-operator](https://github.com/confidential-containers/trustee-operator)
— it works unchanged on Talos.

## Troubleshooting

### `fork/exec containerd-shim-kata-v2: no such file or directory`

The shim binary is dynamically linked. Rebuild — the Dockerfile builds a
static shim from source and hard-gates on it.

### `file /usr/local/share/ovmf/AMDSEV.fd does not exist`

The OVMF firmware for SEV-SNP is missing. The Dockerfile COPYs it from the
kata-static tarball at `opt/kata/share/ovmf/`.

### `Failed to open file "kvmvapic.bin": No such file or directory`

QEMU can't find its ROM files. The `/opt/kata → /usr/local` symlink resolves
this.

### `failed to mount .../rootfs: ENOENT`

Guest-pull is not enabled. The config needs
`experimental_force_guest_pull = true` when `shared_fs = "none"`.

### `CreateContainerRequest timed out`

The in-guest image pull exceeded `create_container_timeout` — the shipped
configs use 1200 s; very large images may also need more guest RAM (see the
guest sizing notes in the [NVIDIA add-on README](../coco-nvidia/README.md)).

### `exiting QMP loop, command cancelled`

Multiple possible causes — check CRI logs for the specific QEMU error:
`talosctl logs containerd | grep -i "qemu\|rom\|error"`.

### `host doesn't support requested feature: CPUID... rdseed`

A warning, not an error — QEMU continues normally.
