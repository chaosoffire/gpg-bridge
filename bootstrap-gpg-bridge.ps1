<#
.SYNOPSIS
  Bootstrap or uninstall gpg-bridge on Windows.
  Downloads the binary from GitHub releases, registers a scheduled task,
  configures gpg-agent, and patches ~/.ssh/config.

.DESCRIPTION
  One-liner install (defaults):
    irm https://raw.githubusercontent.com/chaosoffire/gpg-bridge/master/bootstrap-gpg-bridge.ps1 | iex

  One-liner install (custom params):
    iex "& { $(irm https://raw.githubusercontent.com/chaosoffire/gpg-bridge/master/bootstrap-gpg-bridge.ps1) } -RemoteHost work -RemoteSocket /run/user/1001/gnupg/S.gpg-agent"

  Uninstall:
    iex "& { $(irm https://raw.githubusercontent.com/chaosoffire/gpg-bridge/master/bootstrap-gpg-bridge.ps1) } -Uninstall"

  The script is idempotent — safe to re-run. Only touches what it added
  (marked with sentinel comments in ~/.ssh/config). Does not pollute the
  remote machine — only needs StreamLocalBindUnlink yes in sshd_config.

.PARAMETER RemoteHost
  The SSH Host alias in ~/.ssh/config to configure forwarding for.

.PARAMETER RemoteSocket
  The Unix socket path on the remote to forward from.

.PARAMETER Port
  The local TCP port for gpg-bridge to listen on.

.PARAMETER RemoteIP
  Optional: IP/hostname to add to the Host line so `ssh user@<ip>` also
  gets forwarding. If omitted, only the alias gets forwarding.

.PARAMETER Uninstall
  Remove gpg-bridge: stops process, deletes binary, unregisters
  scheduled task, removes sentinel-tagged SSH config block.
  Leaves allow-loopback-pinentry in gpg-agent.conf (may be needed by
  other tools). Prints a note about it.

.EXAMPLE
  .\bootstrap-gpg-bridge.ps1
  .\bootstrap-gpg-bridge.ps1 -RemoteHost work -RemoteIP 10.0.20.5
  .\bootstrap-gpg-bridge.ps1 -Uninstall
#>

