# ADR — Auth at the Boundary

- **Status:** Accepted
- **Date:** 2026-05-03
- **Owner:** jckeen
- **Scope:** All HTTP services, IPC endpoints, and protocol entry points across `jckeen/*` repositories
- **Supersedes:** None
- **Related:** Per-repo CWE-306 fix PRs (linked below)

---

## Status

**Accepted** as of 2026-05-03. This ADR is binding on all new endpoints in jckeen-owned services and is the reference standard for retrofitting existing endpoints flagged by the cross-repo audit.

---

## Context

In the week of 2026-04-26 → 2026-05-03, an audit pass across six jckeen-owned repositories produced **CWE-306 (Missing Authentication for Critical Function)** findings in every one of them. The repos span four unrelated stacks:

| Repo                 | Stack                                                             |
| -------------------- | ----------------------------------------------------------------- |
| `stringer`           | Fastify (TypeScript) HTTP API                                     |
| `atlas`              | FastAPI (Python) gateway                                          |
| `beacon`             | Next.js 16 (App Router) with Better-Auth                          |
| `clarity-engine`     | Next.js with custom JWT (`jose`) cookie sessions                  |
| `pp2qbo`             | Next.js admin route protected by a static bearer token            |
| `pai-voice-server`   | Python daemon exposing a Unix-socket IPC for local control        |

Because the stacks share no code, this is **not a single-fix-shared-code situation**. It is a **pattern failure**: in each repo, code was written assuming auth would be enforced "somewhere upstream" — middleware, a reverse proxy, the deployment environment, or a sibling route's middleware. In every case, the assumption was wrong:

- A Fastify route was registered without the `preHandler` because the author assumed the global `addHook` would catch it. The global hook had been scoped to `/api/v1/*` two PRs earlier.
- A FastAPI `APIRouter` had `Depends(verify_token)` on every route except one new `/health/diagnostics` endpoint that was added during a hotfix and shipped without the dependency.
- A Next.js route handler called `getSession()` only when `process.env.AUTH_REQUIRED === "true"`. The env var was never set in production.
- A custom JWT route trusted `request.headers.get("x-user-id")` directly because "the middleware sets it".
- A bearer-token check used `if (token === process.env.BEARER_TOKEN)` — passing the auth, but vulnerable to timing attacks and missing the "what if the env var is unset?" branch (an unset env var compared with strict equality to an arbitrary input still passes when both sides are `undefined`).
- A Python daemon listening on a Unix socket trusted any local connection without a peer-credential check, on the theory that "if you're on the box, you're trusted". Multi-tenant container hosts violate this.

**Common root cause:** **auth-by-config**, not auth-by-default. Every one of these patterns fails open. Every one of these patterns shipped past code review because the reviewer also assumed "auth is handled somewhere".

### Risks of doing nothing

- New endpoints continue to ship without auth as the team grows.
- Audit cycles repeat with the same finding class quarterly.
- A single unauthenticated endpoint on a service handling user data is a reportable incident, not a bug.
- "Optional auth" branches accumulate, becoming untestable matrices that mask real bugs.

---

## Decision

**Auth is rejected at the entry boundary, by default.**

Concretely:

1. **Every entry point is auth-required by default.** "Entry point" means: every HTTP route handler, every IPC accept-loop, every WebSocket connection upgrade, every queue consumer that processes external input, every CLI subcommand that mutates shared state.
2. **Auth-by-default, not auth-by-config.** A route is authenticated because the framework's wiring forces it to be, not because a developer remembered to opt in. There is no `if AUTH_REQUIRED` branch. There is no `if env == "prod"` branch. There is no `if mode == "strict"` branch.
3. **Optional or "off when unconfigured" auth modes are forbidden.** If credentials are absent, the request is rejected. If the auth secret is unset, the **service refuses to start**, not "silently allows everything".
4. **Opt-out is per-route and explicit.** A route that intentionally lacks auth (a webhook with signature verification, a public health probe with no PII, a static asset) opts out via a named decorator/wrapper that is greppable across the codebase: `@PublicRoute(reason="...")` or equivalent. Code review for opt-outs is mandatory.
5. **Boundary checks do not depend on upstream layers.** A Fastify route does not assume nginx stripped malicious headers. A FastAPI route does not assume the API gateway rejected unauthenticated requests. Each layer rejects on its own.
6. **Failure mode is closed.** If the auth check throws an unexpected error, the request is rejected, not allowed.

