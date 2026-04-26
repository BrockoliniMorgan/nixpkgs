{
  buildPythonPackage,
  fetchFromGitHub,
  lib,
  hatchling,
  trame-client,
}:

buildPythonPackage (finalAttrs: {
  name = "trame-vtk";
  version = "2.11.8";
  src = fetchFromGitHub {
    owner = "Kitware";
    repo = "trame-vtk";
    tag = "v${finalAttrs.version}";
    hash = "sha256-cNBHQS1nakRnFDbFLMwVEUzQj4zipY/z/5awuObMJJM=";
  };
  pyproject = true;
  build-system = [
    hatchling
  ];
  propagatedBuildInputs = [
    trame-client
  ];
  meta = {
    description = "VTK/ParaView widgets for trame";
    homepage = "https://github.com/kitware/trame-vtk";
    maintainers = with lib.maintainers; [ BrockoliniMorgan ];
    license = lib.licenses.bsd3;
  };
})
