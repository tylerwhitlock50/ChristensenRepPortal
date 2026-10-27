# Stock-only push (erp.fact_available_to_sell), the 15-minute weekday tier.
# Skips (exit 3, no alert) when a full run is loading the same table.
# Everything else - logging to push-ats.log, alerting, heartbeat - is push.ps1.
& "$PSScriptRoot\push.ps1" -Profile ats -IfIdle
exit $LASTEXITCODE
