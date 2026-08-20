{{/*
Expand the name of the chart.
*/}}
{{- define "plaxion-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "plaxion-platform.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "plaxion-platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "plaxion-platform.labels" -}}
helm.sh/chart: {{ include "plaxion-platform.chart" . }}
{{ include "plaxion-platform.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "plaxion-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "plaxion-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
API selector labels
*/}}
{{- define "plaxion-platform.api.selectorLabels" -}}
{{ include "plaxion-platform.selectorLabels" . }}
app.kubernetes.io/component: api
{{- end }}

{{/*
Ingestion selector labels
*/}}
{{- define "plaxion-platform.ingestion.selectorLabels" -}}
{{ include "plaxion-platform.selectorLabels" . }}
app.kubernetes.io/component: ingestion
{{- end }}

{{/*
Migration selector labels
*/}}
{{- define "plaxion-platform.migration.selectorLabels" -}}
{{ include "plaxion-platform.selectorLabels" . }}
app.kubernetes.io/component: migration
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "plaxion-platform.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "plaxion-platform.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference (registry/repository:tag)
*/}}
{{- define "plaxion-platform.image" -}}
{{- $registry := .Values.image.registry | default .Values.global.imageRegistry | default "" }}
{{- $repository := .Values.image.repository }}
{{- $tag := .Values.image.tag | default .Chart.AppVersion }}
{{- if $registry }}
{{- printf "%s/%s:%s" $registry $repository $tag }}
{{- else }}
{{- printf "%s:%s" $repository $tag }}
{{- end }}
{{- end }}

{{/*
Image pull secrets (global + local). Supports string names or {name: ...} maps.
*/}}
{{- define "plaxion-platform.imagePullSecrets" -}}
{{- $secrets := list }}
{{- range .Values.global.imagePullSecrets }}
{{- $secrets = append $secrets . }}
{{- end }}
{{- range .Values.imagePullSecrets }}
{{- $secrets = append $secrets . }}
{{- end }}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  {{- if kindIs "string" . }}
  - name: {{ . }}
  {{- else if .name }}
  - name: {{ .name }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart-managed secret name (DB connection string + optional otlp headers)
*/}}
{{- define "plaxion-platform.secretName" -}}
{{- printf "%s-app" (include "plaxion-platform.fullname" .) }}
{{- end }}

{{/*
Whether the chart should create its managed Secret.
Skip when a full connection-string secret is already provided AND no chart-managed otlp headers are needed.
*/}}
{{- define "plaxion-platform.createSecret" -}}
{{- $hasExistingCS := and .Values.database.external.existingConnectionStringSecret .Values.database.external.existingConnectionStringSecret.name -}}
{{- $needsOtlp := and .Values.secrets.observability.otlpHeaders (not (and .Values.secrets.observability.existingSecret .Values.secrets.observability.existingSecret.name)) -}}
{{- $needsDbSecret := not $hasExistingCS -}}
{{- if or $needsDbSecret $needsOtlp -}}
true
{{- end -}}
{{- end }}

{{/*
Bundled PostgreSQL service hostname (Bitnami subchart)
*/}}
{{- define "plaxion-platform.postgresql.hostname" -}}
{{- printf "%s-postgresql" .Release.Name -}}
{{- end }}

{{/*
Resolve database host
*/}}
{{- define "plaxion-platform.databaseHost" -}}
{{- if eq .Values.database.mode "bundled" -}}
{{- include "plaxion-platform.postgresql.hostname" . -}}
{{- else -}}
{{- .Values.database.external.host -}}
{{- end -}}
{{- end }}

{{/*
Resolve database port
*/}}
{{- define "plaxion-platform.databasePort" -}}
{{- if eq .Values.database.mode "bundled" -}}
5432
{{- else -}}
{{- .Values.database.external.port | default 5432 -}}
{{- end -}}
{{- end }}

{{/*
Resolve database name
*/}}
{{- define "plaxion-platform.databaseName" -}}
{{- if eq .Values.database.mode "bundled" -}}
{{- .Values.postgresql.auth.database | default "plaxion" -}}
{{- else -}}
{{- .Values.database.external.database -}}
{{- end -}}
{{- end }}

{{/*
Resolve database username
*/}}
{{- define "plaxion-platform.databaseUsername" -}}
{{- if eq .Values.database.mode "bundled" -}}
{{- .Values.postgresql.auth.username | default "plaxion" -}}
{{- else -}}
{{- .Values.database.external.username -}}
{{- end -}}
{{- end }}

