# Vintage Story dedicated server — generic, host-agnostic NixOS module.
#
# Deliberately carries NO version and NO machine specifics: bring your own
# package via `services.vintagestory-server.package` (point it at the same build
# your players run — client/server parity is required to connect), and layer any
# host-specific unit wiring (e.g. a storage-mount dependency) or firewall policy
# in your own config. `systemd.services.vintagestory-server` merges across
# modules, so adding `after`/`requires` for a data-dir mount from the consuming
# machine composes cleanly with the unit defined here.
#
# Mods are declarative: list pinned zips in `mods` and a baked-in ExecStartPre
# reconciles <dataPath>/Mods on every (re)start.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.vintagestory-server;

  # Baked-in sync: (re)link the declared, pinned mods into <dataPath>/Mods with
  # clean filenames, and remove any previously-managed mods (our store symlinks)
  # that are no longer declared. Manually dropped real files are left untouched,
  # so declarative and hand-placed mods coexist. Wired as ExecStartPre, so the
  # set is reconciled on every (re)start — including the restart a deploy triggers.
  syncMods = pkgs.writeShellApplication {
    name = "vintagestory-sync-mods";
    text = ''
      mods_dir="${cfg.dataPath}/Mods"
      mkdir -p "$mods_dir"
      # Drop previously-managed mods (symlinks into the store); keep real files.
      find "$mods_dir" -maxdepth 1 -type l -lname '/nix/store/*' -delete
      # (Re)link the declared, pinned mods under clean, hash-free filenames.
      managed=( ${lib.escapeShellArgs cfg.mods} )
      for m in "''${managed[@]}"; do
        name="$(basename "$m")"
        ln -sfn "$m" "$mods_dir/''${name#*-}"
      done
    '';
  };
in
{
  options.services.vintagestory-server = {
    enable = lib.mkEnableOption "Vintage Story dedicated server";

    package = lib.mkPackageOption pkgs "vintagestory" { };

    mods = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression ''
        [ (pkgs.fetchVintagestoryMod {
            name = "ProspectTogether-2.2.1.zip";
            url = "https://moddbcdn.vintagestory.at/ProspectTogether-2.2_....zip";
            hash = "sha256-...";
          })
        ]
      '';
      description = ''
        Mods to install into {file}`<dataPath>/Mods`, each a pinned `.zip`
        release (or an unpacked-mod directory) as a store path — typically from
        {option}`pkgs.fetchVintagestoryMod`. A baked-in ExecStartPre links them
        in on every service (re)start: mods added or removed here are reconciled,
        while files placed in {file}`Mods/` by hand are left untouched. Pin each
        mod to a release built for {option}`package`'s game version.
      '';
    };

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
        ExecStartPre = lib.getExe syncMods;
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
