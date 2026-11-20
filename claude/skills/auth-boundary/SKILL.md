---
name: auth-boundary
description: Checklist for building authentication into a new entry point from the first commit — auth-by-default wiring, refusing to start without a secret, named opt-outs, closed failure, and binding credentials to the host they were issued for. Use when adding or reviewing an HTTP route, IPC accept-loop, WebSocket upgrade, external-input queue consumer or mutating CLI subcommand, when code attaches a token to a URL or path read from a lockfile, manifest or other persisted config, or when the user asks "does this need auth" or "is this endpoint protected".
---

# Auth at the boundary

If a service could ever need auth, build it in from the first commit. Never
assume "auth will be added later" or "the layer above handles it." Across six
repos, every CWE-306 finding traced to the same *auth-by-config* pattern — a
route that authenticates only when an env var is set, trusting some upstream
layer to catch it.

## Checklist for every new entry point

An entry point is an HTTP route, IPC accept-loop, WebSocket upgrade,
external-input queue consumer, or mutating CLI subcommand.

1. Auth-by-default, not auth-by-config — the framework wiring forces it.
2. Refuse to start if the auth secret is unset or too short.
3. Opt-out is explicit, named, and greppable (e.g. `@PublicRoute(reason="…")`).
4. Never trust upstream layers — each layer rejects on its own.
5. Failure mode is closed — if the auth check throws, reject the request.
6. Local dev uses a real token through the same verifier — no skip-auth branch.
7. Credentials bind to the host they were issued for. Never attach an ambient
   token (env fallback, "current login") to a URL or path read from persisted
   or attacker-influenced state — a lockfile, install manifest, or any config
   committed to a repo and cloned onto another machine. Resolve the token by
   exact host/URL match only, require https (loopback aside), set
   `redirect: "error"` on any fetch carrying a bearer, and confine a stored
   path (backup/restore target) with a `..`-rejecting, realpath-contained
   check before reading it. Twice now the same shape — a manifest field fed to
   the network or filesystem with an ambient credential attached — was a
   supply-chain exfiltration primitive.

## Verify

- Start the service with the auth secret unset: it must refuse to start.
- Call the new entry point with no credential and with a wrong one: both are
  rejected by this layer, not by a proxy in front of it.
- `rg` for the opt-out marker and confirm every hit carries a reason.
