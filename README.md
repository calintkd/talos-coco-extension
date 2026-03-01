# Talos System Extension: Confidential Containers (CoCo)

A native **Talos Linux system extension** that packages [Confidential Containers (CoCo)](https://confidentialcontainers.org/) for bare-metal and VM environments, with full AMD SEV-SNP support.

This extension replaces the standard `kata-deploy` Helm chart, which fails on Talos's immutable root filesystem. All binaries are pre-installed into Talos-approved read-only paths.

## What's Included

| Component                 | Path on Talos Host                                                         |
| ------------------------- | -------------------------------------------------------------------------- |
| `containerd-shim-kata-v2` | `/usr/local/bin/`                                                          |
| `cloud-hypervisor`        | `/usr/local/bin/`                                                          |
| `qemu-system-x86_64`      | `/usr/local/bin/`                                                          |
| `virtiofsd`               | `/usr/local/libexec/`                                                      |
| Guest kernel (standard)   | `/usr/local/share/kata-containers/vmlinux.container`                       |
| Guest kernel (SNP)        | `/usr/local/share/kata-containers/vmlinuz-snp.container`                   |
| Guest image               | `/usr/local/share/kata-containers/kata-containers.img`                     |
| Confidential initrd       | `/usr/local/share/kata-containers/kata-containers-initrd-confidential.img` |
| OVMF firmware (SNP)       | `/usr/local/share/kata-containers/OVMF.fd`                                 |
| QEMU firmware blobs       | `/usr/local/share/kata-qemu/`                                              |

### Registered Runtime Handlers

| Handler              | Config File                        | Use Case                                           |
| -------------------- | ---------------------------------- | -------------------------------------------------- |
| `kata-qemu-snp`      | `configuration-qemu-snp.toml`      | **Production** AMD SEV-SNP confidential containers |
| `kata-qemu-coco-dev` | `configuration-qemu-coco-dev.toml` | **Dev/Test** without TEE hardware                  |
| `kata`               | `configuration.toml`               | Standard cloud-hypervisor (non-confidential)       |

---

## Prerequisites

- **Docker** (for building the extension image)
- **A container registry** you can push to (e.g., `ghcr.io`, Docker Hub, private registry)
- **Talos CLI** (`talosctl`) v1.12.4+
- **Talos `imager`** (Docker image `ghcr.io/siderolabs/imager:v1.12.4`)

---

## Step 1: Build the Extension Image

```bash
# Clone this repo / cd to the extension directory
cd /path/to/talos-extension

# Build (uses Kata Containers 3.27.0 by default)
docker build \
  --build-arg KATA_VERSION=3.27.0 \
  -t ghcr.io/<your-org>/talos-coco-extension:v3.27.0 \
  .
```

> **Note on build errors:** The Dockerfile copies specific files from the `kata-static` tarball. If a file doesn't exist in the 3.27.0 release (e.g., the SNP kernel name changed), the build will fail with a clear `COPY --from` error. Run a quick debug build to list available files:
>
> ```bash
> docker build --target kata-static -t kata-debug .
> docker run --rm kata-debug find /kata-static/opt/kata -type f | sort
> ```
>
> Then adjust the `COPY --from=kata-static` source paths in the Dockerfile accordingly.

---

## Step 2: Push to Your Registry

```bash
docker push ghcr.io/<your-org>/talos-coco-extension:v3.27.0
```

---

## Step 3: Build a Custom Talos Installer with the Extension

Use the Talos `imager` to create a custom installer image that includes your extension.

### Option A: Custom Installer Image (for existing clusters — upgrades)

```bash
docker run --rm -t \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(pwd)/_out:/out \
  ghcr.io/siderolabs/imager:v1.12.4 \
  installer \
  --system-extension-image ghcr.io/<your-org>/talos-coco-extension:v3.27.0
```

This produces a custom installer image. Push it to your registry:

```bash
# The imager outputs an installer image reference — tag + push it
crane push _out/installer-amd64.tar ghcr.io/<your-org>/talos-installer:v1.12.4-coco
```

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
  --system-extension-image ghcr.io/<your-org>/talos-coco-extension:v3.27.0
```

Boot your machine from the resulting ISO, then apply the machine config.

### Option C: Use Image Factory (easiest, if public)

If your extension image is public, you can use [Talos Image Factory](https://factory.talos.dev/) and add your extension image URL in the "System Extensions" section.

---

## Step 4: Apply Machine Configuration

Edit `machine-config-patch.yaml` — replace `ghcr.io/<your-org>/talos-coco-extension:v3.27.0` with your actual image reference.

```bash
# For a new cluster
talosctl gen config my-cluster https://<CONTROL_PLANE_IP>:6443 \
  --config-patch @machine-config-patch.yaml

# For an existing node
talosctl apply-config \
  --nodes <NODE_IP> \
  --patch @machine-config-patch.yaml
```

### Machine Config Patch Explained

```yaml
machine:
  install:
    extensions:
      - image: ghcr.io/<your-org>/talos-coco-extension:v3.27.0
  nodeLabels:
    coco.confidentialcontainers.org/snp: "true" # only on SEV-SNP bare-metal
  kernel:
    modules:
      - name: kvm_amd # KVM for AMD (needed by QEMU)
      - name: ccp # AMD Cryptographic Co-processor (provides /dev/sev)
```

> **For your test VM** (no real SEV-SNP): remove the `ccp` module and the `snp: "true"` label.

---

## Step 5: Create Kubernetes RuntimeClasses

After the node reboots with the extension installed:

```bash
kubectl apply -f runtime-classes.yaml
```

---

## Step 6: Test

### Test on VM (kata-qemu-coco-dev)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: coco-test-dev
spec:
  runtimeClassName: kata-qemu-coco-dev
  containers:
  - name: test
    image: busybox
    command: ["sh", "-c", "echo 'Hello from CoCo dev pod!' && uname -a && sleep 3600"]
EOF

# Check it started
kubectl get pod coco-test-dev -w

# Verify it's running inside a micro-VM (different kernel than the host)
kubectl exec coco-test-dev -- uname -r
```

### Test on Bare-Metal (kata-qemu-snp)

```bash
# First, label the SEV-SNP node
kubectl label node <node-name> coco.confidentialcontainers.org/snp=true

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

kubectl get pod coco-test-snp -w
```

#### Verify SEV-SNP is Active

```bash
# On the host (via talosctl)
talosctl dmesg --nodes <NODE_IP> | grep -i sev

# Expected output should include lines like:
#   SEV-SNP: Launching SEV-SNP guest
#   ccp: SEV-SNP API version X.XX
```

---

## Troubleshooting

### Build Fails on COPY — File Not Found

The `kata-static` tarball contents can vary between releases. Run:

```bash
docker build --target kata-static -t kata-debug .
docker run --rm kata-debug find /kata-static/opt/kata -type f | sort
```

Then adjust the `COPY --from=kata-static` paths in the Dockerfile. Common variations:

- `vmlinuz-snp.container` → might be `vmlinuz.container`
- `kata-containers-initrd-confidential.img` → might be `kata-containers-initrd.img`
- `OVMF.fd` → might be `OVMF_CODE.fd` or `OVMF_CODE.snp.fd`

### Pod Stuck in ContainerCreating

```bash
# Check events
kubectl describe pod <pod-name>

# Check containerd logs on the node
talosctl logs containerd --nodes <NODE_IP> | tail -50

# Check kata shim logs
talosctl logs --nodes <NODE_IP> | grep -i kata
```

### RuntimeClass Not Found

Ensure the extension is installed and the node has rebooted:

```bash
talosctl get extensions --nodes <NODE_IP>
# Should show "coco-kata-containers" in the list
```

Check that the containerd config was merged:

```bash
talosctl read /etc/cri/conf.d/20-coco.part --nodes <NODE_IP>
```

### /dev/kvm Not Available

Verify KVM is available:

```bash
talosctl read /dev/kvm --nodes <NODE_IP>
# Or
talosctl dmesg --nodes <NODE_IP> | grep -i kvm
```

If missing, ensure `kvm_amd` (or `kvm_intel`) is in your machine config `kernel.modules`.

### /dev/sev Not Available (SNP only)

```bash
talosctl dmesg --nodes <NODE_IP> | grep -i "sev\|ccp"
```

If missing:

1. Check BIOS: SEV-SNP must be enabled
2. Ensure `ccp` kernel module is loaded via machine config
3. Verify CPU: must be AMD EPYC 7003 (Milan) or newer

---

## File Structure

```
talos-coco-extension/
├── Dockerfile                          # Multi-stage build
├── manifest.yaml                       # Talos extension metadata
├── machine-config-patch.yaml           # Talos machine config example
├── runtime-classes.yaml                # Kubernetes RuntimeClass manifests
├── README.md                           # This file
└── rootfs/
    ├── etc/
    │   └── cri/
    │       └── conf.d/
    │           └── 20-coco.part        # Containerd runtime handler registration
    └── usr/
        └── local/
            └── share/
                └── kata-containers/
                    ├── configuration.toml              # Cloud-hypervisor config
                    ├── configuration-qemu-snp.toml     # QEMU + SEV-SNP config
                    └── configuration-qemu-coco-dev.toml # QEMU dev/test config
```

---

## References

- [Talos System Extensions Guide](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/)
- [Official kata-containers extension](https://github.com/siderolabs/extensions/tree/main/container-runtime/kata-containers)
- [Kata Containers Releases](https://github.com/kata-containers/kata-containers/releases)
- [Confidential Containers Project](https://confidentialcontainers.org/)
- [CoCo Quickstart Guide](https://confidentialcontainers.org/docs/getting-started/)
- [AMD SEV-SNP Documentation](https://www.amd.com/en/developer/sev.html)
