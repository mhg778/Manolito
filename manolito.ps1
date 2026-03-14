<# 
╔══════════════════════════════════════════════════════════════════╗
║              Manolito v2.1 — Windows 11 Education                ║
║       Optimizador modular: dev · gaming · estudio                ║
╠══════════════════════════════════════════════════════════════════╣
║  Modos     : Lite | DevEdu | Deep | Personalizado | Restore      ║
║  DryRun    : simula todos los cambios sin aplicar nada           ║
║  Skip      : -Skip HyperV SSD AdminTools (secciones separadas)   ║
║  Gaming    : -GamingMode (conserva Xbox + optimizaciones gaming) ║
║  DNS       : -SetSecureDNS (1.1.1.1 + 9.9.9.9)                   ║
║  Interac.  : -Interactive (menu + sub-menu toggles)              ║
╠══════════════════════════════════════════════════════════════════╣
║  Ejemplos  : .\manolito.ps1 -Interactive                         ║
║              .\manolito.ps1 -Mode Deep -GamingMode -SetSecureDNS ║
╚══════════════════════════════════════════════════════════════════╝

.SYNOPSIS
    Manolito v2.1 — Optimizador Windows 11 Education con toggles gaming/admin/DNS/OfflineOS
.PARAMETER Mode
    Preset: Lite | DevEdu | Deep | Restore (default: DevEdu)
.PARAMETER DryRun
    Simula todos los cambios sin aplicar nada al sistema.
.PARAMETER Skip
    Secciones a omitir (separadas por espacio):
    Activation,Updates,Defender,HyperV,Bloatware,OneDrive,Xbox,Power,UI,
    Telemetry,SSD,Privacy,Cleanup,OptionalFeatures,DiskSpace,ExplorerPerf,DevEnv,AdminTools
.PARAMETER GamingMode
    Conserva Xbox + optimizaciones gaming (HAGS, mouse latency). Desactiva desgamificación.
.PARAMETER SetSecureDNS
    Configura DNS 1.1.1.1 + 9.9.9.9 en adaptadores físicos Up.
.PARAMETER SkipAdminTools
    Omite instalación de herramientas sysadmin via winget.
.PARAMETER Interactive
    Menu interactivo con sub-menu de toggles.
#>

[CmdletBinding()]
param(
    [ValidateSet("Lite","DevEdu","Deep","Restore")]
    [Parameter(HelpMessage="Preset de ejecucion: Lite | DevEdu | Deep | Restore")]
    [string]$Mode = "DevEdu",

    [Parameter(HelpMessage="Simula todos los cambios sin aplicar nada al sistema")]
    [switch]$DryRun,

    [ValidateSet(
        "Activation","Updates","Defender","HyperV","Bloatware","OneDrive","Xbox",
        "Power","UI","Telemetry","SSD","Privacy","Cleanup","OptionalFeatures",
        "DiskSpace","ExplorerPerf","DevEnv","AdminTools","OfflineOS","DNS"
    )]
    [Parameter(HelpMessage="Secciones a omitir, separadas por espacio (ej: -Skip HyperV SSD)")]
    [string[]]$Skip = @(),

    [Parameter(HelpMessage="Conserva Xbox + optimizaciones gaming (HAGS, mouse latency)")]
    [switch]$GamingMode,

    [Parameter(HelpMessage="Configura DNS seguros 1.1.1.1 + 9.9.9.9 en adaptadores fisicos")]
    [switch]$SetSecureDNS,

    [Parameter(HelpMessage="Omite instalacion de herramientas sysadmin via winget")]
    [switch]$SkipAdminTools,

    [Parameter(HelpMessage="Lanza el menu interactivo con sub-menu de toggles")]
    [switch]$Interactive
)

#region ── CONFIGURACION DE USUARIO ───────────────────────────────────────────
# LICENCIA WINDOWS — introduce tu clave aquí o usa el prompt interactivo
$script:ProductKey = "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"
#endregion

#region ── BOOTSTRAP ──────────────────────────────────────────────────────────
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['Out-File:Encoding'] = 'UTF8'

