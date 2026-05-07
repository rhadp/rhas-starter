# Container Registry Authentication

This document explains how the automotive-dev-operator interacts with container registries and how authentication is handled across all build modes.

## Overview

The operator pushes and pulls container images and OCI artifacts during builds. There are two fundamentally different registry paths:

1. **OpenShift Internal Registry** -- the cluster's built-in `image-registry.openshift-image-registry.svc:5000`, authenticated via short-lived Kubernetes service account tokens.
2. **External Registries** -- any registry outside the cluster (Quay, Docker Hub, GHCR, self-hosted), authenticated via user-supplied credentials.

A single build can use both paths simultaneously ("hybrid mode"): for example, pushing a bootc container to an external registry while pushing a disk image to the internal registry.

## Authentication Types

The `RegistryCredentials` struct (`internal/buildapi/types.go`) supports three credential formats:

| `authType` | Required fields | Description |
|---|---|---|
| `username-password` | `registryUrl`, `username`, `password` | Basic auth. The operator base64-encodes `user:pass` into a `dockerconfigjson`. |
| `token` | `registryUrl`, `token` | Bearer token auth. Encoded as `:token` in the `dockerconfigjson` `auth` field. |
| `docker-config` | `dockerConfig` | Pre-built `dockerconfigjson` content, passed through as-is. |

## Credential Resolution on the CLI (`caib`)

The `caib` CLI resolves credentials in this priority order (`cmd/caib/registryauth/`):

1. **Explicit auth file** -- `--registry-auth-file <path>` flag or `REGISTRY_AUTH_FILE` env var. Must exist and contain valid credentials for the target registry.
2. **Environment variables** -- `REGISTRY_USERNAME` and `REGISTRY_PASSWORD`. Extracted by `ExtractRegistryCredentials()` and sent as `username-password` type.
3. **Local auth files** (auto-discovery) -- searched in order:
   - `$REGISTRY_AUTH_FILE`
   - `$XDG_RUNTIME_DIR/containers/auth.json`
   - `/run/containers/<uid>/auth.json`
   - `~/.config/containers/auth.json`

   The first file containing matching credentials for the target registry is used. Sent as `docker-config` type.

If no credentials are found and the build requires registry push, the CLI warns but proceeds -- the build will fail at push time if auth is truly needed.

## Secret Creation (Build API Server)

When a build request arrives at the Build API (`internal/buildapi/server.go`), the `resolveRegistryForBuild()` function orchestrates secret creation. Two distinct Kubernetes Secrets are created:

### Registry Auth Secret (for build-time pulls)

Created by `createRegistrySecret()` (`internal/buildapi/secrets.go`).

