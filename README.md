# LG WebOS TV Unified Controller (Zero-Dependency & Fork‑Bomb Proof)

A high‑performance, *memory‑safe* automation system for LG WebOS TVs. This version is specifically hardened for Windows Group Policy environments to prevent process stacking (fork‑bombing) using **Kernel‑Level Mutex Locking**.

## 📂 Folder Structure

```text
C:\...\Scripts\LGTV\  <-- Root Folder
├── lgtv.py               (Main Python Logic – no external deps)
├── lgtv.ps1              (PowerShell launcher – single‑instance guard)
└── wrapper\              (Legacy VBScript wrappers – optional)
    ├── startup.vbs
    ├── shutdown.vbs
    └── toggle_mode.vbs
```

The PowerShell script `lgtv.ps1` now performs the same startup, shutdown, and toggle functions that the VBScript wrappers previously handled. It includes the robust single‑instance check, watchdog, and configuration loading.

## 🛡️ Robust Safety Logic

* **Kernel Mutex** – System‑wide `Global\LGTV` flag. If a second instance starts, it exits instantly.
* **pythonw.exe** – The PowerShell wrapper invokes the Python executable in windowless mode, keeping the UI silent.
* **Watchdog** – A 45‑second hard‑kill timer prevents zombie processes.

## 🚀 Setup Steps

### 1. Initial Configuration

Run the Python script once to generate the configuration file:

```powershell
python lgtv.py scan
```

Navigate to `C:\ProgramData\LGTVControl\` and edit **`lgtv_store.json`**:

```json
{
  "TV_MAC": "AA:BB:CC:DD:EE:FF",
  "SUBNET": "192.168.1"
}
```

### 2. Pairing

Turn your TV **ON** and run the following to trigger the pairing prompt:

```powershell
python lgtv.py startup_personal
```

Accept the request on the TV screen. The key is now stored permanently.

### 3. PowerShell Launcher

Use `lgtv.ps1` for all automated actions. Example commands:

```powershell
# Start personal mode (HDMI input 3)
./lgtv.ps1 -Action StartPersonal

# Shut down the TV
./lgtv.ps1 -Action Shutdown

# Toggle input mode
./lgtv.ps1 -Action Toggle
```

`lgtv.ps1` automatically reads `config.txt` in the wrapper folder to locate the Python interpreter and script. If `config.txt` is missing, it falls back to the hard‑coded defaults.

## 🏛️ Group Policy Configuration (Shutdown Only)

1. Open **Local Group Policy Editor** (`gpedit.msc`).
2. Navigate to **Computer Configuration → Windows Settings → Scripts (Startup/Shutdown)**.
3. For **Shutdown**, add `...\LGTV\wrapper\shutdown.vbs` (or use the PowerShell script directly via a scheduled task).

## 🏛️ Group Policy Configuration (Startup via Task Scheduler)

1. Open **Task Scheduler**.
2. Create a trigger for **User Logon**.
3. Add action `...\LGTV\wrapper\startup.vbs` (or `...\LGTV\lgtv.ps1` with the `StartPersonal` action).

## 🛠️ Path Configuration

Create a `config.txt` file in the `wrapper` directory with the following lines:

```
PYTHON_PATH=C:\Python\pythonw.exe
SCRIPT_PATH=L:\Documents\Scripts\Github\LGTV\lgtv.py
```

This keeps paths centralized and avoids editing multiple wrapper files.

## 🔧 PowerShell Wrapper Details

The `lgtv.ps1` script encapsulates the single‑instance guard, watchdog, configuration handling, and command dispatch. It mirrors the previous VBScript logic but offers clearer logging, better error handling, and native PowerShell conveniences.

## 📊 Performance & Safety Specs

| Feature | Logic | Benefit |
| --- | --- | --- |
| **Fork‑Bomb Protection** | Win32 Named Mutex (`Global\LGTV`) | Only one instance can exist system‑wide |
| **Execution Engine** | `pythonw.exe` via PowerShell | No console windows appear |
| **Subprocess Safety** | `proc.wait(timeout=X)` | Never hangs on a stuck command |
| **Memory Ceiling** | 50 concurrent threads | Rapid network scan without RAM bloat |
| **Log Rotation** | Auto‑rotate at 10 MB | Prevents `C:` drive from filling up |
| **Cleanup** | `os._exit(0)` | Immediate termination on lock detection |

## 🐛 Troubleshooting

* **Hundreds of Processes in Task Manager** – The single‑instance check isn’t running first. Ensure the guard runs before any network logic.
* **TV Won’t Wake** – Verify `TV_MAC` in `lgtv_store.json`. Some TVs require “Mobile TV On” enabled.
* **Permission Errors** – The script writes to `C:\ProgramData\LGTVControl`. Ensure the `SYSTEM` account has *Full Control* over that folder.

---

*This README has been updated to reflect the new PowerShell refactor and to remove obsolete VBScript references.*
