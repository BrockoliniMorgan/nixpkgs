{
  stdenv,
  bazel,
  buildBazelPackage,
  lib,
  fetchFromGitHub,
  fetchurl,
  fetchzip,
  symlinkJoin,
  addDriverRunpath,
  fetchpatch,
  linkFarm,
  # Python deps
  buildPythonPackage,
  python,
  # Python libraries
  numpy,
  abseil-cpp,
  absl-py,
  packaging,
  setuptools,
  wheel,
  google-pasta,
  opt-einsum,
  astunparse,
  h5py,
  termcolor,
  grpcio,
  six,
  wrapt,
  protobuf-python,
  tensorflow-estimator-bin,
  dill,
  flatbuffers-python,
  portpicker,
  tblib,
  typing-extensions,
  ml-dtypes,
  keras,
  # Common deps
  git,
  pybind11,
  which,
  binutils,
  glibcLocales,
  cython,
  perl,
  # Common libraries
  jemalloc,
  mpi,
  gast,
  grpc,
  sqlite,
  boringssl,
  jsoncpp,
  nsync,
  curl,
  snappy-cpp,
  flatbuffers-core,
  icu,
  double-conversion,
  libpng,
  libjpeg_turbo,
  giflib,
  protobuf-core,
  libclang,
  # Upstream by default includes cuda support since tensorflow 1.15. We could do
  # that in nix as well. It would make some things easier and less confusing, but
  # it would also make the default tensorflow package unfree. See
  # https://groups.google.com/a/tensorflow.org/forum/#!topic/developers/iRCt5m4qUz0
  config,
  cudaSupport ? config.cudaSupport,
  cudaPackages, # https://www.tensorflow.org/install/source#gpu
  cudaCapabilities ? cudaPackages.flags.cudaCapabilities,
  mklSupport ? false,
  mkl,
  # XLA without CUDA is broken
  xlaSupport ? cudaSupport,
  sse42Support ? stdenv.hostPlatform.sse4_2Support,
  avx2Support ? stdenv.hostPlatform.avx2Support,
  fmaSupport ? stdenv.hostPlatform.fmaSupport,
  cctools,
  llvmPackages,
}:

