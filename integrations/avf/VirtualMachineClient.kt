package xyz.reo101.nns.avf

import android.content.Context
import android.content.ContextWrapper
import android.os.Looper
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.nio.charset.StandardCharsets
import org.json.JSONArray
import org.json.JSONObject

/**
 * Terminal-free AVF launcher: creates and runs a VM from an image payload's
 * `vm_config.json` (nixos-avf / ferrochrome layout) and shares /data/nix/store
 * with the guest over virtiofs (tag "nix-store"), relaying guest console and
 * log output until the VM stops. With no arguments it runs the probe guest
 * used to validate the share end to end.
 */
object VirtualMachineClient {
    private const val STATE_DIRECTORY = "/data/nix/var/avf"
    private const val STORE_PATH = "/data/nix/store"
    // Probe guest (no payload argument).
    private const val PROBE_KERNEL = "/data/local/tmp/nns-vmlinuz"
    private const val PROBE_INITRD = "/data/local/tmp/nns-probe-initramfs.cpio"
    // Host RAM budget for the guest until balloon/swap behaviour is proven.
    private const val PAYLOAD_MEMORY_CAP_MIB = 2048

    private var vmName: String = "nns-guest"
    private var consoleDevice: String = "ttyS0"
    private var memoryBytes: Long = 0
    private var protectedVm: Boolean = false

    @JvmStatic
    fun main(arguments: Array<String>) {
        try {
            execute(arguments)
            System.exit(0)
        } catch (failure: Throwable) {
            failure.printStackTrace()
            System.exit(1)
        }
    }

    private fun execute(arguments: Array<String>) {
        val sharedPathType = Class.forName(
            "android.system.virtualmachine.VirtualMachineCustomImageConfig\$SharedPath"
        )
        val imageBuilderType = Class.forName(
            "android.system.virtualmachine.VirtualMachineCustomImageConfig\$Builder"
        )
        val image = if (arguments.isNotEmpty()) {
            buildPayloadImage(sharedPathType, imageBuilderType, arguments[0])
        } else {
            buildProbeImage(sharedPathType, imageBuilderType)
        }

        Looper.prepareMainLooper()
        val activityThread = Class.forName("android.app.ActivityThread")
        val thread = activityThread.getMethod("systemMain").invoke(null)
        val systemContext = activityThread.getMethod("getSystemContext")
            .invoke(thread) as Context
        val context = object : ContextWrapper(systemContext) {
            override fun getDataDir(): File = File(STATE_DIRECTORY)

            // Hidden API: overrides Context#createCredentialProtectedStorageContext
            // at runtime; absent from the public SDK, hence no override modifier.
            fun createCredentialProtectedStorageContext(): Context = this
        }

        val managerType = Class.forName(
            "android.system.virtualmachine.VirtualMachineManager"
        )
        val manager = managerType.getConstructor(Context::class.java)
            .newInstance(context)
        val capabilities = managerType.getMethod("getCapabilities").invoke(manager) as Int

        val vmConfigType = Class.forName(
            "android.system.virtualmachine.VirtualMachineConfig"
        )
        val configBuilderType = Class.forName(
            "android.system.virtualmachine.VirtualMachineConfig\$Builder"
        )
        val configBuilder = configBuilderType.getConstructor(Context::class.java)
            .newInstance(context)
        configBuilderType.getMethod("setCustomImageConfig", image.javaClass)
            .invoke(configBuilder, image)
        configBuilderType.getMethod("setProtectedVm", Boolean::class.javaPrimitiveType)
            .invoke(configBuilder, protectedVm)
        configBuilderType.getMethod("setMemoryBytes", Long::class.javaPrimitiveType)
            .invoke(configBuilder, memoryBytes)
        configBuilderType.getMethod("setConsoleInputDevice", String::class.java)
            .invoke(configBuilder, consoleDevice)
        configBuilderType.getMethod("setDebugLevel", Int::class.javaPrimitiveType)
            .invoke(configBuilder, 1)
        configBuilderType.getMethod("setVmOutputCaptured", Boolean::class.javaPrimitiveType)
            .invoke(configBuilder, true)
        val vmConfig = configBuilderType.getMethod("build").invoke(configBuilder)

        val virtualizationServiceType = Class.forName(
            "android.system.virtualmachine.VirtualizationService"
        )
        try {
            val getInstance = virtualizationServiceType.getDeclaredMethod("getInstance")
            getInstance.isAccessible = true
            val service = getInstance.invoke(null)
            println("VirtualizationService acquired: $service")
        } catch (serviceFailure: Throwable) {
            println("VirtualizationService acquisition FAILED:")
            serviceFailure.printStackTrace()
        }

        try {
            managerType.getMethod("delete", String::class.java)
                .invoke(manager, vmName)
        } catch (deleteFailure: Throwable) {
            println("delete failed: $deleteFailure")
        }
        val vmDirectory = File("$STATE_DIRECTORY/vm/$vmName")
        if (vmDirectory.exists()) {
            println("Removing stale VM directory by hand: $vmDirectory")
            deleteTree(vmDirectory)
        }
        val vm = managerType.getMethod("create", String::class.java, vmConfigType)
            .invoke(manager, vmName, vmConfig)
        println(
            "VM $vmName created; capabilities=$capabilities; " +
                "state directory=$STATE_DIRECTORY"
        )

        val console = vm.javaClass.getMethod("getConsoleOutput").invoke(vm) as InputStream
        val logs = vm.javaClass.getMethod("getLogOutput").invoke(vm) as InputStream

        vm.javaClass.getMethod("run").invoke(vm)
        println("VM started; relaying console output")

        var sawRunning = false
        var deadline = System.currentTimeMillis() + 600_000
        var lastStatus = -1
        while (System.currentTimeMillis() < deadline) {
            val status = vm.javaClass.getMethod("getStatus").invoke(vm) as Int
            if (status != lastStatus) {
                println("VM status: $status")
                lastStatus = status
            }
            if (status == 1) {
                sawRunning = true
            } else if (sawRunning && status == 0) {
                break
            }
            drain(console, "console")
            drain(logs, "log")
            Thread.sleep(500)
        }
        if (lastStatus != 0) {
            println("VM still running at deadline; stopping it")
            try {
                vm.javaClass.getMethod("stop").invoke(vm)
            } catch (stopFailed: Throwable) {
                stopFailed.printStackTrace()
            }
        }
        Thread.sleep(2_000)
        drain(console, "console")
        drain(logs, "log")
        println(
            "Finished; directory=$vmDirectory; files=" +
                (vmDirectory.list()?.joinToString(", ") ?: "null")
        )
    }

