{ lib, writeText }:
let
  appDomains = [ "untrusted_app" "untrusted_app_25" "untrusted_app_27" "untrusted_app_32" ];
  forAppDomains = rule: lib.concatMapStringsSep "\n" rule appDomains;
  transitions = lib.concatStringsSep "\n" [
    (forAppDomains (domain: "allow ${domain} nns_exec file { getattr open read execute map }"))
    (forAppDomains (domain: "allow ${domain} nns_app process { transition siginh rlimitinh }"))
    (forAppDomains (domain: "allow ${domain} nns_app process2 { nnp_transition nosuid_transition }"))
    (forAppDomains (domain: "allow ${domain} nns_app process noatsecure"))
    (forAppDomains (domain: "allow nns_app ${domain} process sigchld"))
  ];
  typeTransitions = forAppDomains (domain: "type_transition ${domain} nns_exec process nns_app");
  fifoRules = forAppDomains (domain: "allow nns_app ${domain} fifo_file { read write open getattr ioctl append }");
in
writeText "nns-sepolicy.rule" (lib.replaceStrings
  [ "@APP_TRANSITIONS@" "@APP_TYPE_TRANSITIONS@" "@APP_FIFO_RULES@" ]
  [ transitions typeTransitions fifoRules ]
  (builtins.readFile ../module/sepolicy.rule.in))
