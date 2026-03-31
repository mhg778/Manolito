<#
.SYNOPSIS
    Manolito Engine v2.7.1 - Bare-Metal Tweaking & Sysadmin Toolkit (GitHub Release)
.DESCRIPTION
    Motor de ejecución guiado por datos (manolito.json) con interfaz interactiva.
.AUTHOR
    Xciter
#>

#Requires -RunAsAdministrator
Add-Type -AssemblyName PresentationFramework

# ========================================================================
# 1. BOOTSTRAP Y CARGA DE DATOS
# ========================================================================
$DOCS_MANOLITO = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "Manolito"
$JSON_PATH     = Join-Path $PSScriptRoot "manolito.json"
$MANIFEST_PATH = Join-Path $DOCS_MANOLITO "manifest_$(Get-Date -f 'yyyyMMdd_HHmmss').json"

# Mutex (instancia única)
$_mutex = [System.Threading.Mutex]::new($false, "Global\ManolitoOptimizer")
try { $acquired = $_mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if(-not $acquired) { Write-Error "Manolito ya está en ejecución"; exit 1 }

# Transcript
if(-not (Test-Path $DOCS_MANOLITO)) { New-Item $DOCS_MANOLITO -ItemType Directory | Out-Null }
try { Start-Transcript -Path (Join-Path $DOCS_MANOLITO "transcript_$(Get-Date -f 'yyyyMMdd_HHmmss').txt") -Append } catch {}

# Cargar y Validar JSON
$script:Config = $null
if(-not (Test-Path $JSON_PATH)) { [System.Windows.MessageBox]::Show("Falta manolito.json", "Error", 0, 16); exit 1 }
$raw = Get-Content $JSON_PATH -Raw -Encoding UTF8
$raw = $raw -replace '(?m)^\s*//.*$', ''
$script:Config = $raw | ConvertFrom-Json

# Validación de versión para la serie 2.7.x
if ($script:Config.Manifest.Version -notmatch '^2\.7(\.\d+)?$') {
    [System.Windows.MessageBox]::Show('JSON Version incompatible (Se requiere v2.7.x)','Error',0,16)
    exit 1
}

# Contexto Global del Sistema
$script:SystemCaps = [PSCustomObject]@{
    IsVM           = (Get-CimInstance Win32_ComputerSystem).Model -match 'Virtual|VMware|Hyper-V'
    IsDomain       = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
    HasPhysicalNIC = (Get-NetAdapter | Where-Object { !$_.Virtual -and $_.Status -eq 'Up' }).Count -gt 0
    WinBuild       = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    HasNvidia      = (Get-CimInstance Win32_VideoController -EA SilentlyContinue | Where-Object { $_.Name -match 'NVIDIA' }).Count -gt 0
    HasNVMe        = (Get-PhysicalDisk -EA SilentlyContinue | Where-Object { $_.BusType -eq 'NVMe' -or $_.MediaType -eq 'NVMe' }).Count -gt 0
    HasBattery     = (Get-CimInstance Win32_Battery -EA SilentlyContinue).Count -gt 0
    CanUseWinget   = [bool](Get-Command winget -EA SilentlyContinue)
    IsSafeMode     = ((Get-CimInstance Win32_ComputerSystem -EA SilentlyContinue).BootupState -ne 'Normal boot')
    PendingReboot  = (
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
        ($null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -EA SilentlyContinue))
    )
}

$script:ctx = [PSCustomObject]@{
    Runtime  = [PSCustomObject]@{ IsDryRun = $true; IsRollback = $false; IsManifestRestore = $false; Runlevel = $null }
    Options  = [PSCustomObject]@{ Skip = @(); Verify = $false }
    State    = [PSCustomObject]@{ PendingReboot = $false; StepsOk = 0; StepsFail = 0 }
    Tracking = [PSCustomObject]@{ RegDiff = @(); PayloadsExecuted = @(); IrreversibleActions = @() }
    Backups  = [PSCustomObject]@{ 
        ServicesStartup = @{}
        TasksState      = @{}
        DNS             = @{}
        Hosts           = $null
        ActiveSetup     = @{}
        BCD             = @{}
    }
    Results  = [PSCustomObject]@{ Modules = @() }
}

$script:MemoriaPayloads = @{}
$script:logQueue    = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:rsHandle    = $null
$script:rsStateJson = $null

# ========================================================================
# 2. MOTOR DE AUDIO Y HELPERS
# ========================================================================
function global:Beep-UI($tipo) {
    try {
        switch ($tipo) {
            "boot" {
                [Console]::Beep(800, 30)
                [Console]::Beep(1200, 50)
            }
            "action" {
                [Console]::Beep(1000, 20)
                [Console]::Beep(1500, 40)
            }
            "check" {
                [Console]::Beep(1200, 15)
            }
            "close" {
                [Console]::Beep(1000, 30)
                [Console]::Beep(700, 50)
            }
        }
    } catch {
        # Ignora cualquier error de audio/consola
    }
}

function Invoke-ExternalCommand {
    param([string]$Command, [int]$TimeoutSec=30, [int]$MaxRetries=2)
    for($i=0; $i -le $MaxRetries; $i++) {
        $job = Start-Job -ScriptBlock {
            $out = iex $using:Command 2>&1
            [PSCustomObject]@{ Output=$out; ExitCode=$LASTEXITCODE }
        }
        $completed = Wait-Job $job -Timeout $TimeoutSec
        if ($completed) {
            $result   = Receive-Job $job
            $exitCode = if ($null -ne $result.ExitCode) { [int]$result.ExitCode }
                        else { if ($job.ChildJobs[0].Error.Count -eq 0) { 0 } else { 1 } }
            Remove-Job $job -Force
            return @{ Success=($exitCode -eq 0); Stdout=$result.Output; ExitCode=$exitCode }
        }
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force
    }
    return @{ Success=$false; Error="Timeout" }
}

function Set-ManolitoReg {
    param([string]$Path, [string]$Name, $Value, [string]$Type="DWord")
    
    $Type = switch ($Type.ToLower()) {
        'dword'       { 'DWord'       }
        'qword'       { 'QWord'       }
        'string'      { 'String'      }
        'expandstring'{ 'ExpandString' }
        'binary'      { 'Binary'      }
        'multistring' { 'MultiString'  }
        default       { $Type }
    }
    
    $before = try { (Get-ItemProperty $Path -Name $Name -EA Stop).$Name } catch { $null }
    if ($null -ne $before -and $before -is [string]) { $before = $before.ToString() }

    if($script:ctx.Runtime.IsDryRun) {
        return @{ Success=$true; Changes=1; DryRun=$true; Msg="[DRY] $Name -> $Value" }
    }
    
    if ($null -ne $before -and "$before" -eq "$Value") {
        return @{ Success=$true; Changes=0; Msg="    [SKIP] $Name (sin cambio)" }
    }

    try {
        if(!(Test-Path $Path)) { New-Item $Path -Force | Out-Null }
        Set-ItemProperty $Path -Name $Name -Value $Value -Type $Type -Force -EA Stop
        $after = (Get-ItemProperty $Path -Name $Name -EA SilentlyContinue).$Name
        if ($null -ne $after -and $after -is [string]) { $after = $after.ToString() }
        $script:ctx.Tracking.RegDiff += [PSCustomObject]@{ Path=$Path; Name=$Name; Type=$Type; Before=$before; After=$after }
        return @{ Success=$true; Changes=1; Msg="[OK] $Name" }
    } catch {
        return @{ Success=$false; Changes=0; Msg="[FAIL] $($Name): $($_.Exception.Message)" }
    }
}

function Restore-ManolitoReg {
    param([string]$Path, [string]$Name, $Before, [string]$Type="DWord")
    if ($null -eq $Before) {
        if ($script:ctx.Runtime.IsDryRun) { return @{ Success=$true; Changes=1; Msg="[DRY] $Name -> (eliminar)" } }
        if (Test-Path $Path) {
            try { 
                Remove-ItemProperty -Path $Path -Name $Name -EA Stop
                return @{ Success=$true; Changes=1; Msg="[OK] $Name eliminado (restaurando original)" } 
            } catch { 
                return @{ Success=$false; Changes=0; Msg="[FAIL] Eliminar $($Name): $($_.Exception.Message)" } 
            }
        }
        return @{ Success=$true; Changes=0; Msg="    [SKIP] $Name (no existia)" }
    } else {
        return Set-ManolitoReg -Path $Path -Name $Name -Value $Before -Type $Type
    }
}

# ========================================================================
# 3. MODULOS PAYLOAD (BACKEND)
# ========================================================================
function Invoke-PayloadAppx($packages) {
    $r = @{ Success=$true; Changes=0; Logs=@() }
    foreach($pkg in $packages) {
        if($script:ctx.Runtime.IsDryRun) { $r.Changes++; $r.Logs += "[DRY] Remove-Appx: $($pkg.FriendlyName)"; continue }
        try {
            $before = @(Get-AppxPackage -Name $pkg.Pattern -AllUsers -EA SilentlyContinue).Count
            Get-AppxPackage -Name $pkg.Pattern -AllUsers -EA SilentlyContinue | Remove-AppxPackage -AllUsers -EA SilentlyContinue
            
            $provPkg = Get-AppxProvisionedPackage -Online -EA SilentlyContinue | Where-Object { $_.DisplayName -like $pkg.Pattern }
            if ($provPkg) {
                Remove-AppxProvisionedPackage -Online -PackageName $provPkg.PackageName -EA SilentlyContinue | Out-Null
            }
            
            $after = @(Get-AppxPackage -Name $pkg.Pattern -AllUsers -EA SilentlyContinue).Count
            
            if($before -gt $after -or $before -eq 0) {
                $r.Changes++; $r.Logs += "[OK] Purgado: $($pkg.FriendlyName)"
            } else {
                $r.Logs += "[WARN] $($pkg.FriendlyName): no se pudo eliminar completamente"
            }
        } catch { $r.Success=$false; $r.Logs += "[FAIL] Error purgado: $($pkg.FriendlyName)" }
    }
    return $r
}

