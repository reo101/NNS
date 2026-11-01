{ buildFHSEnv }:

buildFHSEnv {
  name = "nns-rom-build-environment";
  targetPkgs = pkgs: with pkgs; [
    bashInteractive
    git-repo
    (git-lfs.overrideAttrs (previous: {
      postPatch = (previous.postPatch or "") + ''
        substituteInPlace lfshttp/client.go \
          --replace-fail 'req.Header.Set("User-Agent", UserAgent)' \
          'req.Header.Set("User-Agent", UserAgent)
          if userAgent := os.Getenv("GIT_LFS_HTTP_USER_AGENT"); userAgent != "" {
            req.Header.Set("User-Agent", userAgent)
          }'
      '';
    }))
    curl
    ccache
    python3
    gnumake
    gcc
    gcc.cc
    glibc.dev
    binutils
    coreutils
    diffutils
    findutils
    gnugrep
    gnused
    gawk
    patch
    m4
    flex
    bison
    perl
    zip
    unzip
    rsync
    util-linux
    e2fsprogs
    file
    which
    zlib
    ncurses
    libxml2
    freetype
    fontconfig
    openssl
    openssl.dev
    libxcrypt-legacy
  ];
  multiPkgs = pkgs: with pkgs; [ zlib ncurses libxcrypt-legacy ];
  runScript = "bash";
}
