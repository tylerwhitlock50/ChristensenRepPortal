# Nightly ERP -> Supabase push, run by the "Run CRM update" scheduled task.
#
# The exit code is the alarm: Task Scheduler records "Last Run Result" from
# it, so a failed load (or a refused one — see ETL_MIN_ROW_RATIO in
# push_to_supabase.py) shows as 0x1 there instead of 0x0. Until an email/
# Teams hook exists, that column is the thing to check when the portal's
# freshness stamp stops moving.
#
# Output is appended to push.log next to this script so the last failure's
# message survives the task's console window closing.

$ErrorActionPreference = "Continue"
Set-Location -Path $PSScriptRoot

$log = Join-Path $PSScriptRoot "push.log"

# Not Tee-Object: under Windows PowerShell 5.1 (what the task runs) it writes
# UTF-16, which tail/grep on the log render as spaced-out characters.
function Log-Line { process { $_; Add-Content -Path $log -Value $_ -Encoding UTF8 } }

"=== push started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Log-Line

& .\venv\Scripts\Activate.ps1

& python push_to_supabase.py 2>&1 | ForEach-Object { "$_" } | Log-Line
$code = $LASTEXITCODE

deactivate

"=== push exited $code at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Log-Line
exit $code
