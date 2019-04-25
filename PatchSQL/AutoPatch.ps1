#region Check_Credential

$cred_count = 0
$checkcred = $false
while(!($checkcred) -and $cred_count -ne 3) {
    $credential = Get-Credential -Message "Please Enter Credentials to Run SQL Patch"
    if($credential -eq $null) {
        Exit;
    }
    $username = $credential.UserName
    $password = $credential.GetNetworkCredential().Password

    #Get Current domain logged-on user's credentials
    $CurrentDomain = "LDAP://" + ([ADSI]"").distinguishedName
    $domain = New-Object System.DirectoryServices.DirectoryEntry($CurrentDomain,$username,$password)
    if ($domain.Name -ne $null)
        Write-Host "Successfully authenticated with domain $($domain.Name)"
        break;
    }
    else {
        $cred_count++
        $temp = 3 - $cred_count
        Write-Host "Authentication failed. Only $temp attempt(s) left"
        Continue;
    }
}

if($cred_count -eq 3) {
    Exit;
}

#endregion Check_Credential

#region Globaal Variables declaration

if(Test-Path "D:\PFSQLteam\Autopatch\CurrentConfig.ini") {
    $configuration = Get-Content -Path "D:\PFSQLteam\Autopatch\CurrentConfig.ini" | Out-String | ConvertFrom-Json
}
else {
    Exit;
}

$run_datime = (Get-Date).ToUniversalTime().ToString('MM_dd_yyyy_hh_mm_ss')

$timeout = $configuration.Timeouts
$state_group = @{}
$configuration.State_groups | % {$state_group.Add($_,@{})}
$target = $configuration.Targets
$scripts = $configuration.Scripts
$location = $scripts.Path
$logfile = "$location\Patch\"+$username.ToString()+"_$run_datime"
$jobs = New-Object System.Collections.ArrayList($null)
$patch = @{}
$detail = @{}
Start-Transcript -Path "$logfile\Patch-Log.log"

#endregion

#region HTML Header&Function Declarations 

$Header = @"
<meta http-equiv="refresh" content="30>
<style>
BODY{background-colour:beige;FONT-FAMILY:CALIBRI;color:black}
TABLE{border-width: 1px;border-style: solid;border -colour: black;border-collapse: collapse;}
TH{border-width: 1px;padding: 4px;border-style: solid;border-color: black;background-color:gray}
TD{border-width: 1px;padding: 4px;border-style: solid;border-color: black;}
</style>
"@

function updateHTML {
    Param(
            [object]$fresh
         )
    $HTMLFilePath = "\output_html.html"
    if ((Test-Path $HTMLFilePath) -eq "True") {
        Remove-Item $HTMLFilePath
    }
    $date = Get-Date
    $a = "<style>"
    $a = $a + "BODY{background-color:beige;FONT-FAMILY:CALIBRI}" 
    $a = $a + "</style>"
    Write-Output $a | Out-File $HTMLFilePath
    Write-Output "<BR>" | Out-File $HTMLFilePath -Append
    Write-Output "<HI><B>Patch Status Report</B></H1>" | Out-File $HTMLFilePath -Append
    Write-Output "<H4><B>Last Updated at $date</B></H4>" | Out-File $HTMLFilePath -Append

    $p = "\$targetpath\Patch_progress.txt"
    $fresh | Select-Object SName, State,@{Name="file Link";Expression={("<a href=\\" + $_.SName + $p+ " target='_blank' </a>")}} | ConvertTo-Html -Body $_ -Title "Status" - -CssUri $location\Patch_Table_Style.css | %{$tmp = $_ -replace "&lt;","<"; $tmp -replace "&gt;",">";} | Out-File $HTMLFilePath -Append

    if($jobs){
        $jobs | Select-Object -Property ID,Name,PSJobTypeName,State,HasMoreData,location,JobStateInfo |ConvertTo-Html -Head $Header | Out-File $HTMLFilePath -Append
        Write-Output "</br></br>" | Out-File $HTMLFilePath -Append
        $jobs.childjobs |Select-Object -Property ID,Name,PSJobTypeName,State,HasMoreData,location,JobStateInfo |ConvertTo-Html -Head $Header | Out-File $HTMLFilePath -Append
    }
}

function log_time {
    $datime=((Get-Date).ToUniversalTime()).ToString()
    return "[$datime] --"
}

function updateset { 
    param(
        [Hashtable] $state_group,
        [String] $from
    )
    switch($from) {
        0 {$file = "servers";Break;}
        1 {$file = "currentsent";Break;}
        2 {$file = "restset";Break;}
    }
    $exclude = New-Object System.Collections.ArrayList($null)
    foreach($state in @($state_group.Keys)) {
        if([bool]($state_group.$state.Count)) {
            foreach($server in $state_group.$state.Keys) {
                $value = $state_group.$state.$server
                Add-Content -Path "$logfile\$state.txt" -Value "$server : $value"
                $exclude.Add($server)
                if(($state -ne "done") -and $patch.ContainsKey($server)) {
                    $patch.Remove($server)
                }
            }
            $state_group.$state =@[}
        }
    }
    if($exclude.Count) {
        $set = Get-Content "$logfile\$file.txt"
        Clear-Content "$logfile\$file.txt"
        $set | % { if($_ -ne $exclude) { Add-Content -Path "$logfile\$file.txt" -Value $_} }
    }
}

