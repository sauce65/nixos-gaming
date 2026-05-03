# Bellum (Astarte Industries) — Wine prefix bootstrap.
# Uses umu-run + GE-Proton for prefix init and runtime, but plain Wine for
# the NSIS installer (pressure-vessel breaks the installer GUI/silent mode).
# GE-Proton bundles DXVK, VKD3D-Proton, and DXVK-NVAPI; no manual layering needed.
#
# Usage:
#   bellum-bootstrap ~/Games/bellum ~/Downloads/AstarteLauncher-amd64-installer.exe
#   bellum            # launch (or click "Bellum" in app menu)
{ pkgs, ... }:
let
  prefixDir = "$HOME/Games/bellum";
  launcherExe = "drive_c/users/steamuser/AppData/Local/Astarte Industries/Astarte Launcher/AstarteLauncher.exe";

  bellum-bootstrap = pkgs.writeShellApplication {
    name = "bellum-bootstrap";
    runtimeInputs = with pkgs; [
      umu-launcher
      wineWowPackages.staging
      winetricks
      cabextract
      coreutils
    ];
    text = ''
      set -euo pipefail

      WINEPREFIX="''${1:?Usage: bellum-bootstrap <prefix-path> <installer.exe>}"
      LAUNCHER_EXE="''${2:?Usage: bellum-bootstrap <prefix-path> <installer.exe>}"

      if [[ ! "$WINEPREFIX" = /* ]]; then
        echo "WINEPREFIX must be an absolute path" >&2; exit 1
      fi
      if [[ -e "$WINEPREFIX" ]]; then
        echo "WINEPREFIX already exists at $WINEPREFIX; delete it first to re-bootstrap" >&2; exit 1
      fi
      if [[ ! -f "$LAUNCHER_EXE" ]]; then
        echo "Installer not found: $LAUNCHER_EXE" >&2; exit 1
      fi

      mkdir -p "$WINEPREFIX"
      export WINEPREFIX WINEARCH="win64" GAMEID="bellum"
      export PROTONPATH="''${PROTONPATH:-GE-Proton}"

      echo "==> Initializing prefix"
      umu-run wineboot -u

      echo "==> Installing VC++ 2022 runtime"
      umu-run winetricks --unattended vcrun2022

      echo "==> Configuring fullscreen + WM decoration overrides"
      umu-run winetricks grabfullscreen=y windowmanagerdecorated=n

      echo "==> Removing Mono (interferes with Astarte launcher)"
      umu-run winetricks --unattended remove_mono

      echo "==> Running Astarte launcher installer (silent, via Wine)"
      wine "$LAUNCHER_EXE" /S
      echo "==> Waiting for installer to finish..."
      wineserver --wait

      if [[ -f "$WINEPREFIX/${launcherExe}" ]]; then
        echo ""
        echo "Bootstrap complete. Launch with: bellum"
      else
        echo ""
        echo "WARNING: AstarteLauncher.exe not found at expected path." >&2
        echo "Searching prefix for installed files..." >&2
        find "$WINEPREFIX/drive_c" -iname "*astarte*" -o -iname "*bellum*" 2>/dev/null || true
        exit 1
      fi
    '';
  };

  bellum = pkgs.writeShellApplication {
    name = "bellum";
    runtimeInputs = with pkgs; [ umu-launcher ];
    text = ''
      WINEPREFIX="${prefixDir}"
      LAUNCHER="$WINEPREFIX/${launcherExe}"

      if [[ ! -d "$WINEPREFIX" ]]; then
        echo "Bellum prefix not found at $WINEPREFIX" >&2
        echo "Run bellum-bootstrap first." >&2
        exit 1
      fi
      if [[ ! -f "$LAUNCHER" ]]; then
        echo "Astarte launcher not found at $LAUNCHER" >&2
        echo "Re-run bellum-bootstrap to reinstall." >&2
        exit 1
      fi

      export WINEPREFIX GAMEID="bellum"
      export PROTONPATH="''${PROTONPATH:-GE-Proton}"
      exec umu-run "$LAUNCHER"
    '';
  };

  bellum-desktop = pkgs.makeDesktopItem {
    name = "bellum";
    desktopName = "Bellum";
    comment = "Astarte Industries tactical shooter";
    exec = "bellum";
    icon = "applications-games";
    terminal = false;
    categories = [ "Game" "ActionGame" ];
  };
in
{
  environment.systemPackages = [
    bellum-bootstrap
    bellum
    bellum-desktop
    pkgs.umu-launcher
    pkgs.wineWowPackages.staging
    pkgs.winetricks
    pkgs.cabextract
  ];
}
