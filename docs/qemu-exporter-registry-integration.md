# Seamless Build-and-Flash with QEMU Exporters and the Internal OpenShift Registry

This document describes how to make the end-to-end flow of **building an OS
image** (via the automotive-dev-operator) and **flashing it to a QEMU exporter**
(via Jumpstarter) work seamlessly against the OpenShift internal registry.

It identifies the current issues, proposes concrete fixes, and describes the
target architecture.

---

## 1. The End-to-End Flow

```
  ┌─────────┐       ┌──────────────┐       ┌───────────────────┐       ┌──────────────────┐
  │  caib    │──────▶│  Build API   │──────▶│  Tekton Pipeline  │──────▶│ Internal Registry│
  │  CLI     │  HTTP │  Server      │  k8s  │  (build + push)   │  push │  (OCI artifact)  │
  └─────────┘       └──────────────┘       └───────────────────┘       └────────┬─────────┘
                            │                                                    │
                            │ FlashEnabled=true                                  │
                            ▼                                                    │
                    ┌───────────────┐       ┌───────────────┐                    │
                    │ Flash TaskRun │──────▶│  jmp shell    │       OCI pull     │
                    │ (Tekton)      │ lease │  on exporter  │◀───────────────────┘
                    └───────────────┘       └───────┬───────┘
                                                    │
                                             ┌──────▼──────┐
                                             │ QEMU        │
                                             │ Exporter Pod│
                                             │             │
                                             │ FLS binary  │
                                             │  from-url   │
                                             └─────────────┘
```

### Step by step

1. **Build**: `caib build --internal-registry ...` triggers a Tekton pipeline
   that builds a disk image.
2. **Push**: The pipeline pushes the OCI artifact to the internal registry at
   `image-registry.openshift-image-registry.svc:5000/<namespace>/<name>:<tag>`.
   Authentication uses a short-lived SA token minted from the `ado-build`
   service account via the TokenRequest API.
3. **Flash trigger**: If `FlashEnabled` is set, the Build API creates a flash
   `TaskRun`. It stores:
   - A Jumpstarter client config secret (for `jmp shell`)
   - An OCI auth secret with username/password for the image pull
4. **Flash execution**: The flash Tekton task runs
   `jmp shell --lease <lease> -- env OCI_USERNAME=... OCI_PASSWORD=... sh -c "j storage flash oci://<image-ref>"`.
5. **Image pull on exporter**: The `j storage flash` command runs inside the
   exporter pod. The QEMU driver invokes FLS as a subprocess, which pulls the
   OCI image from the registry and writes it to the virtual disk.

---

## 2. Current Issues

### Issue 1: QEMU client does not forward OCI credentials to the driver

This is the **root cause** of the broken flow.

When the flash Tekton task runs:

```bash
jmp shell --lease $LEASE -- env \
    OCI_USERNAME="serviceaccount" \
    OCI_PASSWORD="<token>" \
    sh -c "j storage flash oci://image-registry.../ns/image:disk"
```

The credential flow breaks at the client-driver boundary:

```
Flash Tekton task (pod A)
  └─ jmp shell -- env OCI_USERNAME=... OCI_PASSWORD=...
       └─ j storage flash oci://...       ← CLIENT process, has OCI_* in env
            └─ QemuFlasherClient.flash()
                 └─ self.streamingcall("flash_oci", path, target)
                      │
                      │  gRPC call — credentials NOT passed as arguments
                      │
                      ▼
              QemuFlasher.flash_oci()      ← DRIVER process (exporter), different env
                   └─ os.environ.get("OCI_USERNAME")  ← reads exporter's own env, NOT the client's
```

`QemuFlasherClient.flash()` calls `self.streamingcall("flash_oci", path, target)`
with only `path` and `target`. The `flash_oci()` driver method accepts
`oci_username` and `oci_password` parameters, but the client never passes them.
The driver falls back to `os.environ` — which is the **exporter's** process
environment, not the client's.

