@echo off
Title Iniciando Manolito Engine v2.7+...
color 0A

:: 1. Comprobar si tenemos privilegios de Administrador
net session >nul 2>&1
if %errorLevel% == 0 (
    goto :RunManolito
) else (
    echo [!] Solicitando privilegios de Administrador (UAC)...
    :: Auto-elevar y volver a llamarse a si mismo
    powershell -Command "Start-Process -FilePath '%~0' -Verb RunAs"
    exit /b
)

:RunManolito
:: 2. Posicionarnos en el directorio exacto donde esta el .bat
cd /d "%~dp0"

:: 3. Lanzar PowerShell saltando restricciones y ocultando el perfil
echo [OK] Privilegios obtenidos. Arrancando motor...
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "manolito.ps1"

:: Cerrar la ventana negra del CMD
exit