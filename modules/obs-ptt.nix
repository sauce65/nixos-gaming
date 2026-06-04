# OBS push-to-talk daemon. Reads /dev/input/event* directly so PTT works
# regardless of which window has focus — Wayland forbids OBS itself from
# grabbing global keys, so its built-in PTT silently fails the moment a
# game owns focus. The daemon sits below the compositor at the evdev
# layer, sees true keydown/keyup, and drives OBS's Mic/Aux mute state via
# obs-websocket v5. Auth password is read at runtime from OBS's own
# config.json — no nix-side secret to manage.
#
# Mic stays unmuted while *any* configured key is held; muted when all
# are released. Default keyset matches Bellum's V/B/N (local/squad/platoon).
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.obsPtt;

  obs-ptt-daemon = pkgs.writeShellApplication {
    name = "obs-ptt-daemon";
    runtimeInputs = [
      (pkgs.python3.withPackages (ps: with ps; [ evdev websockets ]))
    ];
    text = ''
      exec python3 ${./obs-ptt.py} "$@"
    '';
  };
in
{
  options.programs.obsPtt = {
    enable = lib.mkEnableOption "OBS push-to-talk evdev daemon";

    user = lib.mkOption {
      type = lib.types.str;
      description = "User whose OBS the daemon controls. Added to the input group.";
    };

    keys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "KEY_V" "KEY_B" "KEY_N" ];
      description = ''
        evdev key names (from linux/input-event-codes.h). Mic is unmuted
        while any of these is held. Default matches Bellum's
        local/squad/platoon PTT keys.
      '';
    };

    inputName = lib.mkOption {
      type = lib.types.str;
      default = "Mic/Aux";
      description = "OBS input name to mute/unmute.";
    };

    wsUrl = lib.mkOption {
      type = lib.types.str;
      default = "ws://127.0.0.1:4455";
      description = "obs-websocket URL.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user}.extraGroups = [ "input" ];

    environment.systemPackages = [ obs-ptt-daemon ];

    systemd.user.services.obs-ptt = {
      description = "OBS push-to-talk evdev daemon";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${obs-ptt-daemon}/bin/obs-ptt-daemon";
        Restart = "always";
        RestartSec = "2s";
      };
      environment = {
        OBS_PTT_KEYS = lib.concatStringsSep "," cfg.keys;
        OBS_PTT_INPUT = cfg.inputName;
        OBS_PTT_WS_URL = cfg.wsUrl;
      };
    };
  };
}
