# PART 0 — Initial Deployment (Cloudflare): Walkthrough & Verification

> **Scope:** `arh-agent-docs/development-plan.md` → PART 0 (PhD · P0): D0 backend, D1 frontend, D2 exit criteria
> **Date:** 2026-10-12 · **Cloudflare account:** `Devops@medoflow.com's Account` (`523c0186a1808be62e718907053c513b`)
> **Data:** synthetic demo dump `arh-agent-docs/medoflow-demo-20261005.sql.gz` only. See [PHI gate](../docs/PHI_GATE.md).

---

## 1. Outcome at a glance

| Item                                   | Result            | Acceptance criterion status                                                                                                                                                                                                                                                                                     |
| -------------------------------------- | ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **D0.1** Express API on Cloudflare     | 🟨 **Partial**    | Edge Worker live. The Express API is packaged as a Cloudflare **Container** and verified locally, but it **cannot be deployed: the account is on Workers Free, and Containers require Workers Paid.** AC not met on the deployed env.                                                                           |
| **D0.2** Postgres via Hyperdrive       | 🟨 **Mostly met** | Neon + Hyperdrive live; `migrate deploy` clean; read+write round-trip ✅; 50 concurrent ✅. "Prisma from the deployed runtime" waits on D0.1.                                                                                                                                                                   |
| **D0.3** Redis / BullMQ                | 🟨 **Partial**    | Redis Cloud live. Jobs survive a restart with no loss and no duplicates (verified against the real Redis from a local runner). Deployed-env run waits on D0.1. **Redis eviction policy must be changed to `noeviction`.**                                                                                       |
| **D0.4** Files on R2                   | 🟨 **Partial**    | Bucket is private: anonymous GET is refused and the r2.dev URL is disabled. **Presigned upload/download needs R2 S3 API keys (not yet issued)** plus D0.1.                                                                                                                                                      |
| **D0.5** Secrets + CORS + TLS          | ✅ **Met**        | gitleaks clean (git history + deployed client bundle); bad Origin → 403; HTTP → 301/403; HSTS on both apps.                                                                                                                                                                                                     |
| **D0.6** `wrangler` config + CI deploy | 🟨 **Partial**    | Configs + GitHub Actions pipeline written; build-gated deploy jobs; **rollback demonstrated**. Token `medo-worker-token` verified (deployed `medoflow-api` version `2e8ab89d` with it) and stored as repo secret `CLOUDFLARE_API_TOKEN`. **First CI run happens on the first push of these changes to `main`.** |
| **D1.1** Next.js on Cloudflare         | ✅ **Met**        | `@opennextjs/cloudflare` on Workers. **68/68 routes** across `(auth)`, `(onboarding)`, `(public)`, `dashboard`, `platform` render 2xx, dynamic routes included.                                                                                                                                                 |
| **D1.2** Public env vars               | 🟨 **Partial**    | Bundle calls the deployed API origin ✅. **No Stripe publishable key supplied**, so the placeholder ships.                                                                                                                                                                                                      |
| **D1.3** Custom domains                | ⬜ **Deferred**   | By decision: `workers.dev` only for now.                                                                                                                                                                                                                                                                        |
| **D1.4** Redirects / adapter build     | ✅ **Met**        | All 6 `/dashboard/patient/*` → `/account/*` redirects fire on the deployed env; adapter build has zero errors.                                                                                                                                                                                                  |
| **D2** Live + synthetic only           | 🟨 **Partial**    | Both Workers live. PHI scan = **0 hits**. **The 4 persona smoke flows can't pass on the deployed env until D0.1 is unblocked** (they pass against the same container image run locally, see §5.1).                                                                                                              |
| **D2** PHI gate documented             | ✅ **Met**        | [`docs/PHI_GATE.md`](../docs/PHI_GATE.md), linked from the HIPAA checklist (§7 pre-release, §8 item 11) and the plan's launch-readiness gate.                                                                                                                                                                   |

**Bottom line:** the frontend, edge API, database, Hyperdrive, R2, Redis, secrets, TLS/CORS, PHI gate and rollback are done and verified. The one thing between this and a fully working deployment is the **Workers Paid plan** ($5/mo). Once it's enabled, run `pnpm --filter medoflow-api-edge run deploy:container` (§7). Everything for that step is already built, configured, and loaded with secrets.

