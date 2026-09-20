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
'
' Design rules mirrored from lgtv.ps1:
'
'   * Fail loud. The child's exit code is propagated verbatim so Task
'     Scheduler and hotkey frameworks see failures. The wrapper never
'     substitutes its own success for the child's.
'
'   * Log only what matters. Successful runs leave no trace by default.
'     The DEBUG_MODE flag lives in lgtv_store.json - the same file
'     lgtv.ps1 reads - so both agree on one switch. Set it to true in
'     the JSON to log every invocation from both processes.
'
'   * Log writes overwrite, never append. The whole file is rewritten
'     from in-memory content on every successful line. No temp file is
'     ever produced, matching how lgtv.ps1 writes its own log.
' =====================================================================

Option Explicit

Const DEFAULT_STATE       = "Personal"
Const DEFAULT_DEBUG_MODE  = False
Const LOG_DIR             = "C:\ProgramData\LGTVControl"
Const LOG_FILE            = "C:\ProgramData\LGTVControl\wrapper.log"
Const STORE_FILE          = "C:\ProgramData\LGTVControl\lgtv_store.json"
Const MAX_LOG_BYTES       = 2097152   ' 2 MB, matches lgtv.ps1
Const ForReading          = 1
Const ForWriting          = 2
Const TristateUseDefault  = -2

Dim objShell, objFSO, objEnv
Dim scriptDir, parentDir, configFile, configContent
Dim strPowerShell, strScript, strState
Dim debugMode
Dim exitCode

Set objShell = CreateObject("WScript.Shell")
Set objFSO   = CreateObject("Scripting.FileSystemObject")
Set objEnv   = objShell.Environment("Process")

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

' --- Debug flag from the shared store ------------------------------------
' Same file lgtv.ps1 reads. If the store is missing or unreadable, the
' literal DEFAULT_DEBUG_MODE is used and the wrapper proceeds - the PS
' script will repair the store on its own next run.
debugMode = ReadDebugMode()

' --- Defaults ------------------------------------------------------------
strPowerShell = objEnv("SystemRoot") & _
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
    WriteLog "PowerShell not found at: " & strPowerShell, True
    WScript.Quit 2
End If

If Not objFSO.FileExists(strScript) Then
    WriteLog "Script not found at: " & strScript, True
    WScript.Quit 2
End If

If debugMode Then
    WriteLog "Launching state '" & strState & "' -> " & strScript, False
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
    WriteLog "Failed to launch " & strState & ": " & Err.Description, True
    Err.Clear
    On Error GoTo 0
    WScript.Quit 3
End If
On Error GoTo 0

If exitCode <> 0 Then
    WriteLog "State '" & strState & "' failed with exit code " & exitCode, True
ElseIf debugMode Then
    WriteLog "State '" & strState & "' established (exit 0).", False
End If

WScript.Quit exitCode


' =====================================================================
' Helpers
' =====================================================================

