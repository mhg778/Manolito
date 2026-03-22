# MANUAL TECNICO DE OPERACION Y ARQUITECTURA: MANOLITO ENGINE 2.7.0

## 1. OBJETO DEL DOCUMENTO

Este manual describe el funcionamiento, la arquitectura interna y las instrucciones de uso del optimizador de sistemas Manolito Engine en su versión 2.7.0. El texto detalla el modelo de datos subyacente, la mecánica profunda del motor de ejecución, el manejo de la interfaz gráfica de usuario y el procedimiento guiado para ampliar la base de datos de tareas.

## 2. ARQUITECTURA DEL SISTEMA Y FUNCIONAMIENTO DEL MOTOR

El sistema utiliza una arquitectura declarativa. Este paradigma de diseño separa la lógica de ejecución (el motor) de la definición de los datos (las tareas). El conjunto consta de dos componentes principales: el archivo de configuración en formato *json* y el ejecutable principal programado en *PowerShell*.

### 2.1. Fases de ejecución del motor
El funcionamiento del ejecutable se divide en tres fases secuenciales: inicialización, pre-auditoría y despliegue asíncrono.

* **Fase de inicialización:** Al arrancar, el sistema verifica la existencia del archivo manolito.json. El motor lee su contenido, valida la sintaxis mediante un comprobador de esquema estricto y construye la interfaz gráfica de usuario de forma dinámica en la memoria.
* **Fase de pre-auditoría:** Antes de mostrar la ventana principal, el sistema interroga al Instrumental de Administración de Windows (WMI). Este escaneo detecta el *hardware* físico instalado, como discos de estado sólido NVMe, tarjetas gráficas o baterías, así como el estado lógico del dominio. El motor procesa esta información para bloquear de forma automática aquellas cargas útiles, o *payloads*, que resulten incompatibles con el equipo y puedan generar inestabilidad en el *kernel*.
* **Fase de despliegue asíncrono:** Cuando el usuario ordena la ejecución, el motor aísla el trabajo pesado para no congelar la interfaz gráfica. Para ello, instancia un subproceso paralelo nativo denominado *runspace*. Este hilo secundario ejecuta las modificaciones del sistema. 

### 2.2. Mecanismo de inyección y captura de estado
El hilo secundario evalúa cada tarea asignada. Antes de aplicar cualquier modificación real en el registro de Windows, en los servicios o en la red, el motor lee el valor exacto que el sistema tiene en ese preciso instante. El programa almacena este valor original en la memoria de acceso aleatorio (RAM). Una vez asegurado el dato original, el motor inyecta el nuevo valor de optimización. La comunicación entre el subproceso de ejecución y la ventana gráfica se realiza mediante una cola concurrente segura, lo que permite actualizar la barra de progreso y el texto sin retardos visuales.

## 3. MODOS DE LANZAMIENTO Y LINEA DE COMANDOS

El sistema requiere privilegios de administrador para interactuar con el núcleo del sistema operativo. 

El método de lanzamiento principal emplea el archivo por lotes Run-Manolito.bat. Este ejecutable o *script* comprueba los permisos del usuario actual. Si carece de privilegios, solicita la elevación mediante el Control de Cuentas de Usuario de forma automática y ejecuta el motor con la ruta absoluta correcta.

El usuario también puede iniciar el motor directamente desde la consola de comandos ejecutando la siguiente instrucción:

`powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File manolito.ps1`

Esta cadena de comandos realiza tres funciones. El parámetro -NoProfile omite la carga de configuraciones de usuario para acelerar el arranque. El parámetro -ExecutionPolicy Bypass anula las restricciones temporales de seguridad de Windows. El parámetro -WindowStyle Hidden oculta la ventana de la consola para mostrar únicamente la interfaz gráfica.

## 4. INTERFAZ GRAFICA DE USUARIO

La interfaz gráfica proporciona control directo sobre el motor y se divide en cuatro paneles funcionales. Las interacciones se realizan mediante controles visuales.

### 4.1. Panel de Auditoría WMI
El panel superior izquierdo expone la versión del sistema operativo y los resultados del escaneo de *hardware* mencionado en la sección 2.1. 

### 4.2. Panel de Perfiles de Ejecución
Este panel ofrece cuatro agrupaciones predefinidas de tareas, denominadas *runlevels*. 
* El perfil **Lite** elimina aplicaciones preinstaladas y desactiva la recolección de datos de uso. 
* El perfil **Dev-Edu** aplica la configuración anterior, optimiza los protocolos de red y elimina los activadores irregulares. 
* El perfil **Deep Op** altera el núcleo del sistema para priorizar el rendimiento. 
* El perfil **Rollback** invierte la selección actual para facilitar la restauración del sistema operativo.

### 4.3. Panel Dinámico de Selección
Esta sección lista las tareas disponibles para el perfil activo. El usuario puede seleccionar o descartar cada tarea mediante las casillas de verificación. Un símbolo antecede al nombre de la tarea para advertir sobre su nivel de riesgo. El símbolo de asterisco indica un riesgo bajo. El símbolo de equivalencia indica un riesgo moderado. El símbolo de exclamación advierte sobre modificaciones destructivas.

