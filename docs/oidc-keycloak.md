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

## 3. (Optional) roles/claims for tenant-creation authorization

Only needed if you want `authentication.authorization.tenantCreation.mode` to
be `Role` or `Claim` instead of the default `AnyAuthenticatedUser`:

- **Role mode**: create a realm role (e.g. `plaxion-platform-admin`), assign it
  to the users who may create tenants, and ensure it is included in the token
  (`realm_access.roles` — Platform reads standard role claims).
- **Claim mode**: add a protocol mapper that emits a custom claim
  (e.g. `plaxion:tenant-creator`) with whatever values you choose.

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
      requiredRole: "plaxion-platform-admin"
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
