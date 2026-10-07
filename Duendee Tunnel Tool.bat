@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Duendee Tunnel Tool
color 0B

rem ============ RENKLER (ANSI) ============
for /f "delims=#" %%E in ('"prompt #$E# & for %%E in (1) do rem"') do set "ESC=%%E"
set "RST=%ESC%[0m"
set "BOLD=%ESC%[1m"
set "DIM=%ESC%[2m"
set "CYN=%ESC%[96m"
set "YEL=%ESC%[93m"
set "GRN=%ESC%[92m"
set "RED=%ESC%[91m"
set "BLUE=%ESC%[38;2;59;130;246m"
set "DEEP=%ESC%[38;2;30;64;175m"
set "SKY=%ESC%[38;2;147;197;253m"

set "TOOL=%~dp0"
if "%TOOL:~-1%"=="\" set "TOOL=%TOOL:~0,-1%"
set "PROJECT="
set "PORT=8080"
if exist "%TOOL%\config.json" (
    for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "(Get-Content -Raw '%TOOL%\config.json' | ConvertFrom-Json).projectPath"`) do set "PROJECT=%%P"
    for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$c=Get-Content -Raw '%TOOL%\config.json' | ConvertFrom-Json; if($c.port){$c.port}"`) do set "PORT=%%P"
)
if not defined PROJECT set "PROJECT=%TOOL%\..\Duendee-main"
set "STATE=%TOOL%\.tunnelstate"
set "PID_FILE=%STATE%\tunnel.pid"
set "URL_FILE=%STATE%\tunnel.url"
set "LOG=%STATE%\tunnel.log"
set "OUT_LOG=%STATE%\tunnel.out.log"
set "SERVER_PID=%STATE%\server.pid"

if not exist "%STATE%" mkdir "%STATE%" >nul 2>nul
rem ---- Terminal kapanma izleyicisi; kapaninca tum surecler temizlenir ----
for /f "delims=" %%P in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%TOOL%\scripts\get-tool-pid.ps1"') do set "TOOL_PID=%%P"
if defined TOOL_PID (
    powershell -NoProfile -Command "Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','%TOOL%\scripts\tunnel-watcher.ps1','-ToolPid','%TOOL_PID%','-Project','%PROJECT%','-ToolRoot','%TOOL%' -WindowStyle Hidden"
)

set "AUTO="
if not "%~1"=="" set "AUTO=1"
if "%~1"=="1" goto start
if "%~1"=="2" goto status
if "%~1"=="3" goto copylink
if "%~1"=="4" goto cancel
if "%~1"=="5" goto shutdown
if "%~1"=="6" goto autostart



:menu
cls
call :autostate
echo.
rem ================================ 3D LOGO ================================
<nul set /p "=%BLUE%%BOLD%    ????? ?   ? ????? ?   ? ????? ????? ?????%RST%"
echo.
<nul set /p "=%DEEP%      ????? ?   ? ????? ?   ? ????? ????? ?????%RST%"
<nul set /p "=%ESC%[0G%BLUE%%BOLD%    ?   ? ?   ? ?     ??  ? ?   ? ?     ?%RST%"
echo.
<nul set /p "=%DEEP%      ?   ? ?   ? ?     ??  ? ?   ? ?     ?%RST%"
<nul set /p "=%ESC%[0G%BLUE%%BOLD%    ?   ? ?   ? ?     ? ? ? ?   ? ?     ?%RST%"
echo.
<nul set /p "=%DEEP%      ?   ? ?   ? ?     ? ? ? ?   ? ?     ?%RST%"
<nul set /p "=%ESC%[0G%BLUE%%BOLD%    ?   ? ?   ? ????? ?  ?? ?   ? ????? ?????%RST%"
echo.
<nul set /p "=%DEEP%      ?   ? ?   ? ????? ?  ?? ?   ? ????? ?????%RST%"
<nul set /p "=%ESC%[0G%BLUE%%BOLD%    ?   ? ?   ? ?     ?   ? ?   ? ?     ?%RST%"
echo.
<nul set /p "=%DEEP%      ?   ? ?   ? ?     ?   ? ?   ? ?     ?%RST%"
<nul set /p "=%ESC%[0G%BLUE%%BOLD%    ?   ? ?   ? ?     ?   ? ?   ? ?     ?%RST%"
echo.
<nul set /p "=%DEEP%      ?   ? ?   ? ?     ?   ? ?   ? ?     ?%RST%"
<nul set /p "=%ESC%[0G%BLUE%%BOLD%    ????? ????? ????? ?   ? ????? ????? ?????%RST%"
echo.
<nul set /p "=%DEEP%      ????? ????? ????? ?   ? ????? ????? ?????%RST%"
echo.
rem ========================================================================
echo %DIM%   ???????????????????????????????????????????????????????????%RST%
echo %SKY%%BOLD%          D U E N D E E   T U N N E L   T O O L%RST%
echo %DIM%   ???????????????????????????????????????????????????????????%RST%
echo.
echo   %YEL%%BOLD%[1]%RST%  %SKY%T?nel Servisi Ba?lat%RST%
echo   %YEL%%BOLD%[2]%RST%  %SKY%Servis Durumunu Kontrol Et%RST%
echo   %YEL%%BOLD%[3]%RST%  %SKY%Yay?n Linkini Kopyala%RST%
echo   %YEL%%BOLD%[4]%RST%  %SKY%T?nel Servisini ?ptal Et%RST%
echo   %YEL%%BOLD%[5]%RST%  %SKY%T?m Terminalleri Kapat ve ??k%RST%
  if "%AUTOEN%"=="1" (echo   %YEL%%BOLD%[6]%RST%  %SKY%Cihaz A??l???nda Otomatik Ba?lat%RST%  %GRN%[ACIK]%RST%) else (echo   %YEL%%BOLD%[6]%RST%  %SKY%Cihaz A??l???nda Otomatik Ba?lat%RST%  %DIM%[KAPALI]%RST%)
