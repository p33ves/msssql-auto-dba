#Requires -Version 5.1

#region Credential check

$cred_count = 0
$checkcred  = $false
while (!$checkcred -and $cred_count -ne 3) {
    $credential = Get-Credential -Message "Please enter credentials to run SQL Patch"
    if ($credential -eq $null) { exit }

    $username = $credential.UserName
    $password = $credential.GetNetworkCredential().Password

    $CurrentDomain = "LDAP://" + ([ADSI]"").distinguishedName
    $domain = New-Object System.DirectoryServices.DirectoryEntry($CurrentDomain, $username, $password)
    if ($domain.Name -ne $null) {
        Write-Host "Successfully authenticated with domain $($domain.Name)"
        $checkcred = $true
        break
    }
    else {
        $cred_count++
        $remaining = 3 - $cred_count
        Write-Host "Authentication failed. $remaining attempt(s) left."
    }
}

if ($cred_count -eq 3) { exit }

#endregion

#region Global variables

$config_path = "D:\PFSQLteam\Autopatch\CurrentConfig.ini"
if (!(Test-Path $config_path)) {
    Write-Host "Config file not found: $config_path" -ForegroundColor Red
    exit
}
$configuration = Get-Content -Path $config_path | Out-String | ConvertFrom-Json

$run_datetime  = (Get-Date).ToUniversalTime().ToString('MM_dd_yyyy_HH_mm_ss')
$timeout       = $configuration.Timeouts
$state_group   = @{}
$configuration.State_groups | ForEach-Object { $state_group[$_] = @{} }
$target        = $configuration.Targets
$scripts       = $configuration.Scripts
$location      = $scripts.Path
$logfile       = "$location\Patch\${username}_$run_datetime"
$jobs          = New-Object System.Collections.ArrayList
$patch         = @{}
$detail        = @{}

Start-Transcript -Path "$logfile\Patch-Log.log" -Force

#endregion

#region Helper functions

function log_time {
    return "[$(((Get-Date).ToUniversalTime()).ToString())] --"
}

function updateHTML {
    param([object]$fresh)
    $HTMLFilePath = "$location\output_html.html"
    if (Test-Path $HTMLFilePath) { Remove-Item $HTMLFilePath -Force }

    $style = @"
<style>
BODY { background-color:beige; font-family:Calibri; color:black }
TABLE { border-width:1px; border-style:solid; border-color:black; border-collapse:collapse }
TH { border-width:1px; padding:4px; border-style:solid; border-color:black; background-color:gray }
TD { border-width:1px; padding:4px; border-style:solid; border-color:black }
</style>
"@
    $date = Get-Date
    $style | Out-File $HTMLFilePath -Encoding UTF8
    "<BR>"                                  | Out-File $HTMLFilePath -Append
    "<H1><B>Patch Status Report</B></H1>"   | Out-File $HTMLFilePath -Append
    "<H4><B>Last Updated at $date</B></H4>" | Out-File $HTMLFilePath -Append

    $targetpath = $target.Path
    $p = "\$targetpath\Patch_progress.txt"
    $fresh |
        Select-Object SName, State,
            @{Name="Log"; Expression={"<a href='\\$($_.SName)$p' target='_blank'>view</a>"}} |
        ConvertTo-Html -Title "Status" |
        ForEach-Object { ($_ -replace "&lt;","<") -replace "&gt;",">" } |
        Out-File $HTMLFilePath -Append

    if ($jobs) {
        $jobs | Select-Object ID,Name,PSJobTypeName,State,HasMoreData,Location,JobStateInfo |
            ConvertTo-Html -Head $style | Out-File $HTMLFilePath -Append
        "</br></br>" | Out-File $HTMLFilePath -Append
        $jobs.ChildJobs | Select-Object ID,Name,PSJobTypeName,State,HasMoreData,Location,JobStateInfo |
            ConvertTo-Html -Head $style | Out-File $HTMLFilePath -Append
    }
}

