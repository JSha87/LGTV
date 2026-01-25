"""
LG WebOS TV Unified Controller - Production Memory-Safe Version
- Works for both USER and SYSTEM accounts
- Script in L:\Obsidian\Obsidian Vault\Scripts\LGTV
- Credentials stored in ProgramData (accessible to both USER and SYSTEM)
- Parallel fast scan (50 workers, short timeouts)
- Wake-on-LAN with direct IP send
- Auto pair + plaintext storage
- Safe connect with enforced timeout
- Input switching, shutdown, monitor toggles
- MEMORY SAFE: Proper resource cleanup, bounded retries, explicit limits
"""

import os
import sys
import json
import socket
import time
import subprocess
import traceback
import threading
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
from pywebostv.connection import WebOSClient
from pywebostv.controls import ApplicationControl, SystemControl

# -------------------
# Config
# -------------------

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

# Memory safety limits
MAX_LOG_SIZE = 10 * 1024 * 1024  # 10MB max log file
MAX_CONNECT_RETRIES = 6
MAX_INPUT_SWITCH_RETRIES = 2
MAX_FUTURES_IN_MEMORY = 100  # Limit concurrent futures
WATCHDOG_SEC = 45.0 # Hard exit after 45 seconds no matter what

# -------------------
# New Safety Mechanisms
# -------------------

def start_watchdog(seconds):
    """Force-kills the script if it hangs, preventing RAM accumulation."""
    def kill_script():
        log(f"WATCHDOG: Script exceeded {seconds}s limit. Force exiting.", error=True)
        os._exit(1) # Immediate kernel-level exit
    
    t = threading.Timer(seconds, kill_script)
    t.daemon = True
    t.start()

def ensure_single_instance():
    """Prevents multiple copies of the script from running at once."""
    import msvcrt
    lock_path = os.path.join(STORAGE_DIR, "script.lock")
    try:
        # We must keep this file handle open for the duration of the script
        global _lock_fp
        _lock_fp = open(lock_path, 'w')
        msvcrt.locking(_lock_fp.fileno(), msvcrt.LK_NBLCK, 1)
    except (IOError, PermissionError):
        # Silent exit if another instance is already running
        sys.exit(0)

