Option Explicit

Dim shell, pwshPath, entryScript, command, fileSystem, desktopPath
If WScript.Arguments.Count <> 2 Then WScript.Quit 64

pwshPath = WScript.Arguments(0)
entryScript = WScript.Arguments(1)
Set fileSystem = CreateObject("Scripting.FileSystemObject")
desktopPath = fileSystem.BuildPath(fileSystem.GetParentFolderName(entryScript), "Desktop\CodexQuotaMonitor.exe")
If fileSystem.FileExists(desktopPath) Then
    command = QuoteArgument(desktopPath)
Else
    command = QuoteArgument(pwshPath) & " -NoLogo -NoProfile -NonInteractive -Sta -WindowStyle Hidden -File " & QuoteArgument(entryScript)
End If

Set shell = CreateObject("WScript.Shell")
shell.Run command, 0, False
WScript.Quit 0

Function QuoteArgument(value)
    QuoteArgument = Chr(34) & value & Chr(34)
End Function
