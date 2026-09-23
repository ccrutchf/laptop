# sshd for remote access — reachable only while this machine is on the home LAN.
#
# "At home" has to be an identity, and a subnet is not one: 192.168.1.0/24 is the
# most common LAN range there is, so a plain source-CIDR rule would silently open
# port 22 on hotel and coffee-shop networks that hand out the same addresses. The
# identity used here is the DEFAULT GATEWAY'S MAC — the home router answers ARP
# with a specific address, and an impostor network cannot produce it without
# being on the same wire. It covers the dock and the Wi-Fi in one test, unlike
# the AP's BSSID, which says nothing about the wired path (they are separate
# devices here: gateway 24:5a:4c:12:f9:25 vs AP 94:2a:6f:d8:19:82).
#
# Mechanism: a `ssh-home` chain hangs off nixos-fw and is EMPTY by default, so
# the daemon is unreachable. A NetworkManager dispatcher script re-evaluates on
# every connection event and fills the chain in only for the interfaces whose
# default gateway matches. Fails closed — an unknown network, a failed lookup or
# a dispatcher that never fires all leave the chain empty.
#
# This is not the same reachability a VPN gives: it is home-LAN only, by design.
# `my.ssh.vpnInterfaces` is the hook for adding a tunnel later (see the WireGuard
# notes in git history) — it is empty for now.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.my.ssh;

  # Shared by the dispatcher and the firewall's own start, so a `nixos-rebuild
  # switch` (which restarts firewall.service and flushes the chain) re-opens the
  # port immediately instead of waiting for the next NetworkManager event.
  gate = pkgs.writeShellScript "ssh-home-gate" ''
    set -u
    PATH=${makeBinPath [ pkgs.iproute2 pkgs.iptables pkgs.iputils pkgs.gawk pkgs.coreutils ]}

    # NetworkManager passes <interface> <action>; the firewall calls us bare.
    action="''${2:-refresh}"
    case "$action" in
      up|down|dhcp4-change|dhcp6-change|connectivity-change|refresh) ;;
      *) exit 0 ;;
    esac

    iptables -N ssh-home 2>/dev/null || true
    iptables -F ssh-home

    # Every default route, as "<gateway> <device>".
    ip -4 route show default |
      awk '{ g=""; d=""; for (i=1;i<=NF;i++) { if ($i=="via") g=$(i+1); if ($i=="dev") d=$(i+1) }
             if (g!="" && d!="") print g, d }' |
    while read -r gw dev; do
      # A freshly-brought-up link often has no ARP entry yet; nudge it.
      ping -c1 -w2 -I "$dev" "$gw" >/dev/null 2>&1 || true
      mac=$(ip neigh show "$gw" dev "$dev" |
              awk '{ for (i=1;i<=NF;i++) if ($i=="lladdr") print $(i+1) }' | head -1 | tr 'A-Z' 'a-z')
      [ -n "$mac" ] || continue

      for known in ${escapeShellArgs (map toLower cfg.homeGatewayMacs)}; do
        if [ "$mac" = "$known" ]; then
          iptables -A ssh-home -i "$dev" -p tcp --dport ${toString cfg.port} -j nixos-fw-accept
          break
        fi
      done
    done
  '';
in {
  options.my.ssh = {
    enable = mkEnableOption "keys-only sshd, reachable only on the home LAN";

    port = mkOption {
      type = types.port;
      default = 22;
      description = "Port sshd listens on. Never opened globally — see homeGatewayMacs.";
    };

    homeGatewayMacs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "24:5a:4c:12:f9:25" ];
      description = ''
        MAC addresses of trusted default gateways. Port ${"\${port}"} is opened only
        on an interface whose default gateway answers with one of these, so
        moving to any other network closes it again. Case-insensitive. Re-derive
        with `ip neigh show "$(ip -4 route show default | awk '{print $3; exit}')"`
        after replacing the router.
      '';
    };

    vpnInterfaces = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "myswamp" ];
      description = ''
        Interfaces on which the port is opened unconditionally — intended for a
        VPN link, whose interface only exists once the tunnel authenticates.
        Empty by default: home-LAN access only.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.openssh = {
      enable = true;
      ports = [ cfg.port ];

      # The firewall is gated per-network below; letting the module punch a
      # global hole would defeat the entire point.
      openFirewall = false;

      settings = {
        PasswordAuthentication = false;      # users.mutableUsers = false; the hash is in /persist
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";              # root's hashedPassword is "!" and it has no keys
        AllowUsers = [ "chris" ];
        X11Forwarding = false;
      };
    };

    # Host keys: the module's defaults (rsa4096 + ed25519 under /etc/ssh) are
    # exactly the four paths modules/nixos/impermanence.nix already persists, so
    # the host identity survives the root wipe. impermanence links those paths as
    # SYMLINKS into /persist, which matters: sshd-keygen only `rm -f`s a key path
    # that is not a symlink, so generation writes through to /persist instead of
    # failing on the ephemeral root. Don't convert those entries to bind mounts.

    # The Nextcloud-synced user key (~/.ssh/id_ed25519), which is present on every
    # personal machine — the same identity sops derives its age key from.
    users.users.chris.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF2Z7LbaDPTNkdnuvFivXTUx8X9gU0ZyWrrYBH7KSmG3 chris@chris-laptop"
    ];

    networking.firewall.interfaces =
      genAttrs cfg.vpnInterfaces (_: { allowedTCPPorts = [ cfg.port ]; });

    # nixos-fw is flushed and rebuilt on every firewall start, so the jump has to
    # be re-added here; `|| true` because a failure in extraCommands aborts the
    # whole firewall start, and a closed SSH port must never cost us the firewall.
    networking.firewall.extraCommands = ''
      iptables -N ssh-home 2>/dev/null || true
      iptables -F ssh-home
      iptables -A nixos-fw -j ssh-home
      ${gate} || true
    '';

    networking.firewall.extraStopCommands = ''
      iptables -D nixos-fw -j ssh-home 2>/dev/null || true
      iptables -F ssh-home 2>/dev/null || true
      iptables -X ssh-home 2>/dev/null || true
    '';

    networking.networkmanager.dispatcherScripts = [
      { source = gate; type = "basic"; }
    ];

    # The dispatcher only fires on NetworkManager events, so a chain flushed at
    # an unlucky moment (a link bouncing mid-switch, say) would stay wrong until
    # the next one. Re-run the same gate on a timer so the rules self-heal; it
    # is idempotent, and it fails closed if the network is not home.
    systemd.services.ssh-home-gate = {
      description = "Reconcile the home-LAN SSH firewall rules";
      after = [ "firewall.service" "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${gate}";
      };
    };

    systemd.timers.ssh-home-gate = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "2min";
        AccuracySec = "30s";   # let systemd batch this with other wakeups
      };
    };
  };
}