param(
    [string]$RemoteHost = "dev.lan",
    [string]$RemoteSocket = "/run/user/1000/gnupg/S.gpg-agent",
    [string]$Port = "4321",
    [string]$RemoteIP = "",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

# --- Constants ---
$repo = "chaosoffire/gpg-bridge"
$taskName = "gpg-bridge"
$binDir = Join-Path $env:USERPROFILE "bin"
$exePath = Join-Path $binDir "gpg-bridge.exe"
$sentinelStart = "# >>> gpg-bridge >>>"
$sentinelEnd = "# <<< gpg-bridge <<<"

# ============================================================
# Uninstall
# ============================================================
if ($Uninstall) {
    Write-Host "`nUninstalling gpg-bridge..." -ForegroundColor Cyan

    # 1. Stop running process
    $proc = Get-Process -Name "gpg-bridge" -ErrorAction SilentlyContinue
    if ($proc) {
        $proc | Stop-Process -Force
        Write-Host "  Stopped gpg-bridge process (PID $($proc.Id))" -ForegroundColor Green
    } else {
        Write-Host "  No running gpg-bridge process" -ForegroundColor Yellow
    }

    # 2. Unregister scheduled task
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "  Unregistered scheduled task '$taskName'" -ForegroundColor Green
    } else {
        Write-Host "  No scheduled task '$taskName' found" -ForegroundColor Yellow
    }

    # 3. Delete binary
    if (Test-Path $exePath) {
        Remove-Item $exePath -Force
        Write-Host "  Deleted $exePath" -ForegroundColor Green
    } else {
        Write-Host "  No binary at $exePath" -ForegroundColor Yellow
    }

    # 4. Remove sentinel-tagged SSH config block
    $sshConfig = Join-Path $env:USERPROFILE ".ssh\config"
    if (Test-Path $sshConfig) {
        $raw = Get-Content $sshConfig -Raw
        $pattern = "(?ms)`r?`n?$([regex]::Escape($sentinelStart)).*?$([regex]::Escape($sentinelEnd))`r?`n?"
        if ($raw -match $pattern) {
            $raw = $raw -replace $pattern, ""
            Set-Content -Path $sshConfig -Value $raw.TrimEnd() -NoNewline
            Write-Host "  Removed gpg-bridge block from $sshConfig" -ForegroundColor Green
        } else {
            Write-Host "  No gpg-bridge sentinel block in $sshConfig" -ForegroundColor Yellow
        }

        # Also remove injected lines from existing Host blocks (non-sentinel case)
        $injectPattern = "(?m)`r?`n?    RemoteForward [^\n]*gpg-agent[^\n]*127\.0\.0\.1:$Port[^\n]*`r?`n?    ExitOnForwardFailure yes"
        if ($raw -match $injectPattern) {
            $raw = $raw -replace $injectPattern, ""
            Set-Content -Path $sshConfig -Value $raw.TrimEnd() -NoNewline
            Write-Host "  Removed injected forward lines from existing Host block" -ForegroundColor Green
        }
    }

    # 5. Note about gpg-agent.conf (don't remove)
    $gnupgHome = & gpgconf --list-dir homedir 2>$null
    if (-not $gnupgHome) { $gnupgHome = Join-Path $env:APPDATA "gnupg" }
    $agentConf = Join-Path $gnupgHome "gpg-agent.conf"
    if ((Test-Path $agentConf) -and (Get-Content $agentConf -Raw) -match "allow-loopback-pinentry") {
        Write-Host "`n  Note: allow-loopback-pinentry left in $agentConf" -ForegroundColor Yellow
        Write-Host "  (other tools may need it; remove manually if not wanted)" -ForegroundColor Yellow
    }

    Write-Host "`nUninstall complete." -ForegroundColor Green
    return
}

# ============================================================
# Install
# ============================================================

# --- Pre-flight checks ---
if (-not (Get-Command gpgconf -ErrorAction SilentlyContinue)) {
    Write-Warning "gpgconf not found on PATH. Install Gpg4win from https://gpg4win.org/ — gpg-bridge is unusable without gpg-agent. Continuing install anyway."
}

# --- 1. Download gpg-bridge.exe from GitHub releases ---
Write-Host "`n[1/4] Installing gpg-bridge.exe..." -ForegroundColor Cyan

if (Test-Path $exePath) {
    Write-Host "  Already exists at $exePath (skip)" -ForegroundColor Yellow
} else {
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null

    $releaseUrl = "https://github.com/$repo/releases/latest/download/gpg-bridge.exe"
    $sha256Url = "https://github.com/$repo/releases/latest/download/gpg-bridge.exe.sha256"

    Write-Host "  Downloading from GitHub releases..."
    try {
        Invoke-WebRequest -Uri $releaseUrl -OutFile $exePath -UseBasicParsing

        # Verify SHA256
        $sha256File = Join-Path $env:TEMP "gpg-bridge.exe.sha256"
        try {
            Invoke-WebRequest -Uri $sha256Url -OutFile $sha256File -UseBasicParsing
            $expectedHash = (Get-Content $sha256File -Raw).Trim().Split(' ')[0].Trim().ToLower()
            $actualHash = (Get-FileHash $exePath -Algorithm SHA256).Hash.ToLower()
            if ($expectedHash -eq $actualHash) {
                Write-Host "  SHA256 verified: $actualHash" -ForegroundColor Green
            } else {
                Remove-Item $exePath -Force -ErrorAction SilentlyContinue
                throw "SHA256 mismatch! Expected: $expectedHash`nGot: $actualHash`nDownload may be corrupted or tampered. Re-run or download manually from https://github.com/$repo/releases"
            }
        } catch {
            Write-Host "  WARNING: Could not verify SHA256 ($($_.Exception.Message))" -ForegroundColor Yellow
            Write-Host "  Binary installed without checksum verification" -ForegroundColor Yellow
        }
        Write-Host "  Downloaded to $exePath" -ForegroundColor Green
    } catch {
        Write-Host "  Download from releases failed. Trying cargo install..." -ForegroundColor Yellow
        $cargoBin = Join-Path $env:USERPROFILE ".cargo\bin\gpg-bridge.exe"
        try {
            cargo install --git "https://github.com/$repo" 2>&1 | Out-Null
            if (Test-Path $cargoBin) {
                Copy-Item $cargoBin $exePath -Force
                Write-Host "  Built via cargo, copied to $exePath" -ForegroundColor Green
            } else {
                throw "cargo install did not produce a binary"
            }
        } catch {
            throw "Could not download or build gpg-bridge.`nDownload manually: https://github.com/$repo/releases`nOr install Rust: https://rustup.rs"
        }
    }
}