{{/*
Resolve database password for chart-managed connection string.
Uses lookup to preserve existing generated secrets across upgrades.
*/}}
{{- define "plaxion-platform.databasePassword" -}}
{{- $password := "" }}
{{- if eq .Values.database.mode "bundled" }}
  {{- $password = .Values.postgresql.auth.password | default "" }}
  {{- if not $password }}
    {{- $secName := include "plaxion-platform.secretName" . }}
    {{- $existing := lookup "v1" "Secret" .Release.Namespace $secName }}
    {{- if and $existing $existing.data (index $existing.data "password") }}
      {{- $password = index $existing.data "password" | b64dec }}
    {{- else }}
      {{- /* Also try Bitnami postgresql secret if already present */ -}}
      {{- $pgSecretName := printf "%s-postgresql" .Release.Name }}
      {{- $pgSecret := lookup "v1" "Secret" .Release.Namespace $pgSecretName }}
      {{- if and $pgSecret $pgSecret.data }}
        {{- if index $pgSecret.data "password" }}
          {{- $password = index $pgSecret.data "password" | b64dec }}
        {{- else if index $pgSecret.data "postgres-password" }}
          {{- $password = index $pgSecret.data "postgres-password" | b64dec }}
        {{- end }}
      {{- end }}
    {{- end }}
  {{- end }}
  {{- if not $password }}
    {{- $password = randAlphaNum 24 }}
  {{- end }}
{{- else }}
  {{- /* external mode */ -}}
  {{- if and .Values.database.external.existingSecret .Values.database.external.existingSecret.name }}
    {{- $sec := lookup "v1" "Secret" .Release.Namespace .Values.database.external.existingSecret.name }}
    {{- $key := .Values.database.external.existingSecret.passwordKey | default "password" }}
    {{- if and $sec $sec.data (index $sec.data $key) }}
      {{- $password = index $sec.data $key | b64dec }}
    {{- else }}
      {{- $password = .Values.database.external.password | default "" }}
    {{- end }}
  {{- else }}
    {{- $password = .Values.database.external.password | default "" }}
    {{- if not $password }}
      {{- $secName := include "plaxion-platform.secretName" . }}
      {{- $existing := lookup "v1" "Secret" .Release.Namespace $secName }}
      {{- if and $existing $existing.data (index $existing.data "password") }}
        {{- $password = index $existing.data "password" | b64dec }}
      {{- else }}
        {{- $password = randAlphaNum 24 }}
      {{- end }}
    {{- else }}
      {{- /* Prefer preserving existing password if values password empty was intentional;
           when password is explicitly set in values, use it (allows rotation). */ -}}
    {{- end }}
  {{- end }}
{{- end }}
{{- $password -}}
{{- end }}

{{/*
Build Npgsql connection string (non-secret rendering helper for secret.yaml)
*/}}
{{- define "plaxion-platform.databaseConnectionString" -}}
{{- $host := include "plaxion-platform.databaseHost" . -}}
{{- $port := include "plaxion-platform.databasePort" . -}}
{{- $db := include "plaxion-platform.databaseName" . -}}
{{- $user := include "plaxion-platform.databaseUsername" . -}}
{{- $password := include "plaxion-platform.databasePassword" . -}}
{{- printf "Host=%s;Port=%s;Database=%s;Username=%s;Password=%s" $host $port $db $user $password -}}
{{- end }}

{{/*
Secret name that holds ConnectionStrings__Platform
*/}}
{{- define "plaxion-platform.connectionStringSecretName" -}}
{{- if and .Values.database.external.existingConnectionStringSecret .Values.database.external.existingConnectionStringSecret.name -}}
{{- .Values.database.external.existingConnectionStringSecret.name -}}
{{- else -}}
{{- include "plaxion-platform.secretName" . -}}
{{- end -}}
{{- end }}

{{/*
Secret key for ConnectionStrings__Platform
*/}}
{{- define "plaxion-platform.connectionStringSecretKey" -}}
{{- if and .Values.database.external.existingConnectionStringSecret .Values.database.external.existingConnectionStringSecret.name -}}
{{- .Values.database.external.existingConnectionStringSecret.key | default "connection-string" -}}
{{- else -}}
connection-string
{{- end -}}
{{- end }}

{{/*
Common non-sensitive environment variables shared by api/ingestion/migration
*/}}
{{- define "plaxion-platform.commonEnv" -}}
- name: ASPNETCORE_URLS
  value: {{ .Values.aspnetcore.urls | default "http://+:8080" | quote }}
- name: ASPNETCORE_ENVIRONMENT
  value: {{ .Values.aspnetcore.environment | default "Production" | quote }}
- name: AllowedHosts
  value: {{ .Values.config.allowedHosts | default "*" | quote }}
