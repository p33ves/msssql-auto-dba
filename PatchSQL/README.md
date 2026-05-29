# PatchSQL

Zero-touch SQL Server patch orchestration for fleets of Windows servers, with full awareness of HA/DR topologies.

## Scripts

| Script | Runs on | Purpose |
|---|---|---|
| `ChangeConfig.ps1` | Orchestration host | Generate `CurrentConfig.ini` for a patch cycle |
| `AutoPatch.ps1` | Orchestration host | Main loop — drives patching across all servers |
| `BuildPatchObject.ps1` | Orchestration host | Transform Gedet JSON into a patch-tracking object |
| `Failover.ps1` | Target server (via `Invoke-Command`) | Move cluster groups for failover / failback |
| `ValiPatch.ps1` | Target server (via `Invoke-Command`) | Validate installed patch level via registry |

## Quickstart

```powershell
# Step 1 — generate config (run once per patch cycle)
.\ChangeConfig.ps1 `
    -MediaRoot   "C:\SQL_Patch"              `
    -Cycle       "2024-Q1"                   `
    -ScriptsPath "D:\PFSQLteam\Autopatch"    `
    -TargetPath  "C$\SQL_Patch"

# Step 2 — edit the server list
notepad "D:\PFSQLteam\Autopatch\Patch\servers.txt"

# Step 3 — run
.\AutoPatch.ps1
```

## Config file (`CurrentConfig.ini`)

The config is a JSON file with this structure:

```json
{
  "Timeouts": {
    "Get-details": 50,
    "Copy-media":  8,
    "Failover":    90,
    "Patch":       360,
    "Reboot":      60,
    "Failback":    90,
    "Validate":    20
  },
  "Targets": {
    "Cycle":   "2024-Q1",
    "Path":    "C$\\SQL_Patch",
    "SQL2017": "14.0.3456.2",
    "SQL2019": "15.0.4312.2"
  },
  "Scripts": {
    "Get-Details":  "...\\GetDetails\\Gedet.ps1",
    "Build-Object": "...\\PatchSQL\\BuildPatchObject.ps1",
    "Failover":     "...\\PatchSQL\\Failover.ps1",
    "Failback":     "...\\PatchSQL\\Failover.ps1",
    "Validate":     "...\\PatchSQL\\ValiPatch.ps1",
    "Path":         "D:\\PFSQLteam\\Autopatch"
  },
  "Media": {
    "SQL2017": { "Name": "SQLServer2017-KB3456-x64.exe", ... },
    "SQL2019": { "Name": "SQLServer2019-KB4312-x64.exe", ... }
  }
}
```

`ChangeConfig.ps1` populates `Targets` and `Media` automatically by scanning the media folder.

## Patch ordering

AutoPatch groups servers before starting and determines an order that preserves availability throughout:

```
Standalone servers          → patch immediately (no coordination needed)

Always On (sync secondary)  → async replicas first
                            → sync replicas second
                            → primary last

Windows Cluster (FCI)       → passive nodes first (after failover)
                            → active node last (after failback from newly patched node)

Mirroring                   → mirror first, then principal
Log Shipping                → secondary first, then primary
```

## Log files

All output lands under `<ScriptsPath>\Patch\<username>_<timestamp>\`:

| File | Content |
|---|---|
| `Patch-Log.log` | Full PowerShell transcript |
| `servers0.txt` | Original server list |
| `servers.txt` | Servers still to process |
| `currentset.txt` | Servers actively being patched |
| `restset.txt` | Servers queued for later |
| `done.txt` | Successfully patched |
| `fail.txt` | Failed servers + reason |
| `skip.txt` | Skipped (already up to date or not in scope) |
| `timeout.txt` | Timed-out servers |
| `down.txt` | Unreachable servers |
| `issue.txt` | Servers with configuration issues |
| `Logs\<server>.txt` | Copy of each server's remote progress log |

Each target server also writes to `\\<server>\<TargetPath>\Patch_progress.txt`.

## Troubleshooting

| Symptom | Check |
|---|---|
| Server lands in `issue.txt` with "Multiple Versions" | Server has instances from two different SQL major versions — these must be patched separately |
| Server lands in `issue.txt` with "Multiple Roles" | An instance participates in two HA/DR technologies where it is primary in one and secondary in another — manual review required |
| Server lands in `fail.txt` with "Media Not Copied" | UNC path `\\server\<TargetPath>` is not accessible, or media source share is missing the version folder |
| Patch validation fails | The `.exe` patch binary completed but the registry patch level did not advance — check `\\server\<TargetPath>\Patch_progress.txt` for the installer exit code |
