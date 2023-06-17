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

$Required = @(
    "API_KEY"
    "TEMPLATE"
)
foreach ($Req in $Required) {
    if ([Environment]::GetEnvironmentVariable($Req).Length -eq 0) {
        Write-Host "Abort, missing environment variable: $Req"
        exit 1;
    }
}

# Configure
$Proto = "https"
$GameServer = "gge.vc-non.k.home.net"
$Server = "gge.vc-non.k.home.net"
#$Proto = "http"
#$GameServer = "gge-game.gge.svc"
#$Server = "gge-gateway.gge.svc"

# Use internal websocket reference w/o tls
if ($Proto -eq "http") {
    $StreamURI = "ws://$($Server)/ws?api_key=$($Env:API_KEY)"
}
else {
    $StreamURI = "wss://$($Server)/ws?api_key=$($Env:API_KEY)"
}



$WebSocket = New-Object System.Net.WebSockets.ClientWebSocket
$CancellationToken = New-Object System.Threading.CancellationToken
$WebSocket.Options.UseDefaultCredentials = $true

# Get connected
Write-Host "StreamURI: $($StreamURI)"
$Connection = $WebSocket.ConnectAsync($StreamURI, $CancellationToken)

Write-Host "GameServer: $($GameServer)"
Write-Host "API_KEY: $($Env:API_KEY)"
Write-Host "TEMPLATE: $($Env:TEMPLATE)"

# Establish connection to websocket
While (-Not($Connection.IsCompleted)) { 
    Start-Sleep -Milliseconds 500 
    Write-Host "Still waiting to connect." 
}

Write-Host "Connected."
try {

# When playing a game, this is our player id
$PlayerId = ""

# track multiple games
$Game = @{}

# Loop long as connection exists
"WebSocket.State: $($WebSocket.State)"
while ($WebSocket.State -eq "Open") {
    # Reset recv array
    $Size = 1024
    $Array = [byte[]] @(,0) * $Size

    # Watch for new data from socket
    $Recv = New-Object System.ArraySegment[byte] -ArgumentList @(,$Array)
    $Connection = $WebSocket.ReceiveAsync($Recv, $CancellationToken)
    while (!$Connection.IsCompleted) { 
        #Write-Host "Sleeping for 100 ms"
        Start-Sleep -Milliseconds 100 
    }

    #
    $Result = ""
    $Result = [System.Text.Encoding]::ASCII.GetString($Recv.Array)
    $Result
    $o = $Result | ConvertFrom-Json

    # debug output
    $o | ConvertTo-Json -Depth 3

    switch ($o.type) {
        # we've been invited to a game
        "invite-new" {
            # always accept an invite
            Write-Host "$($Proto)://$($GameServer)/game/$($Env:TEMPLATE)/invite?game=$($o.game)&response=true"
            $Result = Invoke-RestMethod `
                    -Method PATCH `
                    -Headers @{ "X-API-KEY" = $Env:API_KEY } `
                    "$($Proto)://$($GameServer)/game/$($Env:TEMPLATE)/invite?game=$($o.game)&response=true"

            # track this game
            $Game[$o.game] = New-Object -TypeName psobject -Property @{
                PlayerId = 0
            }
        }
        "player-id" {
            # we are being told our player id, indicates we are a player and not a watcher
            $Game[$o.game].PlayerId = $o.data.id
        }
        # it's the next player's turn
        "turn" {
            # are we a watcher or a player?
            if ($Game[$o.game].PlayerId -eq 0) {
                # we are a watcher, don't try to make a move
                break;
            }
            # is it our turn?
            if ($o.data.id -eq $Game[$o.game].PlayerId) {
                # yes, it is our turn, make a move
                $method = "add"
                $unit = ($Game[$o.game].PlayerId -eq 1) ? "x" : "y"
                $grid = "main"
                $level = "0"

                # check existing items to determine available locations
                Write-Host "$($Proto)://$($GameServer)/game/$($Env:TEMPLATE)/item?game=$($o.game)"
                $Result = Invoke-RestMethod `
                    -Method GET `
                    -Headers @{ "X-API-KEY" = $Env:API_KEY } `
                    "$($Proto)://$($GameServer)/game/$($Env:TEMPLATE)/item?game=$($o.game)"

                # debug output
                $Result | ConvertTo-Json -Depth 3

                # number of existing items
                Write-Host "Existing items: $($Result.Count)"

                # look for available spot
                $Candidates = @()
                for ($y = 0; $y -le 2; $y ++) {
                    for ($x = 0; $x -le 2; $x ++) {
                        $Found = $false
                        foreach ($Next in $Result) {
                            if (($Next.gridy -eq $y) -and ($Next.gridx -eq $x)) {
                                $Found = $true
                                break
                            }
                        }
                        if (!$Found) {
                            $Candidates += [pscustomobject]@{
                                gridy=$y
                                gridx=$x
                            }
                        }
                    }
                }

                # available plays
                "Available plays: $($Candidates.Count)"
                foreach ($Next in $Candidates) {
                    "  gridy: $($Next.gridy), gridx: $($Next.gridx)"
                }

                # Chose available play at random
                $Index = Get-Random -Maximum $Candidates.Count
                $gridy = $Candidates[$Index].gridy
                $gridx = $Candidates[$Index].gridx

                # should always find a spot, because if cat the game will stop automatically
                Write-Host "Selected play: gridy: $gridy, gridx: $gridx"
                Write-Host "$($Proto)://$($GameServer)/game/$($Env:TEMPLATE)/play?game=$($o.game)&method=$($method)&unit=$($unit)&grid=$($grid)&gridy=$($gridy)&gridx=$($gridx)&level=$($level)"
                $Result = Invoke-RestMethod `
                    -Method POST `
                    -Headers @{ "X-API-KEY" = $Env:API_KEY } `
                    "$($Proto)://$($GameServer)/game/$($Env:TEMPLATE)/play?game=$($o.game)&method=$($method)&unit=$($unit)&grid=$($grid)&gridy=$($gridy)&gridx=$($gridx)&level=$($level)"
            }
        }
        "game-complete" {
            Write-Host "Nice."
        }
    }
}

}
catch {
    $_
}

Write-Host "Exiting."