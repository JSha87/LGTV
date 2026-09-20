' =====================================================================
' LGTV state launcher
' =====================================================================
' Copy this one file three times and name the copies:
'
'     Personal.vbs
'     Work.vbs
'     Off.vbs
'
' The state is taken from the filename, so the three copies are byte
' identical and there is no per-file literal to forget to change. If the
' filename is not one of the three, DEFAULT_STATE is used.
'
' Layout assumed:   ...\LGTV\lgtv.ps1
'                   ...\LGTV\wrapper\Personal.vbs   (this file)
' =====================================================================

Option Explicit

Const DEFAULT_STATE = "Personal"
Const LOG_DIR  = "C:\ProgramData\LGTVControl"
Const LOG_FILE = "C:\ProgramData\LGTVControl\wrapper.log"
Const ForReading = 1
Const ForAppending = 8

Dim objShell, objFSO
Dim scriptDir, parentDir, configFile, configContent
Dim strPowerShell, strScript, strState
Dim exitCode

Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
parentDir = objFSO.GetParentFolderName(scriptDir)

' --- State from filename -------------------------------------------------
strState = LCase(objFSO.GetBaseName(WScript.ScriptFullName))
Select Case strState
    Case "personal" : strState = "Personal"
    Case "work"     : strState = "Work"
    Case "off"      : strState = "Off"
    Case Else       : strState = DEFAULT_STATE
End Select

' --- Defaults ------------------------------------------------------------
strPowerShell = objShell.ExpandEnvironmentStrings("%SystemRoot%") & _
                "\System32\WindowsPowerShell\v1.0\powershell.exe"
strScript = parentDir & "\lgtv.ps1"

' --- Optional config -----------------------------------------------------
configFile = scriptDir & "\config.txt"
If objFSO.FileExists(configFile) Then
    configContent = ReadAllText(configFile)
    strPowerShell = ConfigValue(configContent, "POWERSHELL_PATH", strPowerShell)
    strScript     = ConfigValue(configContent, "SCRIPT_PATH", strScript)
End If

' --- Preflight -----------------------------------------------------------
If Not objFSO.FileExists(strPowerShell) Then
    WriteLog "PowerShell not found at: " & strPowerShell
    WScript.Quit 2
End If

If Not objFSO.FileExists(strScript) Then
    WriteLog "Script not found at: " & strScript
    WScript.Quit 2
End If

' --- Run -----------------------------------------------------------------
' Run is called in function form so the child's exit code comes back, and
' that code is propagated with WScript.Quit. Without this, Task Scheduler
' reports every run as success even when the state failed to establish,
' and a hotkey gives you no signal at all.
On Error Resume Next
exitCode = objShell.Run( _
    """" & strPowerShell & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass " & _
    "-WindowStyle Hidden -File """ & strScript & """ " & strState, 0, True)

If Err.Number <> 0 Then
    WriteLog "Failed to launch " & strState & ": " & Err.Description
    Err.Clear
    On Error GoTo 0
    WScript.Quit 3
End If
On Error GoTo 0

If exitCode <> 0 Then WriteLog "State '" & strState & "' failed with exit code " & exitCode

WScript.Quit exitCode

' =====================================================================
' Helpers
' =====================================================================

Function ReadAllText(path)
    Dim f, txt
    ReadAllText = ""
    On Error Resume Next
    Set f = objFSO.OpenTextFile(path, ForReading)
    If Err.Number <> 0 Then Err.Clear : On Error GoTo 0 : Exit Function
    If Not f.AtEndOfStream Then txt = f.ReadAll
    f.Close                          ' closed unconditionally, even when empty
    On Error GoTo 0
    ReadAllText = txt
End Function

Function ConfigValue(content, keyName, fallback)
    ' Normalises CRLF and bare LF, ignores blank and # commented lines, and
    ' splits on the first "=" only, so a value containing "=" survives.
    Dim rows, row, i, pos, k, v
    ConfigValue = fallback
    content = Replace(Replace(content, vbCrLf, vbLf), vbCr, vbLf)
    rows = Split(content, vbLf)
    For i = 0 To UBound(rows)
        row = Trim(rows(i))
        If Len(row) > 0 And Left(row, 1) <> "#" And Left(row, 1) <> "'" Then
            pos = InStr(row, "=")
            If pos > 1 Then
                k = Trim(UCase(Left(row, pos - 1)))
                v = Trim(Mid(row, pos + 1))
                ' Tolerate a quoted path in the config file.
                If Len(v) > 1 And Left(v, 1) = """" And Right(v, 1) = """" Then
                    v = Mid(v, 2, Len(v) - 2)
                End If
                If k = UCase(keyName) And Len(v) > 0 Then ConfigValue = v
            End If
        End If
    Next
End Function

Sub WriteLog(message)
    Dim f
    On Error Resume Next
    If Not objFSO.FolderExists(LOG_DIR) Then objFSO.CreateFolder(LOG_DIR)
    Set f = objFSO.OpenTextFile(LOG_FILE, ForAppending, True)
    If Err.Number = 0 Then
        f.WriteLine Now & " [" & strState & "] " & message
        f.Close
    End If
    Err.Clear
    On Error GoTo 0
End Sub