function Invoke-PayloadServices($services) {
    $r = @{ Success=$true; Changes=0; Logs=@() }
    foreach($svc in $services) {
        if ($script:ctx.Runtime.IsManifestRestore) {
            $state = if ($script:ctx.Backups.ServicesStartup.ContainsKey($svc.Name)) {
                $script:ctx.Backups.ServicesStartup[$svc.Name]
            } else { $svc.RestoreState }
        } else {
            $state = if ($script:ctx.Runtime.IsRollback) { $svc.RestoreState } else { $svc.TargetState }
        }

        if($script:ctx.Runtime.IsDryRun) { $r.Changes++; $r.Logs += "[DRY] Servicio $($svc.Name) -> $state"; continue }
        
        $current = Get-Service $svc.Name -EA SilentlyContinue
        if(-not $current) { $r.Logs += "[SKIP] $($svc.Name) no existe"; continue }
        if(-not $script:ctx.Backups.ServicesStartup.ContainsKey($svc.Name)) { $script:ctx.Backups.ServicesStartup[$svc.Name] = $current.StartType.ToString() }
        
        Set-Service $svc.Name -StartupType $state -EA SilentlyContinue
        
        if     ($state -eq 'Disabled')  { Stop-Service  $svc.Name -Force -EA SilentlyContinue }
        elseif ($state -eq 'Automatic') { Start-Service $svc.Name        -EA SilentlyContinue }
        
        $post           = Get-Service $svc.Name -EA SilentlyContinue
        $expectedStatus = switch ($state) {
            'Disabled'  { 'Stopped'  }
            'Automatic' { 'Running'  }
            default     { $null }
        }
        
        if ($expectedStatus -and $post -and $post.Status -ne $expectedStatus) {
            $r.Logs += "    [WARN] $($svc.Name) status=$($post.Status) esperado=$expectedStatus"
        } else {
            $r.Logs += "    [OK]  Servicio $($svc.Name) → $state"; $r.Changes++
        }
    }
    return $r
}

function Invoke-PayloadTasks($tasks) {
    $r = @{ Success=$true; Changes=0; Logs=@() }
    foreach($task in $tasks) {
        if ($script:ctx.Runtime.IsManifestRestore) {
            $taskKey = "$($task.Path)|$($task.Name)"
            $saved   = $script:ctx.Backups.TasksState[$taskKey]
            $state   = if ($saved) {
                           if ($saved -eq 'Disabled') { 'Disable' } else { 'Enable' }
                       } else { $task.RestoreState }
        } else {
            $state = if ($script:ctx.Runtime.IsRollback) { $task.RestoreState } else { $task.TargetState }
        }
        
        if ($task.MinBuild -and $script:SystemCaps.WinBuild -lt [int]$task.MinBuild) {
            $r.Logs += "    [SKIP] $($task.Name) — requiere build $($task.MinBuild), actual $($script:SystemCaps.WinBuild)"
            continue
        }
        
        if ($script:ctx.Runtime.IsDryRun) {
            $r.Changes++; $r.Logs += "    [DRY] Tarea $($task.Name) -> $state"; continue
        }
        
        $schTask = Get-ScheduledTask -TaskPath $task.Path -TaskName $task.Name -EA SilentlyContinue
        if(-not $schTask) { $r.Logs += "[SKIP] $($task.Name) no existe"; continue }
        
        $taskKey = "$($task.Path)|$($task.Name)"
        if (-not $script:ctx.Backups.TasksState.ContainsKey($taskKey)) {
            $script:ctx.Backups.TasksState[$taskKey] = $schTask.State.ToString()
        }
        
        if($state -eq "Disable") { $schTask | Disable-ScheduledTask -EA SilentlyContinue | Out-Null } else { $schTask | Enable-ScheduledTask -EA SilentlyContinue | Out-Null }
        $r.Changes++; $r.Logs += "[OK] Tarea $($task.Name) -> $state"
    }
    return $r
}

function Invoke-PayloadRegistry($registry) {
    $r = @{ Success=$true; Changes=0; Logs=@() }
    foreach($reg in $registry) {
        if ($script:ctx.Runtime.IsManifestRestore) {
            $diff = $script:ctx.Tracking.RegDiff | Where-Object { $_.Path -eq $reg.Path -and $_.Name -eq $reg.Name } | Select-Object -First 1
            if ($diff) {
                $res = Restore-ManolitoReg -Path $reg.Path -Name $reg.Name -Before $diff.Before -Type $reg.Type
            } else {
                $res = Set-ManolitoReg -Path $reg.Path -Name $reg.Name -Value $reg.RestoreValue -Type $reg.Type
            }
        } else {
            $val = if ($script:ctx.Runtime.IsRollback) { $reg.RestoreValue } else { $reg.TargetValue }
            $res = Set-ManolitoReg -Path $reg.Path -Name $reg.Name -Value $val -Type $reg.Type
        }
        $r.Changes += $res.Changes; $r.Logs += $res.Msg; if(-not $res.Success){$r.Success=$false}
    }
    return $r
}

function Invoke-PayloadNagle($template) {
    $r = @{ Success=$true; Changes=0; Logs=@() }
    $adapters = @(Get-NetAdapter | Where-Object { 
        !$_.Virtual -and 
        $_.Status -eq 'Up' -and 
        $_.InterfaceDescription -notmatch 'TAP|Tunnel|VPN|WireGuard|Loopback|Hyper-V|vEthernet' 
    })
    if($adapters.Count -eq 0) { $r.Logs += "[SKIP] Sin NIC fisica activa"; return $r }
    $ifaceRoot = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
    foreach($adapter in $adapters) {
        $nicIPs = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -EA SilentlyContinue | Where-Object { $_.IPAddress -ne "0.0.0.0" } | Select-Object -ExpandProperty IPAddress)
        if($nicIPs.Count -eq 0) { continue }
        foreach($guid in @(Get-ChildItem $ifaceRoot -EA SilentlyContinue)) {
            $props = Get-ItemProperty $guid.PSPath -EA SilentlyContinue
            $allIPs = @($props.DhcpIPAddress) + @($props.IPAddress) | Where-Object { $_ -and $_ -ne "0.0.0.0" }
            if($allIPs | Where-Object { $_ -in $nicIPs }) {
                foreach($entry in $template) {
                    if ($script:ctx.Runtime.IsManifestRestore) {
                        $diff = $script:ctx.Tracking.RegDiff |
                                Where-Object { $_.Name -eq $entry.Name -and $_.Path -like "*$($guid.PSChildName)*" } |
                                Select-Object -First 1
                        if ($diff) {
                            $res = Restore-ManolitoReg -Path $guid.PSPath -Name $entry.Name -Before $diff.Before -Type $entry.Type
                        } else {
                            $res = Restore-ManolitoReg -Path $guid.PSPath -Name $entry.Name -Before $null -Type $entry.Type
                        }
                    } else {
                        $val = if($script:ctx.Runtime.IsRollback){ $entry.RestoreValue } else { $entry.TargetValue }
                        $res = Set-ManolitoReg -Path $guid.PSPath -Name $entry.Name -Value $val -Type $entry.Type
                    }
                    $r.Changes += $res.Changes; $r.Logs += $res.Msg
                }
                break
            }
        }
    }
    return $r
}

function Invoke-PayloadDNS($dns) {
    $r = @{ Success=$true; Changes=0; Logs=@() }
    $adapters = @(Get-NetAdapter | Where-Object { 
        !$_.Virtual -and 
        $_.Status -eq 'Up' -and 
        $_.InterfaceDescription -notmatch 'TAP|Tunnel|VPN|WireGuard|Loopback|Hyper-V|vEthernet' 
    })
    foreach($adapter in $adapters) {
        if($script:ctx.Runtime.IsDryRun) { $r.Changes++; $r.Logs += "[DRY] DNS $($adapter.Name) -> $($dns.Primary.TargetValue)"; continue }
        try {
            if(-not $script:ctx.Backups.DNS.ContainsKey($adapter.Name)) {
                $currentDNS = (Get-DnsClientServerAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -EA SilentlyContinue).ServerAddresses
                $script:ctx.Backups.DNS[$adapter.Name] = if($currentDNS){ @($currentDNS | ForEach-Object { "$_" }) } else { @("DHCP") }
            }
            if ($script:ctx.Runtime.IsManifestRestore) {
                $backup = $script:ctx.Backups.DNS[$adapter.Name]
                if (-not $backup -or $backup -eq 'DHCP') {
                    Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ResetServerAddresses -EA Stop
                } else {
                    $dnsServers = @($backup | ForEach-Object { [string]$_ })
                    Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses $dnsServers -EA Stop
                }
            } elseif ($script:ctx.Runtime.IsRollback) {
                $backup = $script:ctx.Backups.DNS[$adapter.Name]
                if (-not $backup -or $backup -eq 'DHCP' -or (@($backup).Count -eq 1 -and $backup[0] -eq 'DHCP')) {
                    Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ResetServerAddresses -EA Stop
                } else {
                    $dnsServers = @($backup | ForEach-Object { [string]$_ })
                    Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses $dnsServers -EA Stop
                }
            } else {
                Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses $dns.Primary.TargetValue,$dns.Secondary.TargetValue -EA Stop
            }
            $r.Changes++; $r.Logs += "[OK] DNS $($adapter.Name) configurado"
        } catch { $r.Success=$false; $r.Logs += "[FAIL] DNS $($adapter.Name): $($_.Exception.Message)" }
    }
    return $r
}

