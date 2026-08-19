# plaxion-platform

Official **Helm chart** repository for [PlaxionMediator.Platform](https://github.com/plaxion/PlaxionMediator.Platform).

This repo packages the Platform runtime (API + Ingestion + embedded Angular dashboard + EF migrations) for Kubernetes. Application source code lives in the Platform repository; deployable Kubernetes manifests and values live here.

## Chart

See **[charts/plaxion-platform/README.md](charts/plaxion-platform/README.md)** for full documentation:

- Install / upgrade / uninstall
- External vs bundled PostgreSQL
- Migration Helm hook behavior and rollback caveats
- Ingress, Traefik IngressRoute, health probes, HPA
- Secrets and configuration reference

## Quick start

```bash
helm upgrade --install plaxion charts/plaxion-platform \
  -n plaxion --create-namespace \
  -f examples/values-simple.yaml
```

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
