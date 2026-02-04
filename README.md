```markdown
# LG WebOS TV Unified Controller

A robust, "memory-safe" automation system for LG WebOS TVs. It handles startup, shutdown, and input switching based on monitor configuration (Work vs. Personal modes). It runs silently via VBScript wrappers and stores config safely in ProgramData.

## Folder Structure
```text
L:\Obsidian\Obsidian Vault\Scripts\LGTV\  <-- Root Folder
├── lgtv.py                               (Main Python Logic)
└── wrapper\                              (VBScript Launchers)
    ├── startup.vbs                       (Calls: startup_personal)
    ├── shutdown.vbs                      (Calls: shutdown)
    └── toggle_mode.vbs                   (Calls: toggle)

```

## Config Storage (Auto-Generated)

```text
C:\ProgramData\LGTVControl\
├── lgtv_store.json      (Config + Credentials - Accessible by USER and SYSTEM)
├── lgtv.log             (Error logs, auto-rotated)
└── script.lock          (Prevents multiple instances)

```

## 🛠️ Prerequisites & Dependencies

This script relies on Python and the `pywebostv` library to communicate with the TV.

1. **Install Python:** [Download Python for Windows](https://www.python.org/downloads/windows/)
2. **Install Library:** Open Command Prompt/PowerShell and run:
```powershell
pip install pywebostv

```



### About `pywebostv`

This script uses the **`pywebostv`** library to handle the handshake and communication with your LG TV.

* **Pairing:** It handles the cryptographic "Hello" that prompts the "Allow this device?" popup on your TV screen.
* **Security:** Once paired, it manages the secure WebSocket connection used to send commands (like "Switch Input" or "Turn Off").
* **Usage in Script:** We wrap this library in a safety layer that handles network timeouts, threading, and resource cleanup to prevent crashes.

---

## 🚀 Setup Steps

### 1. Create Folders

```powershell
mkdir "L:\Obsidian\Obsidian Vault\Scripts\LGTV\wrapper"

```

### 2. Copy Files

* Save `lgtv.py` to the **LGTV** root folder.
* Save `startup.vbs`, `shutdown.vbs`, and `toggle_mode.vbs` to the **wrapper** subfolder.

### 3. Initial Configuration

1. Open a terminal in the script folder:
```powershell
cd "L:\Obsidian\Obsidian Vault\Scripts\LGTV"

```


2. Run the script once to generate the config file:
```powershell
python lgtv.py scan

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
python lgtv.py startup_personal

```

* **Action:** Look at your TV screen and accept the connection request.
* The script will save the pairing key to `lgtv_store.json`. Future runs will be silent.

Test the other commands:

```powershell
python lgtv.py toggle           # Checks monitor count and switches input
python lgtv.py shutdown         # Turns the TV off

```

---

## 💻 How the Python Script Works

The `lgtv.py` script acts as a smart state machine:

1. **Discovery (Safe Scan):**
* If the TV's IP changes (DHCP), the script launches a multi-threaded scanner (limited to 15 threads to prevent freezing) to find the TV on your subnet `192.168.x.x`.
* Once found, it updates `lgtv_store.json` with the new IP.


2. **Wake-on-LAN (WOL):**
* If the TV is off (not responding to ping), the script sends a "Magic Packet" to the MAC address defined in your config to wake it up.
* It waits for the networking stack to initialize before attempting to connect.


3. **Monitor Control:**
* It uses Windows native `DisplaySwitch.exe` to toggle your PC's display mode.
* **Personal Mode:** Extends display (TV becomes second monitor).
* **Work Mode:** Internal display only (TV is disconnected from PC logic).


4. **Anti-Crash Safety:**
* **Watchdog:** If the script hangs for more than 60 seconds, a background timer kills the process to prevent memory leaks.
* **Locking:** Uses file locking to ensure only one instance runs at a time.



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

```

```