# LG WebOS TV Unified Controller (Zero-Dependency & Fork-Bomb Proof)

A high-performance, "memory-safe" automation system for LG WebOS TVs. This version is specifically hardened for Windows Group Policy environments to prevent process stacking (fork-bombing) using **Kernel-Level Mutex Locking**.

## 📂 Folder Structure

```text
C:\...\Scripts\LGTV\  <-- Root Folder
├── lgtv_controller.py      (Main Python Logic - NO DEPENDENCIES)
└── wrapper\                (VBScript Launchers)
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

## 🛠️ Path Configuration

For easy maintenance, you can create a simple text configuration file named `config.txt` in each wrapper directory with these lines:

```
PYTHON_PATH=C:\Python314\pythonw.exe
SCRIPT_PATH=L:\Documents\Scripts\Github\LGTV\lgtv.py
```

This approach allows you to maintain paths in one location rather than updating each VBScript file separately.

### How to use:
1. Create a `config.txt` file in each wrapper directory (`startup.vbs`, `shutdown.vbs`, `toggle_mode.vbs`)
2. Update the paths to match your environment
3. The VBScript wrappers will automatically read these paths

> **Note:** If no config.txt is found, the scripts will use hardcoded default paths.

---

## 🔧 VBScript Wrappers

Wrapper files use `pythonw.exe` for 100% silent execution.

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
