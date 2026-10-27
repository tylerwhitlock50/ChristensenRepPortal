<#
.SYNOPSIS
    Registers, inspects and drives the four ERP -> Supabase push tasks in
    Task Scheduler folder \CRM\. Everything Task Scheduler's UI is used for,
    from one script.

.DESCRIPTION
    The refresh tiers (etl\views.yml `profiles:`), all times the server's
    clock, which must be America/Denver:

      key        task                    schedule                                 push.ps1 args              limit
      full0430   ERP push - full 0430    daily 04:30, catch up a missed start     -Profile full              2 h
      full1700   ERP push - full 1700    Mon-Fri 17:00, catch up a missed start   -Profile full -SkipAi      2 h
      hourly     ERP push - hourly       Mon-Fri every hour 06:05-16:05 (11)      -Profile hourly            50 min
      ats        ERP push - ATS          Mon-Fri every 15 min 05:00-17:45 (52)    -Profile ats -IfIdle       10 min

    Every task: IgnoreNew when the previous instance is still running (the
    loader's own locks are the second line of defence), battery conditions
    off, run whether or not anyone is logged on. Only the two full tasks
    catch up a missed start (StartWhenAvailable) and wake the machine: a
    missed 15-minute or hourly run is superseded by the next one, but a
    missed full run is a day without scores, signals or the AI batch.

    Modes (the default is register):
      (none)            Register or update the four tasks in place. Checks
                        etl\.env first: PG_CONN and MSSQL_CONN must be set,
                        not the .env.example placeholders, and PG_CONN not on
                        the transaction pooler (6543). Values are never printed.
      -WhatIf           Print the plan and the checks; register, change or
                        prompt for nothing.
      -Status           Show the four tasks (and the legacy task, if present):
                        state, last run, last result decoded, next run. Needs
                        no elevation. Every other mode ends with this table.
      -Start <key>      Start a task now, as the task account, with its logs
                        and alerts (= Start-ScheduledTask).
      -Disable <key>    Pause a task, e.g. -Disable ats while the ERP's stock
      -Enable <key>     view changes. -Enable to resume.
      -Remove           Unregister the four tasks (the \CRM\ folder stays).
      -DisableLegacyTask
                        Also disable the old "Run CRM update" task (the 5 PM
                        PC task) if it exists on this machine. Do this the
                        same day the new tasks go live, or both machines load
                        every evening.

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

    Registering, removing, starting, enabling and disabling need an elevated
    prompt. The script never prints a credential or a .env value.

.PARAMETER EtlDir
    The etl folder holding push.ps1, views.yml, .env and venv. Default: the
    parent of this script's folder.

.PARAMETER User
    The account the tasks run as. Default: the current user.

.PARAMETER LogonType
    Password (default; gMSA when -User ends in $) or S4U. See above.

.PARAMETER Status
    Show the tasks and exit. The only mode that needs no elevation.

.PARAMETER Start
    Start this task now: full0430, full1700, hourly or ats.

.PARAMETER Enable
    Enable this task: full0430, full1700, hourly or ats.

.PARAMETER Disable
    Disable this task: full0430, full1700, hourly or ats.

.PARAMETER Remove
    Unregister the four tasks (the \CRM\ folder is left in place).

.PARAMETER DisableLegacyTask
    Also disable the old "Run CRM update" task if it exists on this machine.

.EXAMPLE
    .\Register-CrmTasks.ps1 -WhatIf
.EXAMPLE
    .\Register-CrmTasks.ps1 -User 'CORP\svc-crm-etl$' -DisableLegacyTask
.EXAMPLE
    .\Register-CrmTasks.ps1 -User 'BISERVER\crm-etl' -LogonType S4U
.EXAMPLE
    .\Register-CrmTasks.ps1 -Status
.EXAMPLE
    .\Register-CrmTasks.ps1 -Start full1700
.EXAMPLE
    .\Register-CrmTasks.ps1 -Disable ats
.EXAMPLE
    .\Register-CrmTasks.ps1 -Remove
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Default resolved below: $PSScriptRoot is empty while Windows PowerShell
    # 5.1 evaluates parameter defaults.
    [string]$EtlDir,
    [string]$User = "$env:USERDOMAIN\$env:USERNAME",
    [ValidateSet('Password', 'S4U')]
    [string]$LogonType = 'Password',
    [switch]$Status,
    [ValidateSet('full0430', 'full1700', 'hourly', 'ats')]
    [string]$Start,
    [ValidateSet('full0430', 'full1700', 'hourly', 'ats')]
    [string]$Enable,
    [ValidateSet('full0430', 'full1700', 'hourly', 'ats')]
    [string]$Disable,
    [switch]$Remove,
    [switch]$DisableLegacyTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskPath = '\CRM\'
$LegacyTaskName = 'Run CRM update'
# Windows PowerShell 5.1, by full path: pwsh 7 may be a per-user Store
# install a service account cannot see.
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Weekdays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')

if ([string]::IsNullOrWhiteSpace($EtlDir)) { $EtlDir = Split-Path -Parent $PSScriptRoot }
$EtlDir = $EtlDir.TrimEnd('\')
$pushScript = Join-Path $EtlDir 'push.ps1'
$envFile = Join-Path $EtlDir '.env'
$pythonExe = Join-Path $EtlDir 'venv\Scripts\python.exe'

# Order matters: this is the order -Status prints them in.
$tasks = @(
    @{
        Key         = 'full0430'
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
        Key         = 'full1700'
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
        Key         = 'hourly'
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
        Key         = 'ats'
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

# --- Helpers -------------------------------------------------------------------

function Get-CrmTask([string]$Key) {
    return $tasks | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
}

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
    # -NonInteractive: a stray prompt must fail the run, not hang it until
    # the time limit kills it.
    return "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$pushScript`" $($t.Arguments)"
}

# Last Run Result, decoded. The low numbers are push.ps1's exit codes
# (README: "Locks and exit codes"); the 0x41xxx values are Task Scheduler's.
function Format-TaskResult([uint32]$code) {
    $meaning = switch ($code) {
        0          { 'ok' }
        1          { 'a table or a required post-load step failed' }
        2          { 'usage or configuration error' }
        3          { 'skipped: another run held the lock' }
        103        { 'python.exe missing from etl\venv' }
        0x41300    { 'ready' }
        0x41301    { 'running now' }
        0x41302    { 'disabled' }
        0x41303    { 'never run' }
        0x41304    { 'no more runs scheduled' }
        0x41306    { 'terminated (time limit or stopped by hand)' }
        0x8004131F { 'an instance is already running' }
        0x800710E0 { 'did not start: operator or system refused (logon/battery/condition)' }
        0x80070005 { 'access denied' }
        0x8007052E { 'bad user name or password (re-register with the new password)' }
        default    { 'see Task Scheduler history' }
    }
    if ($code -lt 256) { return ('{0} ({1})' -f $code, $meaning) }
    return ('0x{0:X8} ({1})' -f $code, $meaning)
}

function Get-CrmStatus {
    $rows = foreach ($t in $tasks) {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $t.Name -ErrorAction SilentlyContinue
        if (-not $task) {
            [pscustomobject]@{ Key = $t.Key; Task = $t.Name; State = 'not registered'; LastRun = $null; LastResult = ''; NextRun = $null }
            continue
        }
        $info = $task | Get-ScheduledTaskInfo
        [pscustomobject]@{
            Key        = $t.Key
            Task       = $t.Name
            State      = "$($task.State)"
            LastRun    = $info.LastRunTime
            LastResult = Format-TaskResult ([uint32]$info.LastTaskResult)
            NextRun    = $info.NextRunTime
        }
    }
    $legacy = @(Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue)
    foreach ($l in $legacy) {
        $info = $l | Get-ScheduledTaskInfo
        $rows += [pscustomobject]@{
            Key        = 'legacy'
            Task       = "$($l.TaskPath)$($l.TaskName)"
            State      = "$($l.State)"
            LastRun    = $info.LastRunTime
            LastResult = Format-TaskResult ([uint32]$info.LastTaskResult)
            NextRun    = $info.NextRunTime
        }
    }
    return $rows
}

function Show-CrmStatus {
    Write-Host ''
    Write-Host "Tasks in $TaskPath on $env:COMPUTERNAME ($(Get-Date -Format 'yyyy-MM-dd HH:mm'), $((Get-TimeZone).Id)):"
    Get-CrmStatus | Format-Table -AutoSize -Property Key, Task, State,
        @{ n = 'LastRun'; e = { if ($_.LastRun -and $_.LastRun.Year -gt 2000) { $_.LastRun.ToString('yyyy-MM-dd HH:mm') } else { '-' } } },
        LastResult,
        @{ n = 'NextRun'; e = { if ($_.NextRun) { $_.NextRun.ToString('yyyy-MM-dd HH:mm') } else { '-' } } } |
        Out-String -Width 200 | ForEach-Object { $_.TrimEnd() } | Write-Host
}

# Minimal KEY=VALUE read of etl\.env, the same rules push.ps1 uses. Values
# are checked, never printed.
function Read-DotEnv([string]$Path) {
    $vars = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $vars }
    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
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
        $vars[$key] = $val
    }
    return $vars
}

# Returns the problems with etl\.env as strings; empty = fine.
function Test-DotEnv {
    $problems = @()
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        return @(".env not found at $envFile - Copy-Item .env.example .env and fill it in (README: Moving to the BI server).")
    }
    $vars = Read-DotEnv $envFile
    foreach ($name in 'MSSQL_CONN', 'PG_CONN') {
        if (-not $vars.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($vars[$name])) {
            $problems += "$name is missing from .env."
            continue
        }
        $v = $vars[$name]
        if ($v -match 'YOURSERVER|YOURPROJECT|\*\*\*') {
            $problems += "$name still holds a .env.example placeholder."
        }
    }
    if ($vars.ContainsKey('PG_CONN') -and $vars['PG_CONN'] -match ':6543(/|$)') {
        $problems += 'PG_CONN is on port 6543 (transaction pooler); the loader needs the session pooler or direct connection on 5432.'
    }
    if ($vars.ContainsKey('MSSQL_CONN') -and $LogonType -eq 'S4U' -and $vars['MSSQL_CONN'] -match 'Trusted_Connection\s*=\s*yes') {
        $problems += 'MSSQL_CONN uses Trusted_Connection=yes but -LogonType S4U has no network credentials; use Password/gMSA or SQL auth.'
    }
    if (-not $vars.ContainsKey('ETL_ALERT_WEBHOOK') -or [string]::IsNullOrWhiteSpace($vars['ETL_ALERT_WEBHOOK'])) {
        Write-Warning 'ETL_ALERT_WEBHOOK is not set in .env: failed runs will only show in the log and in -Status, nobody is messaged.'
    }
    return $problems
}

