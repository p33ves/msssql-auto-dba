$server = $args[0]
$target = $args[1]
$path = $target.Path.Replace('$',':')
$check = $null
$flag = 0

function log_time {
    $datime = ((Get-Date).ToUniversalTime()).ToString()
    return "[$datime] --"
}

$instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances
if ($instances) {
    foreach ($instance in $instances) {
        $reg_path = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$instance
        $patchlevel = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$reg_path\Setup").$patchlevel
        foreach ($key in $server.Versions.Keys) {
            $ver = $patchlevel.SubString(0,2)
            if($ver -eq $target.$key.SubString(0,2)) {
                $datime = log_time
                if($patchlevel -eq $target.$key) {
                    Add-Content "\\$path\Patch_progress.txt" -Value "$datime Patch Successful for $instance with $patchlevel"
                    $check = $true
                }
                else {
                    Add-Content "\\$path\Patch_progress.txt" -Value "$datime Patch Unsuccessful for $instance with $patchlevel"
                    $check = $false
                }
                Break;
            }
        }
        if($check -eq $false) {
            $flag++
        }
    }
}

$datime = log_time
if($flag) {
    Add-Content "\\$path\Patch_progress.txt" -Value "$datime Patch failed"
}
else {
    Add-Content "\\$path\Patch_progress.txt" -Value "$datime Patch applied"
}