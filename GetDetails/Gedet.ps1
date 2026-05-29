#Requires -Version 5.1
param(
    [string]$TargetPath = "C:\SQL_Patch",
    [string]$Domain     = "AD-ENT"
)

$run_datetime = (Get-Date).ToUniversalTime()
$details_path = "$TargetPath\ServerDetails"

if (!(Test-Path $details_path)) {
    New-Item -Path $TargetPath -Name "ServerDetails" -ItemType Directory -Force | Out-Null
}

$access_groups = @("$Domain\PRV_EDM_DA_SRV_SQL_PF", "$Domain\PRV_EDM_DA_SRV_WFISDBAdmins")
$instances     = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances
$cluster_flag  = $false

if (!$instances) {
    Write-Warning "No SQL Server instances found on $env:COMPUTERNAME"
    return $null
}

$services = Get-CimInstance win32_service |
    Where-Object { $_.Name -like "*SQL*" -or $_.Name -like "*OLAP*" -or
                   $_.Name -like "MsDts*" -or $_.Name -like "*ReportServer*" -or
                   $_.Name -like "*DBSmart*" -or $_.Name -like "clusSvc" } |
    Select-Object Name, State, StartMode, StartName

$lastbootup = (Get-CimInstance win32_operatingsystem).LastBootUpTime
$disks      = Get-CimInstance win32_logicaldisk |
    Select-Object DeviceId,
        @{n="Size_GB";      e={[math]::Round($_.Size      / 1GB, 2)}},
        @{n="FreeSpace_GB"; e={[math]::Round($_.FreeSpace / 1GB, 2)}}

$obj_server = [PSCustomObject]@{
    ServerName                     = $env:COMPUTERNAME
    Domain                         = $Domain
    Services                       = $services
    Instances                      = @()
    is_Accessible                  = $false
    LastBootUpTime                 = $lastbootup
    Disks                          = $disks
    Ran_at                         = $run_datetime
    is_PendingFileRenameOperations = $false
}

#region Check local admin group
$admin_output = net localgroup administrators
foreach ($line in $admin_output) {
    if ($line -in $access_groups) {
        $obj_server.is_Accessible = $true
        break
    }
}
#endregion

function Invoke-SqlQuery {
    param([System.Data.SqlClient.SqlConnection]$Conn, [string]$Query)
    $cmd     = New-Object System.Data.SqlClient.SqlCommand($Query, $Conn)
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $ds      = New-Object System.Data.DataSet
    $adapter.Fill($ds) | Out-Null
    return $ds
}

