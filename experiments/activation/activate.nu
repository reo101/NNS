#!/usr/bin/env nu
# Experimental alternative. Production continues to use activate.sh.
const script = path self
const process_boundary = path self process-boundary.sh

def fail [message: string] { error make {msg: $"nns activation: ($message)"} }

# Capture expected failures explicitly. Never depend on ambient LAST_EXIT_CODE.
def probe [arguments: list] {
    let arguments = ($arguments | each { into string })
    do { run-external $arguments.0 ...($arguments | skip 1) } | complete
}

def checked-command [arguments: list] {
    let result = (probe $arguments)
    if $result.exit_code != 0 {
        fail $"command failed [($result.exit_code)]: ($arguments | to nuon): ($result.stderr | str trim)"
    }
    $result.stdout | str trim --right --char (char newline)
}

def is-link [path: string] { ($path | path type) == symlink }
def is-file [path: string] { ($path | path exists) and (($path | path expand | path type) == file) }
def is-directory [path: string] { ($path | path exists) and (($path | path expand | path type) == dir) }
def permissions [path: string] { checked-command [stat -L -c %a $path] | into int --radix 8 }
def is-executable [path: string] {
    ($path | path exists) and (((permissions $path) | bits and 0o111) != 0)
}

def children [directory: string] {
    if not (is-directory $directory) { return [] }
    ls --all $directory | get name | sort
}

def visible-children [directory: string] {
    children $directory | where {|entry| not (($entry | path basename) | str starts-with '.') }
}

def check-directory [path: string] {
    if not ($path | str starts-with '/') { fail $"directory is not absolute: ($path)" }
    if $path in [/ /etc /var /system] { fail $"refusing Android system directory: ($path)" }
    if (is-link $path) { fail $"administrative directory is a symlink: ($path)" }
    if ($path | path exists) {
        if not (is-directory $path) or (checked-command [stat -c %u $path]) != '0' {
            fail $"administrative directory is not root-owned: ($path)"
        }
        if ((permissions $path) | bits and 0o022) != 0 {
            fail $"administrative directory is writable by another identity: ($path)"
        }
    }
}

def configuration [generation: string mode: string] {
    {
        generation: $generation, mode: $mode, sp: ($generation | path join system-profile)
        state: ($env.NNS_STATE_DIRECTORY? | default /data/nix/var/nns)
        etc_root: ($env.NNS_ETC_DIRECTORY? | default /data/nix/var/daemon-etc)
        profiles: ($env.NNS_PROFILE_DIRECTORY? | default /nix/var/nix/profiles)
        nix_conf: ($env.NNS_NIX_CONF_DIRECTORY? | default /data/nix/etc/nix)
        launcher: ($env.NNS_LAUNCHER? | default /data/nix/bin/nix-enter)
    }
}

def root-home [configuration: record] {
    let roots = (open --raw ($configuration.generation | path join etc passwd)
        | lines | where {|line| $line | str starts-with 'root:' })
    if ($roots | is-empty) { fail 'missing root home' }
    let home = ($roots.0 | split row ':' | get 5)
    if $home == '' { fail 'missing root home' }
    $home
}

