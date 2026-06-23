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
 [ MANUAL TECNICO DE OPERACION Y ARQUITECTURA ] - [ v2.9.0 DYNAMIC CORE ]
```

 //--[ 01. OBJETO DEL DOCUMENTO ]------------------------------------\

 Este manual detalla el funcionamiento, arquitectura y protocolos de
 uso del Framework de Aprovisionamiento Declarativo: Manolito Engine
 v2.9.0. Se centra en la extirpación de telemetría comercial
 y bloatware en Windows 11 (22000 - 26200+).

 //--[ 02. ARQUITECTURA: DYNAMIC CORE ENGINE ]-----------------------\

 v2.9.0 introduce el Dynamic Core Engine: motor completamente reescrito
 que separa ejecución, validación y estado en capas independientes.

    [!] WAD (manolito.json): Windows Automation Descriptor. Define
        payloads, runlevels, schema y lógica de validación. Cero
        acoplamiento con el ejecutable base.
    [!] Motor (manolito.ps1): Orquesta inicialización, detección de
        hardware, planificación DAG de payloads y despliegue.
    [!] Modular Async Backend: Runspace pool con ConcurrentQueue y
        batch polling limitado. La UI no se congela ni con 43
        payloads consecutivos en Deep.

 //--[ 03. DETECCION DE HARDWARE (TRIPLE FALLBACK) ]-----------------\

 Antes del despliegue, el motor detecta el entorno mediante tres capas:

    [*] Capa 1 — Win32_ComputerSystem: Modelo del equipo (timeout 8s).
    [*] Capa 2 — Win32_BIOS: Fabricante (VirtualBox=innotek GmbH,
        VMware, Xen, QEMU, Microsoft Hyper-V).
    [*] Capa 3 — ACPI Registry: HKLM\HARDWARE\ACPI\DSDT. Instantáneo,
        sin dependencia de CIM.

 Detecta: VMs, NVMe, GPU NVIDIA, Batería, Impresora, dominio AD.
 Los payloads incompatibles se bloquean antes de ejecutar nada.

 //--[ 04. HITOS DE RENDIMIENTO: WIN11 LIGHTSPEED ]------------------\

 Manolito v2.9.0 mantiene los hitos demostrados en v2.8.x:

    [!] RAM Challenge: Operatividad total en 2.0 GB de RAM totales.
    [!] Idle Base: Consumo reducido a 1.4 GB en uso.
    [!] CPU: Estabilizada entre el 0.0% y 7.0% en reposo absoluto.
    [!] Matrix Bug: Reserva de hardware reportada en 0.0 PB.

 //--[ 05. MODOS DE LANZAMIENTO Y LINEA DE COMANDOS ]----------------\

 Requiere privilegios de administrador. El script eleva
 permisos automáticamente si es necesario.

    Comando estándar:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File manolito.ps1

    -NoProfile: Omite configuraciones de usuario para arranque rápido.
    -ExecutionPolicy Bypass: Anula restricciones de seguridad temporales.

 //--[ 06. INTERFAZ GRAFICA Y PANELES ]------------------------------\

    [6.1] Perfil de Sistema: Versión del motor, backend y SO detectado.
    [6.2] Hardware Detectado: Badges activos según caps del sistema
          (VM, DOMAIN, SAFE, REBOOT, NVMe, NVIDIA, BATTERY...).
    [6.3] Runlevels: Lite, Dev-Edu, Deep, Optional y Rollback.
    [6.4] Selección Dinámica: Casillas con indicadores de riesgo
          (*=SAFE, ~=MOD, !=IRR).
    [6.5] Control y Consola:
          * Dry-Run: Modo simulación sin cambios en disco. Recomendado
            antes de cualquier ejecución Deep por primera vez.
          * Auditar: Genera informe técnico del sistema exportable a HTML.
          * Logs: Abre la carpeta de transcripts de sesión.
          * Iniciar: Desata la ejecución asíncrona.

 //--[ 07. SISTEMA DE RECUPERACION (ROLLBACK DE SESION) ]------------\

 En v2.9.0 el sistema de recuperación es por sesión, sin ficheros externos.

    1. Captura: Antes de modificar, el motor vuelca el valor original
       de cada clave o servicio en un RollbackStack en memoria.
    2. Reversión: Selecciona [ROLLBACK] en el desplegable y pulsa
       [ INICIAR ]. El motor revierte en orden inverso, payload a payload.

 > El botón [ MANIFEST ] está deshabilitado en v2.9.0.
 > La restauración vía manifest v2.8.x no es compatible con el
 > Dynamic Core Engine. Usa exclusivamente el Rollback de sesión.

 //--[ 08. GUIA DE EXPANSION DECLARATIVA (WAD/JSON) ]----------------\

 El diseño permite añadir payloads sin modificar el código fuente.

    Paso 1: Abrir manolito.json en editor de texto plano.
    Paso 2: Localizar el nodo "Payloads".
    Paso 3: Definir metadatos (_meta) con Label, Risk y Reversible.
    Paso 4: Declarar instrucciones operativas (Registry, Services,
            Appx, Tasks o ExternalCommand).
    Paso 5: Asignar el payload al runlevel correspondiente en "Runlevels".
    Paso 6: Validar schema con Test-WADSchema antes de ejecutar.

 //--[ 09. LEGAL & LICENSE (DUAL) ]----------------------------------\

 Manolito es software libre bajo GNU GPLv3 para uso personal y
 educativo.

 [!!!] USO CORPORATIVO: El uso por técnicos o empresas para fines
 lucrativos requiere una Licencia Comercial para eximirse de las
 obligaciones Copyleft de la GPLv3. Contactar con el autor
 para integraciones Enterprise.

──────────────────────────────────────────────────────────────────────
 [ EOF ] - Manolito Engine v2.9.0 - Stay secure. Stay light. Stay fast.