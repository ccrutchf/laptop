# macOS (nix-darwin) home-manager config for chris-macbook. The cross-platform
# shell stack, git, and core CLIs come from ./common.nix; this file is the
# Mac-specific layer.
#
# The non-Nix package layer (Homebrew formulae/casks, Mac App Store) is NOT
# managed by nix-darwin's homebrew module — `depend` owns it via packages.yaml,
# so one manifest drives both machines. Homebrew itself is a prerequisite: install
# it once after the OS reinstall (depend shells out to `brew`/`mas`, never builds them).
{ config, lib, pkgs, inputs, ... }:

let
  depend = inputs.dependency-manager.packages.${pkgs.stdenv.hostPlatform.system}.default;
  synology = inputs.synology-filestation.packages.${pkgs.stdenv.hostPlatform.system};

  # The macOS .app bundle the flake does not build.
  #
  # synologyfuse-gui installs a bare executable on darwin: the desktop entry and
  # icon in that flake are both gated to Linux, because upstream expects its own
  # .pkg to lay down /Applications/SynologyFuse.app. Installed from Nix there is no
  # bundle at all, so nothing reaches Spotlight, Launchpad or the Dock and the only
  # way to start it is to type its name. This is the macOS counterpart of the
  # xdg.desktopEntries block in ./linux.nix, for the same reason.
  #
  # The layout mirrors SynologyFuse.MacInstaller/Build-Installer.sh: the whole
  # publish tree in Contents/MacOS with the FFI dylib and the CLI beside the
  # apphost. That placement is load-bearing — the GUI's native resolver looks for
  # the dylib next to its own executable, which is why nothing here needs the
  # wrapper's SYNOFS_NATIVE_DIR. Info.plist and the icon come from the flake source
  # rather than being retyped, so upstream keeps owning the app's identity.
  #
  # Store symlinks are deliberate: home-manager's copyApps rsyncs with
  # --copy-unsafe-links, so every link pointing out of the tree is materialised and
  # what lands in ~/Applications is a real, Spotlight-indexable bundle.
  #
  # Icon conversion uses png2icns, not the iconutil/sips pair Build-Installer.sh
  # calls — those ship with the Xcode command line tools and do not exist in a Nix
  # build.
  synologyfuse-app =
    pkgs.runCommand "synologyfuse-app-${synology.synologyfuse-gui.version}"
      {
        nativeBuildInputs = [ pkgs.imagemagick pkgs.libicns ];
        meta.platforms = lib.platforms.darwin;
      }
      ''
        contents="$out/Applications/SynologyFuse.app/Contents"
        mkdir -p "$contents/MacOS" "$contents/Resources"

        # buildDotnetModule publishes to $out/lib/<pname>; fail loudly rather than
        # silently assembling an empty bundle if that ever stops being true.
        publish=(${synology.synologyfuse-gui}/lib/*/)
        if [ ''${#publish[@]} -ne 1 ]; then
          echo "expected one publish dir, got: ''${publish[*]}" >&2
          exit 1
        fi
        # The apphost and the managed assembly must be REAL files in the bundle;
        # everything else can stay a symlink. The .NET host canonicalises both paths
        # before it settles AppContext.BaseDirectory, so if either is a symlink into
        # the store the app root lands back in the publish tree — which has no
        # libsynology_filestation_ffi.dylib next to it, since that is ours to place.
        # The GUI then dies at startup with DllNotFoundException, because its
        # resolver's second candidate is AppContext.BaseDirectory (the first, the
        # SYNOFS_NATIVE_DIR override, belongs to the flake's own bin/ wrapper and is
        # not set when macOS launches the bundle). Verified by bisecting which files
        # have to be real: these two, and no others.
        for f in "''${publish[0]}"*; do
          case "$(basename "$f")" in
            SynologyFuse.Gui | SynologyFuse.Gui.dll)
              install -m755 "$f" "$contents/MacOS/" ;;
            *)
              ln -s "$f" "$contents/MacOS/" ;;
          esac
        done

        ln -s ${synology.synology-filestation-ffi}/lib/libsynology_filestation_ffi.dylib \
          "$contents/MacOS/"
        ln -s ${synology.synology-filestation-fuse}/bin/synology-filestation-fuse \
          "$contents/MacOS/"

        for sz in 16 32 128 256 512 1024; do
          magick ${inputs.synology-filestation}/SynologyFuse.Gui/Assets/app.png \
            -resize "''${sz}x''${sz}" "icon_''${sz}.png"
        done
        png2icns "$contents/Resources/AppIcon.icns" icon_*.png

        substitute ${inputs.synology-filestation}/SynologyFuse.MacInstaller/Info.plist \
          "$contents/Info.plist" \
          --replace-fail __VERSION__ "${synology.synologyfuse-gui.version}" \
          --replace-fail __GUI_BINARY__ SynologyFuse.Gui
      '';
in
{
  imports = [ ./common.nix ];

  home.homeDirectory = "/Users/chris";

  # `depend update` reads this to run the nix-darwin system update on macOS —
  # `nix flake update` + `sudo darwin-rebuild switch --flake <ref>` — mirroring the
  # nixos-rebuild step (DEPEND_NIXOS_FLAKE) on the Linux host.
  home.sessionVariables.DEPEND_DARWIN_FLAKE = "${config.home.homeDirectory}/Repos/personal/laptop#chris-macbook";

  # Mac-specific Nix packages. Start minimal — GUI apps + the iOS/dev toolchain
  # come from Homebrew via packages.yaml (the `platform: osx` block). Add genuinely
  # cross-platform CLIs to home-common.nix instead, so both machines share them.
  #
  # The exception to "GUI apps come from Homebrew": E4E's Synology FileStation
  # mounter, from the same flake input the NixOS host installs (see
  # hosts/chris-laptop/default.nix). It is open-source and already packaged for
  # darwin, and there is no cask to install instead. macOS needs none of the FUSE
  # wiring the Linux host does — the CLI serves WebDAV on loopback and hands it to
  # Apple's own mount_webdav, so no kernel extension and no programs.fuse. The GUI
  # loads the Rust core through the FFI cdylib; the CLI is listed separately only so
  # it lands on the interactive PATH too (the GUI's own wrapper already has it).
  # Mount points must live under /Volumes.
  home.packages = [
    synology.synologyfuse-gui
    synology.synology-filestation-fuse
    synologyfuse-app
  ];

  # Reconcile the non-Nix layer on every `darwin-rebuild switch`. Unlike the Linux
  # host this CONVERGES (--prune): brew/cask/mas packages not in packages.yaml's
  # osx block are removed, so the machine matches the manifest (nix-darwin `zap`
  # equivalent). brew/mas live in /opt/homebrew/bin; pipx (the data-tools provider)
  # comes from Nix. Add both to PATH explicitly in case the activation runs with a
  # minimal environment.
  home.activation.dependencyManagerInstall =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="/opt/homebrew/bin:${lib.makeBinPath [ pkgs.git pkgs.pipx ]}:$PATH"
      $DRY_RUN_CMD ${depend}/bin/depend install --prune --config ${../packages.yaml}
    '';
}