    private fun buildPayloadImage(
        sharedPathType: Class<*>,
        imageBuilderType: Class<*>,
        payloadDirectory: String
    ): Any {
        val payload = File(payloadDirectory).canonicalFile
        val config = JSONObject(readAll(File(payload, "vm_config.json")))
        vmName = "nns-guest"
        consoleDevice = config.optString("console_input_device", "ttyS0")
        val requestedMib = config.optInt("memory_mib", 4096)
        memoryBytes = minOf(requestedMib, PAYLOAD_MEMORY_CAP_MIB).toLong() * 1024 * 1024
        protectedVm = config.optBoolean("protected", false)

        val builder = imageBuilderType.getConstructor().newInstance()
        imageBuilderType.getMethod("setName", String::class.java)
            .invoke(builder, config.optString("name", "nns-guest"))

        val diskType = Class.forName(
            "android.system.virtualmachine.VirtualMachineCustomImageConfig\$Disk"
        )
        val partitionType = Class.forName(
            "android.system.virtualmachine.VirtualMachineCustomImageConfig\$Partition"
        )
        val disks = config.getJSONArray("disks")
        for (i in 0 until disks.length()) {
            val diskJson = disks.getJSONObject(i)
            val diskWritable = diskJson.optBoolean("writable", false)
            val disk = diskType.getMethod(
                if (diskWritable) "RWDisk" else "RODisk",
                String::class.java
            ).invoke(null, null as String?)
            val partitions = diskJson.getJSONArray("partitions")
            for (j in 0 until partitions.length()) {
                val partitionJson = partitions.getJSONObject(j)
                val partition = partitionType.getConstructor(
                    String::class.java,
                    String::class.java,
                    Boolean::class.javaPrimitiveType,
                    String::class.java
                ).newInstance(
                    partitionJson.getString("label"),
                    substitute(partitionJson.getString("path"), payload),
                    partitionJson.optBoolean("writable", false),
                    partitionJson.optString("guid", null)
                )
                diskType.getMethod("addPartition", partitionType).invoke(disk, partition)
            }
            imageBuilderType.getMethod("addDisk", diskType).invoke(builder, disk)
        }

        val kernel = config.optString("kernel", null)
        if (kernel != null) {
            imageBuilderType.getMethod("setKernelPath", String::class.java)
                .invoke(builder, substitute(kernel, payload))
        }
        val initrd = config.optString("initrd", null)
        if (initrd != null) {
            imageBuilderType.getMethod("setInitrdPath", String::class.java)
                .invoke(builder, substitute(initrd, payload))
        }
        val params = config.optString("params", null)
        if (params != null) {
            for (param in params.split("+".toRegex())) {
                if (param.isNotEmpty()) {
                    imageBuilderType.getMethod("addParam", String::class.java)
                        .invoke(builder, param)
                }
            }
        }
        // crosvm gets no NIC by default; the payload opts in via "network".
        imageBuilderType.getMethod("useNetwork", Boolean::class.javaPrimitiveType)
            .invoke(builder, config.optBoolean("network", false))

        // The guest's fstab mounts the tags Terminal would serve; provide them from
        // directories we own so those mounts do not hang, regardless of Terminal.
        val sharedPaths = config.optJSONArray("sharedPath")
        File(STATE_DIRECTORY, "app-data/files").mkdirs()
        var configuredShares = 0
        if (sharedPaths != null) {
            for (i in 0 until sharedPaths.length()) {
                val path = substitute(
                    sharedPaths.getJSONObject(i).getString("sharedPath"),
                    payload
                )
                val tag = if (path.contains("emulated")) "android" else "internal"
                configuredShares += addSharedPath(sharedPathType, builder, path, tag)
            }
        }
        configuredShares += addSharedPath(sharedPathType, builder, STORE_PATH, "nix-store")
        println(
            "Payload $payload; shares=$configuredShares; " +
                "memory=${memoryBytes / (1024 * 1024)}MiB; name=$vmName"
        )
        return imageBuilderType.getMethod("build").invoke(builder)
    }

