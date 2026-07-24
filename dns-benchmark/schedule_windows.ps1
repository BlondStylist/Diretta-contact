<#
    schedule_windows.ps1  —  Richtet den mehrtaegigen DNS-Test als Windows-Aufgabe ein.

    Was passiert:
      * Registriert die Aufgabe "DNS-Speedtest": laeuft STUENDLICH, 3 Tage lang,
        misst alle Anbieter und haengt die Ergebnisse an dns_history.jsonl an.
      * Laptop-fest: laeuft auch im Akkubetrieb, holt nach Standby verpasste
        Laeufe nach (StartWhenAvailable) und darf den Rechner dafuer aufwecken.
      * Registriert zusaetzlich "DNS-Speedtest-Auswertung": laeuft EINMAL nach
        3 Tagen und erzeugt Sieger + Grafik (dns_trend.html).

    Ausfuehren (Doppelklick auf start_dns_test.bat) ODER im PowerShell-Fenster:
        powershell -ExecutionPolicy Bypass -File schedule_windows.ps1

    Stoppen / entfernen:
        Unregister-ScheduledTask -TaskName DNS-Speedtest -Confirm:$false
        Unregister-ScheduledTask -TaskName "DNS-Speedtest-Auswertung" -Confirm:$false
#>

$ErrorActionPreference = "Stop"
$here        = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptPath  = Join-Path $here "dns_speed_test.py"
$analyzePath = Join-Path $here "dns_analyze.py"
$historyPath = Join-Path $here "dns_history.jsonl"

# --- Python-Interpreter robust finden (py-Launcher bevorzugt, Store-Stub meiden) ---
$pre = ""
if (Get-Command py -ErrorAction SilentlyContinue) {
    $pyExe = (Get-Command py).Source ; $pre = "-3 "
} else {
    $cand = Get-Command python -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -notlike "*WindowsApps*" } | Select-Object -First 1
    if ($cand) { $pyExe = $cand.Source }
}
if (-not $pyExe) {
    Write-Host "FEHLER: Python 3 nicht gefunden." -ForegroundColor Red
    Write-Host "Bitte von https://www.python.org/downloads/ installieren"
    Write-Host "(beim Setup den Haken 'Add python.exe to PATH' setzen) und erneut ausfuehren."
    exit 1
}
Write-Host "Python:  $pyExe $pre" -ForegroundColor Cyan
Write-Host "Skript:  $scriptPath"
Write-Host "Verlauf: $historyPath`n"

# --- Aktionen ---
$collectArg = "$pre`"$scriptPath`" --rounds 6 --quiet --history `"$historyPath`""
$actCollect = New-ScheduledTaskAction -Execute $pyExe -Argument $collectArg -WorkingDirectory $here

$analyzeArg = "$pre`"$analyzePath`" --history `"$historyPath`""
$actAnalyze = New-ScheduledTaskAction -Execute $pyExe -Argument $analyzeArg -WorkingDirectory $here

# --- Trigger: stuendlich fuer 3 Tage + bei Anmeldung (Backfill) ---
$start   = (Get-Date).AddMinutes(1)
$endAt   = $start.AddDays(3)
$tHourly = New-ScheduledTaskTrigger -Once -At $start `
           -RepetitionInterval (New-TimeSpan -Hours 1) `
           -RepetitionDuration (New-TimeSpan -Days 3)
$tLogon  = New-ScheduledTaskTrigger -AtLogOn
$tEnd    = New-ScheduledTaskTrigger -Once -At $endAt.AddMinutes(5)

# --- Einstellungen: laptop-/standby-fest ---
$set = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun `
       -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
       -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew

# --- Als aktueller Benutzer, ohne Adminrechte, laeuft waehrend Anmeldung ---
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName "DNS-Speedtest" -Action $actCollect `
    -Trigger @($tHourly, $tLogon) -Settings $set -Principal $principal -Force | Out-Null
Register-ScheduledTask -TaskName "DNS-Speedtest-Auswertung" -Action $actAnalyze `
    -Trigger $tEnd -Settings $set -Principal $principal -Force | Out-Null

# --- Sofort einmal starten, damit gleich Daten da sind ---
Start-ScheduledTask -TaskName "DNS-Speedtest"

Write-Host "OK — Aufgaben eingerichtet." -ForegroundColor Green
Write-Host ("  Messung:    stuendlich bis {0}" -f $endAt.ToString("dd.MM.yyyy HH:mm"))
Write-Host ("  Auswertung: automatisch am {0}" -f $endAt.AddMinutes(5).ToString("dd.MM.yyyy HH:mm"))
Write-Host ""
Write-Host "Jederzeit selbst auswerten:"
Write-Host "  $pyExe $pre`"$analyzePath`""
Write-Host ""
Write-Host "Status pruefen:  Get-ScheduledTask -TaskName DNS-Speedtest | Get-ScheduledTaskInfo"
Write-Host "Vorzeitig stoppen:"
Write-Host "  Unregister-ScheduledTask -TaskName DNS-Speedtest -Confirm:`$false"
Write-Host "  Unregister-ScheduledTask -TaskName 'DNS-Speedtest-Auswertung' -Confirm:`$false"
Write-Host ""
Write-Host "TIPP: Damit der Laptop am Strom gar nicht erst schlaeft, optional (Adminrechte):"
Write-Host "  powercfg /change standby-timeout-ac 0"
