# Merge request

**Target:** `GNOME/mutter` → `main`
**Source:** `<your-username>/mutter` → `wip/workspace-onmonitor-region-null-guard`

## MR title

```
workspace: Guard against missing logical monitor data in get_onmonitor_region()
```

## Commit message

```
workspace: Guard against missing logical monitor data

meta_workspace_get_onmonitor_region() dereferences the result of
meta_workspace_get_logical_monitor_data() without checking it for NULL.

On a monitor change, meta_workspace_clear_logical_monitor_data() destroys
the per-workspace cache, and meta_workspace_ensure_work_areas_validated()
rebuilds it by iterating meta_monitor_manager_get_logical_monitors() --
that is, only the monitors that still exist. A window still referencing a
just-removed monitor therefore has no entry, the lookup returns NULL, and
the dereference crashes.

This is reachable in practice: undocking a Thunderbolt dock driving two
external displays segfaults gnome-shell every time, from a queued
move_resize reaching meta_window_constrain():

  #0  meta_workspace_get_onmonitor_region
  #1  meta_window_constrain
  #2  meta_window_move_resize_internal
  #4  move_resize

The sibling meta_workspace_get_work_area_for_monitor() performs the same
lookup and already guards it with g_return_if_fail(). Do the same here so
the two are consistent.

Callers tolerate a NULL region: meta_rectangle_could_fit_in_region()
returns FALSE for an empty list, so
do_screen_and_monitor_relative_constraints() exits early and the
constraint is skipped for that pass, rather than taking down the session.

Closes: https://gitlab.gnome.org/GNOME/mutter/-/issues/NNNN
```

## MR description

> `meta_workspace_get_onmonitor_region()` dereferences the per-monitor cache entry without
> a NULL check. After a monitor is removed the cache is rebuilt only for monitors that
> still exist, so a window that still references the removed monitor hits a NULL entry and
> mutter segfaults.
>
> The sibling `meta_workspace_get_work_area_for_monitor()` already has exactly this guard;
> this makes the two consistent.
>
> Reproduced 100% of the time by undocking a Thunderbolt 4 dock driving two external
> displays, on mutter 50.2 / Wayland. Six coredumps, identical backtrace each time. Also
> reproduced with Dash to Dock disabled, so this is not specific to that extension.
> Verified the code is unchanged on `50.2`, `gnome-50` and `main`.
>
> Full analysis, backtrace and environment details in #NNNN.
>
> I have been running this patched locally.

## The patch

```diff
--- a/src/core/workspace.c
+++ b/src/core/workspace.c
@@ -1230,6 +1230,12 @@
 
   data = meta_workspace_get_logical_monitor_data (workspace, logical_monitor);
 
+  /* The per-monitor cache is rebuilt only for monitors that still exist, so a
+   * window still referencing a just-removed monitor (e.g. on undock) gets no
+   * entry here. Guard like meta_workspace_get_work_area_for_monitor() does
+   * instead of dereferencing NULL. */
+  g_return_val_if_fail (data != NULL, NULL);
+
   return data->logical_monitor_region;
 }
```

Verified with `patch -p1 --dry-run` to apply cleanly to both the `50.2` tag and `main`.

## How to submit

GNOME does not take pull requests on GitHub; everything goes through gitlab.gnome.org.

```sh
# 1. Fork GNOME/mutter in the gitlab.gnome.org web UI, then:
git clone https://gitlab.gnome.org/<your-username>/mutter.git
cd mutter
git remote add upstream https://gitlab.gnome.org/GNOME/mutter.git
git fetch upstream
git checkout -b wip/workspace-onmonitor-region-null-guard upstream/main

# 2. Apply the patch
patch -p1 < ../mutter-onmonitor-region-null-guard.patch

# 3. Commit using the message above
git commit -a               # paste the commit message

# 4. Push and open the MR against GNOME/mutter:main
git push -u origin wip/workspace-onmonitor-region-null-guard
```

Notes on GNOME conventions, so this does not get bounced on style:

- Commit subject is `<subsystem>: <Imperative sentence>`, no trailing period.
- Body wrapped at 72 columns.
- `wip/...` is the usual branch-naming convention.
- Two-space indent, GNU-ish brace style — the patch already matches surrounding code.
- `Closes:` with the full issue URL as the last line, once the issue exists.

## Before submitting — replace these placeholders

- `NNNN` → the issue number, in both the commit message and the MR description.
- `<your-username>` → your gitlab.gnome.org username.

The related-issue numbers in `01-issue.md` (#1979, #2901, #3093, #4136, #4369, #4765)
are resolved and were open as of 2026-08-11; #3402 is closed.
