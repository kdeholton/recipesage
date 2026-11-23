# `nix run .#stack`: the whole docker-compose stack as plain processes on any
# Linux host (no NixOS, docker or root needed), supervised by process-compose.
#
# State lives in $RECIPESAGE_DATA (default: ./.recipesage). Secrets/overrides
# are read from $RECIPESAGE_DATA/.env if present (like compose's `env_file`).
{
  lib,
  writeShellApplication,
  writeText,
  formats,
  process-compose,
  postgresql_16,
  valkey,
  nginx,
  gnused,
  coreutils,
  server,
  frontend,
  pushpin,
}:

let
  pg = postgresql_16;

  nginxConf = writeText "recipesage-nginx.conf" ''
    daemon off;
    pid @DATA@/run/nginx.pid;
    error_log stderr info;
    events { worker_connections 1024; }
    http {
      include ${nginx}/conf/mime.types;
      default_type application/octet-stream;
      access_log /dev/stdout;
      client_body_temp_path @DATA@/run/nginx/body;
      proxy_temp_path @DATA@/run/nginx/proxy;
      fastcgi_temp_path @DATA@/run/nginx/fastcgi;
      uwsgi_temp_path @DATA@/run/nginx/uwsgi;
      scgi_temp_path @DATA@/run/nginx/scgi;
      sendfile on;
      gzip on;
      gzip_types text/css application/javascript application/json image/svg+xml;

      map $http_upgrade $connection_upgrade { default upgrade; "" close; }

      server {
        listen @HTTP_PORT@ default_server;
        client_max_body_size 1G;
        absolute_redirect off;

        location /grip/ws {
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
          proxy_connect_timeout 1h;
          proxy_send_timeout 1h;
          proxy_read_timeout 1h;
          proxy_pass http://127.0.0.1:7999/ws;
        }
        location /api/ { proxy_pass http://127.0.0.1:3000/; }
        location /app/api/ { proxy_pass http://127.0.0.1:3000/; }
        location = /manifest.json { alias ${frontend}/manifest.json; }
        location = /service-worker.js { alias ${frontend}/service-worker.js; }
        location = / { return 301 /app/$is_args$args; }
        location = /app { return 301 /app/$is_args$args; }
        location = /launch { return 301 /app/$is_args$args; }
        location = /app/index.html {
          alias ${frontend}/index.html;
          add_header Cache-Control no-cache;
        }
        location /app/ {
          alias ${frontend}/;
          try_files $uri $uri/ /app/index.html;
        }
      }
    }
  '';

  pushpinConf = writeText "pushpin.conf.in" (
    builtins.replaceStrings [ "sig_key=changeme" ] [ "sig_key=@GRIP_KEY@" ] (
      builtins.readFile "${pushpin}/etc/pushpin/pushpin.conf"
    )
  );

  processes = (formats.yaml { }).generate "process-compose.yaml" {
    version = "0.5";
    processes = {
      postgres = {
        command = "${pg}/bin/postgres -D \"$RECIPESAGE_DATA/postgres\" -k \"$RECIPESAGE_DATA/run\" -c listen_addresses=127.0.0.1 -c port=$RS_POSTGRES_PORT -c wal_level=logical";
        readiness_probe = {
          exec.command = "${pg}/bin/pg_isready -h \"$RECIPESAGE_DATA/run\" -p $RS_POSTGRES_PORT -d recipesage";
          initial_delay_seconds = 1;
          period_seconds = 2;
        };
        shutdown.signal = 2;
      };
      valkey = {
        command = "${valkey}/bin/valkey-server --bind 127.0.0.1 --port 6379 --dir \"$RECIPESAGE_DATA/valkey\"";
        readiness_probe = {
          exec.command = "${valkey}/bin/valkey-cli -p 6379 ping";
          period_seconds = 2;
        };
      };
      pushpin = {
        command = "${lib.getExe pushpin} --config \"$RECIPESAGE_DATA/run/pushpin.conf\" --merge-output";
      };
      migrate = {
        # scripts/selfhost-startup.sh, minus starting the API
        command = "${server}/bin/recipesage-prisma migrate deploy && ${server}/bin/recipesage-cli seed && ${server}/bin/recipesage-cli indexRecipes";
        depends_on.postgres.condition = "process_healthy";
        availability.restart = "no";
      };
      backend = {
        command = "${server}/bin/recipesage-backend";
        depends_on = {
          migrate.condition = "process_completed_successfully";
          valkey.condition = "process_healthy";
          pushpin.condition = "process_started";
        };
        availability.restart = "on_failure";
      };
      proxy = {
        command = "${nginx}/bin/nginx -e stderr -p \"$RECIPESAGE_DATA/run/nginx\" -c \"$RECIPESAGE_DATA/run/nginx.conf\"";
        depends_on.backend.condition = "process_started";
      };
    };
  };
in
writeShellApplication {
  name = "recipesage-stack";
  runtimeInputs = [
    pg
    gnused
    coreutils
    process-compose
  ];
  text = ''
    export RECIPESAGE_DATA="''${RECIPESAGE_DATA:-$PWD/.recipesage}"
    export RS_HTTP_PORT="''${RS_HTTP_PORT:-8080}"
    export RS_POSTGRES_PORT="''${RS_POSTGRES_PORT:-5432}"
    mkdir -p "$RECIPESAGE_DATA"/{run/nginx,valkey,media,logs}
    RECIPESAGE_DATA="$(realpath "$RECIPESAGE_DATA")"

    if [ -f "$RECIPESAGE_DATA/.env" ]; then
      set -a
      # shellcheck disable=SC1091
      . "$RECIPESAGE_DATA/.env"
      set +a
    fi

    if [ ! -s "$RECIPESAGE_DATA/postgres/PG_VERSION" ]; then
      echo "Initializing postgres in $RECIPESAGE_DATA/postgres"
      initdb -D "$RECIPESAGE_DATA/postgres" -U recipesage --auth=trust >/dev/null
      postgres -D "$RECIPESAGE_DATA/postgres" -k "$RECIPESAGE_DATA/run" \
        -c listen_addresses= -c port="$RS_POSTGRES_PORT" &
      pgpid=$!
      until pg_isready -q -h "$RECIPESAGE_DATA/run" -p "$RS_POSTGRES_PORT"; do sleep 0.5; done
      createdb -h "$RECIPESAGE_DATA/run" -p "$RS_POSTGRES_PORT" -U recipesage recipesage
      kill -INT "$pgpid"; wait "$pgpid" || true
    fi

    # Same environment as the compose file's x-common-env, in self-host mode.
    export NODE_ENV="''${NODE_ENV:-selfhost}"
    export ENVIRONMENT="''${ENVIRONMENT:-selfhost}"
    export LOG_LEVEL="''${LOG_LEVEL:-info}"
    export VERBOSE="''${VERBOSE:-false}"
    export PGHOST="$RECIPESAGE_DATA/run"
    export DATABASE_URL="''${DATABASE_URL:-postgresql://recipesage@localhost:$RS_POSTGRES_PORT/recipesage?host=$RECIPESAGE_DATA/run}"
    export DATABASE_SSL="''${DATABASE_SSL:-false}"
    export POSTGRES_LOGGING="''${POSTGRES_LOGGING:-false}"
    export STORAGE_TYPE="''${STORAGE_TYPE:-filesystem}"
    export FILESYSTEM_STORAGE_PATH="''${FILESYSTEM_STORAGE_PATH:-$RECIPESAGE_DATA/media}"
    export API_PUBLIC_BASE_URL="''${API_PUBLIC_BASE_URL:-http://localhost:$RS_HTTP_PORT/api}"
    export GRIP_URL="''${GRIP_URL:-http://127.0.0.1:5561/}"
    export GRIP_KEY="''${GRIP_KEY:-recipesage_selfhost}"
    export JOB_QUEUE_REDIS_HOST="''${JOB_QUEUE_REDIS_HOST:-127.0.0.1}"
    export GROCERY_CATEGORIZER_URL="''${GROCERY_CATEGORIZER_URL:-https://grocery-categorizer.recipesage.com/}"
    export STRIPE_SK="''${STRIPE_SK:-}" STRIPE_WEBHOOK_SECRET="''${STRIPE_WEBHOOK_SECRET:-}"
    export GCM_KEYPAIR="''${GCM_KEYPAIR:-}" SENTRY_DSN="''${SENTRY_DSN:-}"
    export AI_PROVIDER="''${AI_PROVIDER:-openrouter}"
    export AI_MODEL_WEBPAGE="''${AI_MODEL_WEBPAGE:-google/gemini-2.5-flash-lite}"
    export AI_MODEL_TEXT="''${AI_MODEL_TEXT:-google/gemini-2.5-flash-lite}"
    export AI_MODEL_OCR="''${AI_MODEL_OCR:-google/gemini-2.5-flash}"
    export AI_MODEL_DOCUMENT="''${AI_MODEL_DOCUMENT:-google/gemini-2.5-flash}"
    export AI_MODEL_MODERATION="''${AI_MODEL_MODERATION:-google/gemini-2.5-flash}"
    export AI_MODEL_VISION="''${AI_MODEL_VISION:-anthropic/claude-sonnet-4.6}"
    export AI_MODEL_NUTRITION="''${AI_MODEL_NUTRITION:-google/gemini-2.5-flash-lite}"
    export AI_MODEL_ASSISTANT="''${AI_MODEL_ASSISTANT:-anthropic/claude-sonnet-4.6}"
    export AI_MODEL_ASSISTANT_LOW="''${AI_MODEL_ASSISTANT_LOW:-google/gemini-2.5-flash}"

    # Render configs that need runtime values.
    # pushpin's IPC socket paths must stay short (unix socket path limit).
    pushpin_run="''${XDG_RUNTIME_DIR:-/tmp}/recipesage-pushpin-$(id -u)"
    mkdir -p "$pushpin_run"
    sed -e "s|@GRIP_KEY@|$GRIP_KEY|" \
        -e "s|^rundir=.*|rundir=$pushpin_run|" \
        -e "s|^routesfile=.*|routesfile=$RECIPESAGE_DATA/run/pushpin-routes|" \
        ${pushpinConf} > "$RECIPESAGE_DATA/run/pushpin.conf"
    echo "* 127.0.0.1:3000,over_http" > "$RECIPESAGE_DATA/run/pushpin-routes"
    sed -e "s|@DATA@|$RECIPESAGE_DATA|g" -e "s|@HTTP_PORT@|$RS_HTTP_PORT|g" \
        ${nginxConf} > "$RECIPESAGE_DATA/run/nginx.conf"

    echo "RecipeSage will be available at http://localhost:$RS_HTTP_PORT/"
    exec process-compose up --config ${processes} --port "''${PC_PORT:-8079}" "$@"
  '';
}