---

## 2. What is deployed

| Component                                                                  | Where                                                              | Identifier                                                                         |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| Frontend (Next.js 14.2.35 via OpenNext)                                    | Cloudflare Worker `medoflow-web`                                   | https://medoflow-web.advertout-medoflow.workers.dev                                |
| API edge (HTTPS/CORS gate, health, Hyperdrive check; fronts the container) | Cloudflare Worker `medoflow-api`                                   | https://medoflow-api.advertout-medoflow.workers.dev                                |
| Express API container                                                      | `BackendContainer` (Durable Object + Container), `--env container` | **not deployed: needs Workers Paid**                                               |
| Postgres                                                                   | Neon PG 18, db `medoflow-demo-db`, us-east-2                       | host `ep-withered-cherry-b459hcsg…neon.tech`                                       |
| Connection pooling                                                         | Hyperdrive `medoflow-neon`                                         | `5e50f409884f43a880c556fc15ccddf4`                                                 |
| Files                                                                      | R2 bucket `medoflow-files` (private)                               | `https://523c0186a1808be62e718907053c513b.r2.cloudflarestorage.com/medoflow-files` |
| Queue                                                                      | Redis Cloud 8.6 (BullMQ)                                           | `car-copper-price-21980.db.redis.io:19914`                                         |

```
 Browser ──HTTPS──▶ medoflow-web (Worker, OpenNext)            static assets via ASSETS binding
    │
    └──HTTPS (XHR, Origin-checked)──▶ medoflow-api (edge Worker)
                                          ├─ /api/v1/edge/health  → edge liveness + live version id
                                          ├─ /api/v1/edge/db      → Hyperdrive ─▶ Neon (read+write round-trip)
                                          └─ /api/v1/*            → BackendContainer "primary" (Express, Prisma, BullMQ,
                                                                    node-cron) ─▶ Neon (direct) · Redis · R2 (S3 API)
                                                                    [503 until Workers Paid + --env container]
   cron */5 (container env only) ─▶ keeps the single backend instance warm so cron + BullMQ keep running
```

**Design notes**

- **Why a Container for the API:** the Express app runs a long-lived BullMQ worker, node-cron jobs, multer uploads, argon2 (native) and ffmpeg, so it isn't a request-scoped Worker. Free-plan Workers also cap CPU at 10 ms per request and bundles at 3 MB, which Express + Prisma + AWS SDK + googleapis exceed. The container runs the existing `backend/Dockerfile` unchanged.
- **Why the container uses Neon directly, not Hyperdrive:** Container outbound handlers only intercept HTTP on ports 80/443, so raw Postgres TCP from a container can't go through a Hyperdrive binding. Hyperdrive serves the Worker layer (`/edge/db`). Prisma in the container uses Neon's direct endpoint, because Prisma migrations need session-level advisory locks that PgBouncer transaction mode breaks.
- **Single named instance (`"primary"`, `max_instances: 1`):** node-cron and the BullMQ worker must not run twice.
- **Two deploy targets, one Worker name:** `wrangler deploy` = edge only (works on Free). `wrangler deploy --env container` = edge + container (Paid). Both share secrets and URL.
- **`account_id` is pinned in both `wrangler.jsonc` files**, so a deploy with the wrong login fails instead of landing in another account (see §8, incident 1).

---

## 3. Repository changes

