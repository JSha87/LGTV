# LG WebOS TV Unified Controller – PowerShell Edition  

> A zero‑dependency PowerShell wrapper that manages LG WebOS TVs.  
> All logic lives in `lgtv.ps1`; the script guarantees a single‑instance, watchdog protection, and a clear CLI for the most common TV actions.

---

## 📂 Project layout

```
LGTV/
├── lgtv.ps1          ← PowerShell
├── wrapper/          ← VBScript wrappers
    ├── startup_ps.vbs
    ├── shutdown_ps.vbs
    └── toggle_mode_ps.vbs
└── Legacy            ← Legacy Python version
```

---

## ⚙️ Core features

| Feature | How it works | Benefit |
|---------|--------------|---------|
| **Single‑instance guard** | Win32 named mutex `Global\LGTV` | Prevents fork‑bombing – only one instance can run at a time |
| **Watchdog** | 45 s hard‑kill timer | Guarantees the script terminates if it hangs |
| **Configuration** | Reads `wrapper/config.txt` and `lgtv_store.json` | Centralised path & TV settings |
| **PowerShell‑only CLI** | `-Action` parameter (`StartPersonal`, `Shutdown`, `Toggle`) | Simple command line for common tasks |
| **WebOS communication** | `LGWebOSClient` class handles TCP socket, JSON messaging, certificate validation, and command registration | Full control of TV functions (input, monitor mode, shutdown, etc.) |
| **Wake‑on‑LAN** | `Send-WOL` + `Find-TV` | Starts a sleeping TV |
| **Monitor mode switching** | `Set-MonitorMode`, `Get-ActiveMonitorCount` | Toggle between different HDMI inputs or app modes |
| **App management** | `Get-ForegroundAppId`, `Wait-ForForegroundApp` | Detect when a specific app is active |

---

## 📋 Configuration

1. **Run any function once
   This will create lgtv_store.json
   

2. **Store TV settings** in `C:\ProgramData\LGTVControl\lgtv_store.json` (or any location the script can write to).  
   At a minimum it must contain:

   ```json
   {
     "TV_MAC": "AA:BB:CC:DD:EE:FF",
     "SUBNET": "192.168.1.0/24"
   }
   ```

   *The script uses the MAC address to send a Wake‑on‑LAN packet and the subnet to locate the TV on the local network.*

---

## 🚀 Usage

```powershell
# Start personal mode (e.g. HDMI 3)
.\lgtv.ps1 -Action StartPersonal

# Shut down the TV
.\lgtv.ps1 -Action Shutdown

# Toggle between monitor modes
.\lgtv.ps1 -Action Toggle
```

> **`-Action`** accepts one of the following values:  
> `StartPersonal`, `Shutdown`, `Toggle`.

The script will:
1. Acquire the single‑instance mutex.  
2. Start the watchdog.  
3. Load configuration.  
4. Resolve the TV IP via WOL and subnet scanning.  
5. Perform the requested command (connect, send shutdown, toggle input).  
6. Clean up and exit.

---

## 📌 Group Policy / Task Scheduler

| Target | Setup |
|--------|-------|
| **Shutdown** | Add `wrapper\shutdown.vbs` to the *Shutdown* scripts, or schedule a task that runs `.\lgtv.ps1 -Action Shutdown`. |
| **Startup / Logon** | Add `wrapper\startup.vbs` to the *Startup* scripts, or schedule a task that runs `.\lgtv.ps1 -Action StartPersonal`. |

---

## 🔧 Debugging & Logging

* `Write-Log` writes to `C:\ProgramData\LGTVControl\lg_log.txt` (rotated at 10 MB).  
* If many PowerShell processes appear, ensure the single‑instance guard runs first.  
* If the TV does not respond, verify the MAC address and subnet in `lgtv_store.json`.  

---