- name: Storage__Provider
  value: {{ .Values.config.storage.provider | default .Values.database.provider | default "PostgreSql" | quote }}
- name: Database__AutoMigrate
  value: {{ .Values.config.database.autoMigrate | default false | toString | quote }}
- name: Database__FailOnPendingMigrations
  value: {{ .Values.config.database.failOnPendingMigrations | default true | toString | quote }}
- name: Aggregation__Interval
  value: {{ .Values.config.aggregation.interval | default "00:01:00" | quote }}
- name: Aggregation__BucketSize
  value: {{ .Values.config.aggregation.bucketSize | default "00:01:00" | quote }}
- name: Retention__RawSampleRetention
  value: {{ .Values.config.retention.rawSampleRetention | default "7.00:00:00" | quote }}
- name: Retention__CheckInterval
  value: {{ .Values.config.retention.checkInterval | default "00:05:00" | quote }}
- name: Ingestion__MaxRequestSizeBytes
  value: {{ .Values.config.ingestion.maxRequestSizeBytes | default 1048576 | int | toString | quote }}
- name: Ingestion__MaxSamplesPerRequest
  value: {{ .Values.config.ingestion.maxSamplesPerRequest | default 5000 | int | toString | quote }}
- name: Ingestion__MaxMetricNamesPerRequest
  value: {{ .Values.config.ingestion.maxMetricNamesPerRequest | default 200 | int | toString | quote }}
- name: ConnectionStrings__Platform
  valueFrom:
    secretKeyRef:
      name: {{ include "plaxion-platform.connectionStringSecretName" . }}
      key: {{ include "plaxion-platform.connectionStringSecretKey" . }}
{{- if .Values.platform.publicBaseUrl }}
- name: Platform__PublicBaseUrl
  value: {{ .Values.platform.publicBaseUrl | quote }}
{{- end }}
{{- $platEnv := .Values.platform.environment | default "" }}
{{- if $platEnv }}
- name: Platform__Environment
  value: {{ $platEnv | quote }}
{{- else if .Values.aspnetcore.environment }}
- name: Platform__Environment
  value: {{ .Values.aspnetcore.environment | quote }}
{{- end }}
{{- if .Values.config.observability.otlpEndpoint }}
- name: Observability__OtlpEndpoint
  value: {{ .Values.config.observability.otlpEndpoint | quote }}
{{- end }}
{{- if and .Values.secrets.observability.existingSecret .Values.secrets.observability.existingSecret.name }}
- name: Observability__OtlpHeaders
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.observability.existingSecret.name }}
      key: {{ .Values.secrets.observability.existingSecret.key | default "otlp-headers" }}
{{- else if or .Values.secrets.observability.otlpHeaders .Values.config.observability.otlpHeaders }}
- name: Observability__OtlpHeaders
  valueFrom:
    secretKeyRef:
      name: {{ include "plaxion-platform.secretName" . }}
      key: otlp-headers
{{- end }}
{{- end }}

{{/*
API-only env (CORS + API_BASE_URL for dashboard config.json + OIDC authentication/authorization)
*/}}
{{- define "plaxion-platform.apiEnv" -}}
- name: ROLE
  value: api
- name: API_BASE_URL
  value: {{ .Values.platform.apiBaseUrl | default "" | quote }}
{{- range $i, $origin := .Values.config.cors.allowedOrigins }}
- name: {{ printf "Cors__AllowedOrigins__%d" $i | quote }}
  value: {{ $origin | quote }}
{{- end }}
{{- include "plaxion-platform.authenticationEnv" . }}
{{- end }}

{{/*
OIDC authentication + tenant/platform-administrator authorization env (API only).
Maps 1:1 to Platform's Authentication / Authorization:* / Dashboard:Oidc configuration contract.
*/}}
{{- define "plaxion-platform.authenticationEnv" -}}
{{- $auth := .Values.authentication }}
- name: Authentication__Enabled
  value: {{ $auth.enabled | default false | toString | quote }}
- name: Authentication__RequireHttpsMetadata
  value: {{ $auth.oidc.requireHttpsMetadata | default true | toString | quote }}