# --- 2. Register scheduled task (auto-start on login) ---
Write-Host "`n[2/4] Registering scheduled task..." -ForegroundColor Cyan

# Check port conflict
$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    $owner = (Get-Process -Id $existing.OwningProcess -ErrorAction SilentlyContinue).Name
    if ($owner -ne "gpg-bridge") {
        Write-Warning "Port $Port is held by '$owner' (PID $($existing.OwningProcess)), not gpg-bridge. Pick a different -Port or stop that process."
    } else {
        Write-Host "  gpg-bridge already listening on port $Port" -ForegroundColor Yellow
    }
}

$action = New-ScheduledTaskAction -Execute $exePath -Argument "--agent 127.0.0.1:$Port"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep 2
    $listening = (Test-NetConnection 127.0.0.1 -Port $Port -WarningAction SilentlyContinue).TcpTestSucceeded
    if ($listening) {
        Write-Host "  Task registered, gpg-bridge listening on 127.0.0.1:$Port" -ForegroundColor Green
    } else {
        Write-Host "  Task registered (port not responding yet, may need a moment)" -ForegroundColor Yellow
    }
} catch {
    Write-Warning "Scheduled task registration failed: $($_.Exception.Message)"
    Write-Host "  Register manually:" -ForegroundColor Yellow
    Write-Host "    Register-ScheduledTask -TaskName $taskName -Action (New-ScheduledTaskAction -Execute `"$exePath`" -Argument `"--agent 127.0.0.1:$Port`") -Trigger (New-ScheduledTaskTrigger -AtLogOn)"
    throw
}

# --- 3. Configure gpg-agent.conf ---
Write-Host "`n[3/4] Configuring gpg-agent..." -ForegroundColor Cyan

$gnupgHome = & gpgconf --list-dir homedir 2>$null
if (-not $gnupgHome) { $gnupgHome = Join-Path $env:APPDATA "gnupg" }
$agentConf = Join-Path $gnupgHome "gpg-agent.conf"

if (-not (Test-Path $gnupgHome)) {
    New-Item -ItemType Directory -Path $gnupgHome -Force | Out-Null
}

$needAdd = $true
if (Test-Path $agentConf) {
    $content = Get-Content $agentConf -Raw
    if ($content -match "allow-loopback-pinentry") {
        $needAdd = $false
        Write-Host "  allow-loopback-pinentry already in $agentConf (skip)" -ForegroundColor Yellow
    }
}

if ($needAdd) {
    Add-Content -Path $agentConf -Value "allow-loopback-pinentry"
    Write-Host "  Added allow-loopback-pinentry to $agentConf" -ForegroundColor Green
    & gpg-connect-agent killagent /bye 2>$null | Out-Null
    Start-Sleep 1
    & gpg-connect-agent /bye 2>$null | Out-Null
    Write-Host "  gpg-agent restarted" -ForegroundColor Green
}

