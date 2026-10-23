{
  lib,
  pkgs,
  accounts,
  name,
  directory,
}:
let
  owner = accounts.${directory.owner};
  group = accounts.${directory.group};
  labelAccount =
    if directory.selinuxContextFromAccount == null then
      null
    else
      accounts.${directory.selinuxContextFromAccount};
in
pkgs.writeShellScript "nns-directory-${name}" ''
  set -eu
  fail() { printf 'nns directory ${name}: %s\n' "$*" >&2; exit 1; }
  parent=${lib.escapeShellArg (builtins.dirOf directory.path)}
  name=${lib.escapeShellArg (builtins.baseNameOf directory.path)}

  # Hold the parent inode while checking and creating the final component.
  # An app cannot redirect later operations by replacing an ancestor path.
  exec 3<"$parent"
  parent_fd=/proc/$$/fd/3
  [ -d "$parent_fd" ] || fail 'parent is not a directory'
  [ "$(${pkgs.coreutils}/bin/readlink "$parent_fd")" = "$parent" ] || fail 'parent path is not canonical'
  [ "$(${pkgs.coreutils}/bin/stat -L -c %u "$parent_fd")" = 0 ] || fail 'parent is not root-owned'
  permissions=$(${pkgs.coreutils}/bin/stat -L -c %a "$parent_fd")
  [ "$((8#$permissions & 022))" = 0 ] || fail 'parent is writable by another identity'

  ${lib.optionalString (labelAccount != null) ''
    source=${lib.escapeShellArg labelAccount.home}
    [ ! -L "$source" ] || fail 'label source is a symlink'
    metadata=$(/system/bin/stat -c '%u:%g:%C' "$source")
    case "$metadata" in
      ${builtins.toString labelAccount.uid}:${builtins.toString labelAccount.gid}:*) ;;
      *) fail 'label source does not match its configured account UID/GID' ;;
    esac
    context=''${metadata#*:*:}
  ''}

  target="$parent_fd/$name"
  [ ! -L "$target" ] || fail 'directory is a symlink'
  if [ ! -e "$target" ]; then ${pkgs.coreutils}/bin/mkdir -- "$target"; fi
  exec 4<"$target"
  target_fd=/proc/$$/fd/4
  [ -d "$target_fd" ] || fail 'target is not a directory'
  [ "$(${pkgs.coreutils}/bin/readlink "$target_fd")" = ${lib.escapeShellArg directory.path} ] || fail 'target path changed'
  ${pkgs.coreutils}/bin/chown +${builtins.toString owner.uid}:+${builtins.toString group.gid} "$target_fd"
  ${pkgs.coreutils}/bin/chmod ${lib.escapeShellArg directory.mode} "$target_fd"
  ${lib.optionalString (labelAccount != null) ''
    /system/bin/chcon "$context" "$target_fd"
  ''}
''
