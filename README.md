# 📡 MS Graph Change Tracker

An automated zero-maintenance tracker for new Microsoft Graph API permissions and endpoints.

## How It Works

```
Daily cron (GitHub Actions)
  └─► Update-GraphTracker.ps1
        ├─ Fetch permissions.json          (mappings + paths)
        ├─ Fetch permissions-descriptions.json  (display names + descriptions)
        ├─ Diff against data/last-seen.json
        ├─ Append new entries to data/changelog.json
        └─ Push updated JSON → triggers GitHub Pages deploy
                                    └─► index.html reads changelog.json
```

## Repository Structure

```
├── Update-GraphTracker.ps1          # Main PowerShell tracker script
├── index.html                       # GitHub Pages dashboard
├── data/
│   ├── changelog.json               # Cumulative change log (auto-updated)
│   └── last-seen.json               # State snapshot from last run (auto-updated)
└── .github/
    └── workflows/
        └── monitor-graph.yml        # Daily cron + Pages deploy workflow
```

## Setup Instructions

### 1. Fork / clone this repository

### 2. Enable GitHub Pages
- Go to **Settings → Pages**
- Set **Source** to `GitHub Actions`

### 3. Enable write permissions for Actions
- Go to **Settings → Actions → General**
- Under *Workflow permissions*, select **Read and write permissions**
- Check **Allow GitHub Actions to create and approve pull requests** (optional)

### 4. Trigger the first run
- Go to **Actions → Monitor MS Graph Changes**
- Click **Run workflow**

The first run will seed `data/last-seen.json` with the current state (no changelog entries yet).  
Every subsequent run will detect and log only **new** permissions and endpoints.

## Local Testing

```powershell
# From the repo root
pwsh ./Update-GraphTracker.ps1
```

Requires PowerShell 7+. No secrets or authentication needed — all data sources are public.

## Data Sources

| File | URL |
|------|-----|
| Permission Mappings | `https://raw.githubusercontent.com/microsoftgraph/microsoft-graph-devx-content/refs/heads/master/permissions/new/permissions.json` |
| Permission Descriptions | `https://raw.githubusercontent.com/microsoftgraph/microsoft-graph-devx-content/master/permissions/permissions-descriptions.json` |

---

*Automatically maintained by GitHub Actions. No manual updates needed.*