# --- 4. Patch ~/.ssh/config ---
Write-Host "`n[4/4] Configuring SSH ($RemoteHost)..." -ForegroundColor Cyan

$sshConfig = Join-Path $env:USERPROFILE ".ssh\config"
if (-not (Test-Path (Split-Path $sshConfig))) {
    New-Item -ItemType Directory -Path (Split-Path $sshConfig) -Force | Out-Null
}

$forwardLine = "    RemoteForward $RemoteSocket 127.0.0.1:$Port"
$exitLine = "    ExitOnForwardFailure yes"
$hostLine = if ($RemoteIP) { "Host $RemoteHost $RemoteIP" } else { "Host $RemoteHost" }

$needAdd = $true
if (Test-Path $sshConfig) {
    $raw = Get-Content $sshConfig -Raw
    # Match full forward line (not just socket path) so different ports are detected
    if ($raw -match [regex]::Escape($forwardLine.Trim())) {
        $needAdd = $false
        Write-Host "  RemoteForward already present in $sshConfig (skip)" -ForegroundColor Yellow
    }
}

if ($needAdd) {
    if (Test-Path $sshConfig -and $raw) {
        # Check if Host block for this alias already exists
        $hostPattern = "(?m)^(Host\s+[^\n]*\b$([regex]::Escape($RemoteHost))\b[^\n]*)$"
        if ($raw -match $hostPattern) {
            # Inject lines into existing Host block
            $injected = "`n$forwardLine`n$exitLine"
            $raw = $raw -replace $hostPattern, "`$1$injected"
            Set-Content -Path $sshConfig -Value $raw.TrimEnd() -NoNewline
            Write-Host "  Injected RemoteForward into existing '$RemoteHost' block" -ForegroundColor Green
        } else {
            # Append sentinel-tagged new block
            $block = "`n`n$sentinelStart`n$hostLine`n    # TODO: set HostName and User for this remote`n$forwardLine`n$exitLine`n$sentinelEnd`n"
            Add-Content -Path $sshConfig -Value $block
            Write-Host "  Added new SSH config block for $RemoteHost" -ForegroundColor Green
            Write-Host "  NOTE: Edit $sshConfig to set HostName and User" -ForegroundColor Yellow
        }
    } else {
        # Create new config file
        $block = "$sentinelStart`n$hostLine`n    # TODO: set HostName and User for this remote`n$forwardLine`n$exitLine`n$sentinelEnd`n"
        Set-Content -Path $sshConfig -Value $block.TrimStart()
        Write-Host "  Created $sshConfig with $RemoteHost block" -ForegroundColor Green
        Write-Host "  NOTE: Edit $sshConfig to set HostName and User" -ForegroundColor Yellow
    }
}

# --- Summary ---
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  gpg-bridge.exe : $exePath"
Write-Host "  Scheduled task : $taskName (auto-starts on login)"
Write-Host "  gpg-agent.conf : $agentConf"
Write-Host "  SSH config     : $sshConfig"
Write-Host "  Forward        : $RemoteSocket -> 127.0.0.1:$Port"
Write-Host ""
Write-Host "  Remote one-time setup (run on the Linux box):" -ForegroundColor Yellow
Write-Host "    sudo tee /etc/ssh/sshd_config.d/streamlocal.conf << 'EOF'"
Write-Host "    StreamLocalBindUnlink yes"
Write-Host "    EOF"
Write-Host "    sudo systemctl restart sshd"
Write-Host ""
Write-Host "  Test: ssh $RemoteHost" -ForegroundColor Green
Write-Host "        gpg --card-status" -ForegroundColor Green
Write-Host ""
Write-Host "  Uninstall: iex `"& { `$(`$irm https://raw.githubusercontent.com/$repo/master/bootstrap-gpg-bridge.ps1) } -Uninstall`"" -ForegroundColor DarkGray
Write-Host ""