{
  description = "NixOS gaming modules — Steam, Proton-GE, Bellum, OBS streaming, and more";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      # vintagestory is unfree, so the standalone packages output needs a nixpkgs
      # instance with unfree allowed. Machines that apply overlays.default get
      # unfree from their own nixpkgs config instead.
      forAllSystems = f: nixpkgs.lib.genAttrs systems
        (system: f system (import nixpkgs { inherit system; config.allowUnfree = true; }));
    in
    {
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

        # Low-latency PipeWire audio tuning (hardware-agnostic)
        audio-lowlatency = import ./modules/audio-lowlatency.nix;

        # Blue Yeti USB-lockup workaround (hardware-specific; split from audio-lowlatency)
        yeti-fix = import ./modules/yeti-fix.nix;

        # OBS Studio with Wayland capture + virtual camera
        streaming = import ./modules/streaming.nix;

        # OBS push-to-talk daemon (evdev → obs-websocket). Works under
        # Wayland by reading /dev/input below the compositor; OBS's
        # built-in PTT cannot grab keys while another window has focus.
        obs-ptt = import ./modules/obs-ptt.nix;

        # Game controller support (Xbox, etc.)
        controllers = import ./modules/controllers.nix;

        # Vintage Story dedicated server — generic and host-agnostic. Bring your
        # own package (services.vintagestory-server.package) so the server matches
        # your client; the pinned build is exposed via overlays.default below.
        vintagestory-server = import ./modules/vintagestory-server.nix;

        # Sensible gaming core: Steam/Proton + controllers, GPU-agnostic (bring
        # your own graphics module). The heavier/opinionated bits — streaming,
        # obs-ptt, bellum, audio-lowlatency, yeti-fix — are opt-in: import them
        # explicitly on the machines that actually want them.
        default = { imports = [
          ./modules/gaming.nix
          ./modules/controllers.nix
        ]; };
      };

      # Overlay exposing the pinned Vintage Story build (client + dedicated
      # server in one derivation) as pkgs.vintagestory-latest.
      overlays.default = import ./overlays/default.nix;

      # Standalone build of the pinned game (`nix build .#vintagestory-latest`).
      packages = forAllSystems (system: pkgs: {
        vintagestory-latest = pkgs.callPackage ./pkgs/vintagestory.nix { };
      });
    };
}
