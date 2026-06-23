# gpg-bridge

A bridge connects openssh-portable and GnuPG on Windows.

On Windows, GnuPG does not use real Unix domain sockets. Instead it
emulates them via loopback TCP + a 16-byte nonce stored in a file
(`S.gpg-agent`, `S.gpg-agent.extra`). OpenSSH's `RemoteForward` cannot
connect to this emulation, so forwarding a Windows gpg-agent to a Linux
remote over SSH does not work out of the box.

This tool sits in the middle: it listens on a normal TCP port that SSH
can forward, and on the other side it connects to the Windows gpg-agent
using the Assuan nonce handshake. The result: your Windows gpg-agent
(whether backed by a Yubikey or software keys) is reachable from a
remote Linux machine over SSH.

---

## Quick Start (Beginner Guide)

### What you need

- **Windows machine** with [Gpg4win](https://gpg4win.org/) installed
  (includes `gpg-agent.exe`, `gpgconf`, etc.)
- **Windows OpenSSH** (`ssh.exe`, comes with Windows 10/11)
- **Rust toolchain** (`cargo`) to build, OR download a prebuilt binary
  from the [GitHub Actions artifacts](https://docs.github.com/en/actions/managing-workflow-runs/downloading-workflow-artifacts)
- A **Linux remote** you SSH into, with `socat` installed
- A GPG keypair — either:
  - A **Yubikey** (or other OpenPGP smartcard) with keys loaded, OR
  - **Software keys** stored in your local GnuPG keyring (`gpg --gen-key`)

> Both key types work identically through this bridge. The bridge
> forwards the gpg-agent protocol; how the agent accesses the key
> (smartcard vs keyring) is transparent.

### Step 1: Build and install gpg-bridge on Windows

```powershell
# Option A: Build from source (recommended)
cargo install --git https://github.com/chaosoffire/gpg-bridge

# Option B: Build from a local clone
git clone https://github.com/chaosoffire/gpg-bridge.git
cd gpg-bridge
cargo build --release
# Binary is at target\release\gpg-bridge.exe

# Option C: Download prebuilt binary from GitHub Actions artifacts
# (see link above)
```

Copy the binary to a stable location:

```powershell
mkdir C:\Users\<you>\bin -Force
Copy-Item target\release\gpg-bridge.exe C:\Users\<you>\bin\
```

### Step 2: Configure Windows gpg-agent for remote pinentry

When you trigger a GPG operation from the remote, the PIN/passphrase
prompt needs to appear on your Windows desktop (not in the headless
SSH session). Add this to your gpg-agent config:

```powershell
# Find your GnuPG home directory
gpgconf --list-dir homedir
# e.g. C:\Users\<you>\AppData\Roaming\gnupg

# Create or edit gpg-agent.conf in that directory
# Add the line:
#   allow-loopback-pinentry

# Restart gpg-agent to apply
gpg-connect-agent killagent /bye
gpg-connect-agent /bye
```

### Step 3: Start gpg-bridge on Windows

```powershell
# Using --agent (full access, includes smartcard/Yubikey support)
C:\Users\<you>\bin\gpg-bridge.exe --agent 127.0.0.1:4321
```

| Flag | Socket | Use case |
|------|--------|----------|
| `--agent` | `S.gpg-agent` (main) | Full access: card operations, signing, decryption. **Recommended.** |
| `--extra` | `S.gpg-agent.extra` (restricted) | Limited operations only. Returns "Forbidden" for card access. |
| `--ssh` | Pageant IPC (named pipe) | Use GnuPG agent as SSH agent via PuTTY protocol. |

> **Which one to use?** `--agent` covers everything, including
> Yubikey/smartcard. Use `--extra` only if you specifically want the
> restricted socket. You can run multiple at once:
> `gpg-bridge --agent 127.0.0.1:4321 --ssh \\.\pipe\gpg-bridge-ssh`

To run it automatically on login, register a scheduled task:

```powershell
# Save as install-gpg-bridge.ps1 and run once
$taskName = "gpg-bridge"
$exePath = "C:\Users\<you>\bin\gpg-bridge.exe"
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute $exePath -Argument "--agent 127.0.0.1:4321"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
Start-ScheduledTask -TaskName $taskName
```

### Step 4: Configure SSH on Windows

Edit `~/.ssh/config` (i.e. `C:\Users\<you>\.ssh\config`):

```sshconfig
Host my-remote
    HostName <remote-ip-or-hostname>
    User <remote-username>
    # SSH creates the Unix socket on the remote, forwarding to Windows TCP port
    RemoteForward /run/user/<uid>/gnupg/S.gpg-agent 127.0.0.1:4321
    ExitOnForwardFailure yes
```

Replace `<uid>` with your remote user ID (find it with `id -u` on the
remote, usually `1000` for the first user).

This uses SSH's **mixed-mode forward**: the remote side is a Unix
socket (created by sshd), the local side is a TCP port (gpg-bridge).
No `socat` needed on the remote — SSH does the translation natively.

> **Important:** Always SSH using the **alias** (`ssh my-remote`), not
> the raw IP (`ssh user@1.2.3.4`). The `RemoteForward` only applies when
> the Host alias matches. If you want the IP to work too, add it to the
> Host line: `Host my-remote 10.0.0.2`

`ExitOnForwardFailure yes` ensures SSH aborts if the forward fails,
instead of silently connecting without the tunnel.

### Step 5: Configure the Linux remote (one-time, minimal)

Only **one** change is needed on the remote — enable `StreamLocalBindUnlink`
so SSH can overwrite a stale socket from a previous session:

```bash
# Add to sshd config (drop-in file, doesn't modify the main config)
sudo tee /etc/ssh/sshd_config.d/streamlocal.conf << 'EOF'
StreamLocalBindUnlink yes
EOF
sudo systemctl restart sshd
```

That's it. **No `socat`, no systemd masking, no `gpg.conf` changes, no
shell hooks.** The remote stays pristine — when you SSH without the
forwarding alias (or don't SSH at all), gpg on the remote behaves
exactly as it would on a clean install.

> **Why this is non-polluting:** SSH only creates the Unix socket while
> the session is alive. When you disconnect, sshd cleans up the socket
> and the remote's systemd gpg-agent sockets return to normal. There's
> no persistent modification to the remote's gpg environment.

### Step 6: Import your public key on the remote (one-time)

The remote needs to know your public key to sign/verify. Export it from
your Windows machine and import on the remote:

```powershell
# On Windows: export your public key
gpg --export --armor <your-key-id> > pubkey.asc
# Copy to remote
scp pubkey.asc my-remote:/tmp/
```

```bash
# On remote: import
gpg --import /tmp/pubkey.asc
gpg --list-secret-keys --keyid-format=long
# You should see ssb> markers (> = secret key is on card/stub, i.e. forwarded)
```

### Step 7: Verify end-to-end

```bash
# On remote, after ssh my-remote:
gpg --card-status    # Yubikey: shows card info. Software key: no card, but signing works.
echo test | gpg --clearsign --local-user <your-key-id>
# -> PIN/passphrase prompt appears on Windows, signature produced on remote
```

### Step 8 (optional): Enable git signing on the remote

```bash
git config --global user.signingkey <your-key-id>
git config --global commit.gpgsign true
git config --global gpg.program gpg
```

Now every `git commit` on the remote signs via your Windows gpg-agent.

---

## How it works

```
Remote (Linux)                    SSH tunnel                 Windows
┌──────────────┐                                            ┌──────────────────┐
│ gpg          │                                            │ gpg-agent.exe    │
│   ↓          │                                            │   ↑ (PC/SC or    │
│ Unix socket  │                                            │   keyring)       │
│ S.gpg-agent  │                                            │ Yubikey / keys   │
│   ↓          │                                            │                  │
│ sshd creates │──SSH──→ Unix→TCP ──→ 127.0.0.1:4321        │ gpg-bridge.exe   │
│ & manages    │           (native SSH      (gpg-bridge     │ reads nonce file │
│ the socket   │            translation)     listens here)   │ does handshake   │
│              │                                            │ pumps bytes       │
└──────────────┘                                            └──────────────────┘
```

1. `gpg` on remote connects to the Unix socket `S.gpg-agent`
2. SSH's `RemoteForward` (mixed Unix→TCP mode) translates the Unix
   socket traffic to TCP and tunnels it to Windows `127.0.0.1:4321`
3. `gpg-bridge.exe` receives the connection, reads the `S.gpg-agent`
   file (which contains the real port + 16-byte nonce), connects to
   `gpg-agent.exe` on that port, sends the nonce as handshake, then
   pumps bytes bidirectionally
4. `gpg-agent.exe` accesses the key (Yubikey via PC/SC, or software
   keyring) and returns the result

The key never leaves your Windows machine. Only the gpg-agent protocol
travels through the encrypted SSH tunnel.

**No `socat` on the remote.** SSH natively bridges Unix socket → TCP
in this configuration. When the SSH session ends, sshd cleans up the
Unix socket automatically — the remote's gpg environment is untouched.

---

## Troubleshooting

### Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `gpg: End of file` / `No agent running` | SSH forward not active (used IP instead of alias, or gpg-bridge died on Windows) | Use `ssh <alias>` not `ssh user@ip`; check `Test-NetConnection 127.0.0.1 -Port 4321` on Windows |
| `gpg: OpenPGP card not available: Forbidden` | gpg-bridge running with `--extra` instead of `--agent` | Restart with `--agent` flag |
| `ssh: remote port forwarding failed` | Stale socket from previous session on remote | See section below |
| PIN prompt on remote instead of Windows | `allow-loopback-pinentry` not applied | Add to gpg-agent.conf, restart agent: `gpg-connect-agent killagent /bye; gpg-connect-agent /bye` |
| `No secret key` when signing | Public key not imported on remote | `gpg --import pubkey.asc` on remote |

### "Error: remote port forwarding failed for listen port 4321"

This is the most common issue. It happens when a previous SSH session
died ungracefully (closed terminal window, network drop, etc.) but the
remote `sshd-session` process is still alive and holding the port.

**Immediate fix:**

```bash
# SSH in without forwarding, kill stale sessions, reconnect
ssh -o ClearAllForwardings=yes <remote> "pkill -u $USER -f sshd-session -o OLD"
ssh <remote>
```

**Permanent fix (recommended) — configure sshd to auto-kill dead sessions:**

On the remote, create a drop-in sshd config:

```bash
sudo tee /etc/ssh/sshd_config.d/alive.conf << 'EOF'
ClientAliveInterval 30
ClientAliveCountMax 3
EOF

# Debian/Ubuntu:
sudo systemctl restart sshd

# RHEL/Fedora:
sudo systemctl restart sshd
```

This makes sshd send a keepalive ping every 30 seconds. If the client
doesn't respond 3 times in a row (90 seconds — e.g. after a network
drop or closed terminal), sshd kills the session and releases the port.

**Also ensure `ExitOnForwardFailure yes` is in your SSH config** so SSH
fails loudly instead of silently connecting without the tunnel:

```sshconfig
Host my-remote
    RemoteForward /run/user/<uid>/gnupg/S.gpg-agent 127.0.0.1:4321
    ExitOnForwardFailure yes
```

### "gpg: can't connect to the gpg-agent: End of file"

The SSH forward created the Unix socket on the remote, but there's
nothing listening on the other side. Causes:

1. **You used `ssh user@ip` instead of `ssh <alias>`** — the
   `RemoteForward` only applies to the Host alias in your SSH config.
   Always connect using the alias, or add the IP to the Host line:
   ```sshconfig
   Host my-remote 10.0.10.2
   ```
2. **gpg-bridge died on Windows** — check with:
   ```powershell
   Test-NetConnection 127.0.0.1 -Port 4321
   # If False: Start-ScheduledTask -TaskName gpg-bridge
   ```
3. **Windows just rebooted and the scheduled task hasn't fired yet** —
   wait a few seconds or start it manually:
   ```powershell
   Start-ScheduledTask -TaskName gpg-bridge
   ```

### Manual recovery

```powershell
# Windows: restart gpg-bridge
Stop-Process -Name gpg-bridge -Force -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName gpg-bridge
Test-NetConnection 127.0.0.1 -Port 4321   # should be True
```

```bash
# Remote: just reconnect — SSH recreates the socket automatically
# No socat to restart, no scripts to run
exit  # disconnect
ssh my-remote  # reconnect
gpg --card-status   # verify
```

---

## Yubikey vs Software Keys

Both work through this bridge with zero configuration difference.

| | Yubikey / Smartcard | Software Keys |
|--|---------------------|---------------|
| Key storage | On the physical device | In `~/.gnupg` on Windows |
| gpg-agent access | Via PC/SC reader | Direct from keyring |
| PIN/passphrase | Yubikey PIN (numeric) | GPG passphrase (text) |
| Physical interaction | Touch Yubikey (if UIF enabled) | None |
| If key compromised | Replace Yubikey | Revoke + regenerate key |
| Works with `--agent` | Yes | Yes |
| Works with `--extra` | No (Forbidden) | Limited |

No bridge or SSH config changes are needed when switching between them.
The bridge forwards the agent protocol; the agent handles key access
internally.

---

## Using GnuPG Agent as SSH agent

GnuPG Agent supports OpenSSH Agent protocol. This tool also supports
forwarding ssh queries by utilizing putty protocols.

1. To forward it as ssh agent, you need to ensure `--enable-putty-support`
   is configured for gpg client. Or you can put it into the configuration
   files, `homedir/gpg-agent.conf`. `homedir` can be found by
   `gpgconf --list-dir homedir`.

   ```
   enable-putty-support
   ```

2. Then pass `--ssh \\.\pipe\gpg-bridge-ssh` to gpg-bridge.

   ```
   gpg-bridge --agent 127.0.0.1:4321 --ssh \\.\pipe\gpg-bridge-ssh
   ```

3. Now let OpenSSH to use gpg agent by setting environment variable
   `SSH_AUTH_SOCK` to `\\.\pipe\gpg-bridge-ssh`.

The string "gpg-bridge-ssh" can be changed to anything you want, just
make sure it's consistent everywhere.

---

## Why invent the wheel

There are several gotchas if not using bridge to forward gpg agent on
Windows. See PowerShell/Win32-OpenSSH#1564.

1. Specifying remote forward local socket path in openssh-portable can
   be tricky (for now).

   Path like `C:/xxx`, `~/xxx` and `%userprofile%/xxx` will not work.
   You have to use form like `/absolute/path/to/local/socket` and
   execute ssh on the same driver path. See
   https://docs.microsoft.com/en-us/dotnet/standard/io/file-path-formats.

2. Even path is correctly specified and accepted, forwarding will not
   work.

   Openssh-portable can't handle UDS (unix domain socket) on Windows
   correctly (for now).

3. Even Openssh-portable handles UDS correctly, forwarding still can't
   work.

   > Support for Unix domain sockets was introduced in Windows 10
   > Insider Build 17063. It became generally available in version
   > 1809 (aka the October 2018 Update), and in Windows Server
   > 1809/2019.

   GnuPG on Windows has not utilized native UDS support yet. It
   simulates a UDS using a TCP stream socket with customized connect
   step. So without extra tools, you can't really connect
   openssh-portable to GnuPG.

---

## Changes from upstream

This fork adds:

- **`--agent` flag**: Bridges the main `S.gpg-agent` socket (full
  access, includes smartcard/Yubikey support). The original `--extra`
  flag only bridges the restricted extra socket, which returns
  "Forbidden" for card operations like `--card-status`.
- **`--agent-socket` flag**: Optionally specify a custom path to the
  agent socket file.
- **Bug fix**: `PipeServerWrite::poll_write` in `util.rs` incorrectly
  called `poll_read_ready` instead of `poll_write_ready` in the
  WouldBlock branch (copy-paste error from `PipeServerRead`).