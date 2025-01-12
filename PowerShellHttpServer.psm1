function Invoke-HttpServer {
    <#
    .SYNOPSIS
    Starts an HTTP server that listens for incoming requests and processes them.

    .DESCRIPTION
    The `Invoke-HttpServer` function creates and starts an HTTP server on the specified IP and port.
    It listens for incoming HTTP requests, processes them in a separate runspace, and outputs request information to the console.

    The server is configurable via parameters for the listening port, timeout duration, and IP address. 
    The server runs in a loop until the specified timeout is reached or it is stopped manually (Ctrl+C).
    It has basic error handling built-in, therefore the server should not survive for example Nmap script scans.

    .PARAMETER Port
    The port number on which the HTTP server listens. Default is 13824.

    .PARAMETER HttpTimeout
    The duration in seconds for which the HTTP server will run before shutting down automatically.
    Set to 0 to run indefinitely (Default).

    .PARAMETER Ip
    The IP address on which the HTTP server listens. Default is "localhost".

    .EXAMPLE
    Invoke-HttpServer -Port 8080 -HttpTimeout 120 -Ip "*"
    Starts an HTTP server on IP `127.0.0.1` and port `8080`. The server runs for 120 seconds.

    .EXAMPLE
    Invoke-HttpServer
    Starts an HTTP server on IP `localhost` and port `13824`. The server runs for 60 seconds.

    .NOTES
    GitHub: https://github.com/zh54321/
    #>

    param (
        [Parameter(Mandatory=$false)][int]$Port = 13824,
        [Parameter(Mandatory=$false)][int]$HttpTimeout = 0,
        [Parameter(Mandatory=$false)][string]$Ip = "localhost"
    )

    # Create and configure the HTTP listener
    $HttpListener = [System.Net.HttpListener]::new()
    $HttpListener.Prefixes.Add("http://$($Ip):$Port/")
    
    Try {
        $HttpListener.Start()
    } Catch {
        $HttpStartError = $_
        if ($HttpStartError -match "because it conflicts with an existing registration on the machine") {
            Write-Host "[!] The port $Port is already blocked by another process."
            Write-Host "[!] Close the other process or use -port to define another port."
        } elseif ($HttpStartError -match "Access is denied") {
            Write-Host "[!] Listening on any other interface than localhost requires admin privileges."
        } else {
            write-host "[!] ERROR: $HttpStartError"
        }
        break
    }

    if ($HttpListener.IsListening) {
        Write-Host "[*] HTTP server started on http://$($Ip):$Port/. Press Ctrl+C to stop."
    }
    
    # Variable to control the server loop
    $KeepRunning = $true

    # Runspace for the HTTP server
    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.Open()

    # Shared object for communication
    $SharedData = [System.Collections.Concurrent.ConcurrentQueue[PSObject]]::new()

    # Script block for the HTTP server loop
    $ScriptBlock = {
        param($HttpListener, [ref]$KeepRunning, $SharedData)

        #Outer while loop to keep the server running in case of errors
        while ($KeepRunning.Value -and $HttpListener.IsListening) {
            try {
                while ($KeepRunning.Value -and $HttpListener.IsListening) {
                    $Context = $HttpListener.GetContext()

                    # Retrieve request information and share with main script
                    $Request = $Context.Request
                    $SharedData.Enqueue($Request)

                    # Response handeling
                    # Use "if ($Request.HttpMethod -eq 'GET' -and $Request.RawUrl -eq '/')" to customize responses
                    $Response = $Context.Response
                    $Response.StatusCode = 200
                    $Response.ContentType = "text/plain"
                    $ResponseOutput = [System.Text.Encoding]::UTF8.GetBytes("Successful! Time to celebrate with coffee.`nMore PowerShell stuff on: https://github.com/zh54321")
                    $Response.OutputStream.Write($ResponseOutput, 0, $ResponseOutput.Length)
                    $Response.OutputStream.Close()
                }
            } catch {
                # Share error data
                $SharedData.Enqueue($_)
                write-host $HttpListener.IsListening
            }
        }
    }

    # Create a PS instance and assign the script block to it
    $PSInstance = [powershell]::Create()
    $PSInstance.AddScript($ScriptBlock).AddArgument($HttpListener).AddArgument([ref]$KeepRunning).AddArgument($SharedData) | Out-Null
    $PSInstance.Runspace = $Runspace
    $PSInstance.BeginInvoke() | Out-Null

    # Main loop to process output from the shared queue
    $StartTime = [datetime]::Now
    $Proceed = $true

    try {
        while ($Proceed) {
            Start-Sleep -Milliseconds 500

            # Check if the runtime exceeds the timeout (if set)
            if ($HttpTimeout -gt 0 -and ([datetime]::Now - $StartTime).TotalSeconds -ge $HttpTimeout) {
                Write-Host "[!] Runtime limit reached. Stopping the server..."
                break
            }

            # Process output from the shared queue
            
            $Request = $null
            while ($SharedData.TryDequeue([ref]$Request)) {
                # Customize this section to do stuff which you want (trigger actions, end the script etc.)

                # Quit if if receives a request on /quit
                if ($($Request.RawUrl) -match "quit") {
                    Write-Host "[+] Got request on /quit"
                    $Proceed = $false
                    break
                }

                #Null check to avoid the script crashing
                if ($null -ne $Request -and $Request -is [System.Net.HttpListenerRequest]) {
                    Write-Host "[+] Got request $($Request.HttpMethod) $($Request.RawUrl) from $($Request.RemoteEndPoint.ToString())"
                } else {
                    Write-Host "[!] Request caused an error: $Request"
                }
                
            }
        }

    } finally {
        #Cleaning up
        Write-Host "[*] Stopping the server..."
        $KeepRunning = $false
        Start-Sleep -Milliseconds 500 # Allow the loop in the runspace to complete
        $HttpListener.Stop()
        $PSInstance.Stop()
        $PSInstance.Dispose()
        $Runspace.Close()
        $Runspace.Dispose()
        Write-Host "[*] Server stopped."
    }
}