let
  # Tensorflow looks at many toolchain-related variables which may diverge.
  #
  # Toolchain for cuda-enabled builds.
  # We want to achieve two things:
  # 1. NVCC should use a compatible back-end (e.g. gcc11 for cuda11)
  # 2. Normal C++ files should be compiled with the same toolchain,
  #    to avoid potential weird dynamic linkage errors at runtime.
  #    This may not be necessary though
  #
  # Toolchain for Darwin:
  # clang 7 fails to emit a symbol for
  # __ZN4llvm11SmallPtrSetIPKNS_10AllocaInstELj8EED1Ev in any of the
  # translation units, so the build fails at link time
  stdenv' =
    if cudaSupport then
      cudaPackages.backendStdenv
    else if stdenv.hostPlatform.isDarwin then
      llvmPackages.stdenv
    else
      stdenv;
  inherit (cudaPackages) cudatoolkit nccl;
  # use compatible cuDNN (https://www.tensorflow.org/install/source#gpu)
  # cudaPackages.cudnn led to this:
  # https://github.com/tensorflow/tensorflow/issues/60398
  #cudnnAttribute = "cudnn_8_6";
  cudnnAttribute = "cudnn";
  cudnnMerged = symlinkJoin {
    name = "cudnn-merged";
    paths = [
      (lib.getDev cudaPackages.${cudnnAttribute})
      (lib.getLib cudaPackages.${cudnnAttribute})
    ];
  };
  protobuf-extra = linkFarm "protobuf-extra" [
    {
      name = "include";
      path = protobuf-core.src;
    }
  ];

  cudaComponents = with cudaPackages; [
    (cuda_nvcc.__spliced.buildHost or cuda_nvcc)
    (cuda_nvprune.__spliced.buildHost or cuda_nvprune)
    cuda_cccl # block_load.cuh
    cuda_cudart # cuda.h
    cuda_cupti # cupti.h
    cuda_nvcc # See https://github.com/google/jax/issues/19811
    cuda_nvml_dev # nvml.h
    cuda_nvtx # nvToolsExt.h
    libcublas # cublas_api.h
    libcufft # cufft.h
    libcurand # curand.h
    libcusolver # cusolver_common.h
    libcusparse # cusparse.h
  ];

  cudatoolkitDevMerged = symlinkJoin {
    name = "cuda-${cudaPackages.cudaMajorMinorVersion}-dev-merged";
    paths = lib.concatMap (p: [
      (lib.getBin p)
      (lib.getDev p)
      (lib.getLib p)
      (lib.getOutput "static" p) # Makes for a very fat closure
    ]) cudaComponents;
  };

  # Tensorflow expects bintools at hard-coded paths, e.g. /usr/bin/ar
  # The only way to overcome that is to set GCC_HOST_COMPILER_PREFIX,
  # but that path must contain cc as well, so we merge them
  cudatoolkit_cc_joined = symlinkJoin {
    name = "${stdenv'.cc.name}-merged";
    paths = [
      stdenv'.cc
      binutils.bintools # for ar, dwp, nm, objcopy, objdump, strip
    ];
  };

  # Needed for _some_ system libraries, grep INCLUDEDIR.
  includes_joined = symlinkJoin {
    name = "tensorflow-deps-merged";
    paths = [ jsoncpp ];
  };

  tfFeature = x: if x then "1" else "0";

  version = "2.21.0";
  format = "setuptools";
  pname = "tensorflow";

  pythonEnv = python.withPackages (_: [
    # python deps needed during wheel build time (not runtime, see the buildPythonPackage part for that)
    # This list can likely be shortened, but each trial takes multiple hours so won't bother for now.
    absl-py
    astunparse
    dill
    flatbuffers-python
    gast
    google-pasta
    grpcio
    h5py
    numpy
    opt-einsum
    packaging
    protobuf-python
    setuptools
    six
    tblib
    tensorflow-estimator-bin
    termcolor
    typing-extensions
    wheel
    wrapt
  ]);

  rules_cc_darwin_patched = stdenv'.mkDerivation {
    pname = "rules_cc-${pname}";
    inherit version;

    src = _bazel-build.deps;

    prePatch = "pushd rules_cc";
    patches = [
      # https://github.com/bazelbuild/rules_cc/issues/122
      (fetchpatch {
        name = "tensorflow-rules_cc-libtool-path.patch";
        url = "https://github.com/bazelbuild/rules_cc/commit/8c427ab30bf213630dc3bce9d2e9a0e29d1787db.diff";
        hash = "sha256-C4v6HY5+jm0ACUZ58gBPVejCYCZfuzYKlHZ0m2qDHCk=";
      })

      # https://github.com/bazelbuild/rules_cc/pull/124
      (fetchpatch {
        name = "tensorflow-rules_cc-install_name_tool-path.patch";
        url = "https://github.com/bazelbuild/rules_cc/commit/156497dc89100db8a3f57b23c63724759d431d05.diff";
        hash = "sha256-NES1KeQmMiUJQVoV6dS4YGRxxkZEjOpFSCyOq9HZYO0=";
      })
    ];
    postPatch = "popd";

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mv rules_cc/ "$out"

      runHook postInstall
    '';
  };
  llvm-raw_darwin_patched = stdenv'.mkDerivation {
    pname = "llvm-raw-${pname}";
    inherit version;

    src = _bazel-build.deps;

    prePatch = "pushd llvm-raw";
    patches = [
      # Fix a vendored config.h that requires the 10.13 SDK
      ./llvm_bazel_fix_macos_10_12_sdk.patch
    ];
    postPatch = ''
      touch {BUILD,WORKSPACE}
      popd
    '';

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mv llvm-raw/ "$out"

      runHook postInstall
    '';
  };
  bazel-build =
    if stdenv'.hostPlatform.isDarwin then
      _bazel-build.overrideAttrs (prev: {
        bazelFlags = prev.bazelFlags ++ [
          "--override_repository=rules_cc=${rules_cc_darwin_patched}"
          "--override_repository=llvm-raw=${llvm-raw_darwin_patched}"
        ];
        preBuild = ''
          export AR="${cctools}/bin/libtool"
        '';
      })
    else
      _bazel-build;

  bazelbuild-platforms = fetchzip {
    url = "https://github.com/bazelbuild/platforms/releases/download/0.0.11/platforms-0.0.11.tar.gz";
    hash = "sha256-qejSoz3Uf6uPVk9Ar5I4Q6lP74zsuraBymbvczwjGsk=";
    stripRoot = false;
  };
  rules_ml_toolchain = fetchzip {
    url = "https://github.com/google-ml-infra/rules_ml_toolchain/archive/d8cb9c2c168cd64000eaa6eda0781a9615a26ffe.tar.gz";
    hash = "sha256-FuJ4i9jKMpcmO1a/Pk+UYtZiwVc2izxxK9qcsmOxvLU=";
  };

  _bazel-build = buildBazelPackage.override { stdenv = stdenv'; } {
    inherit pname version bazel;

    src = fetchFromGitHub {
      owner = "tensorflow";
      repo = "tensorflow";
      tag = "v${version}";
      hash = "sha256-Hs3g80wSHex1ejz7H8eu6MJMzwthx58sPGDh/dG66FQ=";
    };

    nativeBuildInputs = [
      which
      pythonEnv
      cython
      perl
      protobuf-core
      protobuf-extra
    ]
    ++ lib.optional cudaSupport addDriverRunpath;

    buildInputs = [
      jemalloc
      mpi
      glibcLocales
      git

      # libs taken from system through the TF_SYS_LIBS mechanism
      abseil-cpp
      boringssl
      curl
      double-conversion
      flatbuffers-core
      giflib
      grpc
      # Necessary to fix the "`GLIBCXX_3.4.30' not found" error
      (icu.override { stdenv = stdenv'; })
      jsoncpp
      libjpeg_turbo
      libpng
      (pybind11.override (prev: {
        buildPythonPackage = prev.buildPythonPackage.override {
          stdenv = stdenv';
        };
      }))
      snappy-cpp
      sqlite
    ]
    ++ lib.optionals cudaSupport [
      cudatoolkit
      cudnnMerged
    ]
    ++ lib.optionals mklSupport [ mkl ]
    ++ lib.optionals (!stdenv'.hostPlatform.isDarwin) [ nsync ];

    env = {

      LIBTOOL = lib.optionalString stdenv'.hostPlatform.isDarwin "${cctools}/bin/libtool";

      # Take as many libraries from the system as possible. Keep in sync with
      # list of valid syslibs in
      # https://github.com/tensorflow/tensorflow/blob/master/third_party/systemlibs/syslibs_configure.bzl
      TF_SYSTEM_LIBS = lib.concatStringsSep "," [
        "absl_py"
        "astor_archive"
        "astunparse_archive"
        "boringssl"
        "com_github_googlecloudplatform_google_cloud_cpp"
        # "com_github_grpc_grpc"
        "com_google_absl"
        # "com_google_protobuf"
        # Fails with the error: external/org_tensorflow/tensorflow/core/profiler/utils/tf_op_utils.cc:46:49: error: no matching function for call to 're2::RE2::FullMatch(absl::lts_2020_02_25::string_view&, re2::RE2&)'
        "com_googlesource_code_re2"
        "curl"
        "cython"
        "dill_archive"
        "flatbuffers"
        "functools32_archive"
        "gast_archive"
        "gif"
        "hwloc"
        "icu"
        "jsoncpp_git"
        "libjpeg_turbo"
        "nasm"
        "org_sqlite"
        "pasta"
        "png"
        "pybind11"
        "six_archive"
        "snappy"
        "tblib_archive"
        "termcolor_archive"
        "typing_extensions_archive"
        "wrapt"
        "zlib"
      ];

      INCLUDEDIR = "${includes_joined}/include";

      # This is needed for the Nix-provided protobuf dependency to work,
      # as otherwise the rule `link_proto_files` tries to create the links
      # to `/usr/include/...` which results in build failures.
      PROTOBUF_INCLUDE_PATH = "${protobuf-core}/include";

      PYTHON_BIN_PATH = pythonEnv.interpreter;
      HERMETIC_PYTHON_VERSION = python.pythonVersion;

      TF_NEED_GCP = true;
      TF_NEED_HDFS = true;
      TF_ENABLE_XLA = tfFeature xlaSupport;

      CC_OPT_FLAGS = " ";
      CLANG_COMPILER_PATH = "${llvmPackages.libcxxClang}/bin/clang";

      # https://github.com/tensorflow/tensorflow/issues/14454
      TF_NEED_MPI = tfFeature cudaSupport;

      TF_NEED_CUDA = tfFeature cudaSupport;
      TF_CUDA_PATHS = lib.optionalString cudaSupport "${cudatoolkitDevMerged},${cudnnMerged},${lib.getLib nccl}";
      TF_CUDA_COMPUTE_CAPABILITIES = lib.concatStringsSep "," cudaCapabilities;

      # Needed even when we override stdenv': e.g. for ar
      GCC_HOST_COMPILER_PREFIX = lib.optionalString cudaSupport "${cudatoolkit_cc_joined}/bin";
      GCC_HOST_COMPILER_PATH = lib.optionalString cudaSupport "${cudatoolkit_cc_joined}/bin/cc";

      # https://github.com/tensorflow/tensorflow/pull/39470
      NIX_CFLAGS_COMPILE = toString [ "-Wno-stringop-truncation" ];
    };

    patches = [
      ./bazel_version.patch
      ./clib-src.patch
      ./template-rearrange.patch
    ];

    preConfigure =
      let
        opt_flags =
          [ ]
          ++ lib.optionals sse42Support [ "-msse4.2" ]
          ++ lib.optionals avx2Support [ "-mavx2" ]
          ++ lib.optionals fmaSupport [ "-mfma" ];
      in
      ''
        patchShebangs configure

        # dummy ldconfig
        mkdir dummy-ldconfig
        echo "#!${stdenv'.shell}" > dummy-ldconfig/ldconfig
        chmod +x dummy-ldconfig/ldconfig
        export PATH="$PWD/dummy-ldconfig:$PATH"

        export PYTHON_LIB_PATH="$NIX_BUILD_TOP/site-packages"
        export CC_OPT_FLAGS="${lib.concatStringsSep " " opt_flags}"
        mkdir -p "$PYTHON_LIB_PATH"

        # To avoid mixing Python 2 and Python 3
        unset PYTHONPATH
      '';

    configurePhase = ''
      runHook preConfigure
      ./configure
      runHook postConfigure
    '';

    hardeningDisable = [ "format" ];

    bazelFlags = [
      "--override_repository=platforms=${bazelbuild-platforms}"
      "--override_repository=rules_ml_toolchain=${rules_ml_toolchain}"
    ];

    bazelBuildFlags = [
      "--config=opt" # optimize using the flags set in the configure phase
    ]
    ++ lib.optionals stdenv'.cc.isClang [
      "--cxxopt=-x"
      "--cxxopt=c++"
      "--host_cxxopt=-x"
      "--host_cxxopt=c++"

      # workaround for https://github.com/bazelbuild/bazel/issues/15359
      "--spawn_strategy=sandboxed"
    ]
    ++ lib.optionals mklSupport [ "--config=mkl" ];

    bazelTargets = [
      "//tensorflow/tools/pip_package:build_pip_package.py //tensorflow/tools/lib_package:clib"
    ];

    removeRulesCC = false;
    # Without this Bazel complaints about sandbox violations.
    dontAddBazelOpts = true;

    fetchAttrs = {
      sha256 =
        {
          # Only tested x86_64-linux without cudaSupport
          x86_64-linux =
            if cudaSupport then
              "sha256-5VFMNHeLrUxW5RTr6EhT3pay9nWJ5JkZTGirDds5QkU="
            else
              "sha256-9t+seNUXA0SGnFDVqXqK3CFQJXHWkIvlSTwO1LuwyjE=";
          aarch64-linux =
            if cudaSupport then
              "sha256-ty5+51BwHWE1xR4/0WcWTp608NzSAS/iiyN+9zx7/wI="
            else
              "sha256-9btXrNHqd720oXTPDhSmFidv5iaZRLjCVX8opmrMjXk=";
          x86_64-darwin = "sha256-gqb03kB0z2pZQ6m1fyRp1/Nbt8AVVHWpOJSeZNCLc4w=";
          aarch64-darwin = "sha256-WdgAaFZU+ePwWkVBhLzjlNT7ELfGHOTaMdafcAMD5yo=";
        }
        .${stdenv'.hostPlatform.system} or (throw "unsupported system ${stdenv'.hostPlatform.system}");
    };

    buildAttrs = {
      outputs = [
        "out"
        "python"
      ];

      # need to rebuild schemas since we use a different flatbuffers version
      # preBuild = ''
      #   (cd tensorflow/lite/schema;${flatbuffers-core}/bin/flatc --gen-object-api -c schema.fbs)
      #   (cd tensorflow/lite/schema;${flatbuffers-core}/bin/flatc --gen-object-api -c conversion_metadata.fbs)
      #   (cd tensorflow/lite/acceleration/configuration;${flatbuffers-core}/bin/flatc -o configuration.fbs --proto configuration.proto)
      #   sed -i s,tflite.proto,tflite,g tensorflow/lite/acceleration/configuration/configuration.fbs/configuration.fbs
      #   (cd tensorflow/lite/acceleration/configuration;${flatbuffers-core}/bin/flatc --gen-compare --gen-object-api -c configuration.fbs/configuration.fbs)
      #   cp -r tensorflow/lite/acceleration/configuration/configuration.fbs tensorflow/lite/experimental/acceleration/configuration
      #   (cd tensorflow/lite/experimental/acceleration/configuration;${flatbuffers-core}/bin/flatc -c configuration.fbs/configuration.fbs)
      #   (cd tensorflow/lite/delegates/gpu/cl;${flatbuffers-core}/bin/flatc -c compiled_program_cache.fbs)
      #   (cd tensorflow/lite/delegates/gpu/cl;${flatbuffers-core}/bin/flatc -I $NIX_BUILD_TOP/source -c serialization.fbs)
      #   (cd tensorflow/lite/delegates/gpu/common;${flatbuffers-core}/bin/flatc -I $NIX_BUILD_TOP/source -c gpu_model.fbs)
      #   (cd tensorflow/lite/delegates/gpu/common/task;${flatbuffers-core}/bin/flatc -c serialization_base.fbs)
      #   patchShebangs .
      # '';
      #
      installPhase = ''
        mkdir -p "$out"
        tar -xf bazel-bin/tensorflow/tools/lib_package/libtensorflow.tar.gz -C "$out"
        # Write pkgconfig file.
        mkdir "$out/lib/pkgconfig"
        cat > "$out/lib/pkgconfig/tensorflow.pc" << EOF
        Name: TensorFlow
        Version: ${version}
        Description: Library for computation using data flow graphs for scalable machine learning
        Requires:
        Libs: -L$out/lib -ltensorflow
        Cflags: -I$out/include/tensorflow
        EOF

        # build the source code, then copy it to $python (build_pip_package
        # actually builds a symlink farm so we must dereference them).
        bazel-bin/tensorflow/tools/pip_package/build_pip_package --src "$PWD/dist"
        cp -Lr "$PWD/dist" "$python"
      '';

      postFixup = lib.optionalString cudaSupport ''
        find $out -type f \( -name '*.so' -or -name '*.so.*' \) | while read lib; do
          addDriverRunpath "$lib"
        done
      '';

      requiredSystemFeatures = [ "big-parallel" ];
    };

    meta = {
      badPlatforms = lib.optionals cudaSupport lib.platforms.darwin;
      changelog = "https://github.com/tensorflow/tensorflow/releases/tag/v${version}";
      description = "Computation using data flow graphs for scalable machine learning";
      homepage = "http://tensorflow.org";
      license = lib.licenses.asl20;
      maintainers = [ ];
      platforms = with lib.platforms; linux ++ darwin;
      broken =
        # Dependencies are EOL and have been removed; an update
        # to a newer TensorFlow version will be required to fix the
        # source build.
        (stdenv'.hostPlatform.isDarwin && cudaSupport)
        || !(xlaSupport -> cudaSupport)
        || !(cudaSupport -> builtins.hasAttr cudnnAttribute cudaPackages)
        || !(cudaSupport -> cudaPackages ? cudatoolkit);
    }
    // lib.optionalAttrs stdenv'.hostPlatform.isDarwin {
      timeout = 86400; # 24 hours
      maxSilent = 14400; # 4h, double the default of 7200s
    };
  };
in
buildPythonPackage {
  __structuredAttrs = true;
  inherit version pname format;

  src = bazel-build.python;

  # Adjust dependency requirements:
  # - Drop tensorflow-io dependency until we get it to build
  # - Relax flatbuffers and gast version requirements
  # - The purpose of python3Packages.libclang is not clear at the moment and we don't have it packaged yet
  # - keras will be considered as optional for now.
  postPatch = ''
    sed -i setup.py \
      -e '/tensorflow-io-gcs-filesystem/,+1d' \
      -e "s/'flatbuffers[^']*',/'flatbuffers',/" \
      -e "s/'gast[^']*',/'gast',/" \
      -e "/'libclang[^']*',/d" \
      -e "/'keras[^']*')\?,/d" \
      -e "s/'protobuf[^']*',/'protobuf',/"
  '';

  setupPyGlobalFlags = [
    "--project_name"
    pname
  ];

  # tensorflow/tools/pip_package/setup.py
  propagatedBuildInputs = [
    absl-py
    astunparse
    flatbuffers-python
    gast
    google-pasta
    libclang
    opt-einsum
    packaging
    protobuf-python
    setuptools
    six
    # tensorflow-estimator-bin
    termcolor
    typing-extensions
    wrapt
    keras
    numpy

    ml-dtypes
    h5py
  ]
  ++ lib.optionals stdenv'.hostPlatform.isLittleEndian [ grpcio ];

  nativeBuildInputs = lib.optionals cudaSupport [ addDriverRunpath ];

  postFixup = lib.optionalString cudaSupport ''
    find $out -type f \( -name '*.so' -or -name '*.so.*' \) | while read lib; do
      addDriverRunpath "$lib"

      patchelf --set-rpath "${cudatoolkit}/lib:${cudatoolkit.lib}/lib:${cudnnMerged}/lib:${lib.getLib nccl}/lib:$(patchelf --print-rpath "$lib")" "$lib"
    done
  '';

  # Actual tests are slow and impure.
  # TODO try to run them anyway
  # TODO better test (files in tensorflow/tools/ci_build/builds/*test)
  # TEST_PACKAGES in tensorflow/tools/pip_package/setup.py
  nativeCheckInputs = [
    dill
    portpicker
    tblib
  ];
  checkPhase = ''
    ${python.interpreter} <<EOF
    # A simple "Hello world"
    import tensorflow as tf
    hello = tf.constant("Hello, world!")
    tf.print(hello)

    tf.random.set_seed(0)
    width = 512
    choice = 48
    t_in = tf.Variable(tf.random.uniform(shape=[width]))
    with tf.GradientTape() as tape:
        t_out = tf.slice(tf.nn.softmax(t_in), [choice], [1])
    diff = tape.gradient(t_out, t_in)
    assert(0 < tf.reduce_min(tf.slice(diff, [choice], [1])))
    assert(0 > tf.reduce_max(tf.slice(diff, [1], [choice - 1])))
    EOF
  '';
  # Regression test for #77626 removed because not more `tensorflow.contrib`.

  passthru = {
    deps = bazel-build.deps;
    libtensorflow = bazel-build.out;
  };

  inherit (bazel-build) meta;
}
