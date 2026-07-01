# NVIDIA proprietary driver stack for Turing+ (RTX 20/30/40/50).
# Open kernel modules required on RTX 50-series. Wayland session
# variables and VA-API bridge for hardware video decode.
{ config, lib, pkgs, ... }:
{
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [
      nvidia-vaapi-driver
      libva
      libvdpau-va-gl
    ];
  };

  hardware.nvidia = {
    modesetting.enable = true;
    open = true;
    nvidiaSettings = true;
    powerManagement.enable = true;
    # Tracks nvidiaPackages.new_feature -- a MOVING alias that follows nixpkgs,
    # not a frozen version. Was 590.48.01 when first set (chosen over production
    # 595.58.03, whose Blackwell/RTX-50 shader-compile bug hangs UE5 games via
    # VKD3D-Proton during PSO compile, e.g. Bellum stuck on loading screens).
    # The nixos-unstable 26.11 bump slid the alias to 610.43.02 (2026-06-24),
    # validated good for Bellum. Caveat: as an alias it can swap the driver
    # silently on any nixpkgs bump -- check `cat /proc/driver/nvidia/version`
    # after big rebuilds; to freeze a version, use nvidiaPackages.mkDriver.
    # 595 bug ref: https://github.com/joepaji/bellum-linux-installer/releases/tag/v2.0.0
    package = lib.mkDefault config.boot.kernelPackages.nvidiaPackages.new_feature;
  };

  boot.kernelParams = [
    "nvidia-drm.modeset=1"
    "nvidia-drm.fbdev=1"
  ];

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME         = "nvidia";
    NVD_BACKEND               = "direct";
    GBM_BACKEND               = "nvidia-drm";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    WLR_NO_HARDWARE_CURSORS   = "1";
  };
}
