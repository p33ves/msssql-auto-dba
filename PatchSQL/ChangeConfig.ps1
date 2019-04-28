$run_datime = (Get-date).ToUniversalTime()
$credential = Get-Credential
$path = "<path>"
$cycle = "<cycle>"

if(Test-Path "$path_$cycle") {
    $obj_config = [PSCustomObject] @{
        ServerName = $env:COMPUTERNAME
        Timeouts = @{
            "Get-details" = 50;
            "Copy-media" = 8;
            "Failover" = 90;
            "Patch" = 360;
            "Reboot" = 60;
            "Failback" = 90;
        }
        Targets = @{
            "Cycle" = $cycle
            "Patch" = "<target path>";
        }
        State_groups = @("down","fail","issue","done","skip","timeout")
        Scripts = @{
            "Get-details" = <>
            "Build-object" = <>
            "Failover" = <>
            "Failback" = <>
            "RunPatch" = <>
            "Validate" = <>
            "Path" = $path
            "Create-report" = <>
        }
        Media = @{}
        Ran_at = $run_datime
        Ran_by = $credential.UserName
    }
    $version = Get-ChildItem -Path  "$path_$cycle"
    foreach($ver in $version) {
        $media = $ver.FullName | Get-ChildItem | ? {$_.Name -like "SQLServer*.exe"}
        if($media) {
            $details = @{
                Name = $media.Name
                LastModified = $media.LastWriteTimeUtc
                Size = $media.Length
            }
            $obj_config.Media.Add($ver.Name,$details)
            $obj_config.Targets.Add($ver.Name,$media.VersionInfo.ProductVersion)
        }
    }
}
else {
    Write-Host "NO MEDIA FOUND!!"
}

$filename = "Config_$cycle_"+$run_datime.ToString('MM_dd_yyyy_hh_mm_ss')
$json = ConvertTo-Json -InputObject $obj_config -Depth 3
$json | Out-File "$path\$filename.ini"