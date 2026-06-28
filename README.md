# psys.ps1 — Terminal System Monitor for Windows

A keyboard-driven, `htop`-style system and network monitor for Windows, written entirely in PowerShell. Runs inside any terminal — including remote sessions and Windows Server Core where Task Manager is not available.


## Features

- **Four live views** switchable instantly with `Tab` or `1`–`4`
  - **Processes** — CPU%, memory, disk read/write, CPU history sparkline, thread count, process age
  - **Network** — per-process network I/O, TCP connections, UDP endpoints
  - **Connections** — full TCP connection list with local/remote address, port and state
  - **Adapters** — all network adapters with status, link speed and total bytes transferred
- **Shared system header** always visible — uptime, overall CPU bar, per-core bars, memory bar
- **Colour-coded** — green / yellow / red thresholds on all bars and process rows
- **Selection cursor** — `↑`/`↓` moves a `▶` highlight through the list; `Enter` opens process detail
- **Process detail popup** — full path, command line, TCP connections, loaded modules, thread list
- **CPU history sparkline** — mini bar chart (▁▂▄█▆▃) of the last 10 readings per process
- **New process detection** — processes that appeared since the last refresh highlighted in green
- **Background data collection** — UI responds to keypresses instantly regardless of refresh cycle
- **Regex filter** — press `f` and type; supports full regular expressions or wildcard mode (`r` to toggle)
- **Alert thresholds** — configurable CPU% and memory% thresholds with header badge and log entries
- **Kill by PID** — press `k`, type a PID, confirm; or kill directly from the detail popup
- **Adjustable refresh rate** — `+` / `-` keys, 1–60 seconds
- **Pause / resume** — `Space`
- **HTML session log** — static, dark-themed, collapsible snapshots, searchable, opens in any browser
- **CSV export** — one row per process per refresh cycle, `Alert` column for Excel filtering
- **Persistent defaults** — edit the `param()` block at the top of the script once; settings survive every run
- **No external modules** — pure PowerShell, single file, nothing to install
- **Locale-independent** — works on all Windows language installs including non-English

---

## Requirements

| Requirement | Version |
|---|---|
| PowerShell | 7.0 or later |
| Windows | 10 / 11 / Server 2019 / Server 2022 |
| Permissions | Standard user for most features; Administrator recommended for full disk I/O data |

