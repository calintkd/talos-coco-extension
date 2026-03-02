# Talos CoCo Extension — Confidential Containers for Talos Linux

A Talos Linux system extension that provides [Confidential Containers (CoCo)](https://github.com/confidential-containers) runtime support via [Kata Containers](https://github.com/kata-containers/kata-containers), with full AMD SEV-SNP support on bare-metal hardware.

### How This Compares to Standard CoCo

On standard Linux distributions (Ubuntu, RHEL), CoCo is deployed via the [CoCo Helm Charts](https://github.com/confidential-containers/charts), which deploy a DaemonSet that extracts Kata binaries to `/opt/kata/` at runtime. This extension is the **Talos-native equivalent** — it packages the exact same Kata components (including `qemu-system-x86_64-snp-experimental`) but as an immutable system extension instead.

|                     | Ubuntu + CoCo Helm Charts             | Talos + This Extension                         |
| ------------------- | ------------------------------------- | ---------------------------------------------- |
| **Install method**  | DaemonSet extracts tarball at runtime | System extension baked into initramfs          |
| **Binary location** | `/opt/kata/bin/`                      | `/usr/local/bin/` (symlinked from `/opt/kata`) |
| **Shim**            | Dynamically linked (uses host glibc)  | Statically rebuilt (Talos has no glibc)        |
| **QEMU binary**     | `qemu-system-x86_64-snp-experimental` | Same binary                                    |
| **Filesystem**      | Writable host OS                      | Immutable rootfs                               |

## Overview

This extension packages Kata Containers 3.27.0 into a Talos system extension, providing:

| Runtime Handler      | Use Case                  | Hypervisor              | Confidential   |
| -------------------- | ------------------------- | ----------------------- | -------------- |
| `kata-qemu-snp`      | AMD SEV-SNP production    | QEMU (SNP-experimental) | ✅             |
| `kata-qemu-coco-dev` | CoCo dev/test (no TEE HW) | QEMU                    | ✅ (simulated) |
| `kata`               | Standard VM isolation     | Cloud Hypervisor        | ❌             |

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Talos Linux Host (immutable)                                   │
│                                                                 │
│  containerd ──► containerd-shim-kata-v2 ──► QEMU / CLH         │
│       │                    │                    │               │
│  CRI config          Kata config         Guest VM               │
│  (20-coco.part)   (configuration-*.toml)  ┌────────────┐       │
│                                           │ Guest      │       │
│                                           │ Kernel     │       │
│                                           │ + initrd   │       │
│                                           │ + OVMF     │       │
│  /opt/kata → /usr/local (symlink)         │ (SEV-SNP)  │       │
│                                           └────────────┘       │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Docker with Buildx support
- [`crane`](https://github.com/google/go-containerregistry/tree/main/cmd/crane) for pushing images
- `talosctl` CLI
- Container registry access (e.g., `ghcr.io`)

## Quick Start

### 1. Build & Push the Extension

```bash
docker buildx build --platform linux/amd64 \
  --build-arg KATA_VERSION=3.27.0 \
  -t ghcr.io/<your-org>/talos-coco-extension:v1.0.0 \
  --push .
```

### 2. Build & Push the Installer

```bash
# Build installer with the extension baked in
docker run --rm -t \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(pwd)/_out:/out \
  ghcr.io/siderolabs/imager:v1.12.4 installer \
  --arch amd64 \
  --system-extension-image ghcr.io/<your-org>/talos-coco-extension:v1.0.0

# Push to registry
crane push _out/installer-amd64.tar ghcr.io/<your-org>/talos-installer:v1.12.4-coco
```

### 3. Build ISO (for bare-metal install)

```bash
docker run --rm -t \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(pwd)/_out:/out \
  ghcr.io/siderolabs/imager:v1.12.4 iso \
  --arch amd64 \
  --system-extension-image ghcr.io/<your-org>/talos-coco-extension:v1.0.0
# Output: _out/metal-amd64.iso
```

### 4. Generate Config & Deploy

```bash
# Create a config patch (see machine-config-patch.yaml for template)
talosctl gen config my-cluster https://<NODE-IP>:6443 \
  --output my-cluster/ \
  --output-types controlplane,talosconfig \
  --config-patch @machine-config-patch.yaml

# Apply to node in maintenance mode
talosctl apply-config --insecure --nodes <NODE-IP> --file my-cluster/controlplane.yaml

# Bootstrap after reboot
talosctl bootstrap --talosconfig my-cluster/talosconfig \
  --nodes <NODE-IP> --endpoints <NODE-IP>

# Get kubeconfig
talosctl kubeconfig my-cluster/kubeconfig --talosconfig my-cluster/talosconfig \
  --nodes <NODE-IP> --endpoints <NODE-IP>
```

### 5. Apply RuntimeClasses & Label Node

```bash
kubectl apply -f runtime-classes.yaml
kubectl label node <node-name> coco.confidentialcontainers.org/snp=true
```

### 6. Deploy a Confidential Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: coco-test-snp
  annotations:
    io.containerd.cri.v1.images/unpack: "false"
spec:
  runtimeClassName: kata-qemu-snp
  containers:
    - name: test
      image: busybox:latest
      command:
        ["sh", "-c", "echo 'Hello from SEV-SNP!' && uname -a && sleep 3600"]
```

### 7. Verify SEV-SNP Attestation

Deploy an Ubuntu pod and verify attestation with [snpguest](https://github.com/virtee/snpguest):

```bash
# Deploy Ubuntu on kata-qemu-snp
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: secure-ubuntu
  annotations:
    io.containerd.cri.v1.images/unpack: "false"
spec:
  runtimeClassName: kata-qemu-snp
  containers:
  - name: ubuntu
    image: ubuntu:24.04
    command: ["/bin/sleep", "infinity"]
EOF

# Wait for pod to be Running, then exec in
kubectl exec -it secure-ubuntu -- /bin/bash
```

Inside the pod:

```bash
# Verify SEV-SNP is active in guest kernel
dmesg | grep -i sev
# Expected: "Memory Encryption Features active: AMD SEV SEV-ES SEV-SNP"
# Expected: "SEV: SNP running at VMPL0."

# Create the SEV guest device node
SNP_MAJOR=$(cat /sys/devices/virtual/misc/sev-guest/dev | awk -F: '{print $1}')
SNP_MINOR=$(cat /sys/devices/virtual/misc/sev-guest/dev | awk -F: '{print $2}')
mknod -m 600 /dev/sev-guest c "${SNP_MAJOR}" "${SNP_MINOR}"

# Install snpguest
apt-get update && apt-get install -y curl ca-certificates
curl -LO https://github.com/virtee/snpguest/releases/download/v0.10.0/snpguest
chmod +x snpguest

# Generate attestation report from AMD hardware
./snpguest report report.bin request-file.txt --random

# Fetch AMD certificate chain and verify
./snpguest fetch ca -r report.bin pem ./
./snpguest fetch vcek pem ./ ./report.bin
./snpguest verify certs ./
./snpguest verify attestation ./ ./report.bin
```

Expected output:

```
The AMD ARK was self-signed!
The AMD ASK was signed by the AMD ARK!
The VCEK was signed by the AMD ASK!

Reported TCB Boot Loader from certificate matches the attestation report.
Reported TCB TEE from certificate matches the attestation report.
Reported TCB SNP from certificate matches the attestation report.
Reported TCB Microcode from certificate matches the attestation report.
VEK signed the Attestation Report!
```

---

## Bare-Metal AMD SEV-SNP Deployment

### BIOS Requirements

Before installing, verify these BIOS settings on your AMD EPYC server:

| Setting                               | Required Value |
| ------------------------------------- | -------------- |
| SVM (Secure Virtual Machine)          | Enabled        |
| SEV (Secure Encrypted Virtualization) | Enabled        |
| SEV-ES                                | Enabled        |
| SEV-SNP                               | Enabled        |
| SMEE (Secure Memory Encryption)       | Enabled        |
| IOMMU                                 | Enabled        |
| NX Mode                               | Enabled        |

### Verified Kernel Output

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

### Network Interface Name

On bare-metal servers, the network interface name is hardware-specific (e.g., `enp129s0f1np1` instead of `eth0`). Check the Talos console in maintenance mode for the correct interface name and update your config patch accordingly.

### Install Disk

Bare-metal servers typically use NVMe drives (`/dev/nvme0n1`) instead of SATA (`/dev/sda`). Verify the correct disk path in the Talos maintenance console before applying config.

---

## Key Design Decisions

### Statically Linked Shim

The `containerd-shim-kata-v2` is rebuilt from source with `CGO_ENABLED=0 BUILDFLAGS="-buildmode=exe"` because Talos Linux has no glibc. The pre-built shim from the Kata static tarball is dynamically linked and won't work.

### SNP-Experimental QEMU

The `kata-qemu-snp` handler uses `qemu-system-x86_64-snp-experimental` (not the standard QEMU) because the standard QEMU does not support SEV-SNP VM launch. The config is patched during build to reference this binary.

### /opt/kata Symlink

Both QEMU binaries have `/opt/kata/` paths compiled in for their data directories (ROM files like `kvmvapic.bin`, `efi-virtio.rom`). Since Talos extensions install to `/usr/local/`, the extension creates a symlink `/opt/kata → /usr/local` to make all compiled-in paths work.

### Guest-Pull Mode

Both `kata-qemu-snp` and `kata-qemu-coco-dev` use `shared_fs = "none"` with `experimental_force_guest_pull = true`. Container images are pulled inside the guest VM, not shared from the host. Pods must include `io.containerd.cri.v1.images/unpack: "false"` annotation.

---

## Troubleshooting

### `fork/exec containerd-shim-kata-v2: no such file or directory`

The shim binary is dynamically linked. Rebuild the extension — the Dockerfile builds a static shim from source.

### `file /usr/local/share/ovmf/AMDSEV.fd does not exist`

The OVMF firmware for SEV-SNP is missing. The Dockerfile COPYs it from the kata-static tarball at `opt/kata/share/ovmf/`.

### `Failed to open file "kvmvapic.bin": No such file or directory`

QEMU can't find its ROM files. The `/opt/kata → /usr/local` symlink resolves this. If missing, QEMU falls back to its compiled-in data directory which won't exist on Talos.

### `failed to mount .../rootfs: ENOENT`

Guest-pull is not enabled. The config needs `experimental_force_guest_pull = true` when `shared_fs = "none"`.

### `exiting QMP loop, command cancelled`

Multiple possible causes — check CRI logs for the specific QEMU error:

```bash
talosctl read /var/log/cri.log | grep -i "qemu\|rom\|error"
```

### `host doesn't support requested feature: CPUID... rdseed`

This is a warning, not an error. It occurs when the host CPU doesn't support the RDSEED instruction. QEMU continues normally.

---

## File Structure

```
.
├── Dockerfile                  # Multi-stage build (kata-static + kata-shim + extension)
├── README.md                   # This file
├── manifest.yaml               # Talos extension metadata (v1.0.0)
├── machine-config-patch.yaml   # Machine config patch template
├── runtime-classes.yaml        # Kubernetes RuntimeClass manifests
└── rootfs/
    └── etc/cri/conf.d/
        └── 20-coco.part        # Containerd CRI runtime handler config
```

## Extension Contents

| Path                                                 | Description                                 |
| ---------------------------------------------------- | ------------------------------------------- |
| `/usr/local/bin/containerd-shim-kata-v2`             | Kata shim (static, built from source)       |
| `/usr/local/bin/cloud-hypervisor`                    | Cloud Hypervisor (for `kata` handler)       |
| `/usr/local/bin/qemu-system-x86_64`                  | Standard QEMU (for `kata-qemu-coco-dev`)    |
| `/usr/local/bin/qemu-system-x86_64-snp-experimental` | SNP QEMU (for `kata-qemu-snp`)              |
| `/usr/local/libexec/virtiofsd`                       | virtiofsd daemon                            |
| `/usr/local/share/kata-containers/`                  | Guest kernels, images, initrd, config files |
| `/usr/local/share/ovmf/AMDSEV.fd`                    | OVMF firmware for SEV-SNP                   |
| `/usr/local/share/kata-qemu/`                        | Standard QEMU firmware/ROM files            |
| `/usr/local/share/kata-qemu-snp-experimental/`       | SNP QEMU firmware/ROM files                 |
| `/opt/kata`                                          | Symlink → `/usr/local`                      |
| `/etc/cri/conf.d/20-coco.part`                       | Containerd runtime handler config           |

## Versioning

- **Extension version**: `v1.0.0` (independent from upstream Kata)
- **Kata Containers base**: `3.27.0`
- **Talos compatibility**: `>= v1.9.0`

> **Note:** Configuration TOML files (e.g., `configuration-qemu-snp.toml`) are extracted from the official Kata release tarball during the Docker build, with paths rewritten from `/opt/kata/` to `/usr/local/` and guest-pull enabled.

## References

- [Talos System Extensions Guide](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/)
- [Official kata-containers extension](https://github.com/siderolabs/extensions/tree/main/container-runtime/kata-containers)
- [Kata Containers Releases](https://github.com/kata-containers/kata-containers/releases)
- [Confidential Containers Project](https://confidentialcontainers.org/)
- [CoCo Helm Charts](https://github.com/confidential-containers/charts) (official deployment method)
- [CoCo Quickstart Guide](https://confidentialcontainers.org/docs/getting-started/)
- [AMD SEV-SNP Documentation](https://www.amd.com/en/developer/sev.html)
- [snpguest — AMD SEV-SNP attestation tool](https://github.com/virtee/snpguest)
