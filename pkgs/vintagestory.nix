# Vintage Story bumped ahead of what nixpkgs ships. Reuses nixpkgs's derivation
# but overrides version + hash, and patches installPhase because 1.22 renamed
# gameicon.xpm -> gameicon.png. One derivation yields BOTH the client
# (bin/vintagestory) and the dedicated server (bin/vintagestory-server), so the
# desktop client and the vintagestory-server module share a single version pin.
{ vintagestory, fetchurl, lib, stdenv, patchelf }:

vintagestory.overrideAttrs (old: rec {
  version = "1.22.5";
  src = fetchurl {
    url = "https://cdn.vintagestory.at/gamefiles/stable/vs_client_linux-x64_${version}.tar.gz";
    hash = "sha256-ozpjsnqJKFdzKeJuOSuurYN8UEvLrBw17quGZeMN8PY=";
  };

  # nixpkgs runs the game through a dotnet wrapper (+ LD_LIBRARY_PATH) and never
  # patchelfs the bundled native VSCrashReporter helper — the binary the client
  # exec()s (by its share/ path) when it crashes. So on NixOS it stays a generic
  # ELF: its interpreter is /lib64/ld-linux (absent here → "Could not start
  # dynamically linked executable", and no crash report is written) and it needs
  # libstdc++, which is on no default path. Patch just this one side binary:
  # point it at the nix loader and add libstdc++/libgcc_s (both live in
  # stdenv.cc.cc.lib). Its remaining deps (libc/pthread/dl/m) resolve from the
  # loader's own glibc. Verified with ldd.
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ patchelf ];
  postFixup = (old.postFixup or "") + ''
    patchelf \
      --set-interpreter "$(cat ${stdenv.cc}/nix-support/dynamic-linker)" \
      --set-rpath "${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}" \
      "$out/share/vintagestory/VSCrashReporter"
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/vintagestory $out/bin $out/share/icons/hicolor/512x512/apps $out/share/fonts/truetype
    cp -r * $out/share/vintagestory
    cp $out/share/vintagestory/assets/gameicon.png $out/share/icons/hicolor/512x512/apps/vintagestory.png
    cp $out/share/vintagestory/assets/game/fonts/*.ttf $out/share/fonts/truetype

    rm -rvf $out/share/vintagestory/{install,run,server}.sh

    runHook postInstall
  '';
})
