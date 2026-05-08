# rhas-starter

A starter project for building RHIVOS/AutoSD images with sample automotive applications.

## Overview

This repo walks you through the developer workflow for automotive software: build your app locally or in a Cloud-based Development Environment (CDE), 
test it in a container, then deploy it to a virtual (or real) device. You'll use the same tools and patterns that work at scale in production.

## Build the AutoSD Image

```shell
caib image build manifests/simple.aib.yml --disk --target qemu --internal-registry
```

## Test on a Virtual Device

[Jumpstarter](https://github.com/jumpstarter-dev/jumpstarter) lets you flash and control virtual and physical devices from your terminal. First, initialize the Jumpstarter client config:

```shell
jmp-login
```

### Lease a Virtual Device

Grab an available (virtual) device:

```shell
jmp shell -l type=qemu
```

### Flash and Boot

Flash your image (spins up a QEMU VM on a bare-metal OpenShift worker node), power on, and attach to the console:

```shell
j flasher flash "https://rhadp-aib-cdn.s3.us-east-2.amazonaws.com/prebuilt/autosd9-qemu.qcow2"

# or

j flasher flash oci://default-route-openshift-image-registry.apps.rhas.sandbox5426.opentlc.com/automotive-dev-operator-system/simple-1ef10:disk

j power on && j console start-console
```

Hit `Ctrl-B` three times to exit the Jumpstarter shell and release the device for others.




## Deploy

```shell
oc apply -f manifests/app-qemu-exporter.yml -n openshift-gitops
```