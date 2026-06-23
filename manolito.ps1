<#
.SYNOPSIS
    Manolito v2.9.0
.DESCRIPTION
    Script de configuracion y hardening Windows basado en archivo de datos JSON (WAD).
    Arquitectura modular. UI WPF reactiva. Ejecucion asincrona con runspace.
    Soporta modos DRY RUN y LIVE con modo rollback.
.NOTES
    Requiere ejecucion como Administrador.
    Archivo de datos: manolito.json (poner en la misma carpeta).
#>

#Requires -RunAsAdministrator
Add-Type -AssemblyName PresentationFramework
# BOOT: System.Windows.Forms se carga bajo demanda en Show-MainWindow (lazy load)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ========================================================================
# 1. BOOTSTRAP Y CARGA DE DATOS
# ========================================================================
$DOCS_MANOLITO    = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Manolito'
$script:MANIFESTDIR  = $DOCS_MANOLITO
$script:MANIFESTPATH = Join-Path $script:MANIFESTDIR 'manifest.json'
$script:logQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()  # P0: cola canonica Write-QLog
# P1: Defaults UI strings -- sobrescritos por Apply-UIStrings si el JSON los define
$script:UI_FIRSTRUN    = 'Ejecuta la auditoria previa antes de aplicar cambios.'
$script:UI_READY       = 'Sistema listo. Selecciona un runlevel y confirma.'
$script:UI_LIVECONFIRM = 'Vas a aplicar cambios en este sistema. Continuar?'
$script:UI_ROLLBACK    = 'Revertir los cambios aplicados en esta sesion?'
$script:UI_IRREV       = "Existen {0} cambios irreversibles en el plan:`n{1}`n`nAceptas continuar? Esta accion no se puede deshacer."
$script:UI_AUDITDONE   = 'Auditoria completada.'
$script:UI_MANIFEST    = 'Historial cargado: {0} payloads aplicados.'
$script:JSONPATH    = Join-Path $PSScriptRoot 'manolito.json'
$JSON_PATH          = $script:JSONPATH                                    # alias legacy
$script:JSONBAKPATH = Join-Path $PSScriptRoot 'manolito.json.bak'

# ========================================================================
# RUNTIME CONTEXT - inicializado antes de cualquier uso de $script:ctx
# ========================================================================
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
        RollbackStack       = [System.Collections.Concurrent.ConcurrentStack[object]]::new()  # NEW-03: thread-safe
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
    LogQueue      = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()  # async runspace->UI
    ProgressQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()  # progreso runspace->UI
}
$script:scriptctx = $script:ctx  # alias legacy para providers

# C-03: Mutex renombrado Global\ManolitoEngine
$script:MutexHandle = [System.Threading.Mutex]::new($false, 'Global\ManolitoEngine')
try { $acquired = $script:MutexHandle.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { Write-Error 'Manolito ya esta en ejecucion'; exit 1 }

# Transcript
if (-not (Test-Path $DOCS_MANOLITO)) { New-Item -Path $DOCS_MANOLITO -ItemType Directory -Force | Out-Null }
try {
    $transcriptPath = Join-Path $DOCS_MANOLITO ("transcript_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Start-Transcript -Path $transcriptPath -Append
} catch { Write-Warning ("Transcript no disponible: {0}" -f $_.Exception.Message) }

# $script:NvidiaExclusivePayloads y $script:NVMePayloads ELIMINADOS.

# ========================================================================
# 2. MOTOR DE AUDIO Y HELPERS
# ========================================================================
function Invoke-SafeCheckpoint {
    param([string]$Description = "Manolito Engine - Pre-Execution Checkpoint")
    try {
        $wmi = Get-WmiObject -Class SystemRestore -Namespace root\default -ErrorAction Stop
        $null = ([wmiclass]"\\localhost\root\default:SystemRestore").CreateRestorePoint(
            $Description, 12, 100   # 12=APPLICATION_INSTALL, 100=BEGIN_SYSTEM_CHANGE
        )
        return @{ Success = $true;  Message = "Checkpoint creado: $Description" }
    } catch {
        # Fallback: Enable-ComputerRestore por si el proveedor WMI falla
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
            Checkpoint-Computer -Description $Description -RestorePointType APPLICATION_INSTALL -ErrorAction Stop
            return @{ Success = $true;  Message = "Checkpoint (fallback) creado: $Description" }
        } catch {
            return @{ Success = $false; Message = $_.Exception.Message }
        }
    }
}

function global:Write-UIBeep($tipo) {
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

function Test-AVInterference {
    $edrProcs    = @(Get-Process csagent, falconctl, carbonblack, SentinelAgent, cb -EA SilentlyContinue)
    $edrServices = @(Get-Service CSFalconService, CarbonBlack, SentinelAgent -EA SilentlyContinue | Where-Object { $_.Status -eq 'Running' })
    return ($edrProcs.Count -gt 0 -or $edrServices.Count -gt 0)
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
        [System.Windows.Forms.MessageBox]::Show(
            "Ciclo detectado en runlevel DAG: $Name",
            'Manolito Engine', 'OK', 'Error') | Out-Null
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
            $subList = Resolve-Runlevel -Name $ref -Visited ([System.Collections.Generic.HashSet[string]]::new($Visited))
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
        # Provider check -- P1-C: validar TODOS los providers del payload, no solo el primero
        $provKeys = @($p | Get-Member -MemberType NoteProperty |
                     Where-Object Name -ne '_meta' |
                     Select-Object -ExpandProperty Name)
        foreach ($provKey in $provKeys) {
            $mapped = switch ($provKey) {
                'Services'              { 'Services'      }
                'Tasks'                 { 'Tasks'         }
                'Registry'              { 'Registry'      }
                'RegistryKeys'          { 'RegistryKeys'  }
                'NagleTemplate'         { 'Nagle'         }
                'DNS'                   { 'DNS'           }
                'BCD'                   { 'BCD'           }
                'DeviceClasses'         { 'MSITuning'     }
                'WingetPackages'        { 'Winget'        }
                'NvidiaOptimizeTemplate'{ 'NvidiaOptimize'}
                'OneDriveUninstall'     { 'OneDrive'      }
                'NICProperties'         { 'NICTuning'     }
                'UltimatePowerPlan'     { 'UltimatePower' }
                'TimerResConfig'        { 'TimerResolution'}
                'PowercfgSettings'      { 'Powercfg'      }
                'WindowsFeatures'       { 'WindowsFeatures'}
                'TempCleanup'           { 'Cleanup'       }
                'DismResetBase'         { 'Cleanup'       }
                'ActiveSetupEntries'    { 'ActiveSetup'   }
                'HostsEntries'          { 'Hosts'         }
                'Packages'              { 'Appxpackages'  }
                'BlueHammerStub'        { 'BlueHammer'    }
                'Blacklist'             { 'DeKMS'         }
                'Files'                 { 'DeKMS'         }
                'RegistryTemplate'      { 'MSITuning'     }
                'ACL'                   { 'ACL'           }
                'USBStorageTemplate'    { 'USBStorage'    }
                'NVMeProtectTemplate'   { 'NVMeProtect'   }
                'BlueHammer'            { 'BlueHammer'    }
                default                 { $provKey        }
            }
            if ($mapped -notin $script:SpecializedProviders -and $mapped -ne 'DeKMS') {
                $errors.Add("[$name] Provider desconocido: $provKey -> $mapped")
            }
        }
    }
    # R2-B08: regla Rollback -- todo payload en runlevel Rollback debe ser Reversible=true
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
        [System.Windows.Forms.MessageBox]::Show($msg, 'Manolito Engine - WAD Error', 'OK', 'Error') | Out-Null
        exit 1
    }
}
# B-01: DynamicToggle Pattern
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


function Invoke-ExternalCommand {
    param(
        [string]$Command,
        [int]$TimeoutSec  = 30,
        [int]$MaxRetries  = 2
    )
    if ($Command -match '^"([^"]+)"\s*(.*)$') {
        $exe = $Matches[1]; $exeArgs = $Matches[2]
    }
    elseif ($Command -match '^(\S+)\s*(.*)$') {
        $exe = $Matches[1]; $exeArgs = $Matches[2]
    }
    else { $exe = $Command; $exeArgs = '' }

    for ($i = 0; $i -le $MaxRetries; $i++) {
        $proc = $null
        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = $exe
            $psi.Arguments              = $exeArgs
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true

            $proc        = [System.Diagnostics.Process]::Start($psi)
            $stdoutTask  = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask  = $proc.StandardError.ReadToEndAsync()
            $completed   = $proc.WaitForExit($TimeoutSec * 1000)
            $stdout      = $stdoutTask.Result
            $stderr      = $stderrTask.Result

            if (-not $completed) {
                try { $proc.Kill() } catch {}
                if ($i -lt $MaxRetries) { continue }
                return @{ Success = $false; Stdout = $stdout; Stderr = $stderr; ExitCode = -1; Error = "Timeout tras $($TimeoutSec)s" }
            }

            $exitCode = $proc.ExitCode

            if ($exe -match 'winget' -and $exitCode -eq -1978335157) {
                $script:wingetBlocked = $true
            }

            return @{
                Success  = ($exitCode -eq 0)
                Stdout   = $stdout
                Stderr   = $stderr
                ExitCode = $exitCode
                Error    = if ($exitCode -ne 0) { "ExitCode $exitCode -- $stderr" } else { $null }
            }
        }
        catch {
            if ($i -lt $MaxRetries) { continue }
            return @{ Success = $false; Stdout = ''; Stderr = $_.Exception.Message; ExitCode = -1; Error = "Excepcion: $($_.Exception.Message)" }
        }
        finally {
            if ($null -ne $proc) { try { $proc.Dispose() } catch {} }
        }
    }
    return @{ Success = $false; Error = 'Reintentos agotados'; ExitCode = -1 }
}

function Set-ManolitoReg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    $before = try { (Get-ItemProperty $Path -Name $Name -EA Stop).$Name } catch { $null }
    if ($null -ne $before -and $before -is [string]) { $before = $before.ToString() }

    if ($script:ctx.Runtime.IsDryRun) { return @{ Success = $true; Changes = 1; DryRun = $true; Msg = "[DRY] $Name -> $Value" } }
    if ($null -ne $before -and "$before" -eq "$Value") { return @{ Success = $true; Changes = 0; Msg = "    [SKIP] $Name (sin cambio)" } }

    try {
        if (!(Test-Path $Path)) { New-Item $Path -Force | Out-Null }
        Set-ItemProperty $Path -Name $Name -Value $Value -Type $Type -Force -EA Stop
        $script:ctx.Tracking.RegDiff.Add([PSCustomObject]@{ Path = $Path; Name = $Name; Type = $Type; Before = $before; After = $Value })
        return @{ Success = $true; Changes = 1; Msg = "[OK] $Name" }
    }
    catch {
        return @{ Success = $false; Changes = 0; Msg = "[FAIL] $($Name): $($_.Exception.Message)" }
    }
}