Function ReadDebugMode()
    ' Reads the DEBUG_MODE value out of lgtv_store.json. The store is
    ' written by lgtv.ps1 via ConvertTo-Json, so the value is always a
    ' bare JSON boolean on one line:  "DEBUG_MODE": false
    '
    ' A regex is used because VBScript has no JSON parser and importing
    ' one would add a dependency for a single boolean. The pattern is
    ' anchored on the exact key name to avoid matching _comment text.
    '
    ' Any failure - missing file, unreadable file, absent key, malformed
    ' JSON around the key - falls back to DEFAULT_DEBUG_MODE. This is
    ' deliberate: the wrapper runs before lgtv.ps1 has had a chance to
    ' repair the store, so it cannot depend on the store being healthy.
    Dim content, re, matches
    ReadDebugMode = DEFAULT_DEBUG_MODE
    content = ReadAllText(STORE_FILE)
    If Len(content) = 0 Then Exit Function
    On Error Resume Next
    Set re = New RegExp
    re.Pattern = """DEBUG_MODE""\s*:\s*(true|false)"
    re.IgnoreCase = True
    Set matches = re.Execute(content)
    If Err.Number = 0 Then
        If matches.Count > 0 Then
            ReadDebugMode = (LCase(matches(0).SubMatches(0)) = "true")
        End If
    End If
    Err.Clear
    On Error GoTo 0
End Function

Function ReadAllText(path)
    ' Returns "" if the file cannot be read. On read failure, attempts an
    ' ACL repair and retries once - this is the case where an editor's
    ' save broke the DACL. If the retry also fails, "" is returned and the
    ' caller treats the file as having no prior content.
    Dim f, txt
    ReadAllText = ""
    On Error Resume Next
    Set f = objFSO.OpenTextFile(path, ForReading, False, TristateUseDefault)
    If Err.Number <> 0 Then
        Err.Clear
        RepairAcl path
        Set f = objFSO.OpenTextFile(path, ForReading, False, TristateUseDefault)
        If Err.Number <> 0 Then Err.Clear : On Error GoTo 0 : Exit Function
    End If
    If Not f.AtEndOfStream Then txt = f.ReadAll
    f.Close
    On Error GoTo 0
    ReadAllText = txt
End Function

Function FileLength(path)
    Dim f
    FileLength = -1
    On Error Resume Next
    Set f = objFSO.GetFile(path)
    If Err.Number = 0 Then FileLength = f.Size
    Err.Clear
    On Error GoTo 0
End Function

Sub RepairAcl(path)
    ' Mirrors Repair-StorageAcl in lgtv.ps1. takeown /A sets the owner to
    ' Administrators (of which SYSTEM is a member); icacls /grant then
    ' re-applies the three identities lgtv.ps1 applies. SIDs are used so
    ' the grants are locale-independent - SYSTEM / Administrators / Users
    ' translate differently on non-English Windows.
    '
    ' takeown and icacls enable SeTakeOwnershipPrivilege inside their own
    ' process token, which the direct .NET route does not. That matters
    ' when the file has been replaced by an editor: the current identity
    ' has lost WriteDAC on the new file and cannot restore it via Set-Acl,
    ' but it can still take ownership and rewrite the DACL from there.
    Dim takeown, icacls
    On Error Resume Next
    takeown = objEnv("SystemRoot") & "\System32\takeown.exe"
    icacls  = objEnv("SystemRoot") & "\System32\icacls.exe"
    If objFSO.FileExists(takeown) Then
        objShell.Run """" & takeown & """ /F """ & path & """ /A", 0, True
    End If
    If objFSO.FileExists(icacls) Then
        objShell.Run """" & icacls & """ """ & path & """ /grant " & _
                     "*S-1-5-18:F *S-1-5-32-544:F *S-1-5-32-545:M", 0, True
    End If
    Err.Clear
    On Error GoTo 0
End Sub

Sub WriteLog(message, forceWrite)
    ' forceWrite bypasses debugMode for genuine failures - matching the
    ' -IsError switch on Write-Log in lgtv.ps1. A routine line passes
    ' False and is dropped entirely when debugMode is off.
    '
    ' Read, then overwrite in place. Same shape as lgtv.ps1's log write:
    ' the existing content is read first, then the file is reopened for
    ' writing and the whole thing (old content + new line) is written in
    ' one pass. No temp file is ever created.
    '
    ' If the write fails, the file exists but this identity cannot write
    ' it - the ACL-break case where an editor's save dropped the script's
    ' permissions. Repair the ACL and retry once.
    Dim line, existing, size, f

    If Not forceWrite And Not debugMode Then Exit Sub

    On Error Resume Next
    If Not objFSO.FolderExists(LOG_DIR) Then objFSO.CreateFolder(LOG_DIR)
    If Err.Number <> 0 Then Err.Clear : On Error GoTo 0 : Exit Sub

    line = Now & " [" & strState & "] " & message

    ' Rotation is checked against the current file size before the read,
    ' so there is one fewer window in which the file can change under us.
    size = FileLength(LOG_FILE)
    If size > MAX_LOG_BYTES Then
        If objFSO.FileExists(LOG_FILE & ".old") Then objFSO.DeleteFile LOG_FILE & ".old", True
        objFSO.MoveFile LOG_FILE, LOG_FILE & ".old"
        Err.Clear
        size = -1
    End If

    existing = ""
    If size > 0 Then existing = ReadAllText(LOG_FILE)

    ' ForWriting overwrites the existing file from the start. The `True`
    ' third argument creates it if it does not exist.
    Set f = objFSO.OpenTextFile(LOG_FILE, ForWriting, True, TristateUseDefault)
    If Err.Number = 0 Then
        If Len(existing) > 0 Then f.Write existing
        f.WriteLine line
        f.Close
    Else
        Err.Clear
        RepairAcl LOG_FILE
        Set f = objFSO.OpenTextFile(LOG_FILE, ForWriting, True, TristateUseDefault)
        If Err.Number = 0 Then
            If Len(existing) > 0 Then f.Write existing
            f.WriteLine line
            f.Close
        Else
            Err.Clear
        End If
    End If

    On Error GoTo 0
End Sub

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
