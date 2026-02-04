"""
LG WebOS TV Unified Controller - STABILIZED
- Reduced thread count to prevent resource exhaustion
- Improved single-instance locking
- Multiprocessing guards for Windows safety
"""

import os
import sys
import json
import socket
import time
import subprocess
import traceback
import threading
import multiprocessing  # Added for safety guard
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
from pywebostv.connection import WebOSClient
from pywebostv.controls import ApplicationControl, SystemControl

# -------------------
# Config
# -------------------

# Script directory
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Credentials in ProgramData
STORAGE_DIR = os.path.join(os.environ.get("PROGRAMDATA", "C:\\ProgramData"), "LGTVControl")
STORE_FILE = os.path.join(STORAGE_DIR, "lgtv_store.json")
LOG_FILE = os.path.join(STORAGE_DIR, "lgtv.log")

# Network config
SUBNET = None
SCAN_TIMEOUT = 0.5     # Slightly increased for reliability
MAX_SCAN_TIME = 10     # total scan ceiling
THREADS = 15           # REDUCED from 50 to 15 to prevent "fork bomb" behavior

PERSONAL_INPUT = "com.webos.app.hdmi3"
WORK_INPUT = "com.webos.app.hdmi4"

TV_MAC = None
WOL_PORT = 9
CONNECT_TIMEOUT = 5.0

# Memory safety limits
MAX_LOG_SIZE = 5 * 1024 * 1024  # Reduced to 5MB
MAX_CONNECT_RETRIES = 6
MAX_INPUT_SWITCH_RETRIES = 2
WATCHDOG_SEC = 60.0 

# -------------------
# Safety Mechanisms
# -------------------

def start_watchdog(seconds):
    """Force-kills the script if it hangs."""
    def kill_script():
        log(f"WATCHDOG: Script exceeded {seconds}s limit. Force exiting.", error=True)
        os._exit(1)
    
    t = threading.Timer(seconds, kill_script)
    t.daemon = True
    t.start()

def ensure_single_instance():
    """Prevents multiple copies of the script from running at once."""
    import msvcrt
    lock_path = os.path.join(STORAGE_DIR, "script.lock")
    try:
        os.makedirs(STORAGE_DIR, exist_ok=True)
        # Open in r+ (read/write) or w+ (create/write) but do NOT truncate immediately if exists
        # 'a' is safer to ensure we don't wipe another process's lock, 
        # but we need a file handle. 
        if not os.path.exists(lock_path):
            with open(lock_path, 'w') as f: f.write("LOCK")

        global _lock_fp
        _lock_fp = open(lock_path, 'r+')
        # Attempt non-blocking lock
        msvcrt.locking(_lock_fp.fileno(), msvcrt.LK_NBLCK, 1)
    except (IOError, PermissionError):
        # Already running
        sys.exit(0)

# -------------------
# Logging
# -------------------
def log(msg, error=False):
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {msg}"
    print(line)
    
    if error:
        try:
            os.makedirs(STORAGE_DIR, exist_ok=True)
            if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > MAX_LOG_SIZE:
                try:
                    os.remove(LOG_FILE) # Simple delete instead of rotate to save IO
                except Exception:
                    pass
            
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception:
            pass

