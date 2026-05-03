# PipeWire tuned for low-latency microphone capture. Quantum 256 @ 48kHz
# yields ~5ms buffer latency. RNNoise filter-chain for noise suppression.
#
# After rebuild, select "Noise Canceling source" as your mic input in-game.
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

  # Noise suppression: use EasyEffects (user-launched) rather than PipeWire's
  # filter-chain. PipeWire 1.6.3 in current nixpkgs has a broken
  # libspa-filter-graph-plugin-ladspa.so (undefined symbol spa_log_topic_enum)
  # which prevents filter-chain from loading any LADSPA plugin and crashes
  # the whole PipeWire daemon. EasyEffects loads plugins in user-space and
  # bypasses that bug.
  environment.systemPackages = with pkgs; [
    easyeffects
  ];
}
