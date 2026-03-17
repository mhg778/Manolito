---
name: Reporte de Error (Bug)
about: Reporta un fallo de ejecución, una excepción de PowerShell o una regresión en el sistema.
title: '[BUG] '
labels: bug, triage
assignees: ''
---

## Descripción del Error
[Describe de forma concisa qué ha fallado o qué comportamiento inesperado ha ocurrido].

## Entorno de Ejecución
- **Edición de Windows 11:** [ej. Education, Pro, Enterprise]
- **Build del SO (Ejecuta `winver`):** [ej. 22631.3296]
- **Versión de PowerShell (`$PSVersionTable.PSVersion`):** [ej. 5.1 o 7.4.1]

## Comando Utilizado
[Indica exactamente cómo lanzaste el script y con qué parámetros]
`.\manolito.ps1 -Mode DevEdu -Skip OneDrive`

## Trazabilidad (Logs)
El script genera logs automáticos. Adjunta o pega aquí las líneas relevantes del archivo de log (`%USERPROFILE%\Documents\Manolito\log_YYYYMMDD.log`) o el error exacto en rojo que devolvió la consola.
*(Nota: Oculta cualquier información personal o tu clave de licencia antes de pegar los logs).*

```text
[Pega los logs aquí]
