param(
    [object]$Server,
    [object]$Target
)

$path = $Target.Path.Replace('$', ':')
$file = "$path\Patch_progress.txt"
$flag = 0

function log_time {
    return "[$(((Get-Date).ToUniversalTime()).ToString())] --"
}

$instances = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances

if (!$instances) {
    Add-Content $file -Value "$(log_time) No SQL Server instances found"
    return
}

foreach ($instance in $instances) {
    $reg_path   = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$instance
    $patchLevel = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$reg_path\Setup").PatchLevel

    foreach ($key in $Server.Versions.Keys) {
        $ver_prefix = $Target.$key.Substring(0, 2)
        if ($patchLevel.Substring(0, 2) -eq $ver_prefix) {
            $datime = log_time
            if ($patchLevel -eq $Target.$key) {
                Add-Content $file -Value "$datime Patch successful for $instance — patch level $patchLevel"
            }
            else {
                Add-Content $file -Value "$datime Patch unsuccessful for $instance — expected $($Target.$key), found $patchLevel"
                $flag++
            }
            break
        }
    }
}

$datime = log_time
if ($flag -gt 0) {
    Add-Content $file -Value "$datime Patch failed"
}
else {
    Add-Content $file -Value "$datime Patch applied"
}