function updateset {
    param([Hashtable]$state_group, [int]$from)
    $file = switch ($from) { 0 {"servers"} 1 {"currentset"} 2 {"restset"} }
    $exclude = New-Object System.Collections.ArrayList

    foreach ($state in @($state_group.Keys)) {
        if ($state_group[$state].Count) {
            foreach ($server in $state_group[$state].Keys) {
                $value = $state_group[$state][$server]
                Add-Content -Path "$logfile\$state.txt" -Value "$server : $value"
                $exclude.Add($server) | Out-Null
                if ($state -ne "done" -and $patch.ContainsKey($server)) {
                    $patch.Remove($server)
                }
            }
            $state_group[$state] = @{}
        }
    }

    if ($exclude.Count) {
        $set = Get-Content "$logfile\$file.txt" -ErrorAction SilentlyContinue
        Clear-Content "$logfile\$file.txt"
        $set | ForEach-Object { if ($_ -notin $exclude) { Add-Content -Path "$logfile\$file.txt" -Value $_ } }
    }
}

function moveserver {
    param([string]$server, $from, [int]$to)
    $src = switch ($from) { 0 {"servers"} 1 {"currentset"} 2 {"restset"} $null {$null} }
    $des = switch ($to)   { 0 {"servers"} 1 {"currentset"} 2 {"restset"} }

    if ($server -notin (Get-Content "$logfile\$des.txt" -ErrorAction SilentlyContinue)) {
        Add-Content -Path "$logfile\$des.txt" -Value $server
    }
    if ($src -ne $null) {
        $data = Get-Content "$logfile\$src.txt" -ErrorAction SilentlyContinue |
            Where-Object { $_ -ne $server }
        Clear-Content "$logfile\$src.txt"
        if ($data) { Add-Content -Path "$logfile\$src.txt" -Value $data }
    }
}

function updatestatus {
    param([object]$server)
    $name       = $server.SName
    $targetpath = $target.Path
    $remote_log = "\\$name\$targetpath\Patch_progress.txt"
    if (Test-Path $remote_log) {
        $log = Get-Content $remote_log
        Clear-Content "$logfile\Logs\$name.txt" -ErrorAction SilentlyContinue
        Add-Content   "$logfile\Logs\$name.txt" -Value $log
        $last_line = $log | Select-Object -Last 1
        if ($last_line -and $last_line.IndexOf("] -- ") -ge 0) {
            $server.Display_Status = $last_line.Substring($last_line.IndexOf("] -- ") + 5)
        }
    }
}

function getrelated {
    param([object]$server)
    $pids = @()
    foreach ($id in $server.Instances.Keys) {
        $inst = $server.Instances[$id]
        if ($inst.is_Active) {
            foreach ($hadr in $inst.HADR.Keys) {
                $pids += $inst.HADR[$hadr].Partners
            }
        }
    }
    $pids = $pids | Select-Object -Unique
    if ($pids.Count -eq 0) { return $null }

    $pserv = @()
    foreach ($sname in $patch.Keys) {
        $server1 = $patch[$sname]
        foreach ($id in $server1.Instances.Keys) {
            $inst = $server1.Instances[$id]
            $base = if ($id.Contains(",")) { $id.Split(",")[0] } else { $null }
            if (($sname -ne $server.SName) -and
                (($id -in $pids) -or ($base -ne $null -and $base -in $pids)) -and
                $inst.is_Active) {
                $pserv += $sname
            }
        }
    }
    return ($pserv | Select-Object -Unique)
}

$copymedia = {
    param([object]$server, [object]$configuration)
    $tgt       = $configuration.Targets
    $cycle     = $tgt.Cycle
    $mediapath = "\\$env:COMPUTERNAME\SQL_Patch_$cycle"
    $targetpath = $tgt.Path
    $sname     = $server.SName
    $dest      = "\\$sname\$targetpath"
    $file      = "\\$sname\$targetpath\Patch_Progress.txt"
    $datime_fn = { "[$(((Get-Date).ToUniversalTime()).ToString())] --" }

    foreach ($version in @($server.Versions.Keys)) {
        $patch_req = $false
        foreach ($inst in $server.Versions[$version]) {
            $iname      = $inst.IName
            $patchLevel = $inst.PatchLevel
            if ($tgt.$version -ne $null) {
                if ($patchLevel -lt $tgt.$version) {
                    $patch_req = $true
                }
                else {
                    Add-Content $file -Value "$(& $datime_fn) $iname already at $patchLevel for $version"
                }
            }
            else {
                Add-Content $file -Value "$(& $datime_fn) $iname running $version — not in scope for $cycle"
            }
        }
        if ($patch_req) {
            Copy-Item -Path "$mediapath\$version" -Destination $dest -Force -Recurse
            $binname = $configuration.Media.$version.Name
            if (Test-Path "$dest\$version\$binname") {
                Add-Content $file -Value "$(& $datime_fn) Media copy done for $version"
            }
            else {
                Add-Content $file -Value "$(& $datime_fn) Media copy failed for $version"
            }
        }
    }
}

