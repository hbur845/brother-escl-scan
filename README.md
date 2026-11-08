# brother-escl-scan

> **AI-written.** This code and documentation were written by an AI assistant (Claude, by Anthropic) working with the repository owner, and tested by them on their own hardware. Review it before relying on it.

One-key scanning from a **Brother MFC-L2713DW** (network) to a PDF in your **Downloads** folder, on Windows. No Brother software or driver needed — the script talks to the printer directly over the network using **eSCL** (the standard "driverless" scanning protocol, the same one phones and Macs use).

Why not just use Windows' built-in scanning? On this printer, Windows' own driver is capped at 300 dpi, and its older WIA interface only returns the **first** page from the document feeder. Talking eSCL directly gets the full 100–600 dpi and every feeder page.

## Use it

| Press | Scans in |
|---|---|
| **Ctrl+Alt+S** | Greyscale, 300 dpi (everyday documents) |
| **Ctrl+Alt+Shift+S** | Colour, 600 dpi (photos, colour pages, fine detail) |

1. Put the pages in the **document feeder** (or one page face down on the **glass**).
2. Press the hotkey. A "Scanning…" notification appears.
3. When it's done, File Explorer opens with the new PDF highlighted in Downloads.

- **Feeder or glass:** the script asks the printer whether the feeder has paper. If it does, every page goes into one PDF, in the order the feeder takes them (the top page of the stack is page 1). If the feeder is empty, it scans the glass. If the feeder reports a jam or open cover, the scan stops with that message instead of silently scanning the glass.
- **File name:** `scan-YYYY-MM-DD-HHMMSS.pdf`, e.g. `scan-2026-11-09-143005.pdf`.
- **Page size:** A4.
- **File sizes:** depend heavily on the page. As a guide, a near-blank page was ~120 KB (greyscale 300 dpi) and ~560 KB (colour 600 dpi); busy pages will be larger.
- **One scan at a time:** pressing a hotkey while a scan is running just shows "A scan is already running."

## Set it up

Requirements: Windows 10/11, Windows PowerShell 5.1 (built in), [AutoHotkey v2](https://www.autohotkey.com/), and the printer added in Windows (Settings → Bluetooth & devices → Printers & scanners) on the same network. Windows' driverless (eSCL) discovery must have found it — the script reads the printer's address from that.

1. Put `scan.ps1` and `scan-hotkeys.ahk` in a folder of your own, e.g. `%USERPROFILE%\Scripts\BrotherScan`.
2. Double-click `scan-hotkeys.ahk` to start the hotkeys (a green **H** appears in the system tray).
3. To start it at every sign-in: press Win+R, type `shell:startup`, and put a shortcut to `scan-hotkeys.ahk` in that folder.

Tested only on the **Brother MFC-L2713DW**. It looks for an eSCL scanner whose name contains "Brother", so other Brother eSCL models may work, but resolutions, page sizes and the quirks below may differ.

## Files

| File | What it is |
|---|---|
| `scan-hotkeys.ahk` | The hotkeys (AutoHotkey v2). Runs in the background. |
| `scan.ps1` | The scanning code (PowerShell). Talks eSCL to the printer and builds the PDF itself — no PDF software involved. |

## Run a scan by hand

From PowerShell, with options the hotkeys don't cover:

```
powershell -ExecutionPolicy Bypass -File .\scan.ps1 -Dpi 200 -Source Glass
```

| Option | Meaning |
|---|---|
| `-Dpi 100` / `200` / `300` / `600` | Resolution (default 300). These are the only values the MFC-L2713DW supports. |
| `-Color` | Colour instead of greyscale |
| `-Source Auto` / `Feeder` / `Glass` | Where to scan from (default Auto: feeder if loaded, else glass) |
| `-OutFile "C:\path\name.pdf"` | Save somewhere specific (default: Downloads) |

## Change the hotkeys

Edit `scan-hotkeys.ahk` in Notepad. The two hotkey lines are near the top:

```
^!s::Scan("-Dpi 300", "greyscale, 300 dpi")          ; Ctrl+Alt+S
^!+s::Scan("-Dpi 600 -Color", "colour, 600 dpi")     ; Ctrl+Alt+Shift+S
```

`^` = Ctrl, `!` = Alt, `+` = Shift, `#` = Win. Save, then restart the script (below).

## If something goes wrong

- **"The scan didn't complete" message:** it shows the reason from the log. Usually: the printer is off, asleep, busy, or on a different network. Wait a few seconds and try again.
- **Nothing happens when you press the hotkey:** look for the green **H** icon in the system tray. If it's missing, double-click `scan-hotkeys.ahk` to start it.
- **Restarting the script:** double-click `scan-hotkeys.ahk` (or sign out and back in). Start it from Explorer, not from inside a sandboxed app's terminal (e.g. a packaged desktop app), or its key presses may not reach other windows.
- **Fewer pages than you fed:** the feeder probably pulled two sheets through together (it has no double-feed detection, so neither the printer nor the script can tell). Fan the stack before loading and don't overfill the feeder. The log shows how many pages the printer delivered.
- **Log of the last scan:** `%TEMP%\brother-scan.log` (paste into Win+R to open). It shows the printer's address, whether the feeder was loaded, each page received, and any error (lines starting `ERROR:`). The last 20 scans' logs are kept in `%TEMP%\brother-scan-logs\`.
- **Scanner not found:** check the printer is still listed in Printers & scanners. If its IP address changed, Windows usually picks up the new one by itself; if not, remove and re-add the printer there.

### Printer quirks (don't undo these)

- The MFC-L2713DW advertises eSCL version 2.63, but **only honours the scan settings when the request says version 2.0**, sent on one line in a specific element order. Otherwise it silently scans 200 dpi colour. See the comments in `scan.ps1`.
- When the feeder is empty and a feeder scan is requested, it reports "busy" rather than "empty" — so the script checks the feeder state first.
- The feeder delivers pages top-first; no reordering is needed.
- It has once answered "no more pages" (HTTP 404) after 4 of 6 sheets while still feeding; releasing the job at that point lost the rest. So on the feeder, a "no more pages" reply only counts once the printer's job record says the job is no longer processing, and the script then keeps checking for 8 more seconds before saving. Feeder scans therefore finish ~8 seconds after the last sheet. The log notes each of these checks.

## Limits

- PDFs are **images only** — no OCR, so you can't search or select text.
- Each page is stored as a JPEG inside the PDF.
- Scans one side of each page only (the MFC-L2713DW feeder can't scan double-sided).
- The connection to the printer is plain HTTP on your local network (that's how the printer offers it).

## Remove it

1. Right-click the green **H** in the system tray → **Exit**.
2. Delete the shortcut from the Startup folder (Win+R → `shell:startup`), if you made one.
3. Delete the folder.

## License

MIT — see [LICENSE](LICENSE).