# -------------------
# Logging
# -------------------
def log(msg, error=False):
    """
    Log message to console. Only write to file if error=True.
    Implements log rotation to prevent unbounded growth.
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
            
            # Check log file size and rotate if needed
            if os.path.exists(LOG_FILE):
                try:
                    if os.path.getsize(LOG_FILE) > MAX_LOG_SIZE:
                        # Rotate log file
                        backup = LOG_FILE + ".old"
                        if os.path.exists(backup):
                            os.remove(backup)
                        os.rename(LOG_FILE, backup)
                except (OSError, IOError):
                    # If rotation fails, truncate the file
                    try:
                        with open(LOG_FILE, "w", encoding="utf-8") as f:
                            f.write(f"[{stamp}] Log rotated due to size\n")
                    except Exception:
                        pass
            
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
# Fast parallel scan with memory safety
# -------------------
def probe(ip):
    """
    Probe a single IP for WebOS TV.
    MEMORY SAFE: Explicit socket cleanup in finally block.
    """
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(SCAN_TIMEOUT)
        code = s.connect_ex((ip, 3001))
        return ip if code == 0 else None
    except Exception:
        return None
    finally:
        if s is not None:
            try:
                s.close()
            except Exception:
                pass

def scan():
    """
    MEMORY SAFE: Bounded executor, explicit cleanup, early exit.
    """
    log("Fast scanning for WebOS TV...")
    ips = [f"{SUBNET}.{i}" for i in range(1, 255)]
    found = None
    start = time.time()
    executor = None
    
    try:
        executor = ThreadPoolExecutor(max_workers=THREADS)
        futures = {}
        
        # Submit jobs in batches to limit memory
        for i in range(0, len(ips), MAX_FUTURES_IN_MEMORY):
            batch = ips[i:i + MAX_FUTURES_IN_MEMORY]
            batch_futures = {executor.submit(probe, ip): ip for ip in batch}
            futures.update(batch_futures)
            
            # Process this batch
            for future in as_completed(batch_futures, timeout=MAX_SCAN_TIME):
                try:
                    result = future.result(timeout=1.0)
                    if result:
                        found = result
                        # Cancel remaining futures to free memory
                        for f in futures:
                            f.cancel()
                        return found
                except Exception:
                    pass
                
                # Early exit if time exceeded
                if time.time() - start > MAX_SCAN_TIME:
                    for f in futures:
                        f.cancel()
                    break
            
            if found or (time.time() - start > MAX_SCAN_TIME):
                break
                
    except Exception as e:
        log(f"Scan error: {e}", error=True)
    finally:
        # Explicit cleanup
        if executor is not None:
            try:
                executor.shutdown(wait=False, cancel_futures=True)
            except Exception:
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
    MEMORY SAFE: Explicit socket cleanup.
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
        if s is not None:
            try:
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
    MEMORY SAFE: Bounded subprocess execution.
    """
    log(f"Waiting for TV at {ip} to respond (max {max_wait}s)...")
    waited = 0
    
    while waited < max_wait:
        proc = None
        try:
            # Use ping with 1 second timeout
            if sys.platform == "win32":
                proc = subprocess.Popen(
                    ["ping", "-n", "1", "-w", "500", ip],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
            else:
                proc = subprocess.Popen(
                    ["ping", "-c", "1", "-W", "1", ip],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
            
            # Wait with timeout
            try:
                returncode = proc.wait(timeout=2)
                if returncode == 0:
                    log(f"TV responded to ping after {waited}s")
                    return True
            except subprocess.TimeoutExpired:
                # Kill the process if it times out
                proc.kill()
                proc.wait()
                
        except Exception as e:
            log(f"Ping check failed: {e}", error=True)
        finally:
            # Ensure process is cleaned up
            if proc is not None:
                try:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait()
                except Exception:
                    pass
        
        time.sleep(check_interval)
        waited += check_interval
    
    log(f"WARNING: TV didn't respond to ping after {max_wait}s")
    return False

# -------------------
# Monitor utils
# -------------------
def set_monitor(action):
    """
    Enable or disable secondary monitor.
    Uses Windows built-in DisplaySwitch.exe which works across sessions.
    MEMORY SAFE: Bounded subprocess execution with timeout.
    """
    if action == "enable":
        mode = "/extend"
        log("Enabling monitor (extending displays)")
    elif action == "disable":
        mode = "/internal"
        log("Disabling secondary monitor (PC screen only)")
    else:
        log(f"Unknown monitor action: {action}", error=True)
        return
    
    proc = None
    try:
        proc = subprocess.Popen(
            ["DisplaySwitch.exe", mode],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        
        # Wait with timeout
        try:
            proc.wait(timeout=6)
            log(f"Monitor mode set to {mode}")
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            log(f"DisplaySwitch timed out but command sent", error=True)
            
    except Exception as e:
        log(f"DisplaySwitch failed: {e}", error=True)
    finally:
        if proc is not None:
            try:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
            except Exception:
                pass

def get_active_monitors():
    """
    Get count of active monitors.
    Note: When running as SYSTEM, this may not reflect user's session.
    MEMORY SAFE: No resource leaks.
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
# TV alive check
# -------------------
def is_tv_responding(ip, timeout=1.0):
    """
    Quick check if TV is responding on port 3001.
    Returns True if TV responds, False otherwise.
    MEMORY SAFE: Explicit socket cleanup.
    """
    s = None
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        result = s.connect_ex((ip, 3001))
        return result == 0
    except Exception:
        return False
    finally:
        if s is not None:
            try:
                s.close()
            except Exception:
                pass

# -------------------
# TV connection & registration
# -------------------
def tv_connect():
    """
    Connect to TV and handle registration.
    Checks if TV is responding first, sends WOL if not.
    MEMORY SAFE: Bounded retries, explicit client cleanup on error.
    """
    ip, key = load_data()
    
    if not ip:
        log("No stored IP - sending WOL + scan")
        wol()
        time.sleep(2)
        ip = scan()
        store_data(ip, key or "")  # Store the discovered IP
    
    # Check if TV is responding before attempting connection
    log(f"Checking if TV at {ip} is responding...")
    if not is_tv_responding(ip):
        log("TV not responding - sending WOL packet")
        wol(target_ip=ip)
        
        # Wait for TV to wake up
        log("Waiting for TV to wake...")
        max_wake_wait = 10  # seconds
        wake_start = time.time()
        
        while time.time() - wake_start < max_wake_wait:
            time.sleep(1)
            if is_tv_responding(ip):
                log(f"TV responded after {int(time.time() - wake_start)}s")
                break
        else:
            log("WARNING: TV did not respond after WOL - attempting connection anyway", error=True)
        
        # Additional delay for webOS services to start
        time.sleep(2)
    else:
        log("TV is responding")

    log(f"Connecting to LG TV ({ip})...")
    client = None
    
    try:
        client = WebOSClient(ip, secure=True)

        # WebOS TLS wake delay handling - bounded retries
        for attempt in range(1, MAX_CONNECT_RETRIES + 1):
            try:
                client.connect()
                break
            except Exception as e:
                # Check for socket errors that indicate we should recreate the client
                error_str = str(e)
                if "10038" in error_str or "10054" in error_str:
                    log(f"Connect attempt {attempt}/{MAX_CONNECT_RETRIES} failed with socket error, recreating client")
                    # Clean up old client
                    try:
                        client.disconnect()
                    except Exception:
                        pass
                    # Recreate client to get fresh socket
                    client = WebOSClient(ip, secure=True)
                else:
                    log(f"Connect attempt {attempt}/{MAX_CONNECT_RETRIES} failed: {e}")
                
                if attempt == MAX_CONNECT_RETRIES:
                    raise Exception(f"WebSocket connect failed after {MAX_CONNECT_RETRIES} attempts")
                    
                time.sleep(0.5)

        store = {"client_key": key} if key else {}
        
        # Registration with bounded iteration
        reg_count = 0
        for _ in client.register(store):
            reg_count += 1
            if reg_count > 10:  # Prevent infinite registration loop
                raise Exception("Registration loop exceeded maximum iterations")

        if "client_key" in store:
            store_data(ip, store["client_key"])

        return client
        
    except Exception as e:
        # Clean up client on error
        if client is not None:
            try:
                client.disconnect()
            except Exception:
                pass
        raise Exception(f"Connection/registration failed: {e}")

# -------------------
# High-level actions
# -------------------
def switch(input_id):
    """
    Switch TV input.
    MEMORY SAFE: Guaranteed client cleanup via try/finally.
    """
    client = None
    try:
        client = tv_connect()
        ApplicationControl(client).launch({"id": input_id})
        log(f"Switched to input: {input_id}")
    except Exception as e:
        log(f"Failed to switch input: {e}", error=True)
        raise
    finally:
        if client is not None:
            try:
                client.disconnect()
            except Exception:
                pass

def do_shutdown():
    """
    Shut down the TV.
    MEMORY SAFE: Guaranteed client cleanup via try/finally.
    """
    client = None
    try:
        client = tv_connect()
        SystemControl(client).power_off()
        log("Shutdown command sent")
    except Exception as e:
        log(f"Shutdown failed: {e}", error=True)
        raise
    finally:
        if client is not None:
            try:
                client.disconnect()
            except Exception:
                pass

def do_startup_personal():
    """
    Startup sequence: Wake TV, switch to personal input, enable monitor.
    MEMORY SAFE: Bounded retries, explicit resource cleanup.
    """
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
    
    # Bounded retry loop
    for retry in range(1, MAX_INPUT_SWITCH_RETRIES + 1):
        try:
            switch(PERSONAL_INPUT)
            log("Input switch completed successfully")
            break
        except Exception as e:
            if retry == MAX_INPUT_SWITCH_RETRIES:
                log(f"Input switch failed after {MAX_INPUT_SWITCH_RETRIES} attempts: {e}", error=True)
                raise
            else:
                log(f"Input switch attempt {retry}/{MAX_INPUT_SWITCH_RETRIES} failed: {e}", error=True)
                log("Retrying after brief delay...")
                time.sleep(1)
    
    log("Enabling monitor...")
    set_monitor("enable")
    log("Startup sequence complete")
    log("=" * 60)

def do_toggle():
    """
    Toggle between work and personal modes based on monitor count.
    MEMORY SAFE: All called functions have proper cleanup.
    """
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
    # 1. Immediate Safety Locks
    ensure_single_instance()
    start_watchdog(WATCHDOG_SEC)

    try:
        log(f"Running as: {os.environ.get('USERNAME', 'UNKNOWN')}")
        
        if not init_store(): sys.exit(1)
        if not load_config(): sys.exit(1)
        
        if len(sys.argv) < 2:
            raise ValueError("Missing command.")
            
        cmd = sys.argv[1]
        
        # Mapping commands based on your wrappers
        # startup.vbs uses 'startup_personal' 
        # toggle_mode.vbs uses 'toggle' 
        # shutdown.vbs uses 'shutdown' 
        cmds = {
            "startup_personal": do_startup_personal,
            "toggle": do_toggle,
            "shutdown": do_shutdown,
            "scan": lambda: log(scan()),
        }

        if cmd not in cmds:
            raise ValueError(f"Invalid command: {cmd}")
            
        cmds[cmd]()
        log("Execution finished cleanly.")

    except Exception as e:
        log(f"ERROR: {e}\n{traceback.format_exc()}", error=True)
        sys.exit(1)