# ⚡ Manolito Engine v2.7.0

Manolito es un optimizador de Windows 11 (Build 22000 y posteriores) diseñado para Administradores de Sistemas y Power Users. Está escrito en PowerShell 5.1 y orquesta modificaciones avanzadas del sistema impulsado por una base de datos declarativa en formato JSON (`manolito.json`).

Cuenta con una Interfaz Gráfica WPF Asíncrona (rollo cyberpunk) que garantiza fluidez total sin bloqueos, hace auditoría profunda del hardware mediante WMI y tiene la capacidad de restaurar tu sistema de forma granular en caso de error a través de "Manifiestos de Estado".

---

## 🛠️ Requisitos
- Windows 11 (PRO/EDU/ENT Build 22000 o superior).
- Permisos de Administrador (el script eleva automáticamente si es necesario).
- Estructura obligatoria en la misma carpeta:
  - `manolito.ps1` (El motor/ejecutor).
  - `manolito.json` (La base de datos de Payloads).

## 🚀 Cómo empezar
1. Descarga el repositorio o los archivos "manolito.ps1" y "manolito.json".
2. Haz clic derecho sobre "manolito.ps1" y selecciona "Ejecutar con PowerShell".
3. *Nota:* Si las políticas de ejecución de Windows lo impiden, abre una terminal como Administrador y ejecuta:
   "Set-ExecutionPolicy Bypass -Scope Process -Force; .\manolito.ps1"

---

## 🕹️ Modos de Ejecución

El sistema agrupa los *Payloads* (paquetes de modificaciones) en 4 niveles operativos según el nivel de riesgo:

* 🟢 [01] LITE (Mínimo):
  Desinstala el "Bloatware" preinstalado de Microsoft (Bing, Candy Crush, etc.) y desactiva la telemetría básica y Windows Copilot. Ideal para entornos de oficina que no quieren arriesgar compatibilidad.
* 🔵 [02] DEV-EDU (Dual / Recomendado):
  El modo por defecto. Aplica todo lo de LITE y añade optimización de redes (Desactiva el Algoritmo Nagle y fuerza DNS Cloudflare 1.1.1.1), elimina la publicidad intrusiva del menú inicio, bloquea el rastreo del archivo HOSTS y ejecuta el motor avanzado **DeKMS** (Elimina restos de activadores piratas de Office/Windows).
* 🔴 [03] DEEP OP (Gaming / Extremo):
  Modifica Windows a bajo nivel. Incluye todo lo anterior, sintoniza el retraso del teclado/ratón, fuerza la activación nativa "MSI (Message Signaled Interrupts)" en GPUs NVIDIA y discos duros NVMe detectados, y apaga VBS/HVCI en el arranque para maximizar los FPS (Aumentando la superficie de ataque del Kernel).
* 🟣 [04] ROLLBACK (Restaurar Sistema):
  Activa el sistema de seguridad en caliente. Revierte las opciones marcadas de la sesión de vuelta a los valores estándar de fábrica definidos en el archivo JSON.

---

## 🎮 Guía de la Interfaz y Botones

### Menú Principal
* **Panel de Auditoría WMI:** Manolito escanea en milisegundos tu hardware (presencia de Virtualización, Dominio, si hay un disco NVMe, si es un portátil con batería o si tienes Winget). Dependiendo de lo que detecte, bloqueará o permitirá automáticamente ciertos Payloads.
* **Consola CRT (Verde):** Muestra el progreso en directo de cada servicio desactivado y paquete desinstalado. Se ha programado usando *Runspaces* multihilo, lo que significa que la ventana jamás se congelará.

### Panel de Control (Abajo)
* 🔲 **[ DRY-RUN ] (Por defecto: Activado)**
  El simulador. El motor ejecutará toda la lógica, imprimirá qué haría en la pantalla y guardará un archivo de registro, pero **no alterará tu Windows**. Es obligatorio desactivarlo cuando estés listo para hacer cambios reales.
* 💾 **GUARDAR / CARGAR:**
  Si te gusta modificar la lista dinámica de Payloads marcando y desmarcando opciones, puedes usar estos botones para guardar un perfil personalizado `.json` en tu carpeta `Documentos\Manolito\profiles` y volver a usarlo en el futuro.
* 🕰️ **MANIFEST:**
  La Máquina del Tiempo. Al ejecutar cambios reales, Manolito captura silenciosamente una fotografía de tus servicios, tareas, DNS y registro tal y como estaban **ANTES** de aplicar el código, guardándolo en un archivo en tu carpeta de `Documentos`. Pulsa este botón, selecciona tu Manifest antiguo, y el motor dará marcha atrás reconstruyendo el sistema a la perfección.
* 📋 **COPIAR LOG:** Copia todo el contenido de la consola CRT al portapapeles por si necesitas compartir un error o diagnóstico.
* 🛑 **SALIR:** Apaga el motor y libera de forma segura los recursos del sistema (mutex, runspaces y transcriptor).
* 🚀 **INICIAR:** Desata la magia en función de si `DRY-RUN` está activo o no.

---

## 🏗️ Para Contribuidores y Sysadmins
El motor v2.7.0 está 100% abstraído. Si quieres añadir un nuevo paquete de desinstalación de *Appx*, una nueva política de registro, o un nuevo tweak de red, NO tienes que tocar el código PowerShell!!. 
Simplemente edita el archivo `manolito.json`, añade tu payload siguiendo la estructura existente y el orquestador dinámico en PS5.1 generará automáticamente los botones en la interfaz, lo validará, creará el sistema de Backup y lo ejecutará por ti.

---
*Manolito es una herramienta potente y modifica el registro de Windows. TOCA COSAS SERIAS!!, Úsese bajo su propia responsabilidad.*
