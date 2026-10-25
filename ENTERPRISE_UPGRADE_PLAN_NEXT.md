# _Sync Next Upgrade Plan — Phase 7 to 10

## Realistic Assessment (verified against source, 2026-07-23)

| Dimension | Doc Claim | Verified | Gap |
|-----------|-----------|----------|-----|
| CI/CD | not claimed | absent entirely | HIGH |
| Docker | not claimed | absent entirely | HIGH |
| Config validation | schema present | `Test-GSyncConfig` missing at runtime | HIGH |
| Security at rest | DPAPI/AES claimed | no encryption for `.gsync.state` | HIGH |
| Secret redaction | config-driven claimed | no `redactPatterns` in Logging | HIGH |
| Plugin contract | validation claimed | no `Test-GSyncPlugin` | MEDIUM |
| EventBus v2 | 17 constants | constants exist in EventBus.psm1 but wiring unverified | LOW |
| Metrics endpoint | Prometheus claimed | `Start-MetricsServer` exists but not in End-GSync flow | MEDIUM |
| Rollback | LIFO claimed | `Register-GSyncRollbackAction` wired; `Invoke-GSyncRollback` called on failure | PARTIAL |
| Pester 5+ | not claimed | `Run-Tests.ps1` uses Pester 4 `-Show All` | MEDIUM |
| ADR | not claimed | absent | MEDIUM |
| Multi-tenancy | not claimed | absent | MEDIUM |
| Config hooks | config-driven claimed | no `Invoke-GSyncHook` | MEDIUM |
| Plugin classes | PS 5.1 safe | 3 plugins use PS 7 classes | MEDIUM |

**Honest score: ~75/100 — Needs CI/CD + Security Hardening**

## Constraints
- **No hardcode**: all paths via `$PSScriptRoot`; all values via config/env-placeholder
- **Run independently**: `_Sync/` must be copyable anywhere with `.\gsync.ps1` zero-dep (git + PS only)
- **Fully automated**: CI/CD, full Pester batch, schema validation
- **PS 5.1 safe**: no classes for new code; existing class code must degrade gracefully

## Execution Order

```
Phase 7 (CI/CD + Security) → Phase 8 (Observability) → Phase 9 (Extensibility) → Phase 10 (Polish)
```

Phase 7 is mandatory and should be executed first. Phase 8-10 can be batched after Phase 7 is stable.

---

## Phase 7 — CI/CD Foundation + Security Hardening

| Priority | Task | Target File | Action |
|----------|------|-------------|--------|
| P0 | GitHub Actions CI | `.github/workflows/gsync.yml` | matrix: pwsh 7 + PS 5.1, windows/ubuntu/macos; Pester + PSScriptAnalyzer + schema validation + Pester 5 migration |
| P0 | Dockerfile | `_Sync/Dockerfile` | reproducible container (PS 7.4 + git); smoke-test `.\gsync.ps1 -NonInteractive` |
| P1 | Runtime config validator | `Modules/Config.psm1` | add `Test-GSyncConfig` using `Test-Json` against `gsync.config.schema.json` |
| P1 | Secret redaction | `Modules/Logging.psm1` | config-driven `redactPatterns` array; scrub secrets before file/console write |
| P1 | At-rest encryption | new `Modules/Security.psm1` or extend existing | DPAPI for `.gsync.state` (Windows current user) + AES-256-GCM fallback (cross-platform) |
| P2 | Pester 5 migration | `Run-Tests.ps1`, `Tests/*.Tests.ps1` | replace `-Show All` with `-Output Detailed`; update skipped-test patterns |

---

## Phase 8 — Observability & Reliability

| Priority | Task | Target File | Action |
|----------|------|-------------|--------|
| P1 | Metrics wiring | `gsync.module.psm1`, `Modules/Metrics.psm1` | wire `EVT_SYNC_START/COMPLETE/ERROR` to step durations and cache HIT/MISS counters; start server if `metrics.enabled` in config |
| P1 | Alerting webhook | `Modules/Alerting.psm1` | config-driven webhook on `EVT_SYNC_ERROR` + rollback; Support success/failure paths from config |
| P2 | EventBus v2 stabilization | `Modules/EventBus.psm1` | verify all 17 constants are used; ensure error-isolated dispatch; config-driven enable flag |
| P2 | CorrelationId propagation | `gsync.module.psm1`, `Modules/Logging.psm1` | ensure CorrelationId is included in all log lines and error objects |

---

## Phase 9 — Extensibility & Standards

| Priority | Task | Target File | Action |
|----------|------|-------------|--------|
| P1 | Plugin contract | `Modules/PluginRegistry.psm1` | `Test-GSyncPlugin` enforces `Get-PluginInfo`, `Invoke-PluginSync`, `Invoke-PluginValidate` exports; skip+log on fail |
| P2 | Plugin rewrite | `Plugins/*.psm1` | rewrite GitPlugin, GPGPlugin, LFSPlugin from classes to functions; add SmartStaging plugin |
| P2 | Config-driven hooks | `Modules/Config.psm1`, `gsync.module.psm1` | `Invoke-GSyncHook` runs `sync.hooks.<Name>` array + legacy `Hooks/*.ps1` |
| P2 | Multi-tenancy | `gsync.config.json`, `Modules/Config.psm1` | `tenancy` section with `tenants` array; per-tenant log dir; `Context.TenantId` |
| P3 | Language map | `Modules/PathNormalization.psm1` | config-driven `sync.languageMap` merges with built-in |
| P3 | Deploy targets | `Plugins/Deploy/*.psm1` | optional Azure/AWS/Vercel targets |
| P3 | ADR docs | `_Sync/Docs/ADRs/*.md` | 3–5 ADRs for event bus, plugin contract, metrics, parallelism, security |

---

## Phase 10 — Final Polish

| Priority | Task | Action |
|----------|------|--------|
| P2 | Approved verb audit | All entrypoints: `Send-*`, `Receive-*`, `Submit-*`, `Clear-*`, `New-*`; replace legacy `Register/Unregister/Publish/Reset/Sync` |
| P3 | Per-function `.SYNOPSIS` | CI enforcement; not blocking |
| P3 | Comment standard | Vietnamese/English per AGENTS.md convention |
| P3 | Version bump | `gsync.config.json` → `2.1.0` (adds CI + Security features) |
| P3 | Final eval | recompute score |

---

## Automation Entrypoints

- `Run-Tests.ps1` — Pester batch (needs Pester 5 fix)
- `Invoke-GSync.ps1` — CLI (unchanged signature)
- `.github/workflows/gsync.yml` — CI matrix (new)
- `_Sync/Dockerfile` — reproducible container (new)

---

## Risk Register

| Risk | Mitigation |
|------|------------|
| PS 7 classes in plugins break PS 5.1 | Rewrite plugins as functions; keep classes only in Core/ for PS 7+ tests |
| DPAPI not available on Linux/macOS | Use AES-256-GCM fallback with configurable key/file locations |
| CI matrix bloat | Limit to 3 OS + 2 PS versions until stable, then expand |
| Metrics server port conflict | Make port configurable; bind to loopback only |

**Last Updated: 2026-07-23**
**Reviewer: Kilo**
