param(
    [string]$TargetNode,
    [int]   $Timeout,
    [string]$TargetPath,
    [object]$Cluster
)

$targetpath  = $TargetPath.Replace('$', ':')
$file        = "$targetpath\Patch_progress.txt"
$groups      = @()
$count        = 0
$success_count = 0

function log_time {
    return "[$(((Get-Date).ToUniversalTime()).ToString())] --"
}

if ($TargetNode -ne $env:COMPUTERNAME) {
    $type          = "over"
    $currentgroups = (Get-ClusterGroup | Where-Object { $_.OwnerNode -like $env:COMPUTERNAME }).Name
}
else {
    $type = "back"
}

foreach ($group in $Cluster.Cluster_Groups) {
    $gname = $group.GroupName
    $owned = ($type -eq "over" -and $gname -in $currentgroups) -or
             ($type -eq "back" -and $group.OwnerNode -eq $env:COMPUTERNAME)

    if ($owned) {
        if ([bool]($group.Group_Resources | Where-Object { $_.ResourceType -eq "SQL Server" })) {
            $group | Add-Member -MemberType NoteProperty -Name GroupType   -Value "SQL Group" -Force
            $group | Add-Member -MemberType NoteProperty -Name MoveResult  -Value "NA"        -Force
            $datime = log_time
            Add-Content $file -Value "$datime Moving $gname to $TargetNode"
            $job = Start-Job -Name "move_$gname" -ScriptBlock {
                param([string]$gname, [string]$targetnode)
                Move-ClusterGroup -Name $gname -Node $targetnode
            } -ArgumentList $gname, $TargetNode
            $group | Add-Member -MemberType NoteProperty -Name MoveJob -Value $job -Force
            $count++
        }
        elseif ([bool]($group.Group_Resources | Where-Object { $_.ResourceType -eq "SQL Server Availability Group" })) {
            $group | Add-Member -MemberType NoteProperty -Name GroupType -Value "AG Group"    -Force
        }
        else {
            $group | Add-Member -MemberType NoteProperty -Name GroupType -Value "Other Group" -Force
        }
        $groups += $group
    }
}

$timer = 0
while ($timer -lt $Timeout) {
    Start-Sleep -Seconds 30
    $timer++
    $pending = 0

    foreach ($group in $groups) {
        $gname = $group.GroupName
        if ($group.GroupType -eq "SQL Group" -and $group.MoveResult -eq "NA") {
            $pending++
            $job    = $group.MoveJob
            $datime = log_time
            if ($job.State -eq "Completed") {
                if ((Get-ClusterGroup $gname).State -eq "Online") {
                    Add-Content $file -Value "$datime $gname Fail$type to $TargetNode succeeded"
                    $group.MoveResult = "Success"
                    $success_count++
                }
                else {
                    Add-Content $file -Value "$datime $gname Fail$type to $TargetNode completed but group is offline"
                    $group.MoveResult = "Offline"
                }
                Remove-Job -Name "move_$gname" -Force
            }
            elseif ($job.State -eq "Failed") {
                $reason = $job.JobStateInfo.Reason
                Add-Content $file -Value "$datime $gname Fail$type to $TargetNode failed: $reason"
                $group.MoveResult = "Failed"
                Remove-Job -Name "move_$gname" -Force
            }
        }
    }

    if ($pending -eq 0) { break }
}

$datime = log_time
if ($timer -ge $Timeout) {
    Add-Content $file -Value "$datime Fail$type timed out after $Timeout iterations"
}
elseif ($count -eq 0) {
    Add-Content $file -Value "$datime No SQL Server roles found on $env:COMPUTERNAME"
}
elseif ($count -eq $success_count) {
    Add-Content $file -Value "$datime Fail$type successful for $count roles"
}
else {
    foreach ($group in $groups | Where-Object { $_.MoveResult -ne "Success" }) {
        Add-Content $file -Value "$datime Unable to fail$type $($group.GroupName) successfully (result: $($group.MoveResult))"
    }
}

return $groups
