#!/usr/bin/env bb
(ns activation
  (:require [babashka.fs :as fs]
            [babashka.process :as process]
            [clojure.string :as str]))

(defrecord ActivationContext [generation mode system-profile state etc-root profiles nix-conf launcher path tools])

(def required-tools
  ["id" "nix" "nix-env" "sleep" "runsvdir" "sv" "flock" "install" "mv"
   "mkdir" "mktemp" "cp" "chmod" "chown" "stat" "readlink" "ln" "rm"
   "find" "grep" "cut" "cat" "nohup" "sh"])

(def immutable-path "/system/bin:/system/xbin")
(def ^:dynamic *process-environment* {})
(declare process-pid)

(defn fail [message]
  (throw (ex-info message {:type ::activation-failure})))

(defn command-result [command]
  (apply process/shell {:out :string :err :string :continue true
                        :extra-env *process-environment*} command))

(defn checked-command [command]
  (let [{:keys [exit err]} (command-result command)]
    (when-not (zero? exit)
      (fail (str "command failed (" exit "): " (str/join " " command)
                 (when-not (str/blank? err) (str "\n" (str/trim err))))))))

(defn probe-command [command]
  (zero? (:exit (command-result command))))

(defn resolve-tool [program search-path]
  (some (fn [directory]
          (let [candidate (fs/path directory program)]
            (when (fs/executable? candidate) (str candidate))))
        (str/split search-path (re-pattern (java.util.regex.Pattern/quote fs/path-separator)))))

(defn tool-paths [search-path]
  (into {}
        (map (fn [program]
               [program (or (resolve-tool program search-path)
                            (fail (str "missing system tool: " program)))])
             required-tools)))

(defn owner-id [path]
  (long (fs/get-attribute path "unix:uid")))

(defn mode-bits [path]
  (if (fs/exists? path)
    (long (fs/get-attribute path "unix:mode"))
    0))

