Set objShell = CreateObject("Wscript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Get the directory containing this script (...\LGTV\wrapper)
scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
' lgtv.ps1 lives one level up (...\LGTV)
parentDir = objFSO.GetParentFolderName(scriptDir)

' Default paths (can be overridden by config file)
strPowerShell = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
strScript = parentDir & "\lgtv.ps1"

' Try to read configuration from a simple text file if it exists
configFile = scriptDir & "\config.txt"
If objFSO.FileExists(configFile) Then
    On Error Resume Next
    Set objFile = objFSO.OpenTextFile(configFile, 1)
    If Not objFile.AtEndOfStream Then
        configContent = objFile.ReadAll
        objFile.Close

        lines = Split(configContent, vbCrLf)
        For Each line In lines
            If InStr(line, "POWERSHELL_PATH=") > 0 Then
                newPath = Replace(line, "POWERSHELL_PATH=", "")
                If Len(newPath) > 0 Then strPowerShell = newPath
            ElseIf InStr(line, "SCRIPT_PATH=") > 0 Then
                newPath = Replace(line, "SCRIPT_PATH=", "")
                If Len(newPath) > 0 Then strScript = newPath
            End If
        Next
    End If
    On Error Goto 0
End If

' Ensure the script exists before running
If objFSO.FileExists(strScript) Then
    objShell.Run """" & strPowerShell & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strScript & """ toggle", 0, True
Else
    Set objLog = objFSO.OpenTextFile("C:\ProgramData\LGTVControl\gpo_error.txt", 8, True)
    objLog.WriteLine Now & " - Script not found at: " & strScript
    objLog.Close
End If