def preflight [configuration: record] {
    let c = $configuration
    if (checked-command [id -u]) != '0' { fail 'activation requires root' }
    if $c.mode not-in [switch boot] { fail 'mode must be switch or boot' }
    if not (is-directory ($c.sp | path join bin)) or not (is-directory ($c.generation | path join etc)) {
        fail 'invalid generation'
    }
    for tool in [nix nix-env sleep runsvdir sv flock install mv mkdir mktemp cp chmod chown stat readlink ln rm find grep cut cat nohup sh kill] {
        if (which $tool | is-empty) { fail $"missing system tool: ($tool)" }
    }
    for path in [$c.state $c.etc_root $c.profiles $c.nix_conf] {
        check-directory $path
        check-directory ($path | path dirname)
    }
    check-directory $c.generation
    for path in ([$"($c.state)/services" $"($c.state)/authorized_keys"] ++ (visible-children $"($c.state)/services")) {
        check-directory $path
    }
    for name in [passwd group nix/nix.conf] {
        if not (is-file ($c.generation | path join etc $name)) { fail $"missing etc/($name)" }
    }
    for category in [profiles services authorized_keys] {
        let directory = ($c.generation | path join $category)
        if not (is-directory $directory) { fail $"missing ($category)" }
        for entry in (visible-children $directory) {
            if not ($entry | path exists) {
                if (is-link $entry) { fail $"broken link: ($entry)" }
                continue
            }
            let name = ($entry | path basename)
            if $name !~ '^[A-Za-z0-9][A-Za-z0-9_-]*$' { fail $"invalid ($category) name: ($name)" }
            match $category {
                profiles => {
                    if $name in [nns-system system-profile] { fail $"reserved profile: ($name)" }
                    if not (is-directory ($entry | path join bin)) { fail $"profile has no bin directory: ($name)" }
                }
                services => {
                    if not (is-executable ($entry | path join run)) { fail $"service run script is not executable: ($name)" }
                    if (is-file ($entry | path join oneshot)) and not (is-executable ($entry | path join finish)) {
                        fail $"oneshot has no finish script: ($name)"
                    }
                }
                authorized_keys => { if not (is-file $entry) { fail $"invalid authorized keys: ($name)" } }
            }
        }
    }
    if (is-link $c.launcher) or not (is-executable $c.launcher) or (checked-command [stat -c %u $c.launcher]) != '0' {
        fail 'namespace launcher is not root-owned and executable'
    }
    if ((permissions $c.launcher) | bits and 0o022) != 0 { fail 'namespace launcher is writable by another identity' }
    check-directory ($c.launcher | path dirname)
    check-directory (root-home $c)
    if (is-file ($c.generation | path join sshd-enabled)) {
        if not (is-file ($c.generation | path join sshd_config)) or not (is-executable ($c.generation | path join check-sshd)) {
            fail 'incomplete SSH generation'
        }
        if not (is-executable ($c.sp | path join bin ssh-keygen)) { fail 'SSH bootstrap tools unavailable' }
    }
}

def prepare-state [c: record] {
    let home = (root-home $c)
    checked-command ([mkdir -p $c.state $c.etc_root $c.profiles $c.nix_conf $"($c.state)/services" $"($c.state)/authorized_keys" $home]) | ignore
    for path in [$"($c.state)/services" $"($c.state)/authorized_keys" $"($c.etc_root)/nix" $"($c.etc_root)/ssl" $"($c.etc_root)/ssl/certs"] {
        check-directory $path
    }
    checked-command [chmod 755 $c.state $c.etc_root $c.profiles $c.nix_conf] | ignore
    checked-command [chmod 700 $"($c.state)/services" $"($c.state)/authorized_keys" $home] | ignore
    if (is-file ($c.generation | path join sshd-enabled)) {
        let key = ($c.state | path join ssh_host_ed25519_key)
        if not (is-file $key) { checked-command [$"($c.sp)/bin/ssh-keygen" -q -t ed25519 -N '' -f $key] | ignore }
        if (is-link $key) or (checked-command [stat -c %u $key]) != '0' { fail 'host key is not root-owned' }
        checked-command [chmod 600 $key] | ignore
        checked-command [$"($c.generation)/check-sshd" $"($c.generation)/etc" $"($c.generation)/sshd_config"] | ignore
    }
}

def atomic-copy [source: string destination: string mode: string] {
    let temporary = ($destination | path dirname | path join $".nns-($destination | path basename).($nu.pid)")
    checked-command [install -m $mode $source $temporary] | ignore
    checked-command [mv -Tf $temporary $destination] | ignore
}

