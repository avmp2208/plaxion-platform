# Installing PlaxionMediator.Platform with Helm

This is a complete, copy-paste-friendly tutorial for installing the official
`plaxion-platform` Helm chart on a Kubernetes cluster — from an empty cluster to
a working Platform installation. It assumes little or no prior Helm experience.

Throughout this guide we use:

- Namespace: `plaxion-platform`
- Helm release name: `plaxion-platform`
- Chart path: `charts/plaxion-platform` (from the root of this repository)

You may use a different namespace or release name — just be consistent and
substitute your own values everywhere.

> Placeholders used in this guide (never real credentials):
> `<GHCR_USERNAME>`, `<GHCR_TOKEN>`, `<DB_HOST>`, `<DB_PORT>`, `<DB_NAME>`,
> `<DB_USERNAME>`, `<DB_PASSWORD>`, `<PLATFORM_HOST>`, `<OTLP_HOST>`,
> `<TLS_SECRET_NAME>`.

---

## Table of contents

1. [Before you begin](#before-you-begin)
2. [What this chart installs](#what-this-chart-installs)
3. [Choose your deployment scenario](#choose-your-deployment-scenario)
4. [Prepare namespace](#prepare-namespace)
5. [Prepare image pull credentials (GHCR)](#prepare-image-pull-credentials-ghcr)
6. [Prepare database credentials](#prepare-database-credentials)
7. [Configure values](#configure-values)
8. [Install Platform](#install-platform)
9. [Verify migrations](#verify-migrations)
10. [Verify workloads](#verify-workloads)
11. [Verify Dashboard/API](#verify-dashboardapi)
12. [Verify OTLP ingestion](#verify-otlp-ingestion)
13. [Upgrade Platform](#upgrade-platform)
14. [Rollback](#rollback)
15. [Uninstall](#uninstall)
16. [Troubleshooting](#troubleshooting)
17. [Production checklist](#production-checklist)

---

## Before you begin

You need:

- Access to a Kubernetes cluster (1.25+).
- `kubectl` configured to talk to that cluster.
- `helm` (3.10+) installed locally.
- Pull access to the Platform container image
  (`ghcr.io/plaxion/plaxion-platform`, or your own mirror).
- A reachable PostgreSQL 14+ database — **or** you plan to use the chart's
  bundled PostgreSQL (development/evaluation only, see
  [Optional bundled PostgreSQL](#optional-bundled-postgresql)).
- If you plan to expose Platform outside the cluster: an Ingress controller
  (e.g. NGINX Ingress Controller) **or** Traefik with its CRDs already
  installed. Neither is installed by this chart — you must install one
  yourself if you need it.
- An existing OIDC provider/client for human sign-in (Keycloak, IdentityServer,
  Entra ID, Okta, etc. — **not installed by this chart**), unless you are
  intentionally running an anonymous evaluation deployment. See
  ["Before installing: prepare your OIDC provider"](#before-installing-prepare-your-oidc-provider)
  below and [docs/oidc-authentication.md](oidc-authentication.md).

Verify your tooling before continuing:

```bash
kubectl cluster-info
kubectl get nodes
helm version
```

All three commands must succeed without errors before you proceed.

If you plan to use standard Kubernetes `Ingress` (Scenario B below), also check
that an ingress controller is actually running, e.g.:

```bash
kubectl get pods -A | grep -i ingress
```

If you plan to use Traefik `IngressRoute` (Scenario C below), verify the CRDs
exist:

```bash
kubectl get crd ingressroutes.traefik.io
```

---

## Before installing: prepare your OIDC provider

Dashboard/`Platform.Api` sign-in uses generic, standards-based OIDC
(Authorization Code + PKCE). Before installing a real (non-anonymous)
deployment, prepare an existing OIDC client with:

- Authorization Code flow enabled, **PKCE required**
- **No client secret** — the Angular Dashboard is a public browser client
- Redirect URI: `https://<PLATFORM_HOST>/auth/callback`
- Logout redirect URI (if used): `https://<PLATFORM_HOST>/`
- Scopes: `openid`, `profile`, `email` (defaults; adjust if your provider needs more)
- An audience/resource configured so issued access tokens carry the `aud`
  value you will set in `authentication.oidc.audience`

See provider-specific tutorials: [Keycloak](oidc-keycloak.md) ·
[IdentityServer/Duende](oidc-identityserver.md) · full contract:
[docs/oidc-authentication.md](oidc-authentication.md). Upgrading an existing
pre-OIDC release? Use [docs/upgrade-to-oidc.md](upgrade-to-oidc.md) instead of
this tutorial's plain install flow.

## What this chart installs

The chart packages a single container image that can run in three roles,
selected by the `ROLE` environment variable:

| Component | Role | What it does |
|---|---|---|
| **API workload** (Deployment + Service) | `ROLE=api` | Serves the REST API **and** the built-in Angular Dashboard SPA (same container, same port) |
| **Ingestion workload** (Deployment + Service) | `ROLE=ingestion` | Accepts OTLP over **HTTP** (traces/metrics) on port `8080`. There is **no** OTLP gRPC port. |
| **Migration Job** | `ROLE=api --migrate` | Runs EF Core database migrations, then exits. Runs as a Helm hook before API/Ingestion start. |

There is **no separate Dashboard Deployment** — the Dashboard is static assets
served by the API container.

Optional resources, created only if you enable them:

- Standard Kubernetes `Ingress` for API and/or Ingestion.
- Traefik `IngressRoute` for API and/or Ingestion.
- HPA (`autoscaling/v2`) for API and/or Ingestion.
- A bundled Bitnami PostgreSQL sub-chart (`database.mode: bundled`).
- A `NetworkPolicy`.
- A chart-managed `Secret` holding the database connection string (unless you
  bring your own connection-string Secret).

**API/Dashboard exposure and Ingestion exposure are configured independently.**
You can, for example, expose the Dashboard publicly via Ingress while keeping
Ingestion internal-only (`ClusterIP`), or vice versa.

---

## Choose your deployment scenario

Pick the scenario that matches your environment. Each is documented in full
further down:

| Scenario | API/Dashboard exposure | Ingestion exposure | Use when |
|---|---|---|---|
| **A — Internal only** | ClusterIP (port-forward) | ClusterIP | Evaluating the chart, or Dashboard/API is only used from inside the cluster / via a service mesh |
| **B — Standard Ingress (e.g. NGINX)** | `Ingress` | `Ingress` (optional) | You already run a standard Kubernetes Ingress controller |
| **C — Traefik IngressRoute** | `IngressRoute` | `IngressRoute` (optional) | You already run Traefik with CRDs |
| **Ingestion via LoadBalancer** | (any of the above) | `Service type: LoadBalancer` | You want to expose only OTLP ingestion, without HTTP routing rules |

You do not have to choose the same exposure method for API and Ingestion.

---

## Prepare namespace

Create a dedicated namespace for the release:

```bash
kubectl create namespace plaxion-platform
```

All examples below assume this namespace. If you use a different name, replace
`plaxion-platform` consistently in every `-n <namespace>` / `--namespace
<namespace>` flag.

---

## Prepare image pull credentials (GHCR)

If the Platform image (`ghcr.io/plaxion/plaxion-platform`) is **public**, you
can skip this section entirely — leave `imagePullSecrets: []` in your values.

If the image is private, create a dedicated Kubernetes `Secret` of type
`docker-registry` **in the same namespace** as the release. Keep this Secret
separate from database credentials — do not reuse it for anything else.

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace plaxion-platform \
  --docker-server=ghcr.io \
  --docker-username=<GHCR_USERNAME> \
  --docker-password=<GHCR_TOKEN>
```

Required inputs:

- `<GHCR_USERNAME>` — your GitHub username (or an org token identity).
- `<GHCR_TOKEN>` — a GitHub Personal Access Token with `read:packages` scope
  (classic PAT) or a fine-grained token with package read access.
- `--docker-server` — the registry hostname (`ghcr.io`).
- `--namespace` — must match the namespace you installed the release into.

Reference this Secret in your values file:

```yaml
imagePullSecrets:
  - name: ghcr-pull-secret
```

---

## Prepare database credentials

**Never mix registry credentials and database credentials in the same
Secret.** Create a separate Secret for the database.

The chart supports two different ways of supplying database credentials via an
existing Secret you create yourself (recommended for production):

### Option 1 — existing Secret with the password only

The chart builds the full connection string itself from
`database.external.host` / `port` / `database` / `username` (non-secret
values) plus the password from your Secret.

```bash
kubectl create secret generic plaxion-platform-db-password \
  --namespace plaxion-platform \
  --from-literal=password='<DB_PASSWORD>'
```

Required key: **`password`** (the key name is configurable, see below; the
chart's default expected key is `password`).

Reference it in values:

```yaml
database:
  mode: external
  external:
    host: "<DB_HOST>"
    port: 5432
    database: "<DB_NAME>"
    username: "<DB_USERNAME>"
    existingSecret:
      name: plaxion-platform-db-password
      passwordKey: password   # optional; "password" is the default
```

### Option 2 — existing Secret with a full connection string (recommended for production)

Use this when you want to fully own the connection string (rotation,
formatting, extra Npgsql parameters) outside the chart.

```bash
kubectl create secret generic plaxion-platform-db \
  --namespace plaxion-platform \
  --from-literal=connection-string='Host=<DB_HOST>;Port=5432;Database=<DB_NAME>;Username=<DB_USERNAME>;Password=<DB_PASSWORD>'
```

Required key: **`connection-string`** (this exact key name is the chart's
default; it is configurable via `key:` below).

Reference it in values:

```yaml
database:
  mode: external
  external:
    existingConnectionStringSecret:
      name: plaxion-platform-db
      key: connection-string   # optional; "connection-string" is the default
```

When `existingConnectionStringSecret.name` is set, the chart does **not**
create its own database Secret at all — you fully own credential storage and
rotation.

> Do not commit `database.external.password` directly into a production values
> file. It exists mainly for quick local/CI testing.

---

## Configure values

**Do not edit the chart's packaged `values.yaml` directly as your long-term
configuration.** That file only holds chart defaults and will be
overwritten/ignored on chart upgrades. Instead, keep your own values file
alongside your deployment tooling, e.g. `my-platform-production-values.yaml`,
and always pass it explicitly with `-f` on every `helm install` / `helm
upgrade`. This is what makes upgrades safe and repeatable.

Example values files shipped in this repository (`examples/`) are a good
starting point — copy one and edit it, do not use it verbatim in production:

| File | Purpose |
|---|---|
| `examples/values-simple.yaml` | Minimal external Postgres, no ingress |
| `examples/values-internal.yaml` | ClusterIP-only, internal cluster use |
| `examples/values-production.yaml` | External Postgres via Secret, NGINX Ingress + TLS, HPA |
| `examples/values-traefik.yaml` | Traefik IngressRoute |

Below is an annotated minimum you actually need to touch. Fields are marked:

- **REQUIRED TO CHANGE** — you must set this for your environment.
- **OPTIONAL** — change only if you need the behavior.
- **SAFE DEFAULT** — leave as-is unless you have a specific reason.

```yaml
image:
  registry: ghcr.io                       # SAFE DEFAULT
  repository: plaxion/plaxion-platform    # REQUIRED TO CHANGE if you mirror the image
  tag: "0.1.0"                            # REQUIRED TO CHANGE — pin an explicit version in production
  pullPolicy: IfNotPresent                # SAFE DEFAULT

imagePullSecrets:                         # OPTIONAL — omit if image is public
  - name: ghcr-pull-secret

aspnetcore:
  environment: Production                 # SAFE DEFAULT

platform:
  apiBaseUrl: ""                          # SAFE DEFAULT — empty means "same origin" (Dashboard calls API on the same host)
  publicBaseUrl: "https://<PLATFORM_HOST>"  # REQUIRED TO CHANGE — drives OIDC redirect/post-logout URIs

# OIDC authentication. Production installs require enabled=true (recommended)
# or the explicit, intentionally unsafe allowAnonymousProduction escape hatch.
# See docs/oidc-authentication.md for the full contract and provider tutorials.
authentication:
  enabled: true                           # REQUIRED TO CHANGE for anonymous/dev-only deployments
  allowAnonymousProduction: false         # SAFE DEFAULT — never set true for a real production deployment
  oidc:
    authority: "https://sso.example.com/realms/company"  # REQUIRED TO CHANGE
    audience: "plaxion-platform"                          # REQUIRED TO CHANGE
    requireHttpsMetadata: true                            # SAFE DEFAULT
    dashboard:
      clientId: "plaxion-platform-ui"                     # REQUIRED TO CHANGE
      scopes: [openid, profile, email]                    # SAFE DEFAULT
      redirectPath: /auth/callback                        # SAFE DEFAULT — register with your OIDC provider
      postLogoutRedirectPath: /                            # SAFE DEFAULT — register with your OIDC provider
  authorization:
    tenantCreation:
      mode: AnyAuthenticatedUser                          # OPTIONAL — or Role / Claim

config:
  cors:
    allowedOrigins: []                    # REQUIRED TO CHANGE if Dashboard/API are served from different origins

database:
  provider: PostgreSql                    # SAFE DEFAULT
  mode: external                          # REQUIRED TO CHANGE — "external" (recommended) or "bundled"
  external:
    host: "<DB_HOST>"                     # REQUIRED TO CHANGE (ignored if existingConnectionStringSecret is set)
    port: 5432                            # SAFE DEFAULT
    database: "<DB_NAME>"                 # REQUIRED TO CHANGE
    username: "<DB_USERNAME>"             # REQUIRED TO CHANGE
    existingConnectionStringSecret:       # REQUIRED TO CHANGE — see "Prepare database credentials"
      name: plaxion-platform-db
      key: connection-string

api:
  enabled: true                           # SAFE DEFAULT
  replicaCount: 2                         # OPTIONAL — production should run 2+
  service:
    type: ClusterIP                       # REQUIRED TO CHANGE only if you need NodePort/LoadBalancer
  resources:                              # OPTIONAL but recommended in production
    requests: { cpu: 250m, memory: 512Mi }
    limits:   { cpu: "1",  memory: 1Gi }

ingestion:
  enabled: true                           # SAFE DEFAULT
  replicaCount: 2                         # OPTIONAL
  service:
    type: ClusterIP                       # SAFE DEFAULT — internal by design
  resources:                              # OPTIONAL but recommended in production
    requests: { cpu: 250m, memory: 512Mi }
    limits:   { cpu: "1",  memory: 1Gi }

migrations:
  enabled: true                           # SAFE DEFAULT — do not disable unless you run migrations out-of-band
```

Ingress/TLS/IngressRoute fields are covered in the scenario sections below —
add only the block for the scenario you chose.

---

## Install Platform

Once your namespace, Secrets, and values file are ready:

```bash
helm install plaxion-platform \
  charts/plaxion-platform \
  --namespace plaxion-platform \
  -f my-platform-production-values.yaml
```

For subsequent changes, use `helm upgrade` (see [Upgrade
Platform](#upgrade-platform)) — or `helm upgrade --install` if you want a
single idempotent command for both first install and later runs:

```bash
helm upgrade --install plaxion-platform \
  charts/plaxion-platform \
  --namespace plaxion-platform \
  -f my-platform-production-values.yaml
```

> The chart is not currently published to an OCI registry / GHCR Helm
> repository. Install it from a local checkout of this repository
> (`charts/plaxion-platform`) as shown above.

If you set `database.mode: bundled`, run this once before installing (see
[Optional bundled PostgreSQL](#optional-bundled-postgresql)):

```bash
helm dependency update charts/plaxion-platform
```

---

## Verify migrations

Database migrations are **not** a separate manual step — they run
automatically as a Helm hook (`pre-install`,`pre-upgrade`) before the API and
Ingestion Deployments are rolled out.

What happens:

- A Kubernetes `Job` named `plaxion-platform-migrate` is created using the
  **same container image** as API/Ingestion.
- It runs with `ROLE=api` and arguments `["--migrate"]`
  (`dotnet Platform.Api.dll --migrate`).
- It uses the **same database connection Secret** as the API/Ingestion pods.
- Helm blocks the release (`helm install`/`helm upgrade` will not return
  success) until this Job completes, so API/Ingestion pods are never started
  against a missing/outdated schema.
- If the Job fails, `helm install`/`helm upgrade` fails and no application
  pods are rolled out. The failed Job is retained (not deleted) so you can
  inspect its logs; it is replaced only on the next attempt.

Inspect it:

```bash
kubectl get jobs -n plaxion-platform -l app.kubernetes.io/component=migration
kubectl logs -n plaxion-platform job/plaxion-platform-migrate
```

A successful migration Job shows `COMPLETIONS 1/1` in `kubectl get jobs`.

---

## Verify workloads

Run this checklist after `helm install`/`helm upgrade` returns:

```bash
helm list -n plaxion-platform
kubectl get pods -n plaxion-platform
kubectl get svc -n plaxion-platform
kubectl get jobs -n plaxion-platform
```

Expect:

- `helm list` shows `STATUS: deployed`.
- All API/Ingestion pods show `READY 1/1` and `STATUS Running`.
- The migration Job shows `COMPLETIONS 1/1`.
- `plaxion-platform-api` and `plaxion-platform-ingestion` Services exist.

You can also wait explicitly for pods to become ready:

```bash
kubectl wait -n plaxion-platform --for=condition=Ready pod -l app.kubernetes.io/component=api --timeout=180s
kubectl wait -n plaxion-platform --for=condition=Ready pod -l app.kubernetes.io/component=ingestion --timeout=180s
```

### Health probes

The API and Ingestion containers expose two endpoints:

- **Liveness** — `GET /health` — only checks the process is alive; it does
  **not** check the database. Kubernetes restarts the pod if this fails.
- **Readiness** — `GET /health/ready` — also checks database connectivity.
  Kubernetes removes the pod from Service endpoints (stops sending it traffic)
  if this fails, without restarting it.

To test manually (internal service, no external exposure required):

```bash
kubectl port-forward -n plaxion-platform svc/plaxion-platform-api 8080:8080
curl -i http://127.0.0.1:8080/health
curl -i http://127.0.0.1:8080/health/ready
```

If readiness fails but liveness passes, the most likely cause is that the
database is unreachable or migrations have not completed.

---

## Verify Dashboard/API

How you reach the Dashboard depends on the scenario you chose.

### Scenario A — internal only (no Ingress)

```bash
kubectl port-forward -n plaxion-platform svc/plaxion-platform-api 8080:8080
```

Open `http://127.0.0.1:8080` in a browser. Dashboard and API are served from
the same origin.

Applications running **inside the cluster** can reach the API/Dashboard at:

```
http://plaxion-platform-api.plaxion-platform.svc.cluster.local:8080
```

Applications **outside** the cluster cannot reach a `ClusterIP` Service.

### Scenario B — standard Ingress

Open `https://<PLATFORM_HOST>` in a browser (see [Scenario
B](#scenario-b--standard-kubernetes-ingress-eg-nginx) for setup).

### Scenario C — Traefik IngressRoute

Open `https://<PLATFORM_HOST>` in a browser (see [Scenario
C](#scenario-c--traefik-ingressroute)).

### First steps in the product

Once the Dashboard loads:

1. Open the Dashboard. If `authentication.enabled=true` you are redirected to
   your OIDC provider's login page — authenticate there first.
2. Create a tenant (subject to your `authentication.authorization.tenantCreation`
   policy).
3. Copy the one-time API key shown after tenant creation — it is not shown
   again. This key is what your instrumented applications will use to send
   telemetry (see next section).

The chart does not create or manage tenants/API keys; they are created at
runtime through the product itself.

---

## Verify OTLP ingestion

Point a standard OpenTelemetry exporter (OTLP/HTTP, protobuf) at the Ingestion
Service. There is no proprietary SDK — use any standard OTLP exporter.

### From inside the cluster

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://plaxion-platform-ingestion.plaxion-platform.svc.cluster.local:8080
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <YOUR_TENANT_API_KEY>
```

### From outside the cluster (Scenario B/C only)

```
OTEL_EXPORTER_OTLP_ENDPOINT=https://<OTLP_HOST>
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <YOUR_TENANT_API_KEY>
```

A quick manual smoke test against the traces endpoint:

```bash
curl -i -X POST http://127.0.0.1:8081/v1/traces \
  -H "Content-Type: application/x-protobuf" \
  -H "Authorization: Bearer <YOUR_TENANT_API_KEY>" \
  --data-binary @empty.bin
```

(Use `kubectl port-forward -n plaxion-platform svc/plaxion-platform-ingestion
8081:8080` first if testing internally.) A `2xx`/expected error response
(rather than connection refused) confirms the endpoint is reachable.

---

## Scenario A — no external Ingress

Use this scenario if Platform only needs to be reachable from inside the
cluster.

**1. Create Secrets** — see [Prepare image pull
credentials](#prepare-image-pull-credentials-ghcr) and [Prepare database
credentials](#prepare-database-credentials).

**2. values file:**

```yaml
api:
  service:
    type: ClusterIP
  ingress:
    enabled: false
  ingressRoute:
    enabled: false

ingestion:
  service:
    type: ClusterIP
  ingress:
    enabled: false
  ingressRoute:
    enabled: false
```

(This matches `examples/values-internal.yaml`.)

**3. Install:**

```bash
helm install plaxion-platform charts/plaxion-platform \
  --namespace plaxion-platform \
  -f examples/values-internal.yaml
```

**4–6. Verify, port-forward, internal DNS** — see [Verify
workloads](#verify-workloads) and [Verify Dashboard/API](#verify-dashboardapi)
above. Internal OTLP endpoint:
`http://plaxion-platform-ingestion.plaxion-platform.svc.cluster.local:8080`.

Applications **outside** the cluster cannot reach this ClusterIP Ingestion
endpoint — use Scenario B, C, or a LoadBalancer Service if you need external
ingestion.

---

## Scenario B — standard Kubernetes Ingress (e.g. NGINX)

Requires an Ingress controller already installed in the cluster (this chart
does not install one). NGINX Ingress Controller is used here only as a
concrete, common example — the chart's `Ingress` resource itself is
controller-agnostic.

```yaml
api:
  ingress:
    enabled: true
    className: nginx                       # your IngressClass name
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
    hosts:
      - host: <PLATFORM_HOST>
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: <TLS_SECRET_NAME>
        hosts:
          - <PLATFORM_HOST>

ingestion:
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: <OTLP_HOST>
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: <TLS_SECRET_NAME>
        hosts:
          - <OTLP_HOST>
```

Install:

```bash
helm install plaxion-platform charts/plaxion-platform \
  --namespace plaxion-platform \
  -f examples/values-production.yaml
```

Inspect:

```bash
kubectl get ingress -n plaxion-platform
kubectl describe ingress plaxion-platform-api -n plaxion-platform
kubectl describe ingress plaxion-platform-ingestion -n plaxion-platform
```

DNS: point both hostnames at your ingress controller's public
address/load balancer:

```
<PLATFORM_HOST> -> <ingress controller external IP/hostname>
<OTLP_HOST>     -> <ingress controller external IP/hostname>
```

The nginx-specific annotations above (`nginx.ingress.kubernetes.io/...`) only
apply if you actually run the NGINX Ingress Controller — omit them for other
controllers.

---

## Scenario C — Traefik IngressRoute

Requires Traefik already installed with its CRDs. Verify the CRD exists first:

```bash
kubectl get crd ingressroutes.traefik.io
```

```yaml
api:
  ingress:
    enabled: false        # prefer IngressRoute OR Ingress for a given host, not both
  ingressRoute:
    enabled: true
    entryPoints:
      - websecure
    routes:
      - match: Host(`<PLATFORM_HOST>`)
        kind: Rule
        middlewares: []    # optional Traefik Middleware references
    tls:
      secretName: <TLS_SECRET_NAME>
      # certResolver: letsencrypt   # optional, only if you use Traefik's ACME resolver

ingestion:
  ingress:
    enabled: false
  ingressRoute:
    enabled: true
    entryPoints:
      - websecure
    routes:
      - match: Host(`<OTLP_HOST>`)
        kind: Rule
    tls:
      secretName: <TLS_SECRET_NAME>
```

Topology:

```
https://<PLATFORM_HOST>  -> Platform API / Dashboard
https://<OTLP_HOST>      -> Platform Ingestion
```

Install:

```bash
helm install plaxion-platform charts/plaxion-platform \
  --namespace plaxion-platform \
  -f examples/values-traefik.yaml
```

Verify:

```bash
kubectl get ingressroute -n plaxion-platform
kubectl describe ingressroute plaxion-platform-api -n plaxion-platform
kubectl describe ingressroute plaxion-platform-ingestion -n plaxion-platform
```

DNS: point both hostnames at Traefik's public entrypoint address. TLS: the
`secretName` must reference an existing TLS Secret in the same namespace
(create it as shown in [TLS](#tls)), unless you configure `certResolver` for
Traefik-managed ACME certificates.

---

## Ingestion exposure — choose intentionally

Ingestion does **not** need to be exposed outside the cluster by default, and
this chart defaults it to `ClusterIP` (internal-only) intentionally.

- **Instrumented services run in the same cluster** → use the internal service
  DNS name shown above. No further exposure needed.
- **Instrumented services run outside the cluster** → choose one:
  - Standard `Ingress` (Scenario B)
  - Traefik `IngressRoute` (Scenario C)
  - `Service type: LoadBalancer` (below)

Exposing Ingestion externally means anyone who can reach that hostname/IP can
attempt to send telemetry (protected only by the per-tenant API key). Enable
external exposure deliberately, not by default.

### Optional: LoadBalancer for Ingestion only

If you want to expose only OTLP ingestion without HTTP routing rules (e.g. no
Ingress controller available), set:

```yaml
ingestion:
  service:
    type: LoadBalancer
```

Retrieve the external address once provisioned (this can take a few minutes,
and support/behavior varies by cloud provider — not all Kubernetes
distributions provision an external IP for `LoadBalancer` automatically):

```bash
kubectl get svc plaxion-platform-ingestion -n plaxion-platform
```

---

## TLS

The chart does **not** mint or manage certificates itself (no cert-manager
dependency). You must create the TLS Secret yourself, then reference its name
in `tls.secretName` (Ingress) or `tls.secretName` (IngressRoute).

For documentation/testing purposes, create a TLS Secret from an existing
certificate/key pair:

```bash
kubectl create secret tls <TLS_SECRET_NAME> \
  --namespace plaxion-platform \
  --cert=path/to/tls.crt \
  --key=path/to/tls.key
```

In production, certificate issuance and rotation are normally handled by your
own infrastructure (e.g. an external PKI process, or cert-manager if you
already run it). If you use cert-manager, you may add its annotations under
`api.ingress.annotations` / `ingestion.ingress.annotations` — this is an
optional integration, not something this chart requires or manages.

---

## Optional bundled PostgreSQL

The chart can optionally deploy PostgreSQL via the Bitnami `postgresql`
sub-chart. This is intended for **evaluation, development, or simple
self-hosted setups** — not as the primary recommendation for serious
production use. Prefer [external PostgreSQL](#prepare-database-credentials)
in production.

Enable it:

```yaml
database:
  mode: bundled

postgresql:
  enabled: true
  auth:
    username: plaxion
    password: "<DB_PASSWORD>"   # required on first install; set explicitly
    database: plaxion
  primary:
    persistence:
      enabled: true
      size: 8Gi
      # storageClass: ""        # optional; empty uses the cluster default StorageClass
```

Before installing/upgrading with `postgresql.enabled: true`, fetch the
sub-chart dependency once:

```bash
helm dependency update charts/plaxion-platform
```

Persistence / upgrade / uninstall implications:

- Data is stored on a `PersistentVolumeClaim` created by the sub-chart
  (`primary.persistence.size`, optionally `storageClass`).
- `helm upgrade` preserves the PVC and its data as long as you don't disable
  persistence or change values that force PVC recreation.
- `helm uninstall` typically **retains** the PVC (Bitnami default) — the data
  survives uninstall, but you should delete the PVC manually if you want to
  fully wipe it:

```bash
kubectl get pvc -n plaxion-platform
kubectl delete pvc -n plaxion-platform -l app.kubernetes.io/instance=plaxion-platform
```

---

## Production resources

Set explicit CPU/memory requests and limits for API and Ingestion
independently — Kubernetes uses these for scheduling and to protect the node
from noisy neighbors. The values below are a conservative **starting example**
only, not a universal recommendation — size them to your actual load:

```yaml
api:
  resources:
    requests: { cpu: 250m, memory: 512Mi }
    limits:   { cpu: "1",  memory: 1Gi }

ingestion:
  resources:
    requests: { cpu: 250m, memory: 512Mi }
    limits:   { cpu: "1",  memory: 1Gi }
```

---

## Replicas / scaling

```yaml
api:
  replicaCount: 2

ingestion:
  replicaCount: 2
```

Ingestion often needs to scale further than API/Dashboard, since it absorbs
telemetry write traffic from all instrumented applications, while API traffic
is typically lower-volume browser/dashboard usage.

Optional HPA (autoscaling/v2) per component:

```yaml
ingestion:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 20
    targetCPUUtilizationPercentage: 70
```

When `autoscaling.enabled: true`, `replicaCount` is ignored for that
component — the HPA owns the replica count.

---

## Upgrade Platform

Example: upgrading from Platform 1.0 to 1.1.

1. Keep using your own values file (`my-platform-production-values.yaml`) —
   do not recreate it from chart defaults.
2. Change only what needs to change for the new version, typically
   `image.tag`:

```yaml
image:
  tag: "1.1.0"
```

3. Run:

```bash
helm upgrade plaxion-platform charts/plaxion-platform \
  --namespace plaxion-platform \
  -f my-platform-production-values.yaml
```

What happens:

- The migration hook Job runs again (`pre-upgrade`) before the new
  Deployments roll out — see [Verify migrations](#verify-migrations).
- Existing Secrets, database contents, tenants, API keys, and telemetry data
  are untouched by a normal Helm upgrade — Helm only updates the Kubernetes
  resources it manages (Deployments, Services, Ingress/IngressRoute, the
  chart-managed connection-string Secret if used).
- The chart preserves an existing chart-managed database password/connection
  string across upgrades (via Helm `lookup`) as long as you don't explicitly
  set a new password in values.
- Ingress/IngressRoute/TLS settings you already configured remain in effect
  unless you explicitly change them.

Verify after upgrade the same way as after install: [Verify
workloads](#verify-workloads), [Verify migrations](#verify-migrations),
[Verify Dashboard/API](#verify-dashboardapi).

---

## Rollback

```bash
helm history plaxion-platform -n plaxion-platform
helm rollback plaxion-platform <REVISION> -n plaxion-platform
```

**`helm rollback` only reverts the Kubernetes resources Helm manages (images,
config, Ingress, etc.) — it does NOT reverse database migrations.** Schema
changes applied by the migration Job are forward-only. If you roll back to an
older application version after a schema change, the older binary may be
incompatible with the newer schema. Plan application rollback and database
schema changes as separate concerns; do not assume rollback restores the
database to its prior state.

---

## Uninstall

```bash
helm uninstall plaxion-platform -n plaxion-platform
```

What is removed:

- API/Ingestion Deployments and Services.
- Ingress / IngressRoute resources created by the chart.
- The chart-managed database/OTLP-headers Secret (`plaxion-platform-app`).
- The migration Job (subject to its hook delete policy).

What is **not** removed / survives:

- Any Secret you created yourself and referenced via `existingSecret` /
  `existingConnectionStringSecret` (e.g. `plaxion-platform-db`) — these are
  never managed or deleted by the chart.
- External PostgreSQL data — entirely untouched, since the chart never manages
  the external database itself.
- Bundled PostgreSQL PVCs — typically **retained** (Bitnami sub-chart
  default). Delete them manually if you want the data wiped (see [Optional
  bundled PostgreSQL](#optional-bundled-postgresql)).

---

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| Pods stuck in `ImagePullBackOff` | Missing/incorrect `imagePullSecrets`, or wrong image repository/tag | `kubectl describe pod <pod> -n plaxion-platform`; verify the GHCR Secret exists and is referenced in `imagePullSecrets` |
| Pods `CrashLoopBackOff` | Startup/config validation failure (e.g. missing `ROLE`, bad connection string) | `kubectl logs <pod> -n plaxion-platform --previous` |
| Migration Job failed | DB unreachable, wrong credentials, or migration error | `kubectl logs -n plaxion-platform job/plaxion-platform-migrate`; `kubectl describe job/plaxion-platform-migrate -n plaxion-platform` |
| Readiness probe failing (`/health/ready`) | Database unavailable, or migrations not yet applied | `kubectl exec -it <api-pod> -n plaxion-platform -- wget -qO- http://127.0.0.1:8080/health/ready`; check migration Job status |
| Dashboard opens but API calls fail | Wrong `platform.apiBaseUrl` for cross-origin setup, or `config.cors.allowedOrigins` missing the Dashboard's origin | Browser devtools network/console; verify `config.cors.allowedOrigins` includes the exact origin |
| OTLP telemetry not arriving | Wrong endpoint/DNS, TLS mismatch, or missing/incorrect API key header | `kubectl get ingress`/`ingressroute`; confirm `OTEL_EXPORTER_OTLP_ENDPOINT` and `Authorization` header |
| Ingress returns `404` | Wrong host/path, wrong `className`, or controller not installed | `kubectl describe ingress <name> -n plaxion-platform`; confirm the ingress controller is running |
| `IngressRoute` has no effect | Traefik CRDs/controller missing, or `ingress.enabled` and `ingressRoute.enabled` both true causing conflicts | `kubectl get crd ingressroutes.traefik.io`; `kubectl describe ingressroute <name> -n plaxion-platform` |
| `connection refused` to PostgreSQL | Network policy, DNS, firewall, or wrong Secret/host | `kubectl exec -it <api-pod> -n plaxion-platform -- getent hosts <DB_HOST>`; verify Secret contents and `database.external.*` values |

Useful general-purpose commands:

```bash
kubectl get all -n plaxion-platform
kubectl describe pod <pod> -n plaxion-platform
kubectl logs <pod> -n plaxion-platform
kubectl get events -n plaxion-platform --sort-by=.lastTimestamp
```

If a Helm hook (e.g. the migration Job) appears stuck between attempts:

```bash
kubectl get jobs -n plaxion-platform
kubectl delete job plaxion-platform-migrate -n plaxion-platform
helm upgrade plaxion-platform charts/plaxion-platform -n plaxion-platform -f my-platform-production-values.yaml
```

If you enabled `database.mode: bundled` and `helm dependency update` fails
offline, this is expected — the Bitnami PostgreSQL chart archive must be
fetched with network access at least once.

---

## Production checklist

- [ ] External PostgreSQL configured (`database.mode: external`)
- [ ] Database credentials stored in a Kubernetes Secret (`existingSecret` or `existingConnectionStringSecret`), not in plain values
- [ ] GHCR/registry credentials stored in a **separate** registry Secret (`imagePullSecrets`)
- [ ] Production image tag pinned (`image.tag` set to an explicit version, not empty/`latest`)
- [ ] TLS enabled for any externally exposed host, using an existing TLS Secret
- [ ] DNS configured for every externally exposed host (Dashboard/API and, if applicable, Ingestion)
- [ ] Ingestion exposure intentionally selected (internal-only, Ingress, IngressRoute, or LoadBalancer)
- [ ] CPU/memory `requests`/`limits` configured for `api` and `ingestion`
- [ ] Readiness/liveness probes verified after install (`/health`, `/health/ready`)
- [ ] Migration Job completed successfully (`COMPLETIONS 1/1`)
- [ ] Backup strategy exists for PostgreSQL (this chart does not back up your database)
- [ ] Your own values file (e.g. `my-platform-production-values.yaml`) is stored securely and version-controlled separately from the chart defaults
- [ ] Upgrade procedure understood, including that `helm rollback` does not reverse database migrations
