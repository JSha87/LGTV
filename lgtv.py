"""
LG WebOS TV Unified Controller
- Works for both USER and SYSTEM accounts
- Script in L:\Obsidian\Obsidian Vault\Scripts\LGTV
- Credentials stored in ProgramData (accessible to both USER and SYSTEM)
- Parallel fast scan (50 workers, short timeouts)
- Wake-on-LAN with direct IP send
- Auto pair + plaintext storage
- Safe connect with enforced timeout
- Input switching, shutdown, monitor toggles
"""

import os
import sys
import json
import socket
import time
import subprocess
import traceback
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
from pywebostv.connection import WebOSClient
from pywebostv.controls import ApplicationControl, SystemControl

# -------------------
# Config
# -------------------
MONITOR_TOOL = "MultiMonitorTool.exe"

# Script directory for MultiMonitorTool
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Credentials in ProgramData (accessible to both USER and SYSTEM)
STORAGE_DIR = os.path.join(os.environ.get("PROGRAMDATA", "C:\\ProgramData"), "LGTVControl")
STORE_FILE = os.path.join(STORAGE_DIR, "lgtv_store.json")
LOG_FILE = os.path.join(STORAGE_DIR, "lgtv.log")

# Network config - loaded from JSON
SUBNET = None
SCAN_TIMEOUT = 0.3     # socket timeout per probe (seconds)
MAX_SCAN_TIME = 5      # total scan ceiling (seconds)
THREADS = 50           # number of concurrent probes

PERSONAL_INPUT = "com.webos.app.hdmi3"
WORK_INPUT = "com.webos.app.hdmi4"

# Security-sensitive values - loaded from JSON
TV_MAC = None
WOL_PORT = 9

# Connect timeout for WebOSClient.connect()
CONNECT_TIMEOUT = 5.0  # seconds

# -------------------
# Logging
# -------------------
def log(msg, error=False):
    """
    Log message to console. Only write to file if error=True.
    """
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {msg}"
    
    # Always print to console
    print(line)
    
    # Only write to file on errors
    if error:
        try:
            # Ensure storage directory exists
            os.makedirs(STORAGE_DIR, exist_ok=True)
            
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception:
            # best-effort – avoid crashing on logging errors
            pass