echo.
echo %DIM%      Kapatmak i?in pencereyi kapat?n, [Ctrl]+[C] ya da [5]%RST%
echo.
echo %CYN%   Se?im [1-6]: %RST%
choice /c 123456 /n
if "!errorlevel!"=="255" exit /b 0
if errorlevel 6 goto autostart
if errorlevel 5 goto shutdown
if errorlevel 4 goto cancel
if errorlevel 3 goto copylink
if errorlevel 2 goto status
if errorlevel 1 goto start
goto menu

rem ============================================================
rem  [1] SERV?S BA?LAT
rem ============================================================
:start
cls
echo.
echo %CYN%   --- T?nel servisi ba?lat?l?yor ---%RST%
echo.

rem ---- cloudflared bul ----
set "CF="
if defined DT_CF set "CF=%DT_CF%"
if defined CF goto cfdone
for /f "delims=" %%P in ('where cloudflared 2^>nul') do set "CF=%%P"
if not defined CF if exist "C:\Program Files (x86)\cloudflared\cloudflared.exe" set "CF=C:\Program Files (x86)\cloudflared\cloudflared.exe"
if not defined CF if exist "%ProgramFiles%\cloudflared\cloudflared.exe" set "CF=%ProgramFiles%\cloudflared\cloudflared.exe"
if not defined CF if exist "%USERPROFILE%\.cloudflared\cloudflared.exe" set "CF=%USERPROFILE%\.cloudflared\cloudflared.exe"
if not defined CF (
    echo   %RED%%BOLD%[HATA]%RST% cloudflared bulunamad?.
    goto done
)
:cfdone
echo   %CYN%[1/4]%RST% cloudflared: %CF%

rem ---- ?ift ba?latma / ?l? kay?t temizli?i ----
call :readpid
if defined TPID (
    set "PALIVE=0"
    tasklist /FI "PID eq %TPID%" 2>nul | findstr /c:"%TPID%" >nul
    if not errorlevel 1 set "PALIVE=1"
    if "!PALIVE!"=="1" (
        echo   %RED%%BOLD%[HATA]%RST% Servis zaten ?al???yor. ?nce [4] ile iptal edin.
        goto done
    )
    del "%PID_FILE%" "%URL_FILE%" 2>nul
)

set "SPID="
if exist "%SERVER_PID%" set /p SPID=<"%SERVER_PID%"
if defined SPID (
    tasklist /FI "PID eq %SPID%" 2>nul | findstr /c:"%SPID%" >nul
    if errorlevel 1 del "%SERVER_PID%" 2>nul
)

rem ---- dev server ----
set "VITE_OK=0"
netstat -ano | findstr /c:":8080 " | findstr "LISTENING" >nul
if not errorlevel 1 set "VITE_OK=1"
if "!VITE_OK!"=="0" goto startdev
echo   %CYN%[2/4]%RST% Dev server %PORT% portunda haz?r.
goto tunnelup

