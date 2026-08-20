# Using IdentityServer / Duende as the OIDC provider

This chart does **not** install IdentityServer — bring your own instance. The
Helm values differ from the Keycloak example
([`docs/oidc-keycloak.md`](oidc-keycloak.md)) **only** in normal OIDC
configuration, demonstrating that the chart is provider-neutral.

See [`examples/values-oidc-identityserver.yaml`](../examples/values-oidc-identityserver.yaml).

## 1. Define a public SPA client

In your IdentityServer/Duende `Config.cs` (or equivalent configuration store):

```csharp
new Client
{
    ClientId = "plaxion-platform-ui",
    ClientName = "Plaxion Platform Dashboard",
    RequireClientSecret = false,           // public client — Authorization Code + PKCE
    AllowedGrantTypes = GrantTypes.Code,
    RequirePkce = true,
    RedirectUris = { "https://platform.example.com/auth/callback" },
    PostLogoutRedirectUris = { "https://platform.example.com/" },
    AllowedCorsOrigins = { "https://platform.example.com" },
    AllowedScopes = { "openid", "profile", "email", "plaxion-platform" }
}
```

## 2. Define the API resource / audience

```csharp
new ApiResource("plaxion-platform", "Plaxion Platform API")
{
    Scopes = { "plaxion-platform" }
}
```

The issued access token's `aud` must equal `authentication.oidc.audience`
below (`plaxion-platform` in this example).

## 3. Roles/claims for tenant-creation authorization

Add a role or custom claim to the identity/access token via an
`IProfileService` implementation so `authentication.authorization.tenantCreation.mode`
can be `Role` (production recommendation) or `Claim` instead of
`AnyAuthenticatedUser` — see
[`docs/oidc-authentication.md`](oidc-authentication.md#tenant-creation-authorization).
This controls tenant **creation** only — it is unrelated to the
tenant-internal `Owner`/`Member` roles, which are Platform-owned and require
no IdentityServer role/claim (see
[`docs/tenant-invitations-and-roles.md`](tenant-invitations-and-roles.md)).

## 4. Configure the Helm values

```yaml
platform:
  publicBaseUrl: "https://platform.example.com"

authentication:
  enabled: true
  allowAnonymousProduction: false
  oidc:
    authority: "https://idp.example.com"
    audience: "plaxion-platform"
    requireHttpsMetadata: true
    dashboard:
      clientId: "plaxion-platform-ui"
      scopes: [openid, profile, email]
      redirectPath: /auth/callback
      postLogoutRedirectPath: /
  authorization:
    tenantCreation:
      # Production recommendation: Role.
      mode: Role
      requiredRole: "platform-tenant-admin"
      # Alternative: Claim mode via a custom IProfileService claim, e.g.
      #   mode: Claim
      #   requiredClaimType: "plaxion:tenant-creator"
```

## 5. Verify

Same procedure as the Keycloak tutorial: install/upgrade with this values
file, open the public Dashboard URL, confirm redirect to your IdentityServer
login page, authenticate, and confirm tenant access/creation behaves per your
configured policy.

## 6. Example: Alice creates a tenant, invites Bob

Alice's identity carries the `platform-tenant-admin` role (via the
`IProfileService` from step 3). Bob is a normal authenticated user with **no
special role** — Member never requires one.

1. Alice logs in and calls `POST /v1/tenants` — authorized by the `Role`
   policy above, the tenant is created, and Alice automatically becomes its
   `Owner`.
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

3. Bob authenticates via IdentityServer as usual (no role/claim setup needed
   for him). On his next `GET /v1/tenants`, Platform matches his token's
   email claim against the pending invitation and automatically creates a
   `Member` membership for him — see
   [`docs/tenant-invitations-and-roles.md`](tenant-invitations-and-roles.md)
   for the full flow.
