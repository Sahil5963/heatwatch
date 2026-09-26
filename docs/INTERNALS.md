# HeatWatch internals

## Sampling policy

Nothing is measured while the panel is closed. Opening it shows the last
snapshot instantly (kept in memory), takes a baseline, and shows fresh figures
0.8 s later; then it refreshes every 5 s (adjustable 1–10 s with the Refresh
slider, stored in `refreshInterval`) until it closes. `⌘R` / ↻ refreshes now.
CPU and GPU figures are exponentially smoothed (newest sample weighted 45%) so
a one-second spike does not reshuffle the list. The only background activity is the OS thermal-state notification (push,
not polling), which swaps the flame icon: a template image for nominal/fair,
orange for serious, red for critical. Measured: closed, 0.01 s of CPU over
15 s; open, ≈3% of one core.

## Where the numbers come from

| Metric | Source |
|---|---|
| Per-process CPU / memory (your processes) | `proc_pid_rusage` deltas, physical footprint — same basis as Activity Monitor |
| Per-process CPU / memory (other users' processes) | one `/bin/ps` call per refresh (`ps` is setuid; libproc refuses these without root) |
| Whole-machine CPU | `host_processor_info` deltas |
| GPU (device) | IORegistry `IOAccelerator` → `PerformanceStatistics` (`Device Utilization %`, `In use system memory`), `gpu-core-count` on the GPU device node |
| GPU (per process) | each `AGXDeviceUserClient` under the accelerator is tagged `IOUserClientCreator = "pid N, name"` and carries `AppUsage[].accumulatedGPUTime` (ns); GPU % = Δtime / Δwall. Sums to ≈ device utilisation |
| Memory | `host_statistics64` (app + wired + compressed) and `kern.memorystatus_level` |
| Die temperature | IOKit HID temperature sensors (`PMU tdie*` on Apple silicon) — private API, no root needed |
| Thermal state | `ProcessInfo.thermalState` |

Dead ends, so nobody re-walks them: `task_info(TASK_POWER_INFO_V2).gpu_energy.
task_gpu_utilisation` stays 0 on Apple silicon even under continuous Metal
work, and `task_inspect_for_pid` / `task_read_for_pid` are refused for every
other process. `kernel_task` CPU is not readable without root (only `top`
sees it).

The menu-bar icon never uses `contentTintColor` — NSStatusBarButton renders a
tinted template symbol as solid black. Images are swapped instead.

## Grouping

Every process is rolled up under the root of its process tree (the direct
child of `launchd`). Chrome and its helpers, a terminal and everything it
spawned, an automation daemon and the browser it launched — each is one row.
Group kills signal the helpers first and the root last.

## Issues

Every snapshot is classified after grouping (`Diagnostics.swift`); nothing
extra runs in the background and no permission is asked. Per tree, most
severe first:

| Issue | Signal | Severity |
|---|---|---|
| not responding | WindowServer's own verdict (`CGSEventIsAppUnresponsive`, private SkyLight API, resolved with `dlsym`; absent → never flagged). WindowServer only judges an app with events waiting, so a hung app is flagged ≈15 s after someone clicks or hovers it. | hot |
| burning | lifetime CPU (`ri_user_time + ri_system_time`, or `ps time` for other users' processes) ÷ age ≥ 0.5 cores, age ≥ 10 min | hot from 1 core and 1 h |
| pegged | tree ≥ 90 % CPU (smoothed) for ≥ 30 s while the panel is open | hot from 5 min |
| automation | a known tool by path (agent-browser, Playwright, Puppeteer, chromedriver/geckodriver/…, Selenium, Lighthouse), or a real browser binary launched with `--remote-debugging-*`, `--headless`, `--enable-automation` or a temp-dir `--user-data-dir`. Generic flags are ignored on Electron/node binaries and on helpers whose parent is in the same `.app` (an app driving its own embedded renderer is not automation). Arguments come from `KERN_PROCARGS2`, own processes only. | info, warn ≥ 1 h, hot ≥ 1 day |
| orphaned / idle | own direct child of launchd that `launchctl list` does not know (its terminal, agent or script exited), not a system binary, not inside a bundle, ≥ 2 min old. "idle" when it has averaged < 1 % and is quiet now. | warn |

`launchctl list` is spawned only when an unjudged launchd child old enough to
judge appears. Multi-kill: ticked rows are tree roots in Apps mode or pids in
Processes mode; switching the toggle clears them; the confirmation card lists
what is included. `HEATWATCH_DUMP_ISSUES=1` prints the flagged trees of the
first full sample and quits — the quickest way to check the classifier
against a real machine.

`ps %cpu` on macOS is the kernel's decaying average, not a lifetime figure;
the lifetime average here is computed from cumulative CPU time.

## Screenshots

```sh
Tools/capture.sh                # shots/{cpu,memory,gpu,issues,selected,expanded,confirm}.png
SHADOW=0 ICON=0 Tools/capture.sh gpu
```

`HEATWATCH_CAPTURE=<scenario>` launches the app with the panel open, pinned
(it ignores outside clicks) and showing that scene; `Tools/shoot.swift` grabs
the panel as a *window* capture — nothing else on screen is included — and
composes it on a transparent canvas with a soft shadow and the menu-bar flame
above the arrow. Retina resolution (2×). `ICON_BLACK=1` for light backgrounds.

## Building and releasing

```sh
./build.sh --run       # build/HeatWatch.app, then launch
./build.sh --install   # copy to ~/Applications
./build.sh --dist      # dist/HeatWatch-<version>.dmg + .zip
```

If Xcode's licence has not been accepted (`swift --version` says so), the
script builds with the Command Line Tools and borrows Xcode's SwiftUI macro
plugin, which the CLT do not ship. The binary is universal (Apple silicon + Intel), signed ad-hoc unless
`CODESIGN_IDENTITY="Developer ID Application: …"` is set, in which case the
hardened runtime is enabled and `./notarize.sh` can notarize and staple the
DMG (one-time `notarytool store-credentials` setup is described in the
script). Not sandboxed — it has to signal other processes. The app icon is
generated by `Tools/make-icon.swift` (our own flame path; SF Symbols are not
licensed for app icons).

What users see: no privacy permissions are requested — no Accessibility,
Screen Recording, Full Disk Access or notifications. It can only quit/kill
processes that belong to the logged-in user. A notarized build opens straight
away; a merely signed one needs System Settings → Privacy & Security → "Open
Anyway" once. "Launch at Login" registers a login item (macOS shows its
standard "Background Items Added" notice).
