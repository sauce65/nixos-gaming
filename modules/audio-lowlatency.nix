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

  # RNNoise noise suppression via PipeWire filter-chain.
  # Creates a virtual "Noise Canceling source" input device.
  services.pipewire.extraConfig.pipewire."93-rnnoise" = {
    "context.modules" = [
      { name = "libpipewire-module-filter-chain";
        args = {
          "node.description" = "Noise Canceling source";
          "media.name" = "Noise Canceling source";
          "filter.graph" = {
            nodes = [
              { type = "ladspa";
                name = "rnnoise";
                plugin = "${pkgs.rnnoise-plugin}/lib/ladspa/librnnoise_ladspa";
                label = "noise_suppressor_mono";
                control = {
                  "VAD Threshold (%)" = 50.0;
                  "VAD Grace Period (ms)" = 200;
                  "Retroactive VAD Grace (ms)" = 0;
                };
              }
            ];
          };
          "capture.props" = {
            "node.name" = "capture.rnnoise_source";
            "node.passive" = true;
            "audio.rate" = 48000;
          };
          "playback.props" = {
            "node.name" = "rnnoise_source";
            "media.class" = "Audio/Source";
            "audio.rate" = 48000;
          };
        };
      }
    ];
  };

  environment.systemPackages = with pkgs; [
    rnnoise-plugin
    easyeffects
  ];
}