**Contrast with the flashers driver**: `BaseFlasherClient.flash()` calls
`_resolve_oci_credentials()` on the **client side**, reads from the client's
`os.environ`, and then transfers the credentials to the target device via serial
console. The credentials from `jmp shell -- env` reach the target correctly.

**Impact**: Tekton-provided credentials (fresh, from the build API) are silently
ignored. The QEMU driver uses whatever was in the exporter's own environment at
boot time.

### Issue 2: Exporter SA token goes stale

The StatefulSet exports `OCI_PASSWORD` once at container startup:

```bash
export OCI_PASSWORD="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
```

Projected SA tokens have a ~1 hour lifetime. The kubelet rotates the token file
on disk, but the environment variable retains the old value. If a flash
operation runs hours after pod start, the token is expired.

Even if Issue 1 is fixed (so Tekton-provided credentials reach the driver), this
still affects **manual** flash operations where the user relies on the
exporter's own SA token.

### Issue 3: Missing TLS CA for the internal registry

The internal registry at `image-registry.openshift-image-registry.svc:5000` uses
a TLS certificate signed by OpenShift's **service-serving CA**. This is NOT the
same CA as the API server CA at
`/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`.

FLS will fail TLS verification when connecting to the internal registry because
the service-serving CA is not in the pod's trust store.

### Issue 4: Image-puller RBAC scope

The existing `system:image-puller` RoleBinding only grants pull access in the
`automotive-dev-operator-system` namespace. If images are pushed to a different
namespace (e.g., by a different team or build configuration), pulls will fail
with a 403.

---

## 3. Proposed Fixes

### Fix 1: Forward OCI credentials in `QemuFlasherClient` (code change)

**File**: `python/packages/jumpstarter-driver-qemu/jumpstarter_driver_qemu/client.py`

The `QemuFlasherClient.flash()` method must read `OCI_USERNAME`/`OCI_PASSWORD`
from its own process environment and pass them through the RPC:

```python
import os

class QemuFlasherClient(FlasherClient):
    def flash(self, path, *, target=None, operator=None, compression=None):
        if isinstance(path, str) and path.startswith("oci://"):
            # Read OCI credentials from the CLIENT's environment
            # (set by jmp shell -- env OCI_USERNAME=... or by the user)
            oci_username = os.environ.get("OCI_USERNAME")
            oci_password = os.environ.get("OCI_PASSWORD")

            returncode = 0
            for stdout, stderr, code in self.streamingcall(
                "flash_oci", path, target, oci_username, oci_password
            ):
                if stdout:
                    print(stdout, end="", flush=True)
                if stderr:
                    print(stderr, end="", file=sys.stderr, flush=True)
                if code is not None:
                    returncode = code
            return returncode

        return super().flash(path, target=target, operator=operator, compression=compression)
```

This makes the QEMU driver credential flow match the flashers driver: the
**client** resolves credentials and forwards them over the RPC. The driver-side
`flash_oci()` receives them as parameters and only falls back to `os.environ` if
the client didn't provide any.

With this fix, credentials from `jmp shell -- env OCI_USERNAME=... OCI_PASSWORD=...`
flow through correctly.

### Fix 2: Read the SA token from file at flash-time (code change)

Add support for `OCI_PASSWORD_FILE` so that the token is read fresh on every
flash operation instead of being captured once at boot.

**File**: `python/packages/jumpstarter-driver-qemu/jumpstarter_driver_qemu/driver.py`

In `flash_oci()`, after the existing env var fallback:

```python
if not oci_username:
    oci_username = os.environ.get("OCI_USERNAME")
if not oci_password:
    oci_password = os.environ.get("OCI_PASSWORD")

# Read password from file if OCI_PASSWORD_FILE is set (supports token rotation)
if not oci_password:
    password_file = os.environ.get("OCI_PASSWORD_FILE")
    if password_file:
        with open(password_file) as f:
            oci_password = f.read().strip()
```

The same pattern should be added to `BaseFlasherClient._resolve_oci_credentials()`
for consistency.

