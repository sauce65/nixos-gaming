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

  environment.systemPackages = with pkgs; [
    mangohud
    goverlay
    protonup-qt
    heroic
    umu-launcher
    wineWow64Packages.staging
    winetricks
    dxvk
  ];
}