# -------------------
# Store/load credentials and config
# -------------------
def init_store():
    """
    Create store file with placeholders if it doesn't exist.
    User must fill in TV_MAC and SUBNET before use.
    """
    template = {
        "_comment": "Fill in TV_MAC and SUBNET before first use. Script will populate tv_ip and client_key automatically.",
        "TV_MAC": "",  # Example: "44:27:45:76:93:4E"
        "SUBNET": "",  # Example: "192.168.5"
        "tv_ip": "",  # Example: "192.168.5.107" (auto-populated by script)
        "client_key": ""  # Auto-populated by script during pairing
    }
    
    # Ensure storage directory exists
    try:
        os.makedirs(STORAGE_DIR, exist_ok=True)
    except Exception as e:
        log(f"Failed to create storage directory: {e}", error=True)
        return False
    
    if not os.path.exists(STORE_FILE):
        log("Store file not found - creating template")
        try:
            with open(STORE_FILE, "w", encoding="utf-8") as f:
                json.dump(template, f, indent=2)
            log(f"Created template store file at: {STORE_FILE}")
            log("IMPORTANT: Edit store file and set TV_MAC and SUBNET values")
            return False
        except Exception as e:
            log(f"Failed to create store file: {e}", error=True)
            return False
    
    # File exists - check if all keys are present
    try:
        with open(STORE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        
        modified = False
        for key, default_value in template.items():
            if key not in data:
                log(f"Adding missing key to store: {key}")
                data[key] = default_value
                modified = True
        
        # Write back if we added missing keys
        if modified:
            with open(STORE_FILE, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
            log("Updated store file with missing keys")
        
        return True
        
    except Exception as e:
        log(f"Failed to update store file: {e}", error=True)
        return False

def load_config():
    """
    Load TV_MAC and SUBNET from store file.
    Returns True if valid config loaded, False otherwise.
    """
    global TV_MAC, SUBNET
    
    if not os.path.exists(STORE_FILE):
        log(f"Store file not found at: {STORE_FILE}", error=True)
        return False
    
    try:
        with open(STORE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        
        TV_MAC = data.get("TV_MAC", "")
        SUBNET = data.get("SUBNET", "")
        
        # Validate
        if not TV_MAC or TV_MAC == "":
            log("ERROR: TV_MAC not configured in store file", error=True)
            return False
        
        if not SUBNET or SUBNET == "":
            log("ERROR: SUBNET not configured in store file", error=True)
            return False
        
        mac_clean = TV_MAC.replace(":", "").replace("-", "")
        if len(mac_clean) != 12:
            log(f"ERROR: Invalid TV_MAC format in store file: {TV_MAC}", error=True)
            return False
        
        log(f"Loaded config: TV_MAC={TV_MAC}, SUBNET={SUBNET}")
        return True
        
    except Exception as e:
        log(f"Failed to load config from store file: {e}", error=True)
        return False

def store_data(ip, key):
    """
    Update tv_ip and client_key in store file.
    Preserves TV_MAC and SUBNET values.
    """
    try:
        # Ensure storage directory exists
        os.makedirs(STORAGE_DIR, exist_ok=True)
        
        # Load existing data to preserve config
        existing = {}
        if os.path.exists(STORE_FILE):
            with open(STORE_FILE, "r", encoding="utf-8") as f:
                existing = json.load(f)
        
        # Update only tv_ip and client_key
        existing["tv_ip"] = ip
        existing["client_key"] = key
        
        with open(STORE_FILE, "w", encoding="utf-8") as f:
            json.dump(existing, f, indent=2)
        
        log(f"Stored TV IP: {ip}")
        
    except Exception as e:
        log(f"Failed to write store file: {e}", error=True)

def load_data():
    """Load tv_ip and client_key from store file."""
    if not os.path.exists(STORE_FILE):
        return None, None
    try:
        with open(STORE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        ip = data.get("tv_ip")
        key = data.get("client_key")
        return ip, key
    except Exception as e:
        log(f"Failed to read store file: {e}", error=True)
        return None, None

# -------------------
# Fast parallel scan
# -------------------
def probe(ip):
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(SCAN_TIMEOUT)
        code = s.connect_ex((ip, 3001))
        return ip if code == 0 else None
    except Exception:
        return None
    finally:
        try:
            if s:
                s.close()
        except Exception:
            pass

def scan():
    log("Fast scanning for WebOS TV...")
    ips = [f"{SUBNET}.{i}" for i in range(1, 255)]
    found = None
    start = time.time()
    try:
        with ThreadPoolExecutor(max_workers=THREADS) as ex:
            futures = {ex.submit(probe, ip): ip for ip in ips}
            for future in as_completed(futures, timeout=MAX_SCAN_TIME):
                result = future.result()
                if result:
                    found = result
                    break
                # small early exit if time exceeded
                if time.time() - start > MAX_SCAN_TIME:
                    break
    except Exception:
        # as_completed timeout raises; we handle below
        pass

    if found:
        log(f"TV found at {found}")
        return found

    raise Exception("Failed to locate TV within scan window. Is the TV awake and on the same subnet?")

# -------------------
# Wake on LAN
# -------------------
def wol(target_ip=None):
    """
    Send WOL packet. If target_ip provided, send directly to that IP.
    Otherwise broadcast to subnet.
    """
    mac = TV_MAC.replace(":", "").replace("-", "")
    
    if len(mac) != 12:
        log(f"ERROR: Invalid MAC length ({len(mac)}), expected 12", error=True)
        return
    
    try:
        pkt = bytes.fromhex("FF" * 6 + mac * 16)
    except ValueError as e:
        log(f"ERROR: Failed to build magic packet: {e}", error=True)
        return
    
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        
        if target_ip:
            # Direct send to known IP
            log(f"WOL: Sending to {target_ip}:{WOL_PORT}")
            s.sendto(pkt, (target_ip, WOL_PORT))
        else:
            # Broadcast fallback
            broadcast_addr = f"{SUBNET}.255"
            log(f"WOL: Broadcasting to {broadcast_addr}:{WOL_PORT}")
            s.sendto(pkt, (broadcast_addr, WOL_PORT))
                
    except Exception as e:
        log(f"WOL failed: {e}", error=True)
    finally:
        try:
            if s:
                s.close()
        except Exception:
            pass

# -------------------
# Wait for TV to respond
# -------------------
def wait_for_tv(ip, max_wait=3, check_interval=1):
    """
    Wait for TV to respond to ping.
    Returns True if TV responds, False if timeout.
    """
    log(f"Waiting for TV at {ip} to respond (max {max_wait}s)...")
    waited = 0
    
    while waited < max_wait:
        try:
            # Use ping with 1 second timeout
            if sys.platform == "win32":
                result = subprocess.run(
                    ["ping", "-n", "1", "-w", "500", ip],
                    capture_output=True,
                    timeout=1
                )
            else:
                result = subprocess.run(
                    ["ping", "-c", "1", "-W", "1", ip],
                    capture_output=True,
                    timeout=1
                )
            
            if result.returncode == 0:
                log(f"TV responded to ping after {waited}s")
                return True
                
        except Exception as e:
            log(f"Ping check failed: {e}", error=True)
        
        time.sleep(check_interval)
        waited += check_interval
    
    log(f"WARNING: TV didn't respond to ping after {max_wait}s")
    return False

# -------------------
# Monitor utils
# -------------------
def get_active_monitors():
    """Get count of active monitors. Returns 1 if unable to determine."""
    try:
        import ctypes
        return ctypes.windll.user32.GetSystemMetrics(80)
    except Exception as e:
        log(f"Failed to query monitor count: {e}")
        return 1

import subprocess
import os

def set_monitor(action):
    """
    Enable or disable secondary monitor.
    Uses Windows built-in DisplaySwitch.exe which works across sessions.
    """
    # Map actions to DisplaySwitch modes:
    # /internal = PC screen only (primary monitor)
    # /external = Second screen only
    # /extend = Extend displays
    # /clone = Duplicate displays
    
    if action == "enable":
        mode = "/extend"
        log("Enabling monitor (extending displays)")
    elif action == "disable":
        mode = "/internal"
        log("Disabling secondary monitor (PC screen only)")
    else:
        log(f"Unknown monitor action: {action}", error=True)
        return
    
    try:
        # DisplaySwitch.exe is built into Windows and works across sessions
        subprocess.run(
            ["DisplaySwitch.exe", mode],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=6
        )
        log(f"Monitor mode set to {mode}")
    except Exception as e:
        log(f"DisplaySwitch failed: {e}", error=True)

def get_active_monitors():
    """
    Get count of active monitors.
    Note: When running as SYSTEM, this may not reflect user's session.
    """
    try:
        import ctypes
        count = ctypes.windll.user32.GetSystemMetrics(80)
        log(f"Detected {count} active monitors")
        return count
    except Exception as e:
        log(f"Failed to query monitor count: {e}")
        # Default to 1 for safety
        return 1

# -------------------
# TV connection & registration
# -------------------
def tv_connect():
    """Connect to TV and handle registration."""
    ip, key = load_data()
    if not ip:
        log("No stored IP - sending WOL + scan")
        wol()
        time.sleep(2)
        ip = scan()

    log(f"Connecting to LG TV ({ip})...")
    client = WebOSClient(ip, secure=True)

    # WebOS TLS wake delay handling - try up to 6 times with 0.5s delay
    for attempt in range(1, 7):
        try:
            client.connect()
            break
        except Exception as e:
            # Check for socket errors that indicate we should recreate the client
            error_str = str(e)
            if "10038" in error_str or "10054" in error_str:
                log(f"Connect attempt {attempt}/6 failed with socket error, recreating client")
                try:
                    client.disconnect()
                except Exception:
                    pass
                # Recreate client to get fresh socket
                client = WebOSClient(ip, secure=True)
            else:
                log(f"Connect attempt {attempt}/6 failed: {e}")
            time.sleep(0.5)
    else:
        raise Exception("WebSocket connect failed after wake attempts")

    store = {"client_key": key} if key else {}
    try:
        for _ in client.register(store):
            pass

        if "client_key" in store:
            store_data(ip, store["client_key"])

        return client
    except Exception as e:
        raise Exception(f"Registration failed: {e}")

# -------------------
# High-level actions
# -------------------
def switch(input_id):
    """Switch TV input."""
    c = tv_connect()
    try:
        ApplicationControl(c).launch({"id": input_id})
        log(f"Switched to input: {input_id}")
    except Exception as e:
        log(f"Failed to switch input: {e}", error=True)
        try:
            c.disconnect()
        except Exception:
            pass
        raise
    finally:
        try:
            c.disconnect()
        except Exception:
            pass

def do_shutdown():
    """Shut down the TV."""
    c = tv_connect()
    try:
        SystemControl(c).power_off()
        log("Shutdown command sent")
    except Exception as e:
        log(f"Shutdown failed: {e}", error=True)
        raise
    finally:
        try:
            c.disconnect()
        except Exception:
            pass

def do_startup_personal():
    """Startup sequence: Wake TV, switch to personal input, enable monitor."""
    log("=" * 60)
    log("Startup: PERSONAL mode")
    log("=" * 60)
    
    # Get stored IP first
    ip, key = load_data()
    
    if ip:
        log(f"Using stored IP: {ip}")
        # Send WOL directly to IP
        wol(target_ip=ip)
        
        # Wait for TV to wake
        wait_for_tv(ip, max_wait=3, check_interval=1)
        
        # Brief delay for webOS services
        log("Waiting for webOS services...")
        time.sleep(1)
    else:
        log("No stored IP - sending broadcast WOL + scanning")
        wol()  # broadcast
        time.sleep(2)
    
    log("Attempting to switch input...")
    try:
        switch(PERSONAL_INPUT)
        log("Input switch completed successfully")
    except Exception as e:
        log(f"Input switch failed: {e}", error=True)
        log("Retrying after brief delay...")
        time.sleep(1)
        try:
            switch(PERSONAL_INPUT)
            log("Input switch succeeded on retry")
        except Exception as e2:
            log(f"Retry also failed: {e2}", error=True)
            raise
    
    log("Enabling monitor...")
    set_monitor("enable")
    log("Startup sequence complete")
    log("=" * 60)

def do_toggle():
    """Toggle between work and personal modes based on monitor count."""
    monitors = get_active_monitors()
    if monitors > 1:
        log(f"{monitors} monitors detected -> Work mode")
        switch(WORK_INPUT)
        set_monitor("disable")
    else:
        log(f"{monitors} monitor detected -> Personal mode")
        switch(PERSONAL_INPUT)
        set_monitor("enable")

# -------------------
# CLI mapping
# -------------------
cmds = {
    "startup_personal": do_startup_personal,
    "toggle": do_toggle,
    "shutdown": do_shutdown,
    "scan": lambda: log(scan()),  # helper
}

if __name__ == "__main__":
    try:
        log(f"Running as: {os.environ.get('USERNAME', 'UNKNOWN')}")
        log(f"Script directory: {SCRIPT_DIR}")
        log(f"Storage location: {STORAGE_DIR}")
        
        # Initialize store file if missing
        if not init_store():
            sys.exit(1)
        
        # Load config from store
        if not load_config():
            log("ERROR: Configuration not complete. Please edit store file", error=True)
            log(f"Store file location: {STORE_FILE}", error=True)
            sys.exit(1)
        
        if len(sys.argv) < 2:
            raise ValueError("Missing command. Use one of: startup_personal, toggle, shutdown, scan")
        cmd = sys.argv[1]
        if cmd not in cmds:
            raise ValueError(f"Invalid command: {cmd}")
        cmds[cmd]()
    except Exception as e:
        log(f"ERROR: {e}\n{traceback.format_exc()}", error=True)
        sys.exit(1)