/* SPDX-License-Identifier: Apache-2.0
 * NNS loader for the Shizuku rish client API.
 * Based on RikkaApps/Shizuku's ShizukuShellLoader and permission callbacks.
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
import android.os.RemoteException;
import android.system.Os;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import moe.shizuku.server.IShizukuApplication;
import moe.shizuku.server.IShizukuService;
import rikka.rish.Rish;
import rikka.rish.RishConfig;

public final class ShizukuShellLoader {
    private static String[] arguments;
    private static String callingPackage;
    private static Handler handler;
    private static Runnable timeout;
    private static Runnable permissionGranted;
    private static IShizukuService service;

    private static final IShizukuApplication application = new IShizukuApplication.Stub() {
        @Override
        public void bindApplication(Bundle data) {
            handler.post(() -> new Rish() {
                @Override
                public void requestPermission(Runnable onGranted) {
                    try {
                        if (service.checkSelfPermission()) {
                            onGranted.run();
                        } else if (service.shouldShowRequestPermissionRationale()) {
                            fail("Shizuku permission denied");
                        } else {
                            permissionGranted = onGranted;
                            service.requestPermission(0);
                        }
                    } catch (RemoteException failure) {
                        fail("Cannot request Shizuku permission: " + failure);
                    }
                }
            }.start(arguments));
        }

        @Override
        public void dispatchRequestPermissionResult(int requestCode, Bundle data) {
            handler.post(() -> {
                if (requestCode != 0 || permissionGranted == null) return;
                if (!data.getBoolean("shizuku:request-permission-reply-allowed", false)) {
                    fail("Shizuku permission denied");
                }
                Runnable granted = permissionGranted;
                permissionGranted = null;
                granted.run();
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
            String source = data.readString();
            if (binder == null) {
                fail("Shizuku server is not running");
            } else {
                handler.post(() -> connect(binder, source));
            }
            return true;
        }
    };

    private static void fail(String message) {
        System.err.println(message);
        System.err.flush();
        System.exit(1);
    }

    private static void connect(IBinder binder, String source) {
        handler.removeCallbacks(timeout);
        try {
            Class<?> runtimeType = Class.forName("dalvik.system.VMRuntime");
            Object runtime = runtimeType.getDeclaredMethod("getRuntime").invoke(null);
            String instructionSet = (String) runtimeType.getDeclaredMethod("vmInstructionSet")
                    .invoke(runtime);
            String libraries = new File(source).getParent() + "/lib/" + instructionSet;
            RishConfig.setLibraryPath(libraries);
            RishConfig.init(binder, "moe.shizuku.server.IShizukuService", 30000);
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
        String completion = System.getenv("NNS_RISH_COMPLETION_FILE");
        if (completion != null) {
            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                try (FileOutputStream output = new FileOutputStream(completion)) {
                    output.write("complete\n".getBytes(StandardCharsets.US_ASCII));
                } catch (Exception failure) {
                    failure.printStackTrace(System.err);
                }
            }));
        }
        arguments = args;
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
