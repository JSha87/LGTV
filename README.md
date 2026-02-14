# LG WebOS TV Unified Controller (Zero-Dependency & Fork-Bomb Proof)

A high-performance, "memory-safe" automation system for LG WebOS TVs. This version is specifically hardened for Windows Group Policy environments to prevent process stacking (fork-bombing) using **Kernel-Level Mutex Locking**.

## 📂 Folder Structure

```text
C:\...\Scripts\LGTV\  <-- Root Folder
├── lgtv_controller.py      (Main Python Logic - NO DEPENDENCIES)
└── wrapper\                (OLD VBScript Launchers)
    ├── startup.vbs         (Calls: startup_personal)
    ├── shutdown.vbs        (Calls: shutdown)
    └── toggle_mode.vbs     (Calls: toggle)

```

## 🛡️ "Robustat" Safety Logic

To prevent the common "GPO Fork Bomb" (where Windows triggers multiple instances that choke the CPU), this script utilizes:

* **Kernel Mutex:** Uses a system-wide "Global" flag. If a second instance starts (even under a different user account), it detects the lock and kills itself in milliseconds before any network logic runs.
* **pythonw.exe:** All wrappers are configured to use the windowless Python executable to ensure zero UI flicker.
* **Watchdog:** A 45-second hard-kill timer prevents zombie processes.

---

## 🚀 Setup Steps

### 1. Initial Configuration

Run the script once to generate the config file:

```powershell
python lgtv_controller.py scan

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
python lgtv_controller.py startup_personal

```

Accept the request on the TV screen. The key is now stored permanently.

---

## 🏛️ Group Policy Configuration (Recommended)

This setup ensures the TV starts when the PC boots and shuts down when the PC turns off.

1. Open **Local Group Policy Editor** (`gpedit.msc`).
2. Go to: **Computer Configuration → Windows Settings → Scripts (Startup/Shutdown)**.
3. **For Startup:**
* Double-click **Startup**.
* Add `...\LGTV\wrapper\startup.vbs`.


4. **For Shutdown:**
* Double-click **Shutdown**.
* Add `...\LGTV\wrapper\shutdown.vbs`.



> **Note:** We use the VBS wrappers because they resolve relative paths automatically, making the folder portable.

---

## 🔧 VBScript Wrappers

Update your wrapper files to use `pythonw.exe` for 100% silent execution.

### `startup.vbs`

```vbs
Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")
scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
parentDir = objFSO.GetParentFolderName(scriptDir)
pythonScript = parentDir & "\lgtv_controller.py"
' Using pythonw.exe for zero-window startup
objShell.Run "pythonw """ & pythonScript & """ startup_personal", 0, False

```

### `shutdown.vbs`

```vbs
Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")
scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
parentDir = objFSO.GetParentFolderName(scriptDir)
pythonScript = parentDir & "\lgtv_controller.py"
' Using pythonw.exe for zero-window shutdown
objShell.Run "pythonw """ & pythonScript & """ shutdown", 0, False

```

### `toggle_mode.vbs` (For Desktop Shortcut)

```vbs
Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")
scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
parentDir = objFSO.GetParentFolderName(scriptDir)
pythonScript = parentDir & "\lgtv_controller.py"
objShell.Run "pythonw """ & pythonScript & """ toggle", 0, False

```

---

## 📊 Performance & Safety Specs

| Feature | Logic | Benefit |
| --- | --- | --- |
| **Fork-Bomb Protection** | Win32 Named Mutex (`Global\`) | Only 1 instance can exist across all users/system. |
| **Execution Engine** | `pythonw.exe` | No black console windows ever appear. |
| **Subprocess Safety** | `proc.wait(timeout=X)` | Script never hangs on a stuck `ping` or `DisplaySwitch`. |
| **Memory Ceiling** | 50 concurrent threads | Rapid network scan without RAM bloat. |
| **Log Rotation** | Auto-rotate at 10MB | Prevents `C:` drive from filling up with error logs. |
| **Cleanup** | `os._exit(0)` | Immediate process termination on lock detection. |

---

## 🐛 Troubleshooting

* **Hundreds of Processes in Task Manager:** This indicates the `ensure_single_instance()` logic isn't running first. Ensure that function is called at the **top** of your script's execution block.
* **TV Won't Wake:** Verify `TV_MAC` is correct in `lgtv_store.json`. Some TVs require "Mobile TV On" to be enabled in the TV's network settings.
* **Permission Errors:** The script stores data in `C:\ProgramData\LGTVControl`. If the script fails, ensure the `SYSTEM` account has "Full Control" over that folder.

Would you like me to provide the **final optimized Python code block** for the `ensure_single_instance` function to make sure it matches this "Robustat" standard?