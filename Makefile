# =============================================================================
# talos-coco-extension — build & release entrypoints
# =============================================================================
# Versions are derived from the extension manifests (single source of truth):
#   extensions/coco/manifest.yaml        -> BASE_VERSION
#   extensions/coco-nvidia/manifest.yaml -> NVIDIA_VERSION
# Both extensions of one release share the same MAJOR.MINOR.PATCH (the NVIDIA
# add-on may carry an -rcN suffix until hardware-validated). `make
# check-versions` enforces this and the Kata version pairing.
#
# Common flows:
#   make images PUSH=true          # build + push both extensions
#   make installer-cpu             # CP / CPU-worker installer (stock imager)
#   make installer-gpu             # GPU-worker installer (custom IOMMUFD imager)
#   make iso                       # bare-metal install ISO (base extension)
#   make check-versions            # consistency gate (run by CI)
# =============================================================================

REGISTRY      ?= ghcr.io
USERNAME      ?= calintkd
PLATFORM      ?= linux/amd64
PUSH          ?= false

# Kata release both extensions are built from (must match the Dockerfiles'
# ARG default — enforced by check-versions).
KATA_VERSION  ?= 3.32.0

# Talos release used for installer/ISO composition. Pinned to the newest
# release for which the custom GPU imager exists (installer-gpu needs
# $(GPU_IMAGER) at this tag) — bump only after rebuilding kernel + imager
# for the new Talos release.
TALOS_VERSION ?= v1.13.5

# GPU workers need a custom imager whose install artifacts carry the
# CONFIG_IOMMUFD (=y or =m) + CONFIG_VFIO_DEVICE_CDEV=y kernel (no released
# Talos kernel enables it yet — both merged to siderolabs main 2026-07-15,
# pkgs#1608 as =m + talos#13765; see coco-nvidia/README.md "Custom Talos
# kernel"). Drop this once a Talos release carries iommufd.
GPU_IMAGER    ?= $(REGISTRY)/$(USERNAME)/imager:$(TALOS_VERSION)

# Parse metadata.version out of each manifest. Anchored to the `metadata:`
# block and to a semver-shaped value: an unanchored "first version: that isn't
# v1alpha1" would happily return `">="` from compatibility.talos.version if the
# keys were ever reordered, and tag the image :v">=".
manifest_version = $(shell awk '/^metadata:/{m=1; next} /^[a-z]/{m=0} \
  m && $$1 == "version:" && $$2 ~ /^[0-9]+\.[0-9]+\.[0-9]+/ {print $$2; exit}' $(1))

BASE_VERSION   := $(call manifest_version,extensions/coco/manifest.yaml)
NVIDIA_VERSION := $(call manifest_version,extensions/coco-nvidia/manifest.yaml)

BASE_IMG   := $(REGISTRY)/$(USERNAME)/talos-coco-extension:v$(BASE_VERSION)
NVIDIA_IMG := $(REGISTRY)/$(USERNAME)/talos-coco-nvidia:v$(NVIDIA_VERSION)

# Installer tags include the extension version — two extension releases
# otherwise collide on one tag and silently overwrite each other.
CPU_INSTALLER := $(REGISTRY)/$(USERNAME)/talos-installer:$(TALOS_VERSION)-kata$(KATA_VERSION)-ext$(BASE_VERSION)
GPU_INSTALLER := $(REGISTRY)/$(USERNAME)/talos-installer:$(TALOS_VERSION)-kata$(KATA_VERSION)-gpu-ext$(NVIDIA_VERSION)

# --provenance/--sbom=false: emit a plain OCI manifest instead of buildx's
# attestation-wrapped index — ghcr only reads the repo-linking
# org.opencontainers.image.source LABEL (which grants CI push access) from
# plain manifests, and the Talos imager consumes the image either way.
BUILDX_FLAGS := --provenance=false --sbom=false
# PUSH is matched exactly against true/false. Anything else is an error rather
# than a silent --load: `PUSH=TRUE` or `PUSH=1` would otherwise build, publish
# nothing, and exit 0 — and the installer targets would then quietly compose
# whatever that tag already holds on ghcr instead of what you just built.
ifeq ($(filter $(PUSH),true false),)
  $(error PUSH must be exactly 'true' or 'false', got '$(PUSH)')
endif
BUILDX_OUT := $(if $(filter true,$(PUSH)),--push,--load)

.PHONY: all images base nvidia verify-base verify-nvidia installer-cpu \
        installer-gpu iso check-versions print-versions

all: images

images: base nvidia

print-versions:
	@echo "BASE_VERSION   = $(BASE_VERSION)   -> $(BASE_IMG)"
	@echo "NVIDIA_VERSION = $(NVIDIA_VERSION) -> $(NVIDIA_IMG)"
	@echo "KATA_VERSION   = $(KATA_VERSION)"
	@echo "TALOS_VERSION  = $(TALOS_VERSION)"

