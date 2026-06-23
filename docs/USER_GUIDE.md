```text
______________________________________________________________________
|                                                                      |
|  ███╗   ███╗ █████╗ ███╗  ██╗ ██████╗ ██╗     ██╗████████╗ ██████╗   |
|  ████╗ ████║██╔══██╗████╗ ██║██╔═══██╗██║     ██║╚══██╔══╝██╔═══██╗  |
|  ██╔████╔██║███████║██╔██╗██║██║   ██║██║     ██║   ██║   ██║   ██║  |
|  ██║╚██╔╝██║██╔══██║██║╚████║██║   ██║██║     ██║   ██║   ██║   ██║  |
|  ██║ ╚═╝ ██║██║  ██║██║ ╚███║╚██████╔╝███████╗██║   ██║   ╚██████╔╝  |
|  ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚══╝ ╚═════╝ ╚══════╝╚═╝   ╚═╝    ╚═════╝   |
|______________________________________________________________________|
 [ GUIA DE USUARIO FINAL ] - [ v2.9.0 DYNAMIC CORE ENGINE ]
```

 //--[ 01. ¿QUE ES MANOLITO ENGINE? ]--------------------------------\

 Manolito es un optimizador de Windows 11 (Build 22000+) diseñado para
 Administradores de Sistemas y Power Users. No es
 un script convencional; es un motor asíncrono multihilo que orquesta
 modificaciones profundas del sistema mediante una base de datos
 declarativa en formato JSON.

 La misión: Recuperar el control. Sin telemetría. Sin bloatware.
 Sin procesos basura.

 //--[ 02. REQUISITOS DE ACCESO ]-------------------------------------\

 [!] OS: Windows 11 (PRO/EDU/ENT Build 22000 o superior).
 [!] PRIVILEGIOS: Acceso de Administrador (elevación requerida).
 [!] ESTRUCTURA: Los archivos "manolito.ps1" y "manolito.json" deben
     habitar el mismo directorio para que el motor arranque.

 //--[ 03. INSTRUCCIONES DE LANZAMIENTO ]----------------------------\

 1. Sitúate en la carpeta del motor.
 2. Ejecuta "manolito.ps1" con PowerShell.
 3. Si la seguridad de Redmond te bloquea, usa el bypass táctico:
    Set-ExecutionPolicy Bypass -Scope Process -Force; .\manolito.ps1

 O haz doble clic en el .bat. No te compliques.

 //--[ 04. NIVELES OPERATIVOS (RUNLEVELS) ]--------------------------\

 El sistema clasifica las cargas útiles en niveles de riesgo acumulativos.
 Cada nivel incluye todo lo del anterior:

* 🟢 **[LITE]**: Elimina Bloatware esencial y telemetría básica.
* 🔵 **[DEV-EDU]**: Optimiza redes, elimina publicidad y limpia restos
			de activadores KMS.
* 🔴 **[DEEP]**: Sintonía fina de latencia (Input Lag), activación
			MSI en GPU/NVMe, desactivación de VBS y limpieza WinSxS.
* 🟣 **[ROLLBACK]**: Reversión granular al estado previo de la sesión.
			Sin manifests externos. Stack en memoria.
* 🟠 **[OPTIONAL]**: Payloads de riesgo elevado o configuración específica.
			Requieren confirmación explícita antes de ejecutar.

 > NVMe Fix ya no es un runlevel independiente. El motor detecta
 > hardware NVMe automáticamente y activa el tuning sin intervención.

 //--[ 05. PANEL DE CONTROL Y TELEMETRIA DE INTERFAZ ]---------------\

 [!] DETECCION DE HARDWARE: Al inicio, Manolito escanea tu entorno
     mediante triple fallback (Win32_ComputerSystem → BIOS → ACPI).
     Detecta VMs (VirtualBox, VMware, Hyper-V, QEMU), NVMe, GPU NVIDIA,
     Batería e Impresoras. El motor bloquea automáticamente los payloads
     incompatibles con tu hardware antes de ejecutar nada.

 [!] CONSOLA CRT: Visualización en tiempo real del progreso. El batch
     polling limitado garantiza que la interfaz nunca se congela, ni
     siquiera con 43 payloads en Deep consecutivos.

 [!] DRY-RUN (Simulador): Actívalo antes de lanzar para auditar el
     plan completo sin escribir un solo byte en el sistema.
     Recomendado antes de ejecutar DEEP por primera vez.

 [!] AUDITORIA INTEGRADA: El botón [ AUDITAR ] genera un informe
     técnico del sistema (NVMe driver, MSI mode, KBs de riesgo, HAGS,
     VSS) exportable a HTML con timestamp.

 //--[ 06. HITOS DE RENDIMIENTO (THE MATRIX CHALLENGE) ]-------------\

 Con Manolito v2.9.0 seguimos rompiendo las leyes de Microsoft:
 -> Windows 11 estable con solo 2.0 GB de RAM totales.
 -> Consumo base en reposo reducido hasta los 1.4 GB.
 -> Actividad de CPU entre el 0% y el 7% en idle.
 -> El sistema reporta 0.0 PB de reserva para hardware.

 //--[ 07. ROLLBACK: LA MAQUINA DEL TIEMPO ]-------------------------\

 En v2.9.0 el Rollback es por sesión, sin ficheros externos.
 El motor vuelca el estado previo de cada payload en un stack en memoria
 antes de modificar nada. Si algo falla o cambias de opinión:

 1. Selecciona el runlevel [ROLLBACK] en el desplegable.
 2. Pulsa [ INICIAR ].
 3. El motor revierte en orden inverso, payload por payload.

 > El botón [ MANIFEST ] está deshabilitado en v2.9.0.
 > La restauración vía manifest v2.8.x no es compatible con el
 > Dynamic Core Engine. Usa siempre el Rollback de sesión.

 //--[ 08. LICENCIA Y AVISO LEGAL ]----------------------------------\

 Manolito Engine es software libre bajo GNU GPLv3 para uso personal.
 [!!!] USO CORPORATIVO/MSP: Requiere Licencia Comercial para eximirse
 de las obligaciones de liberación de código de la GPLv3.

 TOCA COSAS SERIAS. ÚSALO BAJO TU PROPIA RESPONSABILIDAD.
──────────────────────────────────────────────────────────────────────
 [ EOF ] - Manolito v2.9.0 - Stay secure. Stay light. Stay fast.
