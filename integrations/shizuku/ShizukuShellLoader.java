/* SPDX-License-Identifier: Apache-2.0
 * NNS client for Shizuku's permission-checked process API.
 * Based on RikkaApps/Shizuku's binder and permission callbacks.
 */
package rikka.shizuku.shell;

import android.content.Context;
import android.content.Intent;
import android.os.Binder;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Parcel;
import android.os.ParcelFileDescriptor;
import android.os.RemoteException;
import android.system.Os;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import moe.shizuku.server.IRemoteProcess;
import moe.shizuku.server.IShizukuApplication;
import moe.shizuku.server.IShizukuService;

public final class ShizukuShellLoader {
    private static final String TERMINAL_HELPER = "/data/nix/bin/nns-rish-terminal";
    private static String[] arguments;
    private static String callingPackage;
    private static Handler handler;
    private static Runnable timeout;
    private static IShizukuService service;
    private static volatile IRemoteProcess remote;
    private static volatile Process console;
    private static final AtomicBoolean started = new AtomicBoolean();
    private static final AtomicBoolean consoleStopped = new AtomicBoolean();
    private static final AtomicBoolean relayFailed = new AtomicBoolean();
    private static boolean permissionPending;

    private static final IShizukuApplication application = new IShizukuApplication.Stub() {
        @Override
        public void bindApplication(Bundle data) {
            handler.post(() -> {
                try {
                    if (service.checkSelfPermission()) {
                        startProcess();
                    } else if (service.shouldShowRequestPermissionRationale()) {
                        fail("Shizuku permission denied");
                    } else {
                        permissionPending = true;
                        service.requestPermission(0);
                    }
                } catch (RemoteException failure) {
                    fail("Cannot request Shizuku permission: " + failure);
                }
            });
        }

        @Override
        public void dispatchRequestPermissionResult(int requestCode, Bundle data) {
            handler.post(() -> {
                if (requestCode != 0 || !permissionPending) return;
                permissionPending = false;
                if (!data.getBoolean("shizuku:request-permission-reply-allowed", false)) {
                    fail("Shizuku permission denied");
                }
                startProcess();
            });
        }

        @Override
        public void showPermissionConfirmation(int uid, int pid, String name, int requestCode) {
            // Only the Shizuku manager implements this callback.
        }
    };

    private static final Binder receiver = new Binder() {
        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
                throws RemoteException {
            if (code != 1) return super.onTransact(code, data, reply, flags);
            IBinder binder = data.readStrongBinder();
            data.readString(); // Manager APK path, unused by this client.
            if (binder == null) {
                fail("Shizuku server is not running");
            } else {
                handler.post(() -> connect(binder));
            }
            return true;
        }
    };

    private static void fail(String message) {
        System.err.println(message);
        System.err.flush();
        System.exit(1);
    }

    private static void stopConsole() {
        Process process = console;
        if (process == null) return;
        consoleStopped.set(true);
        process.destroy();
        try {
            if (!process.waitFor(2, TimeUnit.SECONDS)) {
                process.destroyForcibly();
                process.waitFor();
            }
        } catch (InterruptedException failure) {
            Thread.currentThread().interrupt();
            process.destroyForcibly();
        }
    }

    private static void stopRemote() {
        IRemoteProcess process = remote;
        if (process == null) return;
        try {
            process.destroy();
        } catch (RemoteException ignored) {
            // Binder death already ends the client and its owned process.
        }
    }

    private static Thread relayOutput(InputStream input, OutputStream output) {
        Thread thread = new Thread(() -> {
            try (InputStream source = input) {
                byte[] buffer = new byte[8192];
                int count;
                while ((count = source.read(buffer)) != -1) {
                    output.write(buffer, 0, count);
                    output.flush();
                }
            } catch (Exception failure) {
                relayFailed.set(true);
                failure.printStackTrace(System.err);
                stopRemote();
            }
        }, "nns-rish-output");
        thread.setDaemon(true);
        thread.start();
        return thread;
    }

