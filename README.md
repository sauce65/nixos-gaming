# nixos-gaming

A small flake of NixOS modules for gaming on Linux: Steam + Proton-GE, OBS streaming, low-latency PipeWire, controllers, and a few launcher-specific bits. Designed to be composed into another flake — pick the modules you want, bring your own GPU module.

## Modules

| Module | What it enables |
|---|---|
| `gaming` | Steam (with Gamescope session), Proton-GE, GameMode, MangoHud + goverlay, Heroic, umu-launcher, Wine (Wow64) staging, winetricks |
| `controllers` | Steam input, Xbox wireless (xpadneo), Xbox One USB (xone) |
| `bellum` | Astarte Industries' Bellum launcher via umu-run + GE-Proton, with the WebView2 seccomp workaround for `wine64-preloader` SIGSYS at startup. Self-contained — pulls in `gamelogs`. |
| `gamelogs` | Per-game log-capture harness (`gamerun`/`gamelogs`/`gamewatch`). Games register via `gamelogs.games.<name>`. |
| `audio-lowlatency` | PipeWire 256-quantum @ 48 kHz, RNNoise filter-chain ("Noise Canceling source"), easyeffects. Hardware-agnostic. |
| `yeti-fix` | Blue Yeti USB-suspend mitigation (udev + WirePlumber) + `fix-yeti` USB reset helper. Import only on a box that has a Yeti. |
| `streaming` | OBS Studio with Wayland/PipeWire capture plugins, vkcapture, vaapi, background removal, v4l2loopback virtual camera |
| `obs-ptt` | evdev push-to-talk daemon driving OBS mute over obs-websocket (works under Wayland once a game grabs focus). Set `programs.obsPtt.user`. |
| `graphics-nvidia` | Nvidia proprietary driver pinned to `new_feature` (590-series) for Blackwell compatibility, open kernel modules, Wayland session env, VA-API bridge |

## Composing

`nixosModules.default` is the sensible gaming core — `gaming` + `controllers`, GPU-agnostic — so most machines just import it and add their own graphics module:

```nix
{
  inputs.nixos-gaming.url = "github:sauce65/nixos-gaming";

  outputs = { self, nixpkgs, nixos-gaming, ... }: {
    nixosConfigurations.mybox = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        nixos-gaming.nixosModules.default
        nixos-gaming.nixosModules.graphics-nvidia   # only if you have an Nvidia card
      ];
    };
  };
}
```

The heavier / opinionated modules — `streaming`, `obs-ptt`, `bellum`, `audio-lowlatency`, `yeti-fix` — are **not** in `default`. Import them explicitly on the machines that want them:

```nix
modules = [
  nixos-gaming.nixosModules.default
  nixos-gaming.nixosModules.streaming
  nixos-gaming.nixosModules.audio-lowlatency
  nixos-gaming.nixosModules.yeti-fix          # this box has a Blue Yeti
];
```

## Constraints / sharp edges

- `graphics-nvidia` pins the driver to `new_feature` (590.x) because 595 has a confirmed shader-compilation bug on Blackwell (RTX 50-series) that hangs UE5 games via VKD3D-Proton during PSO compile. The package is set with `lib.mkDefault`, so on Turing/Ampere/Ada you can override `hardware.nvidia.package` back to `production` with a plain assignment.
- `yeti-fix` is Blue-Yeti-specific (vendor `046d`, product `0ab7`) and installs a `fix-yeti` reset helper. Import only where a Yeti is actually attached.
- `bellum` expects the Astarte launcher installer to be downloaded externally; bootstrap with `bellum-bootstrap <prefix-path> <installer.exe>`.
