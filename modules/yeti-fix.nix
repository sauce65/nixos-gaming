# Blue Yeti USB-lockup workaround. The Yeti's firmware mishandles USB
# renumeration after ALSA close — it gets stuck open-but-not-streaming until
# physically replugged. Two layers keep it always-streaming so it never lands
# in that state, plus a `fix-yeti` helper to reset it if it ever does.
#
# Hardware-specific (vendor 046d, product 0ab7): import only on a machine that
# actually has a Yeti. Split out of audio-lowlatency so that module stays
# hardware-agnostic.
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
      echo "Resetting Yeti at bus $BUS device $DEV..."
      sudo usbreset "''${BUS}/''${DEV}"
      echo "Done. Wait ~2s before recording."
    '';
  };
in
{
  # Keep Blue Yeti / Blue Microphones USB devices always-streaming so the
  # firmware never lands in its stuck post-suspend state. Tradeoff: mic-live
  # LED stays on; minor extra USB power draw.
  #
  # Two layers, both required:
  #
  # 1) Kernel-level: disable USB autosuspend for vendor 046d product 0ab7
  #    (Logitech Blue Yeti). The kernel autosuspends idle USB devices after
  #    ~2s by default, and the Yeti's firmware doesn't reliably wake — it
  #    enters a half-stuck state where ALSA says "Running" but no samples
  #    arrive. udev sets power/control = "on" so the kernel never suspends
  #    this device.
  #
  # 2) PipeWire-level: WirePlumber's own suspend-on-idle, set to 0
  #    (never), so ALSA stays open continuously. Without this, even if the
  #    kernel keeps the USB device awake, PipeWire would close the ALSA
  #    handle on idle and reopen it later.
  services.udev.extraRules = ''
    # Blue Microphones (Logitech) Yeti — disable USB autosuspend
    SUBSYSTEM=="usb", ATTR{idVendor}=="046d", ATTR{idProduct}=="0ab7", TEST=="power/control", ATTR{power/control}="on"
  '';

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

  environment.systemPackages = [ fix-yeti ];
}