function Invoke-PayloadBCD($bcd) {
    $r = @{ Success=$true; Changes=0; Logs=@() }
    foreach ($entry in $bcd) {
        if ($script:ctx.Runtime.IsManifestRestore) {
            $val = if ($script:ctx.Backups.BCD.ContainsKey($entry.Setting)) {
                       $script:ctx.Backups.BCD[$entry.Setting]
                   } else { $entry.RestoreValue }
        } else {
            $val = if ($script:ctx.Runtime.IsRollback) { $entry.RestoreValue } else { $entry.TargetValue }
        }
        
        if (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Backups.BCD.ContainsKey($entry.Setting)) {
            $bcdBefore = (bcdedit /enum '{current}' 2>$null | Select-String $entry.Setting)
            $script:ctx.Backups.BCD[$entry.Setting] = if ($bcdBefore) {
                "" + ($bcdBefore.Line -split '\s+', 2)[1].Trim()
            } else { $entry.RestoreValue }
        }
        
        $cmd = "bcdedit /set $($entry.Setting) $val"
        if($script:ctx.Runtime.IsDryRun) { $r.Changes++; $r.Logs += "[DRY] $cmd"; continue }
        $res = Invoke-ExternalCommand -Command $cmd -TimeoutSec 15
        if($res.Success) { $r.Changes++; $r.Logs += "[OK] BCD $($entry.Setting) -> $val" } else { $r.Success=$false; $r.Logs += "[FAIL] BCD Error" }
    }
    return $r
}

