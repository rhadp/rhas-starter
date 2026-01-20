# rhas-starter

Example project demonstrating how to build and test a simple RHIVOS/AutoSD images with a sample automotive applications.

```shell
jmp shell -l type=virtual

j flasher flash "https://rhadp-aib-cdn.s3.us-east-2.amazonaws.com/prebuilt/autosd9-qemu.qcow2"

j power on && j console start-console
```

To drop out of the Jumpstarter shell, hit `Ctrl-B` 3 times.

This will also end your lease on the exporter, making it available for other users or clients.