    private static void runProcess() {
        try {
            int tty = (Os.isatty(FileDescriptor.in) ? 1 : 0)
                    | (Os.isatty(FileDescriptor.out) ? 2 : 0)
                    | (Os.isatty(FileDescriptor.err) ? 4 : 0);
            String ttyPath = tty == 0 ? "" : "/proc/" + Os.getpid() + "/fd/"
                    + ((tty & 1) != 0 ? "0" : (tty & 2) != 0 ? "1" : "2");
            List<String> command = new ArrayList<>();
            command.add(TERMINAL_HELPER);
            command.add("--host");
            command.add(Integer.toString(tty));
            for (String argument : arguments) command.add(argument);
            List<String> environment = new ArrayList<>();
            for (Map.Entry<String, String> entry : System.getenv().entrySet()) {
                if (!entry.getKey().equals("NNS_RISH_COMPLETION_FILE")) {
                    environment.add(entry.getKey() + "=" + entry.getValue());
                }
            }
            remote = service.newProcess(command.toArray(new String[0]),
                    environment.toArray(new String[0]), new File("").getAbsolutePath());
            Thread stdout = relayOutput(
                    new ParcelFileDescriptor.AutoCloseInputStream(remote.getInputStream()),
                    new FileOutputStream(FileDescriptor.out));
            Thread stderr = relayOutput(
                    new ParcelFileDescriptor.AutoCloseInputStream(remote.getErrorStream()),
                    new FileOutputStream(FileDescriptor.err));
            OutputStream remoteInput =
                    new ParcelFileDescriptor.AutoCloseOutputStream(remote.getOutputStream());
            console = new ProcessBuilder(TERMINAL_HELPER, "--input", Integer.toString(tty), ttyPath)
                    .redirectInput(ProcessBuilder.Redirect.INHERIT)
                    .redirectError(ProcessBuilder.Redirect.INHERIT).start();
            Thread input = new Thread(() -> {
                try (InputStream source = console.getInputStream(); OutputStream target = remoteInput) {
                    byte[] buffer = new byte[8192];
                    int count;
                    while ((count = source.read(buffer)) != -1) {
                        target.write(buffer, 0, count);
                        target.flush();
                    }
                } catch (Exception ignored) {
                    // The remote process may exit before local input ends.
                }
                try {
                    int status = console.waitFor();
                    if (!consoleStopped.get() && status != 0) {
                        relayFailed.set(true);
                        stopRemote();
                    }
                } catch (InterruptedException failure) {
                    Thread.currentThread().interrupt();
                    relayFailed.set(true);
                    stopRemote();
                }
            }, "nns-rish-input");
            input.setDaemon(true);
            input.start();
            int status = remote.waitFor();
            stopConsole();
            stdout.join();
            stderr.join();
            input.join();
            if (relayFailed.get()) fail("Shizuku stream relay failed");
            String completion = System.getenv("NNS_RISH_COMPLETION_FILE");
            if (completion != null) {
                try (FileOutputStream output = new FileOutputStream(completion)) {
                    output.write("complete\n".getBytes(StandardCharsets.US_ASCII));
                }
            }
            System.exit(status);
        } catch (Throwable failure) {
            failure.printStackTrace(System.err);
            fail("Cannot run the Shizuku process");
        }
    }

    private static void startProcess() {
        if (started.compareAndSet(false, true)) {
            new Thread(ShizukuShellLoader::runProcess, "nns-rish-process").start();
        }
    }

    private static void connect(IBinder binder) {
        handler.removeCallbacks(timeout);
        try {
            binder.linkToDeath(() -> fail("Shizuku server disconnected"), 0);
            service = IShizukuService.Stub.asInterface(binder);
            Bundle options = new Bundle();
            options.putInt("shizuku:attach-api-version", 13);
            options.putString("shizuku:attach-package-name", callingPackage);
            service.attachApplication(application, options);
        } catch (Throwable failure) {
            failure.printStackTrace(System.err);
            fail("Cannot initialize the Shizuku client");
        }
    }

    public static void main(String[] args) {
        arguments = args;
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            stopConsole();
            stopRemote();
        }, "nns-rish-cleanup"));
        try {
            Looper.prepareMainLooper();
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Object thread = activityThread.getDeclaredMethod("systemMain").invoke(null);
            Context system = (Context) activityThread.getDeclaredMethod("getSystemContext")
                    .invoke(thread);
            String[] packages = system.getPackageManager().getPackagesForUid(Os.getuid());
            callingPackage = packages != null && packages.length == 1
                    ? packages[0] : System.getenv("RISH_APPLICATION_ID");
            if (callingPackage == null || callingPackage.isEmpty()) {
                fail("RISH_APPLICATION_ID is not set");
            }
            Context context = system.createPackageContext(callingPackage, 0);
            handler = new Handler(Looper.getMainLooper());
            timeout = () -> fail("Timed out requesting the Shizuku binder");
            Bundle data = new Bundle();
            data.putBinder("binder", receiver);
            Intent request = new Intent("rikka.shizuku.intent.action.REQUEST_BINDER")
                    .setPackage("moe.shizuku.privileged.api")
                    .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)
                    .putExtra("data", data);
            context.sendBroadcast(request);
            handler.postDelayed(timeout, 5000);
            Looper.loop();
            fail("Shizuku client event loop stopped unexpectedly");
        } catch (Throwable failure) {
            failure.printStackTrace(System.err);
            fail("Cannot start the Shizuku client");
        }
    }
}
