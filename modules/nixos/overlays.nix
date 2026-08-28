# nixpkgs overlays — package-level fixes and version bumps, shared by every NixOS
# host in this flake. Each entry documents WHY it exists and what makes it
# droppable; none of them are machine-specific, so they live here rather than in a
# host module. Patch paths are relative to this file (../../patches = repo root).
{ config, lib, pkgs, inputs, ... }:

{
  # Workaround: pipx 1.8.0's test suite fails on this nixpkgs pin — cosmetic
  # package-spec normalization drift (`pkg@url` vs `pkg @ url`) in
  # test_package_specifier.py, not a functional break — which otherwise fails the
  # whole build. `depend` needs the pipx binary (packages.yaml data-tools block), so
  # skip its checkPhase rather than dropping it. Remove once nixpkgs ships a fixed
  # pipx — or migrate that block to `uv tool` (uv is already installed).
  nixpkgs.overlays = [
    (final: prev: {
      pipx = prev.pipx.overridePythonAttrs (old: { doCheck = false; });

      # cantarell-fonts 0.311 — its variable-font build autohints Cantarell-VF.otf
      # with afdko 5.0.1's otfautohint, which regressed and now exits 1 (an empty
      # "ERROR:") on the Cyrillic Ef even though the recipe already --exclude-glyphs
      # uni0424. That fails the WHOLE system build: cantarell is a default fontconfig
      # font (→ X11-fonts → fontconfig-cache → system-path). nixos-unstable's head
      # (b5aa0fb) is itself broken and no earlier rev past the afdko-5.0.1 bump is
      # good, so there's nothing to pin/revert to — and `depend update` re-pulls the
      # broken head every time. make-variable-font.py runs otfautohint IN-PLACE on an
      # already-saved+cleaned VF and the next step (subroutinize) re-reads that same
      # file, so skipping the autohint yields a valid, un-hinted VF — imperceptible on
      # this HiDPI/Wayland setup, and only the VF is touched (static instances build
      # normally). Short-circuit the sole check_call so otfautohint never runs;
      # --replace-fail trips the build loudly if upstream restructures the script.
      # Drop once afdko's otfautohint is fixed upstream (then cantarell builds clean).
      cantarell-fonts = prev.cantarell-fonts.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace scripts/make-variable-font.py \
            --replace-fail "subprocess.check_call(" "0 and subprocess.check_call("
        '';
      });

      # envfs 1.2.0 — nixpkgs still ships 1.1.0, whose single-threaded FUSE daemon
      # DEADLOCKS whenever a caller's PATH contains /bin or /usr/bin: it re-enters its
      # own mount and every exec through /bin·/usr/bin then hangs in D-state
      # (Mic92/envfs#145/#196). That froze the GNOME desktop on every wipe-enabled gen.
      # 1.2.0 fixes it ("Avoid FUSE deadlocks by resolving paths with O_PATH fds").
      # This is exactly nixpkgs PR #500707 (package-only bump) applied as an overlay;
      # it stays on nixpkgs' fetchCargoVendor, which pulls crates from the
      # static.crates.io CDN — NOT the upstream flake's importCargoLock, which 403s on
      # crates.io's legacy /api/v1/download endpoint. Drop this once #500707 lands.
      envfs = prev.envfs.overrideAttrs (old: rec {
        version = "1.2.0";
        src = final.fetchFromGitHub {
          owner = "Mic92";
          repo = "envfs";
          rev = version;
          hash = "sha256-hj/6zS9ebF0IDqgc1Dne59nWx80nk6jn2gj8BzQUFIQ=";
        };
        cargoDeps = final.rustPlatform.fetchCargoVendor {
          inherit src;
          name = "envfs-${version}-vendor";
          hash = "sha256-dz3gpE464jnmSDsAsmJHcxUsEKeUURNoUjgGU2214Xg=";
        };
      });

      # gnome-shell's vendored libgvc — SEGFAULTS when a dock's audio card is
      # enumerated/torn down. PulseAudio leaves pa_card_info::active_profile NULL for a
      # card with no usable profile (pipewire-pulse logs "card N port M profiles
      # inconsistent"), and update_card() dereferences it unconditionally:
      #   segfault at 0 ... in libgvc.so, #0 _pa_context_get_card_info_by_index_cb
      # Same failure mode as the mutter patch below (unguarded NULL on device teardown),
      # different subsystem — this one fires on REdock, the mutter one on undock. Guards
      # both derefs; the second skips the call rather than passing NULL into
      # gvc_mixer_card_set_profile(), which would crash in g_str_equal(). Present in
      # libgnome-volume-control master too, so not a "wait for the next bump" fix.
      gnome-shell = prev.gnome-shell.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../../patches/gnome-shell-gvc-active-profile-null-guard.patch ];
      });

      # mutter 50.2 — SEGFAULTS on every undock of the Thunderbolt dock. On a monitor
      # change mutter clears workspace->logical_monitor_data, then rebuilds it in
      # meta_workspace_ensure_work_areas_validated() by iterating only the monitors that
      # STILL EXIST. A queued move_resize for a window on the just-removed monitor then
      # reaches meta_workspace_get_onmonitor_region(), whose cache lookup returns NULL and
      # is dereferenced unguarded -> SIGSEGV in meta_window_constrain. Its sibling
      # meta_workspace_get_work_area_for_monitor() already has exactly this NULL check;
      # the patch makes the two consistent. Not extension-related: reproduced with
      # dash-to-dock disabled (upstream GNOME/mutter#3402, #1979, #4369 agree). Still
      # unfixed on mutter main as of 2026-08-11 with no MR in flight, so this is not a
      # "wait for the next bump" workaround — drop it only once upstream lands a guard.
      mutter = prev.mutter.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../../patches/mutter-onmonitor-region-null-guard.patch ];
      });

      # wivrn 26.6 — nixpkgs still ships 26.2.3, but the Quest headset's WiVRn
      # client auto-updated to 26.6 and the server/client protocol must match or
      # the streamer refuses the session. This is nixpkgs PR #531078 (a one-file
      # package-only bump, fully reviewed + green CI, queued for merge) applied as
      # an overlay: callPackage the PR's package.nix straight from the maintainer's
      # branch. The new version is API-compatible, so services.wivrn below needs no
      # changes. Drop this once #531078 lands and unstable catches up (gh pr view
      # 531078 -R NixOS/nixpkgs --json state).
      wivrn = prev.callPackage
        (final.fetchurl {
          url = "https://raw.githubusercontent.com/PassiveLemon/nixpkgs/67a2cb0ba141df83a9b5625b54d0a9023ebd05f2/pkgs/by-name/wi/wivrn/package.nix";
          hash = "sha256-95RL8JYD2kzPUgyMzjWOaKT2RU5VAsmEyyDnCX/ESmg=";
        })
        {};
    })
  ];
}