(defn check-directory [path]
  (when-not (fs/absolute? path)
    (fail (str "directory is not absolute: " path)))
  (when (contains? #{"/" "/etc" "/var" "/system"} (str path))
    (fail (str "refusing Android system directory: " path)))
  (when (fs/sym-link? path)
    (fail (str "administrative directory is a symlink: " path)))
  (when (fs/exists? path)
    (when-not (and (fs/directory? path) (= 0 (owner-id path)))
      (fail (str "administrative directory is not root-owned: " path)))
    (when-not (zero? (bit-and (mode-bits path) 8r022))
      (fail (str "administrative directory is writable by another identity: " path)))))

(defn valid-name? [name]
  (boolean (re-matches #"[A-Za-z0-9][A-Za-z0-9_-]*" name)))

(defn entries [directory]
  (if (fs/directory? directory)
    (remove #(str/starts-with? (str (fs/file-name %)) ".") (fs/list-dir directory))
    []))

(defn validate-generation-entry [directory entry]
  (let [name (str (fs/file-name entry))]
    (when-not (valid-name? name)
      (fail (str "invalid " directory " name: " name)))
    (case directory
      "profiles"
      (do
        (when (contains? #{"nns-system" "system-profile"} name)
          (fail (str "reserved profile: " name)))
        (when-not (fs/directory? (fs/path entry "bin"))
          (fail (str "profile has no bin directory: " name))))
      "services"
      (do
        (when-not (fs/executable? (fs/path entry "run"))
          (fail (str "service run script is not executable: " name)))
        (when (and (fs/regular-file? (fs/path entry "oneshot"))
                   (not (fs/executable? (fs/path entry "finish"))))
          (fail (str "oneshot has no finish script: " name))))
      "authorized_keys"
      (when-not (fs/regular-file? entry)
        (fail (str "invalid authorized keys: " name))))))

(defn validate-generation [context]
  (let [{:keys [generation system-profile launcher]} context]
    (when-not (and (fs/directory? (fs/path system-profile "bin"))
                   (fs/directory? (fs/path generation "etc")))
      (fail "invalid generation"))
    (check-directory generation)
    (doseq [file ["passwd" "group" "nix/nix.conf"]]
      (when-not (fs/regular-file? (fs/path generation "etc" file))
        (fail (str "missing etc/" file))))
    (doseq [directory ["profiles" "services" "authorized_keys"]]
      (when-not (fs/directory? (fs/path generation directory))
        (fail (str "missing " directory)))
      (doseq [entry (entries (fs/path generation directory))]
        (when (or (fs/exists? entry) (fs/sym-link? entry))
          (validate-generation-entry directory entry))))
    (when-not (and (not (fs/sym-link? launcher)) (fs/executable? launcher) (= 0 (owner-id launcher)))
      (fail "namespace launcher is not root-owned and executable"))
    (when-not (zero? (bit-and (mode-bits launcher) 8r022))
      (fail "namespace launcher is writable by another identity"))
    (check-directory (fs/parent launcher))
    (let [root-home (some->> (fs/read-all-lines (fs/path generation "etc/passwd"))
                             (filter #(str/starts-with? % "root:"))
                             first
                             (#(when % (nth (str/split % #":") 5 nil))))]
      (when (str/blank? root-home) (fail "missing root home"))
      (check-directory root-home)
      (when (fs/regular-file? (fs/path generation "sshd-enabled"))
        (when-not (and (fs/regular-file? (fs/path generation "sshd_config"))
                       (fs/executable? (fs/path generation "check-sshd")))
          (fail "incomplete SSH generation"))
        (when-not (and (fs/executable? launcher)
                       (fs/executable? (fs/path system-profile "bin/ssh-keygen")))
          (fail "SSH bootstrap tools unavailable")))
      (assoc context :root-home root-home))))

(defn create-context [generation mode]
  (let [state (or (System/getenv "NNS_STATE_DIRECTORY") "/data/nix/var/nns")
        etc-root (or (System/getenv "NNS_ETC_DIRECTORY") "/data/nix/var/daemon-etc")
        profiles (or (System/getenv "NNS_PROFILE_DIRECTORY") "/nix/var/nix/profiles")
        nix-conf (or (System/getenv "NNS_NIX_CONF_DIRECTORY") "/data/nix/etc/nix")
        launcher (or (System/getenv "NNS_LAUNCHER") "/data/nix/bin/nix-enter")
        sp (str (fs/path generation "system-profile"))
        path (str (fs/path sp "bin") ":" immutable-path)]
    (->ActivationContext generation mode sp state etc-root profiles nix-conf launcher path
                         (tool-paths path))))

(defn run-tool [context program & arguments]
  (checked-command (into [(get (:tools context) program)] (map str arguments))))

(defn run-profile-tool [context program & arguments]
  (checked-command (into [(str (fs/path (:system-profile context) "bin" program))]
                         (map str arguments))))

(defn atomic-install [context source destination permissions temporary-name]
  (check-directory (fs/parent destination))
  (fs/create-dirs (fs/parent destination))
  (let [temporary (str (fs/path (fs/parent destination) temporary-name))]
    (run-tool context "install" "-m" permissions source temporary)
    (run-tool context "mv" "-Tf" temporary destination)))

(defn prepare-state [context]
  (let [{:keys [state etc-root profiles nix-conf root-home generation]} context
        state-parent (fs/parent state)]
    (doseq [directory [state etc-root profiles nix-conf state-parent
                       (fs/parent etc-root) (fs/parent profiles) (fs/parent nix-conf)]]
      (check-directory directory))
    (doseq [directory [state (fs/path state "services") (fs/path state "authorized_keys")
                       (fs/path etc-root "nix") (fs/path etc-root "ssl")
                       (fs/path etc-root "ssl/certs")]]
      (check-directory directory))
    (doseq [directory (concat [(fs/path state "services") (fs/path state "authorized_keys")]
                              (entries (fs/path state "services")))]
      (when (or (fs/exists? directory) (fs/sym-link? directory))
        (check-directory directory)))
    (doseq [directory (entries (fs/path state "authorized_keys"))]
      (when (or (fs/exists? directory) (fs/sym-link? directory))
        (when-not (fs/regular-file? directory)
          (fail (str "invalid authorized keys state: " directory)))))
    (fs/create-dirs state-parent)
    (when (fs/sym-link? (str state ".lock"))
      (fail "activation lock is a symlink"))
    (doseq [directory [state etc-root profiles nix-conf (fs/path state "services")
                       (fs/path state "authorized_keys") root-home]]
      (fs/create-dirs directory))
    (run-tool context "chmod" "755" state)
    (run-tool context "chmod" "700" (fs/path state "services")
              (fs/path state "authorized_keys") root-home)
    (run-tool context "chmod" "755" etc-root profiles nix-conf)
    (when (and (fs/regular-file? (fs/path generation "sshd-enabled"))
               (not (fs/exists? (fs/path state "ssh_host_ed25519_key"))))
      (run-profile-tool context "ssh-keygen" "-q" "-t" "ed25519" "-N" ""
                        "-f" (fs/path state "ssh_host_ed25519_key")))
    (when (fs/regular-file? (fs/path generation "sshd-enabled"))
      (let [host-key (fs/path state "ssh_host_ed25519_key")]
        (when (or (fs/sym-link? host-key) (not= 0 (owner-id host-key)))
          (fail "host key is not root-owned"))
        (run-tool context "chmod" "600" host-key)
        (checked-command [(str (fs/path generation "check-sshd"))
                          (str (fs/path generation "etc"))
                          (str (fs/path generation "sshd_config"))])))))

(defn publish-generated-etc [context]
  (let [{:keys [generation etc-root nix-conf]} context
        etc-source (fs/path generation "etc")
        result (command-result [(get (:tools context) "find")
                                "-L" etc-source "-type" "f" "-print0"])
        _ (when-not (zero? (:exit result))
            (fail (str "command failed (" (:exit result) "): find")))
        files (remove empty? (str/split (:out result) #"\u0000"))]
    (doseq [source files]
      (let [relative (subs source (inc (count (str etc-source))))
            destination (fs/path etc-root relative)
            parent (fs/parent destination)
            temporary-name (str ".nns-" (fs/file-name destination) "." (process-pid))]
        (check-directory parent)
        (run-tool context "install" "-d" "-m" "755" parent)
        (atomic-install context source destination "644" temporary-name)))
    (atomic-install context (fs/path generation "etc/nix/nix.conf")
                    (fs/path nix-conf "nix.conf") "644"
                    (str ".nix.conf." (process-pid)))))

(defn process-pid [] (.pid (java.lang.ProcessHandle/current)))

(defn publish-profiles [context]
  (let [{:keys [generation profiles]} context]
    (run-profile-tool context "nix-env" "--profile" (fs/path profiles "system-profile")
                      "--set" (fs/real-path (:system-profile context)))
    (check-directory (fs/path profiles "per-user"))
    (fs/create-dirs (fs/path profiles "per-user"))
    (run-tool context "chmod" "755" (fs/path profiles "per-user"))
    (doseq [line (fs/read-all-lines (fs/path generation "etc/passwd"))]
      (let [[name _ uid gid] (str/split line #":" -1)
            uid-number (Long/parseLong uid)]
        (when-not (zero? uid-number)
          (let [directory (fs/path profiles "per-user" name)]
            (when (fs/sym-link? directory)
              (fail (str "per-user profile directory is a symlink: " name)))
            (when (fs/exists? directory)
              (let [owner (owner-id directory)]
                (when-not (or (zero? owner) (= owner uid-number))
                  (fail (str "unexpected per-user profile owner: " name)))))
            (fs/create-dirs directory)
            (run-tool context "chown" (str uid ":" gid) directory)
            (run-tool context "chmod" "755" directory)))))
    (doseq [entry (entries (fs/path generation "profiles"))]
      (run-profile-tool context "nix-env" "--profile"
                        (fs/path profiles (fs/file-name entry))
                        "--set" (fs/real-path entry)))))

(defn publish-authorized-keys [context]
  (let [source (fs/path (:generation context) "authorized_keys")
        destination (fs/path (:state context) "authorized_keys")]
    (doseq [entry (entries source)]
      (atomic-install context entry (fs/path destination (fs/file-name entry)) "600"
                      (str "." (fs/file-name entry) "." (process-pid))))
    (doseq [entry (entries destination)]
      (when (and (fs/regular-file? entry)
                 (not (fs/regular-file? (fs/path source (fs/file-name entry)))))
        (fs/delete-if-exists entry)))))

(defn supervised? [context directory]
  (and (= 8r010000 (bit-and (mode-bits (fs/path directory "supervise/control")) 8r170000))
       (probe-command [(get (:tools context) "sv") "status" directory])))

(defn remove-obsolete-services [context]
  (let [service-root (fs/path (:state context) "services")
        generation-services (fs/path (:generation context) "services")]
    (doseq [directory (entries service-root)]
      (when-not (fs/exists? (fs/path generation-services (fs/file-name directory)))
        (check-directory directory)
        (when (supervised? context directory)
          (run-tool context "sv" "-w" "10" "down" directory)
          (run-tool context "sv" "-w" "10" "exit" directory))
        (fs/delete-tree directory)))))

(defn invalidate-oneshots [context]
  (let [service-root (fs/path (:state context) "services")]
    (doseq [entry (entries (fs/path (:generation context) "services"))
            :let [directory (fs/path service-root (fs/file-name entry))]
            :when (or (fs/regular-file? (fs/path entry "oneshot"))
                      (fs/regular-file? (fs/path directory "oneshot")))]
      (when (supervised? context directory)
        (run-tool context "sv" "-w" "10" "down" directory))
      (fs/delete-if-exists (fs/path directory "completed"))
      (fs/delete-if-exists (fs/path directory "exit-status")))))

(defn configure-service [context entry]
  (let [name (fs/file-name entry)
        directory (fs/path (:state context) "services" name)
        previous-run (when (fs/sym-link? (fs/path directory "run"))
                       (str (fs/read-link (fs/path directory "run"))))
        target (str (fs/real-path (fs/path entry "run")))
        previous-oneshot (fs/regular-file? (fs/path directory "oneshot"))
        oneshot (fs/regular-file? (fs/path entry "oneshot"))
        destination (if (fs/directory? directory)
                      directory
                      (fs/create-temp-dir {:dir (:state context)
                                           :prefix (str ".service." name ".")}))
        run-link (fs/path destination (str ".run." (process-pid)))]
    (run-tool context "chmod" "700" destination)
    (fs/create-sym-link run-link target)
    (fs/move run-link (fs/path destination "run") {:replace-existing true :atomic-move true})
    (if oneshot
      (do
        (spit (str (fs/path destination "oneshot")) "")
        (spit (str (fs/path destination "down")) "")
        (let [finish-link (fs/path destination (str ".finish." (process-pid)))]
          (fs/create-sym-link finish-link (fs/real-path (fs/path entry "finish")))
          (fs/move finish-link (fs/path destination "finish")
                   {:replace-existing true :atomic-move true})))
      (do
        (fs/delete-if-exists (fs/path destination "oneshot"))
        (fs/delete-if-exists (fs/path destination "finish"))
        (when previous-oneshot (fs/delete-if-exists (fs/path destination "down")))))
    (when-not (= (str destination) (str directory))
      (fs/move destination directory {:atomic-move true}))
    (when (and (not oneshot)
               (or (not= previous-run target) previous-oneshot)
               (supervised? context directory))
      (run-tool context "sv" "-w" "10" "restart" directory))))

(defn publish-services [context]
  (doseq [entry (entries (fs/path (:generation context) "services"))]
    (let [directory (fs/path (:state context) "services" (fs/file-name entry))]
      (check-directory directory)
      (configure-service context entry))))

(defn supervisor-running? [context]
  (let [pid-file (fs/path (:state context) "supervisor.pid")]
    (when (fs/regular-file? pid-file)
      (let [pid (str/trim (slurp (str pid-file)))]
        (when (re-matches #"[0-9]+" pid)
          (try
            (let [number (Long/parseLong pid)]
              (and (pos? number)
                   (some-> (java.lang.ProcessHandle/of number) (.orElse nil) (.isAlive))
                   (fs/regular-file? (fs/path "/proc" pid "cmdline"))
                   (str/includes? (slurp (str (fs/path "/proc" pid "cmdline"))) "runsvdir")))
            ;; A process can disappear between the PID and cmdline observations.
            (catch Exception _ false)))))))

(defn start-supervisor [context boundary]
  (when-not (supervisor-running? context)
    (when-not (fs/executable? (:launcher context))
      (fail "namespace launcher unavailable"))
    (run-tool context "sh" boundary "spawn"
              (fs/path (:state context) "supervisor.log")
              (fs/path (:state context) "supervisor.pid")
              (:launcher context) "--etc" (:etc-root context) "--"
              (fs/path (:system-profile context) "bin/runsvdir")
              (fs/path (:state context) "services"))))

(defn start-oneshots [context]
  (doseq [entry (entries (fs/path (:generation context) "services"))
          :when (fs/regular-file? (fs/path entry "oneshot"))]
    (let [directory (fs/path (:state context) "services" (fs/file-name entry))]
      (loop [attempts 0]
        (when-not (probe-command [(get (:tools context) "sv") "status" directory])
          (when (>= (inc attempts) 10)
            (fail (str "oneshot is not supervised: " (fs/file-name entry))))
          (run-tool context "sleep" "1")
          (recur (inc attempts))))
      (run-tool context "sv" "up" directory))))

(defn await-nix-daemon [context]
  (when (fs/directory? (fs/path (:generation context) "services/nix-daemon"))
    (loop [attempts 0]
      (let [result (process/shell {:out :string :err :string :continue true
                                   :extra-env (merge *process-environment*
                                                     {"PATH" (:path context) "NIX_REMOTE" "daemon"})}
                                  (str (fs/path (:system-profile context) "bin/nix"))
                                  "--extra-experimental-features" "nix-command"
                                  "store" "ping" "--store" "daemon")]
        (when-not (zero? (:exit result))
          (when (>= (inc attempts) 30)
            (fail "Nix daemon did not become available"))
          (run-tool context "sleep" "1")
          (recur (inc attempts)))))))

(defn activate-locked [generation mode]
  (let [context (-> (create-context generation mode) validate-generation)
        boundary (str (fs/path (fs/parent *file*) "process-boundary.sh"))]
    (when-not (fs/executable? boundary)
      (fail (str "missing process boundary: " boundary)))
    (binding [*process-environment* {"PATH" (:path context)
                                     "NIX_REMOTE" "local"
                                     "NIX_CONF_DIR" (:nix-conf context)}]
      (prepare-state context)
      (publish-generated-etc context)
      (publish-profiles context)
      (publish-authorized-keys context)
      (when (fs/regular-file? (fs/path generation "sshd-enabled"))
        (atomic-install context (fs/path generation "sshd_config")
                        (fs/path (:state context) "sshd_config") "600"
                        (str ".sshd_config." (process-pid))))
      (remove-obsolete-services context)
      (invalidate-oneshots context)
      (publish-services context)
      (start-supervisor context boundary)
      (start-oneshots context)
      (await-nix-daemon context))))

(defn activation-arguments [arguments]
  (let [[generation mode & trailing] arguments]
    (when-not (and (= 2 (count arguments)) (contains? #{"switch" "boot"} mode))
      (fail "usage: activate.clj GENERATION switch|boot"))
    (when (seq trailing) (fail "unexpected activation arguments"))
    (when-not (fs/absolute? generation)
      (fail (str "directory is not absolute: " generation)))
    [generation mode]))

(defn main []
  (let [arguments *command-line-args*]
    (when (= ["--help"] arguments)
      (println "Usage: activate.clj GENERATION switch|boot")
      (System/exit 0)))
  (let [arguments *command-line-args*
        locked? (= "--locked" (last arguments))
        arguments (if locked? (butlast arguments) arguments)
        [generation mode] (activation-arguments arguments)
        uid (str/trim (:out (process/shell {:out :string :err :string :continue true} "id" "-u")))]
    (when-not (= "0" uid) (fail "activation requires root"))
    (if locked?
      (activate-locked generation mode)
      (let [bb (.orElse (.command (.info (java.lang.ProcessHandle/current))) nil)
            script (str (fs/canonicalize *file*))
            generation-path (str (fs/absolutize generation))
            path (str (fs/path generation-path "system-profile/bin") ":" immutable-path)
            tools (tool-paths path)
            state (or (System/getenv "NNS_STATE_DIRECTORY") "/data/nix/var/nns")
            state-parent (fs/parent state)
            boundary (str (fs/path (fs/parent script) "process-boundary.sh"))]
        (when-not bb (fail "missing system tool: bb"))
        (let [context (validate-generation (create-context generation-path mode))]
          (doseq [directory [(:state context) (fs/parent (:state context))
                             (:etc-root context) (fs/parent (:etc-root context))
                             (:profiles context) (fs/parent (:profiles context))
                             (:nix-conf context) (fs/parent (:nix-conf context))]]
            (check-directory directory))
          (doseq [directory (concat [(fs/path (:state context) "services")
                                     (fs/path (:state context) "authorized_keys")]
                                    (entries (fs/path (:state context) "services")))]
            (when (or (fs/exists? directory) (fs/sym-link? directory))
              (check-directory directory))))
        (when-not (fs/executable? boundary)
          (fail (str "missing process boundary: " boundary)))
        (when (fs/sym-link? (str state ".lock"))
          (fail "activation lock is a symlink"))
        (fs/create-dirs state-parent)
        (process/exec {:extra-env {"PATH" path}}
                      (get tools "sh") boundary "lock" (str state ".lock") bb script
                      generation-path mode "--locked")))))

(try
  (main)
  (catch clojure.lang.ExceptionInfo exception
    (binding [*out* *err*]
      (println (str "nns activation: " (ex-message exception))))
    (System/exit 1)))