- name: Authentication__AllowAnonymousProduction
  value: {{ $auth.allowAnonymousProduction | default false | toString | quote }}
{{- if $auth.oidc.authority }}
- name: Authentication__Authority
  value: {{ $auth.oidc.authority | quote }}
{{- end }}
{{- if $auth.oidc.audience }}
- name: Authentication__Audience
  value: {{ $auth.oidc.audience | quote }}
{{- end }}
{{- if $auth.oidc.dashboard.clientId }}
- name: Dashboard__Oidc__ClientId
  value: {{ $auth.oidc.dashboard.clientId | quote }}
{{- end }}
{{- range $i, $scope := $auth.oidc.dashboard.scopes }}
- name: {{ printf "Dashboard__Oidc__Scopes__%d" $i | quote }}
  value: {{ $scope | quote }}
{{- end }}
- name: Dashboard__Oidc__RedirectPath
  value: {{ $auth.oidc.dashboard.redirectPath | default "/auth/callback" | quote }}
- name: Dashboard__Oidc__PostLogoutRedirectPath
  value: {{ $auth.oidc.dashboard.postLogoutRedirectPath | default "/" | quote }}
- name: Authorization__TenantCreation__Mode
  value: {{ $auth.authorization.tenantCreation.mode | default "AnyAuthenticatedUser" | quote }}
{{- if $auth.authorization.tenantCreation.requiredRole }}
- name: Authorization__TenantCreation__RequiredRole
  value: {{ $auth.authorization.tenantCreation.requiredRole | quote }}
{{- end }}
{{- if $auth.authorization.tenantCreation.requiredClaimType }}
- name: Authorization__TenantCreation__RequiredClaimType
  value: {{ $auth.authorization.tenantCreation.requiredClaimType | quote }}
{{- end }}
{{- range $i, $val := $auth.authorization.tenantCreation.requiredClaimValues }}
- name: {{ printf "Authorization__TenantCreation__RequiredClaimValues__%d" $i | quote }}
  value: {{ $val | quote }}
{{- end }}
- name: Authorization__PlatformAdministrator__Mode
  value: {{ $auth.authorization.platformAdministrator.mode | default "Disabled" | quote }}
{{- if $auth.authorization.platformAdministrator.requiredRole }}
- name: Authorization__PlatformAdministrator__RequiredRole
  value: {{ $auth.authorization.platformAdministrator.requiredRole | quote }}
{{- end }}
{{- if $auth.authorization.platformAdministrator.requiredClaimType }}
- name: Authorization__PlatformAdministrator__RequiredClaimType
  value: {{ $auth.authorization.platformAdministrator.requiredClaimType | quote }}
{{- end }}
{{- range $i, $val := $auth.authorization.platformAdministrator.requiredClaimValues }}
- name: {{ printf "Authorization__PlatformAdministrator__RequiredClaimValues__%d" $i | quote }}
  value: {{ $val | quote }}
{{- end }}
{{- range $i, $claimType := $auth.authorization.invitations.emailClaimTypes }}
- name: {{ printf "Authorization__Invitations__EmailClaimTypes__%d" $i | quote }}
  value: {{ $claimType | quote }}
{{- end }}
{{- end }}

{{/*
Ingestion-only env
*/}}
{{- define "plaxion-platform.ingestionEnv" -}}
- name: ROLE
  value: ingestion
{{- end }}

