# Folder Structure for ***\LGTV
```
├── lgtv.py              (main script)
├── MultiMonitorTool.exe (monitor control)
├── startup.vbs          (for Group Policy)
└── shutdown.vbs         (for Group Policy)
```

# C:\ProgramData\LGTVControl\
```
├── lgtv_store.json      (config + credentials - accessible to USER and SYSTEM)
└── lgtv.log             (error logs)
```

Pre-requisites:
- https://www.python.org/downloads/windows/

Setup Steps:

# 1. Create Folders
mkdir "***\LGTV"

# 2. Copy Files
Save lgtv.py to ***\LGTV
Save startup.vbs to ***\LGTV
Save shutdown.vbs to ***\LGTV
Copy MultiMonitorTool.exe to ***\LGTV

# 3. Initial Setup
cd "***\LGTV"
python lgtv.py
This creates C:\ProgramData\LGTVControl\lgtv_store.json. 
Edit it and fill in TV_MAC and SUBNET.

# 4. Test
python lgtv.py startup_personal
python lgtv.py toggle
python lgtv.py shutdown

# 5. Configure Group Policy
Open Local Group Policy Editor (gpedit.msc):

# For Startup:
Go to: Computer Configuration → Windows Settings → Scripts (Startup/Shutdown)
Double-click Startup
Click Add
Script Name: ***\LGTVstartup.vbs
Click OK

# For Shutdown:
Double-click Shutdown
Click Add
Script Name: ***\LGTVshutdown.vbs
Click OK

# Benefits of This Setup:
✅ Scripts on selected drive - Easy to edit and version control
✅ Credentials in ProgramData - Accessible to both USER and SYSTEM
✅ Logs in ProgramData - Won't clutter your Obsidian vault
✅ Hard-coded paths in VBS - No relative path issues
✅ Silent execution - No console windows
The key is that the Python script is in your designated folder, while the credentials and logs are stored in ProgramData where both your user account and SYSTEM can read/write them!