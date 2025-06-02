# === Configuration ===
$Port = 61616
$LogDir = "$PSScriptRoot\FirewallPortAuditLogs"
$TimeStamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$LogFile = Join-Path $LogDir "FirewallPort61616Log_$TimeStamp.txt"
$EventLogSource = "FirewallPortAudit"

# === Email Settings ===
$SmtpSettings = @{
    SmtpServer = ""        # Example: "smtp.yourdomain.com"
    From       = ""        # Example: "firewall-audit@yourdomain.com"
    To         = ""        # Example: "admin@yourdomain.com"
    Subject    = "Firewall Rule Changed on $env:COMPUTERNAME"
}

# === Teams Webhook ===
$TeamsWebhookUrl = ""      # Example: "https://outlook.office.com/webhook/..."

# === Host Info ===
$Hostname = $env:COMPUTERNAME
$User = $env:USERNAME
$IPAddress = (Get-NetIPAddress -AddressFamily IPv4 |
              Where-Object {$_.InterfaceAlias -notmatch 'Loopback'} |
              Select-Object -First 1 -ExpandProperty IPAddress)

# === Ensure log dir and event source exist ===
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
if (-not [System.Diagnostics.EventLog]::SourceExists($EventLogSource)) {
    New-EventLog -LogName Application -Source $EventLogSource
}

function Write-Log {
    param([string]$Message)
    $logEntry = "[{0}] [User: {1}] [Host: {2}] [IP: {3}] {4}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $User, $Hostname, $IPAddress, $Message
    $logEntry | Out-File -FilePath $LogFile -Append
    Write-EventLog -LogName Application -Source $EventLogSource -EntryType Information -EventId 1001 -Message $logEntry
    Write-Host $logEntry
}

function Send-Email {
    param ([string]$Body)
    if ($SmtpSettings.SmtpServer -and $SmtpSettings.To -and $SmtpSettings.From) {
        try {
            Send-MailMessage @SmtpSettings -Body $Body -BodyAsHtml
        } catch {
            Write-Log "Failed to send email: $_"
        }
    } else {
        Write-Log "Email notification skipped: SMTP settings incomplete."
    }
}

function Send-TeamsAlert {
    param([string]$Text)
    if ($TeamsWebhookUrl) {
        try {
            $payload = @{
                "@type"    = "MessageCard"
                "@context" = "http://schema.org/extensions"
                summary    = "Firewall Rule Change"
                themeColor = "0072C6"
                title      = "Firewall Rule Changed"
                sections   = @(@{
                    activityTitle    = "Firewall Rule Changed on $Hostname"
                    activitySubtitle = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    facts            = @(
                        @{ name = "User"; value = $User },
                        @{ name = "Host"; value = $Hostname },
                        @{ name = "IP"; value = $IPAddress },
                        @{ name = "Details"; value = $Text }
                    )
                    markdown = $true
                })
            }
            Invoke-RestMethod -Uri $TeamsWebhookUrl -Method Post -Body (ConvertTo-Json $payload -Depth 4) -ContentType 'application/json'
        } catch {
            Write-Log "Failed to send Teams alert: $_"
        }
    } else {
        Write-Log "Teams alert skipped: Webhook URL not set."
    }
}

# === Begin Script ===
Import-Module NetSecurity -ErrorAction Stop
Write-Log "=== Starting firewall port $Port rule audit ==="

$activeProfiles = Get-NetConnectionProfile | Where-Object {$_.IPv4Connectivity -ne 'Disconnected'}
$profileNames = $activeProfiles | Select-Object -ExpandProperty NetworkCategory

if (-not $profileNames) {
    Write-Log "No active firewall profiles detected. Exiting."
    return
}

Write-Log "Active firewall profiles: $($profileNames -join ', ')"

# Collect matching firewall rules
$rules = Get-NetFirewallRule | Where-Object {
    $_.Enabled -eq 'True' -and
    $_.Direction -in @('Inbound', 'Outbound') -and
    $_.Profile -match ($profileNames -join '|')
} | ForEach-Object {
    $rule = $_
    $filters = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule
    foreach ($filter in $filters) {
        if ($filter.Port -eq $Port -and $filter.Protocol -eq 'TCP') {
            [PSCustomObject]@{
                Name      = $rule.Name
                Action    = $rule.Action
                Direction = $rule.Direction
                Rule      = $rule
                Profiles  = $rule.Profile
            }
        }
    }
}

$changesMade = @()

if ($rules) {
    Write-Log "Found existing firewall rules affecting TCP port $Port:"
    foreach ($r in $rules) {
        Write-Log " - [$($r.Direction)] $($r.Name) => $($r.Action)"
    }

    foreach ($r in $rules) {
        $swap = Read-Host "Toggle '$($r.Name)' from $($r.Action) to $(if ($r.Action -eq 'Allow') {'Block'} else {'Allow'})? (Y/N)"
        if ($swap -match '^[Yy]') {
            $oldAction = $r.Action
            $newAction = if ($oldAction -eq 'Allow') {'Block'} else {'Allow'}
            Set-NetFirewallRule -Name $r.Name -Action $newAction
            $msg = "Toggled rule '$($r.Name)': $oldAction → $newAction (Direction: $($r.Direction), Profiles: $($r.Profiles))"
            Write-Log $msg
            $changesMade += $msg
        } else {
            Write-Log "Skipped toggling rule '$($r.Name)'"
        }
    }
} else {
    Write-Log "No rules found for TCP port $Port in active profiles."
    $create = Read-Host "Create bi-directional BLOCK rule for port $Port? (Y/N)"
    if ($create -match '^[Yy]') {
        $baseName = "Block_Port_$Port"
        foreach ($dir in @('Inbound', 'Outbound')) {
            $ruleName = "$baseName`_$dir"
            New-NetFirewallRule -DisplayName "$baseName ($dir)" `
                                -Name $ruleName `
                                -Direction $dir `
                                -Profile ($profileNames -join ',') `
                                -Action Block `
                                -Enabled True `
                                -Protocol TCP `
                                -LocalPort $Port
            $msg = "Created rule '$ruleName': Block $dir on TCP $Port (Profiles: $($profileNames -join ', '))"
            Write-Log $msg
            $changesMade += $msg
        }
    } else {
        Write-Log "User declined to create rule for port $Port."
    }
}

Write-Log "=== Script completed ==="

# === Send notifications if changes occurred ===
if ($changesMade.Count -gt 0) {
    $logText = $changesMade -join "<br>`n"
    Send-Email -Body "<strong>Firewall Rule Changes on $Hostname ($IPAddress)</strong><br><br>$logText"
    Send-TeamsAlert -Text ($changesMade -join "`n")
}