{ nixpkgsRev, nixpkgsSha, nixHash ? null }:
let
  nixpkgs = fetchTarball {
    # Rename the derivation to accomodate the standard niv naming of nixpkgs
    name = "nixpkgs-src";
    url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsRev}.tar.gz";
    sha256 = nixpkgsSha;
  };


  pkgs = import nixpkgs {
    config = {};
    overlays = [ (import ./overlay.nix) ];
  };
  inherit (pkgs) lib;

  exportProfile = pkgs.writeShellScriptBin "export-profile" (builtins.readFile ./scripts/export-profile);
  startTmate = pkgs.writeShellScriptBin "start-tmate" (builtins.readFile ./scripts/start-tmate);
  bashTmate = pkgs.writeShellScriptBin "bash-tmate" (builtins.readFile ./scripts/bash-tmate);

  # All packages available in the base image
  env = pkgs.buildEnv {
    name = "base-env";
    paths = with pkgs; [
      # Custom things
      exportProfile
      startTmate
      bashTmate
      tmate

      # Very basics
      coreutils
      bashInteractive

      # Nix and runtime dependencies of it
      nix
      cacert
      gitReallyMinimal
      gnutar
      gzip
      openssh
      xz

      # Extra tools
      cachix
      less
      gnused
      gnugrep
    ];
  };

  # Dynamic files in the filesystem root of the base image
  dynamicRootFiles = pkgs.runCommandNoCC "dynamic-root-files" {} ''
    mkdir -p $out/run $out/usr/bin $out/bin $out/lib64
    cp -R -Ls ${env} $out/run/profile
    cp -R -Ls ${env}/etc $out/etc
    ln -s ${pkgs.coreutils}/bin/env $out/usr/bin/env
    ln -s ${pkgs.bashInteractive}/bin/sh $out/bin/sh

    # So that this image can be used as a GitHub Action container directly
    # Needed because it calls its own (non-nix-patched) node binary which uses
    # this dynamic linker path. See also the LD_LIBRARY_PATH assignment below,
    # which provides the necessary libraries for that binary
    ln -s ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 $out/lib64/ld-linux-x86-64.so.2
  '';

  # All contents of the root filesystem
  rootContents = [
    ./static-root-files
    dynamicRootFiles
  ];

  # The contents of the Nix database in the built container
  nixDbContents = [
    # We need to include this such that our environment and stuff doesn't get GC'd
    # and for the environments derivations not to be refetched
    dynamicRootFiles
    # We also need the nixpkgs source to be in the Nix db,
    # which allows it to be used by Nix expressions
    nixpkgs
  ];

  # fix for:
  # `nix-instantiate: /nix/store/ikl21vjfq900ccbqg1xasp83kadw6q8y-glibc-2.32-46/lib/libc.so.6: version `GLIBC_2.33' not found (required by /nix/store/j132k1ncfn6gjfd2f5s1gz37170rch4h-gcc-11.3.0-lib/lib/libstdc++.so.6)`
  patchGLIBC = ''
    export LD_LIBRARY_PATH=${pkgs.stdenv.cc.cc.lib}/lib/:$LD_LIBRARY_PATH
  '';

  # This section is copied from https://github.com/NixOS/nixpkgs/blob/7a100ad9543687d046cfeeb5156dfaa697e1abbd/pkgs/build-support/docker/default.nix#L39-L57
  # but adjusted to support additional contents
  extraCommands = ''
    echo "Generating the nix database..."
    echo "Warning: only the database of the deepest Nix layer is loaded."
    echo "         If you want to use nix commands in the container, it would"
    echo "         be better to only have one layer that contains a nix store."

    export NIX_REMOTE=local?root=$PWD
    # A user is required by nix
    # https://github.com/NixOS/nix/blob/9348f9291e5d9e4ba3c4347ea1b235640f54fd79/src/libutil/util.cc#L478
    export USER=nobody
    ${pkgs.nix}/bin/nix-store --load-db < ${pkgs.closureInfo { rootPaths = nixDbContents; }}/registration

    mkdir -p nix/var/nix/gcroots/docker/
    for i in ${lib.concatStringsSep " " nixDbContents}; do
      ln -s $i nix/var/nix/gcroots/docker/$(basename $i)
    done;

    # make sure /tmp exists
    mkdir -m 1777 tmp
  '' + patchGLIBC;
in pkgs.dockerTools.buildImage {
  name = "nixpkgs";
  # Doesn't make images have a creation date of 1970
  created = "now";

  contents = rootContents;
  inherit extraCommands;

  config = {
    Cmd = [ "bash" ];
    WorkingDir = "/root";
    Env = [
      # So that nix-shell doesn't fetch its own bash
      "NIX_BUILD_SHELL=/run/profile/bin/bash"
      # The image itself pins nixpkgs, expose this for convenience
      "NIX_PATH=nixpkgs=${nixpkgs}"
      # Make nix-env installs work
      "PATH=/nix/var/nix/profiles/default/bin:/run/profile/bin:/bin"
      # Needed for curl and co.
      "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      # Docker apparently doesn't set this
      "USER=root"
      # Needed by some nix commands like nix-store to display output
      "PAGER=/run/profile/bin/less"
      # By default, the linker added in dynamicRootFiles can only find glibc
      # libraries, but the node binary from the GitHub Actions runner also
      # depends on libstdc++.so.6, which is glibc/stdenv. Using LD_LIBRARY_PATH
      # is the easiest way to inject this dependency
      "LD_LIBRARY_PATH=${lib.makeLibraryPath [ pkgs.stdenv.cc.cc ]}"
    ];
  } // lib.optionalAttrs (nixHash != null) {
    # Embed a nixHash into the image if given, allowing later extraction via skopeo inspect
    # By embedding such a hash, we can know whether a commit-specific image on
    # DockerHub needs to be updated after changes made to the image builder
    # See scripts/image-update for how this hash is generated
    Labels.NixHash = nixHash;
  };
}
