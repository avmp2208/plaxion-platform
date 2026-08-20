# OIDC Authentication (generic)

Platform implements a **generic, standards-based OIDC** authentication model for
human-facing surfaces (Dashboard + `Platform.Api`). This chart only *exposes*
that existing contract — it does not implement or invent any authentication
behavior, and it never installs an identity provider.

```
Human access:  Dashboard / Platform.Api  ->  OIDC (Authorization Code + PKCE)
Telemetry:     OTLP        / Platform.Ingestion -> X-Api-Key
```

These two credential types are independent. Ingestion authentication is never
affected by anything in this document.

## The actual Platform configuration contract

Platform binds the following configuration sections at startup
(`Platform.Hosting.Configuration.PlatformOptions`):

| Section | Setting | Helm value |
|---|---|---|
| `Authentication` | `Enabled` | `authentication.enabled` |
| `Authentication` | `Authority` | `authentication.oidc.authority` |
| `Authentication` | `Audience` | `authentication.oidc.audience` |
| `Authentication` | `RequireHttpsMetadata` (default `true`) | `authentication.oidc.requireHttpsMetadata` |
| `Authentication` | `AllowAnonymousProduction` | `authentication.allowAnonymousProduction` |
| `Dashboard:Oidc` | `ClientId` | `authentication.oidc.dashboard.clientId` |
| `Dashboard:Oidc` | `Scopes` (default `openid,profile,email`) | `authentication.oidc.dashboard.scopes` |
| `Dashboard:Oidc` | `RedirectPath` (default `/auth/callback`) | `authentication.oidc.dashboard.redirectPath` |
| `Dashboard:Oidc` | `PostLogoutRedirectPath` (default `/`) | `authentication.oidc.dashboard.postLogoutRedirectPath` |
| `Authorization:TenantCreation` | `Mode` / `RequiredRole` / `RequiredClaimType` / `RequiredClaimValues` | `authentication.authorization.tenantCreation.*` |
| `Authorization:PlatformAdministrator` | `Mode` / `RequiredRole` / `RequiredClaimType` / `RequiredClaimValues` | `authentication.authorization.platformAdministrator.*` |
| `Platform` | `PublicBaseUrl` | `platform.publicBaseUrl` |
| `Cors` | `AllowedOrigins` | `config.cors.allowedOrigins` |