function Assert-Elevated([string]$what) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Run this from an elevated (Administrator) PowerShell: $what needs it."
    }
}

# --- Checks that apply to every mode ----------------------------------------

$tz = (Get-TimeZone).Id
if ($tz -ne 'Mountain Standard Time') {
    Write-Warning "This machine's time zone is '$tz', not 'Mountain Standard Time'. The schedule is in server-clock time and assumes America/Denver: either change the time zone or the task times will be off."
}

$isGmsa = $User.EndsWith('$')
if ($LogonType -eq 'S4U') {
    $principalText = 'S4U (no stored password, NO network credentials)'
} elseif ($isGmsa) {
    $principalText = 'gMSA (password managed by AD)'
} else {
    $principalText = 'Password (prompted once, stored by Task Scheduler)'
}

$manage = $Status -or $Start -or $Enable -or $Disable

# --- Status only ---------------------------------------------------------------

if ($Status -and -not ($Start -or $Enable -or $Disable -or $Remove -or $DisableLegacyTask)) {
    Show-CrmStatus
    exit 0
}

# --- Enable / Disable / Start ----------------------------------------------------

if ($manage -and -not $Remove) {
    if (-not $WhatIfPreference) { Assert-Elevated 'changing or starting a task' }
    foreach ($pair in @(@('Enable', $Enable), @('Disable', $Disable), @('Start', $Start))) {
        $verb = $pair[0]; $key = $pair[1]
        if (-not $key) { continue }
        $t = Get-CrmTask $key
        $existing = Get-ScheduledTask -TaskPath $TaskPath -TaskName $t.Name -ErrorAction SilentlyContinue
        if (-not $existing) { throw "'$($t.Name)' is not registered in $TaskPath on this machine. Run the script without -$verb first." }
        if (-not $PSCmdlet.ShouldProcess("$TaskPath$($t.Name)", $verb)) { continue }
        switch ($verb) {
            'Enable'  { $existing | Enable-ScheduledTask | Out-Null;  Write-Host "enabled   $($t.Name)" }
            'Disable' { $existing | Disable-ScheduledTask | Out-Null; Write-Host "disabled  $($t.Name)" }
            'Start'   {
                if ($existing.State -eq 'Running') {
                    Write-Host "already running  $($t.Name) - not started again (IgnoreNew)"
                } else {
                    $existing | Start-ScheduledTask
                    Write-Host "started   $($t.Name) - follow it in $EtlDir\$(@{ full0430 = 'push.log'; full1700 = 'push.log'; hourly = 'push-hourly.log'; ats = 'push-ats.log' }[$key])"
                }
            }
        }
    }
}

