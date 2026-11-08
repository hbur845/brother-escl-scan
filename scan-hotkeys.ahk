#Requires AutoHotkey v2.0
#SingleInstance Force

; Scan from the Brother MFC-L2713DW (feeder if loaded, otherwise glass) to a PDF in Downloads.
^!s::Scan("-Dpi 300", "greyscale, 300 dpi")          ; Ctrl+Alt+S
^!+s::Scan("-Dpi 600 -Color", "colour, 600 dpi")     ; Ctrl+Alt+Shift+S

global scanning := false

Scan(args, label) {
    global scanning
    if scanning {   ; one scan at a time; the other hotkey would otherwise start a second job
        TrayTip "A scan is already running.", "Brother MFC-L2713DW"
        return
    }
    scanning := true
    try {
        downloads := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders", "{374DE290-123F-4565-9164-39C4925E467B}", EnvGet("USERPROFILE") "\Downloads")
        path := downloads "\scan-" FormatTime(, "yyyy-MM-dd-HHmmss") ".pdf"

        TrayTip "Scanning (" label ")...", "Brother MFC-L2713DW"
        exitCode := RunWait('powershell -NoProfile -ExecutionPolicy Bypass -File "' A_ScriptDir '\scan.ps1" ' args ' -OutFile "' path '"',, "Hide")
        TrayTip
        if (exitCode = 0 && FileExist(path))
            Run 'explorer.exe /select,"' path '"'
        else
            MsgBox "The scan didn't complete.`n`n" LastError() "`n`nDetails: %TEMP%\brother-scan.log", "Brother scan", "Icon!"
    } finally {
        scanning := false
    }
}

; The reason the last scan failed, from the scan log (or a general hint if there isn't one).
LastError() {
    try {
        Loop Read, EnvGet("TEMP") "\brother-scan.log"
            if InStr(A_LoopReadLine, "ERROR: ")
                reason := SubStr(A_LoopReadLine, InStr(A_LoopReadLine, "ERROR: ") + 7)
    }
    return IsSet(reason) ? reason : "Check the printer is on, awake and not busy, then try again."
}