:startdev
echo   %CYN%[2/4]%RST% Dev server ba?lat?l?yor...
if not exist "%PROJECT%\node_modules" (
    echo   %DIM%   node_modules yok, npm install ?al??t?r?l?yor...%RST%
    pushd "%PROJECT%"
    call npm install
    if errorlevel 1 (
        echo   %RED%%BOLD%   [HATA]%RST% npm install ba?ar?s?z.
        popd
        goto done
    )
    popd
)
powershell -NoProfile -Command "$p=Start-Process -FilePath cmd.exe -ArgumentList '/C',('cd /d ' + $env:PROJECT + ' & npm run dev') -WindowStyle Minimized -PassThru; if($p){$p.Id | Set-Content -Encoding ASCII $env:SERVER_PID}"
set /a tries=0
:waitport
set /a tries+=1
netstat -ano | findstr /c:":8080 " | findstr "LISTENING" >nul
if not errorlevel 1 goto portready
if %tries% geq 20 (
    echo   %RED%%BOLD%[HATA]%RST% Dev server %PORT% portunda a??lamad?.
    echo   %DIM%   npm run dev ??kt?s?n? ayr? bir pencerede deneyin.%RST%
    goto done
)
ping -n 2 127.0.0.1 >nul
goto waitport
:portready
echo   %CYN%[2/4]%RST% Dev server http://localhost:%PORT% haz?r.
:tunnelup

rem ---- t?nel ba?lat ----
:launch
echo   %CYN%[3/4]%RST% Cloudflare t?nel ba?lat?l?yor...
taskkill /IM cloudflared.exe /F >nul 2>nul
del "%URL_FILE%" 2>nul
if exist "%LOG%" del "%LOG%"
if exist "%OUT_LOG%" del "%OUT_LOG%"
set "URL="
set "TUNNEL_URL="
set "PREV="
set "TARGET=http://localhost:%PORT%"
powershell -NoProfile -Command "$p=Start-Process -FilePath $env:CF -ArgumentList @('tunnel','--url',$env:TARGET,'--no-autoupdate') -WindowStyle Minimized -PassThru -RedirectStandardOutput $env:OUT_LOG -RedirectStandardError $env:LOG; $p.Id | Set-Content -Encoding ASCII $env:PID_FILE"
call :readpid
if not defined TPID (
    echo   %RED%%BOLD%[HATA]%RST% T?nel ba?lat?lamad?. Log: %LOG%
    goto done
)
ping -n 2 127.0.0.1 >nul
set "PALIVE=0"
tasklist /FI "PID eq %TPID%" 2>nul | findstr /c:"%TPID%" >nul
if not errorlevel 1 set "PALIVE=1"
if "!PALIVE!"=="0" (
    echo   %RED%%BOLD%[HATA]%RST% T?nel a??l?r a??lmaz ??kt?. Son log:
    call :logtail
    del "%PID_FILE%" 2>nul
    goto done
)
echo   %CYN%[4/4]%RST% Yay?n linki bekleniyor - 60 sn'ye kadar...
set "URL="
set /a tries=0
:waiturl
call :refreshurl
if defined URL goto goturl
set /a tries+=1
set /a m5="!tries! %% 5"
if "!m5!"=="0" echo   %DIM%   ... %tries% saniye beklendi%RST%
set "PALIVE=0"
tasklist /FI "PID eq %TPID%" 2>nul | findstr /c:"%TPID%" >nul
if not errorlevel 1 set "PALIVE=1"
if "!PALIVE!"=="0" (
    echo   %RED%%BOLD%[HATA]%RST% T?nel ??kt?, link al?namad?. Son log:
    call :logtail
    del "%PID_FILE%" "%URL_FILE%" 2>nul
    goto done
)
if %tries% geq 60 (
    echo   %RED%%BOLD%[HATA]%RST% Yay?n linki al?namad? - 60 sn doldu. Son log:
    call :logtail
    del "%PID_FILE%" 2>nul
    goto done
)
ping -n 2 127.0.0.1 >nul
goto waiturl

