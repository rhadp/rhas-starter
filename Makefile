# RHAS Container Images Makefile
# Build container images locally using Podman

# Default registry and namespace
REGISTRY ?= ghcr.io
NAMESPACE ?= rhadp

# Image names and tags
DEVELOPER_IMAGE = $(REGISTRY)/$(NAMESPACE)/rhas-starter
BUILDER_IMAGE = $(REGISTRY)/$(NAMESPACE)/rhas-starter-builder
RUNTIME_IMAGE = $(REGISTRY)/$(NAMESPACE)/radioapp

TAG ?= latest

# Build tool
CONTAINER_TOOL ?= podman

# Build arguments
BUILD_ARGS ?= --build-arg TARGETARCH=$(shell uname -m | sed 's/x86_64/amd64/')

# Build the container images
developer-container:
	@echo "🔨 Building codespaces image..."
	$(CONTAINER_TOOL) build $(BUILD_ARGS) \
		-f containers/rhas-starter/Containerfile \
		-t $(DEVELOPER_IMAGE):$(TAG) \
		containers/rhas-starter/
	@echo "✅ Developer image built: $(DEVELOPER_IMAGE):$(TAG)"

builder-container:
	@echo "🔨 Building builder image..."
	$(CONTAINER_TOOL) build $(BUILD_ARGS) \
		-f containers/rhas-starter-builder/Containerfile \
		-t $(BUILDER_IMAGE):$(TAG) \
		containers/rhas-starter-builder/
	@echo "✅ Builder image built: $(BUILDER_IMAGE):$(TAG)"

# Build binaries inside the builder container
build: clean
	@echo "🔨 Building binaries inside container..."
	$(CONTAINER_TOOL) run --rm \
		-v $(PWD)/src:/opt/app-root/src:z \
		-w /opt/app-root/src \
		$(BUILDER_IMAGE):$(TAG) \
		bash -c "cmake . && make"
	@echo "✅ Binaries built successfully"

build-runtime: build
	@echo "🔨 Building runtime container..."
	$(CONTAINER_TOOL) build $(BUILD_ARGS) \
		-f src/Containerfile \
		-t $(RUNTIME_IMAGE):$(TAG) \
		src/
	@echo "✅ Runtime container built: $(RUNTIME_IMAGE):$(TAG)"

# Clean compilation artifacts
clean:
	@echo "🧹 Cleaning compilation artifacts..."
	@cd src && $(MAKE) clean 2>/dev/null || true
	@rm -rf src/CMakeCache.txt src/CMakeFiles src/cmake_install.cmake
	@rm -rf src/Makefile src/*.cmake
	@rm -f src/engine-service src/radio-service src/radio-client
	@rm -f src/*.o src/*.a src/.bash_history .bash_history
	@echo "✅ Cleanup complete"

.PHONY: container build clean

