Option Explicit

Dim shell, args, windir, powershell, quote, command, i
Set shell = CreateObject("WScript.Shell")
Set args = WScript.Arguments

If args.Count < 1 Then
    WScript.Quit 1
End If

windir = shell.ExpandEnvironmentStrings("%WINDIR%")
powershell = windir & "\System32\WindowsPowerShell\v1.0\powershell.exe"
quote = Chr(34)
command = quote & powershell & quote & " -NoProfile -ExecutionPolicy Bypass -File " & quote & args(0) & quote

For i = 1 To args.Count - 1
    command = command & " " & quote & args(i) & quote
Next

shell.Run command, 0, False
