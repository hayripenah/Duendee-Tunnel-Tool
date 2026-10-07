@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
title Duendee Tunnel Tool
color 0B

rem Force UTF-8 console I/O for Turkish glyphs
set "PYTHONIOENCODING=utf-8"

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
if not exist "%TOOL%\config.json" (
    echo   %RED%%BOLD%[HATA]%RST% config.json bulunamadı. Önce config.example.json dosyasını config.json olarak kopyalayıp projectPath ayarlayın.
    pause
    exit /b 1
)
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "(Get-Content -Raw '%TOOL%\config.json' | ConvertFrom-Json).projectPath"`) do set "PROJECT=%%P"
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$c=Get-Content -Raw '%TOOL%\config.json' | ConvertFrom-Json; if($c.port){$c.port}"`) do set "PORT=%%P"
if not defined PROJECT (
    echo   %RED%%BOLD%[HATA]%RST% config.json içinde projectPath tanımlı değil.
    pause
    exit /b 1
)
if not exist "%PROJECT%" (
    echo   %RED%%BOLD%[HATA]%RST% projectPath bulunamadı: %PROJECT%
    pause
    exit /b 1
)
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
<nul set /p "=%BLUE%%BOLD%    █████ █   █ █████ █   █ █████ █████ █████%RST%"
echo.
<nul set /p "=%DEEP%      █████ █   █ █████ █   █ █████ █████ █████%RST%"
<nul set /p "=%ESC%[0G%BLUE%%BOLD%    █   █ █   █ █     ██  █ █   █ █     █%RST%"
echo.
<nul set /p "=%DEEP%      █   █ █   █ █     ██  █ █   █ █     █%RST%"
<nul set /p "=%ESC%[0G%BLUE%%BOLD%    █   █ █   █ █     █ █ █ █   █ █     █%RST%"
echo.
<nul set /p "=%DEEP%      █   █ █   █ █     █ █ █ █   █ █     █%RST%"
<nul set /p "=%ESC%[0G%BLUE%%BOLD%    █   █ █   █ █████ █  ██ █   █ █████ █████%RST%"
echo.
<nul set /p "=%DEEP%      █   █ █   █ █████ █  ██ █   █ █████ █████%RST%"
<nul set /p "=%ESC%[0G%BLUE%%BOLD%    █   █ █   █ █     █   █ █   █ █     █%RST%"
echo.
<nul set /p "=%DEEP%      █   █ █   █ █     █   █ █   █ █     █%RST%"
<nul set /p "=%ESC%[0G%BLUE%%BOLD%    █   █ █   █ █     █   █ █   █ █     █%RST%"
echo.
<nul set /p "=%DEEP%      █   █ █   █ █     █   █ █   █ █     █%RST%"
<nul set /p "=%ESC%[0G%BLUE%%BOLD%    █████ █████ █████ █   █ █████ █████ █████%RST%"
echo.
<nul set /p "=%DEEP%      █████ █████ █████ █   █ █████ █████ █████%RST%"
echo.
rem ========================================================================
echo %DIM%   ───────────────────────────────────────────────────────────%RST%
echo %SKY%%BOLD%          D U E N D E E   T U N N E L   T O O L%RST%
echo %DIM%   ───────────────────────────────────────────────────────────%RST%
echo.
echo   %YEL%%BOLD%[1]%RST%  %SKY%Tünel Servisi Başlat%RST%
echo   %YEL%%BOLD%[2]%RST%  %SKY%Servis Durumunu Kontrol Et%RST%
echo   %YEL%%BOLD%[3]%RST%  %SKY%Yayın Linkini Kopyala%RST%
echo   %YEL%%BOLD%[4]%RST%  %SKY%Tünel Servisini İptal Et%RST%
echo   %YEL%%BOLD%[5]%RST%  %SKY%Tüm Terminalleri Kapat ve Çık%RST%
  if "%AUTOEN%"=="1" (echo   %YEL%%BOLD%[6]%RST%  %SKY%Cihaz Açılışında Otomatik Başlat%RST%  %GRN%[AÇIK]%RST%) else (echo   %YEL%%BOLD%[6]%RST%  %SKY%Cihaz Açılışında Otomatik Başlat%RST%  %DIM%[KAPALI]%RST%)
