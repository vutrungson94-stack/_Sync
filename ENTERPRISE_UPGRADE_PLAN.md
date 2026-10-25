# _Sync Enterprise Upgrade Plan — Phase 0 to 6

## Realistic Assessment (verified against source, 2026-07-22)

| Dimension | Doc Claim | Verified | Gap |
|-----------|-----------|----------|-----|
| Class load | no global pollution | ALL imports use `-Global` | HIGH |
| Class load | `using module` chain | `_SyncCore.psm1` uses `SilentlyContinue` on imports | HIGH |
| Config | schema present | `.schema.json` exists but NO runtime validator | MEDIUM |
| Tests | class tests passing | tests depend on fragile class loading | UNKNOWN |
| CI/CD | not claimed | absent entirely | HIGH |
| Observability | Metrics.psm1 present | same file in Modules/; not wired into pipeline | MEDIUM |
| DI/OOP | implied | no DI container; global `$script:EventManager` | HIGH |
| Security | scan patterns present | no DPAPI/AES encryption at rest; no secret redaction pipeline | HIGH |
| Rollback | SyncRollback.psm1 present | not wired into execution flow | HIGH |
| Plugin | 3 plugins | no contract validation; `-Global` leakage | MEDIUM |
| Extensibility | hook hooks | hardcoded script dots, no config registry | MEDIUM |
| Multi-tenancy | not claimed | absent | MEDIUM |

**Honest score: ~62/100 — Mid-Tier / Needs Hardening**

## Constraints
- **No hardcode**: all paths via `$PSScriptRoot`; all values via config/env-placeholder
- **Run independently**: `_Sync/` must be copyable anywhere with `.\gsync.ps1` zero-dep (git + PS only)
- **Fully automated**: CI/CD, full Pester batch (`Invoke-Pester "_Sync/Tests/*.Tests.ps1"`), schema validation, module parser check
- **PS 5.1 safe**: no classes for new code; existing class code must degrade gracefully or be refactored

## Phase 0 — Stabilization (no-break)

| Task | Target file | Action |
|------|-------------|--------|
| Remove `-Global` from imports | `gsync.module.psm1` | change to `-Force` only; use `using module` only at top-level script for type safety |
| Replace class-dependency `SilentlyContinue` chain | `_SyncCore.psm1` | refactor fragile class pipeline into function-based `SyncContext` + `SyncOrchestrator` (PS 5.1 safe); keep backward-compat exports |
| Class test suite pass or skip | `Tests/Core.Tests.ps1` | wrap `Describe` blocks with `if($PSVersionTable.PSVersion.Major -ge 7)` so PS 5.1 runs skip cleanly |
| Add `Sync.psd1` manifest validation | CI future step | parse-check + `Test-ModuleManifest` |
| Full Pester batch runner | `Run-Tests.ps1` | mirror `_Build/Tests/Run-CoreTests.ps1`; produce JUnit/JSONL output |

## Phase 1 — Core Infrastructure (mirror _Build proven modules)

| Task | Target file | Action |
|------|-------------|--------|
| Unified config schema validator | `Modules/Config.psm1` | add `Test-GSyncConfig` using `Test-Json` against `gsync.config.schema.json` |
| DI-style resolver | `Modules/Container.psm1` | lightweight `Register/Resolve/Test-ServiceRegistered` (singleton + transient) |
| Structured JSON logging | `Modules/Logging.psm1` | add `Write-JsonLog` + `enableJsonLog` config; redact secrets before write |
| Secret redaction pipeline | `Modules/Logging.psm1` | config-driven `redactPatterns` (array of `{name,pattern,replacement}`); do NOT hardcode provider regex |
| CorrelationId | `gsync.module.psm1` | generate 12-char hex in `Start-GSync`; pass through Context |
| Error tracing | `Modules/ErrorHandling.psm1` | structured errors + `Invoke-WithRetry` (exponential backoff, config-driven) + `Invoke-Rollback` (LIFO) |

## Phase 2 — Enterprise Alignment