| File                                         | Purpose                                                                                                                                                                                                                             |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `backend/edge/worker.ts`                     | Edge Worker: HTTPS enforcement, Origin allow-list, `/edge/health` (with live version id), `/edge/db` (Hyperdrive round-trip via a temp table, no rows left behind), proxy to the `BackendContainer` Durable Object, cron keep-warm. |
| `backend/edge/wrangler.jsonc`                | Worker config: Hyperdrive, R2, version-metadata bindings, non-secret vars; `env.container` adds the container, DO binding, migration and cron.                                                                                      |
| `backend/edge/package.json`, `tsconfig.json` | Separate workspace package (`medoflow-api-edge`), so Cloudflare dev-deps never enter the backend Docker image.                                                                                                                      |
| `backend/.dockerignore`                      | Also excludes `edge/`, `.wrangler/`, `.env.*`, `coverage/`, `src/tests/` from the image (original entries kept).                                                                                                                    |
| `backend/scripts/deploy/phi-scan.sql`        | Synthetic-data scan over every text/json column (webmail emails, SSNs, non-555 phones, card numbers).                                                                                                                               |
| `backend/scripts/deploy/queue-smoke.js`      | BullMQ durability test: enqueue → restart → drain in a fresh process; fails on loss or duplicates.                                                                                                                                  |
| `frontend/wrangler.jsonc`                    | `medoflow-web` Worker config (OpenNext output, assets binding).                                                                                                                                                                     |
| `frontend/cf-worker.js`                      | Wraps the OpenNext handler: HTTP → HTTPS redirect, HSTS header.                                                                                                                                                                     |
| `frontend/open-next.config.ts`               | OpenNext config (no incremental cache needed).                                                                                                                                                                                      |
| `frontend/.env.production`                   | `NEXT_PUBLIC_API_URL` for the Cloudflare build (public value, no secrets).                                                                                                                                                          |
| `frontend/scripts/cf-route-smoke.sh`         | Requests every `page.tsx` route plus the 6 redirects on the deployed URL.                                                                                                                                                           |
| `frontend/package.json`                      | `next` 14.2.18 → **14.2.35** (minimum for OpenNext 1.15; also picks up 14.2.x security fixes); `cf:build` / `cf:deploy` / `cf:preview` scripts; `build` no longer uses POSIX-only `NODE_ENV=…` syntax (Next sets it).               |
| `frontend/next.config.js`                    | `experimental.outputFileTracingRoot` = repo root (pnpm monorepo tracing).                                                                                                                                                           |
| `frontend/package-lock.json`                 | **Removed.** A stale npm lockfile in a pnpm workspace made OpenNext treat `frontend/` as a standalone npm project. Installs already use pnpm everywhere (`vercel.json`, root `packageManager`).                                     |
| `frontend/tsconfig.json`                     | Excludes `.open-next/` and `.wrangler/`.                                                                                                                                                                                            |
| `pnpm-workspace.yaml`, `pnpm-lock.yaml`      | Adds `backend/edge`; new dependencies.                                                                                                                                                                                              |
| `.github/workflows/deploy-cloudflare.yml`    | Build gate (backend typecheck+build, edge typecheck+bundle, OpenNext build) → `deploy-api` + `deploy-web` (both `needs: build`) → post-deploy smoke; manual `rollback` dispatch.                                                    |
| `.gitleaksignore`                            | Allow-lists one reviewed false positive (`sk_test_placeholder` literal in `backend/src/config/stripe.ts`).                                                                                                                          |
| `.gitignore`                                 | Adds `.wrangler/` and `.open-next/`.                                                                                                                                                                                                |
| `docs/PHI_GATE.md`                           | The PHI gate (D2).                                                                                                                                                                                                                  |
| `docs/HIPAA_COMPLIANCE_CHECKLIST.md`         | PHI gate added to §7 pre-release, §8 item 11, changelog v1.1.                                                                                                                                                                       |
| `arh-agent-docs/development-plan.md`         | PART 0 statuses + PHI gate in the launch-readiness gate (gitignored folder; local only).                                                                                                                                            |

**Secrets** are never in the repo. They live in Wrangler secrets on `medoflow-api` (`DATABASE_URL`, `JWT_SECRET`, `REDIS_URL`) and in the team password manager. The verification commands below read them from your shell environment.

---

## 4. What was done, step by step

