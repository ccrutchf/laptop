# gnome-shell segfaults in `meta_workspace_get_onmonitor_region()` on undock — NULL per-monitor cache entry for a just-removed monitor

## Summary

`meta_workspace_get_onmonitor_region()` dereferences the result of
`meta_workspace_get_logical_monitor_data()` without a NULL check. When a monitor is
removed (undocking a Thunderbolt dock driving external displays), a window may still
reference the removed `MetaLogicalMonitor`. The per-workspace cache is rebuilt only for
monitors that still exist, so the lookup returns NULL and mutter segfaults.

This reproduces **100% of the time** on my hardware — every single undock, without
exception. I have six coredumps with an identical backtrace.

The sibling function `meta_workspace_get_work_area_for_monitor()` performs the *same*
lookup and *does* guard it with `g_return_if_fail (data != NULL)`. The crash is simply
that one of the two call sites is missing the check.

## Affected versions

Verified byte-identical (no NULL check) in all three:

- `50.2` (the tag I am running)
- `gnome-50` branch
- `main`

So this is still present in current development, and I could find no open merge request
touching `meta_workspace_get_onmonitor_region` or `meta_workspace_get_logical_monitor_data`.

## Steps to reproduce

1. Boot a Wayland GNOME session on a laptop with a Thunderbolt dock driving two external
   displays (three logical monitors total, including the built-in panel).
2. Have ordinary application windows open on the external displays.
3. Physically disconnect the dock.
4. gnome-shell segfaults ~4 seconds later; the session is destroyed and you are returned
   to GDM, losing all open applications.

## Backtrace

```
Stack trace of thread 3389:
#0  meta_workspace_get_onmonitor_region      (libmutter-18.so.0 + 0x15cdcf)
#1  meta_window_constrain                    (libmutter-18.so.0 + 0x1290c8)
#2  meta_window_move_resize_internal         (libmutter-18.so.0 + 0x153aff)
#3  g_list_foreach                           (libglib-2.0.so.0 + 0x60a60)
#4  move_resize                              (libmutter-18.so.0 + 0x12ad7d)
#5  window_queue_run_later_func              (libmutter-18.so.0 + 0x12aba2)
#6  invoke_later_idle                        (libmutter-18.so.0 + 0x119023)
#7  g_idle_dispatch                          (libglib-2.0.so.0 + 0x60ba9)
#8  g_main_context_dispatch_unlocked         (libglib-2.0.so.0 + 0x62c0b)
#9  g_main_context_iterate_unlocked.isra.0   (libglib-2.0.so.0 + 0x661d8)
#10 g_main_loop_run                          (libglib-2.0.so.0 + 0x66cf7)
#11 meta_context_run_main_loop               (libmutter-18.so.0 + 0x13794a)
```

Frame #1 being `meta_window_constrain` is consistent with the `place_window_if_needed()`
call site, which is `static` and inlined into `meta_window_constrain()`.

## Warnings immediately preceding the crash

```
thunderbolt 0-3: device disconnected
boltd: [Thunderbolt 4 Docking Station] disconnected
gnome-shell: meta_monitor_manager_get_logical_monitor_from_number: assertion
             '(unsigned int) number < g_list_length (manager->logical_monitors)' failed
gnome-shell: meta_workspace_get_work_area_for_monitor: assertion
             'logical_monitor != NULL' failed
gnome-shell: <SIGSEGV>
```

Note the second warning: `meta_workspace_get_work_area_for_monitor()` is called with a
now-invalid monitor index and *survives* precisely because it has the NULL guard. Moments
later the unguarded sibling is reached and crashes. The two warnings are the same
underlying condition — stale monitor references outliving the monitor — surfacing once
safely and once fatally.

## Analysis

Line numbers below are against `main`.

1. On a monitor change, `meta_workspace_clear_logical_monitor_data()` (workspace.c:811)
   destroys the per-workspace hash table via
   `g_clear_pointer (&workspace->logical_monitor_data, g_hash_table_destroy)`.

