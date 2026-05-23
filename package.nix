{
  elfkickers,
  lib,
  stdenvNoCC,
  makeWrapper,
  zig,
}:
stdenvNoCC.mkDerivation (
  finalAttrs: {
    name = "ulz";
    version = "0.4.0";
    src = lib.cleanSource ./.;
    nativeBuildInputs =
      [
        zig
        makeWrapper
      ]
      ++ lib.optionals stdenvNoCC.isLinux [elfkickers];

    zigBuildFlags = [
      "-Doptimize=ReleaseSmall"
    ];

    meta = {
      mainProgram = "ulz";
      license = lib.licenses.mit;
    };
  }
)
