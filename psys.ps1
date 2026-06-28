# psys.ps1 - Unified system & network monitor for Windows
# Copyright (c) 2026 - MIT License
#
# Usage: .\psys.ps1 [-RefreshInterval <sec>] [-LogFile <path.html>] [-CsvFile <path.csv>]
#                   [-LogMaxSnapshots <n>] [-AlertCPU <pct>] [-AlertMem <pct>]
#
# Views:  Tab / 1-4 to switch    h for help screen
#   1 Processes   CPU / Mem / Disk I/O / sparkline
#   2 Network     Per-process Net I/O + TCP/UDP
#   3 Connections Full TCP connection detail
#   4 Adapters    Network adapter stats
#
# Keys: h=help  f=filter  r=toggle-regex  Enter=detail  k=kill  +/-=speed  Space=pause  Up/Down=scroll  q=quit

# param() MUST be the first statement — no code can appear before it.
# Edit the default values here to set your personal defaults.
# Any value passed on the command line overrides these defaults.
#
# ============================================================
# USER CONFIGURATION — edit the default values in this block
# ============================================================
param(
    [int]$RefreshInterval = 5,      # seconds between refreshes (1-60)
    [int]$AlertCPU        = 80,     # CPU%  alert threshold per process
    [int]$AlertMem        = 90,     # Mem%  alert threshold (system total)
    [string]$LogFile      = "",     # HTML log  e.g. "C:\logs\psys.html"
    [string]$CsvFile      = "",     # CSV log   e.g. "C:\logs\psys.csv"
    [int]$LogMaxSnapshots = 200     # max snapshots kept in HTML log
)
# ============================================================

Set-StrictMode -Off

# ============================================================
# COLOUR THEME
# ============================================================
$CLR = @{
    Header      = 'Cyan';      Separator   = 'DarkGray';  Label       = 'DarkCyan'
    Value       = 'White';     BarLow      = 'Green';     BarMid      = 'Yellow'
    BarHigh     = 'Red';       ColHeader   = 'DarkYellow';ProcNormal  = 'Gray'
    ProcMid     = 'Yellow';    ProcHigh    = 'Red';       ProcName    = 'White'
    KeyHint     = 'DarkGray';  Paused      = 'Yellow';    ModeMsg     = 'Cyan'
    KillPrompt  = 'Red';       DiskIO      = 'DarkMagenta';NetIO      = 'Cyan'
    Established = 'Green';     Listen      = 'DarkYellow';TimeWait    = 'DarkGray'
    CloseWait   = 'Yellow';    AdapterOk   = 'Green';     AdapterOff  = 'DarkGray'
    TabActive   = 'White';     TabInactive = 'DarkGray';  Alert       = 'Red'
    Sparkline   = 'DarkCyan';  HelpKey     = 'DarkYellow';HelpDesc    = 'Gray'
    NewProc     = 'Green'
    SelectedRow = 'Yellow'
    DetailHdr   = 'Cyan'
    DetailLabel = 'DarkCyan'
    DetailValue = 'White'
    DetailKey   = 'DarkYellow'
    RegexMode   = 'Magenta'
}

# ============================================================
# STATE
# ============================================================
$script:View         = "procs"
$script:SortProcs    = "CPU"
$script:SortNet      = "IO"
$script:Filter       = ""
$script:Paused       = $false
$script:Interval     = $RefreshInterval
$script:Mode         = "normal"
$script:ModeInput    = ""
$script:ModeMsg      = ""
$script:Rows         = 0
$script:ScrollOffset = 0
$script:LastW        = 0
$script:LastH        = 0
$script:NeedsRender  = $false
$script:HtmlSnapshots= [System.Collections.Generic.List[object]]::new()
$script:CpuHistory   = @{}
$script:KnownPids    = @{}
$script:AlertLog     = [System.Collections.Generic.List[string]]::new()
$script:CsvFile      = $CsvFile     # path to CSV export (empty = disabled)
$script:CsvInitDone  = $false       # tracks whether CSV header has been written
$script:DetailPid      = 0            # PID currently shown in detail popup (0 = none)
$script:FilterMode     = "regex"      # "regex" or "wildcard" — toggled with r key
$script:LastVisiblePids= @()          # ordered PIDs of currently visible rows
$script:SelectionIdx   = 0            # index of highlighted row within visible rows

# Virtual screen buffer — eliminates flicker, no Console::Clear() during render
$script:Buf          = [System.Collections.Generic.List[object]]::new()
$script:BufLine      = [System.Collections.Generic.List[object]]::new()

# ============================================================
# VIRTUAL BUFFER ENGINE
# ============================================================
function Buf-NewLine {
    $script:Buf.Add(@($script:BufLine.ToArray()))
    $script:BufLine = [System.Collections.Generic.List[object]]::new()
}

function Buf-Write {
    param([string]$Text, [string]$Color = "Gray", [switch]$NewLine)
    $script:BufLine.Add(@{ T = $Text; C = $Color })
    if ($NewLine) { Buf-NewLine }
}

function Invoke-FlushBuffer {
    param([int]$W, [int]$H)
    # Flush the current line if non-empty (safety net)
    if ($script:BufLine.Count -gt 0) { Buf-NewLine }
    $row = 0
    foreach ($line in $script:Buf) {
        if ($row -ge ($H - 1)) { break }
        [Console]::SetCursorPosition(0, $row)
        $lineLen = 0
        foreach ($seg in $line) {
            [Console]::ForegroundColor = [System.ConsoleColor]$seg.C
            [Console]::Write($seg.T)
            $lineLen += $seg.T.Length
        }
        if ($lineLen -lt $W) {
            [Console]::ForegroundColor = [System.ConsoleColor]::Gray
            [Console]::Write(" " * ($W - $lineLen))
        }
        $row++
    }
    # Erase leftover rows from a previously taller frame
    [Console]::ForegroundColor = [System.ConsoleColor]::Gray
    while ($row -lt ($H - 1)) {
        [Console]::SetCursorPosition(0, $row)
        [Console]::Write(" " * $W)
        $row++
    }
    [Console]::ResetColor()
}

# ============================================================
# SPARKLINE
# ============================================================
$SPARK_CHARS = [char[]]@(0x2581,0x2582,0x2583,0x2584,0x2585,0x2586,0x2587,0x2588)

function Get-Sparkline {
    param([double[]]$History, [int]$Width = 8)
    if (-not $History -or $History.Count -eq 0) { return " " * $Width }
    $recent = $History | Select-Object -Last $Width
    $max    = ($recent | Measure-Object -Maximum).Maximum
    if ($max -le 0) { return ([string][char]0x2581) * $recent.Count }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($v in $recent) {
        $idx = [math]::Min([math]::Floor($v / $max * 7), 7)
        $null = $sb.Append($SPARK_CHARS[$idx])
    }
    return $sb.ToString().PadLeft($Width)
}

function Update-CpuHistory {
    param($Procs)
    $newKnown = @{}
    foreach ($p in $Procs) {
        $newKnown[$p.PID] = $true
        if (-not $script:CpuHistory.ContainsKey($p.PID)) {
            $script:CpuHistory[$p.PID] = [System.Collections.Generic.List[double]]::new()
        }
        $script:CpuHistory[$p.PID].Add($p.CPU)
        if ($script:CpuHistory[$p.PID].Count -gt 10) { $script:CpuHistory[$p.PID].RemoveAt(0) }
    }
    $dead = @($script:CpuHistory.Keys | Where-Object { -not $newKnown.ContainsKey($_) })
    foreach ($d in $dead) { $script:CpuHistory.Remove($d) }
}

# ============================================================
# FORMATTING HELPERS
# ============================================================
function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-IORate {
    param([long]$Bps, [int]$Width = 10)
    if ($Bps -le 0)    { return "-".PadLeft($Width) }
    if ($Bps -ge 1GB)  { return ("{0:N1} GB/s" -f ($Bps/1GB)).PadLeft($Width) }
    if ($Bps -ge 1MB)  { return ("{0:N1} MB/s" -f ($Bps/1MB)).PadLeft($Width) }
    if ($Bps -ge 1KB)  { return ("{0:N1} KB/s" -f ($Bps/1KB)).PadLeft($Width) }
    return ("{0} B/s"  -f $Bps).PadLeft($Width)
}

function Write-Separator {
    param([int]$W = 0)
    if ($W -le 0) { $W = [Console]::WindowWidth - 1 }
    Buf-Write -Text ("-" * $W) -Color $CLR.Separator -NewLine
}

function Write-Bar {
    param([double]$Pct, [int]$Width = 28)
    $filled = [math]::Max(0, [math]::Min([math]::Round($Pct / 100 * $Width), $Width))
    $colour = if ($Pct -ge 80) { $CLR.BarHigh } elseif ($Pct -ge 50) { $CLR.BarMid } else { $CLR.BarLow }
    Buf-Write -Text "["                    -Color $CLR.Separator
    Buf-Write -Text ("#" * $filled)        -Color $colour
    Buf-Write -Text (" " * ($Width-$filled)) -Color $CLR.Separator
    Buf-Write -Text "]"                    -Color $CLR.Separator
}

function Get-CpuColour  { param([double]$p); if($p -ge $AlertCPU){$CLR.Alert} elseif($p -ge 15){$CLR.ProcMid} else{$CLR.ProcNormal} }
function Get-MemColour  { param([double]$p); if($p -ge 80){$CLR.ProcHigh} elseif($p -ge 50){$CLR.ProcMid} else{$CLR.ProcNormal} }
function Get-StateColour {
    param([string]$s)
    switch ($s) {
        "Established" { $CLR.Established } "Listen"    { $CLR.Listen }
        "TimeWait"    { $CLR.TimeWait    } "CloseWait" { $CLR.CloseWait }
        default       { $CLR.ProcNormal  }
    }
}

# ============================================================
# DATA COLLECTION — SYSTEM
# ============================================================
function Get-UptimeString {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        $u = (Get-Date) - $os.LastBootUpTime
        return "{0}d {1:D2}h {2:D2}m {3:D2}s" -f $u.Days, $u.Hours, $u.Minutes, $u.Seconds
    }
    return "N/A"
}