**StatefulSet change**: Replace the static env var with the file-based approach:

```yaml
env:
  - name: OCI_USERNAME
    value: "serviceaccount"
  - name: OCI_PASSWORD_FILE
    value: "/var/run/secrets/kubernetes.io/serviceaccount/token"
```

Remove the `export OCI_PASSWORD="$(cat ...)"` line from the startup script.

This way:
- Manual flashes always use a fresh token (read from disk at flash-time)
- Tekton-triggered flashes use the token provided by the flash task (via Fix 1)
- The exporter's own env never holds a stale password

### Fix 3: Inject the service-serving CA (StatefulSet + ConfigMap)

Create a ConfigMap that OpenShift auto-populates with the service-serving CA
bundle:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: registry-service-ca
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
data: {}
```

Mount it into the exporter pod and update the system trust store:

```yaml
# In the StatefulSet spec
volumes:
  - name: registry-ca
    configMap:
      name: registry-service-ca

containers:
  - name: jumpstarter-exporter
    volumeMounts:
      - name: registry-ca
        mountPath: /etc/pki/ca-trust/source/anchors/service-ca-bundle.crt
        subPath: service-ca-bundle.crt
        readOnly: true
```

In the container startup script, before `jmp run`:

```bash
# Trust the internal registry's service-serving CA
if [ -f /etc/pki/ca-trust/source/anchors/service-ca-bundle.crt ]; then
    update-ca-trust
fi
```

This makes FLS (and any other TLS client in the pod) trust the internal
registry's certificate.

**Alternative (no CA injection)**: Use the external registry route instead of
the internal service URL. The route uses the cluster's ingress certificate,
which is typically already trusted. The OCI URL would be:

```
oci://default-route-openshift-image-registry.apps.<cluster-domain>/<namespace>/<image>:<tag>
```

But using the internal URL is preferred because:
- It avoids an extra network hop through the router
- It doesn't depend on the route being exposed
- It works in air-gapped clusters

### Fix 4: Broaden `system:image-puller` RBAC

Add a RoleBinding in every namespace where images may be pushed. If builds
target multiple namespaces, create a binding in each:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: qemu-exporter-image-puller
  namespace: <image-namespace>      # each namespace that hosts OCI artifacts
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:image-puller
subjects:
  - kind: ServiceAccount
    name: qemu-exporter
    namespace: auto-jumpstarter
```

Alternatively, if all builds push to the operator's own namespace, a single
binding in that namespace suffices.

Note: for Tekton-triggered flashes, the RBAC of the exporter SA is less critical
because the flash task provides its own token (from the `ado-build` SA, which
already has push/pull access). But for manual flashes, the exporter SA must have
pull access.

---

## 4. The Fixed StatefulSet

Here is how the relevant sections of `stateful-set.yaml` should look after all
fixes:

```yaml
volumes:
  - name: shared
    emptyDir: {}
  - name: dev-kvm
    hostPath:
      path: /dev/kvm
      type: CharDevice
  - name: dev-vhost-vsock
    hostPath:
      path: /dev/vhost-vsock
      type: CharDevice
  - name: registry-ca                         # NEW
    configMap:
      name: registry-service-ca

containers:
  - name: jumpstarter-exporter
    # ...
    volumeMounts:
      - mountPath: /shared
        name: shared
      - mountPath: /dev/kvm
        name: dev-kvm
      - mountPath: /dev/vhost-vsock
        name: dev-vhost-vsock
      - mountPath: /etc/pki/ca-trust/source/anchors/service-ca-bundle.crt   # NEW
        name: registry-ca
        subPath: service-ca-bundle.crt
        readOnly: true
    env:
      - name: JUMPSTARTER_GRPC_INSECURE
        value: "1"
      - name: OCI_USERNAME                    # NEW (static, never expires)
        value: "serviceaccount"
      - name: OCI_PASSWORD_FILE               # NEW (read fresh on each flash)
        value: "/var/run/secrets/kubernetes.io/serviceaccount/token"
    command:
      - /bin/bash
      - -c
      - |
        set -eo pipefail
        source /venv/bin/activate

        # ... (existing setup: uv pip install, oc config, jmp admin, etc.) ...

        # Trust the internal registry CA
        if [ -f /etc/pki/ca-trust/source/anchors/service-ca-bundle.crt ]; then
            update-ca-trust
        fi

        # NOTE: Do NOT export OCI_PASSWORD here. The OCI_PASSWORD_FILE env var
        # tells jumpstarter to read the SA token fresh from disk on every flash,
        # so credentials survive kubelet token rotation.

        cat <<EOF > qemu.yaml
        # ... (existing exporter config) ...
        EOF

        jmp run --exporter-config qemu.yaml
```

