Set objShell = CreateObject("Wscript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")
'ABSSOLUTE PATH FIX
strPython = "C:\Python314\pythonw.exe"
strScript = "L:\Documents\Scripts\Github\LGTV\lgtv.py"

' 2. Check if the script exists before running
If objFSO.FileExists(strScript) Then
    ' Run with '0' to hide the window and 'True' to wait for completion
    objShell.Run """" & strPython & """ """ & strScript & """ toggle", 0, True
Else
    ' Log failure to your ProgramData log file for debugging
    Set objLog = objFSO.OpenTextFile("C:\ProgramData\LGTVControl\gpo_error.txt", 8, True)
    objLog.WriteLine Now & " - Script not found at: " & strScript
    objLog.Close
End If
