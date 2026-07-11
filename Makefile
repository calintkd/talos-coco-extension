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
# CONFIG_IOMMUFD=y + CONFIG_VFIO_DEVICE_CDEV=y kernel (no stock Talos kernel
# enables it — see extensions/coco-nvidia/README.md "Custom Talos kernel").
GPU_IMAGER    ?= $(REGISTRY)/$(USERNAME)/imager:$(TALOS_VERSION)

BASE_VERSION   := $(shell awk '$$1 == "version:" && $$2 != "v1alpha1" {print $$2; exit}' extensions/coco/manifest.yaml)
NVIDIA_VERSION := $(shell awk '$$1 == "version:" && $$2 != "v1alpha1" {print $$2; exit}' extensions/coco-nvidia/manifest.yaml)

BASE_IMG   := $(REGISTRY)/$(USERNAME)/talos-coco-extension:v$(BASE_VERSION)
NVIDIA_IMG := $(REGISTRY)/$(USERNAME)/talos-coco-nvidia:v$(NVIDIA_VERSION)

# --provenance/--sbom=false: emit a plain OCI manifest instead of buildx's
# attestation-wrapped index — ghcr only reads the repo-linking
# org.opencontainers.image.source LABEL (which grants CI push access) from
# plain manifests, and the Talos imager consumes the image either way.
BUILDX_FLAGS := --provenance=false --sbom=false
BUILDX_OUT := $(if $(filter true,$(PUSH)),--push,--load)

.PHONY: all images base nvidia installer-cpu installer-gpu iso \
        check-versions print-versions

all: images

images: base nvidia

print-versions:
	@echo "BASE_VERSION   = $(BASE_VERSION)   -> $(BASE_IMG)"
	@echo "NVIDIA_VERSION = $(NVIDIA_VERSION) -> $(NVIDIA_IMG)"
	@echo "KATA_VERSION   = $(KATA_VERSION)"
	@echo "TALOS_VERSION  = $(TALOS_VERSION)"

base:
	docker buildx build --platform $(PLATFORM) $(BUILDX_FLAGS) \
	  --build-arg KATA_VERSION=$(KATA_VERSION) \
	  -f extensions/coco/Dockerfile \
	  -t $(BASE_IMG) $(BUILDX_OUT) extensions/coco/

nvidia:
	docker buildx build --platform $(PLATFORM) $(BUILDX_FLAGS) \
	  --build-arg KATA_VERSION=$(KATA_VERSION) \
	  -f extensions/coco-nvidia/Dockerfile \
	  -t $(NVIDIA_IMG) $(BUILDX_OUT) extensions/coco-nvidia/

# Installer for control-plane / CPU-worker nodes: stock imager, base only.
installer-cpu:
	mkdir -p _out
	docker run --rm -t \
	  -v /var/run/docker.sock:/var/run/docker.sock \
	  -v $(PWD)/_out:/out \
	  ghcr.io/siderolabs/imager:$(TALOS_VERSION) installer --arch amd64 \
	  --system-extension-image $(BASE_IMG)
	@echo "Push with: crane push _out/installer-amd64.tar $(REGISTRY)/$(USERNAME)/talos-installer:$(TALOS_VERSION)-kata$(KATA_VERSION)"

# Installer for GPU workers: custom IOMMUFD imager + BOTH extensions.
installer-gpu:
	mkdir -p _out
	docker run --rm -t \
	  -v /var/run/docker.sock:/var/run/docker.sock \
	  -v $(PWD)/_out:/out \
	  $(GPU_IMAGER) installer --arch amd64 \
	  --base-installer-image ghcr.io/siderolabs/installer-base:$(TALOS_VERSION) \
	  --system-extension-image $(BASE_IMG) \
	  --system-extension-image $(NVIDIA_IMG)
	@echo "Push with: crane push _out/installer-amd64.tar $(REGISTRY)/$(USERNAME)/talos-installer:$(TALOS_VERSION)-kata$(KATA_VERSION)-gpu"

# Bare-metal install ISO (base extension; add the GPU pieces via
# installer-gpu + `talosctl upgrade` after first boot).
iso:
	mkdir -p _out
	docker run --rm -t \
	  -v /var/run/docker.sock:/var/run/docker.sock \
	  -v $(PWD)/_out:/out \
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