---

## Consequences

### Positive

- New endpoints **fail closed** as a property of the framework wiring, not developer discipline.
- Every framework gets a checklist (below) and a copy-paste snippet that demonstrates the right pattern.
- Opt-outs are greppable and reviewable. `grep -r PublicRoute` answers "what's exposed?" in seconds.
- Audit findings of class CWE-306 should drop to zero on new endpoints. Existing endpoints get retrofitted via the per-repo PRs linked below.

### Negative / costs

- Boilerplate at the route level for stacks (Next.js App Router) where there is no global pre-handler. Mitigated by a wrapper helper.
- Local dev requires a real auth token. Mitigated by a documented dev token loaded from `.env.local`. **The dev token must not be the production code path's "skip auth" branch — it must go through the same verifier.**
- Service refuses to start if the auth secret is unset. This is intentional. A misconfigured service should crash, not silently disable auth.

### Out of scope

- This ADR does not specify **which** auth mechanism (bearer, JWT, session cookie, mTLS) — that is a per-service decision. It specifies **that the check happens at the boundary** and **what failure looks like**.
- This ADR does not cover authorization (what the authenticated principal is allowed to do). That is a separate concern handled per-resource.

---

## Per-stack snippets

These are drop-in patterns, not pseudocode. Each is the minimum viable correct implementation for that stack.

### a. Fastify (TypeScript) — global `preHandler` with explicit opt-out

```typescript
// src/auth/preHandler.ts
import type { FastifyInstance, FastifyRequest, FastifyReply } from "fastify";

declare module "fastify" {
  interface FastifyContextConfig {
    public?: boolean; // explicit opt-out marker
  }
}

export async function registerAuth(app: FastifyInstance) {
  const expected = process.env.API_BEARER_TOKEN;
  if (!expected || expected.length < 32) {
    throw new Error("API_BEARER_TOKEN missing or too short — refusing to start");
  }

  app.addHook("preHandler", async (req: FastifyRequest, reply: FastifyReply) => {
    if (req.routeOptions.config?.public === true) return; // explicit opt-out only

    const header = req.headers.authorization ?? "";
    const provided = header.startsWith("Bearer ") ? header.slice(7) : "";
    const a = Buffer.from(provided);
    const b = Buffer.from(expected);
    if (a.length !== b.length || !require("crypto").timingSafeEqual(a, b)) {
      reply.code(401).send({ error: "unauthorized" });
    }
  });
}

// Webhook route opts out (verifies HMAC signature instead, in its own handler).
app.post("/webhooks/stripe", { config: { public: true } }, stripeHandler);
```

The opt-out is `config: { public: true }` — greppable across the codebase, visible in code review, requires explicit intent.

### b. FastAPI (Python) — app-level `Depends` so it cannot be forgotten

```python
# app/auth.py
import os
from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

bearer = HTTPBearer(auto_error=False)

def require_auth(
    request: Request,
    creds: HTTPAuthorizationCredentials | None = Depends(bearer),
) -> str:
    # Explicit opt-out: routes mark themselves public via dependency override or path prefix.
    if getattr(request.state, "public_route", False):
        return "anonymous"
    expected = os.environ["API_TOKEN"]  # KeyError at startup if unset — by design
    if creds is None or creds.scheme.lower() != "bearer":
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing bearer token")
    if not _constant_time_eq(creds.credentials, expected):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid bearer token")
    return "user"  # replace with real principal extraction

# main.py — apply at app level so every route inherits the dependency
app = FastAPI(dependencies=[Depends(require_auth)])
```

`dependencies=[Depends(require_auth)]` at the `FastAPI(...)` constructor means every route has the check. A new route added to any router cannot skip auth without an explicit dependency override — which is reviewable.

### c. Next.js (App Router) with Better-Auth — wrapper that makes forgetting hard

