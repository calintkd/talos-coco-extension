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
# Build (preferred): `make base` from the repo root.
# Manual (context = this directory):
#   docker buildx build --platform linux/amd64 \
#     --build-arg KATA_VERSION=3.32.0 \
#     -f extensions/coco/Dockerfile \
#     -t ghcr.io/<org>/talos-coco-extension:v<VERSION> --push extensions/coco/
#
# Debug (list tarball contents):
#   docker build --target kata-static -t kata-debug .
#   docker run --rm kata-debug find /kata-static/opt/kata -type f | sort
# =============================================================================

ARG KATA_VERSION=3.32.0
ARG GO_VERSION=1.25

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

# Enable guest-pull in coco-dev and SNP configs: with shared_fs=none, the
# kata-agent must pull container images inside the guest VM
RUN sed -i \
  's|^experimental_force_guest_pull = false|experimental_force_guest_pull = true|' \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-coco-dev.toml \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-snp.toml

# Raise create_container_timeout for the guest-pull configs. With guest-pull the
# container image is pulled AND UNPACKED inside the guest during
# CreateContainerRequest; kata's default 60s is too short for large images (a
# ~3GB image times out with "CreateContainerRequest timed out"). Match the NVIDIA
# GPU add-on's 1200s. kubelet runtimeRequestTimeout is unset (0s) on this stack,
# so the guest-pull budget is governed solely by create_container_timeout.
RUN sed -i \
  's|^create_container_timeout = .*|create_container_timeout = 1200|' \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-coco-dev.toml \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-snp.toml

# Point SNP config to the SNP-experimental QEMU binary (the standard QEMU
# does not support SEV-SNP VM launch)
RUN sed -i \
  's|/usr/local/bin/qemu-system-x86_64"|/usr/local/bin/qemu-system-x86_64-snp-experimental"|g' \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-snp.toml && \
  sed -i \
  's|/usr/local/bin/qemu-system-x86_64"]|/usr/local/bin/qemu-system-x86_64-snp-experimental"]|g' \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-snp.toml