#endregion

#region Initialization — verify server list

New-Item -Path $logfile -ItemType Directory -Force | Out-Null
New-Item -Path "$logfile\Logs" -ItemType Directory -Force | Out-Null
foreach ($f in @("servers0.txt","servers.txt","currentset.txt","restset.txt")) {
    New-Item -Path $logfile -Name $f -ItemType File -Force | Out-Null
}

$set = (Get-Content "$location\Patch\servers.txt") | ForEach-Object { $_.Trim() } | Select-Object -Unique
Add-Content -Path "$logfile\servers0.txt" -Value $set
Add-Content -Path "$logfile\servers.txt"  -Value $set

$targetpath = $target.Path
foreach ($server in $set) {
    if (Test-Connection $server -Count 1 -Quiet) {
        $progress_file = "\\$server\$targetpath\patch_progress.txt"
        $role_file     = "\\$server\$targetpath\rolerunning.txt"
        if (Test-Path $progress_file) { Remove-Item $progress_file -Force }
        if (Test-Path $role_file)     { Remove-Item $role_file     -Force }
        New-Item -Path "$logfile\Logs" -Name "$server.txt" -ItemType File -Force | Out-Null
    }
    elseif (Resolve-DnsName $server -ErrorAction SilentlyContinue) {
        $state_group["down"][$server] = "Server Down"
    }
    else {
        $state_group["issue"][$server] = "Server does not exist"
    }
}
updateset -state_group $state_group -from 0

#endregion

#region Get SQL details and copy media

Get-Job | Remove-Job -Force
$set           = Get-Content "$logfile\servers.txt"
$wait_counter  = @{}
$set | ForEach-Object { $wait_counter[$_] = 0 }

while ($wait_counter.Keys.Count) {
    foreach ($server in @($wait_counter.Keys)) {
        $detail_json = "$location\Pre-Patch\Logs\Current\$server.json"
        $jobname_gd  = "Get-Details_$server"
        $jobname_cm  = "Copy-media_$server"

        if (Test-Path $detail_json) {
            $job_cm = $jobs | Where-Object { $_.Name -eq $jobname_cm }
            if ($job_cm) {
                if ($job_cm.State -eq "Completed") {
                    updatestatus -server $patch[$server]
                    $logs = Get-Content "\\$server\$targetpath\Patch_progress.txt" -ErrorAction SilentlyContinue
                    $flag = 0
                    foreach ($version in @($patch[$server].Versions.Keys)) {
                        if ($logs -like "*Media copy done for $version*") {
                            $patch[$server].Versions[$version] | ForEach-Object { $_.State = "Copied" }
                        }
                        else {
                            if ($logs -like "*Media copy failed for $version*") { $flag++ }
                            $patch[$server].Versions.Remove($version)
                        }
                    }
                    if ($patch[$server].Versions.Count) {
                        $patch[$server].State = "Media Copied"
                    }
                    elseif ($flag) {
                        $state_group["fail"][$server] = "Media Not Copied"
                    }
                    else {
                        $state_group["skip"][$server] = "No Patch Required"
                    }
                    $wait_counter.Remove($server)
                }
                elseif ($job_cm.State -eq "Running") {
                    if ($wait_counter[$server] -lt $timeout."Copy-media") { $wait_counter[$server]++ }
                    else { $state_group["timeout"][$server] = "at Copy-media"; $wait_counter.Remove($server) }
                }
                else {
                    $state_group["fail"][$server] = $job_cm.JobStateInfo.Reason
                    $wait_counter.Remove($server)
                }
            }
            else {
                $wait_counter[$server] = 0
                $temp = Get-Content $detail_json | Out-String | ConvertFrom-Json
                $new  = & $scripts."Build-Object" $temp
                $detail[$server] = $temp
                $patch[$server]  = $new
                $jobs.Add((Start-Job -ScriptBlock $copymedia -ArgumentList $new,$configuration -Name $jobname_cm)) | Out-Null
            }
        }
        else {
            $job_gd = $jobs | Where-Object { $_.Name -eq $jobname_gd }
            if ($job_gd) {
                if ($job_gd.State -eq "Completed") {
                    $file = Get-ChildItem "\\$server\$targetpath\ServerDetails" |
                        Where-Object { $_.Name -like "*.json" } |
                        Sort-Object LastWriteTime | Select-Object -Last 1
                    if ($file -and ($file.BaseName -in @($job_gd.ChildJobs.Output))) {
                        Copy-Item "\\$server\$targetpath\ServerDetails\$($file.Name)" -Destination $detail_json -Force
                    }
                    else {
                        $state_group["fail"][$server] = "JSON not created"
                        $wait_counter.Remove($server)
                    }
                }
                elseif ($job_gd.State -eq "Running") {
                    if ($wait_counter[$server] -lt $timeout."Get-details") { $wait_counter[$server]++ }
                    else { $state_group["timeout"][$server] = "at Get-details"; $wait_counter.Remove($server) }
                }
                else {
                    $state_group["fail"][$server] = $job_gd.JobStateInfo.Reason
                    $wait_counter.Remove($server)
                }
            }
            else {
                $jobs.Add((Invoke-Command -ComputerName $server -JobName $jobname_gd -FilePath $scripts."Get-Details" -AsJob -ErrorAction Stop)) | Out-Null
                $wait_counter[$server] = 0
            }
        }
    }
    Start-Sleep -Seconds 30
}
updateset -state_group $state_group -from 0