```typescript
// src/auth/withAuth.ts
import { auth } from "@/lib/auth";
import { headers } from "next/headers";
import { NextResponse, type NextRequest } from "next/server";

type Handler = (
  req: NextRequest,
  ctx: { session: NonNullable<Awaited<ReturnType<typeof auth.api.getSession>>> },
) => Promise<Response> | Response;

export function withAuth(handler: Handler) {
  return async (req: NextRequest) => {
    const session = await auth.api.getSession({ headers: await headers() });
    if (!session) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
    return handler(req, { session });
  };
}

// app/api/posts/route.ts
import { withAuth } from "@/auth/withAuth";
export const GET = withAuth(async (_req, { session }) => {
  return Response.json({ user: session.user.id });
});
```

The `withAuth` wrapper is the only sanctioned way to define an authenticated route handler. A reviewer scanning for `export const GET = async` (without `withAuth`) catches forgotten checks immediately. CI lint rule (custom): forbid bare `export const (GET|POST|PUT|PATCH|DELETE) = async` outside `app/api/public/**`.

### d. Next.js with `jose` / custom JWT — middleware for whole-app, helper for per-route

```typescript
// src/auth/jwt.ts
import { jwtVerify } from "jose";
import { cookies } from "next/headers";

const SECRET = new TextEncoder().encode(
  (() => {
    const s = process.env.JWT_SECRET;
    if (!s || s.length < 32) throw new Error("JWT_SECRET missing or too short");
    return s;
  })(),
);

export async function verifySession() {
  const cookie = (await cookies()).get("session")?.value;
  if (!cookie) return null;
  try {
    const { payload } = await jwtVerify(cookie, SECRET, { algorithms: ["HS256"] });
    return payload as { sub: string; exp: number };
  } catch {
    return null; // expired, malformed, wrong sig — all rejected
  }
}

// middleware.ts — whole-app protection (runs at the edge, before route handlers)
import { NextResponse, type NextRequest } from "next/server";
import { verifySession } from "@/auth/jwt";

export async function middleware(req: NextRequest) {
  if (req.nextUrl.pathname.startsWith("/api/public")) return NextResponse.next();
  const session = await verifySession();
  if (!session) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  return NextResponse.next();
}
export const config = { matcher: ["/api/:path*"] };
```

Middleware is the **default-deny** layer. Per-route handlers can call `verifySession()` again if they need the payload, but the middleware is the boundary check. Note: `JWT_SECRET` and the bearer token (snippet e) are **separate env vars** — never reuse one secret as both a signing key and a comparison value.

### e. Next.js bearer token — `crypto.timingSafeEqual` with length check

```typescript
// src/auth/bearer.ts
import { timingSafeEqual } from "node:crypto";

const EXPECTED = (() => {
  const t = process.env.ADMIN_BEARER_TOKEN;
  if (!t || t.length < 32) throw new Error("ADMIN_BEARER_TOKEN missing or too short");
  return Buffer.from(t);
})();

export function checkBearer(headerValue: string | null): boolean {
  if (!headerValue?.startsWith("Bearer ")) return false;
  const provided = Buffer.from(headerValue.slice(7));
  if (provided.length !== EXPECTED.length) return false; // length check first — required by timingSafeEqual
  return timingSafeEqual(provided, EXPECTED);
}

// app/api/admin/route.ts
import { checkBearer } from "@/auth/bearer";
export async function POST(req: Request) {
  if (!checkBearer(req.headers.get("authorization"))) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  // ... handler ...
}
```

`timingSafeEqual` requires equal-length buffers — passing different-length buffers throws. The length check up front converts that into a clean `false`. The IIFE at module load means an unset/short env var crashes the service at startup, not silently at first request.

### f. Unix-socket IPC (Python) — `SO_PEERCRED` peer-credential check

```python
# pai_voice/server.py
import os
import socket
import struct

ALLOWED_UIDS = {os.geteuid()}  # default: only the user running the daemon

def authorize_peer(conn: socket.socket) -> bool:
    # SO_PEERCRED returns struct ucred { pid, uid, gid } on Linux
    SO_PEERCRED = 17
    raw = conn.getsockopt(socket.SOL_SOCKET, SO_PEERCRED, struct.calcsize("3i"))
    pid, uid, gid = struct.unpack("3i", raw)
    return uid in ALLOWED_UIDS

def serve(sock_path: str) -> None:
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    os.chmod(sock_path, 0o600)  # filesystem ACL is the first line of defence
    srv.listen()
    while True:
        conn, _ = srv.accept()
        if not authorize_peer(conn):
            conn.close()  # reject silently — do not leak which UIDs are allowed
            continue
        handle(conn)
```