1. **Survey.** Express 4 + Prisma 6 + BullMQ/ioredis + node-cron + multer + argon2 + S3 SDK; Next 14 with 68 pages. Wrangler 4.86 was logged in to the MedoFlow account. R2 was initially disabled (later enabled by the account owner). Containers were refused: "requires the Workers Paid plan".
2. **Database.** Restored the dump into Neon (`psql` from the `postgres:16` image; 0 errors): 54 tables, 25 users, 4 clinics, 13 migrations. `prisma migrate deploy` reports _No pending migrations_, and `migrate status` says _Database schema is up to date_.
3. **PII sweep of the dump.** Found 3 public-webmail addresses: two `User` rows that looked like a real person's accounts, and one address in a voice-call tool log. Replaced them in Neon with `@example.com` placeholders. The dump file itself is unchanged. Added `phi-scan.sql`; it now returns 0 hits.
4. **Redis.** Connected (Redis 8.6). BullMQ warns that the eviction policy is `volatile-lru` and should be `noeviction` (action item in §7).
5. **R2 + Hyperdrive.** Created bucket `medoflow-files` and Hyperdrive config `medoflow-neon`.
6. **API edge Worker.** Wrote `backend/edge`, deployed, and verified health, Hyperdrive round-trip, 50-concurrent, HTTPS redirect, and Origin rejection.
7. **Backend container image.** Built `backend/Dockerfile` locally and ran it against Neon + Redis with `NODE_ENV=production`: health 200, the BullMQ worker connected, and all 4 personas logged in and `/auth/me` returned 200. Login rate limiting was confirmed along the way (5 attempts / 15 min → 429).
8. **Container target.** `wrangler deploy --env container --dry-run` validates (BACKEND DO binding + image). Uploaded the runtime secrets to `medoflow-api`.
9. **Frontend.** Pinned `@opennextjs/cloudflare@1.15.1`, the last release supporting Next 14 (it requires `next@^14.2.35`). Fixed two build problems: the stale npm lockfile, and Windows builds that skip an adapter patch (`Dynamic require of "/.next/server/middleware-manifest.json"`). **Build in Linux** (CI does, and locally use the Docker command in §6). Deployed, then ran the 68-route + 6-redirect smoke test: all pass.
10. **Security checks.** gitleaks on git history (clean after allow-listing the placeholder), backend tree (clean), and the 45 JS chunks served by the deployed frontend (clean). HSTS + HTTPS redirect on both apps.
11. **CI/CD + rollback.** Wrote the workflow and set repo secret `CLOUDFLARE_ACCOUNT_ID`. Added a `version_metadata` binding so the live version is visible, then demonstrated rollback B → A → B with `wrangler rollback`.
12. **PHI gate.** Wrote `docs/PHI_GATE.md` and linked it from the HIPAA checklist and the plan.

---

## 5. Verification: commands and expected results

Run from the repo root in Git Bash (or any POSIX shell). Set these once per shell from the password manager. They're needed only for the DB/Redis checks:

```bash
export API=https://medoflow-api.advertout-medoflow.workers.dev
export WEB=https://medoflow-web.advertout-medoflow.workers.dev
export NEON_DIRECT_URL='postgresql://neondb_owner:<password>@ep-withered-cherry-b459hcsg.c-6.us-east-2.aws.neon.tech/medoflow-demo-db?sslmode=require'
export REDIS_URL='redis://default:<password>@car-copper-price-21980.db.redis.io:19914'
# psql without a local install (Windows Git Bash needs MSYS_NO_PATHCONV=1):
psql_() { MSYS_NO_PATHCONV=1 docker run --rm -i postgres:16 psql "$NEON_DIRECT_URL" "$@"; }
```

### 5.1 D0.1: backend

```bash
# Edge Worker is live and reports its version
curl -s $API/api/v1/edge/health
#  → {"success":true,"message":"MedoFlow edge is operational","data":{"backend":"not-deployed","version":"<uuid>",...}}

# Express /health through the edge: honest 503 until the container is deployed
curl -s -w ' [%{http_code}]\n' $API/api/v1/health
#  → {"success":false,"message":"Backend container is not deployed on this environment"} [503]
#  After Workers Paid + deploy:container (§7) the expected result is 200 "Medoflow API is operational".

# Container config validates (no deploy)
cd backend/edge && npx wrangler deploy --env container --dry-run --outdir /tmp/x | grep -E "BACKEND|containers are available" ; cd -
#  → env.BACKEND (BackendContainer)  Durable Object
#  → - medoflow-api-backendcontainer-container (…/backend/Dockerfile)

# Same image, run locally against the deployed data plane (proves the image works)
docker build -t medoflow-backend:local backend
docker run -d --name mf-api -p 3000:3000 -e NODE_ENV=production -e PORT=3000 \
  -e DATABASE_URL="$NEON_DIRECT_URL" -e REDIS_URL="$REDIS_URL" -e JWT_SECRET="$(openssl rand -hex 48)" \
  -e CORS_ORIGIN=$WEB medoflow-backend:local
curl -s localhost:3000/api/v1/health                      # → 200 "Medoflow API is operational"
docker logs mf-api | grep -E "Database connected|AI Scribe worker started|running on port"
for e in admin doctor frontdesk patient; do
  t=$(curl -s -H 'content-type: application/json' -d "{\"email\":\"$e@medoflow.test\",\"password\":\"test1234\"}" \
      localhost:3000/api/v1/auth/login | node -pe "JSON.parse(require('fs').readFileSync(0)).data.accessToken")
  echo "$e: /auth/me $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $t" localhost:3000/api/v1/auth/me)"
done                                                        # → each prints 200
docker rm -f mf-api
```