# -------------------
# Config Logic
# -------------------
def init_store():
    # ... (Same as before, ensuring dir exists) ...
    template = {
        "TV_MAC": "", 
        "SUBNET": "", 
        "tv_ip": "", 
        "client_key": "" 
    }
    try:
        os.makedirs(STORAGE_DIR, exist_ok=True)
        if not os.path.exists(STORE_FILE):
            with open(STORE_FILE, "w", encoding="utf-8") as f:
                json.dump(template, f, indent=2)
            log(f"Created template at {STORE_FILE}. Please edit TV_MAC and SUBNET.")
            return False
            
        # Validate keys exist
        with open(STORE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        
        # Quick validation
        if "TV_MAC" not in data or "SUBNET" not in data:
            log("Store file corrupt or missing keys.")
            return False
            
        return True
    except Exception as e:
        log(f"Init store failed: {e}", error=True)
        return False

def load_config():
    global TV_MAC, SUBNET
    try:
        with open(STORE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        TV_MAC = data.get("TV_MAC", "")
        SUBNET = data.get("SUBNET", "")
        if not TV_MAC or not SUBNET:
            return False
        return True
    except Exception:
        return False

def store_data(ip, key):
    try:
        with open(STORE_FILE, "r", encoding="utf-8") as f:
            existing = json.load(f)
        existing["tv_ip"] = ip
        existing["client_key"] = key
        with open(STORE_FILE, "w", encoding="utf-8") as f:
            json.dump(existing, f, indent=2)
    except Exception as e:
        log(f"Store write failed: {e}", error=True)

def load_data():
    try:
        if not os.path.exists(STORE_FILE): return None, None
        with open(STORE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data.get("tv_ip"), data.get("client_key")
    except Exception:
        return None, None

# -------------------
# Scanning (Stabilized)
# -------------------
def probe(ip):
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(SCAN_TIMEOUT)
        if s.connect_ex((ip, 3001)) == 0:
            return ip
    except:
        pass
    finally:
        if s: s.close()
    return None

def scan():
    if not SUBNET:
        log("Cannot scan: Subnet not configured", error=True)
        return None

    log(f"Scanning {SUBNET}.x with {THREADS} threads...")
    ips = [f"{SUBNET}.{i}" for i in range(1, 255)]
    found = None
    
    executor = ThreadPoolExecutor(max_workers=THREADS)
    try:
        futures = {executor.submit(probe, ip): ip for ip in ips}
        
        for future in as_completed(futures, timeout=MAX_SCAN_TIME):
            result = future.result()
            if result:
                found = result
                break
    except Exception as e:
        log(f"Scan error: {e}", error=True)
    finally:
        executor.shutdown(wait=False) # Ensure threads are killed
        
    if found:
        log(f"Found TV at {found}")
    else:
        log("Scan failed to find TV")
    return found

# -------------------
# WOL & Network
# -------------------
def wol(target_ip=None):
    if not TV_MAC: return
    mac = TV_MAC.replace(":", "").replace("-", "")
    try:
        pkt = bytes.fromhex("FF" * 6 + mac * 16)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        target = target_ip if target_ip else f"{SUBNET}.255"
        s.sendto(pkt, (target, WOL_PORT))
        s.close()
    except Exception as e:
        log(f"WOL error: {e}", error=True)

def is_tv_responding(ip):
    return probe(ip) is not None

def wait_for_tv(ip, max_wait=3):
    log(f"Pinging {ip}...")
    # Pure Python ping via socket connect check is safer than subprocess in a loop
    start = time.time()
    while time.time() - start < max_wait:
        if is_tv_responding(ip):
            return True
        time.sleep(1)
    return False

# -------------------
# Monitor Control
# -------------------
def set_monitor(action):
    mode = "/extend" if action == "enable" else "/internal"
    try:
        subprocess.run(["DisplaySwitch.exe", mode], timeout=5, check=False)
    except Exception as e:
        log(f"DisplaySwitch error: {e}", error=True)

def get_active_monitors():
    try:
        import ctypes
        return ctypes.windll.user32.GetSystemMetrics(80)
    except:
        return 1

# -------------------
# Connection Logic
# -------------------
def tv_connect():
    ip, key = load_data()
    
    # 1. Discovery Phase
    if not ip:
        log("IP unknown. Sending WOL and Scanning.")
        wol() 
        time.sleep(3)
        ip = scan()
        if not ip: raise Exception("TV not found via scan")
        store_data(ip, key)
    
    # 2. Wake Phase
    if not is_tv_responding(ip):
        log(f"TV {ip} asleep. Sending WOL.")
        wol(ip)
        # Wait up to 15s for network stack to wake
        for _ in range(15):
            if is_tv_responding(ip): break
            time.sleep(1)
            
    # 3. Connect Phase
    log(f"Connecting to {ip}...")
    client = WebOSClient(ip, secure=True)
    try:
        client.connect()
    except Exception:
        # Retry once with fresh client
        time.sleep(1)
        client = WebOSClient(ip, secure=True)
        client.connect()

    # 4. Auth Phase
    store = {"client_key": key} if key else {}
    for _ in client.register(store):
        pass # Consume generator
        
    if "client_key" in store and store["client_key"] != key:
        store_data(ip, store["client_key"])
        
    return client

# -------------------
# Commands
# -------------------
def switch(input_id):
    client = None
    try:
        client = tv_connect()
        ApplicationControl(client).launch({"id": input_id})
    except Exception as e:
        log(f"Switch failed: {e}", error=True)
    finally:
        if client: 
            try: client.disconnect() 
            except: pass

def do_startup_personal():
    # If we have an IP, try direct WOL first to save time
    ip, _ = load_data()
    if ip: wol(ip)
    else: wol()
    
    switch(PERSONAL_INPUT)
    set_monitor("enable")

def do_toggle():
    if get_active_monitors() > 1:
        switch(WORK_INPUT)
        set_monitor("disable")
    else:
        switch(PERSONAL_INPUT)
        set_monitor("enable")

def do_shutdown():
    try:
        client = tv_connect()
        SystemControl(client).power_off()
    except Exception as e:
        log(f"Shutdown failed: {e}", error=True)

# -------------------
# Main Entry Point
# -------------------
if __name__ == "__main__":
    # CRITICAL: Prevent Windows multiprocessing recursion
    multiprocessing.freeze_support()
    
    # CRITICAL: Prevent file shadowing check
    # If you have files named socket.py, json.py, etc in this folder, exit immediately
    for risky in ['socket', 'json', 'threading', 'subprocess', 'email']:
        if os.path.exists(os.path.join(SCRIPT_DIR, f"{risky}.py")):
            print(f"FATAL ERROR: You have a file named '{risky}.py' in the script folder.")
            print("This causes Python to break. Rename it immediately.")
            sys.exit(1)

    ensure_single_instance()
    start_watchdog(WATCHDOG_SEC)

    try:
        if not init_store(): sys.exit(1)
        if not load_config(): sys.exit(1)

        if len(sys.argv) < 2:
            log("No command provided.")
            sys.exit(1)

        cmd = sys.argv[1]
        commands = {
            "startup_personal": do_startup_personal,
            "toggle": do_toggle,
            "shutdown": do_shutdown,
            "scan": lambda: scan()
        }
        
        if cmd in commands:
            commands[cmd]()
        else:
            log(f"Unknown command: {cmd}")

    except Exception as e:
        log(f"Global Error: {e}", error=True)
        sys.exit(1)