foreach ($instance in $instances) {

    $reg_base   = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$instance
    $patchLevel = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$reg_base\Setup").PatchLevel
    $tcpAll     = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$reg_base\MSSQLServer\SuperSocketNetLib\Tcp\IPAll" -ErrorAction SilentlyContinue
    $tcpPort    = $tcpAll.TcpPort

    if ($tcpPort) {
        $portType = "STATIC"
    }
    else {
        $portType = "DYNAMIC"
        $tcpPort  = $tcpAll.TcpDynamicPorts
    }

    $sql_version = switch -Wildcard ($patchLevel) {
        "10.0*"  { "SQL2008"   }
        "10.50*" { "SQL2008R2" }
        "11.*"   { "SQL2012"   }
        "12.*"   { "SQL2014"   }
        "13.*"   { "SQL2016"   }
        "14.*"   { "SQL2017"   }
        "15.*"   { "SQL2019"   }
        "16.*"   { "SQL2022"   }
        default  { "Unknown"   }
    }

    $conn_string = "$env:COMPUTERNAME\$instance,$tcpPort"

    $obj_instance = [PSCustomObject]@{
        InstanceName      = $instance
        PatchLevel        = $patchLevel
        SQL_Version       = $sql_version
        TCP_PORT_TYPE     = $portType
        TCP_PORT_NUMBER   = $tcpPort
        is_Active         = $false
        is_Accessible     = $false
        is_Clustered      = $false
        is_AlwaysOn       = $false
        Connection_String = $conn_string
        Databases         = @()
        HADR              = @()
    }

    #region Service state
    if ($instance -eq "MSSQLSERVER") {
        $engine = $services | Where-Object { $_.Name -eq "MSSQLSERVER" }
    }
    else {
        $engine = $services | Where-Object { $_.Name -eq "MSSQL`$$instance" }
    }
    if ($engine.State -eq "Running") { $obj_instance.is_Active = $true }
    #endregion

    #region Cluster and AlwaysOn (registry)
    if (Test-Path "HKLM:\Cluster") {
        $cluster_flag = $true
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$reg_base\Cluster") {
            $obj_instance.is_Clustered = $true
            $virtualname = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$reg_base\Cluster").ClusterName
            $obj_instance | Add-Member -MemberType NoteProperty -Name SQL_VirtualName -Value $virtualname
            $obj_instance.Connection_String = "$virtualname\$instance,$tcpPort"
        }
        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$reg_base\MSSQLServer\HADR") {
            if ((Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$reg_base\MSSQLServer\HADR").HADR_Enabled) {
                $obj_instance.is_AlwaysOn = $true
            }
        }
    }
    #endregion

    #region SQL queries
    if ($obj_instance.is_Active) {

        $SQLConnection = New-Object System.Data.SqlClient.SqlConnection
        $SQLConnection.ConnectionString = "Server=$($obj_instance.Connection_String);Database=master;Integrated Security=True;Connect Timeout=15;"

        try {
            $SQLConnection.Open()
            $obj_instance.is_Accessible = $true
        }
        catch {
            Write-Warning "[$instance] Failed to connect: $_"
        }

        if ($obj_instance.is_Accessible) {

            # SQL version banner
            $ds = Invoke-SqlQuery -Conn $SQLConnection -Query "SELECT @@VERSION AS version;"
            $obj_instance | Add-Member -MemberType NoteProperty -Name About_Version -Value $ds.Tables[0].Rows[0]["version"]

            # SQL logins
            $ds = Invoke-SqlQuery -Conn $SQLConnection -Query "
                SELECT s.loginname, s.sysadmin, s.securityadmin, s.serveradmin, s.setupadmin,
                       s.processadmin, s.diskadmin, s.dbcreator, s.bulkadmin, s.hasaccess, l.is_disabled
                FROM sys.syslogins s
                LEFT JOIN sys.sql_logins l ON s.name = l.name;"

            $logins    = @()
            $chkAccess = $false
            foreach ($row in $ds.Tables[0].Rows) {
                $privilege = @()
                foreach ($col in $ds.Tables[0].Columns) {
                    $colname = $col.ColumnName
                    if ($colname -notin @("loginname","hasaccess","is_disabled") -and $row[$colname]) {
                        $privilege += $colname
                    }
                }
                if (($row.loginname -in $access_groups) -and ("sysadmin" -in $privilege) -and ($row.is_disabled -ne $true)) {
                    $chkAccess = $true
                }
                $logins += [PSCustomObject]@{
                    SQL_LoginName  = $row.loginname
                    SQL_Privileges = $privilege
                    is_Disabled    = $row.is_disabled
                }
            }
            if (!$chkAccess) { $obj_instance.is_Accessible = $false }
            $obj_instance | Add-Member -MemberType NoteProperty -Name SQL_Logins -Value $logins

            # Database status
            $ds_dbstatus = Invoke-SqlQuery -Conn $SQLConnection -Query "
                SELECT name, state_desc, is_read_only, is_in_standby, is_auto_close_on, is_encrypted,
                       recovery_model_desc, is_published, is_subscribed, is_merge_published, is_distributor
                FROM sys.databases;"
            foreach ($row in $ds_dbstatus.Tables[0].Rows) {
                if ($row.is_published -or $row.is_subscribed -or $row.is_merge_published -or $row.is_distributor) {
                    $obj_instance.HADR += "REP"; break
                }
            }

            # Always On AG
            $ds_ag = New-Object System.Data.DataSet
            if ($obj_instance.is_AlwaysOn) {
                $ds_ag = Invoke-SqlQuery -Conn $SQLConnection -Query "
                    SELECT db.name AS DB_name, ag.name AS AG_name,
                           rep.replica_server_name AS Replica_name,
                           drs.is_primary_replica, drs.synchronization_state_desc,
                           drs.synchronization_health_desc, rep.availability_mode_desc,
                           rep.failover_mode_desc, agl.dns_name AS AG_Listener,
                           rep.secondary_role_allow_connections_desc AS ReadableSecondary,
                           drs.is_suspended, drs.is_local
                    FROM sys.availability_replicas rep
                    FULL OUTER JOIN sys.dm_hadr_database_replica_states drs ON rep.replica_id = drs.replica_id
                    JOIN sys.availability_groups ag ON ag.group_id = rep.group_id
                    LEFT JOIN sys.availability_group_listeners agl ON agl.group_id = rep.group_id
                    LEFT JOIN sys.sysdatabases db ON db.dbid = drs.database_id;"
                if ($ds_ag.Tables[0].Rows.Count -eq 0) { $obj_instance.is_AlwaysOn = $false }
                else { $obj_instance.HADR += "AG" }
            }

            # Mirroring
            $ds_mirror = Invoke-SqlQuery -Conn $SQLConnection -Query "
                SELECT db.name AS DB_name, mir.mirroring_state_desc, mir.mirroring_role_desc,
                       mir.mirroring_partner_instance, mir.mirroring_witness_name
                FROM sys.database_mirroring mir
                JOIN sys.sysdatabases db ON db.dbid = mir.database_id
                WHERE mir.mirroring_guid IS NOT NULL;"
            if ($ds_mirror.Tables[0].Rows.Count -gt 0) { $obj_instance.HADR += "MIR" }

            # DB sizes
            $ds_sizes = Invoke-SqlQuery -Conn $SQLConnection -Query "
                SELECT DB_Name(database_id) AS Name,
                       CAST(SUM(size) * 8.0 / (1024 * 1024) AS DECIMAL(12,4)) AS Size_GB
                FROM sys.master_files WITH (NOWAIT)
                GROUP BY database_id;"

            # Service start time
            $ds_start = Invoke-SqlQuery -Conn $SQLConnection -Query "SELECT sqlserver_start_time FROM sys.dm_os_sys_info;"
            $obj_instance | Add-Member -MemberType NoteProperty -Name Service_LastStart -Value $ds_start.Tables[0].Rows[0]["sqlserver_start_time"]

            # TempDB
            $ds_tempdb = Invoke-SqlQuery -Conn $SQLConnection -Query "
                SELECT counter_name, cntr_value / 1024 AS Size_inMB
                FROM sys.dm_os_performance_counters
                WHERE counter_name IN (
                    'Data File(s) Size (KB)',
                    'Log File(s) Size (KB)',
                    'Log File(s) Used Size (KB)')
                  AND instance_name = 'tempdb';"
            $obj_tempdb = [PSCustomObject]@{}
            foreach ($row in $ds_tempdb.Tables[0].Rows) {
                switch ($row.counter_name.Trim()) {
                    "Data File(s) Size (KB)"     { $obj_tempdb | Add-Member NoteProperty DataFile_inMB      $row.Size_inMB }
                    "Log File(s) Size (KB)"      { $obj_tempdb | Add-Member NoteProperty LogFile_Total_inMB $row.Size_inMB }
                    "Log File(s) Used Size (KB)" { $obj_tempdb | Add-Member NoteProperty LogFile_Used_inMB  $row.Size_inMB }
                }
            }
            $obj_instance | Add-Member -MemberType NoteProperty -Name TempDB_Details -Value $obj_tempdb

            $SQLConnection.Close()

            # Backups and Agent Jobs (msdb)
            $SQLConnection.ConnectionString = "Server=$($obj_instance.Connection_String);Database=msdb;Integrated Security=True;Connect Timeout=15;"
            $SQLConnection.Open()

            $ds_backup = Invoke-SqlQuery -Conn $SQLConnection -Query "
                SELECT bset.database_name,
                       CAST(bset.backup_size / (1024.0 * 1024) AS DECIMAL(12,4)) AS BackupSize_inMB,
                       bset.backup_finish_date AS Latest_BackupDate,
                       CASE bset.[type]
                           WHEN 'D' THEN 'Full'
                           WHEN 'I' THEN 'Differential'
                           WHEN 'L' THEN 'Transaction Log'
                           ELSE bset.[type]
                       END AS BackupType,
                       bmed.physical_device_name AS Latest_BackupMediaPath
                FROM msdb.dbo.backupset bset
                JOIN msdb.dbo.backupmediafamily bmed ON bset.media_set_id = bmed.media_set_id
                WHERE bset.backup_finish_date = (
                    SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset subq
                    WHERE subq.database_name = bset.database_name);"

            $ds_jobs = Invoke-SqlQuery -Conn $SQLConnection -Query "
                SELECT j.name, sl.name AS owner, j.enabled AS is_Enabled,
                       CASE jh.run_status
                           WHEN 0 THEN 'Failed'   WHEN 1 THEN 'Succeeded'
                           WHEN 2 THEN 'Retry'    WHEN 3 THEN 'Cancelled'
                           WHEN 4 THEN 'In Progress' ELSE 'Unknown'
                       END AS last_run_status,
                       ja.run_requested_date AS last_run_date,
                       ja.next_scheduled_run_date AS next_run,
                       jh.message AS run_message
                FROM sysjobactivity ja
                LEFT JOIN sysjobhistory jh ON ja.job_history_id = jh.instance_id
                JOIN sysjobs_view j ON ja.job_id = j.job_id
                JOIN sys.sql_logins sl ON j.owner_sid = sl.sid
                WHERE ja.session_id = (SELECT MAX(session_id) FROM sysjobactivity);"
            $sql_jobs = @()
            foreach ($row in $ds_jobs.Tables[0].Rows) {
                $sql_jobs += [PSCustomObject]@{
                    SQL_JobName     = $row.name
                    SQL_JobOwner    = $row.owner
                    is_Enabled      = $row.is_Enabled
                    LastRun_Status  = $row.last_run_status
                    LastRun_Date    = $row.last_run_date
                    LastRun_Message = $row.run_message
                    NextRun_Date    = $row.next_run
                }
            }
            $obj_instance | Add-Member -MemberType NoteProperty -Name SQL_Jobs -Value $sql_jobs

            # Log Shipping
            $ds_ls_pri = Invoke-SqlQuery -Conn $SQLConnection -Query "
                SELECT pdb.primary_database, ls.secondary_server, ls.secondary_database
                FROM log_shipping_primary_secondaries ls
                JOIN log_shipping_primary_databases pdb ON pdb.primary_id = ls.primary_id;"
            $ds_ls_sec = Invoke-SqlQuery -Conn $SQLConnection -Query "
                SELECT secondary_database, primary_server, primary_database
                FROM log_shipping_monitor_secondary;"
            $SQLConnection.Close()

            $ds_ls_det = New-Object System.Data.DataSet
            if ($ds_ls_pri.Tables[0].Rows.Count -gt 0 -or $ds_ls_sec.Tables[0].Rows.Count -gt 0) {
                $obj_instance.HADR += "LS"
                $SQLConnection.ConnectionString = "Server=$($obj_instance.Connection_String);Database=master;Integrated Security=True;Connect Timeout=15;"
                $SQLConnection.Open()
                $ds_ls_det = Invoke-SqlQuery -Conn $SQLConnection -Query "EXEC sp_help_log_shipping_monitor;"
                $SQLConnection.Close()
            }

            # Build per-database objects
            foreach ($row in $ds_dbstatus.Tables[0].Rows) {
                $size_row     = $ds_sizes.Tables[0].Rows | Where-Object { $_.Name -eq $row.name }
                $obj_database = [PSCustomObject]@{
                    Name           = $row.name
                    DB_Status      = $row.state_desc
                    is_Read_Only   = $row.is_read_only
                    is_in_Standby  = $row.is_in_standby
                    is_Encrypted   = $row.is_encrypted
                    is_AutoClose   = $row.is_auto_close_on
                    Recovery_Model = $row.recovery_model_desc
                    DBSize_inGB    = if ($size_row) { $size_row.Size_GB } else { $null }
                    HADR           = @()
                }

                $bk = $ds_backup.Tables[0].Rows | Where-Object { $_.database_name -eq $row.name }
                if ($bk) {
                    $obj_database | Add-Member NoteProperty Last_BackUp_On  $bk.Latest_BackupDate
                    $obj_database | Add-Member NoteProperty BackUpSize_inMB $bk.BackupSize_inMB
                    $obj_database | Add-Member NoteProperty Backup_Type     $bk.BackupType
                    $obj_database | Add-Member NoteProperty BackUp_Path     $bk.Latest_BackupMediaPath
                }

                if ($row.is_published -or $row.is_subscribed -or $row.is_merge_published -or $row.is_distributor) {
                    $obj_database.HADR += "REP"
                    $rep_role = @()
                    if ($row.is_published)       { $rep_role += "PUBLISHED" }
                    if ($row.is_subscribed)      { $rep_role += "SUBSCRIBED" }
                    if ($row.is_merge_published) { $rep_role += "MERGE-PUBLISHED" }
                    if ($row.is_distributor)     { $rep_role += "DISTRIBUTOR" }
                    $obj_database | Add-Member NoteProperty Replication_Role $rep_role
                }

                $mir_row = $ds_mirror.Tables[0].Rows | Where-Object { $_.DB_name -eq $row.name }
                if ($mir_row) {
                    $obj_database.HADR += "MIR"
                    $obj_database | Add-Member NoteProperty Mirroring_Role    $mir_row.mirroring_role_desc
                    $obj_database | Add-Member NoteProperty Mirroring_State   $mir_row.mirroring_state_desc
                    $obj_database | Add-Member NoteProperty Mirroring_Partner $mir_row.mirroring_partner_instance
                    if ($mir_row.mirroring_witness_name) {
                        $obj_database | Add-Member NoteProperty Mirroring_Witness $mir_row.mirroring_witness_name
                    }
                }

                if ($ds_ag.Tables.Count -gt 0) {
                    $ag_row = $ds_ag.Tables[0].Rows | Where-Object { $_.DB_name -eq $row.name -and $_.is_local -eq $true }
                    if ($ag_row) {
                        $obj_database.HADR += "AG"
                        $replica_info = if ($ag_row.is_primary_replica) {
                            $ds_ag.Tables[0].Rows | Where-Object { $_.DB_name -eq $row.name -and $_.is_local -ne $true }
                        } else {
                            $ds_ag.Tables[0].Rows | Where-Object { $_.AG_name -eq $ag_row.AG_name -and $_.is_local -ne $true } |
                                Select-Object AG_name, Replica_name, availability_mode_desc, failover_mode_desc, ReadableSecondary
                        }
                        $obj_database | Add-Member NoteProperty AG_Name              $ag_row.AG_name
                        $obj_database | Add-Member NoteProperty is_AG_PrimaryReplica $ag_row.is_primary_replica
                        $obj_database | Add-Member NoteProperty AG_SyncState         $ag_row.synchronization_state_desc
                        $obj_database | Add-Member NoteProperty AG_HealthState       $ag_row.synchronization_health_desc
                        $obj_database | Add-Member NoteProperty AG_AvailMode         $ag_row.availability_mode_desc
                        $obj_database | Add-Member NoteProperty AG_FailoverMode      $ag_row.failover_mode_desc
                        $obj_database | Add-Member NoteProperty AG_ReadableSecondary $ag_row.ReadableSecondary
                        $obj_database | Add-Member NoteProperty AG_ReplicaInfo       $replica_info
                        $obj_database | Add-Member NoteProperty is_AG_Suspended      $ag_row.is_suspended
                        if ($ag_row.AG_Listener) {
                            $obj_database | Add-Member NoteProperty AG_Listener $ag_row.AG_Listener
                        }
                    }
                }

                $in_ls_pri = $ds_ls_pri.Tables[0].Rows | Where-Object { $_.primary_database   -eq $row.name }
                $in_ls_sec = $ds_ls_sec.Tables[0].Rows | Where-Object { $_.secondary_database -eq $row.name }
                if ($in_ls_pri -or $in_ls_sec) {
                    $obj_database.HADR += "LS"
                    if ($in_ls_pri) {
                        $obj_database | Add-Member NoteProperty LogShipping_Role              "Primary"
                        $obj_database | Add-Member NoteProperty LogShipping_SecondaryServer   $in_ls_pri.secondary_server
                        $obj_database | Add-Member NoteProperty LogShipping_SecondaryDatabase $in_ls_pri.secondary_database
                    }
                    elseif ($in_ls_sec) {
                        $obj_database | Add-Member NoteProperty LogShipping_Role            "Secondary"
                        $obj_database | Add-Member NoteProperty LogShipping_PrimaryServer   $in_ls_sec.primary_server
                        $obj_database | Add-Member NoteProperty LogShipping_PrimaryDatabase $in_ls_sec.primary_database
                    }
                    if ($ds_ls_det.Tables.Count -gt 0) {
                        $ls_row = $ds_ls_det.Tables[0].Rows | Where-Object {
                            $_.database_name -eq $row.name -and $obj_instance.Connection_String -like ($_.server + "*")
                        }
                        if ($ls_row) {
                            $ls_health = if ($ls_row.status -eq $false) { "Healthy" } else { "Unhealthy" }
                            $ls_alert  = if ($ls_row.is_primary -eq $true) { "is_backup_alert_enabled" } else { "is_restore_alert_enabled" }
                            $obj_database | Add-Member NoteProperty LogShipping_Health         $ls_health
                            $obj_database | Add-Member NoteProperty "LogShipping_$ls_alert"    $ls_row.$ls_alert
                        }
                    }
                }

                if ($obj_database.HADR.Count -gt 0) {
                    $obj_instance.Databases += $obj_database
                } else {
                    $obj_instance.Databases += $obj_database | Select-Object -Property * -ExcludeProperty HADR
                }
            }
        }
    }

    $obj_server.Instances += $obj_instance
}

