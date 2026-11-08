# Scan from the Brother MFC-L2713DW to a PDF (default: Downloads, timestamped name).
# Talks to the printer directly over the network with eSCL (driverless scanning), which supports
# 100-600 dpi on both the feeder and the glass. Windows' own driver for this printer stops at 300 dpi.
# Source Auto uses the feeder when it has paper, otherwise the glass.
param(
    [ValidateSet(100, 200, 300, 600)][int]$Dpi = 300,
    [switch]$Color,
    [ValidateSet('Auto', 'Feeder', 'Glass')][string]$Source = 'Auto',
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'

# Each run gets its own log; brother-scan.log is a copy of the latest, for troubleshooting.
# Logging never stops a scan (two scans at once would otherwise clash over the file).
$logDir = Join-Path $env:TEMP 'brother-scan-logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$runLog = Join-Path $logDir ("scan-{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date), $PID)
$latestLog = Join-Path $env:TEMP 'brother-scan.log'
function Write-Log($msg) {
    try { "$(Get-Date -Format HH:mm:ss.fff)  $msg" | Add-Content $runLog } catch {}
    try { Copy-Item $runLog $latestLog -Force } catch {}
}
Get-ChildItem $logDir -Filter *.log | Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 | Remove-Item -ErrorAction SilentlyContinue
Write-Log "start  Dpi=$Dpi Color=$Color Source=$Source"

# Minimal HTTP helper: returns @{ Status; Location; Body (bytes) } without throwing on 4xx/5xx.
function Invoke-Http([string]$method, [string]$url, [string]$xml) {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = $method
    $req.Proxy = $null                 # talk to the printer directly, never through a system proxy or VPN proxy
    $req.Timeout = 300000              # a 600 dpi colour page can take a while before the response starts
    $req.ReadWriteTimeout = 300000
    if ($xml) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($xml)
        $req.ContentType = 'text/xml'
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
    }
    try { $resp = $req.GetResponse() }
    catch [System.Net.WebException] {
        if (-not $_.Exception.Response) { throw }
        $resp = $_.Exception.Response
    }
    try {
        $ms = New-Object System.IO.MemoryStream
        $resp.GetResponseStream().CopyTo($ms)
        @{ Status = [int]$resp.StatusCode; Location = $resp.Headers['Location']; Body = $ms.ToArray() }
    } finally { $resp.Close() }
}
function Get-Xml([string]$url) {
    $r = Invoke-Http 'GET' $url
    if ($r.Status -ne 200) { throw "Scanner returned HTTP $($r.Status) for $url" }
    [xml][System.Text.Encoding]::UTF8.GetString($r.Body)
}
function Select-Text($node, [string]$name) {
    if (-not $node) { return $null }
    $n = $node.SelectSingleNode(".//*[local-name()='$name']"); if ($n) { $n.InnerText }
}

# Read a JPEG's size, colour components (SOF marker) and resolution (JFIF header, if it gives dots per inch).
function Get-JpegInfo([byte[]]$b) {
    $dpi = 0
    $i = 2
    while ($i + 9 -lt $b.Length) {
        if ($b[$i] -ne 0xFF) { $i++; continue }
        $m = $b[$i + 1]
        if ($m -eq 0xFF) { $i++; continue }                                   # fill byte
        if ($m -eq 0x01 -or ($m -ge 0xD0 -and $m -le 0xD8)) { $i += 2; continue }   # markers with no length
        if ($m -eq 0xE0 -and [System.Text.Encoding]::ASCII.GetString($b, $i + 4, 4) -eq 'JFIF' -and $b[$i + 11] -eq 1) {
            $dpi = $b[$i + 12] * 256 + $b[$i + 13]
        }
        if ($m -ge 0xC0 -and $m -le 0xCF -and $m -notin 0xC4, 0xC8, 0xCC) {
            $info = @{ Height = $b[$i + 5] * 256 + $b[$i + 6]; Width = $b[$i + 7] * 256 + $b[$i + 8]; Components = $b[$i + 9]; Dpi = $dpi }
            if ($info.Width -eq 0 -or $info.Height -eq 0) { break }
            return $info
        }
        $i += 2 + $b[$i + 2] * 256 + $b[$i + 3]
    }
    throw 'Could not read a scanned page (not a valid JPEG).'
}

