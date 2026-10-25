# gsync â€” Git Sync VIP PRO

A portable, cross-platform Git synchronization tool written in PowerShell.
Works on Windows, Linux, and macOS with PowerShell 5.1+ / pwsh 7+.

## Features

- **Safe sync**: automatic `.gitignore` protection, sensitive file detection, artifact unstaging
- **Conflict handling**: detects and helps resolve rebase/merge/cherry-pick conflicts
- **State recovery**: remembers interrupted operations (commit without push) and resumes them
- **Retry with exponential backoff**: fetch/pull/push retry with smart delays
- **SSH key management**: loads SSH keys with proper permission checks
- **SSL verification**: detects certificate issues, custom CA bundles, Schannel backend
- **Large file detection**: warns about files > threshold (default: 90MB)
- **Webhook notifications**: supports custom webhook URLs for success/failure
- **Dry-run mode**: preview changes without making them
- **CI/CD ready**: `-Yes`, `-No`, `-NonInteractive`, `-LogLevel Debug` flags for automation
- **Portable**: zero dependencies beyond git and PowerShell â€” copy `_Sync/` anywhere

## Quick Start

```powershell
# Normal run (with prompts)
.\_Sync\gsync.ps1

# Auto-confirm all prompts (CI/CD)
.\_Sync\gsync.ps1 -Yes

# Dry run (preview only)
.\_Sync\gsync.ps1 -DryRun

# Debug logging
.\_Sync\gsync.ps1 -LogLevel Debug
```

## Parameters

| Parameter       | Description                                          |
|-----------------|------------------------------------------------------|
| `-NonInteractive` | Use defaults for all prompts, no questions          |
| `-Yes`            | Auto "yes" to all prompts (CI/CD mode)              |
| `-No`             | Auto "no" to all prompts (dry-run)                  |
| `-DryRun`         | Preview changes, no files modified                  |
| `-ConfigPath`     | Custom config JSON path (default: `.gitignore.config.json`) |
| `-RepoUrl`        | Clone/init repository from this URL                 |
| `-RemoteName`     | Git remote name (default: `origin`)                 |
| `-LogLevel`       | Logging: `Error`, `Warn`, `Info`, `Debug`           |

## Configuration

Default config is auto-created at `.gitignore.config.json` in the project root. Key sections:

```json
{
  "git": {
    "remoteName": "origin",
    "pullConflictPolicy": "ask",
    "retryCount": 3,
    "retryDelaySeconds": 5,
    "pushRetryDelaySeconds": 3
  },
  "sensitive": {
    "enabled": true,
    "blockedPatterns": [ "\\.keystore$", "\\.env$", "secrets\\.json$" ]
  },
  "webhook": {
    "enabled": false,
    "url": ""
  }
}
```

## Directory Structure

```
_Sync/
â”œâ”€â”€ gsync.ps1              # Entry point
â”œâ”€â”€ gsync.module.psm1      # Main module (orchestrator)
â”œâ”€â”€ Modules/
â”‚   â”œâ”€â”€ Logging.psm1       # Logging with levels, file output, progress bar
â”‚   â”œâ”€â”€ Config.psm1        # Config loading, merging, validation
â”‚   â”œâ”€â”€ GitUtils.psm1      # All git operations (fetch, pull, push, stash, etc.)
â”‚   â”œâ”€â”€ Security.psm1      # .gitignore management, sensitive file detection
â”‚   â”œâ”€â”€ Cleanup.psm1       # Junk file removal, large file detection
â”‚   â””â”€â”€ UI.psm1            # Console UI (header, prompts, colors)
â””â”€â”€ README.md
