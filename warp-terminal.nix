# Override of nixpkgs's warp-terminal to track upstream stable releases more
# aggressively than the channel bumps it.
#
# To bump:
#   1. Find the latest stable version. The version base (e.g. 0.2026.05.13.09.15)
#      is listed on https://docs.warp.dev/changelog/2026 — the trailing
#      `stable_NN` is a build counter; probe upward from `_00` against
#      https://releases.warp.dev/stable/v<VERSION>/ to find the highest 200.
#   2. Update `version` below.
#   3. Update `hash`. Quickest path:
#        nix-prefetch-url --type sha256 <url>
#        nix hash convert --hash-algo sha256 --to sri <hash>
#      Or just set `hash = lib.fakeHash;` and let the rebuild error tell you.
#
# URL scheme matches the in-tree derivation; sanity-check with:
#   nix eval --raw nixpkgs#warp-terminal.src.url

{ warp-terminal, fetchurl, lib }:

warp-terminal.overrideAttrs (old: rec {
  version = "0.2026.05.13.09.15.stable_03";

  src = fetchurl {
    url = "https://releases.warp.dev/stable/v${version}/warp-terminal-v${version}-1-x86_64.pkg.tar.zst";
    hash = "sha256-5Gl7EYXSLHsp0GDx89RZiCDhOqCbHZuxJYOKuOzEz3Y=";
  };
})
