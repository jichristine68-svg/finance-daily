@echo off
setlocal
set "PY=C:\Users\jiaruo\AppData\Local\Programs\Python\Python312\python.exe"
set "SCRIPT=%~dp0serve-phone.py"

netstat -ano | findstr ":8080" | findstr "LISTENING" >nul 2>&1
if not errorlevel 1 (
    echo [OK] already running on port 8080.
    "%PY%" "%SCRIPT%" --show
    exit /b
)

"%PY%" "%SCRIPT%" 8080
