{
  description = "NixOS gaming modules — Steam, Proton-GE, Bellum, OBS streaming, and more";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nixosModules = {
      # Core gaming stack: Steam, Proton-GE, Gamescope, GameMode, MangoHud, etc.
      gaming = import ./modules/gaming.nix;

      # Bellum (Astarte Industries) via umu-run + GE-Proton
      bellum = import ./modules/bellum.nix;

      # Per-game log capture harness (gamerun/gamelogs/gamewatch CLIs).
      # Other modules (e.g. bellum) declare their game profiles via the
      # `gamelogs.games.<name>` option this exposes.
      gamelogs = import ./modules/gamelogs.nix;

      # NVIDIA proprietary drivers with Wayland + VA-API
      graphics-nvidia = import ./modules/graphics-nvidia.nix;

      # Low-latency PipeWire audio tuning
      audio-lowlatency = import ./modules/audio-lowlatency.nix;

      # OBS Studio with Wayland capture + virtual camera
      streaming = import ./modules/streaming.nix;

      # Game controller support (Xbox, etc.)
      controllers = import ./modules/controllers.nix;

      # Everything except graphics (pick your own GPU module)
      default = { imports = [
        ./modules/gaming.nix
        ./modules/bellum.nix
        ./modules/gamelogs.nix
        ./modules/audio-lowlatency.nix
        ./modules/streaming.nix
        ./modules/controllers.nix
      ]; };
    };
  };
}
