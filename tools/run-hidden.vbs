' hidden launcher: 0 = no window, False = do not wait
Dim sh, dir, extra
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
extra = ""
If WScript.Arguments.Count > 0 Then extra = " " & WScript.Arguments(0)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & dir & "watch-at.ps1""" & extra, 0, False
