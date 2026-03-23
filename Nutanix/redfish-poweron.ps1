<#
.SYNOPSIS
    Starts MULTIPLE Nutanix Hosts via Redfish API.
    Supports all generations (G5, G8, G9) by using Session-based auth
    with Basic Auth fallback for older BMCs.
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

# --- Functions ---
function Write-Log {
    param (
        [string]$Message,
        [ConsoleColor]$Color = "White"
    )
    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "$($Time): $Message"
    Write-Host $LogLine -ForegroundColor $Color
    try {
        Add-Content -Path $LogFile -Value $LogLine -ErrorAction Stop
    } catch {
        Write-Warning "Could not write to log file: $_"
    }
}

function Connect-RedfishSession {
    param ([string]$TargetIp)

    # Try Session-based auth first (required by G8/G9)
    $SessionUri = "https://$TargetIp/redfish/v1/SessionService/Sessions"
    $SessionBody = @{ UserName = $Username; Password = $Password } | ConvertTo-Json

    try {
        $Response = Invoke-WebRequest -Uri $SessionUri -Method Post `
            -Body $SessionBody -ContentType "application/json" -ErrorAction Stop -UseBasicParsing

        $Token = $Response.Headers["X-Auth-Token"]
        $LocationHeader = $Response.Headers["Location"]

        if ($Token) {
            # Build session delete URI
            if ($LocationHeader -match "^http") {
                $SessionDeleteUri = $LocationHeader
            } elseif ($LocationHeader) {
                $SessionDeleteUri = "https://$TargetIp$LocationHeader"
            } else {
                # Parse from response body as fallback
                $Body = $Response.Content | ConvertFrom-Json
                if ($Body.'@odata.id') {
                    $SessionDeleteUri = "https://$TargetIp$($Body.'@odata.id')"
                }
            }

            Write-Log "Host:$TargetIp Auth:Session Token OK" "Green"
            return @{
                Headers = @{ "X-Auth-Token" = $Token; "Content-Type" = "application/json" }
                AuthMethod = "Session"
                SessionUri = $SessionDeleteUri
                Token = $Token
            }
        }
    }
    catch {
        Write-Log "Host:$TargetIp Session auth not available, trying Basic Auth..." "Yellow"
    }

    # Fallback to Basic Auth (works on G5)
    $Base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))
    $BasicHeaders = @{ Authorization = "Basic $Base64Auth"; "Content-Type" = "application/json" }

    # Verify Basic Auth works
    try {
        $null = Invoke-RestMethod -Uri "https://$TargetIp/redfish/v1/Systems" `
            -Method Get -Headers $BasicHeaders -ErrorAction Stop
        Write-Log "Host:$TargetIp Auth:Basic Auth OK" "Green"
        return @{
            Headers = $BasicHeaders
            AuthMethod = "Basic"
            SessionUri = $null
            Token = $null
        }
    }
    catch {
        Write-Log "Host:$TargetIp Auth:FAILED - Check credentials ($($_.Exception.Message))" "Red"
        return $null
    }
}

function Disconnect-RedfishSession {
    param ([hashtable]$AuthInfo, [string]$TargetIp)

    if ($AuthInfo -and $AuthInfo.AuthMethod -eq "Session" -and $AuthInfo.SessionUri) {
        try {
            $DeleteHeaders = @{ "X-Auth-Token" = $AuthInfo.Token }
            $null = Invoke-RestMethod -Uri $AuthInfo.SessionUri -Method Delete `
                -Headers $DeleteHeaders -ErrorAction Stop
            Write-Log "Host:$TargetIp Session cleaned up" "Gray"
        }
        catch {
            Write-Log "Host:$TargetIp Session cleanup failed (non-critical): $($_.Exception.Message)" "Gray"
        }
    }
}

function Get-RedfishSystemPath {
    param ([string]$TargetIp, [hashtable]$Headers)
    $Uri = "https://$TargetIp/redfish/v1/Systems"
    try {
        $Response = Invoke-RestMethod -Uri $Uri -Method Get -Headers $Headers -ErrorAction Stop
        if ($Response.Members.Count -gt 0) {
            $Path = $Response.Members[0].'@odata.id'
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
    param ([string]$TargetIp, [hashtable]$Headers)
    $SystemUri = Get-RedfishSystemPath -TargetIp $TargetIp -Headers $Headers
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
    param ([string]$TargetIp, [hashtable]$Headers)
    $SystemUri = Get-RedfishSystemPath -TargetIp $TargetIp -Headers $Headers
    if ([string]::IsNullOrEmpty($SystemUri)) { return $false }
    $ActionUri = "$SystemUri/Actions/ComputerSystem.Reset"
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
$HostAuth = @{}

try {
    # STEP 1: AUTHENTICATE AND INITIAL CHECK
    foreach ($Ip in $TargetList) {
        # Check Ping first
        if (-not (Test-Connection -ComputerName $Ip -Count 1 -Quiet)) {
            Write-Log "Host:$Ip State:Unreachable (Ping Fail)" "Red"
            $HostTracker[$Ip] = "Unreachable"
            continue
        }

        # Authenticate per host
        $Auth = Connect-RedfishSession -TargetIp $Ip
        if (-not $Auth) {
            $HostTracker[$Ip] = "AuthFailed"
            continue
        }
        $HostAuth[$Ip] = $Auth

        $State = Get-HostPowerState -TargetIp $Ip -Headers $Auth.Headers
        if ($State -eq "On") {
            Write-Log "Host:$Ip State:Already On" "Green"
            $HostTracker[$Ip] = "On"
        }
        elseif ($State -eq "Error") {
            Write-Log "Host:$Ip State:API Error (Check Credentials/Network)" "Red"
            $HostTracker[$Ip] = "Error"
        }
        else {
            Write-Log "Host:$Ip State:$State -> Action:Startup" "Yellow"
            $Result = Start-HostPower -TargetIp $Ip -Headers $Auth.Headers

            if ($Result) {
                $HostTracker[$Ip] = "Booting"
            } else {
                $HostTracker[$Ip] = "FailedTrigger"
            }
        }
    }

    # STEP 2: MONITOR BOOT
    $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log "Monitoring active boot processes..." "Cyan"
    do {
        $PendingCount = 0
        Start-Sleep -Seconds 5
        $Elapsed = [math]::Round($StopWatch.Elapsed.TotalSeconds, 0)

        foreach ($Ip in $TargetList) {
            if ($HostTracker[$Ip] -eq "Booting") {
                $Auth = $HostAuth[$Ip]
                $NewState = Get-HostPowerState -TargetIp $Ip -Headers $Auth.Headers

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
}
finally {
    # STEP 3: CLEANUP SESSIONS
    foreach ($Ip in $HostAuth.Keys) {
        Disconnect-RedfishSession -AuthInfo $HostAuth[$Ip] -TargetIp $Ip
    }
}