- **Name**: `{build-name}-external-registry-auth`
- **Type**: `Opaque`
- **Data keys**:
  - `REGISTRY_URL`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` (for `username-password`)
  - `REGISTRY_TOKEN` (for `token`)
  - `REGISTRY_AUTH_FILE_CONTENT` (for `docker-config`)
  - `.dockerconfigjson` -- always generated for tools that need Docker config format
- **Usage**: Mounted into the build task's `registry-auth` workspace at `/workspace/registry-auth`. The build script reads these files via `read_registry_creds()` and creates a local auth file.

### Push Secret (for artifact push)

Created by `createPushSecret()` (`internal/buildapi/secrets.go`).

- **Name**: `{build-name}-push-auth`
- **Type**: `kubernetes.io/dockerconfigjson`
- **Data key**: `.dockerconfigjson`
- **Label**: `transient=true` (cleaned up after build completion)
- **Usage**: Referenced by name in the `push-artifact-registry` Tekton Task via the `secret-ref` parameter. Mounted as a volume at `/docker-config/config.json`, and the `DOCKER_CONFIG` environment variable points to `/docker-config` so that `oras` automatically picks it up.

Both secrets are created only when `RegistryCredentials.Enabled` is true. The push secret is additionally required when `PushRepository` or `ExportOCI` is set -- the API returns HTTP 400 if push is requested without credentials.

## Internal Registry Authentication

When `UseInternalRegistry` is true, the Build API uses a completely different path (`setupInternalRegistryBuild()` in `internal/buildapi/server.go`):

### Token Minting

```
ServiceAccount("ado-build") → TokenRequest API → short-lived JWT
```

1. The API calls the Kubernetes `TokenRequest` API against the `ado-build` service account.
2. The token lifetime is configurable via `OperatorConfig.spec.osBuilds.registryTokenLifetimeSeconds` (default: 4 hours / 14400s).
3. The token is formatted into a `dockerconfigjson`:
   ```json
   {
     "auths": {
       "image-registry.openshift-image-registry.svc:5000": {
         "auth": "<base64(serviceaccount:<token>)>"
       }
     }
   }
   ```
4. This is stored as a `kubernetes.io/dockerconfigjson` Secret named `{build-name}-registry-auth`, labeled `transient=true`.

### ImageStream Pre-Creation

The OpenShift internal registry requires an `ImageStream` object to exist before images can be pushed. The API calls `ensureImageStream()` to create one if it doesn't exist. All images for a build (bootc container and disk artifact) share the same ImageStream, distinguished by tag (`:bootc`, `:disk`).

### External Route Resolution

For bootc builds, nested containers inside the build pod need to pull builder images from the internal registry. They can't use the internal service URL, so the operator resolves an external route:

1. Check `OperatorConfig.spec.osBuilds.clusterRegistryRoute` for a manually configured route.
2. Fall back to auto-detecting the `default-route` Route in the `openshift-image-registry` namespace.

If neither is available and the build requires it, the API returns an error.

### On-Demand Token Minting for Pulls

After a build completes, users can request a fresh token to pull the built image. The `mintRegistryToken()` method (`internal/buildapi/registry.go`) creates a new short-lived token via the same `TokenRequest` API mechanism and returns it in the `BuildResponse.RegistryToken` field along with the registry URL.

## How Secrets Flow into Tekton

### Build Pipeline

The ImageBuild controller (`internal/controller/imagebuild/controller.go`) creates a `PipelineRun` with these workspace bindings:

```
ImageBuild.Spec.SecretRef  →  workspace "registry-auth"  →  mounted at /workspace/registry-auth
```

This workspace is **optional**. If `SecretRef` is empty, the workspace is omitted and the build runs without custom registry auth (relying on cluster auth only).

### Build Task (build-image)

The `build-image` task (`internal/common/tasks/tasks.go`) receives the registry auth workspace and an optional `envFrom` referencing the external registry secret. The build script (`scripts/build_image.sh`) processes credentials at runtime:

1. `read_registry_creds("/workspace/registry-auth")` reads individual credential files from the mounted secret.
2. `setup_registry_auth()` creates a unified auth JSON file from whichever credential type is present.
3. `REGISTRY_AUTH_FILE` is exported and used by `buildah`, `skopeo`, and `podman` for all image operations.
4. For builds using the cluster's internal registry, `setup_cluster_auth()` creates auth using the pod's service account token.

### Push Task (push-artifact-registry)

The `push-artifact-registry` task mounts the push secret differently:

```
Volume "docker-config":
  secret: {push-secret-name}  (from "secret-ref" param)
  mounted at: /docker-config/config.json  (subPath: .dockerconfigjson)

