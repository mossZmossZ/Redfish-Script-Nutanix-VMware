<#
.SYNOPSIS
    Starts MULTIPLE Nutanix Hosts via Redfish API.
#>
# --- Configuration ---
$TargetList = @(
    "172.18.13.104",
    "172.18.13.105"
)
$Username = "ADMIN"
$Password = "ADMIN"
$TimeoutSeconds = 300 
$LogFile = ".\nutanix-auto-start.log"
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
$CsharpCode = @"
    using System;
    using System.Net;
    using System.Net.Security;
    using System.Security.Cryptography.X509Certificates;
    public static class SSLHandler {
        public static void Ignore() {
            ServicePointManager.ServerCertificateValidationCallback = (s, c, ch, e) => true;
        }
    }
"@
try { Add-Type -TypeDefinition $CsharpCode -Language CSharp } catch { }
[SSLHandler]::Ignore()

$Base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))
$Headers = @{ Authorization = "Basic $Base64Auth"; "Content-Type" = "application/json" }

# --- Functions ---
function Write-Log {
    param (
        [string]$Message,
        [ConsoleColor]$Color = "White"
    )
    $Time = Get-Date -Format "HH:mm:ss"
    $LogLine = "$($Time): $Message"
    Write-Host $LogLine -ForegroundColor $Color
    try {
        Add-Content -Path $LogFile -Value $LogLine -ErrorAction Stop
    } catch {
        Write-Warning "Could not write to log file: $_"
    }
}
function Get-RedfishSystemPath {
    param ([string]$TargetIp)  
    $Uri = "https://$TargetIp/redfish/v1/Systems"
    try {
        $Response = Invoke-RestMethod -Uri $Uri -Method Get -Headers $Headers -ErrorAction Stop
        if ($Response.Members.Count -gt 0) {
            # Extract the @odata.id (e.g., "/redfish/v1/Systems/System")
            $Path = $Response.Members[0].'@odata.id'
            
            # Sanitize path to ensure full URL
            if ($Path -match "^http") { return $Path }
            return "https://$TargetIp$Path"
        }
        Write-Log "Error: No System Members found at $TargetIp" "Red"
        return $null
    }
    catch {
        Write-Log "API Discovery Failed [$TargetIp]: $($_.Exception.Message)" "Magenta"
        return $null
    }
}
function Get-HostPowerState {
    param ([string]$TargetIp)
    $SystemUri = Get-RedfishSystemPath -TargetIp $TargetIp
    if ([string]::IsNullOrEmpty($SystemUri)) { return "Error" }
    try {
        $Response = Invoke-RestMethod -Uri $SystemUri -Method Get -Headers $Headers -ErrorAction Stop
        return $Response.PowerState
    }
    catch { 
        return "Error" 
    }
}
function Start-HostPower {
    param ([string]$TargetIp)
    $SystemUri = Get-RedfishSystemPath -TargetIp $TargetIp
    if ([string]::IsNullOrEmpty($SystemUri)) { return $false }
    # Construct Action URI
    # Note: Gen 8/9 usually uses standard 'ComputerSystem.Reset'
    $ActionUri = "$SystemUri/Actions/ComputerSystem.Reset" 
    # 'On' is standard. If Gen 8 fails, try 'ForceOn' or 'PushPowerButton'
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
Write-Log "--- Nutanix Cluster Startup By ZenithComp ---" "Cyan"
Write-Log "Targets: $($TargetList -join ', ')" "Cyan"

$HostTracker = @{}
# STEP 1: INITIAL CHECK AND TRIGGER
foreach ($Ip in $TargetList) {
    # Check Ping first
    if (-not (Test-Connection -ComputerName $Ip -Count 1 -Quiet)) {
        Write-Log "Host:$Ip State:Unreachable (Ping Fail)" "Red"
        $HostTracker[$Ip] = "Unreachable"
        continue
    }

    $State = Get-HostPowerState -TargetIp $Ip
    if ($State -eq "On") {
        Write-Log "Host:$Ip State:Already On" "Green"
        $HostTracker[$Ip] = "On"
    }
    elseif ($State -eq "Error") {
        Write-Log "Host:$Ip State:API Error (Check Credentials/Network)" "Red"
        $HostTracker[$Ip] = "Error"
    }
    else {
        # Valid state (Off, PoweringOff, etc.)
        Write-Log "Host:$Ip State:$State -> Action:Startup" "Yellow"
        $Result = Start-HostPower -TargetIp $Ip
        
        if ($Result) {
            $HostTracker[$Ip] = "Booting"
        } else {
            $HostTracker[$Ip] = "FailedTrigger"
        }
    }
}

$StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
Write-Log "Monitoring active boot processes..." "Cyan"
do {
    $PendingCount = 0
    Start-Sleep -Seconds 5
    $Elapsed = [math]::Round($StopWatch.Elapsed.TotalSeconds, 0)

    foreach ($Ip in $TargetList) {
        if ($HostTracker[$Ip] -eq "Booting") {
            $NewState = Get-HostPowerState -TargetIp $Ip
            
            Write-Log "[$Elapsed sec] Host:$Ip State:$NewState" "Gray"

            if ($NewState -eq "On") {
                $HostTracker[$Ip] = "On"
                Write-Log "Host:$Ip State:ONLINE (Complete)" "Green"
            } else {
                $PendingCount++
            }
        }
    }
    if ($PendingCount -eq 0) {
        Write-Log "All targeted hosts are ONLINE." "Green"
        break
    }
} while ($StopWatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
if ($PendingCount -gt 0) {
    Write-Log "TIMEOUT REACHED. Some hosts did not report 'On' state." "Red"
} else {
    Write-Log "Execution Finished." "Cyan"
}