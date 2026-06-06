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
  # bug). Kernel bus-lock detection traps every offending op; even with
  # split_lock_mitigate=0 the #DB trap cost itself wedges the thread.
  # Wine/Proton games hit the same trap. Full off-switch is at the cmdline.
  boot.kernelParams = [ "split_lock_detect=off" ];

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
