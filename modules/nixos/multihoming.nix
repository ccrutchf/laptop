# Two interfaces, one subnet: make each address answer on its own path.
#
# Docked, this machine holds 192.168.1.69 on the USB-ethernet dock and
# 192.168.1.138 on Wi-Fi — both in 192.168.1.0/24. Linux has a single preferred
# route per destination, so a reply sourced from EITHER address leaves via the
# lower-metric interface (the dock, metric 100):
#
#     ip route get 192.168.1.125 from 192.168.1.138  ->  dev enp5s0u1u4u4
#
# The result is that only the address belonging to the current egress interface
# is usable, and which one that is flips whenever the dock re-enumerates. It
# looks exactly like a firewall problem and is not one.
#
# Two halves to the fix:
#   * ARP: with the kernel defaults (arp_ignore=0, arp_announce=0) either
#     interface answers ARP for either address, so a peer can cache .138 against
#     the dock's MAC ("ARP flux"). 1/2 restricts both to the owning interface.
#   * Routing: a per-interface table plus a `from <addr>` rule, so a reply
#     sourced from .138 egresses Wi-Fi and one sourced from .69 egresses the
#     dock. The main table is untouched, so outbound traffic still prefers the
#     dock exactly as before.
#
# IPv4 only: the LAN here is v4, and SLAAC addresses don't have this problem in
# the same way (each is already tied to its interface).
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.my.multihoming;

  # Table and rule ids are derived from the interface index so they are stable
  # for as long as the link exists and never collide between interfaces.
  reconcile = pkgs.writeShellScript "multihoming-reconcile" ''
    set -u
    PATH=${makeBinPath [ pkgs.iproute2 pkgs.gawk pkgs.coreutils ]}

    action="''${2:-refresh}"
    case "$action" in
      up|down|dhcp4-change|connectivity-change|refresh) ;;
      *) exit 0 ;;
    esac

    prio_base=${toString cfg.rulePriorityBase}
    table_base=${toString cfg.routingTableBase}

    # Drop every rule we own before rebuilding, so an unplugged dock or a new
    # DHCP address cannot leave a stale `from <addr>` rule behind pointing at a
    # table that no longer describes reality.
    ip -4 rule show |
      awk -v lo="$prio_base" -v hi="$((prio_base + 999))" \
          -F: '{ p = $1 + 0; if (p >= lo && p <= hi) print p }' |
      sort -u |
    while read -r p; do
      ip -4 rule del priority "$p" 2>/dev/null || true
    done

    ip -4 route show default |
      awk '{ g=""; d=""; for (i=1;i<=NF;i++) { if ($i=="via") g=$(i+1); if ($i=="dev") d=$(i+1) }
             if (g!="" && d!="") print g, d }' |
    while read -r gw dev; do
      idx=$(cat "/sys/class/net/$dev/ifindex" 2>/dev/null) || continue
      table=$((table_base + idx))
      prio=$((prio_base + idx))

      addr=$(ip -4 -o addr show dev "$dev" scope global | awk '{ print $4; exit }')
      [ -n "$addr" ] || continue
      # The on-link prefix as the kernel installed it, e.g. 192.168.1.0/24.
      net=$(ip -4 route show dev "$dev" scope link proto kernel | awk '{ print $1; exit }')

      ip route flush table "$table" 2>/dev/null || true
      [ -n "$net" ] && ip route replace "$net" dev "$dev" scope link \
        src "''${addr%/*}" table "$table"
      ip route replace default via "$gw" dev "$dev" table "$table"
      ip -4 rule add from "''${addr%/*}" lookup "$table" priority "$prio"
    done
  '';
in {
  options.my.multihoming = {
    enable = mkEnableOption "per-address routing for interfaces sharing a subnet";

    routingTableBase = mkOption {
      type = types.ints.positive;
      default = 1000;
      description = "Per-interface routing tables are this plus the interface index.";
    };

    rulePriorityBase = mkOption {
      type = types.ints.positive;
      default = 10000;
      description = ''
        Policy rules are created at this priority plus the interface index. The
        1000 priorities from here up are considered owned by this module and are
        deleted wholesale on every reconcile — don't put other rules in them.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Answer ARP only for addresses on the interface the request arrived on, and
    # source ARP announcements from an address belonging to the outgoing
    # interface. The effective value is max(all, <iface>), so `all` is enough;
    # `default` covers interfaces that appear later (the dock re-enumerates).
    boot.kernel.sysctl = {
      "net.ipv4.conf.all.arp_ignore" = 1;
      "net.ipv4.conf.default.arp_ignore" = 1;
      "net.ipv4.conf.all.arp_announce" = 2;
      "net.ipv4.conf.default.arp_announce" = 2;
    };

    networking.networkmanager.dispatcherScripts = [
      { source = reconcile; type = "basic"; }
    ];

    # The dispatcher covers address changes; this covers everything else — a
    # missed event, a link that came up before NetworkManager was ready, or a
    # rule cleared out from under us. Reconciling is idempotent and costs a
    # handful of netlink calls.
    systemd.services.multihoming-reconcile = {
      description = "Reconcile per-address routing for interfaces sharing a subnet";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${reconcile}";
      };
    };

    systemd.timers.multihoming-reconcile = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "2min";
        AccuracySec = "30s";   # let systemd batch this with other wakeups
      };
    };
  };
}