Env: DOCKER_CONFIG=/docker-config
```

This makes the credentials available to `oras push` without any script-level credential handling. ORAS reads `$DOCKER_CONFIG/config.json` automatically.

### Standalone Push TaskRun

When the build pipeline completes and a disk artifact needs to be pushed to a registry, the controller creates a separate `TaskRun` for the push task. The `PushSecretRef` from the `ImageBuild` spec is passed as the `secret-ref` parameter.

## Hybrid Builds

A build can push to both internal and external registries simultaneously:

- **Bootc container** → pushed to an external registry (e.g., `quay.io/org/image:bootc`) using user-supplied `RegistryCredentials`
- **Disk image** → pushed to the internal registry (e.g., `image-registry.../ns/image:disk`) using the SA token secret

In this case, `resolveRegistryForBuild()` creates both an external registry secret (for the build's `registry-auth` workspace) and an internal registry secret (for the push `secret-ref`).

## Sealed Operations

Sealed image operations (prepare-reseal, reseal, extract-for-signing, inject-signed) use the same `RegistryCredentials` mechanism. The sealed task (`internal/common/tasks/tasks.go`) mounts the `registry-auth` workspace at `/workspace/registry-auth`, and the sealed operation script reads credentials via the `REGISTRY_AUTH_PATH` environment variable.

## Build-Time Container Authentication

During bootc builds, the build task runs nested container operations (building builder images, pulling base images). The build script handles authentication for these operations:

1. **SA-based auth**: `setup_cluster_auth()` creates auth JSON using the pod's service account token for the internal registry.
2. **Custom auth**: `setup_registry_auth()` merges user-supplied credentials with cluster credentials, creating a unified auth file.
3. **Builder image pull**: When pulling or pushing builder images via `skopeo`, the script uses the `REGISTRY_AUTH_FILE` that contains both internal and external registry credentials. For the external registry route hostname, it adds a separate auth entry using `create_service_account_auth()`.
4. **Container push**: `skopeo copy` with `--authfile=$REGISTRY_AUTH_FILE` pushes the built container to the target registry.
5. **Buildah**: `BUILDAH_REGISTRY_AUTH_FILE` is set to `$REGISTRY_AUTH_FILE` so buildah uses the same credentials.

## Secret Lifecycle and Cleanup

| Secret | Lifecycle |
|---|---|
| `{build}-external-registry-auth` | OwnerRef set to ImageBuild; garbage collected on CR deletion. Also explicitly deleted by `cleanupBuildResources()`. |
| `{build}-push-auth` | Labeled `transient=true`. Deleted by `cleanupBuildResources()` on build completion/expiry. |
| `{build}-registry-auth` (internal) | Labeled `transient=true`. Same cleanup as push-auth. Token expires naturally after the configured lifetime. |

When a build expires (TTL-based), transitions to `Failed`, or is deleted, the controller calls `cleanupBuildResources()` which deletes all associated secrets by name from the ImageBuild spec.

## Configuration Reference

### OperatorConfig Fields

| Field | Default | Description |
|---|---|---|
| `spec.osBuilds.registryTokenLifetimeSeconds` | `14400` (4h) | SA token lifetime for internal registry auth |
| `spec.osBuilds.clusterRegistryRoute` | auto-detected | External hostname for the internal registry |
| `spec.buildAPI.clientTokenExpiryDays` | `30` | Expiry for client-issued API tokens |

### ImageBuild Spec Fields

| Field | Description |
|---|---|
| `spec.secretRef` | Name of Secret for build-time registry auth (pull operations) |
| `spec.pushSecretRef` | Name of `dockerconfigjson` Secret for push operations |
| `spec.export.useServiceAccountAuth` | Use SA token instead of explicit credentials (internal registry) |
| `spec.export.container` | OCI URL for pushing the bootc container image |
| `spec.export.disk.oci` | OCI URL for pushing the disk image as an OCI artifact |

## Architecture Diagram

```
                                  ┌──────────────────────────────────┐
                                  │         caib CLI                 │
                                  │                                  │
                                  │  1. Resolve credentials:         │
                                  │     --registry-auth-file         │
                                  │     REGISTRY_USERNAME/PASSWORD   │
                                  │     ~/.config/containers/auth    │
                                  └──────────────┬───────────────────┘
                                                 │
                                    BuildRequest (RegistryCredentials)
                                                 │
                                                 ▼
                                  ┌──────────────────────────────────┐
                                  │        Build API Server          │
                                  │                                  │
                                  │  2. resolveRegistryForBuild()    │
                                  │     ├─ External? createRegistry  │
                                  │     │  Secret + createPushSecret │
                                  │     └─ Internal? TokenRequest    │
                                  │        API → dockerconfigjson    │
                                  │        Secret + ImageStream      │
                                  └──────────────┬───────────────────┘
                                                 │
                                    ImageBuild CR (secretRef,
                                    pushSecretRef, exportSpec)
                                                 │
                                                 ▼
                                  ┌──────────────────────────────────┐
                                  │     ImageBuild Controller        │
                                  │                                  │
                                  │  3. Create PipelineRun:          │
                                  │     workspace "registry-auth"    │
                                  │       ← secretRef                │
                                  └──────────────┬───────────────────┘
                                                 │
                          ┌──────────────────────┼──────────────────────┐
                          │                      │                      │
                          ▼                      ▼                      ▼
               ┌─────────────────┐  ┌──────────────────┐  ┌──────────────────┐
               │  build-image    │  │ push-artifact-    │  │  flash-image     │
               │  Tekton Task    │  │ registry Task     │  │  Tekton Task     │
               │                 │  │                   │  │                  │
               │ /workspace/     │  │ /docker-config/   │  │                  │
               │ registry-auth/  │  │ config.json       │  │                  │
               │ → REGISTRY_     │  │ ← push secret     │  │                  │
               │   AUTH_FILE     │  │ → oras push       │  │                  │
               │                 │  │                   │  │                  │
               │ skopeo, buildah │  │                   │  │                  │
               │ podman          │  │                   │  │                  │
               └─────────────────┘  └──────────────────┘  └──────────────────┘
```
