# PipeWire tuned for low-latency microphone capture. Quantum 256 @ 48kHz
# yields ~5ms buffer latency. RNNoise filter-chain for noise suppression.
# WirePlumber rule prevents Blue Yeti USB lockup by disabling ALSA suspend.
#
# After rebuild, select "Noise Canceling source" as your mic input in-game.
{ pkgs, ... }:
let
  # Yeti firmware mishandles USB renumeration after ALSA close — the device
  # gets stuck open-but-not-streaming until physically replugged. This script
  # finds the Yeti's USB bus/device path and resets it.
  fix-yeti = pkgs.writeShellApplication {
    name = "fix-yeti";
    runtimeInputs = with pkgs; [ usbutils gnugrep gawk ];
    text = ''
      set -euo pipefail
      LINE=$(lsusb | grep -i 'blue\|yeti\|046d:0ab7') || {
        echo "No Blue Yeti found on USB bus" >&2; exit 1;
      }
      BUS=$(echo "$LINE" | awk '{print $2}')
      DEV=$(echo "$LINE" | awk '{print $4}' | tr -d ':')
      DEVPATH="/dev/bus/usb/''${BUS}/''${DEV}"
      echo "Resetting Yeti at $DEVPATH..."
      sudo usbreset "$DEVPATH"
      echo "Done. Wait ~2s before recording."
    '';
  };
in
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

  # Expose rnnoise-plugin to PipeWire's LADSPA path.
  services.pipewire.extraLadspaPackages = [ pkgs.rnnoise-plugin ];

  # RNNoise noise suppression via PipeWire filter-chain.
  # Creates a virtual "Noise Canceling source" input device.
  # `plugin` is a LADSPA basename - PipeWire automatically appends `.so` and
  # searches LADSPA_PATH. Do NOT include `.so` here or you get `.so.so`.
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
                plugin = "librnnoise_ladspa";
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

  # Keep Blue Yeti / Blue Microphones USB devices always-streaming so the
  # firmware never lands in its stuck post-suspend state. Tradeoff: mic-live
  # LED stays on; minor extra USB power draw.
  services.pipewire.wireplumber.extraConfig."51-yeti-no-suspend" = {
    "monitor.alsa.rules" = [
      { matches = [ { "node.name" = "~alsa_input.*Blue.*"; } ];
        actions = {
          update-props = {
            "session.suspend-timeout-seconds" = 0;
          };
        };
      }
    ];
  };

  environment.systemPackages = with pkgs; [
    easyeffects
    fix-yeti
  ];
}