function Invoke-PayloadMSITuning($payload) {
    $r = @{ Success=$true; Changes=0; Logs=@() }
    foreach($class in $payload.DeviceClasses) {
        $devices = Get-CimInstance Win32_PnPEntity -EA SilentlyContinue | Where-Object {
            $_.Status -eq "OK" -and $_.DeviceID -like "PCI*" -and (
                ($class -eq "Display" -and $_.PNPClass -eq "Display") -or
                ($class -eq "NVMe"    -and $_.Name -match "NVM|NVMe|Non-Volatile")
            )
        }
        foreach($dev in $devices) {
            $msiPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($dev.DeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
            $r.Logs += "[MSI] Dispositivo: $($dev.Name)"
            foreach($reg in $payload.RegistryTemplate) {
                $val = if($script:ctx.Runtime.IsRollback){ $reg.RestoreValue } else { $reg.TargetValue }
                $res = Set-ManolitoReg -Path $msiPath -Name $reg.Name -Value $val -Type $reg.Type
                $r.Changes += $res.Changes; $r.Logs += $res.Msg
            }
        }
        if(-not $devices) { $r.Logs += "    [SKIP] MSI: ningún dispositivo $class encontrado" }
    }
    return $r
}

function Invoke-PayloadActiveSetup {
    param([array]$Entries)
    $r        = @{ Success = $true; Changes = 0; Logs = @() }
    $basePath = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components'
    foreach ($guid in $Entries) {
        $keyPath = Join-Path $basePath $guid
        if ($script:ctx.Runtime.IsDryRun) {
            $r.Logs += "    [DRY] ActiveSetup: Remove $guid"
            $r.Changes++
            continue
        }
        if ($script:ctx.Runtime.IsRollback) {
            $backup = $script:ctx.Backups.ActiveSetup[$guid]
            if (-not $backup) {
                $r.Logs += "    [SKIP] ActiveSetup $guid — sin backup de sesión"
                continue
            }
            try {
                New-Item $keyPath -Force -EA Stop | Out-Null
                foreach ($val in $backup) {
                    Set-ItemProperty $keyPath -Name $val.Name -Value $val.Value -Type $val.Type -Force -EA Stop
                }
                $r.Logs += "    [OK]  ActiveSetup restaurado: $guid"
                $r.Changes++
            } catch {
                $r.Logs    += "    [FAIL] ActiveSetup restore $($guid): $($_.Exception.Message)"
                $r.Success  = $false
            }
            continue
        }
        if (Test-Path $keyPath) {
            try {
                $props  = Get-Item $keyPath -EA Stop
                $backup = @()
                foreach ($v in $props.GetValueNames()) {
                    $val = $props.GetValue($v)
                    if ($null -ne $val -and $val -is [string]) { $val = $val.ToString() }
                    $backup += @{
                        Name  = "$v"
                        Value = $val
                        Type  = "" + $props.GetValueKind($v).ToString()
                    }
                }
                $script:ctx.Backups.ActiveSetup[$guid] = $backup
                Remove-Item $keyPath -Recurse -Force -EA Stop
                $r.Logs += "    [OK]  ActiveSetup eliminado: $guid"
                $r.Changes++
            } catch {
                $r.Logs    += "    [FAIL] ActiveSetup $($guid): $($_.Exception.Message)"
                $r.Success  = $false
            }
        } else {
            $r.Logs += "    [SKIP] ActiveSetup $guid — no existe en este sistema"
        }
    }
    return $r
}

function Invoke-PayloadHosts {
    param([array]$Domains)
    $r         = @{ Success = $true; Changes = 0; Logs = @() }
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $header    = '# === Manolito Engine v2.7 — Telemetry Block ==='
    $footer    = '# === END Manolito Block ==='
    if ($script:ctx.Runtime.IsDryRun) {
        foreach ($d in $Domains) { $r.Logs += "    [DRY] HOSTS: 0.0.0.0 $d" }
        $r.Changes = $Domains.Count
        return $r
    }
    try {
        if (-not $script:ctx.Backups.Hosts) {
            $script:ctx.Backups.Hosts = [System.IO.File]::ReadAllText($hostsPath)
            $r.Logs += "    [OK]  HOSTS backup almacenado en memoria"
        }
        if ($script:ctx.Runtime.IsRollback) {
            if (-not $script:ctx.Backups.Hosts) {
                $r.Logs += "    [SKIP] HOSTS Rollback — sin backup en sesión. Usa FEATURE-6 con manifest externo."
                return $r
            }
            $script:ctx.Backups.Hosts | Set-Content $hostsPath -Encoding UTF8 -Force -EA Stop
            $r.Logs += "    [OK]  HOSTS restaurado desde backup de sesión"
            $r.Changes = 1
        } else {
            $current = [System.IO.File]::ReadAllText($hostsPath)
            $current = $current -replace "(?s)$([regex]::Escape($header)).*?$([regex]::Escape($footer))\r?\n?", ''
            $block  = "`r`n$header`r`n"
            foreach ($d in $Domains) { $block += "0.0.0.0 $d`r`n" }
            $block += "$footer`r`n"
            ($current.TrimEnd() + $block) | Set-Content $hostsPath -Encoding UTF8 -Force -EA Stop
            $r.Changes  = $Domains.Count
            $r.Logs    += "    [OK]  HOSTS: $($Domains.Count) dominios → 0.0.0.0"
        }
    } catch {
        $r.Success = $false
        $r.Logs   += "    [FAIL] HOSTS: $($_.Exception.Message)"
    }
    return $r
}

function Invoke-PayloadDeKMS($payload) {
    $r = @{ Success=$true; Changes=0; Logs=@() }
    
    $kmsServer = $null
    try {
        $kmsServer = (Get-CimInstance SoftwareLicensingService -EA SilentlyContinue).KeyManagementServiceMachine
    } catch {}
    
    if ($kmsServer) {
        $r.Logs += "    [INFO] KMS Server activo: $kmsServer"
        $isBlacklisted = $false
        foreach ($entry in $payload.Blacklist) {
            if ($kmsServer -match $entry) { $isBlacklisted = $true; break }
        }
        if (-not $isBlacklisted) {
            $r.Logs += "    [SKIP] DeKMS — KMS no está en blacklist (posible activación corporativa legítima)"
            return $r
        }
        $r.Logs += "    [WARN] KMS irregular detectado: $kmsServer — procediendo a limpieza"
    } else {
        $r.Logs += "    [INFO] Sin KMS server activo — limpieza preventiva de restos"
    }
    
    if ($script:ctx.Runtime.IsDryRun) {
        $r.Logs += "    [DRY] slmgr /ckms"
        foreach ($svc  in $payload.Services) { $r.Logs += "    [DRY] Eliminar servicio KMS: $svc";  $r.Changes++ }
        foreach ($file in $payload.Files)    { $r.Logs += "    [DRY] Eliminar archivo KMS: $file"; $r.Changes++ }
        foreach ($task in $payload.Tasks)    { $r.Logs += "    [DRY] Eliminar tarea KMS: $task";   $r.Changes++ }
        return $r
    }
    
    try {
        $res = Invoke-ExternalCommand -Command "cscript //nologo `"$env:SystemRoot\System32\slmgr.vbs`" /ckms" -TimeoutSec 30
        if ($res.Success) { $r.Logs += "    [OK]  slmgr /ckms ejecutado" }
        else              { $r.Logs += "    [WARN] slmgr /ckms: $($res.Stdout)" }
        
        $sppPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform'
        if (Test-Path $sppPath) {
            Remove-ItemProperty -Path $sppPath -Name 'KeyManagementServiceName' -EA SilentlyContinue
            Remove-ItemProperty -Path $sppPath -Name 'KeyManagementServicePort' -EA SilentlyContinue
            $r.Logs += "    [OK]  Registro SPP KMS limpiado"; $r.Changes++
        }

        foreach ($svc in $payload.Services) {
            Stop-Service $svc -Force -EA SilentlyContinue
            sc.exe delete $svc 2>$null
            $r.Logs += "    [OK]  Servicio $svc purgado"; $r.Changes++
        }
        foreach ($file in $payload.Files) {
            $p = [Environment]::ExpandEnvironmentVariables($file)
            if (Test-Path $p) { Remove-Item $p -Force -EA SilentlyContinue; $r.Logs += "    [OK]  Archivo $file purgado"; $r.Changes++ }
        }
        foreach ($task in $payload.Tasks) {
            Get-ScheduledTask -TaskName $task -EA SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -EA SilentlyContinue
            $r.Logs += "    [OK]  Tarea $task purgada"; $r.Changes++
        }
    } catch {
        $r.Success = $false
        $r.Logs += "    [FAIL] Error en limpieza KMS: $($_.Exception.Message)"
    }
    return $r
}

function Invoke-Payload($PayloadName) {
    $payload = $script:Config.Payloads.PSObject.Properties[$PayloadName].Value
    if(-not $payload) { return @{ Success=$false; Logs=@("[FAIL] Payload no encontrado") } }

    $meta = $payload._meta
    if(-not $meta.Reversible -and $script:ctx.Runtime.IsRollback) { return @{ Success=$true; Skipped=$true; Logs=@("[SKIP] $($meta.Label) (No reversible)") } }
    if($script:SystemCaps.IsVM -and $PayloadName -in @("MSITuning")) { return @{ Success=$true; Skipped=$true; Logs=@("[SKIP] $($meta.Label) (VM)") } }
    if($script:SystemCaps.IsDomain -and $PayloadName -eq "DisableVBS") { return @{ Success=$true; Skipped=$true; Logs=@("    [SKIP] VBS (Dominio)") } }
    if ($script:SystemCaps.IsDomain -and $PayloadName -eq 'KillActiveSetup') { return @{ Success=$true; Skipped=$true; Logs=@('    [SKIP] KillActiveSetup — equipo en dominio') } }

    if(-not $meta.Reversible -and -not $script:ctx.Runtime.IsRollback) {
        $script:ctx.Tracking.IrreversibleActions += $PayloadName
    }

    if($meta.RequiresReboot -and -not $script:ctx.Runtime.IsDryRun) { $script:ctx.State.PendingReboot = $true }

    $moduleResult = @{ Name=$PayloadName; Success=$true; Changes=0; Logs=@() }
    $moduleResult.Logs += "> Ejecutando: $($meta.Label)..."

    if ($PayloadName -eq "DeKMS") {
        $res = Invoke-PayloadDeKMS $payload
        $moduleResult.Changes += $res.Changes; $moduleResult.Logs += $res.Logs; if(-not $res.Success){$moduleResult.Success=$false}
    } else {
        if($payload.PSObject.Properties["Packages"])         { $res = Invoke-PayloadAppx $payload.Packages;       $moduleResult.Changes += $res.Changes; $moduleResult.Logs += $res.Logs; if(-not $res.Success){$moduleResult.Success=$false} }
        if($payload.PSObject.Properties["Services"])         { $res = Invoke-PayloadServices $payload.Services;   $moduleResult.Changes += $res.Changes; $moduleResult.Logs += $res.Logs; if(-not $res.Success){$moduleResult.Success=$false} }
        if($payload.PSObject.Properties["Tasks"])            { $res = Invoke-PayloadTasks $payload.Tasks;         $moduleResult.Changes += $res.Changes; $moduleResult.Logs += $res.Logs; if(-not $res.Success){$moduleResult.Success=$false} }
        if($payload.PSObject.Properties["Registry"])         { $res = Invoke-PayloadRegistry $payload.Registry;   $moduleResult.Changes += $res.Changes; $moduleResult.Logs += $res.Logs; if(-not $res.Success){$moduleResult.Success=$false} }
        if($payload.PSObject.Properties["NagleTemplate"])    { $res = Invoke-PayloadNagle $payload.NagleTemplate; $moduleResult.Changes += $res.Changes; $moduleResult.Logs += $res.Logs; if(-not $res.Success){$moduleResult.Success=$false} }
        if($payload.PSObject.Properties["DNS"])              { $res = Invoke-PayloadDNS $payload.DNS;             $moduleResult.Changes += $res.Changes; $moduleResult.Logs += $res.Logs; if(-not $res.Success){$moduleResult.Success=$false} }
        if($payload.PSObject.Properties["BCD"])              { $res = Invoke-PayloadBCD $payload.BCD;             $moduleResult.Changes += $res.Changes; $moduleResult.Logs += $res.Logs; if(-not $res.Success){$moduleResult.Success=$false} }
        if($payload.PSObject.Properties["DeviceClasses"])    { $res = Invoke-PayloadMSITuning $payload;           $moduleResult.Changes += $res.Changes; $moduleResult.Logs += $res.Logs; if(-not $res.Success){$moduleResult.Success=$false} }
        if($payload.PSObject.Properties['ActiveSetupEntries']) {
            $res = Invoke-PayloadActiveSetup $payload.ActiveSetupEntries
            $moduleResult.Changes += $res.Changes
            $moduleResult.Logs    += $res.Logs
            if (-not $res.Success) { $moduleResult.Success = $false }
        }
        if ($payload.PSObject.Properties['HostsEntries']) {
            $res = Invoke-PayloadHosts $payload.HostsEntries
            $moduleResult.Changes += $res.Changes
            $moduleResult.Logs    += $res.Logs
            if (-not $res.Success) { $moduleResult.Success = $false }
        }
    }

    if($moduleResult.Success) { $script:ctx.State.StepsOk++ } else { $script:ctx.State.StepsFail++ }
    $script:ctx.Results.Modules += $moduleResult
    return $moduleResult
}

# ─── Helper compartido M5/MIN4: PSCustomObject → Hashtable nativo ───────────
function ConvertTo-NativeHashtable {
    param($obj)
    if ($null -eq $obj) { return @{} }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        foreach ($p in $obj.PSObject.Properties) { $ht[$p.Name] = $p.Value }
        return $ht
    }
    return $obj
}

# 1. Filtrar payloads IRR del plan actual (Sintaxis PS5.1 segura)
        $irrPayloads = @()
        foreach ($p in $script:plan) {
            $node = $script:Config.Payloads.$p
            if ($null -ne $node -and $null -ne $node._meta -and $node._meta.Risk -eq 'IRR') {
                $irrPayloads += $p
            }
        }

        # 2. Mostrar advertencia si hay IRRs y NO estamos en DryRun
        if ($irrPayloads.Count -gt 0 -and -not $script:ctx.Runtime.IsDryRun) {
            $irrList = ($irrPayloads | ForEach-Object {
                $label = $script:Config.Payloads.$_._meta.Label
                "  [!] $_ — $label"
            }) -join "`n"
            
            $msg = "ATENCION — Las siguientes acciones son IRREVERSIBLES:`n`n$irrList`n`n" +
                   "No se pueden deshacer ni con el modo ROLLBACK ni con Manifest Restore.`n`n" +
                   "¿Confirmas que quieres continuar bajo tu propia responsabilidad?"
                   
            $confirm = [System.Windows.MessageBox]::Show(
                $msg,
                'ALERTA DE SEGURIDAD',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            
            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
                $txtConsole.Text += "`n> [ABORT] Despliegue cancelado por el usuario para proteger el sistema."
                $btnDeploy.IsEnabled = $true
                $btnDeploy.Background = '#FF2079'
                $script:IsRunning = $false
                return
            }
        }

# ─── M5: Motor asíncrono real mediante Runspaces ────────────────────────────
function Start-ManolitoRunspace {
    param(
        [array]  $Plan,
        [System.Collections.Concurrent.ConcurrentQueue[string]] $Queue
    )
    $motorFuncs = @(
        'Set-ManolitoReg','Restore-ManolitoReg','Invoke-ExternalCommand',
        'Invoke-PayloadAppx','Invoke-PayloadServices','Invoke-PayloadTasks',
        'Invoke-PayloadRegistry','Invoke-PayloadNagle','Invoke-PayloadDNS',
        'Invoke-PayloadBCD','Invoke-PayloadMSITuning','Invoke-PayloadDeKMS',
        'Invoke-PayloadHosts','Invoke-PayloadActiveSetup','Invoke-Payload'
    )
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($name in $motorFuncs) {
        $def = Get-Item "Function:$name" -EA SilentlyContinue
        if ($def) {
            $entry = [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, $def.Definition)
            $iss.Commands.Add($entry)
        }
    }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    
    $null = $ps.AddScript({
        param($plan, $ctx, $systemCaps, $config, $queue)
        $script:ctx        = $ctx
        $script:SystemCaps = $systemCaps
        $script:Config     = $config
        $total = $plan.Count; $i = 0
        try {
            foreach ($pName in $plan) {
                $res = Invoke-Payload $pName
                $script:ctx.Tracking.PayloadsExecuted += $pName
                foreach ($log in $res.Logs) { $queue.Enqueue("LOG:$log") }
                $i++
                $queue.Enqueue("PROG:$([int]($i / $total * 100))")
            }
            $statePayload = @{
                State    = @{
                    StepsOk       = $script:ctx.State.StepsOk
                    StepsFail     = $script:ctx.State.StepsFail
                    PendingReboot = $script:ctx.State.PendingReboot
                }
                Tracking = @{
                    RegDiff             = $script:ctx.Tracking.RegDiff
                    PayloadsExecuted    = $script:ctx.Tracking.PayloadsExecuted
                    IrreversibleActions = $script:ctx.Tracking.IrreversibleActions
                }
                Backups  = @{
                    ServicesStartup = $script:ctx.Backups.ServicesStartup
                    TasksState      = $script:ctx.Backups.TasksState
                    DNS             = $script:ctx.Backups.DNS
                    Hosts           = $script:ctx.Backups.Hosts
                    BCD             = $script:ctx.Backups.BCD
                    ActiveSetup     = $script:ctx.Backups.ActiveSetup
                }
                Results  = @{ Modules = $script:ctx.Results.Modules }
            } | ConvertTo-Json -Depth 15 -Compress
            $queue.Enqueue("STATE:$statePayload")
            $queue.Enqueue('DONE:OK')
        } catch {
            $queue.Enqueue("LOG:    [FATAL] Error inesperado en motor: $($_.Exception.Message)")
            $queue.Enqueue('DONE:FAIL')
        }
    })
    $null = $ps.AddParameter('plan',       $Plan            )
    $null = $ps.AddParameter('ctx',        $script:ctx      )
    $null = $ps.AddParameter('systemCaps', $script:SystemCaps)
    $null = $ps.AddParameter('config',     $script:Config   )
    $null = $ps.AddParameter('queue',      $Queue           )
    
    return @{ PS=$ps; RS=$rs; Result=$ps.BeginInvoke() }
}

# ─── MIN4: Restore como Runlevel oficial ────────────────────────────────────
function Import-ManifestToContext {
    param(
        [string] $ManifestPath,
        [System.Windows.Controls.StackPanel]   $SpDynamic,
        [System.Windows.Controls.TextBlock]    $TxtDesc,
        [System.Windows.Controls.TextBox]      $Console
    )
    try {
        $m = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $Console.Text += "`n    [FAIL] No se pudo leer el manifest: $($_.Exception.Message)"
        return $null
    }
    
    $script:ctx.Backups.ServicesStartup = ConvertTo-NativeHashtable $m.BackupServicesState
    $script:ctx.Backups.TasksState      = ConvertTo-NativeHashtable $m.BackupTasksState
    $script:ctx.Backups.DNS             = ConvertTo-NativeHashtable $m.BackupDNS
    $script:ctx.Backups.BCD             = ConvertTo-NativeHashtable $m.BackupBCD
    $script:ctx.Backups.ActiveSetup     = ConvertTo-NativeHashtable $m.BackupActiveSetup
    $script:ctx.Backups.Hosts           = $m.BackupHosts
    $script:ctx.Tracking.RegDiff        = if ($m.RegDiff) { @($m.RegDiff) } else { @() }
    
    $script:ctx.Runtime.IsRollback        = $true
    $script:ctx.Runtime.IsManifestRestore = $true
    
    $plan = @()
    if ($m.Summary.PayloadsExecuted) {
        foreach ($pName in $m.Summary.PayloadsExecuted) {
            $prop = $script:Config.Payloads.PSObject.Properties[$pName]
            $meta = if ($prop -and $prop.Value -and $prop.Value._meta) { $prop.Value._meta } else { $null }
            if ($meta -and $meta.Reversible) { $plan += $pName }
        }
    }
    if ($plan.Count -eq 0) {
        $Console.Text += "`n    [WARN] El manifest no contiene payloads reversibles o no hay historial (PayloadsExecuted vacio)"
    }
    
    $SpDynamic.Children.Clear()
    $TxtDesc.Text       = "[MANIFEST RESTORE] $($m.Timestamp)  —  Runlevel origen: $($m.Runlevel)"
    $TxtDesc.Foreground = '#BF00FF'
    foreach ($pName in $plan) {
        $meta  = $script:Config.Payloads.$pName._meta
        $icono = if ($meta.Risk -eq 'IRR') { '[!]' } elseif ($meta.Risk -eq 'MOD') { '[~]' } else { '[*]' }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content    = "$icono $($meta.Label)"
        $cb.Tag        = $pName
        $cb.IsChecked  = $true
        $cb.Foreground = '#BF00FF'
        $SpDynamic.Children.Add($cb) | Out-Null
    }
    $Console.Text += "`n    [OK]  Manifest cargado — $($plan.Count) payloads restaurables desde $ManifestPath"
    return $plan
}

# ─── FEATURE-2: Pre-auditoría visual ────────────────────────────────────────
function Write-PreAudit {
    param([array]$Plan, [System.Windows.Controls.TextBox]$Console)
    $Console.Text += "`n`n> [PRE-AUDIT] Plan de ejecución ($($Plan.Count) payloads):"
    foreach ($pName in $Plan) {
        $meta = $script:Config.Payloads.PSObject.Properties[$pName].Value._meta
        if (-not $meta) { continue }
        $tag  = switch ($meta.Risk) {
            'IRR' { '[!]' }
            'MOD' { '[~]' }
            default { '[*]' }
        }
        $rev  = if ($meta.Reversible) { 'Reversible' } else { 'IRREVERSIBLE — confirmar' }
        $Console.Text += "`n    $tag $($pName.PadRight(22)) -> $rev"
    }
    $Console.Text += "`n> Iniciando en 1.5s...`n"
}

# ─── MIN2: Validador de Schema JSON ─────────────────────────────────────────
function Test-ManolitoSchema {
    param([PSObject]$Config)
    $errors = @()
    $validRisks = @('SAFE','MOD','IRR')
    $validTypes = @('DWord','QWord','String','ExpandString','Binary','MultiString')
    
    foreach ($rlName in @('Lite','DevEdu','Deep','Rollback')) {
        $rl = $Config.UIMapping.Runlevels.$rlName
        if (-not $rl)            { $errors += "Runlevel '$rlName' ausente en UIMapping"; continue }
        if (-not $rl.Label)      { $errors += "Runlevel '$rlName': falta Label"  }
        if (-not $rl.Color)      { $errors += "Runlevel '$rlName': falta Color"  }
        if (-not $rl.Payloads)   { $errors += "Runlevel '$rlName': Payloads vacío"; continue }
        foreach ($pName in $rl.Payloads) {
            if (-not $Config.Payloads.PSObject.Properties[$pName]) {
                $errors += "Runlevel '$rlName': payload '$pName' no existe en Payloads"
            }
        }
    }
    
    foreach ($prop in $Config.Payloads.PSObject.Properties) {
        $pName = $prop.Name; $p = $prop.Value
        if (-not $p._meta)                                { $errors += "Payload '$pName': falta _meta"; continue }
        if ([string]::IsNullOrWhiteSpace($p._meta.Label)) { $errors += "Payload '$pName': _meta.Label vacío" }
        if ($p._meta.Risk -notin $validRisks)             { $errors += "Payload '$pName': Risk='$($p._meta.Risk)' inválido" }
        if ($null -eq $p._meta.Reversible)                { $errors += "Payload '$pName': falta _meta.Reversible" }
        if ($null -eq $p._meta.RequiresReboot)            { $errors += "Payload '$pName': falta _meta.RequiresReboot" }
        
        if ($pName -eq 'DeKMS') {
            if ($p.Services) { foreach ($s in $p.Services) { if (-not ($s -is [string]) -or [string]::IsNullOrWhiteSpace($s)) { $errors += "Payload '$pName': Services — cada item debe ser string no vacío" } } }
            if ($p.Tasks) { foreach ($t in $p.Tasks) { if (-not ($t -is [string]) -or [string]::IsNullOrWhiteSpace($t)) { $errors += "Payload '$pName': Tasks — cada item debe ser string no vacío" } } }
            if ($p.Files) { foreach ($f in $p.Files) { if (-not ($f -is [string]) -or [string]::IsNullOrWhiteSpace($f)) { $errors += "Payload '$pName': Files — cada item debe ser string no vacío" } } }
            if ($p.Blacklist) { foreach ($b in $p.Blacklist) { if (-not ($b -is [string]) -or [string]::IsNullOrWhiteSpace($b)) { $errors += "Payload '$pName': Blacklist — cada item debe ser string no vacío" } } }
            continue
        }

        if ($p.Services) {
            foreach ($s in $p.Services) {
                if (-not $s.Name -or -not $s.TargetState -or -not $s.RestoreState) {
                    $errors += "Payload '$pName': Services — item incompleto (Name/TargetState/RestoreState)"
                }
            }
        }
        if ($p.Tasks) {
            foreach ($t in $p.Tasks) {
                if ($null -eq $t.Path -or -not $t.Name -or -not $t.TargetState -or -not $t.RestoreState) {
                    $errors += "Payload '$pName': Tasks — item incompleto (Path/Name/TargetState/RestoreState)"
                }
            }
        }
        if ($p.Registry) {
            foreach ($reg in $p.Registry) {
                if (-not $reg.Path -or -not $reg.Name -or -not $reg.Type) {
                    $errors += "Payload '$pName': Registry — item incompleto (Path/Name/Type)"
                }
                if ($reg.Type -and $reg.Type -notin $validTypes) {
                    $errors += "Payload '$pName': Registry Type='$($reg.Type)' inválido"
                }
            }
        }
        if ($p.DNS) {
            if (-not $p.DNS.Primary.TargetValue -or -not $p.DNS.Secondary.TargetValue) {
                $errors += "Payload '$pName': DNS incompleto (Primary/Secondary.TargetValue)"
            }
        }
        if ($p.BCD) {
            foreach ($b in $p.BCD) {
                if (-not $b.Setting -or $null -eq $b.TargetValue -or $null -eq $b.RestoreValue) {
                    $errors += "Payload '$pName': BCD — item incompleto (Setting/TargetValue/RestoreValue)"
                }
            }
        }
    }
    return $errors
}

$schemaErrors = Test-ManolitoSchema -Config $script:Config
if ($schemaErrors.Count -gt 0) {
    $msg = "manolito.json contiene errores de schema:`n`n" + ($schemaErrors -join "`n")
    [System.Windows.MessageBox]::Show($msg, 'Schema Error', 0, 16)
    exit 1
}

# ─── FEATURE-3: Export HTML Report ──────────────────────────────────────────
function Export-HtmlReport {
    param(
        [string]$OutputDir,
        [string]$Runlevel,
        [int]   $StepsOk,
        [int]   $StepsFail,
        [array] $Modules
    )
    $ts      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $outFile = Join-Path $OutputDir "report_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
    $rows = foreach ($m in $Modules) {
        $statusHtml = if (-not $m.Success) {
            '<span class="b-fail">FAIL</span>'
        } else {
            '<span class="b-ok">OK</span>'
        }
        $logText = (($m.Logs | ForEach-Object {
            [System.Security.SecurityElement]::Escape([string]$_)
        }) -join "`n")
        "<tr><td class='pname'>$($m.Name)</td><td>$statusHtml</td>" +
        "<td class='num'>$($m.Changes)</td><td class='logs'>$logText</td></tr>"
    }
    $rowsHtml = $rows -join "`n"
    $okColor  = if ($StepsFail -gt 0) { '#FFB000' } else { '#00FF88' }
$html = @"
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><title>Manolito Report $ts</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#08001A;color:#00FFFF;font-family:Consolas,monospace;padding:40px;line-height:1.6}h1{color:#FF2079;text-shadow:0 0 16px #FF2079;letter-spacing:4px;font-size:22px;margin-bottom:4px}.sub{color:#BF00FF;font-size:12px;letter-spacing:2px;margin-bottom:20px}.meta{background:#0A0015;border:1px solid #2D0050;padding:12px 18px;margin-bottom:24px;font-size:12px;color:#FFB000}.meta span{color:#00FFFF;margin-right:28px}.meta .ok-n{color:#00FF88;font-weight:bold}.meta .fail-n{color:#FF2222;font-weight:bold}table{width:100%;border-collapse:collapse}thead tr{background:#1A0033}th{padding:10px 14px;text-align:left;border:1px solid #2D0050;color:#FF2079;letter-spacing:1px;font-size:12px}td{padding:8px 14px;border:1px solid #2D0050;vertical-align:top;font-size:12px}tr:nth-child(even) td{background:#0A0015}tr:hover td{background:#12002A}.pname{color:#00FFFF;font-weight:bold;white-space:nowrap}.num{text-align:center;color:#FFB000}.logs{color:#44445A;white-space:pre-wrap;max-width:400px;font-size:11px}.b-ok{background:#00FF88;color:#000;padding:2px 10px;border-radius:3px;font-weight:bold;font-size:11px}.b-fail{background:#FF2222;color:#fff;padding:2px 10px;border-radius:3px;font-weight:bold;font-size:11px}footer{margin-top:28px;padding-top:12px;border-top:1px solid #2D0050;color:#2D0050;font-size:11px}</style></head><body><h1>&#9889; MANOLITO ENGINE v2.7.0</h1><div class="sub">... Xciter ... P R E S E N T A ...</div><div class="meta">  <span>Runlevel: <strong>$Runlevel</strong></span>  <span>Timestamp: <strong>$ts</strong></span>  <span>OK: <strong class="ok-n">$StepsOk</strong></span>  <span>FAIL: <strong class="fail-n">$StepsFail</strong></span></div><table><thead>  <tr><th>PAYLOAD</th><th>STATUS</th><th>CAMBIOS</th><th>LOG</th></tr></thead><tbody>$rowsHtml</tbody></table><footer>Manolito Engine v2.7.0 &mdash; $ts &mdash; $outFile</footer></body></html>
"@
    $html | Out-File -FilePath $outFile -Encoding UTF8 -Force
    return $outFile
}

# ========================================================================
# 4. INTERFAZ GRÁFICA (XAML CYBERPUNK) - DISEÑO GRID RESPONSIVO
# ========================================================================
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Manolito v2.7.1" Height="800" Width="1000" WindowStyle="None" AllowsTransparency="True" WindowStartupLocation="CenterScreen" FontFamily="Consolas">
    <Window.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#08001A" Offset="0"/>
            <GradientStop Color="#1A0033" Offset="1"/>
        </LinearGradientBrush>
    </Window.Background>
    <Window.Resources>
        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#00FFFF"/><Setter Property="Effect"><Setter.Value><DropShadowEffect Color="#00FFFF" BlurRadius="8" ShadowDepth="0" Opacity="0.6"/></Setter.Value></Setter></Style>
        <Style TargetType="CheckBox"><Setter Property="Margin" Value="0,6"/><Setter Property="Cursor" Value="Hand"/></Style>
        <Style TargetType="RadioButton"><Setter Property="Foreground" Value="#00FFFF"/><Setter Property="Margin" Value="0,10"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="FontSize" Value="14"/></Style>
        <Style TargetType="Button"><Setter Property="Cursor" Value="Hand"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="Padding" Value="15,5"/><Setter Property="Margin" Value="5,0"/><Setter Property="Background" Value="Transparent"/></Style>
        <Style TargetType="Border"><Setter Property="BorderBrush" Value="#2D0050"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Background" Value="#0A0015"/><Setter Property="Padding" Value="15"/><Setter Property="Margin" Value="5"/></Style>
    </Window.Resources>
    
    <Border BorderBrush="#00FFFF" Background="Transparent">
        <Border.Effect><DropShadowEffect Color="#BF00FF" BlurRadius="25" ShadowDepth="0" Opacity="0.6"/></Border.Effect>
        <Grid Margin="15">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Name="txtLogo" HorizontalAlignment="Center" FontWeight="Bold" FontSize="11" Margin="0,0,0,6" xml:space="preserve"><TextBlock.Effect><DropShadowEffect Color="#FF2079" BlurRadius="14" ShadowDepth="0" Opacity="1"/></TextBlock.Effect></TextBlock>
            <TextBlock Grid.Row="1" HorizontalAlignment="Center" Margin="0,0,0,10" xml:space="preserve">──────────────────────────────────────────────────────────────────────
         . . . Xciter . . . P R E S E N T A . . .  [ MANOLITO v2.7.0 ]</TextBlock>
            
            <Grid Grid.Row="2" Margin="0,0,0,10">
                <Grid.ColumnDefinitions><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="1.1*"/><ColumnDefinition Width="1.8*"/></Grid.ColumnDefinitions>
                <Border Grid.Column="0"><StackPanel>
                    <TextBlock Text="[ AUDITORIA WMI ]" FontWeight="Bold" Margin="0,0,0,15"/>
                    <TextBlock Margin="0,4"><Run Text="SO         : " Foreground="#555555"/><Run Text="$($script:Config.Manifest.TargetOS)" Foreground="#FF2079"/></TextBlock>
                    <TextBlock Margin="0,4"><Run Text="Motor DB   : " Foreground="#555555"/><Run Text="v$($script:Config.Manifest.Version)" Foreground="#FFB000"/></TextBlock>
                    <TextBlock Margin="0,4"><Run Text="Backend    : " Foreground="#555555"/><Run Text="Modular Integrado" Foreground="#00FFFF"/></TextBlock>
                    <TextBlock Margin="0,4"><Run Text="NVIDIA     : " Foreground="#555555"/><Run Name="runNvidia" Text="..." Foreground="#FF2079"/></TextBlock>
                    <TextBlock Margin="0,4"><Run Text="NVMe       : " Foreground="#555555"/><Run Name="runNVMe" Text="..." Foreground="#FF2079"/></TextBlock>
                    <TextBlock Margin="0,4"><Run Text="Batería    : " Foreground="#555555"/><Run Name="runBattery" Text="..." Foreground="#FF2079"/></TextBlock>
                    <TextBlock Margin="0,4"><Run Text="Winget     : " Foreground="#555555"/><Run Name="runWinget" Text="..." Foreground="#FFB000"/></TextBlock>
                </StackPanel></Border>
                <Border Grid.Column="1"><StackPanel>
                    <TextBlock Text="[ RUNLEVEL ]" FontWeight="Bold" Margin="0,0,0,15"/>
                    <RadioButton Name="rbLite" GroupName="P" Content="$($script:Config.UIMapping.Runlevels.Lite.Label)"/>
                    <RadioButton Name="rbDevEdu" GroupName="P" Content="$($script:Config.UIMapping.Runlevels.DevEdu.Label)" IsChecked="True"/>
                    <RadioButton Name="rbDeep" GroupName="P" Content="$($script:Config.UIMapping.Runlevels.Deep.Label)" Foreground="#FF2222"/>
                    <RadioButton Name="rbRollback" GroupName="P" Content="$($script:Config.UIMapping.Runlevels.Rollback.Label)" Foreground="#BF00FF"/>
                </StackPanel></Border>
                <Border Grid.Column="2"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Name="txtDesc" Text="[ SELECCIONE UN PERFIL ]" FontWeight="Bold" Foreground="#00FFFF" Margin="0,0,0,15"/>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,5,0,0">
                        <StackPanel Name="spDynamicPayloads"></StackPanel>
                    </ScrollViewer>
                </Grid></Border>
            </Grid>
            
            <Border Grid.Row="3" Background="#04000E" Height="260" Margin="5,0,5,5" BorderBrush="#2D0050">
                <ScrollViewer Name="svConsole" VerticalScrollBarVisibility="Auto" Margin="5">
                    <TextBox Name="txtConsole" IsReadOnly="True" Background="Transparent" BorderThickness="0" Foreground="#39FF14" TextWrapping="Wrap" xml:space="preserve" FontSize="12">Manolito Engine v2.7.0 Inicializado. Leyendo Base de Datos...
[INFO] $($script:Config.Manifest.Description)</TextBox>
                </ScrollViewer>
            </Border>
            
            <Grid Grid.Row="4" Margin="5,5,5,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                    <TextBlock Name="txtStatus" Text="ESPERANDO ORDENES..." Foreground="#FFB000"/>
                    <ProgressBar Name="pbProgress" Height="3" Background="#111" Foreground="#FF2079" BorderThickness="0" Margin="0,5,20,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
					<CheckBox Name="chkDryRun" Content="DRY RUN" IsChecked="True" Foreground="#00FFFF" FontWeight="Bold" Margin="0,0,20,0" VerticalAlignment="Center" />
                    <Button Name="btnSaveProfile" Content="GUARDAR"  Foreground="#00FFFF"
                            BorderBrush="#00FFFF" ToolTip="Guardar checkboxes actuales como perfil"/>
                    <Button Name="btnLoadProfile" Content="CARGAR"   Foreground="#FFB000"
                            BorderBrush="#FFB000" ToolTip="Cargar perfil guardado"/>
                    <Button Name="btnManifest"    Content="MANIFEST" Foreground="#BF00FF"
                            BorderBrush="#BF00FF" ToolTip="Restaurar sistema desde manifest externo"/>
                    <Button Name="btnCopy"   Content="COPIAR LOG" Foreground="#00FFFF"
                            BorderBrush="#00FFFF" ToolTip="Copia la consola al portapapeles"/>
                    <Button Name="btnExit"   Content="SALIR"      Foreground="#39FF14" BorderBrush="#39FF14"/>
                    <Button Name="btnDeploy" Content="INICIAR"    Background="#FF2079"
                            Foreground="#08001A" BorderThickness="0"/>
                </StackPanel>
            </Grid>
        </Grid>
    </Border>
</Window>
"@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)
$window.FindName("txtLogo").Text = " ███╗   ███╗ █████╗ ███╗  ██╗ ██████╗ ██╗     ██╗████████╗ ██████╗ `n ████╗ ████║██╔══██╗████╗ ██║██╔═══██╗██║     ██║╚══██╔══╝██╔═══██╗`n ██╔████╔██║███████║██╔██╗██║██║   ██║██║     ██║   ██║   ██║   ██║`n ██║╚██╔╝██║██╔══██║██║╚████║██║   ██║██║     ██║   ██║   ██║   ██║`n ██║ ╚═╝ ██║██║  ██║██║ ╚███║╚██████╔╝███████╗██║   ██║   ╚██████╔╝`n ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚══╝ ╚═════╝ ╚══════╝╚═╝   ╚═╝    ╚═════╝ "

$btnDeploy = $window.FindName("btnDeploy"); $btnExit = $window.FindName("btnExit"); $btnCopy = $window.FindName("btnCopy")
$txtStatus = $window.FindName("txtStatus"); $pbProgress = $window.FindName("pbProgress")
$chkDryRun = $window.FindName("chkDryRun"); $txtConsole = $window.FindName("txtConsole")
$svConsole = $window.FindName("svConsole"); $txtDesc = $window.FindName("txtDesc")
$spDynamic = $window.FindName("spDynamicPayloads")

$btnSaveProfile = $window.FindName('btnSaveProfile')
$btnLoadProfile = $window.FindName('btnLoadProfile')
$btnManifest    = $window.FindName('btnManifest')

$window.FindName('runNvidia').Text  = if ($script:SystemCaps.HasNvidia)    { 'DETECTADA' }  else { 'NO' }
$window.FindName('runNVMe').Text    = if ($script:SystemCaps.HasNVMe)      { 'DETECTADO' }  else { 'NO' }
$window.FindName('runBattery').Text = if ($script:SystemCaps.HasBattery)   { 'SÍ (portátil)' } else { 'NO' }
$window.FindName('runWinget').Text  = if ($script:SystemCaps.CanUseWinget) { 'DISPONIBLE' } else { 'NO ENCONTRADO' }

$updateUI = { param($runlevelKey)
    $rl = $script:Config.UIMapping.Runlevels.$runlevelKey
    $txtDesc.Text = "[ PARAMETROS: $($rl.Label) ]"; $txtDesc.Foreground = $rl.Color
    
    $spDynamic.Children.Clear()
    foreach($p in $rl.Payloads) {
        $meta = $script:Config.Payloads.$p._meta
        $icono = if($meta.Risk -eq 'IRR') { "[!]" } elseif ($meta.Risk -eq 'MOD') { "[~]" } else { "[*]" }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "$icono $($meta.Label)"; $cb.Tag = $p
        
        if ($script:MemoriaPayloads.ContainsKey($p) -and $script:MemoriaPayloads[$p] -eq $false) {
            $cb.IsChecked = $false; $cb.Foreground = "#555555"
        } else {
            $cb.IsChecked = $true;  $cb.Foreground = "#FF2079"
        }
        
        $cb.Add_Checked({ $script:MemoriaPayloads.Remove($this.Tag); $this.Foreground = "#FF2079"; Beep-UI "check" })
        $cb.Add_Unchecked({ $script:MemoriaPayloads[$this.Tag] = $false; $this.Foreground = "#555555"; Beep-UI "check" })
        $spDynamic.Children.Add($cb) | Out-Null
    }
    Beep-UI "check"
}

$window.FindName("rbLite").Add_Checked({ & $updateUI "Lite" })
$window.FindName("rbDevEdu").Add_Checked({ & $updateUI "DevEdu" })
$window.FindName("rbDeep").Add_Checked({ & $updateUI "Deep" })
$window.FindName("rbRollback").Add_Checked({ & $updateUI "Rollback" })

$window.Add_MouseLeftButtonDown({ $window.DragMove() })

$window.Add_Loaded({ 
    Beep-UI "boot"
    $window.FindName("rbDevEdu").Focus() | Out-Null
    & $updateUI "DevEdu"
})

$btnCopy.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($txtConsole.Text)) {
        try { [System.Windows.Clipboard]::SetText($txtConsole.Text) } catch {}
        $btnCopy.Content = "[ ¡COPIADO! ]"; Beep-UI "check"
        $tCopy = New-Object System.Windows.Threading.DispatcherTimer; $tCopy.Interval = [TimeSpan]::FromSeconds(2)
        $tCopy.Add_Tick({ $this.Stop(); $btnCopy.Content = "COPIAR LOG" })
        $tCopy.Start()
    }
})

