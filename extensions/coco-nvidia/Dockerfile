# =============================================================================
# Talos System Extension: NVIDIA GPU add-on for Confidential Containers
# =============================================================================
# Three-stage Dockerfile (plus a busybox source stage for the CDI service):
#   1. Downloads + extracts the official kata-static release tarball and
#      rewrites /opt/kata/ paths → /usr/local/ (byte-identical steps to the
#      base extension's Stage 1 → Docker layer cache shares the ~1.5 GB
#      download between the two builds)
#   2. Assembles the add-on extension (FROM scratch) with the NVIDIA bits
#      (GPU+SNP Kata config, NVIDIA guest kernel, NVIDIA confidential guest
#      image ~533 MiB in Kata 3.32.0 — Ubuntu noble + driver + NVRC; was
#      ~1.1 GB in the 3.30.0 tarball) AND the SNP-experimental QEMU + its
#      datadir (the GPU config is the only thing that names it).
#   3. Verifies the assembled rootfs against its own config (build-time gate,
#      not shipped — `make nvidia` runs it via the verify-nvidia prerequisite)
#
# virtiofsd, the Kata shim, and OVMF AMDSEV.fd come from the BASE extension —
# this add-on requires coco-kata-containers from the SAME release (same
# version, same Kata) on the same node.
#
# Build (preferred): `make nvidia` from the repo root.
# Manual (context = this directory):
#   docker buildx build --platform linux/amd64 \
#     --build-arg KATA_VERSION=3.32.0 \
#     -f extensions/coco-nvidia/Dockerfile --target extension \
#     -t ghcr.io/<org>/talos-coco-nvidia:v<VERSION> --push extensions/coco-nvidia/
# =============================================================================

ARG KATA_VERSION=3.32.0

# sha256 of kata-static-${KATA_VERSION}-amd64.tar.zst. MUST match the base
# extension's ARG of the same name — see the verification note below.
ARG KATA_SHA256=1449ecea50bd91fa73a94648db195d18950fe869ba4b1f12d05f55f1fa7c1b01

# Static busybox for the nvidia-vfio-cdi extension service (the extension
# rootfs is FROM scratch — no shell of its own).
FROM busybox:1.36.1-musl AS busybox-static

# =============================================================================
# Stage 1: Download, extract, and patch paths in config files
# (steps 1-3 identical to the base extension Dockerfile for cache sharing)
# =============================================================================
FROM alpine:3.21 AS kata-static

ARG KATA_VERSION
ARG KATA_SHA256

RUN apk add --no-cache curl zstd tar sed

# Download and verify the official static release tarball. See the base
# extension's Dockerfile for why the checksum is load-bearing rather than
# hygiene.
#
# It matters twice over here. This extension and the base each fetch the
# tarball independently — CI builds them as separate matrix jobs on separate
# runners with no shared cache, so the "identical Stage 1 shares the download"
# comment above holds only for a local sequential build. Both manifests assert
# that the add-on's guest assets pair with the base's QEMU and shim "from the
# same release"; matching version STRINGS cannot enforce that, but a shared
# pinned hash can. If upstream re-cut the release between the two jobs, this is
# what catches it.
# See the base extension's Dockerfile for why --retry/-C are here and why the
# checksum is what makes retrying safe.
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

# Enable guest-pull in the NVIDIA SNP config: shared_fs=none requires the
# kata-agent to pull container images inside the guest VM (same sed the
# base extension applies to its coco-dev + snp configs)
RUN sed -i \
  's|^experimental_force_guest_pull = false|experimental_force_guest_pull = true|' \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu-snp.toml

# Sanity gate on the extracted 3.32.0 tarball:
#  - the GPU+SNP TOML exists and (post-rewrite) references the
#    SNP-experimental QEMU and the AMDSEV.fd firmware the BASE ships
#  - the NVIDIA guest kernel + confidential image symlinks resolve
#  - guest-pull is on
RUN test -f /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu-snp.toml \
  && test -e /kata-static/opt/kata/share/kata-containers/vmlinuz-nvidia-gpu.container \
  && test -e /kata-static/opt/kata/share/kata-containers/kata-containers-nvidia-gpu-confidential.img \
  && grep -q '^path = "/usr/local/bin/qemu-system-x86_64-snp-experimental"' \
       /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu-snp.toml \
  && grep -q '^firmware = "/usr/local/share/ovmf/AMDSEV.fd"' \
       /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu-snp.toml \
  && grep -q '^experimental_force_guest_pull = true' \
       /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu-snp.toml \
  && echo "OK: NVIDIA add-on artifacts verified"

# =============================================================================
# Stage 2: Assemble the Talos system extension image (FROM scratch)
# =============================================================================
FROM scratch AS extension

# Links the ghcr package to this repository (grants the repo's Actions
# workflows push access and surfaces the README on the package page).
LABEL org.opencontainers.image.source="https://github.com/calintkd/talos-coco-extension"

# -- Extension manifest -------------------------------------------------------
COPY manifest.yaml /manifest.yaml

# -- Kata configuration: SEV-SNP + NVIDIA GPU passthrough ----------------------
COPY --from=kata-static \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu-snp.toml \
  /rootfs/usr/local/share/kata-containers/configuration-qemu-nvidia-gpu-snp.toml