function moveserver {
    param(
        [String] $server,
        [String] $from,
        [String] $to
    )
    switch ($from) {
        0 {$src = "servers";Break;}
        1 {$src = "currentset";Break;}
        2 {$src = "restset";Break;}
        $null {$src = $null;Break;}
    } 
    switch ($to) {
        0 {$des = "servers";Break;}
        1 {$des = "currentset";Break;}
        2 {$des = "restset";Break;}
    }
    if($server -notin (Get-Content "$logfile\$des.txt")) {
        Add-Content -Path "$logfile\$des.txt" -Value $server
    }
    if($src -ne $null) {
        $data = Get-Content "$ogfile\$src.txt"
        $data = $data | % {if($_ -ne $server) {$_}}
        Clear-Content "$logfile\$src.txt" 
        Add-Content -Path "$logfile\$src.tx" -Value $data
    }
}

function updatestatus {
    param (
        [Object] $server
    )
    $name=$server.SName
    $targetpath=$target."Path"
    if (Test-Path "\\$name\$targetpath\Patch_progress.txt") {
        $log = Get-Content "\\$name\$targetpath\Patch_progress.txt"
        Clear-Content "$logfile\Logs\$name.txt"
        Add-Content "$logfile\Logs\$name.txt" -Value $log
        $log = $log | Select -Last 1
        $message = $log.substring($log.IndexOf("] -- ")+5)
        $server.Display_Status = $message
    }
}