$btnSaveProfile.Add_Click({
    $profilesDir = Join-Path $DOCS_MANOLITO 'profiles'
    if (-not (Test-Path $profilesDir)) { New-Item $profilesDir -ItemType Directory -Force | Out-Null }
    $rlKey = if     ($window.FindName('rbLite').IsChecked)   { 'Lite'     }
             elseif ($window.FindName('rbDevEdu').IsChecked) { 'DevEdu'   }
             elseif ($window.FindName('rbDeep').IsChecked)   { 'Deep'     }
             else                                            { 'Rollback' }
    $checked = @($spDynamic.Children | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    $profile  = [ordered]@{
        Runlevel = $rlKey
        SavedAt  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Payloads = $checked
    }
    $filePath = Join-Path $profilesDir "profile_${rlKey}_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    $profile | ConvertTo-Json -Depth 5 | Out-File $filePath -Encoding UTF8 -Force
    $txtConsole.Text += "`n    [OK]  Perfil guardado -> $filePath"
    $svConsole.ScrollToEnd()
    Beep-UI 'check'
    $btnSaveProfile.Content = 'GUARDADO!'
    $tSave = New-Object System.Windows.Threading.DispatcherTimer
    $tSave.Interval = [TimeSpan]::FromSeconds(2)
    $tSave.Add_Tick({ $args[0].Stop(); $btnSaveProfile.Content = 'GUARDAR' })
    $tSave.Start()
})

$btnLoadProfile.Add_Click({
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.Title            = 'Cargar Perfil Manolito'
    $ofd.Filter           = 'Perfil Manolito (*.json)|*.json'
    $ofd.InitialDirectory = Join-Path $DOCS_MANOLITO 'profiles'
    if (-not $ofd.ShowDialog()) { return }
    try {
        $profileData = Get-Content $ofd.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $profileData.Payloads) { throw 'Formato inválido: falta array Payloads' }
        $rlKey = $profileData.Runlevel
        $script:MemoriaPayloads = @{}
        $allPayloads = $script:Config.UIMapping.Runlevels.$rlKey.Payloads
        foreach ($p in $allPayloads) {
            if ($profileData.Payloads -notcontains $p) {
                $script:MemoriaPayloads[$p] = $false
            }
        }
        $rbMap = @{ Lite='rbLite'; DevEdu='rbDevEdu'; Deep='rbDeep'; Rollback='rbRollback' }
        if ($rbMap[$rlKey]) { $window.FindName($rbMap[$rlKey]).IsChecked = $true }
        $txtConsole.Text += "`n    [OK]  Perfil cargado — $rlKey / $($profileData.Payloads.Count) payloads — $($ofd.FileName)"
        $svConsole.ScrollToEnd()
        Beep-UI 'check'
    } catch {
        $txtConsole.Text += "`n    [FAIL] Perfil: $($_.Exception.Message)"
    }
})

