# msssql-auto-dba

PowerShell automation toolkit for SQL Server DBA operations — discovery, inventory, and zero-touch patch orchestration across fleets of Windows servers.

## What it does

| Module | Purpose |
|---|---|
| `GetDetails/` | Collects a full SQL Server inventory snapshot from a single host and writes it to JSON/XML |
| `PatchSQL/` | Orchestrates patching across a list of servers, handling HA/DR dependencies (AG, FCI, Mirroring, Log Shipping) automatically |

---

## Prerequisites

- PowerShell 5.1 or later on the orchestration host
- WinRM enabled on all target servers (`Enable-PSRemoting`)
- The running account must have:
  - Local Administrator on all target servers
  - `sysadmin` on all SQL instances
  - Read access to `\\server\<TargetPath>` share (UNC path to the patch staging area on each server)
- SQL Server patch `.exe` binaries staged under `<MediaRoot>_<Cycle>\<SQLVersion>\SQLServer*.exe`
- `FailoverClusters` PowerShell module installed on any Windows Server Failover Cluster node
- Active Directory LDAP accessible for credential validation

---

## Architecture

```
ChangeConfig.ps1
   └─► CurrentConfig.ini (JSON)
          │
          ▼
     AutoPatch.ps1  (orchestration host)
          │
          ├── Invoke-Command ──► Gedet.ps1         (runs on each target, collects inventory)
          │                          └─► <server>_server_<timestamp>.json
          │
          ├── BuildPatchObject.ps1  (transforms inventory JSON → patch-ready object)
          │
          ├── [copy patch media to target via UNC share]
          │
          ├── Invoke-Command ──► Failover.ps1      (moves cluster groups before patching)
          │
          ├── Invoke-Command ──► <patch .exe /quiet /allinstances>
          │
          ├── Invoke-Command ──► ValiPatch.ps1     (registry check post-patch)
          │
          ├── Restart-Computer
          │
          └── Invoke-Command ──► Failover.ps1      (failback)
```

### Server state machine (AutoPatch)

```
[Queued for Patch] ──► [Requires Cluster Failover] ──► [Ready to Patch]
                                                              │
                   [Waiting for BCP / Waiting for Async]     │
                                                              ▼
                                                       [Patch Validation]
                                                              │
                                                              ▼
                                                         [Rebooting]
                                                              │
                                                              ▼
                                                    [Requires Failback] ──► [Patch Complete]
```

Terminal states: `done`, `fail`, `skip`, `timeout`, `down`, `issue`

---

## Setup

### 1. Stage patch media

```
\\<orchestration-host>\SQL_Patch_<Cycle>\
    SQL2016\SQLServer2016-KB<n>-x64.exe
    SQL2017\SQLServer2017-KB<n>-x64.exe
    SQL2019\SQLServer2019-KB<n>-x64.exe
```

### 2. Generate the config

```powershell
.\PatchSQL\ChangeConfig.ps1 `
    -MediaRoot  "C:\SQL_Patch"   `
    -Cycle      "2024-Q1"        `
    -ScriptsPath "D:\PFSQLteam\Autopatch" `
    -TargetPath  "C$\SQL_Patch"
```

This creates `CurrentConfig.ini` and auto-detects all SQL versions present in the media folder.

### 3. Create the server list

Edit `<ScriptsPath>\Patch\servers.txt` — one server name per line:

```
SQLSRV01
SQLSRV02
SQLSRV03
```

### 4. Run the patch

```powershell
.\PatchSQL\AutoPatch.ps1
```

Enter domain credentials when prompted. Progress is written to:
- `<ScriptsPath>\Patch\<user>_<timestamp>\Patch-Log.log` — transcript
- `<ScriptsPath>\Patch\<user>_<timestamp>\*.txt` — per-state server lists
- `\\<server>\<TargetPath>\Patch_progress.txt` — per-server log
- `<ScriptsPath>\output_html.html` — live HTML dashboard (auto-refreshes every 30 s)