:goturl
call :refreshurl
if not defined URL goto waiturl
echo   %DIM%   Link al?nd?, origin sa?l??? do?rulan?yor...%RST%
set /a tries=0
:origincheck
set "ORIG="
for /f "delims=" %%O in ('curl -s -o nul -w "%%{http_code}" --max-time 4 http://localhost:%PORT%') do set "ORIG=%%O"
if not defined ORIG set "ORIG=000"
if !ORIG! geq 200 if !ORIG! leq 399 (
    echo   %GRN%   Origin kontrol? ba?ar?l?, kod: !ORIG!.%RST%
    goto pubtry
)
set /a tries+=1
set "PALIVE=0"
tasklist /FI "PID eq %TPID%" 2>nul | findstr /c:"%TPID%" >nul
if not errorlevel 1 set "PALIVE=1"
if "!PALIVE!"=="0" (
    echo   %RED%%BOLD%[HATA]%RST% T?nel ba?lant? s?ras?nda ??kt?.
    call :logtail
    del "%PID_FILE%" "%URL_FILE%" 2>nul
    goto done
)
if %tries% geq 15 (
    echo   %RED%%BOLD%[HATA]%RST% Dev server origin %PORT% portunda yan?t vermiyor, son kod: !ORIG!.
    echo   %DIM%   000 = ba?lant? kurulamad?, 4xx/5xx = sunucu hata kodu; npm run dev penceresini kontrol edin.%RST%
    call :logtail
    del "%PID_FILE%" "%URL_FILE%" 2>nul
    goto done
)
ping -n 2 127.0.0.1 >nul
goto origincheck
:pubtry
call :refreshurl
set /a tries=0
:pubcheck
set "PUB="
for /f "delims=" %%S in ('curl -s -o nul -w "%%{http_code}" --max-time 6 !URL!') do set "PUB=%%S"
if not defined PUB set "PUB=000"
if !PUB! geq 200 if !PUB! leq 399 (
    echo   %GRN%   Yay?n adresi eri?ilebilir, kod: !PUB! - yay?n haz?r.%RST%
    goto ready
)
set /a tries+=1
if %tries% geq 3 (
    echo   %YEL%   Uyar?: halk adres hen?z do?rulanamad?, son kod: !PUB!.%RST%
    echo   %DIM%   000 = Cloudflare hen?z y?nlendirmiyor; birka? saniye i?inde eri?ilebilir olur.%RST%
    goto ready
)
ping -n 2 127.0.0.1 >nul
goto pubcheck
:ready
call :refreshurl
echo.
echo %GRN%%BOLD%
echo   ????????????????????????????????????????????????????????
echo   ?      YAYIN HAZIR - Di?er cihazlar ba?lanabilir!      ?
echo   ????????????????????????????????????????????????????????
echo %RST%
echo.
call :logtail
echo.
call :refreshurl
powershell -NoProfile -Command "$u=''; if(Test-Path -LiteralPath $env:URL_FILE){$u=(Get-Content -Raw -LiteralPath $env:URL_FILE).Trim()}; if($u){Set-Clipboard $u}"
if defined URL echo %BLUE%%BOLD%     !URL!%RST%
echo %GRN%   Link panoya kopyaland?.%RST%  Gerekirse [3] ile yeniden kopyalay?n.
echo.

rem ---- varsay?lan taray?c?da otomatik a? ----
echo   Varsay?lan taray?c?da a??l?yor...
start "" "!URL!"

rem ---- WhatsApp'a link gonderme ----
echo   WhatsApp'a link gonderiliyor...
node "%TOOL%\scripts\send-whatsapp.js" "%URL_FILE%" "+905315162429"

echo.
goto done

rem ============================================================
rem  [2] DURUM
rem ============================================================
:status
cls
echo.
echo %CYN%   --- Servis Durumu ---%RST%
echo.
set "LINE1=Dev Server ........ %RED%KAPALI%RST%"
netstat -ano | findstr /c:":8080 " | findstr "LISTENING" >nul
if not errorlevel 1 set "LINE1=Dev Server ........ %GRN%CALISIYOR%RST%  -  http://localhost:%PORT%"
echo   %LINE1%
call :readpid
set "PALIVE=0"
if defined TPID (
    tasklist /FI "PID eq %TPID%" 2>nul | findstr /c:"%TPID%" >nul
    if not errorlevel 1 set "PALIVE=1"
)
set "LINE2=T?nel Servisi ..... %RED%KAPALI%RST%"
if "!PALIVE!"=="1" set "LINE2=T?nel Servisi ..... %GRN%CALISIYOR%RST%  -  PID %TPID%"
echo   %LINE2%
if "!PALIVE!"=="1" (
    call :refreshurl
    if defined URL echo   Yay?n Linki ......... %BLUE%%BOLD%%URL%%RST%
)
  if exist "%LOG%" (
    call :logtail
  )
