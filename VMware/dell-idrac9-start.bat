@echo off
setlocal EnableDelayedExpansion

:: ---------- CONFIGURATION (edit only this section) -------------
:: ---------- BMC_PASS with double quote "" ----------------------
set "TARGETS=172.18.13.104 172.18.13.105"
set "IDRAC_USER=root"
set "IDRAC_PASS=P@ssw0rd"
set "POLL_SEC=10"
set "TIMEOUT_SEC=300"
:: ---------------------------------------------------------------

set "SCRIPT_DIR=%~dp0"
set "LOG_FILE=%SCRIPT_DIR%idrac-auto-start.log"
set "TMP_DIR=%TEMP%\idrac_rf_%RANDOM%%RANDOM%"
mkdir "%TMP_DIR%" >nul 2>&1

call :log "=== Dell iDRAC Startup ==="
call :log "Targets: %TARGETS%"

:: Index the target list
set "HOST_COUNT=0"
for %%H in (%TARGETS%) do (
    set /a HOST_COUNT+=1
    set "HOST_!HOST_COUNT!=%%H"
    set "TRACKER_!HOST_COUNT!=pending"
)

:: ---- STEP 1: Ping, authenticate, check power, trigger start ----
for /l %%I in (1,1,%HOST_COUNT%) do call :process %%I

:: ---- STEP 2: Monitor boot until all online or timeout ----
call :log "Monitoring boot progress..."
set "ELAPSED=0"

:monitor_loop
    set "PENDING=0"
    for /l %%I in (1,1,%HOST_COUNT%) do (
        if "!TRACKER_%%I!"=="booting" set /a PENDING+=1
    )
    if !PENDING! equ 0 goto all_online

    if !ELAPSED! geq %TIMEOUT_SEC% (
        call :log "TIMEOUT: %TIMEOUT_SEC%s elapsed — not all hosts reached On state."
        goto cleanup
    )

    timeout /t %POLL_SEC% /nobreak >nul
    set /a ELAPSED+=%POLL_SEC%

    for /l %%I in (1,1,%HOST_COUNT%) do (
        if "!TRACKER_%%I!"=="booting" (
            call :get_power_state %%I
            call :log "[!ELAPSED!s] Host:!HOST_%%I! PowerState:!PS_%%I!"
            if /i "!PS_%%I!"=="On" (
                set "TRACKER_%%I=online"
                call :log "Host:!HOST_%%I! ONLINE"
            )
        )
    )
goto monitor_loop

:all_online
:: Final summary
set "SUCCESS=0"
for /l %%I in (1,1,%HOST_COUNT%) do (
    if "!TRACKER_%%I!"=="online" set /a SUCCESS+=1
)
call :log "--- Execution Finished --- Hosts Online: !SUCCESS! / %HOST_COUNT%"

:cleanup
for /l %%I in (1,1,%HOST_COUNT%) do call :del_session %%I
rd /s /q "%TMP_DIR%" >nul 2>&1
endlocal
exit /b 0

:process
set "IDX=%~1"
set "IP=!HOST_%IDX%!"

ping -n 1 -w 2000 !IP! >nul 2>&1
if errorlevel 1 (
    call :log "Host:!IP! State:Unreachable (Ping Fail)"
    set "TRACKER_%IDX%=unreachable"
    goto :eof
)

call :do_auth %IDX%
if "!AUTH_OK_%IDX%!"=="0" goto :eof

call :get_power_state %IDX%
set "CPS=!PS_%IDX%!"

if /i "!CPS!"=="On" (
    call :log "Host:!IP! State:Already On"
    set "TRACKER_%IDX%=online"
    goto :eof
)
if "!CPS!"=="Error" (
    call :log "Host:!IP! State:iDRAC API Error - check credentials/network"
    set "TRACKER_%IDX%=error"
    goto :eof
)

call :log "Host:!IP! State:!CPS! -> Action:Powering On"
call :send_power_on %IDX%
goto :eof

:do_auth
set "IDX=%~1"
set "IP=!HOST_%IDX%!"
set "AUTH_OK_%IDX%=0"
set "HDR=%TMP_DIR%\hdr_%IDX%.txt"
set "SRSP=%TMP_DIR%\srsp_%IDX%.json"
set "SREQ=%TMP_DIR%\sreq_%IDX%.json"

