Set objShell = CreateObject("Wscript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")
strScriptPath = objFSO.GetParentFolderName(WScript.ScriptFullName)
strParentPath = objFSO.GetParentFolderName(strScriptPath)
objShell.Run "python """ & strParentPath & "\lgtv.py"" toggle", 0, False