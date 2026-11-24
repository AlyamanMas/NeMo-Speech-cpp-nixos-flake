# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NeMo-Speech.cpp. Call with callPackage and pick one accelerator backend:
#
#   nemo-speech.override { cudaSupport = true; }                     # NVIDIA CUDA
#   nemo-speech.override { vulkanSupport = true; }                   # Vulkan (AMD/Intel/NVIDIA)
#   nemo-speech.override { metalSupport = true; }                    # Apple Silicon (default there)
#
# CUDA GPU architectures come from the nixpkgs `cudaCapabilities` config, e.g.
# `import nixpkgs { config.cudaCapabilities = [ "8.9" ]; }`. Narrowing it to the
# GPUs you run on shortens the build considerably.
#
# llamaCppSrc and cppHttplibSrc are the pinned llama.cpp and cpp-httplib
# submodule sources, which a Nix source tree does not carry.
{
  lib,
  config,
  stdenv,
  cmake,
  ninja,
  pkg-config,
  git,
  python3,
  sentencepiece,
  abseil-cpp,
  openssl,
  autoAddDriverRunpath,
  shaderc,
  vulkan-headers,
  vulkan-loader,
  spirv-headers,

  llamaCppSrc,
  cppHttplibSrc,

  # Accelerator backends. CUDA follows the nixpkgs `cudaSupport` config.
  cudaSupport ? config.cudaSupport,
  cudaPackages ? { },
  vulkanSupport ? false,
  metalSupport ? stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64 && !vulkanSupport,

  # -march=native for the build machine's CPU. The result runs only on that CPU
  # model and is not substitutable from a binary cache. Off, x86_64 builds target
  # x86-64-v3 (AVX2/FMA/F16C), as the release archives do.
  nativeCpu ? false,

  # Components; the defaults mirror the cpu-server / cuda-server presets.
  enableAsr ? true,
  enableDiarization ? true,
  enableTts ? true,
  enableNmt ? true,
  enableSpeechLm ? true,
  # Full-duplex voicechat requires the patched ggml, which only CPU and CUDA use.
  enableS2s ? false,
  enableHttp ? true,
  enableHttpTls ? false,
  enableMicCapture ? true,
  enableTools ? false,
  # Build and run the unit tests in the sandbox (CPU builds only; the sandbox has no GPU).
  doCheck ? !cudaSupport && !vulkanSupport && !metalSupport,
}:

let
  inherit (lib) cmakeBool cmakeFeature optionals;

  # The patches/ series targets ggml-cpu and ggml-cuda; the Metal and Vulkan
  # presets build against stock ggml.
  ggmlPatched = !metalSupport && !vulkanSupport;

  # CUDA imposes an upper bound on the host compiler version.
  effectiveStdenv = if cudaSupport then cudaPackages.backendStdenv else stdenv;

  versionLine = lib.findFirst (lib.hasPrefix "NEMO_SPEECH_VERSION:") null (
    lib.splitString "\n" (builtins.readFile ../VERSION)
  );
  version = lib.trim (lib.removePrefix "NEMO_SPEECH_VERSION:" versionLine);

  fs = lib.fileset;
  src = fs.toSource {
    root = ../.;
    fileset = fs.unions [
      ../CMakeLists.txt
      ../VERSION
      ../LICENSE
      ../NOTICE
      ../THIRD_PARTY_NOTICES.md
      ../README.md
      ../CONTRIBUTING.md
      ../app
      ../cmake
      ../config
      ../docs
      ../examples
      ../include
      ../kernels
      ../models
      ../patches
      ../server
      ../src
      ../tests
      ../test_files
      ../tools
      ../third_party/miniaudio
    ];
  };
in
assert lib.assertMsg (
  lib.count lib.id [
    cudaSupport
    vulkanSupport
    metalSupport
  ] <= 1
) "nemo-speech: enable at most one of cudaSupport, vulkanSupport, metalSupport";
assert lib.assertMsg (
  enableS2s -> ggmlPatched
) "nemo-speech: enableS2s requires the patched ggml (CPU or CUDA backend)";

