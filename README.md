# Talos System Extension: Confidential Containers (CoCo)

A native **Talos Linux system extension** that packages [Confidential Containers (CoCo)](https://confidentialcontainers.org/) for bare-metal and VM environments, with full AMD SEV-SNP support.

This extension replaces the standard `kata-deploy` Helm chart, which fails on Talos's immutable root filesystem. All binaries are pre-installed into Talos-approved read-only paths.

## What's Included

| Component                  | Path on Talos Host                                                         |
| -------------------------- | -------------------------------------------------------------------------- |
| `containerd-shim-kata-v2`  | `/usr/local/bin/` _(built from source, statically linked)_                 |
| `cloud-hypervisor`         | `/usr/local/bin/`                                                          |
| `qemu-system-x86_64`       | `/usr/local/bin/`                                                          |
| `virtiofsd`                | `/usr/local/libexec/`                                                      |
| Guest kernel (compressed)  | `/usr/local/share/kata-containers/vmlinuz.container`                       |
| Guest kernel (standard)    | `/usr/local/share/kata-containers/vmlinux.container`                       |
| Guest image (standard)     | `/usr/local/share/kata-containers/kata-containers.img`                     |
| Guest image (confidential) | `/usr/local/share/kata-containers/kata-containers-confidential.img`        |
| Confidential initrd        | `/usr/local/share/kata-containers/kata-containers-initrd-confidential.img` |
| QEMU firmware blobs        | `/usr/local/share/kata-qemu/`                                              |

### Registered Runtime Handlers

| Handler              | Hypervisor       | Config File                        | Use Case                                            |
| -------------------- | ---------------- | ---------------------------------- | --------------------------------------------------- |
| `kata-qemu-snp`      | QEMU             | `configuration-qemu-snp.toml`      | **Production** AMD SEV-SNP confidential containers  |
| `kata-qemu-coco-dev` | QEMU             | `configuration-qemu-coco-dev.toml` | **Dev/Test** without TEE hardware (guest-pull mode) |
| `kata`               | cloud-hypervisor | `configuration.toml`               | Standard Kata (non-confidential, virtio-fs)         |

---

## Prerequisites

- **Docker** with `buildx` (for cross-platform building on Apple Silicon)
- **A container registry** you can push to (e.g., `ghcr.io`, Docker Hub)
- **[crane](https://github.com/google/go-containerregistry/tree/main/cmd/crane)** — for pushing installer images (`brew install crane`)
- **Talos CLI** (`talosctl`) v1.12.4+
- **Talos `imager`** (Docker image `ghcr.io/siderolabs/imager:v1.12.4`)

---

## Step 1: Build & Push the Extension Image

> **Important:** If building on Apple Silicon (M1/M2/M3 Mac), you must use `--platform linux/amd64` since Talos nodes run x86_64.

```bash
docker buildx build --platform linux/amd64 \
  --build-arg KATA_VERSION=3.27.0 \
  -t ghcr.io/<your-org>/talos-coco-extension:v1.0.0 \
  --push .
```

The Dockerfile has three stages:

1. **kata-static** — Downloads the official Kata release tarball, rewrites `/opt/kata/` paths to `/usr/local/`, and enables `experimental_force_guest_pull` for the coco-dev config
2. **kata-shim** — Builds `containerd-shim-kata-v2` from source with `CGO_ENABLED=0 -buildmode=exe` for a statically-linked binary (the pre-compiled tarball binary is dynamically linked against glibc, which Talos doesn't have)
3. **extension** — Assembles the final `FROM scratch` Talos extension image

> **Debug build:** To inspect what's in the kata-static tarball:
>
> ```bash
> docker build --target kata-static -t kata-debug .
> docker run --rm kata-debug find /kata-static/opt/kata -type f | sort
> ```

---

## Step 2: Build a Custom Talos Installer

Use the Talos `imager` to create a custom installer image that includes your extension.

### Option A: Custom Installer Image (for existing clusters — upgrades)

```bash
docker run --rm -t \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(pwd)/_out:/out \
  ghcr.io/siderolabs/imager:v1.12.4 \
  installer \
  --arch amd64 \
  --system-extension-image ghcr.io/<your-org>/talos-coco-extension:v1.0.0
```

Push the installer to your registry:

```bash
crane push _out/installer-amd64.tar ghcr.io/<your-org>/talos-installer:v1.12.4-coco
```

> **Note:** Make sure the package is public in your registry so Talos nodes can pull it.

Then upgrade your existing node:

```bash
talosctl upgrade \
  --nodes <NODE_IP> \
  --image ghcr.io/<your-org>/talos-installer:v1.12.4-coco
```

### Option B: Custom ISO (for new installations)

```bash
docker run --rm -t \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(pwd)/_out:/out \
  ghcr.io/siderolabs/imager:v1.12.4 \
  iso \
  --arch amd64 \
  --system-extension-image ghcr.io/<your-org>/talos-coco-extension:v1.0.0
```

---

## Step 3: Verify Extension is Loaded

```bash
talosctl get extensions --nodes <NODE_IP>
# Should show: coco-kata-containers  3.27.0

# Verify the containerd config was merged
talosctl read /etc/cri/conf.d/20-coco.part --nodes <NODE_IP>

# Verify the shim binary is statically linked
talosctl read /usr/local/bin/containerd-shim-kata-v2 --nodes <NODE_IP> | file -
# Should show: ELF 64-bit LSB executable, x86-64, statically linked
```

---

## Step 4: Create Kubernetes RuntimeClasses

```bash
kubectl apply -f runtime-classes.yaml
```

---

## Step 5: Test

### Test 1: Standard Kata (cloud-hypervisor, virtio-fs)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: kata-test
spec:
  runtimeClassName: kata
  containers:
  - name: test
    image: busybox
    command: ["sh", "-c", "echo 'Hello from Kata pod!' && uname -a && sleep 3600"]
EOF

# Verify it runs inside a micro-VM (different kernel than host)
kubectl exec kata-test -- uname -r
# Expected: 6.18.12 (Kata guest kernel, different from host's 6.18.9-talos)
```

### Test 2: CoCo Dev Mode (QEMU, guest-pull, dm-verity)

The `kata-qemu-coco-dev` handler uses **guest-pull mode** — container images are pulled inside the QEMU micro-VM, not on the host. This is designed for confidential computing where the host is untrusted.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: coco-test-dev
  annotations:
    io.containerd.cri.v1.images/unpack: "false"
spec:
  runtimeClassName: kata-qemu-coco-dev
  containers:
  - name: test
    image: busybox:latest
    command: ["sh", "-c", "echo 'Hello from CoCo dev pod!' && uname -a && sleep 3600"]
EOF

kubectl get pod coco-test-dev -w
kubectl logs coco-test-dev
# Expected: Hello from CoCo dev pod!
```

### Verify CoCo Functionality

```bash
# 1. dm-verity protected guest rootfs
kubectl exec coco-test-dev -- sh -c "cat /proc/cmdline | tr ' ' '\n' | grep -E 'dm-mod|verity|sha256'"
# Expected: dm-verity hash verification of the guest root filesystem

# 2. Confidential Data Hub (CDH) configured
kubectl exec coco-test-dev -- sh -c "cat /proc/cmdline | tr ' ' '\n' | grep cdh"
# Expected: agent.cdh_api_timeout=50

# 3. VM isolation (different kernel)
kubectl exec coco-test-dev -- uname -r
# Expected: 6.18.12 (guest kernel, not host's 6.18.9-talos)

# 4. Guest-pull overlay mount
kubectl exec coco-test-dev -- mount | head -1
# Expected: overlay on / type overlay (...lowerdir=/run/kata-containers/image/layers/...)

# 5. No host path leakage
kubectl exec coco-test-dev -- sh -c "ls /opt/kata 2>/dev/null || echo 'PASS: no host paths leaked'"
```

### Test 3: CoCo nginx (multi-VM workload)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: coco-nginx
  annotations:
    io.containerd.cri.v1.images/unpack: "false"
spec:
  runtimeClassName: kata-qemu-coco-dev
  containers:
  - name: nginx
    image: nginx:1.27-alpine
    ports:
    - containerPort: 80
    command: ["sh", "-c", "echo 'CoCo confidential nginx!' > /usr/share/nginx/html/index.html && nginx -g 'daemon off;'"]
EOF

# After it's running, test from another CoCo pod
kubectl exec coco-test-dev -- wget -qO- http://<coco-nginx-pod-ip>
# Expected: CoCo confidential nginx!
```

### Test on Bare-Metal (kata-qemu-snp)

Requires AMD EPYC 7003 (Milan) or newer with SEV-SNP enabled in BIOS.

```bash
# Apply machine config with KVM/SEV modules
talosctl apply-config --nodes <NODE_IP> --patch @machine-config-patch.yaml

# Label the SNP node
kubectl label node <node-name> katacontainers.io/kata-runtime=true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: coco-test-snp
spec:
  runtimeClassName: kata-qemu-snp
  containers:
  - name: test
    image: busybox
    command: ["sh", "-c", "echo 'Hello from SNP confidential pod!' && sleep 3600"]
EOF

# Verify SEV-SNP is active
talosctl dmesg --nodes <NODE_IP> | grep -i sev
```

---

## Troubleshooting

### Pod fails: `fork/exec containerd-shim-kata-v2: no such file or directory`

The shim binary may be dynamically linked. Verify it's static:

```bash
talosctl read /usr/local/bin/containerd-shim-kata-v2 --nodes <NODE_IP> | file -
```

If it says "dynamically linked" — rebuild the extension. The Dockerfile builds the shim from source with `CGO_ENABLED=0 -buildmode=exe` to produce a static binary. The Kata Makefile defaults to `-buildmode=pie` which creates a dynamic binary even with `CGO_ENABLED=0`.

### Pod fails: `shared_fs mount ENOENT` or `rootfs mount failed`

The `kata-qemu-coco-dev` handler uses `shared_fs = "none"` and `experimental_force_guest_pull = true`. Container images are pulled inside the guest VM. Make sure:

1. The pod has `io.containerd.cri.v1.images/unpack: "false"` annotation
2. The guest VM has network access to pull images
3. No old Helm chart config is overriding the runtime handler (check `/etc/cri/conf.d/` for stale files)

### Old Helm chart configs interfering

If you previously installed CoCo via Helm / `kata-deploy`, old containerd drop-in files may override your extension's config. Check:

```bash
talosctl ls /etc/cri/conf.d/ --nodes <NODE_IP>
```

Remove any stale files via `talosctl edit machineconfig` — look for entries under `machine.files` that reference `/var/lib/coco-guest/` or `/var/lib/kata/`.

### Build Fails on COPY — File Not Found

The `kata-static` tarball contents can vary between releases. Debug with:

```bash
docker build --target kata-static -t kata-debug .
docker run --rm kata-debug find /kata-static/opt/kata -type f | sort
```

### /dev/kvm Not Available

```bash
talosctl dmesg --nodes <NODE_IP> | grep -i kvm
```

If missing, add `kvm_amd` (or `kvm_intel`) to your machine config `kernel.modules`.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Talos Host (immutable root FS)                                 │
│                                                                 │
│  containerd ──► 20-coco.part ──► containerd-shim-kata-v2       │
│                                         │                       │
│                    ┌────────────────────┤────────────────────┐  │
│                    │                    │                    │  │
│             ┌──────▼──────┐   ┌────────▼───────┐  ┌────────▼─┐│
│             │ kata        │   │ kata-qemu-     │  │ kata-    ││
│             │ (clh)       │   │ coco-dev       │  │ qemu-snp ││
│             │ virtio-fs   │   │ guest-pull     │  │ initrd   ││
│             │ standard    │   │ dm-verity      │  │ SEV-SNP  ││
│             └─────────────┘   └────────────────┘  └──────────┘│
│                                                                 │
│  Extension files:  /usr/local/bin/      (binaries)             │
│                    /usr/local/libexec/  (virtiofsd)             │
│                    /usr/local/share/    (kernels, images, cfg)  │
│                    /etc/cri/conf.d/     (containerd drop-in)   │
└─────────────────────────────────────────────────────────────────┘
```

---

## File Structure

```
talos-coco-extension/
├── Dockerfile                          # Three-stage build (tarball + Go shim + scratch)
├── manifest.yaml                       # Talos extension metadata
├── machine-config-patch.yaml           # Talos machine config example
├── runtime-classes.yaml                # Kubernetes RuntimeClass manifests
├── README.md                           # This file
└── rootfs/
    └── etc/
        └── cri/
            └── conf.d/
                └── 20-coco.part        # Containerd runtime handler registration
```

> **Note:** Configuration TOML files (e.g., `configuration-qemu-coco-dev.toml`) are extracted from the official Kata release tarball during the Docker build, with paths rewritten from `/opt/kata/` to `/usr/local/` and guest-pull enabled.

---

## References

- [Talos System Extensions Guide](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/)
- [Official kata-containers extension](https://github.com/siderolabs/extensions/tree/main/container-runtime/kata-containers)
- [Kata Containers Releases](https://github.com/kata-containers/kata-containers/releases)
- [Confidential Containers Project](https://confidentialcontainers.org/)
- [CoCo Quickstart Guide](https://confidentialcontainers.org/docs/getting-started/)
- [AMD SEV-SNP Documentation](https://www.amd.com/en/developer/sev.html)
