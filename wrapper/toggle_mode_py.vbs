Set objShell = CreateObject("Wscript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Get the directory containing this script
scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
parentDir = objFSO.GetParentFolderName(scriptDir)

' Define default paths (these can be overridden by config file)
strPython = "C:\Python314\pythonw.exe"
strScript = parentDir & "\lgtv.py"

' Try to read configuration from a simple text file if it exists
configFile = scriptDir & "\config.txt"
If objFSO.FileExists(configFile) Then
    On Error Resume Next
    Set objFile = objFSO.OpenTextFile(configFile, 1)
    If Not objFile.AtEndOfStream Then
        configContent = objFile.ReadAll
        objFile.Close

        ' Look for path definitions in the config file
        lines = Split(configContent, vbCrLf)
        For Each line In lines
            If InStr(line, "PYTHON_PATH=") > 0 Then
                newPath = Replace(line, "PYTHON_PATH=", "")
                ' Only override if path is not empty
                If Len(newPath) > 0 Then
                    strPython = newPath
                End If
            ElseIf InStr(line, "SCRIPT_PATH=") > 0 Then
                newPath = Replace(line, "SCRIPT_PATH=", "")
                ' Only override if path is not empty
                If Len(newPath) > 0 Then
                    strScript = newPath
                End If
            End If
        Next
    End If
    On Error Goto 0
End If

' Ensure the script exists before running
If objFSO.FileExists(strScript) Then
    objShell.Run """" & strPython & """ """ & strScript & """ toggle", 0, True
Else
    ' Log error to a file for debugging
    Set objLog = objFSO.OpenTextFile("C:\ProgramData\LGTVControl\gpo_error.txt", 8, True)
    objLog.WriteLine Now & " - Script not found at: " & strScript
    objLog.Close
End If
