# NVIDIA proprietary driver stack for Turing+ (RTX 20/30/40/50).
# Open kernel modules required on RTX 50-series. Wayland session
# variables and VA-API bridge for hardware video decode.
{ config, pkgs, ... }:
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
    # Pinned to new_feature (590.48.01) instead of production (595.58.03).
    # 595 has a confirmed shader-compilation bug on Blackwell (RTX 50-series)
    # that hangs UE5 games via VKD3D-Proton during PSO compile (e.g., Bellum
    # gets stuck on loading screens). 590 is the highest known-good driver
    # for Blackwell at time of writing. See:
    # https://github.com/joepaji/bellum-linux-installer/releases/tag/v2.0.0
    package = config.boot.kernelPackages.nvidiaPackages.new_feature;
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
