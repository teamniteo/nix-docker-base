FROM nixpkgs-nixos-20.03:cb1996818edf506c0d1665ab147c253c558a7426

COPY . ./src
RUN set -x \
  && drv=$(nix-instantiate /src) \
  && nix-store -v --export $(nix-store -qR $(nix-store -r -v $drv)) > /root/export \
  && NIX_REMOTE=local?root=/root/nix nix-store -v --import < /root/export
