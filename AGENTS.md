# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What This Project Is

AzGlue is a PowerShell-based Azure Functions app that acts as a secure API gateway between client scripts and the IT Glue API. It authenticates clients via API keys, validates requests against a YAML whitelist, filters request/response payloads, and proxies approved calls to IT Glue.

## Local Development

- **Run locally:** Press F5 in VS Code (requires Azure Functions extension + Azure Functions Core Tools). This runs the `func: host start` task and attaches the PowerShell debugger.
- **Test URL:** `http://localhost:7071/api/AzGlueForwarder?ResourceURI=`
- **Deploy:** Use the Azure Functions VS Code extension — right-click the function app and select "Deploy to Function App..."

**Setup before first run:**
1. Copy `local.settings.json.example` → `local.settings.json` and populate `APIKey_ORG`, `ITGlueAPIKey`, `ITGlueURI`
2. Copy `OrgList.csv.example` → `OrgList.csv`

**Dependencies** (auto-managed by Azure Functions): `Az` 4.x, `powershell-yaml` 0.4.2 (see `requirements.psd1`)

## Architecture

### Request Flow

```
Client (x-api-key header + ResourceURI param)
  → AzGlueForwarder/run.ps1
      1. Authenticate: match x-api-key against APIKey_* env vars
      2. Validate: check ResourceURI path + HTTP method against whitelisted-endpoints.yml
      3. Filter request: strip disallowed query params; enforce required params (e.g. show_passwords=false)
      4. Proxy to IT Glue API (with retry + random backoff for rate limits)
      5. Filter response: strip fields not in returnbody schema
  → Return filtered JSON to client
```

### Key Files

| File | Role |
|------|------|
| `AzGlueForwarder/run.ps1` | The entire gateway logic — auth, validation, proxy, filtering |
| `whitelisted-endpoints.yml` | Master config: allowed endpoints, methods, query params, request/response schemas |
| `local.settings.json` | Local env vars (gitignored — contains secrets) |
| `APIKeyGenerator.ps1` | Interactive tool to generate per-org API keys |
| `profile.ps1` | Azure Functions startup — MSI authentication for Key Vault |

### whitelisted-endpoints.yml Structure

Each resource type entry has:
- `endpoints` — URL patterns (`:id` is a wildcard)
- `methods` — allowed HTTP verbs
- `allowed_parameters` — query params the client may send
- `required_parameters` — params always injected/enforced (e.g. `show_passwords: "false"`)
- `createbody` — schema whitelist for request body (POST/PATCH)
- `returnbody` — schema whitelist for response body (controls what data reaches the client)

### Authentication & Per-Key RBAC

Clients send `x-api-key` in the request header. The function matches it against all `APIKey_*` environment variables. An empty or missing key always fails.

Keys follow the naming convention `APIKey_<Profile>_<Label>` where `<Profile>` maps to a profile defined in the `profiles:` section of `whitelisted-endpoints.yml`. Keys named `APIKey_<Label>` (no profile segment) get the `Default` profile, which grants full access to all whitelisted endpoints.

**Adding a new key:** Add `APIKey_<Profile>_<Label> = <uuid>` to Azure App Settings. No redeployment needed.

**Adding a new profile:** Add a block under `profiles:` in `whitelisted-endpoints.yml` listing allowed endpoint keys and their permitted methods, then redeploy. A `null` profile value means full access.

```yaml
profiles:
  Default:          # null = full access to everything in whitelist
  ReadOnly:
    organizations: [GET]
    configurations: [GET]
  DocumentsNoPasswords:
    flexible_assets: [GET, POST, PATCH]
    flexible_asset_types: [GET]
```

### Build-Body Function

`Build-Body` in `run.ps1` recursively filters objects against a whitelist schema (from YAML). It caps recursion at depth 8, and explicitly preserves single-item arrays (which PowerShell would otherwise collapse to scalars).

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `APIKey_<Profile>_<Label>` (or `APIKey_<Label>`) | Client API key(s) — at least 14 chars; profile controls RBAC |
| `ITGlueAPIKey` | The real IT Glue API key (never exposed to clients) |
| `ITGlueURI` | IT Glue API base URL (e.g. `https://api.itglue.com`) |

In Azure, these go in Configuration → Application Settings. Key Vault references are supported.

## Important Behaviors

- Errors are returned as HTTP 200 with `{"Error": "..."}` body (not 4xx/5xx) for compatibility with the IT Glue PowerShell module.
- The gateway retries IT Glue requests once on failure with 1–10 second random backoff.
- `itglue-endpoints.yml` is a reference/scratchpad file — it is **not** used by the running function.
