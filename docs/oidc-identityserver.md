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

## 3. (Optional) roles/claims for tenant-creation authorization

Add a role or custom claim to the identity/access token via a
`IProfileService` implementation if you want
`authentication.authorization.tenantCreation.mode: Role` or `Claim` instead of
the default `AnyAuthenticatedUser` — see
[`docs/oidc-authentication.md`](oidc-authentication.md#tenant-creation-authorization).

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
      mode: Claim
      requiredClaimType: "plaxion:tenant-creator"
```

## 5. Verify

Same procedure as the Keycloak tutorial: install/upgrade with this values
file, open the public Dashboard URL, confirm redirect to your IdentityServer
login page, authenticate, and confirm tenant access/creation behaves per your
configured policy.