# Debug: show what we have (visible in build log)
RUN echo "=== Binaries ===" && ls -1 /kata-static/opt/kata/bin/ \
  && echo "=== Libexec ===" && ls -1 /kata-static/opt/kata/libexec/ \
  && echo "=== Guest assets ===" && ls -1 /kata-static/opt/kata/share/kata-containers/ \
  && echo "=== Config files ===" && ls -1 /kata-static/opt/kata/share/defaults/kata-containers/*.toml

# Create /opt/kata → /usr/local symlink for COPY into scratch stage
RUN mkdir -p /tmp/opt-symlink/opt && ln -sf /usr/local /tmp/opt-symlink/opt/kata

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
# -mod=mod (not vendor): since Kata 3.32.0 the runtime's vendor/modules.txt is
# out of sync with go.mod ("explicitly required in go.mod, but not marked as
# explicit in vendor/modules.txt") — modules come from `go mod download`
# above, integrity enforced by go.sum.
RUN CGO_ENABLED=0 PREFIX=/usr/local make \
  BUILDFLAGS="-buildmode=exe -mod=mod" \
  SKIP_GO_VERSION_CHECK=y \
  containerd-shim-v2

# Verify it's static — HARD gate (a dynamic shim silently fails on Talos: no
# glibc). Use ldd, not file: `file` isn't installed in golang:bookworm, which
# made the old warn-only check always print its fallback.
RUN ldd containerd-shim-kata-v2 2>&1 | grep -q "not a dynamic executable" \
  && echo "OK: static binary" \
  || { echo "ERROR: shim is dynamically linked"; exit 1; }

# =============================================================================
# Stage 3: Assemble the Talos system extension image (FROM scratch)
# =============================================================================
FROM scratch AS extension

# Links the ghcr package to this repository (grants the repo's Actions
# workflows push access and surfaces the README on the package page).
LABEL org.opencontainers.image.source="https://github.com/calintkd/talos-coco-extension"

# -- Extension manifest -------------------------------------------------------
COPY manifest.yaml /manifest.yaml

# -- containerd-shim-kata-v2 (built from source, statically linked) ------------
COPY --from=kata-shim \
  /go/src/github.com/kata-containers/kata-containers/src/runtime/containerd-shim-kata-v2 \
  /rootfs/usr/local/bin/containerd-shim-kata-v2

# -- Hypervisors ---------------------------------------------------------------

# qemu-system-x86_64 (for kata-qemu-coco-dev)
COPY --from=kata-static \
  /kata-static/opt/kata/bin/qemu-system-x86_64 \
  /rootfs/usr/local/bin/qemu-system-x86_64

# qemu-system-x86_64-snp-experimental (for kata-qemu-snp — standard QEMU doesn't support SEV-SNP)
COPY --from=kata-static \
  /kata-static/opt/kata/bin/qemu-system-x86_64-snp-experimental \
  /rootfs/usr/local/bin/qemu-system-x86_64-snp-experimental

# virtiofsd
COPY --from=kata-static \
  /kata-static/opt/kata/libexec/virtiofsd \
  /rootfs/usr/local/libexec/virtiofsd

# -- Guest kernel -------------------------------------------------------------

# vmlinuz (compressed) — kata resolves KERNELCONFIDENTIALPATH to this for both
# kata-qemu-snp and kata-qemu-coco-dev. The uncompressed vmlinux.container is
# cloud-hypervisor's kernel only and is not shipped.
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/vmlinuz.container \
  /rootfs/usr/local/share/kata-containers/vmlinuz.container

# -- Guest image --------------------------------------------------------------

# Confidential guest image — used by BOTH kata-qemu-snp and kata-qemu-coco-dev
# (both configs set image = this; neither sets initrd, so the upstream
# kata-containers-initrd-confidential.img is not shipped).
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/kata-containers-confidential.img \
  /rootfs/usr/local/share/kata-containers/kata-containers-confidential.img

# -- QEMU firmware blobs (required by qemu-system-x86_64 at runtime) ----------
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-qemu/ \
  /rootfs/usr/local/share/kata-qemu/

# -- SNP-experimental QEMU firmware blobs (kvmvapic.bin, efi-virtio.rom, etc.) -
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-qemu-snp-experimental/ \
  /rootfs/usr/local/share/kata-qemu-snp-experimental/

# -- OVMF firmware (required by kata-qemu-snp for SEV-SNP) --------------------
# Contains AMDSEV.fd (AMD SEV-SNP) and OVMF.fd (standard UEFI)
COPY --from=kata-static \
  /kata-static/opt/kata/share/ovmf/ \
  /rootfs/usr/local/share/ovmf/


# -- Official configuration files (path-patched in Stage 1) --------------------

# kata-qemu-snp: AMD SEV-SNP production
COPY --from=kata-static \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-snp.toml \
  /rootfs/usr/local/share/kata-containers/configuration-qemu-snp.toml

# kata-qemu-coco-dev: Development/testing without TEE hardware
COPY --from=kata-static \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-coco-dev.toml \
  /rootfs/usr/local/share/kata-containers/configuration-qemu-coco-dev.toml

# -- Containerd CRI drop-in configuration -------------------------------------
COPY rootfs/etc/cri/conf.d/20-coco.part \
  /rootfs/etc/cri/conf.d/20-coco.part

# -- Symlink /opt/kata → /usr/local -------------------------------------------
# QEMU binaries have /opt/kata/ paths compiled in (e.g., data directory for ROM
# files, firmware paths). Since Talos extensions install to /usr/local/, this
# symlink makes all compiled-in paths work transparently.
# Note: Created in kata-static stage via a preparatory step, then copied here.
COPY --from=kata-static /tmp/opt-symlink/opt /rootfs/opt

# =============================================================================
# Stage 4: Verify the assembled rootfs
# =============================================================================
# Cross-checks the shipped configs against the shipped payload in both
# directions. Guest assets are the largest thing in this image, and the
# config files that name them come from the upstream tarball — so a Kata
# bump can silently repoint a config at a file we do not ship (breaks boot),
# or strand a file no config names (dead weight; kata-containers-initrd-
# confidential.img shipped unreferenced from v1.0.0 until 1.4.0 at 77 MB).
# Neither is visible without running a guest, so assert it at build time.
#
# Not in the default build graph — run via `make verify-base`.
FROM alpine:3.21 AS verify

COPY --from=extension /rootfs /rootfs

RUN set -eu; \
  cfgdir=/rootfs/usr/local/share/kata-containers; \
  refs=$(grep -hE '^[[:space:]]*(kernel|image|initrd|path|firmware)[[:space:]]*=' \
           "$cfgdir"/configuration-*.toml \
         | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' \
         | grep '^/usr/local/' | sort -u); \
  rc=0; \
  echo "--- paths named by a config must exist:"; \
  for p in $refs; do \
    if [ -e "/rootfs$p" ]; then echo "  ok    $p"; \
    else echo "  MISSING $p"; rc=1; fi; \
  done; \
  echo "--- guest assets must be named by a config:"; \
  for f in "$cfgdir"/*.img "$cfgdir"/*.container; do \
    [ -e "$f" ] || continue; \
    p="${f#/rootfs}"; \
    if echo "$refs" | grep -qxF "$p"; then echo "  ok    $p"; \
    else echo "  DEAD  $p (shipped, referenced by nothing)"; rc=1; fi; \
  done; \
  if [ "$rc" -eq 0 ]; then echo "OK: rootfs self-consistent"; \
  else echo "FAIL: rootfs inconsistent"; fi; \
  exit "$rc"
