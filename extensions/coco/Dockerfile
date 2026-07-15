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

# sha256 of kata-static-${KATA_VERSION}-amd64.tar.zst. MUST be updated with
# KATA_VERSION — the build fails closed if it does not match.
ARG KATA_SHA256=1449ecea50bd91fa73a94648db195d18950fe869ba4b1f12d05f55f1fa7c1b01

# =============================================================================
# Stage 1: Download, extract, and patch paths in config files
# =============================================================================
FROM alpine:3.21 AS kata-static

ARG KATA_VERSION
ARG KATA_SHA256

RUN apk add --no-cache curl zstd tar sed

# Download and verify the official static release tarball.
#
# The checksum is not optional bookkeeping: this tarball IS the trusted
# computing base. It supplies the SEV-SNP QEMU, the AMDSEV.fd measured
# firmware, and the confidential guest kernel and image whose dm-verity root
# hash the shipped Kata config asserts. A GitHub release asset can be replaced
# in place by anyone with write access to the upstream repo, and the URL does
# not change when it is; TLS authenticates the host we fetch from, not the
# bytes it serves. Without this line the honest answer to "how do you know what
# is in your TCB" is "we downloaded whatever was at that URL that day".
#
# This value is corroborated by siderolabs/extensions, which pins the same
# sha256 for the same file in container-runtime/vars.yaml
# (KATA_CONTAINERS_STATIC_AMD64_SHA256).
# --retry/--continue-at: this is a 1.5 GB transfer and a mid-stream TCP reset is
# routine on a long link. Without them a dropped connection fails the whole
# build (curl 56), which is correct but needlessly brittle; resume + retry makes
# it survivable. The checksum below is what makes retrying SAFE — a partial or
# swapped body cannot pass it.
RUN curl -fSL --retry 5 --retry-delay 5 --retry-all-errors -C - \
  -o /tmp/kata-static.tar.zst \
  "https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-amd64.tar.zst" \
  && echo "${KATA_SHA256}  /tmp/kata-static.tar.zst" | sha256sum -c - \
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

# kata-qemu-snp deliberately stays on upstream's default hypervisor
# (@QEMUPATH@ -> qemu-system-x86_64). Earlier revisions rewrote it to
# qemu-system-x86_64-snp-experimental on the belief that the standard build
# could not launch an SEV-SNP guest. That is false at Kata 3.32.0: both
# binaries expose sev-snp-guest, and a standard-QEMU SNP guest was verified
# on EPYC 9355 hardware (QEMU launched with confidential-guest-support=snp
# and -object sev-snp-guest,cbitpos=51,policy=196608). The rewrite also
# pinned production SNP to the older QEMU of the two (11.0.0 vs 11.0.1).
# Only the GPU config uses the snp-experimental build, per upstream
# (@QEMUSNPPATH@), and the add-on ships that binary itself.

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

# qemu-system-x86_64 — backs BOTH kata-qemu-snp and kata-qemu-coco-dev.
# The snp-experimental build is not shipped here: only the GPU add-on's
# config names it, and the add-on ships it.
COPY --from=kata-static \
  /kata-static/opt/kata/bin/qemu-system-x86_64 \
  /rootfs/usr/local/bin/qemu-system-x86_64

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

# -- QEMU datadir (ROMs, firmware blobs) --------------------------------------
# qemu-system-x86_64 resolves this by a COMPILED-IN path (/opt/kata/share/
# kata-qemu/qemu), not via any config key — hence the /opt/kata symlink below,
# and hence the verify stage cannot check this tree by config reference.
# The kata-qemu-snp-experimental tree is not shipped here; it belongs with the
# binary that reads it, in the GPU add-on.
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-qemu/ \
  /rootfs/usr/local/share/kata-qemu/

# -- OVMF firmware ------------------------------------------------------------
# ONLY AMDSEV.fd: it is the sole firmware any shipped config names
# (configuration-qemu-snp.toml's firmware key; coco-dev leaves firmware = "").
# The upstream ovmf/ dir also carries OVMF.fd and OVMF.inteltdx.fd — the latter
# is Intel TDX firmware, which this AMD SEV-SNP extension can never load.
COPY --from=kata-static \
  /kata-static/opt/kata/share/ovmf/AMDSEV.fd \
  /rootfs/usr/local/share/ovmf/AMDSEV.fd


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
# directions. The configs come from the upstream tarball, so a Kata bump can
# silently repoint one at a file we do not ship (build stays green, guest will
# not boot), or strand a file no config names (dead RAM on every node —
# kata-containers-initrd-confidential.img shipped unreferenced for five
# releases at 77 MB, and the ovmf/ dir shipped Intel TDX firmware). Neither is
# visible without booting a guest, so it is asserted here.
#
# Three checks:
#   1. every path a config names resolves under /usr/local — a sed that
#      silently stops matching leaves an /opt/kata path, which would otherwise
#      only surface as a boot failure (the /opt/kata symlink would even mask it)
#   2. every named path exists
#   3. every payload file is either named by a config or explicitly allowlisted
#      below. The allowlist is NOT a rubber stamp: each entry is something
#      resolved by a mechanism other than a config key, and each needs a
#      stated reason.
#
# Run via `make verify-base`; CI runs it on every build.
FROM alpine:3.21 AS verify

COPY --from=extension /rootfs /rootfs

RUN set -eu; \
  cfgdir=/rootfs/usr/local/share/kata-containers; \
  rc=0; \
  refs=$(grep -hE '^[[:space:]]*(kernel|image|initrd|path|firmware|virtio_fs_daemon)[[:space:]]*=' \
           "$cfgdir"/configuration-*.toml \
         | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' | grep -v '^$' | sort -u); \
  echo "--- 1. every config-named path must be under /usr/local (sed drift):"; \
  for p in $refs; do \
    case "$p" in \
      /usr/local/*) echo "  ok      $p" ;; \
      *) echo "  BAD PREFIX $p (path rewrite did not apply)"; rc=1 ;; \
    esac; \
  done; \
  echo "--- 2. every config-named path must exist:"; \
  for p in $refs; do \
    if [ -e "/rootfs$p" ]; then echo "  ok      $p"; \
    else echo "  MISSING $p"; rc=1; fi; \
  done; \
  echo "--- 3. every payload file must be named by a config, or allowlisted:"; \
  for f in $(find /rootfs/usr/local -type f -o -type l | sort); do \
    p="${f#/rootfs}"; \
    case "$p" in \
      */share/kata-qemu/*|*/share/kata-qemu-snp-experimental/*) \
        continue ;; \
      */share/kata-containers/configuration-*.toml) \
        continue ;; \
      */bin/containerd-shim-kata-v2) \
        continue ;; \
    esac; \
    if echo "$refs" | grep -qxF "$p"; then echo "  ok      $p"; \
    else echo "  DEAD    $p (shipped, named by nothing)"; rc=1; fi; \
  done; \
  if [ "$rc" -eq 0 ]; then echo "OK: rootfs self-consistent"; \
  else echo "FAIL: rootfs inconsistent"; fi; \
  exit "$rc"

# Allowlist reasons (check 3):
#   share/kata-qemu/**            QEMU's datadir, resolved by a compiled-in
#                                 path, never named by a config key
#   share/kata-qemu-snp-experimental/**
#                                 same, for the add-on's binary (not shipped
#                                 by this extension; the pattern is kept so the
#                                 same check can be reused verbatim)
#   configuration-*.toml          the configs themselves
#   bin/containerd-shim-kata-v2   containerd resolves it from runtime_type
#                                 io.containerd.kata.v2, not from a path
