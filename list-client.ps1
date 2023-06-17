<#
function Send-Message($WebSocket, $Message) {
    $ByteStream = [System.Text.Encoding]::UTF8.GetBytes($Message)
    $MessageStream = New-Object System.ArraySegment[byte] -ArgumentList @(,$ByteStream)      

    $SendConn = $webSocket.SendAsync($MessageStream, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cancellationToken)

    While (-Not($SendConn.IsCompleted)) { 
        Start-Sleep -Milliseconds 500 
        Write-Host "Still waiting for send to complete." 
    }

    Write-Host "Sent message."
}
#>
function IsContainer() {
    $IsContainer = $false

    try {
        # Attempt dns resolution of internal kubernetes service
        $InternalServer = "kubernetes.default.svc";
        [System.Net.Dns]::GetHostAddresses($InternalServer)

        $IsContainer = $true
    } catch { }

    return $IsContainer
}

function CheckRequiredEnvironmentVariables($Required) {
    foreach ($Req in $Required) {
        if ([Environment]::GetEnvironmentVariable($Req).Length -eq 0) {
            throw "Abort, missing environment variable: $Req"
        }
    }
}

# Verify required environment variables have been set
$Required = @(
    "API_KEY"
)
CheckRequiredEnvironmentVariables($Required)

# Configure target servers based on whether we are inside a container or not
if (IsContainer) {
    Write-Host "IsContainer: true"

    $Proto = "http"
    $ListServer = "list.list.svc"
    $WebSocketServer = "list.list.svc"
    $WebSocketUri = "ws://$($WebSocketServer)/ws?api_key=$($Env:API_KEY)"
}
else {
    Write-Host "IsContainer: false"

    $Proto = "https"
    $ListServer = "list.vc-non.k.home.net"
    $WebSocketServer = "list.vc-non.k.home.net"
    $WebSocketUri = "wss://$($WebSocketServer)/ws?api_key=$($Env:API_KEY)"
}

# Debug output
Write-Host "API_KEY: $($Env:API_KEY)"
Write-Host "ListServer: $($ListServer)"
Write-Host "WebSocketServer: $($WebSocketUri)"

# Declare
$WebSocket = New-Object System.Net.WebSockets.ClientWebSocket
$CancellationToken = New-Object System.Threading.CancellationToken
$WebSocket.Options.UseDefaultCredentials = $true

# Get connected
$Connection = $WebSocket.ConnectAsync($WebSocketUri, $CancellationToken)

# Establish connection to websocket
Write-Host "Connecting to websocket ..." 
While (-Not($Connection.IsCompleted)) { 
    Start-Sleep -Milliseconds 100 
}

# Debug output
Write-Host "Connected."


# Main
try {

# track multiple lists
$Lists = @{}

# check if there are already lists to process
Write-Host "$($Proto)://$($ListServer)/list"
$Items = Invoke-RestMethod `
        -Method Get `
        -Headers @{ "X-API-KEY" = $Env:API_KEY } `
        "$($Proto)://$($ListServer)/list"

# if so, acquire the state of each list to see if it is active
foreach ($Item in $Items) {
    Write-Host "list: $($Item)"

    # get list details
    $List = Invoke-RestMethod `
            -Method Get `
            -Headers @{ "X-API-KEY" = $Env:API_KEY } `
            "$($Proto)://$($ListServer)/list?list=$($Item)"

    # if active, add list to be processed
    if ($List.state -eq "active") {
        Write-Host "adding: $($List.state)"

        # track this list
        $Lists[$Item] = $List.state
    }
    else {
        Write-Host "ignoring: $($List.state)"
    }
}

# Loop long as connection exists
while ($WebSocket.State -eq "Open") {
    # Reset recv array
    $Size = 1024
    $Array = [byte[]] @(,0) * $Size

    # Watch for new data from socket
    $Recv = New-Object System.ArraySegment[byte] -ArgumentList @(,$Array)
    $Connection = $WebSocket.ReceiveAsync($Recv, $CancellationToken)
    while (!$Connection.IsCompleted) { 
        # While we wait for new data work on lists
        foreach ($List in $Lists.Keys) {
            # Check for backoff & check if backoff interval has passed
            if ($Lists[$List] -ne "active") {
                # If backoff interval has passed, set as active again
                if ((Get-Date) -gt $Lists[$List]) {
                    $Lists[$List] = "active"

                    # Restart foreach to avoid 'Collection was modified' exception
                    break
                }
                else {
                    # Otherwise skip until backoff interval has passed
                    continue
                }
            }

            try {
                # Get a block to work on
                $Block = Invoke-RestMethod `
                        -Method Post `
                        -Headers @{ "X-API-KEY" = $Env:API_KEY } `
                        "$($Proto)://$($ListServer)/block?list=$($List)"
            }
            catch {
                $_.Exception.Response.StatusCode.value__

                # If block not found, set a backoff interval to wait before processing again
                if ($_.Exception.Response.StatusCode.value__ -eq 404) {
                    $Lists[$List] = (Get-Date).AddMinutes(1);

                    # Restart foreach to avoid 'Collection was modified' exception
                    break
                }
            }
            
            try {
                # For each block index, process
                for ([int]$Index = [int]$Block.index; [int]$Index -lt ([int]$Block.index + [int]$Block.size); [int]$Index ++) {
                    Write-Host "(List: $($List)) Processing task: $($Block.task) action: $($Block.action) index: $($Index) ..."
                }

                # If no errors, upon completion check block back in as complete
                $Result = Invoke-RestMethod `
                        -Method Patch `
                        -Headers @{ "X-API-KEY" = $Env:API_KEY } `
                        "$($Proto)://$($ListServer)/block?block=$($Block.block)"
                Write-Host "$($Proto)://$($ListServer)/block?block=$($Block.block)"
            }
            catch {
                Write-Error "error processing block: $($Block.index), list: $($List)"
                Write-Error $_
            }
        }

        # Avoid maxing the cpu if there are no lists to work on, or if processing is very quick
        Start-Sleep -Milliseconds 100 
    }

    # We have new data from the server, convert from json
    $Result = ""
    $Result = [System.Text.Encoding]::ASCII.GetString($Recv.Array)
    $Result
    $o = $Result | ConvertFrom-Json

    # Debug output
    $o | ConvertTo-Json -Depth 3

    switch ($o.event) {
        # A new list for us to process
        "active" {
            Write-Host "adding: $($o.event)"

            # track this list
            $Lists[$o.list] = $o.event
        }
        "complete" {
            # track this list
            $Lists.Remove($o.list)
        }
        # For now, by default ignore other list states
        default {
            Write-Host "ignoring: $($List.state)"
        }
    }
}

}
catch {
    $_
}

Write-Host "Exiting."