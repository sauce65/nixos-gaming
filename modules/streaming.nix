# OBS Studio with Wayland-first capture plugins and v4l2loopback virtual camera.
{ config, pkgs, ... }:
{
  programs.obs-studio = {
    enable = true;
    enableVirtualCamera = true;
    plugins = with pkgs.obs-studio-plugins; [
      obs-pipewire-audio-capture
      obs-vkcapture
      obs-vaapi
      obs-backgroundremoval
      obs-gstreamer
      input-overlay
    ];
  };

  boot.extraModulePackages = with config.boot.kernelPackages; [ v4l2loopback ];
  boot.kernelModules = [ "v4l2loopback" ];
  boot.extraModprobeConfig = ''
    options v4l2loopback devices=1 video_nr=1 \
      card_label="OBS Virtual Camera" exclusive_caps=1
  '';
}