---

## 5. Credential Flow After Fixes

### Tekton-triggered flash (build → flash pipeline)

```
Build API                    Flash TaskRun           QEMU Exporter Pod
───────                      ──────────────          ──────────────────
mintRegistryToken()
 → ado-build SA token
 → flash-oci-auth Secret
   (username + password)
                              ┌──────────────┐
                              │ flash_image.sh│
                              │              │
                              │ reads        │
                              │ /workspace/  │
                              │ flash-oci-   │
                              │ auth/        │
                              │ {username,   │
                              │  password}   │
                              │              │
                              │ jmp shell    │
                              │  --lease ... │
                              │  -- env      │
                              │  OCI_USER..  │─── gRPC ──▶ QemuFlasherClient.flash()
                              │  OCI_PASS..  │                │
                              └──────────────┘           reads OCI_USERNAME/PASSWORD
                                                         from CLIENT env (Fix 1)
                                                              │
                                                         streamingcall("flash_oci",
                                                           path, target,
                                                           oci_username, oci_password)
                                                              │
                                                              ▼
                                                         QemuFlasher.flash_oci()
                                                           receives credentials
                                                           as parameters
                                                              │
                                                              ▼
                                                         FLS subprocess
                                                           FLS_REGISTRY_USERNAME=...
                                                           FLS_REGISTRY_PASSWORD=...
                                                           fls from-url oci://... /dev/...
                                                              │
                                                              ▼
                                                         image-registry.openshift-
                                                         image-registry.svc:5000
                                                         (TLS trusted via Fix 3)
```

### Manual flash (user runs `j storage flash` directly)

```
User                         QEMU Exporter Pod
────                         ──────────────────
j storage flash
  oci://image-registry.../
  ns/image:disk
        │
        │  (no OCI_USERNAME/PASSWORD in user's env)
        │
        └──── gRPC ──▶ QemuFlasherClient.flash()
                            │
                       reads OCI_USERNAME from env → "serviceaccount"
                       reads OCI_PASSWORD from env → (not set)
                            │
                       streamingcall("flash_oci", path, target,
                         "serviceaccount", None)
                            │
                            ▼
                       QemuFlasher.flash_oci()
                         oci_password is None
                         falls back to OCI_PASSWORD_FILE (Fix 2)
                         reads /var/run/secrets/.../token (fresh!)
                            │
                            ▼
                       FLS subprocess (same as above)
```

---

## 6. What Needs to Change Where

### Jumpstarter code changes

| File | Change | Purpose |
|---|---|---|
| `jumpstarter-driver-qemu/.../client.py` | Forward `OCI_USERNAME`/`OCI_PASSWORD` from client env to `flash_oci()` RPC call | Fix 1: credentials from Tekton flash reach the driver |
| `jumpstarter-driver-qemu/.../driver.py` | Add `OCI_PASSWORD_FILE` fallback in `flash_oci()` | Fix 2: fresh token for manual flashes |
| `jumpstarter-driver-flashers/.../client.py` | Add `OCI_PASSWORD_FILE` fallback in `_resolve_oci_credentials()` | Fix 2: consistency across all drivers |

### Deployment changes (rhas-deploy)

