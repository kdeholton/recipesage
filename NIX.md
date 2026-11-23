# Running RecipeSage with Nix (no docker)

`flake.nix` builds RecipeSage from source and runs it and everything it
depends on as native processes. It follows upstream's `docker-compose.yml`,
with the production settings from
[recipesage-selfhost](https://github.com/julianpoy/recipesage-selfhost)
(`NODE_ENV=selfhost`, images stored on the local filesystem, the frontend's
`build:selfhost` build).

| compose service       | Nix replacement                                                             |
| --------------------- | --------------------------------------------------------------------------- |
| `postgres`            | PostgreSQL with `wal_level=logical`                                         |
| `valkey`              | valkey                                                                      |
| `pushpin`             | `packages.pushpin`, built from source (it isn't in nixpkgs)                 |
| `backend`             | `packages.recipesage-server` → `recipesage-backend`                         |
| `queue-worker`        | `recipesage-queue-worker` (optional; the self-host API already runs jobs)   |
| `grocery-categorizer` | `packages.grocery-categorizer` (optional; uses the public API by default)   |
| `frontend`            | `packages.recipesage-frontend` (static files)                               |
| `www`                 | `packages.recipesage-www` (static files, optional)                          |
| `proxy`               | nginx                                                                       |

The upstream source comes from the `recipesage-src` flake input, pinned to
`v4.1.6`.

## Option 1: NixOS module

```nix
# flake.nix of your NixOS host
{
  inputs.recipesage.url = "github:kdeholton/recipesage/<branch>";

  outputs = { nixpkgs, recipesage, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        recipesage.nixosModules.default
        {
          services.recipesage = {
            enable = true;
            hostName = "recipes.example.com";
            # publicUrl defaults to https://<hostName>
            environmentFile = "/run/secrets/recipesage.env";
          };
          # TLS (optional)
          services.nginx.virtualHosts."recipes.example.com" = {
            enableACME = true;
            forceSSL = true;
          };
          security.acme = { acceptTerms = true; defaults.email = "you@example.com"; };
          networking.firewall.allowedTCPPorts = [ 80 443 ];
        }
      ];
    };
  };
}
```

`/run/secrets/recipesage.env` (systemd `EnvironmentFile` format, kept out of
the Nix store):

```
GRIP_KEY=<long random string>   # shared with pushpin
AI_API_KEY=<openrouter key>     # optional, for AI features
SCRAPFLY_API_KEY=               # optional
```

The module sets up:

- `postgresql.service`: database `recipesage`, peer auth over the unix socket
- `redis-recipesage.service`: valkey on 127.0.0.1:6379
- `recipesage-pushpin.service`: ports 7999 (clients) and 5561 (GRIP control)
- `recipesage-backend.service`: API on 127.0.0.1:3000. Before it starts, it
  runs `prisma migrate deploy`, `seed` and `indexRecipes`, the same steps as
  upstream's `scripts/selfhost-startup.sh`.
- An nginx vhost with the same routes as the self-host proxy (`/app/`,
  `/api/`, `/grip/ws`, …)
- `recipesage-manage`: runs the RecipeSage CLI (or `recipesage-manage prisma
  …`) with the service's environment. Run it as the `recipesage` user, e.g.
  `sudo -u recipesage recipesage-manage indexRecipes`.

Useful options (see `nix/module.nix` for the full list):

```nix
services.recipesage = {
  settings = { TRUST_PROXY_HOPS = "1"; AI_MODEL_ASSISTANT = "..."; }; # extra env vars
  disableRegistration = true;
  mediaDir = "/srv/recipesage-media";
  queueWorker.enable = true;          # separate worker, like compose's queue-worker
  www.enable = true;                  # serve the marketing site at /
  database.createLocally = false;     # then put DATABASE_URL in environmentFile
  groceryCategorizer = {
    enable = true;                    # needs AVX and about 1 GB of RAM
    modelDir = "/var/lib/aisle_model_onnx";
  };
};
```

The grocery-categorizer model (`aisle_model_onnx`, about 330 MB) is not in
upstream's git repo. You can copy it out of the published image once:

```sh
docker create --name gc julianpoy/grocery-categorizer:f9d9562
docker cp gc:/app/aisle_model_onnx ./aisle_model_onnx && docker rm gc
```

## Option 2: `nix run` on any Linux host

This runs the whole stack as an unprivileged user, supervised by
process-compose. It doesn't need NixOS, root or docker:

```sh
nix run github:kdeholton/recipesage/<branch>#stack
# → http://localhost:8080/
```

- State (postgres, valkey, uploaded media) goes in `$RECIPESAGE_DATA`, which
  defaults to `./.recipesage`.
- Secrets and overrides are read from `$RECIPESAGE_DATA/.env`, like compose's
  `env_file`.
- `RS_HTTP_PORT` (default 8080) and `RS_POSTGRES_PORT` (default 5432) set the
  ports, matching the compose file's variables.
- Extra arguments go to `process-compose up`. For example, `-t=false` turns
  off the TUI.

## Building individual pieces

```sh
nix build .#recipesage-server     # API, queue worker, CLI and prisma wrappers in result/bin
nix build .#recipesage-frontend   # static web app
nix build .#recipesage-www        # static marketing site
nix build .#pushpin
nix build .#grocery-categorizer
nix develop                       # node 26, pnpm 10, postgres, valkey, pushpin, ...
```

## Updating RecipeSage

1. Change the tag in `inputs.recipesage-src.url` and `version` in `flake.nix`.
2. Set `pnpmDepsHash = "";` and run `nix build .#recipesage-server`.
3. Copy the `got: sha256-…` hash from the error into `pnpmDepsHash`.
4. Run `nix flake update recipesage-src`.

To build your own checkout instead of the pinned tag:

```sh
nix build .#recipesage-server --override-input recipesage-src path:/path/to/recipesage
```