#endregion

#region Validate roles and populate passive nodes

foreach ($sname in @($patch.Keys)) {
    $flag   = 0
    $server = $patch[$sname]

    if ($server.Versions.Count -gt 1) {
        $state_group["issue"][$sname] = "Multiple Versions"; continue
    }
    if ($server.AG_Type -eq "Both") {
        $state_group["issue"][$sname] = "Multiple Sync Types in AG"; continue
    }

    foreach ($instance_id in $server.Instances.Keys) {
        $inst = $server.Instances[$instance_id]

        if ($inst.is_Clustered -and !$inst.is_Active) {
            foreach ($clupartner in $server.Windows_Cluster.Cluster_Partners) {
                $serv = $clupartner.Name
                if ($patch.ContainsKey($serv) -and
                    $patch[$serv].Instances.ContainsKey($instance_id) -and
                    $patch[$serv].Instances[$instance_id].is_Active) {
                    $inst.HADR  = $patch[$serv].Instances[$instance_id].HADR
                    $inst.isPri = $patch[$serv].Instances[$instance_id].isPri
                    foreach ($hadr in $inst.HADR.Keys) {
                        if (!$server.HADR.ContainsKey($hadr)) { $server.HADR[$hadr] = @() }
                        $server.HADR[$hadr] += $patch[$serv].HADR[$hadr]
                    }
                }
            }
        }

        foreach ($hadr in $inst.HADR.Keys) {
            if ($inst.HADR[$hadr].Priority.Count -gt 1) {
                $datime = log_time
                Add-Content "\\$sname\$targetpath\Patch_Progress.txt" -Value "$datime Multiple roles found for $instance_id under $hadr"
                $flag++
            }
        }

        if ($flag -eq 0) {
            if ($inst.isPri -eq -1) {
                $datime = log_time
                Add-Content "\\$sname\$targetpath\Patch_Progress.txt" -Value "$datime Multiple roles found for $instance_id across different HADRs"
                $flag++
            }
            elseif ($inst.isPri -ne $null) {
                if ($server.isPri -eq $null) {
                    $server.isPri = $inst.isPri
                    $temp_inst    = $instance_id
                }
                elseif ($server.isPri -ne $inst.isPri) {
                    $datime = log_time
                    Add-Content "\\$sname\$targetpath\Patch_Progress.txt" -Value "$datime Multiple roles found for instances $instance_id and $temp_inst"
                    $flag++
                }
            }
        }
    }

    if ($flag) { $state_group["issue"][$sname] = "Multiple Roles" }
}
updateset -state_group $state_group -from 0

#endregion

#region Build groups and ordering sets

$group = @{}
$link  = @{}
$set   = Get-Content "$logfile\servers.txt"