#region Windows Cluster
if ($cluster_flag) {
    $clustername = (Get-ItemProperty "HKLM:\Cluster").ClusterName
    $obj_cluster = [PSCustomObject]@{ ClusterName = $clustername }

    if (($services | Where-Object { $_.Name -eq "ClusSvc" }).State -eq "Running") {
        $clu_resources = Get-ClusterResource | Select-Object Name, State, OwnerGroup, ResourceType
        $clu_groups    = Get-ClusterGroup |
            Where-Object { $_.Name -ne "Available Storage" -and $_.Name -ne "Cluster Group" } |
            Select-Object Name, State, OwnerNode, GroupType, @{N='is_AutoFailback'; E={$_.AutoFailbackType}}

        $groups = @()
        foreach ($g in $clu_groups) {
            $res = $clu_resources | Where-Object { $_.OwnerGroup -eq $g.Name } | ForEach-Object {
                [PSCustomObject]@{ Name = $_.Name; State = $_.State.ToString(); ResourceType = $_.ResourceType.Name }
            }
            $groups += [PSCustomObject]@{
                GroupName       = $g.Name
                State           = $g.State.ToString()
                OwnerNode       = $g.OwnerNode.Name
                is_AutoFailback = $g.is_AutoFailback
                Group_Resources = @($res)
            }
        }
        $obj_cluster | Add-Member NoteProperty Cluster_Groups $groups

        $clu_partners = @(Get-ClusterNode | Where-Object { $_.Name -ne $env:COMPUTERNAME } | ForEach-Object {
            [PSCustomObject]@{ Name = $_.Name; State = $_.State.ToString() }
        })
        $obj_cluster | Add-Member NoteProperty Cluster_Partners $clu_partners
    }

    $obj_server | Add-Member NoteProperty Windows_Cluster $obj_cluster
}
#endregion

#region Pending reboot
$pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations
$obj_server.is_PendingFileRenameOperations = [bool]$pending
#endregion

$filename = "$($env:COMPUTERNAME)_server_$($run_datetime.ToString('MM_dd_yyyy_HH_mm_ss'))"
$obj_server | Export-Clixml   "$details_path\$filename.xml"
$obj_server | ConvertTo-Json -Depth 6 | Out-File "$details_path\$filename.json" -Encoding UTF8

return $filename