# -- SNP-experimental QEMU + its datadir ---------------------------------------
# Upstream builds configuration-qemu-nvidia-gpu-snp.toml against @QEMUSNPPATH@,
# so this handler — and ONLY this handler — needs the snp-experimental binary.
# It lives here rather than in the base because the base's own handlers run on
# the standard QEMU: shipping it in the base would put ~38 MB of unused payload
# on every control-plane and CPU-worker node.
# The datadir is resolved by a compiled-in path (/opt/kata/share/
# kata-qemu-snp-experimental/qemu) — the base's /opt/kata -> /usr/local symlink
# makes it resolve; both extensions land in one merged rootfs.
COPY --from=kata-static \
  /kata-static/opt/kata/bin/qemu-system-x86_64-snp-experimental \
  /rootfs/usr/local/bin/qemu-system-x86_64-snp-experimental
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-qemu-snp-experimental/ \
  /rootfs/usr/local/share/kata-qemu-snp-experimental/

# -- NVIDIA guest kernel (version tracks the Kata release; COPY dereferences the symlink)
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/vmlinuz-nvidia-gpu.container \
  /rootfs/usr/local/share/kata-containers/vmlinuz-nvidia-gpu.container

# -- NVIDIA confidential guest image (~533 MiB in Kata 3.32.0) -----------------
# Ubuntu noble rootfs with NVIDIA driver 595.58.03 + NVRC init; dm-verity
# root hash is baked into the TOML's kernel_verity_params.
COPY --from=kata-static \
  /kata-static/opt/kata/share/kata-containers/kata-containers-nvidia-gpu-confidential.img \
  /rootfs/usr/local/share/kata-containers/kata-containers-nvidia-gpu-confidential.img

# -- Containerd CRI drop-in (merges after the base extension's 20-coco.part) --
COPY rootfs/etc/cri/conf.d/30-coco-nvidia.part \
  /rootfs/etc/cri/conf.d/30-coco-nvidia.part

# -- Extension service: VFIO CDI spec generator --------------------------------
# Writes /run/cdi/nvidia-vfio.yaml at every boot (tmpfs) so vfio-bound NVIDIA
# GPUs resolve as CDI devices (kind nvidia.com/pgpu, CDEV-only -> Kata uses
# the IOMMUFD backend). Runner is a static busybox; spec discovered via /sys.
# The service container's rootfs is /usr/local/lib/containers/<service-name>
# (Talos derives it from the service `name`) — binary + script live THERE.
COPY --from=busybox-static /bin/busybox \
  /rootfs/usr/local/lib/containers/nvidia-vfio-cdi/busybox
COPY --chmod=0755 rootfs/usr/local/lib/containers/nvidia-vfio-cdi/nvidia-vfio-cdi-gen.sh \
  /rootfs/usr/local/lib/containers/nvidia-vfio-cdi/nvidia-vfio-cdi-gen.sh
COPY rootfs/usr/local/etc/containers/nvidia-vfio-cdi.yaml \
  /rootfs/usr/local/etc/containers/nvidia-vfio-cdi.yaml

# =============================================================================
# Stage 3: Verify the assembled rootfs
# =============================================================================
# Same contract as the base extension's verify stage, with one addition that
# matters here: this add-on's config legitimately names files the BASE ships
# (AMDSEV.fd, virtiofsd). Those are declared below as cross-extension
# references rather than treated as missing — but they are still asserted to
# be under /usr/local, so a sed drift in either extension is caught.
#
# This extension carries the largest object in the release (the ~533 MiB NVIDIA
# guest image), and its Stage-1 gate only checks the SOURCE tree by hardcoded
# filename. Those names are symlinks in the tarball, so a Kata bump that
# repoints the TOML at a new asset while keeping the old symlink would pass
# that gate, ship the wrong file, and fail only at guest boot. This stage
# closes that gap by deriving the expectation from the TOML instead.
#
# Run via `make verify-nvidia`; CI runs it on every build.
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
      /usr/local/*) echo "  ok       $p" ;; \
      *) echo "  BAD PREFIX $p (path rewrite did not apply)"; rc=1 ;; \
    esac; \
  done; \
  echo "--- 2. every config-named path must exist here, or be base-provided:"; \
  for p in $refs; do \
    case "$p" in \
      /usr/local/share/ovmf/AMDSEV.fd|/usr/local/libexec/virtiofsd) \
        echo "  base     $p (cross-extension: coco-kata-containers ships it)"; \
        continue ;; \
    esac; \
    if [ -e "/rootfs$p" ]; then echo "  ok       $p"; \
    else echo "  MISSING  $p"; rc=1; fi; \
  done; \
  echo "--- 3. every payload file must be named by a config, or allowlisted:"; \
  for f in $(find /rootfs/usr/local -type f -o -type l | sort); do \
    p="${f#/rootfs}"; \
    case "$p" in \
      */share/kata-qemu-snp-experimental/*) continue ;; \
      */share/kata-containers/configuration-*.toml) continue ;; \
      */lib/containers/nvidia-vfio-cdi/*) continue ;; \
      */etc/containers/nvidia-vfio-cdi.yaml) continue ;; \
    esac; \
    if echo "$refs" | grep -qxF "$p"; then echo "  ok       $p"; \
    else echo "  DEAD     $p (shipped, named by nothing)"; rc=1; fi; \
  done; \
  if [ "$rc" -eq 0 ]; then echo "OK: rootfs self-consistent"; \
  else echo "FAIL: rootfs inconsistent"; fi; \
  exit "$rc"

# Allowlist reasons (check 3):
#   share/kata-qemu-snp-experimental/**  QEMU datadir, resolved by a
#                                        compiled-in path, never named by a
#                                        config key
#   configuration-*.toml                 the config itself
#   lib/containers/nvidia-vfio-cdi/**    extension-service rootfs (busybox +
#                                        script); Talos resolves it from the
#                                        service name, not from a config
#   etc/containers/nvidia-vfio-cdi.yaml  the extension-service spec
