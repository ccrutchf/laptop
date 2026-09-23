# GNOME Remote Login over RDP — a NEW session spawned by GDM on connect, not a
# mirror of whatever is on the physical screens.
#
# Why remote login and not screen sharing: gnome-remote-desktop hard-caps a
# screen-share session at ONE monitor (MAX_MONITOR_COUNT_SCREEN_SHARE = 1 in
# grd-session-rdp.c), and the default 'mirror-primary' mode records only the
# primary connector — with three displays attached here that means two of them
# are simply invisible to the client. The headless system daemon allows 16
# virtual monitors, built from the layout the client advertises, so a multimon
# client gets a real multi-head desktop. The tradeoff is that it is a fresh
# session: the windows open on the physical screens are NOT in it.
#
# Mechanism: gnome-remote-desktop.service runs as the `gnome-remote-desktop`
# system user and owns the port. On a connection it asks GDM to create a remote
# display (org.gnome.DisplayManager.RemoteDisplayFactory — GDM's own bus policy
# denies that interface to everyone but root and group gdm, but grd ships a
# policy granting its own user access, installed here via the nixpkgs module's
# services.dbus.packages). GDM starts a greeter; the connection is handed to the
# greeter's own grd instance (gnome-remote-desktop-handover.service, a USER
# unit); you authenticate against PAM exactly as at the physical GDM — same
# account password, which is declarative here (users.mutableUsers = false) — and
# the connection is handed over once more to the session's grd.
#
# Both the system unit and the per-session handover unit ship [Install] sections
# that NixOS does not act on — systemd.packages only LINKS units, it does not
# enable them — so the two wantedBy lines below are what actually turns this on.
# Enabling them imperatively would not survive the root wipe either.
#
# NOT reachable from off-machine: nothing here opens the firewall, deliberately.
# Reach it over the home-gated sshd instead —
#     ssh -N -L 3389:localhost:3389 chris@chris-msi
# then point the client at localhost:3389 (with /multimon for multi-head:
# `xfreerdp3 /v:localhost /multimon`, or mstsc /multimon on Windows). To make
# the port first-class later, gate it the way ssh.nix gates 22; do not simply add
# it to networking.firewall.allowedTCPPorts.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.my.remoteDesktop;

  # The system daemon reads a key file, layering /etc over the package default
  # (GRD_CUSTOM_CONF, compiled in as this exact path). Declaring it here means
  # the Settings → System → Remote Desktop toggle can no longer write it — that
  # is the intended direction: the switch is the source of truth, not the GUI.
  # Only four keys are read in system mode (grd-settings-system.c): enabled,
  # tls-cert, tls-key, port.
  certDir = "/var/lib/gnome-remote-desktop";
  tlsCert = "${certDir}/rdp-tls.crt";
  tlsKey  = "${certDir}/rdp-tls.key";
in {
  options.my.remoteDesktop = {
    enable = mkEnableOption "GNOME Remote Login over RDP (headless, via GDM handover)";

    port = mkOption {
      type = types.port;
      default = 3389;
      description = ''
        Port the system daemon binds. Never opened in the firewall — reach it
        through an SSH tunnel over the home-gated sshd (see the module header).
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      { assertion = config.services.displayManager.gdm.enable;
        message = "my.remoteDesktop needs GDM: the handover that turns an RDP "
                  + "connection into a real session is GDM's RemoteDisplayFactory.";
      }
    ];

    # Pulls in the daemon, its dbus + polkit policy, the system user and the
    # tmpfiles entries for ${certDir} and /etc/gnome-remote-desktop.
    # (services.desktopManager.gnome already mkDefaults this true; state it
    # anyway so the feature does not silently depend on that.)
    services.gnome.gnome-remote-desktop.enable = true;

    # asDropinIfExists (the NixOS default) merges these into the units shipped by
    # the package rather than replacing them, so the ExecStart lines survive.
    systemd.services.gnome-remote-desktop.wantedBy = [ "graphical.target" ];
    systemd.user.services.gnome-remote-desktop-handover.wantedBy = [ "gnome-session.target" ];

    environment.etc."gnome-remote-desktop/grd.conf".text = ''
      [RDP]
      enabled=true
      port=${toString cfg.port}
      tls-cert=${tlsCert}
      tls-key=${tlsKey}
    '';

    # grd reads tls-cert/tls-key with g_file_test(IS_REGULAR) and SILENTLY
    # ignores a path that is not there yet, so the cert has to exist before the
    # daemon starts, not merely eventually. Self-signed is the norm for RDP —
    # clients pin the fingerprint — which is also why ${certDir} is persisted
    # (see impermanence.nix): a fresh cert every boot means a fresh scary prompt
    # every boot.
    systemd.services.gnome-remote-desktop-tls = {
      description = "Self-signed TLS certificate for GNOME Remote Desktop";
      wantedBy = [ "gnome-remote-desktop.service" ];
      before   = [ "gnome-remote-desktop.service" ];
      after    = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "gnome-remote-desktop";
        Group = "gnome-remote-desktop";
        UMask = "0077";
      };
      script = ''
        [ -s ${tlsCert} ] && [ -s ${tlsKey} ] && exit 0
        ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
          -subj "/CN=${config.networking.hostName}" \
          -addext "subjectAltName=DNS:${config.networking.hostName}" \
          -keyout ${tlsKey} -out ${tlsCert}
        chmod 0600 ${tlsKey}
        chmod 0644 ${tlsCert}
      '';
    };
  };
}
