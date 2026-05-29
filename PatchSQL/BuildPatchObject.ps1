param(
    [object]$ServerDetail
)

$server = $ServerDetail

$obj_server = [PSCustomObject]@{
    SName          = $server.ServerName
    is_PendingReboot = $server.is_PendingFileRenameOperations
    Versions       = @{}
    HADR           = @{}
    Instances      = @{}
    Stage_timer    = 0
    Display_Status = ""
    State          = ""
    SplInst        = ""
    isPri          = $null
    AG_Type        = $null
}

if ([bool]($server.Windows_Cluster)) {
    $obj_server | Add-Member -MemberType NoteProperty -Name Windows_Cluster -Value $server.Windows_Cluster
}

foreach ($instance in $server.Instances) {

    if ($instance.is_Clustered) {
        $id = if ($instance.InstanceName -eq "MSSQLSERVER") {
            "$($instance.SQL_VirtualName),$($instance.TCP_PORT_NUMBER)"
        } else {
            "$($instance.SQL_VirtualName)\$($instance.InstanceName)"
        }
        if (!$obj_server.HADR.ContainsKey("FC")) {
            $obj_server.HADR["FC"] = @()
        }
        $obj_server.HADR["FC"] += $id
    }
    else {
        $id = if ($instance.InstanceName -eq "MSSQLSERVER") {
            "$($server.ServerName),$($instance.TCP_PORT_NUMBER)"
        } else {
            "$($server.ServerName)\$($instance.InstanceName)"
        }
    }

    $obj_version = [PSCustomObject]@{
        ID         = $id
        IName      = $instance.InstanceName
        PatchLevel = $instance.PatchLevel
        State      = ""
    }

    if ($instance.SQL_Version -and !$obj_server.Versions.ContainsKey($instance.SQL_Version)) {
        $obj_server.Versions[$instance.SQL_Version] = @()
    }
    if ($instance.SQL_Version) {
        $obj_server.Versions[$instance.SQL_Version] += $obj_version
    }

    $obj_instance = [PSCustomObject]@{
        is_Active  = $instance.is_Active
        IName      = $instance.InstanceName
        TCP        = $instance.TCP_PORT_NUMBER
        is_Clustered = $instance.is_Clustered
        HADR       = @{}
        isPri      = $null
    }
    $obj_server.Instances[$id] = $obj_instance

    foreach ($hadr in $instance.HADR) {
        $obj_properties = [PSCustomObject]@{
            Priority = @()
            Partners = @()
        }

        $databases = $instance.Databases | Where-Object { $hadr -in $_.HADR }
        $partners  = @()
        $pri       = @()

        foreach ($db in $databases) {
            if ($hadr -eq "MIR") {
                if ($db.Mirroring_Role -eq "PRINCIPAL") { $pri += 1 }
                elseif ($db.Mirroring_Role -eq "MIRROR") { $pri += 2 }
                $partners += $db.Mirroring_Partner
            }
            elseif ($hadr -eq "AG") {
                if ($db.is_AG_PrimaryReplica)                          { $pri += 1 }
                elseif ($db.AG_AvailMode -eq "SYNCHRONOUS_COMMIT")     { $pri += 2 }
                elseif ($db.AG_AvailMode -eq "ASYNCHRONOUS_COMMIT")    { $pri += 3 }
                foreach ($row in $db.AG_ReplicaInfo) { $partners += $row.Replica_name }
            }
            elseif ($hadr -eq "LS") {
                if ($db.LogShipping_Role -eq "Primary") {
                    $pri += 1
                    $partners += $db.LogShipping_SecondaryServer
                }
                elseif ($db.LogShipping_Role -eq "Secondary") {
                    $pri += 2
                    $partners += $db.LogShipping_PrimaryServer
                }
            }
        }

        $obj_properties.Priority = @($pri      | Select-Object -Unique)
        $obj_properties.Partners = @($partners  | Select-Object -Unique)

        # Determine primary/secondary role for this instance
        if ($obj_properties.Priority.Count -le 1 -or 1 -notin $obj_properties.Priority) {
            if ($obj_instance.isPri -eq $null) {
                if ($hadr -eq "AG") {
                    if (1 -in $obj_properties.Priority) {
                        $obj_instance.isPri = 1
                    }
                    else {
                        $obj_instance.isPri = 0
                        $temp = if ((2 -in $obj_properties.Priority) -and (3 -in $obj_properties.Priority)) { "Both" }
                                elseif (2 -in $obj_properties.Priority) { "Sync" }
                                elseif (3 -in $obj_properties.Priority) { "Async" }
                                else { "Error" }
                        if ($obj_server.AG_Type -eq $null) { $obj_server.AG_Type = $temp }
                        elseif ($obj_server.AG_Type -ne $temp) { $obj_server.AG_Type = "Both" }
                    }
                }
                else {
                    $obj_instance.isPri = if (1 -in $obj_properties.Priority) { 1 } else { 0 }
                }
            }
            elseif ($obj_instance.isPri -eq 0 -and 1 -in $obj_properties.Priority) {
                $obj_instance.isPri = -1
            }
            elseif ($obj_instance.isPri -eq 1 -and 1 -notin $obj_properties.Priority) {
                $obj_instance.isPri = -1
            }
        }
        else {
            $obj_instance.isPri = -1
        }

        $obj_instance.HADR[$hadr] = $obj_properties
        if (!$obj_server.HADR.ContainsKey($hadr)) { $obj_server.HADR[$hadr] = @() }
        $obj_server.HADR[$hadr] += $id
    }
}

return $obj_server
