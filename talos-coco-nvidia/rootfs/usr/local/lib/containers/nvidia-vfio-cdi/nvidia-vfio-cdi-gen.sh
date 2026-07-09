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
# Requires a host kernel with CONFIG_IOMMUFD=y + CONFIG_VFIO_DEVICE_CDEV=y
# (custom Talos kernel — see the add-on README).
#
# Device names registered per GPU (all resolve to the same cdev) match what
# the nvidia-sandbox-device-plugin (P_GPU_ALIAS=pgpu) may request:
#   - the cdev name  (vfio0)   <- the plugin's device ID
#   - the IOMMU group (73)
#   - a running index (0)
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
idx=0
SEEN=" "
for dev in "$DRV_DIR"/*:*:*.*; do
  [ -e "$dev" ] || continue
  bdf=$(basename "$dev")
  vendor=$(cat "$dev/vendor" 2>/dev/null)
  [ "$vendor" = "0x10de" ] || continue

  # IOMMUFD cdev name (requires VFIO_DEVICE_CDEV in the host kernel)
  cdev=$(ls "$dev/vfio-dev" 2>/dev/null | head -n 1)
  [ -n "$cdev" ] || { echo "$bdf: no vfio-dev cdev (kernel lacks IOMMUFD/CDEV?)"; continue; }

  group=$(basename "$(readlink "$dev/iommu_group" 2>/dev/null)" 2>/dev/null)

  # CDI device names must be unique across the whole spec — dedup (e.g. a
  # GPU in IOMMU group 0 would collide with another GPU's index 0).
  for name in "$cdev" "$group" "$idx"; do
    [ -n "$name" ] || continue
    case "$SEEN" in *" $name "*) continue ;; esac
    SEEN="$SEEN$name "
    {
      echo "  - name: \"$name\""
      echo "    containerEdits:"
      echo "      deviceNodes:"
      echo "        - path: /dev/vfio/devices/$cdev"
    } >> "$TMP"
  done

  echo "$bdf -> cdev=$cdev group=$group idx=$idx"
  count=$((count + 1))
  idx=$((idx + 1))
done

if [ "$count" -eq 0 ]; then
  echo "no vfio-bound NVIDIA GPU found yet — retrying"
  rm -f "$TMP"
  exit 1
fi

mv "$TMP" "$OUT"
echo "wrote $OUT ($count GPU(s))"
exit 0
