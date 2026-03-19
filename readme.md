#
```text
 ███╗   ███╗ █████╗ ██████╗  ██████╗ ██╗     ██╗████████╗ ██████╗ 
 ████╗ ████║██╔══██╗██╔══██╗██╔═══██╗██║     ██║╚══██╔══╝██╔═══██╗
 ██╔████╔██║███████║██║  ██║██║   ██║██║     ██║   ██║   ██║   ██║
 ██║╚██╔╝██║██╔══██║██║  ██║██║   ██║██║     ██║   ██║   ██║   ██║
 ██║ ╚═╝ ██║██║  ██║██║  ██║╚██████╔╝███████╗██║   ██║   ╚██████╔╝
 ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝   ╚═╝    ╚═════╝ 
──────────────────────────────────────────────────────────────────────
 . . . Xciter . . . P R E S E N T S . . .

Target OS  : Windows 11 Pro, Enterprise & Education (22000 - 26100+)
Framework  : PowerShell 5.1 / 7.x (Multithreaded)
Payload    : Manolito v2.5.5 - The Complete Update
Protection : MS Telemetry, Cloud Identity, KMS Hijackers, Bloatware
Tuning     : Bare-Metal Esports (MSI, NIC Nagle, Input Latency)
──────────────────────────────────────────────────────────────────────
```
//--[ I N F O ]------------------------------------------------------\\

La telemetría no se negocia. El bloatware no se tolera.

Manolito ha evolucionado. Dejo atrás los scripts de limpieza básicos para 
entregar un framework de aprovisionamiento diseñado bajo principios 
de Confianza Cero. Retomamos el control absoluto de las ediciones 
profesionales de Windows 11, extirpando la telemetría comercial y aislando
el sistema de la infraestructura en la nube de Microsoft o de los
backdoors de KMS toxicos que circulan y convierten tu pc en un bot esclavo.

Sin frameworks pesados de GUI. Sin dependencias. Sin fallos silenciosos.
Ingeniería de sistemas pura basada en PowerShell, control de concurrencia y 
auditoría estricta. Y por supuesto, sin pagar un duro...


//--[ A R Q U I T E C T U R A   ( B a s e ) ]------------------------\\

Manolito no es un simple script de debloat. Es un motor de 
aprovisionamiento escrito en PowerShell puro, diseñado para entornos 
corporativos, educativos y competitivos (Esports). 

Destruye telemetría intrusiva (Recall/Copilot), aniquila tareas ocultas, 
limpia secuestros KMS piratas, y reduce la latencia a nivel de hardware 
interactuando directamente con el bus PCI-Express (MSITuning) y los 
controladores de red físicos (NICTuning). 

Todo ello con un sistema de auditoría matemática (Set-RegTracked) que 
demuestra exactamente qué ha cambiado en tu PC post-ejecución.

Sin binarios opacos. Sin telemetría propia. 100% auditable.

//--[ C O R E   P A Y L O A D S   ( v 2 . 5 . 5 ) ]------------------\\

[+] 1. Bare-Metal Esports (Baja Latencia)
  * MSITuning   : Inyecta interrupciones MSI (Message Signaled Interrupts)
                  con prioridad alta en GPU y NVMe. Aniquila el stuttering.
  * NICTuning   : Apaga el algoritmo de Nagle (TcpAckFrequency/TCPNoDelay), 
                  Flow Control y EEE cruzando IPs físicas. Ping mínimo.
  * InputTuning : Fulmina la aceleración nativa de ratón y fuerza el
                  KeyboardDelay a 0 absoluto.
[+] 2. Enterprise Auditing (Trazabilidad)
  * Set-RegTracked : Motor de inyección de registro interceptado. Lee el 
                     estado Before/After y guarda el diferencial en RAM.
  * -Verify        : Auditoría matemática post-ejecución. Demuestra qué 
                     claves se han aplicado o bloqueado por el sistema.
  * -Mode Check    : Escáner 100% pasivo (WMI/Registry) que exporta una tabla 
                     ASCII con el estado de VBS, Nagle, Energía y Telemetría.
[+] 3. Security & Core (Ciberseguridad)
  * DisableVBS   : Inyección profunda que apaga la Seguridad Basada en 
                   Virtualización (kernel) para rascar FPS (Solo Deep).
  * AI Blocker   : Bloquea de raíz el análisis de IA de Microsoft (Recall) 
                   anticipándose a las builds 26100+.
  * WU Integrity : Instruye a Windows Update para aplicar parches de 
                   seguridad pero NUNCA pisar los drivers de vídeo.
[+] 4. Adaptive Interface (UX)
  * Toggles CLI  : Sub-menú inteligente de despliegue en caliente para 
                   controlar periféricos, DNS, o preservación de Xbox.
+ [!] Módulo OfflineOS: Blindaje total contra la identidad Cloud. Bloquea el
  Azure AD Join, fulmina los prompts de OOBE y fuerza la creación de cuentas
  locales mediante políticas restrictivas de sistema (NoMicrosoftAccount).
