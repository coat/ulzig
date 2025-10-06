{
  callPackage,
  elfkickers,
  lib,
  stdenvNoCC,
  makeWrapper,
  zig_0_15,
}: let
  zig_hook = zig_0_15.hook.overrideAttrs {
    zig_default_flags = "-Dcpu=baseline -Doptimize=ReleaseSmall --color off";
  };
in
  stdenvNoCC.mkDerivation (
    finalAttrs: {
      name = "ulz";
      version = "0.3.1";
      src = lib.cleanSource ./.;
      nativeBuildInputs = [
        zig_hook
        makeWrapper
      ] ++ lib.optionals stdenvNoCC.isLinux [elfkickers];

      meta = {
        mainProgram = "ulz";
        license = lib.licenses.mit;
      };
    }
  )
