# OBS Studio with Wayland-first capture plugins and v4l2loopback virtual camera.
{ config, pkgs, ... }:
{
  programs.obs-studio = {
    enable = true;
    enableVirtualCamera = true;
    # On NixOS, /run/opengl-driver/lib is not on the default LD_LIBRARY_PATH,
    # so OBS's obs-nvenc-test helper can't dlopen libnvidia-encode.so.1 and
    # NVENC is silently disabled (encoder list shows only x264/SVT-AV1/AOM-AV1).
    # Wrap both binaries to inject the driver lib path. Harmless on non-NVIDIA
    # systems: the directory just won't contain libnvidia-encode and NVENC
    # stays off as it would anyway.
    package = pkgs.obs-studio.overrideAttrs (old: {
      postFixup = (old.postFixup or "") + ''
        for bin in obs obs-nvenc-test; do
          if [ -x "$out/bin/$bin" ]; then
            wrapProgram "$out/bin/$bin" \
              --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib
          fi
        done
      '';
    });
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
