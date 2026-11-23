# grocery-categorizer: the ML service RecipeSage uses to sort shopping-list
# items into aisles. Replaces the `julianpoy/grocery-categorizer` image.
#
# The ~330 MB int8 ONNX model (`aisle_model_onnx/`) is NOT in the git repo; it
# is produced by upstream's training pipeline and shipped only inside the docker
# image. Point `services.recipesage.groceryCategorizer.modelDir` at a copy of it,
# e.g. extracted with:
#   docker create --name gc julianpoy/grocery-categorizer:f9d9562
#   docker cp gc:/app/aisle_model_onnx ./aisle_model_onnx
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  python3,
  makeWrapper,
}:

let
  python = python3.withPackages (
    ps: with ps; [
      onnxruntime
      tokenizers
      numpy
      fastapi
      uvicorn
      pydantic
    ]
    ++ uvicorn.optional-dependencies.standard
  );
in
stdenvNoCC.mkDerivation {
  pname = "grocery-categorizer";
  version = "0-unstable-f9d9562";

  src = fetchFromGitHub {
    owner = "julianpoy";
    repo = "grocery-categorizer";
    rev = "f9d9562c7aad5d3fd87af28d34adbe4bc49038d9";
    hash = "sha256-Coxd5ZVNG/nlFne7ojIpv2NwNTFKFhzNNqmwmdfKO/E=";
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    app=$out/share/grocery-categorizer
    install -Dm644 -t $app server.py inference_onnx.py text_norm.py aisle_map.py LICENSE NOTICE
    # server.py loads the model from ./aisle_model_onnx, so the wrapper expects
    # to be started in a directory that contains it (the module sets this up).
    makeWrapper ${python.interpreter} $out/bin/grocery-categorizer \
      --prefix PYTHONPATH : $app \
      --add-flags "$app/server.py"
    runHook postInstall
  '';

  passthru = { inherit python; };

  meta = {
    description = "Grocery item aisle categorization API used by RecipeSage";
    homepage = "https://github.com/julianpoy/grocery-categorizer";
    license = lib.licenses.agpl3Only;
    mainProgram = "grocery-categorizer";
  };
}