foreach ($sname in $set) {
    $set1 = Get-Content "$logfile\currentset.txt" -ErrorAction SilentlyContinue
    $set2 = Get-Content "$logfile\restset.txt"    -ErrorAction SilentlyContinue
    updateset -state_group $state_group -from 0

    if ($sname -notin $set1 -and $sname -notin $set2 -and $patch.ContainsKey($sname)) {
        $server = $patch[$sname]

        if ($server.HADR.ContainsKey("FC")) {
            $flag        = 0
            $ids         = @($server.HADR["FC"])
            $active_counter = @{ $sname = 0 }

            foreach ($id in $ids) {
                if ($server.Instances[$id].is_Clustered -and $server.Instances[$id].is_Active) {
                    $active_counter[$sname]++
                }
            }

            foreach ($clupartner in $server.Windows_Cluster.Cluster_Partners) {
                $serv = $clupartner.Name
                if ($patch.ContainsKey($serv) -and $serv -in $set -and
                    $patch[$serv].HADR.ContainsKey("FC") -and
                    !(Compare-Object $ids $patch[$serv].HADR["FC"]) -and
                    $server.isPri -eq $patch[$serv].isPri) {
                    $active_counter[$serv] = 0
                    $patch[$serv].HADR["FC"] = $ids
                    foreach ($id in $ids) {
                        if ($patch[$serv].Instances[$id].is_Clustered -and $patch[$serv].Instances[$id].is_Active) {
                            $active_counter[$serv]++
                        }
                    }
                }
            }

            if ($active_counter.Count -lt 2 -and $active_counter[$sname] -gt 0) {
                $state_group["issue"][$sname] = "No Cluster Partners Found"
                continue
            }

            $obj_group = [PSCustomObject]@{
                isPri       = $server.isPri
                Order       = New-Object System.Collections.ArrayList
                ActiveChart = @{}
            }

            $sorted = $active_counter.GetEnumerator() | Sort-Object Value
            foreach ($entry in $sorted) {
                $obj_group.Order.Add($entry.Key)       | Out-Null
                $obj_group.ActiveChart[$entry.Key] = $entry.Value
            }

            if (!$group.ContainsKey("FC")) { $group["FC"] = @{} }
            $group["FC"][[string]$ids] = $obj_group

            if ($obj_group.isPri -eq 1) {
                $obj_group.Order | ForEach-Object {
                    moveserver -server $_ -from $null -to 2
                    if ($_ -and $patch.ContainsKey($_)) { $patch[$_].State = "Waiting for BCP" }
                }
            }
            else {
                $total = $obj_group.Order.Count
                for ($i = 0; $i -lt $total; $i++) {
                    $tempname = $obj_group.Order[$i]
                    if ($tempname -and $patch.ContainsKey($tempname)) {
                        if ($i -lt [math]::Floor($total / 2)) {
                            moveserver -server $tempname -from $null -to 1
                            if ($obj_group.ActiveChart[$tempname]) {
                                $patch[$tempname].State = "Requires Cluster Failover"
                                $mirror_idx = $total - 1 - $i
                                $link[$tempname] = if ($i -ne $mirror_idx) {
                                    $obj_group.Order[$mirror_idx]
                                } else {
                                    $obj_group.Order[$total - $i]
                                }
                            }
                            else {
                                moveserver -server $tempname -from $null -to 2
                                $patch[$tempname].State = "Queued for Patch"
                            }
                        }
                        else {
                            moveserver -server $tempname -from $null -to 2
                            $patch[$tempname].State = "Queued for Patch"
                        }
                    }
                }
            }
        }
        elseif ($server.HADR.Count -gt 0) {
            $gr = $group["Other"] | Where-Object { $_ -like "*$sname" }
            if ($gr -ne $null) {
                if ($server.isPri -eq 1) {
                    moveserver -server $sname -from $null -to 2
                    $patch[$sname].State = "Waiting for BCP"
                }
                else {
                    moveserver -server $sname -from $null -to 1
                    $patch[$sname].State = "Ready to Patch"
                }
            }
            else {
                $gr = $group["Mul-AG"] -and ($group["Mul-AG"].Keys | Where-Object { $_ -like "*$sname*" })
                if ($gr) {
                    $thisgr = $group["Mul-AG"][$gr]
                    foreach ($rep in $thisgr.Keys) {
                        $obj_rep = $patch[$rep]
                        if ($obj_rep.isPri -eq 1) {
                            moveserver -server $rep -from $null -to 2
                            $patch[$rep].State = "Waiting for BCP"
                        }
                        elseif ($thisgr[$rep] -eq 3) {
                            moveserver -server $rep -from $null -to 1
                            $patch[$rep].State = "Ready to Patch"
                        }
                        elseif ($thisgr[$rep] -eq 2) {
                            moveserver -server $rep -from $null -to 2
                            $patch[$rep].State = "Waiting for Async"
                        }
                    }
                }
                else {
                    $partners = getrelated -server $server
                    if ($partners.Count -eq 0) {
                        if (!$group.ContainsKey("Other")) { $group["Other"] = @() }
                        $group["Other"] += "$sname"
                        moveserver -server $sname -from $null -to 1
                        $patch[$sname].State = "Ready to Patch"
                    }
                    elseif ($partners.Count -eq 1) {
                        if (!$group.ContainsKey("Other")) { $group["Other"] = @() }
                        $part_obj = $patch[$partners[0]]
                        if ($server.isPri -eq $part_obj.isPri) {
                            $state_group["issue"][$sname]       = "Multiple HADR Roles"
                            $state_group["issue"][$partners[0]] = "Multiple HADR Roles"
                            continue
                        }
                        $group["Other"] += "$($partners[0])+$sname"
                    }
                    else {
                        $state_group["issue"][$sname] = "Multiple HADR Partners"
                        continue
                    }
                }
            }
        }
        else {
            if (!$group.ContainsKey("SA")) { $group["SA"] = @() }
            $group["SA"] += $sname
            $server.State = "Ready to Patch"
            moveserver -server $sname -from $null -to 1
        }
    }
}

