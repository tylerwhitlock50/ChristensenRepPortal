# Hourly push: dim_customer, dim_part and the order/invoice/shipment facts,
# then the rollups, order change capture and order QC (views.yml profiles).
# Skips (exit 3, no alert) when a full run holds the core run lock. No
# -IfIdle: the only other run that can hold one of these tables is a
# hand-run subset, and waiting a minute for it beats skipping the hour.
# Everything else - logging to push-hourly.log, alerting, heartbeat - is push.ps1.
& "$PSScriptRoot\push.ps1" -Profile hourly
exit $LASTEXITCODE
