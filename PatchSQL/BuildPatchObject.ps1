$server = $args[0]

$obj_server = [PSCustomObject] @{
    SName = $server.Servername
    is_PendingReboot = $server.is_PendingFileRenameOperations
    Versions = @{}
    HADR = @{}
    Instances = @{}
    Stage_timer = 0
    Display_Status = ""
    State = ""
    SplInst = ""
    isPri = $null
    AG_Type = $null
}

if([bool]($server.Windows_Cluster)) {
    $obj_server | Add-Member -MemberType NoteProperty -Name Windows_Cluster -Value $server.Windows_Cluster
}
foreach($instance in $server.Instances) {
    if ($instance.is_Clustered) {
        if ($instance.InstanceName -eq "MSSQLSERVER") {
            $id = $instance.SQL_VirtualName+","+$instance.TCP_Port_Number
        }
        else {
            $id = $instance.SQL_VirtualName+"\"+$instance.InstanceName
        }
        if (!$obj_server.HADR.ContainsKey("FC")) {
            $obj_server.HADR."FC" = @()
        }
        $obj_server.HADR."FC" += $id
    }
    else {
        if ($instance.InstanceName -eq "MSSQLSERVER") {
            $id = $server.Servername+","+$instance.TCP_Port_Number
        }
        else {
            $id = $server.Servername+"\"+$instance.InstanceName
        }
    }
    $obj_version = [PSCustomObject]@{
        ID = $id
        IName = $instance.InstanceName
        PatchLevel = $instance.PatchLevel
        State = ""
    }
    if (($instance.SQL_Version -ne $null) -and !$obj_server.Versions.ContainsKey($instance.SQL_Version)) {
        $obj_server.Versions.($instance.SQL_Version) = @()
    }
    $obj_server.Versions.($instance.SQL_Version) += $obj_version

    $obj_instance = [PSCustomObject]@{
        is_Active = $instance.is_Active
        IName = $instance.InstanceName
        TCP = $instance.TCP_Port_Number
        is_Clustered = $instance.is_Clustered
        HADR = @{}
        isPri = $null
    }
    $obj_server.Instances.$id += $obj_instance
    foreach ($hadr in $instance.HADR) {
        $obj_properties = [PSCustomObject]@{
            Priority = @()
            Partners = @()
        }
        $databases = $instance.Databases | ? {hadr -in $_.HADR}
        $partners = @()
        $pri = @()
        foreach($db in $databases) {
            if ($hadr -eq "MIR") {
                if ($db.Mirroring_Role -eq "PRINCIPAL") {
                    $pri+=1
                }
                elseif ($db.Mirroring_Role -eq "MIRROR") {
                    $pri+=2
                }
                $partners += $db.Mirroring_Partner
            }
            elseif($hadr -eq "AG") {
                if($db.is_AG_PrimaryReplica) {
                    $pri+=1
                }
                elseif($db.AG_AvailMode -eq "SYNCHRONOUS_COMMIT") {
                    $pri+=2
                }
                elseif($db.AG_AvailMode -eq "ASYNCHRONOUS_COMMIT") {
                    $pri+=3
                }
                foreach($row in $db.ag_replicainfo) {
                    $partners+=$row.replica_name
                }
            }
            elseif ($hadr -eq "LS") {
                if($db.LogShipping_Role -eq "Primary") {
                    $pri+=1
                    $partners += $db.LogShipping_SecondaryServer
                }
                elseif($db.LogShipping_Role -eq "Secondary") {
                    $pri+=2
                    $partners += $db.LogShipping_PrimaryServer
                }
            }
        }
        $obj_properties.Priority = $pri | Select -Unique
        $obj_properties.Partners = $partners | Select -Unique
        if(($obj_properties.Priority.Count -le 1) -or (1 -notin $obj_properties.Priority)) {
            if($obj_instance.isPri -eq $null) {
                if($hadr -eq "AG") {
                    if(1 -in $obj_properties.Priority) {
                        $obj_instance.isPri = 1
                    }
                    else {
                        $obj_instance.isPri = 0
                        if((2 -in $obj_properties.Priority) -and (3 -in $obj_properties.Priority)) {
                            $temp = "Both"
                        }
                        elseif(2 -in $obj_properties.Priority) {
                            $temp = "Sync"
                        }
                        elseif(3 -in $obj_properties.Priority) {
                            $temp = "Async"
                        }
                        else {
                            $temp = "Error"
                        }
                        if($obj_server.AG_Type -eq $null) {
                            $obj_server.AG_Type = $temp
                        }
                        elseif($obj_server.AG_Type -ne $temp) {
                            $obj_server.AG_Type = "Both"
                        }
                    }
                }
                else {
                    if(1 -in $obj_properties.Priority) {
                        $obj_instance.isPri = 1
                    }
                    else {
                        $obj_instance.isPri = 0
                    }
                }
            }
            elseif($obj_instance.isPri -eq 0) {
                if(1 -in $obj_properties.Priority) {
                    $obj_instance.isPri = -1
                }
            }
            elseif($obj_instance.isPri -eq 1) {
                if(1 -notin $obj_properties.Priority) {
                    $obj_instance.isPri = -1
                }
            }
        }
        else {
            $obj_instance.isPri = -1
        }
        $obj_instance.HADR.$hadr = $obj_properties
        if(!$obj_server.HADR.ContainsKey($hadr)) {
            $obj_server.HADR.$hadr = @()
        }
        $obj_server.HADR.$hadr+=$id
        #$obj_server.HADR.$hadr+=$obj_properties.Partners
    }
}
return $obj_server