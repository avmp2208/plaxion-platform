# plaxion-platform Helm Chart

Official Helm chart for **PlaxionMediator.Platform** — a single container image that runs:

| Role | How selected | What it serves |
|------|----------------|----------------|
| **API** | `ROLE=api` | REST API + Angular dashboard SPA (`wwwroot`, SPA fallback to `index.html`) |
| **Ingestion** | `ROLE=ingestion` | OTLP **HTTP** on port **8080** (`/v1/traces`, `/v1/metrics`, …) — **no gRPC port** |
| **Migrate** | `ROLE=api` + args `["--migrate"]` | EF Core migrations, then exit 0 |

There is **no separate dashboard Deployment**. The dashboard is built into the image and served by the API process.

Chart version: `0.1.0` · App version: `0.1.0`

---

## What this chart installs

- Deployment + Service for **api**
- Deployment + Service for **ingestion** (default **ClusterIP / internal-only**)
- Optional Ingress (`networking.k8s.io/v1`) and/or Traefik `IngressRoute` per service
- Optional HPA (autoscaling/v2) per service
- **Migration Job** as a Helm `pre-install,pre-upgrade` hook
- Chart-managed Secret for DB connection string (or refs to existing Secrets)
- Optional ServiceAccount, NetworkPolicy
- Optional **Bitnami PostgreSQL** subchart when `database.mode=bundled`

---

## Prerequisites

- Kubernetes 1.25+
- Helm 3.10+
- A PostgreSQL 14+ instance **or** enable bundled PostgreSQL
- Container image `ghcr.io/<owner>/plaxion-platform:<tag>` pullable by the cluster
- (Optional) Ingress controller or Traefik CRDs if exposing HTTP externally
- (Optional) `helm dependency update` when using bundled PostgreSQL

---

## Quick start

```bash
# From repository root
helm dependency update charts/plaxion-platform   # needed only if postgresql.enabled=true

helm upgrade --install plaxion charts/plaxion-platform \
  -n plaxion --create-namespace \
  -f examples/values-simple.yaml
```

Port-forward the API (dashboard + API on the same origin):

```bash
kubectl -n plaxion port-forward svc/plaxion-plaxion-platform-api 8080:8080
# open http://127.0.0.1:8080
```

Example values files:

| File | Purpose |
|------|---------|
| `examples/values-simple.yaml` | Minimal external Postgres |
| `examples/values-production.yaml` | Ingress+TLS, HPA, existing connection-string Secret |
| `examples/values-traefik.yaml` | Traefik IngressRoute |
| `examples/values-internal.yaml` | ClusterIP only + NetworkPolicy |

---

## Image configuration

```yaml
image:
  registry: ghcr.io
  repository: plaxion/plaxion-platform   # required
  tag: "0.1.0"                          # defaults to Chart.AppVersion when empty
  pullPolicy: IfNotPresent

imagePullSecrets:
  - name: ghcr-pull-secret
```

Rendered image: `{{ registry }}/{{ repository }}:{{ tag }}`.

Both roles and the migration Job use **the same image**. Role selection is exclusively via the `ROLE` environment variable (entrypoint exits 1 if unset/invalid).

---

## Database

### Modes

| `database.mode` | `postgresql.enabled` | Behavior |
|-----------------|----------------------|----------|
| `external` | `false` | Use an existing Postgres (recommended for production) |
| `bundled` | `true` | Deploy Bitnami PostgreSQL subchart |

`Storage__Provider` is always set to `PostgreSql` (configurable via `config.storage.provider`).

### External Postgres — password in values (chart-managed Secret)

```yaml
database:
  mode: external
  external:
    host: postgres.default.svc.cluster.local
    port: 5432
    database: plaxion
    username: plaxion
    password: "s3cret"
```

The chart creates Secret `<release>-plaxion-platform-app` with:

- `password`
- `connection-string` (Npgsql format)

Pods mount `ConnectionStrings__Platform` via `secretKeyRef`.

**Upgrade preservation:** templates use the Helm `lookup` function so an existing chart Secret is not blindly rotated on every `helm upgrade` when password is left empty. Setting `database.external.password` explicitly allows intentional rotation.

### External Postgres — existing password Secret

```yaml
database:
  mode: external
  external:
    host: postgres.default.svc.cluster.local
    database: plaxion
    username: plaxion
    existingSecret:
      name: my-pg-secret
      passwordKey: password
```

At install/upgrade time the chart looks up the password and writes the full connection string into the chart-managed Secret. For CI/`helm template` (no cluster), also provide `password` as a fallback so the connection string can be rendered.

### External Postgres — existing full connection-string Secret (recommended prod)

```yaml
database:
  mode: external
  external:
    existingConnectionStringSecret:
      name: plaxion-db-connection
      key: connection-string
```

No chart-managed DB Secret keys are created for the connection string. You own rotation.

### Bundled PostgreSQL