$PSMajor = $PSVersionTable.PSVersion.Major
if ($PSMajor -lt 5) {
    $errMsg = "[ERROR] Se requiere PowerShell 5.1 o superior. Detectado: $PSMajor"
    [Console]::Error.WriteLine($errMsg)
    Write-Host $errMsg -ForegroundColor Red
    exit 1
}
$PS7Plus = ($PSMajor -ge 7)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Se requieren privilegios de administrador. Relanzando elevado..."
    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode `"$Mode`""
    if ($DryRun.IsPresent)      { $argList += " -DryRun" }
    if ($Interactive.IsPresent) { $argList += " -Interactive" }
    if ($GamingMode.IsPresent)  { $argList += " -GamingMode" }
    if ($SetSecureDNS.IsPresent){ $argList += " -SetSecureDNS" }
    if ($SkipAdminTools.IsPresent) { $argList += " -SkipAdminTools" }
    if ($Skip.Count -gt 0) {
        $skipArgs = $Skip | ForEach-Object { "`"$_`"" }
        $argList += " -Skip " + ($skipArgs -join " ")
    }
    Start-Process $psExe $argList -Verb RunAs
    exit
}

Set-StrictMode -Version Latest

# Exit-Script en scope global: disponible antes del try{} (fix B3)
function Exit-Script {
    param([int]$Code = 0)
    exit $Code  # finally{} siempre libera mutex + Stop-Transcript
}

# Mutex — $_mutex y $acquired preinicializados para garantizar finally{} seguro
$_mutex   = $null
$acquired = $false

try {
    $_mutex = [System.Threading.Mutex]::new($false, "Global\ManolitoOptimizer")
    try {
        $acquired = $_mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $acquired = $true  # mutex recuperado del proceso anterior muerto
    }
    if (-not $acquired) {
        Write-Host "[ERROR] Manolito ya esta en ejecucion en otra ventana." -ForegroundColor Red
        exit 1  # No poseemos el mutex, no lo liberamos
    }

    $PS7Plus = ($PSMajor -ge 7)   # $PSMajor ya validado en bootstrap

    # Verificacion de entorno: Windows 11 Education
    $OSInfo    = Get-CimInstance Win32_OperatingSystem
    $WinBuild  = [int]$OSInfo.BuildNumber
    $OSCaption = $OSInfo.Caption
    $OSSku     = [int]$OSInfo.OperatingSystemSKU
    $IsEducationSku = ($OSSku -in @(121, 122))  # Education / Education N

    $WIN11_BUILD_LATEST_TESTED = 26100
    if ($WinBuild -gt $WIN11_BUILD_LATEST_TESTED -and $IsEducationSku) {
        Write-Warning "Build $WinBuild superior al ultimo testado ($WIN11_BUILD_LATEST_TESTED / Win11 24H2). Proceder con precaucion."
    }

    if ($WinBuild -lt 22000 -or -not $IsEducationSku) {
        $skuLabel = if ($OSSku -gt 0) { "SKU=$OSSku" } else { "SKU desconocido" }
        $errLines = @(
            "ERROR: Este script esta disenado exclusivamente para Windows 11 Education.",
            "SO detectado: $OSCaption (Build $WinBuild | $skuLabel)",
            "SKUs aceptados: 121 (Education), 122 (Education N).",
            "Abortando."
        )
        foreach ($e in $errLines) {
            [Console]::Error.WriteLine($e)
            Write-Host $e -ForegroundColor Red
        }
        Exit-Script 1
    }

    # Transcript y rutas
    $TranscriptPath = Join-Path $env:USERPROFILE "manolito_transcript_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    Start-Transcript -Path $TranscriptPath -Append -NoClobber -ErrorAction SilentlyContinue

    $LogFile  = Join-Path $env:USERPROFILE "manolito_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $BackupDir = Join-Path $env:USERPROFILE "manolito_regbackup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    # Constantes de registro
    $REG_DATACOLLECTION    = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
    $REG_DATACOLLECTION2   = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"
    $REG_WU_AU             = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $REG_DEFENDER_SPYNET   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet"
    $REG_COPILOT_USER      = "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot"
    $REG_COPILOT_MACHINE   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
    $REG_EXPLORER_ADV      = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    $REG_CDM               = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    $REG_APP_PRIVACY       = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore"
    $REG_POLICIES_SYSTEM   = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    $REG_WORKPLACE_JOIN    = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WorkplaceJoin"
    $REG_MSA               = "HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftAccount"
    $REG_OOBE              = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"
    $REG_SYSTEM_POLICIES   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
    $REG_EDGE_POLICIES     = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    $REG_LONGPATHS         = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"

    # Listas compartidas
    $PrivacyCapabilities = @("location","contacts","appointments","phoneCallHistory","radios","userNotificationListener")
    $TelemetryTasks = @(
        @{Path="\Microsoft\Windows\Application Experience\"; Name="Microsoft Compatibility Appraiser"},
        @{Path="\Microsoft\Windows\Application Experience\"; Name="ProgramDataUpdater"},
        @{Path="\Microsoft\Windows\Application Experience\"; Name="StartupAppTask"},
        @{Path="\Microsoft\Windows\Customer Experience Improvement Program\"; Name="Consolidator"},
        @{Path="\Microsoft\Windows\Customer Experience Improvement Program\"; Name="UsbCeip"},
        @{Path="\Microsoft\Windows\Autochk\"; Name="Proxy"},
        @{Path="\Microsoft\Windows\DiskDiagnostic\"; Name="Microsoft-Windows-DiskDiagnosticDataCollector"}
    )

    # Estado global
    $ctx = @{
        StepsOk          = 0
        StepsFail        = 0
        StepNum          = 0
        AggressiveDisk   = $false
        RebootRequired   = [System.Collections.Generic.List[string]]::new()
        SkipList         = [System.Collections.Generic.List[string]]::new()
        ProvisionedCache = $null
        InstalledCache   = $null
        DryRunActions    = [System.Collections.Generic.List[string]]::new()
        FailedModules    = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($s in ($Skip -split '[,\s]+' | Where-Object { $_ })) { $ctx.SkipList.Add($s) }

    $ValidSections = @("Activation","Updates","Defender","HyperV","Bloatware","OneDrive","Xbox",
                      "Power","UI","Telemetry","SSD","Privacy","Cleanup","OptionalFeatures",
                      "DiskSpace","ExplorerPerf","DevEnv","AdminTools","OfflineOS","DNS")

    # Helpers
    function Write-Log {
        param([string]$Message, [string]$Color = "White")
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
        Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue
        Write-Host $Message -ForegroundColor $Color
    }

    function Add-Skip {
        param([string]$Section)
        if ($Section -in $ValidSections) {
            if ($Section -notin $ctx.SkipList) { $ctx.SkipList.Add($Section) }
        } else {
            Write-Log "[WARN] Seccion '$Section' no reconocida en Add-Skip. Ignorada." "DarkYellow"
        }
    }

    function Test-Skip([string]$Section) { $ctx.SkipList -contains $Section }


    function Set-RegistryValue {
        param([string]$Path, [string]$Name, $Value, [string]$Type = "DWord")
        if ($DryRun.IsPresent) {
            $msg = "  [DRY-RUN] Reg: $Path\$Name = $Value"
            Write-Log $msg "DarkGray"
            $ctx.DryRunActions.Add($msg)
            return
        }
        try {
            if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
            if ($Name -eq "(Default)") {
                $current = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
                if ($null -ne $current -and $current.GetValue('') -eq $Value) { return }
                Set-Item -LiteralPath $Path -Value $Value -ErrorAction Stop
            } else {
                $current = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
                if ($null -ne $current -and $current.$Name -eq $Value) { return }
                Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
            }
        } catch {
            Write-Log "  [WARN] No se pudo escribir $Path\$Name : $_" "DarkYellow"
        }
    }

    function Set-PrivacyConsent {
        param([ValidateSet("Allow","Deny")][string]$Value)
        foreach ($cap in $PrivacyCapabilities) {
            Set-RegistryValue "$REG_APP_PRIVACY\$cap" "Value" $Value "String"
        }
    }

    function Stop-ServiceSafe {
        param([string]$Name)
        if ($DryRun.IsPresent) {
            $msg = "  [DRY-RUN] Stop+Disable servicio: $Name"
            Write-Log $msg "DarkGray"
            $ctx.DryRunActions.Add($msg)
            return
        }
        $svc = Get-Service $Name -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service $Name -Force -ErrorAction SilentlyContinue
            Set-Service $Name -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Log "   Servicio $Name detenido y deshabilitado." "DarkGray"
        }
    }

    function Start-ServiceSafe {
        param([string]$Name)
        if ($DryRun.IsPresent) {
            $msg = "  [DRY-RUN] Enable+Start servicio: $Name"
            Write-Log $msg "DarkGray"
            $ctx.DryRunActions.Add($msg)
            return
        }
        $svc = Get-Service $Name -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service $Name -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service $Name -ErrorAction SilentlyContinue
            Write-Log "   Servicio $Name habilitado e iniciado." "DarkGray"
        }
    }

    function Disable-ScheduledTaskSafe {
        param([string]$TaskPath, [string]$TaskName)
        if ($DryRun.IsPresent) {
            $msg = "  [DRY-RUN] Disable task: $TaskPath$TaskName"
            Write-Log $msg "DarkGray"
            $ctx.DryRunActions.Add($msg)
            return
        }
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task -and $task.State -ne 'Disabled') {
            $task | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
            Write-Log "   Tarea $TaskName deshabilitada." "DarkGray"
        }
    }

    function Enable-ScheduledTaskSafe {
        param([string]$TaskPath, [string]$TaskName)
        if ($DryRun.IsPresent) {
            $msg = "  [DRY-RUN] Enable task: $TaskPath$TaskName"
            Write-Log $msg "DarkGray"
            $ctx.DryRunActions.Add($msg)
            return
        }
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task -and $task.State -eq 'Disabled') {
            $task | Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
            Write-Log "   Tarea $TaskName habilitada." "DarkGray"
        }
    }

    function Remove-AppxSafe {
        param([string]$Pattern)
        if ($DryRun.IsPresent) {
            $msg = "  [DRY-RUN] Remove-Appx $Pattern"
            Write-Log $msg "DarkGray"
            $ctx.DryRunActions.Add($msg)
            return
        }
        if ($null -ne $ctx.InstalledCache) {
            $ctx.InstalledCache | Where-Object { $_.Name -like $Pattern } | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        } else {
            Get-AppxPackage -Name $Pattern -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        }
        if ($null -ne $ctx.ProvisionedCache) {
            $ctx.ProvisionedCache | Where-Object { $_.DisplayName -like $Pattern } | ForEach-Object {
                Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }

    function Invoke-Step {
        param([string]$Section, [string]$Label, [scriptblock]$Action)
        if (Test-Skip $Section) {
            Write-Log "[$Section] OMITIDO por -Skip" "DarkYellow"
            return
        }
        $ctx.StepNum++
        $stepTag = "[$($ctx.StepNum.ToString('D2'))][$Section]"
        if ($DryRun.IsPresent) {
            $msg = "  [DRY-RUN] $stepTag $Label"
            Write-Log $msg "DarkGray"
            $ctx.DryRunActions.Add($msg)
            $ctx.StepsOk++
            return
        }
        Write-Log "$stepTag $Label" "Cyan"
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        try {
            & $Action
            $ctx.StepsOk++
        } catch {
            Write-Log "  [ERROR] $Section : $_" "Red"
            $ctx.StepsFail++
            $ctx.FailedModules.Add($Section)
        } finally {
            $ErrorActionPreference = $prevEAP
        }
    }

    # Preflight functions
    function Test-PendingReboot {
        $cbsKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
        $wuKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        $smKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
        $pfroExists = $false
        try {
            $smProps = Get-ItemProperty -LiteralPath $smKey -ErrorAction Stop
            $pfro = $smProps.PendingFileRenameOperations
            $pfroExists = ($null -ne $pfro) -and ($pfro.Count -gt 0)
        } catch {}
        return (Test-Path $cbsKey) -or (Test-Path $wuKey) -or $pfroExists
    }

    function Test-AVInterference {
        $mpPref = Get-MpPreference -ErrorAction SilentlyContinue
        if ($mpPref -and -not $mpPref.DisableRealtimeMonitoring) { return $true }
        $edr = Get-Process "csagent","falconctl","carbonblack" -ErrorAction SilentlyContinue
        return ($null -ne $edr -and $edr.Count -gt 0)
    }

    function Test-SafeMode {
        return $env:SAFEBOOT_OPTION  # Fix B2: variable oficial de Windows Safe Mode
    }

    function Backup-Registry {
        New-Item $BackupDir -ItemType Directory -Force | Out-Null
        & reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer" "$BackupDir\HKCU_Explorer.reg" /y 2>$null
        & reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Search" "$BackupDir\HKCU_Search.reg" /y 2>$null
        & reg export "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "$BackupDir\HKLM_DataCollection.reg" /y 2>$null
        & reg export "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" "$BackupDir\HKLM_WindowsUpdate.reg" /y 2>$null
        & reg export "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies" "$BackupDir\HKLM_Policies.reg" /y 2>$null
        Write-Log "Backup de registro selectivo creado en: $BackupDir" "Green"
    }

    # Menu interactivo con sub-menu toggles
    if ($Interactive.IsPresent) {
        Clear-Host
        $menuText = @"
╔══════════════════════════════════════════════════════════════════╗
║           Manolito v2.1 — Optimizador Windows 11 Education       ║
╠══════════════════════════════════════════════════════════════════╣
║  [1] Lite        Estudio basico. Minimo impacto al sistema.      ║
║  [2] DevEdu      Dev + gaming + video.  ★ RECOMENDADO           ║
║  [3] Deep        Maxima limpieza. Incluye DISM (irreversible).   ║
║  [4] Personalizado  Elige que secciones omitir.                  ║
║  [5] DryRun      Simular DevEdu sin aplicar cambios.             ║
║  [6] Restore     Revertir cambios criticos al estado original.   ║
║  [0] Salir                                                       ║
╚══════════════════════════════════════════════════════════════════╝
"@
        Write-Host $menuText -ForegroundColor Cyan
        $choice = Read-Host "Elige [0-6]"
        switch ($choice) {
            "1" { $Mode = "Lite" }
            "2" { $Mode = "DevEdu" }
            "3" { $Mode = "Deep" }
            "4" {
                $Mode = "DevEdu"
                Write-Log "`nSecciones disponibles:" "Yellow"
                Write-Log "  Activation, Updates, Defender, HyperV, Bloatware, OneDrive, Xbox," "DarkGray"
                Write-Log "  Power, UI, Telemetry, SSD, Privacy, Cleanup, OptionalFeatures," "DarkGray"
                Write-Log "  DiskSpace, ExplorerPerf, DevEnv, AdminTools" "DarkGray"
                $customSkip = Read-Host "`nSecciones a OMITIR separadas por coma (Enter = ninguna)"
                if ($customSkip.Trim()) {
                    $customSkip -split "\s*,\s*" | ForEach-Object { Add-Skip $_.Trim() }
                }
            }
            "5" { $Mode = "DevEdu"; $DryRun = [switch]::Present }
            "6" { $Mode = "Restore" }
            "0" { Exit-Script 0 }
            default { Write-Log "Opcion no valida. Saliendo." "Red"; Exit-Script 1 }
        }

        # Sub-menu toggles SOLO para modos 1-4 (no DryRun ni Restore)
        if ($Mode -in @("Lite","DevEdu","Deep") -and -not $DryRun.IsPresent) {
            $optAdminTools = $true
            $optDesgamificar = $true  # Desgamifica por defecto
            $optDNS = $false

            do {
                Clear-Host
                $toggleText = @"
╔═══════════════════════════════════════ TOGGLES ═══════════════════════╗
║  [1] Instalar Kit Sysadmin (Winget)    : [$(if ($optAdminTools) {'X'} else {' '})] SI / [ ] NO ║
║  [2] Desgamificar (Eliminar Xbox)      : [$(if ($optDesgamificar) {'X'} else {' '})] SI / [ ] NO ║
║  [3] Aplicar DNS Seguras (1.1.1.1)     : [$(if ($optDNS) {'X'} else {' '})] SI / [ ] NO         ║
║  [0] CONFIRMAR Y EJECUTAR                                                     ║
╚════════════════════════════════════════════════════════════════════════╝
"@
                Write-Host $toggleText -ForegroundColor Cyan
                $toggleChoice = Read-Host "Elige [0-3]"
                switch ($toggleChoice) {
                    "1" { $optAdminTools = -not $optAdminTools }
                    "2" { $optDesgamificar = -not $optDesgamificar }
                    "3" { $optDNS = -not $optDNS }
                    "0" { break }
                }
            } while ($toggleChoice -notin @("0"))

            # Aplicar toggles como flags CLI equivalentes
            if (-not $optAdminTools) { Add-Skip "AdminTools" }
            if (-not $optDesgamificar) { $GamingMode = [switch]::Present }
            if ($optDNS) { $SetSecureDNS = [switch]::Present }
        }
    }

    # Aplicar Skip por modo
    switch ($Mode) {
        "Lite" { foreach ($s in @("HyperV","Xbox","Power","SSD","DiskSpace")) { Add-Skip $s } }
        "Deep" { $ctx.AggressiveDisk = $true }
    }

    # Aplicar flags CLI como skips
    if ($SkipAdminTools.IsPresent) { Add-Skip "AdminTools" }

    # Preflight
    if ($DryRun.IsPresent) {
        Write-Log "[DRY-RUN] Backup de registro omitido (sin cambios en simulacion)." "DarkYellow"
    } else {
        Backup-Registry
    }

    if (Test-PendingReboot) {
        Write-Warning "[⚠️] Hay un reinicio pendiente detectado. Reinicia antes de continuar."
        $continueAny = Read-Host "Continuar de todos modos? [s/N]"
        if ($continueAny -notmatch "^[sS]$") { Exit-Script 2 }
    }

    # Fix B2: Safe Mode correcto
    if (Test-SafeMode) {
        Write-Host "[ERROR] Manolito no debe ejecutarse en modo seguro. Reinicia en modo normal." -ForegroundColor Red
        Exit-Script 1
    }

    if (Test-AVInterference) {
        Write-Warning "[⚠️] Defender RealTime o EDR detectado. Algunas operaciones pueden fallar."
    }

    if (-not $DryRun.IsPresent) {
        $ctx.ProvisionedCache = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        $ctx.InstalledCache = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    }

    # Cabecera
    $dryLabel = if ($DryRun.IsPresent) { " (DRY-RUN)" } else { "" }
    $skipLabel = if ($ctx.SkipList.Count -gt 0) { " | Skip: $($ctx.SkipList -join ',')" } else { "" }
    $psLabel = if ($PS7Plus) { "PS7+ (paralelo)" } else { "PS$PSMajor" }
    Write-Log "================================================================" "Green"
    Write-Log "Manolito v2.1 — Modo: $Mode$dryLabel$skipLabel | $psLabel" "Green"
    Write-Log "OS: $OSCaption  |  Build: $WinBuild" "DarkGray"
    Write-Log "Log: $LogFile  |  Transcript: $TranscriptPath" "DarkGray"
    if (-not $DryRun.IsPresent) { Write-Log "Backup registro: $BackupDir" "DarkGray" }
    Write-Log "================================================================" "Green"

    # MODO RESTORE
    function Invoke-RestoreMode {
        Write-Log "MODO RESTORE: revirtiendo cambios al estado Windows por defecto..." "Yellow"

        Write-Log "  Windows Update -> automatico..." "Cyan"
        Set-RegistryValue $REG_WU_AU "AUOptions" 3
        Set-RegistryValue $REG_WU_AU "NoAutoUpdate" 0
        Set-RegistryValue $REG_WU_AU "NoAutoRebootWithLoggedOnUsers" 0

        Write-Log "  Telemetria -> nivel basico (1)..." "Cyan"
        Set-RegistryValue $REG_DATACOLLECTION  "AllowTelemetry" 1
        Set-RegistryValue $REG_DATACOLLECTION2 "AllowTelemetry" 1
        Set-RegistryValue $REG_DATACOLLECTION2 "MaxTelemetryAllowed" 1

        Write-Log "  Servicios -> restaurando DiagTrack y SysMain..." "Cyan"
        Start-ServiceSafe "DiagTrack"
        Start-ServiceSafe "SysMain"

        Write-Log "  Advertising ID -> habilitado..." "Cyan"
        Set-RegistryValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 1

        Write-Log "  Copilot -> restaurado..." "Cyan"
        Set-RegistryValue $REG_COPILOT_USER    "TurnOffWindowsCopilot" 0
        Set-RegistryValue $REG_COPILOT_MACHINE "TurnOffWindowsCopilot" 0

        Write-Log "  Copilot button -> restaurado..." "Cyan"
        Set-RegistryValue $REG_EXPLORER_ADV "ShowCopilotButton" 1

        Write-Log "  Permisos de privacidad -> Allow..." "Cyan"
        Set-PrivacyConsent -Value "Allow"

        Write-Log "  OfflineOS -> restaurando cuentas Microsoft y Azure AD..." "Cyan"
        Set-RegistryValue $REG_POLICIES_SYSTEM "NoConnectedUser" 0
        Set-RegistryValue $REG_WORKPLACE_JOIN  "BlockAADWorkplaceJoin" 0
        Set-RegistryValue $REG_MSA             "DisableUserAuth" 0
        Set-RegistryValue $REG_OOBE            "DisablePrivacyExperience" 0
        Set-RegistryValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled" 1

        Write-Log "  Windows AI / Recall -> restaurando..." "Cyan"
        Set-RegistryValue "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 0
        Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 0
        Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 0

        Write-Log "  Edge -> restaurando politicas..." "Cyan"
        if (-not $DryRun.IsPresent) {
            Remove-ItemProperty -LiteralPath $REG_EDGE_POLICIES -Name "HubsSidebarEnabled" -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $REG_EDGE_POLICIES -Name "EdgeShoppingAssistantEnabled" -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $REG_EDGE_POLICIES -Name "StartupBoostEnabled" -ErrorAction SilentlyContinue
        } else {
            Write-Log "  [DRY-RUN] Remove-ItemProperty: Edge policies (HubsSidebar, Shopping, StartupBoost)" "DarkGray"
        }

        Write-Log "  DNS -> restaurando DHCP automatico..." "Cyan"
        if (-not $DryRun.IsPresent) {
            Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object {
                Set-DnsClientServerAddress -InterfaceAlias $_.Name -ResetServerAddresses -ErrorAction SilentlyContinue
            }
        } else {
            Write-Log "  [DRY-RUN] Set-DnsClientServerAddress -ResetServerAddresses (todos los adaptadores activos)" "DarkGray"
        }

        Write-Log "  Tareas programadas -> reactivando telemetria..." "Cyan"
        foreach ($t in $TelemetryTasks) { Enable-ScheduledTaskSafe $t.Path $t.Name }

        Write-Log "================================================================" "Green"
        Write-Log "Restore completado. Reinicia para aplicar todos los cambios." "Green"
        Write-Log "NOTA: Las apps desinstaladas (bloatware/OneDrive) NO se restauran." "Yellow"
        Write-Log "NOTA: La activacion de Windows NO se revierte desde aqui." "Yellow"
        Write-Log "Log: $LogFile" "DarkGray"
        Exit-Script 0
    }

    # Despachar Restore
    if ($Mode -eq "Restore") { Invoke-RestoreMode }

    # UX Licencia: prompt solo si placeholder Y sin Skip Activation
    if (-not $DryRun.IsPresent -and -not (Test-Skip "Activation") -and ($script:ProductKey -match "^XXXXX")) {
        $promptKey = Read-Host "No se ha configurado clave. Introduce tu clave real (Enter para omitir):"
        if ($promptKey.Trim()) {
            $script:ProductKey = $promptKey.Trim()
            Write-Log "Licencia configurada via prompt interactivo." "Yellow"
        } else {
            Add-Skip "Activation"
            Write-Log "[INFO] Licencia omitida por usuario (equivalente a -Skip Activation)." "DarkYellow"
        }
    }

    # Despachar DryRun Activation auto-skip
    if ($DryRun.IsPresent -and -not (Test-Skip "Activation")) {
        Add-Skip "Activation"
        Write-Log "[DRY-RUN] Activation omitida automaticamente (no simulable)." "DarkYellow"
    }

