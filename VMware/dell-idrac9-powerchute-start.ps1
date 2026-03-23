<#
.SYNOPSIS
    Starts Dell Hosts via iDRAC9 Redfish API.
#>
$TargetList = @(
    "10.38.22.64"
)
$Username = "root"  #iDRAC username
$Password = "P@ssw0rd" #iDRAC password
$TimeoutSeconds = 300 
$LogFile = ".\idrac9-auto-start.log"

# Setup Security Protocols
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$CsharpCode = @"
    using System.Net;
    using System.Net.Security;
    public static class SSLHandler {
        public static void Ignore() {
            ServicePointManager.ServerCertificateValidationCallback = (s, c, ch, e) => true;
        }
    }
"@
try { Add-Type -TypeDefinition $CsharpCode -Language CSharp } catch { }
[SSLHandler]::Ignore()
$Base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))
$Headers = @{ 
    Authorization = "Basic $Base64Auth"
    "Content-Type" = "application/json"
    "Accept"       = "application/json"
}
# --- Functions ---
function Write-Log {
    param (
        [string]$Message,
        [ConsoleColor]$Color = "White"
    )
    $Time = Get-Date -Format "HH:mm:ss"
    $LogLine = "$($Time): $Message"
    Write-Host $LogLine -ForegroundColor $Color
    try { Add-Content -Path $LogFile -Value $LogLine -ErrorAction SilentlyContinue } catch {}
}
function Get-iDRACSystemPath {
    param ([string]$TargetIp)  
    # iDRAC9 typically maps the main system to /redfish/v1/Systems/System.Embedded.1
    $Uri = "https://$TargetIp/redfish/v1/Systems"
    try {
        $Response = Invoke-RestMethod -Uri $Uri -Method Get -Headers $Headers -ErrorAction Stop
        if ($Response.Members.Count -gt 0) {
            $Path = $Response.Members[0].'@odata.id'
            return "https://$TargetIp$Path"
        }
        return $null
    }
    catch {
        Write-Log "API Discovery Failed [$TargetIp]: $($_.Exception.Message)" "Magenta"
        return $null
    }
}

function Get-HostPowerState {
    param ([string]$TargetIp)
    $SystemUri = Get-iDRACSystemPath -TargetIp $TargetIp
    if (-not $SystemUri) { return "Error" }
    try {
        $Response = Invoke-RestMethod -Uri $SystemUri -Method Get -Headers $Headers -ErrorAction Stop
        return $Response.PowerState # Returns 'On' or 'Off'
    }
    catch { return "Error" }
}
function Start-HostPower {
    param ([string]$TargetIp)
    $SystemUri = Get-iDRACSystemPath -TargetIp $TargetIp
    if (-not $SystemUri) { return $false }

    # iDRAC9 Redfish Action URL
    $ActionUri = "$SystemUri/Actions/ComputerSystem.Reset"
    # ResetType "On" powers the system on if it is currently off.
    $Body = @{ ResetType = "On" } | ConvertTo-Json
    try {
        $null = Invoke-RestMethod -Uri $ActionUri -Method Post -Headers $Headers -Body $Body -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log "Host:$TargetIp Start Action Failed: $($_.Exception.Message)" "Red"
        return $false
    }
}

# --- Main Execution ---
Clear-Host
Write-Log "--- Dell iDRAC9 Startup ---" "Cyan"

$HostTracker = @{}
foreach ($Ip in $TargetList) {
    # 1. Network Check
    if (-not (Test-Connection -ComputerName $Ip -Count 1 -Quiet)) {
        Write-Log "Host:$Ip State:Unreachable (Ping Fail)" "Red"
        $HostTracker[$Ip] = "Unreachable"
        continue
    }
    # 2. Power Check
    $State = Get-HostPowerState -TargetIp $Ip
    if ($State -eq "On") {
        Write-Log "Host:$Ip State:Already On" "Green"
        $HostTracker[$Ip] = "On"
    }
    elseif ($State -eq "Error") {
        Write-Log "Host:$Ip State:iDRAC API Error" "Red"
        $HostTracker[$Ip] = "Error"
    }
    else {
        # 3. Trigger Power On
        Write-Log "Host:$Ip State:$State -> Action:Powering On" "Yellow"
        if (Start-HostPower -TargetIp $Ip) {
            $HostTracker[$Ip] = "Booting"
        } else {
            $HostTracker[$Ip] = "FailedTrigger"
        }
    }
}

# 4. Monitoring Loop
$StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
Write-Log "Monitoring boot progress..." "Cyan"

do {
    $PendingCount = 0
    Start-Sleep -Seconds 10 # iDRAC status updates slightly slower than Nutanix/IPMI
    $Elapsed = [math]::Round($StopWatch.Elapsed.TotalSeconds, 0)

    foreach ($Ip in $TargetList) {
        if ($HostTracker[$Ip] -eq "Booting") {
            $NewState = Get-HostPowerState -TargetIp $Ip
            Write-Log "[$Elapsed sec] Host:$Ip Current State: $NewState" "Gray"

            if ($NewState -eq "On") {
                $HostTracker[$Ip] = "On"
                Write-Log "Host:$Ip State:ONLINE" "Green"
            } else {
                $PendingCount++
            }
        }
    }

    if ($PendingCount -eq 0) { break }

} while ($StopWatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)

# Final Summary
$SuccessCount = ($HostTracker.Values | Where-Object { $_ -eq "On" }).Count
Write-Log "--- Execution Finished ---" "Cyan"
Write-Log "Hosts Online: $SuccessCount / $($TargetList.Count)" "Cyan"

if ($PendingCount -gt 0) {
    Write-Log "Warning: Some hosts timed out or failed to start." "Red"
}