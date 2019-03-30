$run_datime = (Get-Date).ToUniversalTime()
$target_path = "C:\SQL_Patch"
if(!(Test-Path "$target_path\ServerDetails")) {
    if(!(Test-Path $target_path)) {
        New-Item -Path C: -Name "SQL_PATCH" -ItemType Directory
    }
    New-Item -Path $target_path -Name "ServerDetails" -ItemType Directory 
}
 
 
 $instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances
 $cluser_flag=$false
 $domain = "AD-ENT"
 $access_groups = @("$domain\PRV_EDM_DA_SRV_SQL_PF","$domain\PRV_EDM_DA_SRV_WFISDBAdmins")
 
 if($instances) {
     $services = Get-WmiObject win32_service | ? {$_.name -like "*SQL*" -or $_.name -like "*OLAP*" -or $_.name -like "MsDts*" -or $_.name -like "*ReportServer*" -or $_.name -like "*DBSmart*" -or $_.name -like "clusSvc"} |Select-Object Name,State,StartMode,StartName  
     $lastbootup = Get-WmiObject win32_operatingsystem | select @{LABEL='LastBootUpTime';EXPRESION={$_.ConverttoDateTime($_.lastbootuptime}}
     $disks = gwmi win32_logicaldisk | select DeviceId, @{n="Size";e={[math]::Round($_.Size/1GB,2)}},@{n="Freespace";e={[math]::Round($_.FreeSpace/1GB,2)}}
     $obj_server = [PSCustomObject]@{
         ServerName = $env:COMPUTERNAME
         Services = $services
         Instaces = @()
         is_Accessible =$false
         LastBootUpTime = $lastbootup.LastBootUpTime
         Disks = $disks
         Ran_at = $run_datime
         Domain = $domain
     }
     
     #region check for local admin group 
     $admin_groups = net localgroup adminstrators
     foreach($line in $admin_groups) {
         if($line -in $access_groups) {
            $obj_server.Is_Accessible = $true
            Break;
         }
     }
     #endregion check for local admin group
     
     foreach ($instances in $instances) {
      
        $path = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Serve\Instance Names\SQL').$instance
        $pathlevel = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$path\Setup").PatchLevel
        $tcpport = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$path\MSQLServer\SuperSocketNetLib\Tcp\IPAll").TcpPort
        if($tcpport) {
            $type="STATIC"
        }
        else {
            $type="DYNAMIC"
            $tcpport = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$path\MSQLServer\SuperSocketNetLib\Tcp\IPAll").TcpDynamicPorts
        }
        switch -Wildcard ($pathlevel) {
            "10.0*" {$SQL_Version = "SQL2008"}
            "10.50*" {$SQL_Version = "SQL2008R2"}
            "11.*" {$SQL_Version = "SQL2012"}
            "12.*" {$SQL_Version = "SQL2014"}
            "13.*" {$SQL_Version = "SQL2016"}
            "14.*" {$SQL_Version = "SQL2017"}
        }

        $obj_instance = [PSCustomObejct]@{
            InstanceName = $instance
            PatchLevel = $patchlevel
            SQL_Version = $SQL_Version
            TCP_PORT_TYPE = $type
            TCP_PORT_NUMBER = $tcpport
            is_Active = $false
            Databases = @()
            is_Accessible = $false
            is_Clustered = $false
            is_AlwaysOn = $false
            Connection_String="$env:Computername\$instance,$tcpport"
            HADR = @()
        }

        $obj_server.Instances += $obj_instance
        #region Registry info
        if($instance -eq "MSSQLSERVER") {
            $engine = $obj_server.Services | ? {$_.Name -eq "MSSQLSERVER"}
        }
        else {
            $engine = $obj_server.Services | ? {$_.Name -eq "MSSQL`$$instance"}
        }
        if($engine.state -eq "Running") {
            $obj_instance.is_Active = $true
        }
        else{
            $obj_instance.is_Accessible = $null;
        }
        
        if(Test-Path "HKLM:\Cluster") {
            $cluster_flag=$true
            if (Test-Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$path\cluster") {
                $obj_instance.is_Clustered = $true
                $flag++
                $virtualname = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$path\cluster").Clustername
                $obj_instance | Add-Member -MemberType NoteProperty -Name SQL_VirtualName -Value $virtualname
                $obj_instance.Connection_String="$Virtualname\$instance,$tcpport"
            }

            if (Test-Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$path\MSSQLSERVER\HADR") {
                if ((Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$path\MSSQLSERVER\HADR").HADR_Enabled) {
                    $obj_instance.is_Alwayson=$true
                }
            }
        }
        #endregion Registry info

        if($obj_instance.is_Active) {
            Try
            {
                $SQLConnection = New-Object System.Data.SqlClient.SqlConnection
                $string = $obj_instance.Connection_String
                $SQLConnection.ConnectionString ="server=$string;database=master;Intergrated Security=True;"
                $SQLConnection.Open()
                $obj_instance.Is_Accessible=$true
            }
            catch
            {
                [System.Windows.Forms.MessageBox]::show("Failed to connect SQL Server:")
            }
            if($obj_instance.is_Accessible) {
                $SQLCommand = New-Object System.Data.SqlClient.SqlDataAdapter
                
                #region about version 
                $SQLCommand.CommandText = "Select @@version as version;"
                $SQLCommand.Connection = $SQLConnection
                $SQLAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
                $SqlAdapter.SelectCommand = $SQLCommand
                $About_Version = New-Object System.Data.DataSet
                $SQLAdapter.fill($About_Version) | out-null
                $obj_instance | Add-Member -MemberType NoteProperty -Name About_version $About_Version.Tables.rows.version
                #endregion about version 
                
                #region SQL Logins
                $SQLCommand.CommandText = "Select s.loginname, s.sysadmin, s.securityadmin, s.serveradmin, s.setupadmin,
                    s,processadmin, s.diskadmin, s.dbcreator, s.bulkadmin, s.hasacess, l.is_disabled
                    from sys.syslogins s left joi sys.sql_logins l on s.name=l.name;"
                $SQLCommand.Connection = $SQLConnection
                $SQLAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
                $SqlAdapter.SelectCommand = $SQLCommand
                $SQL_Logins =New-Object System.Data.DataSet
                $SqlAdapter.fill($SQL_Logins) | out-null
                $logins=@()
                $chkAccess = $false
                foreach($row in $SQL_Logins.Tables.rows) {
                    $obj_login=[PSCustomObject]@{}
                    $privillege = @()
                    foreach($col in ($SQL_Logins.Tables.columnc | select -Property columnname).columname ) {
                        if(($col -ne "loginname") -and ($col -ne "hasaccess") -and ($col -ne "is_disabled")) {
                            if($row.$col) {
                                $privillege += $col
                            }
                        }
                    }
                    if(($row.loginname -in $access_groups) -and ("sysadmin" -in $privillege) -and ($row.is_disabled -ne $true)) {
                        $chkAccess = $true
                    }
                    $obj_login | Add-Member -MemberType NoteProperty -Name SQL_LoginName -Value $row.loginname
                    $obj_login | Add-Member -MemberType NoteProperty -Name SQL_Privileges -Value $privilage
                    $obj_login | Add-Member -MemberType NoteProperty -Name is_Disabled -Value $row.is_disabled
                    $logins+=$obj_login
                }
                if($chkAccess -eq $false) {
                    $obj_instance.IS_Accessible = $false
                }
                $obj_instance | Add-Member -MemberType NoteProperty -Name SQL_Privileges -Value $logins 
                #endregion SQL Logins
                
                #region DB Status
                $SQLCommand.CommandText = "select name, state_desc, is_read_only,
                    is_in_standby, is_auto_close_on, is_encrypted,
                    recovery_model_desc, is_published, is_subscribed,
                    is_merge_published,is_distributor
                    from sys.databases;"
                $SQLCommand.Connection = $SQLConnection 
                $SQLAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
                $SqlAdapter.SelectCommand = $SQLCommand
                $SQLDB_Status = New-Object System.Data.Dataset 
                $SQLAdapter.fill($SQLDB_Status) |out-null 

                foreach($row in $SQLDB_Status.Tables.rows) {
                    if($row.is_published -or $row.is_subscribed -or $row.is_merge_published -or $row.is_distributo) {
                        $obj_instance.HADR += "REP"
                        break;
                    }
                }
                #endregion DB Status

                #region AG data
                if($obj_instance.is_Alwayson) {
                    $SQLCommand.CommandText = "Select db.name as DB_name,ag.name as AD_name,
                        rep.replica_server_name as Replica_name,
                        drs.is_primary_replica, drs.sunchronization_state_desc,
                        rep.failover_mode_desc, agl.dns_name as AG_Listener,
                        rep.secondary_role_allow_connections_desc as ReadableSecondary,
                        drs.is_suspended, drs.is_local
                        from sys.availablilty_replicas rep
                        full outer join sys.dm_hadr_database_replica_states drs on rep.replica_id=drs.replica_id
                        join sys.availablity_groups ag on ag.group_id=rep.group_id
                        left join sys.availability_group_listeners agl on agl.group_id=rep.group_id
                        left join sys.sysdatabases db on db.dbid=drs.database_id;"
                    $SQLAdapter.SelectCommand = $SQLCommand
                    $SQLAG_Status = New-Object System.Data.DataSet
                    $SQLAdapter.fill($SQLAG_Status) | out-null
                    if(!($SQLAG_Status.Tables.rows)) {
                        $obj_instance.is_AlwaysOn=$false
                    }
                    else {
                        $obj_instance.HADR += "AG"
                    }
                }
                #endregion AG data

                #region Mirroring data
                $SQLCommand.CommandText = "select db.name as DB.name, mir.mirroring_state_desc, mir.mirroring_role_desc,
                    mir.mirroring_partner_instance, mir.mirroring_witness_name
                    from sys.database_mirroring mir
                    join sys.sysdatabases db on db.dbid=mir.database_id
                    where mir.mirroring_guid is not null;"
                $SQLAdapter.SelectCommand = $SQLCommand
                $Mirroring_Status = New-Object System.Data.Datatset
                $SQLAdapter.fill($Mirroring_Status) | Out-Null
                
                if($Mirroring_Status.Tables.rows) {
                    $obj_instance.HADR +="MIR"
                }
                #endregion Mirroring data data 
                
                #region dbsize, service restart, tempdb
                $SQLCommand.CommandText = "SELECT Name = DB_Name(database_id),
                    Size = CAST(SUM(size) * 8. / (1024*10240 AS DECIMAL(12,4))
                    FROM sys.master_files WITH(NOWAIT)
                    GROUP BY database_id;"
                $SQLAdapter.SelectCommand = $SQLCommand
                $dbsize = New-Object System.Data.DataSet
                $SQLAdapter.fill($dbsize) | Out-Null
                
                $SQLCommand.CommandText = "SELECT sqlserver_start_time FROM sys.dm_os_sys_info;"
                $SQLAdapter.SelectCommand = $SQLCommand
                $start_time = New-Object System.Data.DataSet
                $SQLAdapter.fill($start_time) | Out-Null
                $obj_instance | Add-Member -MemberType NoteProperty -Name Servie_LastStart -Value $start_time.Tables.sqlserver_start_time
                
                $SQLCommand.CommandText = "SELECT Counter_name, cntr_value/1024 as Size_inMB
                    FROM sys.dm_os_performance_counters
                    WHERE counter_name IN ('Data file(s) Size (KB)','Log File(s) Size (KB)', Log File(s) Used Size (KB)')
                    AND instance_name = 'tempdb';"
                $SQLAdapter.SelectCommand = $SQLCommand
                $tempdb = New-Object System.Data.DataSet
                $SQLAdapter.fill($tempdb) | Out-Null
                $obj_tempdb=[PSCustomObject]@{}
                foreach($row in $tempdb.Tables.rows) {
                    switch($row.counter_name_Trim()) {
                        "Data File(s) Size (KB)" {
                            $obj_tempdb | Add-Member -MemberType NoteProperty -Name DataFile_inMB -Value $row.Size_inMB
                        }
                        "Log File(s) Size (KB)" {
                            $obj_tempdb | Add-Member -MemberType NoteProperty -Name LogFile_Total_inMB -Value $row.Size_inMB
                        }
                        "Log File(s) Used Size (KB)" {
                            $obj_tempdb | Add-Member -MemberType NoteProperty -Name LogFile_Used_inMB -Value $row.Size_inMB
                        }
                    }
                }

                $obj_instance | Add-Member -MemberType NoteProperty -Name TempDB_Details -Value $obj_tempdb

                #endregion dbsize, service restart, tempdb

                $SQLConnection.close()

                #region backups, jobs
                $SQLConnection.ConnectionString ="server=$string;database=msdb;Integrated Security=True;"
                $SQLConnection.Open()
                $SQLCommand = New-Object System.Data.SqlClient.SqlCommand
                $SQLCommand.Connection = $SQLConnection
                $SQLCommand.CommandText = "select bset.database_name,BackupSize_inMB = CAST(bset.backup_size / (1024*1024) AS DECIMAL(12,4)),
                    bset.backup_finish_date as Latest_BackupDate,
                    CASE bset.[type]
                        WHEN 'D' THEN 'Full'
                        WHEN 'I' THEN 'Differential'
                        WHEN 'L' THEN 'Transaction Log'
                        ELSE bset.[type]
                    END as BackupType,
                    bmed.physical_device_name as Latest_BackupMediaPath
                    from msdb.dbo.backupset bset join msdb.dbo.backupmedia family bmed on bset.media_set_id = bmed.media_set_id
                    where bset.backup_finish_date = (select max(backup_finish_date) from msdb.dbo.backupset subq where subq.database_name = bset.database_name);"
                $SQLAdapter.SelectCommand = $SQLCommand
                $last_backup = New-Object System.Data.DataSet
                $SQLAdapter.Fill($last_backup) | out-null
                
                $SQLCommand.CommandText = "SELECT j.name, sl.name as owner, j.enabled as is_Enabled,
                    CASE jh.run_status WHEN 0 THEN 'Error Failed'
                        WHEN 1 THEN 'Succeeded'
                        WHEN 2 THEN 'Retry'
                        WHEN 3 THEN 'Cancelled'
                        WHEN 4 THEN 'In Progress' ELSE
                        'Status Unknown' END AS 'last_run_status',
                    ja.run_requested_date as last_run_date,
                    ja.next_scheduled_run_date as next_run,
                    jh.message as run_message
                    FROM (sysjobactivity ja EFT JOIN sysjobhistory jh ON ja.job_history_id = jh.instance_id)
                    join sysjobs_view j on ja.job_id = j.job_id
                    join sys.sql_logins sl on j.owner_sid = sl.sid
                    WHERE ja.session_id=(SELECT MAX (session_id) from sysjobactivity);"
                $SQLAdapter.SelectCommand = $SQLCommand
                $SQL_jobs = New-Object System.Data.DataSet
                $SQLAdapter.fill($SQL_jobs) Out-Null
                $jobs=@()
                foreach($row in $SQL_jobs.Tables.rows) {
                    $obj_job=[PSCustomObject]@{}
                    $obj_job | Add-Member -MemberType NoteProperty -Name SQL_JobName -Value $row.name
                    $obj_job | Add-Member -MemberType NoteProperty -Name SQL_JobOwner -Value $row.owner
                    $obj_job | Add-Member -MemberType NoteProperty -Name is_Enabled -Value $row.is_enabled
                    $obj_job | Add-Member -MemberType NoteProperty -Name LastRun_Status -Value $row.last_run_status
                    $obj_job | Add-Member -MemberType NoteProperty -Name LastRun_Data -Value $row.last_data_run
                    $obj_job | Add-Member -MemberType NoteProperty -Name LastRun_Message -Value $row.run_message 
                    $obj_job | Add-Member -MemberType NoteProperty -Name NextRun_Date -Value $row.next_run
                    $jobs+=$obj_job
                }
                $obj_instance | Add-Member -MemberType NoteProperty -Name SQL_Jobs -Value $jobs
                #endregion backups, jobs

                #region logshipping data
                $SQLCommand.CommandText = "select pdb.primary_database, ls.secondary_server,
                    ls.secondary_database from log_shipping_primary_secondaries ls
                    join log_shipping_primary_databases pdb on pdb.primary_id= ls.primary_id;"
                $SQLAdapter.SelectCommand = $SQLCommand
                $ls_pri = New-Object System.Data.DataSet
                $SQLAdapter.fill($ls_pri) | Out-Null

                $SQLCommand.CommandText = "select secondary_database, primary_server,
                    primary_database from log_shipping_monitor_secondary;"
                $SQLAdapter.SelectCommand = $SQLCommand
                $ls_sec = New-Object System.Data.DataSet
                $SQLAdapter.fill($ls_sec) | Out-Null

                $SQLConnection.Close()

                if($ls_pri.Tables.rows -or $ls_sec.Tables.rows) {
                    $obj_instance.HADR +="LS"
                    $SQLConnection.ConnectionString = "server=$string;database=master;Integrated Security=True;"
                    $SQLConnection.Open()
                    $SQLCommand = New-Object System.Data.SqlClient.SqlCommand
                    $SQLConnection.Connection=$SQLConnection
                    $SQLCommand.CommandText = "sp_help_log_shipping_monitor;"
                    $SQLAdapter.SelectCommand = $SQLCommand
                    $ls_det=New-Object System.Data.DataSet
                    $SQLAdapter.fill($ls_det) | Out-Null
                    $SQLConnection.close()
                }
                #endregion logshipping data

                foreach($table in $SQLDB_Status.Tables) {
                    foreach($row in $table) {
                        $obj_database = [PSCustomObject]@{
                            Name=$row.name
                            DB_Status=$row.state_desc
                            is_Read_Only=$row.is_read_only
                            is_in_Standby=$row.is_in_standby
                            is_Encrypted=$row.is_Encrypted
                            is_AutoClose=$row.is_auto_close_on
                            Recovery_Model=$row.recovery_model_desc
                            DBSize_inGB=$dbsize.Tables.rows | % -Process {if($_.Name -eq $row.name) {$_.Size} }
                            HADR=@()
                        }

                        if($row.name -in $last_backup.Tables.database_name) {
                            $data_backup = $last_backup.Tables.rows | ? {$_.database_name -eq $row.name}
                             $obj_database | Add-Member -MemberType NoteProperty -Name Last_BackUp_On -Value $data_backup.Latest_BackupDate
                             $obj_database | Add-Member -MemberType NoteProperty -Name BackUpSize_inMB -Value $data_backup.BackupSize_inMB
                             $obj_database | Add-Member -MemberType NoteProperty -Name Backup_Type -Value $data_backup.BackupType
                             $obj_database | Add-Member -MemberType NoteProperty -Name BackUp_Path -Value $data_backup.Latest_BackupMediaPath
                        }

                        if($row.is_published -or $row.is_subscribed -or $row.is_merge_published -or $row.is_distributor) {
                            $obj_database.HADR += "REP"
                            $rep_role=@()
                            if($row.is_published) {
                                $rep_role += "PUBLISHED"
                            }
                            if($row.is_subscribed) {
                                $rep_role += "SUBSCRIBED"
                            }
                            if($row.is_merge_published) {
                                $rep_role += "MERGE-PUBLISHED"
                            }
                            if($row.is_distributor) {
                                $rep_role += "DISTRIBUTOR"
                            }
                            $obj_database | Add-Member -MemberType NoteProperty -Name Replication_Role -Value $rep_role
                        }

                        if($row.name -in $Mirroring_Status.tables.DB_name) {
                            $obj_database.HADR += "MIR"
                            $temp_mir=$Mirroring_Status.Tables.rows | ? {$_.DB_name -eq $row.name}
                            $obj_database | Add-Member -MemberType NoteProperty -Name Mirroring_Role -Value $temp_mir.mirroring_role_desc
                            $obj_database | Add-Member -MemberType NoteProperty -Name Mirroring_State -Value $temp_mir.mirroring_state_desc
                            $obj_database | Add-Member -MemberType NoteProperty -Name Mirroring_Partner -Value $temp_mir.mirroring_partner_instance
                            if($temp_mir.mirroring_witness_name) {
                                $obj_database | Add-Member -MemberType NoteProperty -Name Mirroring_Witness -Value $temp_mir.mirroring_witness_name
                            }
                        }

                        if($row.name -in $SQLAG_Status.Tables.DB_name) {
                            $obj_database.HADR += "AG"
                            $temp_ag=$SQLAG_Status.Tables.rows | ? {($_.DB_name -eq $row.name) -and ($_.is_local -eq $true)}
                            $obj_database | Add-Member -MemberType NoteProperty -Name AG_Name -Value $temp_ag.AG_name
                            $obj_database | Add-Member -MemberType NoteProperty -Name is_AG_PrimaryReplica -Value $temp_ag.is_primary_replica
                            if($temp_ag.is_primary_replica) {
                                $replica_info = $SQLAG_Status.Tables.rows | ? {($_.DB_name -eq $row.name) -and ($_.AG_name -eq $temp_ag.AG_name) -and ($_.is_local -ne $true)}
                            }
                            else {
                                $replica_info = $SQLAG_Status.Tables.rows | ? {($_.AG_name -eq $temp_ag.name) -and ($_.is_local -ne $true)} | select -Property AG_name,Replica_name,availablity_mode_desc_,failover_mode_desc,ReadableSecondary
                            }
                            $obj_database | Add-Member -MemberType NoteProperty -Name AG_SyncState -Value $temp_ag.synchronization_state_desc
                            $obj_database | Add-Member -MemberType NoteProperty -Name AG_HealthState -Value $temp_ag.synchronization_health_desc
                            $obj_database | Add-Member -MemberType NoteProperty -Name AG_AvailMode -Value $temp_ag.availability_mode_desc
                            $obj_database | Add-Member -MemberType NoteProperty -Name AG_FailoverMode -Value $temp_ag.failover_mode_desc
                            $obj_database | Add-Member -MemberType NoteProperty -Name AG_ReadableSecondary -Value $temp_ag.ReadableSecondary
                            $obj_database | Add-Member -MemberType NoteProperty -Name AG_ReplicaInfo -Value $replica_info
                            $obj_database | Add-Member -MemberType NoteProperty -Name is_AG_Suspended -Value $temp_ag.is_suspended
                            if($temp_ag.AG_Listener) {
                                $obj_database | Add-Member -MemberType NoteProperty -Name AG_Listener -Value $temp_ag.AG_Listener
                            }
                        }

                        if(($row.name -in $ls_pri.Tables.primary_database) -or ($row.name -in $ls_sec.Tables.secondary_database)) {
                            $obj_database.HADR += "LS"
                            if($row.name -in $ls_pri.Tables.primary_database) {
                                $temp_ls=$ls_pri.Tables.rows | ? {$_.primary_database -eq $row.name}
                                $obj_database | Add-Member -MemberType NoteProperty -Name LogShipping_Role -Value "Primary"
                                $obj_database | Add-Member -MemberType NoteProperty -Name LogShipping_SecondaryServer -Value $temp_ls.secondary_server
                                $obj_database | Add-Member -MemberType NoteProperty -Name LogShipping_SecondaryDatabase -Value $temp_ls.secondary_database
                            }
                            else if($row.name -in $ls_sec.Tables.secondary_database) {
                                $temp_ls=$ls_sec.Tables.rows | ? {$_.secondary_database -eq $row.name}
                                $obj_database | Add-Member -MemberType NoteProperty -Name LogShipping_Role -Value "Secondary"
                                $obj_database | Add-Member -MemberType NoteProperty -Name LogShipping_PrimaryServer -Value $temp_ls.primary_server
                                $obj_database | Add-Member -MemberType NoteProperty -Name LogShipping_PrimaryServer -Value $temp_ls.primary_server
                            }

                            $temp_ls=$ls_det.Tables.rows | ? {($_.database_name -eq $row.name) -and ($string -like $_.server+"*")}
                            if($temp_ls.status -eq $false) {
                                $ls_status = "Healthy"
                            }
                            elseif($temp_ls.status -eq $true) {
                                $ls_status = "Unhealthy"
                            }
                            if($temp_ls.is_primary -eq $true) {
                                $ls_alert = "is_backup_alert_enabled"
                            }
                            elseif($temp_ls.is_primary -eq $false) {
                                $ls_alert = "is_restore_alert_enabled"
                            }
                            $obj_database | Add-Member -MemberType NoteProperty -Name LogShipping_Health -Value $ls_status
                            $obj_database | Add-Member -MemberType NoteProperty -Name "LogShipping_$ls_alert" -Value $temp_ls.$ls_alert

                        }
                        
                        if([bool]($obj_database.HADR.Count)) {
                            $obj_instance.Databases += $obj_database
                        }
                        else {
                            $obj_instance.Databases +=$obj_database | Select-Object -Property * -ExcludeProperty HADR
                        }
                    }
                }

            }
        }
    }

    #region cluadmin data
    if($cluser_flag) {
        $clustername=(Get-ItemProperty "HKLM:\Cluster").ClusterName
        $Obj_cluster = [PSCustomObject]@{
            ClusterName = $clustername
        }
        if(($obj_server.Services | ? {$_.Name -eq "ClusSvc"}).State -eq "Running") {
            $groups=@()
            $clu_resource = Get-ClusterResource | select -Property name, state, ownergroup, resourcetype
            $clu_group = Get-ClusterGroup | ? {$_.name -ne "Available Storage" -and $_.name -ne "Cluster Group"} | select -Property name, state, ownernode, grouptype, @{N='is_AutoFailback';E={$_.AutoFailbackType}}
            foreach($g in $clu_group) {
                $res =@()
                foreach($r in $clu_resource ) {
                    if($r.ownergroup -eq  $g.name) {
                        $obj_clusterresource = [PSCustomObject]@{
                            Name = $r.Name
                            State = $r.State.ToString()
                            ResourceType = $r.ResourceType.Name
                        }
                        $res+= $obj_clusterresource
                    }
                }
                $obj_clustergroup = [PSCustomObject]@{
                    GroupName = $g.Name
                    State = $g.State.ToString()
                    OwnerNode = $g.OwnerNode.Name
                    is_AutoFailback = $g.is_AutoFailback
                    Group_Resources = $res
                }
                $groups+=$obj_clustergroup
            }
            $obj_cluster | Add-Member -MemberType NoteProperty -Name Cluster_Groups -Value $groups
            $clu_nodes = Get-ClusterNode | ? {$_.Name -ne $env:COMPUTERNAME}
            $clu_partners = @()
            $clu_nodes | % {
                $obj_clusterpartner = [PSCustomObject]@{
                    Name = $_.Name
                    State = $_.State.ToString()
                }
                $clu_partners+=$obj_clusterpartner
            }
            $obj_cluster | Add-Member -MemberType NoteProperty -Name Cluster_Partners -Value $clu_partners
        }
        $obj_server | Add-Member -MemberType NoteProperty -Name Windows_Cluster -Value $Obj_cluster
    }
    #endregion clauadmin data

    #region reboot required 
    $rebootreq = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').PendingFileRenameOperations
    if($rebootreq) {
        $obj_server | Add-Member -MemberType NoteProperty -Name is_PendingFileRenameOpertaions -Value $true
    }
    else {
        $obj_server | Add-Member -MemberType NoteProperty -Name is_PendingFileRenameOpertaions -Value $false
    }
    #endregion reboot required
}
 
 $filename = $env:Computername+"_server_"+$run_datime.ToString('MM_dd_yyyy_hh_mm_ss')
 $objserver | Export-Clixml "$targer_path\ServerDetails\$filename.xml"

 $json = ConvertTo-Json -InputObject $objserver -Depth 5
 $json | Out-File "$target_path\ServerDetails\$filename.json"
 return $filename








                                      
