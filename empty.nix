{ dockerTools
, coreutils
, bashInteractive
, nix
, cacert
, gitReallyMinimal
, gnutar
, gzip
, openssh
, xz
, stdenv
, cachix
, shadow
}:
dockerTools.buildImage {
  name = "nixpkgs-${nixpkgs.branch}";
  tag = "empty";
  contents = [
    coreutils
    bashInteractive
  ];

  extraCommands = ''
    # for /usr/bin/env
    mkdir usr
    ln -s ../bin usr/bin
  '';

  runAsRoot = ''
    #!${stdenv.shell}
    ${dockerTools.shadowSetup}
    useradd builder
  '';

  config = {
    Cmd = [ "/bin/bash" ];
    Env = [
      "ENV=/etc/profile.d/nix.sh"
      "BASH_ENV=/etc/profile.d/nix.sh"
      "NIX_BUILD_SHELL=/bin/bash"
      "NIX_PATH=nixpkgs=${nixpkgs}"
      "PAGER=cat"
      "PATH=/nix/var/nix/profiles/default/bin:/bin/usr/bin:/bin"
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "USER=root"
    ];
  };
}