echo.
goto done

rem ============================================================
rem  [3] L?NK? KOPYALA
rem ============================================================
:copylink
cls
echo.
call :readpid
set "PALIVE=0"
if defined TPID (
    tasklist /FI "PID eq %TPID%" 2>nul | findstr /c:"%TPID%" >nul
    if not errorlevel 1 set "PALIVE=1"
)
if "!PALIVE!"=="0" goto nolink
call :refreshurl
if not defined URL goto nolink
powershell -NoProfile -Command "$u=''; if(Test-Path -LiteralPath $env:URL_FILE){$u=(Get-Content -Raw -LiteralPath $env:URL_FILE).Trim()}; if(-not $u){exit 1}; Set-Clipboard $u"
echo %GRN%   Yay?n linki panoya kopyaland?:%RST%
echo %BLUE%%BOLD%     !URL!%RST%
echo.
goto done
:nolink
echo   %RED%%BOLD%[HATA]%RST% Aktif yay?n linki yok.
echo   %DIM%   ?nce [1] ile t?nel servisini ba?lat?n.%RST%
echo.
goto done
rem ============================================================
rem  [4] ?PTAL
rem ============================================================
:cancel
cls
echo.
echo %CYN%   --- Yeni tunel linki olusturuluyor ---%RST%
echo.
call :killtunnel
set "URL="
set "TUNNEL_URL="
set "PREV="
ping -n 2 127.0.0.1 >nul
goto start

rem ============================================================
rem  [6] OTOMAT?K BA?LAT
rem ============================================================
:autostart
cls
echo.
set "BATFILE=%~f0"
echo %CYN%   --- Cihaz A??l???nda Otomatik Ba?lat ---%RST%
echo.
call :autostate
if "%AUTOEN%"=="1" goto autooff
goto autoon

rem ---- durum A?IK: kapat ----
:autooff
echo   %DIM%   Durum:%RST% %YEL%%BOLD%[ACIK]%RST%
  echo   %DIM%   Cihaz a??ld???nda tool kendili?inden a??l?r, servisi [1] ile elle ba?lat?rs?n.%RST%
echo.
choice /c KX /n /m "   Otomatik ba?latmay? kapat  [K]   -   geri d?n  [X]: "
if errorlevel 2 goto menu
powershell -NoProfile -Command "Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -ErrorAction SilentlyContinue"
call :autostate
echo.
if "%AUTOEN%"=="0" (
    echo   %GRN%   Otomatik ba?latma kapat?ld?.%RST%
    echo   %DIM%   Bundan sonra cihaz a??ld???nda tool a??lmayacak.%RST%
) else (
    echo   %RED%%BOLD%[HATA]%RST% Ayar kapat?lamad?, kay?t duruyor.
)
echo.
goto done

rem ---- durum KAPALI: a? ----
:autoon
echo   %DIM%   Durum:%RST% %RED%%BOLD%[KAPALI]%RST%
echo   %DIM%   Cihaz a??ld???nda tool a??lm?yor.%RST%
echo.
choice /c AX /n /m "   Otomatik ba?latmay? a?  [A]   -   geri d?n  [X]: "
if errorlevel 2 goto menu
powershell -NoProfile -Command "$q=[char]34; $v=$q + $env:BATFILE + $q; New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -Value $v -PropertyType String -Force | Out-Null"
call :autostate
echo.
if "%AUTOEN%"=="1" (
    echo   %GRN%   Otomatik ba?latma a??k.%RST%
    echo   %DIM%   Bundan sonra cihaz a??ld???nda tool kendili?inden a??lacak. Servisi [1] ile ba?latabilirsin.%RST%
    echo   %DIM%   Kay?t: HKCU\...\CurrentVersion\Run  -  DuendeeTunnelTool%RST%
) else (
    echo   %RED%%BOLD%[HATA]%RST% Ayar kaydedilemedi, kay?t olu?turulamad?.
)
echo.
goto done
:shutdown
cls
echo.
echo %CYN%   --- T?m terminaller kapat?l?yor ---%RST%
call :killall
echo %GRN%   Tool'a ba?l? terminaller kapat?ld?. ??k?l?yor...%RST%
echo.
exit /b 0