effectiveStdenv.mkDerivation (finalAttrs: {
  pname = "nemo-speech";
  inherit version src doCheck;

  # Drop the pinned submodule sources into place. CMake then applies patches/
  # to a copy of llama.cpp in the build directory, exactly as in a git checkout.
  postUnpack = ''
    rmdir "$sourceRoot/llama.cpp" 2>/dev/null || true
    cp -r --no-preserve=mode ${llamaCppSrc} "$sourceRoot/llama.cpp"
  ''
  + lib.optionalString enableHttp ''
    mkdir -p "$sourceRoot/third_party"
    cp -r --no-preserve=mode ${cppHttplibSrc} "$sourceRoot/third_party/cpp-httplib"
  '';

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    git # `git apply` for the ggml/llama.cpp patch series
  ]
  ++ optionals finalAttrs.doCheck [ python3 ]
  ++ optionals cudaSupport [
    cudaPackages.cuda_nvcc
    # Adds /run/opengl-driver/lib to the RUNPATH so libcuda.so.1 resolves on NixOS.
    autoAddDriverRunpath
  ]
  ++ optionals vulkanSupport [ shaderc ];

  buildInputs = [
    sentencepiece
    abseil-cpp # sentencepiece_processor.h includes absl
  ]
  ++ optionals enableHttpTls [ openssl ]
  ++ optionals cudaSupport (
    with cudaPackages;
    [
      cccl # <nv/target>
      cuda_cudart
      libcublas
    ]
  )
  ++ optionals vulkanSupport [
    vulkan-headers
    vulkan-loader
    spirv-headers
  ];

  cmakeFlags = [
    (cmakeBool "NEMO_SPEECH_GGML_PATCHED" ggmlPatched)
    (cmakeBool "NEMO_SPEECH_BUILD_ASR" (enableAsr || enableS2s || enableSpeechLm))
    (cmakeBool "NEMO_SPEECH_BUILD_DIAR" enableDiarization)
    (cmakeBool "NEMO_SPEECH_BUILD_TTS" enableTts)
    (cmakeBool "NEMO_SPEECH_BUILD_NMT" enableNmt)
    (cmakeBool "NEMO_SPEECH_BUILD_SPEECHLM" enableSpeechLm)
    (cmakeBool "NEMO_SPEECH_BUILD_S2S" enableS2s)
    (cmakeBool "NEMO_SPEECH_BUILD_HTTP" enableHttp)
    (cmakeBool "NEMO_SPEECH_HTTP_TLS" enableHttpTls)
    (cmakeBool "NEMO_SPEECH_BUILD_MIC_CAPTURE" enableMicCapture)
    (cmakeBool "NEMO_SPEECH_BUILD_TOOLS" enableTools)
    (cmakeBool "NEMO_SPEECH_BUILD_TESTS" finalAttrs.doCheck)
    (cmakeBool "NEMO_SPEECH_BUILD_GRPC" false)
    (cmakeBool "NEMO_SPEECH_WITH_FLASHLIGHT" false)
    (cmakeBool "NEMO_SPEECH_WITH_NORM" false)
    (cmakeBool "GGML_NATIVE" nativeCpu)
    (cmakeBool "GGML_LLAMAFILE" true)
    (cmakeBool "GGML_CUDA" cudaSupport)
    (cmakeBool "GGML_VULKAN" vulkanSupport)
    (cmakeBool "GGML_METAL" metalSupport)
  ]
  ++ optionals cudaSupport [
    (cmakeBool "GGML_CUDA_GRAPHS" true)
    (cmakeBool "GGML_CUDA_NCCL" false)
    (cmakeFeature "CMAKE_CUDA_ARCHITECTURES" cudaPackages.flags.cmakeCudaArchitecturesString)
  ]
  ++ optionals metalSupport [
    # Compile the Metal shaders into the library; no runtime .metal lookup.
    (cmakeBool "GGML_METAL_EMBED_LIBRARY" true)
  ];

  # Sandbox-friendly subset: tests that need network, an install tree, or
  # interactive tooling are excluded.
  checkPhase = ''
    runHook preCheck
    ctest --output-on-failure --timeout 600 -j $NIX_BUILD_CORES \
      -E '^(installed_sdk_consumer|cli_model_store|cli_install_.*)$'
    runHook postCheck
  '';

  passthru = {
    inherit
      cudaSupport
      vulkanSupport
      metalSupport
      ggmlPatched
      ;
    inherit cudaPackages;
  };

  meta = {
    description = "Speech recognition, diarization, synthesis, and translation for NeMo models on ggml";
    homepage = "https://github.com/NVIDIA/NeMo-Speech.cpp";
    license = lib.licenses.asl20;
    mainProgram = "nemo-speech";
    platforms = if metalSupport then lib.platforms.darwin else lib.platforms.unix;
    badPlatforms = optionals cudaSupport lib.platforms.darwin;
  };
})