| File | Change | Purpose |
|---|---|---|
| `manifests/jumpstarter-qemu/stateful-set.yaml` | Add `registry-ca` volume + mount; add `OCI_USERNAME` and `OCI_PASSWORD_FILE` env vars; remove `export OCI_PASSWORD=...` from script; add `update-ca-trust` | Fixes 2 + 3 |
| `manifests/jumpstarter-qemu/registry-service-ca.yaml` (new) | ConfigMap with `service.beta.openshift.io/inject-cabundle: "true"` | Fix 3: TLS trust |
| `manifests/jumpstarter-qemu/role-binding-platform.yaml` | Add RoleBindings for `system:image-puller` in additional namespaces as needed | Fix 4: RBAC |

### No changes needed in the automotive-dev-operator

The builder side already works correctly:
- `mintRegistryToken()` creates valid pull tokens
- `createFlashOCIAuthSecret()` stores them as a Kubernetes secret
- `flash_image.sh` reads the secret and passes credentials via
  `jmp shell -- env OCI_USERNAME=... OCI_PASSWORD=...`
- The `{image_uri}` placeholder is replaced with the actual OCI URL

The gap is entirely on the Jumpstarter side (credential forwarding) and the
exporter deployment side (TLS + token freshness).

---

## 7. OCI URL Format

### Internal URL (preferred, in-cluster)

```
oci://image-registry.openshift-image-registry.svc:5000/<namespace>/<image-name>:<tag>
```

Example:
```
oci://image-registry.openshift-image-registry.svc:5000/ado-system/rhel-edge:disk
```

This is what the builder stores in `ImageBuild.Spec.Export.Disk.OCI` and what
the flash task receives as `IMAGE_REF`.

### External route URL (fallback)

```
oci://default-route-openshift-image-registry.apps.<cluster-domain>/<namespace>/<image-name>:<tag>
```

The Build API's `translateToExternalURL()` converts internal URLs to this format
when returning results to the CLI. Use the external URL when:
- The TLS CA injection (Fix 3) is not in place
- The exporter is outside the cluster
- Debugging connectivity issues

---

## 8. Testing the Integration

### Verify TLS trust

```bash
# Inside the exporter pod
curl -s -o /dev/null -w "%{http_code}" \
    https://image-registry.openshift-image-registry.svc:5000/v2/
# Should return 401 (unauthorized but TLS works), not a TLS error
```

### Verify SA token pull access

```bash
# Inside the exporter pod
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -s -H "Authorization: Bearer $TOKEN" \
    https://image-registry.openshift-image-registry.svc:5000/v2/<namespace>/<image>/tags/list
# Should return a JSON tag list
```

### Verify end-to-end flash

```bash
# From a workstation with caib and jmp configured
caib build --internal-registry --flash --target qemu \
    --name test-flash \
    my-image-config.yaml
```

### Verify manual flash with exporter SA

```bash
# Acquire a lease
jmp create lease -l platform=qemu-arm --duration 01:00:00

# Flash using the exporter's own SA token (no explicit credentials)
jmp shell --lease <lease-name> -- \
    j storage flash oci://image-registry.openshift-image-registry.svc:5000/ado-system/my-image:disk
```

---

## 9. Summary

| Problem | Root cause | Fix | Scope |
|---|---|---|---|
| Tekton-provided credentials ignored | `QemuFlasherClient.flash()` doesn't forward `OCI_*` env vars | Forward credentials in `streamingcall()` | Jumpstarter code |
| Stale SA token on long-running pods | `OCI_PASSWORD` set once at boot | Add `OCI_PASSWORD_FILE` support, read at flash-time | Jumpstarter code + StatefulSet |
| TLS failure to internal registry | Service-serving CA not in trust store | Inject CA via annotated ConfigMap + `update-ca-trust` | StatefulSet + new ConfigMap |
| 403 on pull from other namespaces | Missing `system:image-puller` binding | Add RoleBinding per image namespace | RBAC manifests |
