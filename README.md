# nixos-gaming

A small flake of NixOS modules for gaming on Linux: Steam + Proton-GE, OBS streaming, low-latency PipeWire, controllers, and a few launcher-specific bits. Designed to be composed into another flake — pick the modules you want, bring your own GPU module.

## Modules

| Module | What it enables |
|---|---|
| `gaming` | Steam (with Gamescope session), Proton-GE, GameMode, MangoHud + goverlay, Heroic, umu-launcher, Wine (Wow64) staging, winetricks |
| `bellum` | Astarte Industries' Bellum launcher via umu-run + GE-Proton, with the WebView2 seccomp workaround for `wine64-preloader` SIGSYS at startup |
| `audio-lowlatency` | PipeWire 256-quantum @ 48 kHz, RNNoise filter-chain ("Noise Canceling source"), Blue Yeti USB-suspend mitigation + `fix-yeti` USB reset helper |
| `streaming` | OBS Studio with Wayland/PipeWire capture plugins, vkcapture, vaapi, background removal, v4l2loopback virtual camera |
| `controllers` | Steam input, Xbox wireless (xpadneo), Xbox One USB (xone) |
| `graphics-nvidia` | Nvidia proprietary driver pinned to `new_feature` (590-series) for Blackwell compatibility, open kernel modules, Wayland session env, VA-API bridge |

## Composing

`nixosModules.default` aggregates everything **except** graphics, so AMD/Intel users can compose freely:

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

Or import individual modules:

```nix
modules = [
  nixos-gaming.nixosModules.gaming
  nixos-gaming.nixosModules.audio-lowlatency
  nixos-gaming.nixosModules.controllers
];
```

## Constraints / sharp edges

- `graphics-nvidia` pins the driver to `new_feature` (590.x) because 595 has a confirmed shader-compilation bug on Blackwell (RTX 50-series) that hangs UE5 games via VKD3D-Proton during PSO compile. If you're on Turing/Ampere/Ada, you can override the package back to `production`.
- `audio-lowlatency` enables a Yeti-specific udev rule (vendor `046d`, product `0ab7`) and WirePlumber matcher (`alsa_input.*Blue.*`). Harmless if you don't have a Yeti, but the `fix-yeti` binary is also installed unconditionally.
- `bellum` expects the Astarte launcher installer to be downloaded externally; bootstrap with `bellum-bootstrap <prefix-path> <installer.exe>`.
