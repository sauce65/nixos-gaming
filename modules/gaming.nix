# Gaming stack: Steam + Proton-GE, Gamescope, GameMode, MangoHud, Heroic,
# Bottles, umu-launcher, Wine, winetricks, DXVK.
{ pkgs, ... }:
{
  programs.steam = {
    enable = true;
    gamescopeSession.enable = true;
    extraCompatPackages = with pkgs; [
      proton-ge-bin
    ];
    remotePlay.openFirewall = true;
    dedicatedServer.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
  };

  programs.gamemode.enable = true;
  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };

  # Steam's CHTTPClientThread does unaligned atomics (long-standing Valve
  # bug). Kernel split-lock detection's ratelimit mode throttles offending
  # threads to ~1/s, wedging Steam updates after ~10s. Wine/Proton games
  # hit the same trap. Detection stays on at the warn level via dmesg.
  boot.kernel.sysctl."kernel.split_lock_mitigate" = 0;

  environment.systemPackages = with pkgs; [
    mangohud
    goverlay
    protonup-qt
    heroic
    umu-launcher
    wineWow64Packages.staging
    winetricks
  ];
}
