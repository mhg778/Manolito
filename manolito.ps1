<#
.SYNOPSIS
    Manolito Engine v$($script:ENGINE_VERSION)
.DESCRIPTION
    Motor de configuracion Windows basado en perfil JSON (WAD).
    Arquitectura modular. UI WPF reactiva. Ejecucion asincrona con runspace.
    Soporta modos DRY RUN y LIVE con rollback por payload.
.NOTES
    Requiere ejecucion como Administrador.
    Archivo de datos: manolito.json (mismo directorio).
#>
#Requires -RunAsAdministrator
Add-Type -AssemblyName PresentationFramework
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$DOCS_MANOLITO    = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Manolito'
$script:MANIFESTDIR  = $DOCS_MANOLITO
$script:MANIFESTPATH = Join-Path $script:MANIFESTDIR 'manifest.json'
$script:ENGINE_VERSION = '2.9.1'  # fallback pre-carga JSON; se sobreescribe con Manifest.Version tras Import-WAD (ver Paso2-ENGVER)
$script:UI_FIRSTRUN    = 'Ejecuta la auditoria previa antes de aplicar cambios.'
$script:UI_READY       = 'Sistema listo. Selecciona un runlevel y confirma.'
$script:UI_LIVECONFIRM = 'Vas a aplicar {0} cambios en este sistema. Continuar?'
$script:UI_ROLLBACK    = 'Revertir {0} cambios aplicados en esta sesion?'
$script:UI_IRREV       = "Existen {0} cambios irreversibles en el plan:`n{1}`n`nAceptas continuar? Esta accion no se puede deshacer."
$script:UI_AUDITDONE   = 'Auditoria completada.'
$script:UI_MANIFEST    = 'Historial cargado: {0} payloads aplicados.'
$script:JSONPATH    = Join-Path $PSScriptRoot 'manolito.json'
$JSON_PATH          = $script:JSONPATH                                    # alias legacy
$script:JSONBAKPATH = Join-Path $PSScriptRoot 'manolito.json.bak'
$script:ctx = [PSCustomObject]@{
    Runtime = [PSCustomObject]@{
        IsDryRun          = $true
        IsRollback        = $false
        IsManifestRestore = $false
        Runlevel          = $null
    }
    Options = [PSCustomObject]@{
        Skip   = @()
        Verify = $false
    }
    State = [PSCustomObject]@{
        PendingReboot = $false
        StepsOk       = 0
        StepsFail     = 0
    }
    Tracking = [PSCustomObject]@{
        RegDiff             = [System.Collections.Generic.List[object]]::new()
        PayloadsExecuted    = [System.Collections.Generic.List[string]]::new()
        AppliedPayloads     = [System.Collections.Generic.List[string]]::new()
        IrreversibleActions = [System.Collections.Generic.List[string]]::new()
        RollbackStack       = [System.Collections.Concurrent.ConcurrentStack[object]]::new()
        Backups             = [PSCustomObject]@{
            ServicesStartup = @{}
            TasksState      = @{}
            DNS             = @{}
            Hosts           = $null
            ActiveSetup     = @{}
            BCD             = @{}
            WindowsFeatures = @{}
        }
    }
    Results = [PSCustomObject]@{
        Modules = [System.Collections.Generic.List[object]]::new()
    }
    Config     = @{}
    WADData    = $null
    SystemCaps = $null
    LogQueue      = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    Cache         = @{ EnumDevices = $null }  # S5B-02  # async runspace->UI
    ProgressQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()  # progreso runspace->UI
}
$script:scriptctx = $script:ctx  # alias legacy para providers
$script:MutexHandle = [System.Threading.Mutex]::new($false, 'Global\ManolitoEngine')
try { $acquired = $script:MutexHandle.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { Write-Error 'Manolito ya esta en ejecucion'; exit 1 }
if (-not (Test-Path $DOCS_MANOLITO)) { New-Item -Path $DOCS_MANOLITO -ItemType Directory -Force | Out-Null }
$script:ManolitoTranscriptPath = $null
try {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $transcriptPath = Join-Path $DOCS_MANOLITO ("transcript_{0}.txt" -f $stamp)
    Start-Transcript -Path $transcriptPath -Append
    $script:ManolitoTranscriptPath = Join-Path $DOCS_MANOLITO ("console_log_{0}.txt" -f $stamp)
} catch { Write-Warning ("Transcript no disponible: {0}" -f $_.Exception.Message) }
function Invoke-SafeCheckpoint {
    param([string]$Description = "Manolito Engine - Pre-Execution Checkpoint")
    try {
        $null = Invoke-CimMethod -ClassName SystemRestore -Namespace root/default `
            -MethodName CreateRestorePoint `
            -Arguments @{ Description = $Description; RestorePointType = 12; EventType = 100 } `
            -ErrorAction Stop
        return @{ Success = $true; Message = "Checkpoint CIM creado: $Description" }
    } catch {
        try {
            if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
                $null = ([wmiclass]"\\localhost\root\default:SystemRestore").CreateRestorePoint($Description, 12, 100)
                return @{ Success = $true; Message = "Checkpoint WMI creado: $Description" }
            }
        } catch {}
        try {
            Enable-ComputerRestore -Drive $env:SystemDrive -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description $Description -RestorePointType 'APPLICATION_INSTALL' -ErrorAction Stop
            return @{ Success = $true; Message = "Checkpoint nativo creado: $Description" }
        } catch {
            return @{ Success = $false; Message = "No se pudo crear checkpoint: $($_.Exception.Message)" }
        }
    }
}
function Write-UIBeep($tipo) {
    try {
        switch ($tipo) {
            'boot'   { [Console]::Beep(800, 30); [Console]::Beep(1200, 50) }
            'action' { [Console]::Beep(1000, 20); [Console]::Beep(1500, 40) }
            'check'  { [Console]::Beep(1200, 15) }
            'close'  { [Console]::Beep(1000, 30); [Console]::Beep(700, 50) }
        }
    }
    catch {}
}
function Resolve-DnsBackup {
    param($Backup)
    if ($null -eq $Backup) { return 'DHCP' }
    $arr = @($Backup | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
    if ($arr.Count -eq 0) { return 'DHCP' }
    if ($arr.Count -eq 1 -and $arr[0] -eq 'DHCP') { return 'DHCP' }
    return $arr
}
function Resolve-Runlevel {
    param([string]$Name, [System.Collections.Generic.HashSet[string]]$Visited = $null)
    if (-not $Visited) { $Visited = [System.Collections.Generic.HashSet[string]]::new() }
    if ($Visited.Contains($Name)) {
        [System.Windows.MessageBox]::Show(
            "Ciclo detectado en runlevel DAG: $Name",
            'Manolito Engine', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        exit 1
    }
    [void]$Visited.Add($Name)
    $rl = $script:ctx.WADData.UIMapping.Runlevels.$Name
    if (-not $rl) { return @() }
    $result = [System.Collections.Generic.List[string]]::new()
    $seen   = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($entry in $rl.Payloads) {
        if ($entry -match '^\$(.+)') {
            $ref     = $Matches[1]
            $subList = Resolve-Runlevel -Name $ref -Visited ([System.Collections.Generic.HashSet[string]]::new($Visited))  # FIX A.3: copia el set por rama para evitar falsos positivos de ciclo en dependencias compartidas (diamante)
            foreach ($p in $subList) {
                if ($seen.Add($p)) { $result.Add($p) }
            }
        } else {
            if ($seen.Add($entry)) { $result.Add($entry) }
        }
    }
    return $result
}
function Test-RunlevelDAG {
    $levels = $script:ctx.WADData.UIMapping.Runlevels |
              Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    foreach ($lv in $levels) {
        Resolve-Runlevel -Name $lv | Out-Null
    }
}
function Test-PayloadGuards {
    param($Payload, [string]$PayloadName)
    $meta = $Payload._meta
    $caps = $script:ctx.SystemCaps
    foreach ($req in @($meta.RequiresSystemCaps)) {
        if (-not $req) { continue }
        if (-not $caps[$req]) {
            return @{ Pass = $false; Reason = "RequiresSystemCaps no cumplido: $req" }
        }
    }
    foreach ($deny in @($meta.DenySystemCaps)) {
        if (-not $deny) { continue }
        if ($caps[$deny]) {
            return @{ Pass = $false; Reason = "DenySystemCaps activo: $deny" }
        }
    }
    if ($meta.MinBuild) {
        $build = [Environment]::OSVersion.Version.Build
        if ($build -lt [int]$meta.MinBuild) {
            return @{ Pass = $false; Reason = "Build $build < MinBuild $($meta.MinBuild)" }
        }
    }
    if ($meta.DenyOnBattery -and $caps.HasBattery) {
        return @{ Pass = $false; Reason = 'DenyOnBattery: bateria detectada' }
    }
    return @{ Pass = $true; Reason = '' }
}
function Test-WADSchema {
    $errors = [System.Collections.Generic.List[string]]::new()
    $payloads = $script:ctx.WADData.Payloads
    foreach ($name in ($payloads | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
        $p    = $payloads.$name
        $meta = $p._meta
        if (-not $meta) { $errors.Add("[$name] falta _meta"); continue }
        if (-not $meta.Label)       { $errors.Add("[$name] _meta.Label ausente") }
        if ($null -eq $meta.Reversible) { $errors.Add("[$name] _meta.Reversible ausente") }
        if ($null -eq $meta.RiskLevel)  { $errors.Add("[$name] _meta.RiskLevel ausente") }
        if ($meta.RiskLevel -notin $script:ValidRiskLevels) { $errors.Add("[$name] RiskLevel invalido: $($meta.RiskLevel)") }
        if ($meta.DynamicToggle -and $meta.DynamicToggle -notin $script:ValidToggle) {
            $errors.Add("[$name] DynamicToggle invalido: $($meta.DynamicToggle)")
        }
        foreach ($cap in @($meta.RequiresSystemCaps)) {
            if ($cap -and $cap -notin $script:KnownCaps) { $errors.Add("[$name] RequiresSystemCaps desconocido: $cap") }
        }
        foreach ($cap in @($meta.DenySystemCaps)) {
            if ($cap -and $cap -notin $script:KnownCaps) { $errors.Add("[$name] DenySystemCaps desconocido: $cap") }
        }
        $provKeys = @($p | Get-Member -MemberType NoteProperty |
                     Where-Object Name -ne '_meta' |
                     Select-Object -ExpandProperty Name)
        foreach ($provKey in $provKeys) {
            $internalFields = @('Files', 'Services', 'Tasks', 'Registry', 'RegistryKeys',
                                'DNS', 'BCD', 'WindowsFeatures', 'ACL')  # campos internos / multi-dispatch
            if ($provKey -in $internalFields) { continue }
            if (-not $script:ProviderMap.Contains($provKey)) {
                $errors.Add("[$name] Provider desconocido: $provKey (no encontrado en ProviderMap)")
            }
        }
    }
    foreach ($pname in $script:ctx.WADData.Payloads.PSObject.Properties.Name) {
        $p = $script:ctx.WADData.Payloads.$pname
        if ($p.PSObject.Properties['RegistryTemplate'] -and -not $p.PSObject.Properties['DeviceClasses']) {
            $errors.Add("[$pname] RegistryTemplate requiere DeviceClasses")
        }
    }
    $rollbackRL = $script:ctx.WADData.UIMapping.Runlevels.Rollback
    if ($rollbackRL -and $rollbackRL.Payloads) {
        foreach ($rbName in $rollbackRL.Payloads) {
            if (-not $script:ctx.WADData.Payloads.$rbName) { continue }
            $rbMeta = $script:ctx.WADData.Payloads.$rbName._meta
            if ($rbMeta -and $rbMeta.Reversible -eq $false) {
                $errors.Add("[SCHEMA] Rollback contiene payload irreversible: $rbName (_meta.Reversible=false)")
            }
        }
    }
    if ($errors.Count -gt 0) {
        $msg = "Errores de validacion WAD:`n" + ($errors -join "`n")
        [System.Windows.MessageBox]::Show($msg, 'Manolito Engine - WAD Error', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        exit 1
    }
}
function Test-ManolitoOwnership {
    param([string]$PayloadName)
    $manifestPath = Join-Path $DOCS_MANOLITO 'manifest.json'
    if (-not (Test-Path $manifestPath)) { return $false }
    try {
        $m = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($m.PSObject.Properties['AppliedPayloads'] -and $m.AppliedPayloads -contains $PayloadName) { return $true }
    }
    catch {}
    return $false
}
function Push-RollbackEntry {
    param(
        [bool]$Condition,
        [string]$PayloadName,
        [string]$ProviderKey,
        [string]$Type,
        [bool]$IsIRR,
        [object]$Data
    )
    if ($Condition) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = $ProviderKey
            Type        = $Type
            IsIRR       = $IsIRR
            Data        = $Data
        })
    }
}
function Get-RegistrySnapshot {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Label,
        [switch]$TrackPathExists
    )
    $before = $null
    $pathExistedBefore = $true
    if ($TrackPathExists) { $pathExistedBefore = Test-Path $Path }
    try {
        $before = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
    } catch {
        if ($TrackPathExists) {
            $before = if (-not $pathExistedBefore) { '__NEW_PATH__' } else { '__READ_ERROR__' }
        } else {
            $before = $null
        }
        Write-QLog "[WARN-SNAP] $Label`: $($_.Exception.Message)"
    }
    return $before
}
function New-PayloadContract {
    [CmdletBinding()]
    param()
    return @{
        Logs    = [System.Collections.Generic.List[string]]::new()
        Success = $true
        Changes = 0
    }
}
function Complete-ProviderContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Contract)
    return @{ Success = $Contract.Success; Changes = $Contract.Changes; Logs = $Contract.Logs }
}
function Invoke-PayloadWindowsFeatures {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($e in $data.Entries) {
            $fn   = $e.Feature
            $prev = $e.PreviousState
            if (-not $fn) { continue }
            if ($prev -eq 'Unknown') {
                Write-QLog "[ROLLBACK]   SKIP WF $fn -- PreviousState=Unknown, no se puede revertir automaticamente"
                continue
            }
            try {
                if ($prev -match '^Enabled') {
                    dism.exe /Online /Enable-Feature /FeatureName:$fn /NoRestart /Quiet 2>$null | Out-Null
                    Write-QLog "[ROLLBACK]   WF $fn restaurado a Enabled"
                } elseif ($prev -match '^Disabled') {
                    dism.exe /Online /Disable-Feature /FeatureName:$fn /NoRestart /Quiet 2>$null | Out-Null
                    Write-QLog "[ROLLBACK]   WF $fn restaurado a Disabled"
                } else {
                    Write-QLog "[ROLLBACK]   SKIP WF $fn -- PreviousState='$prev' no reconocido"
                    $allOk = $false
                }
            } catch {
                Write-QLog "[ROLLBACK]   ERR WF $fn : $($_.Exception.Message)"
                $allOk = $false
            }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $changed = [System.Collections.Generic.List[string]]::new()
    $wfPrevStates = @{}  # captura de estado real previo
    foreach ($f in $Payload.WindowsFeatures) {
        $logs.Add("DISM $($f.Name) -> $($f.TargetState)")
        if (-not $script:ctx.Runtime.IsDryRun) {
            try {
                $wfObj = Get-WindowsOptionalFeature -Online -FeatureName $f.Name -ErrorAction SilentlyContinue
                $wfPrevStates[$f.Name] = if ($wfObj) { $wfObj.State.ToString() } else { 'Unknown' }
            } catch { $wfPrevStates[$f.Name] = 'Unknown' }
        }
        if ($script:ctx.Runtime.IsDryRun) { continue }
        try {
            if ($f.TargetState -eq 'Disable') {
                dism.exe /Online /Disable-Feature /FeatureName:$f.Name /NoRestart /Quiet 2>$null | Out-Null
            } else {
                dism.exe /Online /Enable-Feature /FeatureName:$f.Name /NoRestart /Quiet 2>$null | Out-Null
            }
            $changed.Add("$($f.Name) -> $($f.TargetState)")
            $ctr.Changes++
        } catch { $ctr.Success = $false; $logs.Add("ERR Feature $($f.Name) : $($_.Exception.Message)") }
    }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $changed.Count -gt 0) {
        $rbWFEntries = $changed | ForEach-Object {
            $fn = ($_ -split ' ->')[0].Trim()
            @{ Feature = $fn; PreviousState = $wfPrevStates[$fn] }
        }
        $inverse = $changed | ForEach-Object { $_ -replace '-> Disable','-> Enable' -replace '-> Enable','-> Disable' }
        Push-RollbackEntry -Condition $true -PayloadName $PayloadName -ProviderKey 'WindowsFeatures' -Type 'A' -IsIRR $false -Data @{
            Instructions = "Revertir manualmente via DISM: $($inverse -join '; ')"
            Entries      = $rbWFEntries
        }
    }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadCleanup {
    param($Payload, [string]$PayloadName)
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $isDism = ($null -ne $Payload.DismResetBase)
    if ($isDism) {
        $logs.Add('DISM ResetBase - WinSxS cleanup')
        if ($script:ctx.Runtime.IsDryRun) { return Complete-ProviderContract $ctr }
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = 'dism.exe'
            $psi.Arguments              = '/Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet'
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $dismProc      = [System.Diagnostics.Process]::Start($psi)
            $dismOutLineCount = 0
            $dismErrBuffer    = [System.Text.StringBuilder]::new()
            $outHandler = {
                if ($null -ne $EventArgs.Data) { $Event.MessageData.Count++ }
            }
            $errHandler = {
                if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.Append($EventArgs.Data).Append("`n") }
            }
            $outCounter = [PSCustomObject]@{ Count = 0 }
            Register-ObjectEvent -InputObject $dismProc -EventName OutputDataReceived -Action $outHandler -MessageData $outCounter | Out-Null
            Register-ObjectEvent -InputObject $dismProc -EventName ErrorDataReceived  -Action $errHandler -MessageData $dismErrBuffer | Out-Null
            $dismProc.BeginOutputReadLine()
            $dismProc.BeginErrorReadLine()
            $dismStart   = [DateTime]::UtcNow
            $dismTimeout = 1800
            while (-not $dismProc.HasExited) {
                $elapsed = ([DateTime]::UtcNow - $dismStart).TotalSeconds
                $pct = [Math]::Min(99, [int]($elapsed / $dismTimeout * 100))
                $script:ctx.ProgressQueue.Enqueue("PROG:$pct")
                $script:ctx.LogQueue.Enqueue("LOG:[DISM] ResetBase en progreso -- ${elapsed}s transcurridos ($($outCounter.Count) lineas stdout)...")
                Start-Sleep -Seconds 5
                if ($elapsed -ge $dismTimeout) {
                    try { Stop-Process -Id $dismProc.Id -Force -ErrorAction Stop } catch {}
                    try { taskkill /PID $dismProc.Id /T /F 2>$null } catch {}
                    $script:ctx.LogQueue.Enqueue("LOG:[DISM] WARN Timeout de ${dismTimeout}s superado -- proceso y arbol de hijos forzados a terminar")
                    break
                }
            }
            Get-EventSubscriber | Where-Object { $_.SourceObject -eq $dismProc } | Unregister-Event
            $dismExitCode = if ($dismProc.HasExited) { $dismProc.ExitCode } else { -1 }
            $dismStdout   = "$($outCounter.Count) lineas (no retenidas en memoria)"
            $dismStderr   = $dismErrBuffer.ToString()
            $dismProc.Dispose()
            $dismResult = @{ Success = ($dismExitCode -in @(0, 3010, 50)); ExitCode = $dismExitCode; Stderr = $dismStderr }
            if (-not $dismResult.Success) {
                $logs.Add("WARN DismResetBase ExitCode $($dismResult.ExitCode): $($dismResult.Stderr)")
                if ($dismResult.ExitCode -notin @(0, 3010, 50)) { $ctr.Success = $false }
            }
        } catch { $ctr.Success = $false; $logs.Add("ERR DismResetBase : $($_.Exception.Message)") }
        Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) `
            -PayloadName $PayloadName -ProviderKey 'TempCleanup' -Type 'C' -IsIRR $true `
            -Data @{ Note = 'DISM ResetBase elimina componentes de Windows de forma permanente' }
    } else {
        $logs.Add('CLEAN Limpiando temporales')
        if ($script:ctx.Runtime.IsDryRun) { return Complete-ProviderContract $ctr }
        $dirs = @($env:TEMP, $env:TMP, "$env:SystemRoot\Temp")
        foreach ($d in $dirs) {
            Get-ChildItem $d -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        $ctr.Changes++
    }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadAppxpackages {
    param($Payload, [string]$PayloadName, [switch]$IsRollback)
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $removed = [System.Collections.Generic.List[string]]::new()
    $riskyPatterns  = @('StorePurchaseApp')
    $legacyPatterns = @('Wunderlist')
    [array]$_pkgs = $Payload.Packages
    foreach ($pkg in $_pkgs) {
        foreach ($rp in $riskyPatterns) {
            if ($pkg.Pattern -match $rp) {
                $logs.Add("WARN PurgeAppx '$($pkg.FriendlyName)': puede romper funciones de compra en Microsoft Store -- revisar si es necesario")
            }
        }
        foreach ($lp in $legacyPatterns) {
            if ($pkg.Pattern -match $lp) {
                $logs.Add("INFO PurgeAppx '$($pkg.FriendlyName)': app discontinuada -- seguro eliminar")
            }
        }
    }
    [array]$_pkgs = $Payload.Packages
    foreach ($pkg in $_pkgs) {
        $logs.Add("APPX Eliminando $($pkg.FriendlyName)")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        try {
            Get-AppxPackage -Name $pkg.Pattern -AllUsers -ErrorAction SilentlyContinue |
                Remove-AppxPackage -ErrorAction SilentlyContinue
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.PackageName -like $pkg.Pattern } |
                Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
            $removed.Add($pkg.FriendlyName)
            $ctr.Changes++
        } catch { $logs.Add("WARN Appx $($pkg.FriendlyName) : $($_.Exception.Message)") }
    }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $removed.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'Packages' -Type 'B' -IsIRR $false `
        -Data @{
            RemovedPackages = $removed.ToArray()
            Instructions    = "Reinstalar manualmente desde Microsoft Store: $($removed -join ', ')"
        }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadServices {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($s in $data.Entries) {
            try {
                Set-Service -Name $s.Name -StartupType $s.Before -ErrorAction Stop
                if ($s.WasRunning -eq $true) {
                    Start-Service -Name $s.Name -ErrorAction SilentlyContinue
                    Write-QLog "[ROLLBACK]   SVC $($s.Name) Start intentado (WasRunning=true)"
                }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR Service $($s.Name): $_" }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    [array]$_svcs = $Payload.Services
    foreach ($svc in $_svcs) {
        $name   = if ($svc -is [string]) { $svc } else { $svc.Name }
        $target = if ($svc -is [string]) { 'Disabled' } else { $svc.TargetState }
        $logs.Add("SVC $name -> $target")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        try {
            $s = Get-Service -Name $name -ErrorAction Stop
            $beforeStartup = $s.StartType.ToString()
            $wasRunning    = ($s.Status -eq 'Running')
            if ($target -eq 'Disabled' -and $wasRunning) {
                Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $name -StartupType $target -ErrorAction Stop
            $ctr.Changes++
            $rbEntries.Add(@{
                Name          = $name
                Before        = $beforeStartup
                WasRunning    = $wasRunning
            })
        } catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
            if ($_.Exception.Message -match 'Cannot find any service') {
                $logs.Add("SKIP SVC $name -- no existe en este OS (eliminado en 24H2 o superior)")
            } else {
                $ctr.Success = $false; $logs.Add("ERR SVC $name : $($_.Exception.Message)")
            }
        } catch {
            $ctr.Success = $false; $logs.Add("ERR SVC $name : $_")
        }
    }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'Services' -Type 'A' -IsIRR $false -Data @{ Entries = $rbEntries.ToArray() }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadTasks {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($t in $data.Entries) {
            try {
                if ($t.WasEnabled -eq $true) {
                    Enable-ScheduledTask  -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop | Out-Null
                    Write-QLog "[ROLLBACK]   TASK $($t.Name) re-habilitada (WasEnabled=true)"
                } else {
                    Disable-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop | Out-Null
                    Write-QLog "[ROLLBACK]   TASK $($t.Name) deshabilitada (WasEnabled=false)"
                }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR Task $($t.Name): $_" }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    [array]$_tsks = $Payload.Tasks
    foreach ($t in $_tsks) {
        $tName   = if ($t -is [string]) { $t } else { $t.Name }
        $tPath   = if ($t -is [string]) { '' } else { $t.Path }
        $tTarget = if ($t -is [string]) { 'Disabled' } else { $t.TargetState }
        $full    = if ($tPath) { "$tPath\$tName" } else { $tName }
        $logs.Add("TASK $full -> $tTarget")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        try {
            $existing = Get-ScheduledTask -TaskName $tName -TaskPath $tPath -ErrorAction SilentlyContinue
            $wasEnabled = $false
            if ($existing) {
                $wasEnabled = ($existing.Settings.Enabled -eq $true)
            }
            if ($tTarget -eq 'Disable') {
                Disable-ScheduledTask -TaskName $tName -TaskPath $tPath -ErrorAction Stop | Out-Null
            } else {
                Enable-ScheduledTask  -TaskName $tName -TaskPath $tPath -ErrorAction Stop | Out-Null
            }
            $ctr.Changes++
            $rbEntries.Add(@{
                Name       = $tName
                Path       = $tPath
                WasEnabled = $wasEnabled
            })
        } catch { $logs.Add("WARN TASK $full : $_") }
    }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'Tasks' -Type 'A' -IsIRR $false -Data @{ Entries = $rbEntries.ToArray() }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadRegistry {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($r in $data.Entries) {
            try {
                if ($r.Before -eq '__NEW_PATH__') {
                    if (Test-Path $r.Path) { Remove-Item -Path $r.Path -Force -ErrorAction SilentlyContinue }
                    Write-QLog "[ROLLBACK DEL] Registry $($r.Path) eliminado (creado por Manolito)"
                } elseif ($r.Before -eq '__READ_ERROR__') { Write-QLog "[ROLLBACK SKIP] Registry $($r.Path)\$($r.Name) -- valor previo no pudo leerse, omitido" }
                elseif ($null -eq $r.Before) {
                    Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction Stop
                } else {
                    Set-ItemProperty -Path $r.Path -Name $r.Name -Value $r.Before -Type $r.Type -Force -ErrorAction Stop
                }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR Registry $($r.Path)\$($r.Name): $_" }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    $seenRegKeys = [System.Collections.Generic.HashSet[string]]::new()
    [array]$_regs = $Payload.Registry
    foreach ($r in $_regs) {
        $tv = if ($null -ne $r.TargetValue) { $r.TargetValue } else { $r.Value }
        $dedupKey = "$($r.Path)|$($r.Name)"
        if (-not $seenRegKeys.Add($dedupKey)) {
            $logs.Add("SKIP-DUP REG $($r.Path) $($r.Name) (duplicado en payload)")
            continue
        }
        $logs.Add("REG $($r.Path) $($r.Name) = $tv")
        if ($script:ctx.Runtime.IsDryRun) { $ctr.Changes++; continue }
        try {
            $before = Get-RegistrySnapshot -Path $r.Path -Name $r.Name -Label "Registry $($r.Path)\$($r.Name)" -TrackPathExists
            $shouldCreate = ($null -eq $r.CreateIfMissing -or $r.CreateIfMissing -eq $true)
            if (-not (Test-Path $r.Path)) {
                if ($shouldCreate) { New-Item -Path $r.Path -Force | Out-Null }
                else { $logs.Add("SKIP REG $($r.Path) -- ruta no existe y CreateIfMissing=false"); continue }
            }
            if (-not $shouldCreate) {
                $existingVal = $null
                try { $existingVal = (Get-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction Stop).$($r.Name) } catch {}
                if ($null -eq $existingVal) {
                    $logs.Add("SKIP REG $($r.Path)\$($r.Name) -- valor no existe y CreateIfMissing=false")
                    continue
                }
            }
            $meta = $script:ctx.WADData.Payloads.$PayloadName._meta
            if ($meta -and $meta.DynamicToggle -eq 'Universal' -and
                $null -ne $before -and $before -ne '__READ_ERROR__' -and
                -not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) {
                $currentVal = $before
                if ("$currentVal" -eq "$tv") {
                    $rv = if ($null -ne $r.RestoreValue) { $r.RestoreValue } else { $null }
                    if ($null -ne $rv) {
                        $logs.Add("TOGGLE REG $($r.Name): ya en estado $tv, invirtiendo a RestoreValue=$rv")
                        $tv = $rv
                    }
                }
            }
            $tvFinal = $tv
            if ($r.Type -eq 'DWord') {
                $tvAsDouble = $null
                if ([double]::TryParse("$tv", [ref]$tvAsDouble)) {
                    if ($tvAsDouble -ge [int32]::MinValue -and $tvAsDouble -le [int32]::MaxValue) {
                        $tvFinal = [Int32]$tvAsDouble
                    } elseif ($tvAsDouble -gt [int32]::MaxValue -and $tvAsDouble -le [uint32]::MaxValue) {
                        $uintVal = [uint32]$tvAsDouble
                        $tvFinal = [System.BitConverter]::ToInt32([System.BitConverter]::GetBytes($uintVal), 0)
                    } else {
                        $logs.Add("WARN REG $($r.Path) $($r.Name) -- valor '$tv' fuera de rango representable como DWord (Int32/UInt32), se aplica sin castear")
                    }
                }
            }
            $propExists = $null -ne (Get-ItemProperty $r.Path -Name $r.Name -ErrorAction SilentlyContinue).$($r.Name)
            if ($propExists) {
                Set-ItemProperty -Path $r.Path -Name $r.Name -Value $tvFinal -Type $r.Type -Force
            } else {
                New-ItemProperty -Path $r.Path -Name $r.Name -Value $tvFinal -PropertyType $r.Type -Force | Out-Null
            }
            $ctr.Changes++
            $rbEntries.Add(@{ Path = $r.Path; Name = $r.Name; Type = $r.Type; Before = $before })
        } catch { $ctr.Success = $false; $logs.Add("ERR REG $($r.Path) $($r.Name) : $($_.Exception.Message)") }
    }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'Registry' -Type 'A' -IsIRR $false -Data @{ Entries = $rbEntries.ToArray() }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadRegistryKeys {
    param($Payload, [string]$PayloadName, [switch]$IsRollback)
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $changed = [System.Collections.Generic.List[string]]::new()
    [array]$_rks = $Payload.RegistryKeys
    foreach ($r in $_rks) {
        $logs.Add("REGKEY $($r.Path)")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        try {
            if ($r.Action -eq 'Delete') {
                Remove-Item -Path $r.Path -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                New-Item -Path $r.Path -Force | Out-Null
            }
            $changed.Add("$($r.Action) $($r.Path)")
        } catch { $ctr.Success = $false; $logs.Add("ERR REGKEY $($r.Path) : $($_.Exception.Message)") }
    }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $changed.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'RegistryKeys' -Type 'B' -IsIRR $false `
        -Data @{ Instructions = "Revisar manualmente las claves modificadas: $($changed -join '; ')" }
    if ($changed.Count -gt $ctr.Changes) { $ctr.Changes = $changed.Count }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadNagle {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($n in $data.Entries) {
            try {
                if ($null -eq $n.Before) {
                    Remove-ItemProperty -Path $n.Path -Name $n.Name -ErrorAction Stop
                } else {
                    Set-ItemProperty -Path $n.Path -Name $n.Name -Value $n.Before -Type $n.Type -Force -ErrorAction Stop
                }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR Nagle $($n.Path): $_" }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $logs.Add('NAGLE Desactivando algoritmo Nagle en NIC activa')
    if ($script:ctx.Runtime.IsDryRun) { return Complete-ProviderContract $ctr }
    if (-not $script:ctx.SystemCaps.HasPhysicalNIC) {
        $logs.Add('SKIP NAGLE -- HasPhysicalNIC=false (sin NIC fisica activa detectada)')
        return Complete-ProviderContract $ctr
    }
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    try {
        $guid = (Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).InterfaceGuid
        if (-not $guid) { $logs.Add('SKIP No NIC activa encontrada'); return Complete-ProviderContract $ctr }
        $base = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
        foreach ($e in $Payload.NagleTemplate) {
            $before = Get-RegistrySnapshot -Path $base -Name $e.Name -Label "Nagle $base"
            if (-not (Test-Path $base)) { New-Item -Path $base -Force | Out-Null }
            Set-ItemProperty -Path $base -Name $e.Name -Value $e.TargetValue -Type $e.Type -Force
            $rbEntries.Add(@{ Path = $base; Name = $e.Name; Type = $e.Type; Before = $before })
        }
    } catch { $ctr.Success = $false; $logs.Add("ERR Nagle : $($_.Exception.Message)") }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'NagleTemplate' -Type 'A' -IsIRR $false -Data @{ Entries = $rbEntries.ToArray() }
    if ($rbEntries.Count -gt $ctr.Changes) { $ctr.Changes = $rbEntries.Count }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadDNS {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($a in $data.Entries) {
            try {
                $prev = Resolve-DnsBackup -Backup $a.Before
                if ($prev -eq 'DHCP') {
                    Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                } else {
                    Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses $prev -ErrorAction Stop
                }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR DNS iface $($a.InterfaceIndex): $_" }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $logs.Add("DNS -> $($Payload.DNS.Primary.TargetValue) / $($Payload.DNS.Secondary.TargetValue)")
    if ($script:ctx.Runtime.IsDryRun) { return Complete-ProviderContract $ctr }
    if (-not $script:ctx.SystemCaps.HasPhysicalNIC) {
        $logs.Add('SKIP DNS -- HasPhysicalNIC=false (sin NIC fisica activa detectada)')
        return Complete-ProviderContract $ctr
    }
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    try {
        $adapters = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' }
        foreach ($a in $adapters) {
            $before = (Get-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
            Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex `
                -ServerAddresses $Payload.DNS.Primary.TargetValue, $Payload.DNS.Secondary.TargetValue
            $rbEntries.Add(@{ InterfaceIndex = $a.InterfaceIndex; Before = $before })
        }
    } catch { $ctr.Success = $false; $logs.Add("ERR DNS : $($_.Exception.Message)") }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'DNS' -Type 'A' -IsIRR $false -Data @{ Entries = $rbEntries.ToArray() }
    if ($rbEntries.Count -gt $ctr.Changes) { $ctr.Changes = $rbEntries.Count }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadBCD {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($b in $data.Entries) {
            try {
                if ($b.IsNew) {
                    bcdedit /deletevalue '{current}' $b.Setting 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "bcdedit deletevalue salio con $LASTEXITCODE" }
                    Write-QLog "[ROLLBACK]   BCD deletevalue $($b.Setting)"
                } else {
                    if ($null -eq $b.OldValue) { throw "OldValue nulo para $($b.Setting)" }
                    bcdedit /set '{current}' $b.Setting $b.OldValue 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "bcdedit set salio con $LASTEXITCODE" }
                    Write-QLog "[ROLLBACK]   BCD set $($b.Setting) = $($b.OldValue)"
                }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR BCD $($b.Setting): $_" }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($b in $Payload.BCD) {
        $logs.Add("BCD $($b.Setting) -> $($b.TargetValue)")
        if ($script:ctx.Runtime.IsDryRun) { $ctr.Changes++; continue }
        try {
            $enumOut      = bcdedit /enum '{current}' 2>$null
            $settingEsc   = [regex]::Escape($b.Setting)
            $existingLine = $enumOut | Where-Object { $_ -match "^\s*$settingEsc\s+" }
            $isNew        = (-not $existingLine)
            $oldVal       = $null
            if (-not $isNew -and $existingLine) {
                $oldVal = ($existingLine -split '\s+', 2)[-1].Trim()
            }
            bcdedit /set '{current}' $b.Setting $b.TargetValue 2>$null | Out-Null
            $rbEntries.Add(@{ Setting = $b.Setting; IsNew = $isNew; OldValue = $oldVal })
            $ctr.Changes++
        } catch { $ctr.Success = $false; $logs.Add("ERR BCD $($b.Setting) : $_") }
    }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'BCD' -Type 'A' -IsIRR $false -Data @{ Entries = $rbEntries.ToArray() }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadMSITuning {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($r in $data.Entries) {
            try {
                if ($null -eq $r.Before) {
                    Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction Stop
                } else {
                    Set-ItemProperty -Path $r.Path -Name $r.Name -Value $r.Before -Type $r.Type -Force -ErrorAction Stop
                }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR MSI $($r.Name): $_" }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $msiOwned    = Test-ManolitoOwnership 'MSITuning'
    $msiExternal = $false
    try {
    $devEnum = if ($script:ctx.Cache.EnumDevices) { $script:ctx.Cache.EnumDevices }
               else {
                    $enumRoots2 = @('HKLM:\SYSTEM\CurrentControlSet\Enum\PCI',
                                    'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY')
                    $enumRoots2 | Where-Object { Test-Path $_ } |
                    ForEach-Object { Get-ChildItem $_ -Recurse -Depth 3 -ErrorAction SilentlyContinue } |
                    Where-Object { $_.PSChildName -eq 'Device Parameters' }
               }
        foreach ($dev in $devEnum) {
            if ($null -eq $dev -or [string]::IsNullOrEmpty($dev.PSPath)) {
                Write-QLog "  [MSI] SKIP dispositivo nulo o sin PSPath (virtual/incompleto) en pre-chequeo msiExternal"; continue
            }
            $intPath = Join-Path $dev.PSPath 'Interrupt Management'
            if (Test-Path $intPath) {
                $val = (Get-ItemProperty $intPath -Name 'MSISupported' -ErrorAction SilentlyContinue).MSISupported
                if ($val -eq 1) { $msiExternal = $true; break }
            }
        }
    } catch {}
    if ($msiOwned) {
        $logs.Add('INFO MSITuning: activo por Manolito -- sobreescribiendo con backup capturado')
        $script:ctx.SystemCaps.MSIState = 'AppliedByManolito'
    } elseif ($msiExternal) {
        $logs.Add('WARN MSITuning: MSI activo por herramienta externa -- Manolito aplicara perfil propio y creara nuevo backup')
        $script:ctx.SystemCaps.MSIState = 'AppliedExternal'
    } else {
        $logs.Add('INFO MSITuning: MSI inactivo -- aplicando')
        $script:ctx.SystemCaps.MSIState = 'Inactive'
    }
    $logs.Add('MSI Activando MSI Interrupts en GPU y NVMe')
    if ($script:ctx.Runtime.IsDryRun) { return Complete-ProviderContract $ctr }
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($class in $Payload.DeviceClasses) {
        $devPath = "HKLM:\SYSTEM\CurrentControlSet\Enum"
        try {
            $devs = Get-ChildItem -Path $devPath -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match 'Device Parameters' -and
                                   ($_.GetValue('Class') -eq $class -or $_.PSPath -match $class) }
            foreach ($dev in $devs) {
                if ($null -eq $dev -or [string]::IsNullOrEmpty($dev.PSPath)) {
                    Write-QLog "  [MSI] SKIP dispositivo nulo o sin PSPath (virtual/incompleto)"; continue
                }
                $intPath = Join-Path $dev.PSPath 'Interrupt Management'
                if (-not (Test-Path $intPath)) { New-Item -Path $intPath -Force | Out-Null }
                foreach ($t in $Payload.RegistryTemplate) {
                    $before = Get-RegistrySnapshot -Path $intPath -Name $t.Name -Label "MSITuning $intPath"
                    Set-ItemProperty -Path $intPath -Name $t.Name -Value $t.TargetValue -Type $t.Type -Force
                    $rbEntries.Add(@{ Path = $intPath; Name = $t.Name; Type = $t.Type; Before = $before })
                }
            }
        } catch { $logs.Add("WARN MSI $class : $($_.Exception.Message)") }
    }
    $script:ctx.SystemCaps.MSIState = 'AppliedByManolito'
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'DeviceClasses' -Type 'A' -IsIRR $false -Data @{ Entries = $rbEntries.ToArray() }
    if ($rbEntries.Count -gt $ctr.Changes) { $ctr.Changes = $rbEntries.Count }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadActiveSetup {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($ae in $data.Entries) {
            try {
                $props = $ae.KeyData | Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue |
                         Where-Object {
                             $_.Name -notmatch '^PS[A-Z]' -and
                             $_.Name -notin @('PSChildName','PSParentPath','PSPath','PSProvider','PSDrive')
                         }
                if (-not $ae.KeyData) {
                    Write-QLog "[ROLLBACK]   WARN ActiveSetup $($ae.Path) sin KeyData -- omitido"
                    $allOk = $false; continue
                }
                New-Item -Path $ae.Path -Force -ErrorAction Stop | Out-Null
                foreach ($v in $props) {
                    Set-ItemProperty -Path $ae.Path -Name $v.Name -Value $ae.KeyData.$($v.Name) -Force -ErrorAction Stop
                }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR ActiveSetup $($ae.Path): $_" }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    [array]$_ases = $Payload.ActiveSetupEntries
    foreach ($entry in $_ases) {
        $logs.Add("AS Eliminando $entry")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$entry",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Active Setup\Installed Components\$entry"
        )
        foreach ($p in $paths) {
            if (Test-Path $p) {
                $keyData = $null
                try { $keyData = Get-ItemProperty -Path $p -ErrorAction Stop } catch {}
                Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
                $ctr.Changes++
                $rbEntries.Add(@{
                    Path         = $p
                    KeyData      = $keyData
                    Instructions = "Restaurar clave de registro: $p (snapshot plano adjunto en KeyData)"
                })
            }
        }
    }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'ActiveSetupEntries' -Type 'A' -IsIRR $false `
        -Data @{
            Entries      = $rbEntries.ToArray()
            Instructions = "Restaurar claves Active Setup manualmente. Ver KeyData en cada entrada."
        }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadHosts {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        if ([string]::IsNullOrEmpty($data.OriginalContent)) {
            Write-QLog '[ROLLBACK]   WARN Hosts: sin snapshot -- requiere restauracion manual'
            return @{ Success = $false; PendingAction = "restaurar manualmente C:\Windows\System32\drivers\etc\hosts" }
        }
        try {
            $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
            Set-Content -Path $hostsPath -Value $data.OriginalContent -Encoding ASCII -Force -ErrorAction Stop
            Write-QLog '[ROLLBACK]   Hosts restaurado desde snapshot de sesion'
            return @{ Success = $true }
        } catch {
            Write-QLog "[ROLLBACK]   ERR Hosts: $_"
            return @{ Success = $false; PendingAction = "restaurar manualmente hosts: $($_.Exception.Message)" }
        }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $logs.Add('HOSTS Procesando entradas')
    if ($script:ctx.Runtime.IsDryRun) { return Complete-ProviderContract $ctr }
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    try {
        $existing = Get-Content $hostsPath -ErrorAction Stop
        $script:ctx.Tracking.Backups.Hosts = $existing   # usar propiedad Hosts fija (no $PayloadName dinamico -- PSCustomObject no admite propiedades dinamicas)
        $seen    = [System.Collections.Generic.HashSet[string]]::new()
        $deduped = 0
        $toAdd   = [System.Collections.Generic.List[string]]::new()
        [array]$_hes = $Payload.HostsEntries
    foreach ($rawEntry in $_hes) {
            $domain = if ($rawEntry -is [string]) { $rawEntry } else { $rawEntry.Domain }
            if ([string]::IsNullOrWhiteSpace($domain)) { continue }
            $norm = $domain.Trim().ToLower()
            if (-not $seen.Add($norm)) { $deduped++; continue }
            $line = "0.0.0.0 $norm"
            if ($existing -notcontains $line) { $toAdd.Add($line) }
        }
        if ($deduped -gt 0)    { $logs.Add("HOSTS $deduped entradas deduplicadas") }
        if ($toAdd.Count -eq 0) { $logs.Add('HOSTS Sin entradas nuevas'); return Complete-ProviderContract $ctr }
        Add-Content -Path $hostsPath -Value $toAdd -Encoding ASCII
        $ctr.Changes = $toAdd.Count
        $logs.Add("HOSTS $($toAdd.Count) entradas anadidas")
        Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) `
            -PayloadName $PayloadName -ProviderKey 'HostsEntries' -Type 'A' -IsIRR $false -Data @{ OriginalContent = $existing }
    } catch { $ctr.Success = $false; $logs.Add("ERR Hosts : $($_.Exception.Message)") }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadDeKMS {
    param($Payload, [string]$PayloadName)
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $logs.Add('DeKMS Inspeccionando activacion KMS')
    if ($script:ctx.Runtime.IsDryRun) { return Complete-ProviderContract $ctr }
    $cleaned = $false
    try {
        $kmsHost = ''
        try {
            $kmsHost = Get-ItemPropertyValue `
                -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform' `
                -Name 'KeyManagementServiceName' -ErrorAction Stop
        } catch {
            $kmsHost = ''
        }
        if ($null -eq $kmsHost) { $kmsHost = '' }
        $blocked = $false
        foreach ($pattern in $Payload.Blacklist) {
            if ($kmsHost -match $pattern) { $blocked = $true; break }
        }
        if (-not $blocked) {
            $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
            if (Test-Path $hostsFile) {
                $hostsRaw = Get-Content $hostsFile -Raw -ErrorAction SilentlyContinue
                foreach ($pattern in $Payload.Blacklist) {
                    if ($pattern -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                        if ($hostsRaw -match [regex]::Escape($pattern)) {
                            $blocked = $true
                            $logs.Add("DeKMS IP KMS detectada en HOSTS: $pattern")
                            break
                        }
                    }
                }
            }
        }
        if ($blocked) {
            $logs.Add("DeKMS KMS irregular detectado: [$kmsHost] - limpiando")
            & cscript /Nologo "$env:SystemRoot\System32\slmgr.vbs" /ckms 2>$null | Out-Null
            [array]$_svcs2 = $Payload.Services
    foreach ($svcName in $_svcs2) {
                if ([string]::IsNullOrWhiteSpace($svcName)) { continue }
                $svcObj = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                if ($svcObj) {
                    if ($svcObj.Status -eq 'Running') {
                        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
                        Write-QLog "  [DeKMS] SVC $svcName detenido"
                    }
                    Set-Service -Name $svcName -StartupType Disabled -ErrorAction SilentlyContinue
                    Write-QLog "  [DeKMS] SVC $svcName -> Disabled"
                } else {
                    Write-QLog "  [DeKMS] SVC $svcName no encontrado (omitido)"
                }
            }
            foreach ($f in $Payload.Files) {
                if ([string]::IsNullOrWhiteSpace($f)) { continue }
                $resolved = [System.Environment]::ExpandEnvironmentVariables($f)
                if (Test-Path $resolved) {
                    $sig = Get-AuthenticodeSignature -LiteralPath $resolved -ErrorAction SilentlyContinue
                    $isMSSigned = $sig -and $sig.Status -eq 'Valid' -and
                                  $sig.SignerCertificate -and
                                  $sig.SignerCertificate.Subject -match 'Microsoft'
                    if ($isMSSigned) {
                        $logs.Add("DeKMS SKIP -- firmado por Microsoft: $resolved")
                    } else {
                        Remove-Item $resolved -Force -ErrorAction SilentlyContinue
                        $ctr.Changes++
                        Write-QLog "  [DeKMS] FILE eliminado: $resolved"
                    }
                } else {
                    Write-QLog "  [DeKMS] FILE no existe: $resolved (omitido)"
                }
            }
            foreach ($taskName in $Payload.Tasks) {
                if ([string]::IsNullOrWhiteSpace($taskName)) { continue }
                $found = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if ($found) {
                    foreach ($t in @($found)) {
                        try {
                            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath `
                                -Confirm:$false -ErrorAction Stop
                            Write-QLog "  [DeKMS] TASK eliminada: $($t.TaskPath)$($t.TaskName)"
                        } catch {
                            Write-QLog "  [DeKMS] WARN TASK $($t.TaskName): $($_.Exception.Message)"
                        }
                    }
                } else {
                    Write-QLog "  [DeKMS] TASK $taskName no encontrada (omitido)"
                }
            }
            $cleaned = $true
            $ctr.Changes++
        } else {
            $logs.Add("DeKMS Sin KMS irregular detectado (host actual: '$(if($kmsHost){"$kmsHost"}else{"<vacio>"})')")
        }
    } catch { $ctr.Success = $false; $logs.Add("ERR DeKMS : $($_.Exception.Message)") }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $cleaned) `
        -PayloadName $PayloadName -ProviderKey 'Blacklist' -Type 'B' -IsIRR $true `
        -Data @{ Instructions = 'Reactivacion KMS requiere accion manual del administrador. DeKMS es IRREVERSIBLE.' }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $cleaned -and
        -not $script:ctx.Tracking.IrreversibleActions.Contains($PayloadName)) {
        [void]$script:ctx.Tracking.IrreversibleActions.Add($PayloadName)
    }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadWinget {
    param($Payload, [string]$PayloadName, [switch]$IsRollback)
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    if ($script:wingetBlocked) {
        $logs.Add('SKIP winget bloqueado por GPO (circuit-breaker activo)')
        return @{ Success = $true; Skipped = $true; Changes = 0; Logs = $logs }
    }
    $installed = [System.Collections.Generic.List[string]]::new()
    $wingetWhitelist = @('install', 'upgrade', 'uninstall')
    foreach ($pkg in $Payload.WingetPackages) {
        $logs.Add("WINGET $($pkg.FriendlyName) ($($pkg.Id))")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        if ($pkg.Action -notin $wingetWhitelist) {
            $logs.Add("ERR Winget action '$($pkg.Action)' no esta en whitelist para $($pkg.Id) -- omitido")
            $ctr.Success = $false; continue
        }
        try {
            $out = & winget $pkg.Action --id $pkg.Id --silent --accept-source-agreements --accept-package-agreements 2>&1
            if ($LASTEXITCODE -eq 0x8A150013 -or ($out -match '0x8A150013')) {
                $logs.Add('GPO winget bloqueado por GPO - activando circuit breaker')
                $script:wingetBlocked = $true
                break
            }
            if ($LASTEXITCODE -eq 0) { $installed.Add($pkg.Id) }
        } catch { $ctr.Success = $false; $logs.Add("ERR Winget $($pkg.Id) : $($_.Exception.Message)") }
    }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $installed.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'WingetPackages' -Type 'B' -IsIRR $false `
        -Data @{
            InstalledIds  = $installed.ToArray()
            Instructions  = "Desinstalar manualmente: $($installed -join ', ')"
        }
    if ($installed.Count -gt $ctr.Changes) { $ctr.Changes = $installed.Count }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadOneDrive {
    param($Payload, [string]$PayloadName, [switch]$IsRollback)
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $logs.Add('ONEDRIVE Desinstalando OneDrive')
    if ($script:ctx.Runtime.IsDryRun) { return Complete-ProviderContract $ctr }
    $changed = $false
    try {
        $exe = "$env:SYSTEMROOT\SysWOW64\OneDriveSetup.exe"
        if (-not (Test-Path $exe)) { $exe = "$env:SYSTEMROOT\System32\OneDriveSetup.exe" }
        if (Test-Path $exe) { & $exe /uninstall 2>$null | Out-Null; $changed = $true; $ctr.Changes++ }
        $paths = @(
            "$env:USERPROFILE\OneDrive",
            "$env:LOCALAPPDATA\Microsoft\OneDrive",
            "$env:PROGRAMDATA\Microsoft OneDrive",
            "$env:SYSTEMDRIVE\OneDriveTemp"
        )
        foreach ($path in $paths) { Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue }
        if ($changed) {
            $regPaths = @(
                'HKCU:\SOFTWARE\Microsoft\OneDrive',
                'HKLM:\SOFTWARE\Microsoft\OneDrive'
            )
            foreach ($rp in $regPaths) {
                if (-not (Test-Path $rp)) { New-Item $rp -Force | Out-Null }
                Set-ItemProperty $rp -Name DisableFileSyncNGSC -Value 1 -Type DWord -Force
            }
        }
    } catch { $ctr.Success = $false; $logs.Add("ERR OneDrive : $($_.Exception.Message)") }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $changed) `
        -PayloadName $PayloadName -ProviderKey 'OneDriveUninstall' -Type 'B' -IsIRR $false `
        -Data @{ Instructions = 'Reinstalar OneDrive manualmente desde https://onedrive.live.com/about/download/' }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadNICTuning {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($p in $data.Entries) {
            try {
                Set-NetAdapterAdvancedProperty -Name $p.AdapterName `
                    -RegistryKeyword $p.Keyword -RegistryValue $p.Before -ErrorAction Stop
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR NIC $($p.AdapterName) $($p.Keyword): $_" }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $logs.Add('NIC Ajustando propiedades avanzadas NIC')
    if ($script:ctx.Runtime.IsDryRun) { return Complete-ProviderContract $ctr }
    if (-not $script:ctx.SystemCaps.HasPhysicalNIC) {
        $logs.Add('SKIP NIC -- HasPhysicalNIC=false (sin NIC fisica activa detectada)')
        return Complete-ProviderContract $ctr
    }
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    try {
        $adapters = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' }
        foreach ($a in $adapters) {
            foreach ($prop in $Payload.NICProperties) {
                try {
                    $existing = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $prop.RegistryKeyword -ErrorAction SilentlyContinue
                    $before   = if ($existing) { $existing.RegistryValue } else { $null }
                    Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $prop.RegistryKeyword -RegistryValue $prop.TargetValue -ErrorAction Stop
                    $rbEntries.Add(@{ AdapterName = $a.Name; Keyword = $prop.RegistryKeyword; Before = $before })
                } catch { $logs.Add("WARN NIC $($a.Name) $($prop.RegistryKeyword) : $($_.Exception.Message)") }
            }
        }
    } catch { $ctr.Success = $false; $logs.Add("ERR NICTuning : $($_.Exception.Message)") }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'NICProperties' -Type 'A' -IsIRR $false -Data @{ Entries = $rbEntries.ToArray() }
    if ($rbEntries.Count -gt $ctr.Changes) { $ctr.Changes = $rbEntries.Count }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadPowercfg {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($s in $data.Entries) {
            try {
                if ($s.Setting -eq 'hibernate') {
                    powercfg /hibernate $s.Before 2>$null | Out-Null
                } else {
                    powercfg /change $s.Setting $s.Before 2>$null | Out-Null
                }
                if ($LASTEXITCODE -ne 0) { throw "powercfg /change salio con $LASTEXITCODE" }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR Powercfg $($s.Setting): $_" }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $Payload.PowercfgSettings) {
        $logs.Add("PCFG $($s.Setting) -> $($s.TargetValue)")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        try {
            $realBefore = $null
            try {
                $qOut = powercfg /query SCHEME_CURRENT 2>$null
                if ($LASTEXITCODE -eq 0 -and $qOut) {
                    $qLines = @($qOut)
                    for ($qi = 0; $qi -lt $qLines.Count; $qi++) {
                        if ($qLines[$qi] -match [regex]::Escape($s.Setting)) {
                            for ($qj = $qi + 1; $qj -lt $qLines.Count; $qj++) {
                                if ($qLines[$qj] -match 'Current AC Power Setting Index:\s*(0x[\da-fA-F]+|\d+)') {
                                    $realBefore = $Matches[1]
                                    break
                                }
                                if ($qLines[$qj] -match 'Power Setting GUID|Subgroup GUID') { break }
                            }
                            if ($null -ne $realBefore) { break }
                        }
                    }
                }
            } catch { Write-QLog "[WARN] No se pudo leer configuracion actual de powercfg /q: $($_.Exception.Message)" }
            if ($s.Setting -eq 'hibernate') {
                try {
                    $hib = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue
                    if ($hib) {
                        $realBefore = if ($null -ne $hib.HibernateEnabled -and [int]$hib.HibernateEnabled -eq 1) { 'on' } else { 'off' }
                    }
                } catch {}
            }
            $before = if ($null -ne $realBefore) { $realBefore } else { $s.RestoreValue }
            if ($s.Setting -eq 'hibernate') {
                powercfg /hibernate $s.TargetValue 2>$null | Out-Null
            } else {
                powercfg /change $s.Setting $s.TargetValue 2>$null | Out-Null
            }
            if ($LASTEXITCODE -ne 0) { throw "powercfg '$($s.Setting)' salio con $LASTEXITCODE" }
            $ctr.Changes++
            $rbEntries.Add(@{
                Setting       = $s.Setting
                Before        = $before
                RealCaptured  = ($null -ne $realBefore)
            })
        } catch { $ctr.Success = $false; $logs.Add("ERR Powercfg $($s.Setting) : $_") }
    }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'PowercfgSettings' -Type 'A' -IsIRR $false -Data @{ Entries = $rbEntries.ToArray() }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadUltimatePower {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $guid = if ($data.OldPlanGuid) { $data.OldPlanGuid }
                elseif ($data.BalancedGUID) { $data.BalancedGUID }
                else { $null }
        if ([string]::IsNullOrEmpty($guid)) {
            Write-QLog '[ROLLBACK]   WARN UltimatePower: GUID no capturado -- accion manual'
            return @{ Success = $false; PendingAction = "ejecutar 'powercfg /setactive <GUID>' manualmente" }
        }
        $caption = if ($data.GuidCaptured) { 'plan previo real' } else { 'fallback Balanced' }
        try {
            powercfg /setactive $guid 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive salio con $LASTEXITCODE" }
            Write-QLog "[ROLLBACK]   Plan restaurado ($caption): $guid"
            return @{ Success = $true }
        } catch {
            Write-QLog "[ROLLBACK]   ERR UltimatePower: $_"
            return @{ Success = $false; PendingAction = "ejecutar 'powercfg /setactive $guid' manualmente" }
        }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $logs.Add('POWER Activando Ultimate Performance')
    if ($script:ctx.Runtime.IsDryRun) {
        return @{ Success = $ctr.Success; Changes = 0; Logs = $logs }
    }
    $oldPlanGuid = $null
    try {
        $scheme = powercfg /getactivescheme 2>$null
        if ($LASTEXITCODE -eq 0 -and $scheme -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
            $oldPlanGuid = $Matches[1]
        }
    } catch { Write-QLog "[WARN] No se pudo obtener el plan de energia activo (rollback de GUID no disponible): $($_.Exception.Message)" }
    $changed = $false
    try {
        $guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        $dup  = powercfg /duplicatescheme $guid 2>$null
        if ($LASTEXITCODE -eq 0) {
            $newGuid = ($dup | Select-String '[0-9a-f]{8}-[0-9a-f]{4}').Matches[0].Value
            powercfg /setactive $newGuid 2>$null | Out-Null
        } else {
            powercfg /setactive $guid 2>$null | Out-Null
        }
        $changed = $true; $ctr.Changes++
    } catch { $ctr.Success = $false; $logs.Add("ERR UltimatePower : $_") }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $changed) `
        -PayloadName $PayloadName -ProviderKey 'UltimatePowerPlan' -Type 'A' -IsIRR $false `
        -Data @{
            OldPlanGuid  = if ($oldPlanGuid) { $oldPlanGuid } else { '381b4222-f694-41f0-9685-ff5bb260df2e' }
            GuidCaptured = ($null -ne $oldPlanGuid)
        }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadNvidiaOptimize {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($r in $data.Entries) {
            try {
                if ($null -eq $r.Before) {
                    Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction Stop
                } else {
                    Set-ItemProperty -Path $r.Path -Name $r.Name -Value $r.Before -Type $r.Type -Force -ErrorAction Stop
                }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR Nvidia $($r.Name): $_" }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $logs.Add('NVIDIA Aplicando tweaks PowerMizer')
    if ($script:ctx.Runtime.IsDryRun) { return Complete-ProviderContract $ctr }
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    try {
        $nvidiaBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        $subkeys = Get-ChildItem $nvidiaBase -ErrorAction Stop | Where-Object { $_.PSChildName -match '^\d+$' }
        foreach ($sk in $subkeys) {
            $provider = (Get-ItemProperty $sk.PSPath -Name ProviderName -ErrorAction SilentlyContinue).ProviderName
            if ($provider -notmatch 'NVIDIA') { continue }
            foreach ($t in $Payload.NvidiaOptimizeTemplate) {
                $before = Get-RegistrySnapshot -Path $sk.PSPath -Name $t.Name -Label "NvidiaOpt $($sk.PSPath)"
                Set-ItemProperty -Path $sk.PSPath -Name $t.Name -Value $t.TargetValue -Type $t.Type -Force -ErrorAction SilentlyContinue
                $rbEntries.Add(@{ Path = $sk.PSPath; Name = $t.Name; Type = $t.Type; Before = $before })
            $ctr.Changes++
            }
        }
    } catch { $ctr.Success = $false; $logs.Add("ERR NvidiaOptimize : $($_.Exception.Message)") }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'NvidiaOptimizeTemplate' -Type 'A' -IsIRR $false -Data @{ Entries = $rbEntries.ToArray() }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadTimerResolution {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        foreach ($b in $data.Entries) {
            try {
                if ($b.IsNew) {
                    bcdedit /deletevalue '{current}' $b.Setting 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "bcdedit deletevalue salio con $LASTEXITCODE" }
                } else {
                    if ($null -eq $b.OldValue) { throw "OldValue nulo para $($b.Setting)" }
                    bcdedit /set '{current}' $b.Setting $b.OldValue 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "bcdedit set salio con $LASTEXITCODE" }
                }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR TimerRes $($b.Setting): $_" }
        }
        return @{ Success = $allOk }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $val = $Payload.TimerResConfig.TargetValue
    $logs.Add("TIMER bcdedit disabledynamictick $val")
    if ($script:ctx.Runtime.IsDryRun) { return Complete-ProviderContract $ctr }
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    try {
        $enumOut = bcdedit /enum current 2>$null
        foreach ($setting in @('useplatformtick', 'disabledynamictick')) {
            $existingLine = $enumOut | Select-String $setting
            $isNew  = (-not $existingLine)
            $oldVal = $null
            if (-not $isNew) { $oldVal = ($existingLine.Line -split '\s+', 2)[1].Trim() }
            if ($setting -eq 'disabledynamictick') {
                bcdedit /set '{current}' $setting $val 2>$null | Out-Null
            } else {
                $ptVal = if ($val -eq 'yes') { 'no' } else { 'yes' }
                bcdedit /set '{current}' $setting $ptVal 2>$null | Out-Null
            }
            $rbEntries.Add(@{ Setting = $setting; IsNew = $isNew; OldValue = $oldVal })
        }
    } catch { $ctr.Success = $false; $logs.Add("ERR TimerResolution : $($_.Exception.Message)") }
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) `
        -PayloadName $PayloadName -ProviderKey 'TimerResConfig' -Type 'A' -IsIRR $false -Data @{ Entries = $rbEntries.ToArray() }
    if ($rbEntries.Count -gt $ctr.Changes) { $ctr.Changes = $rbEntries.Count }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadUSBStorage {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        try {
            if ($null -eq $data.OldStart) { throw "OldStart es null" }
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' `
                -Name Start -Value $data.OldStart -Type DWord -Force -ErrorAction Stop
            Write-QLog "[ROLLBACK]   USBSTOR Start restaurado a $($data.OldStart)"
            $handledOk_ok = $true
        } catch { Write-QLog "[ROLLBACK]   ERR USBStorage: $_"; $handledOk_ok = $false }
        return @{ Success = ($handledOk_ok -eq $true) }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $svcPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR'
    $startRaw = $null
    try { $startRaw = (Get-ItemProperty $svcPath -Name Start -ErrorAction Stop).Start } catch {}
    if ($null -eq $startRaw) { $logs.Add('SKIP USBStorage -- clave USBSTOR no encontrada'); return }
    if ($script:ctx.Runtime.IsDryRun) {
        $logs.Add("DRY USBStorage -- Start actual=$startRaw. Toggle 3=enabled, 4=disabled")
        return Complete-ProviderContract $ctr
    }
    if ($startRaw -eq 2) {
        $logs.Add('WARN Start=2 enterprise. Requiere confirmacion explicita.')
        $r = [System.Windows.MessageBox]::Show(
            "USBSTOR Start=2 detectado (configuracion enterprise/especial).`nModificar de todas formas?",
            'Manolito Engine', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($r -ne 'Yes') { $logs.Add('SKIP USB cancelado'); return }
    }
    $newVal = if ($startRaw -eq 4) { 3 } else { 4 }
    $state  = if ($newVal -eq 4) { 'DISABLED' } else { 'ENABLED' }
    Set-ItemProperty -Path $svcPath -Name Start -Value $newVal -Type DWord -Force
    $ctr.Changes++
    $logs.Add("USB Start $startRaw -> $newVal ($state)")
    if ($newVal -eq 4) { $logs.Add('INFO Unidades USB montadas permanecen hasta desconexion fisica') }
    $logs.Add('INFO Solo afecta almacenamiento masivo (USBSTOR). HID y audio no modificados.')
    Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) `
        -PayloadName $PayloadName -ProviderKey 'USBStorageTemplate' -Type 'A' -IsIRR $false -Data @{ OldStart = $startRaw }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadNVMeProtect {
    param($Payload, [string]$PayloadName, [switch]$IsRollback)
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $caps = $script:SystemCaps
    $logs.Add("NVMe Driver: $($caps.NVMeDriverName)")
    if ($caps.NVMeDriverIsOEM) {
        $logs.Add('NVMe Driver OEM detectado - OK')
    } else {
        $logs.Add('WARN Driver generico Microsoft stornvme.sys. Considera instalar driver OEM.')
    }
    $logs.Add('NVMe KBs de referencia: KB5034441, KB5028185')
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadACL {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $allOk = $true
        $aclPath = $data.Path
        $origSddl = $data.OriginalAclSddl
        if ([string]::IsNullOrEmpty($aclPath)) {
            Write-QLog "[ROLLBACK]   ERR ACL: Path nulo en RollbackEntry"
            return @{ Success = $false; PendingAction = "restaurar ACL manualmente: Path nulo" }
        } elseif ([string]::IsNullOrEmpty($origSddl)) {
            Write-QLog "[ROLLBACK]   ERR ACL: OriginalAclSddl nulo -- sin backup restaurable"
            return @{ Success = $false; PendingAction = "restaurar ACL en ${aclPath}: sin SDDL backup" }
        } elseif (-not (Test-Path $aclPath)) {
            Write-QLog "[ROLLBACK]   ERR ACL: Path no existe en rollback: $aclPath"
            return @{ Success = $false; PendingAction = "restaurar ACL en ${aclPath}: ruta no existe" }
        }
        try {
            $restoredAcl = Get-Acl -Path $aclPath -ErrorAction Stop
            $restoredAcl.SetSecurityDescriptorSddlForm($origSddl)
            Set-Acl -Path $aclPath -AclObject $restoredAcl -ErrorAction Stop
            $postAcl = Get-Acl -Path $aclPath -ErrorAction Stop
            if ($postAcl.Sddl -ne $origSddl) {
                Write-QLog "[ROLLBACK]   WARN ACL: SDDL post-restore difiere del original"
            } else {
                Write-QLog "[ROLLBACK]   OK ACL restaurada: $aclPath"
            }
            return @{ Success = $true }
        } catch {
            Write-QLog "[ROLLBACK]   ERR ACL Set-Acl fallo: $_"
            return @{ Success = $false; PendingAction = "restaurar ACL en $aclPath desde SDDL backup" }
        }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    $entries = @()
    if ($Payload.PSObject.Properties['_AclSteps']) {
        $entries = @($Payload._AclSteps)
    } elseif ($Payload.PSObject.Properties['ACL']) {
        $raw = $Payload.ACL
        $entries = if ($raw -is [array]) { $raw } else { @($raw) }
    }
    if ($entries.Count -eq 0) {
        $logs.Add('    [SKIP] ACL: sin entradas definidas')
        return Complete-ProviderContract $ctr
    }
    foreach ($entry in $entries) {
        $path       = $entry.Path
        $action     = $entry.Action
        $principal  = $entry.Principal
        $rights     = $entry.Rights
        $acType     = if ($entry.PSObject.Properties['AccessControlType']) { $entry.AccessControlType } else { 'Allow' }
        $inherit    = if ($entry.PSObject.Properties['InheritanceFlags'])  { $entry.InheritanceFlags  } else { 'None'  }
        $propagate  = if ($entry.PSObject.Properties['PropagationFlags'])  { $entry.PropagationFlags  } else { 'None'  }
        $reqBackup  = if ($entry.PSObject.Properties['RequireBackup'])     { [bool]$entry.RequireBackup } else { $true }
        $allowMiss  = if ($entry.PSObject.Properties['AllowIfMissing'])    { [bool]$entry.AllowIfMissing } else { $false }
        $critical   = if ($entry.PSObject.Properties['PreserveCriticalPrincipals']) {
                          @($entry.PreserveCriticalPrincipals)
                      } else {
                          @('NT AUTHORITY\SYSTEM','BUILTIN\Administrators','NT SERVICE\TrustedInstaller')
                      }
        $label = "ACL [$action] $path / $principal / $rights"
        $logs.Add("    > $label")
        $entryChanged = $false
        if ($action -eq 'CheckOnly') {
            $exists = Test-Path $path
            $logs.Add("      [CHECK] Path existe: $exists")
            continue
        }
        if (-not (Test-Path $path)) {
            if ($allowMiss) {
                $logs.Add("      [SKIP] Path no existe (AllowIfMissing=true): $path")
                continue
            }
            $ctr.Success = $false
            $logs.Add("      [ERR] Path no existe: $path")
            if (-not $script:ctx.Runtime.ContinueOnError) { break }
            continue
        }
        if ($script:ctx.Runtime.IsDryRun) {
            $logs.Add("      [DRY] Accion prevista: $action | Principal: $principal | Rights: $rights | ACType: $acType")
            continue
        }
        if ($script:ctx.Runtime.IsRollback -or $script:ctx.Runtime.IsManifestRestore) {
            $logs.Add("      [SKIP] ACL omitida en modo rollback/restore")
            continue
        }
        $originalAcl  = $null
        $originalSddl = $null
        $backupOk     = $false
        try {
            $originalAcl  = Get-Acl -Path $path -ErrorAction Stop
            $originalSddl = $originalAcl.Sddl
            $backupOk     = $true
            $logs.Add("      [ACL] Backup capturado. SDDL length: $($originalSddl.Length)")
        } catch {
            $ctr.Success = $false
            $logs.Add("      [ERR] No se pudo capturar ACL original: $_")
            if ($reqBackup) {
                $logs.Add("      [FAIL] RequireBackup=true -- abortando entrada ACL")
                if (-not $script:ctx.Runtime.ContinueOnError) { break }
                continue
            }
        }
        if ($reqBackup -and -not $backupOk) {
            $ctr.Success = $false
            $logs.Add("      [FAIL] Sin backup ACL valido -- operacion cancelada: $path")
            if (-not $script:ctx.Runtime.ContinueOnError) { break }
            continue
        }
        try {
            $identityRef = New-Object System.Security.Principal.NTAccount($principal)
            $fileRights  = [System.Security.AccessControl.FileSystemRights]$rights
            $inhFlags    = [System.Security.AccessControl.InheritanceFlags]$inherit
            $propFlags   = [System.Security.AccessControl.PropagationFlags]$propagate
            $acTypeEnum  = [System.Security.AccessControl.AccessControlType]$acType
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $identityRef, $fileRights, $inhFlags, $propFlags, $acTypeEnum
            )
        } catch {
            $ctr.Success = $false
            $logs.Add("      [ERR] No se pudo construir la regla ACL: $_")
            if (-not $script:ctx.Runtime.ContinueOnError) { break }
            continue
        }
        $criticalViolation = $false
        foreach ($cp in $critical) {
            $existingRules = $originalAcl.Access | Where-Object { $_.IdentityReference.Value -eq $cp }
            if ($action -in @('RemoveRule','SetRule') -and $cp -eq $principal) {
                $criticalViolation = $true
                $logs.Add("      [ERR] Intento de modificar principal critico: $cp")
            }
        }
        if ($criticalViolation) {
            $ctr.Success = $false
            if (-not $script:ctx.Runtime.ContinueOnError) { break }
            continue
        }
        try {
            $newAcl     = Get-Acl -Path $path -ErrorAction Stop
            $beforeSddl = $newAcl.Sddl
            $ruleApplied = $false
            switch ($action) {
                'AddRule'    { $newAcl.AddAccessRule($rule); $ruleApplied = $true }
                'RemoveRule' {
                    $ruleApplied = $newAcl.RemoveAccessRule($rule)
                    if (-not $ruleApplied) {
                        $logs.Add("      [NOCHANGE] RemoveRule: regla no encontrada o no coincide exactamente -- sin cambio")
                        continue
                    }
                }
                'SetRule'    { $newAcl.SetAccessRule($rule); $ruleApplied = $true }
                default {
                    $ctr.Success = $false
                    $logs.Add("      [ERR] Accion ACL no reconocida: $action")
                    continue
                }
            }
            Set-Acl -Path $path -AclObject $newAcl -ErrorAction Stop
            $verifyAcl  = Get-Acl -Path $path -ErrorAction Stop
            $afterSddl  = $verifyAcl.Sddl
            if ($afterSddl -eq $beforeSddl) {
                $logs.Add("      [NOCHANGE] SDDL identico pre/post Set-Acl -- no se cuenta como cambio")
            } else {
                $ctr.Changes++
                $entryChanged = $true
                $logs.Add("      [OK] ACL aplicada: $action en $path")
                $logs.Add("      [VERIFY] SDDL pre-length=$($beforeSddl.Length) post-length=$($afterSddl.Length)")
            }
        } catch {
            $ctr.Success = $false
            $logs.Add("      [ERR] Set-Acl fallo: $_")
            if (-not $script:ctx.Runtime.ContinueOnError) { break }
            continue
        }
        if ($backupOk -and $entryChanged -and
            -not $script:ctx.Runtime.IsRollback -and
            -not $script:ctx.Runtime.IsManifestRestore) {
            $rbEntries.Add(@{
                Step            = "ACL.$action"
                Path            = $path
                Principal       = $principal
                Rights          = $rights
                Action          = $action
                OriginalAclSddl = $originalSddl
                Timestamp       = [DateTime]::UtcNow.ToString('o')
            })
        }
    }
    foreach ($rb in $rbEntries) {
        Push-RollbackEntry -Condition $true -PayloadName $PayloadName -ProviderKey 'ACL' -Type 'A' -IsIRR $false -Data $rb
    }
    return Complete-ProviderContract $ctr
}
function Invoke-PayloadBlueHammer {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)
    if ($IsRollback) {
        $defVer = ''
        try {
            $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
            if ($mpStatus) { $defVer = $mpStatus.AMProductVersion }
        } catch {}
        if ($defVer) {
            $script:ctx.LogQueue.Enqueue("LOG:[BlueHammer] Defender version pre-rollback: $defVer")
            $verParts = $defVer -split '\.'
            if ($verParts.Count -ge 3 -and [int]($verParts[1]) -ge 18 -and [int]($verParts[2]) -ge 24) {
                $script:ctx.LogQueue.Enqueue("LOG:[BlueHammer] WARN Defender $defVer puede re-aplicar ACLs tras rollback -- reinicio recomendado")
            }
        }
        $data  = $RollbackEntry.Data
        $pkey = $RollbackEntry.ProviderKey
        switch ($pkey) {
            'BlueHammer.Defender' {
                $allOk = $true
                $rPath = $data.Path; $rName = $data.Name; $rOld = $data.OldValue
                if ([string]::IsNullOrEmpty($rPath) -or [string]::IsNullOrEmpty($rName)) {
                    Write-QLog "[ROLLBACK]   ERR BlueHammer.Defender: Path/Name nulo"
                    $allOk = $false
                } elseif ($null -eq $rOld) {
                    try {
                        Remove-ItemProperty -Path $rPath -Name $rName -ErrorAction Stop
                        Write-QLog "[ROLLBACK]   OK BlueHammer.Defender REG eliminado: $rName"
                    } catch { Write-QLog "[ROLLBACK]   ERR BlueHammer.Defender Remove: $_"; $allOk = $false }
                } else {
                    try {
                        Set-ItemProperty -Path $rPath -Name $rName -Value $rOld -Type $data.Type -ErrorAction Stop
                        Write-QLog "[ROLLBACK]   OK BlueHammer.Defender REG restaurado: $rName = $rOld"
                    } catch { Write-QLog "[ROLLBACK]   ERR BlueHammer.Defender Set: $_"; $allOk = $false }
                }
                if (-not $allOk) {
                    $pending_action_rb = "restaurar REG $rPath\$rName a valor anterior"
                }
            }
            'BlueHammer.Task0300' {
                $allOk = $true
                $tName = $data.Name; $tPath = $data.Path; $wasEn = $data.WasEnabled
                if ([string]::IsNullOrEmpty($tName)) {
                    Write-QLog "[ROLLBACK]   ERR BlueHammer.Task0300: TaskName nulo"
                    $allOk = $false
                } else {
                    try {
                        if ($wasEn) {
                            Enable-ScheduledTask  -TaskName $tName -TaskPath $tPath -ErrorAction Stop | Out-Null
                            Write-QLog "[ROLLBACK]   OK BlueHammer.Task0300 habilitada: $tPath$tName"
                        } else {
                            Disable-ScheduledTask -TaskName $tName -TaskPath $tPath -ErrorAction Stop | Out-Null
                            Write-QLog "[ROLLBACK]   OK BlueHammer.Task0300 deshabilitada: $tPath$tName"
                        }
                    } catch { Write-QLog "[ROLLBACK]   ERR BlueHammer.Task0300: $_"; $allOk = $false }
                }
                if (-not $allOk) {
                    $pending_action_rb = "restaurar tarea $tPath$tName a WasEnabled=$wasEn"
                }
            }
            'BlueHammer.VSS' {
                Write-QLog "[ROLLBACK]   INFO BlueHammer.VSS: sin rollback automatico"
                $instr = if ($data.RestoreInstructions) { $data.RestoreInstructions } else { "Revisar servicio VSS manualmente" }
                $pending_action_rb = $instr
                $allOk = $false   # VSS siempre requiere accion manual
            }
        }
        if ($allOk -eq $false -and $pending_action_rb) {
            return @{ Success = $false; PendingAction = $pending_action_rb }
        }
        return @{ Success = ($null -eq $allOk -or $allOk) }
    }
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    $bhCfg = if ($Payload.PSObject.Properties['BlueHammer']) { $Payload.BlueHammer } else { $null }
    if (-not $bhCfg -or -not $bhCfg.Enabled) {
        $logs.Add('    [SKIP] BlueHammer: no configurado o deshabilitado en WAD')
        return Complete-ProviderContract $ctr
    }
    $continueOnErr = if ($bhCfg.PSObject.Properties['ContinueOnError']) { [bool]$bhCfg.ContinueOnError } else { $false }
    $steps = @($bhCfg.Steps | Where-Object { $_.Enabled })
    $logs.Add("    > BlueHammer: $($steps.Count) pasos habilitados")
    foreach ($step in $steps) {
        $sName = $step.Name
        $logs.Add("    [BLUEHAMMER][$sName] Iniciando...")
        if ($sName -eq 'Defender') {
            $regs = @($step.Registry)
            if ($regs.Count -eq 0) {
                $logs.Add("      [SKIP] Defender: sin entradas Registry definidas")
                continue
            }
            if ($script:ctx.Runtime.IsDryRun) {
                foreach ($r in $regs) {
                    $logs.Add("      [DRY] Defender REG: $($r.Path) | $($r.Name) -> $($r.TargetValue)")
                }
                continue
            }
            $defOk = $true
            foreach ($r in $regs) {
                $before = Get-RegistrySnapshot -Path $r.Path -Name $r.Name -Label "BlueHammer Registry"
                try {
                    if (-not (Test-Path $r.Path)) {
                        New-Item -Path $r.Path -Force -ErrorAction Stop | Out-Null
                    }
                    Set-ItemProperty -Path $r.Path -Name $r.Name -Value $r.TargetValue -Type $r.Type -ErrorAction Stop
                    $ctr.Changes++
                    $logs.Add("      [OK] Defender REG $($r.Name): $before -> $($r.TargetValue)")
                    if (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) {
                        $rbEntries.Add(@{
                            PayloadName = $PayloadName; ProviderKey = 'BlueHammer.Defender'; Type = 'A'; IsIRR = $false
                            Data = @{ Path = $r.Path; Name = $r.Name; OldValue = $before; NewValue = $r.TargetValue
                                      Type = $r.Type; Step = 'BlueHammer.Defender' }
                        })
                    }
                } catch {
                    $ctr.Success = $false; $defOk = $false
                    $logs.Add("      [ERR] Defender REG $($r.Name) : $_")
                }
            }
            if (-not $defOk -and -not $continueOnErr) { break }
        }
        elseif ($sName -eq 'Task0300') {
            $tName  = $step.TaskName
            $tPath  = $step.TaskPath
            $tState = $step.TargetState
            $skipMiss = if ($step.PSObject.Properties['SkipIfMissing']) { [bool]$step.SkipIfMissing } else { $true }
            $logs.Add("      Task: $tPath$tName -> $tState")
            if ($script:ctx.Runtime.IsDryRun) {
                $logs.Add("      [DRY] Task0300: $tPath$tName TargetState=$tState")
                continue
            }
            $task = $null
            try {
                $task = Get-ScheduledTask -TaskName $tName -TaskPath $tPath -ErrorAction Stop
            } catch { Write-QLog "[WARN] Get-ScheduledTask fallo ($tPath$tName): $($_.Exception.Message)" }
            if (-not $task) {
                if ($skipMiss) {
                    $logs.Add("      [SKIP] Task no encontrada (SkipIfMissing=true): $tPath$tName")
                } else {
                    $ctr.Success = $false
                    $logs.Add("      [ERR] Task no encontrada y SkipIfMissing=false: $tPath$tName")
                    if (-not $continueOnErr) { break }
                }
                continue
            }
            $wasEnabled = ($task.State -ne 'Disabled')
            $logs.Add("      WasEnabled=$wasEnabled State=$($task.State)")
            $alreadyDone = ($tState -eq 'Disable' -and $task.State -eq 'Disabled') -or
                           ($tState -eq 'Enable'  -and $task.State -ne 'Disabled')
            if ($alreadyDone) {
                $logs.Add("      [NOCHANGE] Task ya en estado objetivo")
                continue
            }
            try {
                if ($tState -eq 'Disable') {
                    Disable-ScheduledTask -TaskName $tName -TaskPath $tPath -ErrorAction Stop | Out-Null
                } else {
                    Enable-ScheduledTask  -TaskName $tName -TaskPath $tPath -ErrorAction Stop | Out-Null
                }
                $ctr.Changes++
                $logs.Add("      [OK] Task0300 $tState aplicado")
                if (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) {
                    $rbEntries.Add(@{
                        PayloadName = $PayloadName; ProviderKey = 'BlueHammer.Task0300'; Type = 'A'; IsIRR = $false
                        Data = @{ Name = $tName; Path = $tPath; WasEnabled = $wasEnabled
                                  TargetState = $tState; Step = 'BlueHammer.Task0300' }
                    })
                }
            } catch {
                $ctr.Success = $false
                $logs.Add("      [ERR] Task0300 fallo: $_")
                if (-not $continueOnErr) { break }
            }
        }
        elseif ($sName -eq 'VSS') {
            $action   = $step.Action
            $svcName  = if ($step.PSObject.Properties['ServiceName']) { $step.ServiceName } else { 'VSS' }
            $logs.Add("      VSS Action=$action Service=$svcName")
            if ($script:ctx.Runtime.IsDryRun) {
                $logs.Add("      [DRY] VSS: accion prevista=$action en servicio $svcName")
                continue
            }
            $svc = $null
            try { $svc = Get-Service -Name $svcName -ErrorAction Stop } catch { Write-QLog "[WARN] Get-Service ($svcName) fallo: $($_.Exception.Message)"; continue }
            if (-not $svc) {
                $logs.Add("      [WARN] VSS servicio no encontrado: $svcName")
                continue
            }
            $prevState = $svc.Status.ToString()
            $logs.Add("      [CHECK] VSS estado actual: $prevState")
            if ($action -eq 'CheckAndEnsureRunning') {
                if ($prevState -notin @('Running','Stopped')) {
                    $logs.Add("      [WARN] VSS estado inusual: $prevState -- revisar manualmente")
                } else {
                    $logs.Add("      [OK] VSS disponible: $prevState")
                }
                if ($prevState -notin @('Running','Stopped') -and
                    -not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) {
                    $rbEntries.Add(@{
                        PayloadName = $PayloadName; ProviderKey = 'BlueHammer.VSS'; Type = 'B'; IsIRR = $false
                        Data = @{ Step = 'BlueHammer.VSS'; ServiceName = $svcName; PreviousState = $prevState
                                  RestoreInstructions = "Revisar estado del servicio VSS manualmente: sc.exe start VSS" }
                    })
                }
                continue
            }
            $logs.Add("      [WARN] Accion VSS '$action' no implementada -- solo CheckAndEnsureRunning soportado")
        }
        elseif ($sName -eq 'ACL') {
            $rawPath = $step.Path
            $resolvMode = if ($step.PSObject.Properties['ResolvePath']) { $step.ResolvePath } else { '' }
            $targetFile = if ($step.PSObject.Properties['TargetFile'])  { $step.TargetFile  } else { '' }
            $resolvedPath = $rawPath
            if ($resolvMode -eq 'WDPlatformLatest' -and $targetFile) {
                $platformBase = [System.Environment]::ExpandEnvironmentVariables($rawPath)
                if (Test-Path $platformBase) {
                    $latest = Get-ChildItem -Path $platformBase -Directory -ErrorAction SilentlyContinue |
                              Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
                    if ($latest) {
                        $resolvedPath = Join-Path $latest.FullName $targetFile
                        $logs.Add("      [ACL] Path resuelto: $resolvedPath")
                    } else {
                        if (-not $step.AllowIfMissing) {
                            $ctr.Success = $false
                            $logs.Add("      [ERR] No se encontro ninguna version en Platform: $platformBase")
                            if (-not $continueOnErr) { break }
                        } else {
                            $logs.Add("      [SKIP] WD Platform dir no encontrado (AllowIfMissing=true)")
                        }
                        continue
                    }
                } else {
                    if (-not $step.AllowIfMissing) {
                        $ctr.Success = $false
                        $logs.Add("      [ERR] Base path no existe: $platformBase")
                        if (-not $continueOnErr) { break }
                    } else {
                        $logs.Add("      [SKIP] Base path inexistente (AllowIfMissing=true)")
                    }
                    continue
                }
            }
            $aclStep = [PSCustomObject]@{
                Path                      = $resolvedPath
                Action                    = $step.Action
                Principal                 = $step.Principal
                Rights                    = $step.Rights
                AccessControlType         = if ($step.PSObject.Properties['AccessControlType']) { $step.AccessControlType } else { 'Allow' }
                InheritanceFlags          = if ($step.PSObject.Properties['InheritanceFlags'])  { $step.InheritanceFlags  } else { 'None' }
                PropagationFlags          = if ($step.PSObject.Properties['PropagationFlags'])  { $step.PropagationFlags  } else { 'None' }
                RequireBackup             = if ($step.PSObject.Properties['RequireBackup'])     { $step.RequireBackup     } else { $true }
                AllowIfMissing            = if ($step.PSObject.Properties['AllowIfMissing'])    { $step.AllowIfMissing    } else { $false }
                PreserveCriticalPrincipals = if ($step.PSObject.Properties['PreserveCriticalPrincipals']) {
                                                $step.PreserveCriticalPrincipals
                                            } else {
                                                @('NT AUTHORITY\SYSTEM','BUILTIN\Administrators','NT SERVICE\TrustedInstaller')
                                            }
            }
            $aclPayload = [PSCustomObject]@{ _AclSteps = @($aclStep) }
            $aclResult = Invoke-PayloadACL -Payload $aclPayload -PayloadName $PayloadName
            if ($aclResult.Logs) { $logs.AddRange([string[]]$aclResult.Logs) }
            if ($null -ne $aclResult.Changes) { $ctr.Changes += [int]$aclResult.Changes }
            if ($aclResult.PSObject.Properties['Success'] -and -not $aclResult.Success) {
                $ctr.Success = $false
                if (-not $continueOnErr) { break }
            }
        }
        else {
            $logs.Add("    [WARN] Paso BlueHammer no reconocido: $sName")
        }
    }
    if ($rbEntries.Count -gt 0 -and
        -not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) {
        foreach ($rb in $rbEntries) {
            $script:ctx.Tracking.RollbackStack.Push($rb)
        }
    }
    return Complete-ProviderContract $ctr
}
function Invoke-Payload {
    param([string]$PayloadName)
    $payload = $script:PayloadMap[$PayloadName]
    if (-not $payload) {
        return @{ Success = $false; Changes = 0; Logs = @("[FAIL] Payload '$PayloadName' no encontrado") }
    }
    $meta = $payload._meta
    $guardResult = Test-PayloadGuards -Payload $payload -PayloadName $PayloadName
    if (-not $guardResult.Pass) {
        $script:ctx.LogQueue.Enqueue("LOG:$($guardResult.Reason)")
        return @{ Success = $true; Skipped = $true; Changes = 0; Logs = @($guardResult.Reason) }
    }
    if (-not $meta.Reversible -and $script:ctx.Runtime.IsRollback) {
        return @{ Success = $true; Skipped = $true; Changes = 0; Logs = @("    [SKIP] $($meta.Label) (No reversible)") }
    }
    if ($meta.DynamicToggle -eq 'OwnedOnly' -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore) {
        if (-not (Test-ManolitoOwnership -PayloadName $PayloadName)) {
            return @{ Success = $true; Skipped = $true; Changes = 0;
                Logs = @("    [SKIP-OWNED] $($meta.Label) -- DynamicToggle=OwnedOnly y no hay registro de aplicacion previa por Manolito") }
        }
    }
    if ($meta.PSObject.Properties['RequiresReboot'] -and $meta.RequiresReboot -and
        -not $script:ctx.Runtime.IsDryRun) {
        $script:ctx.State.PendingReboot = $true
    }
    if (-not $meta.Reversible -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Tracking.IrreversibleActions.Contains($PayloadName)) {
        $script:ctx.Tracking.IrreversibleActions.Add($PayloadName)
    }
    $moduleResult = @{
        Name    = $PayloadName
        Success = $true
        Changes = 0
        Logs    = [System.Collections.Generic.List[string]]::new()
    }
    $moduleResult.Logs.Add("> Ejecutando: $($meta.Label)...")
    if ($script:SystemCaps.HasBattery -and $PayloadName -eq 'PowerTuning') {
        $moduleResult.Logs.Add("    [WARN] PowerTuning en portatil -- puede afectar bateria.")
    }
    $byNameKey = "_name_$PayloadName"
    if ($script:ProviderMap.Contains($byNameKey)) {
        $handlerName = $script:ProviderMap[$byNameKey]
        $cmd = Get-Command $handlerName -CommandType Function -ErrorAction SilentlyContinue
        if (-not $cmd) {
            $moduleResult.Logs.Add("[FAIL] Handler no encontrado en runspace: $handlerName")
            $moduleResult.Success = $false
        } else {
            $res = & $cmd.Name -Payload $payload -PayloadName $PayloadName -IsRollback:$script:ctx.Runtime.IsRollback
            if ($res) {
                if ($null -ne $res.Changes) { $moduleResult.Changes += [int]$res.Changes }
                if ($res.Logs)              { $moduleResult.Logs.AddRange([string[]]$res.Logs) }
                if ($res.PSObject.Properties['Success'] -and -not $res.Success) { $moduleResult.Success = $false }
            }
        }
    } else {
        $providerKeys = if ($script:PayloadProviderPlan -and $script:PayloadProviderPlan.ContainsKey($PayloadName)) {
            $script:PayloadProviderPlan[$PayloadName].Providers
        } else {
            @($script:ProviderMap.Keys | Where-Object { -not $_.StartsWith('_name_') -and $payload.PSObject.Properties[$_] })
        }
        foreach ($propKey in $providerKeys) {
            if ($propKey -eq 'WingetPackages' -and -not $script:SystemCaps.CanUseWinget) {
                $moduleResult.Logs.Add("    [SKIP] WingetPackages -- Winget no disponible")
                continue
            }
            $handlerName = $script:ProviderMap[$propKey]
            $cmd = Get-Command $handlerName -CommandType Function -ErrorAction SilentlyContinue
            if (-not $cmd) {
                $moduleResult.Logs.Add("[FAIL] Handler no encontrado en runspace: $handlerName")
                $moduleResult.Success = $false
                continue
            }
            $res = & $cmd.Name -Payload $payload -PayloadName $PayloadName -IsRollback:$script:ctx.Runtime.IsRollback
            if ($res) {
                if ($null -ne $res.Changes) { $moduleResult.Changes += [int]$res.Changes }
                if ($res.Logs)              { $moduleResult.Logs.AddRange([string[]]$res.Logs) }
                if ($res.PSObject.Properties['Success'] -and -not $res.Success) { $moduleResult.Success = $false }
            }
        }
    }
    if ($moduleResult.Success) {
        $script:ctx.State.StepsOk++
        $script:ctx.LogQueue.Enqueue("COUNT:$($script:ctx.State.StepsOk)")
        $moduleResult.Status = 'OK'
    } else {
        $script:ctx.State.StepsFail++
        $moduleResult.Status = 'FAIL'
    }
    $script:ctx.Results.Modules.Add($moduleResult)
    return $moduleResult
}
function ConvertTo-NativeHashtable {
    param($obj, [int]$Depth = 0, [int]$MaxDepth = 10)
    if ($null -eq $obj -or $Depth -ge $MaxDepth) { return $obj }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        foreach ($p in $obj.PSObject.Properties) {
            $ht[$p.Name] = ConvertTo-NativeHashtable -obj $p.Value -Depth ($Depth+1) -MaxDepth $MaxDepth
        }
        return $ht
    }
    if ($obj -is [System.Array] -or $obj -is [System.Collections.IList]) {
        return @($obj | ForEach-Object { ConvertTo-NativeHashtable -obj $_ -Depth ($Depth+1) -MaxDepth $MaxDepth })
    }
    return $obj
}
function Import-ManifestToContext {
    param([object]$ManifestData)
    $m = $ManifestData
    if (-not $m) { return @() }
    if ($m.PSObject.Properties['EngineVersion'] -and $m.EngineVersion) {
        $mMM = ($m.EngineVersion -split '\.')[0..1] -join '.'
        $eMM = ($script:ctx.Config.Manifest.Version -split '\.')[0..1] -join '.'
        if ($mMM -ne $eMM) {
            Write-QLog "[WARN] Manifest v$($m.EngineVersion) vs motor v$($script:ctx.Config.Manifest.Version) -- restauracion puede ser incompleta."
        }
    }
    $script:ctx.Tracking.Backups.ServicesStartup = ConvertTo-NativeHashtable $m.BackupServicesState
    $script:ctx.Tracking.Backups.TasksState      = ConvertTo-NativeHashtable $m.BackupTasksState
    $script:ctx.Tracking.Backups.DNS             = ConvertTo-NativeHashtable $m.BackupDNS
    $script:ctx.Tracking.Backups.BCD             = ConvertTo-NativeHashtable $m.BackupBCD
    $script:ctx.Tracking.Backups.ActiveSetup     = ConvertTo-NativeHashtable $m.BackupActiveSetup
    $script:ctx.Tracking.Backups.WindowsFeatures = ConvertTo-NativeHashtable $m.BackupWindowsFeatures
    $script:ctx.Tracking.Backups.Hosts           = $m.BackupHosts
    $script:ctx.Tracking.RegDiff.Clear()
    if ($m.RegDiff) { $script:ctx.Tracking.RegDiff.AddRange($m.RegDiff) }
    $script:ctx.Tracking.RollbackStack = [System.Collections.Concurrent.ConcurrentStack[hashtable]]::new()
    if ($m.PSObject.Properties['RollbackStack'] -and $m.RollbackStack) {
        $stackItems = @($m.RollbackStack)
        for ($ri = $stackItems.Count - 1; $ri -ge 0; $ri--) {
            if ($null -ne $stackItems[$ri]) { $script:ctx.Tracking.RollbackStack.Push($stackItems[$ri]) }
        }
    }
    $script:ctx.Runtime.IsRollback        = $true
    $script:ctx.Runtime.IsManifestRestore = $true
    $plan = [System.Collections.Generic.List[string]]::new()
    $candidateSources = @()
    if ($m.Summary.PSObject.Properties['PayloadsExecuted'] -and $m.Summary.PayloadsExecuted) {
        $candidateSources += @($m.Summary.PayloadsExecuted)
    }
    if ($m.PSObject.Properties['AppliedPayloads'] -and $m.AppliedPayloads) {
        $candidateSources += @($m.AppliedPayloads)
    }
    if ($m.PSObject.Properties['RollbackStack'] -and $m.RollbackStack) {
        $candidateSources += @($m.RollbackStack | ForEach-Object { $_.PayloadName } | Where-Object { $_ })
    }
    foreach ($pName in ($candidateSources | Select-Object -Unique)) {
        $prop = $script:PayloadMap[$pName]
        $meta = if ($prop -and $prop._meta) { $prop._meta } else { $null }
        if ($meta -and $meta.Reversible) { $plan.Add($pName) }
    }
    $originalCount = $plan.Count
    $dedupPlan = @($plan | Select-Object -Unique)
    if ($dedupPlan.Count -lt $originalCount) {
        Write-QLog "[WARN] Payloads duplicados en manifest -- deduplicado a $($dedupPlan.Count)."
    }
    Write-QLog "[MANIFEST RESTORE] $($m.Timestamp)  --  Runlevel origen: $($m.Runlevel)"
    $uiItems = [System.Collections.Generic.List[object]]::new()
    foreach ($pName in $dedupPlan) {
        $meta = $script:PayloadMap[$pName]._meta
        if ($meta.PSObject.Properties['DenyOnBattery'] -and $meta.DenyOnBattery -eq $true -and $script:SystemCaps.HasBattery) {
            Write-QLog "[WARN-GUARD] $pName -- DenyOnBattery en portatil, permitido en manifest restore"
        }
        $riskLevel  = if ($meta.PSObject.Properties['RiskLevel']) { [int]$meta.RiskLevel } else { 0 }
        $riskColor  = $script:riskColorMap[[int]$riskLevel]
        $riskTag    = switch ($riskLevel) {
            { $_ -ge 4 } { '[!!!]' }
            { $_ -ge 3 } { '[!]'   }
            { $_ -ge 2 } { '[~]'   }
            default      { '[*]'   }
        }
        $uiItems.Add([PSCustomObject]@{
            Name        = $pName
            Display     = "$riskTag $($meta.Label)  ($pName)"
            IsSelected  = $true
            RiskColor   = $riskColor
            ToggleState = $null
            DynamicToggle = $null
        })
    }
    Write-QLog "[OK]  Manifest cargado -- $($dedupPlan.Count) payloads desde manifest restore"
    return @{ Plan = $dedupPlan; UIItems = $uiItems }
}
function Save-ManifestEntry {
    param([string]$PayloadName)
    $mutex = [System.Threading.Mutex]::new($false, 'Global\ManolitoManifestMutex')
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(3000)
        if (-not $acquired) {
            $script:ctx.LogQueue.Enqueue("LOG:[WARN] Save-ManifestEntry timeout mutex -- entrada $PayloadName puede perderse")
            return
        }
        if (-not (Test-Path $script:MANIFESTDIR)) { New-Item -Path $script:MANIFESTDIR -ItemType Directory -Force | Out-Null }
        $mf = if (Test-Path $script:MANIFESTPATH) { Get-Content $script:MANIFESTPATH -Raw | ConvertFrom-Json }
              else { [PSCustomObject]@{ AppliedPayloads = @() } }
        if ($mf.AppliedPayloads -notcontains $PayloadName) { $mf.AppliedPayloads += $PayloadName }
        $mf | ConvertTo-Json -Depth 5 | Set-Content $script:MANIFESTPATH -Encoding UTF8
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
function Save-FullManifest {
    param([string]$RunlevelName)
    try {
        if (-not (Test-Path $script:MANIFESTDIR)) {
            New-Item -Path $script:MANIFESTDIR -ItemType Directory -Force | Out-Null
        }
        $svcBackup  = @{}
        $taskBackup = @{}
        $dnsBackup  = @{}
        $bcdBackup  = @{}
        $wfBackup   = @{}
        $asBackup   = @{}
        $stackSnap  = [System.Collections.Generic.List[object]]::new()
        $item = $null
        try {
            while ($script:ctx.Tracking.RollbackStack.TryPop([ref]$item)) { $stackSnap.Add($item) }
        } finally {
            if ($stackSnap.Count -gt 0) {
                foreach ($ri in $stackSnap[($stackSnap.Count - 1)..0]) {  # FIX S14-P0b: guard Count=0 evita rango invalido (-1)..0
                    $script:ctx.Tracking.RollbackStack.Push($ri)
                }
            }
        }
        foreach ($entry in $stackSnap) {
            switch ($entry.ProviderKey) {
                'Services'     {
                    foreach ($e in $entry.Data.Entries) {
                        $svcBackup[$e.Name] = @{ StartupType = $e.Before; WasRunning = $e.WasRunning }
                    }
                }
                'Tasks'        {
                    foreach ($e in $entry.Data.Entries) {
                        $key = "$($e.Path)$($e.Name)"
                        $taskBackup[$key] = @{ WasEnabled = $e.WasEnabled }
                    }
                }
                'DNS'          {
                    foreach ($e in $entry.Data.Entries) {
                        $dnsBackup[$e.InterfaceIndex] = $e.Before
                    }
                }
                'BCD'          {
                    foreach ($e in $entry.Data.Entries) {
                        $bcdBackup[$e.Setting] = @{ OldValue = $e.OldValue; IsNew = $e.IsNew }
                    }
                }
                'WindowsFeatures' {
                    if ($entry.Data.Entries) {
                        foreach ($e in $entry.Data.Entries) { $wfBackup[$e.Feature] = $e.PreviousState }
                    }
                }
                'ActiveSetupEntries' {
                    foreach ($e in $entry.Data.Entries) { $asBackup[$e.Path] = $e.KeyData }
                }
            }
        }
        $manifest = [PSCustomObject]@{
            EngineVersion         = $script:ctx.WADData.Manifest.Version
            SchemaVersion         = '2.9.1'
            Timestamp             = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Runlevel              = $RunlevelName
            Summary               = [PSCustomObject]@{
                PayloadsExecuted  = $script:ctx.Tracking.PayloadsExecuted.ToArray()
                StepsOk           = $script:ctx.State.StepsOk
                StepsFail         = $script:ctx.State.StepsFail
                PendingReboot     = $script:ctx.State.PendingReboot
            }
            AppliedPayloads       = $script:ctx.Tracking.AppliedPayloads.ToArray()
            IrreversibleActions   = $script:ctx.Tracking.IrreversibleActions.ToArray()
            BackupServicesState   = $svcBackup
            BackupTasksState      = $taskBackup
            BackupDNS             = $dnsBackup
            BackupBCD             = $bcdBackup
            BackupWindowsFeatures = $wfBackup
            BackupActiveSetup     = $asBackup
            BackupHosts           = $script:ctx.Tracking.Backups.Hosts
            RegDiff               = $script:ctx.Tracking.RegDiff.ToArray()
            RollbackStack         = @($script:ctx.Tracking.RollbackStack.ToArray())  # Validacion de esquema y DAG de dependencias
        }
        $manifestMutex = [System.Threading.Mutex]::new($false, 'Global\ManolitoManifestMutex')
        $manifestAcquired = $false
        try {
            $manifestAcquired = $manifestMutex.WaitOne(5000)
            if (-not $manifestAcquired) {
                Write-QLog "[MANIFEST WARN] Save-FullManifest timeout mutex -- manifest no guardado en este ciclo"
            } else {
                $manifest | ConvertTo-Json -Depth 15 | Set-Content $script:MANIFESTPATH -Encoding UTF8
                Write-QLog "[MANIFEST] Guardado en $script:MANIFESTPATH ($($script:ctx.Tracking.PayloadsExecuted.Count) payloads)"
            }
        } finally {
            if ($manifestAcquired) { $manifestMutex.ReleaseMutex() }
            $manifestMutex.Dispose()
        }
    } catch {
        Write-QLog "[MANIFEST ERR] $($_.Exception.Message)"
    }
}
function Invoke-AuditMode {
    $lines = [System.Collections.Generic.List[string]]::new()
    $caps  = $script:ctx.SystemCaps
    $lines.Add('=== MANOLITO AUDIT REPORT ===')
    $lines.Add("Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("Modo: $(if ($script:ctx.Runtime.IsDryRun) { 'DRY RUN' } else { 'LIVE' })")
    $lines.Add('')
    $lines.Add('[CHECK 1] NVMe Driver')
    if (-not $caps.HasNVMe) {
        $lines.Add('  SIN unidad NVMe detectada')
    } elseif ($caps.NVMeDriverIsOEM) {
        $lines.Add("  OK - Driver OEM: $($caps.NVMeDriverName)")
    } else {
        $lines.Add("  WARN - Driver generico Microsoft (stornvme.sys)")
        $lines.Add("  Recomendacion: instalar driver OEM del fabricante")
        $lines.Add("  KBs de referencia: KB5034441, KB5028185")
    }
    $lines.Add('')
    $lines.Add('[CHECK 2] USB Storage')
    $usbRaw = $caps.USBStorageRawValue
    $usbState = switch ($usbRaw) {
        2       { 'HABILITADO (Start=2 enterprise)' }
        3       { 'HABILITADO (Start=3 default)' }
        4       { 'DESHABILITADO (Start=4)' }
        default { "DESCONOCIDO (Start=$usbRaw)" }
    }
    $usbOwned = Test-ManolitoOwnership -PayloadName 'USBStorageTemplate'
    $lines.Add("  Estado: $usbState")
    $lines.Add("  Gestionado por Manolito: $(if ($usbOwned) { 'SI' } else { 'NO' })")
    $lines.Add('')
    $lines.Add('[CHECK 3] MSI Mode (GPU / NVMe)')
    $msiOwned = Test-ManolitoOwnership -PayloadName 'MSITuning'
    $lines.Add("  CapabilityKey MSIState: $($caps.MSIState)")
    $lines.Add("  Gestionado por Manolito: $(if ($msiOwned) { 'SI' } else { 'NO' })")
    if (-not $msiOwned -and $caps.MSIState -ne 'Unknown') {
        $lines.Add('  INFO: MSI activo por herramienta externa. Manolito puede aplicar su perfil creando backup nuevo.')
    }
    $lines.Add('')
    $lines.Add('[CHECK 4] KBs de riesgo instalados')
    $riskKBs = @()
    try { $riskKBs = $script:ctx.WADData.AuditConfig.RiskKBs } catch {}
    if ($riskKBs.Count -eq 0) {
        $lines.Add('  Sin lista de RiskKBs en AuditConfig')
    } else {
        try {
            $installed = Get-HotFix -ErrorAction Stop | Select-Object -ExpandProperty HotFixID
            foreach ($kb in $riskKBs) {
                $found = $installed -contains $kb
                $lines.Add("  $kb : $(if ($found) { 'INSTALADO - revisar compatibilidad con tweaks' } else { 'no instalado' })")
            }
        } catch {
            $lines.Add("  ERR al consultar hotfixes: $_")
        }
    }
    $lines.Add('')
    $lines.Add('[CHECK 5] Hardware Accelerated GPU Scheduling (HAGS)')
    if (-not $caps.HasHAGS) {
        $lines.Add('  Hardware insuficiente para HAGS (requiere GPU 8GB+ VRAM / driver reciente)')
    } else {
        try {
            $hwsch = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' `
                        -Name HwSchMode -ErrorAction Stop).HwSchMode
            $hagsActive = ($hwsch -eq 2)
            $lines.Add("  HwSchMode=$hwsch : $(if ($hagsActive) { 'ACTIVO' } else { 'INACTIVO' })")
        } catch {
            $lines.Add('  ERR al leer HwSchMode')
        }
    }
    $lines.Add('')
    $lines.Add('[CHECK 6] Proteccion del Sistema (unidad C)')
    try {
        $vss = & vssadmin list shadowstorage /for=C: 2>&1
        $active = ($vss -join '') -match 'Maximum Shadow Copy Storage'
        $lines.Add("  Proteccion Sistema C: $(if ($active) { 'ACTIVA' } else { 'INACTIVA o sin espacio asignado' })")
    } catch {
        $lines.Add("  ERR al consultar VSS: $_")
    }
    $lines.Add('')
    $lines.Add('[CHECK A] Inicio Rapido (FastStartup / HiberbootEnabled)')
    try {
        $hibboot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled
        if ($hibboot -eq 1) {
            $lines.Add('  ACTIVO  -- Puede causar estados inconsistentes en dual-boot. Recomendado: DisableFastStartup.')
        } else {
            $lines.Add('  INACTIVO -- Correcto para dual-boot o configuraciones estrictas.')
        }
    } catch { $lines.Add("  ERR al consultar HiberbootEnabled: $_") }
    $lines.Add('')
    $lines.Add('[CHECK B] HAGS (HwSchMode)')
    try {
        $hagsVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction Stop).HwSchMode
        $hagsStr = if ($hagsVal -eq 2) { 'ACTIVO (valor=2)' } else { "INACTIVO (valor=$hagsVal)" }
        $lines.Add("  $hagsStr -- Requiere GPU con VRAM >= 8 GB para beneficio real.")
    } catch { $lines.Add('  NO CONFIGURADO -- HAGS usa valor por defecto del sistema.') }
    $lines.Add('')
    $lines.Add('[CHECK C] Hibernacion (HibernateEnabled)')
    $hibVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
    if ($null -eq $hibVal) {
        $lines.Add('  NO CONFIGURADO -- Estado por defecto del sistema.')
    } elseif ($hibVal -eq 1) {
        $lines.Add("  ACTIVA  -- Ocupa espacio en disco (hiberfil.sys). Toggle con payload Hibernation.")
    } else {
        $lines.Add("  INACTIVA -- Sin hiberfil.sys. Adecuado para desktops con UPS.")
    }
    $lines.Add('')
    $lines.Add('[CHECK D] Modern Standby (PlatformAoAcOverride)')
    try {
        $msVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name PlatformAoAcOverride -ErrorAction SilentlyContinue).PlatformAoAcOverride
        if ($null -eq $msVal -or $msVal -ne 0) {
            $lines.Add('  ACTIVO (S0ix)  -- Puede causar suspensiones irregulares. Payload DisableModernStandby disponible.')
        } else {
            $lines.Add('  DESACTIVADO (S3 clasico) -- Correcto para equipos con problemas de standby.')
        }
    } catch { $lines.Add('  NO CONFIGURADO -- Usando comportamiento por defecto.') }
    $lines.Add('')
    $lines.Add('[CHECK E] USB Storage (USBSTOR)')
    try {
        $usbVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -Name Start -ErrorAction Stop).Start
        $usbStr = switch ($usbVal) {
            2 { 'FORZADO (Start=2, enterprise)' }
            3 { 'HABILITADO (Start=3)' }
            4 { 'DESHABILITADO (Start=4)' }
            default { "DESCONOCIDO (Start=$usbVal)" }
        }
        $lines.Add("  $usbStr")
    } catch { $lines.Add('  ERR al consultar USBSTOR: CLAVE NO ENCONTRADA') }
    $lines.Add('')
    $lines.Add('=== FIN AUDIT ===')
    foreach ($l in $lines) { Write-QLog $l }
    $msg = [string]::Format($script:UI_AUDITDONE, $lines.Count)
    Write-QLog $msg
    return $lines
}
function Export-HTMLReport {
    param(
        [string]$RunlevelName   # nombre del runlevel activo (cabecera del informe)
    )
    try {
        if (-not (Test-Path $DOCS_MANOLITO)) { New-Item $DOCS_MANOLITO -ItemType Directory | Out-Null }
        $reportPath = Join-Path $DOCS_MANOLITO "report_$(Get-Date -f 'yyyyMMdd_HHmmss').html"
        $sb = [System.Text.StringBuilder]::new(8192)
        $null = $sb.AppendLine('<!DOCTYPE html>')
        $null = $sb.AppendLine('<html lang="es"><head><meta charset="UTF-8">')
        $null = $sb.AppendLine('<title>Manolito Engine Report</title>')
        $null = $sb.AppendLine('<style>')
        $null = $sb.AppendLine('body{background:#0d0d0d;color:#c8c8c8;font-family:Consolas,monospace;font-size:13px;margin:0;padding:20px}')
        $null = $sb.AppendLine('h1{color:#00ff99;border-bottom:1px solid #333;padding-bottom:8px}')
        $null = $sb.AppendLine('h2{color:#88c0d0;margin-top:24px}')
        $null = $sb.AppendLine('table{border-collapse:collapse;width:100%;margin-top:8px}')
        $null = $sb.AppendLine('th{background:#1a1a2e;color:#00ff99;padding:6px 10px;text-align:left;border:1px solid #333}')
        $null = $sb.AppendLine('td{padding:5px 10px;border:1px solid #222;vertical-align:top}')
        $null = $sb.AppendLine('tr:nth-child(even){background:#111}')
        $null = $sb.AppendLine('.ok{color:#00ff99}.fail{color:#ff5555}.warn{color:#ffcc00}.skip{color:#888}.irr{color:#ff8800;font-weight:bold}')
        $null = $sb.AppendLine('.badge-info{background:#1e3a5f;color:#88c0d0;padding:1px 5px;border-radius:3px}')
        $null = $sb.AppendLine('.badge-low{background:#1e4a1e;color:#80cc80;padding:1px 5px;border-radius:3px}')
        $null = $sb.AppendLine('.badge-mod{background:#4a3a1e;color:#ffcc00;padding:1px 5px;border-radius:3px}')
        $null = $sb.AppendLine('.badge-high{background:#4a1e1e;color:#ff8800;padding:1px 5px;border-radius:3px}')
        $null = $sb.AppendLine('.badge-crit{background:#5a0000;color:#ff5555;padding:1px 5px;border-radius:3px;font-weight:bold}')
        $null = $sb.AppendLine('pre{background:#111;padding:10px;overflow-x:auto;border:1px solid #222;border-radius:4px;white-space:pre-wrap}')
        $null = $sb.AppendLine('</style></head><body>')
        $null = $sb.AppendLine("<h1>Manolito Engine v$($script:Config.Manifest.Version) &mdash; Informe de Ejecucion</h1>")
        $null = $sb.AppendLine("<p><b>Fecha:</b> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp; <b>Runlevel:</b> $([System.Net.WebUtility]::HtmlEncode($RunlevelName)) &nbsp;|&nbsp; <b>WinBuild:</b> $($script:SystemCaps.WinBuild)</p>")
        $null = $sb.AppendLine('<h2>Capacidades del Sistema</h2><table><tr><th>Cap</th><th>Valor</th></tr>')
        foreach ($cap in $script:SystemCaps.GetEnumerator()) {
            $valHtml = [System.Net.WebUtility]::HtmlEncode("$($cap.Value)")
            $null = $sb.AppendLine("<tr><td>$([System.Net.WebUtility]::HtmlEncode($cap.Key))</td><td>$valHtml</td></tr>")
        }
        $null = $sb.AppendLine('</table>')
        $null = $sb.AppendLine('<h2>Resultados por Payload</h2>')
        $null = $sb.AppendLine('<table><tr><th>Payload</th><th>Estado</th><th>Cambios</th><th>Risk</th><th>Rev</th><th>Logs</th></tr>')
        foreach ($mod in $script:ctx.Results.Modules) {
            $pName   = $mod.Name
            $meta    = $script:PayloadMap[$pName]._meta
            $riskLevel = if ($meta -and $meta.PSObject.Properties['RiskLevel']) { $meta.RiskLevel } else { 0 }
            $riskBadge = switch ($riskLevel) {
                4       { '<span class="badge-crit">CRITICAL</span>' }
                3       { '<span class="badge-high">HIGH</span>'     }
                2       { '<span class="badge-mod">MOD</span>'       }
                1       { '<span class="badge-low">LOW</span>'       }
                default { '<span class="badge-info">INFO</span>'     }
            }
            $revHtml  = if ($meta -and $meta.Reversible) { '<span class="ok">REV</span>' } else { '<span class="irr">IRR</span>' }
            $stateHtml = if ($mod.Success) { '<span class="ok">OK</span>' } else { '<span class="fail">FAIL</span>' }
            $logSb = [System.Text.StringBuilder]::new(512)
            $null  = $logSb.Append('<pre>')
            foreach ($line in $mod.Logs) {
                $safeL = [System.Net.WebUtility]::HtmlEncode($line)
                $css   = if ($line -match '\[OK\]')   { 'ok'   }
                         elseif ($line -match '\[FAIL\]') { 'fail' }
                         elseif ($line -match '\[WARN\]') { 'warn' }
                         elseif ($line -match '\[SKIP\]') { 'skip' }
                         else { '' }
                if ($css) { $null = $logSb.Append("<span class=`"$css`">$safeL</span>`n") }
                else       { $null = $logSb.Append("$safeL`n") }
            }
            $null = $logSb.Append('</pre>')
            $null = $sb.AppendLine("<tr><td><b>$([System.Net.WebUtility]::HtmlEncode($pName))</b></td><td>$stateHtml</td><td>$($mod.Changes)</td><td>$riskBadge</td><td>$revHtml</td><td>$($logSb.ToString())</td></tr>")
        }
        $null = $sb.AppendLine('</table>')
        $irrevList = @($script:ctx.Tracking.IrreversibleActions)
        if ($irrevList.Count -gt 0) {
            $null = $sb.AppendLine('<h2 class="irr">Acciones Irreversibles</h2><ul>')
            foreach ($a in $irrevList) { $null = $sb.AppendLine("<li class=`"irr`">$([System.Net.WebUtility]::HtmlEncode($a))</li>") }
            $null = $sb.AppendLine('</ul>')
        }
        if ($script:ctx.State.PendingReboot) {
            $null = $sb.AppendLine('<p class="warn"><b>[!] REINICIO REQUERIDO</b> -- Algunos cambios requieren reiniciar el sistema para surtir efecto.</p>')
        }
        $null = $sb.AppendLine("<p style='color:#555;font-size:11px;margin-top:30px'>Generado por Manolito Engine v$($script:Config.Manifest.Version) &mdash; $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>")
        $null = $sb.AppendLine('</body></html>')
        [System.IO.File]::WriteAllText($reportPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
        Write-QLog "[Report] HTML guardado en $reportPath"
        return $reportPath
    }
    catch {
        Write-Warning "[Report] Error al generar: $($_.Exception.Message)"
        return $null
    }
}
function Export-AuditHTMLReport {
    param([System.Collections.Generic.List[string]]$AuditLines)
    try {
        if (-not (Test-Path $DOCS_MANOLITO)) { New-Item $DOCS_MANOLITO -ItemType Directory | Out-Null }
        $reportPath = Join-Path $DOCS_MANOLITO "pc_auditoria_$(Get-Date -f 'yyyyMMdd_HHmmss').html"
        $sb = [System.Text.StringBuilder]::new(4096)
        $null = $sb.AppendLine('<!DOCTYPE html>')
        $null = $sb.AppendLine('<html lang="es"><head><meta charset="UTF-8">')
        $null = $sb.AppendLine('<title>Manolito Audit Report</title>')
        $null = $sb.AppendLine('<style>')
        $null = $sb.AppendLine('body{background:#0d0d0d;color:#c8c8c8;font-family:Consolas,monospace;font-size:13px;margin:0;padding:20px}')
        $null = $sb.AppendLine('h1{color:#00ff99;border-bottom:1px solid #333;padding-bottom:8px}')
        $null = $sb.AppendLine('h2{color:#88c0d0;margin-top:20px}')
        $null = $sb.AppendLine('.check{margin:6px 0;padding:6px 10px;border-left:3px solid #333;background:#111}')
        $null = $sb.AppendLine('.ok{color:#00ff99;font-weight:bold}.warn{color:#ffcc00;font-weight:bold}.err{color:#ff5555;font-weight:bold}.info{color:#888}')
        $null = $sb.AppendLine('</style></head><body>')
        $null = $sb.AppendLine("<h1>Manolito Audit Report</h1>")
        $null = $sb.AppendLine("<p class='info'>Generado: $(Get-Date -f 'yyyy-MM-dd HH:mm:ss') | Motor: v$($script:ENGINE_VERSION)</p>")
        $section = ''
        foreach ($line in $AuditLines) {
            if ($line -match '^\[CHECK') {
                if ($section) { $null = $sb.AppendLine('</div>') }
                $section = $line
                $null = $sb.AppendLine("<h2>$([System.Web.HttpUtility]::HtmlEncode($line))</h2><div class='section'>")
            } elseif ($line -match '=== FIN AUDIT') {
                if ($section) { $null = $sb.AppendLine('</div>') }
            } elseif ($line -match '^\s*(ACTIVO|INACTIVO|ACTIVA|INACTIVA|HABILITADO|DESHABILITADO)') {
                $css = if ($line -match 'INACTIVO|INACTIVA|DESHABILITADO') { 'ok' } else { 'warn' }
                $null = $sb.AppendLine("<div class='check $css'>$([System.Web.HttpUtility]::HtmlEncode($line.Trim()))</div>")
            } elseif ($line -match '^\s*ERR|^\s*NO CONFIGURADO|^\s*DESCONOCIDO') {
                $null = $sb.AppendLine("<div class='check err'>$([System.Web.HttpUtility]::HtmlEncode($line.Trim()))</div>")
            } elseif ($line -match '\S') {
                $null = $sb.AppendLine("<div class='check info'>$([System.Web.HttpUtility]::HtmlEncode($line.Trim()))</div>")
            }
        }
        $null = $sb.AppendLine('</body></html>')
        $sb.ToString() | Set-Content -Path $reportPath -Encoding UTF8
        return $reportPath
    } catch {
        Write-QLog "[ERR] Export-AuditHTMLReport: $($_.Exception.Message)"
        return $null
    }
}
function Test-ManolitoSchema {
    param([PSObject]$Config)
    $errors = [System.Collections.Generic.List[string]]::new()
    $validRisks = @('SAFE', 'MOD', 'IRR')
    $validTypes = @('DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString')
    if ($Config.PSObject.Properties['UIMapping'] -and
        $Config.UIMapping.PSObject.Properties['Runlevels']) {
        foreach ($rlProp in $Config.UIMapping.Runlevels.PSObject.Properties) {
            $rl = $rlProp.Value
            if (-not $rl.Payloads) { $errors.Add("Runlevel '$($rlProp.Name)': Payloads vacio"); continue }
            foreach ($pName in $rl.Payloads) {
                if (-not $Config.Payloads.PSObject.Properties[$pName]) {
                    $errors.Add("Runlevel '$($rlProp.Name)': payload '$pName' no existe")
                }
            }
        }
    }
    foreach ($prop in $Config.Payloads.PSObject.Properties) {
        $pName = $prop.Name; $p = $prop.Value
        if (-not $p._meta) { $errors.Add("Payload '$pName': falta _meta"); continue }
        if ([string]::IsNullOrWhiteSpace($p._meta.Label)) { $errors.Add("Payload '$pName': _meta.Label vacio") }
        if ($p._meta.PSObject.Properties['Risk'] -and $p._meta.Risk -notin $validRisks) {
            $errors.Add("Payload '$pName': Risk='$($p._meta.Risk)' invalido (legacy)")
        }
        if ($p.SkuSiPolicyTemplate) {
            if (-not $p.SkuSiPolicyTemplate.SourcePath) { $errors.Add("Payload '$pName': SkuSiPolicyTemplate sin SourcePath") }
            if (-not $p.SkuSiPolicyTemplate.DestPath)   { $errors.Add("Payload '$pName': SkuSiPolicyTemplate sin DestPath") }
        }
        if ($p.Registry) {
            foreach ($entry in $p.Registry) {
                if ($entry.Type -and $entry.Type -notin $validTypes) { $errors.Add("Payload '$pName': Registry Type '$($entry.Type)' invalido") }
                if ([string]::IsNullOrWhiteSpace($entry.Path)) { $errors.Add("Payload '$pName': Registry entry sin Path") }
            }
        }
    }
    return $errors
}
function Build-ExecutionPlan {
    param([string]$RunlevelName)
    $payloads = Resolve-Runlevel -Name $RunlevelName
    $plan     = [System.Collections.Generic.List[hashtable]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $seenRegKeys = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)  # FIX S10-013: key->TargetValue para dedup y deteccion conflictos
    foreach ($name in $payloads) {
        $p = $script:ctx.WADData.Payloads.$name
        if (-not $p) { Write-QLog "[SKIP-PLAN] $name no en WAD"; continue }
        $meta = $p._meta
        $guard = Test-PayloadGuards -Payload $p -PayloadName $name
        if (-not $guard.Pass) { Write-QLog "[SKIP-PLAN] $name - $($guard.Reason)"; continue }
        $risk = if ($meta.RiskLevel) { [int]$meta.RiskLevel } else { 0 }
        $allowedRisk = if ($script:ctx.WADData.Config.MaxRiskAllowed) {
            [int]$script:ctx.WADData.Config.MaxRiskAllowed
        } else { 5 }
        if ($risk -gt $allowedRisk) {
            $script:ctx.LogQueue.Enqueue("LOG:[PLAN] BLOQUEADO MaxRiskAllowed=${allowedRisk}: $name (Risk=$risk) -- edita MaxRiskAllowed en el JSON para incluirlo")
            Write-QLog "[SKIP-PLAN] $name -- RiskLevel $risk supera MaxRiskAllowed $allowedRisk"
            $plan.Add(@{
                Name      = $name
                Label     = $meta.Label
                Risk      = $risk
                RiskLevel = $risk
                Reversible= $meta.Reversible
                Skipped   = $true
                SkipReason= "RiskLevel $risk supera MaxRiskAllowed $allowedRisk"
            })
            continue
        }
        $toggleState = $null
        $toggleLabel = $null
        if ($meta.DynamicToggle -and $meta.DynamicToggle -ne 'None' -and $meta.ToggleStateCapKey) {
            $capKey = $meta.ToggleStateCapKey
            if ($script:ctx.SystemCaps.Contains($capKey) -or $script:ctx.SystemCaps.Contains($capKey)) {
                $toggleState = $script:ctx.SystemCaps[$capKey]
                $toggleLabel = if ($toggleState) { '[ON ]' } else { '[OFF]' }
            } else {
                $toggleLabel = '[---]'  # cap no detectado
            }
        }
        $regKeys = @()
        if ($p.PSObject.Properties['Registry']) {
            foreach ($rEntry in $p.Registry) {
                $rk = "$($rEntry.Path)|$($rEntry.Name)"
                $tv = if ($rEntry.PSObject.Properties['TargetValue']) { "$($rEntry.TargetValue)" } else { '__unset__' }
                if ($seenRegKeys.ContainsKey($rk)) {
                    $existingTv = $seenRegKeys[$rk]
                    if ($existingTv -ne $tv) {
                        $errors.Add("[CONFLICT] Registry $rk tiene TargetValue conflictivo entre payloads ('$existingTv' vs '$tv')")
                    } else {
                        Write-QLog "[DEDUP] Registry duplicado omitido: $rk (payload: $name, mismo TargetValue)"
                    }
                } else {
                    $seenRegKeys[$rk] = $tv
                }
            }
        }
        $plan.Add(@{
            Name        = $name
            Label       = $meta.Label
            Risk        = $risk
            RiskLevel   = $risk
            Reversible  = $meta.Reversible
            ToggleState = $toggleState
            ToggleLabel = $toggleLabel
            DynamicToggle = $meta.DynamicToggle
        })
    }
    $maxRisk = ($plan | Where-Object { -not $_.Skipped } | ForEach-Object { [int]$_.RiskLevel } | Measure-Object -Maximum).Maximum
    if ($null -eq $maxRisk) { $maxRisk = 0 }
    foreach ($e in $errors) { Write-QLog "[PLAN] $e" }
    return @{ Plan = $plan; MaxRisk = $maxRisk; ConflictErrors = @($errors) }
}
[xml]$script:XAML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Manolito v2.9.1" Height="820" Width="1000" WindowStyle="None" AllowsTransparency="True"
        WindowStartupLocation="CenterScreen" FontFamily="Consolas">
    <Window.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#08001A" Offset="0"/>
            <GradientStop Color="#1A0033" Offset="1"/>
        </LinearGradientBrush>
    </Window.Background>
    <Window.Resources>
        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#00FFFF"/><Setter Property="Effect"><Setter.Value><DropShadowEffect Color="#00FFFF" BlurRadius="8" ShadowDepth="0" Opacity="0.6"/></Setter.Value></Setter></Style>
        <Style TargetType="CheckBox"><Setter Property="Margin" Value="0,6"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Foreground" Value="#00FFFF"/></Style>
        <Style TargetType="Button"><Setter Property="Cursor" Value="Hand"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="Padding" Value="15,5"/><Setter Property="Margin" Value="5,0"/><Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="#00FFFF"/><Setter Property="BorderBrush" Value="#00FFFF"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Effect"><Setter.Value><DropShadowEffect Color="#BF00FF" BlurRadius="8" ShadowDepth="0" Opacity="0.6"/></Setter.Value></Setter></Style>
        <Style TargetType="Border"><Setter Property="BorderBrush" Value="#2D0050"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Background" Value="#0A0015"/><Setter Property="Padding" Value="15"/><Setter Property="Margin" Value="5"/></Style>
        <Style TargetType="ComboBox"><Setter Property="Margin" Value="0,10"/><Setter Property="Padding" Value="5"/><Setter Property="Background" Value="#000033"/><Setter Property="Foreground" Value="#BF00FF"/><Setter Property="BorderBrush" Value="#BF00FF"/><Setter Property="BorderThickness" Value="1"/><Setter Property="FontWeight" Value="Bold"/></Style>
    </Window.Resources>
    
    <Border BorderBrush="#00FFFF" Background="Transparent" BorderThickness="1">
        <Border.CacheMode><BitmapCache EnableClearType="False" SnapsToDevicePixels="True"/></Border.CacheMode>
        <Border.Effect><DropShadowEffect Color="#BF00FF" BlurRadius="25" ShadowDepth="0" Opacity="0.6"/></Border.Effect>
        <Grid Margin="15">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

                        <TextBlock Grid.Row="0" Name="txtLogo" HorizontalAlignment="Center" FontWeight="Bold" FontSize="11" Margin="0,0,0,6"><TextBlock.Effect><DropShadowEffect Color="#FF2079" BlurRadius="14" ShadowDepth="0" Opacity="1"/></TextBlock.Effect></TextBlock>
            
            <StackPanel Grid.Row="1" HorizontalAlignment="Center" Margin="0,0,0,10">
                <TextBlock TextAlignment="Center" Margin="0,0,0,4" Foreground="#444444" Effect="{x:Null}">----------------------------------------------------------------------</TextBlock>
                <TextBlock TextAlignment="Center" FontWeight="Bold">. . .  Xciter  . . . P R E S E N T A . . .  [ MANOLITO v2.9.1 ]</TextBlock>
            </StackPanel>
            
            <Grid Grid.Row="2" Margin="0,0,0,10">
                <Grid.ColumnDefinitions><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="1.1*"/><ColumnDefinition Width="1.8*"/></Grid.ColumnDefinitions>
                <Border Grid.Column="0"><StackPanel>
                    <TextBlock Text="[ PERFIL DE SISTEMA ]" FontWeight="Bold" Margin="0,0,0,15"/>
                    <TextBlock Margin="0,4"><Run Text="Motor DB   : " Foreground="#555555"/><Run Text="v2.9.1" Foreground="#FFB000"/></TextBlock>
                    <TextBlock Margin="0,4"><Run Text="Backend    : " Foreground="#555555"/><Run Text="Modular Async" Foreground="#00FFFF"/></TextBlock>
                    <TextBlock Margin="0,4"><Run Text="OS Build  " Foreground="#555555"/><Run x:Name="TxtOSVersion" Text="--" Foreground="#00FF99"/></TextBlock>
                    
                    <GroupBox Header="Hardware Detectado" Margin="0,15,0,0" Foreground="#AAAAAA" BorderBrush="#333333">
                        <WrapPanel Margin="4,8,4,4" Orientation="Horizontal">
                            <TextBlock Name="TxtBadgeVM" Text="VM" Margin="5" Padding="6,2" Background="#1A1A1A" Foreground="#666666" Effect="{x:Null}"/>
                            <TextBlock Name="TxtBadgeDomain" Text="DOMAIN" Margin="5" Padding="6,2" Background="#1A1A1A" Foreground="#666666" Effect="{x:Null}"/>
                            <TextBlock Name="TxtBadgeSafe"    Text="SAFE"    Margin="5" Padding="6,2" Background="#1A1A1A" Foreground="#666666" Effect="{x:Null}"/>
                            <TextBlock Name="TxtBadgeReboot"  Text="REBOOT"  Margin="5" Padding="6,2" Background="#1A1A1A" Foreground="#666666" Effect="{x:Null}"/>
                            <TextBlock Name="TxtBadgeNVIDIA"  Text="NVIDIA"  Margin="5" Padding="6,2" Background="#1A1A1A" Foreground="#666666" Effect="{x:Null}"/>
                            <TextBlock Name="TxtBadgeBattery" Text="BATTERY" Margin="5" Padding="6,2" Background="#1A1A1A" Foreground="#666666" Effect="{x:Null}"/>
                            <TextBlock Name="TxtBadgeNVMe"    Text="NVMe"    Margin="5" Padding="6,2" Background="#1A1A1A" Foreground="#666666" Effect="{x:Null}"/>
                            <TextBlock Name="TxtBadgePrinter" Text="PRINT"   Margin="5" Padding="6,2" Background="#1A1A1A" Foreground="#666666" Effect="{x:Null}"/>
                        </WrapPanel>
                    </GroupBox>
                </StackPanel></Border>
                <Border Grid.Column="1"><StackPanel>
                    <TextBlock Text="[ RUNLEVEL ]" FontWeight="Bold" Margin="0,0,0,15"/>
                    <ComboBox x:Name="CbRunlevel" SelectedIndex="0" Margin="0,10,0,20" Foreground="#BF00FF"/>
                    <CheckBox x:Name="ChkDryRun" Content="DRY RUN" IsChecked="True" Foreground="#00FFFF" FontWeight="Bold" Margin="0,5"/>
                    <CheckBox x:Name="ChkCheckpoint" Content="Crear Restore Point" Foreground="#AAAAAA" Margin="0,5"/>
                    <CheckBox x:Name="ChkAutoScroll" Content="Auto-Scroll Consola" IsChecked="True" Foreground="#AAAAAA" Margin="0,5"/>
                </StackPanel></Border>
                <Border Grid.Column="2"><Grid>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Name="TxtDesc" Text="[ SELECCIONE UN PERFIL ]" FontWeight="Bold" Foreground="#00FFFF" Margin="0,0,0,15"/>
                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,5,0,0">
                        <ItemsControl x:Name="icPayloads">
                            <ItemsControl.ItemTemplate>
                                <DataTemplate>
                                    <CheckBox Content="{Binding Display}" IsChecked="{Binding IsSelected}" Margin="2,4" Foreground="{Binding RiskColor}"/>
                                </DataTemplate>
                            </ItemsControl.ItemTemplate>
                        </ItemsControl>
                    </ScrollViewer>
                </Grid></Border>
            </Grid>
            
            <Border Grid.Row="3" Background="#04000E" Height="260" Margin="5,0,5,5" BorderBrush="#2D0050">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="5">
                    <TextBox x:Name="TxtConsole" 
                             IsReadOnly="True" 
                             IsUndoEnabled="False"
                             Background="Transparent" 
                             BorderThickness="0" 
                             Foreground="#39FF14" 
                             TextWrapping="Wrap" 
                             xml:space="preserve" 
                             FontSize="12"
                             TextOptions.TextFormattingMode="Display"
                             TextOptions.TextRenderingMode="Aliased">Inicializando Manolito Engine v2.9.1...</TextBox>
                </ScrollViewer>
            </Border>
            
            <Grid Grid.Row="4" Margin="5,5,5,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center" Orientation="Horizontal">
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock Name="TxtStatus" Text="ESPERANDO ORDENES..." Foreground="#FFB000"/>
                        <ProgressBar Name="PrgBar" Height="3" Width="200" Background="#111" Foreground="#FF2079" BorderThickness="0" Margin="0,5,0,0" HorizontalAlignment="Left"/>
                        <TextBlock Name="TxtProgress" Text="0%" FontSize="10" Foreground="#555" Margin="0,2,0,0"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="15,0,0,0" VerticalAlignment="Center">
                        <Label Content="OK:" Foreground="#888888" FontSize="11" VerticalAlignment="Center"/>
                        <TextBlock x:Name="TxtStepsOk" Text="0" Foreground="#00FF99" FontSize="13" FontWeight="Bold" VerticalAlignment="Center" Margin="5,0,10,0"/>
                        <Label Content="FAIL:" Foreground="#888888" FontSize="11" VerticalAlignment="Center"/>
                        <TextBlock x:Name="TxtStepsFail" Text="0" Foreground="#FF2222" FontSize="13" FontWeight="Bold" VerticalAlignment="Center" Margin="5,0"/>
                    </StackPanel>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="BtnClearLog" Content="LIMPIAR" Foreground="#AAAAAA" BorderBrush="#AAAAAA" ToolTip="Limpiar Consola" Margin="5,0"/>
                    <Button x:Name="BtnAudit" Content="AUDITAR PC" Foreground="#FFAA00" BorderBrush="#FFAA00" Margin="5,0"/>
                    <Button x:Name="BtnReport" Foreground="#00FFFF" BorderBrush="#00FFFF" Margin="5,0"><Button.Content><StackPanel Orientation="Horizontal"><TextBlock Text="&#x1F4C1;" Margin="0,0,3,0" VerticalAlignment="Center"/><TextBlock Text="Logs" VerticalAlignment="Center"/></StackPanel></Button.Content></Button>
                    <Button x:Name="BtnLoadProfile" Content="OPEN MIX" Foreground="#FFB000" BorderBrush="#FFB000" Margin="5,0" ToolTip="Aplica una seleccion de payloads (mix) guardada previamente sobre el plan ya cargado en pantalla"/>
                    <Button x:Name="BtnSaveProfile" Content="SAVE MIX" Foreground="#00FFFF" BorderBrush="#00FFFF" Margin="5,0" ToolTip="Guarda que payloads tienes marcados ahora mismo (mix), para reaplicar la misma seleccion en el futuro"/>
                    <Button x:Name="BtnLoadManifest" Content="RESTAURAR" Foreground="#BF00FF" BorderBrush="#BF00FF" Margin="5,0"/>
                    <Button x:Name="BtnRollback" Content="ROLLBACK" Foreground="#FF6600" BorderBrush="#FF6600" Margin="5,0" ToolTip="Revierte los cambios aplicados en esta sesion usando el RollbackStack"/>
                    <Button x:Name="btnExit" Content="SALIR" Foreground="#39FF14" BorderBrush="#39FF14" Margin="5,0"/>
                    
                    <TextBlock x:Name="TxtRebootBadge" Text="[ REINICIO REQ. ]" Foreground="#FF4500" FontWeight="Bold" Visibility="Collapsed" VerticalAlignment="Center" Margin="8,0"/>
                    <Button x:Name="BtnExecute" Content="INICIAR" Margin="16,0,0,0" Background="#FF2079" Foreground="#08001A" BorderBrush="#FF2079" BorderThickness="0">
                        <Button.Effect>
                            <DropShadowEffect Color="#FF2079" BlurRadius="10" ShadowDepth="0" Opacity="0.8"/>
                        </Button.Effect>
                    </Button>
                </StackPanel>
            </Grid>
        </Grid>
    </Border>
</Window>
'@
$script:uiRunspaceJob = $null
function Invoke-LoadPlan {
    param([string]$Runlevel)
    if (-not $Runlevel -or $Runlevel -eq '-- Selecciona perfil --') { & $setStatus 'Selecciona un runlevel'; return }
        Write-UIBeep 'check'
        $lv = $Runlevel  # FIX S13-001: usar el parametro saneado; no releer SelectedItem con el display label
        if (-not $lv) { & $setStatus 'Selecciona un runlevel'; return }
        try {
            $result = Build-ExecutionPlan -RunlevelName $lv
            $script:uiPlanResult = $result
            $plan    = $result.Plan
            $maxRisk = $result.MaxRisk
            $riskLabel = switch ($maxRisk) {
                4 { 'CRITICO' } 3 { 'ALTO' } 2 { 'MODERADO' } 1 { 'BAJO' } default { 'INFO' }
            }
            $txtPlanHdr.Text = "Runlevel: $lv  |  $($plan.Count) payload(s)  |  Riesgo max: $riskLabel (nivel $maxRisk)"
            $items = $plan | ForEach-Object {
                $riskColor = $script:riskColorMap[[int]$_.RiskLevel]
                $toggleSuffix = if ($_.ToggleLabel) { "  $($_.ToggleLabel)" } else { '' }
                [PSCustomObject]@{
                    Name       = $_.Name
                    Display    = "[$($_.Risk)] $($_.Label)$toggleSuffix  ($($_.Name))"
                    IsSelected = $true
                    RiskColor  = $riskColor
                    ToggleState = $_.ToggleState
                    DynamicToggle = $_.DynamicToggle
                }
            }
            $icPayloads.ItemsSource = @($items)
            & $appendLog "[PLAN] $($plan.Count) payload(s) cargados para runlevel '$lv'"
            $warnSel = @($plan | Where-Object {
                $pm = $script:PayloadMap[$_]; $pm -and $pm._meta -and $pm._meta.WarnOnSelect
            })
            if ($warnSel.Count -gt 0) {
                & $appendLog "[PLAN-WARN] WarnOnSelect: $($warnSel -join ', ')"
                [System.Windows.MessageBox]::Show(
                    "Atencion: los siguientes payloads requieren confirmacion manual:`n`n$($warnSel -join "`n")",
                    'Manolito -- Aviso de Seleccion',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
            & $setStatus $script:UI_READY
        } catch {
            & $setStatus "Error al cargar plan: $_"
        }
}
function Get-CachedBrush {
    param([string]$hex)
    if (-not $script:brushCache.ContainsKey($hex)) {
        $script:brushCache[$hex] = [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex)
    }
    return $script:brushCache[$hex]
}
function Show-SplashWindow {
    $splashXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="480" Height="180" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" WindowStartupLocation="CenterScreen" Topmost="True">
  <Border BorderBrush="#00FFFF" BorderThickness="1" CornerRadius="4">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
        <GradientStop Color="#08001A" Offset="0"/>
        <GradientStop Color="#1A0033" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Border.Effect><DropShadowEffect Color="#BF00FF" BlurRadius="20" ShadowDepth="0" Opacity="0.5"/></Border.Effect>
    <Grid Margin="20,16,20,16">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Text="[ MANOLITO ENGINE $script:ENGINE_VERSION ]" FontFamily="Consolas" FontSize="13"
                 FontWeight="Bold" Foreground="#00FFFF" HorizontalAlignment="Center" Margin="0,0,0,10"/>
      <ProgressBar x:Name="SplashProgress" Grid.Row="1" Height="8" Minimum="0" Maximum="100" Value="0"
                   Foreground="#BF00FF" Background="#1A0033" BorderBrush="#2D0050" Margin="0,0,0,10"/>
      <TextBlock x:Name="SplashStatus" Grid.Row="2" Text="Iniciando..." FontFamily="Consolas" FontSize="11"
                 Foreground="#AAAAAA" HorizontalAlignment="Center"/>
    </Grid>
  </Border>
</Window>
"@
    $xmlReader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($splashXaml))
    $splashWin  = [Windows.Markup.XamlReader]::Load($xmlReader)
    $splashProg = $splashWin.FindName('SplashProgress')
    $splashTxt  = $splashWin.FindName('SplashStatus')
    $script:_splashSteps = @(
        @{ Pct=10; Text='Cargando configuracion WAD...';    Action={
            $wadOk = Import-WAD
            if (-not $wadOk) { throw 'Import-WAD fallo -- motor detenido. Revisar JSON y logs.' }
            if ($script:ctx.WADData.Manifest.Version) {
                $script:ENGINE_VERSION = $script:ctx.WADData.Manifest.Version
            }
        }},
        @{ Pct=40; Text='Detectando hardware...';           Action={
            Get-SystemCaps
            foreach ($plProp in $script:ctx.WADData.Payloads.PSObject.Properties) {
                $ck = $plProp.Value._meta.ToggleStateCapKey
                if ($ck -and -not $script:ctx.SystemCaps.Contains($ck)) {
                    throw "ToggleStateCapKey no resuelto: '$ck' (payload: $($plProp.Name))"
                }
            }
            $script:ValidRiskLevels = @(0, 1, 2, 3, 4)
            $script:ValidToggle     = @('Universal', 'OwnedOnly', 'None')
            $script:SpecializedProviders = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]@(
                    'Packages','Services','Tasks','Registry','RegistryKeys','NagleTemplate','DNS','BCD',
                    'DeviceClasses','WingetPackages','NvidiaOptimizeTemplate','NICProperties','UltimatePowerPlan',
                    'TimerResConfig','PowercfgSettings','WindowsFeatures','TempCleanup','DismResetBase',
                    'ActiveSetupEntries','HostsEntries','ACL','Blacklist','OneDriveUninstall','USBStorageTemplate',
                    'NVMeProtectTemplate','BlueHammer','SkuSiPolicyTemplate'
                ))
            $script:KnownCaps = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]@(
                    'IsVM','IsDomain','HasNVIDIA','HasNVMe','HasBattery','HasPhysicalNIC',
                    'HasPrinter','HasOffice','HasOneDrive','HasHAGS','CanUseWinget',
                    'IsSafeMode','PendingReboot','USBStorageEnabled','USBStorageRawValue',
                    'NVMeDriverIsOEM','NVMeDriverName','MSIState','HiberbootEnabled','WinBuild',
                    'BitLockerAutoEncryptionEnabled',
                    'HAGSEnabled','ModernStandbyEnabled','HibernationEnabled','HasNVIDIA'
                ),
                [System.StringComparer]::OrdinalIgnoreCase
            )
        }},
        @{ Pct=70; Text='Validando esquema y runlevels...'; Action={
            Test-WADSchema
            Test-RunlevelDAG
        }},
        @{ Pct=90; Text='Preparando interfaz...';           Action={ $null } }
    )
    $script:_splashIdx  = 0
    $script:_splashWin  = $splashWin
    $script:_splashProg = $splashProg
    $script:_splashTxt  = $splashTxt
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({
        $i = $script:_splashIdx
        if ($i -ge $script:_splashSteps.Count) { return }
        $step = $script:_splashSteps[$i]
        $script:_splashProg.Value = $step.Pct
        $script:_splashTxt.Text   = $step.Text
        $script:_splashIdx++
        $isLast = ($script:_splashIdx -ge $script:_splashSteps.Count)
        try {
            & $step.Action
        } catch {
            $timer.Stop()
            [System.Windows.MessageBox]::Show(
                "Error durante el arranque:`n$($_.Exception.Message)",
                'Manolito Engine - Error de Arranque',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
            $script:_splashWin.Close()
            exit 1
        }
        if ($isLast) {
            $timer.Stop()
            $script:_splashProg.Value = 100
            $script:_splashTxt.Text   = 'Listo'
            Show-Logo
            $caps = $script:ctx.SystemCaps
            if ($caps -and $caps.IsSafeMode) {
                $ans = [System.Windows.MessageBox]::Show(
                    "El sistema esta en Modo Seguro. Manolito Engine puede funcionar de forma limitada.`n`nDeseas continuar de todos modos?",
                    'Manolito Engine - Modo Seguro',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning)
                if ($ans -ne [System.Windows.MessageBoxResult]::Yes) {
                    $script:_splashWin.Close(); exit 0
                }
            }
            if ($caps -and $caps.PendingReboot) {
                [System.Windows.MessageBox]::Show(
                    "Hay un reinicio pendiente en este sistema.`n`nAlgunas operaciones pueden comportarse de forma inesperada.`n`nPuedes continuar, pero se recomienda reiniciar antes.",
                    'Manolito Engine - Reinicio Pendiente',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information) | Out-Null
            }
            if ($caps -and $caps.HasNVMe -and -not $caps.NVMeDriverIsOEM) {
                Write-Warning '[CAPS] NVMe con driver Microsoft estandar (stornvme). Considera driver OEM.'
            }
            $script:_splashWin.Close()
            Show-MainWindow
        }
    })
    $splashWin.Add_Loaded({ $timer.Start() })
    $splashWin.ShowDialog() | Out-Null
}
function Show-MainWindow {
    if (-not ([System.Management.Automation.PSTypeName]'System.Windows.Forms.OpenFileDialog').Type) {
        Add-Type -AssemblyName System.Windows.Forms
    }
    $reader = [System.Xml.XmlNodeReader]::new($script:XAML)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $window.Title = "Manolito v$($script:ENGINE_VERSION)"
    $cboRunlevel   = $window.FindName('CbRunlevel')
    $chkDryRun     = $window.FindName('ChkDryRun')
    $btnAudit      = $window.FindName('BtnAudit')
    $icPayloads    = $window.FindName('icPayloads')
    $txtPlanHdr    = $window.FindName('TxtDesc')
    $txtLog        = $window.FindName('TxtConsole')
    $pbProgress    = $window.FindName('PrgBar')
    $btnRun        = $window.FindName('BtnExecute')
    $btnRollback   = $window.FindName('BtnRollback')
    $btnReport     = $window.FindName('BtnReport')
    $btnManifest   = $window.FindName('BtnLoadManifest')
    $btnSaveProfile= $window.FindName('BtnSaveProfile')
    $btnLoadProfile= $window.FindName('BtnLoadProfile')
    $txtStatus     = $window.FindName('TxtStatus')
    $chkCheckpoint = $window.FindName('ChkCheckpoint')
    $txtProgress      = $window.FindName('TxtProgress')     # P2-A: conectar huerfanos
    $txtRebootBadgeLg  = $window.FindName('TxtRebootBadge')  # P2-A: alias badge legacy
    $btnClearLog   = $window.FindName('BtnClearLog')    # P2-01: conectar controles huerfanos
    $chkAutoScroll = $window.FindName('ChkAutoScroll')
    $txtVersion    = $window.FindName('TxtVersion')
    if ($null -ne $txtVersion) { $txtVersion.Text = " v$($script:ctx.WADData.Manifest.Version)" }
    if ($null -ne $btnClearLog) {
        $btnClearLog.Add_Click({
            $txtLog.Clear()
            $script:uiLogLines.Clear()
            & $setStatus 'Log limpiado.'
        })
    }
    if ($null -ne $chkAutoScroll) {
        $chkAutoScroll.Add_Checked({   $script:uiAutoScroll = $true  })
        $chkAutoScroll.Add_Unchecked({ $script:uiAutoScroll = $false })
    }
    if ($script:SystemCaps.IsVM) {
        $b = $window.FindName('TxtBadgeVM')
        $b.Text       = '[ VM ]'
        $b.Background = [System.Windows.Media.Brushes]::DarkBlue
        $b.Foreground = (Get-CachedBrush '#88C0D0')
    }
    if ($script:SystemCaps.IsDomain) {
        $b = $window.FindName('TxtBadgeDomain')
        $b.Text       = '[ DOMINIO ]'
        $b.Background = (Get-CachedBrush '#3a1e4a')
        $b.Foreground = (Get-CachedBrush '#BF00FF')
    }
    if ($script:SystemCaps.IsSafeMode) {
        $b = $window.FindName('TxtBadgeSafe')
        $b.Text       = '[ SAFE MODE ]'
        $b.Background = (Get-CachedBrush '#4a1e1e')
        $b.Foreground = (Get-CachedBrush '#FF5555')
    }
    $bOSV = $window.FindName('TxtOSVersion')
    if ($null -ne $bOSV) {
        $bOSV.Text = "$([System.Environment]::OSVersion.Version.Build)"
    }
    if ($script:SystemCaps.HasNVIDIA -or $script:SystemCaps.HasNVMe) {
        $bNV = $window.FindName('TxtBadgeNVIDIA')
        if ($null -ne $bNV -and $script:SystemCaps.HasNVIDIA) {
            $bNV.Text = '[ NVIDIA ]'; $bNV.Background = (Get-CachedBrush '#1a1200')
            $bNV.Foreground = (Get-CachedBrush '#FFB000')
        }
    }
    if ($script:SystemCaps.HasBattery) {
        $bBat = $window.FindName('TxtBadgeBattery')
        if ($null -ne $bBat) {
            $bBat.Text = '[ BATTERY ]'; $bBat.Background = (Get-CachedBrush '#1a2200')
            $bBat.Foreground = (Get-CachedBrush '#00FF99')
        }
    }
    if ($script:SystemCaps.HasNVMe) {
        $bNVMe = $window.FindName('TxtBadgeNVMe')
        if ($null -ne $bNVMe) {
            $bNVMe.Text = '[ NVMe ]'; $bNVMe.Background = (Get-CachedBrush '#001a2a')
            $bNVMe.Foreground = (Get-CachedBrush '#00FFFF')
        }
    }
    if ($script:SystemCaps.HasPrinter) {
        $bPrt = $window.FindName('TxtBadgePrinter')
        if ($null -ne $bPrt) {
            $bPrt.Text = '[ PRINT ]'; $bPrt.Background = (Get-CachedBrush '#2a1a00')
            $bPrt.Foreground = (Get-CachedBrush '#FFAA00')
        }
    }
    $logoLines = $null
    try { $logoLines = $script:ctx.WADData.Logo } catch {}
    $levels = Get-RunlevelList
    $cboRunlevel.DisplayMemberPath = 'Label'
    $cboRunlevel.SelectedValuePath = 'Key'
    [void]$cboRunlevel.Items.Add([PSCustomObject]@{ Key = $null; Label = '-- Selecciona perfil --' })
    foreach ($lv in $levels) {
        $rlMeta  = $script:ctx.WADData.UIMapping.Runlevels.$lv
        $rlLabel = if ($rlMeta -and $rlMeta.PSObject.Properties['Label'] -and $rlMeta.Label) {
            $rlMeta.Label
        } else { $lv }
        [void]$cboRunlevel.Items.Add([PSCustomObject]@{ Key = $lv; Label = $rlLabel })
    }
    $cboRunlevel.SelectedIndex = 0   # apunta a la entrada vacia
    $script:uiPlanResult  = $null
    $script:uiAuditLines  = @()
    $script:uiLogLines    = [System.Collections.Generic.List[string]]::new()
    $script:uiBusy        = $false
    $appendLog = {
        param([string]$msg)
        $script:uiLogLines.Add($msg)
        $maxLines = Get-ConfigValue -Key 'LogMaxLines' -Default 2000
        if ($script:uiLogLines.Count -gt $maxLines) {
            $script:uiLogLines.RemoveAt(0)
            $txtLog.Text = $script:uiLogLines -join "`n"
        } else {
            $txtLog.AppendText("`n$msg")
        }
        if ($script:uiAutoScroll -ne $false) { $txtLog.ScrollToEnd() }
        if ($script:ManolitoTranscriptPath) {
            try {
                Add-Content -Path $script:ManolitoTranscriptPath -Value $msg -Encoding UTF8
            } catch {}
        }
    }
    $setStatus = { param([string]$msg) $txtStatus.Text = $msg }
    $pollMs = Get-ConfigValue -Key 'PollIntervalMs' -Default 50
    $timer  = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds($pollMs)
    $timer.Add_Tick({
        $item = $null
        while ($script:ctx.LogQueue.TryDequeue([ref]$item)) {
            if ($item -match '(?s)^LOG:(.*)') {
                & $appendLog $Matches[1]
            } elseif ($item -match '^STATE:(.+)') {
                try {
                    $rs = $Matches[1] | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $rs.State.PendingReboot) {
                        $script:ctx.State.PendingReboot = $rs.State.PendingReboot
                        if ($rs.State.PendingReboot -eq $true -and $null -ne $txtRebootBadgeLg) {
                            $txtRebootBadgeLg.Text       = '[ REINICIO REQ. ]'
                            $txtRebootBadgeLg.Visibility = [System.Windows.Visibility]::Visible
                        }
                    }
                    if ($null -ne $rs.State.StepsOk)   { $script:ctx.State.StepsOk   = $rs.State.StepsOk }
                    if ($null -ne $rs.State.StepsFail) { $script:ctx.State.StepsFail = $rs.State.StepsFail }
                    if ($null -ne $rs.Delta) {
                        if ($rs.Delta.LastModule) {
                            if ($script:ctx.Results.Modules -isnot [System.Collections.Generic.List[object]]) {
                                $script:ctx.Results.Modules = [System.Collections.Generic.List[object]]::new()
                            }
                            $lastAdded = if ($script:ctx.Results.Modules.Count -gt 0) { $script:ctx.Results.Modules[-1] } else { $null }
                            $isDuplicate = $lastAdded -and $lastAdded.Name -eq $rs.Delta.LastModule.Name -and
                                           $lastAdded.Status -eq $rs.Delta.LastModule.Status
                            if (-not $isDuplicate) {
                                $script:ctx.Results.Modules.Add($rs.Delta.LastModule)
                            }
                        }
                        if ($rs.Delta.IrreversibleActions) {
                            foreach ($ia in $rs.Delta.IrreversibleActions) {
                                if (-not $script:ctx.Tracking.IrreversibleActions.Contains($ia)) {
                                    $script:ctx.Tracking.IrreversibleActions.Add($ia)
                                }
                            }
                        }
                    }
                } catch { Write-Warning "[STATE] Deserializacion fallida: $($_.Exception.Message)" }
            } elseif ($item -match '^DONE:ROLLBACK_(OK|FAIL)$') {
                continue
            } elseif ($item -match '^DONE:(.*)') {
                $result = $Matches[1]
                $pbProgress.Value = 100
                & $setStatus "Completado: $result"
                if ($script:uiRunspaceJob) {
                    try { $script:uiRunspaceJob.PS.EndInvoke($script:uiRunspaceJob.Handle) } catch {}
                    try { $script:uiRunspaceJob.PS.Dispose() } catch {}
                    try { $script:uiRunspaceJob.RS.Close(); $script:uiRunspaceJob.RS.Dispose() } catch {}
                    $script:uiRunspaceJob = $null
                }
                $stepsOk   = ($script:ctx.Results.Modules | Where-Object { $_.Success -eq $true  }).Count
                $stepsFail = ($script:ctx.Results.Modules | Where-Object { $_.Success -eq $false }).Count
                $window.FindName('TxtStepsOk').Text   = "$stepsOk"
                $window.FindName('TxtStepsFail').Text = "$stepsFail"
                if ($script:ctx.State.PendingReboot) {
                    $badgeReboot = $window.FindName('TxtBadgeReboot')
                    if ($null -ne $badgeReboot) {
                        $badgeReboot.Text       = '[ REBOOT PENDING ]'
                        $badgeReboot.Background = Get-CachedBrush '#2a1a00'
                        $badgeReboot.Foreground = Get-CachedBrush '#FF4500'
                    }
                if ($null -ne $txtRebootBadgeLg) {
                        $txtRebootBadgeLg.Text       = '[ REINICIO REQ. ]'
                        $txtRebootBadgeLg.Visibility = [System.Windows.Visibility]::Visible
                    }  # FIX5
                    if ($stepsFail -eq 0 -and $result -eq 'OK') {
                        $r = [System.Windows.MessageBox]::Show(
                            "La ejecucion ha completado correctamente. Algunos cambios requieren REINICIAR el sistema.`n`nDeseas reiniciar ahora? (El sistema se reiniciara en 30 segundos si aceptas)",
                            'Reinicio Pendiente', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
                        if ($r -eq 'Yes') {
                            & $appendLog '[INFO] Usuario acepto reinicio. Reiniciando en 30 segundos...'
                            Start-Process shutdown.exe -ArgumentList '/r /t 30 /c "Manolito Engine - Reinicio post-despliegue"'
                        } else {
                            & $appendLog '[INFO] Usuario rechazo reinicio. Reiniciar manualmente cuando sea posible.'
                        }
                    } else {
                        & $appendLog '[WARN] Reinicio pendiente pero hay fallos activos. Revisar log y reiniciar manualmente.'
                    }
                }
                if (-not $script:ctx.Runtime.IsDryRun -and $result -eq 'OK') {
                    Write-UIBeep 'check'
                }
                $script:uiBusy = $false
                $btnRun.IsEnabled      = $true
                $btnRollback.IsEnabled = $true
                $btnReport.IsEnabled   = $true
            } elseif ($item -match '^COUNT:(\d+)') {
            } elseif ($item -match '^PAYLOAD_NOCHANGE:(.+)') {
                & $appendLog "[NOCHANGE] $($Matches[1]) -- sin cambios reales"
            } elseif ($item -match '^PAYLOAD_FAIL:(.+)') {
                & $appendLog "[FAIL] $($Matches[1]) -- errores criticos, sin manifest"
            } elseif ($item -match '^PAYLOAD_OK:(.+)') {
                $pname = $Matches[1]
                if (-not $script:ctx.Runtime.IsDryRun) {
                    if ($script:ctx.Tracking.AppliedPayloads -notcontains $pname) {
                        $script:ctx.Tracking.AppliedPayloads.Add($pname)
                    }
                    if ($script:ctx.Tracking.PayloadsExecuted -notcontains $pname) {
                        $script:ctx.Tracking.PayloadsExecuted.Add($pname)
                    }
                    Save-ManifestEntry -PayloadName $pname
                }
            }
        }
        while ($script:ctx.ProgressQueue.TryDequeue([ref]$item)) {
            if ($item -match '^PROG:(\d+)') {
                $pbProgress.Value = [int]$Matches[1]
                if ($null -ne $txtProgress) { $txtProgress.Text = "$($Matches[1])%" }  # P2-A
            }
        }
        if ($script:uiRunspaceJob -and $script:uiBusy) {
            if ([DateTime]::UtcNow -gt $script:uiRunspaceJob.Deadline) {
                try { $script:uiRunspaceJob.PS.Stop() } catch {}
                $script:ctx.LogQueue.Enqueue('LOG:[TIMEOUT] Runspace UI supero limite')
                $script:ctx.LogQueue.Enqueue('DONE:TIMEOUT')
            }
        }
    })
    $timer.Start()
    $btnSaveProfile.Add_Click({
        if ($script:uiBusy) { return }
        $source = $icPayloads.ItemsSource
        if (-not $source) { & $setStatus 'Primero debes cargar un plan (runlevel) antes de guardar un mix'; return }
        $selectedNames = @($source | Where-Object { $_.IsSelected } | Select-Object -ExpandProperty Name)
        if ($selectedNames.Count -eq 0) { & $setStatus 'Sin payloads seleccionados'; return }
        if (-not (Test-Path $DOCS_MANOLITO)) { New-Item $DOCS_MANOLITO -ItemType Directory -Force | Out-Null }
        $sfd = [System.Windows.Forms.SaveFileDialog]::new()
        $sfd.Filter           = 'Mix Manolito (*.json)|*.json|Todos (*.*)|*.*'
        $sfd.Title            = 'Guardar Mix de payloads'
        $sfd.InitialDirectory = $DOCS_MANOLITO
        $sfd.FileName         = "mix_$(Get-Date -f 'yyyyMMdd_HHmmss').json"
        if ($sfd.ShowDialog() -ne 'OK') { return }
        try {
            $outPath = $sfd.FileName
            $selectedNames | ConvertTo-Json | Set-Content -Path $outPath -Encoding UTF8
            [System.Windows.MessageBox]::Show(
                "Mix guardado ($($selectedNames.Count) payloads):`n$outPath",
                'Mix Guardado', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
            & $appendLog "[MIX] Guardado: $($selectedNames.Count) payloads -> $outPath"
            Write-UIBeep 'check'
        } catch { & $appendLog "[MIX] Error al guardar: $($_.Exception.Message)" }
    })
    $btnLoadProfile.Add_Click({
        if ($script:uiBusy) { return }
        $source = $icPayloads.ItemsSource
        if (-not $source) {
            & $setStatus 'Primero debes cargar un plan (runlevel) para poder abrir un mix guardado'
            [System.Windows.MessageBox]::Show(
                "Este boton aplica un mix de payloads previamente guardado, pero necesita" +
                " un plan cargado primero.`n`nCarga un runlevel arriba antes de usar OPEN MIX.",
                'Sin Plan Cargado', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
            return
        }
        if (-not (Test-Path $DOCS_MANOLITO)) { New-Item $DOCS_MANOLITO -ItemType Directory -Force | Out-Null }
        $ofd = [System.Windows.Forms.OpenFileDialog]::new()
        $ofd.Filter           = 'Mix Manolito (*.json)|*.json|Todos (*.*)|*.*'
        $ofd.Title            = 'Abrir Mix de payloads'
        $ofd.InitialDirectory = $DOCS_MANOLITO
        if ($ofd.ShowDialog() -ne 'OK') { return }
        $inPath = $ofd.FileName
        try {
            $savedNames = @(Get-Content $inPath -Raw | ConvertFrom-Json)
            foreach ($item in $source) { $item.IsSelected = ($item.Name -in $savedNames) }
            $icPayloads.Items.Refresh()
            & $appendLog "[MIX] Cargado: $($savedNames.Count) payloads restaurados desde $inPath"
            Write-UIBeep 'check'
        } catch { & $appendLog "[MIX] Error al cargar: $($_.Exception.Message)" }
    })
    $cboRunlevel.Add_SelectionChanged({ Invoke-LoadPlan -Runlevel $cboRunlevel.SelectedValue })
    $btnRun.Add_Click({
        if ($script:uiBusy) { return }
        Write-UIBeep 'action'
        if (-not $script:uiPlanResult) { & $setStatus 'Carga un plan primero'; return }
        $isDry = $chkDryRun.IsChecked  # ChkDryRun reemplaza rdoDryRun
        $selected = $icPayloads.ItemsSource |
                    Where-Object { $_.IsSelected } |
                    Select-Object -ExpandProperty Name
        if (-not $selected -or @($selected).Count -eq 0) {
            & $setStatus 'Sin payloads seleccionados'; return
        }
        $planSource = if ($script:uiPlanResult -and $script:uiPlanResult.Plan) {
            $script:uiPlanResult.Plan
        } else {
            @($icPayloads.ItemsSource | ForEach-Object {
                $pMeta = $script:ctx.WADData.Payloads.$($_.Name)._meta
                @{
                    Name       = $_.Name
                    Label      = if ($pMeta -and $pMeta.Label) { $pMeta.Label } else { $_.Name }
                    RiskLevel  = if ($pMeta -and $null -ne $pMeta.RiskLevel) { [int]$pMeta.RiskLevel } else { 0 }
                    Reversible = if ($pMeta -and $null -ne $pMeta.Reversible) { [bool]$pMeta.Reversible } else { $false }
                    Skipped    = $false
                }
            })
        }
        $subPlan = @{
            Plan           = $planSource | Where-Object { $selected -contains $_['Name'] }
            MaxRisk        = ($planSource |
                       Where-Object { $selected -contains $_['Name'] } |
                       ForEach-Object { if ($null -ne $_['RiskLevel']) { [int]$_['RiskLevel'] } else { 0 } } |
                       Measure-Object -Maximum).Maximum
            ConflictErrors = if ($script:uiPlanResult -and $script:uiPlanResult.ConflictErrors) { $script:uiPlanResult.ConflictErrors } else { @() }
        }
        $script:ctx.Runtime.IsDryRun = $isDry
        $script:uiLastRunlevelName = $cboRunlevel.SelectedValue  # FIX S14-002d: SelectedValue via Key, no parseo de texto visible
        if (-not (Confirm-ExecutionPlan -PlanResult $subPlan)) {
            & $setStatus 'Ejecucion cancelada'; return
        }
        $doCheckpointFlag = (-not $isDry -and $chkCheckpoint -and $chkCheckpoint.IsChecked)
        $script:uiBusy       = $true
        $btnRun.IsEnabled      = $false
        $btnRollback.IsEnabled = $false
        $btnReport.IsEnabled   = $false
        $pbProgress.Value      = 0
        $modeStr = if ($isDry) { 'DRY RUN' } else { 'LIVE' }
        & $appendLog "[START] Ejecutando $(@($selected).Count) payload(s) en modo $modeStr"
        & $setStatus "Ejecutando..."
        $skippedNames = @($subPlan.Plan | Where-Object { $_['Skipped'] } | ForEach-Object { $_['Name'] })
        $namesArr = @($selected | Where-Object { $_ -notin $skippedNames })
        if ($namesArr.Count -eq 0) { & $setStatus 'Todos los payloads seleccionados fueron omitidos por MaxRiskAllowed'; $script:uiBusy = $false; $btnRun.IsEnabled = $true; return }
        $script:uiRunspaceJob = Invoke-RunspaceWorker -PayloadNames $namesArr -IsDryRun $isDry -Async `
            -DoCheckpoint $doCheckpointFlag -CheckpointDesc "Manolito Engine v$($script:ENGINE_VERSION) - Pre-Execution" `
            -DoPostReport $true -PostReportRunlevel $(if ($script:uiLastRunlevelName) { $script:uiLastRunlevelName } else { $cboRunlevel.SelectedValue })
    })
    $btnRollback.Add_Click({
        if ($script:uiBusy) { return }
        Write-UIBeep 'action'
        $cnt    = $script:ctx.Tracking.AppliedPayloads.Count
        $rbCnt  = $script:ctx.Tracking.RollbackStack.Count
        if ($cnt -eq 0 -and $rbCnt -eq 0) { & $setStatus 'Sin payloads aplicados en esta sesion'; return }
        $cnt = [math]::Max($cnt, $rbCnt)
        $msg = [string]::Format($script:UI_ROLLBACK, $cnt)
        $r   = [System.Windows.MessageBox]::Show($msg, 'Manolito Engine', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($r -ne 'Yes') { return }
        & $appendLog '[ROLLBACK] Iniciando reversion asincrona...'
        $script:ctx.Runtime.IsDryRun   = $chkDryRun.IsChecked
        $script:ctx.Runtime.IsRollback = $true
        $script:uiBusy = $true
        & $setStatus 'Rollback en curso...'
        Ensure-WorkerISS
        $rbRS = [runspacefactory]::CreateRunspace($script:workerISS)
        $rbRS.ApartmentState = 'STA'
        $rbRS.Open()
        $rbRS.SessionStateProxy.SetVariable('ctx',           $script:ctx)
        $rbRS.SessionStateProxy.SetVariable('PayloadMap',    $script:PayloadMap)
        $rbRS.SessionStateProxy.SetVariable('ProviderMap',   $script:ProviderMap)
        $rbRS.SessionStateProxy.SetVariable('SystemCaps',    $script:SystemCaps)
        $rbRS.SessionStateProxy.SetVariable('Config',        $script:Config)
        $rbRS.SessionStateProxy.SetVariable('wingetBlocked', $script:wingetBlocked)
        $rbWorker = [System.Management.Automation.PowerShell]::Create()
        $rbWorker.Runspace = $rbRS
        [void]$rbWorker.AddScript({
            param($ctx)
            $script:ctx           = $ctx
            $script:PayloadMap    = $PayloadMap
            $script:ProviderMap   = $ProviderMap
            $script:SystemCaps    = $SystemCaps
            $script:Config        = $Config
            $script:wingetBlocked = $wingetBlocked
            $ok = $true
            try {
                Invoke-RollbackSession
            } catch {
                $ok = $false
                $ctx.LogQueue.Enqueue("LOG:[ERR-RB] $_")
            }
            if ($ok) { $ctx.LogQueue.Enqueue('DONE:ROLLBACK_OK'); return 'ROLLBACK_OK' }
            else     { $ctx.LogQueue.Enqueue('DONE:ROLLBACK_FAIL'); return 'ROLLBACK_FAIL' }
        }).AddArgument($script:ctx)
        $rbAsync = $rbWorker.BeginInvoke()
        $rbTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $rbTimer.Interval = [timespan]::FromMilliseconds(200)
        $rbTimer.Add_Tick({
            if ($rbAsync.IsCompleted) {
                $rbTimer.Stop()
                $rbOutput = $null
                try { $rbOutput = $rbWorker.EndInvoke($rbAsync) } catch {}
                $rbWorker.Dispose()
                try { $rbRS.Close(); $rbRS.Dispose() } catch {}
                $script:uiBusy = $false
                $script:ctx.Runtime.IsRollback = $false
                $rbFailed = ($null -eq $rbOutput) -or ($rbOutput -contains 'ROLLBACK_FAIL') -or (-not ($rbOutput -contains 'ROLLBACK_OK'))
                if ($rbFailed) {
                    & $setStatus 'Rollback finalizado con errores'
                    & $appendLog '[ROLLBACK] Reversion finalizada con errores'
                } else {
                    & $setStatus 'Rollback completado'
                    & $appendLog '[ROLLBACK] Reversion completada'
                }
            }
        })
        $rbTimer.Start()
    })
    $btnAudit.Add_Click({
        if ($script:uiBusy) { return }
        & $appendLog '[AUDIT] Iniciando...'
        $script:uiAuditLines = Invoke-AuditMode
        $auditHtml = Export-AuditHTMLReport -AuditLines $script:uiAuditLines
        if ($auditHtml) {
            & $appendLog "[AUDIT] Reporte HTML: $auditHtml"
            & $setStatus "Audit completado -- reporte en $auditHtml"
        } else {
            & $setStatus 'Audit completado'
        }
    })
    $script:uiLastRunlevelName = $null  # NEW-S5-02: runlevel de la ultima ejecucion real
    $btnReport.Add_Click({
        $rlName = if ($script:uiLastRunlevelName) { $script:uiLastRunlevelName } else { $cboRunlevel.SelectedValue }  # FIX S14-003c
        $path = Export-HTMLReport -RunlevelName $rlName
        & $setStatus "Reporte exportado: $path"
        & $appendLog "[REPORT] $path"
        try {
            if ($path -and (Test-Path $path)) {
                Start-Process 'explorer.exe' -ArgumentList "/select,`"$path`""
            } elseif (Test-Path $DOCS_MANOLITO) {
                Start-Process 'explorer.exe' -ArgumentList "`"$DOCS_MANOLITO`""
            }
        } catch { & $appendLog "[REPORT] No se pudo abrir el explorador: $($_.Exception.Message)" }
    })
    $btnManifest.Add_Click({
        if ($script:uiBusy) { return }
        $ofd = [System.Windows.Forms.OpenFileDialog]::new()
        $ofd.Filter = 'Manifest Manolito (*.json)|*.json|Todos (*.*)|*.*'
        $ofd.Title  = 'Seleccionar Manifest de restauracion'
        if ($ofd.ShowDialog() -ne 'OK') { return }
        try {
            & $appendLog "[MANIFEST] Cargando: $($ofd.FileName)"
            $mData  = Get-Content $ofd.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
            $result = Import-ManifestToContext -ManifestData $mData
            $planList   = if ($result -is [hashtable]) { $result.Plan    } else { $result }
            $uiItemList = if ($result -is [hashtable]) { $result.UIItems } else { $null  }
            if ($planList -and $planList.Count -gt 0) {
                if ($uiItemList -and $uiItemList.Count -gt 0) {
                    $icPayloads.ItemsSource = @($uiItemList)
                }
                $script:uiPlanResult = $planList
                & $appendLog "[MANIFEST] Plan restaurado: $($planList.Count) payloads -- listo para RUN"
                & $setStatus "Manifest cargado -- $($planList.Count) acciones listas"
                [System.Windows.MessageBox]::Show(
                    "Manifest cargado correctamente.`n$($planList.Count) acciones listas.`nRevisa el panel y pulsa RUN en modo LIVE para aplicar.",
                    'Manifest OK', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
            } else {
                & $appendLog "[MANIFEST] ERR: Import-ManifestToContext devolvio vacio"
                [System.Windows.MessageBox]::Show("Error al procesar el manifest. Revisa la consola.",'Error Manifest',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
        } catch {
            & $appendLog "[MANIFEST] EXCEPCION: $($_.Exception.Message)"
            [System.Windows.MessageBox]::Show("Excepcion: $($_.Exception.Message)",'Error',
                [System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Error) | Out-Null
        }
    })
    $window.Add_Closed({
        $timer.Stop()
        if ($script:MutexHandle) {
            try { $script:MutexHandle.ReleaseMutex() } catch {}
            $script:MutexHandle.Dispose()
        }
        try { Stop-Transcript } catch {}
    })
    $txtLogo = $window.FindName('txtLogo')
    if ($null -ne $txtLogo) {
        $wadLogo = $null
        try { $wadLogo = $script:ctx.WADData.Logo } catch {}
        if ($wadLogo) {
            $txtLogo.Text = ($wadLogo -join [Environment]::NewLine)
        }
    }
    $window.Add_MouseLeftButtonDown({ $window.DragMove() })
    $btnExit = $window.FindName('btnExit')
    if ($null -ne $btnExit) { 
        $btnExit.Add_Click({ 
            Write-UIBeep "close"
            $btnExit.Content = "[ APAGANDO ]"
            $btnExit.IsEnabled = $false
            $t = New-Object System.Windows.Threading.DispatcherTimer
            $t.Interval = [TimeSpan]::FromMilliseconds(400)
            $t.Add_Tick({ $args[0].Stop(); $window.Close() })
            $t.Start()
        }) 
    }
    Write-UIBeep 'boot'
    $window.ShowDialog() | Out-Null
}
function Get-ConfigValue {
    param([string]$Key, $Default)
    if ($null -ne $script:ctx.Config[$Key]) { return $script:ctx.Config[$Key] }
    return $Default
}
function Show-Logo {
    $logo = $null
    try { $logo = $script:ctx.WADData.Logo } catch {}
    if ($logo) {
        foreach ($line in $logo) { Write-Host $line }
    }
}
function Apply-UIStrings {
    $ui = $null
    try { $ui = $script:ctx.WADData.UIStrings } catch {}
    if (-not $ui) { return }
    if ($ui.FirstRunAuditMessage) { $script:UI_FIRSTRUN    = $ui.FirstRunAuditMessage }
    if ($ui.ReadyMessage)         { $script:UI_READY       = $ui.ReadyMessage }
    if ($ui.LiveConfirm)          { $script:UI_LIVECONFIRM = $ui.LiveConfirm }
    if ($ui.RollbackConfirm)      { $script:UI_ROLLBACK    = $ui.RollbackConfirm }
    if ($ui.IrreversibleConfirm)  { $script:UI_IRREV       = $ui.IrreversibleConfirm }
    if ($ui.AuditCompleted)       { $script:UI_AUDITDONE   = $ui.AuditCompleted }
    if ($ui.ManifestLoaded)       { $script:UI_MANIFEST    = $ui.ManifestLoaded }
}
function Invoke-WADAutoUpdate {
    param(
        [string]$LocalPath,
        [string]$BakPath
    )
    try { $auEnabled = $script:ctx.WADData.Config.WADAutoUpdate.Enabled } catch { $auEnabled = $false }
    if ($auEnabled -ne $true) {
        Write-QLog '[WAD] WADAutoUpdate deshabilitado (local-only policy RC). Usando WAD local.'
        return
    }
    Write-QLog '[WAD] WADAutoUpdate Enabled=true detectado pero canal remoto no disponible en RC.'
    Write-QLog '[WAD] Para activar actualizacion remota, implementar ExpectedSha256 fail-closed.'
}
function Import-WAD {
    if (-not (Test-Path $script:JSONPATH)) {
        [System.Windows.MessageBox]::Show(
            "No se encontro manolito.json en:`n$script:JSONPATH`n`nPolitica local-only: coloca el WAD junto al motor y vuelve a ejecutar.",
            'Manolito Engine - WAD requerido',
            'OK',
            'Error'
        ) | Out-Null
        exit 1
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $raw = Get-Content $script:JSONPATH -Raw -Encoding UTF8
        $rawForHash = $raw -replace '"ExpectedSha256"\s*:\s*"[A-Fa-f0-9]{0,64}"', '"ExpectedSha256": ""'
        $actualHash = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($rawForHash))).Replace('-','')
        $expectedHash = ''
        if ($raw -match '"ExpectedSha256"\s*:\s*"([A-Fa-f0-9]{64})"') { $expectedHash = $Matches[1].ToUpper() }
        if ($expectedHash -and $actualHash -ne $expectedHash) {
            $script:ctx.LogQueue.Enqueue("LOG:[SEC] INTEGRIDAD WAD FALLIDA -- Esperado: $expectedHash / Real: $actualHash")
            [System.Windows.MessageBox]::Show(
                "ALERTA DE SEGURIDAD`nEl archivo manolito.json no coincide con el hash esperado.`n`nEsperado: $expectedHash`nReal:      $actualHash`n`nEl motor NO se iniciara.",
                'Manolito -- Integridad Comprometida', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
            return $false
        }
        if ($expectedHash) { $script:ctx.LogQueue.Enqueue("LOG:[SEC] WAD hash OK: $actualHash") }
        else                { $script:ctx.LogQueue.Enqueue("LOG:[SEC] WARN WAD sin ExpectedSha256 -- sin verificacion de integridad") }
        $raw = $raw -replace '(?m)^\s*//.*$', ''
        $script:ctx.WADData = $raw | ConvertFrom-Json
        $script:Config = $script:ctx.WADData  # O006: referencia directa, elimina round-trip JSON
        $script:PayloadMap = @{}
        if ($script:ctx.WADData.Payloads) {
            foreach ($p in $script:ctx.WADData.Payloads.PSObject.Properties) {
                $script:PayloadMap[$p.Name] = $p.Value
            }
        }
    }
    catch {
        [System.Windows.MessageBox]::Show(
            "Error al parsear manolito.json:`n$($_.Exception.Message)",
            'Manolito Engine - Error', 'OK', 'Error'
        ) | Out-Null
        exit 1
    }
    $sw.Stop()
    if ($sw.ElapsedMilliseconds -gt 2000) {
        Write-Warning "[WAD] ConvertFrom-Json tardo $($sw.ElapsedMilliseconds)ms (umbral 2000ms)"
    }
    Invoke-WADAutoUpdate -LocalPath $script:JSONPATH -BakPath $script:JSONBAKPATH
    $cfgRaw = $script:ctx.WADData.Config
    $script:ctx.Config = @{
        LogMaxLines        = if ($cfgRaw.LogMaxLines)        { [int]$cfgRaw.LogMaxLines }        else { 2000 }
        RunspaceTimeoutSec = if ($cfgRaw.RunspaceTimeoutSec) { [int]$cfgRaw.RunspaceTimeoutSec } else { 600  }
        PollIntervalMs     = if ($cfgRaw.PollIntervalMs)     { [int]$cfgRaw.PollIntervalMs }     else { 50   }
        WADAutoUpdate      = $cfgRaw.WADAutoUpdate
    }
    Apply-UIStrings
    $ver = $null
    try { $ver = $script:ctx.WADData.Manifest.Version } catch {}
    if ($ver -and $ver -notmatch '^2\.[89](\.\d+)?(-\w+)?$') {
        [System.Windows.MessageBox]::Show(
            "JSON Version incompatible: $ver`nSe requiere v2.8.x o v2.9.x",
            'Manolito Engine - Error', [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
        exit 1
    }
    $script:PayloadProviderPlan = @{}
    foreach ($plProp in $script:ctx.WADData.Payloads.PSObject.Properties) {
        $pname  = $plProp.Name
        $pdata  = $plProp.Value
        $keys   = @()
        foreach ($provKey in $script:ProviderMap.Keys) {
            if ($provKey.StartsWith('_name_')) { continue }
            if ($pdata.PSObject.Properties[$provKey]) { $keys += $provKey }
        }
        $byNameKey = "_name_$pname"
        $script:PayloadProviderPlan[$pname] = @{
            ByName   = if ($script:ProviderMap.Contains($byNameKey)) { $byNameKey } else { $null }
            Providers = $keys
        }
    }
    Write-QLog "[INIT] PayloadProviderPlan precalculado: $($script:PayloadProviderPlan.Count) payloads"
    if ($script:ctx.WADData.Config.HostsBlacklist.Enabled -eq $true) {
        Write-QLog "[WARN] Config.HostsBlacklist.Enabled=true pero el modulo no esta implementado -- forzado a false"
        $script:ctx.WADData.Config.HostsBlacklist.Enabled = $false
    }
    return $true
}
$script:wmiRunspace = $null
$script:workerISS  = $null
$script:brushCache    = @{}  # O011: cache de SolidColorBrush por color hex
$script:riskColorMap  = @{ 4='#F44747'; 3='#CE9178'; 2='#DCDCAA'; 1='#4EC9B0'; 0='#D4D4D4' }  # O011
function Get-WmiRunspace {
    if ($null -eq $script:wmiRunspace -or
        $script:wmiRunspace.RunspaceStateInfo.State -ne [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
        if ($null -ne $script:wmiRunspace) { try { $script:wmiRunspace.Dispose() } catch {} }
        $script:wmiRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $script:wmiRunspace.Open()
    }
    return $script:wmiRunspace
}
function Get-WmiSafe {
    param([string]$Class, [int]$TimeoutSec = 5, [string]$Filter = '')
    $rs  = Get-WmiRunspace
    $ps  = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($c, $f)
        try { if ($f) { Get-CimInstance -ClassName $c -Filter $f -ErrorAction Stop }
              else    { Get-CimInstance -ClassName $c -ErrorAction Stop } }
        catch { $null }
    }).AddArgument($Class).AddArgument($Filter)
    $async = $ps.BeginInvoke()
    $completed = $async.AsyncWaitHandle.WaitOne([timespan]::FromSeconds($TimeoutSec))
    try {
        if ($completed) { return $ps.EndInvoke($async) }
        Write-Verbose "Get-WmiSafe: timeout ${TimeoutSec}s para $Class"
        return $null
    } finally {
        if (-not $completed) {
            try { $ps.Stop() } catch {}
        }
        $ps.Dispose()  # solo dispose del PS, NO del runspace (se reutiliza)
    }
}
function Get-SystemCaps {
    $caps = @{}
    $caps.IsVM       = $false
    $caps.IsDomain   = $false
    $caps.IsSafeMode = ($env:SAFEMODE -eq '1') -or
                       ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option' -ErrorAction SilentlyContinue).OptionValue -eq 1)
    try {
        $cs = Get-WmiSafe -Class Win32_ComputerSystem -TimeoutSec 5
        $caps.IsVM     = $cs.Model -match 'Virtual|VMware|VirtualBox|HyperV|Hyper-V|QEMU'
        $caps.IsDomain = $cs.PartOfDomain
    } catch { Write-Debug "Get-SystemCaps WMI/CIM: $($_.Exception.Message)" }
    $caps.HasNVIDIA = $false
    try {
        $gpus = Get-WmiSafe -Class Win32_VideoController -TimeoutSec 5
        $caps.HasNVIDIA = ($gpus | Where-Object { $_.Name -match 'NVIDIA' }) -ne $null
        $caps.HasHAGS   = ($gpus | Where-Object {
            $_.Name -match 'NVIDIA|AMD|Radeon|Intel' -and
            ($_.AdapterRAM -ge 8GB -or $_.Name -match 'RTX|RX 5|RX 6|RX 7|Arc')
        }) -ne $null
    } catch { $caps.HasHAGS = $false }
    $caps.HasNVMe = $false
    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop
        $nvme  = $disks | Where-Object {
            $_.BusType -eq 'NVMe' -or
            $_.MediaType -eq 'SSD' -and $_.FriendlyName -match 'NVMe|NVME' -or
            $_.FriendlyName -match 'NVMe|NVME'
        }
        $caps.HasNVMe = $nvme -ne $null
        if ($caps.HasNVMe) {
            $drv = (Get-WmiSafe -Class Win32_PnPSignedDriver -TimeoutSec 8) |
                   Where-Object { $_.DeviceName -match 'NVMe' } |
                   Select-Object -First 1
            $caps.NVMeDriverIsOEM  = $drv -and $drv.DriverProviderName -notmatch 'Microsoft'
            $caps.NVMeDriverName   = if ($drv) { $drv.DriverProviderName } else { 'Microsoft (generic)' }
        }
    } catch { $caps.NVMeDriverIsOEM = $false; $caps.NVMeDriverName = 'Unknown' }
    $caps.HasBattery = $false
    try { $caps.HasBattery = (Get-WmiSafe -Class Win32_Battery -TimeoutSec 3) -ne $null } catch { Write-Debug "Get-SystemCaps WMI/CIM: $($_.Exception.Message)" }
    $caps.HasPhysicalNIC = $false
    try {
        $nics = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
        $caps.HasPhysicalNIC = $nics -ne $null
    } catch { Write-Debug "Get-SystemCaps WMI/CIM: $($_.Exception.Message)" }
    $caps.HasPrinter = $false
    try { $caps.HasPrinter = (Get-WmiSafe -Class Win32_Printer -TimeoutSec 3) -ne $null } catch { Write-Debug "Get-SystemCaps WMI/CIM: $($_.Exception.Message)" }
    $caps.HasOffice = Test-Path 'HKCU:\Software\Microsoft\Office\16.0'
    $caps.HasOneDrive = Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
    $caps.CanUseWinget = (Get-Command winget -ErrorAction SilentlyContinue) -ne $null
    $caps.PendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                          (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $usbStart = $null
    try {
        $usbStart = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -ErrorAction Stop).Start
    } catch { Write-Debug "Get-SystemCaps WMI/CIM: $($_.Exception.Message)" }
    $caps.USBStorageEnabled  = ($usbStart -eq 2 -or $usbStart -eq 3)
    $caps.USBStorageRawValue = $usbStart
    $caps.MSIState = 'Inactive'
    try {
        $enumRoots = @('HKLM:\SYSTEM\CurrentControlSet\Enum\PCI',
                       'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY',
                       'HKLM:\SYSTEM\CurrentControlSet\Enum\USB')
        $devEnum = $enumRoots | Where-Object { Test-Path $_ } |
                   ForEach-Object { Get-ChildItem $_ -Recurse -Depth 3 -ErrorAction SilentlyContinue } |
                   Where-Object { $_.PSChildName -eq 'Device Parameters' }
        foreach ($dev in $devEnum) {
            $intPath = Join-Path $dev.PSPath 'Interrupt Management'
            if (Test-Path $intPath) {
                $val = (Get-ItemProperty $intPath -Name 'MSISupported' -ErrorAction SilentlyContinue).MSISupported
                if ($val -eq 1) { $caps.MSIState = 'Active'; break }
            }
        }
    } catch { $caps.MSIState = 'Unknown' }
    $hagsVal = $null
    try {
        $hagsVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
    } catch { $hagsVal = $null }
    $caps.HAGSEnabled = ($null -ne $hagsVal -and $hagsVal -eq 2)
    $msVal = $null
    try {
        $msVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name PlatformAoAcOverride -ErrorAction SilentlyContinue).PlatformAoAcOverride
    } catch { $msVal = $null }
    $caps.ModernStandbyEnabled = ($null -eq $msVal -or $msVal -ne 0)   # default = ModernStandby activo si no se puede leer   # default = Modern Standby activo
    $hibVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
    $caps.HibernationEnabled = ($null -ne $hibVal -and $hibVal -eq 1) -or ($null -eq $hibVal)
    try {
        $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled
        $caps.HiberbootEnabled = $hib
    } catch { $caps.HiberbootEnabled = 1 }
    try {
        $caps.WinBuild = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuild
    } catch { $caps.WinBuild = 'N/A' }
    try {
        $blKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'
        $blVal = (Get-ItemProperty $blKey -Name 'PreventDeviceEncryption' -ErrorAction SilentlyContinue).PreventDeviceEncryption
        $caps.BitLockerAutoEncryptionEnabled = ($null -eq $blVal -or $blVal -ne 1)
    } catch { $caps.BitLockerAutoEncryptionEnabled = $true }
    $toggleDefaults = @{
        MSIState             = 'Inactive'
        HiberbootEnabled     = $false
        HAGSEnabled          = $false
        ModernStandbyEnabled = $false
        HibernationEnabled   = $false
        HasNVIDIA            = $false
        HasAMD               = $false
        HasIntelArc          = $false
        HasNVMe              = $false
        BitLockerAutoEncryptionEnabled = $false
    }
    foreach ($kd in $toggleDefaults.Keys) {
        if (-not $caps.Contains($kd)) { $caps[$kd] = $toggleDefaults[$kd] }
    }
    $script:ctx.SystemCaps = $caps
    $script:SystemCaps = $script:ctx.SystemCaps
    try { if ($null -ne $devEnum) { $script:ctx.Cache.EnumDevices = $devEnum } }
    catch { $script:ctx.Cache.EnumDevices = $null }
}
function Write-QLog {
    param([string]$msg)
    if ($null -ne $script:ctx -and $null -ne $script:ctx.LogQueue) {
        $script:ctx.LogQueue.Enqueue("LOG:$msg")
    } elseif ($null -ne $script:logQueue) {
        $script:logQueue.Enqueue("LOG:$msg")
    }
}
function Get-RunlevelList {
    $preferred = @('Lite','DevEdu','Deep','Optional','NvmeFix','Rollback')
    $available = ($script:ctx.WADData.UIMapping.Runlevels |
                  Get-Member -MemberType NoteProperty |
                  Select-Object -ExpandProperty Name)
    $ordered = @($preferred | Where-Object { $_ -in $available })
    $rest    = @($available | Where-Object { $_ -notin $preferred } | Sort-Object)
    return ($ordered + $rest)
}
function Confirm-ExecutionPlan {
    param($PlanResult)
    $plan    = $PlanResult.Plan
    $maxRisk = $PlanResult.MaxRisk
    $activePlan = @($plan | Where-Object { -not $_.Skipped })
    $irrev      = $activePlan | Where-Object { -not $_['Reversible'] }
    $conflictErrors = @($PlanResult.ConflictErrors)
    if ($conflictErrors.Count -gt 0) {
        $conflictMsg = "CONFLICTOS DETECTADOS EN EL PLAN:`n`n" + ($conflictErrors -join "`n") +
            "`n`nEsto significa que dos o mas payloads seleccionados intentan aplicar valores distintos" +
            " a la misma clave de registro. El resultado final dependera del orden de ejecucion." +
            "`n`nDeseas continuar de todos modos?"
        $rc = [System.Windows.MessageBox]::Show($conflictMsg, 'Manolito -- Conflictos en el Plan', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($rc -ne 'Yes') { return $false }
        Write-QLog "[CONFIRM] Conflictos de registro aceptados por usuario ($($conflictErrors.Count) conflicto(s))"
    }
    $warnSel = if ($script:ctx.Runtime.IsDryRun) { @() } else { $activePlan | Where-Object {
        $pname = $_['Name']
        $pmeta = $script:ctx.WADData.Payloads.$pname._meta
        $pmeta -and $pmeta.WarnOnSelect
    } }
    if ($warnSel.Count -gt 0) {
        $wnames = ($warnSel | ForEach-Object { $_['Name'] }) -join ', '
        $warnMsg = "ADVERTENCIA: Los siguientes payloads tienen WarnOnSelect activo:`n$wnames`n`nRevisa cada uno antes de continuar."
        [System.Windows.MessageBox]::Show($warnMsg, 'Atencion -- Seleccion de Riesgo', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
    }
    if (-not $script:ctx.Runtime.IsDryRun) {
        $warnExec = $activePlan | Where-Object {
            $pname = $_['Name']
            $pmeta = $script:ctx.WADData.Payloads.$pname._meta
            $pmeta -and $pmeta.WarnOnExecute
        }
        if ($warnExec.Count -gt 0) {
            $enames = ($warnExec | ForEach-Object { $_['Name'] }) -join ', '
            $execMsg = "ADVERTENCIA PREVIA A EJECUCION:`n`nLos siguientes payloads tienen WarnOnExecute activo:`n$enames`n`nEsta a punto de ejecutar cambios que pueden ser dificiles de revertir.`nDeseas continuar?"
            $er = [System.Windows.MessageBox]::Show($execMsg, 'Atencion -- Ejecucion de Riesgo', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($er -ne 'Yes') { return $false }
            Write-QLog "[WARN] WarnOnExecute aceptado por usuario para: $enames"
        }
    }
    $confirmReq = if ($script:ctx.Runtime.IsDryRun) { @() } else { $activePlan | Where-Object {
        $pname = $_['Name']
        $pmeta = $script:ctx.WADData.Payloads.$pname._meta
        $pmeta -and $pmeta.ConfirmRequired
    } }
    if ($confirmReq.Count -gt 0) {
        $cnames = ($confirmReq | ForEach-Object { $_['Name'] }) -join ', '
        Write-QLog "[CONFIRM] ConfirmRequired detectado para: $cnames (incluido en dialogo de riesgo)"
    }
    if ($irrev.Count -gt 0 -and -not $script:ctx.Runtime.IsDryRun) {
        $names = ($irrev | ForEach-Object { $_['Name'] }) -join ', '
        $msg   = [string]::Format($script:UI_IRREV, $irrev.Count, $names)
        $r = [System.Windows.MessageBox]::Show($msg, 'Manolito Engine', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($r -ne 'Yes') { return $false }
    }
    if ($script:ctx.Runtime.IsDryRun) { return $true }
    $riskLabel = switch ($maxRisk) {
        4 { 'CRITICO' }
        3 { 'ALTO' }
        2 { 'MODERADO' }
        1 { 'BAJO' }
        default { 'INFO' }
    }
    if ($maxRisk -ge 4) {
        $critPayloads = $activePlan | Where-Object { $_['RiskLevel'] -ge 4 }
        $critNames    = ($critPayloads | ForEach-Object { "  - $($_['Name']) ($($_['Label']))" }) -join "`n"
        Write-QLog "[CONFIRM] Riesgo CRITICO detectado: $critNames (incluido en dialogo de riesgo)"
    }
	if ($maxRisk -ge 3) {
        $highPayloads = $activePlan | Where-Object { $_['RiskLevel'] -ge 3 }
        $highNames    = ($highPayloads | ForEach-Object { "  - $($_['Name'])" }) -join "`n"
        $extraNote = if ($maxRisk -ge 4) { "`n`nATENCION: este plan incluye payloads de nivel CRITICO (4). Algunos pueden ser dificiles o imposibles de revertir." } else { "" }
        $confirmNote = if ($confirmReq.Count -gt 0) { "`n`nAdemas, los siguientes payloads requieren confirmacion explicita: $($confirmReq | ForEach-Object { $_['Name'] } | Out-String)".TrimEnd() } else { "" }
        $msg2 = "CONFIRMACION PREVIA -- Riesgo $riskLabel`n`nPayloads de riesgo alto/critico en este plan:`n$highNames$extraNote$confirmNote`n`nRevisa que el equipo tiene un punto de restauracion activo o backup reciente.`n`nConfirmas que quieres continuar?"
        $r2 = [System.Windows.MessageBox]::Show($msg2, "Manolito -- Riesgo $riskLabel", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($r2 -ne 'Yes') { return $false }
        Write-QLog "[CONFIRM] Riesgo $riskLabel -- dialogo de riesgo aceptado (incluye ConfirmRequired/Critico si aplica)"
    }
    $msg = [string]::Format($script:UI_LIVECONFIRM, $activePlan.Count) +
           "`n`nRiesgo maximo del plan: $riskLabel (nivel $maxRisk)" +
           "`nModo: LIVE"
    $r = [System.Windows.MessageBox]::Show($msg, 'Manolito Engine', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
    return ($r -eq 'Yes')
}
function Ensure-WorkerISS {
    if ($null -eq $script:workerISS) {
        $script:workerISS = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $fnFilter = '^(Invoke-Payload|Test-Payload|Test-Manolito|Test-WAD|Get-SystemCaps|Get-Runlevel|Resolve-Runlevel|Save-|Export-|Write-QLog|Build-Execution|Confirm-Execution|Import-Manifest|Load-WAD|ConvertTo-Native|Invoke-Rollback|Invoke-Safe|Invoke-WAD|Invoke-LoadPlan|Write-UIBeep|Get-WmiSafe|Get-WmiRunspace|Resolve-DnsBackup|Push-RollbackEntry|New-PayloadContract|Complete-ProviderContract|Get-RegistrySnapshot)'
        foreach ($fn in (Get-ChildItem Function: | Where-Object { $_.Name -match $fnFilter })) {
            try {
                $sfe = [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($fn.Name, $fn.ScriptBlock.ToString())
                $script:workerISS.Commands.Add($sfe)
            } catch {}
        }
    }
}
function Invoke-RunspaceWorker {
    param(
        [string[]]$PayloadNames,
        [bool]$IsDryRun     = $true,
        [bool]$IsRollback   = $false,
        [switch]$Async,
        [bool]$DoCheckpoint      = $false,
        [string]$CheckpointDesc  = '',
        [bool]$DoPostReport      = $false,
        [string]$PostReportRunlevel = ''
    )
    $timeoutSec = Get-ConfigValue -Key 'RunspaceTimeoutSec' -Default 600
    if ($PayloadNames -contains 'DismResetBase') {
        $timeoutSec = [Math]::Max($timeoutSec, 1800 + 300)
    }
    Ensure-WorkerISS
    $iss = $script:workerISS
    $rs  = [runspacefactory]::CreateRunspace($iss)
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('ctx',           $script:ctx)
    $rs.SessionStateProxy.SetVariable('PayloadMap',    $script:PayloadMap)
    $rs.SessionStateProxy.SetVariable('ProviderMap',   $script:ProviderMap)
    $rs.SessionStateProxy.SetVariable('SystemCaps',    $script:SystemCaps)
    $rs.SessionStateProxy.SetVariable('Config',        $script:Config)
    $rs.SessionStateProxy.SetVariable('wingetBlocked', $script:wingetBlocked)
	$rs.SessionStateProxy.SetVariable('PayloadNames',  $PayloadNames)
	$rs.SessionStateProxy.SetVariable('DOCS_MANOLITO', $DOCS_MANOLITO)
    $rs.SessionStateProxy.SetVariable('MANIFESTDIR',   $script:MANIFESTDIR)
    $rs.SessionStateProxy.SetVariable('MANIFESTPATH',  $script:MANIFESTPATH)
    $rs.SessionStateProxy.SetVariable('logQueue',      $script:ctx.LogQueue)  # fallback explicito
    $rs.SessionStateProxy.SetVariable('PayloadNames',  $PayloadNames)
    $rs.SessionStateProxy.SetVariable('IsDryRun',      $IsDryRun)
    $rs.SessionStateProxy.SetVariable('IsRollback',    $IsRollback)
    $rs.SessionStateProxy.SetVariable('DoCheckpoint',       $DoCheckpoint)
    $rs.SessionStateProxy.SetVariable('CheckpointDesc',     $CheckpointDesc)
    $rs.SessionStateProxy.SetVariable('DoPostReport',       $DoPostReport)
    $rs.SessionStateProxy.SetVariable('PostReportRunlevel', $PostReportRunlevel)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $script:ctx           = $ctx
        $script:PayloadMap    = $PayloadMap
        $script:ProviderMap   = $ProviderMap
        $script:SystemCaps    = $SystemCaps
        $script:Config        = $Config
        $script:wingetBlocked = $wingetBlocked
		$DOCS_MANOLITO        = $DOCS_MANOLITO
        $script:logQueue      = $script:ctx.LogQueue
        $script:ctx.Runtime.IsDryRun   = $IsDryRun
        $script:ctx.Runtime.IsRollback = $IsRollback
        $script:MANIFESTDIR  = $MANIFESTDIR
        $script:MANIFESTPATH = $MANIFESTPATH
        if ($DoCheckpoint) {
            $script:ctx.LogQueue.Enqueue('LOG:[CHECKPOINT] Creando punto de restauracion del sistema...')
            $cp = Invoke-SafeCheckpoint -Description $CheckpointDesc
            if ($cp.Success) { $script:ctx.LogQueue.Enqueue("LOG:[OK] $($cp.Message)") }
            else             { $script:ctx.LogQueue.Enqueue("LOG:[WARN] Checkpoint fallo: $($cp.Message)") }
        }
        $total = $PayloadNames.Count; $current = 0
        foreach ($name in $PayloadNames) {
            $current++
            $pct = [int](($current / $total) * 100)
            $script:ctx.LogQueue.Enqueue("LOG:[${current}/${total}] $name")
            $script:ctx.ProgressQueue.Enqueue("PROG:$pct")
            try {
                $result = Invoke-Payload -PayloadName $name
                if ($result -and -not $result.Skipped) {
                    if ($result.Success -and $result.Changes -gt 0) {
                        $script:ctx.LogQueue.Enqueue("PAYLOAD_OK:$name")
                    } elseif ($result.Success -and $result.Changes -eq 0) {
                        $script:ctx.LogQueue.Enqueue("PAYLOAD_NOCHANGE:$name")
                    } else {
                        $script:ctx.LogQueue.Enqueue("PAYLOAD_FAIL:$name")
                    }
                }
            } catch {
                $script:ctx.LogQueue.Enqueue("LOG:[ERR] $name : $_")
            }
        }
        try {
            $lastMod = if ($script:ctx.Results.Modules.Count -gt 0) { $script:ctx.Results.Modules[-1] } else { $null }
            $statePayload = @{
                State    = @{
                    StepsOk       = $script:ctx.State.StepsOk
                    StepsFail     = $script:ctx.State.StepsFail
                    PendingReboot = $script:ctx.State.PendingReboot
                }
                Delta    = @{
                    LastModule          = $lastMod
                    PayloadsExecuted    = @($script:ctx.Tracking.PayloadsExecuted)
                    IrreversibleActions = @($script:ctx.Tracking.IrreversibleActions)
                }
            } | ConvertTo-Json -Depth 8 -Compress
            $script:ctx.LogQueue.Enqueue("STATE:$statePayload")
        } catch {
            $script:ctx.LogQueue.Enqueue("LOG:    [WARN] STATE serialization failed: $($_.Exception.Message)")
        }
        if ($DoPostReport -and -not $script:ctx.Runtime.IsDryRun) {
            try {
                $rptPath = Export-HTMLReport -RunlevelName $PostReportRunlevel
                $script:ctx.LogQueue.Enqueue("LOG:[REPORT] Reporte generado: $rptPath")
            } catch {
                $script:ctx.LogQueue.Enqueue("LOG:[REPORT] Error al generar reporte: $($_.Exception.Message)")
            }
            Save-FullManifest -RunlevelName $PostReportRunlevel
        }
        $script:ctx.LogQueue.Enqueue('DONE:OK')
        $script:ctx.ProgressQueue.Enqueue('PROG:100')
    })
    $handle = $ps.BeginInvoke()
    if ($Async) {
        return @{ PS = $ps; RS = $rs; Handle = $handle; Deadline = [DateTime]::UtcNow.AddSeconds($timeoutSec) }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSec)
    while (-not $handle.IsCompleted) {
        if ([DateTime]::UtcNow -gt $deadline) {
            $ps.Stop()
            $script:ctx.LogQueue.Enqueue('LOG:[TIMEOUT] Runspace supero limite')
            $script:ctx.LogQueue.Enqueue('DONE:TIMEOUT')
            break
        }
        Start-Sleep -Milliseconds 200
    }
    try { $ps.EndInvoke($handle) } catch { $script:ctx.LogQueue.Enqueue("LOG:[ERR-RS] $_") }
    $ps.Dispose(); $rs.Close(); $rs.Dispose()
}
function Invoke-RollbackStack {
    $stack = $script:ctx.Tracking.RollbackStack
    if ($stack.Count -eq 0) {
        Write-QLog '[ROLLBACK] Pila vacia -- sin entradas que procesar'
        return
    }
    $countA  = 0; $countB = 0; $countC = 0
    $pending = [System.Collections.Generic.List[string]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()
    $item = $null
    while ($stack.TryPop([ref]$item)) { $entries.Add($item) }
    foreach ($entry in $entries) {
        $pname = $entry.PayloadName
        $pkey  = $entry.ProviderKey
        $type  = $entry.Type
        switch ($type) {
            'C' {
                Write-QLog "[ROLLBACK] SKIP-IRR $pname ($pkey) -- irreversible (Type C)"
                $countC++
            }
            'B' {
                Write-QLog "[ROLLBACK] MANUAL  $pname ($pkey) -- accion manual requerida (Type B)"
                if ($entry.Data.Instructions) { Write-QLog "[ROLLBACK]   -> $($entry.Data.Instructions)" }
                $pending.Add("$pname : $($entry.Data.Instructions)")
                $countB++
            }
            'A' {
                Write-QLog "[ROLLBACK] AUTO    $pname ($pkey)"
                $baseKey = if ($pkey -match '^BlueHammer\.') { 'BlueHammer' } else { $pkey }
                $handlerName = $script:ProviderMap[$baseKey]
                if (-not $handlerName) {
                    Write-QLog "[ROLLBACK]   SKIP -- sin handler en ProviderMap para: $pkey"
                    continue
                }
                $cmd = Get-Command $handlerName -CommandType Function -ErrorAction SilentlyContinue
                if (-not $cmd) {
                    Write-QLog "[ROLLBACK]   SKIP -- handler no disponible en runspace: $handlerName"
                    continue
                }
                try {
                    if ($script:ctx.Runtime.IsDryRun) {
                        Write-QLog "  [DRY RUN] Revertira: $pkey"
                        $countA++
                        continue
                    }
                    $res = & $cmd.Name -IsRollback -RollbackEntry $entry
                    if ($res -and $res.Success) {
                        $targetLabel = if ($null -ne $entry.Data.Target) { $entry.Data.Target } else { $pname }
                    Write-QLog "  [OK] Revertido: $pkey -> $targetLabel"
                        $countA++
                    } else {
                        Write-QLog "  [FAIL] Error revirtiendo $pkey"
                        if ($res -and $res.PendingAction) {
                            $pending.Add("$pname ($pkey): $($res.PendingAction)")
                            $countB++
                        }
                    }
                } catch {
                    Write-QLog "  [FAIL] Excepcion no controlada en $($pkey): $($_.Exception.Message)"
                }
            }
        }
    }
    $total = $countA + $countB + $countC
    Write-QLog "[ROLLBACK] Completado: $total entradas procesadas (AUTO=$countA MANUAL=$countB SKIP=$countC)"
    if ($pending.Count -gt 0) {
        $msg = "Las siguientes acciones requieren intervencion manual:`n" + ($pending -join "`n")
        [System.Windows.MessageBox]::Show($msg, 'Rollback - Acciones Manuales', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
    }
}
function Invoke-RollbackSession {
    $applied = $script:ctx.Tracking.AppliedPayloads
    if ($applied.Count -eq 0 -and $script:ctx.Tracking.RollbackStack.Count -eq 0) {
        Write-QLog '[ROLLBACK] Sin payloads aplicados en esta sesion'
        return
    }
    Write-QLog "[ROLLBACK] Iniciando rollback -- $($applied.Count) payloads aplicados"
    Invoke-RollbackStack
}
function Load-Manifest {
    if (-not (Test-Path $script:MANIFESTPATH)) { return }
    try {
        $mf  = Get-Content $script:MANIFESTPATH -Raw | ConvertFrom-Json
        $cnt = @($mf.AppliedPayloads).Count
        Write-QLog ([string]::Format($script:UI_MANIFEST, $cnt))
    } catch { Write-QLog "[WARN] Load-Manifest: $_" }
}
function Start-ManolitoEngine {
    Show-SplashWindow
}
function Invoke-PayloadSkuSiPolicy {
    param($Payload, [string]$PayloadName,
          [switch]$IsRollback,
          [object]$RollbackEntry)
    $ctr = New-PayloadContract; $logs = $ctr.Logs
    if ($IsRollback) {
        $data = $RollbackEntry.Data
        try {
            if ($data.BackupPath -and (Test-Path $data.BackupPath)) {
                $p7bHash = (Get-FileHash $data.BackupPath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
                if ($data.OriginalHash -and $p7bHash -and $p7bHash -ne $data.OriginalHash) {
                    Write-QLog "[ROLLBACK]   WARN SkuSiPolicy.p7b hash no coincide -- abortando eliminacion"
                } else {
                    Remove-Item $data.BackupPath -Force -ErrorAction Stop
                    $ctr.Changes++
                    Write-QLog "[ROLLBACK]   SkuSiPolicy.p7b eliminado del ESP"
                }
            } else {
                Write-QLog "[ROLLBACK]   SkuSiPolicy.p7b no encontrado -- posiblemente ya eliminado"
            }
        } catch { Write-QLog "[ROLLBACK]   ERR SkuSiPolicy: $_" }
        return @{ Success = $true }
    }
    $espPath = $null
    try {
        $espPart = Get-Partition -ErrorAction SilentlyContinue |
                   Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
                   Select-Object -First 1
        if ($espPart) {
            $espVol  = Get-Volume -Partition $espPart -ErrorAction SilentlyContinue
            if ($espVol -and $espVol.DriveLetter) { $espPath = "$($espVol.DriveLetter):" }
        }
    } catch {}
    if (-not $espPath) {
        try {
            $vols = & mountvol 2>$null
            foreach ($line in $vols) {
                $line = $line.Trim()
                if ($line -match '^[A-Z]:\\$') {
                    $candidate = $line.TrimEnd('\')
                    $efi = Join-Path $candidate 'EFI'
                    if (Test-Path $efi) { $espPath = $candidate; break }
                }
            }
        } catch {}
    }
    if (-not $espPath) {
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -eq 'Fixed') {
                $efi = Join-Path $drive.RootDirectory.FullName 'EFI'
                if (Test-Path $efi) { $espPath = $drive.RootDirectory.FullName.TrimEnd('\'); break }
            }
        }
    }
    if (-not $espPath) {
        $logs.Add("ERR SkuSiPolicy -- no se pudo localizar el ESP (EFI System Partition)")
        return @{ Success = $false; Changes = 0; Logs = $logs }
    }
    $destDir  = Join-Path $espPath 'EFI\Microsoft\Boot'
    $destFile = Join-Path $destDir 'SkuSiPolicy.p7b'
    $customPath = if ($Payload.PSObject.Properties['SkuSiPolicyTemplate'] -and
                         $Payload.SkuSiPolicyTemplate.PSObject.Properties['CustomPolicyPath']) {
                      $Payload.SkuSiPolicyTemplate.CustomPolicyPath
                  } else { $null }
    $srcFile = if ($customPath -and (Test-Path $customPath)) {
        $logs.Add("INFO SkuSiPolicy: usando custom policy: $customPath")
        $customPath
    } else {
        $logs.Add("WARN SkuSiPolicy: CustomPolicyPath no definido -- usando policy del sistema (fallback)")
        Join-Path $env:SystemRoot 'Boot\EFI\SkuSiPolicy.p7b'
    }
    if (-not (Test-Path $srcFile)) {
        $logs.Add("ERR SkuSiPolicy -- origen no encontrado: $srcFile")
        return @{ Success = $false; Changes = 0; Logs = $logs }
    }
    if ($script:ctx.Runtime.IsDryRun) {
        $logs.Add("DRY SkuSiPolicy -- copiaria $srcFile -> $destFile")
        return Complete-ProviderContract $ctr
    }
    try {
        if (-not (Test-Path $destDir)) { New-Item $destDir -ItemType Directory -Force | Out-Null }
        $originalHash = (Get-FileHash $srcFile -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        Copy-Item $srcFile $destFile -Force -ErrorAction Stop
        $ctr.Changes++
        $logs.Add("OK  SkuSiPolicy.p7b copiado a ESP: $destFile")
        $logs.Add("INFO Requiere reinicio para activarse. Requiere reinicio del sistema")
        Push-RollbackEntry -Condition (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) `
                -PayloadName $PayloadName -ProviderKey 'SkuSiPolicyTemplate' -Type 'A' -IsIRR $false -Data @{ BackupPath = $destFile; OriginalHash = $originalHash }
    } catch {
        $logs.Add("ERR SkuSiPolicy -- $_")
        $ctr.Success = $false
    }
    return Complete-ProviderContract $ctr
}
$script:ProviderMap = [ordered]@{
    'Packages'               = 'Invoke-PayloadAppxpackages'
    'Services'               = 'Invoke-PayloadServices'
    'Tasks'                  = 'Invoke-PayloadTasks'
    'Registry'               = 'Invoke-PayloadRegistry'
    'RegistryKeys'           = 'Invoke-PayloadRegistryKeys'
    'NagleTemplate'          = 'Invoke-PayloadNagle'
    'DNS'                    = 'Invoke-PayloadDNS'
    'BCD'                    = 'Invoke-PayloadBCD'
    'DeviceClasses'          = 'Invoke-PayloadMSITuning'
    'WingetPackages'         = 'Invoke-PayloadWinget'
    'NvidiaOptimizeTemplate' = 'Invoke-PayloadNvidiaOptimize'
    'NICProperties'          = 'Invoke-PayloadNICTuning'
    'UltimatePowerPlan'      = 'Invoke-PayloadUltimatePower'
    'TimerResConfig'         = 'Invoke-PayloadTimerResolution'
    'PowercfgSettings'       = 'Invoke-PayloadPowercfg'
    'WindowsFeatures'        = 'Invoke-PayloadWindowsFeatures'
    'TempCleanup'            = 'Invoke-PayloadCleanup'
    'DismResetBase'          = 'Invoke-PayloadCleanup'
    'ActiveSetupEntries'     = 'Invoke-PayloadActiveSetup'
    'HostsEntries'           = 'Invoke-PayloadHosts'
    'ACL'                    = 'Invoke-PayloadACL'
    'Blacklist'              = 'Invoke-PayloadDeKMS'
    'OneDriveUninstall'      = 'Invoke-PayloadOneDrive'
    'USBStorageTemplate'     = 'Invoke-PayloadUSBStorage'
    'NVMeProtectTemplate'    = 'Invoke-PayloadNVMeProtect'
    'BlueHammer'             = 'Invoke-PayloadBlueHammer'
    'SkuSiPolicyTemplate'    = 'Invoke-PayloadSkuSiPolicy'
    'RegistryTemplate'       = 'Invoke-PayloadMSITuning'
}
Start-ManolitoEngine
