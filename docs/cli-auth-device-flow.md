# CLI Authentication in Dev Spaces (Device Flow)

## Problem

The `jumpstarter-cli` and `caib-cli` use the OIDC **Authorization Code flow with a local
callback server**. When the user runs the CLI from a local machine this works fine: Keycloak
redirects the browser to `http://localhost:PORT/callback`, and the CLI's local HTTP server
picks up the authorization code.

When the CLI runs inside **OpenShift Dev Spaces** (or any cloud/container-based IDE), the
flow breaks:

1. The browser is redirected to `http://localhost:PORT/callback`.
2. `localhost` in the browser refers to the **user's laptop**, not the Dev Spaces pod.
3. Nothing is listening on that port on the laptop → browser shows a connection error.

## Fix already applied (Keycloak side)

`ansible/roles/setup-auth/templates/openshift-realm.yml.j2` has been updated:

- Redirect URI wildcards fixed: `http://localhost:*` and `http://127.0.0.1:*`
  (wildcard must be at the end for Keycloak prefix-matching to work).
- `oauth2DeviceAuthorizationGrantEnabled: true` added to both `jumpstarter-cli` and
  `caib-cli` clients so Keycloak can serve device-flow requests.

## Remaining work (CLI side)

Both CLIs need a **Device Authorization Grant** (RFC 8628) code path. This flow does not
require a local callback server:

1. CLI calls the Keycloak device authorization endpoint and gets a `device_code` +
   `user_code` + `verification_uri`.
2. CLI prints the URL and code to the terminal, e.g.:
   ```
   Open the following URL in your browser and enter the code:
     https://keycloak.example.com/realms/openshift/device
     Code: ABCD-1234
   ```
3. CLI polls the token endpoint until the user completes authentication in the browser.
4. CLI stores the received tokens (same as today).

### `jumpstarter-cli` (Python)

File: `python/packages/jumpstarter-cli-common/jumpstarter_cli_common/oidc.py`

- The existing `authlib` (or equivalent) library likely already supports device flow.
- Add a `--device-flow` flag (or auto-detect, see below) to the login command.
- When device flow is active, skip the local HTTP server and use the polling loop instead.

### `caib-cli` (Go)

File: `cmd/caib/auth/oidc.go`

- Read the device authorization endpoint from the OIDC discovery document
  (`device_authorization_endpoint`).
- Add a `--device-flow` flag (or auto-detect).
- Implement the polling loop against the token endpoint with `grant_type=urn:ietf:params:oauth:grant-type:device_code`.

### Auto-detection (recommended)

Instead of requiring users to pass a flag, the CLI can detect the environment and choose
the flow automatically:

| Signal | Action |
|---|---|
| `TERM_PROGRAM=vscode` and no local listener succeeds | Use device flow |
| `VSCODE_INJECTION=1` (Dev Spaces sets this) | Use device flow |
| Env var `JMP_OIDC_DEVICE_FLOW=1` / `CAIB_OIDC_DEVICE_FLOW=1` | Force device flow |
| None of the above | Use existing local callback flow |

## References

- [RFC 8628 — OAuth 2.0 Device Authorization Grant](https://datatracker.ietf.org/doc/html/rfc8628)
- [RFC 8252 — OAuth 2.0 for Native Apps (loopback redirect)](https://datatracker.ietf.org/doc/html/rfc8252)
- Keycloak device flow config: `oauth2DeviceAuthorizationGrantEnabled`