$btnManifest.Add_Click({
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.Title            = 'Seleccionar Manifest Manolito'
    $ofd.Filter           = 'Manifest JSON (*.json)|*.json'
    $ofd.InitialDirectory = $DOCS_MANOLITO
    if (-not $ofd.ShowDialog()) { return }
    Beep-UI 'action'
    
    $window.FindName('rbRollback').IsChecked = $true
    
    $plan = Import-ManifestToContext -ManifestPath $ofd.FileName -SpDynamic $spDynamic -TxtDesc $txtDesc -Console $txtConsole
    if ($plan) {
        $txtConsole.Text += "`n    [INFO] Revisa el plan y pulsa INICIAR para restaurar"
        $svConsole.ScrollToEnd()
        Beep-UI 'check'
    } else {
        $script:ctx.Runtime.IsManifestRestore = $false
        $script:ctx.Runtime.IsRollback        = $false
    }
})

$btnExit.Add_Click({
    Beep-UI "close"; $btnExit.Content="[ APAGANDO ]"; $btnExit.IsEnabled=$false
    $t=New-Object System.Windows.Threading.DispatcherTimer; $t.Interval=[TimeSpan]::FromMilliseconds(400)
    $t.Add_Tick({$args[0].Stop(); $window.Close()}); $t.Start()
})

