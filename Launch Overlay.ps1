[CmdletBinding()]
param(
    [string]$GroupCode,
    [switch]$Build
)

$ErrorActionPreference = "Stop"

$hostRoot = Split-Path -Parent $PSScriptRoot
$serverDirectory = Join-Path $hostRoot "Spectra-Server"
$frontendDirectory = Join-Path $hostRoot "Spectra-Frontend-VAL26"
$proxyScript = Join-Path $PSScriptRoot "reverse-proxy.js"

foreach ($directory in @($serverDirectory, $frontendDirectory)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Required directory not found: $directory"
    }
}

if (-not (Test-Path -LiteralPath $proxyScript -PathType Leaf)) {
    throw "Reverse proxy script not found: $proxyScript"
}

function Resolve-Executable {
    param([string[]]$Names)

    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    throw "Required executable not found: $($Names -join ', ')"
}

function Invoke-Yarn {
    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & $script:yarnCommand @Arguments 1>$null 2>$null
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorAction
        }
        if ($exitCode -ne 0) {
            throw "Yarn command failed with exit code ${exitCode}: yarn $($Arguments -join ' ')"
        }
    }
    finally {
        Pop-Location
    }
}

function Wait-ForPort {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $client.Connect("127.0.0.1", $Port)
            return
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
        finally {
            $client.Dispose()
        }
    }

    throw "Timed out waiting for local port $Port"
}

function Wait-ForTunnelUrl {
    param(
        [System.Diagnostics.Process]$Process,
        [string[]]$OutputFiles,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $pattern = "https://[a-zA-Z0-9.-]+\.trycloudflare\.com"

    while ((Get-Date) -lt $deadline) {
        foreach ($outputFile in $OutputFiles) {
            if (Test-Path -LiteralPath $outputFile -PathType Leaf) {
                $output = Get-Content -LiteralPath $outputFile -Raw -ErrorAction SilentlyContinue
                if ($output) {
                    $match = [regex]::Match($output, $pattern)
                    if ($match.Success) {
                        return $match.Value.TrimEnd("/")
                    }
                }
            }
        }

        if ($Process.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    throw "Cloudflare Quick Tunnel URL was not found."
}

function Stop-ProcessTree {
    param([System.Diagnostics.Process]$Process)

    if ($Process -and -not $Process.HasExited) {
        & taskkill.exe /PID $Process.Id /T /F | Out-Null
    }
}

$script:yarnCommand = Resolve-Executable @("yarn.cmd", "yarn")
$nodeCommand = Resolve-Executable @("node.exe", "node")
$cloudflaredCommand = Resolve-Executable @("cloudflared.exe", "cloudflared")

while ([string]::IsNullOrWhiteSpace($GroupCode)) {
    $GroupCode = Read-Host "Enter the Spectra group code"
}

$groupCode = $GroupCode.Trim().ToUpperInvariant()

$shouldBuild = $Build
if (-not $Build) {
    $buildAnswer = Read-Host "Build the frontend now? [y/N]"
    $shouldBuild = $buildAnswer -match "^(?i:y|yes)$"
}

Write-Host "`nBooting Spectra..." -ForegroundColor Cyan

$logDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "spectra-self-hosting-$PID"
if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $logDirectory | Out-Null
}

$processes = @()

try {
    if ($shouldBuild) {
        Invoke-Yarn -WorkingDirectory $frontendDirectory -Arguments @("build")
    }

    $previousInsecure = [Environment]::GetEnvironmentVariable("INSECURE", "Process")
    $env:INSECURE = "true"
    try {
        $serverProcess = Start-Process `
            -FilePath $script:yarnCommand `
            -ArgumentList @("start_single") `
            -WorkingDirectory $serverDirectory `
            -RedirectStandardOutput (Join-Path $logDirectory "server.out.log") `
            -RedirectStandardError (Join-Path $logDirectory "server.err.log") `
            -NoNewWindow `
            -PassThru
    }
    finally {
        if ($null -eq $previousInsecure) {
            Remove-Item Env:INSECURE -ErrorAction SilentlyContinue
        }
        else {
            $env:INSECURE = $previousInsecure
        }
    }
    $processes += $serverProcess

    Wait-ForPort -Port 5101
    Wait-ForPort -Port 5200

    $frontendProcess = Start-Process `
        -FilePath $nodeCommand `
        -ArgumentList @("server.js") `
        -WorkingDirectory $frontendDirectory `
        -RedirectStandardOutput (Join-Path $logDirectory "frontend.out.log") `
        -RedirectStandardError (Join-Path $logDirectory "frontend.err.log") `
        -NoNewWindow `
        -PassThru
    $processes += $frontendProcess

    Wait-ForPort -Port 4200

    $proxyProcess = Start-Process `
        -FilePath $nodeCommand `
        -ArgumentList @($proxyScript) `
        -WorkingDirectory $PSScriptRoot `
        -RedirectStandardOutput (Join-Path $logDirectory "proxy.out.log") `
        -RedirectStandardError (Join-Path $logDirectory "proxy.err.log") `
        -NoNewWindow `
        -PassThru
    $processes += $proxyProcess

    Wait-ForPort -Port 4201

    $tunnelProcess = Start-Process `
        -FilePath $cloudflaredCommand `
        -ArgumentList @("tunnel", "--url", "http://127.0.0.1:4201") `
        -RedirectStandardOutput (Join-Path $logDirectory "cloudflared.out.log") `
        -RedirectStandardError (Join-Path $logDirectory "cloudflared.err.log") `
        -NoNewWindow `
        -PassThru
    $processes += $tunnelProcess

    $tunnelUrl = Wait-ForTunnelUrl `
        -Process $tunnelProcess `
        -OutputFiles @(
            (Join-Path $logDirectory "cloudflared.out.log"),
            (Join-Path $logDirectory "cloudflared.err.log")
        )
    $encodedGroupCode = [System.Uri]::EscapeDataString($groupCode)
    $overlayUrl = "$tunnelUrl/overlay?groupCode=$encodedGroupCode"
    $header = "Spectra tunnel ready"
    $innerWidth = [Math]::Max($header.Length, $overlayUrl.Length) + 4
    $border = "+" + ("-" * $innerWidth) + "+"

    Write-Host ""
    Write-Host $border -ForegroundColor DarkCyan
    Write-Host (("|  " + $header).PadRight($innerWidth) + "|") -ForegroundColor Cyan
    Write-Host (("|  " + $overlayUrl).PadRight($innerWidth) + "|") -ForegroundColor Green
    Write-Host $border -ForegroundColor DarkCyan
    Write-Host "Keep window open. CTRL+C to exit" -ForegroundColor DarkGray

    while (-not $tunnelProcess.HasExited) {
        if ($serverProcess.HasExited) {
            throw "Spectra Server exited unexpectedly."
        }
        if ($frontendProcess.HasExited) {
            throw "Spectra Frontend exited unexpectedly."
        }
        if ($proxyProcess.HasExited) {
            throw "Standalone reverse proxy exited unexpectedly."
        }
        Start-Sleep -Seconds 1
    }
}
finally {
    foreach ($process in $processes) {
        Stop-ProcessTree -Process $process
    }
    if (Test-Path -LiteralPath $logDirectory -PathType Container) {
        Remove-Item -LiteralPath $logDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