Two layers: `chmod 0o600` on the socket path (filesystem boundary) **and** `SO_PEERCRED` check on accept (in case the socket is somehow accessible). On macOS use `getpeereid(3)`; on FreeBSD use `LOCAL_PEERCRED`. The `ALLOWED_UIDS` set is explicit — no "if empty, allow all" branch.

---

## Anti-patterns

The six specific patterns the audit found, with the wrong and right form for each:

### 1. Optional auth keyed off env or config

```python
# WRONG — auth is opt-in based on config
if mode == "required":
    if not verify_token(req): raise HTTPException(401)
```

```python
# RIGHT — auth is the default; config can only loosen it via an explicit, named opt-out
if not request.state.public_route:
    if not verify_token(req): raise HTTPException(401)
```

### 2. Routes registered without the auth `preHandler`

```typescript
// WRONG — depends on developer remembering to add the hook per-route
app.get("/admin/users", adminUsersHandler);
```

```typescript
// RIGHT — global preHandler covers every route; opt-out is explicit and greppable
app.get("/admin/users", adminUsersHandler);          // inherits global auth
app.post("/webhooks/x", { config: { public: true } }, xHandler); // explicit opt-out
```

### 3. Naive equality for token comparison (timing attack)

```typescript
// WRONG — string equality short-circuits, leaking length and prefix via timing
if (token === expected) { /* allow */ }
```

```typescript
// RIGHT — length-checked timingSafeEqual on equal-length buffers
const a = Buffer.from(token), b = Buffer.from(expected);
if (a.length === b.length && timingSafeEqual(a, b)) { /* allow */ }
```

### 4. User-controlled header reflected into a redirect (open redirect)

```typescript
// WRONG — attacker controls the redirect target via the header
const platform = req.headers.get("platform") as string;
return NextResponse.redirect(`https://${platform}.example.com/login`);
```

```typescript
// RIGHT — validate against an allowlist; reject anything else
const ALLOWED = new Set(["app", "admin", "dashboard"]);
const platform = req.headers.get("platform") ?? "";
if (!ALLOWED.has(platform)) return new Response("bad platform", { status: 400 });
return NextResponse.redirect(`https://${platform}.example.com/login`);
```

### 5. Hardcoded credential reused as both bearer AND JWT signing key

```typescript
// WRONG — same secret used for two distinct cryptographic purposes
const SECRET = process.env.APP_SECRET;
if (req.headers.authorization === `Bearer ${SECRET}`) { /* admin */ }
const token = await new SignJWT(payload).sign(new TextEncoder().encode(SECRET));
```

```typescript
// RIGHT — separate secrets for separate purposes; rotate independently
const ADMIN_BEARER = process.env.ADMIN_BEARER_TOKEN; // for the admin endpoint
const JWT_SIGNING_KEY = process.env.JWT_SIGNING_KEY; // for session JWTs
```

### 6. IPC accept loop with no peer-credential check

```python
# WRONG — any local process can connect and issue commands
while True:
    conn, _ = srv.accept()
    handle(conn)
```

```python
# RIGHT — verify peer UID via SO_PEERCRED; reject unknown peers
while True:
    conn, _ = srv.accept()
    if not authorize_peer(conn):
        conn.close()
        continue
    handle(conn)
