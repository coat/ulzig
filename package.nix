{
  callPackage,
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
      version = "0.2.0";
      src = lib.cleanSource ./.;
      nativeBuildInputs = [
        zig_hook
        makeWrapper
      ];

      deps = callPackage ./build.zig.zon.nix {name = "ulz-${finalAttrs.version}";};

      zigBuildFlags = [
        "--system"
        "${finalAttrs.deps}"
      ];
      meta = {
        mainProgram = "ulz";
        license = lib.licenses.mit;
      };
    }
  )
