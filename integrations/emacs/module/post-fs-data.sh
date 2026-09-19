#!/system/bin/sh
# Publish the optional Lisp package. No daemon, sockets, or app data edits.
MODDIR=${0%/*}
DEST=/data/nix/share/emacs/site-lisp
mkdir -p "$DEST" || exit 1
cp "$MODDIR/lisp/nns.el" "$DEST/nns.el.new" || exit 1
chmod 644 "$DEST/nns.el.new"
chcon u:object_r:system_file:s0 /data/nix/share /data/nix/share/emacs "$DEST" "$DEST/nns.el.new" || exit 1
mv -f "$DEST/nns.el.new" "$DEST/nns.el"