2. `meta_workspace_ensure_work_areas_validated()` repopulates it by iterating
   `meta_monitor_manager_get_logical_monitors (monitor_manager)` (workspace.c:903) — i.e.
   **only monitors that currently exist**. Nothing is inserted for a removed monitor.

3. A queued `move_resize` for a window still associated with the removed monitor runs,
   reaching `meta_window_constrain()` and then `meta_workspace_get_onmonitor_region()`.

4. `meta_workspace_get_logical_monitor_data()` (workspace.c:95) returns NULL — explicitly
   so when the table is absent, and via `g_hash_table_lookup()` returning NULL for a key
   that was never reinserted.

5. `meta_workspace_get_onmonitor_region()` (workspace.c:1224) does:

```c
  data = meta_workspace_get_logical_monitor_data (workspace, logical_monitor);

  return data->logical_monitor_region;   /* <-- NULL dereference */
```

Compare `meta_workspace_get_work_area_for_monitor()` (workspace.c:1175), which does the
identical lookup and guards it:

```c
  data = meta_workspace_get_logical_monitor_data (workspace, logical_monitor);

  g_return_if_fail (data != NULL);

  *area = data->logical_monitor_work_area;
```

## Proposed fix

Add the matching guard, making the two functions consistent. A merge request is attached.

Callers tolerate a NULL region: `info->usable_monitor_region` is consumed by
`meta_rectangle_contained_in_region()`, which iterates with `while (!contained && temp != NULL)`,
and by `do_screen_and_monitor_relative_constraints()`, where
`meta_rectangle_could_fit_in_region()` returns FALSE for an empty list and sets
`exit_early = TRUE`. The constraint is therefore skipped for that one pass, and the window
is constrained correctly on the next pass once the monitors-changed handler has rebuilt the
cache. Skipping a single constraint pass is plainly preferable to destroying the session.

I have been running the patched build locally.

## On extension involvement

Crashes of this shape are frequently attributed to extensions, so I tested this
specifically. GNOME's own `org.gnome.Shell-disable-extensions.service` fired on two of my
crashes and disabled all my extensions, which is what led me to investigate.

I reproduced the crash with **Dash to Dock disabled** (Desktop Icons NG, AppIndicator and
User Themes were still enabled, so this is not a no-extensions run). The backtrace was
identical. Combined with #2901, reported as `[no extensions]`, I do not believe an
extension is required to trigger this. In any case the NULL dereference is reachable
whenever a window outlives its monitor, and mutter should not segfault regardless of what
JavaScript is loaded.

## Environment

| | |
|---|---|
| mutter / gnome-shell | 50.2 |
| Session | Wayland (GDM) |
| Distro | NixOS unstable (nixpkgs 26.11) |
| Kernel | 7.1.7 |
| Laptop | MSI Creator 15 A11UE, Intel i7-11800H |
| GPUs | NVIDIA RTX 3060 (open kernel module 595.84) + Intel iGPU, PRIME render offload |
| Dock | Thunderbolt 4 Docking Station (8-in-1) |
| Displays | 2 external DisplayPort + built-in eDP-1 |

Crash timestamps (all identical backtrace): 2026-08-05 17:48, 2026-08-08 13:30,
2026-08-08 13:30 (again, 35s later), 2026-08-11 22:01, 2026-08-11 22:37, 2026-08-11 22:39.

## Possibly related

- #2901 — "gnome-shell crashes (segfault) after disconnecting docking station and closing lid [no extensions]" (2023-07, open)
- #3093 — same assertion via a non-dock trigger, after locking the screen and putting monitors to sleep (2023-10, open)
- #4136 — "GNOME Shell crashes when disconnecting from USB-C docking station" (2025-05, open)
- #4765 — "GNOME Shell crashes when disconnecting from USB-C monitor" (2026-04, open)
- #3402 — same assertion, closed 2024-04 without a fix
- #1979 — "Unplugging a USB-C Dock crashes gnome-shell on wayland"
- #4369 — Thunderbolt dock, mutter 49

If maintainers prefer, I am happy to fold this into whichever of the above is considered
canonical rather than keeping a new report — I opened one because none of those pinpoint
the faulting line, and I have a 100% reproducer plus coredumps.