{{/*
Render extra env list (supports value or valueFrom)
*/}}
{{- define "plaxion-platform.extraEnv" -}}
{{- range . }}
- name: {{ .name | quote }}
{{- if hasKey . "valueFrom" }}
  valueFrom:
{{ toYaml .valueFrom | nindent 4 }}
{{- else }}
  value: {{ .value | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Merge nodeSelector: component overrides global
*/}}
{{- define "plaxion-platform.nodeSelector" -}}
{{- $global := .root.Values.nodeSelector | default dict }}
{{- $local := .component.nodeSelector | default dict }}
{{- $merged := mergeOverwrite (deepCopy $global) $local }}
{{- if $merged }}
nodeSelector:
{{ toYaml $merged | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Merge tolerations
*/}}
{{- define "plaxion-platform.tolerations" -}}
{{- $global := .root.Values.tolerations | default list }}
{{- $local := .component.tolerations | default list }}
{{- $merged := concat $global $local }}
{{- if $merged }}
tolerations:
{{ toYaml $merged | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Affinity: component wins if set, else global
*/}}
{{- define "plaxion-platform.affinity" -}}
{{- $affinity := .component.affinity | default dict }}
{{- if not $affinity }}
{{- $affinity = .root.Values.affinity | default dict }}
{{- end }}
{{- if $affinity }}
affinity:
{{ toYaml $affinity | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Topology spread constraints
*/}}
{{- define "plaxion-platform.topologySpreadConstraints" -}}
{{- $tsc := .component.topologySpreadConstraints | default list }}
{{- if not $tsc }}
{{- $tsc = .root.Values.topologySpreadConstraints | default list }}
{{- end }}
{{- if $tsc }}
topologySpreadConstraints:
{{ toYaml $tsc | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Validate required database settings (fail fast on helm template/install)
*/}}
{{- define "plaxion-platform.validate" -}}
{{- if not .Values.image.repository }}
{{- fail "image.repository is required" }}
{{- end }}
{{- if eq .Values.database.mode "bundled" }}
  {{- if not .Values.postgresql.enabled }}
  {{- fail "database.mode=bundled requires postgresql.enabled=true" }}
  {{- end }}
  {{- if not .Values.postgresql.auth.password }}
    {{- $secName := include "plaxion-platform.secretName" . }}
    {{- $existing := lookup "v1" "Secret" .Release.Namespace $secName }}
    {{- if not (and $existing $existing.data (index $existing.data "password")) }}
    {{- fail "postgresql.auth.password is required on first install when database.mode=bundled (must match the Bitnami subchart password)" }}
    {{- end }}
  {{- end }}
{{- else if eq .Values.database.mode "external" }}
  {{- if .Values.postgresql.enabled }}
  {{- fail "database.mode=external requires postgresql.enabled=false" }}
  {{- end }}
  {{- $hasCS := and .Values.database.external.existingConnectionStringSecret .Values.database.external.existingConnectionStringSecret.name }}
  {{- if not $hasCS }}
    {{- if not .Values.database.external.host }}
    {{- fail "database.external.host is required when database.mode=external and existingConnectionStringSecret is not set" }}
    {{- end }}
    {{- if not .Values.database.external.database }}
    {{- fail "database.external.database is required when database.mode=external and existingConnectionStringSecret is not set" }}
    {{- end }}
    {{- if not .Values.database.external.username }}
    {{- fail "database.external.username is required when database.mode=external and existingConnectionStringSecret is not set" }}
    {{- end }}
  {{- end }}
{{- else }}
  {{- fail "database.mode must be 'external' or 'bundled'" }}
{{- end }}
{{- $auth := .Values.authentication }}
{{- $env := .Values.platform.environment | default .Values.aspnetcore.environment | default "Production" }}
{{- if $auth.enabled }}
  {{- if not $auth.oidc.authority }}
  {{- fail "authentication.oidc.authority is required when authentication.enabled=true" }}
  {{- end }}
  {{- if not $auth.oidc.audience }}
  {{- fail "authentication.oidc.audience is required when authentication.enabled=true" }}
  {{- end }}
  {{- if not $auth.oidc.dashboard.clientId }}
  {{- fail "authentication.oidc.dashboard.clientId is required when authentication.enabled=true" }}
  {{- end }}
{{- else }}
  {{- if and (eq $env "Production") (not $auth.allowAnonymousProduction) }}
  {{- fail "authentication.enabled=false in a Production environment requires authentication.allowAnonymousProduction=true (Platform refuses to start anonymous in Production otherwise). This is intentionally unsafe-looking — do not set it for real production deployments; configure OIDC instead." }}
  {{- end }}
{{- end }}
{{- $tcMode := $auth.authorization.tenantCreation.mode | default "AnyAuthenticatedUser" }}
{{- if eq $tcMode "Role" }}
  {{- if not $auth.authorization.tenantCreation.requiredRole }}
  {{- fail "authentication.authorization.tenantCreation.requiredRole is required when mode=Role" }}
  {{- end }}
{{- else if eq $tcMode "Claim" }}
  {{- if not $auth.authorization.tenantCreation.requiredClaimType }}
  {{- fail "authentication.authorization.tenantCreation.requiredClaimType is required when mode=Claim" }}
  {{- end }}
{{- else if ne $tcMode "AnyAuthenticatedUser" }}
  {{- fail (printf "authentication.authorization.tenantCreation.mode '%s' is not supported (use AnyAuthenticatedUser, Role, or Claim)" $tcMode) }}
{{- end }}
{{- $paMode := $auth.authorization.platformAdministrator.mode | default "Disabled" }}
{{- if eq $paMode "Role" }}
  {{- if not $auth.authorization.platformAdministrator.requiredRole }}
  {{- fail "authentication.authorization.platformAdministrator.requiredRole is required when mode=Role" }}
  {{- end }}
{{- else if eq $paMode "Claim" }}
  {{- if not $auth.authorization.platformAdministrator.requiredClaimType }}
  {{- fail "authentication.authorization.platformAdministrator.requiredClaimType is required when mode=Claim" }}
  {{- end }}
{{- else if ne $paMode "Disabled" }}
  {{- fail (printf "authentication.authorization.platformAdministrator.mode '%s' is not supported (use Disabled, Role, or Claim)" $paMode) }}
{{- end }}
{{- end }}
