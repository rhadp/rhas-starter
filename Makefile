# RHAS Container Images Makefile
# Build container images locally using Podman

# Default registry and namespace
REGISTRY ?= ghcr.io
NAMESPACE ?= rhadp

# Image names and tags
DEVELOPER_IMAGE = $(REGISTRY)/$(NAMESPACE)/rhas-starter

TAG ?= latest

# Build tool
CONTAINER_TOOL ?= podman

# Build arguments
BUILD_ARGS ?= --build-arg TARGETARCH=$(shell uname -m | sed 's/x86_64/amd64/')

# Build the developer image
container:
	@echo "🔨 Building codespaces image..."
	$(CONTAINER_TOOL) build $(BUILD_ARGS) \
		-f containers/rhas-starter/Containerfile \
		-t $(DEVELOPER_IMAGE):$(TAG) \
		containers/rhas-starter/
	@echo "✅ Developer image built: $(DEVELOPER_IMAGE):$(TAG)"

# Build binaries inside the container
build:
	@echo "🔨 Building binaries inside container..."
	$(CONTAINER_TOOL) run --rm \
		-v $(PWD)/src:/workspace:Z \
		-w /workspace \
		$(DEVELOPER_IMAGE):$(TAG) \
		bash -c "cmake . && make"
	@echo "✅ Binaries built successfully"

# Clean compilation artifacts
clean:
	@echo "🧹 Cleaning compilation artifacts..."
	@cd src && $(MAKE) clean 2>/dev/null || true
	@rm -rf src/CMakeCache.txt src/CMakeFiles src/cmake_install.cmake
	@rm -rf src/Makefile src/*.cmake
	@rm -f src/engine-service src/radio-service src/radio-client
	@rm -f src/*.o src/*.a
	@echo "✅ Cleanup complete"

.PHONY: container build clean

