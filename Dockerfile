# =============================================================================
# Talos System Extension: Confidential Containers (CoCo) with AMD SEV-SNP
# =============================================================================
# Three-stage Dockerfile:
#   1. Downloads + extracts the official kata-static release tarball and
#      rewrites /opt/kata/ paths → /usr/local/ in the bundled config files
#   2. Builds containerd-shim-kata-v2 from source (statically linked)
#      because the tarball binary is dynamically linked against glibc,
#      which does not exist on Talos's minimal filesystem
#   3. Assembles a Talos system extension image (FROM scratch)
#
# Build:
#   docker buildx build --platform linux/amd64 \
#     --build-arg KATA_VERSION=3.27.0 \
#     -t ghcr.io/<org>/talos-coco-extension:v1.0.0 --push .
#
# Debug (list tarball contents):
#   docker build --target kata-static -t kata-debug .
#   docker run --rm kata-debug find /kata-static/opt/kata -type f | sort
# =============================================================================

ARG KATA_VERSION=3.27.0
ARG GO_VERSION=1.24

# =============================================================================
# Stage 1: Download, extract, and patch paths in config files
# =============================================================================
FROM alpine:3.21 AS kata-static

ARG KATA_VERSION

RUN apk add --no-cache curl zstd tar sed

# Download the official static release tarball
RUN curl -fSL -o /tmp/kata-static.tar.zst \
  "https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-amd64.tar.zst" \
  && mkdir -p /kata-static \
  && tar --use-compress-program=unzstd -xf /tmp/kata-static.tar.zst -C /kata-static \
  && rm /tmp/kata-static.tar.zst

# Rewrite /opt/kata/ paths → /usr/local/ in all official config files
# so they match Talos extension filesystem layout
RUN for f in /kata-static/opt/kata/share/defaults/kata-containers/*.toml; do \
  sed -i \
  -e 's|/opt/kata/bin/|/usr/local/bin/|g' \
  -e 's|/opt/kata/libexec/|/usr/local/libexec/|g' \
  -e 's|/opt/kata/share/|/usr/local/share/|g' \
  "$f"; \
  done

# Enable guest-pull in coco-dev config: with shared_fs=none, the kata-agent
# must pull container images inside the guest VM
RUN sed -i \
  's|^experimental_force_guest_pull = false|experimental_force_guest_pull = true|' \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-coco-dev.toml

# Debug: show what we have (visible in build log)
RUN echo "=== Binaries ===" && ls -1 /kata-static/opt/kata/bin/ \
  && echo "=== Libexec ===" && ls -1 /kata-static/opt/kata/libexec/ \
  && echo "=== Guest assets ===" && ls -1 /kata-static/opt/kata/share/kata-containers/ \
  && echo "=== Config files ===" && ls -1 /kata-static/opt/kata/share/defaults/kata-containers/*.toml

# =============================================================================
# Stage 2: Build containerd-shim-kata-v2 from source (statically linked)
# =============================================================================
# The pre-compiled shim in the kata-static tarball is dynamically linked
# against glibc (/lib64/ld-linux-x86-64.so.2), which does not exist on
# Talos Linux. Building from source with CGO_ENABLED=0 produces a static
# Go binary that works on Talos.
# =============================================================================
FROM golang:${GO_VERSION}-bookworm AS kata-shim

ARG KATA_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
  git make gcc libc6-dev \
  && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${KATA_VERSION}" \
  https://github.com/kata-containers/kata-containers.git \
  /go/src/github.com/kata-containers/kata-containers

WORKDIR /go/src/github.com/kata-containers/kata-containers/src/runtime

RUN go mod download

# Build with CGO_ENABLED=0 and override -buildmode=pie → -buildmode=exe
# The Makefile defaults to -buildmode=pie which creates a dynamically linked PIE
# binary (requires /lib64/ld-linux-x86-64.so.2 which doesn't exist on Talos).
# Using -buildmode=exe produces a truly static, self-contained binary.
RUN CGO_ENABLED=0 PREFIX=/usr/local make \
  BUILDFLAGS="-buildmode=exe -mod=vendor" \
  SKIP_GO_VERSION_CHECK=y \
  containerd-shim-v2

# Verify it's static
RUN file containerd-shim-kata-v2 | grep -q "statically linked" && echo "OK: static binary" || echo "WARNING: not static"

# =============================================================================
# Stage 3: Assemble the Talos system extension image (FROM scratch)
# =============================================================================
FROM scratch AS extension

# -- Extension manifest -------------------------------------------------------
COPY manifest.yaml /manifest.yaml

# -- containerd-shim-kata-v2 (built from source, statically linked) ------------
COPY --from=kata-shim \
  /go/src/github.com/kata-containers/kata-containers/src/runtime/containerd-shim-kata-v2 \
  /rootfs/usr/local/bin/containerd-shim-kata-v2

# -- Hypervisors ---------------------------------------------------------------

# Cloud Hypervisor (for standard "kata" runtime handler)
COPY --from=kata-static \
  /kata-static/opt/kata/bin/cloud-hypervisor \
  /rootfs/usr/local/bin/cloud-hypervisor

# QEMU (for kata-qemu-snp & kata-qemu-coco-dev runtime handlers)
COPY --from=kata-static \
  /kata-static/opt/kata/bin/qemu-system-x86_64 \
  /rootfs/usr/local/bin/qemu-system-x86_64

# virtiofsd
COPY --from=kata-static \
  /kata-static/opt/kata/libexec/virtiofsd \
  /rootfs/usr/local/libexec/virtiofsd

# -- Guest kernels -------------------------------------------------------------

# vmlinux (uncompressed, for cloud-hypervisor)
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/vmlinux.container \
  /rootfs/usr/local/share/kata-containers/vmlinux.container

# vmlinuz (compressed, for QEMU — used by both SNP and coco-dev)
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/vmlinuz.container \
  /rootfs/usr/local/share/kata-containers/vmlinuz.container

# -- Guest images / initrd ----------------------------------------------------

# Standard guest image (for cloud-hypervisor "kata" handler)
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/kata-containers.img \
  /rootfs/usr/local/share/kata-containers/kata-containers.img

# Confidential guest image (for kata-qemu-coco-dev — dm-verity protected)
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/kata-containers-confidential.img \
  /rootfs/usr/local/share/kata-containers/kata-containers-confidential.img

# Confidential initrd (for kata-qemu-snp — contains attestation agent)
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/kata-containers-initrd-confidential.img \
  /rootfs/usr/local/share/kata-containers/kata-containers-initrd-confidential.img

# -- QEMU firmware blobs (required by qemu-system-x86_64 at runtime) ----------
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-qemu/ \
  /rootfs/usr/local/share/kata-qemu/

# -- Official configuration files (path-patched in Stage 1) --------------------

# kata-qemu-snp: AMD SEV-SNP production
COPY --from=kata-static \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-snp.toml \
  /rootfs/usr/local/share/kata-containers/configuration-qemu-snp.toml

# kata-qemu-coco-dev: Development/testing without TEE hardware
COPY --from=kata-static \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-coco-dev.toml \
  /rootfs/usr/local/share/kata-containers/configuration-qemu-coco-dev.toml

# kata (cloud-hypervisor): Standard non-confidential fallback
COPY --from=kata-static \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-clh.toml \
  /rootfs/usr/local/share/kata-containers/configuration.toml

# -- Containerd CRI drop-in configuration -------------------------------------
COPY rootfs/etc/cri/conf.d/20-coco.part \
  /rootfs/etc/cri/conf.d/20-coco.part
