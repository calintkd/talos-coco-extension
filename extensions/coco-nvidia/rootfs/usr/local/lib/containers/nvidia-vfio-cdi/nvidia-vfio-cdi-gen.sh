#!/bin/sh
# nvidia-vfio-cdi-gen — Talos extension service payload (coco-kata-nvidia-gpu).
#
# Generates the VFIO CDI spec for NVIDIA GPUs bound to vfio-pci and writes it
# to /run/cdi (containerd's cdiSpecDirs on Talos; tmpfs, so this must run on
# every boot — hence an extension service, restart: untilSuccess).
#
# The spec is CDEV-ONLY on purpose: each device maps exclusively to
# /dev/vfio/devices/vfioN (the IOMMUFD char device). Including the legacy
# group node (/dev/vfio/<group>) makes Kata pick the legacy VFIO group
# backend and fail confidential guests with
# "ConfidentialGuest needs IOMMUFD - cannot use /dev/vfio/<group>".
# Requires a host kernel with CONFIG_IOMMUFD (=y or =m) +
# CONFIG_VFIO_DEVICE_CDEV=y. No released Talos kernel enables it; it is
# enabled upstream and will ship in a future Talos release. See the add-on
# README.
#
# Each GPU is registered under ONE CDI device name: its cdev (vfio0, vfio1,
# …) — the exact ID the nvidia-sandbox-device-plugin (P_GPU_ALIAS=pgpu)
# requests. No aliases: the IOMMU-group id and a running index live in
# different namespaces than the cdev, and flattening all three into CDI's
# single device-name space with a first-wins dedup could resolve a request to
# the WRONG GPU on a multi-GPU node. The cdev is already unique per device, so
# one name is correct and unambiguous.
#
# Exit 1 (-> service retry) until at least one vfio-bound NVIDIA GPU exists.
set -u

# The container rootfs ships a bare /busybox with NO applet symlinks — shim
# every external command through it (sh builtins cover the rest).
mkdir()    { /busybox mkdir "$@"; }
cat()      { /busybox cat "$@"; }
ls()       { /busybox ls "$@"; }
head()     { /busybox head "$@"; }
basename() { /busybox basename "$@"; }
readlink() { /busybox readlink "$@"; }
rm()       { /busybox rm "$@"; }
mv()       { /busybox mv "$@"; }

OUT_DIR=/run/cdi
OUT=$OUT_DIR/nvidia-vfio.yaml
DRV_DIR=/sys/bus/pci/drivers/vfio-pci

# Base-extension dependency guard (host /usr/local is bind-mounted ro).
# Talos extensions cannot declare dependencies on each other — this is the
# loud, runtime end of the pairing contract (build end: `make check-versions`).
#
# Check files the base provides and this add-on does NOT: the Kata shim,
# virtiofsd, and the SNP OVMF firmware (the GPU config's virtio_fs_daemon +
# firmware paths resolve here). The SNP-experimental QEMU is NOT a valid
# marker — this add-on ships that itself.
for f in \
  /usr/local/bin/containerd-shim-kata-v2 \
  /usr/local/libexec/virtiofsd \
  /usr/local/share/ovmf/AMDSEV.fd
do
  [ -e "$f" ] && continue
  echo "ERROR: base extension coco-kata-containers is not installed on this node"
  echo "       ($f missing). Install the base extension from the SAME release"
  echo "       as this add-on — kata-qemu-nvidia-gpu-snp pods cannot start"
  echo "       without it."
  exit 1
done

[ -d "$DRV_DIR" ] || { echo "vfio-pci driver not present yet"; exit 1; }

# temp file inside the rw-mounted /run (the service container has no /tmp)
mkdir -p "$OUT_DIR"
TMP=$OUT_DIR/.nvidia-vfio.tmp.$$
{
  echo 'cdiVersion: "0.5.0"'
  echo 'kind: nvidia.com/pgpu'
  echo 'devices:'
} > "$TMP"

count=0
for dev in "$DRV_DIR"/*:*:*.*; do
  [ -e "$dev" ] || continue
  bdf=$(basename "$dev")
  vendor=$(cat "$dev/vendor" 2>/dev/null)
  [ "$vendor" = "0x10de" ] || continue

  # IOMMUFD cdev name (requires VFIO_DEVICE_CDEV in the host kernel)
  cdev=$(ls "$dev/vfio-dev" 2>/dev/null | head -n 1)
  [ -n "$cdev" ] || { echo "$bdf: no vfio-dev cdev (kernel lacks IOMMUFD/CDEV?)"; continue; }

  {
    echo "  - name: \"$cdev\""
    echo "    containerEdits:"
    echo "      deviceNodes:"
    echo "        - path: /dev/vfio/devices/$cdev"
  } >> "$TMP"

  echo "$bdf -> cdev=$cdev"
  count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
  echo "no vfio-bound NVIDIA GPU found yet — retrying"
  rm -f "$TMP"
  exit 1
fi

mv "$TMP" "$OUT"
echo "wrote $OUT ($count GPU(s))"
exit 0