#endregion

#region ── MÓDULOS 0-15 (existentes con fixes) ──────────────────────────────

    function Invoke-ModuleActivation {
        $slmgr = "$env:SystemRoot\System32\slmgr.vbs"
        $licInfo = & cscript.exe //Nologo $slmgr /dlv 2>&1 | Out-String
        $yaActivado = $licInfo -match "License Status:\s*Licensed" -or $licInfo -match "Estado de licencia:\s*Con licencia"
        if ($yaActivado) {
            $channel = if ($licInfo -match 'License Description\s*:\s*(.+)') { $Matches[1].Trim() } else { 'desconocido' }
            Write-Log "   Windows ya activado. Canal: $channel" "DarkGray"
        } else {
            if ($script:ProductKey -match "^XXXXX") { throw "Clave no configurada." }
            if ($script:ProductKey -notmatch "^[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$") {
                throw "Formato de clave invalido."
            }
            Write-Log "   Inyectando clave de producto..." "Yellow"
            $ipkResult = & cscript.exe //Nologo $slmgr /ipk $script:ProductKey 2>&1 | Out-String
            Write-Log "   slmgr /ipk $($script:ProductKey.Substring(0,5))-****-****-****-*****" "DarkGray"
            if ($ipkResult -match "(?i)error|0x8") { throw "slmgr /ipk fallo: $ipkResult" }

            Write-Log "   Verificando conectividad..." "Yellow"
            $netOk = Test-NetConnection -ComputerName "activation.sls.microsoft.com" -Port 443 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if (-not $netOk.TcpTestSucceeded) { throw "Sin conectividad a activation.sls.microsoft.com:443." }

            Write-Log "   Activando (timeout 60 s)..." "Yellow"
            $atoProc = Start-Process "cscript.exe" -ArgumentList "//Nologo `"$slmgr`" /ato" -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\slmgr_ato.txt" -RedirectStandardError "$env:TEMP\slmgr_ato_err.txt" -ErrorAction Stop
            try { Wait-Process -Id $atoProc.Id -Timeout 60 -ErrorAction Stop } catch [System.TimeoutException] {
                Stop-Process -Id $atoProc.Id -Force -ErrorAction SilentlyContinue
                throw "slmgr /ato excedio timeout 60 s."
            }
            if (-not $atoProc.HasExited) {
                Stop-Process -Id $atoProc.Id -Force -ErrorAction SilentlyContinue
                throw "slmgr /ato no termino (HasExited=false)."
            }
            $atoResult = (Get-Content "$env:TEMP\slmgr_ato.txt" -ErrorAction SilentlyContinue) -join "`n"
            $atoErr = (Get-Content "$env:TEMP\slmgr_ato_err.txt" -ErrorAction SilentlyContinue) -join "`n"
            Remove-Item "$env:TEMP\slmgr_ato*.txt" -Force -ErrorAction SilentlyContinue
            Write-Log "   $atoResult" "DarkGray"
            if ($atoErr.Trim()) { Write-Log "   [stderr] $atoErr" "DarkYellow" }
            if ("$atoResult`n$atoErr" -match "(?i)error|0x8") { throw "slmgr /ato fallo." }

            $dlvResult = & cscript.exe //Nologo $slmgr /dlv 2>&1 | Out-String
            if ($dlvResult -match "Licensed|Con licencia") {
                Write-Log "   Windows activado correctamente." "Green"
            } else {
                throw "Activacion ejecutada pero NO Licensed. Verifica: slmgr /dlv"
            }
        }

    }

    Invoke-Step "Activation" "Activando Windows..." { Invoke-ModuleActivation }

    # MÓDULO OfflineOS: Bloqueo de identidad cloud — siempre ejecutado salvo -Skip OfflineOS
    function Invoke-ModuleOfflineOS {
        Write-Log "   Bloqueando vinculacion a cuenta Microsoft personal..." "DarkGray"
        Set-RegistryValue $REG_POLICIES_SYSTEM "NoConnectedUser" 3
        Write-Log "   Bloqueando Azure AD / Work account join..." "DarkGray"
        Set-RegistryValue $REG_WORKPLACE_JOIN "BlockAADWorkplaceJoin" 1
        Write-Log "   Deshabilitando proveedor de identidad MSA..." "DarkGray"
        Set-RegistryValue $REG_MSA "DisableUserAuth" 1
        Write-Log "   Suprimiendo prompts OOBE de cuenta en la nube..." "DarkGray"
        Set-RegistryValue $REG_OOBE "DisablePrivacyExperience" 1
        Write-Log "   Bloqueando banner Sign-in (Scoobe)..." "DarkGray"
        Set-RegistryValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled" 0
        Write-Log "   Identidad cloud aislada correctamente." "Green"
    }

    Invoke-Step "OfflineOS" "Aislando identidad cloud (AAD/MSA/OOBE)..." { Invoke-ModuleOfflineOS }

    function Invoke-ModuleUpdates {
        Set-RegistryValue $REG_WU_AU "AUOptions" 2
        Set-RegistryValue $REG_WU_AU "NoAutoUpdate" 0
        Set-RegistryValue $REG_WU_AU "NoAutoRebootWithLoggedOnUsers" 1
        Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" 0
    }
    Invoke-Step "Updates" "Configurando Windows Update a modo manual..." { Invoke-ModuleUpdates }

    function Invoke-ModuleDefender {
        Set-RegistryValue $REG_DEFENDER_SPYNET "SubmitSamplesConsent" 2
        Set-RegistryValue $REG_DEFENDER_SPYNET "SpynetReporting" 0
        Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" "DisableBlockAtFirstSeen" 1
    }
    Invoke-Step "Defender" "Cortando telemetria de Windows Defender..." { Invoke-ModuleDefender }

    function Invoke-ModuleHyperV {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
        if ($feature -and $feature.State -eq "Enabled") {
            Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart -ErrorAction SilentlyContinue | Out-Null
            $ctx.RebootRequired.Add("HyperV")
            Write-Log "   Hyper-V desactivado. Requiere reinicio." "Yellow"
        } else {
            Write-Log "   Hyper-V ya desactivado." "DarkGray"
        }
    }
    Invoke-Step "HyperV" "Desactivando Hyper-V..." { Invoke-ModuleHyperV }

    function Invoke-ModuleBloatware {
        $bloatware = @("*YourPhone*","*PhoneLink*","*SkypeApp*","*Microsoft.People*","*MicrosoftTeams*","*LinkedInforWindows*",
                      "*ZuneMusic*","*ZuneVideo*","*Clipchamp*","*Microsoft3DViewer*","*Print3D*","*MixedReality*","*Paint3D*",
                      "*BingSearch*","*News*","*Weather*","*BingFinance*","*BingSports*","*BingTravel*","*BingHealthAndFitness*",
                      "*549981C3F5F10*","*MicrosoftWindows.Client.WebExperience*","*WindowsFeedbackHub*","*GetHelp*","*Getstarted*",
                      "*MicrosoftOfficeHub*","*Todos*","*PowerAutomateDesktop*","*MicrosoftSolitaireCollection*","*WindowsMaps*",
                      "*WindowsAlarms*","*WindowsSoundRecorder*","*MicrosoftStickyNotes*","*Microsoft.Wallet*","*WindowsCommunicationsApps*",
                      "*ContentDeliveryManager*","*Microsoft.OutlookForWindows*","*Microsoft.Copilot*","*Microsoft.Windows.DevHome*",
                      "*Microsoft.MSPaint*","*Microsoft.BingSearch*")
        if ($PS7Plus) {
            $localProv = $ctx.ProvisionedCache
            $localInst = $ctx.InstalledCache
            $bloatware | ForEach-Object -Parallel {
                $pat = $_
                $prov = $using:localProv
                $inst = $using:localInst
                if ($null -ne $inst) {
                    $inst | Where-Object { $_.Name -like $pat } | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                } else {
                    Get-AppxPackage -Name $pat -AllUsers -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
                }
                if ($null -ne $prov) {
                    $prov | Where-Object { $_.DisplayName -like $pat } | ForEach-Object {
                        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
                    }
                }
            } -ThrottleLimit 4
        } else {
            foreach ($app in $bloatware) { Remove-AppxSafe $app }
        }
    }
    Invoke-Step "Bloatware" "Erradicando Bloatware..." { Invoke-ModuleBloatware }

    function Invoke-ModuleOneDrive {
        Get-Process OneDrive,OneDriveSetup -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
        $onedrivePaths = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe","$env:SystemRoot\System32\OneDriveSetup.exe")
        foreach ($od in $onedrivePaths) {
            if (Test-Path $od) {
                Write-Log "   Desinstalando OneDrive ($od)..." "Yellow"
                $proc = Start-Process $od "/uninstall" -NoNewWindow -PassThru -Wait
                if ($proc.ExitCode -ne 0) { Write-Log "   [WARN] Exit code $($proc.ExitCode)" "DarkYellow" }
                else { Write-Log "   OneDrive desinstalado." "DarkGray" }
                break
            }
        }
        Remove-AppxSafe "*OneDrive*"
        @("$env:LOCALAPPDATA\Microsoft\OneDrive","$env:PROGRAMDATA\Microsoft OneDrive","$env:USERPROFILE\OneDrive") | ForEach-Object {
            if (Test-Path $_) { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Remove-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -ErrorAction SilentlyContinue
    }
    Invoke-Step "OneDrive" "OneDrive: Desinstalar y limpiar..." { Invoke-ModuleOneDrive }

    function Invoke-ModuleXbox {
        if ($GamingMode.IsPresent) {
            # Gaming mode: conservar Xbox + optimizaciones
            Write-Log "   Gaming mode activado: conservando Xbox + optimizaciones." "Yellow"
            Set-RegistryValue "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "HwSchMode" 2  # HAGS
            Set-RegistryValue "HKCU:\Control Panel\Mouse" "MouseSpeed" "0" "String"  # Latencia ratón
        } else {
            # Desgamificar por defecto
            Remove-AppxSafe "*Xbox*"
            Remove-AppxSafe "*GamingApp*"
            Set-RegistryValue "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0
            Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 0
        }
    }
    Invoke-Step "Xbox" "Xbox/Gaming mode..." { Invoke-ModuleXbox }

    function Invoke-ModulePower {
        & powercfg.exe /hibernate off 2>&1 | Out-Null
        & powercfg.exe /change standby-timeout-ac 120 2>&1 | Out-Null
        & powercfg.exe /change monitor-timeout-ac 15 2>&1 | Out-Null
    }
    Invoke-Step "Power" "Optimizando energia..." { Invoke-ModulePower }

    function Invoke-ModuleUI {
        # Menu contextual clásico
        Set-RegistryValue "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" "(Default)" "" "String"
        Set-RegistryValue $REG_EXPLORER_ADV "TaskbarAl" 0
        Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0
        Set-RegistryValue $REG_EXPLORER_ADV "TaskbarDa" 0
        Set-RegistryValue $REG_COPILOT_USER "TurnOffWindowsCopilot" 1
        Set-RegistryValue $REG_COPILOT_MACHINE "TurnOffWindowsCopilot" 1
        Set-RegistryValue $REG_EXPLORER_ADV "TaskbarMn" 0
        Set-RegistryValue $REG_EXPLORER_ADV "ShowCopilotButton" 0  # Fix L3
        # Edge castrado
        Set-RegistryValue $REG_EDGE_POLICIES "HubsSidebarEnabled" 0
        Set-RegistryValue $REG_EDGE_POLICIES "EdgeShoppingAssistantEnabled" 0
        Set-RegistryValue $REG_EDGE_POLICIES "StartupBoostEnabled" 0
        $searchPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
        Set-RegistryValue $searchPath "BingSearchEnabled" 0
        Set-RegistryValue $searchPath "SearchboxTaskbarMode" 1
        Set-RegistryValue "HKCU:\Software\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1
        Set-RegistryValue $REG_CDM "SubscribedContent-338389Enabled" 0
        Set-RegistryValue $REG_CDM "SubscribedContent-310093Enabled" 0
        Set-RegistryValue $REG_CDM "SubscribedContent-338388Enabled" 0
        Set-RegistryValue $REG_CDM "SubscribedContent-353698Enabled" 0
        Set-RegistryValue $REG_CDM "SilentInstalledAppsEnabled" 0
        Set-RegistryValue $REG_CDM "SystemPaneSuggestionsEnabled" 0
        Set-RegistryValue $REG_CDM "SoftLandingEnabled" 0
    }
    Invoke-Step "UI" "Restaurando interfaz clasica..." { Invoke-ModuleUI }

    function Invoke-ModuleTelemetry {
        Set-RegistryValue $REG_DATACOLLECTION "AllowTelemetry" 0
        Set-RegistryValue $REG_DATACOLLECTION2 "AllowTelemetry" 0
        Set-RegistryValue $REG_DATACOLLECTION2 "MaxTelemetryAllowed" 0
        Set-RegistryValue $REG_SYSTEM_POLICIES "EnableActivityFeed" 0
        Set-RegistryValue $REG_SYSTEM_POLICIES "PublishUserActivities" 0
        Set-RegistryValue $REG_SYSTEM_POLICIES "UploadUserActivities" 0
        Set-RegistryValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0
        @("DiagTrack","dmwappushservice","diagnosticshub.standardcollector.service") | ForEach-Object { Stop-ServiceSafe $_ }
        foreach ($t in $TelemetryTasks) {
            Disable-ScheduledTaskSafe $t.Path $t.Name
        }
        # Cazador dinamico: deshabilita cualquier tarea activa en rutas CEIP (cubre tareas nuevas futuras)
        $ceipPaths = @(
            "\Microsoft\Windows\Application Experience\",
            "\Microsoft\Windows\Customer Experience Improvement Program\"
        )
        foreach ($ceipPath in $ceipPaths) {
            $dynTasks = Get-ScheduledTask -TaskPath $ceipPath -ErrorAction SilentlyContinue
            if ($dynTasks) {
                $dynTasks | Where-Object { $_.State -ne 'Disabled' } | ForEach-Object {
                    $_ | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
                    Write-Log "   [Dyn] Tarea deshabilitada: $($_.TaskName) en $ceipPath" "DarkGray"
                }
            }
        }
    }
    Invoke-Step "Telemetry" "Desactivando telemetria..." { Invoke-ModuleTelemetry }

    function Invoke-ModulePrivacy {
        Set-PrivacyConsent "Deny"
        Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC" "PreventHandwritingDataSharing" 1
        Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports" "PreventHandwritingErrorReports" 1
        Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" "DisableInventory" 1
        Set-RegistryValue "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config" "AutoConnectAllowedOEM" 0
        # DisableAIDataAnalysis: deshabilita Recall (captura de pantalla AI)
        Set-RegistryValue "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
        Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1
        # Deshabilitar el boton Copilot en taskbar (24H2 re-introduce esta clave)
        Set-RegistryValue $REG_EXPLORER_ADV "ShowCopilotButton" 0
        # Cloud Content / Consumer Features
        Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" 1
        Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableSoftLanding"             1
        Set-RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableCloudOptimizedContent"  1
        # Telemetria nivel policy adicional (24H2)
        Set-RegistryValue "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\System" "AllowTelemetry" 0
        Write-Log "   Privacidad Win11 24H2+ (Recall/AI/Copilot/CloudContent) configurada." "DarkGray"
    }
    Invoke-Step "Privacy" "Endureciendo privacidad..." { Invoke-ModulePrivacy }

    function Invoke-ModuleSSD {
        Disable-ScheduledTaskSafe "\Microsoft\Windows\Defrag\" "ScheduledDefrag"
        $trimOutput = & fsutil.exe behavior query DisableDeleteNotify 2>&1 | Out-String
        if ($trimOutput -match 'DisableDeleteNotify\s*=\s*1') {
            if ($trimOutput -match 'NTFS\s+DisableDeleteNotify\s*=\s*1') { & fsutil.exe behavior set DisableDeleteNotify NTFS 0 2>&1 | Out-Null }
            if ($trimOutput -match 'ReFS\s+DisableDeleteNotify\s*=\s*1') { & fsutil.exe behavior set DisableDeleteNotify ReFS 0 2>&1 | Out-Null }
            Write-Log "   TRIM reactivado." "Yellow"
        }
        Stop-ServiceSafe "SysMain"
    }
    Invoke-Step "SSD" "Optimizando SSD..." { Invoke-ModuleSSD }

    function Invoke-ModuleCleanup {
        $targets = @(
            @{Path="$env:TEMP";                                     Label="TEMP usuario"},
            @{Path="$env:SystemRoot\Temp";                          Label="TEMP sistema"},
            # Prefetch excluido: solo se limpia en modo Deep (AggressiveDisk)
            @{Path="$env:SystemRoot\SoftwareDistribution\Download"; Label="WU Cache"}
        )
        if ($ctx.AggressiveDisk) {
            Write-Log "   [Deep] Limpiando Prefetch (solo modo Deep)..." "Yellow"
            $prefetchPath = "$env:SystemRoot\Prefetch"
            if (Test-Path $prefetchPath) {
                $pbefore = (Get-ChildItem $prefetchPath -Force -ErrorAction SilentlyContinue |
                            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum -as [long]
                Get-ChildItem $prefetchPath -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                Write-Log "   Prefetch: ~$([math]::Round(($pbefore/1MB),1)) MB liberados (apps tardaran mas en 1er arranque)." "DarkGray"
            }
        }
        foreach ($t in $targets) {
            if (Test-Path $t.Path) {
                $before  = (Get-ChildItem $t.Path -Recurse -Force -ErrorAction SilentlyContinue |
                             Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum -as [long]
                Get-ChildItem $t.Path -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -notin @($LogFile, $TranscriptPath) } |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                $after   = (Get-ChildItem $t.Path -Recurse -Force -ErrorAction SilentlyContinue |
                             Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum -as [long]
                $freedMB = [math]::Round((($before - $after) / 1MB), 1)
                Write-Log "   $($t.Label): ~${freedMB} MB liberados" "DarkGray"
            }
        }
        $iconCache = "$env:LOCALAPPDATA\IconCache.db"
        if (Test-Path $iconCache) { Remove-Item $iconCache -Force -ErrorAction SilentlyContinue }
        $cbsLogs = "$env:SystemRoot\Logs\CBS"
        if (Test-Path $cbsLogs) {
            Get-ChildItem $cbsLogs -Filter "*.log" -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
    Invoke-Step "Cleanup" "Limpiando caches..." { Invoke-ModuleCleanup }

    function Invoke-ModuleOptionalFeatures {
        $features = @("FaxServicesClientPackage","Printing-XPSServices-Features","WorkFolders-Client")
        $anyDisabled = $false
        foreach ($f in $features) {
            $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
            if ($feat -and $feat.State -eq "Enabled") {
                Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -ErrorAction SilentlyContinue | Out-Null
                $anyDisabled = $true
            }
        }
        if ($anyDisabled) {
            $ctx.RebootRequired.Add("OptionalFeatures")
            Write-Log "   Requiere reinicio para features." "Yellow"
        }
    }
    Invoke-Step "OptionalFeatures" "Desactivando features opcionales..." { Invoke-ModuleOptionalFeatures }

    function Invoke-ModuleDiskSpace {
        if (-not $ctx.AggressiveDisk) {
            Write-Log "   [SKIP] DiskSpace profundo solo en Deep." "DarkGray"
            return
        }
        Write-Log "   [IRREVERSIBLE] Limpiando WinSxS con DISM..." "Yellow"
        & Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /NoRestart 2>&1 | ForEach-Object { Write-Log "   $_" "DarkGray" }
        if ($LASTEXITCODE -ne 0) { throw "DISM fallo codigo $LASTEXITCODE" }
        $ctx.RebootRequired.Add("WinSxS")
    }
    Invoke-Step "DiskSpace" "Limpieza WinSxS DISM..." { Invoke-ModuleDiskSpace }

    function Invoke-ModuleExplorerPerf {
        Set-RegistryValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 2
    }
    Invoke-Step "ExplorerPerf" "Desactivando animaciones..." { Invoke-ModuleExplorerPerf }

    function Invoke-ModuleDevEnv {
        Set-RegistryValue $REG_EXPLORER_ADV "HideFileExt" 0
        Set-RegistryValue $REG_EXPLORER_ADV "Hidden" 1
        Set-RegistryValue $REG_EXPLORER_ADV "ShowSuperHidden" 1
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction SilentlyContinue
        Write-Log "   ExecutionPolicy -> RemoteSigned (CurrentUser)" "DarkGray"
        # LongPathsEnabled (solo marca reboot si el valor cambia)
        $longPathsCurrent = (Get-ItemProperty -LiteralPath $REG_LONGPATHS -Name 'LongPathsEnabled' -ErrorAction SilentlyContinue).LongPathsEnabled
        Set-RegistryValue $REG_LONGPATHS "LongPathsEnabled" 1
        if ($longPathsCurrent -ne 1) {
            $ctx.RebootRequired.Add("LongPaths")
            Write-Log "   LongPathsEnabled activado (requiere reinicio)." "Yellow"
        } else {
            Write-Log "   LongPathsEnabled ya estaba activo." "DarkGray"
        }
    }
    Invoke-Step "DevEnv" "Configurando entorno desarrollo..." { Invoke-ModuleDevEnv }

    # MÓDULO 16: Admin Tools (winget + features de red nativas)
    function Invoke-ModuleAdminTools {
        # Apps via winget
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-Log "   [SKIP] winget no disponible. Instala Microsoft Store o winget CLI." "DarkYellow"
        } else {
            $apps = @("7zip.7zip", "PuTTY.PuTTY", "Notepad++.Notepad++", "Microsoft.Sysinternals", "Ghisler.TotalCommander")
            foreach ($app in $apps) {
                Write-Log "   Instalando $app via winget..." "Yellow"
                $proc = Start-Process "winget" -ArgumentList @("install","--id",$app,"--exact","--silent","--accept-package-agreements","--accept-source-agreements") -NoNewWindow -PassThru -Wait
                if ($proc.ExitCode -ne 0) {
                    Write-Log "   [WARN] $app fallo (codigo $($proc.ExitCode))." "DarkYellow"
                } else {
                    Write-Log "   $app instalado." "DarkGray"
                }
            }
        }

        # Features de red nativas (try/catch individual por robustez en builds que no las tienen)
        $netFeatures = @("TelnetClient", "TFTPClient", "ClientForNFS-Infrastructure")
        $anyNetEnabled = $false
        foreach ($f in $netFeatures) {
            try {
                $feat = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop
                if ($feat.State -ne 'Enabled') {
                    Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction Stop | Out-Null
                    Write-Log "   $f habilitado." "DarkGray"
                    $anyNetEnabled = $true
                } else {
                    Write-Log "   $f ya estaba habilitado." "DarkGray"
                }
            } catch {
                Write-Log "   [WARN] $f no disponible en este build/edicion: $_" "DarkYellow"
            }
        }
        if ($anyNetEnabled) { $ctx.RebootRequired.Add("NetFeatures") }
    }
    Invoke-Step "AdminTools" "Instalando kit sysadmin (winget + features de red)..." { Invoke-ModuleAdminTools }

    # MÓDULO 17: DNS seguros (Cloudflare 1.1.1.1 + Quad9 9.9.9.9)
    function Invoke-ModuleDNS {
        $adapters = Get-NetAdapter -Physical | Where-Object Status -eq 'Up'
        if ($adapters.Count -eq 0) {
            Write-Log "   [SKIP] No se encontraron adaptadores fisicos Up." "DarkGray"
            return
        }
        foreach ($adapter in $adapters) {
            Write-Log "   Configurando DNS en $($adapter.Name)..." "Yellow"
            Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses ("1.1.1.1", "9.9.9.9") -ErrorAction SilentlyContinue
        }
        Write-Log "   DNS seguros configurados en $($adapters.Count) adaptadores." "Green"
    }
    if ($SetSecureDNS) { Invoke-Step "DNS" "Configurando DNS seguros (Cloudflare/Quad9)..." { Invoke-ModuleDNS } }

#endregion

#region ── FINALIZACION ──────────────────────────────────────────────────────

    # Restart Explorer condicional (fix L2)
    if (-not (Test-Skip "UI") -or -not (Test-Skip "ExplorerPerf")) {
        if ($DryRun.IsPresent) {
            $msg = "  [DRY-RUN] Explorer restart omitido."
            Write-Log $msg "DarkGray"
            $ctx.DryRunActions.Add($msg)
        } else {
            Write-Log "Reiniciando Explorer..." "Yellow"
            $explorerProcs = Get-Process explorer -ErrorAction SilentlyContinue
            if ($explorerProcs) {
                $originalPIDs = $explorerProcs.Id
                $explorerProcs | Stop-Process -Force -ErrorAction SilentlyContinue
                $deadline = (Get-Date).AddSeconds(5)
                while ((Get-Date) -lt $deadline) {
                    $stillAlive = $originalPIDs | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) }
                    if (-not $stillAlive) { break }
                    Start-Sleep -Milliseconds 300
                }
                Start-Process explorer.exe
            }
        }
    }

    Write-Log "================================================================" "Green"
    $summaryColor = if ($ctx.StepsFail -gt 0) { "Red" } else { "Green" }
    Write-Log "Resumen: $($ctx.StepsOk) OK | $($ctx.StepsFail) errores" $summaryColor
    if ($ctx.FailedModules.Count -gt 0) {
        Write-Log "Fallidos: $($ctx.FailedModules -join ', ')" "Red"
    }

    if ($DryRun.IsPresent) {
        Write-Log "" "White"
        Write-Log "═══════════════ RESUMEN DRY-RUN ═══════════════" "Cyan"
        Write-Log "Acciones simuladas: $($ctx.DryRunActions.Count)" "Cyan"
        Write-Log "───────────────────────────────────────────────" "DarkGray"
        $ctx.DryRunActions | ForEach-Object { Write-Log $_ "DarkGray" }
        Write-Log "═══════════════════════════════════════════════" "Cyan"
        Write-Log "[DRY-RUN] Ningun cambio aplicado." "Green"
        Exit-Script 0
    }

    if ($ctx.RebootRequired.Count -gt 0) {
        Write-Log "Reinicio OBLIGATORIO para: $($ctx.RebootRequired -join ', ')" "Yellow"
    }

    Write-Log "Backup: $BackupDir | Log: $LogFile | Transcript: $TranscriptPath" "DarkGray"
    $respuesta = Read-Host "`nReiniciar ahora? [s/N]"
    if ($respuesta -match "^[sS]$") {
        Restart-Computer -Force
    } else {
        Write-Host "Reinicio pospuesto. Recuerda reiniciar para aplicar todo." -ForegroundColor Yellow
    }

    if ($ctx.StepsFail -gt 0) { Exit-Script 1 }
    Exit-Script 0

} finally {
    Stop-Transcript -ErrorAction SilentlyContinue
    try { if ($_mutex -and $acquired) { $_mutex.ReleaseMutex() } } catch {}
}
