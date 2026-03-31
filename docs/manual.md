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
 [ MANUAL TECNICO DE OPERACION Y ARQUITECTURA ] - [ v2.8.0 RELEASE ]
```
 //--[ 01. OBJETO DEL DOCUMENTO ]------------------------------------\

 Este manual detalla el funcionamiento, arquitectura y protocolos de 
 uso del Framework de Aprovisionamiento Declarativo: Manolito Engine 
 v2.8.0. Se centra en la extirpación de telemetría comercial 
 y bloatware en Windows 11 (22000 - 26200+).

 //--[ 02. ARQUITECTURA: DATA-DRIVEN & ASYNC CORE ]------------------\

 El sistema utiliza un paradigma de diseño que separa la lógica de 
 ejecución del motor de la definición de las tareas.

    [!] Base de Datos (manolito.json): Contiene toda la lógica de 
        negocio, riesgos y estados de reversión.
    [!] Motor (manolito.ps1): Orquesta las fases de inicialización, 
        auditoría y despliegue.
    [!] Zero-Lag WPF UI: Interfaz multihilo mediante Runspaces. 
        El hilo secundario ejecuta payloads mientras la UI permanece 
        reactiva mediante una cola concurrente segura.

 //--[ 03. AUDITORIA INTELIGENTE (WMI GUARDS) ]----------------------\

 Antes del despliegue, el motor interroga al Instrumental de 
 Administración de Windows (WMI) para detectar hardware físico y 
 estados lógicos.

    [*] VM Guard: Detecta entornos virtuales y bloquea tweaks que 
        podrían comprometer el hypervisor (VBS/HVCI).
    [*] Hardware Scan: Identifica GPUs NVIDIA, discos NVMe, baterías 
        y presencia de Winget.
    [*] Domain Check: Valida si el equipo pertenece a un dominio para 
        evitar conflictos con políticas corporativas.

 //--[ 04. HITOS DE RENDIMIENTO: WIN11 LIGHTSPEED ]------------------\

 Manolito v2.8.0 ha demostrado que el kernel de Windows 11 es ligero 
 si se libera de servicios innecesarios:

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

    [4.1] Panel Auditoría: Muestra versión de OS y hardware detectado.
    [4.2] Perfiles (Runlevels): Lite, Dev-Edu, Deep Op y Rollback.
    [4.3] Selección Dinámica: Casillas con indicadores de riesgo (*=SAFE, 
          ~=MOD, !=IRR).
    [4.4] Control y Consola:
          * Dry-Run: Modo simulación sin cambios en disco.
          * Manifest: Inicia procedimiento de recuperación granular.
          * Iniciar: Desata la ejecución asíncrona.

 //--[ 07. SISTEMA DE RECUPERACION (TIME-MACHINE) ]------------------\

 El motor opera independientemente de los puntos de restauración 
 tradicionales.

    1. Captura: Antes de inyectar, el motor lee y almacena en RAM el 
       valor original de cada Servicio o Clave de Registro.
    2. Persistencia: Al finalizar, escribe estos valores en un 
       archivo de texto inmutable denominado Manifiesto.
    3. Rollback: Cargando el Manifiesto mediante el botón homónimo, 
       el motor reconstruye el estado previo exacto.

 //--[ 08. GUIA DE EXPANSION DECLARATIVA (JSON) ]--------------------\

 El diseño permite añadir tareas sin modificar el código fuente.

    Paso 1: Abrir manolito.json en editor de texto plano.
    Paso 2: Localizar el nodo "Payloads".
    Paso 3: Definir metadatos (_meta) con Label, Risk y Reversible.
    Paso 4: Declarar instrucciones operativas (Registry, Services, 
            Appx o Tasks).
    Paso 5: Asignar identificador en la sección "UIMapping".

 //--[ 09. LEGAL & LICENSE (DUAL) ]----------------------------------\

 Manolito es software libre bajo GNU GPLv3 para uso personal y 
 educativo. 

 [!!!] USO CORPORATIVO: El uso por técnicos o empresas para fines 
 lucrativos requiere una Licencia Comercial para eximirse de las 
 obligaciones Copyleft de la GPLv3. Contactar con el autor 
 para integraciones Enterprise.

──────────────────────────────────────────────────────────────────────
 [ EOF ] - Manolito Engine v2.8.0 - Stay safe. Stay fit.
