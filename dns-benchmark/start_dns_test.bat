@echo off
REM ---------------------------------------------------------------------------
REM  start_dns_test.bat  —  Doppelklick startet die Einrichtung des
REM  mehrtaegigen DNS-Tests (umgeht die PowerShell-ExecutionPolicy-Sperre).
REM  Hinweis: Bei einer SmartScreen-/Defender-Rueckfrage auf
REM  "Weitere Informationen" -> "Trotzdem ausfuehren" klicken.
REM ---------------------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0schedule_windows.ps1"
echo.
pause