# --- Plan ----------------------------------------------------------------------

if (-not $manage) {
    Write-Host ''
    if ($Remove) {
        Write-Host "Plan: REMOVE these tasks from $TaskPath"
        foreach ($t in $tasks) { Write-Host "  $($t.Name)" }
    } else {
        Write-Host "Plan: register in $TaskPath as $User - logon $principalText"
        Write-Host "  action:   $PowerShellExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$pushScript`" <args>"
        Write-Host "  start in: $EtlDir"
        Write-Host "  .env:     $envFile"
        foreach ($t in $tasks) {
            $when = if ($t.Schedule -eq 'Daily') { "daily $($t.At)" } else { "Mon-Fri $($t.At)" }
            if ($t.Every) { $when += " every $(Format-Span $t.Every) for $(Format-Span $t.For)" }
            $catch = if ($t.CatchUp) { 'catch up a missed start' } else { 'no catch-up' }
            Write-Host ("  {0,-9} {1,-22} {2,-26} {3,-44} limit {4}, {5}" -f $t.Key, $t.Name, $t.Arguments, $when, (Format-Span $t.Limit), $catch)
        }
    }
    if ($DisableLegacyTask) { Write-Host "  and disable the legacy task '$LegacyTaskName' if it exists" }
    Write-Host ''
}

