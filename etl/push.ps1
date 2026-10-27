# ERP -> Supabase push, run by the \CRM\ scheduled tasks that
# schedule\Register-CrmTasks.ps1 registers (README: "Runbook").
#
#   push.ps1                         full run (all tables, post-load, AI batch)
#   push.ps1 -SkipAi                 full run without the AI batch (17:00)
#   push.ps1 -Profile hourly         orders/invoices/shipments + rollups
#   push.ps1 -Profile ats -IfIdle    stock only (every 15 min)
#   push.ps1 -Tables dim_part,fact_order_line   legacy subset: no post-load
#
# The exit code is the loader's (0 ok, 1 failed, 2 usage/config, 3 skipped
# because busy; 103 = the venv's python.exe is missing). Task Scheduler
# records it as "Last Run Result", and this script also turns it into an
# alert and a heartbeat, so a dead load is noticed the same day instead of
# when a rep asks why the numbers stopped moving:
#
#   ETL_ALERT_WEBHOOK      POST {"text": ...} (Teams Workflows / Slack
#                          incoming webhook) on a failure, naming the host,
#                          profile, exit code and the run's last log lines.
#   ETL_HEARTBEAT_URL_FULL / _HOURLY / _ATS
#                          GET on success, GET <url>/fail on failure
#                          (healthchecks.io convention), per profile.
#
# Exceptions, so the channel carries only what needs a human:
#   - exit 3 on ats/hourly is a notice: the run found another run doing the
#     work (no alert, no ping; the heartbeat's grace period absorbs it). On
#     full it IS an alert: a full run waited 45 min for the lock and gave up.
#   - ats alerts (and pings /fail) only from the 3rd consecutive failure,
#     counted in push-ats.failcount and reset to 0 on success; it says once
#     when it recovers. One failed 15-minute run is noise, three is an hour
#     of stale stock.
#   - a -Tables subset is a hand run, not the tier: it alerts on a failure
#     but sends no heartbeat, so a noon subset never pings the full check
#     in place of a missed 04:30 run (or marks it failed while testing).
# A failed alert or ping is logged and never changes the exit code.
#
# Settings come from the environment first, then a minimal KEY=VALUE read of
# etl\.env (the same file the loader reads). Values are never logged.

param(
    [ValidateSet('full', 'hourly', 'ats')]
    [string]$Profile = 'full',
    [string[]]$Tables,
    [switch]$IfIdle,
    [switch]$SkipAi
)

$ErrorActionPreference = 'Continue'
Set-Location -Path $PSScriptRoot

$logNames = @{ full = 'push.log'; hourly = 'push-hourly.log'; ats = 'push-ats.log' }
$log = Join-Path $PSScriptRoot $logNames[$Profile]

# Roll over at 10 MB: the stock run alone logs ~50 times a weekday.
$maxLogBytes = 10MB
if ((Test-Path -LiteralPath $log) -and ((Get-Item -LiteralPath $log).Length -gt $maxLogBytes)) {
    Move-Item -LiteralPath $log -Destination "$log.1" -Force
}

# This run's lines, for the alert text.
$runLines = New-Object System.Collections.Generic.List[string]

# Not Tee-Object: under Windows PowerShell 5.1 (what the task runs) it writes
# UTF-16, which tail/grep on the log render as spaced-out characters.
function Log-Line {
    process {
        $line = "$_"
        $line
        $runLines.Add($line)
        Add-Content -Path $log -Value $line -Encoding UTF8
    }
}

# Python prints em dashes; decode its output as UTF-8 so the log and the
# alert do not turn them into mojibake. Best-effort: a host without a
# console handle keeps the default.
$env:PYTHONIOENCODING = 'utf-8'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# Windows PowerShell 5.1 may still default to TLS 1.0/1.1; webhooks and
# healthchecks.io require 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$dotEnv = @{}
$envFile = Join-Path $PSScriptRoot '.env'
if (Test-Path -LiteralPath $envFile) {
    foreach ($raw in (Get-Content -LiteralPath $envFile -Encoding UTF8)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('export ')) { $line = $line.Substring(7).Trim() }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $dotEnv[$key] = $val
    }
}

