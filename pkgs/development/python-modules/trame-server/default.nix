{
  buildPythonPackage,
  fetchFromGitHub,
  lib,
  setuptools,
  wslink,
  more-itertools,
}:

buildPythonPackage (finalAttrs: {
  name = "trame-server";
  version = "3.10.0";
  src = fetchFromGitHub {
    owner = "Kitware";
    repo = "trame-server";
    tag = "v${finalAttrs.version}";
    hash = "sha256-M3UQYJlo539y3M0LyxkHeQJgpVt+AkSXyjpVpukdV8w=";
  };
  pyproject = true;
  build-system = [
    setuptools
  ];
  propagatedBuildInputs = [
    wslink
    more-itertools
  ];
  meta = {
    description = "Internal server side implementation of trame";
    homepage = "https://github.com/kitware/trame-server";
    maintainers = with lib.maintainers; [ BrockoliniMorgan ];
    license = lib.licenses.asl20;
  };
})
