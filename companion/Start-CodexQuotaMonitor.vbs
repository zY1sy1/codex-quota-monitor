Option Explicit

Dim shell, pwshPath, entryScript, command
If WScript.Arguments.Count <> 2 Then WScript.Quit 64

pwshPath = WScript.Arguments(0)
entryScript = WScript.Arguments(1)
command = QuoteArgument(pwshPath) & " -NoLogo -NoProfile -NonInteractive -Sta -WindowStyle Hidden -File " & QuoteArgument(entryScript)

Set shell = CreateObject("WScript.Shell")
shell.Run command, 0, False
WScript.Quit 0

Function QuoteArgument(value)
    QuoteArgument = Chr(34) & value & Chr(34)
End Function
