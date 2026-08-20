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

Chart version `0.1.0` · App version `0.1.0` · Kubernetes 1.25+ · Helm 3.10+.

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
| [`examples/values-simple.yaml`](examples/values-simple.yaml) | Minimal external Postgres |
| [`examples/values-production.yaml`](examples/values-production.yaml) | Production Ingress + TLS + HPA |
| [`examples/values-traefik.yaml`](examples/values-traefik.yaml) | Traefik IngressRoute |
| [`examples/values-internal.yaml`](examples/values-internal.yaml) | ClusterIP-only / internal |

## CI

Pull requests run `helm lint` and `helm template` against each example values file (see [`.github/workflows/helm-ci.yml`](.github/workflows/helm-ci.yml)).

## Runtime contract (summary)

- Single image: `ghcr.io/<owner>/plaxion-platform:<tag>`
- `ROLE=api` | `ROLE=ingestion` (required)
- Migrations: same image, `ROLE=api`, args `--migrate`
- Listen port: **8080** (HTTP only; OTLP over HTTP, no gRPC port)
- Liveness: `/health` · Readiness: `/health/ready`