# --- Preflight (register only) ---------------------------------------------------

if (-not $manage -and -not $Remove) {
    $problems = @()
    if (-not (Test-Path -LiteralPath $pushScript)) { $problems += "push.ps1 not found at $pushScript - pass -EtlDir." }
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        Write-Warning "venv\Scripts\python.exe not found under $EtlDir - the tasks will exit 103 (and alert) until it exists (README: Moving to the BI server)."
    }
    $problems += Test-DotEnv
    if ($problems.Count -gt 0) {
        if ($WhatIfPreference) {
            foreach ($p in $problems) { Write-Warning $p }
        } else {
            throw ("Fix these before registering:`n  " + ($problems -join "`n  "))
        }
    }
}

if ($WhatIfPreference) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Warning 'Not elevated: a real run must be from an elevated prompt.' }
    Write-Host 'WhatIf: nothing was changed.'
    Show-CrmStatus
    exit 0
}

# --- Remove ----------------------------------------------------------------------

if ($Remove) {
    Assert-Elevated 'removing the tasks'
    foreach ($t in $tasks) {
        $existing = Get-ScheduledTask -TaskPath $TaskPath -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $t.Name -Confirm:$false
            Write-Host "removed  $($t.Name)"
        } else {
            Write-Host "absent   $($t.Name)"
        }
    }
}

# --- Register --------------------------------------------------------------------

if (-not $manage -and -not $Remove) {
    Assert-Elevated 'registering tasks for another account'

    $principal = $null
    $credential = $null
    if ($LogonType -eq 'S4U') {
        $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited
    } elseif ($isGmsa) {
        $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Password -RunLevel Limited
    } else {
        $credential = Get-Credential -UserName $User -Message "Windows password for $User (stored by Task Scheduler, not by this script). Not the SQL or Supabase password."
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
            WakeToRun                  = [bool]$t.CatchUp
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
}

# --- Legacy task -------------------------------------------------------------------

if ($DisableLegacyTask) {
    Assert-Elevated 'disabling the legacy task'
    $legacy = @(Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue)
    if ($legacy.Count -eq 0) {
        Write-Host "legacy task '$LegacyTaskName' not found on this machine - disable it on the PC that runs it."
    } else {
        foreach ($l in $legacy) {
            if ($PSCmdlet.ShouldProcess("$($l.TaskPath)$($l.TaskName)", 'Disable')) {
                $l | Disable-ScheduledTask | Out-Null
                Write-Host "disabled legacy task $($l.TaskPath)$($l.TaskName)"
            }
        }
    }
}

Show-CrmStatus
