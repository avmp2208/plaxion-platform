# Upgrading a pre-OIDC Platform release

This guide is for operators running an **existing** `plaxion-platform` release
created before OIDC support was added to this chart (chart `< 0.2.0`), who now
want to enable `authentication.enabled: true`. It is production-safe and does
**not** require uninstall/reinstall.

Before OIDC, tenants had no owning identity (API-key/browser-local model).
After OIDC, every tenant is expected to have at least one
`TenantMembership` row linking an OIDC identity (issuer + subject) to that
tenant. Existing tenants created before this upgrade have **zero** membership
rows — without the bootstrap step below they would become inaccessible to
everyone once `Authentication:Enabled=true`.

Platform provides an explicit, auditable mechanism for this — it is **not** a
Helm-only invention:

- `Authorization:PlatformAdministrator` (`authentication.authorization.platformAdministrator`
  in Helm) designates a break-glass operator group.
- `POST /v1/tenants/{tenantId}/memberships` (guarded by the
  `PlatformAdministrator` policy) lets that operator explicitly grant an OIDC
  identity ownership of any existing tenant, including legacy ones.

## Step-by-step

### 1. Prerequisites

- An OIDC provider/client already prepared (see
  [`docs/oidc-authentication.md`](oidc-authentication.md) /
  [`docs/oidc-keycloak.md`](oidc-keycloak.md) /
  [`docs/oidc-identityserver.md`](oidc-identityserver.md)).
- Know the identity (issuer + subject, i.e. `iss`/`sub` claims from your OIDC
  provider) of the operator(s) who will reconcile legacy tenants — or plan to
  self-grant by calling the endpoint while logged in as that operator.
- A tightly scoped IdP role or claim reserved for platform administrators
  (e.g. Keycloak realm role `plaxion-platform-bootstrap`), used **only**
  during this upgrade window.

### 2. First upgrade: enable OIDC + a temporary PlatformAdministrator

```yaml
authentication:
  enabled: true
  allowAnonymousProduction: false
  oidc:
    authority: "https://sso.example.com/realms/company"
    audience: "plaxion-platform"
    dashboard:
      clientId: "plaxion-platform-ui"
  authorization:
    tenantCreation:
      # Production recommendation: Role (see docs/oidc-authentication.md).
      mode: Role
      requiredRole: "platform-tenant-admin"
    # Temporary — revoke after reconciliation (step 5). This is a break-glass
    # mechanism only; it is never used for normal day-to-day membership
    # management.
    platformAdministrator:
      mode: Role
      requiredRole: "plaxion-platform-bootstrap"
```

```bash
helm upgrade plaxion-platform charts/plaxion-platform \
  -n plaxion-platform \
  -f my-existing-values.yaml \
  -f my-oidc-bootstrap-values.yaml
```

The existing migration Job/hook runs first, as always — no separate
OIDC-specific migration process exists; any tenant-membership schema changes
are applied through the same `pre-install`/`pre-upgrade` mechanism already
used for every other schema change.

### 3. First authenticated login

Open the Dashboard, log in via your OIDC provider as the operator who has the
`plaxion-platform-bootstrap` role/claim.

### 4. Reconcile each legacy tenant

For every pre-existing tenant, grant an owning membership (self-grant using
the caller's own identity, or an explicit issuer/subject):

```bash
curl -X POST https://platform.example.com/v1/tenants/<tenantId>/memberships \
  -H "Authorization: Bearer <bootstrap operator's access token>" \
  -H "Content-Type: application/json" \
  -d '{}'
```

Repeat for each tenant that must remain accessible. You may instead target a
specific end-user identity by supplying `identityIssuer`/`identitySubject`
explicitly in the body, granting that user ownership directly instead of the
bootstrap operator.

### 5. Revoke bootstrap access

Once every tenant has been reconciled (each legacy tenant now has an `Owner`
membership), set `platformAdministrator` back to `Disabled` and upgrade
again. From this point on, **all future onboarding uses Owner-issued
invitations** (`POST /v1/invitations`) — see
[`docs/tenant-invitations-and-roles.md`](tenant-invitations-and-roles.md) —
not `PlatformAdministrator`. `PlatformAdministrator` should only ever be
re-enabled again for a similar future break-glass/reconciliation need, never
for routine membership management:

```yaml
authentication:
  authorization:
    platformAdministrator:
      mode: Disabled
```

```bash
helm upgrade plaxion-platform charts/plaxion-platform \
  -n plaxion-platform \
  -f my-existing-values.yaml \
  -f my-oidc-final-values.yaml
```

### 6. Verify

- Existing tenants are reachable and show their historical data.
- Existing telemetry API keys still work (`Platform.Ingestion` is unaffected
  by this entire procedure).
- New logins for reconciled users succeed and can access their tenant(s).
- Unreconciled/unauthorized users correctly receive `403`/`404` on tenants
  they were not granted membership to.

## Do not

- Do not invent a Helm-only ownership/ownership-transfer mechanism — always
  use the `PlatformAdministrator` policy + membership endpoint above.
- Do not leave `PlatformAdministrator` enabled longer than the reconciliation
  window.
- Do not skip step 2 and jump straight to `authentication.enabled: true` with
  `platformAdministrator.mode: Disabled` — you would have no way to grant
  legacy tenants ownership afterwards without direct database access.
- Do not use `PlatformAdministrator` for ongoing/day-to-day tenant
  membership management once reconciliation is complete — use Owner-issued
  invitations (`POST /v1/invitations`) instead; see
  [`docs/tenant-invitations-and-roles.md`](tenant-invitations-and-roles.md).