echo.
echo %DIM%      Kapatmak için pencereyi kapatın, [Ctrl]+[C] ya da [5]%RST%
echo.
echo %CYN%   Seçim [1-6]: %RST%
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
rem  [1] SERVİS BAŞLAT
rem ============================================================
:start
cls
echo.
echo %CYN%   --- Tünel servisi başlatılıyor ---%RST%
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
    echo   %RED%%BOLD%[HATA]%RST% cloudflared bulunamadı.
    goto done
)
:cfdone
echo   %CYN%[1/4]%RST% cloudflared: %CF%

rem ---- Çift başlatma / ölü kayıt temizliği ----
call :readpid
if defined TPID (
    set "PALIVE=0"
    tasklist /FI "PID eq %TPID%" 2>nul | findstr /c:"%TPID%" >nul
    if not errorlevel 1 set "PALIVE=1"
    if "!PALIVE!"=="1" (
        echo   %RED%%BOLD%[HATA]%RST% Servis zaten çalışıyor. Önce [4] ile iptal edin.
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
netstat -ano | findstr /c:":%PORT% " | findstr "LISTENING" >nul
if not errorlevel 1 set "VITE_OK=1"
if "!VITE_OK!"=="0" goto startdev
echo   %CYN%[2/4]%RST% Dev server %PORT% portunda hazır.
goto tunnelup

:startdev
echo   %CYN%[2/4]%RST% Dev server başlatılıyor...
if not exist "%PROJECT%\node_modules" (
    echo   %DIM%   node_modules yok, npm install çalıştırılıyor...%RST%
    pushd "%PROJECT%"
    call npm install
    if errorlevel 1 (
        echo   %RED%%BOLD%   [HATA]%RST% npm install başarısız.
        popd
        goto done
    )
    popd
)
powershell -NoProfile -Command "$p=Start-Process -FilePath cmd.exe -ArgumentList '/C',('cd /d ' + $env:PROJECT + ' & npm run dev') -WindowStyle Minimized -PassThru; if($p){$p.Id | Set-Content -Encoding ASCII $env:SERVER_PID}"
set /a tries=0
:waitport
set /a tries+=1
netstat -ano | findstr /c:":%PORT% " | findstr "LISTENING" >nul
if not errorlevel 1 goto portready
if %tries% geq 20 (
    echo   %RED%%BOLD%[HATA]%RST% Dev server %PORT% portunda açılamadı.
    echo   %DIM%   npm run dev çıktısını ayrı bir pencerede deneyin.%RST%
    goto done
)
ping -n 2 127.0.0.1 >nul
goto waitport
:portready
echo   %CYN%[2/4]%RST% Dev server http://localhost:%PORT% hazır.
:tunnelup

rem ---- tünel başlat ----
:launch
echo   %CYN%[3/4]%RST% Cloudflare tünel başlatılıyor...
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
    echo   %RED%%BOLD%[HATA]%RST% Tünel başlatılamadı. Log: %LOG%
    goto done
)
ping -n 2 127.0.0.1 >nul
set "PALIVE=0"
tasklist /FI "PID eq %TPID%" 2>nul | findstr /c:"%TPID%" >nul
if not errorlevel 1 set "PALIVE=1"
if "!PALIVE!"=="0" (
    echo   %RED%%BOLD%[HATA]%RST% Tünel açılır açılmaz çıktı. Son log:
    call :logtail
    del "%PID_FILE%" 2>nul
    goto done
)
echo   %CYN%[4/4]%RST% Yayın linki bekleniyor - 60 sn'ye kadar...
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
    echo   %RED%%BOLD%[HATA]%RST% Tünel çıktı, link alınamadı. Son log:
    call :logtail
    del "%PID_FILE%" "%URL_FILE%" 2>nul
    goto done
)
if %tries% geq 60 (
    echo   %RED%%BOLD%[HATA]%RST% Yayın linki alınamadı - 60 sn doldu. Son log:
    call :logtail
    del "%PID_FILE%" 2>nul
    goto done
)
ping -n 2 127.0.0.1 >nul
goto waiturl

