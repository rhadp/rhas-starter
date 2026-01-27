# rhas-starter

Example project demonstrating how to build and test a simple RHIVOS/AutoSD images with a sample automotive applications.

## Build

### Build locally

Prerequisites
- ARM CPU (e.g. Apple Silicon)
- Podman

Building the codebase requires dependencies that normally are not installed on a developers desktop/laptop, e.g. vsomeip3-devel or boost-devel. 
To avoid installing these dependecies locally, there is a so-called "builder container" with all build-time dependencies included. To build the apps locally, simply run:

```shell
# build the binaries
make build

# or, build a runnable container
make build-runtime
```

### Test locally

```shell
# run the radioapp container
make run
````

To monitor the apps output:
```shell
podman logs -f radioapp
```

To access the running container and `poke` around:
```shell
podman exec -it radioapp /bin/bash
```

- 
## Test on a virtual device

```shell
jmp shell -l type=virtual

j flasher flash "https://rhadp-aib-cdn.s3.us-east-2.amazonaws.com/prebuilt/autosd9-qemu.qcow2"

j power on && j console start-console
```

To drop out of the Jumpstarter shell, hit `Ctrl-B` 3 times.

This will also end your lease on the exporter, making it available for other users or clients.