# =============================================================================
# Talos System Extension: Confidential Containers (CoCo) with AMD SEV-SNP
# =============================================================================
# Simple two-stage Dockerfile that:
#   1. Downloads + extracts the official kata-static release tarball
#      (which already contains ALL pre-compiled binaries including the shim)
#   2. Assembles a Talos system extension image (FROM scratch)
#
# Build:
#   docker build --build-arg KATA_VERSION=3.27.0 \
#     -t ghcr.io/<org>/talos-coco-extension:v3.27.0 .
# =============================================================================

# ---------------------------------------------------------------------------
# Build args
# ---------------------------------------------------------------------------
ARG KATA_VERSION=3.27.0

# =============================================================================
# Stage 1: Download and extract kata-static release tarball
# =============================================================================
FROM alpine:3.21 AS kata-static

ARG KATA_VERSION

RUN apk add --no-cache curl zstd tar

# Download the official static release tarball
RUN curl -fSL -o /tmp/kata-static.tar.zst \
  "https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-amd64.tar.zst" \
  && mkdir -p /kata-static \
  && tar --use-compress-program=unzstd -xf /tmp/kata-static.tar.zst -C /kata-static \
  && rm /tmp/kata-static.tar.zst

# List what we got (useful for debugging during build)
RUN echo "=== kata-static contents ===" \
  && find /kata-static/opt/kata -type f | sort | head -200 || true

# =============================================================================
# Stage 2: Assemble the Talos system extension image
# =============================================================================
FROM scratch AS extension

# -- Extension manifest -------------------------------------------------------
COPY manifest.yaml /manifest.yaml

# -- containerd-shim-kata-v2 (pre-compiled in the static tarball) --------------
COPY --from=kata-static \
  /kata-static/opt/kata/bin/containerd-shim-kata-v2 \
  /rootfs/usr/local/bin/containerd-shim-kata-v2

# -- Hypervisors ---------------------------------------------------------------

# Cloud Hypervisor (standard kata runtime)
COPY --from=kata-static \
  /kata-static/opt/kata/bin/cloud-hypervisor \
  /rootfs/usr/local/bin/cloud-hypervisor

# QEMU (for CoCo SNP & coco-dev runtimes)
COPY --from=kata-static \
  /kata-static/opt/kata/bin/qemu-system-x86_64 \
  /rootfs/usr/local/bin/qemu-system-x86_64

# virtiofsd
COPY --from=kata-static \
  /kata-static/opt/kata/libexec/virtiofsd \
  /rootfs/usr/local/libexec/virtiofsd

# -- Guest kernels -------------------------------------------------------------

# Standard guest kernel (for cloud-hypervisor / coco-dev)
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/vmlinux.container \
  /rootfs/usr/local/share/kata-containers/vmlinux.container

# SNP-specific guest kernel (for kata-qemu-snp)
# NOTE: If vmlinuz-snp.container does not exist in your release, the build
# will fail here. Some releases use a single vmlinuz.container for all QEMU
# variants — in that case, change the source path below.
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/vmlinuz-snp.container \
  /rootfs/usr/local/share/kata-containers/vmlinuz-snp.container

# -- Guest images / initrd ----------------------------------------------------

# Standard guest root filesystem image (for cloud-hypervisor / coco-dev)
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/kata-containers.img \
  /rootfs/usr/local/share/kata-containers/kata-containers.img

# Confidential guest initrd (for kata-qemu-snp — contains attestation agent)
# NOTE: The exact filename varies across releases. Common names:
#   - kata-containers-initrd-confidential.img
#   - kata-containers-initrd.img
# Adjust if your release uses a different name.
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/kata-containers-initrd-confidential.img \
  /rootfs/usr/local/share/kata-containers/kata-containers-initrd-confidential.img

# -- OVMF firmware (for SEV-SNP) -----------------------------------------------
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/OVMF.fd \
  /rootfs/usr/local/share/kata-containers/OVMF.fd

# -- QEMU firmware blobs (required by qemu-system-x86_64) ---------------------
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-qemu/ \
  /rootfs/usr/local/share/kata-qemu/

# -- Configuration files -------------------------------------------------------
COPY rootfs/usr/local/share/kata-containers/configuration.toml \
  /rootfs/usr/local/share/kata-containers/configuration.toml

COPY rootfs/usr/local/share/kata-containers/configuration-qemu-snp.toml \
  /rootfs/usr/local/share/kata-containers/configuration-qemu-snp.toml

COPY rootfs/usr/local/share/kata-containers/configuration-qemu-coco-dev.toml \
  /rootfs/usr/local/share/kata-containers/configuration-qemu-coco-dev.toml

# -- Containerd CRI drop-in configuration -------------------------------------
COPY rootfs/etc/cri/conf.d/20-coco.part \
  /rootfs/etc/cri/conf.d/20-coco.part