### 4.4. Barra de Control y Consola
La parte inferior de la ventana agrupa los controles de estado y la consola de lectura. 
* La casilla **Dry-Run** activa el modo de simulación; el motor evalúa las tareas e imprime los resultados en la consola, pero omite las operaciones de escritura. 
* El botón **Guardar** almacena las tareas seleccionadas en un archivo de perfil local. 
* El botón **Cargar** recupera un perfil de usuario guardado previamente. 
* El botón **Manifest** inicia el procedimiento de recuperación del sistema. 
* El botón **Copiar Log** transfiere el texto de la consola al portapapeles de Windows. 
* El botón **Salir** cierra los subprocesos y apaga la aplicación. 
* El botón **Iniciar** ejecuta el plan de tareas seleccionado en la interfaz.

## 5. SISTEMA DE RECUPERACION Y MANIFIESTOS

El programa incorpora un mecanismo de reversión de cambios (*rollback*) que opera de forma independiente a los puntos de restauración tradicionales del sistema operativo.

Al ejecutar el motor con la casilla **Dry-Run** desactivada, el sistema captura el estado original de la máquina, tal como se detalla en la sección 2.2. Al concluir el despliegue de las optimizaciones, el sistema extrae los datos de la memoria RAM y los escribe en un archivo de texto inmutable en el disco duro. Este archivo actúa como una fotografía técnica del equipo y se denomina manifiesto.

Para deshacer los cambios introducidos en una sesión anterior, el usuario debe abrir la aplicación y pulsar el botón **Manifest**. El sistema abrirá un cuadro de diálogo para seleccionar el archivo de manifiesto generado durante la ejecución problemática. Una vez cargado, el usuario debe pulsar el botón **Iniciar**. El motor leerá los valores originales almacenados en el archivo y reconstruirá el estado previo exacto del sistema.

## 6. GUIA DE EXPANSION: COMO AÑADIR NUEVAS TAREAS AL ARCHIVO JSON

El diseño declarativo permite incorporar nuevas optimizaciones sin conocimientos avanzados de programación y sin modificar el código fuente del ejecutable. Esta sección detalla el procedimiento secuencial para añadir un nuevo *payload* a la base de datos.

**Paso 1. Apertura de la base de datos**
Abra el archivo manolito.json utilizando un editor de texto plano que no añada formato enriquecido.

**Paso 2. Localización del nodo principal**
Busque la sección denominada *Payloads*. Esta sección funciona como el almacén central de todas las tareas posibles.

**Paso 3. Creación del bloque de la tarea**
Desplácese hasta el final de la lista de tareas dentro del bloque *Payloads*. Inserte un nuevo identificador interno entre comillas, seguido de dos puntos y la apertura de llaves. Por ejemplo: `"MiNuevaOptimizacion": {`

**Paso 4. Definición de los metadatos obligatorios**
Dentro de las llaves recién creadas, es obligatorio añadir un sub-bloque denominado *_meta*. Este bloque dictamina el comportamiento del motor frente a la tarea y requiere cuatro parámetros:
* *Label*: El texto descriptivo que aparecerá en la interfaz gráfica.
* *Risk*: El nivel de riesgo asignado. Las opciones válidas son SAFE, MOD o IRR.
* *Reversible*: Un valor lógico (*true* o *false*) que indica si el motor debe almacenar el estado previo para permitir la recuperación.
* *RequiresReboot*: Un valor lógico que indica si el sistema necesitará un reinicio tras aplicar esta tarea.

**Paso 5. Añadido de las instrucciones operativas**
Debajo del bloque de metadatos, declare qué componente técnico desea modificar. Si desea alterar el registro de Windows, cree una matriz denominada *Registry*. Dentro de ella, especifique la ruta de la clave en *Path*, el nombre del valor en *Name*, el valor que desea inyectar en *TargetValue*, el valor por defecto de fábrica en *RestoreValue*, y el tipo de dato informático en *Type* (por ejemplo, DWord o String).

**Paso 6. Cierre del bloque**
Cierre la matriz de operaciones y asegúrese de cerrar la llave general de la tarea creada en el Paso 3.

**Paso 7. Asignación a un perfil de ejecución**
Para que la interfaz gráfica muestre la nueva tarea, el sistema necesita saber a qué perfil pertenece. Busque la sección superior denominada *UIMapping*. Localice el perfil deseado, como por ejemplo *Lite*, y añada el identificador interno creado en el Paso 3 (`"MiNuevaOptimizacion"`) a la lista denominada *Payloads*.

**Paso 8. Guardado y validación**
Guarde los cambios en el archivo. Al ejecutar de nuevo la aplicación, el motor validará la sintaxis estricta del archivo *json*. Si el formato es correcto, la nueva tarea aparecerá de forma inmediata en la interfaz gráfica, lista para su ejecución.
