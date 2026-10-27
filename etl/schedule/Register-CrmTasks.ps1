<#
.SYNOPSIS
    Registers the four ERP -> Supabase push tasks in Task Scheduler folder \CRM\.

.DESCRIPTION
    The refresh tiers (etl\views.yml `profiles:`), all times the server's
    clock, which must be America/Denver:

      ERP push - ATS          Mon-Fri every 15 min 05:00-17:45 (52 runs)
                              push.ps1 -Profile ats -IfIdle     limit 10 min
      ERP push - hourly       Mon-Fri every hour 06:05-16:05 (11 runs)
                              push.ps1 -Profile hourly          limit 50 min
      ERP push - full 0430    daily 04:30, catch up a missed start
                              push.ps1 -Profile full            limit 2 h
      ERP push - full 1700    Mon-Fri 17:00, catch up a missed start
                              push.ps1 -Profile full -SkipAi    limit 2 h

    Every task: IgnoreNew when the previous instance is still running (the
    loader's own locks are the second line of defence), battery conditions
    off, run whether or not anyone is logged on. Only the two full tasks
    catch up a missed start (StartWhenAvailable): a missed 15-minute or
    hourly run is superseded by the next one, but a missed full run is a
    day without scores, signals or the AI batch.

    Logon type - read this before choosing:
      Password (default)  Prompts once with Get-Credential; Task Scheduler
                          stores the password. The task gets the account's
                          full network identity, so Windows-integrated auth
                          (Trusted_Connection=yes) to a remote SQL Server works.
      gMSA                Pass -User 'DOMAIN\svc-crm-etl$' (trailing $) with
                          -LogonType Password: no prompt, no stored password,
                          network identity included. The best option on a
                          domain-joined BI server.
      S4U                 No stored password, but the task runs WITHOUT
                          network credentials: Windows-integrated auth to a
                          REMOTE SQL Server fails (the login arrives as
                          anonymous). Use S4U only with SQL authentication in
                          MSSQL_CONN (UID=/PWD=) or a SQL Server on this box.

    Re-running the script updates the tasks in place (-Force). Run it
    elevated. It never prints the credential.

.PARAMETER EtlDir
    The etl folder holding push.ps1, views.yml, .env and venv. Default: the
    parent of this script's folder.

.PARAMETER User
    The account the tasks run as. Default: the current user.

.PARAMETER LogonType
    Password (default; gMSA when -User ends in $) or S4U. See above.

.PARAMETER WhatIf
    Print the plan; register, change or prompt for nothing.

.PARAMETER Remove
    Unregister the four tasks (the \CRM\ folder is left in place).

.PARAMETER DisableLegacyTask
    Also disable the old "Run CRM update" task (the 5 PM PC task) if it
    exists on this machine. Do this the same day the new tasks go live, or
    both machines load every evening.

.EXAMPLE
    .\Register-CrmTasks.ps1 -WhatIf
.EXAMPLE
    .\Register-CrmTasks.ps1 -User 'CORP\svc-crm-etl$' -DisableLegacyTask
.EXAMPLE
    .\Register-CrmTasks.ps1 -User 'BISERVER\crm-etl' -LogonType S4U
.EXAMPLE
    .\Register-CrmTasks.ps1 -Remove
#>
param(
    [string]$EtlDir = (Split-Path -Parent $PSScriptRoot),
    [string]$User = "$env:USERDOMAIN\$env:USERNAME",
    [ValidateSet('Password', 'S4U')]
    [string]$LogonType = 'Password',
    [switch]$WhatIf,
    [switch]$Remove,
    [switch]$DisableLegacyTask
)

$ErrorActionPreference = 'Stop'

$TaskPath = '\CRM\'
$LegacyTaskName = 'Run CRM update'
# Windows PowerShell 5.1, by full path: pwsh 7 may be a per-user Store
# install a service account cannot see.
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Weekdays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')

$EtlDir = $EtlDir.TrimEnd('\')
$pushScript = Join-Path $EtlDir 'push.ps1'

$tasks = @(
    @{
        Name        = 'ERP push - full 0430'
        Arguments   = '-Profile full'
        Schedule    = 'Daily'
        At          = '04:30'
        Every       = $null
        For         = $null
        Limit       = New-TimeSpan -Hours 2
        CatchUp     = $true
        Description = 'Full ERP -> Supabase load: every table, post-load (rollups, scores, recommendations, order changes, QC) and the AI summary batch. Ledger: etl:run. Log: etl\push.log.'
    },
    @{
        Name        = 'ERP push - full 1700'
        Arguments   = '-Profile full -SkipAi'
        Schedule    = 'Weekdays'
        At          = '17:00'
        Every       = $null
        For         = $null
        Limit       = New-TimeSpan -Hours 2
        CatchUp     = $true
        Description = 'Evening full ERP -> Supabase load without the AI batch. Waits up to 45 min for a running hourly. Ledger: etl:run. Log: etl\push.log.'
    },
    @{
        Name        = 'ERP push - hourly'
        Arguments   = '-Profile hourly'
        Schedule    = 'Weekdays'
        At          = '06:05'
        # 06:05 + 10 h = 16:05 is the 11th and last run; the extra minute
        # keeps 16:05 inside the window.
        Every       = New-TimeSpan -Hours 1
        For         = New-TimeSpan -Hours 10 -Minutes 1
        Limit       = New-TimeSpan -Minutes 50
        CatchUp     = $false
        Description = 'Hourly ERP -> Supabase load: dim_customer, dim_part, order/invoice/shipment facts (merge swap), then rollups, order change capture and QC. Skips if a full run is on. Ledger: etl:run:hourly. Log: etl\push-hourly.log.'
    },
    @{
        Name        = 'ERP push - ATS'
        Arguments   = '-Profile ats -IfIdle'
        Schedule    = 'Weekdays'
        At          = '05:00'
        # 05:00 + 51 x 15 min = 17:45 is the 52nd and last run.
        Every       = New-TimeSpan -Minutes 15
        For         = New-TimeSpan -Hours 12 -Minutes 46
        Limit       = New-TimeSpan -Minutes 10
        CatchUp     = $false
        Description = 'Stock-only ERP -> Supabase load (erp.fact_available_to_sell). Skips when a full run is loading the same table. Alerts after 3 consecutive failures. Log: etl\push-ats.log.'
    }
)

function New-CrmTrigger($t) {
    if ($t.Schedule -eq 'Daily') {
        return New-ScheduledTaskTrigger -Daily -At $t.At
    }
    $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $Weekdays -At $t.At
    if ($t.Every) {
        # A weekly trigger cannot take -RepetitionInterval itself; a -Once
        # trigger can, and its Repetition object carries over unchanged.
        $once = New-ScheduledTaskTrigger -Once -At $t.At -RepetitionInterval $t.Every -RepetitionDuration $t.For
        $trigger.Repetition = $once.Repetition
    }
    return $trigger
}

function Format-Span([TimeSpan]$s) {
    if ($s.TotalMinutes -lt 60) { return ('{0} min' -f [int]$s.TotalMinutes) }
    return ('{0}h{1:00}' -f [int][Math]::Floor($s.TotalHours), $s.Minutes)
}

function Get-TaskArgument($t) {
    return "-NoProfile -ExecutionPolicy Bypass -File `"$pushScript`" $($t.Arguments)"
}

$isGmsa = $User.EndsWith('$')
if ($LogonType -eq 'S4U') {
    $principalText = 'S4U (no stored password, NO network credentials)'
} elseif ($isGmsa) {
    $principalText = 'gMSA (password managed by AD)'
} else {
    $principalText = 'Password (prompted once, stored by Task Scheduler)'
}

# --- Checks that apply to every mode ----------------------------------------

$tz = (Get-TimeZone).Id
if ($tz -ne 'Mountain Standard Time') {
    Write-Warning "This machine's time zone is '$tz', not 'Mountain Standard Time'. The schedule is in server-clock time and assumes America/Denver: either change the time zone or the task times will be off."
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- Plan --------------------------------------------------------------------

Write-Host ''
if ($Remove) {
    Write-Host "Plan: REMOVE these tasks from $TaskPath"
    foreach ($t in $tasks) { Write-Host "  $($t.Name)" }
} else {
    Write-Host "Plan: register in $TaskPath as $User - logon $principalText"
    Write-Host "  action: $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File `"$pushScript`" <args>"
    Write-Host "  start in: $EtlDir"
    foreach ($t in $tasks) {
        $when = if ($t.Schedule -eq 'Daily') { "daily $($t.At)" } else { "Mon-Fri $($t.At)" }
        if ($t.Every) { $when += " every $(Format-Span $t.Every) for $(Format-Span $t.For)" }
        $catch = if ($t.CatchUp) { 'catch up a missed start' } else { 'no catch-up' }
        Write-Host ("  {0,-22} {1,-26} {2,-44} limit {3}, {4}" -f $t.Name, $t.Arguments, $when, (Format-Span $t.Limit), $catch)
    }
}
if ($DisableLegacyTask) { Write-Host "  and disable the legacy task '$LegacyTaskName' if it exists" }
Write-Host ''

if ($WhatIf) {
    if (-not (Test-Path -LiteralPath $pushScript)) { Write-Warning "push.ps1 not found at $pushScript" }
    if (-not (Test-Path -LiteralPath (Join-Path $EtlDir 'venv\Scripts\python.exe'))) { Write-Warning "venv\Scripts\python.exe not found under $EtlDir - create the venv before the first run (README: Runbook)" }
    if (-not $isAdmin) { Write-Warning 'Not elevated: a real run must be from an elevated prompt.' }
    Write-Host 'WhatIf: nothing was changed.'
    exit 0
}

if (-not $isAdmin) {
    throw 'Run this from an elevated (Administrator) PowerShell: registering tasks for another account needs it.'
}

# --- Remove ------------------------------------------------------------------

if ($Remove) {
    foreach ($t in $tasks) {
        $existing = Get-ScheduledTask -TaskPath $TaskPath -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $t.Name -Confirm:$false
            Write-Host "removed  $($t.Name)"
        } else {
            Write-Host "absent   $($t.Name)"
        }
    }
} else {
    # --- Register --------------------------------------------------------------

    if (-not (Test-Path -LiteralPath $pushScript)) {
        throw "push.ps1 not found at $pushScript - pass -EtlDir."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $EtlDir 'venv\Scripts\python.exe'))) {
        Write-Warning "venv\Scripts\python.exe not found under $EtlDir. The tasks will exit 103 (and alert) until it exists."
    }

    $principal = $null
    $credential = $null
    if ($LogonType -eq 'S4U') {
        $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited
    } elseif ($isGmsa) {
        $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Password -RunLevel Limited
    } else {
        $credential = Get-Credential -UserName $User -Message "Password for $User (stored by Task Scheduler, not by this script)"
        if (-not $credential) { throw 'No credential entered.' }
    }

    foreach ($t in $tasks) {
        $action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument (Get-TaskArgument $t) -WorkingDirectory $EtlDir
        $trigger = New-CrmTrigger $t
        $settingsArgs = @{
            MultipleInstances          = 'IgnoreNew'
            ExecutionTimeLimit         = $t.Limit
            AllowStartIfOnBatteries    = $true
            DontStopIfGoingOnBatteries = $true
            StartWhenAvailable         = [bool]$t.CatchUp
        }
        $settings = New-ScheduledTaskSettingsSet @settingsArgs

        $register = @{
            TaskName    = $t.Name
            TaskPath    = $TaskPath
            Action      = $action
            Trigger     = $trigger
            Settings    = $settings
            Description = $t.Description
            Force       = $true
        }
        if ($principal) {
            $register.Principal = $principal
        } else {
            $register.User = $credential.UserName
            $register.Password = $credential.GetNetworkCredential().Password
            $register.RunLevel = 'Limited'
        }
        try {
            Register-ScheduledTask @register | Out-Null
        } finally {
            $register.Remove('Password')
        }
        Write-Host "registered  $($t.Name)"
    }
    $credential = $null

    Write-Host ''
    Get-ScheduledTask -TaskPath $TaskPath | ForEach-Object {
        $info = $_ | Get-ScheduledTaskInfo
        '{0,-22} {1,-8} next run {2}' -f $_.TaskName, $_.State, $info.NextRunTime
    } | Write-Host
}

# --- Legacy task ---------------------------------------------------------------

if ($DisableLegacyTask) {
    $legacy = @(Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue)
    if ($legacy.Count -eq 0) {
        Write-Host "legacy task '$LegacyTaskName' not found on this machine - disable it on the PC that runs it."
    } else {
        foreach ($l in $legacy) {
            $l | Disable-ScheduledTask | Out-Null
            Write-Host "disabled legacy task $($l.TaskPath)$($l.TaskName)"
        }
    }
}