:: Generate JSON body via PowerShell so passwords with special chars are safe.
:: PowerShell -Command does NOT require ExecutionPolicy — only .ps1 files do.
powershell -NoProfile -Command ^
    "$u='!IDRAC_USER!';$p='!IDRAC_PASS!';$b=@{UserName=$u;Password=$p}|ConvertTo-Json -Compress;[IO.File]::WriteAllText('!SREQ!',$b)"

curl.exe -k -s -m 20 -X POST ^
    "https://!IP!/redfish/v1/SessionService/Sessions" ^
    -H "Content-Type: application/json" ^
    -d "@!SREQ!" ^
    -D "!HDR!" -o "!SRSP!" >nul 2>&1

:: Extract X-Auth-Token from response headers
set "TOKEN_%IDX%="
for /f "tokens=2 delims=: " %%T in ('findstr /i "^X-Auth-Token:" "!HDR!" 2^>nul') do (
    if not defined TOKEN_%IDX% set "TOKEN_%IDX%=%%T"
)
:: Strip any trailing whitespace or carriage return from token
if defined TOKEN_%IDX% (
    for /f "tokens=* delims= " %%C in ("!TOKEN_%IDX%!") do set "TOKEN_%IDX%=%%C"
)

if defined TOKEN_%IDX% if "!TOKEN_%IDX%!" neq "" (
    :: Default session URI; override if Location header is present
    set "SESS_URI_%IDX%=https://!IP!/redfish/v1/SessionService/Sessions"
    for /f "tokens=2 delims=: " %%L in ('findstr /i "^Location:" "!HDR!" 2^>nul') do (
        if not defined _LOC_FOUND (
            set "_LOC=%%L"
            set "_LOC=!_LOC: =!"
            if "!_LOC:~0,4!"=="http" (
                set "SESS_URI_%IDX%=!_LOC!"
            ) else if "!_LOC!" neq "" (
                set "SESS_URI_%IDX%=https://!IP!!_LOC!"
            )
            set "_LOC_FOUND=1"
        )
    )
    set "_LOC_FOUND="
    set "AUTH_TYPE_%IDX%=session"
    set "AUTH_OK_%IDX%=1"
    call :log "Host:!IP! Auth:Session OK"
    goto :eof
)

:: --- Fallback: Basic Auth ---
call :log "Host:!IP! Session auth unavailable - trying Basic Auth..."
for /f "usebackq delims=" %%B in (`powershell -NoProfile -Command ^
    "[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('!IDRAC_USER!:!IDRAC_PASS!'))"`) do (
    set "B64_%IDX%=%%B"
)

set "CHK=%TMP_DIR%\basic_chk_%IDX%.json"
curl.exe -k -s -m 20 -X GET ^
    "https://!IP!/redfish/v1/Systems" ^
    -H "Authorization: Basic !B64_%IDX%!" ^
    -H "Content-Type: application/json" ^
    -H "Accept: application/json" ^
    -o "!CHK!" >nul 2>&1

findstr /i "Members" "!CHK!" >nul 2>&1
if %errorlevel% equ 0 (
    set "AUTH_TYPE_%IDX%=basic"
    set "AUTH_OK_%IDX%=1"
    call :log "Host:!IP! Auth:Basic OK"
    goto :eof
)

call :log "Host:!IP! Auth:FAILED - check credentials"
set "TRACKER_%IDX%=authfailed"
goto :eof

:get_system_uri
set "IDX=%~1"
set "IP=!HOST_%IDX%!"
if defined SYS_URI_%IDX% goto :eof

set "SYSRSP=%TMP_DIR%\sysuri_%IDX%.json"
if "!AUTH_TYPE_%IDX%!"=="session" (
    curl.exe -k -s -m 20 -X GET "https://!IP!/redfish/v1/Systems" ^
        -H "X-Auth-Token: !TOKEN_%IDX%!" ^
        -H "Content-Type: application/json" ^
        -H "Accept: application/json" ^
        -o "!SYSRSP!" >nul 2>&1
) else (
    curl.exe -k -s -m 20 -X GET "https://!IP!/redfish/v1/Systems" ^
        -H "Authorization: Basic !B64_%IDX%!" ^
        -H "Content-Type: application/json" ^
        -H "Accept: application/json" ^
        -o "!SYSRSP!" >nul 2>&1
)

