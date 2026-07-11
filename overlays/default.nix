# Overlay exposing the pinned Vintage Story build so any machine can reference
# pkgs.vintagestory-latest. One derivation provides both the client
# (bin/vintagestory) and the dedicated server (bin/vintagestory-server), which is
# what lets the desktop client and the vintagestory-server module share a single
# version pin.
#
# Single source of truth: ../pkgs/vintagestory.nix, reused by this overlay, the
# flake's packages output, and (via the package option) the server module.
final: prev: {
  vintagestory-latest = final.callPackage ../pkgs/vintagestory.nix { };
}