function Invoke-PayloadWindowsFeatures {

    param($Payload, [string]$PayloadName)
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Payload.WindowsFeatures) {
        $logs.Add("DISM $($f.Name) -> $($f.TargetState)")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        try {
            if ($f.TargetState -eq 'Disable') {
                dism.exe /Online /Disable-Feature /FeatureName:$f.Name /NoRestart /Quiet 2>$null | Out-Null
            } else {
                dism.exe /Online /Enable-Feature /FeatureName:$f.Name /NoRestart /Quiet 2>$null | Out-Null
            }
            $changed.Add("$($f.Name) -> $($f.TargetState)")
        } catch { $success = $false; $logs.Add("ERR Feature $($f.Name) : $($_.Exception.Message)") }
    }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $changed.Count -gt 0) {
        $inverse = $changed | ForEach-Object { $_ -replace '-> Disable','-> Enable' -replace '-> Enable','-> Disable' }
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'WindowsFeatures'
            Type        = 'B'
            IsIRR       = $false
            Data        = @{
                Instructions = "Revertir manualmente via DISM: $($inverse -join '; ')"
            }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadCleanup {

    param($Payload, [string]$PayloadName)
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $isDism = ($null -ne $Payload.DismResetBase)
    if ($isDism) {
        $logs.Add('DISM ResetBase - WinSxS cleanup')
        if ($script:ctx.Runtime.IsDryRun) { return @{ Success = $true; Changes = 0; Logs = $logs } }
        try {
            # dism.exe | Out-Null bloquea el runspace durante toda la ejecucion (puede ser
            # varios minutos). Fix: usar Invoke-ExternalCommand con timeout generoso (30min) para
            # mantener el progressQueue activo y evitar que la UI parezca congelada.
            $dismResult = Invoke-ExternalCommand -Command 'dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet' -TimeoutSec 1800 -MaxRetries 0
            if (-not $dismResult.Success) {
                $logs.Add("WARN DismResetBase ExitCode $($dismResult.ExitCode): $($dismResult.Stderr)")
                # DISM puede devolver exit codes no-0 en warnings no criticos -- no marcar como fail
                if ($dismResult.ExitCode -notin @(0, 3010, 50)) { $success = $false }
            }
        } catch { $success = $false; $logs.Add("ERR DismResetBase : $($_.Exception.Message)") }
        # Type C: irreversible
        if (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) {
            $script:ctx.Tracking.RollbackStack.Push(@{
                PayloadName = $PayloadName
                ProviderKey = 'TempCleanup'
                Type        = 'C'
                IsIRR       = $true
                Data        = @{ Note = 'DISM ResetBase elimina componentes de Windows de forma permanente' }
            })
        }
    } else {
        $logs.Add('CLEAN Limpiando temporales')
        if ($script:ctx.Runtime.IsDryRun) { return @{ Success = $true; Changes = 0; Logs = $logs } }
        $dirs = @($env:TEMP, $env:TMP, "$env:SystemRoot\Temp")
        foreach ($d in $dirs) {
            Get-ChildItem $d -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        $changes++
        # Limpieza temporal: no empuja RollbackEntry (datos efimeros, sin valor de restore)
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadAppxpackages {

    param($Payload, [string]$PayloadName)
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $removed = [System.Collections.Generic.List[string]]::new()
    foreach ($pkg in $Payload.Packages) {
        $logs.Add("APPX Eliminando $($pkg.FriendlyName)")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        try {
            Get-AppxPackage -Name $pkg.Pattern -AllUsers -ErrorAction SilentlyContinue |
                Remove-AppxPackage -ErrorAction SilentlyContinue
            # -match con patrones "*Microsoft.BingNews*" es regex invalido en PS5.1
            # (asterisco sin cuantificando previo). Fix: usar -like que acepta wildcards nativos.
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.PackageName -like $pkg.Pattern } |
                Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
            $removed.Add($pkg.FriendlyName)
        } catch { $logs.Add("WARN Appx $($pkg.FriendlyName) : $($_.Exception.Message)") }
    }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $removed.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'Packages'
            Type        = 'B'
            IsIRR       = $false
            Data        = @{
                RemovedPackages = $removed.ToArray()
                Instructions    = "Reinstalar manualmente desde Microsoft Store: $($removed -join ', ')"
            }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadServices {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
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
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $rbEntries = [System.Collections.Generic.List[object]]::new()

    foreach ($svc in $Payload.Services) {
        $name   = $svc.Name
        $target = $svc.TargetState
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
            $changes++
            $rbEntries.Add(@{
                Name          = $name
                Before        = $beforeStartup
                WasRunning    = $wasRunning
            })
        } catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
            # Servicios eliminados en Win11 24H2 (utcsvc, diagnosticshub.standardcollector.service)
            # Get-Service lanza ServiceCommandException con "Cannot find any service with service name".
            # No es un error de ejecucion -- se registra como SKIP en lugar de ERR para no marcar
            # el payload como fallido en sistemas actualizados.
            if ($_.Exception.Message -match 'Cannot find any service') {
                $logs.Add("SKIP SVC $name -- no existe en este OS (eliminado en 24H2 o superior)")
            } else {
                $success = $false; $logs.Add("ERR SVC $name : $($_.Exception.Message)")
            }
        } catch {
            $success = $false; $logs.Add("ERR SVC $name : $_")
        }
    }

    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'Services'
            Type        = 'A'
            IsIRR       = $false
            Data        = @{ Entries = $rbEntries.ToArray() }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadTasks {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
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
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $rbEntries = [System.Collections.Generic.List[object]]::new()

    foreach ($t in $Payload.Tasks) {
        $full = "$($t.Path)\$($t.Name)"
        $logs.Add("TASK $full -> $($t.TargetState)")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        try {
            $existing = Get-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction SilentlyContinue
            $wasEnabled = $false
            if ($existing) {
                $wasEnabled = ($existing.Settings.Enabled -eq $true)
            }

            if ($t.TargetState -eq 'Disable') {
                Disable-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop | Out-Null
            } else {
                Enable-ScheduledTask  -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop | Out-Null
            }
            $changes++
            $rbEntries.Add(@{
                Name       = $t.Name
                Path       = $t.Path
                WasEnabled = $wasEnabled
            })
        } catch { $logs.Add("WARN TASK $full : $_") }
    }

    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'Tasks'
            Type        = 'A'
            IsIRR       = $false
            Data        = @{ Entries = $rbEntries.ToArray() }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadRegistry {

    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
        $allOk = $true
        foreach ($r in $data.Entries) {
            try {
                if ($null -eq $r.Before) {
                    Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction Stop
                } else {
                    Set-ItemProperty -Path $r.Path -Name $r.Name -Value $r.Before -Type $r.Type -Force -ErrorAction Stop
                }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR Registry $($r.Path)\$($r.Name): $_" }
        }
        return @{ Success = $allOk }
    }
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    # Desduplicar entradas Registry por (Path+Name) -- evita doble-apply
    # cuando el mismo valor aparece en dos payloads del mismo runlevel (e.g. TaskbarDa
    # en DisableWidgets y DebloatW11Nuisances) o por error de copia en el JSON.
    $seenRegKeys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($r in $Payload.Registry) {
        # v2.9.0: normalizar Value->TargetValue (compat schema legacy)
        $tv = if ($null -ne $r.TargetValue) { $r.TargetValue } else { $r.Value }
        $dedupKey = "$($r.Path)|$($r.Name)"
        if (-not $seenRegKeys.Add($dedupKey)) {
            $logs.Add("SKIP-DUP REG $($r.Path) $($r.Name) (duplicado en payload)")
            continue
        }
        $logs.Add("REG $($r.Path) $($r.Name) = $tv")
        if ($script:ctx.Runtime.IsDryRun) { $changes++; continue }
        try {
            $before = $null
            try { $before = (Get-ItemProperty $r.Path -Name $r.Name -ErrorAction Stop).$($r.Name) } catch { $before = $null; Write-QLog "[WARN-SNAP] No se pudo leer valor previo (Registry $($r.Path)): $($_.Exception.Message)" }
            # v2.9.0: CreateIfMissing -- crear path solo si la flag lo permite (default: true)
            $shouldCreate = ($null -eq $r.CreateIfMissing -or $r.CreateIfMissing -eq $true)
            if (-not (Test-Path $r.Path)) {
                if ($shouldCreate) { New-Item -Path $r.Path -Force | Out-Null }
                else { $logs.Add("SKIP REG $($r.Path) -- ruta no existe y CreateIfMissing=false"); continue }
            }
            Set-ItemProperty -Path $r.Path -Name $r.Name -Value $tv -Type $r.Type -Force
            $changes++
            $rbEntries.Add(@{ Path = $r.Path; Name = $r.Name; Type = $r.Type; Before = $before })
        } catch { $success = $false; $logs.Add("ERR REG $($r.Path) $($r.Name) : $($_.Exception.Message)") }
    }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'Registry'
            Type        = 'A'
            IsIRR       = $false
            Data        = @{ Entries = $rbEntries.ToArray() }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadRegistryKeys {

    param($Payload, [string]$PayloadName)
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $Payload.RegistryKeys) {
        $logs.Add("REGKEY $($r.Path)")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        try {
            if ($r.Action -eq 'Delete') {
                Remove-Item -Path $r.Path -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                New-Item -Path $r.Path -Force | Out-Null
            }
            $changed.Add("$($r.Action) $($r.Path)")
        } catch { $success = $false; $logs.Add("ERR REGKEY $($r.Path) : $($_.Exception.Message)") }
    }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $changed.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'RegistryKeys'
            Type        = 'B'
            IsIRR       = $false
            Data        = @{
                Instructions = "Revisar manualmente las claves modificadas: $($changed -join '; ')"
            }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadNagle {

    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
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
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $logs.Add('NAGLE Desactivando algoritmo Nagle en NIC activa')
    if ($script:ctx.Runtime.IsDryRun) { return @{ Success = $true; Changes = 0; Logs = $logs } }
    # Guard HasPhysicalNIC -- en VMs sin NIC fisica Get-NetAdapter puede lanzar excepcion
    if (-not $script:ctx.SystemCaps.HasPhysicalNIC) {
        $logs.Add('SKIP NAGLE -- HasPhysicalNIC=false (sin NIC fisica activa detectada)')
        return @{ Success = $true; Changes = 0; Logs = $logs }
    }
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    try {
        $guid = (Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1).InterfaceGuid
        if (-not $guid) { $logs.Add('SKIP No NIC activa encontrada'); return }
        $base = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
        foreach ($e in $Payload.NagleTemplate) {
            $before = $null
            try { $before = (Get-ItemProperty $base -Name $e.Name -ErrorAction Stop).$($e.Name) } catch { $before = $null; Write-QLog "[WARN-SNAP] No se pudo leer valor previo (Nagle $base): $($_.Exception.Message)" }
            if (-not (Test-Path $base)) { New-Item -Path $base -Force | Out-Null }
            Set-ItemProperty -Path $base -Name $e.Name -Value $e.TargetValue -Type $e.Type -Force
            $rbEntries.Add(@{ Path = $base; Name = $e.Name; Type = $e.Type; Before = $before })
        }
    } catch { $success = $false; $logs.Add("ERR Nagle : $($_.Exception.Message)") }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'NagleTemplate'
            Type        = 'A'
            IsIRR       = $false
            Data        = @{ Entries = $rbEntries.ToArray() }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadDNS {

    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
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
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $logs.Add("DNS -> $($Payload.DNS.Primary.TargetValue) / $($Payload.DNS.Secondary.TargetValue)")
    if ($script:ctx.Runtime.IsDryRun) { return @{ Success = $true; Changes = 0; Logs = $logs } }
    # Guard HasPhysicalNIC para DNS
    if (-not $script:ctx.SystemCaps.HasPhysicalNIC) {
        $logs.Add('SKIP DNS -- HasPhysicalNIC=false (sin NIC fisica activa detectada)')
        return @{ Success = $true; Changes = 0; Logs = $logs }
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
    } catch { $success = $false; $logs.Add("ERR DNS : $($_.Exception.Message)") }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'DNS'
            Type        = 'A'
            IsIRR       = $false
            Data        = @{ Entries = $rbEntries.ToArray() }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadBCD {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
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
    $logs      = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes   = 0
    $rbEntries = [System.Collections.Generic.List[object]]::new()

    foreach ($b in $Payload.BCD) {
        $logs.Add("BCD $($b.Setting) -> $($b.TargetValue)")
        if ($script:ctx.Runtime.IsDryRun) { $changes++; continue }
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
            $changes++
        } catch { $success = $false; $logs.Add("ERR BCD $($b.Setting) : $_") }
    }

    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'BCD'
            Type        = 'A'
            IsIRR       = $false
            Data        = @{ Entries = $rbEntries.ToArray() }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadMSITuning {

    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
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
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0

    $msiOwned    = Test-ManolitoOwnership 'MSITuning'
    $msiExternal = $false
    try {
        # Comprobar si ya hay MSISupported=1 en algun dispositivo (aplicado por herramienta externa)
        # Win32_PnPEntity CIM en lugar de Get-ChildItem -Recurse (OOM en VMs)
        $pnpAll = Get-CimInstance Win32_PnPEntity -Filter "PNPClass = 'Display' OR PNPClass = 'NVMe'" `
                  -ErrorAction SilentlyContinue
        foreach ($pnp in $pnpAll) {
            $devId   = $pnp.DeviceID
            if ([string]::IsNullOrEmpty($devId)) { continue }
            $intPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$devId\Device Parameters\Interrupt Management"
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
    if ($script:ctx.Runtime.IsDryRun) { return @{ Success = $true; Changes = 0; Logs = $logs } }
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    # FIX-MEM: usar Win32_PnPEntity filtrado por CIM en lugar de Get-ChildItem -Recurse
    # en HKLM:\SYSTEM\CurrentControlSet\Enum (15k-50k subclaves = OOM en VMs con <4GB RAM)
    foreach ($class in $Payload.DeviceClasses) {
        $cimClass = if ($class -eq 'Display') { 'Display' } else { $class }
        try {
            $pnpDevs = Get-CimInstance Win32_PnPEntity -Filter "PNPClass = '$cimClass'" `
                       -ErrorAction SilentlyContinue
            if (-not $pnpDevs) {
                $logs.Add("INFO MSI $class : sin dispositivos de clase '$cimClass' detectados (VM/sin hardware)")
                continue
            }
            foreach ($pnp in $pnpDevs) {
                # DeviceID formato: PCI\VEN_xxxx&DEV_xxxx\... → ruta en Enum
                $devId = $pnp.DeviceID -replace '\',''
                if ([string]::IsNullOrEmpty($devId)) { continue }
                $enumPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$devId"
                if (-not (Test-Path $enumPath)) {
                    $logs.Add("  [MSI] SKIP $($pnp.Name): ruta Enum no existe"); continue
                }
                $intPath = "$enumPath\Device Parameters\Interrupt Management"
                if (-not (Test-Path $intPath)) {
                    New-Item -Path $intPath -Force -ErrorAction SilentlyContinue | Out-Null
                }
                if ([string]::IsNullOrEmpty($intPath)) { continue }
                foreach ($t in $Payload.RegistryTemplate) {
                    $before = $null
                    try { $before = (Get-ItemProperty $intPath -Name $t.Name -EA Stop).$($t.Name) } catch { $before = $null }
                    Set-ItemProperty -Path $intPath -Name $t.Name -Value $t.TargetValue -Type $t.Type -Force -EA SilentlyContinue
                    $rbEntries.Add(@{ Path = $intPath; Name = $t.Name; Type = $t.Type; Before = $before })
                }
                $logs.Add("MSI ${class}: $($pnp.Name) -> MSI activado")
            }
        } catch { $logs.Add("WARN MSI $class : $($_.Exception.Message)") }
    }
    $script:ctx.SystemCaps.MSIState = 'AppliedByManolito'
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'DeviceClasses'
            Type        = 'A'
            IsIRR       = $false
            Data        = @{ Entries = $rbEntries.ToArray() }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadActiveSetup {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
        $allOk = $true
        foreach ($ae in $data.Entries) {
            try {
                # Filtro solo por nombre -- los checks -isnot [PSObject] evaluan
                # siempre FALSE en PS5.1 (todo primitivo esta envuelto en PSObject),
                # filtrando TODAS las propiedades y vaciando la clave restaurada
                $props = $ae.KeyData | Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue |
                         Where-Object {
                             $_.Name -notmatch '^PS[A-Z]' -and
                             $_.Name -notin @('PSChildName','PSParentPath','PSPath','PSProvider','PSDrive')
                         }
                if (-not $ae.KeyData -or -not $props) {
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
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $rbEntries = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $Payload.ActiveSetupEntries) {
        $logs.Add("AS Eliminando $entry")
        if ($script:ctx.Runtime.IsDryRun) { continue }

        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$entry",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Active Setup\Installed Components\$entry"
        )
        foreach ($p in $paths) {
            if (Test-Path $p) {
                # Se captura snapshot plano de valores para informacion, pero
                # el rollback se clasifica como Type B (best-effort manual).
                $keyData = $null
                try { $keyData = Get-ItemProperty -Path $p -ErrorAction Stop } catch {}
                Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
                $changes++
                # Guardar snapshot plano + instruccion manual
                $rbEntries.Add(@{
                    Path         = $p
                    KeyData      = $keyData
                    Instructions = "Restaurar clave de registro: $p (snapshot plano adjunto en KeyData)"
                })
            }
        }
    }

    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'ActiveSetupEntries'
            Type        = 'B'
            IsIRR       = $false
            Data        = @{
                Entries      = $rbEntries.ToArray()
                Instructions = "Restaurar claves Active Setup manualmente. Ver KeyData en cada entrada."
            }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadHosts {

    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
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
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $logs.Add('HOSTS Procesando entradas')
    if ($script:ctx.Runtime.IsDryRun) { return @{ Success = $true; Changes = 0; Logs = $logs } }
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    try {
        $existing = Get-Content $hostsPath -ErrorAction Stop
        $script:ctx.Tracking.Backups.Hosts = $existing   # hf17-07: usar propiedad Hosts fija (no $PayloadName dinamico -- PSCustomObject no admite propiedades dinamicas)
        $seen    = [System.Collections.Generic.HashSet[string]]::new()
        $deduped = 0
        $toAdd   = [System.Collections.Generic.List[string]]::new()
        foreach ($rawEntry in $Payload.HostsEntries) {
            $domain = if ($rawEntry -is [string]) { $rawEntry } else { $rawEntry.Domain }
            if ([string]::IsNullOrWhiteSpace($domain)) { continue }
            $norm = $domain.Trim().ToLower()
            if (-not $seen.Add($norm)) { $deduped++; continue }
            $line = "0.0.0.0 $norm"
            if ($existing -notcontains $line) { $toAdd.Add($line) }
        }
        if ($deduped -gt 0)    { $logs.Add("HOSTS $deduped entradas deduplicadas") }
        if ($toAdd.Count -eq 0) { $logs.Add('HOSTS Sin entradas nuevas'); return }
        Add-Content -Path $hostsPath -Value $toAdd -Encoding ASCII
        $logs.Add("HOSTS $($toAdd.Count) entradas anadidas")
        # S3: RollbackEntry Type A con backup del contenido original
        if (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) {
            $script:ctx.Tracking.RollbackStack.Push(@{
                PayloadName = $PayloadName
                ProviderKey = 'HostsEntries'
                Type        = 'A'
                IsIRR       = $false
                Data        = @{ OriginalContent = $existing }
            })
        }
    } catch { $success = $false; $logs.Add("ERR Hosts : $($_.Exception.Message)") }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadDeKMS {
    # Fix Get-ItemPropertyValue PS5.1 no suprime PropertyNotFoundException con
    # -SilentlyContinue cuando la propiedad no existe (solo KeyNotFoundException). Se requiere
    # try/catch explicito. Ademas: $changes++ cuando $cleaned, y Unregister robusto con busqueda
    # por nombre en todas las rutas si TaskPath no esta especificado.
    param($Payload, [string]$PayloadName)
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $logs.Add('DeKMS Inspeccionando activacion KMS')
    if ($script:ctx.Runtime.IsDryRun) { return @{ Success = $true; Changes = 0; Logs = $logs } }
    $cleaned = $false
    try {
        # Get-ItemPropertyValue lanza PropertyNotFoundException en PS5.1
        # cuando la clave existe pero el valor no -- no suprimible con -ErrorAction SilentlyContinue.
        # Envolvemos en try/catch explicito con fallback a string vacio.
        $kmsHost = ''
        try {
            $kmsHost = Get-ItemPropertyValue `
                -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform' `
                -Name 'KeyManagementServiceName' -ErrorAction Stop
        } catch {
            # Valor no presente = sistema sin KMS configurado (limpio). No es error.
            $kmsHost = ''
        }
        if ($null -eq $kmsHost) { $kmsHost = '' }
        $blocked = $false
        foreach ($pattern in $Payload.Blacklist) {
            if ($kmsHost -match $pattern) { $blocked = $true; break }
        }
        if ($blocked) {
            $logs.Add("DeKMS KMS irregular detectado: [$kmsHost] - limpiando")
            & cscript /Nologo "$env:SystemRoot\System32\slmgr.vbs" /ckms 2>$null | Out-Null
            # Services en DeKMS son strings directos -- Stop+Disable con guard
            # para servicios inexistentes (no lanzar excepcion si el svc no existe en el sistema).
            foreach ($svcName in $Payload.Services) {
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
                    Remove-Item $resolved -Force -ErrorAction SilentlyContinue
                    Write-QLog "  [DeKMS] FILE eliminado: $resolved"
                } else {
                    Write-QLog "  [DeKMS] FILE no existe: $resolved (omitido)"
                }
            }
            # Tasks en DeKMS son strings directos sin TaskPath.
            # Unregister-ScheduledTask sin TaskPath falla silenciosamente si la tarea esta en
            # subcarpeta. Buscamos por nombre en todas las rutas primero.
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
            # $changes no se incrementaba cuando habia limpieza real.
            $changes++
        } else {
            $logs.Add("DeKMS Sin KMS irregular detectado (host actual: '$(if($kmsHost){"$kmsHost"}else{"<vacío>"})')")
        }
    } catch { $success = $false; $logs.Add("ERR DeKMS : $($_.Exception.Message)") }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $cleaned) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'Blacklist'
            Type        = 'B'
            IsIRR       = $false
            Data        = @{ Instructions = 'Reactivacion KMS requiere accion manual del administrador' }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadWinget {

    param($Payload, [string]$PayloadName)
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    if ($script:wingetBlocked) {
        $logs.Add('SKIP winget bloqueado por GPO (circuit-breaker activo)')
        return @{ Success = $true; Skipped = $true; Changes = 0; Logs = $logs }
    }
    $installed = [System.Collections.Generic.List[string]]::new()
    foreach ($pkg in $Payload.WingetPackages) {
        $logs.Add("WINGET $($pkg.FriendlyName) ($($pkg.Id))")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        try {
            $out = & winget $pkg.Action --id $pkg.Id --silent --accept-source-agreements --accept-package-agreements 2>&1
            if ($LASTEXITCODE -eq 0x8A150013 -or ($out -match '0x8A150013')) {
                $logs.Add('GPO winget bloqueado por GPO - activando circuit breaker')
                $script:wingetBlocked = $true
                break
            }
            if ($LASTEXITCODE -eq 0) { $installed.Add($pkg.Id) }
        } catch { $success = $false; $logs.Add("ERR Winget $($pkg.Id) : $($_.Exception.Message)") }
    }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $installed.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'WingetPackages'
            Type        = 'B'
            IsIRR       = $false
            Data        = @{
                InstalledIds  = $installed.ToArray()
                Instructions  = "Desinstalar manualmente: $($installed -join ', ')"
            }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadOneDrive {

    param($Payload, [string]$PayloadName)
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $logs.Add('ONEDRIVE Desinstalando OneDrive')
    if ($script:ctx.Runtime.IsDryRun) { return @{ Success = $true; Changes = 0; Logs = $logs } }
    $changed = $false
    try {
        $exe = "$env:SYSTEMROOT\SysWOW64\OneDriveSetup.exe"
        if (-not (Test-Path $exe)) { $exe = "$env:SYSTEMROOT\System32\OneDriveSetup.exe" }
        if (Test-Path $exe) { & $exe /uninstall 2>$null | Out-Null; $changed = $true }
        $paths = @(
            "$env:USERPROFILE\OneDrive",
            "$env:LOCALAPPDATA\Microsoft\OneDrive",
            "$env:PROGRAMDATA\Microsoft OneDrive",
            "$env:SYSTEMDRIVE\OneDriveTemp"
        )
        foreach ($path in $paths) { Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue }
        $regPaths = @(
            'HKCU:\SOFTWARE\Microsoft\OneDrive',
            'HKLM:\SOFTWARE\Microsoft\OneDrive'
        )
        foreach ($rp in $regPaths) {
            if (-not (Test-Path $rp)) { New-Item $rp -Force | Out-Null }
            Set-ItemProperty $rp -Name DisableFileSyncNGSC -Value 1 -Type DWord -Force
        }
    } catch { $success = $false; $logs.Add("ERR OneDrive : $($_.Exception.Message)") }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $changed) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'OneDriveUninstall'
            Type        = 'B'
            IsIRR       = $false
            Data        = @{
                Instructions = 'Reinstalar OneDrive manualmente desde https://onedrive.live.com/about/download/'
            }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadNICTuning {

    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
        $allOk = $true
        foreach ($p in $data.Entries) {
            try {
                Set-NetAdapterAdvancedProperty -Name $p.AdapterName `
                    -RegistryKeyword $p.Keyword -RegistryValue $p.Before -ErrorAction Stop
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR NIC $($p.AdapterName) $($p.Keyword): $_" }
        }
        return @{ Success = $allOk }
    }
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $logs.Add('NIC Ajustando propiedades avanzadas NIC')
    if ($script:ctx.Runtime.IsDryRun) { return @{ Success = $true; Changes = 0; Logs = $logs } }
    # hf17-08: guard HasPhysicalNIC para NICTuning
    if (-not $script:ctx.SystemCaps.HasPhysicalNIC) {
        $logs.Add('SKIP NIC -- HasPhysicalNIC=false (sin NIC fisica activa detectada)')
        return @{ Success = $true; Changes = 0; Logs = $logs }
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
    } catch { $success = $false; $logs.Add("ERR NICTuning : $($_.Exception.Message)") }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'NICProperties'
            Type        = 'A'
            IsIRR       = $false
            Data        = @{ Entries = $rbEntries.ToArray() }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadPowercfg {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
        $allOk = $true
        foreach ($s in $data.Entries) {
            try {
                powercfg /change $s.Setting $s.Before 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "powercfg /change salio con $LASTEXITCODE" }
            } catch { $allOk = $false; Write-QLog "[ROLLBACK]   ERR Powercfg $($s.Setting): $_" }
        }
        return @{ Success = $allOk }
    }
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $rbEntries = [System.Collections.Generic.List[object]]::new()

    foreach ($s in $Payload.PowercfgSettings) {
        $logs.Add("PCFG $($s.Setting) -> $($s.TargetValue)")
        if ($script:ctx.Runtime.IsDryRun) { continue }
        try {
            # powercfg /query devuelve lineas con "Current AC Power Setting Index"
            $realBefore = $null
            try {
                $qOut = powercfg /query SCHEME_CURRENT 2>$null
                if ($LASTEXITCODE -eq 0 -and $qOut) {
                    # antes del "Current AC Power Setting Index", no esta siempre en idx+1
                    $qLines = @($qOut)
                    for ($qi = 0; $qi -lt $qLines.Count; $qi++) {
                        if ($qLines[$qi] -match [regex]::Escape($s.Setting)) {
                            for ($qj = $qi + 1; $qj -lt $qLines.Count; $qj++) {
                                if ($qLines[$qj] -match 'Current AC Power Setting Index:\s*(0x[\da-fA-F]+|\d+)') {
                                    $realBefore = $Matches[1]
                                    break
                                }
                                # nuevo contexto GUID = salimos
                                if ($qLines[$qj] -match 'Power Setting GUID|Subgroup GUID') { break }
                            }
                            if ($null -ne $realBefore) { break }
                        }
                    }
                }
            } catch { Write-QLog "[WARN] No se pudo leer configuracion actual de powercfg /q: $($_.Exception.Message)" }

            # Usar RestoreValue como fallback si no se pudo leer valor real
            $before = if ($null -ne $realBefore) { $realBefore } else { $s.RestoreValue }

            powercfg /change $s.Setting $s.TargetValue 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "powercfg /change '$($s.Setting)' salio con $LASTEXITCODE" }

            $changes++
            $rbEntries.Add(@{
                Setting       = $s.Setting
                Before        = $before
                RealCaptured  = ($null -ne $realBefore)
            })
        } catch { $success = $false; $logs.Add("ERR Powercfg $($s.Setting) : $_") }
    }

    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'PowercfgSettings'
            Type        = 'A'
            IsIRR       = $false
            Data        = @{ Entries = $rbEntries.ToArray() }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadUltimatePower {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
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
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $logs.Add('POWER Activando Ultimate Performance')
    if ($script:ctx.Runtime.IsDryRun) {
        return @{ Success = $success; Changes = 0; Logs = $logs }
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
        $changed = $true; $changes++
    } catch { $success = $false; $logs.Add("ERR UltimatePower : $_") }

    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $changed) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'UltimatePowerPlan'
            Type        = 'A'
            IsIRR       = $false
            # Si no se pudo capturar, fallback a Balanced conocido
            Data        = @{
                OldPlanGuid  = if ($oldPlanGuid) { $oldPlanGuid } else { '381b4222-f694-41f0-9685-ff5bb260df2e' }
                GuidCaptured = ($null -ne $oldPlanGuid)
            }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadNvidiaOptimize {

    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
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
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $logs.Add('NVIDIA Aplicando tweaks PowerMizer')
    if ($script:ctx.Runtime.IsDryRun) { return @{ Success = $true; Changes = 0; Logs = $logs } }
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    try {
        $nvidiaBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        $subkeys = Get-ChildItem $nvidiaBase -ErrorAction Stop | Where-Object { $_.PSChildName -match '^\d+$' }
        foreach ($sk in $subkeys) {
            $provider = (Get-ItemProperty $sk.PSPath -Name ProviderName -ErrorAction SilentlyContinue).ProviderName
            if ($provider -notmatch 'NVIDIA') { continue }
            foreach ($t in $Payload.NvidiaOptimizeTemplate) {
                $before = $null
                try { $before = (Get-ItemProperty $sk.PSPath -Name $t.Name -ErrorAction Stop).$($t.Name) } catch { $before = $null; Write-QLog "[WARN-SNAP] No se pudo leer valor previo (NvidiaOpt $($sk.PSPath)): $($_.Exception.Message)" }
                Set-ItemProperty -Path $sk.PSPath -Name $t.Name -Value $t.TargetValue -Type $t.Type -Force -ErrorAction SilentlyContinue
                $rbEntries.Add(@{ Path = $sk.PSPath; Name = $t.Name; Type = $t.Type; Before = $before })
            }
        }
    } catch { $success = $false; $logs.Add("ERR NvidiaOptimize : $($_.Exception.Message)") }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'NvidiaOptimizeTemplate'
            Type        = 'A'
            IsIRR       = $false
            Data        = @{ Entries = $rbEntries.ToArray() }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadTimerResolution {

    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
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
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $val = $Payload.TimerResConfig.TargetValue
    $logs.Add("TIMER bcdedit disabledynamictick $val")
    if ($script:ctx.Runtime.IsDryRun) { return @{ Success = $true; Changes = 0; Logs = $logs } }
    $rbEntries = [System.Collections.Generic.List[object]]::new()
    try {
        $enumOut = bcdedit /enum current 2>$null
        foreach ($setting in @('useplatformtick', 'disabledynamictick')) {
            $existingLine = $enumOut | Select-String $setting
            $isNew  = (-not $existingLine)
            $oldVal = $null
            if (-not $isNew) { $oldVal = ($existingLine.Line -split '\s+', 2)[1].Trim() }
            if ($setting -eq 'disabledynamictick') {
                bcdedit /set $setting $val 2>$null | Out-Null
            } else {
                $ptVal = if ($val -eq 'yes') { 'no' } else { 'yes' }
                bcdedit /set $setting $ptVal 2>$null | Out-Null
            }
            $rbEntries.Add(@{ Setting = $setting; IsNew = $isNew; OldValue = $oldVal })
        }
    } catch { $success = $false; $logs.Add("ERR TimerResolution : $($_.Exception.Message)") }
    if (-not $script:ctx.Runtime.IsDryRun -and -not $script:ctx.Runtime.IsRollback -and
        -not $script:ctx.Runtime.IsManifestRestore -and $rbEntries.Count -gt 0) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'TimerResConfig'
            Type        = 'A'
            IsIRR       = $false
            Data        = @{ Entries = $rbEntries.ToArray() }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


# B-02: USBStorageControl -- Universal
function Invoke-PayloadUSBStorage {

    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
        try {
            if ($null -eq $data.OldStart) { throw "OldStart es null" }
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' `
                -Name Start -Value $data.OldStart -Type DWord -Force -ErrorAction Stop
            Write-QLog "[ROLLBACK]   USBSTOR Start restaurado a $($data.OldStart)"
            $handledOk_ok = $true
        } catch { Write-QLog "[ROLLBACK]   ERR USBStorage: $_"; $handledOk_ok = $false }
        return @{ Success = ($handledOk_ok -eq $true) }
    }
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $svcPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR'
    $startRaw = $null
    try { $startRaw = (Get-ItemProperty $svcPath -Name Start -ErrorAction Stop).Start } catch {}
    if ($null -eq $startRaw) { $logs.Add('SKIP USBStorage -- clave USBSTOR no encontrada'); return }
    if ($script:ctx.Runtime.IsDryRun) {
        $logs.Add("DRY USBStorage -- Start actual=$startRaw. Toggle 3=enabled, 4=disabled")
        return @{ Success = $true; Changes = 0; Logs = $logs }
    }
    if ($startRaw -eq 2) {
        $logs.Add('WARN Start=2 enterprise. Requiere confirmacion explicita.')
        $r = [System.Windows.Forms.MessageBox]::Show(
            "USBSTOR Start=2 detectado (configuracion enterprise/especial).`nModificar de todas formas?",
            'Manolito Engine', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($r -ne 'Yes') { $logs.Add('SKIP USB cancelado'); return }
    }
    $newVal = if ($startRaw -eq 4) { 3 } else { 4 }
    $state  = if ($newVal -eq 4) { 'DISABLED' } else { 'ENABLED' }
    Set-ItemProperty -Path $svcPath -Name Start -Value $newVal -Type DWord -Force
    $changes++
    $logs.Add("USB Start $startRaw -> $newVal ($state)")
    if ($newVal -eq 4) { $logs.Add('INFO Unidades USB montadas permanecen hasta desconexion fisica') }
    $logs.Add('INFO Solo afecta almacenamiento masivo (USBSTOR). HID y audio no modificados.')
    if (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) {
        $script:ctx.Tracking.RollbackStack.Push(@{
            PayloadName = $PayloadName
            ProviderKey = 'USBStorageTemplate'
            Type        = 'A'
            IsIRR       = $false
            Data        = @{ OldStart = $startRaw }
        })
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


# B-03: NVMeProtect CheckOnly
function Invoke-PayloadNVMeProtect {

    param($Payload, [string]$PayloadName)
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $caps = $script:SystemCaps
    $logs.Add("NVMe Driver: $($caps.NVMeDriverName)")
    if ($caps.NVMeDriverIsOEM) {
        $logs.Add('NVMe Driver OEM detectado - OK')
    } else {
        $logs.Add('WARN Driver generico Microsoft stornvme.sys. Considera instalar driver OEM.')
    }
    $logs.Add('NVMe KBs de referencia: KB5034441, KB5028185')
    # S3: CheckOnly -- no empuja RollbackEntry (cero cambios reales en v2.9.0)
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


function Invoke-PayloadACL {
    # Verified: Set-Acl usa -ErrorAction Stop + try/catch en cada op
    # Timeout global del runspace (600s) cubre casos extremos de bloqueo AV
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
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
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $rbEntries = [System.Collections.Generic.List[object]]::new()

    # Soporte como provider standalone (Payload.ACL) y como helper de BlueHammer (se pasa AclStep directamente)
    $entries = @()
    if ($Payload.PSObject.Properties['_AclSteps']) {
        $entries = @($Payload._AclSteps)
    } elseif ($Payload.PSObject.Properties['ACL']) {
        $raw = $Payload.ACL
        $entries = if ($raw -is [array]) { $raw } else { @($raw) }
    }
    if ($entries.Count -eq 0) {
        $logs.Add('    [SKIP] ACL: sin entradas definidas')
        return @{ Success = $success; Changes = $changes; Logs = $logs }
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

        # CheckOnly -- sin cambios
        if ($action -eq 'CheckOnly') {
            $exists = Test-Path $path
            $logs.Add("      [CHECK] Path existe: $exists")
            continue
        }

        # Validar path
        if (-not (Test-Path $path)) {
            if ($allowMiss) {
                $logs.Add("      [SKIP] Path no existe (AllowIfMissing=true): $path")
                continue
            }
            $success = $false
            $logs.Add("      [ERR] Path no existe: $path")
            if (-not $script:ctx.Runtime.ContinueOnError) { break }
            continue
        }

        # DryRun -- log de intencion, sin cambio
        if ($script:ctx.Runtime.IsDryRun) {
            $logs.Add("      [DRY] Accion prevista: $action | Principal: $principal | Rights: $rights | ACType: $acType")
            continue
        }

        # No ejecutar durante rollback manual (los handlers de IRS lo gestionan)
        if ($script:ctx.Runtime.IsRollback -or $script:ctx.Runtime.IsManifestRestore) {
            $logs.Add("      [SKIP] ACL omitida en modo rollback/restore")
            continue
        }

        # Capturar ACL original ANTES de cualquier cambio
        $originalAcl  = $null
        $originalSddl = $null
        $backupOk     = $false
        try {
            $originalAcl  = Get-Acl -Path $path -ErrorAction Stop
            $originalSddl = $originalAcl.Sddl
            $backupOk     = $true
            $logs.Add("      [ACL] Backup capturado. SDDL length: $($originalSddl.Length)")
        } catch {
            $success = $false
            $logs.Add("      [ERR] No se pudo capturar ACL original: $_")
            if ($reqBackup) {
                $logs.Add("      [FAIL] RequireBackup=true -- abortando entrada ACL")
                if (-not $script:ctx.Runtime.ContinueOnError) { break }
                continue
            }
        }

        if ($reqBackup -and -not $backupOk) {
            $success = $false
            $logs.Add("      [FAIL] Sin backup ACL valido -- operacion cancelada: $path")
            if (-not $script:ctx.Runtime.ContinueOnError) { break }
            continue
        }

        # Construir regla
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
            $success = $false
            $logs.Add("      [ERR] No se pudo construir la regla ACL: $_")
            if (-not $script:ctx.Runtime.ContinueOnError) { break }
            continue
        }

        # Verificar que no se comprometen principals criticos
        $criticalViolation = $false
        foreach ($cp in $critical) {
            $existingRules = $originalAcl.Access | Where-Object { $_.IdentityReference.Value -eq $cp }
            if ($action -in @('RemoveRule','SetRule') -and $cp -eq $principal) {
                $criticalViolation = $true
                $logs.Add("      [ERR] Intento de modificar principal critico: $cp")
            }
        }
        if ($criticalViolation) {
            $success = $false
            if (-not $script:ctx.Runtime.ContinueOnError) { break }
            continue
        }

        # Aplicar cambio con validacion semantica pre/post
        # Get-Acl dentro del try para que cualquier fallo quede capturado con $success=false
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
                    $success = $false
                    $logs.Add("      [ERR] Accion ACL no reconocida: $action")
                    continue
                }
            }
            Set-Acl -Path $path -AclObject $newAcl -ErrorAction Stop

            # Verificar cambio semantico real comparando SDDL pre/post
            $verifyAcl  = Get-Acl -Path $path -ErrorAction Stop
            $afterSddl  = $verifyAcl.Sddl
            if ($afterSddl -eq $beforeSddl) {
                $logs.Add("      [NOCHANGE] SDDL identico pre/post Set-Acl -- no se cuenta como cambio")
            } else {
                $changes++
                $entryChanged = $true
                $logs.Add("      [OK] ACL aplicada: $action en $path")
                $logs.Add("      [VERIFY] SDDL pre-length=$($beforeSddl.Length) post-length=$($afterSddl.Length)")
            }

        } catch {
            $success = $false
            $logs.Add("      [ERR] Set-Acl fallo: $_")
            if (-not $script:ctx.Runtime.ContinueOnError) { break }
            continue
        }

        # RollbackEntry Type A -- solo si ESTA entrada concreta causo un cambio real
        if ($backupOk -and $entryChanged -and
            -not $script:ctx.Runtime.IsRollback -and
            -not $script:ctx.Runtime.IsManifestRestore) {
            $rbEntries.Add(@{
                PayloadName     = $PayloadName
                ProviderKey     = 'ACL'
                Type            = 'A'
                IsIRR           = $false
                Data            = @{
                    Step            = "ACL.$action"
                    Path            = $path
                    Principal       = $principal
                    Rights          = $rights
                    Action          = $action
                    OriginalAclSddl = $originalSddl
                    Timestamp       = [DateTime]::UtcNow.ToString('o')
                }
            })
        }
    }

    # Empujar RollbackEntries acumuladas
    if ($rbEntries.Count -gt 0) {
        foreach ($rb in $rbEntries) {
            $script:ctx.Tracking.RollbackStack.Push($rb)
        }
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}

function Invoke-PayloadBlueHammer {
    param($Payload, [string]$PayloadName,
              [switch]$IsRollback,
              [object]$RollbackEntry)

    if ($IsRollback) {
        $data  = $RollbackEntry.Data
        $pname = $RollbackEntry.PayloadName
        $pkey = $RollbackEntry.ProviderKey
        switch ($pkey) {
            'BlueHammer.Defender' {
                # Reutiliza logica Registry -- mismo formato Data
                $allOk = $true
                $rPath = $data.Path; $rName = $data.Name; $rOld = $data.OldValue
                if ([string]::IsNullOrEmpty($rPath) -or [string]::IsNullOrEmpty($rName)) {
                    Write-QLog "[ROLLBACK]   ERR BlueHammer.Defender: Path/Name nulo"
                    $allOk = $false
                } elseif ($null -eq $rOld) {
                    # Si no habia valor previo, eliminar la clave
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
                # Reutiliza logica Tasks -- mismo formato Data (WasEnabled, Name, Path)
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
                # Type B informativo -- sin rollback automatico de VSS
                Write-QLog "[ROLLBACK]   INFO BlueHammer.VSS: sin rollback automatico"
                $instr = if ($data.RestoreInstructions) { $data.RestoreInstructions } else { "Revisar servicio VSS manualmente" }
                $pending_action_rb = $instr
                $allOk = $false   # VSS siempre requiere accion manual
            }
        }
        # Devolver resultado estandar al orquestador (OCP rollback contract)
        if ($allOk -eq $false -and $pending_action_rb) {
            return @{ Success = $false; PendingAction = $pending_action_rb }
        }
        return @{ Success = ($null -eq $allOk -or $allOk) }
    }
    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0
    $rbEntries = [System.Collections.Generic.List[object]]::new()

    $bhCfg = if ($Payload.PSObject.Properties['BlueHammer']) { $Payload.BlueHammer } else { $null }
    if (-not $bhCfg -or -not $bhCfg.Enabled) {
        $logs.Add('    [SKIP] BlueHammer: no configurado o deshabilitado en WAD')
        return @{ Success = $success; Changes = $changes; Logs = $logs }
    }
    $continueOnErr = if ($bhCfg.PSObject.Properties['ContinueOnError']) { [bool]$bhCfg.ContinueOnError } else { $false }
    $steps = @($bhCfg.Steps | Where-Object { $_.Enabled })
    $logs.Add("    > BlueHammer: $($steps.Count) pasos habilitados")

    foreach ($step in $steps) {
        $sName = $step.Name
        $logs.Add("    [BLUEHAMMER][$sName] Iniciando...")

        #  PASO 1: DEFENDER 
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
                $before = $null
                try {
                    $before = (Get-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction Stop).$($r.Name)
                } catch { $before = $null; Write-QLog "[WARN-SNAP] No se pudo leer valor previo (BlueHammer Registry): $($_.Exception.Message)" }
                try {
                    if (-not (Test-Path $r.Path)) {
                        New-Item -Path $r.Path -Force -ErrorAction Stop | Out-Null
                    }
                    Set-ItemProperty -Path $r.Path -Name $r.Name -Value $r.TargetValue -Type $r.Type -ErrorAction Stop
                    $changes++
                    $logs.Add("      [OK] Defender REG $($r.Name): $before -> $($r.TargetValue)")
                    if (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) {
                        $rbEntries.Add(@{
                            PayloadName = $PayloadName; ProviderKey = 'BlueHammer.Defender'; Type = 'A'; IsIRR = $false
                            Data = @{ Path = $r.Path; Name = $r.Name; OldValue = $before; NewValue = $r.TargetValue
                                      Type = $r.Type; Step = 'BlueHammer.Defender' }
                        })
                    }
                } catch {
                    $success = $false; $defOk = $false
                    $logs.Add("      [ERR] Defender REG $($r.Name) : $_")
                }
            }
            if (-not $defOk -and -not $continueOnErr) { break }
        }

        #  PASO 2: TASK 0300 
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
                    $success = $false
                    $logs.Add("      [ERR] Task no encontrada y SkipIfMissing=false: $tPath$tName")
                    if (-not $continueOnErr) { break }
                }
                continue
            }

            $wasEnabled = ($task.State -ne 'Disabled')
            $logs.Add("      WasEnabled=$wasEnabled State=$($task.State)")

            # No cambio si ya esta en estado objetivo
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
                $changes++
                $logs.Add("      [OK] Task0300 $tState aplicado")
                if (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) {
                    $rbEntries.Add(@{
                        PayloadName = $PayloadName; ProviderKey = 'BlueHammer.Task0300'; Type = 'A'; IsIRR = $false
                        Data = @{ Name = $tName; Path = $tPath; WasEnabled = $wasEnabled
                                  TargetState = $tState; Step = 'BlueHammer.Task0300' }
                    })
                }
            } catch {
                $success = $false
                $logs.Add("      [ERR] Task0300 fallo: $_")
                if (-not $continueOnErr) { break }
            }
        }

        #  PASO 3: VSS 
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
                # Solo validacion -- no inicia ni detiene, no genera RollbackEntry
                if ($prevState -notin @('Running','Stopped')) {
                    $logs.Add("      [WARN] VSS estado inusual: $prevState -- revisar manualmente")
                } else {
                    $logs.Add("      [OK] VSS disponible: $prevState")
                }
                # Type B informativo si no estaba OK
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

            # Acciones activas (futuras, no en Sprint 4 baseline)
            $logs.Add("      [WARN] Accion VSS '$action' no implementada en Sprint 4 -- solo CheckAndEnsureRunning soportado")
        }

        #  PASO 4: ACL 
        elseif ($sName -eq 'ACL') {
            # Resolver path dinamico (WD Platform latest version)
            $rawPath = $step.Path
            $resolvMode = if ($step.PSObject.Properties['ResolvePath']) { $step.ResolvePath } else { '' }
            $targetFile = if ($step.PSObject.Properties['TargetFile'])  { $step.TargetFile  } else { '' }
            $resolvedPath = $rawPath

            if ($resolvMode -eq 'WDPlatformLatest' -and $targetFile) {
                # Resolver la version mas reciente en %ProgramData%\Microsoft\Windows Defender\Platform\
                $platformBase = [System.Environment]::ExpandEnvironmentVariables($rawPath)
                if (Test-Path $platformBase) {
                    $latest = Get-ChildItem -Path $platformBase -Directory -ErrorAction SilentlyContinue |
                              Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
                    if ($latest) {
                        $resolvedPath = Join-Path $latest.FullName $targetFile
                        $logs.Add("      [ACL] Path resuelto: $resolvedPath")
                    } else {
                        if (-not $step.AllowIfMissing) {
                            $success = $false
                            $logs.Add("      [ERR] No se encontro ninguna version en Platform: $platformBase")
                            if (-not $continueOnErr) { break }
                        } else {
                            $logs.Add("      [SKIP] WD Platform dir no encontrado (AllowIfMissing=true)")
                        }
                        continue
                    }
                } else {
                    if (-not $step.AllowIfMissing) {
                        $success = $false
                        $logs.Add("      [ERR] Base path no existe: $platformBase")
                        if (-not $continueOnErr) { break }
                    } else {
                        $logs.Add("      [SKIP] Base path inexistente (AllowIfMissing=true)")
                    }
                    continue
                }
            }

            # Delegar a Invoke-PayloadACL con un payload virtual que lleva _AclSteps
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

            # Propagar resultado
            if ($aclResult.Logs) { $logs.AddRange([string[]]$aclResult.Logs) }
            if ($null -ne $aclResult.Changes) { $changes += [int]$aclResult.Changes }
            if ($aclResult.PSObject.Properties['Success'] -and -not $aclResult.Success) {
                $success = $false
                if (-not $continueOnErr) { break }
            }
        }
        else {
            $logs.Add("    [WARN] Paso BlueHammer no reconocido: $sName")
        }
    }

    # Empujar RollbackEntries acumuladas (de pasos Defender/Task0300/VSS)
    # Las de ACL ya las empuja Invoke-PayloadACL directamente
    if ($rbEntries.Count -gt 0 -and
        -not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) {
        foreach ($rb in $rbEntries) {
            $script:ctx.Tracking.RollbackStack.Push($rb)
        }
    }
    return @{ Success = $success; Changes = $changes; Logs = $logs }
}


# ========================================================================
# Ejecutar tras definir todas las funciones y antes de ShowDialog
# ========================================================================

# ========================================================================
# 4. DISPATCHER PRINCIPAL
# ========================================================================

function Invoke-Payload {
    param([string]$PayloadName)

    $payload = $script:PayloadMap[$PayloadName]
    if (-not $payload) {
        return @{ Success = $false; Changes = 0; Logs = @("[FAIL] Payload '$PayloadName' no encontrado") }
    }
    $meta = $payload._meta

    $guardResult = Test-PayloadGuards -Payload $payload -PayloadName $PayloadName
    if (-not $guardResult.Pass) {
        $script:logQueue.Enqueue("LOG:$($guardResult.Reason)")
        return @{ Success = $true; Skipped = $true; Changes = 0; Logs = @($guardResult.Reason) }
    }
    if (-not $meta.Reversible -and $script:ctx.Runtime.IsRollback) {
        return @{ Success = $true; Skipped = $true; Changes = 0; Logs = @("    [SKIP] $($meta.Label) (No reversible)") }
    }
    if ($meta.PSObject.Properties['RequiresReboot'] -and $meta.RequiresReboot -and
        -not $script:ctx.Runtime.IsDryRun) {
        $script:ctx.State.PendingReboot = $true
    }
    if (-not $meta.Reversible -and -not $script:ctx.Runtime.IsRollback) {
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

    # Paso 1: handler dedicado por PayloadName
    $byNameKey = "_name_$PayloadName"
    if ($script:ProviderMap.ContainsKey($byNameKey)) {
        $handlerName = $script:ProviderMap[$byNameKey]
        $cmd = Get-Command $handlerName -CommandType Function -ErrorAction SilentlyContinue
        if (-not $cmd) {
            $moduleResult.Logs.Add("[FAIL] Handler no encontrado en runspace: $handlerName")
            $moduleResult.Success = $false
        } else {
            $res = & $cmd.Name -Payload $payload -PayloadName $PayloadName
            if ($res) {
                if ($null -ne $res.Changes) { $moduleResult.Changes += [int]$res.Changes }
                if ($res.Logs)              { $moduleResult.Logs.AddRange([string[]]$res.Logs) }
                if ($res.PSObject.Properties['Success'] -and -not $res.Success) { $moduleResult.Success = $false }
            }
        }
    } else {
        # Paso 2: dispatch data-driven por clave de schema presente en el payload
        foreach ($propKey in $script:ProviderMap.Keys) {
            if ($propKey.StartsWith('_name_')) { continue }
            if (-not $payload.PSObject.Properties[$propKey]) { continue }

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
            $res = & $cmd.Name -Payload $payload -PayloadName $PayloadName
            if ($res) {
                if ($null -ne $res.Changes) { $moduleResult.Changes += [int]$res.Changes }
                if ($res.Logs)              { $moduleResult.Logs.AddRange([string[]]$res.Logs) }
                if ($res.PSObject.Properties['Success'] -and -not $res.Success) { $moduleResult.Success = $false }
            }
        }
    }

    if ($moduleResult.Success) {
        # NEW-04: foreach secuencial en runspace -- no concurrente, ++ es seguro
        $script:ctx.State.StepsOk++
        $script:logQueue.Enqueue("COUNT:$($script:ctx.State.StepsOk)")
        $moduleResult.Status = 'OK'
    } else {
        $script:ctx.State.StepsFail++
        $moduleResult.Status = 'FAIL'
    }
    $script:ctx.Results.Modules.Add($moduleResult)
    return $moduleResult
}


# ========================================================================
# 5. RUNSPACE Y SERIALIZACION
# ========================================================================

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


function Import-ManifestToContext {
    param(
        [string]$ManifestPath,
        [System.Windows.Controls.StackPanel]$SpDynamic,
        [System.Windows.Controls.TextBlock]$TxtDesc,
        [System.Windows.Controls.TextBox]$Console
    )
    try { $m = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $Console.AppendText("`n    [FAIL] No se pudo leer el manifest: $($_.Exception.Message)"); return $null }

    # Guard campos minimos requeridos
    foreach ($f in @('Summary', 'BackupServicesState', 'BackupTasksState', 'BackupDNS', 'BackupBCD', 'RegDiff')) {
        if (-not $m.PSObject.Properties[$f]) {
            $Console.AppendText("`n    [ERROR] Manifest incompleto -- falta campo: $f. Abortando.")
            return $null
        }
    }

    # C-04: Compatibilidad de version
    if ($m.PSObject.Properties['EngineVersion'] -and $m.EngineVersion) {
        $mMM = ($m.EngineVersion -split '\.')[0..1] -join '.'
        $eMM = ($script:Config.Manifest.Version -split '\.')[0..1] -join '.'
        if ($mMM -ne $eMM) {
            $Console.AppendText("`n    [WARN] Manifest v$($m.EngineVersion) vs motor v$($script:Config.Manifest.Version) -- restauracion puede ser incompleta.")
        }
    }

    # C-02: Rellenar ctx.Tracking.Backups (nueva ruta)
    $script:ctx.Tracking.Backups.ServicesStartup = ConvertTo-NativeHashtable $m.BackupServicesState
    $script:ctx.Tracking.Backups.TasksState      = ConvertTo-NativeHashtable $m.BackupTasksState
    $script:ctx.Tracking.Backups.DNS             = ConvertTo-NativeHashtable $m.BackupDNS
    $script:ctx.Tracking.Backups.BCD             = ConvertTo-NativeHashtable $m.BackupBCD
    $script:ctx.Tracking.Backups.ActiveSetup     = ConvertTo-NativeHashtable $m.BackupActiveSetup
    $script:ctx.Tracking.Backups.WindowsFeatures = ConvertTo-NativeHashtable $m.BackupWindowsFeatures
    $script:ctx.Tracking.Backups.Hosts           = $m.BackupHosts

    $script:ctx.Tracking.RegDiff.Clear()
    if ($m.RegDiff) { $script:ctx.Tracking.RegDiff.AddRange($m.RegDiff) }

    $script:ctx.Runtime.IsRollback        = $true
    $script:ctx.Runtime.IsManifestRestore = $true

    # Construir plan desde PayloadsExecuted, solo reversibles
    $plan = [System.Collections.Generic.List[string]]::new()
    if ($m.Summary.PSObject.Properties['PayloadsExecuted'] -and $m.Summary.PayloadsExecuted) {
        foreach ($pName in $m.Summary.PayloadsExecuted) {
            $prop = $script:PayloadMap[$pName]
            $meta = if ($prop -and $prop._meta) { $prop._meta } else { $null }
            if ($meta -and $meta.Reversible) { $plan.Add($pName) }
        }
    }

    # Dedup
    $originalCount = $plan.Count
    $dedupPlan = @($plan | Select-Object -Unique)
    if ($dedupPlan.Count -lt $originalCount) {
        $Console.AppendText("`n    [WARN] Payloads duplicados en manifest -- deduplicado a $($dedupPlan.Count).")
    }

    $SpDynamic.Children.Clear()
    $TxtDesc.Text       = "[MANIFEST RESTORE] $($m.Timestamp)  --  Runlevel origen: $($m.Runlevel)"
    $TxtDesc.Foreground = '#BF00FF'

    foreach ($pName in $dedupPlan) {
        $meta = $script:PayloadMap[$pName]._meta

        if ($meta.PSObject.Properties['DenyOnBattery'] -and $meta.DenyOnBattery -eq $true -and $script:SystemCaps.HasBattery) {
            $Console.AppendText("`n    [WARN-GUARD] $pName -- DenyOnBattery en portatil, permitido en manifest restore")
        }

        $riskLevel = if ($meta.PSObject.Properties['RiskLevel']) { $meta.RiskLevel } else { 0 }
        $icono = switch ($riskLevel) {
            { $_ -ge 4 } { '[!!!]' }
            { $_ -ge 3 } { '[!]'   }
            { $_ -ge 2 } { '[~]'   }
            default      { '[*]'   }
        }
        $cb             = [System.Windows.Controls.CheckBox]::new()
        $cb.Content     = "$icono $($meta.Label)"
        $cb.Tag         = $pName
        $cb.IsChecked   = $true
        $cb.Foreground  = '#BF00FF'
        $SpDynamic.Children.Add($cb) | Out-Null
    }

    $Console.AppendText("`n    [OK]  Manifest cargado -- $($dedupPlan.Count) payloads desde $ManifestPath")
    return $dedupPlan
}

function Save-ManifestEntry {
    param([string]$PayloadName)
    if (-not (Test-Path $script:MANIFESTDIR)) {
        New-Item -Path $script:MANIFESTDIR -ItemType Directory -Force | Out-Null
    }
    $mf = if (Test-Path $script:MANIFESTPATH) {
        Get-Content $script:MANIFESTPATH -Raw | ConvertFrom-Json
    } else {
        [PSCustomObject]@{ AppliedPayloads = @() }
    }
    if ($mf.AppliedPayloads -notcontains $PayloadName) {
        $mf.AppliedPayloads += $PayloadName
    }
    $mf | ConvertTo-Json -Depth 5 | Set-Content $script:MANIFESTPATH -Encoding UTF8
}
# ========================================================================
# 7. AUDIT MODE / PRE-AUDIT / HTML REPORT
# ========================================================================

function Write-PreAudit {
    param(
        [array]$Plan,
        [System.Windows.Controls.TextBox]$Console
    )
    $Console.AppendText("`n`n> [PRE-AUDIT] Plan de ejecucion ($($Plan.Count) payloads):")
    foreach ($pName in $Plan) {
        $meta = $script:PayloadMap[$pName]._meta
        if (-not $meta) { continue }

        $riskLevel = if ($meta.PSObject.Properties['RiskLevel']) { $meta.RiskLevel } else { 0 }
        $tag = switch ($riskLevel) {
            { $_ -ge 4 } { '[!!!]' }
            { $_ -ge 3 } { '[!]'   }
            { $_ -ge 2 } { '[~]'   }
            default      { '[*]'   }
        }
        $rev = if ($meta.Reversible) { 'Reversible' } else { 'IRREVERSIBLE -- confirmar' }
        $Console.AppendText("`n    $tag $($pName.PadRight(24)) -> $rev")
    }
    $Console.AppendText("`n> Iniciando en 1.5s...`n")
}

function Invoke-AuditMode {
    $lines = [System.Collections.Generic.List[string]]::new()
    $caps  = $script:ctx.SystemCaps

    $lines.Add('=== MANOLITO AUDIT REPORT ===')
    $lines.Add("Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("Modo: $(if ($script:ctx.Runtime.IsDryRun) { 'DRY RUN' } else { 'LIVE' })")
    $lines.Add('')

    # CHECK 1 - NVMe driver OEM vs generico
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

    # CHECK 2 - USB Storage con ownership
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

    # CHECK 3 - MSI por GPU y NVMe con ownership
    $lines.Add('[CHECK 3] MSI Mode (GPU / NVMe)')
    $msiOwned = Test-ManolitoOwnership -PayloadName 'MSITuning'
    $lines.Add("  CapabilityKey MSIState: $($caps.MSIState)")
    $lines.Add("  Gestionado por Manolito: $(if ($msiOwned) { 'SI' } else { 'NO' })")
    if (-not $msiOwned -and $caps.MSIState -ne 'Unknown') {
        $lines.Add('  INFO: MSI activo por herramienta externa. Manolito puede aplicar su perfil creando backup nuevo.')
    }
    $lines.Add('')

    # CHECK 4 - KBs de riesgo desde AuditConfig.RiskKBs
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

    # CHECK 5 - HAGS
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

    # CHECK 6 - Proteccion Sistema C
    $lines.Add('[CHECK 6] Proteccion del Sistema (unidad C)')
    try {
        $vss = & vssadmin list shadowstorage /for=C: 2>&1
        $active = ($vss -join '') -match 'Maximum Shadow Copy Storage'
        $lines.Add("  Proteccion Sistema C: $(if ($active) { 'ACTIVA' } else { 'INACTIVA o sin espacio asignado' })")
    } catch {
        $lines.Add("  ERR al consultar VSS: $_")
    }
    $lines.Add('')
    $lines.Add('=== FIN AUDIT ===')

    # Log a cola
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

        # SystemCaps summary
        $null = $sb.AppendLine('<h2>Capacidades del Sistema</h2><table><tr><th>Cap</th><th>Valor</th></tr>')
        foreach ($cap in $script:SystemCaps.PSObject.Properties) {
            $valHtml = [System.Net.WebUtility]::HtmlEncode("$($cap.Value)")
            $null = $sb.AppendLine("<tr><td>$([System.Net.WebUtility]::HtmlEncode($cap.Name))</td><td>$valHtml</td></tr>")
        }
        $null = $sb.AppendLine('</table>')

        # Resultados por payload
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

            # Logs con coloreado por prefijo
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

        # Irreversible actions warning
        $irrevList = @($script:ctx.Tracking.IrreversibleActions)
        if ($irrevList.Count -gt 0) {
            $null = $sb.AppendLine('<h2 class="irr">Acciones Irreversibles</h2><ul>')
            foreach ($a in $irrevList) { $null = $sb.AppendLine("<li class=`"irr`">$([System.Net.WebUtility]::HtmlEncode($a))</li>") }
            $null = $sb.AppendLine('</ul>')
        }

        # Pending Reboot
        if ($script:ctx.State.PendingReboot) {
            $null = $sb.AppendLine('<p class="warn"><b>[!] REINICIO REQUERIDO</b> -- Algunos cambios requieren reiniciar el sistema para surtir efecto.</p>')
        }

        # Footer
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

# ========================================================================
# 8. VALIDACION LEGACY (compatibilidad v2.8 -- conservada como fallback)
# ========================================================================

# Test-ManolitoSchema legacy -- mantenido para compatibilidad con JSON v2.8
# En v2.9 la validacion principal es Test-WADSchema (declarativa, ya ejecutada al arranque).
# Esta funcion solo se llama si el JSON reporta version 2.8.x.
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
    $maxRisk  = 0

    foreach ($name in $payloads) {
        $p = $script:ctx.WADData.Payloads.$name
        if (-not $p) { Write-QLog "[SKIP-PLAN] $name no en WAD"; continue }
        $meta = $p._meta
        $guard = Test-PayloadGuards -Payload $p -PayloadName $name
        if (-not $guard.Pass) { Write-QLog "[SKIP-PLAN] $name - $($guard.Reason)"; continue }
        $risk = if ($meta.RiskLevel) { [int]$meta.RiskLevel } else { 0 }
        if ($risk -gt $maxRisk) { $maxRisk = $risk }
        # filtrar por MaxRiskAllowed en runtime (no solo en schema)
        $allowedRisk = if ($script:ctx.WADData.Config.MaxRiskAllowed) {
            [int]$script:ctx.WADData.Config.MaxRiskAllowed
        } else { 5 }
        if ($risk -gt $allowedRisk) {
            Write-QLog "[SKIP-PLAN] $name -- RiskLevel $risk supera MaxRiskAllowed $allowedRisk"
            $plan.Add(@{
                Name      = $name
                Label     = $meta.Label
                Risk      = $meta.Risk
                RiskLevel = $risk
                Reversible= $meta.Reversible
                Skipped   = $true
                SkipReason= "RiskLevel $risk supera MaxRiskAllowed $allowedRisk"
            })
            continue
        }
        $plan.Add(@{
            Name     = $name
            Label    = $meta.Label
            Risk     = $meta.Risk
            RiskLevel= $risk
            Reversible = $meta.Reversible
        })
    }
    return @{ Plan = $plan; MaxRisk = $maxRisk }
}
# ========================================================================
# 10. UI WPF -- XAML
# ========================================================================

$script:XAML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Manolito v2.9.0" Height="820" Width="1000" WindowStyle="None" AllowsTransparency="True"
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

            <!-- CONTROLES OCULTOS DE COMPATIBILIDAD V2.9.0 -->
            <StackPanel Visibility="Collapsed" Grid.Row="0">
                <Button x:Name="BtnLoadPlan"/>
                <TextBlock x:Name="TxtRebootBadge"/>
                <TextBlock x:Name="TxtVersion"/>
                <CheckBox x:Name="ChkAutoScroll"/>
                <Button x:Name="BtnRollback"/>
            </StackPanel>

            <TextBlock Grid.Row="0" Name="txtLogo" HorizontalAlignment="Center" FontWeight="Bold" FontSize="11" Margin="0,0,0,6"><TextBlock.Effect><DropShadowEffect Color="#FF2079" BlurRadius="14" ShadowDepth="0" Opacity="1"/></TextBlock.Effect></TextBlock>
            
            <StackPanel Grid.Row="1" HorizontalAlignment="Center" Margin="0,0,0,10">
                <TextBlock TextAlignment="Center" Margin="0,0,0,4" Foreground="#444444" Effect="{x:Null}">----------------------------------------------------------------------</TextBlock>
                <TextBlock TextAlignment="Center" FontWeight="Bold">. . .  Xciter  . . . P R E S E N T A . . .  [ MANOLITO v2.9.0 ]</TextBlock>
            </StackPanel>
            
            <Grid Grid.Row="2" Margin="0,0,0,10">
                <Grid.ColumnDefinitions><ColumnDefinition Width="1.5*"/><ColumnDefinition Width="1.1*"/><ColumnDefinition Width="1.8*"/></Grid.ColumnDefinitions>
                <Border Grid.Column="0"><StackPanel>
                    <TextBlock Text="[ PERFIL DE SISTEMA ]" FontWeight="Bold" Margin="0,0,0,15"/>
                    <TextBlock Margin="0,4"><Run Text="Motor DB   : " Foreground="#555555"/><Run Text="v2.9.0" Foreground="#FFB000"/></TextBlock>
                    <TextBlock Margin="0,4"><Run Text="Backend    : " Foreground="#555555"/><Run Text="Modular Async" Foreground="#00FFFF"/></TextBlock>
                    
                    <GroupBox Header="Hardware Detectado" Margin="0,15,0,0" Foreground="#AAAAAA" BorderBrush="#333333">
                        <WrapPanel Margin="4,8,4,4" Orientation="Horizontal">
                            <TextBlock Name="TxtBadgeVM" Text="VM" Margin="5" Padding="6,2" Background="#1A1A1A" Foreground="#666666" Effect="{x:Null}"/>
                            <TextBlock Name="TxtBadgeDomain" Text="DOMAIN" Margin="5" Padding="6,2" Background="#1A1A1A" Foreground="#666666" Effect="{x:Null}"/>
                            <TextBlock Name="TxtBadgeSafe" Text="SAFE" Margin="5" Padding="6,2" Background="#1A1A1A" Foreground="#666666" Effect="{x:Null}"/>
                            <TextBlock Name="TxtBadgeReboot" Text="REBOOT" Margin="5" Padding="6,2" Background="#1A1A1A" Foreground="#666666" Effect="{x:Null}"/>
                        </WrapPanel>
                    </GroupBox>
                </StackPanel></Border>
                <Border Grid.Column="1"><StackPanel>
                    <TextBlock Text="[ RUNLEVEL ]" FontWeight="Bold" Margin="0,0,0,15"/>
                    <ComboBox x:Name="CbRunlevel" SelectedIndex="0" Margin="0,10,0,20" Foreground="#BF00FF"/>
                    <CheckBox x:Name="ChkDryRun" Content="DRY RUN" IsChecked="True" Foreground="#00FFFF" FontWeight="Bold" Margin="0,5"/>
                    <CheckBox x:Name="ChkCheckpoint" Content="Crear Restore Point" Foreground="#AAAAAA" Margin="0,5"/>
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
                <ScrollViewer x:Name="svConsole" VerticalScrollBarVisibility="Auto" Margin="5">
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
                             TextOptions.TextRenderingMode="Aliased">Inicializando Manolito Engine v2.9.0...</TextBox>
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
                    <Button x:Name="BtnClearLog" Content="LIMPIAR" Foreground="#555555" BorderBrush="#555555" ToolTip="Limpiar Consola"/>
                    <Button x:Name="BtnAudit" Content="[ Auditar ]" Foreground="#FFAA00" BorderBrush="#FFAA00"/>
                    <Button x:Name="BtnReport" Content="[ Logs ]" Foreground="#00FFFF" BorderBrush="#00FFFF"/>
                    <Button x:Name="BtnSaveProfile" Content="GUARDAR" Foreground="#00FFFF" BorderBrush="#00FFFF"/>
                    <Button x:Name="BtnLoadProfile" Content="CARGAR" Foreground="#FFB000" BorderBrush="#FFB000"/>
                    <Button x:Name="BtnLoadManifest" Content="MANIFEST" Foreground="#BF00FF" BorderBrush="#BF00FF"/>
                    <Button x:Name="btnExit" Content="SALIR" Foreground="#39FF14" BorderBrush="#39FF14"/>
                    <Button x:Name="BtnDryRun" Content="DRY RUN" Foreground="#00FFFF" BorderBrush="#00FFFF" Visibility="Collapsed"/>
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

# ========================================================================
# 11. SHOW-MANOLITODIALOG -- ENTRY POINT UI
# ========================================================================

$script:uiRunspaceJob = $null

function Show-SplashWindow {
    # Splash con ShowDialog (mantiene Dispatcher vivo) + DispatcherTimer interno
    # La carga ocurre paso a paso en el timer. Al terminar abre la ventana principal.
    $splashXaml = @'
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
      <TextBlock Grid.Row="0" Text="[ MANOLITO ENGINE v2.9.0 ]" FontFamily="Consolas" FontSize="13"
                 FontWeight="Bold" Foreground="#00FFFF" HorizontalAlignment="Center" Margin="0,0,0,10"/>
      <ProgressBar x:Name="SplashProgress" Grid.Row="1" Height="8" Minimum="0" Maximum="100" Value="0"
                   Foreground="#BF00FF" Background="#1A0033" BorderBrush="#2D0050" Margin="0,0,0,10"/>
      <TextBlock x:Name="SplashStatus" Grid.Row="2" Text="Iniciando..." FontFamily="Consolas" FontSize="11"
                 Foreground="#AAAAAA" HorizontalAlignment="Center"/>
    </Grid>
  </Border>
</Window>
'@
    $xmlReader  = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($splashXaml))
    $splashWin  = [Windows.Markup.XamlReader]::Load($xmlReader)
    $splashProg = $splashWin.FindName('SplashProgress')
    $splashTxt  = $splashWin.FindName('SplashStatus')

    # Pasos de carga: [pct, texto, scriptblock]
    $script:_splashSteps = @(
        @{ Pct=10; Text='Cargando configuracion WAD...';    Action={ Import-WAD } },
        @{ Pct=40; Text='Detectando hardware...';           Action={ Get-SystemCaps } },
        @{ Pct=85; Text='Preparando interfaz...';           Action={ $null } }
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
        # Primero actualizar UI (render ocurre al salir del tick)
        $script:_splashProg.Value = $step.Pct
        $script:_splashTxt.Text   = $step.Text
        $script:_splashIdx++
        $isLast = ($script:_splashIdx -ge $script:_splashSteps.Count)
        if (-not $isLast) {
            # Ejecutar paso pesado DESPUES de que el render ya fue programado
            try { & $step.Action } catch {}
        } else {
            $timer.Stop()
            $script:_splashProg.Value = 100
            $script:_splashTxt.Text   = 'Listo'
            try { & $step.Action } catch {}
            Show-Logo
            $caps = $script:ctx.SystemCaps
            if ($caps -and $caps.IsSafeMode) {
                $ans = [System.Windows.MessageBox]::Show(
                    "El sistema esta en Modo Seguro.`n`nDeseas continuar?",
                    'Manolito Engine - Modo Seguro',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning)
                if ($ans -ne [System.Windows.MessageBoxResult]::Yes) {
                    $script:_splashWin.Close(); exit 0
                }
            }
            if ($caps -and $caps.PendingReboot) {
                [System.Windows.MessageBox]::Show(
                    "Hay un reinicio pendiente.`n`nPuedes continuar, pero se recomienda reiniciar antes.",
                    'Manolito Engine - Reinicio Pendiente',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information) | Out-Null
            }
            $script:_splashWin.Close()
            Show-MainWindow
        }
    })

    $splashWin.Add_Loaded({ $timer.Start() })
    $splashWin.ShowDialog() | Out-Null
}

function Show-MainWindow {
    Add-Type -AssemblyName System.Windows.Forms  # BOOT: lazy load -- no penaliza el arranque

    # BOOT-B: parsear XAML aquí (no a nivel módulo) usando StringReader
    $xmlReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($script:XAML))
    $window = [Windows.Markup.XamlReader]::Load($xmlReader)

    # Controles
    # Controles actualizados segun XAML v2.9 (PascalCase)
    $cboRunlevel   = $window.FindName('CbRunlevel')
    $chkDryRun     = $window.FindName('ChkDryRun')
    $btnLoadPlan   = $window.FindName('BtnLoadPlan')
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
    $btnDryRunBtn  = $window.FindName('BtnDryRun')
    $chkAutoScroll = $window.FindName('ChkAutoScroll')
    $txtVersion    = $window.FindName('TxtVersion')

    # Popular version real desde WAD
    if ($null -ne $txtVersion) { $txtVersion.Text = " v$($script:ctx.WADData.Manifest.Version)" }

    # BtnClearLog -- limpiar consola
    if ($null -ne $btnClearLog) {
        $btnClearLog.Add_Click({
            $txtLog.Clear()                           # PERF-07-fix: TextBox.Clear() -- Document.Blocks es RichTextBox API
            $script:uiLogLines.Clear()
            & $setStatus 'Log limpiado.'
        })
    }

    # BtnDryRun -- toggle ChkDryRun (alias de acceso rapido)
    if ($null -ne $btnDryRunBtn) {
        $btnDryRunBtn.Add_Click({
            $chkDryRun.IsChecked = $true
            & $setStatus 'Dry Run: ON'
            $btnRun.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        })
    }

    # ChkAutoScroll -- scroll automatico en TxtConsole
    if ($null -ne $chkAutoScroll) {
        $chkAutoScroll.Add_Checked({   $script:uiAutoScroll = $true  })
        $chkAutoScroll.Add_Unchecked({ $script:uiAutoScroll = $false })
    }

    # Badges Hardware -- en VM/Domain/SafeMode el color de fondo/texto
    if ($script:SystemCaps.IsVM) {
        $b = $window.FindName('TxtBadgeVM')
        $b.Text       = '[ VM ]'
        $b.Background = [System.Windows.Media.Brushes]::DarkBlue
        $b.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#88C0D0')
    }
    if ($script:SystemCaps.IsDomain) {
        $b = $window.FindName('TxtBadgeDomain')
        $b.Text       = '[ DOMINIO ]'
        $b.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#3a1e4a')
        $b.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#BF00FF')
    }
    if ($script:SystemCaps.IsSafeMode) {
        $b = $window.FindName('TxtBadgeSafe')
        $b.Text       = '[ SAFE MODE ]'
        $b.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4a1e1e')
        $b.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF5555')
    }

    # Logo (S2-05)
    $logoLines = $null
    try { $logoLines = $script:ctx.WADData.Logo } catch {}
    # $txtLogo extirpado del XAML v2.9 -- logo se escribe en transcript

    # Mensaje primer arranque (S2-11)
    # $txtFirstRun extirpado del XAML v2.9

    # Popular runlevels -- primera entrada vacia para forzar seleccion activa
    $levels = Get-RunlevelList
    [void]$cboRunlevel.Items.Add('-- Selecciona perfil --')
    foreach ($lv in $levels) { [void]$cboRunlevel.Items.Add($lv) }
    $cboRunlevel.SelectedIndex = 0   # apunta a la entrada vacia

    # Estado local de la sesion UI
    $script:uiPlanResult  = $null
    $script:uiAuditLines  = @()
    $script:uiLogLines    = [System.Collections.Generic.List[string]]::new()
    $script:uiBusy        = $false

    # Helper: append log UI
    $maxLogLines = Get-ConfigValue -Key 'LogMaxLines' -Default 5000  # mas margen para Deep
    $appendLog = {
        param([string]$msg)
        $txtLog.AppendText("$msg`n")              # O(1) siempre
        $script:uiLogLines.Add($msg)
        # Histéresis: purga en lote de 500 cuando se supera maxLogLines+500
        # Reduce frecuencia de rebuild O(n) -- critico en Deep con 43 payloads
        if ($script:uiLogLines.Count -gt ($maxLogLines + 500)) {
            $script:uiLogLines.RemoveRange(0, 500)
            $txtLog.Text = ($script:uiLogLines -join "`n") + "`n"  # rebuild puntual cada ~500 msgs
        }
        if ($script:uiAutoScroll -ne $false) { $txtLog.ScrollToEnd() }  # Extra#2: respetar ChkAutoScroll
    }

    $setStatus = { param([string]$msg) $txtStatus.Text = $msg }

    # -----------------------------------------------------------------------
    # DISPATCHERTIMER - drena colas log/progress desde runspace
    # -----------------------------------------------------------------------
    $pollMs = Get-ConfigValue -Key 'PollIntervalMs' -Default 80  # PERF-07: 50->80ms para ceder al renderer en Deep
    $timer  = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds($pollMs)
    $timer.Add_Tick({
        $item = $null
        # Log queue -- batch limitado para no bloquear el dispatcher (max 30 por tick)
        $batchCount = 0
        while ($batchCount -lt 30 -and $script:ctx.LogQueue.TryDequeue([ref]$item)) {
            $batchCount++
            if ($item -match '^LOG:(.*)') {
                & $appendLog $Matches[1]
            } elseif ($item -match '^STATE:(.+)') {
                # (SessionStateProxy comparte el mismo objeto en memoria).
                # Deserializar y destruir el stack nativo seria una degradacion de tipo.
                # Solo se actualiza PendingReboot, que no tiene canal de memoria compartida.
                try {
                    $rs = $Matches[1] | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $rs.State.PendingReboot) {
                        $script:ctx.State.PendingReboot = $rs.State.PendingReboot
                    }
                    if ($null -ne $rs.Results -and $null -ne $rs.Results.Modules) {
                        $script:ctx.Results.Modules.Clear()
                        foreach ($m in @($rs.Results.Modules)) {
                            $script:ctx.Results.Modules.Add($m)
                        }
                    }
                } catch { Write-Warning "[STATE] Deserializacion fallida: $($_.Exception.Message)" }
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
                # 1. Recuento StepsOk / StepsFail desde Results.Modules (ya en ctx via STATE:)
                $stepsOk   = ($script:ctx.Results.Modules | Where-Object { $_.Success -eq $true  }).Count
                $stepsFail = ($script:ctx.Results.Modules | Where-Object { $_.Success -eq $false }).Count
                $window.FindName('TxtStepsOk').Text   = "OK: $stepsOk"
                $window.FindName('TxtStepsFail').Text = "FAIL: $stepsFail"
                # 2. Badge de reinicio pendiente
                if ($script:ctx.State.PendingReboot) {
                    $window.FindName('TxtBadgeReboot').Text = '[ REBOOT PENDING ]'
                if ($null -ne $txtRebootBadgeLg) { $txtRebootBadgeLg.Text = '[ REBOOT PENDING ]' }  # P2-A
                    if ($stepsFail -eq 0 -and $result -eq 'OK') {
                        $r = [System.Windows.MessageBox]::Show(
                            "La ejecucion ha completado correctamente. Algunos cambios requieren REINICIAR el sistema.`n`nDeseas reiniciar ahora? (El sistema se reiniciara en 30 segundos si aceptas)",
                            'Reinicio Pendiente', 'YesNo', 'Warning')
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
                # 3. Auto-export HTML si fue LIVE (no DryRun)
                if (-not $script:ctx.Runtime.IsDryRun -and $result -eq 'OK') {
                    try {
                        $rptPath = Export-HTMLReport -RunlevelName $cboRunlevel.SelectedItem
                        & $appendLog "[REPORT] Reporte generado: $rptPath"
                        Write-UIBeep 'check'
                    } catch { & $appendLog "[REPORT] Error al generar reporte: $($_.Exception.Message)" }
                }
                $script:uiBusy = $false
                $btnRun.IsEnabled      = $true
                $btnRollback.IsEnabled = $true
                $btnReport.IsEnabled   = $true
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
                    Save-ManifestEntry -PayloadName $pname
                }
            }
        }
        # Progress queue
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

    # -----------------------------------------------------------------------
    # CARGAR PLAN
    # -----------------------------------------------------------------------
    $btnLoadPlan.Add_Click({
        Write-UIBeep 'check'
        $lv = $cboRunlevel.SelectedItem
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
                $riskColor = switch ($_.RiskLevel) {
                    4 { '#F44747' } 3 { '#CE9178' } 2 { '#DCDCAA' } 1 { '#4EC9B0' } default { '#D4D4D4' }
                }
                [PSCustomObject]@{
                    Name       = $_.Name
                    Display    = "[$($_.Risk)] $($_.Label)  ($($_.Name))"
                    IsSelected = $true
                    RiskColor  = $riskColor
                }
            }
            $icPayloads.ItemsSource = @($items)
            & $appendLog "[PLAN] $($plan.Count) payload(s) cargados para runlevel '$lv'"
            & $setStatus $script:UI_READY
        } catch {
            & $setStatus "Error al cargar plan: $_"
        }
    })

    # -----------------------------------------------------------------------
    # EJECUTAR
    # -----------------------------------------------------------------------
    $btnSaveProfile.Add_Click({
        $source = $icPayloads.ItemsSource
        if (-not $source) { & $setStatus 'Sin plan cargado'; return }
        $selectedNames = @($source | Where-Object { $_.IsSelected } | Select-Object -ExpandProperty Name)
        if ($selectedNames.Count -eq 0) { & $setStatus 'Sin payloads seleccionados'; return }
        try {
            if (-not (Test-Path $DOCS_MANOLITO)) { New-Item $DOCS_MANOLITO -ItemType Directory -Force | Out-Null }
            $outPath = Join-Path $DOCS_MANOLITO 'custom_profile.json'
            $selectedNames | ConvertTo-Json | Set-Content -Path $outPath -Encoding UTF8
            [System.Windows.MessageBox]::Show(
                "Perfil guardado ($($selectedNames.Count) payloads):`n$outPath",
                'Perfil Guardado', 'OK', 'Information') | Out-Null
            & $appendLog "[PERFIL] Guardado: $($selectedNames.Count) payloads -> $outPath"
            Write-UIBeep 'check'
        } catch { & $appendLog "[PERFIL] Error al guardar: $($_.Exception.Message)" }
    })

    $btnLoadProfile.Add_Click({
        $source = $icPayloads.ItemsSource
        if (-not $source) { & $setStatus 'Sin plan cargado'; return }
        $inPath = Join-Path $DOCS_MANOLITO 'custom_profile.json'
        if (-not (Test-Path $inPath)) {
            [System.Windows.MessageBox]::Show(
                "No se encontro perfil guardado.`nRuta esperada: $inPath",
                'Perfil No Encontrado', 'OK', 'Warning') | Out-Null
            return
        }
        try {
            $savedNames = @(Get-Content $inPath -Raw | ConvertFrom-Json)
            foreach ($item in $source) { $item.IsSelected = ($item.Name -in $savedNames) }
            $icPayloads.Items.Refresh()
            & $appendLog "[PERFIL] Cargado: $($savedNames.Count) payloads restaurados desde $inPath"
            Write-UIBeep 'check'
        } catch { & $appendLog "[PERFIL] Error al cargar: $($_.Exception.Message)" }
    })

    $cboRunlevel.Add_SelectionChanged({
        $sel = $cboRunlevel.SelectedItem
        if ($sel -and $sel -ne '-- Selecciona perfil --') {
            $btnLoadPlan.RaiseEvent(
                (New-Object System.Windows.RoutedEventArgs(
                    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            )
        } elseif ($sel -eq '-- Selecciona perfil --') {
            # Limpiar panel de payloads sin cargar ningun plan
            $lstPayloads.Items.Clear()
            if ($null -ne $txtPlanHdr) { $txtPlanHdr.Text = 'Runlevel: --  |  Selecciona un perfil para comenzar' }
        }
    })

    $btnRun.Add_Click({
        if ($script:uiBusy) { return }
        Write-UIBeep 'action'
        if (-not $script:uiPlanResult) { & $setStatus 'Carga un plan primero'; return }

        $isDry = $chkDryRun.IsChecked  # FIX-1d: ChkDryRun reemplaza rdoDryRun

        # Recoger seleccionados
        $selected = $icPayloads.ItemsSource |
                    Where-Object { $_.IsSelected } |
                    Select-Object -ExpandProperty Name
        if (-not $selected -or @($selected).Count -eq 0) {
            & $setStatus 'Sin payloads seleccionados'; return
        }

        # Construir sub-plan solo con seleccionados
        $subPlan = @{
            Plan    = $script:uiPlanResult.Plan | Where-Object { $selected -contains $_['Name'] }
            MaxRisk = ($script:uiPlanResult.Plan |
                       Where-Object { $selected -contains $_['Name'] } |
                       ForEach-Object { if ($null -ne $_['RiskLevel']) { [int]$_['RiskLevel'] } else { 0 } } |
                       Measure-Object -Maximum).Maximum
        }

        # para que WarnOnExecute evalue el modo real, no el modo inicial (true)
        $script:ctx.Runtime.IsDryRun = $isDry
        if (-not (Confirm-ExecutionPlan -PlanResult $subPlan)) {
            & $setStatus 'Ejecucion cancelada'; return
        }
        # Checkpoint VSS antes de bloquear UI (solo LIVE)
        if (-not $isDry -and $chkCheckpoint -and $chkCheckpoint.IsChecked) {
            & $appendLog '[CHECKPOINT] Creando punto de restauracion del sistema...'
            $cp = Invoke-SafeCheckpoint -Description "Manolito Engine v2.9.0 - Pre-Execution"
            if ($cp.Success) { & $appendLog "[OK] $($cp.Message)"; Write-UIBeep 'check' }
            else             { & $appendLog "[WARN] Checkpoint fallo: $($cp.Message)" }
        }
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
        $script:uiRunspaceJob = Invoke-RunspaceWorker -PayloadNames $namesArr -IsDryRun $isDry -Async
    })

    # -----------------------------------------------------------------------
    # ROLLBACK
    # -----------------------------------------------------------------------
    $btnRollback.Add_Click({
        if ($script:uiBusy) { return }
        Write-UIBeep 'action'
        $cnt    = $script:ctx.Tracking.AppliedPayloads.Count
        $rbCnt  = $script:ctx.Tracking.RollbackStack.Count
        if ($cnt -eq 0 -and $rbCnt -eq 0) { & $setStatus 'Sin payloads aplicados en esta sesion'; return }
        $cnt = [math]::Max($cnt, $rbCnt)
        $msg = [string]::Format($script:UI_ROLLBACK, $cnt)
        $r   = [System.Windows.Forms.MessageBox]::Show($msg, 'Manolito Engine', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
        & $appendLog '[ROLLBACK] Iniciando reversion...'
        $script:ctx.Runtime.IsDryRun = $chkDryRun.IsChecked  # FIX-1d
        Invoke-RollbackSession
        & $setStatus 'Rollback completado'
    })

    # -----------------------------------------------------------------------
    # AUDITAR
    # -----------------------------------------------------------------------
    $btnAudit.Add_Click({
        if ($script:uiBusy) { return }
        & $appendLog '[AUDIT] Iniciando...'
        $script:uiAuditLines = Invoke-AuditMode
        & $setStatus 'Audit completado'
    })

    # -----------------------------------------------------------------------
    # EXPORTAR HTML
    # -----------------------------------------------------------------------
    $btnReport.Add_Click({
        $path = Export-HTMLReport -RunlevelName $cboRunlevel.SelectedItem
        & $setStatus "Reporte exportado: $path"
        & $appendLog "[REPORT] $path"
    })

    # -----------------------------------------------------------------------
    # MANIFEST
    # -----------------------------------------------------------------------
    $btnManifest.Add_Click({
        # FATAL: Manifest v2.8 legacy incompatible con RollbackStack v2.9 -- deshabilitado
        [System.Windows.Forms.MessageBox]::Show(
            "La restauracion desde Manifest v2.8 esta temporalmente deshabilitada en el motor v2.9.0 (Dynamic Core).`nUtilice el Rollback de Sesion.",
            'Funcion No Disponible', 'OK', 'Warning'
        ) | Out-Null
    })

    # -----------------------------------------------------------------------
    # CERRAR
    # -----------------------------------------------------------------------
    # cierre via X nativo de WPF

    $window.Add_Closed({
        $timer.Stop()
        if ($script:MutexHandle) {
            try { $script:MutexHandle.ReleaseMutex() } catch {}
            $script:MutexHandle.Dispose()
        }
        try { Stop-Transcript } catch {}
    })

    
    # CYBERPUNK GUI HACKS: Logo ASCII, arrastre y boton cerrar nativo 2.8.1
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

    # Validaciones de schema en evento Loaded (post-render, UI ya visible)
    $window.Add_Loaded({
        Test-WADSchema    # valida schema WAD (post-render: UI visible antes de validar)
        Test-RunlevelDAG  # valida DAG runlevels
    })

    # Mostrar
    Write-UIBeep 'boot'

    $window.ShowDialog() | Out-Null
}
# ========================================================================
# 12. ENTRY POINT
# ========================================================================
# La llamada aparece al final absoluto, despues de todas las funciones.

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
        # obligatorio. Con Enabled=false (default) esta funcion es no-op.
    try { $auEnabled = $script:ctx.WADData.Config.WADAutoUpdate.Enabled } catch { $auEnabled = $false }
    if ($auEnabled -ne $true) {
        Write-QLog '[WAD] WADAutoUpdate deshabilitado (local-only policy RC). Usando WAD local.'
        return
    }
    # STUB: canal remoto reservado -- requiere ExpectedSha256 obligatorio antes de activar
    Write-QLog '[WAD] WADAutoUpdate Enabled=true detectado pero canal remoto no disponible en RC.'
    Write-QLog '[WAD] Para activar actualizacion remota, implementar ExpectedSha256 fail-closed.'
}
function Import-WAD {
    # Canal remoto eliminado hasta 2.9.1

    if (-not (Test-Path $script:JSONPATH)) {
        [System.Windows.Forms.MessageBox]::Show(
            "No se encontro manolito.json en:`n$script:JSONPATH`n`nPolitica local-only: coloca el WAD junto al motor y vuelve a ejecutar.",
            'Manolito Engine - WAD requerido',
            'OK',
            'Error'
        ) | Out-Null
        exit 1
    }
    # ctx.Config y Apply-UIStrings se asignan DESPUES para recoger el WAD final
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $raw = Get-Content $script:JSONPATH -Raw -Encoding UTF8
        $raw = $raw -replace '(?m)^\s*//.*$', ''
        $script:ctx.WADData = $raw | ConvertFrom-Json
        $script:Config = $script:ctx.WADData
        # FATAL-A fix: reconstruir PayloadMap tras cada carga (incluyendo post-update)
        $script:PayloadMap = @{}
        if ($script:ctx.WADData.Payloads) {
            foreach ($p in $script:ctx.WADData.Payloads.PSObject.Properties) {
                $script:PayloadMap[$p.Name] = $p.Value
            }
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
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

    # Asignar ctx.Config y UI DESPUES del posible update (recoge WAD final)
    $cfgRaw = $script:ctx.WADData.Config
    $script:ctx.Config = @{
        LogMaxLines        = if ($cfgRaw.LogMaxLines)        { [int]$cfgRaw.LogMaxLines }        else { 2000 }
        RunspaceTimeoutSec = if ($cfgRaw.RunspaceTimeoutSec) { [int]$cfgRaw.RunspaceTimeoutSec } else { 600  }
        PollIntervalMs     = if ($cfgRaw.PollIntervalMs)     { [int]$cfgRaw.PollIntervalMs }     else { 50   }
        WADAutoUpdate      = $cfgRaw.WADAutoUpdate
    }
    Apply-UIStrings

    # C-04: Version validator (sobre WAD final post-update)
    $ver = $null
    try { $ver = $script:ctx.WADData.Manifest.Version } catch {}
    if ($ver -and $ver -notmatch '^2\.[89](\.\d+)?$') {
        [System.Windows.MessageBox]::Show(
            "JSON Version incompatible: $ver`nSe requiere v2.8.x o v2.9.x",
            'Manolito Engine - Error', [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
        exit 1
    }
}
function Get-SystemCaps {
    # BOOT-D: Get-CimInstance directo (DCOM por defecto en PS5.1 local, sin -Property)
    $cimSess = $null  # sin sesión explícita: PS5.1 usa DCOM fast path automáticamente
    $caps = @{}
    $caps.IsVM       = $false
    $caps.IsDomain   = $false
    $caps.IsSafeMode = ($env:SAFEMODE -eq '1') -or
                       ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option' -ErrorAction SilentlyContinue).OptionValue -eq 1)
    try {
        # timeout 3s: Win32_ComputerSystem tarda ~1.8s en VirtualBox
        $csJob = Start-Job { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
        $cs    = $csJob | Wait-Job -Timeout 8 | Receive-Job
        Remove-Job $csJob -Force -ErrorAction SilentlyContinue
        if ($cs) {
            $caps.IsVM     = $cs.Model -match 'Virtual|VMware|VirtualBox|HyperV|Hyper-V|QEMU'
            $caps.IsDomain = $cs.PartOfDomain
        }
        # Fallback 1: BIOS manufacturer (VirtualBox=innotek GmbH, VMware, Xen, QEMU)
        if (-not $cs -or -not $caps.IsVM) {
            try {
                $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
                if ($bios -and $bios.Manufacturer -match 'VBOX|VMware|Microsoft|QEMU|Xen|innotek') {
                    $caps.IsVM = $true
                }
            } catch {}
        }
        # Fallback 2: clave ACPI en registro -- instantaneo, sin CIM
        if (-not $caps.IsVM) {
            try {
                $acpi = Get-ItemProperty 'HKLM:\HARDWARE\ACPI\DSDT' -ErrorAction SilentlyContinue
                $acpiNames = (Get-ChildItem 'HKLM:\HARDWARE\ACPI\DSDT' -ErrorAction SilentlyContinue).PSChildName -join ' '
                if ($acpiNames -match 'VBOX|VMWARE|QEMU|VIRT') { $caps.IsVM = $true }
            } catch {}
        }
    } catch {}
    # GPU
    $caps.HasNvidia = $false
    try {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction Stop
        $caps.HasNvidia = ($gpus | Where-Object { $_.Name -match 'NVIDIA' }) -ne $null
        $caps.HasHAGS   = ($gpus | Where-Object {
            $_.Name -match 'NVIDIA|AMD|Radeon|Intel' -and
            ($_.AdapterRAM -ge 8GB -or $_.Name -match 'RTX|RX 5|RX 6|RX 7|Arc')
        }) -ne $null
    } catch { $caps.HasHAGS = $false }
    # NVMe -- timeout 6s: Get-PhysicalDisk tarda 11s+ en VirtualBox/entornos VM
    $caps.HasNVMe = $false
    try {
        $diskJob = Start-Job { Get-PhysicalDisk -ErrorAction Stop }
        $disks   = $diskJob | Wait-Job -Timeout 6 | Receive-Job
        Remove-Job $diskJob -Force -ErrorAction SilentlyContinue
        $nvme = $disks | Where-Object {
            $_.BusType -eq 'NVMe' -or
            $_.MediaType -eq 'SSD' -and $_.FriendlyName -match 'NVMe|NVME' -or
            $_.FriendlyName -match 'NVMe|NVME'
        }
        $caps.HasNVMe = $nvme -ne $null
        if ($caps.HasNVMe) {
            # PnPSignedDriver timeout 4s -- solo se ejecuta si HasNVMe=true
            $drvJob = Start-Job { Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceName LIKE '%NVMe%'" -EA SilentlyContinue | Select-Object -First 1 }
            $drv    = $drvJob | Wait-Job -Timeout 4 | Receive-Job
            Remove-Job $drvJob -Force -ErrorAction SilentlyContinue
            $caps.NVMeDriverIsOEM = $drv -and $drv.DriverProviderName -notmatch 'Microsoft'
            $caps.NVMeDriverName  = if ($drv) { $drv.DriverProviderName } else { 'Microsoft (generic)' }
        }
    } catch { $caps.NVMeDriverIsOEM = $false; $caps.NVMeDriverName = 'Unknown' }
    # Battery
    $caps.HasBattery = $false
    try { $caps.HasBattery = (Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1) -ne $null } catch {}
    # NIC -- timeout 4s: Get-NetAdapter tarda 7s+ en VirtualBox con adaptadores virtuales
    $caps.HasPhysicalNIC = $false
    try {
        $nicJob = Start-Job { Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } }
        $nics   = $nicJob | Wait-Job -Timeout 4 | Receive-Job
        Remove-Job $nicJob -Force -ErrorAction SilentlyContinue
        $caps.HasPhysicalNIC = $nics -ne $null
    } catch {}
    # Printer
    $caps.HasPrinter = $false
    try { $caps.HasPrinter = (Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null } catch {}
    # Office
    $caps.HasOffice = Test-Path 'HKCU:\Software\Microsoft\Office\16.0'
    # OneDrive
    $caps.HasOneDrive = Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
    # Winget
    $caps.CanUseWinget = (Get-Command winget -ErrorAction SilentlyContinue) -ne $null
    # Pending reboot
    $caps.PendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                          (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    # USB Storage
    $usbStart = $null
    try {
        $usbStart = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' -ErrorAction Stop).Start
    } catch {}
    $caps.USBStorageEnabled  = ($usbStart -eq 2 -or $usbStart -eq 3)
    $caps.USBStorageRawValue = $usbStart
    # MSI State placeholder
    $caps.MSIState = 'Unknown'
    # HiberbootEnabled
    try {
        $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled
        $caps.HiberbootEnabled = $hib
    } catch { $caps.HiberbootEnabled = 1 }

    # Extrae: WinBuild -- numero de build de Windows para reporte HTML
    try {
        $caps.WinBuild = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuild
    } catch { $caps.WinBuild = 'N/A' }

    try {
        $blKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker'
        $blVal = (Get-ItemProperty $blKey -Name 'PreventDeviceEncryption' -ErrorAction SilentlyContinue).PreventDeviceEncryption
        $caps.BitLockerAutoEncryptionEnabled = ($null -eq $blVal -or $blVal -ne 1)
    } catch { $caps.BitLockerAutoEncryptionEnabled = $true }

    $script:ctx.SystemCaps = $caps
    $script:SystemCaps = $script:ctx.SystemCaps
    # (sin CimSession que cerrar)
}
function Write-QLog {
    param([string]$msg)
    # P1-B: siempre escribir en ctx.LogQueue (cola drenada por el timer UI)
    # Garantiza que Write-QLog es seguro dentro y fuera del runspace
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
    # Primero los del orden preferido que existan, luego los demas alfabeticamente
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

    # WarnOnSelect: payloads que deben avisarse al seleccionar (ya antes de LIVE)
    $warnSel = if ($script:ctx.Runtime.IsDryRun) { @() } else { $activePlan | Where-Object {
        $pname = $_['Name']
        $pmeta = $script:ctx.WADData.Payloads.$pname._meta
        $pmeta -and $pmeta.WarnOnSelect
    } }
    if ($warnSel.Count -gt 0) {
        $wnames = ($warnSel | ForEach-Object { $_['Name'] }) -join ', '
        $warnMsg = "ADVERTENCIA: Los siguientes payloads tienen WarnOnSelect activo:`n$wnames`n`nRevisa cada uno antes de continuar."
        [System.Windows.Forms.MessageBox]::Show($warnMsg, 'Atencion -- Seleccion de Riesgo', 'OK', 'Warning') | Out-Null
    }


    # WarnOnExecute: aviso Yes/No justo antes de LIVE
    if (-not $script:ctx.Runtime.IsDryRun) {
        $warnExec = $activePlan | Where-Object {
            $pname = $_['Name']
            $pmeta = $script:ctx.WADData.Payloads.$pname._meta
            $pmeta -and $pmeta.WarnOnExecute
        }
        if ($warnExec.Count -gt 0) {
            $enames = ($warnExec | ForEach-Object { $_['Name'] }) -join ', '
            $execMsg = "ADVERTENCIA PREVIA A EJECUCION:`n`nLos siguientes payloads tienen WarnOnExecute activo:`n$enames`n`nEsta a punto de ejecutar cambios que pueden ser dificiles de revertir.`nDeseas continuar?"
            $er = [System.Windows.Forms.MessageBox]::Show($execMsg, 'Atencion -- Ejecucion de Riesgo', 'YesNo', 'Warning')
            if ($er -ne 'Yes') { return $false }
            Write-QLog "[WARN] WarnOnExecute aceptado por usuario para: $enames"
        }
    }

    # ConfirmRequired: payloads que exigen confirmacion explicita
    $confirmReq = if ($script:ctx.Runtime.IsDryRun) { @() } else { $activePlan | Where-Object {
        $pname = $_['Name']
        $pmeta = $script:ctx.WADData.Payloads.$pname._meta
        $pmeta -and $pmeta.ConfirmRequired
    } }
    if ($confirmReq.Count -gt 0) {
        $cnames = ($confirmReq | ForEach-Object { $_['Name'] }) -join ', '
        $cMsg = "CONFIRMACION REQUERIDA:`n`nLos siguientes payloads requieren confirmacion explicita antes de ejecutar:`n$cnames`n`nHas leido las advertencias de cada uno y aceptas los riesgos?"
        $cr = [System.Windows.Forms.MessageBox]::Show($cMsg, 'Confirmacion Obligatoria', 'YesNo', 'Warning')
        if ($cr -ne 'Yes') { return $false }
        Write-QLog "[CONFIRM] ConfirmRequired aceptado por usuario para: $cnames"
    }

    # Irreversibles primero (omitir en Dry Run)
    if ($irrev.Count -gt 0 -and -not $script:ctx.Runtime.IsDryRun) {
        $names = ($irrev | ForEach-Object { $_['Name'] }) -join ', '
        $msg   = [string]::Format($script:UI_IRREV, $irrev.Count, $names)
        $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Manolito Engine', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return $false }
    }

    # Confirmacion general -- ojo solo en LIVE
    if ($script:ctx.Runtime.IsDryRun) { return $true }

    $riskLabel = switch ($maxRisk) {
        4 { 'CRITICO' }
        3 { 'ALTO' }
        2 { 'MODERADO' }
        1 { 'BAJO' }
        default { 'INFO' }
    }
    $msg = [string]::Format($script:UI_LIVECONFIRM, $activePlan.Count) +
           "`n`nRiesgo maximo del plan: $riskLabel (nivel $maxRisk)" +
           "`nModo: LIVE"
    $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Manolito Engine', 'YesNo', 'Information')
    return ($r -eq 'Yes')
}

function Invoke-RunspaceWorker {
    param(
        [string[]]$PayloadNames,
        [bool]$IsDryRun     = $true,
        [bool]$IsRollback   = $false,
        [switch]$Async
    )
    $timeoutSec = Get-ConfigValue -Key 'RunspaceTimeoutSec' -Default 600

    # PERF-04: solo volcar funciones necesarias en el runspace
    $rsWhitelist = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(
            'ConvertTo-NativeHashtable',
            'Get-ConfigValue',
            'Invoke-ExternalCommand',
            'Invoke-Payload',
            'Invoke-PayloadACL',
            'Invoke-PayloadActiveSetup',
            'Invoke-PayloadAppxpackages',
            'Invoke-PayloadBCD',
            'Invoke-PayloadBlueHammer',
            'Invoke-PayloadCleanup',
            'Invoke-PayloadDNS',
            'Invoke-PayloadDeKMS',
            'Invoke-PayloadHosts',
            'Invoke-PayloadMSITuning',
            'Invoke-PayloadNICTuning',
            'Invoke-PayloadNVMeProtect',
            'Invoke-PayloadNagle',
            'Invoke-PayloadNvidiaOptimize',
            'Invoke-PayloadOneDrive',
            'Invoke-PayloadPowercfg',
            'Invoke-PayloadRegistry',
            'Invoke-PayloadRegistryKeys',
            'Invoke-PayloadServices',
            'Invoke-PayloadSkuSiPolicy',
            'Invoke-PayloadTasks',
            'Invoke-PayloadTimerResolution',
            'Invoke-PayloadUSBStorage',
            'Invoke-PayloadUltimatePower',
            'Invoke-PayloadWindowsFeatures',
            'Invoke-PayloadWinget',
            'Resolve-DnsBackup',
            'Save-ManifestEntry',
            'Set-ManolitoReg',
            'Test-ManolitoOwnership',
            'Test-PayloadGuards',
            'Write-QLog'
        ),
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $fb = [System.Text.StringBuilder]::new()
    foreach ($fn in (Get-ChildItem Function:)) {
        if (-not $rsWhitelist.Contains($fn.Name)) { continue }
        try { [void]$fb.Append("function $($fn.Name) {`n$($fn.ScriptBlock)`n}`n") } catch {}
    }
    $funcDefsStr  = $fb.ToString()
    # PERF-05: precompilar el ScriptBlock en el hilo UI (una sola vez por ejecución)
    $funcDefsBlock = [ScriptBlock]::Create($funcDefsStr)

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
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
    $rs.SessionStateProxy.SetVariable('logQueue',      $script:ctx.LogQueue)  # P1: fallback explicito
    $rs.SessionStateProxy.SetVariable('PayloadNames',  $PayloadNames)
    $rs.SessionStateProxy.SetVariable('IsDryRun',      $IsDryRun)
    $rs.SessionStateProxy.SetVariable('IsRollback',    $IsRollback)
    $rs.SessionStateProxy.SetVariable('funcDefs',      $funcDefsStr)
    $rs.SessionStateProxy.SetVariable('funcDefsBlock', $funcDefsBlock)  # PERF-05

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        # PERF-05: usar ScriptBlock precompilado si disponible, Invoke-Expression como fallback
        if ($funcDefsBlock) {
            try   { . $funcDefsBlock }
            catch { $script:ctx.LogQueue.Enqueue("LOG:[ERR-FUNCDEFS] Fallo al cargar funciones (block): $_") }
        } elseif ($funcDefs) {
            try   { Invoke-Expression $funcDefs }
            catch { $script:ctx.LogQueue.Enqueue("LOG:[ERR-FUNCDEFS] Fallo al cargar funciones (expr): $_") }
        }
        $script:ctx           = $ctx
        $script:PayloadMap    = $PayloadMap
        $script:ProviderMap   = $ProviderMap
        $script:SystemCaps    = $SystemCaps
        $script:Config        = $Config
        $script:wingetBlocked = $wingetBlocked
        $script:logQueue      = $script:ctx.LogQueue
        $script:ctx.Runtime.IsDryRun   = $IsDryRun
        $script:ctx.Runtime.IsRollback = $IsRollback

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
        # NEW-01 fix: DONE:OK en finally -- garantiza emision aunque ConvertTo-Json falle
        try {
            $statePayload = @{
                State    = @{
                    StepsOk       = $script:ctx.State.StepsOk
                    StepsFail     = $script:ctx.State.StepsFail
                    PendingReboot = $script:ctx.State.PendingReboot
                }
                Tracking = @{
                    RegDiff             = @($script:ctx.Tracking.RegDiff)
                    PayloadsExecuted    = @($script:ctx.Tracking.PayloadsExecuted)
                    IrreversibleActions = @($script:ctx.Tracking.IrreversibleActions)
                    RollbackStack       = @($script:ctx.Tracking.RollbackStack.ToArray())
                }
                Results  = @{ Modules = @($script:ctx.Results.Modules) }
            } | ConvertTo-Json -Depth 12 -Compress
            $script:ctx.LogQueue.Enqueue("STATE:$statePayload")
        } catch {
            $script:ctx.LogQueue.Enqueue("LOG:    [WARN] STATE serialization failed: $($_.Exception.Message)")
        } finally {
            $script:ctx.LogQueue.Enqueue('DONE:OK')
            $script:ctx.ProgressQueue.Enqueue('PROG:100')
        }
    })

    $handle = $ps.BeginInvoke()

    if ($Async) {
        return @{ PS = $ps; RS = $rs; Handle = $handle; Deadline = [DateTime]::UtcNow.AddSeconds($timeoutSec) }
    }

    # Modo sincrono (rollback directo / CLI)
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
    # NEW-03: ConcurrentStack usa TryPop([ref]) en lugar de .Pop()
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
                # Despacho O(1) por ProviderMap -- sin switch masivo (OCP)
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
        [System.Windows.MessageBox]::Show($msg, 'Rollback - Acciones Manuales', 'OK', 'Warning') | Out-Null
    }
}

function Invoke-RollbackSession {
    # S3: Delega en Invoke-RollbackStack (pila formal Type A/B/C)
    # AppliedPayloads se usa solo como log de nombres; la inversion real
    # viene del RollbackStack que cada provider ha llenado.
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
    # Inicializa constantes (sin I/O) y muestra splash
    # Import-WAD, Get-SystemCaps, guards y Show-MainWindow se orquestan
    # dentro del DispatcherTimer de Show-SplashWindow
    $script:ValidRiskLevels = @(0, 1, 2, 3, 4)
    $script:ValidToggle     = @('Universal', 'OwnedOnly', 'None')
    $script:SpecializedProviders = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(
            'Hosts','Services','Tasks','AppxPackages','WindowsFeatures','Cleanup',
            'BCD','MSITuning','NICTuning','DNS','Nagle','Powercfg','UltimatePower',
            'TimerResolution','NvidiaOptimize','ActiveSetup','OneDrive','DeKMS',
            'Winget','USBStorage','NVMeProtect','BlueHammer','RegistryKeys','ACL',
            'Registry','NICProperties','UltimatePowerPlan','TimerResConfig',
            'PowercfgSettings','NVMeProtectTemplate','USBStorageTemplate',
            'Blacklist','WingetPackages','NvidiaOptimizeTemplate','OneDriveUninstall',
            'ActiveSetupEntries','HostsEntries','Packages','TempCleanup','DismResetBase',
            'NagleTemplate','DeviceClasses','SkuSiPolicyTemplate'
        ),
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $script:KnownCaps = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(
            'IsVM','IsDomain','HasNvidia','HasNVMe','HasBattery','HasPhysicalNIC',
            'HasPrinter','HasOffice','HasOneDrive','HasHAGS','CanUseWinget',
            'IsSafeMode','PendingReboot','USBStorageEnabled','USBStorageRawValue',
            'NVMeDriverIsOEM','NVMeDriverName','MSIState','HiberbootEnabled','WinBuild',
            'BitLockerAutoEncryptionEnabled'
        ),
        [System.StringComparer]::OrdinalIgnoreCase
    )
    Show-SplashWindow   # ojo, bloquea hasta que Show-MainWindow se cierre
}
# ========================================================================
# INICIO
# ========================================================================

# Copia SkuSiPolicy.p7b al ESP para permitir Feature Updates en hardware
function Invoke-PayloadSkuSiPolicy {
    param($Payload, [string]$PayloadName,
          [switch]$IsRollback,
          [object]$RollbackEntry)

    $logs    = [System.Collections.Generic.List[string]]::new()
    $success = $true
    $changes = 0

    if ($IsRollback) {
        $data = $RollbackEntry.Data
        try {
            if ($data.BackupPath -and (Test-Path $data.BackupPath)) {
                Remove-Item $data.BackupPath -Force -ErrorAction Stop
                Write-QLog "[ROLLBACK]   SkuSiPolicy.p7b eliminado del ESP"
            } else {
                Write-QLog "[ROLLBACK]   SkuSiPolicy.p7b no encontrado -- posiblemente ya eliminado"
            }
        } catch { Write-QLog "[ROLLBACK]   ERR SkuSiPolicy: $_" }
        return @{ Success = $true }
    }

    # Detectar ruta del ESP via mountvol
    $espPath = $null
    try {
        $vols = & mountvol 2>$null
        foreach ($line in $vols) {
            $line = $line.Trim()
            if ($line -match '^[A-Z]:\\$') {
                $candidate = $line.TrimEnd('')
                $efi = Join-Path $candidate 'EFI'
                if (Test-Path $efi) { $espPath = $candidate; break }
            }
        }
    } catch {}

    if (-not $espPath) {
        # Fallback: buscar en unidades disponibles
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -eq 'Fixed') {
                $efi = Join-Path $drive.RootDirectory.FullName 'EFI'
                if (Test-Path $efi) { $espPath = $drive.RootDirectory.FullName.TrimEnd(''); break }
            }
        }
    }

    if (-not $espPath) {
        $logs.Add("ERR SkuSiPolicy -- no se pudo localizar el ESP (EFI System Partition)")
        return @{ Success = $false; Changes = 0; Logs = $logs }
    }

    $destDir  = Join-Path $espPath 'EFI\Microsoft\Boot'
    $destFile = Join-Path $destDir 'SkuSiPolicy.p7b'
    $srcFile  = Join-Path $env:SystemRoot 'Boot\EFI\SkuSiPolicy.p7b'

    if (-not (Test-Path $srcFile)) {
        $logs.Add("ERR SkuSiPolicy -- origen no encontrado: $srcFile")
        return @{ Success = $false; Changes = 0; Logs = $logs }
    }

    if ($script:ctx.Runtime.IsDryRun) {
        $logs.Add("DRY SkuSiPolicy -- copiaria $srcFile -> $destFile")
        return @{ Success = $true; Changes = 0; Logs = $logs }
    }

    try {
        if (-not (Test-Path $destDir)) { New-Item $destDir -ItemType Directory -Force | Out-Null }
        Copy-Item $srcFile $destFile -Force -ErrorAction Stop
        $changes++
        $logs.Add("OK  SkuSiPolicy.p7b copiado a ESP: $destFile")
        $logs.Add("INFO Requiere reinicio para activarse. Requiere reinicio del sistema")

        if (-not $script:ctx.Runtime.IsRollback -and -not $script:ctx.Runtime.IsManifestRestore) {
            $script:ctx.Tracking.RollbackStack.Push(@{
                PayloadName = $PayloadName
                ProviderKey = 'SkuSiPolicyTemplate'
                Type        = 'A'
                IsIRR       = $false
                Data        = @{ BackupPath = $destFile }
            })
        }
    } catch {
        $logs.Add("ERR SkuSiPolicy -- $_")
        $success = $false
    }

    return @{ Success = $success; Changes = $changes; Logs = $logs }
}

$script:ProviderMap = @{
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
}


Start-ManolitoEngine
