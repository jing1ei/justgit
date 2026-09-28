@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if not errorlevel 1 (
  py -3 Windows\app.py %*
  if errorlevel 1 goto failed
  exit /b 0
)
where python >nul 2>nul
if not errorlevel 1 (
  python Windows\app.py %*
  if errorlevel 1 goto failed
  exit /b 0
)
echo Install Python 3.11 or later from python.org with Tcl/Tk and the Python launcher.
echo Also install Git for Windows with Git available on PATH.
:failed
echo JustGit could not start or exited with an error. Review the message above.
pause
exit /b 1