:killtunnel
call :readpid
if defined TPID (
    set "PALIVE=0"
    tasklist /FI "PID eq %TPID%" 2>nul | findstr /c:"%TPID%" >nul
    if not errorlevel 1 set "PALIVE=1"
    if "!PALIVE!"=="1" (
        taskkill /PID %TPID% /F /T >nul 2>nul
        echo   %GRN%   Eski tunel durduruldu - PID %TPID%.%RST%
    )
) else (
    echo   %DIM%   Aktif tunel yok, yeni link baslatilacak.%RST%
)
taskkill /IM cloudflared.exe /F >nul 2>nul
del "%PID_FILE%" "%URL_FILE%" 2>nul
exit /b 0

:killall
call :readpid
if defined TPID (
    set "PALIVE=0"
    tasklist /FI "PID eq %TPID%" 2>nul | findstr /c:"%TPID%" >nul
    if not errorlevel 1 set "PALIVE=1"
    if "!PALIVE!"=="1" (
        taskkill /PID %TPID% /F /T >nul 2>nul
        echo   %GRN%   T?nel servisi durduruldu - PID %TPID%.%RST%
    ) else (
        echo   %DIM%   PID %TPID% zaten ?al??m?yor.%RST%
    )
) else (
    echo   %YEL%   Tan?ml? ?al??an t?nel servisi yok.%RST%
)
taskkill /IM cloudflared.exe /F >nul 2>nul
set "SPID="
if exist "%SERVER_PID%" set /p SPID=<"%SERVER_PID%"
if defined SPID (
    tasklist /FI "PID eq %SPID%" 2>nul | findstr /c:"%SPID%" >nul
    if not errorlevel 1 (
        taskkill /PID %SPID% /T /F >nul 2>nul
        echo   %GRN%   Dev server penceresi kapat?ld? - PID %SPID%.%RST%
    ) else (
        echo   %DIM%   Dev server zaten kapal?.%RST%
    )
    del "%SERVER_PID%" 2>nul
)
del "%PID_FILE%" "%URL_FILE%" 2>nul
taskkill /IM PhotosApp.exe /F >nul 2>nul
del "%TEMP%\duendee-whatsapp-qr.png" 2>nul
exit /b 0

rem ============================================================
rem  yard?mc?lar
rem ============================================================

:autostate
set "AUTOEN=0"
powershell -NoProfile -Command "if (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
if not errorlevel 1 set "AUTOEN=1"
exit /b 0
:readpid
set "TPID="
if exist "%PID_FILE%" set /p TPID=<"%PID_FILE%"
exit /b 0

:extracturl
powershell -NoProfile -ExecutionPolicy Bypass -File "%TOOL%\scripts\extract-tunnel-url.ps1" -Log "%LOG%" -OutLog "%OUT_LOG%" -UrlFile "%URL_FILE%" >nul
exit /b 0

:refreshurl
set "PREV=!URL!"
set "URL="
call :extracturl
if exist "%URL_FILE%" (
    for /f "usebackq delims=" %%U in ("%URL_FILE%") do set "URL=%%U"
)
if not defined URL if defined PREV if exist "%URL_FILE%" set "URL=!PREV!"
if defined URL set "TUNNEL_URL=!URL!"
exit /b 0

:logtail
echo   %DIM%   Son log:%RST%
powershell -NoProfile -Command "$b=Get-Content $env:LOG -Tail 8 -ErrorAction SilentlyContinue; foreach($s in $b){ $t=$s; $t=$t -replace '^ERR ','Hata: '; $t=$t -replace '^WRN ','Uyar?: '; $t=$t -replace '^INF ','Bilgi: '; $t=$t -replace 'precheck complete','?n kontrol tamamland?'; $t=$t -replace 'Registered tunnel connection','t?nel ba?lant?s? kuruldu'; $t=$t -replace 'Unable to reach the origin','yerel sunucu (origin) eri?ilemiyor'; $t=$t -replace 'connection refused','ba?lant? reddedildi'; $t=$t -replace 'error=','hata='; if($s -match 'ERR'){Write-Host ('    ' + $t) -ForegroundColor Red}elseif($s -match 'WRN'){Write-Host ('    ' + $t) -ForegroundColor Yellow}elseif($s -match 'INF'){Write-Host ('    ' + $t) -ForegroundColor Green}else{Write-Host ('    ' + $t) -ForegroundColor Gray}}"
exit /b 0

:done
echo.
if defined AUTO ( exit /b 0 )
pause
goto menu