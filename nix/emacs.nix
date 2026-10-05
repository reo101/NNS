{ lib, stdenvNoCC, emacs-nox, zip, python3 }:
stdenvNoCC.mkDerivation {
  pname = "nns-emacs";
  version = "3.2.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [ ../integrations/emacs ../tests/nns-test.el ];
  };
  nativeBuildInputs = [ emacs-nox zip python3 ];
  dontConfigure = true;
  dontFixup = true;
  allowedReferences = [ ];
  buildPhase = ''
    emacs -Q --batch -L integrations/emacs -f batch-byte-compile integrations/emacs/nns.el
  '';
  doCheck = true;
  checkPhase = ''
    emacs -Q --batch -L integrations/emacs -l ${../tests/nns-test.el} -f ert-run-tests-batch-and-exit
  '';
  installPhase = ''
    mkdir -p "$out/share/emacs/site-lisp" "$out/module/lisp"
    # Ship source, not bytecode tied to the build host's Emacs version.
    cp integrations/emacs/nns.el "$out/share/emacs/site-lisp/"
    cp integrations/emacs/nns.el "$out/module/lisp/"
    cp integrations/emacs/module/* "$out/module/"
    touch "$out/module/skip_mount"
    chmod 755 "$out/module/"*.sh
    find "$out/module" -exec touch -h -t 198001010000 {} +
    (cd "$out/module"; find . -type f -print | LC_ALL=C sort | zip -X -9 "$out/nns-emacs.zip" -@)
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    python3 - "$out/nns-emacs.zip" <<'PY'
    import sys, zipfile
    with zipfile.ZipFile(sys.argv[1]) as z:
        assert set(z.namelist()) == {'module.prop', 'customize.sh', 'post-fs-data.sh', 'skip_mount', 'lisp/nns.el'}
        assert z.testzip() is None
        assert b'id=nns-emacs\n' in z.read('module.prop')
    PY
  '';
  meta = {
    description = "Optional Emacs package and manager module for rootless NNS subprocesses";
    platforms = lib.platforms.unix;
  };
}
