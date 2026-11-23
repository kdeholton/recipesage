# NixOS module that runs the whole RecipeSage stack on bare metal, without
# docker. Each docker-compose service maps to a native NixOS service:
#
#   compose service      -> here
#   -------------------     ---------------------------------------------------
#   postgres             -> services.postgresql (wal_level=logical)
#   valkey               -> services.redis.servers.recipesage (valkey package)
#   pushpin              -> systemd.services.recipesage-pushpin
#   backend              -> systemd.services.recipesage-backend
#   queue-worker         -> systemd.services.recipesage-queue-worker (optional)
#   grocery-categorizer  -> systemd.services.recipesage-grocery-categorizer
#                           (optional; uses the public API by default)
#   frontend             -> static files served by nginx
#   www                  -> static files served by nginx (optional)
#   proxy                -> services.nginx virtual host
#
# The settings follow upstream's self-host stack
# (github.com/julianpoy/recipesage-selfhost): NODE_ENV=selfhost, filesystem
# image storage, and the frontend's `build:selfhost` configuration.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.recipesage;
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    mkDefault
    types
    literalExpression
    optional
    optionalAttrs
    optionalString
    ;

  system = pkgs.stdenv.hostPlatform.system;
  defaultPkgs = self.packages.${system};

  dbUrl =
    if cfg.database.createLocally then
      "postgresql://${cfg.database.user}@localhost/${cfg.database.name}?host=/run/postgresql"
    else
      null;

  # Environment shared by the API, queue worker and CLI.
  appEnv = {
    NODE_ENV = "selfhost";
    ENVIRONMENT = "selfhost";
    VERSION = cfg.package.version;
    LOG_LEVEL = "info";
    VERBOSE = "false";
    PORT = toString cfg.port;
    API_PUBLIC_BASE_URL = cfg.publicUrl + "/api";
    STORAGE_TYPE = "filesystem";
    FILESYSTEM_STORAGE_PATH = cfg.mediaDir;
    POSTGRES_LOGGING = "false";
    DATABASE_SSL = "false";
    GRIP_URL = "http://127.0.0.1:${toString cfg.pushpin.controlPort}/";
    GRIP_KEY = "recipesage_selfhost"; # override via environmentFile
    JOB_QUEUE_REDIS_HOST = "127.0.0.1";
    JOB_QUEUE_REDIS_PORT = toString cfg.redis.port;
    GROCERY_CATEGORIZER_URL =
      if cfg.groceryCategorizer.enable then
        "http://127.0.0.1:${toString cfg.groceryCategorizer.port}/"
      else
        cfg.groceryCategorizer.url;
    MALLOC_ARENA_MAX = "2";
    # Values that must be empty for self-hosting (see recipesage-selfhost).
    STRIPE_SK = "";
    STRIPE_WEBHOOK_SECRET = "";
    GCM_KEYPAIR = "";
    SENTRY_DSN = "";
    AI_PROVIDER = "openrouter";
    AI_MODEL_WEBPAGE = "google/gemini-2.5-flash-lite";
    AI_MODEL_TEXT = "google/gemini-2.5-flash-lite";
    AI_MODEL_OCR = "google/gemini-2.5-flash";
    AI_MODEL_DOCUMENT = "google/gemini-2.5-flash";
    AI_MODEL_MODERATION = "google/gemini-2.5-flash";
    AI_MODEL_VISION = "anthropic/claude-sonnet-4.6";
    AI_MODEL_NUTRITION = "google/gemini-2.5-flash-lite";
    AI_MODEL_ASSISTANT = "anthropic/claude-sonnet-4.6";
    AI_MODEL_ASSISTANT_LOW = "google/gemini-2.5-flash";
  }
  // optionalAttrs (dbUrl != null) { DATABASE_URL = dbUrl; }
  // optionalAttrs cfg.disableRegistration { DISABLE_REGISTRATION = "true"; }
  // cfg.settings;

  envFiles = optional (cfg.environmentFile != null) cfg.environmentFile;

  serviceHardening = {
    User = cfg.user;
    Group = cfg.group;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
  };

  dbDeps =
    optional cfg.database.createLocally "postgresql.service"
    ++ [ "redis-recipesage.service" ];

  # `recipesage-cli <command>` on the host, with the service's environment.
  manageScript = pkgs.writeShellScriptBin "recipesage-manage" ''
    set -a
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "${k}=${lib.escapeShellArg v}") appEnv
    )}
    ${lib.concatMapStringsSep "\n" (f: "[ -r ${f} ] && . ${f}") envFiles}
    set +a
    cmd=''${1:-}
    if [ "$cmd" = prisma ]; then shift; exec ${cfg.package}/bin/recipesage-prisma "$@"; fi
    exec ${cfg.package}/bin/recipesage-cli "$@"
  '';

  pushpinRoutes = pkgs.writeText "pushpin-routes" ''
    * 127.0.0.1:${toString cfg.port},over_http
  '';

  # Rendered at runtime so the GRIP_KEY can come from environmentFile.
  pushpinConfTemplate = pkgs.runCommand "pushpin.conf.in" { } ''
    sed \
      -e 's|^rundir=.*|rundir=/run/recipesage-pushpin|' \
      -e 's|^routesfile=.*|routesfile=${pushpinRoutes}|' \
      -e 's|^http_port=.*|http_port=${toString cfg.pushpin.port}|' \
      -e 's|^push_in_http_port=.*|push_in_http_port=${toString cfg.pushpin.controlPort}|' \
      -e 's|^sig_key=.*|sig_key=@GRIP_KEY@|' \
      ${cfg.pushpin.package}/etc/pushpin/pushpin.conf > $out
  '';
