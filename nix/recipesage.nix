# RecipeSage application packages, built from the upstream pnpm/nx monorepo.
#
# Mirrors what the upstream Dockerfiles do:
#   - production.Dockerfile  -> `server`   (backend, queue-worker, cli)
#   - frontend selfhost build -> `frontend` (static Angular/Ionic PWA)
#   - packages/www (astro)    -> `www`      (static marketing site)
#
# All three share a single fixed-output pnpm store (`pnpmDeps`).
{
  lib,
  stdenv,
  src,
  version,
  pnpmDepsHash,
  nodejs_26,
  nodejs-slim_26,
  pnpm_10,
  fetchPnpmDeps,
  pnpmConfigHook,
  makeWrapper,
  prisma-engines_7,
  openssl,
  mdbtools,
  poppler-utils,
  pandoc,
  libheif,
}:

let
  nodejs = nodejs_26;
  pnpm = pnpm_10.override { nodejs-slim = nodejs-slim_26; };

  pnpmDeps = fetchPnpmDeps {
    pname = "recipesage";
    inherit version src pnpm;
    fetcherVersion = 5;
    hash = pnpmDepsHash;
  };

  # Runtime tools the API shells out to (see Dockerfile `apk add` lines).
  runtimeTools = [
    openssl
    mdbtools
    poppler-utils # pdftotext
    pandoc
    libheif # heif-convert
  ];

  commonEnv = {
    CI = "true";
    HUSKY = "0";
    NX_DAEMON = "false";
    NX_NO_CLOUD = "true";
    NX_SKIP_NX_CACHE = "true";
    NX_TUI = "false";
    # nx's run-commands executor wants a pseudo terminal, which the sandbox lacks.
    NX_NATIVE_COMMAND_RUNNER = "false";
    NX_ISOLATE_PLUGINS = "false";
    NG_CLI_ANALYTICS = "false";
    ASTRO_TELEMETRY_DISABLED = "1";
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
    SENTRYCLI_SKIP_DOWNLOAD = "1";
    PRISMA_SCHEMA_ENGINE_BINARY = "${prisma-engines_7}/bin/schema-engine";
    PRISMA_ENGINES_CHECKSUM_IGNORE_MISSING = "1";
    NODE_OPTIONS = "--max-old-space-size=6144";
    APP_VERSION = version;
    VERSION = version;
  };

  mkPnpmBuild =
    args:
    stdenv.mkDerivation (
      {
        inherit version src pnpmDeps;
        nativeBuildInputs = [
          nodejs
          pnpm
          pnpmConfigHook
        ]
        ++ (args.nativeBuildInputs or [ ]);
        env = commonEnv // (args.env or { });
        # Everything here is JS/static assets; nothing to strip.
        dontStrip = true;
        # sass-embedded ships a prebuilt Dart VM that expects /lib64/ld-linux.
        preBuild = ''
          for f in node_modules/.pnpm/sass-embedded-linux-*/node_modules/sass-embedded-linux-*/dart-sass/src/dart; do
            [ -e "$f" ] || continue
            patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
              --set-rpath ${lib.makeLibraryPath [ stdenv.cc.libc ]} "$f"
          done
        '';
      }
      // removeAttrs args [
        "nativeBuildInputs"
        "env"
      ]
    );

  server = mkPnpmBuild {
    pname = "recipesage-server";

    nativeBuildInputs = [ makeWrapper ];
    # Note: no autoPatchelf. sharp's prebuilt libvips segfaults once patchelf
    # rewrites it, and it doesn't need patching anyway: it only links glibc,
    # libstdc++ and libgcc_s, which the nix-built node has already loaded.

    buildPhase = ''
      runHook preBuild

      # Prisma must be generated since the postinstall script was skipped.
      pnpm exec prisma generate

      pnpm exec nx run-many -t build -p backend,queue-worker,cli \
        --parallel=1 --output-style=static

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      app=$out/lib/recipesage
      mkdir -p $app $out/bin

      # Keep the full node_modules, like production.Dockerfile does: the
      # bundles require some devDependencies (e.g. @faker-js/faker) at runtime.
      rm -rf node_modules/.cache

      cp -r dist node_modules package.json prisma.config.ts fonts LICENSE.md $app/
      mkdir -p $app/packages/prisma/src $app/packages/frontend/src/assets
      cp -r packages/prisma/src/prisma $app/packages/prisma/src/
      cp -r packages/frontend/src/assets/i18n $app/packages/frontend/src/assets/

      wrap() {
        makeWrapper ${lib.getExe nodejs} "$out/bin/$1" \
          --chdir "$app" \
          --prefix PATH : ${lib.makeBinPath runtimeTools} \
          --set-default NODE_ENV selfhost \
          --set-default ENVIRONMENT selfhost \
          --set-default VERSION ${version} \
          --set-default FONTS_PATH "$app/fonts" \
          --set-default EXPRESS_VIEWS_PATH "$app/dist/apps/backend/views" \
          --set-default FRONTEND_I18N_PATH "$app/packages/frontend/src/assets/i18n" \
          --set-default JOB_QUEUE_WORKER_PATH "$app/dist/apps/queue-worker/worker.cjs" \
          --set PRISMA_SCHEMA_ENGINE_BINARY ${prisma-engines_7}/bin/schema-engine \
          --add-flags "$2"
      }

      wrap recipesage-backend "$app/dist/apps/backend/main.cjs"
      wrap recipesage-queue-worker "$app/dist/apps/queue-worker/main.cjs"
      wrap recipesage-cli "$app/dist/apps/cli/main.cjs"
      # `recipesage-prisma migrate deploy` == upstream `pnpm exec prisma migrate deploy`
      wrap recipesage-prisma "$app/node_modules/prisma/build/index.js"

      runHook postInstall
    '';

    passthru = { inherit pnpmDeps nodejs pnpm; };

    meta = {
      description = "RecipeSage API, queue worker and CLI";
      homepage = "https://github.com/julianpoy/recipesage";
      license = lib.licenses.agpl3Only;
      mainProgram = "recipesage-backend";
      platforms = lib.platforms.linux;
    };
  };

  frontend = mkPnpmBuild {
    pname = "recipesage-frontend";

    env.ENVIRONMENT = "production";

    buildPhase = ''
      runHook preBuild
      # Steps of the `frontend:build:selfhost` nx target, run directly.
      export PATH=$PWD/node_modules/.bin:$PATH
      pushd packages/frontend
      tsx build-service-worker.ts
      ng build --configuration=selfhost
      workbox injectManifest
      cp ../../LICENSE.md www/LICENSE.md
      popd
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      sed -i 's/window.version = "development";/window.version = "${version}";/' \
        packages/frontend/www/index.html
      cp -r packages/frontend/www $out
      runHook postInstall
    '';

    meta = {
      description = "RecipeSage web app (self-host build, static files)";
      homepage = "https://github.com/julianpoy/recipesage";
      license = lib.licenses.agpl3Only;
      platforms = lib.platforms.all;
    };
  };

  www = mkPnpmBuild {
    pname = "recipesage-www";

    buildPhase = ''
      runHook preBuild
      export PATH=$PWD/node_modules/.bin:$PATH
      (cd packages/www && astro build)
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp -r packages/www/dist $out
      runHook postInstall
    '';

    meta = {
      description = "RecipeSage marketing site (static files)";
      homepage = "https://github.com/julianpoy/recipesage";
      license = lib.licenses.agpl3Only;
      platforms = lib.platforms.all;
    };
  };
in
{
  inherit
    server
    frontend
    www
    pnpmDeps
    ;
}