### 5.2 D0.2: Postgres via Hyperdrive

```bash
# Read + write round-trip from the deployed runtime through Hyperdrive
curl -s $API/api/v1/edge/db
#  → {"success":true,"message":"Postgres reachable via Hyperdrive","data":{"write":true,"clinics":4,"migrations":13,"latencyMs":…}}

# 50 concurrent requests: expect "50 200" and nothing else
seq 1 50 | xargs -P 50 -I{} curl -s -o /dev/null -w "%{http_code}\n" $API/api/v1/edge/db | sort | uniq -c

# Migrations applied cleanly
cd backend && DATABASE_URL="$NEON_DIRECT_URL" npx prisma migrate deploy && DATABASE_URL="$NEON_DIRECT_URL" npx prisma migrate status; cd -
#  → "No pending migrations to apply." / "Database schema is up to date!"

# Hyperdrive config exists
npx wrangler hyperdrive get 5e50f409884f43a880c556fc15ccddf4 | grep -E '"name"|"host"'
```

### 5.3 D0.3: Redis / BullMQ durability

```bash
cd backend
node scripts/deploy/queue-smoke.js enqueue 20     # → enqueued 20; waiting=20   (no worker running)
# … restart / redeploy here: the producer process has exited …
node scripts/deploy/queue-smoke.js work; echo exit=$?
#  → expected=20 completed=20 processedNow=20 duplicates=0
#  → exit=0
cd -
```

Expected warning until fixed: `IMPORTANT! Eviction policy is volatile-lru. It should be "noeviction"` (§7).

### 5.4 D0.4: R2

```bash
npx wrangler r2 bucket dev-url get medoflow-files             # → Public access via the r2.dev URL is disabled.
npx wrangler r2 object get medoflow-files/deploy-check/probe.txt --remote --pipe   # authenticated read works
curl -s -w ' [%{http_code}]\n' https://523c0186a1808be62e718907053c513b.r2.cloudflarestorage.com/medoflow-files/deploy-check/probe.txt
#  → <Error><Code>InvalidArgument</Code><Message>Authorization</Message></Error> [400]
```

R2 refuses an anonymous GET with **400 `InvalidArgument: Authorization`**, not the 403 the AC states. Either way the object is not served. The presigned-URL half of the AC is pending (§7).

### 5.5 D0.5: secrets, CORS, TLS

```bash
# Secret scan: full git history (all committed content)
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/repo:ro" zricethezav/gitleaks:latest git /repo --redact \
  --gitleaks-ignore-path /repo/.gitleaksignore                # → "no leaks found"

# Secret scan: the JS actually served by the deployed frontend
mkdir -p /tmp/bundle && for r in / /login /dashboard /account /checkout /platform; do curl -s $WEB$r; done \
  | grep -oE '/_next/static/[^"]+\.js' | sort -u | while read u; do curl -s "$WEB$u" -o "/tmp/bundle/$(echo $u | tr / _)"; done
MSYS_NO_PATHCONV=1 docker run --rm -v "$(cd /tmp/bundle && pwd -W 2>/dev/null || pwd):/b:ro" zricethezav/gitleaks:latest dir /b --redact
#  → "no leaks found"

# CORS: disallowed Origin rejected, allowed Origin accepted
curl -s -w ' [%{http_code}]\n' -H "Origin: https://evil.example" $API/api/v1/edge/health   # → Origin not allowed [403]
curl -s -o /dev/null -w '[%{http_code}]\n' -H "Origin: $WEB" $API/api/v1/edge/health      # → [200]

# HTTPS only + HSTS
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://medoflow-api.advertout-medoflow.workers.dev/api/v1/edge/health  # → 301 -> https://…
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' http://medoflow-web.advertout-medoflow.workers.dev/login                # → 301 -> https://…
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://medoflow-api.advertout-medoflow.workers.dev/api/v1/auth/login                # → 403
curl -sI $WEB/login | grep -i strict-transport ; curl -sI $API/api/v1/edge/health | grep -i strict-transport
#  → strict-transport-security: max-age=31536000; includeSubDomains   (both)
```