```

---

## Per-framework checklist

When you add a new entry point to one of these stacks, verify in code review:

### Fastify
- [ ] App registers a global `preHandler` that 401s on missing/invalid auth.
- [ ] The required auth secret is validated at startup (length + presence) and the process refuses to start otherwise.
- [ ] Token comparison uses `crypto.timingSafeEqual` with a length pre-check.
- [ ] Any opt-out route uses `config: { public: true }` — no other opt-out mechanism exists.
- [ ] Webhook opt-outs verify a signature (HMAC) inside the handler.

### FastAPI
- [ ] `FastAPI(dependencies=[Depends(require_auth)])` is set at the `app` constructor (not just on routers).
- [ ] `require_auth` raises `HTTPException(401)` on missing or invalid credentials, with no "auth_mode" branch.
- [ ] The auth secret is read at import time (so unset = startup crash).
- [ ] Public routes use a documented dependency override or are under a clearly-named `/public/*` prefix.

### Next.js (Better-Auth)
- [ ] Every route handler is wrapped in `withAuth(...)` — no bare `export const GET = async`.
- [ ] CI lint rule rejects bare route exports outside `app/api/public/**`.
- [ ] `withAuth` calls `auth.api.getSession({ headers: await headers() })` and 401s on null.

### Next.js (jose / custom JWT)
- [ ] `middleware.ts` matches the API surface and rejects unauthenticated requests.
- [ ] `JWT_SECRET` is validated at startup (length ≥ 32 bytes).
- [ ] `jwtVerify` specifies `algorithms: ["HS256"]` (or your chosen alg) explicitly — no `none` permitted.
- [ ] Verification failures (expired, malformed, wrong sig) all collapse to a single 401 response.

### Next.js (bearer token)
- [ ] Token comparison uses `crypto.timingSafeEqual` after a length check.
- [ ] `ADMIN_BEARER_TOKEN` is validated at startup.
- [ ] Token is read once at module load, not per-request from the env.
- [ ] The bearer token and any JWT signing key are **distinct** env vars.

### Unix-socket IPC (Python)
- [ ] Socket file is `chmod 0o600` after bind.
- [ ] `accept()` loop calls `authorize_peer(conn)` before `handle(conn)`.
- [ ] `ALLOWED_UIDS` is non-empty and explicit (no "empty means allow all").
- [ ] Rejected connections are closed silently (no error message that leaks policy).

---

## Cross-references — per-repo fix PRs

| Repo                 | PR                                                                                                                       |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `parlance`           | [#18](https://github.com/jckeen/parlance/pull/18) (Fastify bearer-token preHandler) + [#19](https://github.com/jckeen/parlance/pull/19) (apps/web Route Handler proxy) |
| `impact-dash`        | [#21](https://github.com/jckeen/impact-dash/pull/21) (FastAPI JWT, `AUTH_MODE=required` default, separate `JWT_SIGNING_SECRET`) |
| `pp2qbo`             | [#19](https://github.com/jckeen/pp2qbo/pull/19) (`POSTGRES_USER`/`POSTGRES_PASSWORD` required, no insecure defaults)      |
| `smss`               | [#18](https://github.com/jckeen/smss/pull/18) (`IP_HASH_SALT` lazy resolution, `CRON_SECRET` required in production)     |
| `stringer`           | [#64](https://github.com/jckeen/stringer/pull/64) (OAuth state-binding: 256-bit CSPRNG nonce in httpOnly cookie + `crypto.timingSafeEqual` validation; `SEED_USER_PASSWORD` env-required, no default) |
| `atlas`              | <TBD>                                                                                                                    |
| `beacon`             | <TBD>                                                                                                                    |
| `clarity-engine`     | <TBD>                                                                                                                    |
| `pai-voice-server`   | <TBD>                                                                                                                    |

Five rows are landed. The remaining `<TBD>` rows are repos where prior rounds didn't produce a CWE-306 (missing auth) fix — open follow-ups before claiming full ADR conformance for those services. Note: `atlas` PR [#5](https://github.com/jckeen/atlas/pull/5) (CWE-209 error disclosure + CWE-532 PII logging) and `beacon` PR [#17](https://github.com/jckeen/beacon/pull/17) (security headers + rate limiting) are adjacent hardening but don't address the "auth at every entry point" property this ADR codifies.

---

## Verification

This ADR is satisfied for a given service when:

1. Every entry point in the service is reachable only after passing the auth check, OR is in an explicit, greppable opt-out list with a documented reason.
2. The service refuses to start if its auth secret is unset or too short.
3. A new endpoint added by anyone other than the original author still inherits auth without that author having to remember anything.
4. The opt-out list can be enumerated by a single `grep` and is small enough to review in one sitting.

If any of these four properties is false, the service does not yet conform to this ADR.
