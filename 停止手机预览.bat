@echo off
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":8080" ^| findstr "LISTENING"') do taskkill /f /pid %%a >nul 2>&1
echo [OK] phone preview on port 8080 stopped.
pause