for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command ^
    "try{$p=(Get-Content '!SYSRSP!' -Raw|ConvertFrom-Json).Members[0].'@odata.id';if($p){$p}}catch{}"`) do (
    set "RAW_PATH=%%P"
)
if defined RAW_PATH (
    if "!RAW_PATH:~0,4!"=="http" (
        set "SYS_URI_%IDX%=!RAW_PATH!"
    ) else (
        set "SYS_URI_%IDX%=https://!IP!!RAW_PATH!"
    )
    set "RAW_PATH="
)
goto :eof

:get_power_state
set "IDX=%~1"
set "IP=!HOST_%IDX%!"
set "PS_%IDX%=Error"

call :get_system_uri %IDX%
if not defined SYS_URI_%IDX% goto :eof

set "PRSP=%TMP_DIR%\ps_%IDX%.json"
if "!AUTH_TYPE_%IDX%!"=="session" (
    curl.exe -k -s -m 20 -X GET "!SYS_URI_%IDX%!" ^
        -H "X-Auth-Token: !TOKEN_%IDX%!" ^
        -H "Content-Type: application/json" ^
        -H "Accept: application/json" ^
        -o "!PRSP!" >nul 2>&1
) else (
    curl.exe -k -s -m 20 -X GET "!SYS_URI_%IDX%!" ^
        -H "Authorization: Basic !B64_%IDX%!" ^
        -H "Content-Type: application/json" ^
        -H "Accept: application/json" ^
        -o "!PRSP!" >nul 2>&1
)

for /f "usebackq delims=" %%S in (`powershell -NoProfile -Command ^
    "try{(Get-Content '!PRSP!' -Raw|ConvertFrom-Json).PowerState}catch{'Error'}"`) do (
    set "PS_%IDX%=%%S"
)
goto :eof

:send_power_on
set "IDX=%~1"
set "IP=!HOST_%IDX%!"

call :get_system_uri %IDX%
if not defined SYS_URI_%IDX% (
    call :log "Host:!IP! Cannot find system URI - power-on skipped"
    set "TRACKER_%IDX%=error"
    goto :eof
)

set "ACT_URI=!SYS_URI_%IDX%!/Actions/ComputerSystem.Reset"
set "ACTRSP=%TMP_DIR%\act_%IDX%.json"

if "!AUTH_TYPE_%IDX%!"=="session" (
    curl.exe -k -s -m 20 -X POST "!ACT_URI!" ^
        -H "X-Auth-Token: !TOKEN_%IDX%!" ^
        -H "Content-Type: application/json" ^
        -H "Accept: application/json" ^
        -d "{\"ResetType\":\"On\"}" ^
        -o "!ACTRSP!" >nul 2>&1
) else (
    curl.exe -k -s -m 20 -X POST "!ACT_URI!" ^
        -H "Authorization: Basic !B64_%IDX%!" ^
        -H "Content-Type: application/json" ^
        -H "Accept: application/json" ^
        -d "{\"ResetType\":\"On\"}" ^
        -o "!ACTRSP!" >nul 2>&1
)

:: Redfish returns an error JSON object on failure; 204 No Content on success
findstr /i "\"error\"" "!ACTRSP!" >nul 2>&1
if %errorlevel% equ 0 (
    call :log "Host:!IP! Power-On FAILED - Redfish error returned"
    set "TRACKER_%IDX%=failedtrigger"
) else (
    call :log "Host:!IP! Power-On command accepted"
    set "TRACKER_%IDX%=booting"
)
goto :eof

:del_session
set "IDX=%~1"
if "!AUTH_TYPE_%IDX%!"=="session" (
    if defined SESS_URI_%IDX% (
        curl.exe -k -s -m 10 -X DELETE "!SESS_URI_%IDX%!" ^
            -H "X-Auth-Token: !TOKEN_%IDX%!" ^
            -o nul >nul 2>&1
        call :log "Host:!HOST_%IDX%! Session deleted"
    )
)
goto :eof

:log
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command ^
    "Get-Date -Format 'yyyy-MM-dd HH:mm:ss'"`) do set "TS=%%T"
set "LINE=!TS!: %~1"
echo !LINE!
echo !LINE!>>"%LOG_FILE%"
goto :eof