| Task | Target file | Action |
|------|-------------|--------|
| EventBus v2 | `Modules/EventBus.psm1` | 17 constants (`EVT_SYNC_START`…`EVT_TELEMETRY_RECORDED`); error-isolated dispatch; config-driven enable |
| Config-driven hooks | `Modules/Config.psm1` | `Invoke-GSyncHook` runs `sync.hooks.<Name>` array + legacy `Hooks/*.ps1` |
| Multi-tenancy | `gsync.config.json` + `Modules/Config.psm1` | `tenancy` section; per-tenant log dir; Context.TenantId |
| Plugin contract | `Modules/PluginRegistry.psm1` | `Test-GSyncPlugin` enforces exports; skip+log on fail |
| Rollback wiring | `Modules/SyncRollback.psm1` | stack in `$global:GSyncRollbackStack`; Orchestrator registers cleanup actions |
| Approved verb audit | all new code | `Send-*`, `Receive-*`, `Submit-*`, `Clear-*`, `New-*`; replace legacy `Register/Unregister/Publish/Reset/Sync` |

## Phase 3 — Observability & Security

| Task | Target file | Action |
|------|-------------|--------|
| Metrics endpoint | `Modules/Metrics.psm1` | Prometheus HTTP endpoint (`HttpListener` + background runspace) + OTLP push; config-driven enable |
| Adapters | `Modules/Metrics.psm1` | `New-MetricCounter/Histogram`, `Submit-GSyncMetric`, `Get-MetricsAsPrometheus` |
| Wire metrics into pipeline | `gsync.module.psm1` | `EVT_SYNC_START/COMPLETE/ERROR` emit step durations; cache HIT/MISS counters |
| Secret encryption at rest | `Modules/Security.psm1` | DPAPI + AES fallback for `.gsync.state`; `CredentialVault.psm1` v2 if needed |
| Security scan config-driven | `Modules/Security.psm1` | patterns + exclude dirs from config; auto-detect test dirs |
| Alerting webhook | `Modules/Alerting.psm1` | config-driven webhook on `EVT_SYNC_ERROR` + rollback; token rotation |

## Phase 4 — Extensibility

| Task | Target file | Action |
|------|-------------|--------|
| Plugin registry 2.0 | `Modules/PluginRegistry.psm1` | `Get/Register/Invoke-GSyncPlugin`; plugins implement `Get-PluginInfo`, `Invoke-PluginSync`, `Invoke-PluginValidate` |
| Build 3 plugins | `Plugins/*.psm1` | GitPlugin, GPGPlugin, LFSPlugin rewritten to contract; add SmartStaging plugin |
| Deploy targets | new `Plugins/Deploy/*.psm1` | optional Azure/AWS/Vercel targets (optional) |
| Language map | `Modules/PathNormalization.psm1` | config-driven `sync.languageMap` merges with built-in |

## Phase 5 — CI/CD & Verification

| Task | Target file | Action |
|------|-------------|--------|
| Full Pester batch | `Run-Tests.ps1` | 350+ tests across all modules; JSONL + JUnit output |
| CI matrix | `.github/workflows/gsync.yml` (new) | pwsh 7 + PS 5.1 on windows/ubuntu/macos; Pester + PSScriptAnalyzer + schema validation |
| Dockerfile | `_Sync/Dockerfile` | reproducible container (PS 7.4 + git); smoke-test `.\gsync.ps1 -NonInteractive` |
| PSScriptAnalyzer | CI step | Error-only; fail on Error, warn on Warning |
| ADR | `_Sync/Docs/ADRs/` | 3–5 ADRs for event bus, plugin contract, metrics, parallelism, security |

## Phase 6 — Final Polish

| Task | Action |
|------|--------|
| Per-function `.SYNOPSIS` on all entrypoints | CI blueprint; not blocking |
| Vietnamese/English comment standard | follow AGENTS.md convention |
| Version bump | `gsync.config.json` → `1.1.0` (or `2.0.0` if breaking loading changes) |
| Final eval | recompute ~98/100 (185/185) — Grade A |

## Execution Order

```
Phase 0 → 1 → 2 → 3 → 4 → 5 → 6
```

Phase 0 and 1 can be batched in parallel branches; Phase 2+ require Phase 1 artifacts.

## Automation Entrypoints

- `Run-Tests.ps1` — Pester batch
- `Invoke-GSync.ps1` — CLI (unchanged signature)
- `_Sync/Dockerfile` — reproducible
- `.github/workflows/gsync.yml` — CI matrix

---

**Last Updated: 2026-07-22**
**Reviewer: Kilo**
