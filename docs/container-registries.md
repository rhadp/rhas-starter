# Jumpstarter and Container Registries

This document explains how Jumpstarter interacts with OCI container registries
when flashing devices, how authentication works across the different driver
families, and how the FLS binary bridges the gap between the target device and
the registry.

## Overview

Jumpstarter uses container registries in two distinct ways during a flash
operation:

1. **Flasher bundle pulling** -- the exporter (host machine) downloads an OCI
   artifact that contains a kernel, initramfs, device-tree blobs, and a manifest
   describing how to boot the target into a minimal environment suitable for
   flashing.

2. **OS image pulling** -- the target device (or, in the QEMU case, the
   exporter itself) pulls the actual disk image from a registry using the
   `oci://` URL scheme and the **FLS** binary.

These two interactions have different authentication models because they execute
in different contexts (host vs. target).

---

## 1. Flasher Bundle Pulling (Exporter-Side)

### What happens

The `BaseFlasher` driver on the exporter downloads an OCI artifact -- the
"flasher bundle" -- that contains everything needed to net-boot the target
device into a minimal Linux environment. The bundle is specified by the
`flasher_bundle` field in the exporter configuration (e.g.
`quay.io/jumpstarter-dev/jumpstarter-flasher-ti-j784s4:latest`).

### Library used

