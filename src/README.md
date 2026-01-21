# Sample automotive applications

This directory contains a set of applications that demonstrate how
typical automotive applications use SOME/IP to talk to each
other. These apps work both natively and in a container.

## The apps

### engine-service

This is a very simple service with a single event that signals that
the car is reversing, which is regularly emitted.

### radio-service

This is a service that emulates a radio, regularly publishing
information about the current song, radio station and volume. It
accepts requests to turn on/off, switch channel, and change volume.
If the engine service is available it will listen for events from it
and temporarily lower the volume while reversing.

### radio-client

This is a command line program that displays the current state of the
radio service, as well as allow you to control it. The keyboard controls
are displayed on the screen.

## Building

The apps depend on boost and vsomeip3, and can be build with cmake like this:

```
 $ cmake .
 $ make
```

There is also a makefile that allows building rpms and srpms:

```
 $ make -f Makefile.rpm srpm
 $ make -f Makefile.rpm rpm
```

These rpms, in addition to required dependencies (dlt-daemon,
vsomeip3) are pre-build for cs9 it in [this copr
repo](https://copr.fedorainfracloud.org/coprs/alexl/cs9-sample-images/packages/).

Additionally, there is a
[Containerfile.auto-apps](Containerfile.auto-apps) file that allows
installing these apps into a container, using the above rpms. You can
build it like this:

```
 $ podman build -f Containerfile.auto-apps
```

Or use the Makefile.container helpers:

```
 $ make -f Makefile.container build
```

A pre-built version of these containers for aarch64 and x86-64 is
available in the [automotive sig container
repo](https://gitlab.com/CentOS/automotive/sample-images/container_registry/2944592).
