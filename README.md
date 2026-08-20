# plaxion-platform

Official **Helm chart** repository for [PlaxionMediator.Platform](https://github.com/plaxion/PlaxionMediator.Platform).

This repo packages the Platform runtime (API + Ingestion + embedded Angular dashboard + EF migrations) for Kubernetes. Application source code lives in the Platform repository; deployable Kubernetes manifests and values live here.

## 📘 Installation tutorial

**New to this chart? Start here → [docs/installation.md](docs/installation.md)**

A complete, beginner-friendly, step-by-step tutorial covering prerequisites,
GHCR/database Secrets, `values.yaml` configuration, installation, migrations,
verification, all three exposure scenarios (internal-only, standard Ingress,
Traefik `IngressRoute`), upgrade, rollback, uninstall, troubleshooting, and a
production checklist.

## 🔐 Authentication (OIDC)

Dashboard and `Platform.Api` are secured by **generic, standards-based OIDC**
(Authorization Code + PKCE) — the same identity provider you already run.
This chart never installs an identity provider; `Platform.Ingestion` (OTLP)
is unaffected and continues to use `X-Api-Key`.

- [docs/oidc-authentication.md](docs/oidc-authentication.md) — the generic contract, values reference, same-origin/CORS, troubleshooting
- [docs/oidc-keycloak.md](docs/oidc-keycloak.md) — Keycloak walkthrough
- [docs/oidc-identityserver.md](docs/oidc-identityserver.md) — IdentityServer/Duende walkthrough
- [docs/upgrade-to-oidc.md](docs/upgrade-to-oidc.md) — upgrading an existing pre-OIDC release without losing tenant access
- [docs/tenant-invitations-and-roles.md](docs/tenant-invitations-and-roles.md) — platform-level tenant-creation authorization vs tenant-level Owner/Member roles, and the multi-tenant email invitation flow

## Chart

See **[charts/plaxion-platform/README.md](charts/plaxion-platform/README.md)** for the condensed chart reference:

- Install / upgrade / uninstall
- External vs bundled PostgreSQL
- Migration Helm hook behavior and rollback caveats
- Ingress, Traefik IngressRoute, health probes, HPA
- Secrets and configuration reference

## Prerequisites

- Kubernetes 1.25+ cluster with `kubectl` configured
- Helm 3.10+
- Access to the `ghcr.io/plaxion/plaxion-platform` container image
- A PostgreSQL 14+ instance (external, recommended) or bundled PostgreSQL for evaluation
- An Ingress controller or Traefik CRDs only if exposing HTTP externally

See [docs/installation.md](docs/installation.md#before-you-begin) for details and verification commands.

## Chart compatibility

Chart version `0.3.0` · App version `0.3.0` · Kubernetes 1.25+ · Helm 3.10+.

> Chart `0.2.0` adds generic OIDC authentication (`authentication.*` values).
> Existing pre-`0.2.0` releases keep working after upgrade only if you follow
> [docs/upgrade-to-oidc.md](docs/upgrade-to-oidc.md) — Production installations
> now require either `authentication.enabled: true` (recommended) or the
> explicit, intentionally unsafe `authentication.allowAnonymousProduction: true`.
>
> Chart `0.3.0` documents Platform's multi-tenant email invitation model
> (`Owner`/`Member` tenant roles, `POST /v1/invitations`, JIT-claim on
> `GET /v1/tenants`) and adds the optional
> `authentication.authorization.invitations.emailClaimTypes` value — see
> [docs/tenant-invitations-and-roles.md](docs/tenant-invitations-and-roles.md).
> No breaking changes to existing `authentication.*` values.

## Quick start

```bash
helm upgrade --install plaxion charts/plaxion-platform \
  -n plaxion --create-namespace \
  -f examples/values-simple.yaml
```

For a production-oriented walkthrough, follow [docs/installation.md](docs/installation.md) instead of the quick start above.

## Examples

| File | Description |
|------|-------------|
| [`examples/values-simple.yaml`](examples/values-simple.yaml) | Minimal external Postgres, anonymous (Development) |
| [`examples/values-production.yaml`](examples/values-production.yaml) | Production Ingress + TLS + HPA + OIDC |
| [`examples/values-traefik.yaml`](examples/values-traefik.yaml) | Traefik IngressRoute + OIDC |
| [`examples/values-internal.yaml`](examples/values-internal.yaml) | ClusterIP-only / internal, explicit anonymous Production override |
| [`examples/values-oidc-production.yaml`](examples/values-oidc-production.yaml) | OIDC + external Postgres Secret + Ingress + internal Ingestion |
| [`examples/values-oidc-traefik.yaml`](examples/values-oidc-traefik.yaml) | OIDC + Traefik IngressRoute + optional public OTLP host |
| [`examples/values-oidc-keycloak.yaml`](examples/values-oidc-keycloak.yaml) | Keycloak-specific OIDC values only |
| [`examples/values-oidc-identityserver.yaml`](examples/values-oidc-identityserver.yaml) | IdentityServer/Duende-specific OIDC values only |

## CI

Pull requests run `helm lint` and `helm template` against each example values file (see [`.github/workflows/helm-ci.yml`](.github/workflows/helm-ci.yml)).

## Runtime contract (summary)

- Single image: `ghcr.io/<owner>/plaxion-platform:<tag>`
- `ROLE=api` | `ROLE=ingestion` (required)
- Migrations: same image, `ROLE=api`, args `--migrate`
- Listen port: **8080** (HTTP only; OTLP over HTTP, no gRPC port)
- Liveness: `/health` · Readiness: `/health/ready`
