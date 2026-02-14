Set objShell = CreateObject("Wscript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

'ABSOLUTE PATH FIX
strPython = "C:\Python314\pythonw.exe"
strScript = "L:\Documents\Scripts\Github\LGTV\lgtv.py"

If objFSO.FileExists(strScript) Then
    objShell.Run """" & strPython & """ """ & strScript & """ shutdown", 0, True
Else
    Set objLog = objFSO.OpenTextFile("C:\ProgramData\LGTVControl\gpo_error.txt", 8, True)
    objLog.WriteLine Now & " - Script not found at: " & strScript
    objLog.Close
End If