def publish-configuration [c: record] {
    # NUL framing preserves arbitrary names. Keep the staged /etc inode and live mounts.
    let sources = (checked-command [find -L $"($c.generation)/etc" -type f -print0] | split row (char nul) | where {|path| $path != '' })
    for source in $sources {
        let relative = ($source | path relative-to $"($c.generation)/etc")
        let destination = ($c.etc_root | path join $relative)
        check-directory ($destination | path dirname)
        checked-command [install -d -m 755 ($destination | path dirname)] | ignore
        atomic-copy $source $destination '644'
    }
    atomic-copy $"($c.generation)/etc/nix/nix.conf" $"($c.nix_conf)/nix.conf" '644'
}

def --env publish-profiles [c: record] {
    $env.NIX_REMOTE = 'local'
    $env.NIX_CONF_DIR = $c.nix_conf
    checked-command [$"($c.sp)/bin/nix-env" --profile $"($c.profiles)/system-profile" --set ($c.sp | path expand)] | ignore
    let per_user = ($c.profiles | path join per-user)
    check-directory $per_user
    checked-command [mkdir -p $per_user] | ignore
    checked-command [chmod 755 $per_user] | ignore
    for line in (open --raw $"($c.generation)/etc/passwd" | lines) {
        let fields = ($line | split row ':')
        let uid = ($fields.2 | into int)
        if $uid == 0 { continue }
        let directory = ($per_user | path join $fields.0)
        if (is-link $directory) { fail $"per-user profile directory is a symlink: ($fields.0)" }
        if ($directory | path exists) {
            let owner = (checked-command [stat -c %u $directory] | into int)
            if $owner not-in [0 $uid] { fail $"unexpected per-user profile owner: ($fields.0)" }
        }
        checked-command [mkdir -p $directory] | ignore
        checked-command [chown $"($fields.2):($fields.3)" $directory] | ignore
        checked-command [chmod 755 $directory] | ignore
    }
    for entry in (visible-children $"($c.generation)/profiles") {
        checked-command [$"($c.sp)/bin/nix-env" --profile ($c.profiles | path join ($entry | path basename)) --set ($entry | path expand)] | ignore
    }
}

def publish-keys [c: record] {
    for entry in (visible-children $"($c.generation)/authorized_keys") {
        atomic-copy $entry ($c.state | path join authorized_keys ($entry | path basename)) '600'
    }
    for entry in (visible-children $"($c.state)/authorized_keys") {
        if (is-file $entry) and not (is-file ($c.generation | path join authorized_keys ($entry | path basename))) {
            checked-command [rm -f $entry] | ignore
        }
    }
    if (is-file $"($c.generation)/sshd-enabled") { atomic-copy $"($c.generation)/sshd_config" $"($c.state)/sshd_config" '600' }
}

def supervised [directory: string] {
    (($directory | path join supervise control | path type) == pipe) and ((probe [sv status $directory]).exit_code == 0)
}

def atomic-link [target: string destination: string] {
    let temporary = ($destination | path dirname | path join $".($destination | path basename).($nu.pid)")
    checked-command [ln -s $target $temporary] | ignore
    checked-command [mv -Tf $temporary $destination] | ignore
}