base: check-versions verify-base
	docker buildx build --platform $(PLATFORM) $(BUILDX_FLAGS) \
	  --build-arg KATA_VERSION=$(KATA_VERSION) \
	  -f extensions/coco/Dockerfile --target extension \
	  -t $(BASE_IMG) $(BUILDX_OUT) extensions/coco/

nvidia: check-versions verify-nvidia
	docker buildx build --platform $(PLATFORM) $(BUILDX_FLAGS) \
	  --build-arg KATA_VERSION=$(KATA_VERSION) \
	  -f extensions/coco-nvidia/Dockerfile --target extension \
	  -t $(NVIDIA_IMG) $(BUILDX_OUT) extensions/coco-nvidia/

# Cross-check each assembled rootfs against its own configs (see the `verify`
# stages). Prerequisites of base/nvidia so a build cannot publish an image
# whose configs and payload disagree — the failure mode is invisible until a
# guest boots. Layer-cached, so the subsequent build is near-free.
verify-base:
	docker buildx build --platform $(PLATFORM) \
	  --build-arg KATA_VERSION=$(KATA_VERSION) \
	  -f extensions/coco/Dockerfile --target verify \
	  --output type=cacheonly --progress plain extensions/coco/

verify-nvidia:
	docker buildx build --platform $(PLATFORM) \
	  --build-arg KATA_VERSION=$(KATA_VERSION) \
	  -f extensions/coco-nvidia/Dockerfile --target verify \
	  --output type=cacheonly --progress plain extensions/coco-nvidia/

# Installers.
#
# Each target writes to its OWN output directory. They used to share
# _out/installer-amd64.tar, which meant a cpu build silently clobbered a gpu
# build (and a concurrent `crane push` would stream a half-overwritten tar).
#
# The tag carries the EXTENSION version, not just the Talos/Kata versions:
# different extension releases otherwise produce byte-different installers
# under an identical tag and overwrite each other in the registry.
#
# The imager pulls extension images from the REGISTRY, never from the local
# docker daemon (Talos v1.13 pkg/imager/profile/input.go: Pull() -> crane.Pull;
# it has no daemon code path). So these targets require the extension images to
# be pushed first — a local `make base PUSH=false` will be silently ignored in
# favour of whatever that tag currently holds on ghcr.
installer-cpu: check-versions
	mkdir -p _out-cpu && rm -f _out-cpu/installer-amd64.tar
	docker run --rm -t \
	  -v $(PWD)/_out-cpu:/out \
	  ghcr.io/siderolabs/imager:$(TALOS_VERSION) installer --arch amd64 \
	  --system-extension-image $(BASE_IMG)
	@echo "Push with: crane push _out-cpu/installer-amd64.tar $(CPU_INSTALLER)"

installer-gpu: check-versions
	mkdir -p _out-gpu && rm -f _out-gpu/installer-amd64.tar
	docker run --rm -t \
	  -v $(PWD)/_out-gpu:/out \
	  $(GPU_IMAGER) installer --arch amd64 \
	  --base-installer-image ghcr.io/siderolabs/installer-base:$(TALOS_VERSION) \
	  --system-extension-image $(BASE_IMG) \
	  --system-extension-image $(NVIDIA_IMG)
	@echo "Push with: crane push _out-gpu/installer-amd64.tar $(GPU_INSTALLER)"

# Bare-metal install ISO (base extension; add the GPU pieces via
# installer-gpu + `talosctl upgrade` after first boot).
iso: check-versions
	mkdir -p _out-iso && rm -f _out-iso/metal-amd64.iso
	docker run --rm -t \
	  -v $(PWD)/_out-iso:/out \
	  ghcr.io/siderolabs/imager:$(TALOS_VERSION) iso --arch amd64 \
	  --system-extension-image $(BASE_IMG)

# Consistency gate: lockstep versions + Kata pairing. CI runs this first.
check-versions:
	@set -e; \
	base="$(BASE_VERSION)"; nvidia="$(NVIDIA_VERSION)"; \
	[ -n "$$base" ] || { echo "FAIL: could not parse base version"; exit 1; }; \
	[ -n "$$nvidia" ] || { echo "FAIL: could not parse nvidia version"; exit 1; }; \
	core="$${nvidia%%-rc*}"; \
	[ "$$base" = "$$core" ] || { \
	  echo "FAIL: version lockstep broken: base=$$base nvidia=$$nvidia (core $$core)"; exit 1; }; \
	for df in extensions/coco/Dockerfile extensions/coco-nvidia/Dockerfile; do \
	  grep -q "^ARG KATA_VERSION=$(KATA_VERSION)$$" $$df || { \
	    echo "FAIL: $$df ARG KATA_VERSION != $(KATA_VERSION)"; exit 1; }; \
	done; \
	for mf in extensions/coco/manifest.yaml extensions/coco-nvidia/manifest.yaml; do \
	  grep -q "Kata Containers $(KATA_VERSION)" $$mf || { \
	    echo "FAIL: $$mf does not reference Kata Containers $(KATA_VERSION)"; exit 1; }; \
	done; \
	echo "OK: base=$$base nvidia=$$nvidia kata=$(KATA_VERSION)"