> PowerShell 7 can be installed from the [Microsoft Store](https://aka.ms/PSWindows) or [GitHub releases](https://github.com/PowerShell/PowerShell/releases).

---

## Installation

No installation required. Download the script and run it.

**Option 1 — Clone the repository**
```powershell
git clone https://github.com/az104tor/psys.git
cd psys
.\psys.ps1
```

**Option 2 — Download the script directly**
```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/az104tor/psys/main/psys.ps1" -OutFile psys.ps1
.\psys.ps1
```

**Option 3 — Manual download**

Download `psys.ps1` from this repository and run it from any PowerShell 7 terminal.

> **Execution policy:** if you get a script execution error, run:
```powershell
 Unblock-File -Path .\psys.ps1
 Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## Usage

```powershell
# Basic — uses defaults from param() block at top of script
.\psys.ps1

# Custom refresh interval
.\psys.ps1 -RefreshInterval 2

# With HTML session log
.\psys.ps1 -LogFile "$env:USERPROFILE\Desktop\psys.html"

# With both HTML log and CSV export
.\psys.ps1 -LogFile "C:\logs\psys.html" -CsvFile "C:\logs\psys.csv"

# Custom alert thresholds and snapshot history
.\psys.ps1 -AlertCPU 70 -AlertMem 85 -LogMaxSnapshots 500
```

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-RefreshInterval` | `int` | `5` | Seconds between data refreshes (1–60) |
| `-LogFile` | `string` | _(none)_ | Path to HTML log. Created/updated on each refresh. |
| `-CsvFile` | `string` | _(none)_ | Path to CSV export. One row per process per refresh. |
| `-LogMaxSnapshots` | `int` | `200` | Maximum snapshots kept in the HTML log (rolling window) |
| `-AlertCPU` | `int` | `80` | CPU% threshold — highlights process and writes alert log entry |
| `-AlertMem` | `int` | `90` | Memory% threshold — highlights bar and writes alert log entry |

### Persisting Your Defaults

To make your preferred settings permanent without retyping them every time, edit the default values directly in the `param()` block at the very top of `psys.ps1`:

```powershell
param(
    [int]$RefreshInterval = 3,                        # changed from 5
    [int]$AlertCPU        = 70,                       # changed from 80
    [string]$LogFile      = "C:\logs\psys.html",      # always log
    [string]$CsvFile      = "C:\logs\psys.csv"        # always export CSV
)
```

Command-line parameters always override these values for that session.

---

## Keyboard Controls

### All Views

| Key | Action |
|---|---|
| `Tab` or `1` `2` `3` `4` | Switch view |
| `h` | Toggle help screen (shows all keybindings) |
| `f` | Filter by process name — visible yellow input box at bottom |
| `r` | Toggle filter mode: **regex** (default) / **wildcard** |
| `+` / `-` | Increase / decrease refresh interval |
| `Space` | Pause / resume data collection |
| `q` | Quit |
| `Esc` | Close detail / help popup, or quit |

### Views 1 & 2 — Processes and Network

| Key | Action |
|---|---|
| `↑` / `↓` | Move `▶` selection cursor up / down |
| `PgUp` / `PgDn` | Scroll list by one full page |
| `Enter` | Open process detail popup for selected row |
| `k` | Kill a process by PID |

### View 1 — Processes (sort keys)

| Key | Action |
|---|---|
| `c` | Sort by CPU% |
| `m` | Sort by Memory |
| `d` | Sort by Disk I/O |
| `p` | Sort by PID |
| `n` | Sort by Name |

### View 2 — Network (sort keys)

| Key | Action |
|---|---|
| `o` | Sort by Net I/O |
| `t` | Sort by TCP connections |
| `p` | Sort by PID |
| `n` | Sort by Name |

---

## Process Detail Popup

Press `Enter` on any highlighted row (views 1 and 2) to open a full-screen detail panel:

```
──────────────────────────────────────────────────────────────────
  PROCESS DETAIL — msedge  (PID 5352)   Esc to close
──────────────────────────────────────────────────────────────────
  Path        : C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe
  CommandLine : "msedge.exe" --type=renderer ...
  Started     : 2026-06-20 23:52:15
  Priority    : Normal

  CPU Time    : 12.4 s    Handles : 892    Threads : 29
  Memory WS   : 267.5 MB  Peak WS : 312.1 MB

  TCP CONNECTIONS (4)
  LOCAL                     REMOTE                    STATE
  192.168.1.5:52341         52.114.128.9:443          Established
  ...

  TOP MODULES (by memory)       THREADS (first 15)
  msedge.dll     48.2 MB        TID    STATE     WAIT REASON
  ...                           ...
──────────────────────────────────────────────────────────────────
  Press Esc to return   k=kill this process
```

Press `k` from inside the detail panel to kill that process directly.

---

## Filter

Press `f` to open the filter input. The bottom bar shows a clearly visible yellow input box:

```
──────────────────────────────────────────────────────────────────
  FILTER [regex]  ›  edge▌·····················   Enter=apply  Esc=cancel  r=toggle
```

Press `r` to toggle between two modes:

| Mode | Example | Matches |
|---|---|---|
| **Regex** (default) | `^ms` | Processes starting with "ms" |
| **Regex** | `edge\|chrome` | msedge OR chrome |
| **Regex** | `(?i)EDGE` | Case-insensitive match |
| **Wildcard** | `edge` | Anything containing "edge" |

If you type an invalid regex it silently falls back to wildcard rather than crashing.

---

## HTML Log

When `-LogFile` is specified, psys writes a dark-themed HTML report on every refresh cycle.

- **Static file** — no auto-refresh. Press `F5` in the browser to load new snapshots.
- **Collapsible snapshots** — each refresh cycle is a collapsible section with system bars and the full process table
- **Alert section** — timestamped CPU and memory alerts collected at the top of the page
- **Live search** — filter rows across all snapshots by process name using the search box
- **Self-contained** — no external dependencies, works offline, can be shared or archived

---

## CSV Export

When `-CsvFile` is specified, psys appends one row per process per refresh cycle:

```
Timestamp,PID,Name,CPU_Pct,Mem_Bytes,Mem_MB,DiskRead_Bps,DiskWrite_Bps,NetOther_Bps,TCP_Connections,UDP_Endpoints,Threads,Age,Alert
2026-06-20 23:55:18,5352,"msedge",20.0,280608768,267.5,639300,620800,0,4,0,29,0m03s,0
```

The `Alert` column is `1` when a process exceeded the CPU threshold at that snapshot. Filter in Excel with `=FILTER(A:N, N:N=1)` to see only alert moments.

---

## How It Works

### CPU Measurement

CPU% uses two snapshots of `Process.CPU` (total accumulated CPU-seconds) separated by a 1-second interval. The delta is divided by elapsed time and logical CPU count — the same method used by `top` on Linux:

```
CPU% = (snap2.CPU - snap1.CPU) / (elapsed × logicalCpus) × 100
```

### Disk I/O

Disk read/write rates come from `Win32_PerfFormattedData_PerfProc_Process`, which provides pre-computed bytes/sec per process. Two queries are made 1 second apart to establish Windows' internal rate baseline.

### Network I/O

Network activity is approximated via `IOOtherBytesPersec` from `Win32_PerfFormattedData_PerfProc_Process`. This counter covers all non-disk I/O including network sockets, pipes and IPC — the best available per-process network proxy without ETW kernel tracing. TCP connection details come from `Get-NetTCPConnection`.

### Per-Core CPU

Per-core load is read from `Win32_PerfFormattedData_PerfOS_Processor` — a locale-independent WMI class that works on all Windows language installs. An earlier approach using `Get-Counter` with English-language counter path strings failed silently on non-English Windows.

### Background Thread

Data collection runs in a dedicated PowerShell runspace using `[System.Management.Automation.PowerShell]::Create()`. A thread-safe synchronized hashtable communicates between threads. The main thread runs an 80ms polling loop — view switching, cursor movement, and filter input all respond instantly regardless of where the collection cycle is.

### No-Flicker Rendering

Instead of `[Console]::Clear()` (which causes a visible blank flash), all output is built in memory as a list of `{Text, Color}` segments per line, then written to the screen line by line using `[Console]::SetCursorPosition`. Each line is padded to terminal width to erase leftover characters from the previous frame.

---

## psys.ps1 vs Windows Task Manager

| Feature | psys.ps1 | Task Manager |
|---|---|---|
| Works in terminal / SSH / Server Core | ✅ | ❌ |
| Works without a GUI | ✅ | ❌ |
| Keyboard driven | ✅ | Partial |
| Scriptable / automatable | ✅ | ❌ |
| Selection cursor + process detail | ✅ | Partial (via right-click) |
| HTML session log | ✅ | ❌ |
| CSV export for Excel | ✅ | ❌ |
| Configurable alert thresholds | ✅ | ❌ |
| Regex / wildcard filter | ✅ | ❌ |
| Per-process CPU sparkline | ✅ | ❌ |
| New process detection | ✅ | ❌ |
| Per-core CPU bars | ✅ | ✅ |
| Kill process | ✅ | ✅ |
| TCP connection detail | ✅ | ❌ |
| Network adapter stats | ✅ | Partial |
| Performance history graphs | ❌ | ✅ |
| Startup impact scoring | ❌ | ✅ |
| Suspend process | ❌ | ✅ |
| App history (cumulative) | ❌ | ✅ |
| Open file location | ❌ | ✅ |

---

## Troubleshooting

**Script exits immediately with no output**
Ensure you are using PowerShell 7 (`$PSVersionTable.PSVersion`). Check for errors in the startup output before the screen clears.

**Disk I/O columns show `–` for all processes**
Some processes (system and protected processes) do not expose I/O counters to standard users. Run PowerShell as Administrator for full coverage.

**Per-core bars show 0%**
WMI may be degraded on your system. Run `Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor` to verify it returns data.

**Filter not matching what I expect**
The default filter mode is **regex**. Press `r` to switch to wildcard if you want simple substring matching. An invalid regex silently falls back to wildcard.

**Process detail shows "Access denied" for path or modules**
Some system and protected processes restrict access to their module list and executable path. Run as Administrator for full access.

**View switching is slow**
Ensure you are running the latest version. Earlier versions blocked the main thread during data collection; the current version uses a background runspace for instant UI response.

**Execution policy error**
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## Contributing

Contributions, bug reports and feature requests are welcome.

**Planned features**
- [ ] Alert sound or Windows toast notification on threshold breach
- [ ] Process grouping — collapse multiple `svchost` instances into one aggregated row
- [ ] Sort direction toggle — press sort key twice to reverse order
- [ ] Remote machine monitoring via `-ComputerName` parameter

Please open an issue before submitting a large pull request so we can discuss the approach.

---

## License

MIT License — see [LICENSE](LICENSE) for details.

Copyright (c) 2026 \<Your Name\>

---

## Acknowledgements

- Built with assistance from **[Claude](https://claude.ai)** (Anthropic) through an iterative debugging process on real Windows 11 machines
- CPU measurement methodology inspired by the [`htop`](https://github.com/htop-dev/htop) project
- Windows internals reference: [Microsoft WMI documentation](https://learn.microsoft.com/en-us/windows/win32/wmisdk/wmi-start-page) and Raymond Chen's [The Old New Thing](https://devblogs.microsoft.com/oldnewthing/)