def reconcile-services [c: record] {
    for directory in (visible-children $"($c.state)/services") {
        check-directory $directory
        if not (is-directory ($c.generation | path join services ($directory | path basename))) {
            if (supervised $directory) {
                checked-command [sv -w '10' down $directory] | ignore
                checked-command [sv -w '10' exit $directory] | ignore
            }
            checked-command [rm -rf -- $directory] | ignore
        }
    }
    let entries = (visible-children $"($c.generation)/services")
    # Invalidate all finite results before publishing any replacement service.
    for entry in $entries {
        let directory = ($c.state | path join services ($entry | path basename))
        if (is-file $"($entry)/oneshot") or (is-file $"($directory)/oneshot") {
            if (supervised $directory) { checked-command [sv -w '10' down $directory] | ignore }
            checked-command [rm -f $"($directory)/completed" $"($directory)/exit-status"] | ignore
        }
    }
    for entry in $entries {
        let directory = ($c.state | path join services ($entry | path basename))
        check-directory $directory
        let previous = ((probe [readlink $"($directory)/run"]).stdout | str trim --right --char (char newline))
        let target = ($entry | path join run | path expand)
        let previous_oneshot = (is-file $"($directory)/oneshot")
        let oneshot = (is-file $"($entry)/oneshot")
        let destination = if (is-directory $directory) { $directory } else { checked-command [mktemp -d $"($c.state)/.service.($entry | path basename).XXXXXXXX"] }
        checked-command [chmod 700 $destination] | ignore
        atomic-link $target $"($destination)/run"
        if $oneshot {
            '' | save --force $"($destination)/oneshot"
            '' | save --force $"($destination)/down"
            atomic-link ($entry | path join finish | path expand) $"($destination)/finish"
        } else {
            checked-command [rm -f $"($destination)/oneshot" $"($destination)/finish"] | ignore
            if $previous_oneshot { checked-command [rm -f $"($destination)/down"] | ignore }
        }
        if $destination != $directory { checked-command [mv -T $destination $directory] | ignore }
        if not $oneshot and ($previous != $target or $previous_oneshot) and (supervised $directory) {
            checked-command [sv -w '10' restart $directory] | ignore
        }
    }
}

def supervisor-running [c: record] {
    let pidfile = ($c.state | path join supervisor.pid)
    if not (is-file $pidfile) { return false }
    let pid = (open --raw $pidfile | str trim)
    if $pid !~ '^[0-9]+$' or $pid =~ '^0+$' { return false }
    if (probe [kill '-0' $pid]).exit_code != 0 { return false }
    try { open --raw $"/proc/($pid)/cmdline" | str contains runsvdir } catch { false }
}

def await [predicate: closure attempts: int message: string] {
    for attempt in 1..$attempts {
        if (do $predicate) { return }
        if $attempt < $attempts { sleep 1sec }
    }
    fail $message
}

def start-services [c: record] {
    if not (supervisor-running $c) {
        if not (is-executable $c.launcher) { fail 'namespace launcher unavailable' }
        checked-command [$"($c.sp)/bin/sh" $process_boundary spawn $"($c.state)/supervisor.log" $"($c.state)/supervisor.pid" $c.launcher --etc $c.etc_root -- $"($c.sp)/bin/runsvdir" $"($c.state)/services"] | ignore
    }
    for entry in (visible-children $"($c.generation)/services") {
        if not (is-file $"($entry)/oneshot") { continue }
        let directory = ($c.state | path join services ($entry | path basename))
        await { (probe [sv status $directory]).exit_code == 0 } 10 $"oneshot is not supervised: ($entry | path basename)"
        checked-command [sv up $directory] | ignore
    }
    if (is-directory $"($c.generation)/services/nix-daemon") {
        await { with-env {NIX_REMOTE: daemon} { (probe [$"($c.sp)/bin/nix" --extra-experimental-features nix-command store ping --store daemon]).exit_code == 0 } } 30 'Nix daemon did not become available'
    }
}

def main [generation: string mode: string --locked] {
    let c = (configuration $generation $mode)
    $env.PATH = [$"($c.sp)/bin" /system/bin /system/xbin]
    preflight $c
    if not $locked {
        checked-command [mkdir -p ($c.state | path dirname)] | ignore
        if (is-link $"($c.state).lock") { fail 'activation lock is a symlink' }
        exec $"($c.sp)/bin/sh" $process_boundary lock $"($c.state).lock" $nu.current-exe --no-config-file $script $generation $mode --locked
    }
    umask rwx------ | ignore
    prepare-state $c
    publish-configuration $c
    publish-profiles $c
    publish-keys $c
    reconcile-services $c
    start-services $c
}
