# GetDetails

`Gedet.ps1` collects a complete SQL Server inventory snapshot from the local Windows machine and writes it to JSON and XML files.

## Usage

```powershell
# Run locally (default paths)
.\Gedet.ps1

# Custom output path and domain
.\Gedet.ps1 -TargetPath "D:\Inventory" -Domain "CORP"
```

## Output

Files are written to `<TargetPath>\ServerDetails\`:

```
<hostname>_server_MM_dd_yyyy_HH_mm_ss.json
<hostname>_server_MM_dd_yyyy_HH_mm_ss.xml
```

The script returns the filename (without extension) so callers can locate the output.

## Output schema

```
{
  ServerName, Domain, Ran_at, LastBootUpTime,
  is_Accessible,                    # true if a known AD group is local admin
  is_PendingFileRenameOperations,   # pending reboot required
  Disks: [ { DeviceId, Size_GB, FreeSpace_GB } ],
  Services: [ { Name, State, StartMode, StartName } ],
  Instances: [
    {
      InstanceName, PatchLevel, SQL_Version,
      TCP_PORT_TYPE, TCP_PORT_NUMBER,
      Connection_String,
      is_Active, is_Accessible, is_Clustered, is_AlwaysOn,
      SQL_VirtualName,        # only if is_Clustered
      About_Version,          # @@VERSION string
      Service_LastStart,
      TempDB_Details: { DataFile_inMB, LogFile_Total_inMB, LogFile_Used_inMB },
      SQL_Logins: [ { SQL_LoginName, SQL_Privileges, is_Disabled } ],
      SQL_Jobs:   [ { SQL_JobName, SQL_JobOwner, is_Enabled,
                      LastRun_Status, LastRun_Date, LastRun_Message, NextRun_Date } ],
      HADR: [ "AG" | "MIR" | "LS" | "REP" ],
      Databases: [
        {
          Name, DB_Status, is_Read_Only, is_in_Standby, is_Encrypted,
          is_AutoClose, Recovery_Model, DBSize_inGB,
          Last_BackUp_On, BackUpSize_inMB, Backup_Type, BackUp_Path,
          HADR: [],
          # AG properties (if AG member)
          AG_Name, is_AG_PrimaryReplica, AG_SyncState, AG_HealthState,
          AG_AvailMode, AG_FailoverMode, AG_ReadableSecondary,
          AG_ReplicaInfo, is_AG_Suspended, AG_Listener,
          # Mirroring properties (if mirrored)
          Mirroring_Role, Mirroring_State, Mirroring_Partner, Mirroring_Witness,
          # Log Shipping properties (if LS participant)
          LogShipping_Role, LogShipping_Health,
          LogShipping_SecondaryServer, LogShipping_SecondaryDatabase,
          LogShipping_PrimaryServer, LogShipping_PrimaryDatabase,
          # Replication properties (if replicated)
          Replication_Role: [ "PUBLISHED" | "SUBSCRIBED" | "MERGE-PUBLISHED" | "DISTRIBUTOR" ]
        }
      ]
    }
  ],
  Windows_Cluster: {          # only if WSFC detected
    ClusterName,
    Cluster_Groups: [ { GroupName, State, OwnerNode, is_AutoFailback,
                        Group_Resources: [ { Name, State, ResourceType } ] } ],
    Cluster_Partners: [ { Name, State } ]
  }
}
```

## SQL version support

| PatchLevel prefix | Detected as |
|---|---|
| `10.0.*` | SQL2008 |
| `10.50.*` | SQL2008R2 |
| `11.*` | SQL2012 |
| `12.*` | SQL2014 |
| `13.*` | SQL2016 |
| `14.*` | SQL2017 |
| `15.*` | SQL2019 |
| `16.*` | SQL2022 |