function getrelated {
    param (
        [Object] $server 
    )
    $pids = @()
    foreach($id in $server.Instances.Keys) {
        $instance = $server.Instances.$id
        if($instances.is_active) {
            foreach($hadr in $instance.HADR.Keys) {
                $pids += $instance.HADR.$hadr.partners
            }
        }
    }
    $pids = $pids | select -unique
    if($pids.count -eq 0) {
        return $null
    }
    $pserv = @()
    foreach($sname in $patch.Keys) {
        $server1 = $patch.$sname
        foreach($id in $server1.Instances.Keys) {
            $instance = $server1.Instances.$id
            if($id.contains(",")) {
            $t = $id.split(",")
            $temp = $t[0]
         }

         else {
             $temp = $null
         }
         if(($sname -ne $server.sname) -and (($id -in $pids) -or (($temp -ne $null) -and (($temp -in $pids))) -and ($server1.Instances..$id.is_Active)) {
             $pserv += $sname
         }
      }
   }
   return ($pserv | select -unique)
}

$copymdeia = {
    param (
        [Object]$server,
        [Object]$configuration
        )
    $target = $configuration.Targets
    $cycle = $target.Cycle
    $mediapath = "\\$env:Computername\SQL_Patch_$cycle"
    $targetpath = $target.Path
    $servername = $server.SName
    $dest="\\$servername\$targetpath"
    $file="\\$servername\$targetpath\Patch_Progress.txt"
    foreach($version in @($server.Versions.Keys)) {
        $patch_req = $false
        foreach($instance in $server.Versions.$version) {
            $instancename=$instance.Iname
            $patchlevel = $instance.PatchLevel
            if($target.$version -ne $null) {
                if($patchlevel -lt $target.$version) {
                    $patch_req=$true
                }
                else {
                    $datime = "[$(((Get-Date).ToUniversalTime()).ToString())] --"
                    Add-Content -Path $file -Value "$datime $instancename is already updated with $patchlevel for $version"
                }
            }
            else {
                $datime = "[$(((Get-Date).ToUniversalTime()).ToString())] --"
                Add-Content -Path $file -Value "$datime $instancename running with $version is not in scope for $cycle"
            }
        }
        if($patch_req) {
           Copy-Item -Path "$mediapath\$version" -Destination $dest -Force -Recurse -Verbose
           $datime = "[$(((Get-Date).ToUniversalTime()).ToString())] --"
           $binname = $configuration.Media.$version.Name
           if(Test-Path "$dest\$version\$binname") {
               Add-Content -Path $file -Value "$datime Media copy done for $version"
           }
           else {
               Add-Content -Path $file -Value "$datime Media copy failed for $version"
           }
        }
 }
 
 #endregion HTML&Function Declarations 

 #region Initialization -Checking serverlist and making sure all nodes are up

 New-Item -Path $logile -ItemType Directory -Force -Verbose
 New-Item -Path $logfile -Name "logs" -ItemType Directory -Force -Verbose
 foreach($file in @("servers0.txt","servers.txt","currentset.txt","restset.txt")) {
    New-Item -Path $logfile -Name $file -ItemType File -Force -Verbose
}

$set = (Get-Content "$location\Patch\servers.txt")
Add-Content -Path "$logfile\servers0.txt" -Value $set
$set | % {$_.Trim()} | Select -Unique
Add-Content -Path "$logfile\servers.txt" -Value $set

$targetpath = $target.Path
foreach($server in $set) {
    if(Test-Connection $server -Count 1 -Quiet) {
        if(Test-Path "\\$server\$targetpath\patch_progress.txt") {
            Remove-Item -Recurse -Force "\\$server\$targetpath\patch_progress.txt"
        }
        if(Test-Path "\\$server\$targetpath\rolerunning.txt") {
            Remove-Item -Recurse -Force "\\$server\$targetpath\rolerunning.txt"
        }
        New-Item -Path "$logfile\logs" -Name "$server.txt" -ItemType File
    }
    elseif([bool](Resolve-DnsName $server -ErrorAction SilentlyContinue)) {
        $state_group.'down'.Add($server,"Server Down")
    }
    else {
        $state_group.'issue'.Add($server,"Server does not exist")
    }
}
updateset -state_group $state_group -from 0

#endregion Initilization -Checking serverlist and making sure all nodes are up

#region Getting SQL Details and Copy Media

Get-Job | Remove-Job -Force
$set = (Get-Content "$logfile\servers.txt")
$wait_counter=@{}
$set | % {$wait_counter.$_ = 0}
while($wait_counter.Keys.Count) {
    foreach($server in @($wait_counter.Keys)) {
        if(Test-Path "$location\Pre-Patch\Logs\Current\$server.json") {
            $jobname = "Copy-media_$server"
            if($jobname -in $jobs.Name) {
                $job = $jobs | ? {$_.Name -eq $jobname}
                if($job) {
                    if($job.State -like "Completed") {
                        updatestatus -server $patch.$server
                        $flag = 0
                        $logs = Get-Content "\\$server\$targetpath\Patch_progress.txt"
                        foreach($version in @($patch.$server.Versions.Keys)) {
                            $datime = log_time
                            if($logs -like "*Media copy done for $version*") {
                                $patch.$server.Versions.$version | % {$_.State = "Copied"}
                            }
                            else {
                                if($logs -like "*Media copy failed for $version*") {
                                    $flag++
                                }
                                $patch.$server.Versions.Remove($version)
                            }
                        }
                        if($patch.$server.Versions.Count) {
                            $patch.$server.State = "Media Copied"
                        }
                        elseif($flag) {
                            $state_group."fail".Add($server,"Media Not Copied")
                        }
                        else {
                            $state_group."skip".Add($server,"No Patch Required")
                        }
                        $wait_counter.Remove($server)
                    }
                    elseif($job.state -like "Running") {
                        if($wait_counter.$server -lt $timeout."Copy-media") {
                            $wait_counter.$server++
                        }
                        else {
                            $state_group."timeout".Add($server,"at Copy-media")
                            $wait_counter.Remove($server)
                        }
                    }
                }
                else {
                    $wait_counter.$server = 0
                    $temp = Get-Content -Path "$location\Pre-Patch\Logs\Current\$server.json" | Out-String | ConvertFrom-Json
                    $new = Invoke-Command -FilePath $scripts."Build-Object" -ComputerName $server -ErrorAction Stop -ArgumentList $temp
                    $details.Add($server,$temp)
                    $patch.Add($server,$new)
                    $jobs += Start-Job -ScriptBlock $copymdeia -ArgumentList $new,$configuration -Name "Copy-media_$server"
                }
            }
            elseif([bool](Get-Job -Name "Get-Details_$server" -ea SilentlyContinue)) {
                $jobs = $jobs | ? {$_.Name -eq "Get-Details_$server"}
                if($job) {
                    if($job.state -like "Completed") {
                        $file = gci -Path "\\$server\$targetpath\ServerDetails" | ? {$_.Name -like "*.json"} | sort LastWritetime | select -Last 1
                        if($file.Name.Substring(0,$file.Name.IndexOf('.')) -in @($job.ChildJobs.Output)) {
                            Copy-Item -Path "\\$server\$targetpath\ServerDetails\$file" -Destination "$location\Pre-Patch\Logs\Current\$server.json" -Force -Recurse -Verbose 
                        }
                        else {
                            $wait_counter.Remove($server)
                            $state_group."fail".Add($server,"JSON not created")
                        }
                    }
                    elseif($job.state -like "Running") {
                        if($wait_counter.$server -lt $timeout."Get-details") {
                            $wait_counter.$server++
                        }
                        else {
                            $state_group."timeout".Add($server,"at Get-details")
                            $wait_counter.Remove($server)
                        }
                    }
                    else {
                        $cj = Get-Job -Id ($job.Id+1)
                        $reason = $cj.JobStateInfo.Reason
                        $state_group."fail".Add($server,$reason)
                        $wait_counter.Remove($server)
                    }
                }
            }
            else {
                $jobs += Invoke-Command -ComputerName $server -JobName "Get-Details_$server" -FilePath $scripts."Get-Details" -ErrorAction Stop
                $wait_counter.$server = 0
            }
        }
        Start-Sleep -Seconds 30
}
updateset -state_group $state_group -from 0

#endregion Getting SQL Details and Copy Media

#region check Mul roles and Populate Passive nodes

$targetpath = $target.path
foreach($name in $patch.Keys) {
    $flag = 0
    $server = $patch.$sname
    if($server.Versions.Count -gt 1) {
        $state_group."issuse".Add($sname, "Multiple Versions")
        Continue;
    }
    if($server.AG_type -eq "Both") {
        $state_group."issue".Add($sname,"Multiple Sync Types in AG")
        Continue;
    }
    foreach($instance in $server.Instances.Keys) {
        if(($server.Instances.$instance.is_Clustered) -and (!$server.Instances.$instance.is_Active)) {
            foreach($clupartner in $server.Windows_Cluster.Cluster_Partners) {
                $serv = $clupartner.Name
                if($patch.ContainsKey($serv) -and $patch.$serv.Instances.ContainsKey($instance) -and $patch.$serv.Instances.$instance.is_Active) {
                    $server.Instances.$instance.HADR = $patch.$serv.Instances.$instance.HADR
                    $server.Instances.$instance.isPri = $patch.$serv.Instances.$instance.isPri
                    foreach ($hadr in $server.Instances.$instance.HADR.Keys) {
                        if(!$server.HADR.ContainsKey($hadr)) {
                            $server.HADR.$hadr = @()
                        }
                        $server.HADR.$hadr+= $patch.$serv.HADR.$hadr
                    }
                }
            }
        }
        foreach($hadr in $server.Instances.$instance.HADR.Keys) {
            if($server.Instances.$instance.HADR.$hadr.Priority.count -gt 1) {
                $datime = log_time
                Add-Content -Path \\$sname\$targetpath\Patch_Progress.txt -Value "$datime Multiple Roles found for $instance under $_"
                $flag++
            }
        }
        if($flag -eq 0) {
            if($server.Instances.$instance.isPri -eq -1) {
                $datime = log_time
                Add-Content -Path \\$sname\$targetpath\Patch_Progress.txt -Value "$datime Multiple Roles found for $instance under different HADRs"
                $flag++
            }
            elseif($server.Instances.$instance.isPri -ne $null) {
                if($server.isPri -eq $null) {
                    $server.isPri = $server.Instances.$instance.isPri
                    $temp = $instance
                }
                elseif($server.isPri -ne $server.Instances.$instance.isPri) {
                    $datime= log_time
                    Add-Content -Path "\\$sname\$targetpath\Patch_Progress.txt" -Value "$datime Multiple Roles found for Instances $instance and $temp"
                    $flag++
                }
            }
        }
    }
    if($flag) {
        $state_group."issue".Add($sname,"Multiple Roles")
    }
}
updateset -state_group $state_group -from 0

#endregion Check Mul roles and populate Passive nodes

#region Make groups and ordering sets

$group=@{}
$set = Get-Content "$logfile\servers.txt"
$link = @{}

foreach($sname in $set) {
    $set1 = Get-Content "$logfile\currentset.txt"
    $set2 = Get-Content "$logfile\restset.txt"
    updateset -state_group $state_group -from 0
    if((($sname -notin $set1) -and ($sname -notin $set2)) -and ($patch.ContainsKey($sname))) {
        $server = $patch.$sname
        if($server.HADR.Count) {
            $list = $null
            foreach($gid in $group."Other") {
                if($gid -like "*$sname") {
                    $list = $gid.Split("+")
                    Break;
                }
            }
            if($list -eq $null) {
                $partners = getrelated -server $server
                if(($partners.Count -eq 1) -or ($check -ne $sname)) {
                    $state_group."issue".Add($sname, "Multiple HADR Partners")
                    $state_group."issue".Add($partners, "Multiple HADR Partners")
                    $state_group."issue".Add($check, "Multiple HADR Partners")
                    Continue;
                }
                elseif($server.isPri -eq $part_obj.isPri) {
                    $state_group."issue".Add($sname, "Multiple HADR Roles")
                    $state_group."issue".Add($partners, "Multiple HADR Roles")
                    Cotinue;
                }
                elseif(!$group.ContainsKey("Other")) {
                    $group."Other"=@()
                }
                $name = "$partners+$sname"
                $group."Other"+= $name
            }
            elseif($partners.Count -gt 1) {
                $flag = $false
                foreach($p in $partners) {
                    $part_obj = $patch.$p
                    $check = getrelated -server $part_obj
                    foreach($chk_serv in $check) {
                        if(($patch.ContainsKey($chk_srv)) -and ($chk_serv -notin $partners) -and ($chk_Serv -ne $sname)) {
                            $state_group."issue".Add($sname,"Multiple HADR Partners")
                            $state_group."issue".Add($chk_serv,"Multiple HADR Partners")
                            $state_group."issue".Add($p,"Multiple HADR Partners")
                            $flag = $true
                        }
                    }
                }
                if($flag -eq $false) {
                    if(!$group.ContainsKey("Mul-AG")) {
                        $group."Mul-AG"=@{}
                    }
                    $sync_chart = @{}
                    $temp = $partners
                    $temp+=$sname
                    foreach($n in $temp) {
                        $s1 = $patch.$n
                        if($s1.isPri -eq 1) {
                            $sync_chart.$n = 1
                        }
                        elseif($s1.AG_Type -eq "Sync") {
                            $sync_chart.$n = 2
                        }
                        elseif($s1.AG_Type -eq "Async") {
                            $sync_chart.$n = 3
                        }
                    }
                    [system.String]::Join("+",$temp)
                    $group."Other".Add($temp,$sync_chart)
                }
                else {
                    Continue;
                }
            }
        }
        if($server.HADR.ContainsKey("FC")) {
            $flag = 0
            $ids = @()
            $ids += $server.HADR."FC"
            $active_counter = @{}
            $active_counter.$sname = 0
            $group_Pri = $server.isPri
            $obj_group = [PSCustomObject]@{
                isPri = $server.isPri
                Order = New-Object System.Collections.ArrayList($null)
            }
            foreach ($id in $ids) {
                if(($server.Instances.$id.is_clustered) -and ($server.Instances.$id.is_active)) {
                    $active_counter.$sname++
                }
            }
            foreach($clupartner in $server.Windows_Cluster.CLuster_Partners) {
                $serv = $clupartner.Name
                if(($patch.ContainsKey($serv)) -and ($serv -in $set) -and ($patch.$serv.HADR.ContainsKey("FC")) -and ([bool](Compare-Object $ids $patch.$serv.HADR."FC" | % { $_.InputObjects}) -eq $false) -and ($obj_group.isPri -eq $patch.$serv.isPri)) {
                    $active_counter.$serv=0
                    $patch.$serv.HADR."FC" = $ids
                    foreach($id in $ids) {
                        if(($server.Instances.$id.is_Clustered) -and ($server.Instances.$id.is_Active)) {
                            $active_counter.$serv++
                        }
                    }
                }
            }
            if(($active_counter.Count) -lt 2 -and ($active_counter.$sname -gt0)) {
                $state_group."issue".Add($name,"No Cluster Partners Found")
                $flag++
                Continue;
            }
            $obj_group | Add-Member -MemberType NoteProperty -Name ActiveChart -Value @{}
            while(@($active_counter.Count)) {
                foreach($i in @($active_counter.Keys)) {
                    if($i -notin $obj_group.Order) {
                        $min = $i
                        foreach($j in @($active_counter.Keys)) {
                            if(($j -ne $i) -and ($active_counter.$min -gt $active_counter.$j)) {
                                $min = $j
                            }
                        }
                        $obj_group.Order.Add($min)
                        $obj_group.ActiveChart.Add($min,$active_counter.$min)
                        $active_counter.Remove($min)
                    }
                }
            }
            if(!$group.ContainsKey("FC")) {
                $group."FC"=@{}
            }
            $group."FC".Add([string]$ids,$obj_group)
            if($obj_group.isPri -eq 1) {
                $obj_group.Order | % {
                    moveserver -server $_ -from $null -to 2
                    if([bool]$_ -and $patch.ContainsKey($_)) {
                        $patch.$_.State = "Waiting for BCP"
                    }
                }
            }
            else {
                $total = $obj_group.Order.Count
                for($i =0;$i -lt $total;$i++) {
                    $tempname = $obj_group.Order[$i]
                    if([bool]$tempname -and $patch.ContainsKey($tempname)) {
                        if($i -lt $obj_group.Order.Count/2) {
                            moveserver -server $tempname -from $null -to 1
                            if($obj_group.ActiveChart.$tempname) {
                                $patch.$tempname.State = "Requires Cluster Failover"
                                if($i -ne $total-1-$i) {
                                    $link.$tempname = $obj_group.Order[$total-1-$i]
                                }
                                else {
                                    $link.$tempname = $obj_group.Order[$total-$i]
                                }
                            }
                            else{
                                moveserver -server $tempname -from $null -to 2
                                $ptach.$tempname.State = "Queued for Patch"
                            }
                        }
                    }
                }
            }
            else {
                $gr = $null 
                $gr = $group."Other" | ? {$_ -like "*$sname"}
                if($gr -ne $null) {
                    if($server.isPri -eq 1) {
                        moveserver -server $sname -from $null -to 2
                        $patch.$sname.State = "Waiting for BCP"
                    }
                    else {
                        moveserver -server $sname -from $null -to 1
                        $patch.$sname.State = "Ready to Patch"
                    }
                }
                else {
                    $gr = $group."Mul-AG".Keys | ? {$_ -like "*$sname*"}
                    if($gr -ne $null) {
                        $thisgr = $group."Mul-AG".$gr
                        foreach($rep in $thisgr.Keys) {
                            $obj_rep = $path.$rep
                            if($obj_rep.isPri -eq 1) {
                                moveserver -server $rep -from $null -to 2
                                $patch.$rep.State = "Waiting for BCP"
                            }
                            elseif($thisgr.$rep -eq 3) {
                                moveserver -server $rep -from $null -to 1
                                $patch.$rep.State = "Ready to Patch"
                            }
                            elseif($thisgr.$rep -eq 2) {
                                moveserver -server $rep -from $null -to 2
                                $patch.$rep.State = "Waiting for Async"
                            }
                        }
                    }
                }
            }
        }
        else {
            if(!$group.ContainsKey("SA")) {
                $group."SA"=@()
            }
            $group."SA"+=$sname
            $server.State = "Ready to Patch"
            moveserver -server $sname -from $null -to 1
        }
    }
}

#endregion Make Groups and Ordering sets

#region Run Patch

$set1 = Get-Content "$logfile\currentset.txt"
$set2 = Get-Content "$logfile\restset.txt"
while($set1) {
    $fresh = @()
    $set1 = Get-Content "$logfile\currentset.txt"
    $set2 = Get-Content "$logfile\restset.txt"

    foreach($sname in $set1) {
        $server = $patch.$sname
        if($server.State -eq "Requires Failback") {
            $jobname = "Failback_$sname"
            if($jobname -in $jobs.Name) {
                $job = $jobs | ? {$_.Name -eq $jobname}
                $cj = Get-Job -Id ($job.Id+1)
                if($job.State -like "Completed") {
                    updatestatus -server $server
                    $datime = log_time
                    if($server.Display_Status -like "Failback successful for * roles") {
                        Add-Content "\\$sname\$targetpath\Patch_Progress.txt" -Value "$datime Patching activity Complete"
                        $state_group."done".Add($sname,"Completely Successfully")
                        $server.State = "Patch Complete"
                    }
                    else {
                        Add-Content "\\$sname\$targetpath\Patch_Progress.txt" -Value "$datime Patching activity Complete with errors"
                        $state_group."fail".Add($sname,"Patched with failback errors")
                    }
                }
                elseif(($job.State -like "Running") -or ($job.State -like "Failed")) {
                    if(($job.State -like "Failed") -and ($server.Stage_timer -lt $timeout."Failback")) {
                        $jobs = $jobs | ? {$_.Name -ne $jobname}
                        $jobs += Invoke-Command -ComputerName $sname -JobName $jobname -FilePath $scripts.Failback -ErrorAction Stop -ArgumentList ($sname,$timeout.Failback,$targetpath,$server.Windows_Cluster)
                    }
                    elseif($server.Stage_timer -lt $timeout."Failback") {
                        $server.Stage_timer++
                    }
                    elseif($job.State -like "Running") {
                        $state_group."timeout".Add($sname,"at Failback")
                    }
                    else {
                        $reason = $cj.JobStateInfo.Reason
                        $state_group."fail".Add($sname,$reason)
                    }
                }
                else {
                    $state_group."fail".Add($sname,"Failback job failed")
                    $server.Stage_timer = 0
                }
            }
            else {
                $jobs += Invoke-Command -ComputerName $sname -JobName $jobname -FilePath $scripts.Failback -ErrorAction Stop -ArgumentList ($sname,$timeout.Failback,$targetpath,$server.Windows_Cluster)
            }
        }
        elseif ($server.State -eq "Rebooting") {
            if((Test-Connection $sname -Count 1 -Quiet) -and (Test-Path "\\$sname\$targetpath\Patch_progress.txt")) {
                $datime = log_time
                Add-Content "\\$sname\$targetpath\Patch_progress.txt" -Value "$datime Server back online"
                if($server.HADR.ContainsKey("FC") -and ($group."FC".($server.HADR."FC").ActiveChart.$sname -ne 0)) {
                    $server.State = "Requires Failback"
                    $server.Stage_timer = 0
                }
                else {
                    $datime = log_time
                    Add-Content "\\$sname\$targetpath\Patch_progress.txt" -Value "$datime Patching activity Complete"
                    $state_group."done".Add($sname,"Completed Successfully")
                }
            }
            else {
                $state_group."down".Add($sname,"after Patch")
            }
        }
        elseif ($server.State -eq "Patch Validation") {
            $jobname = "Validate_$sname"
            if($jobname -in $jobs.Name) {
                $job = $jobs | ? {$_.Name -eq $jobname}
                $cj = Get-Job -Id ($job.Id+1)
                if($job.State -like "Completed") {
                    updatestatus -server $server
                    if($server.Display_Status -like "Patch applied") {
                        $server.State = "Rebooting"
                        $datime = log_time
                        Add-Content "\\$sname\$targetpath\Patch_progress.txt" -Value "$datime Rebooting server"
                        updatestatus -server $server
                        Restart-Computer -ComputerName $sname -Force
                        $server.Stage_timer = 0
                    }
                    else {
                        $state_group."fail".Add($sname,"Patch failed")
                    }
                }
                elseif($job.State -like "Running") {
                    if($server.Stage_timer -lt $timeout."Validate") {
                        $server.Stage_timer++
                    }
                    else {
                        $state_group."timeout".Add($sname,"at Validation")
                    }
                }
                else {
                    $reason = $cj.JobStateInfo.Reason
                    $state_group."fail".Add($sname,$reason)
                }
            }
        }
        elseif ($server.State -eq "Ready to Patch") {
            $jobname = "SQL-Patch_$sname"
            if($jobname -in $jobs.Name) {
                $job = $jobs | ? {$_.Name -eq $jobname}
                $cj = Get-Job -Id ($job.Id+1)
                $mediapath = @($server.Versions.Keys)[0]
                $currentcycle = $target.Cycle
                $temp = "\\$sname\$targetpath\$mediapath"
                if($job.State -like "Completed") {
                    $jobs += Invoke-Command -ComputerName $sname -JobName "Validate_$sname" -FilePath $scripts.Validate -ErrorAction Stop -ArgumentList ($server,$target)
                    $server.Stage_timer = 0
                    $server.State = "Patch Validation"
                    $file = "SQL_Patching_"+$currentcycle+".bat"
                    $batch = Get-ChildItem -Path $temp | ? {$_.Name -eq $file}
                    if($batch) {
                        $batch | % {Remove-Item $_.FullName -Force -Verbose -ErrorAction SilentlyContinue}
                    }
                }
                elseif ($job.State -like "Running") {
                    if($server.Stage_timer -lt $timeout."Patch") {
                        $server.Stage_timer++
                    }
                    else {
                        $state_group."timeout".Add($sname,"at Patching")
                    }
                }
                else {
                    $reason = $cj.JobStateInfo.Reason
                    $state_group."fail".Add($sname,$reason)
                }
            }
            else {
                $tp = $targetpath.Replace('$',':')
                $tp = $tp+"\"+$mediapath
                $batch = Get-ChildItem -Path $temp | ? {$_.Name -like "*.bat"}
                if($batch) {
                    $batch | % {Remove-Item $_.FullName -Force -Verbose -ErrorAction SilentlyContinue}
                }
                $bin_name = $configuration.Media.$mediapath.Name
                $val = $tp+"\$bin_name /quiet /IAcceptSQLServerLicenseTerms /allinstances"
                $tp = $tp+"\SQL_Patching_"+$currentcycle+".bat"
                $temp = $temp+"\SQL_Patching_"+$currentcycle+".bat"
                Add-Content -Path $temp -Value $val
                $jobs += Invoke-Command -ComputerName $sname -Credential $credential -JobName $jobname -ErrorAction Stop -ScriptBlock {
                    param($tp) & cmd.exe /c $tp
                } -ArgumentList ($tp)
                $datime = log_time
                Add-Content "\\$sname\$targetpath\Patch_progress.txt" -Value "$datime Running Patch for $mediapath"
            }
        }
        elseif ($server.State -eq "Requires Cluster Failover") {
            $jobname = "Failover_$sname"
            if($jobname -in $jobs.Name) {
                $job = $jobs | ? {$_.Name -eq $jobname}
                $cj = Get-Job -Id ($job.Id+1)
                if($job.State -like "Completed") {
                    updatestatus -server $server
                    if($server.Display_Status -like "Failover successful for * roles") {
                        $server.State = "Ready to Patch"
                        $server.Stage_timer = 0
                    }
                    else {
                        $state_group."fail".Add($sname,"Failover failed")
                    }
                }
                elseif ($job.State -like "Running") {
                    if($server.Stage_timer -lt $timeout.Failover) {
                        $server.Stage_timer++
                    }
                    else {
                        $state_group."timeout".Add($sname,"at Failover")
                    }
                }
                else {
                    $reason = $cj.JobStateInfo.Reason
                    $state_group."fail".Add($sname,$reason)
                }
            }
            else {
                $jobs += Invoke-Command -ComputerName $sname -JobName $jobname -FilePath $scripts.Failover -ErrorAction Stop -ArgumentList ($link.$sname,$timeout.Failover,$targetpath,$server.Windows_Cluster)
            }
        }
        else {
            $state_group."issue".Add($sname,"Unexpected stage")
        }
        updatestatus -server $server
        $fresh += $server | Select -property Sname,Display_Status,State
    }
    $disp = $fresh
    $datime =log_time
    Add-Content -Path "$logfile/Patch_progress.txt" -Value "$datime `n$disp`n`n"
    Write-Host $disp | Format-Table
    
    foreach($key in $state_group.Keys) {
        if($state_group.$key.Count) {
            foreach($sname in $state_group.$key.Keys) {
                if($key -eq "done") {
                    moveserver -server $sname -from 1 -to 2
                }
                $next = $null
                $fin = 0
                $server = $patch.$sname
                if($server.HADR.Count) {
                    if($server.HADR.ContainsKey("FC") -and $group."FC".ContainsKey([string]($server.HADR."FC"))) {
                        $temp = $fc_ids | ? {$_ -eq $server.HADR."FC"}
                        $og = $group."FC".[string]($server.HADR."FC")
                        if($link.ContainsKey($sname)) {
                            $link.Remove($sname)
                        }
                        foreach($node in $og.Order) {
                            if(($node -in $set2) -and (!$link.ContainsValue($node)) -and ($patch.$node.State -eq "Queued for Patch")) {
                                moveserver -server $node -from 2 -to 1
                                if($og.ActiveChart.$node) {
                                    $patch.$node.State = "Requires Cluster Failover"
                                    $link.$node = $sname
                                }
                                else {
                                    $patch.$node.State = "Ready to Patch"
                                    $next = $node
                                    Break;
                                }
                            }
                            elseif ($patch.$node.State -eq "Patch Complete") {
                                $fin++
                            }
                        }
                        if($og.Order.Count -ne $fin) {
                            Continue;
                        }
                    }
                    if($next -eq $null) {
                        $serv_group = $null
                        $serv_group = $group."Other" | ? {$_ -like "*$sname*"}
                        if($serv_group -ne $null) {
                            $list = $serv_group.Split("+")
                            $ng = $list | ? {$_ -ne $sname}
                            $ns = $patch.$ng
                            if($ns.HADR.ContainsKey("FC")) {
                                if($group."FC".ContainsKey([string]($ns.HADR."FC"))) {
                                    $og = $group."FC".[string]($ns.HADR."FC")
                                    $total = $og.Order.Count
                                    for($i =0;$i -lt $total;$i++) {
                                        $tempname = $og.Order[$i]
                                        if([bool]$tempname -and $patch.ContainsKey($tempname)) {
                                            if($i -lt $og.Order.Count/2) {
                                                moveserver -server $tempname -from 2 -to 1
                                                if($og.ActiveChart.$tempname) {
                                                    $patch.$tempname.State = "Requires Cluster Failover"
                                                    if($i -ne $total-1-$i) {
                                                        $link.$tempname = $og.Order[$total-1-$i]
                                                    }
                                                    else {
                                                        $link.$tempname = $og.Order[$total-$i]
                                                    }
                                                }
                                                else {
                                                    $patch.$tempname.State = "Ready to Patch"
                                                }
                                            }
                                            else {
                                                $patch.$tempname.State = "Queued for Patch"
                                            }
                                        }
                                    }
                                    Continue;
                                }
                            }
                            elseif ($ns.State -eq "Waiting for BCP") {
                                moveserver -server $ng -from 2 -to 1
                                $ns.State = "Ready to Patch"
                                Continue;
                            }
                        }
                        else {
                            $next = $null
                            $serv_group = $group."Mul-AG".Keys | ? {$_ -like "*$sname*"}
                            if($serv_group -ne $null) {
                                $gr = $group."Mul-AG".$serv_group
                                $cur = $gr.$sname
                                if($cur -ne 1) {
                                    $next = $cur - 1
                                    $these = $gr.Keys | ? {$gr.$_ -eq $cur}
                                    foreach($rep in $these) {
                                        if($rep -notin $set2) {
                                            $next = $false
                                            Break;
                                        }
                                    }
                                    if($next -eq $false) {
                                        Continue;
                                    }
                                    else {
                                        $nset = $gr.Keys | ? {$gr.$_ -eq 2}
                                        foreach ($rep in $nset) {
                                            moveserver -server $rep -from 2 -to 1
                                            $rep.State = "Ready to Patch"
                                        }
                                        Continue;
                                    }
                                }
                            }
                        }
                    }
                    else {
                        Continue;
                    }
                }
            }
        }
    }
    updateset -state_group $state_group -from 1
    Start-Sleep -Seconds 30
}
                  
#endregion Run Patch

#region populate skip

Clear-Content "$location\Patch\servers.txt"
$set2 = Get-Content "$logfile\restset.txt"
foreach ($sname in $set2) {
    $flag = $false
    foreach ($state in $state_group.Keys) {
        $data = Get-Content "$logfile\$state.txt" -ErrorAction SilentlyContinue
        if($data -like "$sname : *") {
            $flag = $true
        }
    }
    if(!$flag) {
        $state_group."skip".Add($sname,"Skipped Server")
    }
}
updateset -state_group $state_group -from 2

#endregion populate skip
Stop-Transcript



 
   






       