:goturl
call :refreshurl
if not defined URL goto waiturl
echo   %DIM%   Link alındı, origin sağlığı doğrulanıyor...%RST%
set /a tries=0
:origincheck
set "ORIG="
for /f "delims=" %%O in ('curl -s -o nul -w "%%{http_code}" --max-time 4 http://localhost:%PORT%') do set "ORIG=%%O"
if not defined ORIG set "ORIG=000"
if !ORIG! geq 200 if !ORIG! leq 399 (
    echo   %GRN%   Origin kontrolü başarılı, kod: !ORIG!.%RST%
    goto pubtry
)
set /a tries+=1
set "PALIVE=0"
tasklist /FI "PID eq %TPID%" 2>nul | findstr /c:"%TPID%" >nul
if not errorlevel 1 set "PALIVE=1"
if "!PALIVE!"=="0" (
    echo   %RED%%BOLD%[HATA]%RST% Tünel bağlantı sırasında çıktı.
    call :logtail
    del "%PID_FILE%" "%URL_FILE%" 2>nul
    goto done
)
if %tries% geq 15 (
    echo   %RED%%BOLD%[HATA]%RST% Dev server origin %PORT% portunda yanıt vermiyor, son kod: !ORIG!.
    echo   %DIM%   000 = bağlantı kurulamadı, 4xx/5xx = sunucu hata kodu; npm run dev penceresini kontrol edin.%RST%
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
    echo   %GRN%   Yayın adresi erişilebilir, kod: !PUB! - yayın hazır.%RST%
    goto ready
)
set /a tries+=1
if %tries% geq 3 (
    echo   %YEL%   Uyarı: halk adres henüz doğrulanamadı, son kod: !PUB!.%RST%
    echo   %DIM%   000 = Cloudflare henüz yönlendirmiyor; birkaç saniye içinde erişilebilir olur.%RST%
    goto ready
)
ping -n 2 127.0.0.1 >nul
goto pubcheck
:ready
call :refreshurl
echo.
echo %GRN%%BOLD%
echo   ╔══════════════════════════════════════════════════════╗
echo   ║      YAYIN HAZIR - Diğer cihazlar bağlanabilir!      ║
echo   ╚══════════════════════════════════════════════════════╝
echo %RST%
echo.
call :logtail
echo.
call :refreshurl
powershell -NoProfile -Command "$u=''; if(Test-Path -LiteralPath $env:URL_FILE){$u=(Get-Content -Raw -LiteralPath $env:URL_FILE).Trim()}; if($u){Set-Clipboard $u}"
if defined URL echo %BLUE%%BOLD%     !URL!%RST%
echo %GRN%   Link panoya kopyalandı.%RST%  Gerekirse [3] ile yeniden kopyalayın.
echo.

rem ---- varsayılan tarayıcıda otomatik aç ----
echo   Varsayılan tarayıcıda açılıyor...
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
netstat -ano | findstr /c:":%PORT% " | findstr "LISTENING" >nul
if not errorlevel 1 set "LINE1=Dev Server ........ %GRN%CALISIYOR%RST%  -  http://localhost:%PORT%"
echo   %LINE1%
call :readpid
set "PALIVE=0"
if defined TPID (
    tasklist /FI "PID eq %TPID%" 2>nul | findstr /c:"%TPID%" >nul
    if not errorlevel 1 set "PALIVE=1"
)
set "LINE2=Tünel Servisi ..... %RED%KAPALI%RST%"
if "!PALIVE!"=="1" set "LINE2=Tünel Servisi ..... %GRN%CALISIYOR%RST%  -  PID %TPID%"
echo   %LINE2%
if "!PALIVE!"=="1" (
    call :refreshurl
    if defined URL echo   Yayın Linki ......... %BLUE%%BOLD%%URL%%RST%
)
  if exist "%LOG%" (
    call :logtail
  )
echo.
goto done

rem ============================================================
rem  [3] LİNKİ KOPYALA
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
echo %GRN%   Yayın linki panoya kopyalandı:%RST%
echo %BLUE%%BOLD%     !URL!%RST%
echo.
goto done
:nolink
echo   %RED%%BOLD%[HATA]%RST% Aktif yayın linki yok.
echo   %DIM%   Önce [1] ile tünel servisini başlatın.%RST%
echo.
goto done
rem ============================================================
rem  [4] İPTAL
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
rem  [6] OTOMATİK BAŞLAT
rem ============================================================
:autostart
cls
echo.
set "BATFILE=%~f0"
echo %CYN%   --- Cihaz Açılışında Otomatik Başlat ---%RST%
echo.
call :autostate
if "%AUTOEN%"=="1" goto autooff
goto autoon

rem ---- durum AÇIK: kapat ----
:autooff
echo   %DIM%   Durum:%RST% %YEL%%BOLD%[AÇIK]%RST%
  echo   %DIM%   Cihaz açıldığında tool kendiliğinden açılır, servisi [1] ile elle başlatırsın.%RST%
