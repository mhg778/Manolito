@echo off
setlocal EnableDelayedExpansion
title Manolito Engine v2.9.0 - Arranque...
color 0A

:: ============================================================
:: MANOLITO ENGINE v2.9.0 -- Run-Manolito.bat
::
:: COMANDOS EXTERNOS USADOS:
:: certutil -- calculo SHA256 del .ps1 (nativo Windows)
:: findstr  -- busqueda en hashes.txt (nativo Windows)
:: powershell-- descarga TLS 1.2 fallback (nativo Windows)
:: No requiere librerias ni DLLs externas.
:: ============================================================

set "PS1_FILE=%~dp0manolito.ps1"
set "HASHES_FILE=%~dp0hashes.txt"
set "HASHES_TMP=%TEMP%\manolito_hashes_tmp.txt"
set "REPO_HASHES_URL=https://raw.githubusercontent.com/mhg778/manolito/main/hashes.txt"
set "REPO_PS1_URL=https://raw.githubusercontent.com/mhg778/manolito/main/manolito.ps1"
set "ENGINE_VERSION=2.9.0"

:: ============================================================
:: PASO 1 -- Verificar si manolito.ps1 existe
:: ============================================================
if not exist "%PS1_FILE%" goto :ps1_missing

goto :verify_hash

:: ============================================================
:: PS1 AUSENTE: ofrecer descarga con confirmacion obligatoria
:: ============================================================
:ps1_missing
color 0E
echo.
echo [!] No se encuentra manolito.ps1 en esta carpeta.
echo.
echo Ruta esperada: %PS1_FILE%
echo.
echo [?] Deseas descargar manolito.ps1 desde el repositorio oficial?
echo URL: %REPO_PS1_URL%
echo.
set /p "CONFIRM_DL=Escribe SI para continuar o cualquier otra cosa para salir: "
if /I "!CONFIRM_DL!" neq "SI" (
color 0C
echo.
echo [i] Descarga cancelada por el usuario. Sin cambios.
echo.
pause
exit /b 0
)

echo.
echo [i] Descargando manolito.ps1 con TLS 1.2...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%REPO_PS1_URL%' -OutFile '%PS1_FILE%' -UseBasicParsing"

if not exist "%PS1_FILE%" (
color 0C
echo.
echo [!] ERROR: No se pudo descargar manolito.ps1.
echo Descargalo manualmente desde: %REPO_PS1_URL%
echo.
pause
exit /b 1
)
echo [OK] manolito.ps1 descargado.

:: ============================================================
:: PASO 2 -- Obtener hashes.txt (local o remoto)
:: ============================================================
:verify_hash
echo.
echo [i] Verificando integridad con hashes.txt...

:: Intentar descargar hashes.txt a temporal (siempre, para tener version fresca)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -Uri '%REPO_HASHES_URL%' -OutFile '%HASHES_TMP%' -UseBasicParsing -TimeoutSec 8 } catch { exit 1 }" >nul 2>&1

if exist "%HASHES_TMP%" (
set "HASH_SOURCE=%HASHES_TMP%"
echo [i] hashes.txt descargado correctamente.
) else (
if exist "%HASHES_FILE%" (
color 0E
echo.
echo [!] No se pudo descargar hashes.txt desde el servidor.
echo     Usando copia local: %HASHES_FILE%
echo     La verificacion puede no reflejar la version publicada mas reciente.
echo.
set "HASH_SOURCE=%HASHES_FILE%"
set /p "CONFIRM_LOCAL=Escribe SI para continuar con copia local o cualquier otra cosa para salir: "
if /I "!CONFIRM_LOCAL!" neq "SI" (
echo [i] Verificacion cancelada por el usuario.
pause
exit /b 0
)
color 0A
) else (
color 0C
echo.
echo [!] No se pudo obtener hashes.txt ni local ni remotamente.
echo     Sin verificacion de integridad no se puede continuar.
echo.
echo     Descarga hashes.txt manualmente desde: %REPO_HASHES_URL%
echo.
pause
exit /b 1
)
)

:: ============================================================
:: PASO 3 -- Calcular SHA256 de manolito.ps1
:: ============================================================
echo [i] Calculando SHA256 de manolito.ps1...
set "ACTUAL_HASH="
for /f "skip=1 tokens=* delims=" %%H in ('certutil -hashfile "%PS1_FILE%" SHA256 2^>nul') do (
if not defined ACTUAL_HASH set "ACTUAL_HASH=%%H"
)
set "ACTUAL_HASH=%ACTUAL_HASH: =%"

if "!ACTUAL_HASH!"=="" (
color 0C
echo.
echo [!] ERROR: certutil no pudo calcular el hash de manolito.ps1.
echo.
pause
exit /b 1
)

:: ============================================================
:: PASO 4 -- Buscar VERSION HASH en hashes.txt con findstr
:: Formato de linea esperado: 2.9.0 <HASH>
:: ============================================================
for /f %%U in ('powershell -NoProfile -Command "('%ACTUAL_HASH%').ToUpper()"') do set "ACTUAL_HASH_UP=%%U"

findstr /I /C:"%ENGINE_VERSION% %ACTUAL_HASH_UP%" "!HASH_SOURCE!" >nul 2>&1
if %errorlevel% equ 0 goto :hash_ok

color 0C
echo.
echo ====================================================
echo [ INTEGRIDAD NO VERIFICADA ]
echo ====================================================
echo     Version  : %ENGINE_VERSION%
echo     Hash PS1 : %ACTUAL_HASH_UP%
echo     El hash calculado NO se encuentra en hashes.txt
echo     para la version %ENGINE_VERSION%.
echo.
echo [?] Es posible que tengas una version distinta o que
echo     el archivo haya sido modificado.
echo.
set /p "CONFIRM_RISK=Escribe ACEPTO para continuar bajo tu responsabilidad o cualquier otra cosa para salir: "
if /I "!CONFIRM_RISK!" neq "ACEPTO" (
echo.
echo [i] Ejecucion cancelada. Sin cambios.
echo.
if exist "%HASHES_TMP%" del "%HASHES_TMP%" >nul 2>&1
pause
exit /b 0
)
echo [!] Continuando sin verificacion confirmada por el usuario.
goto :launch

:hash_ok
color 0A
echo.
echo [OK] Integridad verificada -- manolito.ps1 v%ENGINE_VERSION% autentico.
echo.

:: ============================================================
:: PASO 5 -- Lanzar motor con doble bypass + elevacion UAC
:: ============================================================
:launch
if exist "%HASHES_TMP%" del "%HASHES_TMP%" >nul 2>&1

echo [i] Iniciando Manolito Engine v%ENGINE_VERSION%...
echo.

net session >nul 2>&1
if %errorlevel% equ 0 (
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1_FILE%"
) else (
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"\"%PS1_FILE%\"\"' -Verb RunAs"
)

if exist "%HASHES_TMP%" del "%HASHES_TMP%" >nul 2>&1
endlocal
exit /b 0

) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"\"%PS1_FILE%\"\"' -Verb RunAs"
)
exit