$job = $null
$tmpPdf = $null
try {
    # --- Where to save (resolved to a full path, so a bare file name also works) ---
    if ($OutFile) {
        $out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
    } else {
        $outDir = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
        $out = Join-Path $outDir ("scan-{0:yyyy-MM-dd-HHmmss}.pdf" -f (Get-Date))
    }
    $outParent = Split-Path $out
    if ($outParent) { New-Item -ItemType Directory -Force $outParent | Out-Null }

    # --- Find the printer's eSCL address (Windows records it when it discovers the printer) ---
    $escl = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'SWD\ESCL\*' -and $_.FriendlyName -like '*Brother*' } | Select-Object -First 1
    if (-not $escl) { throw 'Brother scanner not found. Is the printer on and on the same network?' }
    $base = Get-PnpDeviceProperty -InstanceId $escl.InstanceId | ForEach-Object { "$($_.Data)" } |
        Where-Object { $_ -match '^https?://[^\s]+/eSCL$' } | Select-Object -First 1
    if (-not $base) { throw 'Could not find the scanner''s network address.' }
    Write-Log "scanner at $base"

    # --- Decide feeder or glass ---
    $caps = Get-Xml "$base/ScannerCapabilities"
    $status = Get-Xml "$base/ScannerStatus"
    $adfState = Select-Text $status 'AdfState'
    Write-Log "scanner state: $(Select-Text $status 'State'); feeder: $adfState"
    # Only an empty (or unreported) feeder means "use the glass". A jam or open cover is reported, not ignored.
    $feederEmpty = (-not $adfState) -or $adfState -eq 'ScannerAdfEmpty'
    $feederProblem = (-not $feederEmpty) -and $adfState -ne 'ScannerAdfLoaded'
    $useFeeder = switch ($Source) {
        'Glass'  { $false }
        'Feeder' {
            if ($feederEmpty) { throw 'The document feeder is empty.' }
            if ($feederProblem) { throw "The document feeder isn't ready ($adfState). Check for a paper jam or open cover." }
            $true
        }
        default  {
            if ($feederProblem) { throw "The document feeder isn't ready ($adfState). Check for a paper jam or open cover." }
            -not $feederEmpty
        }
    }
    $inputSource = if ($useFeeder) { 'Feeder' } else { 'Platen' }
    $capsNode = $caps.SelectSingleNode("//*[local-name()='$(if ($useFeeder) { 'Adf' } else { 'Platen' })']")
    if (-not $capsNode) { throw "The scanner doesn't offer the $(if ($useFeeder) { 'feeder' } else { 'glass' })." }

    # A4, in the scanner's units (1/300 inch), limited to what this input can take.
    $maxW = [int](Select-Text $capsNode 'MaxWidth'); $maxH = [int](Select-Text $capsNode 'MaxHeight')
    if ($maxW -le 0 -or $maxH -le 0) { throw 'The scanner didn''t report its maximum page size.' }
    $width = [math]::Min(2481, $maxW); $height = [math]::Min(3507, $maxH)

    # Version must be 2.0: this printer advertises 2.63 but ignores the settings (and scans 200 dpi colour) if sent 2.63.
    $settings = @"
<?xml version="1.0" encoding="UTF-8"?>
<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:Version>2.0</pwg:Version>
  <pwg:ScanRegions>
    <pwg:ScanRegion>
      <pwg:Height>$height</pwg:Height>
      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
      <pwg:Width>$width</pwg:Width>
      <pwg:XOffset>0</pwg:XOffset>
      <pwg:YOffset>0</pwg:YOffset>
    </pwg:ScanRegion>
  </pwg:ScanRegions>
  <pwg:InputSource>$inputSource</pwg:InputSource>
  <scan:ColorMode>$(if ($Color) { 'RGB24' } else { 'Grayscale8' })</scan:ColorMode>
  <scan:XResolution>$Dpi</scan:XResolution>
  <scan:YResolution>$Dpi</scan:YResolution>
  <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
