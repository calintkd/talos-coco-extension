# =============================================================================
# Talos System Extension: NVIDIA GPU add-on for Confidential Containers
# =============================================================================
# Two-stage Dockerfile:
#   1. Downloads + extracts the official kata-static release tarball and
#      rewrites /opt/kata/ paths → /usr/local/ (byte-identical steps to the
#      base extension's Stage 1 → Docker layer cache shares the ~3 GB
#      download between the two builds)
#   2. Assembles the add-on extension (FROM scratch) with ONLY the NVIDIA
#      bits: GPU+SNP Kata config, NVIDIA guest kernel, NVIDIA confidential
#      guest image (~533 MiB in Kata 3.32.0 — Ubuntu noble + driver + NVRC;
#      was ~1.1 GB in the 3.30.0 tarball)
#
# Everything else (QEMU SNP-experimental, virtiofsd, shim, OVMF AMDSEV.fd)
# comes from the BASE extension — this add-on requires coco-kata-containers
# from the SAME release (same version, same Kata) on the same node.
#
# Build (preferred): `make nvidia` from the repo root.
# Manual (context = this directory):
#   docker buildx build --platform linux/amd64 \
#     --build-arg KATA_VERSION=3.32.0 \
#     -f extensions/coco-nvidia/Dockerfile \
#     -t ghcr.io/<org>/talos-coco-nvidia:v<VERSION> --push extensions/coco-nvidia/
# =============================================================================

ARG KATA_VERSION=3.32.0

# Static busybox for the nvidia-vfio-cdi extension service (the extension
# rootfs is FROM scratch — no shell of its own).
FROM busybox:1.36.1-musl AS busybox-static

# =============================================================================
# Stage 1: Download, extract, and patch paths in config files
# (steps 1-3 identical to the base extension Dockerfile for cache sharing)
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

# Enable guest-pull in the NVIDIA SNP config: shared_fs=none requires the
# kata-agent to pull container images inside the guest VM (same sed the
# base extension applies to its coco-dev + snp configs)
RUN sed -i \
  's|^experimental_force_guest_pull = false|experimental_force_guest_pull = true|' \
  /kata-static/opt/kata/share/defaults/kata-containers/configuration-qemu-nvidia-gpu-snp.toml

# Sanity gate — verified against the 3.32.0 tarball listing (2026-07-09):
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
