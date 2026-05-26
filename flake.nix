{
  description = "chris-laptop — personal NixOS workstation (MSI Creator 15 A11UE)";

  inputs = {
    # DELIBERATELY UNSTABLE. This is a personal daily driver, not a fleet box
    # (cf. KastnerRG/krg-infra, which pins nixos-25.11). It tracks nixos-unstable
    # — the system already runs 26.05pre — and the flake.lock just formalizes the
    # old nix-channel + fetchTarball-home-manager setup with a pin.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";       # master, follows unstable
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative disk partitioning — btrfs-on-LUKS, the 2TB drive ONLY.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # "Erase your darlings": ephemeral btrfs root (recreated empty each boot) + /persist.
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";  # dedupe — don't drag in a 2nd nixpkgs
    };

    # Secure Boot (signed boot chain). Hardens the TPM2 LUKS auto-unlock by
    # measuring the boot path — without it an attacker can swap the initrd.
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v0.4.2";  # bump to latest release as needed
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets. age identity = ssh-to-age of the SSH key synced via Nextcloud, so
    # every personal machine can decrypt and a reinstall doesn't lose the key.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The user's own non-Nix package reconciler (`depend`). Must be a flake INPUT
    # now: home.nix's old `builtins.getFlake "github:..."` is illegal in a flake's
    # pure eval, so it's referenced via inputs.dependency-manager instead.
    dependency-manager = {
      url = "github:ccrutchf/dependency-manager";
      inputs.nixpkgs.follows = "nixpkgs";  # dedupe — don't pull a 2nd nixpkgs into the lock
    };

    # Prebuilt nix-index database (weekly) so `comma` / nix-locate work instantly.
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, disko, lanzaboote, sops-nix, ... }@inputs:
  {
    nixosConfigurations.chris-laptop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      # Pass all inputs down so local modules can import e.g.
      # inputs.impermanence.nixosModules.impermanence (mirrors krg-infra).
      specialArgs = { inherit inputs; };
      modules = [
        ./configuration.nix   # imports ./disko-config.nix + ./modules/*.nix itself

        disko.nixosModules.disko
        lanzaboote.nixosModules.lanzaboote
        sops-nix.nixosModules.sops
        inputs.nix-index-database.nixosModules.nix-index

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.users.chris = import ./home.nix;
        }
      ];
    };
  };
}
