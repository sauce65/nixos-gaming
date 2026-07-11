# Overlay exposing the pinned Vintage Story build (pkgs.vintagestory-latest) and
# a mod-fetch helper (pkgs.fetchVintagestoryMod). One derivation provides both
# the client (bin/vintagestory) and the dedicated server (bin/vintagestory-server),
# which is what lets the desktop client and the vintagestory-server module share a
# single version pin.
#
# Single source of truth: ../pkgs/vintagestory.nix, reused by this overlay, the
# flake's packages output, and (via the package option) the server module.
final: prev: {
  vintagestory-latest = final.callPackage ../pkgs/vintagestory.nix { };

  # Fetch a Vintage Story mod release (a .zip from the ModDB, or any URL), pinned
  # by hash and named so the server's mod-sync drops it into Mods/ as `name`.
  # Get the hash with:  nix store prefetch-file --name <name> <url>
  fetchVintagestoryMod = { name, url, hash }:
    final.fetchurl { inherit name url hash; };
}
