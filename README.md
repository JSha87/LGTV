# LG WebOS TV Unified Controller

A robust, "memory-safe" automation system for LG WebOS TVs with **zero external dependencies**. It handles startup, shutdown, and input switching based on monitor configuration (Work vs. Personal modes). It runs silently via VBScript wrappers and stores config safely in ProgramData.

## Folder Structure
```text
C:\...\Scripts\LGTV\  <-- Root Folder
├── lgtv_controller.py                    (Main Python Logic - NO DEPENDENCIES!)
└── wrapper\                              (VBScript Launchers)
    ├── startup.vbs                       (Calls: startup_personal)
    ├── shutdown.vbs                      (Calls: shutdown)
    └── toggle_mode.vbs                   (Calls: toggle)
```

## Config Storage (Auto-Generated)

```text
C:\ProgramData\LGTVControl\
├── lgtv_store.json      (Config + Credentials - Accessible by USER and SYSTEM)
├── lgtv.log             (Error logs, auto-rotated at 10MB)
└── script.lock          (Prevents multiple instances)
```

## 🛠️ Prerequisites & Dependencies

**This script requires ONLY Python 3.6+ (no pip packages needed!)**

1. **Install Python:** [Download Python for Windows](https://www.python.org/downloads/windows/)
   - That's it! No `pip install` required.

### Why No Dependencies?

The previous version relied on the `pywebostv` library, which required installation and could break during Python updates. This refactored version:

* ✅ **Built-in WebSocket Client:** Implements the WebSocket protocol using only Python's standard `socket` and `ssl` libraries
* ✅ **Native WebOS Protocol:** Handles TV pairing and command messaging directly without external libraries
* ✅ **Crash-Resistant:** Won't fail due to missing packages or version conflicts
* ✅ **Works Anywhere:** Runs on any Windows system with Python 3.6+ out of the box

---

## 🚀 Setup Steps

### 1. Create Folders

```powershell
mkdir "C:\...\LGTV\wrapper"
```

### 2. Copy Files

* Save `lgtv_controller.py` to the **LGTV** root folder.
* Save `startup.vbs`, `shutdown.vbs`, and `toggle_mode.vbs` to the **wrapper** subfolder.

### 3. Initial Configuration

1. Open a terminal in the script folder:
```powershell
cd "C:\...\LGTV"
```

2. Run the script once to generate the config file:
```powershell
python lgtv_controller.py scan
```

   *(This will fail to find the TV initially but creates the necessary folder structure).*

3. Navigate to `C:\ProgramData\LGTVControl\` and edit **`lgtv_store.json`**.

4. Fill in your TV's MAC Address and Subnet:
```json
{
  "TV_MAC": "AA:BB:CC:DD:EE:FF",
  "SUBNET": "192.168.1"
}
```

   *(Leave `tv_ip` and `client_key` blank; the script will populate these automatically).*

### 4. Pairing & Testing

Make sure your TV is **ON**. Run the startup command manually to trigger the pairing prompt on your TV:

```powershell
python lgtv_controller.py startup_personal
```

* **Action:** Look at your TV screen and accept the connection request.
* The script will save the pairing key to `lgtv_store.json`. Future runs will be silent.

Test the other commands:

```powershell
python lgtv_controller.py toggle           # Checks monitor count and switches input
python lgtv_controller.py shutdown         # Turns the TV off
```

---

## 💻 How the Python Script Works

The `lgtv_controller.py` script acts as a smart state machine:

1. **Discovery (Safe Scan):**
   * If the TV's IP changes (DHCP), the script launches a multi-threaded scanner (50 workers with strict timeout limits) to find the TV on your subnet `192.168.x.x`.
   * Once found, it updates `lgtv_store.json` with the new IP.

2. **Wake-on-LAN (WOL):**
   * If the TV is off (not responding to ping), the script sends a "Magic Packet" to the MAC address defined in your config to wake it up.
   * It waits for the networking stack to initialize before attempting to connect.

3. **WebSocket Communication:**
   * **Custom WebSocket Client:** Implements the WebSocket protocol from scratch using Python's `socket` and `ssl` libraries.
   * **Secure Connection:** Uses WSS (WebSocket Secure) over port 3001 with TLS encryption.
   * **WebOS Protocol:** Sends JSON commands directly to the TV (input switching, power off, etc.).
   * **Auto-Pairing:** Handles the cryptographic handshake and stores the client key for future sessions.

4. **Monitor Control:**
   * Uses Windows native `DisplaySwitch.exe` to toggle your PC's display mode.
   * **Personal Mode:** Extends display (TV becomes second monitor).
   * **Work Mode:** Internal display only (TV is disconnected from PC logic).

5. **Anti-Crash Safety:**
   * **Watchdog Timer:** If the script hangs for more than 45 seconds, a background timer kills the process to prevent memory leaks.
   * **File Locking:** Uses Windows file locking to ensure only one instance runs at a time (prevents fork-bomb behavior when run as SYSTEM).
   * **Bounded Retries:** All network operations have hard limits to prevent infinite loops.
   * **Log Rotation:** Error logs auto-rotate at 10MB to prevent disk bloat.
   * **Resource Cleanup:** All sockets and processes explicitly cleaned up in `finally` blocks.

---

## 🏛️ Group Policy Configuration

To make this run automatically at PC boot/shutdown:

1. Open **Local Group Policy Editor** (`gpedit.msc`).

### For Startup:

1. Go to: **Computer Configuration → Windows Settings → Scripts (Startup/Shutdown)**.
2. Double-click **Startup**.
3. Click **Add**.
4. **Script Name:** Browse to `...\LGTV\wrapper\startup.vbs`.
5. Click **OK**.

### For Shutdown:

1. Double-click **Shutdown**.
2. Click **Add**.
3. **Script Name:** Browse to `...\LGTV\wrapper\shutdown.vbs`.
4. Click **OK**.

### Benefits of This Setup:

✅ **Silent Execution:** VBS wrappers hide the black command prompt window.  
✅ **System-Wide Access:** Storing config in `ProgramData` allows the script to work even when run by the SYSTEM user (Group Policy) or your local User account.  
✅ **Hard-Coded Stability:** The VBS scripts use relative paths to find the Python file, so you can move the main folder without breaking links.  
✅ **No Dependencies:** Won't break when Python updates or during system maintenance.  
✅ **Fork-Bomb Protection:** Single-instance locking prevents runaway processes when triggered by Group Policy.

---

## 🔧 VBScript Wrappers (Update These!)

Update your VBS wrapper files to reference the new filename:

### startup.vbs
```vbs
Set objShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
parentDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(scriptDir)
pythonScript = parentDir & "\lgtv_controller.py"
objShell.Run "python """ & pythonScript & """ startup_personal", 0, False
```

### shutdown.vbs
```vbs
Set objShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
parentDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(scriptDir)
pythonScript = parentDir & "\lgtv_controller.py"
objShell.Run "python """ & pythonScript & """ shutdown", 0, False
```

### toggle_mode.vbs
```vbs
Set objShell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
parentDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(scriptDir)
pythonScript = parentDir & "\lgtv_controller.py"
objShell.Run "python """ & pythonScript & """ toggle", 0, False
```

---

## 🐛 Troubleshooting

### TV Not Found During Scan
- Verify your TV is powered on and connected to the network
- Check that `SUBNET` in `lgtv_store.json` matches your network (e.g., `192.168.1`)
- Try running: `python lgtv_controller.py scan` manually

### Connection Refused / Timeout
- Make sure your TV's firewall isn't blocking connections
- Verify the TV is on the same network as your PC
- Try power cycling the TV

### Pairing Fails
- Delete `client_key` from `lgtv_store.json` and re-run `startup_personal`
- Make sure to accept the prompt on your TV screen within 60 seconds
- Check error logs in `C:\ProgramData\LGTVControl\lgtv.log`

### Script Hangs
- The watchdog will automatically kill the process after 45 seconds
- Check logs for network issues or TV unresponsiveness
- Try deleting `script.lock` if the script won't run

### Monitor Switching Doesn't Work
- `DisplaySwitch.exe` may not work correctly when run as SYSTEM on all Windows versions
- Test manually with: `DisplaySwitch.exe /extend` and `DisplaySwitch.exe /internal`
- Consider adding user-level startup scripts if Group Policy version fails

---

## 📊 Performance & Safety

**Memory Safety Features:**
- Maximum 50 concurrent scan threads (prevents thread explosion)
- 5-second hard timeout on network scans
- 45-second watchdog timer (force exit if hung)
- 10MB log file rotation (prevents disk bloat)
- Explicit socket/process cleanup in all code paths
- Single-instance locking (prevents fork bombs)
- Bounded retry loops (max 6 connection attempts, 2 input switch attempts)

**Why This Matters:**
When running as SYSTEM via Group Policy, scripts that hang or leak resources can cause system-wide issues. Every timeout, loop, and resource has hard limits to ensure the script never consumes excessive CPU, memory, or disk space.

---

## 📝 License & Credits

This script implements the LG WebOS protocol based on the original `pywebostv` library's design, but rewritten from scratch to eliminate external dependencies.

**Original Library:** [pywebostv](https://github.com/klattimer/LGWebOSRemote)  
**WebSocket Protocol:** RFC 6455  
**WebOS API:** LG Electronics  

Free to use and modify. No warranty provided.