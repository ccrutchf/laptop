# The GNOME-on-Wayland desktop, shared by every graphical host: GDM + GNOME,
# geoclue (darkman's sunrise/sunset), CUPS + Avahi, and Bluetooth. Split out of
# the host module so a second laptop gets an identical desktop for one import.
#
# The Brother HL-L2370DW is declared here because it is a network printer on the
# home LAN that any of these machines should be able to reach — move it back into
# a host module if that stops being true.
{ config, lib, pkgs, inputs, ... }:

{
  # X infrastructure: kept for the NVIDIA driver config (videoDrivers below) and
  # XWayland. GNOME runs its Wayland session by default; GDM's own greeter is
  # Wayland too. X stays enabled so a fallback Xorg GNOME session is available and
  # the NVIDIA/xserver options apply.
  services.xserver.enable = true;

  # GNOME (Wayland) + GDM. GNOME provides the shell, Settings, Files (Nautilus),
  # gnome-keyring (Secret Service for Slack/VSCode), power management (low-battery
  # warnings + auto-suspend), lid handling, and accessibility (Large Text +
  # fractional scaling in Settings). Desktop tweaks live in home/linux.nix (dconf,
  # extensions, darkman light/dark).
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Location service for darkman's geoclue-based sunrise/sunset (home.nix). The
  # demo agent (enabled by default) authorizes per-user apps against appConfig
  # below — darkman's desktop ID must be allowlisted or it gets no fix. Mozilla
  # Location Service shut down in 2024, so point the WiFi geolocation backend at
  # beaconDB (its community successor); without it geoclue has no network source.
  # If geoclue ever proves flaky, drop to fixed coords: set lat/lng + usegeoclue
  # = false in services.darkman.settings (home.nix) and disable this.
  services.geoclue2 = {
    enable = true;
    geoProviderUrl = "https://beacondb.net/v1/geolocate";
    appConfig.darkman = {
      isAllowed = true;
      isSystem = false;
      users = [ "1000" ];   # chris (id -u); geoclue keys its allowlist by uid string
    };
  };

  # CUPS for campus/network printers.
  services.printing.enable = true;
  # brlaser is the de-facto driver for the Brother HL-L2370DW. Bundling the PPD
  # here means lpadmin can build the queue WITHOUT the printer being online at
  # switch time (unlike driverless "everywhere", which queries the device).
  services.printing.drivers = [ pkgs.brlaser ];

  # mDNS so the printer stays reachable by name across DHCP lease changes.
  # The HL-L2370DW is on DHCP, so we address it by its stable node name
  # (BRNxxxx.local) instead of an IP. nssmdns4 wires Avahi into NSS so CUPS /
  # getent resolve *.local; openFirewall lets the 5353/udp replies back in.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # Brother HL-L2370DW, declared so it survives the impermanent-root wipe
  # (/etc/cups and /var/lib/cups are NOT in the persist list). Node name found
  # via `avahi-browse -rt _ipp._tcp`; brl2370d.ppd is brlaser's HL-L2370DN PPD,
  # same engine as the DW (DN/DW differ only in ethernet vs wifi).
  hardware.printers.ensureDefaultPrinter = "Brother_HL_L2370DW";
  hardware.printers.ensurePrinters = [{
    name = "Brother_HL_L2370DW";
    location = "home";
    deviceUri = "ipp://BRNB42200021209.local/ipp/print";
    model = "drv:///brlaser.drv/brl2370d.ppd";
  }];

  # Bluetooth (controller present). Pinned explicitly so the flake owns it.
  hardware.bluetooth.enable = true;
}
