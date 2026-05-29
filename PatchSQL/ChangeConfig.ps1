param(
    [Parameter(Mandatory)][string]$MediaRoot,
    [Parameter(Mandatory)][string]$Cycle,
    [Parameter(Mandatory)][string]$ScriptsPath,
    [Parameter(Mandatory)][string]$TargetPath
)

$run_datetime  = (Get-Date).ToUniversalTime()
$credential    = Get-Credential -Message "Enter credentials to store in config"
$media_cycle   = "${MediaRoot}_${Cycle}"

if (!(Test-Path $media_cycle)) {
    Write-Host "NO MEDIA FOUND at $media_cycle" -ForegroundColor Red
    return
}

$obj_config = [PSCustomObject]@{
    ServerName   = $env:COMPUTERNAME
    Ran_at       = $run_datetime
    Ran_by       = $credential.UserName
    Timeouts     = @{
        "Get-details" = 50
        "Copy-media"  = 8
        "Failover"    = 90
        "Patch"       = 360
        "Reboot"      = 60
        "Failback"    = 90
        "Validate"    = 20
    }
    Targets      = @{
        "Cycle" = $Cycle
        "Path"  = $TargetPath
    }
    State_groups = @("down","fail","issue","done","skip","timeout")
    Scripts      = @{
        "Get-Details"   = "$ScriptsPath\GetDetails\Gedet.ps1"
        "Build-Object"  = "$ScriptsPath\PatchSQL\BuildPatchObject.ps1"
        "Failover"      = "$ScriptsPath\PatchSQL\Failover.ps1"
        "Failback"      = "$ScriptsPath\PatchSQL\Failover.ps1"
        "Validate"      = "$ScriptsPath\PatchSQL\ValiPatch.ps1"
        "Path"          = $ScriptsPath
    }
    Media        = @{}
}

$versions = Get-ChildItem -Path $media_cycle -Directory
foreach ($ver in $versions) {
    $media = Get-ChildItem -Path $ver.FullName | Where-Object { $_.Name -like "SQLServer*.exe" }
    if ($media) {
        $obj_config.Media[$ver.Name] = @{
            Name         = $media.Name
            LastModified = $media.LastWriteTimeUtc
            Size         = $media.Length
        }
        $obj_config.Targets[$ver.Name] = $media.VersionInfo.ProductVersion
    }
}

$filename = "Config_${Cycle}_$($run_datetime.ToString('MM_dd_yyyy_HH_mm_ss'))"
$json = ConvertTo-Json -InputObject $obj_config -Depth 4
$json | Out-File "$ScriptsPath\$filename.ini" -Encoding UTF8

Write-Host "Config written to $ScriptsPath\$filename.ini"
Write-Host "Detected versions: $($obj_config.Media.Keys -join ', ')"
