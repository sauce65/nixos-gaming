# BFME: All-In-One Launcher (The Bfme Foundation) — Wine prefix bootstrap.
# Sibling of the bellum module: umu-run + GE-Proton for prefix init and
# runtime — GE-Proton bundles DXVK, which routes the old D3D8/9 games (BFME1,
# BFME2, Rise of the Witch-king) through Vulkan instead of the wined3d GL path
# that limps on the Blackwell driver — but plain Wine for the NSIS installer
# (pressure-vessel breaks it).
#
# Two BFME-specific wrinkles vs bellum:
#   * The AllInOneLauncher is an Electron app. `--no-sandbox` avoids the
#     Chromium seccomp/SIGSYS trap under pressure-vessel (bellum's WebView2
#     needed the same class of fix). The launcher spawns the games in its own
#     prefix, so they inherit Proton/DXVK from the one `umu-run`.
#   * SAGE-engine exclusive fullscreen is INVISIBLE under KDE Wayland/XWayland
#     (renders + plays audio, but the compositor never shows the surface). The
#     launcher passes `-win` when WindowedMode* is set, so the bootstrap forces
#     those on in settings.json.
#
# Usage:
#   bfme-bootstrap ~/Games/bfme ~/Downloads/AllInOneLauncherSetup.exe
#   bfme            # launch (or click "BFME" in the app menu)
{ pkgs, ... }:
let
  prefixDir = "$HOME/Games/bfme";
  launcherSub = "drive_c/users/steamuser/AppData/Roaming/BFME All In One Launcher";
  launcherExe = "${launcherSub}/AllInOneLauncher.exe";
  settingsJson = "${launcherSub}/settings.json";

  bfme-bootstrap = pkgs.writeShellApplication {
    name = "bfme-bootstrap";
    runtimeInputs = with pkgs; [
      umu-launcher
      wineWow64Packages.staging
      winetricks
      cabextract
      coreutils
      jq
    ];
    text = ''
      set -euo pipefail

      WINEPREFIX="''${1:?Usage: bfme-bootstrap <prefix-path> <installer.exe>}"
      INSTALLER="''${2:?Usage: bfme-bootstrap <prefix-path> <installer.exe>}"

      if [[ ! "$WINEPREFIX" = /* ]]; then
        echo "WINEPREFIX must be an absolute path" >&2; exit 1
      fi
      if [[ -e "$WINEPREFIX" ]]; then
        echo "WINEPREFIX already exists at $WINEPREFIX; delete it first to re-bootstrap" >&2; exit 1
      fi
      if [[ ! -f "$INSTALLER" ]]; then
        echo "Installer not found: $INSTALLER" >&2; exit 1
      fi

      mkdir -p "$WINEPREFIX"
      export WINEPREFIX WINEARCH="win64" GAMEID="bfme"
      export PROTONPATH="''${PROTONPATH:-GE-Proton}"

      # Proton first: creates the steamuser profile and the $USER -> steamuser
      # symlink, so the plain-Wine installer below (which runs as $USER) lands
      # its files under steamuser where `bfme` expects them.
      echo "==> Initializing prefix"
      umu-run wineboot -u

      echo "==> Installing VC++ 2022 runtime"
      umu-run winetricks --unattended vcrun2022

      echo "==> Configuring windowed-friendly WM overrides"
      umu-run winetricks grabfullscreen=y windowmanagerdecorated=n

      echo "==> Removing Mono (Electron launcher misbehaves with it)"
      umu-run winetricks --unattended remove_mono

      # NSIS/electron-builder installer, run under plain Wine (pressure-vessel
      # breaks it). It AUTO-LAUNCHES the Electron app after /S, so we must NOT
      # `wineserver --wait` (that blocks forever on the running launcher).
      # Poll for the installed exe, then stop the prefix.
      echo "==> Running AllInOneLauncher installer (silent, via Wine)"
      wine "$INSTALLER" /S &

      echo "==> Waiting for launcher to install..."
      for _ in $(seq 1 150); do
        [[ -f "$WINEPREFIX/${launcherExe}" ]] && break
        sleep 2
      done

      if [[ ! -f "$WINEPREFIX/${launcherExe}" ]]; then
        echo "AllInOneLauncher.exe not found after install." >&2
        find "$WINEPREFIX/drive_c" -iname 'AllInOneLauncher.exe' 2>/dev/null || true
        wineserver -k || true
        exit 1
      fi

      # Let the auto-launched instance settle (it self-updates on first run),
      # then stop the prefix so we can patch settings and hand off to `bfme`.
      echo "==> Launcher installed; letting it settle, then stopping prefix"
      sleep 10
      wineserver -k || true
      sleep 2

      # Force windowed mode for all three games (exclusive fullscreen is
      # invisible under KDE Wayland/XWayland). Merge over settings.json if the
      # launcher already wrote one, else seed it; the launcher preserves these
      # keys across its own rewrites.
      echo "==> Forcing windowed mode in settings.json"
      base='{}'
      [[ -f "$WINEPREFIX/${settingsJson}" ]] && base="$(cat "$WINEPREFIX/${settingsJson}")"
      printf '%s' "$base" \
        | jq '.WindowedModeBfme1 = true | .WindowedModeBfme2 = true | .WindowedModeRotwk = true' \
        > "$WINEPREFIX/${settingsJson}"

      echo ""
      echo "Bootstrap complete. Launch with: bfme"
    '';
  };

  bfme = pkgs.writeShellApplication {
    name = "bfme";
    runtimeInputs = with pkgs; [ umu-launcher ];
    text = ''
      WINEPREFIX="${prefixDir}"
      LAUNCHER="$WINEPREFIX/${launcherExe}"

      if [[ ! -d "$WINEPREFIX" ]]; then
        echo "BFME prefix not found at $WINEPREFIX" >&2
        echo "Run bfme-bootstrap first." >&2
        exit 1
      fi
      if [[ ! -f "$LAUNCHER" ]]; then
        echo "AllInOneLauncher not found at $LAUNCHER" >&2
        echo "Re-run bfme-bootstrap to reinstall." >&2
        exit 1
      fi

      export WINEPREFIX GAMEID="bfme"
      export PROTONPATH="''${PROTONPATH:-GE-Proton}"

      # --no-sandbox: the launcher is Electron; Chromium's seccomp sandbox
      # SIGSYS-traps wine under pressure-vessel. GE-Proton routes the games'
      # D3D8/9 through DXVK; they launch windowed (settings.json) because
      # exclusive fullscreen is invisible under KDE Wayland/XWayland.
      exec gamerun bfme "$@" -- umu-run "$LAUNCHER" --no-sandbox
    '';
  };

  bfme-desktop = pkgs.makeDesktopItem {
    name = "bfme";
    desktopName = "BFME (All-In-One Launcher)";
    comment = "The Lord of the Rings: The Battle for Middle-earth";
    exec = "bfme";
    icon = "applications-games";
    terminal = false;
    categories = [ "Game" "StrategyGame" ];
  };
in
{
  # Self-contained: bfme logs through the gamelogs harness (declares
  # gamelogs.games.bfme below and execs `gamerun`), so it brings gamelogs with
  # it rather than depending on the consumer's import order. Importing
  # gamelogs.nix from both this and bellum.nix is fine — the module system
  # dedupes by path.
  imports = [ ./gamelogs.nix ];

  # Deliberately NOT re-listing umu-launcher/wine/winetricks/cabextract in
  # systemPackages: the bfme/bfme-bootstrap scripts carry them via
  # runtimeInputs, so the module is self-contained without duplicating the
  # heavy runtime already pulled in by the gaming profile / bellum.
  environment.systemPackages = [
    bfme-bootstrap
    bfme
    bfme-desktop
  ];

  gamelogs.games.bfme = {
    wrapperOf = "umu-run";
    engine = "native"; # SAGE engine (2004-2006), D3D8/9. Not ue5/unity/source.
    antiCheat = false; # community online (no EAC/BattlEye); MangoHud/vkcapture OK.
    # SAGE writes no continuous log; on a crash it drops DUMP_*.dmp files
    # directly in the game dir (e.g. drive_c/BFME2). gamerun's crashBundleDirs
    # copies crash *subdirs*, which don't match these flat .dmp files, so we
    # skip it — captured stdout/stderr + exit-code classification suffice.
    extraEnv = {
      # Fall back from fsync to esync. Under fsync, SAGE deadlocks on the
      # splash before the main menu — game.dat parks 30+ threads in
      # futex_wait_multiple (the fsync primitive) waiting on a futex that
      # never fires, at 0% CPU. Off fsync it runs at ~90% CPU and loads the
      # shell-map menu normally. Same class of fsync hang the bellum module
      # documents; esync implements the same Windows primitives without the
      # race. (System Wine dodged it by using a different sync backend.)
      PROTON_NO_FSYNC = "1";
      # Silence Wine logging for normal play. The gamelogs default
      # WINEDEBUG=+module,+pid,+tid,+timestamp is a synchronous-stderr firehose
      # (~105k lines in a 2-min SAGE startup — the engine loads thousands of
      # tiny assets) that stutters these old games to a crawl on the splash.
      # `gamerun bfme --debug` still re-enables the heavy channels for triage.
      WINEDEBUG = "-all";
    };
  };
}
