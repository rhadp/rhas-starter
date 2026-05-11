# rhas-starter

A starter project for building RHIVOS/AutoSD images with sample automotive applications.

## Overview

This repo walks you through the developer workflow for automotive software: build your app locally or in a Cloud-based Development Environment (CDE), test it in a container, then deploy it to a virtual (or real) device. You'll use the same tools and patterns that work at scale in production.

### About the Sample App

The sample mimics a typical in-vehicle setup: a `radio-service` that broadcasts track info, station name, and volume, plus a `radio-client` that sends commands (power, tune, volume). There's also an `engine-service` for good measure.

The apps communicate over [SOME/IP](https://some-ip.com/)—the standard middleware for automotive service discovery and messaging. Built with C++ and [CMake](https://cmake.org/).

## Build Locally

**Prerequisites:** ARM CPU (e.g. Apple Silicon) and Podman.

The build needs dependencies like `vsomeip3-devel` and `boost-devel` that you probably don't have installed. Rather than polluting your system, use the builder container:

```shell
make build-podman    # compile binaries
make build-runtime   # package into runtime container
```

### Test Locally

```shell
make run                            # start the radioapp container
podman logs -f radioapp             # watch the output
podman exec -it radioapp /bin/bash  # poke around inside
```

## Build in OpenShift Dev Spaces

Create a workspace from [github.com/rhadp/rhas-starter](https://github.com/rhadp/rhas-starter/). The `.devfile.yaml` configures the IDE to use a container with all build dependencies pre-installed.

Build directly in the IDE:

```shell
make build
```

Then build and run the runtime container:

```shell
make build-runtime
make run
```

OpenShift Dev Spaces supports [nested containers](https://docs.redhat.com/en/documentation/red_hat_openshift_dev_spaces/3.25/html/release_notes_and_known_issues/new-features#enhancement-crw-8320), so `podman` commands work as expected. Inspect your container the same way as locally:

```shell
podman logs -f radioapp
podman exec -it radioapp /bin/bash
```

## Build the AutoSD Image

Once your app works, package it into an [AutoSD](https://sigs.centos.org/automotive/index.html) OS image—a bootable in-vehicle OS with your containerized app baked in:

```shell
./scripts/trigger-build
```

This kicks off an OpenShift Pipeline. Track progress in the OpenShift web console; the finished image lands in S3.

## Test on a Virtual Device

[Jumpstarter](https://github.com/jumpstarter-dev/jumpstarter) lets you flash and control virtual and physical devices from your terminal. First, initialize the Jumpstarter client config:

```shell
./scripts/init-jumpstarter
```

### Lease a Virtual Device

Grab an available (virtual) device:

```shell
jmp shell -l type=virtual
```

### Flash and Boot

Flash your image (spins up a QEMU VM on a bare-metal OpenShift worker node), power on, and attach to the console:

```shell
j flasher flash "https://rhadp-aib-cdn.s3.us-east-2.amazonaws.com/prebuilt/autosd9-qemu.qcow2"

j power on && j console start-console
```

Hit `Ctrl-B` three times to exit the Jumpstarter shell and release the device for others.