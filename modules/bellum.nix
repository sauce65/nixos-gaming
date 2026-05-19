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
      wineWow64Packages.staging
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

  # Sidekick that XDefineCursors an arrow onto the Astarte launcher window so
  # the mouse stays visible over it. See bellum-cursor-fix.py for why.
  bellum-cursor-fix = pkgs.writeShellApplication {
    name = "bellum-cursor-fix";
    runtimeInputs = [ (pkgs.python3.withPackages (ps: [ ps.xlib ])) ];
    text = ''
      exec python3 ${./bellum-cursor-fix.py} "$@"
    '';
  };

  bellum = pkgs.writeShellApplication {
    name = "bellum";
    runtimeInputs = with pkgs; [ umu-launcher bellum-cursor-fix ];
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

      # Sidekick self-exits a few seconds after the launcher window goes away.
      bellum-cursor-fix astarte &

      # gamerun supplies WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS,
      # VKD3D_CONFIG=breadcrumbs, and all the logging knobs via the
      # gamelogs.games.bellum profile declared below.
      exec gamerun bellum "$@" -- umu-run "$LAUNCHER"
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
    pkgs.wineWow64Packages.staging
    pkgs.winetricks
    pkgs.cabextract
  ];

  # gamelogs harness — declarative log-capture profile. The bellum wrapper
  # `exec gamerun bellum -- umu-run "$LAUNCHER"`s through this; gamerun
  # mirrors the internal log files into the run dir and sets the env knobs.
  gamelogs.games.bellum = {
    wrapperOf = "umu-run";
    engine = "ue5";
    internalPaths = [
      # UE5 game log + auto-rotated backups.
      "$WINEPREFIX/drive_c/users/steamuser/AppData/Local/Project_Bellum/Saved/Logs/Project_Bellum.log"
      # Astarte launcher logs.
      "$WINEPREFIX/drive_c/users/steamuser/AppData/Roaming/Astarte Industries/Astarte Launcher/logs/out.log"
      "$WINEPREFIX/drive_c/users/steamuser/AppData/Roaming/Astarte Industries/Astarte Launcher/logs/error.log"
      # Bootstrap winetricks log (one-shot, but cheap to mirror).
      "$WINEPREFIX/winetricks.log"
    ];
    extraEnv = {
      # WebView2 SIGSYS workaround. The --service-sandbox-type=service flag
      # Chromium 147+ adds to utility subprocesses (e.g. storage.mojom.StorageService)
      # overrides --disable-seccomp-filter-sandbox alone, re-installing the BPF
      # filter that traps wine64-preloader's arch_prctl(ARCH_SET_FS) at _start+38.
      # --no-sandbox disables all sandbox layers globally; we keep the seccomp
      # flag alongside as defense-in-depth.
      WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--no-sandbox --disable-seccomp-filter-sandbox";
      # Breadcrumbs are already in gamelogs.defaultEnv but explicit here is fine;
      # if a future override removes them globally, Bellum still keeps them.
      VKD3D_CONFIG = "breadcrumbs";
    };
  };
}