echo.
choice /c KX /n /m "   Otomatik başlatmayı kapat  [K]   -   geri dön  [X]: "
if errorlevel 2 goto menu
powershell -NoProfile -Command "Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -ErrorAction SilentlyContinue"
call :autostate
echo.
if "%AUTOEN%"=="0" (
    echo   %GRN%   Otomatik başlatma kapatıldı.%RST%
    echo   %DIM%   Bundan sonra cihaz açıldığında tool açılmayacak.%RST%
) else (
    echo   %RED%%BOLD%[HATA]%RST% Ayar kapatılamadı, kayıt duruyor.
)
echo.
goto done

rem ---- durum KAPALI: aç ----
:autoon
echo   %DIM%   Durum:%RST% %RED%%BOLD%[KAPALI]%RST%
echo   %DIM%   Cihaz açıldığında tool açılmıyor.%RST%
echo.
choice /c AX /n /m "   Otomatik başlatmayı aç  [A]   -   geri dön  [X]: "
if errorlevel 2 goto menu
powershell -NoProfile -Command "$q=[char]34; $v=$q + $env:BATFILE + $q; New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DuendeeTunnelTool' -Value $v -PropertyType String -Force | Out-Null"
call :autostate
echo.
if "%AUTOEN%"=="1" (
    echo   %GRN%   Otomatik başlatma açık.%RST%
    echo   %DIM%   Bundan sonra cihaz açıldığında tool kendiliğinden açılacak. Servisi [1] ile başlatabilirsin.%RST%
    echo   %DIM%   Kayıt: HKCU\...\CurrentVersion\Run  -  DuendeeTunnelTool%RST%
) else (
    echo   %RED%%BOLD%[HATA]%RST% Ayar kaydedilemedi, kayıt oluşturulamadı.
)
echo.
goto done
:shutdown
cls
echo.
echo %CYN%   --- Tüm terminaller kapatılıyor ---%RST%
call :killall
echo %GRN%   Tool'a bağlı terminaller kapatıldı. Çıkılıyor...%RST%
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
        echo   %GRN%   Tünel servisi durduruldu - PID %TPID%.%RST%
    ) else (
        echo   %DIM%   PID %TPID% zaten çalışmıyor.%RST%
    )
) else (
    echo   %YEL%   Tanımlı çalışan tünel servisi yok.%RST%
)
taskkill /IM cloudflared.exe /F >nul 2>nul
set "SPID="
if exist "%SERVER_PID%" set /p SPID=<"%SERVER_PID%"
if defined SPID (
    tasklist /FI "PID eq %SPID%" 2>nul | findstr /c:"%SPID%" >nul
    if not errorlevel 1 (
        taskkill /PID %SPID% /T /F >nul 2>nul
        echo   %GRN%   Dev server penceresi kapatıldı - PID %SPID%.%RST%
    ) else (
        echo   %DIM%   Dev server zaten kapalı.%RST%
    )
    del "%SERVER_PID%" 2>nul
)
del "%PID_FILE%" "%URL_FILE%" 2>nul
taskkill /IM PhotosApp.exe /F >nul 2>nul
del "%TEMP%\duendee-whatsapp-qr.png" 2>nul
exit /b 0

rem ============================================================
rem  yardımcılar
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
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; $b=Get-Content $env:LOG -Tail 8 -ErrorAction SilentlyContinue; foreach($s in $b){ $t=$s; $t=$t -replace '^ERR ','Hata: '; $t=$t -replace '^WRN ','Uyarı: '; $t=$t -replace '^INF ','Bilgi: '; $t=$t -replace 'precheck complete','ön kontrol tamamlandı'; $t=$t -replace 'Registered tunnel connection','tünel bağlantısı kuruldu'; $t=$t -replace 'Unable to reach the origin','yerel sunucu (origin) erişilemiyor'; $t=$t -replace 'connection refused','bağlantı reddedildi'; $t=$t -replace 'error=','hata='; if($s -match 'ERR'){Write-Host ('    ' + $t) -ForegroundColor Red}elseif($s -match 'WRN'){Write-Host ('    ' + $t) -ForegroundColor Yellow}elseif($s -match 'INF'){Write-Host ('    ' + $t) -ForegroundColor Green}else{Write-Host ('    ' + $t) -ForegroundColor Gray}}"
exit /b 0

:done
echo.
if defined AUTO ( exit /b 0 )
pause
goto menu