# Pushpin: reverse proxy for realtime (WebSocket / streaming) services.
# Replaces the `julianpoy/pushpin` docker image. It is not in nixpkgs, so we
# build it from source (Rust + a Qt/C++ core).
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  makeWrapper,
  qt6,
  boost,
  zeromq,
  openssl,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "pushpin";
  version = "1.42.0";

  src = fetchFromGitHub {
    owner = "fastly";
    repo = "pushpin";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Dq43pQWOXs8ASlJiFOBdfIA7qElHYkdpMvY0EURohHo=";
  };

  cargoHash = "sha256-QFWSeDOWnA/idAjJ27Nns7NVe5gN751Kr1uPdP56TrQ=";

  nativeBuildInputs = [
    pkg-config
    makeWrapper
    qt6.qtbase # provides qmake, which build.rs invokes
  ];

  buildInputs = [
    qt6.qtbase
    boost
    zeromq
    openssl
  ];

  dontWrapQtApps = true;

  # build.rs bakes these paths into the binaries (LIB_DIR / CONFIG_DIR).
  env = {
    PREFIX = placeholder "out";
    RUNDIR = "/run";
    LOGDIR = "/var/log";
    BOOST_INCLUDE_DIR = "${lib.getDev boost}/include";
  };

  # The C++ test suite needs a network and is slow; the Rust tests are enough.
  doCheck = false;

  # Upstream installs through a qmake-generated Makefile in postbuild/ that
  # copies binaries out of target/release.
  postInstall = ''
    install -Dm644 src/internal.conf $out/lib/pushpin/internal.conf
    install -Dm644 -t $out/lib/pushpin/runner src/runner/*.template
    mkdir -p $out/etc/pushpin/runner
    cp -r examples/config/runner/certs $out/etc/pushpin/runner/
    install -Dm644 examples/config/routes $out/etc/pushpin/routes
    sed -e "s,configdir=.*,configdir=$out/etc/pushpin/runner,g" \
      examples/config/pushpin.conf > $out/etc/pushpin/pushpin.conf
    ln -sf pushpin-connmgr $out/bin/pushpin-condure
    rm -f $out/lib/libpushpin.a

    # The runner spawns pushpin-connmgr/-proxy/-handler by name from PATH.
    wrapProgram $out/bin/pushpin --prefix PATH : $out/bin
  '';

  meta = {
    description = "Reverse proxy for realtime web services";
    homepage = "https://pushpin.org";
    license = lib.licenses.asl20;
    mainProgram = "pushpin";
    platforms = lib.platforms.linux;
  };
})
