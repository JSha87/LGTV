' Silent startup script for LG TV Controller
' Runs python script with no visible window
' Uses relative paths - finds lgtv.py in parent directory
' Folder structure: LGTV\Startup\startup.vbs calls LGTV\lgtv.py

Set objShell = CreateObject("Wscript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Get this script's directory, then go up one level to find lgtv.py
strScriptPath = objFSO.GetParentFolderName(WScript.ScriptFullName)
strParentPath = objFSO.GetParentFolderName(strScriptPath)

' Run python script from parent directory
' Window style 0 = hidden (no console window)
' False = don't wait for script to complete (faster startup)
objShell.Run "python """ & strParentPath & "\lgtv.py"" startup_personal", 0, False