# ========================================================================
# 5. EL ORQUESTADOR PRINCIPAL
# ========================================================================
$btnDeploy.Add_Click({
    $script:ctx.Runtime.IsDryRun = [bool]$chkDryRun.IsChecked

    if ($script:SystemCaps.IsSafeMode) {
        $txtConsole.Text += "`n    [ABORT] Manolito no puede ejecutarse en modo seguro"
        $btnDeploy.IsEnabled = $true; $btnDeploy.Background = '#FF2079'
        return
    }
    if ($script:SystemCaps.PendingReboot -and -not $script:ctx.Runtime.IsDryRun) {
        $txtConsole.Text += "`n    [WARN] Reinicio pendiente detectado — se recomienda reiniciar antes de ejecutar"
    }

    Beep-UI "action"
    $btnDeploy.IsEnabled=$false; $btnDeploy.Background="#444"; $pbProgress.Value=0
    
    $script:ctx.State.StepsOk = 0
    $script:ctx.State.StepsFail = 0
    $script:ctx.Tracking.RegDiff             = @()
    $script:ctx.Tracking.PayloadsExecuted    = @()
    $script:ctx.Tracking.IrreversibleActions = @()
    $script:ctx.Backups.ServicesStartup      = @{}
    $script:ctx.Backups.TasksState           = @{}
    $script:ctx.Backups.DNS                  = @{}
    $script:ctx.Backups.BCD                  = @{}
    $script:ctx.Backups.ActiveSetup          = @{}
    $script:ctx.Backups.Hosts                = $null
    $script:ctx.Results.Modules              = @()
    
    $rlKey = if($window.FindName("rbLite").IsChecked){"Lite"} elseif($window.FindName("rbDevEdu").IsChecked){"DevEdu"} elseif($window.FindName("rbDeep").IsChecked){"Deep"} else {"Rollback"}
    
    if (-not $script:ctx.Runtime.IsManifestRestore) {
        $script:ctx.Runtime.IsRollback = ($rlKey -eq "Rollback")
    }
    $script:ctx.Runtime.Runlevel = $rlKey
    
    $script:plan = @()
    foreach($cb in $spDynamic.Children) { if($cb.IsChecked) { $script:plan += $cb.Tag } }
    
    if($script:SystemCaps.IsDomain) { $script:plan = @($script:plan | Where-Object { $_ -ne "DisableVBS" }) }
    if(-not $script:SystemCaps.HasPhysicalNIC) { $script:plan = @($script:plan | Where-Object { $_ -ne "NetworkOptimize" }) }
    if($script:SystemCaps.IsVM) { $script:plan = @($script:plan | Where-Object { $_ -notin @("MSITuning","DisableVBS") }) }
    
    $script:capsWarnings = @()
    if (-not $script:SystemCaps.HasNvidia -and -not $script:SystemCaps.HasNVMe) {
        if ($script:plan -contains 'MSITuning') {
            $script:capsWarnings += "    [SKIP] MSITuning — Sin GPU NVIDIA ni NVMe detectados"
        }
        $script:plan = @($script:plan | Where-Object { $_ -ne 'MSITuning' })
    } elseif (-not $script:SystemCaps.HasNvidia -and $script:SystemCaps.HasNVMe) {
        if ($script:plan -contains 'MSITuning') {
            $script:capsWarnings += "    [INFO] MSITuning — Sin NVIDIA, solo NVMe será procesado"
        }
    }
    
    if ($script:SystemCaps.HasBattery) {
        if ($script:plan -contains 'InputTuning') {
            $script:capsWarnings += "    [WARN] InputTuning — Portátil detectado (batería presente)"
        }
    }

    $btnDeploy.Content = if($script:ctx.Runtime.IsDryRun){"[ SIMULANDO ]"}else{"[ INYECTANDO ]"}
    $txtStatus.Text = if($script:ctx.Runtime.IsDryRun){"MODO SIMULACION ACTIVADO..."}else{"ALTERANDO SISTEMA..."}
    $txtConsole.Text += "`n`n> [$(Get-Date -f 'HH:mm:ss')] $(if($script:ctx.Runtime.IsDryRun){'--- INICIANDO SIMULACION DRY-RUN ---'}else{'!!! DESPLIEGUE BARE-METAL INICIADO !!!'})"
    
    Write-PreAudit -Plan $script:plan -Console $txtConsole
    $svConsole.ScrollToEnd()

    if(-not $script:ctx.Runtime.IsDryRun) {
        $backupDir = Join-Path $DOCS_MANOLITO "backup_$(Get-Date -f 'yyyyMMdd_HHmmss')"
        New-Item $backupDir -ItemType Directory -Force | Out-Null
        & reg export "HKLM\SOFTWARE\Policies" "$backupDir\Policies.reg" /y 2>$null
    }

    if ($script:capsWarnings.Count -gt 0) {
        foreach ($w in $script:capsWarnings) { $txtConsole.Text += "`n$w" }
    }

    $script:logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $script:rsHandle = Start-ManolitoRunspace -Plan $script:plan -Queue $script:logQueue

    $tDrain = New-Object System.Windows.Threading.DispatcherTimer
    $tDrain.Interval = [TimeSpan]::FromMilliseconds(50)
    $tDrain.Add_Tick({
        $msg      = $null
        $maxTick  = 20
        $count    = 0
        $isDone   = $false
        while ($count -lt $maxTick -and $script:logQueue.TryDequeue([ref]$msg)) {
            if     ($msg.StartsWith('LOG:'))   { $txtConsole.Text += "`n$($msg.Substring(4))" }
            elseif ($msg.StartsWith('PROG:'))  { $pbProgress.Value = [int]$msg.Substring(5)  }
            elseif ($msg.StartsWith('STATE:')) { $script:rsStateJson = $msg.Substring(6)      }
            elseif ($msg.StartsWith('DONE:'))  { $isDone = $true; break }
            $count++
        }
        $svConsole.ScrollToEnd()
        
        if ($isDone) {
            $args[0].Stop()
            
            while ($script:logQueue.TryDequeue([ref]$msg)) {
                if     ($msg.StartsWith('LOG:'))   { $txtConsole.Text += "`n$($msg.Substring(4))" }
                elseif ($msg.StartsWith('STATE:')) { $script:rsStateJson = $msg.Substring(6)      }
            }
            $svConsole.ScrollToEnd()
            
            try { $script:rsHandle.PS.EndInvoke($script:rsHandle.Result) } catch {}
            $script:rsHandle.RS.Close()
            $script:rsHandle.PS.Dispose()
            $script:rsHandle = $null

            if ($script:rsStateJson) {
                try {
                    $rs = $script:rsStateJson | ConvertFrom-Json
                    $script:ctx.State.StepsOk       = [int]$rs.State.StepsOk
                    $script:ctx.State.StepsFail     = [int]$rs.State.StepsFail
                    $script:ctx.State.PendingReboot = [bool]$rs.State.PendingReboot
                    
                    $script:ctx.Tracking.RegDiff             = if ($rs.Tracking.RegDiff)             { @($rs.Tracking.RegDiff) }             else { @() }
                    $script:ctx.Tracking.PayloadsExecuted    = if ($rs.Tracking.PayloadsExecuted)    { @($rs.Tracking.PayloadsExecuted) }    else { @() }
                    $script:ctx.Tracking.IrreversibleActions = if ($rs.Tracking.IrreversibleActions) { @($rs.Tracking.IrreversibleActions) } else { @() }
                    
                    $script:ctx.Backups.ServicesStartup = ConvertTo-NativeHashtable $rs.Backups.ServicesStartup
                    $script:ctx.Backups.TasksState      = ConvertTo-NativeHashtable $rs.Backups.TasksState
                    $script:ctx.Backups.DNS             = ConvertTo-NativeHashtable $rs.Backups.DNS
                    $script:ctx.Backups.BCD             = ConvertTo-NativeHashtable $rs.Backups.BCD
                    $script:ctx.Backups.ActiveSetup     = ConvertTo-NativeHashtable $rs.Backups.ActiveSetup
                    $script:ctx.Backups.Hosts           = $rs.Backups.Hosts
                    
                    $script:ctx.Results.Modules = if ($rs.Results.Modules) { @($rs.Results.Modules) } else { @() }
                } catch {
                    $txtConsole.Text += "`n    [WARN] Deserialización de estado: $($_.Exception.Message)"
                }
                $script:rsStateJson = $null
            } else {
                $txtConsole.Text += "`n    [WARN] No se recibió STATE del Runspace — manifest puede estar incompleto"
            }

            if (-not $script:ctx.Runtime.IsDryRun) {
                $manifest = [ordered]@{
                    EngineVersion       = '2.7.0'
                    Timestamp           = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                    Runlevel            = $script:ctx.Runtime.Runlevel
                    BackupServicesState = $script:ctx.Backups.ServicesStartup
                    BackupTasksState    = $script:ctx.Backups.TasksState
                    BackupDNS           = $script:ctx.Backups.DNS
                    BackupHosts         = $script:ctx.Backups.Hosts
                    BackupBCD           = $script:ctx.Backups.BCD
                    BackupActiveSetup   = $script:ctx.Backups.ActiveSetup
                    RegDiff             = $script:ctx.Tracking.RegDiff
                    IrreversibleActions = $script:ctx.Tracking.IrreversibleActions
                    Summary             = @{
                        StepsOk          = $script:ctx.State.StepsOk
                        StepsFail        = $script:ctx.State.StepsFail
                        Reboot           = $script:ctx.State.PendingReboot
                        PayloadsExecuted = $script:ctx.Tracking.PayloadsExecuted 
                    }
                }
                $manifest | ConvertTo-Json -Depth 10 | Out-File $MANIFEST_PATH -Encoding UTF8
                $txtConsole.Text += "`n    [MANIFEST] Guardado en $MANIFEST_PATH"
                
                $htmlOut = Export-HtmlReport `
                    -OutputDir  $DOCS_MANOLITO `
                    -Runlevel   $script:ctx.Runtime.Runlevel `
                    -StepsOk    $script:ctx.State.StepsOk `
                    -StepsFail  $script:ctx.State.StepsFail `
                    -Modules    $script:ctx.Results.Modules
                $txtConsole.Text += "`n    [HTML] Report -> $htmlOut"
            }

            if ($script:ctx.State.PendingReboot -and -not $script:ctx.Runtime.IsDryRun) {
                $txtStatus.Text       = 'DESPLIEGUE EXITOSO. SE REQUIERE REINICIO'
                $txtStatus.Foreground = '#FFB000'
            } else {
                $txtStatus.Text = if ($script:ctx.Runtime.IsDryRun) {
                    'SIMULACION COMPLETADA.'
                } else { 'DESPLIEGUE EXITOSO.' }
                $txtStatus.Foreground = '#FF2079'
            }
            $txtConsole.Text += "`n    PROCESO FINALIZADO. Pasos OK=$($script:ctx.State.StepsOk), FAIL=$($script:ctx.State.StepsFail)"
            $svConsole.ScrollToEnd()
            
            $btnDeploy.Content    = 'INICIAR'
            $btnDeploy.Background = '#FF2079'
            $btnDeploy.IsEnabled  = $true
            
            $script:ctx.Runtime.IsManifestRestore = $false
       		$txtConsole.Text += "`n> [INFO] Revisa el informe HTML antes de reiniciar: $htmlOut"
			$txtConsole.Text += "`n> [INFO] Transcript completo en: $(Join-Path $script:DOCSMANOLITO 'transcript*.txt')"
            Beep-UI 'boot'
        }
    })
    $tDrain.Start()
})

$window.Add_Closed({ try { Stop-Transcript } catch {}; try { $_mutex.ReleaseMutex(); $_mutex.Dispose() } catch {} })
$window.ShowDialog() | Out-Null