function Get-EtlSetting([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    if ($dotEnv.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace($dotEnv[$Name])) {
        return $dotEnv[$Name]
    }
    return $null
}

function Send-Alert([string]$Text) {
    $hook = Get-EtlSetting 'ETL_ALERT_WEBHOOK'
    if (-not $hook) {
        'alert: ETL_ALERT_WEBHOOK is not set - no alert sent' | Log-Line
        return
    }
    try {
        $json = @{ text = $Text } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        Invoke-RestMethod -Uri $hook -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 15 -UseBasicParsing | Out-Null
        'alert: sent' | Log-Line
    } catch {
        "alert: FAILED - $($_.Exception.Message)" | Log-Line
    }
}

function Send-Heartbeat([bool]$Ok) {
    $url = Get-EtlSetting ("ETL_HEARTBEAT_URL_" + $Profile.ToUpperInvariant())
    if (-not $url) { return }
    if (-not $Ok) { $url = $url.TrimEnd('/') + '/fail' }
    $what = if ($Ok) { 'success' } else { 'fail' }
    try {
        Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 10 -UseBasicParsing | Out-Null
        "heartbeat: $what ping sent" | Log-Line
    } catch {
        "heartbeat: $what ping FAILED - $($_.Exception.Message)" | Log-Line
    }
}

$hostName = $env:COMPUTERNAME
$isSubset = [bool]$Tables
$runLabel = if ($isSubset) { 'subset' } else { $Profile }
"=== push started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ($runLabel on $hostName) ===" | Log-Line

# The venv's interpreter, called directly: no Activate.ps1, so nothing
# depends on the execution policy or on PATH. 2026-10-26: Datto RMM
# reinstalled Python elsewhere overnight and the venv's base interpreter
# vanished; the task failed in 1 s with nothing in the log. Now it says so.
$python = Join-Path $PSScriptRoot 'venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    "ETL interpreter not found: $python - rebuild the venv (etl\README.md, Runbook)" | Log-Line
    $code = 103
} else {
    # -u: stdout is a pipe here, not a console, so Python would block-buffer
    # and print nothing until exit - a 9-minute run that looks stalled.
    $pyArgs = @('-u', 'push_to_supabase.py', '--profile', $Profile)
    if ($IfIdle) { $pyArgs += '--if-idle' }
    if ($SkipAi) { $pyArgs += '--no-http' }
    if ($Tables) {
        # -File passes "-Tables a,b" as ONE string; accept commas or spaces.
        $pyArgs += @($Tables | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
    }
    & $python @pyArgs 2>&1 | ForEach-Object { "$_" } | Log-Line
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 1 }
}

"=== push exited $code at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Log-Line

$meaning = switch ($code) {
    0 { 'ok' }
    1 { 'a table or a required post-load step failed' }
    2 { 'usage or configuration error' }
    3 { 'skipped: another run held the lock' }
    103 { 'python.exe missing from etl\venv' }
    default { 'unexpected exit code' }
}

# Busy on ats/hourly: the other run is doing this run's work.
$notice = ($code -eq 3) -and ($Profile -ne 'full')

$alert = $false
$failPing = $false
$extra = ''
if ($Profile -eq 'ats' -and -not $isSubset) {
    $failFile = Join-Path $PSScriptRoot 'push-ats.failcount'
    $fails = 0
    if (Test-Path -LiteralPath $failFile) {
        $parsed = 0
        if ([int]::TryParse(((Get-Content -LiteralPath $failFile -TotalCount 1) -as [string]), [ref]$parsed)) { $fails = $parsed }
    }
    $before = $fails
    if ($code -eq 0) {
        $fails = 0
        if ($before -ge 3) {
            Send-Alert "CRM ETL ats on ${hostName}: recovered after $before consecutive failed runs."
        }
    } elseif (-not $notice) {
        $fails++
        if ($fails -ge 3) {
            $failPing = $true
            # Once per streak: a 4-hour ERP outage is one message, not 16.
            if ($fails -eq 3) { $alert = $true; $extra = " ($fails consecutive failures; no further alerts until it succeeds)" }
            else { "ats: failure $fails in a row (alerted at 3)" | Log-Line }
        } else {
            "ats: failure $fails of 3 before alerting" | Log-Line
        }
    }
    try { Set-Content -LiteralPath $failFile -Value $fails -Encoding ASCII -ErrorAction Stop } catch { "ats: could not write push-ats.failcount - $($_.Exception.Message)" | Log-Line }
} elseif ($code -ne 0 -and -not $notice) {
    $alert = $true
    $failPing = $true
}

if ($code -eq 0) {
    if (-not $isSubset) { Send-Heartbeat $true }
} elseif ($notice) {
    "notice: $runLabel run skipped (exit 3, another run held the lock) - no alert" | Log-Line
} else {
    if ($failPing -and -not $isSubset) { Send-Heartbeat $false }
    if ($alert) {
        $tail = @($runLines | Select-Object -Last 15) -join "`n"
        Send-Alert ("CRM ETL $runLabel run FAILED on ${hostName}: exit $code ($meaning)$extra`n" + $tail)
    }
}

exit $code