    private fun buildProbeImage(
        sharedPathType: Class<*>,
        imageBuilderType: Class<*>
    ): Any {
        vmName = "nns-store"
        consoleDevice = "hvc0"
        memoryBytes = 512L * 1024 * 1024
        protectedVm = false
        val builder = imageBuilderType.getConstructor().newInstance()
        addSharedPath(sharedPathType, builder, STORE_PATH, "nix-store")
        imageBuilderType.getMethod("setKernelPath", String::class.java)
            .invoke(builder, PROBE_KERNEL)
        imageBuilderType.getMethod("setInitrdPath", String::class.java)
            .invoke(builder, PROBE_INITRD)
        imageBuilderType.getMethod("addParam", String::class.java)
            .invoke(builder, "rdinit=/init")
        imageBuilderType.getMethod("addParam", String::class.java)
            .invoke(builder, "console=hvc0")
        imageBuilderType.getMethod("addParam", String::class.java)
            .invoke(builder, "console=ttyS0")
        return imageBuilderType.getMethod("build").invoke(builder)
    }

    private fun addSharedPath(
        sharedPathType: Class<*>,
        imageBuilder: Any,
        path: String,
        tag: String
    ): Int {
        val sharedPath = sharedPathType.getConstructor(
            String::class.java,
            Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType,
            String::class.java,
            String::class.java,
            Boolean::class.javaPrimitiveType,
            String::class.java
        ).newInstance(path, 0, 0, 0, 0, 7, tag, tag, false, "")
        imageBuilder.javaClass.getMethod("addSharedPath", sharedPathType)
            .invoke(imageBuilder, sharedPath)
        println("share: $path -> tag $tag")
        return 1
    }

    private fun substitute(path: String, payload: File): String =
        path.replace("\$PAYLOAD_DIR", payload.absolutePath)
            .replace(
                "\$APP_DATA_DIR",
                File(STATE_DIRECTORY, "app-data").absolutePath
            )

    private fun readAll(file: File): String {
        FileInputStream(file).use { stream ->
            val buffer = ByteArrayOutputStream()
            val chunk = ByteArray(8192)
            while (true) {
                val read = stream.read(chunk)
                if (read <= 0) break
                buffer.write(chunk, 0, read)
            }
            return buffer.toString(StandardCharsets.UTF_8.name())
        }
    }

    private fun deleteTree(file: File) {
        file.listFiles()?.forEach { deleteTree(it) }
        file.delete()
    }

    private fun drain(stream: InputStream, label: String) {
        val buffer = ByteArray(8192)
        while (stream.available() > 0) {
            val read = stream.read(buffer, 0, minOf(buffer.size, stream.available()))
            if (read <= 0) break
            System.out.print(
                "[$label] " + String(buffer, 0, read, StandardCharsets.UTF_8)
            )
        }
    }
}
