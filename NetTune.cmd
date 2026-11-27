@echo off
rem NetTune launcher: double-click it. Keep it in the same folder as NetTune.ps1.
rem It only shows a menu and calls NetTune.ps1; all the logic lives in the script.
rem   NetTune.cmd /ascii   forces ASCII characters on screen (same as -Ascii)
setlocal EnableExtensions DisableDelayedExpansion
title NetTune
cd /d "%~dp0"

set "NT_PS1=%~dp0NetTune.ps1"
set "NT_SELF=%~f0"
set "NT_DIR=%~dp0"
set "NT_ELEVATED="
set "NT_QUIT="
set "NT_ASCII="
for %%A in (%*) do (
    if /i "%%~A"=="/elevated" set "NT_ELEVATED=1"
    if /i "%%~A"=="/ascii" set "NT_ASCII=-Ascii"
)

if not exist "%NT_PS1%" (
    echo.
    echo   NetTune.ps1 was not found next to NetTune.cmd.
    echo   Put both files in the same folder and try again.
    echo.
    pause >nul
    exit /b 1
)

rem ---------------------------------------------------------------- administrator

set "NT_ADMIN="
fltmc >nul 2>&1 && set "NT_ADMIN=1"
if not defined NT_ADMIN if not defined NT_ELEVATED (
    call :elevate && exit /b 0
    echo.
    echo   No administrator rights. Test and the dry run still work.
    echo.
    timeout /t 3 >nul
)

rem ---------------------------------------------------------------- console

rem NetTune draws with Unicode symbols. UTF-8 code page for them; if the console
rem cannot take it (or is the legacy console), NetTune runs with -Ascii.
set "NT_OLDCP="
for /f "tokens=2 delims=:." %%C in ('chcp') do set "NT_OLDCP=%%C"
if defined NT_OLDCP set "NT_OLDCP=%NT_OLDCP: =%"
chcp 65001 >nul 2>&1 || set "NT_ASCII=-Ascii"
reg query "HKCU\Console" /v ForceV2 2>nul | find "0x0" >nul && set "NT_ASCII=-Ascii"

rem ---------------------------------------------------------------- menu

:menu
cls
echo.
echo   NetTune
echo   -------
if defined NT_ADMIN (echo   Running as administrator.) else (echo   Not administrator: Apply and Revert need it.)
echo.
echo   1  Test            measure only, changes nothing
echo   2  Apply -WhatIf   dry run: shows what would change
echo   3  Apply           back up, apply the tweaks, measure again
echo   4  Revert          undo everything from the latest backup
echo   5  Advanced        Apply with -NoTcp / -NoMtu / -Dns Keep
echo   0  Exit
echo.
choice /c 123450 /n /m "  Choose 1-5 or 0: "
set "NT_KEY=%errorlevel%"
if "%NT_KEY%"=="1" call :run -Mode Test
if "%NT_KEY%"=="2" call :run -Mode Apply -WhatIf
if "%NT_KEY%"=="3" call :needadmin && call :run -Mode Apply
if "%NT_KEY%"=="4" call :needadmin && call :run -Mode Revert
if "%NT_KEY%"=="5" call :advanced
if "%NT_KEY%"=="6" goto :quit
if "%NT_KEY%"=="0" goto :quit
if defined NT_QUIT goto :quit
goto :menu

rem ---------------------------------------------------------------- advanced

:advanced
set "NT_OPT="
echo.
choice /c ysn /n /m "  Skip the TCP Optimizer set (-NoTcp)? [y/n]: "
if not errorlevel 3 set "NT_OPT=%NT_OPT% -NoTcp"
choice /c ysn /n /m "  Skip the MTU test (-NoMtu)? [y/n]: "
if not errorlevel 3 set "NT_OPT=%NT_OPT% -NoMtu"
choice /c ysn /n /m "  Leave the DNS alone (-Dns Keep)? [y/n]: "
if not errorlevel 3 set "NT_OPT=%NT_OPT% -Dns Keep"
echo.
echo   1  Dry run (-WhatIf)    2  Apply    0  Back
choice /c 120 /n /m "  Choose: "
set "NT_KEY=%errorlevel%"
if "%NT_KEY%"=="1" call :run -Mode Apply -WhatIf%NT_OPT%
if "%NT_KEY%"=="2" call :needadmin && call :run -Mode Apply%NT_OPT%
exit /b 0

rem ---------------------------------------------------------------- helpers

:run
rem A clean screen: Write-Progress draws its bar over whatever is at the top.
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%NT_PS1%" %* %NT_ASCII%
echo.
echo   Press any key to go back to the menu...
pause >nul
exit /b 0

:needadmin
if defined NT_ADMIN exit /b 0
echo.
echo   This needs administrator rights.
choice /c ysn /n /m "  Open NetTune again as administrator? [y/n]: "
if errorlevel 3 exit /b 1
rem The elevated window takes over: this one closes.
call :elevate && (set "NT_QUIT=1" & exit /b 1)
echo   Administrator rights were not granted.
timeout /t 3 >nul
exit /b 1

:elevate
rem Paths go through environment variables, so spaces, accents and quotes are safe.
set "NT_ARGS=/elevated"
if defined NT_ASCII set "NT_ARGS=/elevated /ascii"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath $env:NT_SELF -ArgumentList $env:NT_ARGS -WorkingDirectory $env:NT_DIR -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }"
exit /b %errorlevel%

:quit
if defined NT_OLDCP chcp %NT_OLDCP% >nul 2>&1
exit /b 0