The [ORAS Python client](https://github.com/oras-project/oras-py)
(`oras.provider.Registry`) handles the pull:

```python
# python/packages/jumpstarter-driver-flashers/jumpstarter_driver_flashers/driver.py

oras_client = Registry()
oras_client.pull(self.flasher_bundle, outdir=bundle_dir)
```

### Authentication

ORAS uses the **standard OCI credential stores** on the exporter host.
Jumpstarter does not pass explicit credentials here -- it relies on whatever
credentials are already configured for the host user running the exporter.
Typical credential sources (in order of ORAS lookup) include:

| Source | Path |
|---|---|
| Docker config | `~/.docker/config.json` |
| Podman/containers auth | `${XDG_RUNTIME_DIR}/containers/auth.json` |
| Legacy Docker config | `~/.dockercfg` |

To authenticate to a private registry for flasher bundles, run the appropriate
login command on the exporter host before starting the exporter:

```bash
# Docker
docker login quay.io

# Podman
podman login quay.io

# Skopeo
skopeo login quay.io
```

### Caching

Downloaded bundles are cached at `/var/lib/jumpstarter/flasher` (configurable
via the `cache_dir` field). A bundle that has already been pulled during the
current exporter session is not pulled again.

---

## 2. OS Image Pulling (Target-Side via FLS)

### What happens

When the user passes an `oci://` URL as the image path, the actual disk image
is pulled **on the target device** (the device being flashed). The target boots
into a minimal BusyBox environment and runs the **FLS** binary, which knows how
to pull an OCI image layer and write it directly to a block device.

### The FLS binary

[FLS](https://github.com/jumpstarter-dev/fls) is a small, statically-linked
tool purpose-built for flashing OCI images. It supports two subcommands:

- `fls from-url <oci-url> <target-device>` -- used by the flashers driver
  (physical boards with U-Boot + BusyBox).
- `fls fastboot <oci-url> [-t partition:file ...]` -- used by the RideSX
  driver (Qualcomm boards via USB fastboot).

FLS is resolved through the following priority chain:

1. Custom binary URL (`fls_binary_url` / `--fls-binary-url`), if
   `allow_custom_binaries` is enabled.
2. GitHub release download (`fls_version` / `--fls-version`).
3. Pre-installed system binary (i.e., `fls` on `$PATH`).

For the flashers driver specifically, FLS may also be downloaded directly onto
the target via `curl` from a GitHub release URL.

### Authentication -- Environment Variables

OCI registry authentication for `oci://` image pulls is handled through two
environment variables:

| Variable | Description |
|---|---|
| `OCI_USERNAME` | Registry username or robot account name |
| `OCI_PASSWORD` | Registry password or token (including JWTs) |

Both must be provided together -- setting one without the other raises an error.

These variables are read **client-side** and translated into the
`FLS_REGISTRY_USERNAME` / `FLS_REGISTRY_PASSWORD` environment variables that
FLS expects.

### Authentication -- Explicit Parameters

When using the Python API directly, credentials can be passed as method arguments:

```python
client.flash(
    "oci://registry.example.com/my-image:latest",
    oci_username="myuser",
    oci_password="mypassword",
)
```

If explicit parameters are not provided and the path starts with `oci://`, the
client falls back to reading `OCI_USERNAME` and `OCI_PASSWORD` from the
environment.

### How Credentials Reach the Target

The credential delivery mechanism differs by driver:

#### Flashers driver (physical boards via serial console)

The target device is running a BusyBox shell accessed over a serial console.
Credentials cannot be passed via environment variables (there is no shared
process space), so the client writes a credentials file directly to the target
through the serial console:

1. A file `/tmp/fls_creds` is created containing:
   ```
   FLS_REGISTRY_USERNAME='<username>'
   FLS_REGISTRY_PASSWORD='<password>'
   ```
2. The content is **base64-encoded** and written in 512-byte chunks to avoid
   serial line buffer overflow (important for long tokens like JWTs).
3. The base64 data is decoded on the target:
   `base64 -d /tmp/fls_creds.b64 > /tmp/fls_creds`
4. Before running FLS, the credentials are sourced into the shell environment:
   `set -o allexport; . /tmp/fls_creds; set +o allexport;`
5. The console debug stream automatically **redacts** password values via
   `_RedactingConsoleWriter` so credentials do not appear in logs.

#### QEMU driver (virtual machines)

The QEMU driver runs FLS as a subprocess on the exporter host. Credentials are
passed directly as process environment variables:

```python
fls_env = os.environ.copy()
fls_env["FLS_REGISTRY_USERNAME"] = oci_username
fls_env["FLS_REGISTRY_PASSWORD"] = oci_password
```

#### RideSX driver (Qualcomm boards via fastboot)

Similar to QEMU -- FLS runs as a subprocess on the exporter host and
credentials are injected via the process environment:

```python
fls_env = os.environ.copy()
fls_env["FLS_REGISTRY_USERNAME"] = oci_username
fls_env["FLS_REGISTRY_PASSWORD"] = oci_password
```

---

## 3. Credential Resolution Summary

The following diagram shows the credential resolution order for `oci://` paths:

```
User calls flash("oci://registry.com/image:tag")
        │
        ▼
┌─────────────────────────────────┐
│ Explicit oci_username/password  │──── provided? ──▶ use them
│ passed as method arguments      │
└─────────────────────────────────┘
        │ not provided
        ▼
┌─────────────────────────────────┐
│ OCI_USERNAME / OCI_PASSWORD     │──── set? ──────▶ use them
│ environment variables           │
└─────────────────────────────────┘
        │ not set
        ▼
  No credentials (public image)
```

Validation rules:

- Both `OCI_USERNAME` and `OCI_PASSWORD` must be set, or neither. Setting only
  one raises an error.
- If credentials are provided for a non-`oci://` path, they are ignored with a
  warning.

---

## 4. CLI Usage Examples

### Flashing from a public registry (no auth)

```bash
# Flashers driver (U-Boot boards)
j storage flash oci://quay.io/myorg/rhel-image:9.4

# RideSX driver (Qualcomm boards)
j storage flash oci://quay.io/myorg/qcm-image:latest

# QEMU driver
j storage flash oci://quay.io/myorg/fedora-qcow2:latest
```

### Flashing from a private registry

```bash
# Set credentials in the environment
export OCI_USERNAME=myrobot
export OCI_PASSWORD=secret-token

# Then flash as normal
j storage flash oci://registry.example.com/private-image:v1.0
```

### Flashing with partition mappings (RideSX)

```bash
export OCI_USERNAME=myuser
export OCI_PASSWORD=mypass

# Auto-detect partitions from OCI manifest
j storage flash oci://registry.example.com/image:tag

# Explicit partition-to-filename mapping
j storage flash oci://registry.example.com/image:tag \
    -t boot_a:boot.img \
    -t system_a:system.img
```

### Flashing with custom TLS settings

```bash
# Skip TLS verification (e.g., self-signed registry)
j storage flash -k oci://registry.local/image:latest

# Use a custom CA certificate
j storage flash --cacert /path/to/ca.crt oci://registry.local/image:latest
```

### Flashing with HTTP bearer token (non-OCI HTTP URLs)

```bash
j storage flash --bearer eyJhbGci... https://artifacts.example.com/image.raw.xz
```

---

## 5. Non-OCI Image Sources

For completeness, the flashers driver also supports pulling OS images from
non-registry sources. These do **not** use OCI authentication:

| Source | Example | How it works |
|---|---|---|
| Local file | `/path/to/image.raw.xz` | Uploaded to the exporter's HTTP server, then downloaded by the target via `curl` or FLS |
| HTTP/HTTPS URL | `https://example.com/image.raw.xz` | Passed directly to the target (or routed through the exporter's HTTP server if `--force-exporter-http` is set) |
| OCI reference | `oci://registry.com/image:tag` | Pulled directly by FLS on the target using OCI credentials |

For HTTP(S) URLs, additional authentication options are available:

- `--bearer <token>` -- adds an `Authorization: Bearer <token>` header
- `--header 'Key: Value'` -- adds arbitrary HTTP headers
- `--cacert <file>` -- uses a custom CA certificate for TLS verification
- `-k` / `--insecure-tls` -- disables TLS certificate verification

---

## 6. Security Considerations

### Credential handling

- Passwords are **never** logged. The `_RedactingConsoleWriter` redacts any
  registered sensitive value from the debug console stream.
- When writing credentials through a serial console, values are base64-encoded
  and the console debug stream is temporarily disabled during the write.
- Credentials files on the target (`/tmp/fls_creds`) are created with mode
  `0600`.

### FLS binary trust

- By default, only pre-installed or GitHub-release FLS binaries are accepted.
- Custom FLS binary URLs require explicit opt-in via
  `fls_allow_custom_binaries: true` in the driver configuration.
- A security warning is logged when custom binary downloads are enabled.

### TLS on the target

- The target's system clock is set to match the exporter before any TLS
  connection to avoid certificate validation failures due to clock skew.
- Custom CA certificates can be transferred to the target for private registry
  access.

---

## 7. Architecture Diagram

```
                        ┌──────────────────────────────────────────────────┐
                        │                  EXPORTER HOST                   │
                        │                                                  │
  ┌──────────┐          │  ┌────────────┐     ┌─────────────────────────┐  │
  │ Registry │◀─ ORAS ──│──│ BaseFlasher│     │ TFTP + HTTP servers     │  │
  │ (bundle) │  pull    │  │  driver    │────▶│ serve kernel/initram/dtb│  │
  └──────────┘          │  └────────────┘     └────────────┬────────────┘  │
                        │                                  │               │
                        │                        boot via U-Boot           │
                        │                                  │               │
                        │                                  ▼               │
                        │                     ┌────────────────────────┐   │
                        │                     │   TARGET DEVICE        │   │
  ┌──────────┐          │                     │   (BusyBox shell)      │   │
  │ Registry │◀─ FLS ───│─────────────────────│                        │   │
  │ (image)  │  pull    │  FLS_REGISTRY_*     │   fls from-url         │   │
  └──────────┘          │  via serial creds   │     oci://... /dev/sdX │   │
                        │                     └────────────────────────┘   │
                        └──────────────────────────────────────────────────┘
```

For QEMU and RideSX drivers, FLS runs on the exporter host instead of the
target, so credentials are passed as subprocess environment variables rather
than through a serial console.