function Get-LogicalCpuCount {
    $c = (Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue |
          Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    if ($c -gt 0) { return [int]$c } else { return 1 }
}

function Get-PerCoreCpuLoad {
    param([int]$CoreCount)
    $r = New-Object double[] $CoreCount
    try {
        $rows = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor `
                    -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+$' }
        foreach ($row in $rows) {
            $i = [int]$row.Name
            if ($i -lt $CoreCount) { $r[$i] = [math]::Round([double]$row.PercentProcessorTime, 0) }
        }
    } catch {}
    return $r
}

function Get-SystemSummary {
    $os  = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $tot = if ($os) { $os.TotalVisibleMemorySize * 1KB } else { 0 }
    $fr  = if ($os) { $os.FreePhysicalMemory     * 1KB } else { 0 }
    $us  = $tot - $fr
    $mp  = if ($tot -gt 0) { [math]::Round($us / $tot * 100, 1) } else { 0 }
    [PSCustomObject]@{
        Uptime   = Get-UptimeString
        CpuName  = if ($cpu) { $cpu.Name.Trim() } else { "Unknown" }
        CpuLoad  = if ($cpu) { [double]$cpu.LoadPercentage } else { 0 }
        TotalMem = $tot; UsedMem = $us; FreeMem = $fr; MemPct = $mp
    }
}

# ============================================================
# DATA COLLECTION — DISK I/O
# ============================================================
function Get-DiskIODelta {
    $snap1 = @{}
    try {
        Get-CimInstance -ClassName Win32_PerfRawData_PerfProc_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.IDProcess -gt 0 } |
            ForEach-Object { $snap1[[int]$_.IDProcess] = @($_.IOReadBytesPersec, $_.IOWriteBytesPersec) }
    } catch {}
    Start-Sleep -Seconds 1
    $result = @{}
    try {
        Get-CimInstance -ClassName Win32_PerfRawData_PerfProc_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.IDProcess -gt 0 } |
            ForEach-Object {
                $pid2 = [int]$_.IDProcess
                if ($snap1.ContainsKey($pid2)) {
                    $result[$pid2] = @(
                        [math]::Max(0, [long](($_.IOReadBytesPersec  - $snap1[$pid2][0]))),
                        [math]::Max(0, [long](($_.IOWriteBytesPersec - $snap1[$pid2][1])))
                    )
                }
            }
    } catch {}
    return $result
}

# ============================================================
# DATA COLLECTION — NETWORK I/O
# ============================================================
function Get-NetIOByPid {
    $script:_netPrime = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process `
                            -ErrorAction SilentlyContinue
}

function Get-NetIORates {
    $result = @{}
    try {
        $rows = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process `
                    -ErrorAction SilentlyContinue |
                Where-Object { $_.IDProcess -gt 0 }
        foreach ($row in $rows) {
            $pid2  = [int]$row.IDProcess
            $other = [math]::Max(0, [long]$row.IOOtherBytesPersec)
            if ($result.ContainsKey($pid2)) { $result[$pid2] += $other }
            else                            { $result[$pid2]  = $other }
        }
    } catch {}
    return $result
}

# ============================================================
# DATA COLLECTION — TCP / UDP / ADAPTERS
# ============================================================
function Get-TcpByPid {
    $result = @{}
    try {
        foreach ($c in (Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
            $p = [int]$c.OwningProcess
            if (-not $result.ContainsKey($p)) {
                $result[$p] = [System.Collections.Generic.List[object]]::new()
            }
            $result[$p].Add([PSCustomObject]@{
                LocalAddress  = $c.LocalAddress;  LocalPort  = $c.LocalPort
                RemoteAddress = $c.RemoteAddress; RemotePort = $c.RemotePort
                State         = $c.State.ToString()
            })
        }
    } catch {}
    return $result
}

function Get-UdpByPid {
    $result = @{}
    try {
        foreach ($u in (Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) {
            $p = [int]$u.OwningProcess
            if ($result.ContainsKey($p)) { $result[$p]++ } else { $result[$p] = 1 }
        }
    } catch {}
    return $result
}

function Get-AdapterStats {
    $out = @()
    try {
        $infoMap = @{}
        foreach ($i in (Get-NetAdapter -ErrorAction SilentlyContinue)) { $infoMap[$i.Name] = $i }
        foreach ($s in (Get-NetAdapterStatistics -ErrorAction SilentlyContinue)) {
            $info = $infoMap[$s.Name]
            $out += [PSCustomObject]@{
                Name          = $s.Name
                Status        = if ($info) { $info.Status    } else { "?" }
                Speed         = if ($info) { $info.LinkSpeed } else { "?" }
                ReceivedBytes = $s.ReceivedBytes
                SentBytes     = $s.SentBytes
            }
        }
    } catch {}
    return $out
}

# ============================================================
# MASTER DATA COLLECTION
# ============================================================
function Get-AllData {
    param([int]$LogicalCpus)

    $t1    = [datetime]::UtcNow
    $snap1 = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $e = [PSCustomObject]@{
            Name      = $_.Name; CpuSec = $_.CPU; MemWS    = $_.WorkingSet64
            Handles   = $_.Handles; Threads = $_.Threads.Count; StartTime = $null
        }
        try { $e.StartTime = $_.StartTime } catch {}
        $snap1[$_.Id] = $e
    }

    Get-NetIOByPid
    $diskIO = Get-DiskIODelta   # includes 1s sleep

    $t2      = [datetime]::UtcNow
    $elapsed = ($t2 - $t1).TotalSeconds

    $netIO    = Get-NetIORates
    $tcpByPid = Get-TcpByPid
    $udpByPid = Get-UdpByPid
    $adapters = Get-AdapterStats
    $sys      = Get-SystemSummary
    $cores    = Get-PerCoreCpuLoad -CoreCount $LogicalCpus

    $snap2 = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $snap2[$_.Id] = [PSCustomObject]@{
            Name    = $_.Name; CpuSec  = $_.CPU; MemWS    = $_.WorkingSet64
            Handles = $_.Handles; Threads = $_.Threads.Count
        }
    }

    $procs = foreach ($id in $snap1.Keys) {
        $p1 = $snap1[$id]; $p2 = $snap2[$id]
        if (-not $p2 -or $null -eq $p1.CpuSec -or $null -eq $p2.CpuSec) { continue }

        $delta  = [math]::Max(0, $p2.CpuSec - $p1.CpuSec)
        $cpuPct = [math]::Min([math]::Round($delta / ($elapsed * $LogicalCpus) * 100, 1), 100.0)

        $age = "?"
        if ($p1.StartTime) {
            $span = (Get-Date) - $p1.StartTime
            if    ($span.TotalDays  -ge 1) { $age = "{0}d{1:D2}h" -f [int]$span.TotalDays,  $span.Hours   }
            elseif($span.TotalHours -ge 1) { $age = "{0}h{1:D2}m" -f [int]$span.TotalHours, $span.Minutes }
            else                           { $age = "{0}m{1:D2}s" -f [int]$span.TotalMinutes,$span.Seconds }
        }

        $disk    = if ($diskIO.ContainsKey($id))   { $diskIO[$id]   } else { @(0L, 0L) }
        $netOth  = if ($netIO.ContainsKey($id))    { $netIO[$id]    } else { 0L }
        $tcpList = if ($tcpByPid.ContainsKey($id)) { $tcpByPid[$id] } else { @() }
        $udpCnt  = if ($udpByPid.ContainsKey($id)) { $udpByPid[$id] } else { 0 }
        $estab   = ($tcpList | Where-Object { $_.State -eq "Established" }).Count
        $listen  = ($tcpList | Where-Object { $_.State -eq "Listen"      }).Count

        [PSCustomObject]@{
            PID       = $id;          Name      = $p1.Name;     CPU       = $cpuPct
            MemWS     = $p2.MemWS;    Handles   = $p2.Handles;  Threads   = $p2.Threads
            Age       = $age;         DiskRead  = $disk[0];     DiskWrite = $disk[1]
            DiskTotal = $disk[0]+$disk[1]; NetOther = $netOth;  TCPTotal  = $tcpList.Count
            Estab     = $estab;       Listen    = $listen;      UDP       = $udpCnt
            Conns     = $tcpList
        }
    }

    return [PSCustomObject]@{
        Sys = $sys; Cores = $cores; Procs = @($procs); Adapters = $adapters; Elapsed = $elapsed
    }
}

# ============================================================
# PROCESS DETAIL — fetch extra info for the detail popup
# ============================================================
function Get-ProcessDetail {
    param([int]$Pid2)
    $proc = $null
    try { $proc = Get-Process -Id $Pid2 -ErrorAction Stop } catch { return $null }

    # Command line via WMI
    $cmdLine = ""
    try {
        $wmi = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$Pid2" -ErrorAction SilentlyContinue
        if ($wmi) { $cmdLine = $wmi.CommandLine }
    } catch {}

    # Modules (DLLs) — top 10 by size
    $modules = @()
    try {
        $modules = $proc.Modules | Sort-Object ModuleMemorySize -Descending |
                   Select-Object -First 10 |
                   ForEach-Object { [PSCustomObject]@{ Name=$_.ModuleName; Size=$_.ModuleMemorySize } }
    } catch {}

    # TCP connections for this PID
    $tcpConns = @()
    try {
        $tcpConns = Get-NetTCPConnection -OwningProcess $Pid2 -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        [PSCustomObject]@{
                            Local  = "$($_.LocalAddress):$($_.LocalPort)"
                            Remote = "$($_.RemoteAddress):$($_.RemotePort)"
                            State  = $_.State.ToString()
                        }
                    }
    } catch {}

    # Threads
    $threads = @()
    try {
        $threads = $proc.Threads | Select-Object -First 15 |
                   ForEach-Object { [PSCustomObject]@{ Id=$_.Id; State=$_.ThreadState; WaitReason=$_.WaitReason } }
    } catch {}

    # Resolve values that may throw before building the object
    $procPath     = try { $proc.MainModule.FileName }                          catch { "Access denied" }
    $procStart    = try { $proc.StartTime.ToString("yyyy-MM-dd HH:mm:ss") }   catch { "N/A" }
    $procCpu      = try { [math]::Round($proc.TotalProcessorTime.TotalSeconds, 2) } catch { 0 }
    $procPriority = try { $proc.PriorityClass.ToString() }                    catch { "N/A" }
    $procCmdLine  = if ($cmdLine) { $cmdLine } else { "Access denied" }

    [PSCustomObject]@{
        PID         = $Pid2
        Name        = $proc.Name
        Path        = $procPath
        CommandLine = $procCmdLine
        StartTime   = $procStart
        CPU         = $procCpu
        MemWS       = $proc.WorkingSet64
        MemPeak     = $proc.PeakWorkingSet64
        Handles     = $proc.HandleCount
        Threads     = $proc.Threads.Count
        Priority    = $procPriority
        Modules     = $modules
        TcpConns    = $tcpConns
        ThreadList  = $threads
    }
}

# ============================================================
# RENDER — PROCESS DETAIL POPUP
# ============================================================
function Invoke-RenderDetail {
    param([int]$W)

    $detail = Get-ProcessDetail -Pid2 $script:DetailPid
    if (-not $detail) {
        Buf-Write -Text "  Process PID $($script:DetailPid) not found or access denied." -Color $CLR.Alert -NewLine
        Buf-Write -Text "  Press Esc to close." -Color $CLR.KeyHint -NewLine
        return
    }

    # Header
    Write-Separator -Width $W
    Buf-Write -Text "  PROCESS DETAIL — $($detail.Name)  (PID $($detail.PID))   Esc to close" -Color $CLR.DetailHdr -NewLine
    Write-Separator -Width $W

    # Identity section
    Buf-Write -Text "  Path        : " -Color $CLR.DetailLabel
    Buf-Write -Text $detail.Path        -Color $CLR.DetailValue -NewLine

    # Command line wrapped to terminal width
    $cl = $detail.CommandLine
    $maxCl = $W - 18
    Buf-Write -Text "  CommandLine : " -Color $CLR.DetailLabel
    if ($cl.Length -le $maxCl) {
        Buf-Write -Text $cl -Color $CLR.DetailValue -NewLine
    } else {
        Buf-Write -Text $cl.Substring(0, $maxCl) -Color $CLR.DetailValue -NewLine
        $offset = $maxCl
        while ($offset -lt $cl.Length) {
            $chunk = $cl.Substring($offset, [math]::Min($maxCl, $cl.Length - $offset))
            Buf-Write -Text ("  " + " " * 15) -Color $CLR.DetailLabel
            Buf-Write -Text $chunk -Color $CLR.DetailValue -NewLine
            $offset += $maxCl
        }
    }

    Buf-Write -Text "  Started     : " -Color $CLR.DetailLabel
    Buf-Write -Text $detail.StartTime   -Color $CLR.DetailValue -NewLine

    Buf-Write -Text "  Priority    : " -Color $CLR.DetailLabel
    Buf-Write -Text $detail.Priority    -Color $CLR.DetailValue -NewLine

    # Performance section
    Write-Separator -Width $W
    Buf-Write -Text ("  CPU Time    : {0} s       Handles : {1}       Threads : {2}" `
        -f $detail.CPU, $detail.Handles, $detail.Threads) -Color $CLR.DetailValue -NewLine

    Buf-Write -Text "  Memory WS   : " -Color $CLR.DetailLabel
    Buf-Write -Text (Format-Bytes $detail.MemWS) -Color $CLR.DetailValue
    Buf-Write -Text "    Peak WS : " -Color $CLR.DetailLabel
    Buf-Write -Text (Format-Bytes $detail.MemPeak) -Color $CLR.DetailValue -NewLine

    # TCP connections
    if ($detail.TcpConns -and $detail.TcpConns.Count -gt 0) {
        Write-Separator -Width $W
        Buf-Write -Text ("  TCP CONNECTIONS ({0})" -f $detail.TcpConns.Count) -Color $CLR.DetailHdr -NewLine
        Buf-Write -Text ("  {0,-28} {1,-28} {2}" -f "LOCAL","REMOTE","STATE") -Color $CLR.ColHeader -NewLine
        foreach ($conn in ($detail.TcpConns | Select-Object -First 8)) {
            $sc = Get-StateColour -s $conn.State
            Buf-Write -Text ("  {0,-28} " -f $conn.Local)  -Color $CLR.TabInactive
            Buf-Write -Text ("{0,-28} "   -f $conn.Remote) -Color $CLR.Value
            Buf-Write -Text $conn.State -Color $sc -NewLine
        }
        if ($detail.TcpConns.Count -gt 8) {
            Buf-Write -Text ("  ... and $($detail.TcpConns.Count - 8) more connections") -Color $CLR.KeyHint -NewLine
        }
    }

    # Loaded modules
    if ($detail.Modules -and $detail.Modules.Count -gt 0) {
        Write-Separator -Width $W
        Buf-Write -Text "  TOP MODULES (by memory)" -Color $CLR.DetailHdr -NewLine
        Buf-Write -Text ("  {0,-40} {1,12}" -f "MODULE","SIZE") -Color $CLR.ColHeader -NewLine
        foreach ($mod in $detail.Modules) {
            Buf-Write -Text ("  {0,-40} {1,12}" -f $mod.Name, (Format-Bytes $mod.Size)) -Color $CLR.DetailValue -NewLine
        }
    }

    # Threads
    if ($detail.ThreadList -and $detail.ThreadList.Count -gt 0) {
        Write-Separator -Width $W
        Buf-Write -Text "  THREADS (first 15)" -Color $CLR.DetailHdr -NewLine
        Buf-Write -Text ("  {0,-8} {1,-16} {2}" -f "TID","STATE","WAIT REASON") -Color $CLR.ColHeader -NewLine
        foreach ($t in $detail.ThreadList) {
            $wr = if ($t.WaitReason) { $t.WaitReason.ToString() } else { "-" }
            Buf-Write -Text ("  {0,-8} {1,-16} {2}" -f $t.Id, $t.State, $wr) -Color $CLR.ProcNormal -NewLine
        }
    }

    Write-Separator -Width $W
    Buf-Write -Text "  Press Esc to return   k=kill this process" -Color $CLR.KeyHint -NewLine
}

# ============================================================
# ALERT ENGINE
# ============================================================
function Invoke-AlertCheck {
    param($Data)
    $ts = Get-Date -Format "HH:mm:ss"
    if ($Data.Sys.MemPct -ge $AlertMem) {
        $msg = "[$ts] MEM ALERT: $($Data.Sys.MemPct)% >= $AlertMem%"
        if ($script:AlertLog.Count -eq 0 -or $script:AlertLog[-1] -ne $msg) {
            $script:AlertLog.Add($msg)
        }
    }
    foreach ($p in $Data.Procs) {
        if ($p.CPU -ge $AlertCPU) {
            $script:AlertLog.Add("[$ts] CPU ALERT: $($p.Name) (PID $($p.PID)) at $($p.CPU)% >= $AlertCPU%")
        }
    }
    while ($script:AlertLog.Count -gt 50) { $script:AlertLog.RemoveAt(0) }
}

# ============================================================
# RENDER — SHARED SYSTEM HEADER
# ============================================================
function Write-SystemHeader {
    param($Sys, $Cores, [int]$LogicalCpus, [int]$W)

    Buf-Write -Text "  "       -Color $CLR.Label
    Buf-Write -Text "Uptime:"  -Color $CLR.Label
    Buf-Write -Text " $($Sys.Uptime)  " -Color $CLR.Value
    Buf-Write -Text (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Color $CLR.Value
    if ($script:Paused)                { Buf-Write -Text "  ** PAUSED **"                     -Color $CLR.Paused }
    if ($script:AlertLog.Count -gt 0) { Buf-Write -Text "  ⚠ $($script:AlertLog.Count) alert(s)" -Color $CLR.Alert }
    Buf-NewLine

    Buf-Write -Text "  "        -Color $CLR.Label
    Buf-Write -Text "CPU:  "    -Color $CLR.Label
    Buf-Write -Text $Sys.CpuName -Color $CLR.Value -NewLine

    Buf-Write -Text "  "     -Color $CLR.Label
    Buf-Write -Text "CPU % " -Color $CLR.Label
    Write-Bar -Pct $Sys.CpuLoad
    $cc = if ($Sys.CpuLoad -ge 80) { $CLR.BarHigh } elseif ($Sys.CpuLoad -ge 50) { $CLR.BarMid } else { $CLR.BarLow }
    Buf-Write -Text (" {0,5:N1}%" -f $Sys.CpuLoad) -Color $cc -NewLine

    if ($Cores -and $Cores.Count -gt 0) {
        $cpl = [math]::Min($LogicalCpus, 8)
        for ($row = 0; $row -lt [math]::Ceiling($LogicalCpus / $cpl); $row++) {
            Buf-Write -Text "  "     -Color $CLR.Label
            Buf-Write -Text "Cores " -Color $CLR.Label
            for ($ci = $row * $cpl; $ci -lt [math]::Min(($row+1)*$cpl, $LogicalCpus); $ci++) {
                $ld   = $Cores[$ci]
                $cc2  = if ($ld -ge 80) { $CLR.BarHigh } elseif ($ld -ge 50) { $CLR.BarMid } else { $CLR.BarLow }
                $fill = [math]::Round($ld / 100 * 5)
                Buf-Write -Text (" C$ci`[")             -Color $CLR.Separator
                Buf-Write -Text ("#" * $fill)            -Color $cc2
                Buf-Write -Text (" " * (5-$fill) + "]") -Color $CLR.Separator
                Buf-Write -Text ("{0,3:N0}%" -f $ld)    -Color $cc2
            }
            Buf-NewLine
        }
    }

    Buf-Write -Text "  "     -Color $CLR.Label
    Buf-Write -Text "Mem   " -Color $CLR.Label
    Write-Bar -Pct $Sys.MemPct
    $mc = if ($Sys.MemPct -ge $AlertMem) { $CLR.Alert } elseif ($Sys.MemPct -ge 50) { $CLR.BarMid } else { $CLR.BarLow }
    Buf-Write -Text (" {0,5:N1}%  used {1} / total {2}" -f $Sys.MemPct, (Format-Bytes $Sys.UsedMem), (Format-Bytes $Sys.TotalMem)) -Color $mc -NewLine
}

# ============================================================
# RENDER — TAB BAR
# ============================================================
function Write-TabBar {
    param([int]$W)
    $tabs = [ordered]@{
        "1:Processes" = "procs"; "2:Network" = "net"
        "3:Connections" = "conns"; "4:Adapters" = "adapters"
    }
    Buf-Write -Text "  " -Color $CLR.Separator
    foreach ($kv in $tabs.GetEnumerator()) {
        $active    = ($script:View -eq $kv.Value)
        $tabLabel  = if ($active) { "[ $($kv.Key) ]" } else { "  $($kv.Key)  " }
        $tabColour = if ($active) { $CLR.TabActive   } else { $CLR.TabInactive }
        Buf-Write -Text $tabLabel -Color $tabColour
        Buf-Write -Text "  "     -Color $CLR.Separator
    }
    Buf-NewLine
}

# ============================================================
# RENDER — HELP SCREEN
# ============================================================
function Invoke-RenderHelp {
    param([int]$W)
    $lines = @(
        @("",                     "")
        @("NAVIGATION",           "")
        @("  Tab / 1-4",          "Switch between views")
        @("  Up / Down",          "Move selection cursor  (scrolls list at edges)")
        @("  PgUp / PgDn",        "Scroll list by one full page")
        @("  h",                  "Toggle this help screen")
        @("  q / Esc",            "Quit")
        @("",                     "")
        @("VIEW 1 — PROCESSES",   "")
        @("  c",                  "Sort by CPU%")
        @("  m",                  "Sort by Memory")
        @("  d",                  "Sort by Disk I/O")
        @("  p",                  "Sort by PID")
        @("  n",                  "Sort by Name")
        @("",                     "")
        @("VIEW 2 — NETWORK",     "")
        @("  o",                  "Sort by Net I/O")
        @("  t",                  "Sort by TCP connections")
        @("  p",                  "Sort by PID")
        @("  n",                  "Sort by Name")
        @("",                     "")
        @("COMMON",               "")
        @("  f",                  "Filter by process name  (Enter to apply, Esc to cancel)")
        @("  r",                  "Toggle filter mode: regex / wildcard  (default: regex)")
        @("  Enter",              "Open process detail popup  (view 1 and 2 only)")
        @("  k",                  "Kill a process by PID   (or kill from detail popup)")
        @("  +  /  -",            "Increase / decrease refresh interval")
        @("  Space",              "Pause / resume data collection")
        @("",                     "")
        @("LAUNCH PARAMETERS",    "")
        @("  -RefreshInterval n", "Refresh every n seconds  (default: 5)")
        @("  -LogFile path.html", "Write HTML session log   (default: none)")
        @("  -CsvFile path.csv",  "Write CSV export log     (default: none)")
        @("  -LogMaxSnapshots n", "Max snapshots in log     (default: 200)")
        @("  -AlertCPU pct",      "CPU alert threshold %    (default: 80)")
        @("  -AlertMem pct",      "Memory alert threshold % (default: 90)")
        @("",                     "")
        @("  Edit param() defaults at top of script to persist settings", "")
        @("",                     "")
        @("  Press h or Esc to close", "")
    )
    Write-Separator -Width $W
    Buf-Write -Text ("  psys.ps1 — Help".PadRight($W)) -Color $CLR.Header -NewLine
    Write-Separator -Width $W
    foreach ($row in $lines) {
        $key  = $row[0]; $desc = $row[1]
        if ($key -eq "" -and $desc -eq "") {
            Buf-Write -Text "" -Color $CLR.Value -NewLine
        } elseif ($desc -eq "") {
            Buf-Write -Text "  $key" -Color $CLR.ColHeader -NewLine
        } else {
            Buf-Write -Text ("  {0,-26}" -f $key) -Color $CLR.HelpKey
            Buf-Write -Text $desc                  -Color $CLR.HelpDesc -NewLine
        }
    }
}

# ============================================================
# RENDER — VIEW 1: PROCESSES
# ============================================================
function Invoke-RenderProcs {
    param($Data, [int]$W)

    $procs = switch ($script:SortProcs) {
        "Memory" { $Data.Procs | Sort-Object MemWS     -Descending }
        "DiskIO" { $Data.Procs | Sort-Object DiskTotal -Descending }
        "PID"    { $Data.Procs | Sort-Object PID }
        "Name"   { $Data.Procs | Sort-Object Name }
        default  { $Data.Procs | Sort-Object CPU       -Descending }
    }
    if ($script:Filter) {
        $procs = if ($script:FilterMode -eq "regex") {
            $procs | Where-Object { try { $_.Name -match $script:Filter } catch { $_.Name -like "*$($script:Filter)*" } }
        } else {
            $procs | Where-Object { $_.Name -like "*$($script:Filter)*" }
        }
    }
    $procs = @($procs)

    $total  = $procs.Count
    $maxOff = [math]::Max(0, $total - $script:Rows)
    $script:ScrollOffset = [math]::Max(0, [math]::Min($script:ScrollOffset, $maxOff))

    $modeTag = if ($script:FilterMode -eq "regex") { " [regex]" } else { " [wildcard]" }
    $fi     = if ($script:Filter) { "  filter${modeTag}:'$($script:Filter)'" } else { "  [r] filter mode: $($script:FilterMode)" }
    $scroll = if ($total -gt $script:Rows) {
        "  ↑↓ ($($script:ScrollOffset+1)-$([math]::Min($script:ScrollOffset+$script:Rows,$total))/$total)"
    } else { "" }

    $filterClr = if ($script:FilterMode -eq "regex") { $CLR.RegexMode } else { $CLR.KeyHint }
    Buf-Write -Text ("  Processes: {0} total{1}   Sort: {2}   [c]PU [m]em [d]isk [p]id [n]ame   [k]ill   ↑↓=select  PgUp/PgDn=scroll  Enter=detail{3}" -f $total,$fi,$script:SortProcs,$scroll) -Color $filterClr -NewLine
    Write-Separator -Width $W
    Buf-Write -Text ("{0,-7} {1,-20} {2,6} {3,10} {4,10} {5,10} {6,8} {7,7} {8,9}" -f "PID","NAME","CPU%","MEM","DISK-R","DISK-W","SPARK","THDS","AGE") -Color $CLR.ColHeader -NewLine
    Write-Separator -Width $W

    $visibleProcs = @($procs | Select-Object -Skip $script:ScrollOffset -First $script:Rows)
    # Clamp selection to visible range
    $script:SelectionIdx = [math]::Max(0, [math]::Min($script:SelectionIdx, $visibleProcs.Count - 1))

    $rowIdx = 0
    foreach ($p in $visibleProcs) {
        $nm       = $p.Name; if ($nm.Length -gt 20) { $nm = $nm.Substring(0,17)+"..." }
        $cpuClr   = Get-CpuColour -p $p.CPU
        $mp       = if ($Data.Sys.TotalMem -gt 0) { [math]::Round($p.MemWS / $Data.Sys.TotalMem * 100, 1) } else { 0 }
        $memClr   = Get-MemColour -p $mp
        $isNew    = -not $script:KnownPids.ContainsKey($p.PID)
        $hist     = if ($script:CpuHistory.ContainsKey($p.PID)) { @($script:CpuHistory[$p.PID]) } else { @() }
        $spark    = Get-Sparkline -History $hist -Width 8
        $selected = ($rowIdx -eq $script:SelectionIdx)

        if ($selected) {
            # Selected row — marker + all columns in highlight colour
            Buf-Write -Text ([char]0x25B6 + " ")                     -Color 'Yellow'
            Buf-Write -Text ("{0,-6} " -f $p.PID)                   -Color 'Yellow'
            Buf-Write -Text ("{0,-20} " -f $nm)                     -Color 'White'
            Buf-Write -Text ("{0,6:N1} " -f $p.CPU)                 -Color 'Yellow'
            Buf-Write -Text ("{0,10} " -f (Format-Bytes $p.MemWS))  -Color 'Yellow'
            Buf-Write -Text ("{0,10} " -f (Format-IORate $p.DiskRead))  -Color 'Yellow'
            Buf-Write -Text ("{0,10} " -f (Format-IORate $p.DiskWrite)) -Color 'Yellow'
            Buf-Write -Text (" $spark ")                             -Color 'Cyan'
            Buf-Write -Text ("{0,7} " -f $p.Threads)                -Color 'Yellow'
            Buf-Write -Text ("{0,9}"  -f $p.Age)                    -Color 'Yellow' -NewLine
        } else {
            $nmClr = if ($isNew) { $CLR.NewProc } else { $CLR.ProcName }
            Buf-Write -Text "  "                                     -Color $CLR.ProcNormal
            Buf-Write -Text ("{0,-6} " -f $p.PID)                   -Color $CLR.ProcNormal
            Buf-Write -Text ("{0,-20} " -f $nm)                     -Color $nmClr
            Buf-Write -Text ("{0,6:N1} " -f $p.CPU)                 -Color $cpuClr
            Buf-Write -Text ("{0,10} " -f (Format-Bytes $p.MemWS))  -Color $memClr
            Buf-Write -Text ("{0,10} " -f (Format-IORate $p.DiskRead))  -Color $CLR.DiskIO
            Buf-Write -Text ("{0,10} " -f (Format-IORate $p.DiskWrite)) -Color $CLR.DiskIO
            Buf-Write -Text (" $spark ")                             -Color $CLR.Sparkline
            Buf-Write -Text ("{0,7} " -f $p.Threads)                -Color $CLR.ProcNormal
            Buf-Write -Text ("{0,9}"  -f $p.Age)                    -Color $CLR.ProcNormal -NewLine
        }
        $rowIdx++
    }

    # Track visible PIDs so Enter knows which PID is selected
    $script:LastVisiblePids = @($visibleProcs.PID)
    foreach ($p in $Data.Procs) { $script:KnownPids[$p.PID] = $true }
}

# ============================================================
# RENDER — VIEW 2: NETWORK
# ============================================================
function Invoke-RenderNet {
    param($Data, [int]$W)

    $procs = $Data.Procs | Where-Object { $_.NetOther -gt 0 -or $_.TCPTotal -gt 0 -or $_.UDP -gt 0 }
    if ($script:Filter) {
        $procs = if ($script:FilterMode -eq "regex") {
            $procs | Where-Object { try { $_.Name -match $script:Filter } catch { $_.Name -like "*$($script:Filter)*" } }
        } else {
            $procs | Where-Object { $_.Name -like "*$($script:Filter)*" }
        }
    }
    $procs = @(switch ($script:SortNet) {
        "TCP"  { $procs | Sort-Object TCPTotal -Descending }
        "PID"  { $procs | Sort-Object PID }
        "Name" { $procs | Sort-Object Name }
        default{ $procs | Sort-Object NetOther -Descending }
    })

    $total  = $procs.Count
    $maxOff = [math]::Max(0, $total - $script:Rows)
    $script:ScrollOffset = [math]::Max(0, [math]::Min($script:ScrollOffset, $maxOff))
    $fi     = if ($script:Filter) { "  filter:'$($script:Filter)'" } else { "" }
    $scroll = if ($total -gt $script:Rows) {
        "  ↑↓ ($($script:ScrollOffset+1)-$([math]::Min($script:ScrollOffset+$script:Rows,$total))/$total)"
    } else { "" }

    Buf-Write -Text ("  Network-active: {0}{1}   Sort: {2}   [o]IO [t]CP [p]id [n]ame   [k]ill{3}" -f $total,$fi,$script:SortNet,$scroll) -Color $CLR.KeyHint -NewLine
    Write-Separator -Width $W
    Buf-Write -Text ("{0,-7} {1,-22} {2,11} {3,7} {4,7} {5,7} {6,6}" -f "PID","NAME","NET I/O","TCP","ESTAB","LISTEN","UDP") -Color $CLR.ColHeader -NewLine
    Write-Separator -Width $W

    $visibleNet = @($procs | Select-Object -Skip $script:ScrollOffset -First $script:Rows)
    $script:SelectionIdx = [math]::Max(0, [math]::Min($script:SelectionIdx, $visibleNet.Count - 1))

    $rowIdx = 0
    foreach ($p in $visibleNet) {
        $nm       = $p.Name; if ($nm.Length -gt 22) { $nm = $nm.Substring(0,19)+"..." }
        $nc       = if ($p.NetOther -ge 1MB) { $CLR.BarHigh } elseif ($p.NetOther -ge 10KB) { $CLR.BarMid } else { $CLR.NetIO }
        $selected = ($rowIdx -eq $script:SelectionIdx)

        if ($selected) {
            Buf-Write -Text ([char]0x25B6 + " ")                       -Color 'Yellow'
            Buf-Write -Text ("{0,-6} " -f $p.PID)                     -Color 'Yellow'
            Buf-Write -Text ("{0,-22} " -f $nm)                       -Color 'White'
            Buf-Write -Text ("{0,11} " -f (Format-IORate $p.NetOther 11)) -Color 'Yellow'
            Buf-Write -Text ("{0,7} "  -f $p.TCPTotal)                -Color 'Yellow'
            Buf-Write -Text ("{0,7} "  -f $p.Estab)                   -Color 'Yellow'
            Buf-Write -Text ("{0,7} "  -f $p.Listen)                  -Color 'Yellow'
            Buf-Write -Text ("{0,6}"   -f $p.UDP)                     -Color 'Yellow' -NewLine
        } else {
            Buf-Write -Text "  "                                       -Color $CLR.ProcNormal
            Buf-Write -Text ("{0,-6} " -f $p.PID)                     -Color $CLR.ProcNormal
            Buf-Write -Text ("{0,-22} " -f $nm)                       -Color $CLR.ProcName
            Buf-Write -Text ("{0,11} " -f (Format-IORate $p.NetOther 11)) -Color $nc
            Buf-Write -Text ("{0,7} "  -f $p.TCPTotal)                -Color $CLR.ProcNormal
            Buf-Write -Text ("{0,7} "  -f $p.Estab)                   -Color $CLR.Established
            Buf-Write -Text ("{0,7} "  -f $p.Listen)                  -Color $CLR.Listen
            Buf-Write -Text ("{0,6}"   -f $p.UDP)                     -Color $CLR.NetIO -NewLine
        }
        $rowIdx++
    }
    $script:LastVisiblePids = @($visibleNet.PID)
}

# ============================================================
# RENDER — VIEW 3: TCP CONNECTIONS
# ============================================================
function Invoke-RenderConns {
    param($Data, [int]$W)

    $allConns = [System.Collections.Generic.List[object]]::new()
    $procs = $Data.Procs | Where-Object { $_.TCPTotal -gt 0 }
    if ($script:Filter) {
        $procs = if ($script:FilterMode -eq "regex") {
            $procs | Where-Object { try { $_.Name -match $script:Filter } catch { $_.Name -like "*$($script:Filter)*" } }
        } else {
            $procs | Where-Object { $_.Name -like "*$($script:Filter)*" }
        }
    }
    foreach ($p in ($procs | Sort-Object TCPTotal -Descending)) {
        foreach ($c in $p.Conns) {
            $allConns.Add([PSCustomObject]@{ ProcName=$p.Name; PID=$p.PID; Conn=$c })
        }
    }

    $total  = $allConns.Count
    $maxOff = [math]::Max(0, $total - $script:Rows)
    $script:ScrollOffset = [math]::Max(0, [math]::Min($script:ScrollOffset, $maxOff))
    $scroll = if ($total -gt $script:Rows) {
        "  ↑↓ ($($script:ScrollOffset+1)-$([math]::Min($script:ScrollOffset+$script:Rows,$total))/$total)"
    } else { "" }

    Buf-Write -Text ("  TCP Connections: {0} total{1}" -f $total,$scroll) -Color $CLR.KeyHint -NewLine
    Write-Separator -Width $W
    Buf-Write -Text ("{0,-22} {1,-6} {2,-24} {3,-24} {4}" -f "PROCESS","PID","LOCAL","REMOTE","STATE") -Color $CLR.ColHeader -NewLine
    Write-Separator -Width $W

    foreach ($row in ($allConns | Select-Object -Skip $script:ScrollOffset -First $script:Rows)) {
        $nm     = $row.ProcName; if ($nm.Length -gt 22) { $nm = $nm.Substring(0,19)+"..." }
        $local  = "$($row.Conn.LocalAddress):$($row.Conn.LocalPort)"
        $remote = "$($row.Conn.RemoteAddress):$($row.Conn.RemotePort)"
        $sc     = Get-StateColour -s $row.Conn.State

        Buf-Write -Text ("{0,-22} " -f $nm)     -Color $CLR.ProcName
        Buf-Write -Text ("{0,-6} "  -f $row.PID)-Color $CLR.ProcNormal
        Buf-Write -Text ("{0,-24} " -f $local)  -Color $CLR.TabInactive
        Buf-Write -Text ("{0,-24} " -f $remote) -Color $CLR.Value
        Buf-Write -Text ("{0}"      -f $row.Conn.State) -Color $sc -NewLine
    }
}

# ============================================================
# RENDER — VIEW 4: ADAPTERS
# ============================================================
function Invoke-RenderAdapters {
    param($Data, [int]$W)

    Buf-Write -Text "  Network Adapters" -Color $CLR.KeyHint -NewLine
    Write-Separator -Width $W

    if (-not $Data.Adapters -or $Data.Adapters.Count -eq 0) {
        Buf-Write -Text "  No adapter data available." -Color $CLR.ProcNormal -NewLine
        return
    }

    Buf-Write -Text ("{0,-30} {1,-8} {2,-18} {3,14} {4,14}" -f "ADAPTER","STATUS","SPEED","TOTAL RECV","TOTAL SENT") -Color $CLR.ColHeader -NewLine
    Write-Separator -Width $W

    foreach ($a in $Data.Adapters) {
        $nm = $a.Name; if ($nm.Length -gt 30) { $nm = $nm.Substring(0,27)+"..." }
        $sc = if ($a.Status -eq "Up") { $CLR.AdapterOk } else { $CLR.AdapterOff }

        Buf-Write -Text ("{0,-30} " -f $nm)                          -Color $CLR.ProcName
        Buf-Write -Text ("{0,-8} "  -f $a.Status)                    -Color $sc
        Buf-Write -Text ("{0,-18} " -f $a.Speed)                     -Color $CLR.Value
        Buf-Write -Text ("{0,14} "  -f (Format-Bytes $a.ReceivedBytes)) -Color $CLR.NetIO
        Buf-Write -Text ("{0,14}"   -f (Format-Bytes $a.SentBytes))     -Color $CLR.NetIO -NewLine
    }
}

# ============================================================
# MASTER RENDER — builds buffer then flushes in one shot
# ============================================================
function Invoke-Render {
    param($Data, [int]$LogicalCpus)

    $W = [Console]::WindowWidth - 1
    $H = [Console]::WindowHeight

    # Reset scroll on terminal resize
    if ($W -ne $script:LastW -or $H -ne $script:LastH) {
        $script:LastW = $W; $script:LastH = $H
        $script:ScrollOffset = 0
    }

    $coreRows    = if ($LogicalCpus -gt 0) { [math]::Ceiling($LogicalCpus / 8) } else { 1 }
    $script:Rows = [math]::Max(3, $H - 15 - $coreRows)

    # Reset buffer for this frame
    $script:Buf     = [System.Collections.Generic.List[object]]::new()
    $script:BufLine = [System.Collections.Generic.List[object]]::new()

    # Title bar
    $logParts = @()
    if ($LogFile)             { $logParts += "html->$(Split-Path $LogFile -Leaf)" }
    if ($script:CsvFile -ne "") { $logParts += "csv->$(Split-Path $script:CsvFile -Leaf)" }
    $logTag = if ($logParts.Count -gt 0) { "  " + ($logParts -join "  ") } else { "" }
    $title  = " psys  |  q:quit  h:help  Tab/1-4:view  f:filter  ↑↓:scroll  +/-:speed  Space:pause$logTag"
    Buf-Write -Text ($title.PadRight($W).Substring(0, [math]::Min($title.Length+1, $W))) -Color $CLR.Header -NewLine
    Write-Separator -Width $W

    Write-SystemHeader -Sys $Data.Sys -Cores $Data.Cores -LogicalCpus $LogicalCpus -W $W
    Write-Separator -Width $W
    Write-TabBar -W $W
    Write-Separator -Width $W

    if ($script:Mode -eq "help") {
        Invoke-RenderHelp -W $W
    } elseif ($script:Mode -eq "detail") {
        Invoke-RenderDetail -W $W
    } else {
        switch ($script:View) {
            "procs"    { Invoke-RenderProcs    -Data $Data -W $W }
            "net"      { Invoke-RenderNet      -Data $Data -W $W }
            "conns"    { Invoke-RenderConns    -Data $Data -W $W }
            "adapters" { Invoke-RenderAdapters -Data $Data -W $W }
        }
    }

    Write-Separator -Width $W

    # Status / mode line
    if ($script:Mode -eq "filter") {
        $fmLabel   = if ($script:FilterMode -eq "regex") { "[regex]" } else { "[wildcard]" }
        $fmLClr    = if ($script:FilterMode -eq "regex") { $CLR.RegexMode } else { $CLR.ModeMsg }
        $inputText = if ($script:ModeInput.Length -gt 0) { $script:ModeInput } else { "" }
        $cursor    = [char]0x258C   # left half-block — clearly visible blinking-style cursor

        Write-Separator -Width $W
        Buf-Write -Text "  FILTER " -Color 'White'
        Buf-Write -Text $fmLabel    -Color $fmLClr
        Buf-Write -Text "  ›  "     -Color $CLR.Separator
        Buf-Write -Text $inputText  -Color 'Yellow'
        Buf-Write -Text "$cursor"   -Color 'Yellow'
        Buf-Write -Text ("  " + "·" * [math]::Max(0, 30 - $inputText.Length)) -Color 'DarkGray'
        Buf-Write -Text "   Enter=apply  Esc=cancel  r=toggle regex/wildcard" -Color $CLR.KeyHint -NewLine
    } elseif ($script:Mode -eq "kill") {
        $inputText = if ($script:ModeInput.Length -gt 0) { $script:ModeInput } else { "" }
        $cursor    = [char]0x258C

        Write-Separator -Width $W
        Buf-Write -Text "  KILL PROCESS " -Color 'Red'
        Buf-Write -Text "  ›  "           -Color $CLR.Separator
        Buf-Write -Text $inputText         -Color 'Yellow'
        Buf-Write -Text "$cursor"          -Color 'Yellow'
        Buf-Write -Text ("  " + "·" * [math]::Max(0, 20 - $inputText.Length)) -Color 'DarkGray'
        Buf-Write -Text "   Enter=confirm  Esc=cancel" -Color $CLR.KeyHint -NewLine
    } elseif ($script:AlertLog.Count -gt 0 -and $script:Mode -ne "help") {
        Buf-Write -Text "  ⚠ $($script:AlertLog[-1])" -Color $CLR.Alert -NewLine
    } elseif ($script:ModeMsg) {
        Buf-Write -Text "  >> $($script:ModeMsg)" -Color $CLR.ModeMsg -NewLine
        $script:ModeMsg = ""
    } else {
        $fmTag = if ($script:FilterMode -eq "regex") { "[regex] " } else { "[wildcard] " }
        $fmClr = if ($script:FilterMode -eq "regex") { $CLR.RegexMode } else { $CLR.KeyHint }
        $selPid = if ($script:View -in @("procs","net") -and $script:LastVisiblePids.Count -gt $script:SelectionIdx) {
            "  Selected PID: $($script:LastVisiblePids[$script:SelectionIdx])"
        } else { "" }
        Buf-Write -Text "  Ready. " -Color $CLR.KeyHint
        Buf-Write -Text $fmTag      -Color $fmClr
        Buf-Write -Text "Alerts: CPU>$AlertCPU%  Mem>$AlertMem%" -Color $CLR.KeyHint
        if ($selPid) { Buf-Write -Text $selPid -Color 'Yellow' }
        Buf-Write -Text "" -Color $CLR.KeyHint -NewLine
    }

    # Flush entire buffer to screen without ever clearing — no flicker
    [Console]::CursorVisible = $false
    Invoke-FlushBuffer -W $W -H $H
}

# ============================================================
# CSV LOG
# ============================================================
function Write-CsvLog {
    param($Data)
    if ($script:CsvFile -eq "") { return }

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Write header on first call
    if (-not $script:CsvInitDone) {
        $header = "Timestamp,PID,Name,CPU_Pct,Mem_Bytes,Mem_MB,DiskRead_Bps,DiskWrite_Bps,NetOther_Bps,TCP_Connections,UDP_Endpoints,Threads,Age,Alert"
        try {
            $header | Out-File -FilePath $script:CsvFile -Encoding utf8 -Force
            $script:CsvInitDone = $true
        } catch {
            $script:ModeMsg = "CSV error: $_"
            return
        }
    }

    # One row per process per refresh cycle
    $lines = foreach ($p in $Data.Procs) {
        $memMB   = [math]::Round($p.MemWS / 1MB, 2)
        $isAlert = if ($p.CPU -ge $AlertCPU) { "1" } else { "0" }
        # Escape name in case it contains a comma
        $name    = '"' + $p.Name.Replace('"', '""') + '"'
        "$ts,$($p.PID),$name,$($p.CPU),$($p.MemWS),$memMB,$($p.DiskRead),$($p.DiskWrite),$($p.NetOther),$($p.TCPTotal),$($p.UDP),$($p.Threads),$($p.Age),$isAlert"
    }

    try {
        $lines | Out-File -FilePath $script:CsvFile -Encoding utf8 -Append
    } catch {
        $script:ModeMsg = "CSV write error: $_"
    }
}

# ============================================================
# HTML LOG
# ============================================================
function Get-HtmlClass { param([double]$p); if($p -ge 80){"high"} elseif($p -ge 40){"mid"} else{"low"} }

function Write-HtmlLog {
    param($Data)
    if ($LogFile -eq "") { return }

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $script:HtmlSnapshots.Add([PSCustomObject]@{
        Timestamp = $ts; Sys = $Data.Sys; Cores = $Data.Cores; Procs = $Data.Procs
    })
    while ($script:HtmlSnapshots.Count -gt $LogMaxSnapshots) { $script:HtmlSnapshots.RemoveAt(0) }

    $snapHtml = [System.Text.StringBuilder]::new()
    for ($si = $script:HtmlSnapshots.Count-1; $si -ge 0; $si--) {
        $snap = $script:HtmlSnapshots[$si]; $s = $snap.Sys
        $cc   = Get-HtmlClass $s.CpuLoad;  $mc = Get-HtmlClass $s.MemPct
        $open = if ($si -eq $script:HtmlSnapshots.Count-1) { "open" } else { "" }

        $null = $snapHtml.Append("<details class='snap $open'><summary>")
        $null = $snapHtml.Append("<span class='ts'>$($snap.Timestamp)</span>")
        $null = $snapHtml.Append("  CPU <span class='$cc'>$($s.CpuLoad)%</span>")
        $null = $snapHtml.Append("  MEM <span class='$mc'>$($s.MemPct)%</span>")
        $null = $snapHtml.Append("  Uptime: $($s.Uptime)</summary>")

        $cpuW = [math]::Round($s.CpuLoad); $memW = [math]::Round($s.MemPct)
        $null = $snapHtml.Append("<div class='si'>")
        $null = $snapHtml.Append("<div class='sr'><span class='lb'>CPU</span><div class='bar'><div class='fill $cc' style='width:$cpuW%'></div></div><span class='$cc'>$($s.CpuLoad)%</span></div>")
        $null = $snapHtml.Append("<div class='sr'><span class='lb'>MEM</span><div class='bar'><div class='fill $mc' style='width:$memW%'></div></div><span class='$mc'>$($s.MemPct)% — $(Format-Bytes $s.UsedMem) / $(Format-Bytes $s.TotalMem)</span></div>")
        $null = $snapHtml.Append("</div>")

        $null = $snapHtml.Append("<table><thead><tr><th>PID</th><th>Name</th><th>CPU%</th><th>Mem</th><th>Disk R</th><th>Disk W</th><th>Net I/O</th><th>TCP</th><th>UDP</th><th>Threads</th><th>Age</th></tr></thead><tbody>")
        foreach ($p in $snap.Procs) {
            $pc  = Get-HtmlClass $p.CPU
            $mp  = if ($s.TotalMem -gt 0) { [math]::Round($p.MemWS / $s.TotalMem * 100, 1) } else { 0 }
            $mpc = Get-HtmlClass $mp
            $ar  = if ($p.CPU -ge $AlertCPU) { " class='alert-row'" } else { "" }
            $null = $snapHtml.Append("<tr$ar><td>$($p.PID)</td><td class='pn'>$($p.Name)</td>")
            $null = $snapHtml.Append("<td class='$pc'>$($p.CPU)</td><td class='$mpc'>$(Format-Bytes $p.MemWS)</td>")
            $null = $snapHtml.Append("<td class='io'>$(Format-IORate $p.DiskRead)</td><td class='io'>$(Format-IORate $p.DiskWrite)</td>")
            $null = $snapHtml.Append("<td class='io'>$(Format-IORate $p.NetOther)</td>")
            $null = $snapHtml.Append("<td>$($p.TCPTotal)</td><td>$($p.UDP)</td><td>$($p.Threads)</td><td>$($p.Age)</td></tr>")
        }
        $null = $snapHtml.Append("</tbody></table></details>")
    }

    $alertHtml = ""
    if ($script:AlertLog.Count -gt 0) {
        $alertHtml = "<h2 class='alert-hdr'>⚠ Alerts</h2><div class='alert-box'>"
        foreach ($a in ($script:AlertLog | Select-Object -Last 20)) {
            $alertHtml += "<div class='alert-line'>$a</div>"
        }
        $alertHtml += "</div>"
    }

    $html = @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<title>psys log — $($script:HtmlSnapshots[-1].Timestamp)</title>
<style>
:root{--bg:#0d1117;--bg2:#161b22;--bg3:#1f2937;--bd:#30363d;--tx:#c9d1d9;--dim:#6e7681;
      --low:#3fb950;--mid:#d29922;--high:#f85149;--ac:#58a6ff;--io:#79c0ff;--nm:#e6edf3}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--tx);font-family:'Consolas','Fira Mono',monospace;font-size:13px;padding:16px}
h1{color:var(--ac);font-size:18px;margin-bottom:4px}
h2.alert-hdr{color:var(--high);font-size:14px;margin:16px 0 8px}
.meta{color:var(--dim);margin-bottom:12px;font-size:12px}
.note{color:var(--mid);font-style:italic}
.alert-box{background:var(--bg2);border:1px solid var(--high);border-radius:6px;padding:10px 14px;margin-bottom:16px}
.alert-line{color:var(--high);font-size:12px;padding:2px 0}
details.snap{border:1px solid var(--bd);border-radius:6px;margin-bottom:8px;background:var(--bg2);overflow:hidden}
details.snap summary{cursor:pointer;padding:8px 12px;list-style:none;display:flex;align-items:center;gap:14px;background:var(--bg3);user-select:none;border-bottom:1px solid transparent}
details.snap[open] summary{border-bottom-color:var(--bd)}
details.snap summary::before{content:"▶";color:var(--dim);font-size:10px;margin-right:4px;transition:transform .15s}
details.snap[open] summary::before{transform:rotate(90deg)}
.ts{color:var(--ac);min-width:160px}
.si{padding:8px 14px;border-bottom:1px solid var(--bd)}
.sr{display:flex;align-items:center;gap:8px;margin-bottom:4px}
.lb{color:var(--dim);min-width:36px}
.bar{flex:0 0 200px;height:9px;background:#21262d;border-radius:4px;overflow:hidden}
.fill{height:100%;border-radius:4px}
.low{color:var(--low)}.mid{color:var(--mid)}.high{color:var(--high)}
.fill.low{background:var(--low)}.fill.mid{background:var(--mid)}.fill.high{background:var(--high)}
table{width:100%;border-collapse:collapse;font-size:12px}
thead tr{background:var(--bg3)}
th{padding:5px 8px;text-align:right;color:var(--dim);font-weight:600;border-bottom:1px solid var(--bd);white-space:nowrap}
th:nth-child(2){text-align:left}
td{padding:3px 8px;text-align:right;border-bottom:1px solid #21262d;white-space:nowrap}
td:nth-child(2){text-align:left}
tr:hover td{background:#1c2128}
tr.alert-row td{background:#2d1117}
tr.alert-row td:nth-child(3){color:var(--high);font-weight:bold}
.pn{color:var(--nm)}.io{color:var(--io)}
.toolbar{margin-bottom:12px;display:flex;gap:10px;align-items:center}
#search{background:var(--bg2);border:1px solid var(--bd);color:var(--tx);padding:5px 10px;
        border-radius:4px;font-family:monospace;font-size:13px;width:220px}
#search:focus{outline:none;border-color:var(--ac)}
.badge{background:var(--bg3);border:1px solid var(--bd);border-radius:4px;padding:3px 10px;color:var(--dim);font-size:12px}
</style></head><body>
<h1>⚡ psys — session log</h1>
<div class="meta">
  Host: <b>$($env:COMPUTERNAME)</b> &nbsp;|&nbsp;
  $($script:HtmlSnapshots[-1].Sys.CpuName) &nbsp;|&nbsp;
  Snapshots: $($script:HtmlSnapshots.Count)/$LogMaxSnapshots &nbsp;|&nbsp;
  Last: <b>$($script:HtmlSnapshots[-1].Timestamp)</b> &nbsp;|&nbsp;
  Alerts: CPU&gt;$AlertCPU%  Mem&gt;$AlertMem% &nbsp;|&nbsp;
  <span class="note">Static — press F5 to reload</span>
</div>
$alertHtml
<div class="toolbar">
  <input id="search" type="text" placeholder="Filter by process name…" oninput="filterRows(this.value)">
  <span class="badge" id="badge">—</span>
</div>
$($snapHtml.ToString())
<script>
function filterRows(q){
  q=q.toLowerCase();
  document.querySelectorAll('tbody tr').forEach(function(r){
    var n=r.cells[1]?r.cells[1].textContent.toLowerCase():'';
    r.style.display=(!q||n.includes(q))?'':'none';
  });
  document.getElementById('badge').textContent=
    document.querySelectorAll('tbody tr:not([style*="none"])').length+' rows';
}
document.getElementById('badge').textContent=
  document.querySelectorAll('tbody tr').length+' total rows';
</script></body></html>
"@
    $html | Out-File -FilePath $LogFile -Encoding utf8 -Force
}

# ============================================================
# KEY INPUT
# ============================================================
function Invoke-KeyInput {
    if (-not [Console]::KeyAvailable) { return }
    $key = [Console]::ReadKey($true)

    if ($script:Mode -eq "filter") {
        if    ($key.Key -eq "Enter") {
            $script:Filter=$script:ModeInput.Trim(); $script:ModeInput=""
            $script:Mode="normal"; $script:ScrollOffset=0
            $script:ModeMsg = if ($script:Filter) { "Filter: '$($script:Filter)'" } else { "Filter cleared" }
        }
        elseif($key.Key -eq "Escape")    { $script:ModeInput=""; $script:Mode="normal"; $script:ModeMsg="Cancelled" }
        elseif($key.Key -eq "Backspace") { if($script:ModeInput.Length -gt 0){ $script:ModeInput=$script:ModeInput.Substring(0,$script:ModeInput.Length-1) } }
        else                             { $script:ModeInput += $key.KeyChar }
        $script:NeedsRender = $true; return
    }

    if ($script:Mode -eq "kill") {
        if ($key.Key -eq "Enter") {
            $pidStr=$script:ModeInput.Trim(); $script:ModeInput=""; $script:Mode="normal"
            if ($pidStr -match '^\d+$') {
                try   { Stop-Process -Id ([int]$pidStr) -Force -ErrorAction Stop; $script:ModeMsg="Killed PID $pidStr" }
                catch { $script:ModeMsg="Kill failed: $_" }
            } else { $script:ModeMsg="Cancelled (invalid PID)" }
        }
        elseif($key.Key -eq "Escape")    { $script:ModeInput=""; $script:Mode="normal"; $script:ModeMsg="Cancelled" }
        elseif($key.Key -eq "Backspace") { if($script:ModeInput.Length -gt 0){ $script:ModeInput=$script:ModeInput.Substring(0,$script:ModeInput.Length-1) } }
        else                             { $script:ModeInput += $key.KeyChar }
        $script:NeedsRender = $true; return
    }

    # Up/Down — move selection cursor; scroll list when cursor reaches edge
    if ($key.Key -eq [ConsoleKey]::UpArrow) {
        if ($script:View -in @("procs","net")) {
            if ($script:SelectionIdx -gt 0) {
                $script:SelectionIdx--
            } elseif ($script:ScrollOffset -gt 0) {
                $script:ScrollOffset--   # scroll up when at top of visible area
            }
        } else {
            $script:ScrollOffset = [math]::Max(0, $script:ScrollOffset - 1)
        }
        $script:NeedsRender = $true; return
    }
    if ($key.Key -eq [ConsoleKey]::DownArrow) {
        if ($script:View -in @("procs","net")) {
            if ($script:SelectionIdx -lt ($script:Rows - 1)) {
                $script:SelectionIdx++
            } else {
                $script:ScrollOffset++   # scroll down when at bottom of visible area
            }
        } else {
            $script:ScrollOffset++
        }
        $script:NeedsRender = $true; return
    }

    # PgUp / PgDn — scroll by one full page
    if ($key.Key -eq [ConsoleKey]::PageUp) {
        $script:ScrollOffset = [math]::Max(0, $script:ScrollOffset - $script:Rows)
        $script:SelectionIdx = 0
        $script:NeedsRender = $true; return
    }
    if ($key.Key -eq [ConsoleKey]::PageDown) {
        $script:ScrollOffset += $script:Rows
        $script:SelectionIdx = 0
        $script:NeedsRender = $true; return
    }

    # Enter — open detail for the currently selected (highlighted) row
    if ($key.Key -eq [ConsoleKey]::Enter) {
        if ($script:Mode -eq "detail") {
            $script:Mode="normal"; $script:NeedsRender=$true; return
        }
        if ($script:View -in @("procs","net") -and $script:LastVisiblePids -and $script:LastVisiblePids.Count -gt 0) {
            if ($script:SelectionIdx -lt $script:LastVisiblePids.Count) {
                $script:DetailPid = $script:LastVisiblePids[$script:SelectionIdx]
                $script:Mode = "detail"
                $script:NeedsRender = $true
            }
        }
        return
    }

    if ($key.Key -eq [ConsoleKey]::Tab) {
        $script:View=switch($script:View){"procs"{"net"}"net"{"conns"}"conns"{"adapters"}"adapters"{"procs"}}
        $script:ScrollOffset=0; $script:SelectionIdx=0; $script:Mode="normal"; $script:NeedsRender=$true; return
    }

    switch ($key.KeyChar) {
        'h' { $script:Mode=if($script:Mode-eq"help"){"normal"}else{"help"};                                       $script:NeedsRender=$true }
        '1' { $script:View="procs";    $script:ScrollOffset=0; $script:SelectionIdx=0; $script:Mode="normal"; $script:ModeMsg="Processes";  $script:NeedsRender=$true }
        '2' { $script:View="net";      $script:ScrollOffset=0; $script:SelectionIdx=0; $script:Mode="normal"; $script:ModeMsg="Network";     $script:NeedsRender=$true }
        '3' { $script:View="conns";    $script:ScrollOffset=0; $script:SelectionIdx=0; $script:Mode="normal"; $script:ModeMsg="Connections"; $script:NeedsRender=$true }
        '4' { $script:View="adapters"; $script:ScrollOffset=0; $script:SelectionIdx=0; $script:Mode="normal"; $script:ModeMsg="Adapters";    $script:NeedsRender=$true }
        'c' { if($script:View-eq"procs"){$script:SortProcs="CPU";    $script:ScrollOffset=0; $script:SelectionIdx=0; $script:ModeMsg="Sort: CPU";    $script:NeedsRender=$true} }
        'm' { if($script:View-eq"procs"){$script:SortProcs="Memory"; $script:ScrollOffset=0; $script:SelectionIdx=0; $script:ModeMsg="Sort: Memory"; $script:NeedsRender=$true} }
        'd' { if($script:View-eq"procs"){$script:SortProcs="DiskIO"; $script:ScrollOffset=0; $script:SelectionIdx=0; $script:ModeMsg="Sort: Disk";   $script:NeedsRender=$true} }
        'p' { if($script:View-eq"procs"){$script:SortProcs="PID";    $script:ScrollOffset=0; $script:SelectionIdx=0; $script:ModeMsg="Sort: PID";    $script:NeedsRender=$true}
              if($script:View-eq"net")  {$script:SortNet="PID";      $script:ScrollOffset=0; $script:SelectionIdx=0; $script:ModeMsg="Sort: PID";    $script:NeedsRender=$true} }
        'n' { if($script:View-eq"procs"){$script:SortProcs="Name";   $script:ScrollOffset=0; $script:SelectionIdx=0; $script:ModeMsg="Sort: Name";   $script:NeedsRender=$true}
              if($script:View-eq"net")  {$script:SortNet="Name";     $script:ScrollOffset=0; $script:SelectionIdx=0; $script:ModeMsg="Sort: Name";   $script:NeedsRender=$true} }
        'o' { if($script:View-eq"net")  {$script:SortNet="IO";       $script:ScrollOffset=0; $script:SelectionIdx=0; $script:ModeMsg="Sort: Net I/O";$script:NeedsRender=$true} }
        't' { if($script:View-eq"net")  {$script:SortNet="TCP";      $script:ScrollOffset=0; $script:SelectionIdx=0; $script:ModeMsg="Sort: TCP";    $script:NeedsRender=$true} }
        'f' { $script:Mode="filter"; $script:ModeInput=""; $script:ModeMsg=""; $script:NeedsRender=$true }
        'r' { $script:FilterMode = if($script:FilterMode -eq "regex"){"wildcard"}else{"regex"}
              $script:ModeMsg = "Filter mode: $($script:FilterMode)"; $script:NeedsRender=$true }
        'k' { if ($script:Mode -eq "detail") {
                  # Kill directly from detail view
                  try { Stop-Process -Id $script:DetailPid -Force -ErrorAction Stop
                        $script:ModeMsg="Killed PID $($script:DetailPid)"
                        $script:Mode="normal" }
                  catch { $script:ModeMsg="Kill failed: $_" }
              } else { $script:Mode="kill"; $script:ModeInput=""; $script:ModeMsg="" }
              $script:NeedsRender=$true }
        '+' { $script:Interval=[math]::Min($script:Interval+1,60); $script:ModeMsg="Refresh: $($script:Interval)s"; $script:NeedsRender=$true }
        '-' { $script:Interval=[math]::Max($script:Interval-1,1);  $script:ModeMsg="Refresh: $($script:Interval)s"; $script:NeedsRender=$true }
        ' ' { $script:Paused=-not $script:Paused; $script:ModeMsg=if($script:Paused){"PAUSED"}else{"Resumed"};      $script:NeedsRender=$true }
        'q' { throw "quit" }
    }
    if ($key.Key -eq [ConsoleKey]::Escape) {
        if ($script:Mode -eq "help" -or $script:Mode -eq "detail") {
            $script:Mode="normal"; $script:NeedsRender=$true
        } else { throw "quit" }
    }
}

# ============================================================
# MAIN LOOP
# ============================================================
$logicalCpus = Get-LogicalCpuCount

Write-Host "psys starting... (collecting first snapshot, please wait)" -ForegroundColor Cyan
try {
    $null = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
} catch { Write-Host "ERROR: Cannot query WMI/CIM. $_" -ForegroundColor Red; exit 1 }
try {
    $null = Get-Process -ErrorAction Stop | Select-Object -First 1
} catch { Write-Host "ERROR: Cannot query processes. $_" -ForegroundColor Red; exit 1 }

[Console]::CursorVisible = $false
$lastData = $null

$syncHash = [hashtable]::Synchronized(@{
    LogicalCpus = $logicalCpus
    Paused      = $false
    Interval    = $script:Interval
    Result      = $null
    Error       = $null
    Done        = $false
    Stop        = $false
})

$collectScript = {
    param($sync, $fnDefs)
    foreach ($def in $fnDefs) { Invoke-Expression $def }
    while (-not $sync.Stop) {
        if (-not $sync.Paused) {
            try {
                $sync.Result = Get-AllData -LogicalCpus $sync.LogicalCpus
                $sync.Error  = $null
            } catch {
                $sync.Error  = $_.ToString()
                $sync.Result = $null
            }
            $sync.Done = $true
        }
        $elapsed = 0
        while ($elapsed -lt $sync.Interval -and -not $sync.Stop) {
            Start-Sleep -Milliseconds 200
            $elapsed += 0.2
        }
    }
}

$fnNames = @(
    'Get-UptimeString','Get-LogicalCpuCount','Get-PerCoreCpuLoad','Get-SystemSummary',
    'Get-DiskIODelta','Get-NetIOByPid','Get-NetIORates',
    'Get-TcpByPid','Get-UdpByPid','Get-AdapterStats','Get-AllData'
)
$fnDefs = $fnNames | ForEach-Object { "function $_ { $((Get-Command $_).Definition) }" }

$rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$rs.Open()
$ps = [System.Management.Automation.PowerShell]::Create()
$ps.Runspace = $rs
$null = $ps.AddScript($collectScript).AddArgument($syncHash).AddArgument($fnDefs)
$asyncResult = $ps.BeginInvoke()

try {
    while ($true) {
        $syncHash.Interval = $script:Interval
        $syncHash.Paused   = $script:Paused

        if ($syncHash.Done) {
            $syncHash.Done = $false
            if ($syncHash.Error) {
                [Console]::CursorVisible = $true; [Console]::Clear()
                Write-Host "ERROR in Get-AllData:" -ForegroundColor Red
                Write-Host $syncHash.Error -ForegroundColor Red
                Write-Host "`nPress any key to exit..." -ForegroundColor DarkGray
                $null = [Console]::ReadKey($true); exit 1
            }
            if ($syncHash.Result) {
                $lastData = $syncHash.Result
                Update-CpuHistory -Procs $lastData.Procs
                Invoke-AlertCheck -Data $lastData
                if ($LogFile -ne "") {
                    try { Write-HtmlLog -Data $lastData } catch { $script:ModeMsg = "HTML log error: $_" }
                }
                if ($script:CsvFile -ne "") {
                    try { Write-CsvLog -Data $lastData } catch { $script:ModeMsg = "CSV log error: $_" }
                }
                $script:NeedsRender = $true
            }
        }

        $cw = [Console]::WindowWidth; $ch = [Console]::WindowHeight
        if ($cw -ne $script:LastW -or $ch -ne $script:LastH) { $script:NeedsRender = $true }

        if ($lastData -and $script:NeedsRender) {
            try {
                Invoke-Render -Data $lastData -LogicalCpus $logicalCpus
            } catch {
                [Console]::CursorVisible = $true; [Console]::Clear()
                Write-Host "ERROR in Invoke-Render:" -ForegroundColor Red
                Write-Host $_.ToString()             -ForegroundColor Red
                Write-Host $_.ScriptStackTrace       -ForegroundColor DarkRed
                Write-Host "`nPress any key to exit..." -ForegroundColor DarkGray
                $null = [Console]::ReadKey($true); exit 1
            }
            $script:NeedsRender = $false
        }

        Invoke-KeyInput
        Start-Sleep -Milliseconds 80
    }
}
catch {
    if ($_.ToString() -ne "quit") {
        [Console]::CursorVisible = $true; [Console]::Clear()
        Write-Host "FATAL ERROR:"        -ForegroundColor Red
        Write-Host $_.ToString()         -ForegroundColor Red
        Write-Host $_.ScriptStackTrace   -ForegroundColor DarkRed
        Write-Host "`nPress any key to exit..." -ForegroundColor DarkGray
        $null = [Console]::ReadKey($true)
    }
}
finally {
    $syncHash.Stop = $true
    try { $ps.Stop() }      catch {}
    try { $ps.Dispose() }   catch {}
    try { $rs.Close() }     catch {}
    try { $rs.Dispose() }   catch {}
    [Console]::CursorVisible = $true
    [Console]::Clear()
    Write-Host "psys exited." -ForegroundColor Cyan
    if ($script:AlertLog.Count -gt 0) {
        Write-Host "`nAlerts during session:" -ForegroundColor Red
        $script:AlertLog | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkRed }
    }
    if ($LogFile -ne "")           { Write-Host "HTML log : $LogFile"          -ForegroundColor DarkCyan }
    if ($script:CsvFile -ne "")    { Write-Host "CSV log  : $script:CsvFile"  -ForegroundColor DarkCyan }
}