+ [!] DeKMS Hunter: Módulo forense de limpieza. Rastrea y destruye activadores
  KMS irregulares (KMSpico, HEU) ocultos en perfiles de servicio (S-1-5-20),
  limpiando el terreno para la inyección de licencias corporativas legítimas.
+ [!] Multithreaded Appx Purge: Erradicación del ecosistema comercial (TikTok,
  Spotify, Netflix). Utiliza Runspaces paralelos en PS7+ con protección 
  transaccional contra condiciones de carrera en el motor DISM.
+ [!] Secure DNS (Dual-Stack): Enrutamiento forzado de tráfico IPv4 e IPv6 
  hacia resolutores de confianza (Cloudflare/Quad9) en adaptadores físicos.
+ [!] Sysadmin Bootstrapper: Inyección automatizada vía Winget (7-Zip, PuTTY, 
  Notepad++, Sysinternals, Windhawk) evadiendo firewalls corporativos.
+ [!] Strict Architecture: Control de concurrencia (Mutex), gestión de estado 
  mediante try/finally y logs forenses consolidados en ejecución desatendida.

//--[ M O D O S   D E   E J E C U C I Ó N ]------------------\\

* [ DevEdu ] (Recomendado)
  Equilibrio perfecto. Privacidad, sin telemetría, UI clásica. Conserva 
  Xbox si usas -GamingMode. Ideal para desarrolladores y dual-booters 
  (aplica RealTimeIsUniversal en hardware).

* [ Deep ] (Agresivo)
  Máxima limpieza para Gaming. Incluye purga de WinSxS (DISM /ResetBase), 
  apaga Modern Standby y desactiva telemetría a nivel driver (NVIDIA).

* [ Lite ] (Conservador)
  Optimización mínima para oficinas. Limpia UI y telemetría básica, 
  sin tocar discos, energía ni hardware.

* [ Check ] (Auditoría Pasiva)
  No escribe nada. Lee el WMI y el Registro y escupe una tabla ASCII con 
  el estado de salud de tu VBS, Plan de Energía, Nagle y Telemetría.

* [ Restore ] (Botón del Pánico)
  Revierte servicios críticos, Windows Update, telemetría, DNS y RTC 
  al estado por defecto de Microsoft.


//--[ E J E M P L O S   D E   U S O   ( C L I ) ]------------\\

* [ Menú Visual Interactivo (Recomendado para humanos) ]
  .\manolito.ps1 -Interactive

* [ Despliegue Gaming / Esports Desatendido con Auditoría ]
  .\manolito.ps1 -Mode Deep -GamingMode -SetSecureDNS -Verify -Force

* [ Despliegue Silencioso Sysadmin (Ideal para Intune / SCCM) ]
  .\manolito.ps1 -Mode DevEdu -Skip AdminTools -Force

* [ QA / Simulacro (No rompe nada, muestra Dry-Run logs) ]
  .\manolito.ps1 -Mode DevEdu -DryRun

//--[ S U P P O R T   &   D O N A T I O N S ]------------------------\\

Manolito es un proyecto desarrollado de forma independiente con cientos 
de horas de ingeniería inversa, pruebas en laboratorio y depuración.

Si este motor te ha ayudado a rascar esos FPS extra en tu setup, ha 
salvado tu viejo portátil o te ha ahorrado horas de configuración tras 
un formateo, considera invitar al autor a un café (o a una bebida 
energética para las noches en vela):

[☕] Ko-fi   : https://ko-fi.com/mhg778
[💸] PayPal  : https://paypal.me/mhg778

Cualquier aporte ayuda a mantener el proyecto vivo, pagar los servidores 
de pruebas y seguir investigando las entrañas de Windows. ¡Gracias!
──────────────────────────────────────────────────────────────────────

//--[ L E G A L   &   L I C E N S E   ( D U A L ) ]------------------\\

Manolito es software libre de código abierto. Se distribuye bajo los 
términos de la licencia [GNU GPLv3](LICENSE).

Esto significa que eres completamente libre de usarlo, estudiarlo, 
compartirlo y modificarlo para uso personal, doméstico o en instituciones 
educativas públicas.

[!!!] AVISO PARA EMPRESAS Y PROVEEDORES IT (MSP) [!!!]
La licencia GPLv3 es estricta (Copyleft). El uso de este software en 
entornos corporativos, empresariales, o por parte de técnicos informáticos 
para dar soporte lucrativo a terceros, OBLIGA LEGALMENTE a liberar el 
código fuente de cualquier ecosistema derivado en el que se integre.

Si deseas utilizar Manolito de forma comercial en tu empresa SIN estar 
sujeto a las obligaciones de la GPLv3 sobre tu propia propiedad intelectual, 
debes adquirir una Licencia Comercial. Contacta con el autor.