in
{
  options.services.recipesage = {
    enable = mkEnableOption "RecipeSage, a recipe keeper, meal planner and shopping list manager";

    package = mkOption {
      type = types.package;
      default = defaultPkgs.recipesage-server;
      defaultText = literalExpression "recipesage.packages.\${system}.recipesage-server";
      description = "Package providing the API, queue worker and CLI.";
    };

    frontendPackage = mkOption {
      type = types.package;
      default = defaultPkgs.recipesage-frontend;
      defaultText = literalExpression "recipesage.packages.\${system}.recipesage-frontend";
      description = "Static web app files (self-host build).";
    };

    hostName = mkOption {
      type = types.str;
      example = "recipes.example.com";
      description = "Host name of the nginx virtual host serving RecipeSage.";
    };

    publicUrl = mkOption {
      type = types.str;
      default = "https://${cfg.hostName}";
      defaultText = literalExpression ''"https://''${config.services.recipesage.hostName}"'';
      description = ''
        Public base URL users reach RecipeSage on, without trailing slash.
        `API_PUBLIC_BASE_URL` is set to this plus `/api`.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 3000;
      description = "Local port the API listens on.";
    };

    backendMemoryMB = mkOption {
      type = types.ints.positive;
      default = 400;
      description = "Node heap limit (MB) for the API, as in the self-host compose file.";
    };

    user = mkOption {
      type = types.str;
      default = "recipesage";
      description = "User the RecipeSage services run as.";
    };

    group = mkOption {
      type = types.str;
      default = "recipesage";
      description = "Group the RecipeSage services run as.";
    };

    mediaDir = mkOption {
      type = types.path;
      default = "/var/lib/recipesage/media";
      description = "Where uploaded images and files are stored (STORAGE_TYPE=filesystem).";
    };

    disableRegistration = mkOption {
      type = types.bool;
      default = false;
      description = "Prevent new accounts from being created.";
    };

    settings = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = literalExpression ''
        {
          AI_MODEL_ASSISTANT = "anthropic/claude-sonnet-4.6";
          TRUST_PROXY_HOPS = "1";
        }
      '';
      description = ''
        Extra (non-secret) environment variables for the API, queue worker and
        CLI. These override the module defaults. See upstream `example.env` and
        the recipesage-selfhost docker-compose.yml for available variables.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/recipesage.env";
      description = ''
        File with secret environment variables, in systemd `EnvironmentFile`
        format, e.g.:

            GRIP_KEY=some-long-random-string
            AI_API_KEY=sk-or-...
            SCRAPFLY_API_KEY=...

        `GRIP_KEY` set here is also used for pushpin's `sig_key`.
        Use `DATABASE_URL` here when `database.createLocally = false`.
      '';
    };

    database = {
      createLocally = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Create a local PostgreSQL database, reached through the unix socket
          with peer authentication. If false, set `DATABASE_URL` via
          `environmentFile`.
        '';
      };
      name = mkOption {
        type = types.str;
        default = "recipesage";
        description = "Database name.";
      };
      user = mkOption {
        type = types.str;
        default = cfg.user;
        defaultText = literalExpression "config.services.recipesage.user";
        description = "Database user; must match the service user for peer auth.";
      };
    };

    redis.port = mkOption {
      type = types.port;
      default = 6379;
      description = "Port of the local valkey (redis) instance used for the job queue.";
    };

    pushpin = {
      package = mkOption {
        type = types.package;
        default = defaultPkgs.pushpin;
        defaultText = literalExpression "recipesage.packages.\${system}.pushpin";
        description = "Pushpin package (websocket/GRIP proxy).";
      };
      port = mkOption {
        type = types.port;
        default = 7999;
        description = "Port pushpin serves client (websocket) traffic on.";
      };
      controlPort = mkOption {
        type = types.port;
        default = 5561;
        description = "Port of pushpin's HTTP publish/control endpoint (GRIP_URL).";
      };
    };

    queueWorker.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run the job queue worker as its own service, like the `queue-worker`
        compose service. In self-host mode the API already processes jobs
        in-process, so this only adds extra job capacity.
      '';
    };

    groceryCategorizer = {
      enable = mkEnableOption "a local grocery-categorizer ML service (needs AVX and ~1 GB RAM)";
      package = mkOption {
        type = types.package;
        default = defaultPkgs.grocery-categorizer;
        defaultText = literalExpression "recipesage.packages.\${system}.grocery-categorizer";
        description = "grocery-categorizer package.";
      };
      modelDir = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/var/lib/grocery-categorizer/aisle_model_onnx";
        description = ''
          Path to the `aisle_model_onnx` directory (not in upstream's git repo;
          copy it out of the `julianpoy/grocery-categorizer` docker image).
        '';
      };
      port = mkOption {
        type = types.port;
        default = 8000;
        description = "Local port for the grocery-categorizer API.";
      };
      threads = mkOption {
        type = types.ints.positive;
        default = 4;
        description = "OMP_NUM_THREADS for onnxruntime.";
      };
      url = mkOption {
        type = types.str;
        default = "https://grocery-categorizer.recipesage.com/";
        description = "Grocery categorizer URL used when the local service is disabled.";
      };
    };

    www = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Serve the RecipeSage marketing site (the `www` compose service) at
          `/`. When disabled, `/` redirects to the app at `/app/`, like the
          self-host proxy.
        '';
      };
      package = mkOption {
        type = types.package;
        default = defaultPkgs.recipesage-www;
        defaultText = literalExpression "recipesage.packages.\${system}.recipesage-www";
        description = "Static marketing site files.";
      };
    };

    nginx = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Configure an nginx virtual host (replaces the compose `proxy` service).";
      };
      maxBodySize = mkOption {
        type = types.str;
        default = "1G";
        description = "nginx client_max_body_size (imports can be large).";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.groceryCategorizer.enable || cfg.groceryCategorizer.modelDir != null;
        message = "services.recipesage.groceryCategorizer.modelDir must be set when the local grocery-categorizer is enabled.";
      }
      {
        assertion = cfg.database.createLocally || cfg.environmentFile != null;
        message = "services.recipesage: with database.createLocally = false, provide DATABASE_URL in environmentFile.";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/lib/recipesage";
    };
    users.groups.${cfg.group} = { };

    environment.systemPackages = [ manageScript ];

    systemd.tmpfiles.settings."10-recipesage".${cfg.mediaDir}.d = {
      user = cfg.user;
      group = cfg.group;
      mode = "0750";
    };

    # --- postgres ------------------------------------------------------------
    services.postgresql = mkIf cfg.database.createLocally {
      enable = true;
      settings.wal_level = "logical";
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = cfg.database.user == cfg.database.name;
        }
      ];
    };

    # ensureDBOwnership needs user == db name; handle the other case too.
    systemd.services.postgresql-setup.postStart = mkIf (
      cfg.database.createLocally && cfg.database.user != cfg.database.name
    ) ''
      psql -tAc 'ALTER DATABASE "${cfg.database.name}" OWNER TO "${cfg.database.user}";'
    '';

    # --- valkey --------------------------------------------------------------
    services.redis.package = mkDefault pkgs.valkey;
    services.redis.servers.recipesage = {
      enable = true;
      bind = "127.0.0.1";
      port = cfg.redis.port;
    };

    # --- pushpin -------------------------------------------------------------
    systemd.services.recipesage-pushpin = {
      description = "Pushpin realtime proxy for RecipeSage";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment.GRIP_KEY = appEnv.GRIP_KEY;
      script = ''
        conf=$RUNTIME_DIRECTORY/pushpin.conf
        sed "s|@GRIP_KEY@|$GRIP_KEY|" ${pushpinConfTemplate} > "$conf"
        exec ${lib.getExe cfg.pushpin.package} --config "$conf" --merge-output
      '';
      serviceConfig = serviceHardening // {
        EnvironmentFile = envFiles;
        RuntimeDirectory = "recipesage-pushpin";
        RuntimeDirectoryMode = "0700";
        Restart = "on-failure";
      };
    };

    # --- backend (API) -------------------------------------------------------
    systemd.services.recipesage-backend = {
      description = "RecipeSage API";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ] ++ dbDeps ++ [ "recipesage-pushpin.service" ];
      requires = dbDeps;
      wants = [ "recipesage-pushpin.service" ];
      environment = appEnv // {
        NODE_OPTIONS = "--max-old-space-size=${toString cfg.backendMemoryMB}";
      };
      # Same as upstream scripts/selfhost-startup.sh
      preStart = ''
        echo "==== Running migrations ===="
        ${cfg.package}/bin/recipesage-prisma migrate deploy
        echo "==== Running database seeders ===="
        ${cfg.package}/bin/recipesage-cli seed
        echo "==== Rebuilding search index ===="
        ${cfg.package}/bin/recipesage-cli indexRecipes
      '';
      serviceConfig = serviceHardening // {
        ExecStart = "${cfg.package}/bin/recipesage-backend";
        EnvironmentFile = envFiles;
        StateDirectory = "recipesage";
        StateDirectoryMode = "0750";
        ReadWritePaths = [ cfg.mediaDir ];
        WorkingDirectory = "/var/lib/recipesage";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStartSec = "15min"; # first-boot migrations + indexing
      };
    };

    # --- queue worker --------------------------------------------------------
    systemd.services.recipesage-queue-worker = mkIf cfg.queueWorker.enable {
      description = "RecipeSage job queue worker";
      wantedBy = [ "multi-user.target" ];
      after = [ "recipesage-backend.service" ] ++ dbDeps;
      requires = dbDeps;
      environment = appEnv // {
        PORT = "3001";
        NODE_OPTIONS = "--max-old-space-size=2000";
      };
      serviceConfig = serviceHardening // {
        ExecStart = "${cfg.package}/bin/recipesage-queue-worker";
        EnvironmentFile = envFiles;
        StateDirectory = "recipesage";
        ReadWritePaths = [ cfg.mediaDir ];
        WorkingDirectory = "/var/lib/recipesage";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # --- grocery categorizer -------------------------------------------------
    systemd.services.recipesage-grocery-categorizer = mkIf cfg.groceryCategorizer.enable {
      description = "RecipeSage grocery categorizer";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      before = [ "recipesage-backend.service" ];
      environment.OMP_NUM_THREADS = toString cfg.groceryCategorizer.threads;
      preStart = ''
        ln -sfn ${toString cfg.groceryCategorizer.modelDir} "$STATE_DIRECTORY/aisle_model_onnx"
      '';
      serviceConfig = serviceHardening // {
        ExecStart = "${lib.getExe cfg.groceryCategorizer.package} --host 127.0.0.1 --port ${toString cfg.groceryCategorizer.port}";
        DynamicUser = true;
        User = "recipesage-grocery";
        Group = "recipesage-grocery";
        StateDirectory = "recipesage-grocery-categorizer";
        WorkingDirectory = "/var/lib/recipesage-grocery-categorizer";
        Restart = "on-failure";
      };
    };

    # --- nginx (proxy) -------------------------------------------------------
    # Equivalent of recipesage-selfhost's proxy.conf.
    services.nginx = mkIf cfg.nginx.enable {
      enable = true;
      recommendedProxySettings = mkDefault true;
      recommendedGzipSettings = mkDefault true;
      virtualHosts.${cfg.hostName} = {
        extraConfig = ''
          client_max_body_size ${cfg.nginx.maxBodySize};
          absolute_redirect off;
        '';
        locations = {
          "/grip/ws" = {
            proxyPass = "http://127.0.0.1:${toString cfg.pushpin.port}/ws";
            proxyWebsockets = true;
            extraConfig = ''
              proxy_connect_timeout 1h;
              proxy_send_timeout 1h;
              proxy_read_timeout 1h;
            '';
          };
          "/api/".proxyPass = "http://127.0.0.1:${toString cfg.port}/";
          # Filesystem image URLs are relative, so browsers resolve them under /app/
          "/app/api/".proxyPass = "http://127.0.0.1:${toString cfg.port}/";
          "= /manifest.json".alias = "${cfg.frontendPackage}/manifest.json";
          "= /service-worker.js".alias = "${cfg.frontendPackage}/service-worker.js";
          "= /app".return = "301 /app/$is_args$args";
          "= /launch".return = "301 /app/$is_args$args";
          "/app/" = {
            alias = "${cfg.frontendPackage}/";
            tryFiles = "$uri $uri/ /app/index.html";
          };
          "= /app/index.html" = {
            alias = "${cfg.frontendPackage}/index.html";
            extraConfig = "add_header Cache-Control no-cache;";
          };
        }
        // (
          if cfg.www.enable then
            {
              "/" = {
                root = cfg.www.package;
                tryFiles = "$uri $uri/ $uri.html =404";
              };
            }
          else
            {
              # PWA share_target sends users to "/" with query params; keep them.
              "= /".return = "301 /app/$is_args$args";
            }
        );
      };
    };
  };

}
