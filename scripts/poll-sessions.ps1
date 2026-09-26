<#
.SYNOPSIS
    Poll HTTP session counts and JVM heap usage from a JBoss EAP domain during a
    load test, and write one CSV row per host every interval.

.DESCRIPTION
    PowerShell version of poll-sessions.sh, for Windows. Works in Windows
    PowerShell 5.1 and PowerShell 7+, with no extra modules.

    Uses the domain controller's HTTP management API (digest authentication).
    The management user needs at least the Monitor role.

    Credentials come from the JBOSS_MGMT_USER and JBOSS_MGMT_PASS environment
    variables if both are set; otherwise you are prompted for them.

    Columns:
      time, host, active_sessions, sessions_created, expired_sessions,
      rejected_sessions, highest_session_count, heap_used_mb, heap_max_mb
    An empty value means that read failed (e.g. the server was stopped for a
    failover test); the reason is shown as a warning on the console, and
    polling carries on. Stop with Ctrl+C.

.EXAMPLE
    .\scripts\poll-sessions.ps1 -Controller dc-host:9990 -Deployment app.war -Hosts node1,node2 -OutFile sessions.csv

.EXAMPLE
    $env:JBOSS_MGMT_USER = 'monitor-user'; $env:JBOSS_MGMT_PASS = '...'
    .\scripts\poll-sessions.ps1 -Controller dc-host:9990 -Deployment app.war -Hosts node1,node2 -Server server-one -IntervalSeconds 30 -OutFile sessions.csv
#>
param(
    [string]$Controller = 'localhost:9990',
    [Parameter(Mandatory = $true)][string]$Deployment,
    [Parameter(Mandatory = $true)][string[]]$Hosts,
    [string]$Server = 'server-one',
    [int]$IntervalSeconds = 30,
    # CSV file to append to. Rows are also printed to the console.
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

# "-Hosts node1,node2" arrives as one string when run via "powershell -File".
$Hosts = @($Hosts | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($env:JBOSS_MGMT_USER -and $env:JBOSS_MGMT_PASS) {
    $password = ConvertTo-SecureString $env:JBOSS_MGMT_PASS -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($env:JBOSS_MGMT_USER, $password)
} else {
    $credential = Get-Credential -Message "JBoss management user for $Controller"
}

$uri = "http://$Controller/management"

function Invoke-Mgmt([hashtable]$Operation) {
    $params = @{
        Uri         = $uri
        Method      = 'Post'
        ContentType = 'application/json'
        Body        = ($Operation | ConvertTo-Json -Depth 5 -Compress)
        Credential  = $credential
        TimeoutSec  = 10
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # PowerShell 7 refuses to send credentials over plain HTTP unless told to.
        $params.AllowUnencryptedAuthentication = $true
    }
    Invoke-RestMethod @params
}

function Get-ServerAddress([string]$HostName) {
    @(@{ host = $HostName }, @{ server = $Server })
}

function Format-Value($Value) {
    if ($null -eq $Value) { '' } else { "$Value" }
}

function Write-Row([string]$Line) {
    Write-Output $Line
    if ($OutFile) { Add-Content -Path $OutFile -Value $Line -Encoding ASCII }
}

Write-Row 'time,host,active_sessions,sessions_created,expired_sessions,rejected_sessions,highest_session_count,heap_used_mb,heap_max_mb'

while ($true) {
    $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    foreach ($hostName in $Hosts) {
        $serverAddress = Get-ServerAddress $hostName

        try {
            $r = (Invoke-Mgmt @{
                operation         = 'read-resource'
                'include-runtime' = $true
                address           = $serverAddress + @(@{ deployment = $Deployment }, @{ subsystem = 'undertow' })
            }).result
            $sessions = (@(
                $r.'active-sessions', $r.'sessions-created', $r.'expired-sessions',
                $r.'rejected-sessions', $r.'highest-session-count'
            ) | ForEach-Object { Format-Value $_ }) -join ','
        } catch {
            Write-Warning "$hostName sessions: $($_.Exception.Message)"
            $sessions = ',,,,'
        }

        try {
            $m = (Invoke-Mgmt @{
                operation = 'read-attribute'
                name      = 'heap-memory-usage'
                address   = $serverAddress + @(@{ 'core-service' = 'platform-mbean' }, @{ type = 'memory' })
            }).result
            if ($null -eq $m) { throw 'no heap result' }
            $heap = '{0},{1}' -f [math]::Floor($m.used / 1MB), [math]::Floor($m.max / 1MB)
        } catch {
            Write-Warning "$hostName heap: $($_.Exception.Message)"
            $heap = ','
        }

        Write-Row "$now,$hostName,$sessions,$heap"
    }
    Start-Sleep -Seconds $IntervalSeconds
}
