package org.nns.signing

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Process
import android.os.UserManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import java.io.File
import java.nio.file.Files
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

/** Disposable lab state. This instrumentation never reads other apps' data. */
class SigningStateInstrumentation : Instrumentation() {
    private lateinit var phase: String

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        phase = arguments?.getString("phase", "verify") ?: "verify"
        start()
    }

    private fun Context.readState(name: String) = Files.readAllBytes(File(filesDir, name).toPath())

    private fun Context.writeState(name: String, contents: ByteArray) {
        check(!File(filesDir, name).exists()) { "Refusing to overwrite seeded state: $name" }
        openFileOutput(name, Context.MODE_PRIVATE).use {
            it.write(contents)
            it.fd.sync()
        }
    }

    private fun digest(contents: ByteArray) = MessageDigest.getInstance("SHA-256")
        .digest(contents).joinToString("") { "%02x".format(it.toInt() and 255) }

    private fun checkStorage(context: Context, key: SecretKey): String = with(context) {
        if (phase == "seed") {
            val marker = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.ENCRYPT_MODE, key)
            }
            val encrypted = cipher.doFinal(marker)
            writeState("nns-signing-marker.bin", marker)
            writeState("nns-signing-iv.bin", cipher.iv)
            writeState("nns-signing-ciphertext.bin", encrypted)
        }
        val marker = readState("nns-signing-marker.bin")
        val decrypted = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, readState("nns-signing-iv.bin")))
            doFinal(readState("nns-signing-ciphertext.bin"))
        }
        check(marker.size == 32 && marker.contentEquals(decrypted)) {
            "Persisted state failed authenticated decryption"
        }
        digest(marker)
    }

    override fun onStart() {
        super.onStart()
        val report = JSONObject().put("phase", phase)
        val resultCode = try {
            require(phase in setOf("seed", "verify")) { "Expected seed or verify phase" }
            val context = targetContext
            check(checkNotNull(context.getSystemService(UserManager::class.java)).isUserUnlocked) {
                "User credential-encrypted storage is locked"
            }
            val alias = "${context.packageName}.signing-state"
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            if (phase == "seed") {
                check(!store.containsAlias(alias)) { "Refusing to replace an existing key" }
                KeyGenerator.getInstance("AES", "AndroidKeyStore").apply {
                    init(KeyGenParameterSpec.Builder(alias,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .build())
                }.generateKey()
            }
            check(store.containsAlias(alias)) { "Persisted keystore alias is missing" }
            val key = store.getKey(alias, null) as SecretKey
            val information = SecretKeyFactory.getInstance("AES", "AndroidKeyStore")
                .getKeySpec(key, KeyInfo::class.java) as KeyInfo
            val permission = if (context.packageName.endsWith(".system")) {
                "android.permission.INTERACT_ACROSS_USERS_FULL"
            } else {
                "android.permission.POST_NOTIFICATIONS"
            }
            val certificate = context.packageManager.getPackageInfo(context.packageName,
                PackageManager.GET_SIGNING_CERTIFICATES).signingInfo!!
                .apkContentsSigners.single().toByteArray()
            report.put("credential_encrypted_sha256", checkStorage(context, key))
                .put("device_encrypted_sha256", checkStorage(context.createDeviceProtectedStorageContext(), key))
                .put("key_security_level", information.securityLevel)
                .put("key_user_authentication_required", information.isUserAuthenticationRequired)
                .put("package", context.packageName)
                .put("uid", Process.myUid())
                .put("permission", permission)
                .put("permission_granted", context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED)
                .put("certificate_sha256", digest(certificate))
                .put("passed", true)
            Activity.RESULT_OK
        } catch (failure: Exception) {
            report.put("passed", false)
                .put("error", "${failure.javaClass.name}: ${failure.message}")
            Activity.RESULT_CANCELED
        }
        finish(resultCode, Bundle().apply { putString("nns.signing.state", report.toString()) })
    }
}
