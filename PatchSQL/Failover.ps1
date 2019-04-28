$targetnode = $args[0]
$timeout = $args[1]
$targetpath = $args[2].Replace('$',':')
$file = "$targetpath\Patch_progress.txt"
$cluster = $args[3]
$groups = @()
$returncode = $null
$job = @{}
$count = 0
$success = $false
$success_count = 0

if($targetnode -ne $env:COMPUTERNAME) {
    $type = "over"
    $currentgroups = (Get-ClusterGroup | ? {$_.Ownernode -like $env:COMPUTERNAME}).Name
}
else {
    $type = "back"
}

function log_time {
   $datime = ((Get-Date).ToUniversalTime().ToString())
   return "[$datime] --"
}

foreach($group in $cluster.Cluster_Groups) {
    $gname = $group.GroupName
    if((($type -eq "over") -and ($gname -in $currentgroups)) -or (($type -eq "back" -and ($group.Ownernode -eq $env:COMPUTERNAME))) {
        if([bool]($group.Group_Resources | ? {$_.ResourceType -eq "SQL Server"})) {
            $group | Add-Member -MemberType NoteProperty -Name GroupType -Value "SQL Group"
            $group | Add-Member -MemberType NoteProperty -Name MoveResult -Value "NA"
            $datime = log_time
            Add-Content $file -Value "$datime Moving $gname to $targetnode"
            $job = Start-Job -Name "move_$gname" -ScriptBlock {
                param([string]$gname,$targetnode) Move-ClusterGroup -Name $gname -Node $targetnode
            } -ArgumentList $gname,$targetnode
            $group | Add-Member -MemberType NoteProperty -Name MoveJob -Value $job
            $count++
        }
        elseif ([bool]($group.Group_Resources | ? {$_.ResourceType -eq "SQL Server Availability Group"})) {
            $group | Add-Member -MemberType NoteProperty -Name GroupType -Value "AG Group"            
        }
        else {
            $group | Add-Member -MemberType NoteProperty -Name GroupType -Value "Other Group"
        }
        $groups += $group
    }
}

$timer = 0
while ($timer -lt $timeout) {
    Start-Sleep -Seconds 30
    $timer++
    $cc = 0
    foreach ($group in $groups) {
        $gname = $group.GroupName
        if (($group.GroupType -eq "SQL Group") -and ($group.MoveResult -eq "NA")) {
            $cc++
            $job = $group.MoveJob
            $datime = log_time
            if ($job.State -eq "Completed") {
                if ((Get-ClusterGroup $gname).State -eq "Online") {
                    Add-Content $file -Value "$datime $gname is Failover $type to $targetnode"
                    $group.MoveResult = "Success"
                    $success_count++
                }
                else {
                    Add-Content $file -Value "$datime $gname is Failed $type to $targetnode, but not online"
                    $group.MoveResult = "Offline"
                }
                Remove-Job -Name "move_$gname"
            }
            elseif ($job.State -eq "Failed") {
                $reason = $job.JobstateInfo.$reason
                Add-Content $file -Value "$datime $gname- Fail $type to $targetnode failed due to: $reason"
                $group.MoveResult = "Failed"
            }
        }
    }
    if(![bool]$cc) {
        Break;
    }
}

$datime = log_time
if($timer -ge $timeout) {
    Add-Content $file -Value "$datime Fail$type timed out"
}
elseif ($count -eq 0) {
    Add-Content $file -Value "$datime No SQL Server roles on $env:COMPUTERNAME"
}
elseif ($count -eq $success_count) {
    Add-Content $file -Value "$datime Fail$type successful for $count roles"
}
else {
    foreach ($group in $groups) {
        if ($group.MoveResult -ne "Success") {
            $gname = $group.GroupName
            Add-Content $file -Value "$datime Unable to fail$type $gname successfully"
        }
    }
}
return $groups