```yaml
database:
  mode: bundled

postgresql:
  enabled: true
  auth:
    username: plaxion
    password: "s3cret"   # set explicitly in real installs
    database: plaxion
  primary:
    persistence:
      enabled: true
      size: 8Gi
```

```bash
helm dependency update charts/plaxion-platform
```

Connection host becomes `<release>-postgresql`.

> **Uninstall:** Bitnami PostgreSQL PVCs are typically **retained** after `helm uninstall`. Delete PVCs manually to wipe data.

---

## Secrets model

| Data | Source |
|------|--------|
| `ConnectionStrings__Platform` | Chart Secret **or** `existingConnectionStringSecret` |
| `Observability__OtlpHeaders` | Chart Secret / `secrets.observability.*` / existing Secret (optional, sensitive) |
| Tenant API keys | **Not templated** — the app self-provisions keys at runtime via API |

Non-sensitive settings (CORS origins, aggregation intervals, retention, ingestion limits, `Storage__Provider`, etc.) are rendered as **inline env vars** on the Pods. Sensitive connection data always uses `valueFrom.secretKeyRef`.

.NET configuration hierarchy uses `__` in env var names (e.g. `Cors__AllowedOrigins__0`).

---

## Migrations

### Behavior

The chart runs a Kubernetes **Job** annotated as a Helm hook:

```yaml
annotations:
  helm.sh/hook: pre-install,pre-upgrade
  helm.sh/hook-weight: "-5"
  helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
```

Container:

- **Same image** as api/ingestion
- `ROLE=api`
- `args: ["--migrate"]` → `dotnet Platform.Api.dll --migrate`
- Same DB secret/config as the API
- Exits 0 after applying EF migrations

### Why a Helm hook (not `Database__AutoMigrate`, not a plain Job)?

1. **Platform contract:** migrations are an explicit one-shot process (`--migrate`), not EnsureCreated and not auto-migrate in Production (`Database__AutoMigrate` defaults to `false`).
2. **Ordering:** `pre-install` / `pre-upgrade` hooks block the release until the Job succeeds, so api/ingestion Deployments are not rolled out against a missing/outdated schema. This mirrors docker-compose `depends_on: service_completed_successfully`.
3. **Fail-closed runtime:** API/ingestion keep `Database__FailOnPendingMigrations=true` by default; if someone disables the hook, pods refuse to serve rather than silently drift.
4. **Hook delete policy:** `before-hook-creation,hook-succeeded` cleans successful Jobs and replaces failed ones on the next upgrade while leaving failures around for log inspection.

Disable only if you run migrations out-of-band:

```yaml
migrations:
  enabled: false
```

Check status:

```bash
kubectl -n <ns> get jobs -l app.kubernetes.io/component=migration
kubectl -n <ns> logs job/<release>-plaxion-platform-migrate
```

### Rollback caveat

**`helm rollback` does NOT reverse database migrations.** Schema changes are forward-only. Rolling back the application chart may leave a newer schema under an older binary. Plan DB and app rollbacks separately.

---

## API / Ingestion exposure

### Defaults

| Component | Service type | Ingress | Notes |
|-----------|--------------|---------|-------|
| api | ClusterIP | off | Serves API + dashboard |
| ingestion | ClusterIP | off | **Internal-only by design**; external exposure is opt-in |

Both listen on container port **8080** (`ASPNETCORE_URLS=http://+:8080`). There is **no OTLP gRPC port**.

### Kubernetes Ingress

```yaml
api:
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: platform.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: platform-tls
        hosts:
          - platform.example.com
```

TLS uses an **existing** TLS Secret (`secretName`). The chart does not mint certificates.

### Traefik IngressRoute

```yaml
api:
  ingress:
    enabled: false   # prefer one or the other for the same host
  ingressRoute:
    enabled: true
    entryPoints: [websecure]
    routes:
      - match: Host(`platform.example.com`)
    tls:
      secretName: platform-tls
```

> Prefer enabling **either** `ingress` **or** `ingressRoute` for a given host — not both — to avoid duplicate routing / TLS conflicts. The chart keeps independent enable flags and documents the caveat (no hard mutual-exclusion fail).

### LoadBalancer / NodePort

```yaml
api:
  service:
    type: LoadBalancer   # or NodePort
```

---

## Health probes

| Probe | Path | Purpose |
|-------|------|---------|
| Liveness | `GET /health` (or `/healthz`) | Process up — **no** dependency checks |
| Readiness | `GET /health/ready` | Includes DB connectivity |

**Never** use the readiness/DB check as liveness — a temporary DB blip would kill pods instead of taking them out of service.

---

## Dashboard

- Served by the **API** container from `wwwroot`.
- Entrypoint writes `wwwroot/assets/config.json` using `API_BASE_URL`.
- Leave `platform.apiBaseUrl` **empty** for same-origin (recommended when the dashboard is reached via the API Ingress/Service).

