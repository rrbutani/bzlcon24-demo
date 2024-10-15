{
  inputs.nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
  inputs.flake-utils.url = github:numtide/flake-utils;

  outputs = { nixpkgs, flake-utils, self }: flake-utils.lib.eachDefaultSystem (sys: let
    np = nixpkgs.legacyPackages.${sys};
    inherit (np) lib;

    bazelUtils = {
      # builds a Bazel package from a pre-release dist zip
      #
      # !!! nevermind, misguided; see:
      # https://github.com/NixOS/nixpkgs/issues/318833#issuecomment-2158859843
      #
      # happens to work for `8.0.0-pre.20240618.2`, newer releases are broken
      # (require things that aren't in the bundled `distdir`)
      mkFromCustomSrc =
        { version
        , src
        , base ? np.bazel_7
        }: let
          # the actual bazel nixpkg vendors this file to avoid IFD; we're okay
          # with IFD:
          lockfile = np.stdenvNoCC.mkDerivation {
            name = "bazel-${version}-MODULE.bazel.lock";
            inherit src;
            sourceRoot = ".";
            nativeBuildInputs = [ np.unzip ];
            buildPhase = "cp MODULE.bazel.lock $out";
          };

        # apply the overrides:
        in lib.pipe base [
          # bazel 8 wants JDK 21:
          (pkg: pkg.override rec {
            buildJdk = np.jdk21_headless;
            runJdk = buildJdk;
          })
          (pkg: pkg.overrideAttrs (old: {
            postPatch = builtins.replaceStrings
              ["java_runtime_version=local_jdk_17" "java_language_version=17" "--extra_toolchains=@bazel_tools//tools/jdk:all"]
              ["java_runtime_version=local_jdk_21" "java_language_version=21" ""]
              old.postPatch
            ;
          }))

          # version gets used in many places and is overrideable at the
          # `callPackage` level:
          (pkg: pkg.override { inherit version; })

          # `src` and `lockfile` must be overriden at the `mkDerivation` level:
          (pkg: pkg.overrideAttrs (old: let
            # `lockfile` gets used in a couple of places:
            distDir = repoCache;
            repoCache = old.passthru.repoCache.override { inherit lockfile; };
          in {
            inherit src;

            postPatch = builtins.replaceStrings
              ["${old.passthru.repoCache}"]
              ["${repoCache}"]
              old.postPatch
            ;

            passthru = old.passthru // {
              tests = old.passthru.tests.override { inherit lockfile repoCache; };
              inherit lockfile distDir repoCache;
            };
          }))
        ];

      # get the version and `dist.zip` SHA256 from `.bazelversion`:
      infoFromBazelVersionFile = file: let
        lines = lib.splitString "\n" (builtins.readFile ./.bazelversion);

        version = builtins.head lines;
        sha256 = builtins.elemAt lines 1;
        majorVersion = builtins.head (lib.splitString "-" version);
      in {
        inherit version;
        src = np.fetchurl {
          url = "https://releases.bazel.build/${majorVersion}/rolling/${version}/bazel-${version}-dist.zip";
          inherit sha256;
        };
      };
    };
  in {
    packages = with bazelUtils; {
      bazel = mkFromCustomSrc (infoFromBazelVersionFile ./.bazelversion);
      /* bazel_custom = mkFromCustomSrc { # TODO
        # src = null;
        # version = null;
      }; */
    };

    devShells.default = np.mkShell {
      nativeBuildInputs = with np; [
        self.packages.${sys}.bazel_custom
        buildifier
      ];
    };
  });
}