Inside the container, Express keeps its own `cors()` allow-list (`CORS_ORIGIN`) and `helmet()`. The edge check is a second layer.

### 5.6 D0.6: config, CI, rollback

```bash
# Rollback drill (verified 2026-10-12: a4be0e5e → 12458bb7 → a4be0e5e)
cd backend/edge
npx wrangler versions list | grep "Version ID" | tail -3
curl -s $API/api/v1/edge/health | grep -oE '"version":"[^"]+"'          # current version (B)
npx wrangler rollback <previous-version-id> -m "rollback drill" -y         # → SUCCESS … deployed to 100% of traffic
curl -s $API/api/v1/edge/health | grep -oE '"version":"[^"]+"'          # → previous version (A)
npx wrangler rollback <B-version-id> -m "restore" -y                       # roll forward again
cd -

# CI pipeline
gh secret list                                    # → CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN (both set 2026-10-12)
git push origin main                              # → Actions: build → deploy-api + deploy-web → smoke
gh run watch
# Failing build blocks deploy: push a commit with a backend type error → "build" fails, deploy jobs are skipped.
# Rollback via CI: Actions → "Deploy to Cloudflare" → Run workflow → action = rollback
```

### 5.7 D1.1 / D1.4: frontend routes and redirects

```bash
bash frontend/scripts/cf-route-smoke.sh
#  → "ok   200 /…" for every page, then 6 × "ok   redirect /dashboard/patient… -> /account…"
#  → routes=68 failures=0
```

### 5.8 D1.2: frontend → backend wiring

```bash
for r in / /login /dashboard; do curl -s $WEB$r; done | grep -oE '/_next/static/[^"]+\.js' | sort -u \
  | while read u; do curl -s "$WEB$u"; done | grep -c "medoflow-api.advertout-medoflow.workers.dev"
#  → ≥ 1  (the client calls the deployed API origin)
```

In the browser: open `$WEB/login` → DevTools → Network → submit the form. The request goes to `https://medoflow-api.advertout-medoflow.workers.dev/api/v1/auth/login`, and it returns **503** until the container is deployed.

### 5.9 D2: synthetic data only

```bash
psql_ -v ON_ERROR_STOP=1 < backend/scripts/deploy/phi-scan.sql
#  →  card_number | 0 · phone_non555 | 0 · ssn | 0 · webmail_email | 0
psql_ -Atc 'select role, count(*) from "User" group by role order by 1'
#  → FRONT_DESK|1 · PATIENT|13 · PLATFORM_ADMIN|2 · PROVIDER|5 · SUPER_ADMIN|4
```

### 5.10 D2: PHI gate

```bash
head -5 docs/PHI_GATE.md                                     # → Status: CLOSED
grep -n "PHI_GATE" docs/HIPAA_COMPLIANCE_CHECKLIST.md          # → §7 pre-release line + §8 item 11
grep -n "PHI gate" arh-agent-docs/development-plan.md          # → launch-readiness gate entry
```

---

## 6. Day-to-day operations

