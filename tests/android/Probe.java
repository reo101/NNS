package xyz.reo101.nnstest;

import android.app.Instrumentation;
import android.os.Bundle;
import android.system.Os;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/** A real zygote app process, not adb shell, run-as, or a root proxy. */
public final class Probe extends Instrumentation {
    private Bundle arguments;

    @Override public void onCreate(Bundle args) {
        super.onCreate(args);
        arguments = args;
        start();
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            int uid = Os.getuid();
            String status = new String(Files.readAllBytes(Paths.get("/proc/self/status")), StandardCharsets.UTF_8);
            String domain = new String(Files.readAllBytes(Paths.get("/proc/self/attr/current")), StandardCharsets.UTF_8);
            if (uid < 10000 || !status.contains("Seccomp:\t2") || !domain.contains(":untrusted_app:"))
                throw new AssertionError("not an ordinary filtered app: uid=" + uid + " domain=" + domain + "\n" + status);
            if ("global-mount".equals(arguments.getString("mode"))) {
                android.system.StructStat source = Os.stat("/data/nix");
                android.system.StructStat target = Os.stat("/nix");
                if (source.st_dev != target.st_dev || source.st_ino != target.st_ino)
                    throw new AssertionError("/nix is not the backing directory");
                String proof = new String(Files.readAllBytes(Paths.get("/nix/mount-proof")), StandardCharsets.UTF_8);
                if (!"global-store\n".equals(proof))
                    throw new AssertionError("global store content missing");
                try {
                    Os.open("/nix/app-write", android.system.OsConstants.O_CREAT |
                        android.system.OsConstants.O_WRONLY, 0600);
                    throw new AssertionError("app can write the root-owned backing directory");
                } catch (android.system.ErrnoException expected) {
                    if (expected.errno != android.system.OsConstants.EACCES)
                        throw expected;
                }
                result.putString("result", "NNS-GLOBAL-MOUNT-PASS");
                finish(-1, result);
                return;
            }
            if (new File("/nix/store").exists()) throw new AssertionError("/nix leaked outside launcher");
            String ns = Os.readlink("/proc/self/ns/user");
            File home = getTargetContext().getFilesDir();
            File tmp = getTargetContext().getCacheDir();
            boolean blocked = "blocked".equals(arguments.getString("mode"));
            ProcessBuilder pb = new ProcessBuilder("/data/nix/bin/nix-enter", "--tmpdir", tmp.toString(), "--",
                "/system/bin/sh", "/data/nix/etc/test-app.sh", Integer.toString(uid), ns);
            pb.directory(home);
            pb.redirectErrorStream(true);
            Map<String, String> env = pb.environment();
            env.put("HOME", home.toString());
            env.put("TMPDIR", tmp.toString());
            env.put("USER", "nns-test");
            env.put("LOGNAME", "nns-test");
            env.put("PATH", "/nix/var/nix/profiles/profile/bin:/system/bin");
            env.put("NIX_CONF_DIR", "/data/nix/etc/nix");
            env.put("NIX_REMOTE", "daemon");
            Process child = pb.start();
            if (!child.waitFor(120, TimeUnit.SECONDS)) {
                child.destroyForcibly();
                throw new AssertionError("launcher timed out");
            }
            String output = new String(child.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
            result.putString("output", output);
            if (blocked) {
                if (child.exitValue() == 0 || output.contains("NNS-APP-PASS"))
                    throw new AssertionError("launcher succeeded with seccomp bypass disabled");
                result.putString("result", "NNS-BLOCKED-PASS");
            } else {
                if (child.exitValue() != 0 || !output.contains("NNS-APP-PASS"))
                    throw new AssertionError("launcher failed (" + child.exitValue() + "):\n" + output);
                if (!Os.readlink("/proc/self/ns/user").equals(ns) || new File("/nix/store").exists())
                    throw new AssertionError("launcher changed the parent namespace");
                result.putString("result", "NNS-INSTRUMENTATION-PASS");
            }
            finish(-1, result);
        } catch (Throwable failure) {
            result.putString("failure", failure.toString());
            finish(1, result);
        }
    }
}
