# PipeWire tuned for low-latency microphone capture. Quantum 256 @ 48kHz
# yields ~5ms buffer latency. NoiseTorch for real-time noise suppression.
{ pkgs, ... }:
{
  services.pipewire.extraConfig.pipewire."92-low-latency" = {
    "context.properties" = {
      "default.clock.rate"          = 48000;
      "default.clock.allowed-rates" = [ 44100 48000 96000 ];
      "default.clock.quantum"       = 256;
      "default.clock.min-quantum"   = 128;
      "default.clock.max-quantum"   = 1024;
    };
  };

  programs.noisetorch.enable = true;

  environment.systemPackages = with pkgs; [
    easyeffects
  ];
}