Platform's own startup validation (`AuthenticationOptionsValidator`) already
requires `Authority`/`Audience` when `Enabled=true`, and `Program.cs` fails
fast in Production when `Enabled=false` unless `AllowAnonymousProduction=true`.
The chart adds Helm-time checks (`values.schema.json` + a `fail`-based template
guard) that catch the same obvious misconfigurations *before* a pod is even
scheduled — see [Troubleshooting](#troubleshooting).

## Public configuration vs secrets

The Angular Dashboard is a **public OIDC client** using Authorization Code +
PKCE — it has **no client secret**. `Authority`, `Audience`, `ClientId`,
scopes, and redirect paths are non-sensitive and are:

- rendered as plain (non-Secret) environment variables on the API container,
- surfaced to the browser via `GET /v1/platform/config` / `wwwroot/assets/config.json`.

They are **not** placed in a Kubernetes `Secret`. Actual secrets (database
credentials, registry credentials) continue to live in their own
purpose-specific Secrets — see [Secret separation](#secret-separation).

## Same-origin Dashboard + API

There is **no separate Dashboard Deployment**: the Angular SPA is served by
the same `api` container/Service as `Platform.Api`. As long as you expose the
`api` Service through a single Ingress/IngressRoute host (`platform.example.com`),
Dashboard and API share one browser-visible origin automatically —
`platform.apiBaseUrl` can stay empty and `config.cors.allowedOrigins` can stay
empty (no cross-origin requests to allow).

If you deploy Dashboard and API behind **different** external hostnames, set
`platform.apiBaseUrl` to the API's public URL and add that Dashboard origin to
`config.cors.allowedOrigins` so the browser's CORS preflight succeeds. Platform
never enables wildcard CORS for authenticated traffic — you must list origins
explicitly.

A browser can never reach `*.svc.cluster.local` / `ClusterIP` addresses. Do not
configure `platform.apiBaseUrl` with an internal Service DNS name if the
Dashboard will be opened from outside the cluster.

## Redirect URI coordination

`platform.publicBaseUrl` drives the URLs you must register with your OIDC
provider:

- Redirect URI: `<platform.publicBaseUrl><authentication.oidc.dashboard.redirectPath>`
  (default: `https://platform.example.com/auth/callback`)
- Post-logout redirect URI: `<platform.publicBaseUrl><authentication.oidc.dashboard.postLogoutRedirectPath>`
  (default: `https://platform.example.com/`)

Set `platform.publicBaseUrl` once and reuse it — do not hardcode `localhost`
or a ClusterIP hostname in Production.

## Tenant-creation authorization

`POST /v1/tenants` (self-service tenant bootstrap) is governed by
`authentication.authorization.tenantCreation.mode`:

```yaml
authentication:
  authorization:
    tenantCreation:
      mode: AnyAuthenticatedUser   # any authenticated OIDC user may create a tenant
      # mode: Role
      # requiredRole: plaxion-platform-admin
      # mode: Claim
      # requiredClaimType: plaxion:tenant-creator
      # requiredClaimValues: []    # empty = presence of the claim type alone is enough
```

These claim/role checks are provider-neutral — the chart never encodes
Keycloak-, Entra-, or Okta-specific claim shapes.

## Existing-tenant upgrade / bootstrap

See [`docs/upgrade-to-oidc.md`](upgrade-to-oidc.md) for the full pre-OIDC
upgrade procedure, which relies on
`authentication.authorization.platformAdministrator.*` and the explicit
`POST /v1/tenants/{tenantId}/memberships` reconciliation endpoint.

## Ingress / IngressRoute / TLS

Both the generic Kubernetes `Ingress` (`api.ingress.*`) and Traefik
`IngressRoute` (`api.ingressRoute.*`) blocks already support `className`,
`annotations`, `hosts`/routes, `tls`/existing TLS Secret, and (for Traefik)
`middlewares`/`entryPoints`. Nothing OIDC-specific needed to change here —
point either one at the same host that serves both Dashboard and API. Neither
nginx nor Traefik is installed by this chart.

## Ingestion stays independent

`ingestion.*` exposure (`ClusterIP` by default, optional `Ingress`,
`IngressRoute`, or `LoadBalancer`) is completely independent of
`authentication.*`. Enabling OIDC never forces Ingestion to be externally
exposed, and Ingestion never gains OIDC login — it continues to authenticate
callers via `X-Api-Key` only.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Dashboard redirects repeatedly / loops back to login | Redirect URI registered at the OIDC provider does not exactly match `<publicBaseUrl><redirectPath>` |
| OIDC discovery fails at startup | `authentication.oidc.authority` unreachable, wrong scheme, or TLS/CA issue between the cluster and the IdP |
| `401` from `Platform.Api` after login | `audience`/`authority` mismatch between the issued token and `authentication.oidc.audience`/`authority` |
| `403`/`404` on tenant access | Caller has no `TenantMembership` for that tenant — see the upgrade/bootstrap guide |
| Login succeeds but Dashboard cannot reach the API | `platform.apiBaseUrl` points at a ClusterIP/internal hostname unreachable from the browser |
| API URL is `*.svc.cluster.local` | Invalid for any external-browser topology — use the same public origin or a separate public API hostname |
| Keycloak-issued token rejected | Missing/incorrect audience mapper, or `authority` doesn't match the realm issuer exactly (trailing slash matters) |
| `Platform.Ingestion` returns `401` | Unrelated to OIDC — check the `X-Api-Key` used by the telemetry exporter, not user login |
| Metrics never arrive in the Dashboard | Check Ingestion networking/API key, not authentication — the two are independent |

## Secret separation

| Secret | Contents |
|---|---|
| Registry Secret (`imagePullSecrets`) | GHCR credentials only |
| Database Secret (`database.external.existing*Secret`) | PostgreSQL connection string/password only |
| — none — | The SPA's `Authority`/`ClientId`/scopes are public and are **not** stored as a Secret |

Never combine unrelated credentials into one Secret.