```yaml
platform:
  apiBaseUrl: ""  # same-origin
```

CORS for browser cross-origin access (API only):

```yaml
config:
  cors:
    allowedOrigins:
      - "https://app.example.com"
```

Empty `allowedOrigins` in Production **blocks** all cross-origin browser calls.

---

## Scaling and resources

```yaml
api:
  replicaCount: 2
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 8
    targetCPUUtilizationPercentage: 70
  resources:
    requests: { cpu: 250m, memory: 512Mi }
    limits:   { cpu: "2", memory: 1Gi }

ingestion:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 20
```

When HPA is enabled, `replicas` is omitted from the Deployment so the autoscaler owns scale.

---

## Security context

Defaults run as non-root UID/GID `1000` with dropped capabilities.  
`readOnlyRootFilesystem` is **false** because the entrypoint must write `wwwroot/assets/config.json`.

---

## NetworkPolicy

Disabled by default:

```yaml
networkPolicy:
  enabled: true
  allowExternal: true
  restrictiveEgress: false
```

When enabled, allows ingress to api/ingestion ports and egress to DNS + Postgres (and all egress unless `restrictiveEgress: true`).

---

## Upgrade behavior

1. Helm runs the **migration hook** first (`pre-upgrade`).
2. Deployments roll out with the new image/config.
3. Chart-managed Secrets use `lookup` to **preserve** generated passwords/connection strings across upgrades when you do not supply a new password.
4. Pod template includes `checksum/secret` so secret changes trigger rolling restarts.

```bash
helm upgrade plaxion charts/plaxion-platform -n plaxion -f my-values.yaml
```

---

## Uninstall

```bash
helm uninstall plaxion -n plaxion
```

- Chart resources (Deployments, Services, hook Jobs per delete policy, chart Secrets) are removed.
- **Bundled PostgreSQL PVCs are usually retained** — delete manually if you want data wiped.
- External database data is untouched.
- Prefer `existingConnectionStringSecret` so DB credentials outlive the release.

---

## Configuration reference (high level)

| Key | Description |
|-----|-------------|
| `image.*` | Container image |
| `aspnetcore.environment` | `Development` \| `Testing` \| `Staging` \| `Production` |
| `platform.apiBaseUrl` | Dashboard `API_BASE_URL` (empty = same-origin) |
| `config.*` | Non-sensitive app settings → env vars |
| `database.mode` | `external` \| `bundled` |
| `database.external.*` | Host/credentials / existing secrets |
| `postgresql.*` | Bitnami subchart values |
| `api.*` / `ingestion.*` | Replicas, service, ingress, HPA, resources, probes |
| `migrations.*` | Hook Job settings |
| `secrets.*` | Chart secret annotations / OTLP headers |
| `networkPolicy.*` | Optional NetworkPolicy |
| `serviceAccount.*` | SA creation |
| `extraEnv` / `extraEnvFrom` | Global extras (also per-component) |

Full defaults: [`values.yaml`](./values.yaml). Schema: [`values.schema.json`](./values.schema.json).

---

## Troubleshooting

**Migration Job failing**

```bash
kubectl -n <ns> describe job/<release>-plaxion-platform-migrate
kubectl -n <ns> logs job/<release>-plaxion-platform-migrate
```

Common causes: wrong connection string, Postgres not reachable, subchart not ready on first bundled install (retry upgrade once Postgres is up), missing `ROLE` (should not happen — chart sets it).

**Pods not Ready**

```bash
kubectl -n <ns> get pods
kubectl -n <ns> describe pod <api-pod>
kubectl -n <ns> exec -it <api-pod> -- wget -qO- http://127.0.0.1:8080/health/ready
```

Readiness fails when DB is down or migrations are pending (`FailOnPendingMigrations`).

**Dashboard cannot call API**

- Same-origin: leave `platform.apiBaseUrl` empty and expose API (not a separate static host without proxy).
- Cross-origin: set `config.cors.allowedOrigins` and matching `platform.apiBaseUrl`.

**Image pull errors**

Configure `imagePullSecrets` for `ghcr.io` (or your registry).

**Helm hook stuck**

```bash
kubectl -n <ns> get jobs -a
kubectl -n <ns> delete job <release>-plaxion-platform-migrate
helm upgrade ...   # recreates hook (before-hook-creation)
```

**`helm dependency update` fails (offline)**

Bundled mode needs the Bitnami chart tarball under `charts/`. External-mode examples (`postgresql.enabled=false`) still lint/template without the dependency archive.

---

## Development / CI

```bash
helm lint charts/plaxion-platform -f examples/values-simple.yaml
helm template plaxion charts/plaxion-platform -f examples/values-simple.yaml
```

GitHub Actions workflow: [`.github/workflows/helm-ci.yml`](../../.github/workflows/helm-ci.yml).

---

## License / source

Platform application source: PlaxionMediator.Platform.  
This repository publishes the official Helm packaging only.
