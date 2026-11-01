package org.nns.storage.fixture;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Process;
import android.os.UserManager;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

public final class StorageReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        JSONObject report = new JSONObject();
        try {
            Context protectedContext = context.createDeviceProtectedStorageContext();
            report.put("uid", Process.myUid());
            report.put("user_unlocked", context.getSystemService(UserManager.class).isUserUnlocked());
            report.put("device_protected", protectedContext.isDeviceProtectedStorage());
            try (FileInputStream image = new FileInputStream("/data/nns-storage/nix.btrfs")) {
                image.read();
                report.put("private_image_denied", false);
            } catch (java.io.IOException expected) {
                report.put("private_image_denied", true);
            }
            java.lang.Process child = new ProcessBuilder("/nix/storage-execution")
                    .redirectErrorStream(true).start();
            String output;
            try (java.io.InputStream stream = child.getInputStream()) {
                output = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
            }
            report.put("exit_code", child.waitFor());
            report.put("output", output);
            File file = new File(protectedContext.getFilesDir(), "storage-report.json");
            try (FileOutputStream stream = new FileOutputStream(file)) {
                stream.write(report.toString().getBytes(StandardCharsets.UTF_8));
                stream.getFD().sync();
            }
            setResultCode(Activity.RESULT_OK);
        } catch (Exception error) {
            try {
                report.put("error", error.toString());
            } catch (org.json.JSONException ignored) {
                throw new AssertionError(ignored);
            }
            setResultCode(Activity.RESULT_CANCELED);
        }
        setResultData(report.toString());
    }
}
