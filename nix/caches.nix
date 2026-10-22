# The accepted binary caches. Consumed by the NixOS hosts (via the
# substituters module) and rendered into the phone's shared staged
# nix.conf by the NNS system through nix.settings.
[
  {
    substituter = "https://cache.nixos.org";
    public-key = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
  }
  {
    substituter = "https://nix-community.cachix.org";
    public-key = "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=";
  }
  {
    substituter = "https://rix101.cachix.org";
    public-key = "rix101.cachix.org-1:2u9ZGi93zY3hJXQyoHkNBZpJK+GiXQyYf9J5TLzCpFY=";
  }
  # {
  #   substituter = "https://lean4.cachix.org";
  #   public-key = "lean4.cachix.org-1:mawtxSxcaiWE24xCXXgh3qnvlTkyU7evRRnGeAhD4Wk=";
  # }
  # {
  #   substituter = "https://nixpkgs-cross-overlay.cachix.org";
  #   public-key = "nixpkgs-cross-overlay.cachix.org-1:TjKExGN4ys960TlsGqNOI/NBdoz2Jdr2ow1VybWV5JM=";
  # }
  # {
  #   substituter = "https://cache.ngi0.nixos.org";
  #   public-key = "cache.ngi0.nixos.org-1:KqH5CBLNSyX184S9BKZJo1LxrxJ9ltnY2uAs5c/f1MA=";
  # }
]
