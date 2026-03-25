@echo off
Title Verificando Integridad de Manolito Engine...
color 0A

:: ======================================================
:: 1. DEFINIR LA FIRMA DIGITAL
set "EXPECTED_HASH=9425AE7138CE43F1CFF9BC030504879CA3D58C071A99EB0B840F91445E92BC7F"
:: ======================================================

set "PS1_FILE=%~dp0manolito.ps1"

if not exist "%PS1_FILE%" (
    color 0C
    echo [!] ERROR CRITICO: No se encuentra el archivo manolito.ps1
    pause
    exit /b
)

echo [i] Verificando integridad criptografica (SHA256)...
for /f "skip=1 tokens=* delims=" %%# in ('certutil -hashfile "%PS1_FILE%" SHA256') do (
    set "ACTUAL_HASH=%%#"
    goto :check_hash
)

:check_hash
set ACTUAL_HASH=%ACTUAL_HASH: =%

if /I "%ACTUAL_HASH%" neq "%EXPECTED_HASH%" (
    color 0C
    echo ===================================================
    echo [!] ALERTA DE SEGURIDAD: INTEGRIDAD COMPROMETIDA
    echo ===================================================
    echo Hash Esperado: %EXPECTED_HASH%
    echo Hash Actual  : %ACTUAL_HASH%
    pause
    exit /b
)

:: 2. Lanzamiento Inteligente (Doble Bypass de Politicas)
net session >nul 2>&1
if %errorLevel% == 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1_FILE%"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"\"%PS1_FILE%\"\"' -Verb RunAs"
)
exit
