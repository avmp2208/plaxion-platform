# Using Keycloak as the OIDC provider

This chart does **not** install Keycloak — it consumes an existing,
standards-compliant OIDC provider. This tutorial maps an existing Keycloak
realm/client to Platform's actual OIDC contract. If you do not already run
Keycloak, install/operate it separately (outside this chart).

See [`examples/values-oidc-keycloak.yaml`](../examples/values-oidc-keycloak.yaml)
for the values-only diff, and [`docs/oidc-authentication.md`](oidc-authentication.md)
for the full generic contract.

## 1. Create a public SPA client in Keycloak

In your Keycloak realm (e.g. `plaxion`), create a new client:

| Keycloak field | Value |
|---|---|
| Client ID | `plaxion-platform-ui` |
| Client authentication | **Off** (public client — no client secret) |
| Standard flow (Authorization Code) | **On** |
| Direct access grants | Off (not needed) |
| Valid redirect URIs | `https://platform.example.com/auth/callback` |
| Valid post logout redirect URIs | `https://platform.example.com/` |
| Web origins | `https://platform.example.com` |

PKCE is enforced automatically by the Angular SPA client library for public
clients using Authorization Code — no extra Keycloak flag is required beyond
"Standard flow" + "Client authentication: Off".

## 2. Ensure the access token has the expected audience

Platform validates the JWT `aud` claim against `authentication.oidc.audience`.
Keycloak does not include a custom audience by default — add a client scope
with an **Audience** mapper (Client scopes → create scope → Mapper: Audience)
that sets `aud` to your chosen value (e.g. `plaxion-platform`), then assign
that client scope to `plaxion-platform-ui`.

## 3. Roles/claims for tenant-creation authorization

Production recommendation is `authentication.authorization.tenantCreation.mode: Role`
(rather than `AnyAuthenticatedUser`), so only intentionally-designated users
can create tenants:

- **Role mode**: create a realm role (e.g. `platform-tenant-admin`), assign it
  to the users who may create tenants, and ensure it is included in the token
  (`realm_access.roles` — Platform reads standard role claims).
- **Claim mode**: add a protocol mapper that emits a custom claim
  (e.g. `plaxion:tenant-creator`) with whatever values you choose.

This role/claim controls tenant **creation** only. It has nothing to do with
the tenant-internal `Owner`/`Member` roles described below — those are
Platform-owned and require no Keycloak role at all.

## 4. Configure the Helm values

```yaml
platform:
  publicBaseUrl: "https://platform.example.com"

authentication:
  enabled: true
  allowAnonymousProduction: false
  oidc:
    authority: "https://keycloak.example.com/realms/plaxion"
    audience: "plaxion-platform"
    requireHttpsMetadata: true
    dashboard:
      clientId: "plaxion-platform-ui"
      scopes: [openid, profile, email]
      redirectPath: /auth/callback
      postLogoutRedirectPath: /
  authorization:
    tenantCreation:
      mode: Role
      requiredRole: "platform-tenant-admin"
```

`authority` must exactly match the realm issuer Keycloak reports at
`https://keycloak.example.com/realms/plaxion/.well-known/openid-configuration`
(`issuer` field) — trailing slashes matter.

## 5. Verify

1. `helm upgrade --install ... -f your-values.yaml -f examples/values-oidc-keycloak.yaml`
2. Open `https://platform.example.com` — you should be redirected to Keycloak's
   login page.
3. Log in — you should land back on the Dashboard, authenticated.
4. Create a tenant (subject to your `tenantCreation` policy).

If login loops or fails, see the Troubleshooting table in
[`docs/oidc-authentication.md`](oidc-authentication.md#troubleshooting) —
common Keycloak-specific causes are a redirect URI mismatch or a missing
audience mapper.

## 6. Example: Alice creates a tenant, invites Bob

Alice has the Keycloak realm role `platform-tenant-admin` (assigned in step 3).
Bob is a normal authenticated user with **no special Keycloak role** —
Member never requires one.

1. Alice logs in and calls `POST /v1/tenants` — she is authorized by the
   `Role` policy above, the tenant is created, and Alice automatically
   becomes its `Owner`.
2. Alice invites Bob into that tenant:

   ```bash
   curl -X POST https://platform.example.com/v1/invitations \
     -H "Authorization: Bearer <alice's access token>" \
     -H "Content-Type: application/json" \
     -d '{
       "email": "bob@example.com",
       "tenantIds": ["<tenant-a-id>"]
     }'
   ```

3. Bob authenticates via Keycloak as usual (no role/claim setup needed for
   him). On his next `GET /v1/tenants`, Platform matches his token's email
   claim against the pending invitation and automatically creates a `Member`
   membership for him — see
   [`docs/tenant-invitations-and-roles.md`](tenant-invitations-and-roles.md)
   for the full flow.