</scan:ScanSettings>
"@
    # The printer's XML parser is strict: send it on one line, in the element order above.
    $settings = ($settings -split "`r?`n" | ForEach-Object { $_.Trim() }) -join ''

    # --- Start the job; retry briefly if the scanner is still busy with something else ---
    for ($try = 0; $try -lt 10 -and -not $job; $try++) {
        $r = Invoke-Http 'POST' "$base/ScanJobs" $settings
        if ($r.Status -eq 201 -and $r.Location) {
            $loc = "$($r.Location)".TrimEnd('/')
            $job = ([Uri]::new([Uri]"$base/", $loc)).AbsoluteUri.TrimEnd('/')
        }
        elseif ($r.Status -eq 201) { throw 'The scanner accepted the job but gave no job address.' }
        elseif ($r.Status -eq 503) { Write-Log 'scanner busy, retrying'; Start-Sleep -Seconds 3 }
        else { throw "Scanner refused the scan job (HTTP $($r.Status))." }
    }
    if (-not $job) { throw 'The scanner stayed busy. Try again in a moment.' }
    Write-Log "job $job ($inputSource, $Dpi dpi, $(if ($Color) { 'colour' } else { 'greyscale' }))"

    # The printer's own record of this job: @{ State; ToTransfer; Done } (State is '' if it isn't listed).
    $jobId = ($job -split '/')[-1]
    function Get-JobStatus {
        try {
            $st = Get-Xml "$base/ScannerStatus"
            foreach ($j in $st.SelectNodes("//*[local-name()='JobInfo']")) {
                if ((Select-Text $j 'JobUri') -like "*$jobId") {
                    return @{ State = Select-Text $j 'JobState'; ToTransfer = [int](Select-Text $j 'ImagesToTransfer'); Done = [int](Select-Text $j 'ImagesCompleted') }
                }
            }
        } catch {}
        @{ State = ''; ToTransfer = 0; Done = -1 }
    }

    # --- Collect pages until the printer has really finished ---
    # While the next sheet is still being scanned the printer answers 503 (wait up to 5 minutes per page).
    # It can also answer 404 ("no more pages") between feeder sheets while it is still scanning, so a 404 on the
    # feeder only counts as the end once the printer's job record says the job is no longer processing.
    # Even once the printer says it's finished, keep checking for a few seconds in case a slow sheet is still coming.
    $graceSeconds = 8
    $pages = @()
    $waitStart = Get-Date
    $endSeen = $null
    $busyPolls = 0
    while ($true) {
        $r = Invoke-Http 'GET' "$job/NextDocument"
        if ($r.Status -eq 200) {
            $pages += , $r.Body
            $waitStart = Get-Date
            if ($endSeen) { Write-Log 'another page arrived after the printer said it was finished' }
            $endSeen = $null
            Write-Log "page $($pages.Count) received ($([math]::Round($r.Body.Length / 1KB)) KB$(if ($busyPolls) { ", after $busyPolls busy replies" }))"
            $busyPolls = 0
            if (-not $useFeeder) { break }   # the glass gives one page
        } elseif ($r.Status -eq 404) {
            if (-not $useFeeder) { break }
            $js = Get-JobStatus
            $stillGoing = $js.State -in 'Processing', 'Pending' -or $js.ToTransfer -gt 0
            if (((Get-Date) - $waitStart).TotalMinutes -ge 5) { Write-Log 'gave up waiting for more pages after 5 minutes'; break }
            if ($stillGoing) {
                if (-not $endSeen) { Write-Log "no-more-pages reply after $($pages.Count) page(s), but printer says job '$($js.State)' ($($js.Done) scanned, $($js.ToTransfer) waiting); still waiting" }
                $endSeen = $null
            } else {
                if (-not $endSeen) {
                    $endSeen = Get-Date
                    Write-Log "printer says finished after $($pages.Count) page(s) (job '$($js.State)', $($js.Done) scanned); checking for $graceSeconds more seconds"
                } elseif (((Get-Date) - $endSeen).TotalSeconds -ge $graceSeconds) {
                    break
                }
            }
            Start-Sleep -Seconds 1
        } elseif ($r.Status -eq 503 -and ((Get-Date) - $waitStart).TotalMinutes -lt 5) {
            $busyPolls++
            Start-Sleep -Seconds 1
        } else {
            throw "Scanner returned HTTP $($r.Status) while scanning (after $($pages.Count) page(s))."
        }
    }
    if ($pages.Count -eq 0) { throw 'Nothing was scanned.' }
    if ($useFeeder) {
        $js = Get-JobStatus
        Write-Log "feeder finished: received $($pages.Count) page(s); printer says job '$($js.State)', $($js.Done) scanned; feeder now $(Select-Text (Get-Xml "$base/ScannerStatus") 'AdfState')"
        if ($js.Done -gt $pages.Count) { Write-Log "WARNING: the printer scanned $($js.Done) page(s) but only $($pages.Count) arrived" }
    }

    # Check every page before writing anything, so a bad page can't leave a broken PDF behind.
    $infos = @(foreach ($p in $pages) { Get-JpegInfo $p })

    # --- Write a minimal PDF (one JPEG image per page) to a temporary file, then move it into place ---
    $tmpPdf = "$out.part"
    $fs = [System.IO.File]::Create($tmpPdf)
    $offsets = New-Object System.Collections.Generic.List[long]
    function Write-Ascii([string]$s) { $b = [System.Text.Encoding]::ASCII.GetBytes($s); $fs.Write($b, 0, $b.Length) }
    function Start-Obj([int]$n) { $offsets.Add($fs.Position); Write-Ascii "$n 0 obj`n" }
    try {
        Write-Ascii "%PDF-1.4`n"
        $n = $pages.Count
        $kids = (0..($n - 1) | ForEach-Object { "$(3 + 3 * $_) 0 R" }) -join ' '
        Start-Obj 1; Write-Ascii "<< /Type /Catalog /Pages 2 0 R >>`nendobj`n"
        Start-Obj 2; Write-Ascii "<< /Type /Pages /Kids [$kids] /Count $n >>`nendobj`n"
        for ($i = 0; $i -lt $n; $i++) {
            $bytes = $pages[$i]; $info = $infos[$i]
            $pageObj = 3 + 3 * $i; $imgObj = $pageObj + 1; $contentObj = $pageObj + 2
            # Trust the image's own resolution only if it's one the printer actually scans at.
            $pageDpi = if ($info.Dpi -in 100, 200, 300, 600) { $info.Dpi } else { $Dpi }
            if ($pageDpi -ne $Dpi) { Write-Log "page $($i + 1): asked for $Dpi dpi, image says $pageDpi dpi" }
            $w = [math]::Round($info.Width * 72 / $pageDpi, 2); $h = [math]::Round($info.Height * 72 / $pageDpi, 2)
            $cs = if ($info.Components -eq 1) { '/DeviceGray' } else { '/DeviceRGB' }
            Start-Obj $pageObj
            Write-Ascii "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $w $h] /Resources << /XObject << /Im0 $imgObj 0 R >> >> /Contents $contentObj 0 R >>`nendobj`n"
            Start-Obj $imgObj
            Write-Ascii "<< /Type /XObject /Subtype /Image /Width $($info.Width) /Height $($info.Height) /ColorSpace $cs /BitsPerComponent 8 /Filter /DCTDecode /Length $($bytes.Length) >>`nstream`n"
            $fs.Write($bytes, 0, $bytes.Length)
            Write-Ascii "`nendstream`nendobj`n"
            $content = "q $w 0 0 $h 0 0 cm /Im0 Do Q"
            Start-Obj $contentObj
            Write-Ascii "<< /Length $($content.Length) >>`nstream`n$content`nendstream`nendobj`n"
        }
        $xref = $fs.Position
        Write-Ascii "xref`n0 $($offsets.Count + 1)`n0000000000 65535 f `n"
        foreach ($o in $offsets) { Write-Ascii ("{0:D10} 00000 n `n" -f $o) }
        Write-Ascii "trailer`n<< /Size $($offsets.Count + 1) /Root 1 0 R >>`nstartxref`n$xref`n%%EOF`n"
    } finally { $fs.Close() }
    Move-Item $tmpPdf $out -Force
    $tmpPdf = $null

    Write-Log "saved $out ($n pages)"
    Write-Output "Saved $out ($n page$(if ($n -ne 1) { 's' }))"
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    throw
}
finally {
    # Always release the scanner, even if something failed part-way, so the next scan isn't blocked.
    if ($job) { try { $null = Invoke-Http 'DELETE' $job } catch {} }
    if ($tmpPdf) { Remove-Item $tmpPdf -ErrorAction SilentlyContinue }
}