```bash
# No global pnpm? Substitute `npx pnpm@10.33.0` for `pnpm` below.
# API edge (works on Windows)
pnpm --filter medoflow-api-edge run deploy                 # edge only (current)
pnpm --filter medoflow-api-edge run deploy:container       # edge + Express container (needs Workers Paid)
cd backend/edge && npx wrangler secret put STRIPE_SECRET_KEY   # add more runtime secrets the same way

# Frontend: build in LINUX (CI, WSL, or Docker). Windows builds silently miss an OpenNext patch → every page 500s.
# The ~/.wrangler config is the MedoFlow login; account_id in wrangler.jsonc rejects any other account.
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/src:ro" -v "$(cygpath -w ~/.wrangler/config/default.toml):/root/.config/.wrangler/config/default.toml" \
  -w /work node:22-bookworm bash -c '
  tar -C /src --exclude=node_modules --exclude=.next --exclude=.open-next --exclude=.git --exclude=arh-agent-docs -cf - \
      package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc frontend backend/package.json backend/edge/package.json | tar -xf - &&
  corepack enable && corepack prepare pnpm@10.33.0 --activate &&
  pnpm install --frozen-lockfile --filter medoflow-frontend... && cd frontend &&
  pnpm run cf:build && OPEN_NEXT_DEPLOY=true pnpm exec wrangler deploy'

# Logs
npx wrangler tail medoflow-api      # or medoflow-web
```

Demo logins (synthetic): `admin@medoflow.test`, `doctor@medoflow.test`, `frontdesk@medoflow.test`, `patient@medoflow.test`, `platform@medoflow.test`. Password `test1234` (from `backend/prisma/seed.ts`).

---

## 7. Open items to fully close PART 0 (owner action required)

| #   | Action                                                                                                                                                                                                                                                                 | Unblocks                                                               | How                                                                                                                                                                                                       |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Enable Workers Paid** ($5/mo)                                                                                                                                                                                                                                        | D0.1, D0.2 (Prisma), D0.3 (deployed), D0.4 (presign), D2 persona flows | Dashboard → Workers & Pages → Plans. Then `pnpm --filter medoflow-api-edge run deploy:container`. Re-run §5.1 (`/api/v1/health` → 200), §5.3 inside the container, and the persona logins against `$API`. |
| 2   | ~~Create a valid Cloudflare API token~~ ✅ done 2026-10-12 (`medo-worker-token`, user token for devops@medoflow.com; verified by a real deploy; stored as `CLOUDFLARE_API_TOKEN`). When moving to the container target, confirm the token also has _Containers: Edit_. | D0.6 auto-deploy                                                       | Remaining: push to `main` and watch the first run (`gh run watch`).                                                                                                                                       |
| 3   | **Issue R2 S3 API keys** (R2 → Manage API tokens → Object Read & Write, bucket `medoflow-files`)                                                                                                                                                                       | D0.4 presigned URLs                                                    | `wrangler secret put S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY` on `medoflow-api`. Endpoint/bucket/region vars are already set.                                                                         |
| 4   | **Set Redis eviction policy to `noeviction`**                                                                                                                                                                                                                          | D0.3 "no lost jobs" guarantee                                          | Redis Cloud console → database → Configuration → Data eviction policy. (`CONFIG SET` is blocked on managed Redis.)                                                                                        |
| 5   | **Stripe test publishable key**                                                                                                                                                                                                                                        | D1.2                                                                   | GitHub repo variable `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` (CI), or add it to `frontend/.env.production`. Also `wrangler secret put STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET`.                          |
| 6   | **Custom domain + wildcard clinic subdomains**                                                                                                                                                                                                                         | D1.3                                                                   | Deferred by decision. Needs a zone on this account, then `routes`/`custom_domain` in both `wrangler.jsonc` files and `CORS_ORIGIN` updated.                                                               |
| 7   | **Commit + push** these changes                                                                                                                                                                                                                                        | D0.6 first CI run                                                      | Not committed yet (left for review).                                                                                                                                                                      |

Out of scope here but noted: `TENANT_ISOLATION_MODE` is explicitly `warn` (B0.1.1). The Neon role `neondb_owner` has `BYPASSRLS` (B0.1.3). `next.config.js` still sets `ignoreBuildErrors` (F0.1.1).

---

## 8. Incidents during this work

1. **Real-looking personal data in the demo dump (resolved).** Three public-webmail addresses (two `User` rows plus one voice-call log entry) were replaced with `@example.com` placeholders in the Neon database. The dump file `arh-agent-docs/medoflow-demo-20261005.sql.gz` **still contains them**. Scrub it before reusing it anywhere else.
