# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
{
  description = "NeMo-Speech.cpp: speech recognition, diarization, TTS, and translation on ggml";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Submodule sources. A flake's own source tree carries no submodules, so the
    # build-time ones are separate inputs pinned to the same commits as the
    # gitlinks; scripts/check_nix_submodule_pins.sh keeps the two in sync.
    llama-cpp = {
      url = "github:ggml-org/llama.cpp/bd4f514db14d87fded667787a7a963bfbaa98e89";
      flake = false;
    };
    cpp-httplib = {
      url = "github:yhirose/cpp-httplib/62d899feac3cf9215a55f2b43da250fdd98d2156";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      llama-cpp,
      cpp-httplib,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # CUDA is unfree; allow only the CUDA toolkit, not unfree packages in general.
      allowUnfreePredicate =
        pkg:
        builtins.all (license: license.free || license.shortName == "CUDA EULA") (
          lib.toList (pkg.meta.license or [ ])
        );

      pkgsFor =
        system: config:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
          config = {
            inherit allowUnfreePredicate;
          }
          // config;
        };

      nixpkgsFor = lib.genAttrs systems (system: pkgsFor system { });

      forAllSystems = f: lib.genAttrs systems (system: f system nixpkgsFor.${system});

      # Jetson CUDA comes from the L4T redistributables, which nixpkgs selects from
      # the configured capabilities. Tegra has no CUDA forward compatibility, so
      # each toolkit matches its JetPack's driver: 12.6 for JetPack 6 (Orin),
      # 13.0 for JetPack 7 (Thor).
      jetsonPackage =
        capability: cudaPackages:
        let
          pkgs = pkgsFor "aarch64-linux" { cudaCapabilities = [ capability ]; };
        in
        pkgs.nemo-speech.override {
          cudaSupport = true;
          cudaPackages = pkgs.${cudaPackages};
        };
    in
    {
      overlays.default = final: _prev: {
        nemo-speech = final.callPackage ./nix/package.nix {
          llamaCppSrc = llama-cpp;
          cppHttplibSrc = cpp-httplib;
        };
      };

      packages = forAllSystems (
        system: pkgs:
        let
          inherit (pkgs.stdenv.hostPlatform) isLinux isDarwin isAarch64;
        in
        {
          # Metal on Apple Silicon, CPU elsewhere.
          default = pkgs.nemo-speech;
          cpu = pkgs.nemo-speech.override { metalSupport = false; };
        }
        // lib.optionalAttrs isLinux {
          cuda = pkgs.nemo-speech.override { cudaSupport = true; };
          vulkan = pkgs.nemo-speech.override { vulkanSupport = true; };
        }
        // lib.optionalAttrs (isLinux && isAarch64) {
          cuda-jetson-orin = jetsonPackage "8.7" "cudaPackages_12_6";
          cuda-jetson-thor = jetsonPackage "11.0" "cudaPackages_13_0";
        }
        // lib.optionalAttrs (isDarwin && isAarch64) {
          metal = pkgs.nemo-speech.override { metalSupport = true; };
        }
      );

      apps = forAllSystems (
        system: _pkgs:
        lib.mapAttrs (_name: pkg: {
          type = "app";
          program = lib.getExe pkg;
          meta.description = pkg.meta.description;
        }) (lib.filterAttrs (name: _: !lib.hasPrefix "cuda-jetson" name) self.packages.${system})
      );

      devShells = forAllSystems (
        system: pkgs:
        let
          mkShell =
            pkg: extraPackages:
            (pkgs.mkShell.override { stdenv = pkg.stdenv; }) {
              inputsFrom = [ pkg ];
              packages = [
                pkgs.clang-tools
                pkgs.gdb
                pkgs.pre-commit
                pkgs.shellcheck
                (pkgs.python3.withPackages (ps: [
                  ps.numpy
                  ps.gguf
                ]))
              ]
              ++ extraPackages;
              # The shell builds from your submodule checkout:
              #   git submodule update --init llama.cpp third_party/cpp-httplib
              #   scripts/configure.sh cpu-server
              shellHook = ''
                export CMAKE_GENERATOR=Ninja
              '';
            };
        in
        {
          default = mkShell self.packages.${system}.default [ ];
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          cuda = mkShell self.packages.${system}.cuda [ ];
          vulkan = mkShell self.packages.${system}.vulkan [ pkgs.vulkan-tools ];
        }
      );

      formatter = forAllSystems (_system: pkgs: pkgs.nixfmt-tree);

      checks = forAllSystems (
        system: pkgs:
        let
          pkg = self.packages.${system}.default;
        in
        {
          # The default build runs ctest in its check phase.
          build = pkg;
          cli-version = pkgs.runCommand "nemo-speech-cli-version" { } ''
            ${lib.getExe pkg} --version | tee $out
            grep -q '${pkg.version}' $out
          '';
          format = pkgs.runCommand "nix-format" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${./flake.nix} ${./nix/package.nix}
            touch $out
          '';
        }
      );
    };
}
