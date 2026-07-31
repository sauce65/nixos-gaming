# Game controller support.
#
#   * hardware.steam-hardware — udev rules for Steam Controller / Valve HID
#     devices (and lets Steam Input grab supported pads).
#   * hardware.xpadneo — enhanced driver for Xbox controllers over *Bluetooth*
#     (rumble, battery, correct axis/button maps).
#
# Wired Xbox controllers — Xbox One/Series and Xbox-protocol third-party pads
# such as the Razer Wolverine V2 — are driven by the *in-kernel* `xpad` driver,
# which now has native support for them (its device table literally lists
# "Razer Wolverine V2"). No out-of-tree module is required.
#
# We deliberately do NOT enable `hardware.xone`. xone grabs every Xbox USB
# controller and *blacklists xpad* to avoid a bind conflict — but the packaged
# xone (0.5.8) mis-parses the Wolverine V2's chunked GIP init packet
# ("xone-gip: gip_process_pkt_chunked: buffer too small" → data-in fails with
# -EINVAL). The pad then churns in a connect/disconnect loop and delivers zero
# input to games, while the working in-kernel xpad is blacklisted out of the
# way. Not enabling xone leaves xpad free to autoload and bind, which it does
# cleanly.
#
# Tradeoff: dropping xone also drops the proprietary Xbox Wireless *dongle* (the
# 2.4 GHz USB adapter), which only xone supports. Wireless pads here connect
# over Bluetooth via xpadneo instead. A host that genuinely needs the dongle can
# re-enable `hardware.xone` locally (and accept that its wired pads then route
# through xone rather than xpad).
{ ... }:
{
  hardware.steam-hardware.enable = true;
  hardware.xpadneo.enable = true;
}
