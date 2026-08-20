# Tenant invitations and roles

Platform separates authorization into **two independent domains**. Understanding
this split is essential before configuring `authentication.authorization.*` in
this chart.

## 1. Platform-level: who may create a tenant

`Authorization:TenantCreation` (`authentication.authorization.tenantCreation` in
Helm) is an **OIDC role/claim check** evaluated on `POST /v1/tenants`. It
answers: "is this authenticated principal allowed to create a brand-new
tenant?" See [`docs/oidc-authentication.md`](oidc-authentication.md#tenant-creation-authorization)
for the Helm configuration; production deployments should use
`mode: Role` with a dedicated IdP role (e.g. `platform-tenant-admin`) rather
than `AnyAuthenticatedUser`.

## 2. Tenant-level: Owner and Member

Once a tenant exists, access **within** that tenant is governed by
`TenantMembership` rows, which carry one of two Platform-internal roles:

- **`Owner`** — automatically granted to whoever successfully calls
  `POST /v1/tenants` and creates the tenant. Owners may invite other users
  into the tenant (see below).
- **`Member`** — granted automatically when an invited user's login is
  JIT-claimed (see the flow below).

`Owner` and `Member` are **not** OIDC roles or claims. They are stored and
enforced entirely by Platform itself. No IdP configuration, role mapping, or
Helm value is needed for a user to become a `Member` — the only requirement
is that their OIDC identity's email matches a pending invitation.

This separation is intentional: it lets Platform add future fine-grained,
tenant-scoped permissions (e.g. SLO management, alert configuration, API key
management, tenant administration) purely as internal authorization logic on
top of `Owner`/`Member`, without ever requiring new Helm/IdP configuration.

## The invitation flow (multi-tenant, JIT-claimed)

1. An `Owner` of one or more tenants calls:

   ```bash
   curl -X POST https://platform.example.com/v1/invitations \
     -H "Authorization: Bearer <owner's access token>" \
     -H "Content-Type: application/json" \
     -d '{
       "email": "bob@example.com",
       "tenantIds": ["<tenant-a-id>", "<tenant-b-id>"]
     }'
   ```

   This is **Owner-only** and **atomic, all-or-nothing** across the supplied
   `tenantIds`: either a `TenantInvitation` row (state `Pending`) is created
   for every listed tenant, or none are created. Uniqueness is enforced on
   `(TenantId, NormalizedEmail)` for `Pending` invitations — you cannot create
   a second pending invitation for the same email on the same tenant.

2. **No invitation email is sent.** Platform has no email delivery mechanism
   for invitations — communicating the invite to the invitee (email, chat,
   ticket, etc.) is the Owner's/operator's responsibility outside Platform.

3. **No manual acceptance step exists.** The invitee simply authenticates
   through the normal OIDC login flow.

4. On the invitee's next `GET /v1/tenants` call, Platform validates the
   token's `iss`/`sub` and extracts an email using the first non-empty claim
   found among `authentication.authorization.invitations.emailClaimTypes`
   (defaults: `email`, `emails`, `preferred_username`, and the legacy XML SOAP
   `emailaddress` claim). Platform then automatically claims **all** matching
   `Pending` invitations for that email into `Member` `TenantMembership` rows,
   across every tenant they were invited to. This is the **JIT (just-in-time)
   claim**.

5. The invitee's `GET /v1/tenants` response now includes every tenant where
   they hold a membership (as `Owner` or `Member`).

No polling, background job, or separate "accept invite" endpoint is involved
— the claim happens inline during the invitee's first `GET /v1/tenants` call
after login.

## Configuring the email claim types

```yaml
authentication:
  authorization:
    invitations:
      # Leave empty to use Platform's built-in defaults (email, emails,
      # preferred_username, and the legacy XML SOAP emailaddress claim).
      emailClaimTypes: []
      # Example override for an IdP that only issues a custom claim:
      # emailClaimTypes:
      #   - email
      #   - upn
```

## Summary of what Member does NOT require

- No OIDC role or claim.
- No IdP group membership.
- No manual invitation acceptance.
- No invitation email delivery.
- No per-tenant limit — a single `POST /v1/invitations` call can target
  multiple tenants at once.

See [`docs/oidc-authentication.md`](oidc-authentication.md) for the
platform-level `TenantCreation` policy, and
[`docs/upgrade-to-oidc.md`](upgrade-to-oidc.md) for how legacy (pre-OIDC)
tenants establish their first `Owner` via the break-glass
`PlatformAdministrator` mechanism before switching to Owner-issued
invitations for all further onboarding.