#endregion

#region Run patch

$set1 = Get-Content "$logfile\currentset.txt" -ErrorAction SilentlyContinue
while ($set1) {
    $fresh = @()
    $set1  = Get-Content "$logfile\currentset.txt" -ErrorAction SilentlyContinue
    $set2  = Get-Content "$logfile\restset.txt"    -ErrorAction SilentlyContinue

    foreach ($sname in $set1) {
        $server = $patch[$sname]

        if ($server.State -eq "Requires Failback") {
            $jobname = "Failback_$sname"
            $job = $jobs | Where-Object { $_.Name -eq $jobname }
            if ($job) {
                if ($job.State -eq "Completed") {
                    updatestatus -server $server
                    $datime = log_time
                    if ($server.Display_Status -like "Fail*back successful for * roles") {
                        Add-Content "\\$sname\$targetpath\Patch_Progress.txt" -Value "$datime Patching activity complete"
                        $state_group["done"][$sname] = "Completed Successfully"
                        $server.State = "Patch Complete"
                    }
                    else {
                        $state_group["fail"][$sname] = "Patched with failback errors"
                    }
                }
                elseif ($job.State -in @("Running","Failed")) {
                    if ($job.State -eq "Failed" -and $server.Stage_timer -lt $timeout.Failback) {
                        $jobs.Remove($job)
                        $jobs.Add((Invoke-Command -ComputerName $sname -JobName $jobname -FilePath $scripts.Failback -AsJob -ErrorAction Stop -ArgumentList ($sname,$timeout.Failback,$targetpath,$server.Windows_Cluster))) | Out-Null
                    }
                    elseif ($server.Stage_timer -lt $timeout.Failback) {
                        $server.Stage_timer++
                    }
                    elseif ($job.State -eq "Running") {
                        $state_group["timeout"][$sname] = "at Failback"
                    }
                    else {
                        $state_group["fail"][$sname] = $job.JobStateInfo.Reason
                    }
                }
                else {
                    $state_group["fail"][$sname] = "Failback job in unexpected state: $($job.State)"
                    $server.Stage_timer = 0
                }
            }
            else {
                $jobs.Add((Invoke-Command -ComputerName $sname -JobName $jobname -FilePath $scripts.Failback -AsJob -ErrorAction Stop -ArgumentList ($sname,$timeout.Failback,$targetpath,$server.Windows_Cluster))) | Out-Null
            }
        }
        elseif ($server.State -eq "Rebooting") {
            if ((Test-Connection $sname -Count 1 -Quiet) -and (Test-Path "\\$sname\$targetpath\Patch_progress.txt")) {
                $datime = log_time
                Add-Content "\\$sname\$targetpath\Patch_progress.txt" -Value "$datime Server back online"
                $fc_key = [string]($server.HADR["FC"])
                if ($server.HADR.ContainsKey("FC") -and
                    $group["FC"].ContainsKey($fc_key) -and
                    $group["FC"][$fc_key].ActiveChart[$sname] -ne 0) {
                    $server.State = "Requires Failback"
                    $server.Stage_timer = 0
                }
                else {
                    Add-Content "\\$sname\$targetpath\Patch_progress.txt" -Value "$datime Patching activity complete"
                    $state_group["done"][$sname] = "Completed Successfully"
                }
            }
            else {
                if ($server.Stage_timer -lt $timeout.Reboot) {
                    $server.Stage_timer++
                }
                else {
                    $state_group["down"][$sname] = "Timed out waiting for reboot"
                }
            }
        }
        elseif ($server.State -eq "Patch Validation") {
            $jobname = "Validate_$sname"
            $job = $jobs | Where-Object { $_.Name -eq $jobname }
            if ($job) {
                if ($job.State -eq "Completed") {
                    updatestatus -server $server
                    if ($server.Display_Status -like "Patch applied*") {
                        $server.State = "Rebooting"
                        $datime = log_time
                        Add-Content "\\$sname\$targetpath\Patch_progress.txt" -Value "$datime Rebooting server"
                        $server.Stage_timer = 0
                        Restart-Computer -ComputerName $sname -Force
                    }
                    else {
                        $state_group["fail"][$sname] = "Patch failed validation"
                    }
                }
                elseif ($job.State -eq "Running") {
                    if ($server.Stage_timer -lt $timeout.Validate) { $server.Stage_timer++ }
                    else { $state_group["timeout"][$sname] = "at Validation" }
                }
                else {
                    $state_group["fail"][$sname] = $job.JobStateInfo.Reason
                }
            }
        }
        elseif ($server.State -eq "Ready to Patch") {
            $jobname    = "SQL-Patch_$sname"
            $mediapath  = @($server.Versions.Keys)[0]
            $currentcycle = $target.Cycle
            $remote_media = "\\$sname\$targetpath\$mediapath"
            $job = $jobs | Where-Object { $_.Name -eq $jobname }

            if ($job) {
                if ($job.State -eq "Completed") {
                    $jobs.Add((Invoke-Command -ComputerName $sname -JobName "Validate_$sname" -FilePath $scripts.Validate -AsJob -ErrorAction Stop -ArgumentList ($server,$target))) | Out-Null
                    $server.Stage_timer = 0
                    $server.State = "Patch Validation"
                    $batfile = "$remote_media\SQL_Patching_${currentcycle}.bat"
                    if (Test-Path $batfile) { Remove-Item $batfile -Force -ErrorAction SilentlyContinue }
                }
                elseif ($job.State -eq "Running") {
                    if ($server.Stage_timer -lt $timeout.Patch) { $server.Stage_timer++ }
                    else { $state_group["timeout"][$sname] = "at Patching" }
                }
                else {
                    $state_group["fail"][$sname] = $job.JobStateInfo.Reason
                }
            }
            else {
                # Clean up any old batch files
                Get-ChildItem $remote_media -Filter "*.bat" -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue

                $local_tp  = $targetpath.Replace('$',':')
                $bin_name  = $configuration.Media.$mediapath.Name
                $bat_local = "$local_tp\$mediapath\SQL_Patching_${currentcycle}.bat"
                $bat_cmd   = "$local_tp\$mediapath\$bin_name /quiet /IAcceptSQLServerLicenseTerms /allinstances"

                Add-Content -Path "\\$sname\$targetpath\$mediapath\SQL_Patching_${currentcycle}.bat" -Value $bat_cmd
                $jobs.Add((Invoke-Command -ComputerName $sname -Credential $credential -JobName $jobname -AsJob -ErrorAction Stop -ScriptBlock {
                    param([string]$bat) & cmd.exe /c $bat
                } -ArgumentList $bat_local)) | Out-Null

                $datime = log_time
                Add-Content "\\$sname\$targetpath\Patch_progress.txt" -Value "$datime Running patch for $mediapath"
            }
        }
        elseif ($server.State -eq "Requires Cluster Failover") {
            $jobname = "Failover_$sname"
            $job = $jobs | Where-Object { $_.Name -eq $jobname }
            if ($job) {
                if ($job.State -eq "Completed") {
                    updatestatus -server $server
                    if ($server.Display_Status -like "Failover successful for * roles") {
                        $server.State = "Ready to Patch"
                        $server.Stage_timer = 0
                    }
                    else {
                        $state_group["fail"][$sname] = "Failover failed"
                    }
                }
                elseif ($job.State -eq "Running") {
                    if ($server.Stage_timer -lt $timeout.Failover) { $server.Stage_timer++ }
                    else { $state_group["timeout"][$sname] = "at Failover" }
                }
                else {
                    $state_group["fail"][$sname] = $job.JobStateInfo.Reason
                }
            }
            else {
                $jobs.Add((Invoke-Command -ComputerName $sname -JobName $jobname -FilePath $scripts.Failover -AsJob -ErrorAction Stop -ArgumentList ($link[$sname],$timeout.Failover,$targetpath,$server.Windows_Cluster))) | Out-Null
            }
        }
        else {
            $state_group["issue"][$sname] = "Unexpected stage: $($server.State)"
        }

        updatestatus -server $server
        $fresh += $server | Select-Object SName, Display_Status, State
    }

    $datime = log_time
    $disp   = $fresh | Format-Table | Out-String
    Add-Content -Path "$logfile\Patch_progress.txt" -Value "$datime`n$disp`n"
    Write-Host $disp
    updateHTML -fresh $fresh

    # Advance queued servers after completions/failures
    foreach ($key in @($state_group.Keys)) {
        if ($state_group[$key].Count) {
            foreach ($sname in @($state_group[$key].Keys)) {
                if ($key -eq "done") { moveserver -server $sname -from 1 -to 2 }

                $server = $patch[$sname]
                if (!$server -or !$server.HADR.Count) { continue }

                $fc_key = [string]($server.HADR["FC"])
                if ($server.HADR.ContainsKey("FC") -and $group["FC"].ContainsKey($fc_key)) {
                    $og = $group["FC"][$fc_key]
                    if ($link.ContainsKey($sname)) { $link.Remove($sname) }
                    $fin = 0
                    foreach ($node in $og.Order) {
                        if ($node -in $set2 -and !$link.ContainsValue($node) -and $patch[$node].State -eq "Queued for Patch") {
                            moveserver -server $node -from 2 -to 1
                            if ($og.ActiveChart[$node]) {
                                $patch[$node].State = "Requires Cluster Failover"
                                $link[$node] = $sname
                            }
                            else {
                                $patch[$node].State = "Ready to Patch"
                            }
                            break
                        }
                        elseif ($patch[$node].State -eq "Patch Complete") {
                            $fin++
                        }
                    }
                    if ($og.Order.Count -eq $fin) {
                        # All FC nodes done — check for paired AG partner
                        $serv_group = $group["Other"] | Where-Object { $_ -like "*$sname*" }
                        if ($serv_group) {
                            $ng = ($serv_group.Split("+") | Where-Object { $_ -ne $sname })[0]
                            $ns = $patch[$ng]
                            if ($ns -and $ns.State -eq "Waiting for BCP") {
                                moveserver -server $ng -from 2 -to 1
                                $ns.State = "Ready to Patch"
                            }
                        }
                    }
                    continue
                }

                $serv_group = $group["Other"] | Where-Object { $_ -like "*$sname*" }
                if ($serv_group) {
                    $ng = ($serv_group.Split("+") | Where-Object { $_ -ne $sname })[0]
                    $ns = $patch[$ng]
                    if ($ns -and $ns.State -eq "Waiting for BCP") {
                        moveserver -server $ng -from 2 -to 1
                        $ns.State = "Ready to Patch"
                    }
                    continue
                }

                $mul_key = $group["Mul-AG"] -and ($group["Mul-AG"].Keys | Where-Object { $_ -like "*$sname*" })
                if ($mul_key) {
                    $gr  = $group["Mul-AG"][$mul_key]
                    $cur = $gr[$sname]
                    if ($cur -ne 1) {
                        $next_tier = $cur - 1
                        $ready     = $true
                        $these     = $gr.Keys | Where-Object { $gr[$_] -eq $cur }
                        foreach ($rep in $these) {
                            if ($rep -notin $set2) { $ready = $false; break }
                        }
                        if ($ready) {
                            $nset = $gr.Keys | Where-Object { $gr[$_] -eq $next_tier }
                            foreach ($rep in $nset) {
                                moveserver -server $rep -from 2 -to 1
                                $patch[$rep].State = "Ready to Patch"
                            }
                        }
                    }
                }
            }
        }
    }

    updateset -state_group $state_group -from 1
    Start-Sleep -Seconds 30
}

#endregion

#region Mark remaining servers as skipped

Clear-Content "$location\Patch\servers.txt"
$set2 = Get-Content "$logfile\restset.txt" -ErrorAction SilentlyContinue
foreach ($sname in $set2) {
    $found = $false
    foreach ($state in $state_group.Keys) {
        $data = Get-Content "$logfile\$state.txt" -ErrorAction SilentlyContinue
        if ($data -like "$sname : *") { $found = $true; break }
    }
    if (!$found) { $state_group["skip"][$sname] = "Skipped" }
}
updateset -state_group $state_group -from 2

#endregion

Stop-Transcript
