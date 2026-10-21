# Mute Slack's sounds while GNOME's Do Not Disturb is on.
#
# Why: Slack's banners go through org.freedesktop.Notifications, which gnome-shell
# suppresses in DND, but Slack plays the "knock" itself as an ordinary PulseAudio
# stream — GNOME never sees it, so DND can't silence it, and Slack has no setting
# that follows the desktop. This user service watches the DND key
# (org.gnome.desktop.notifications show-banners) and the Pulse event stream, and
# keeps every Slack playback stream muted while DND is on.
#
# Chromium opens a fresh stream per sound and closes it when idle, so muting the
# live streams on the DND toggle isn't enough: each NEW Slack stream is re-checked
# as it appears (before it has played more than a few ms). WirePlumber remembers
# the mute under `application.name:Slack`, so later streams start muted anyway and
# the daemon also UNmutes new streams once DND is off.
#
# Huddles are exempt: while Slack holds the mic (a source-output) its streams stay
# audible even in DND, since you joined that call on purpose.
#
# Streams are resolved by application.name on every event, never by a cached
# node id (ids are renumbered when the Pulse server restarts). Stopping the
# service unmutes Slack (ExecStopPost) so it never leaves Slack silenced.
{ pkgs, ... }:
let
  pactl = "${pkgs.pulseaudio}/bin/pactl";
  jq = "${pkgs.jq}/bin/jq";
  gsettings = "${pkgs.glib}/bin/gsettings";

  slackStreams = ''
    ${pactl} -f json list sink-inputs \
      | ${jq} -r '.[] | select(.properties["application.name"] == "Slack") | .index'
  '';

  unmute = pkgs.writeShellScript "slack-dnd-unmute" ''
    for id in $(${slackStreams}); do ${pactl} set-sink-input-mute "$id" 0; done
  '';

  daemon = pkgs.writeShellScript "slack-dnd" ''
    set -u
    sync() {
      mute=0
      if [ "$(${gsettings} get org.gnome.desktop.notifications show-banners)" = false ] \
         && ! ${pactl} -f json list source-outputs \
              | ${jq} -e 'any(.[]; .properties["application.name"] == "Slack")' >/dev/null
      then mute=1; fi
      for id in $(${slackStreams}); do ${pactl} set-sink-input-mute "$id" "$mute"; done
    }

    sync
    # Both watchers feed one loop; if either exits (e.g. the Pulse server
    # restarted) the service fails and systemd restarts it with fresh state.
    {
      ${gsettings} monitor org.gnome.desktop.notifications show-banners &
      ${pactl} subscribe &
      wait -n
    } | while read -r line; do
      case "$line" in
        show-banners:*|"Event 'new' on sink-input"*|*"on source-output"*) sync ;;
      esac
    done
  '';
in
{
  systemd.user.services.slack-dnd = {
    Unit = {
      Description = "Mute Slack's sounds while GNOME Do Not Disturb is on";
      After = [ "graphical-session.target" "pipewire-pulse.service" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${daemon}";
      ExecStopPost = "${unmute}";
      Restart = "always";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