---

## Script reference

### `GetDetails/Gedet.ps1`

Collects a complete SQL Server inventory from the local machine and writes JSON + XML.

**Parameters**

| Parameter | Default | Description |
|---|---|---|
| `-TargetPath` | `C:\SQL_Patch` | Root output directory |
| `-Domain` | `AD-ENT` | AD domain prefix used to check access group membership |

**Output** — `<TargetPath>\ServerDetails\<hostname>_server_<timestamp>.json`

**Collected data**

- Windows services (SQL Engine, SSAS, SSIS, SSRS, Cluster)
- Disk free space
- Per-instance: patch level, SQL version, TCP port, active/accessible state
- Per-instance: SQL logins and privileges
- Per-instance: TempDB sizes, last service start time
- Per-database: state, recovery model, encryption, size, last backup, HADR membership
- HADR details: Always On AG (sync mode, replica info, listener), Mirroring, Log Shipping, Replication
- Windows Server Failover Cluster topology (groups, resources, partner nodes)
- Pending reboot flag

---

### `PatchSQL/ChangeConfig.ps1`

Generates the `CurrentConfig.ini` used by `AutoPatch.ps1`.

**Parameters**

| Parameter | Description |
|---|---|
| `-MediaRoot` | Local path to the root of the patch media tree |
| `-Cycle` | Patch cycle label (e.g. `2024-Q1`). Media folder is `<MediaRoot>_<Cycle>` |
| `-ScriptsPath` | Path where all scripts live; also the output location for the config |
| `-TargetPath` | UNC-style path on each target server used as the staging area (e.g. `C$\SQL_Patch`) |

---

### `PatchSQL/BuildPatchObject.ps1`

Transforms a raw `Gedet.ps1` JSON object into the lightweight patch-tracking object used by `AutoPatch.ps1`. Computes HA/DR roles (primary/secondary, sync mode) for each instance.

**Input** — `[object]$ServerDetail` (deserialized Gedet JSON)  
**Output** — patch server object with `Versions`, `HADR`, `Instances`, `isPri`, `AG_Type`

---

### `PatchSQL/Failover.ps1`

Moves all SQL Server cluster groups from the current node to `$TargetNode` (failover) or back (failback). Run remotely via `Invoke-Command` on the cluster node being patched.

**Parameters**

| Parameter | Description |
|---|---|
| `-TargetNode` | Destination node name. Pass current hostname for failback |
| `-Timeout` | Max wait iterations (each is 30 s) |
| `-TargetPath` | Path to the per-server progress log (`$` → `:` conversion is done internally) |
| `-Cluster` | `Windows_Cluster` object from the Gedet output |

---

### `PatchSQL/ValiPatch.ps1`

Reads the registry on the local machine after patching and confirms the installed patch level matches the target. Run remotely via `Invoke-Command` on the target server.

**Parameters** — `[object]$Server`, `[object]$Target` (from config)

---

### `PatchSQL/AutoPatch.ps1`

Main orchestration script. Reads `D:\PFSQLteam\Autopatch\CurrentConfig.ini` and patches all servers in `<ScriptsPath>\Patch\servers.txt`.

**HA/DR ordering logic**

| Scenario | Order |
|---|---|
| Standalone | Patch immediately |
| Always On AG (sync secondary) | Patch async secondaries first, then sync secondaries, primary last |
| Always On AG (async only) | Patch secondary, then primary |
| Windows Server Failover Cluster (FCI) | Failover passive nodes to active node → patch passive → failback → patch next |
| Mirroring | Patch mirror first, then principal |
| Log Shipping | Patch secondary first, then primary |

---

## HA/DR type codes

| Code | Meaning |
|---|---|
| `AG` | Always On Availability Group |
| `FC` | Windows Server Failover Cluster (FCI) |
| `MIR` | Database Mirroring |
| `LS` | Log Shipping |
| `REP` | Transactional / Merge Replication |
