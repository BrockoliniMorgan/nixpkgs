{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  rustPlatform,
}:

buildPythonPackage (finalAttrs: {
  pname = "ast-serialize";
  version = "0.12.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "mypyc";
    repo = "ast_serialize";
    tag = "v${finalAttrs.version}";
    hash = "sha256-SqnnNSSYN5WvwpmK1LIjByVHwTMZWUUUbpB4WugiMno=";
  };

  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) pname version src;
    hash = "sha256-MujdMrxSBPqFmrMbCr35CtVZcrq6+fR8ERhAFbXTYkI=";
  };

  build-system = [
    rustPlatform.cargoSetupHook
    rustPlatform.maturinBuildHook
  ];

  pythonImportsCheck = [
    "ast_serialize"
  ];

  meta = {
    description = "Fast Python parser that generates a serialized AST";
    homepage = "https://github.com/mypyc/ast_serialize";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ hexa ];
  };
})
