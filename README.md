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

### Build using OpenShift Dev Spaces

Navigate to the OpenShift Dev Spaces Dashboard and create a new workspace form the GitHub repo: [https://github.com/rhadp/rhas-starter/](https://github.com/rhadp/rhas-starter/).

The project contains a `.devfile.yaml`, which tells OpenShift Dev Spaces to use the `ghcr.io/rhadp/rhas-starter:latest` container image to launch the web IDE. 
The container image is similar to the previous builder image as such as it has all the build-time dependencies for this project pre-installed.

You can build the code directly in the IDE:

```shell
make build

# or, like this:
cd src
cmake .
make
```

After creating the binaries, you can create and test the runtime container:

```shell
# build the runtime container
make build-runtime

# run the runtime container
make run
```
**Note:** You will see that the "builder container" is pulled from the conatiner registry the first time you run the "build-runtime" target.

Similar to inspecting the container locally, you can do the same inside the web IDE:

```shell
# and inspect it's output
podman logs -f radioapp

# or connect to the container
podman exec -it radioapp /bin/bash
```

This is possible because OpenShift Dev Spaces supports running nested containers, which allows you to use commands like `podman run` directly in a workspace.

- 
## Test on a virtual device

```shell
jmp shell -l type=virtual

j flasher flash "https://rhadp-aib-cdn.s3.us-east-2.amazonaws.com/prebuilt/autosd9-qemu.qcow2"

j power on && j console start-console
```

To drop out of the Jumpstarter shell, hit `Ctrl-B` 3 times.

This will also end your lease on the exporter, making it available for other users or clients.