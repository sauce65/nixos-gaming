# Vintage Story dedicated server — generic, host-agnostic NixOS module.
#
# Deliberately carries NO version and NO machine specifics: bring your own
# package via `services.vintagestory-server.package` (point it at the same build
# your players run — client/server parity is required to connect), and layer any
# host-specific unit wiring (e.g. a storage-mount dependency) or firewall policy
# in your own config. `systemd.services.vintagestory-server` merges across
# modules, so adding `after`/`requires` for a data-dir mount from the consuming
# machine composes cleanly with the unit defined here.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.vintagestory-server;
in
{
  options.services.vintagestory-server = {
    enable = lib.mkEnableOption "Vintage Story dedicated server";

    package = lib.mkPackageOption pkgs "vintagestory" { };

    dataPath = lib.mkOption {
      type = lib.types.path;
      default = "/srv/vintagestory";
      description = ''
        Server data directory — world saves, serverconfig.json, `Mods/`,
        `ModData/`. Passed to the server as `--dataPath` and used as the service
        user's home + working directory. Provision it (or its mount) yourself;
        the module does not create or chown it.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "vintagestory";
      description = "User the server runs as (created as a system user).";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "vintagestory";
      description = "Primary group for the server user (created).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open {option}`port` (TCP+UDP) on all interfaces. Left off by default: an
        open server has no whitelist, so a source-scoped rule is usually
        preferable. The real listen port lives in serverconfig.json — keep
        {option}`port` in sync if you enable this.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 42420;
      description = ''
        Port opened when {option}`openFirewall` is set. Informational only — it
        does not configure the server (set the port in serverconfig.json).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataPath;
      description = "Vintage Story dedicated server";
    };
    users.groups.${cfg.group} = { };

    systemd.services.vintagestory-server = {
      description = "Vintage Story dedicated server";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe' cfg.package "vintagestory-server"} --dataPath ${cfg.dataPath}";
        Restart = "on-failure";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataPath;
      };
    };

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
      allowedUDPPorts = [ cfg.port ];
    };
  };
}
