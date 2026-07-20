package com.erebrus.drop

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import com.solana.mobilewalletadapter.clientlib.protocol.MobileWalletAdapterClient
import com.solana.mobilewalletadapter.clientlib.scenario.LocalAssociationIntentCreator
import com.solana.mobilewalletadapter.clientlib.scenario.LocalAssociationScenario
import com.solana.mobilewalletadapter.clientlib.scenario.Scenario
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

object SolanaWalletBridge {
    private const val WALLET_REQUEST_CODE = 9241
    private const val CONNECT_TIMEOUT_MS = 30_000L
    private const val WALLET_ICON_PX = 96
    // Wallets resolve icon via Uri.withAppendedPath(identityUri, iconPath), not RFC
    // relative resolution — use a simple filename under the site root.
    private val MWA_IDENTITY_URI = Uri.parse("https://erebrus.io/drop/")
    private val MWA_ICON_RELATIVE_URI = Uri.parse("logo.png?v=2")

    private data class KnownWallet(
        val name: String,
        val packageName: String,
        val associationEndpoint: String? = null,
        val isSeedVault: Boolean = false,
    )

    private val knownWallets = listOf(
        KnownWallet(
            name = "Seed Vault",
            packageName = "com.solanamobile.wallet",
            isSeedVault = true,
        ),
        KnownWallet(
            name = "Phantom",
            packageName = "app.phantom",
        ),
        KnownWallet(
            name = "Solflare",
            packageName = "com.solflare.mobile",
        ),
        KnownWallet(
            name = "Backpack",
            packageName = "app.backpack.mobile.standalone",
            associationEndpoint = "https://backpack.app/ul",
        ),
        KnownWallet(
            name = "Backpack",
            packageName = "app.backpack.mobile",
            associationEndpoint = "https://backpack.app/ul",
        ),
        KnownWallet(
            name = "Jupiter",
            packageName = "ag.jup.jupiter.android",
        ),
        KnownWallet(
            name = "Espresso Cash",
            packageName = "com.pleasecrypto.flutter",
        ),
    )

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var pendingResult: MethodChannel.Result? = null
    private var pendingScenario: LocalAssociationScenario? = null
    private var timeoutRunnable: Runnable? = null

    fun listWallets(context: Activity): List<Map<String, Any?>> {
        val packageManager = context.packageManager
        val wallets = linkedMapOf<String, Map<String, Any?>>()

        for (wallet in knownWallets) {
            if (!isPackageInstalled(packageManager, wallet.packageName)) {
                continue
            }
            if (!canHandleMwaAssociation(packageManager, wallet)) {
                continue
            }
            wallets[wallet.packageName] = wallet.toMap(packageManager)
        }

        return wallets.values.sortedWith(
            compareBy<Map<String, Any?>> { (it["isSeedVault"] as? Boolean) != true }
                .thenBy { walletSortKey(it["name"] as? String ?: "") },
        )
    }

    fun authorizeWallet(
        activity: Activity,
        packageName: String,
        authToken: String?,
        result: MethodChannel.Result,
    ) {
        if (pendingResult != null) {
            result.error("BUSY", "Wallet connection already in progress.", null)
            return
        }

        val packageManager = activity.packageManager
        val wallet = knownWalletFor(packageName)
        if (wallet == null || !canHandleMwaAssociation(packageManager, wallet)) {
            result.error(
                "WALLET_UNAVAILABLE",
                "This wallet cannot handle Solana Mobile connections on this device.",
                null,
            )
            return
        }

        pendingResult = result
        val scenario = LocalAssociationScenario(Scenario.DEFAULT_CLIENT_TIMEOUT_MS)
        pendingScenario = scenario
        val associationIntent = buildAssociationIntent(packageManager, wallet, scenario)

        timeoutRunnable = Runnable {
            failPending("Wallet connection timed out after 30 seconds. Try again.")
        }
        mainHandler.postDelayed(timeoutRunnable!!, CONNECT_TIMEOUT_MS)

        executor.execute {
            try {
                val launchLatch = java.util.concurrent.CountDownLatch(1)
                var launchError: Throwable? = null
                mainHandler.post {
                    try {
                        activity.startActivityForResult(associationIntent, WALLET_REQUEST_CODE)
                    } catch (error: Throwable) {
                        launchError = error
                    } finally {
                        launchLatch.countDown()
                    }
                }
                launchLatch.await()
                if (launchError != null) {
                    throw launchError!!
                }

                val client = scenario.start().get()
                val authResult = if (authToken.isNullOrBlank()) {
                    client.authorize(
                        MWA_IDENTITY_URI,
                        MWA_ICON_RELATIVE_URI,
                        "Erebrus Drop",
                        "mainnet-beta",
                    ).get()
                } else {
                    client.reauthorize(
                        MWA_IDENTITY_URI,
                        MWA_ICON_RELATIVE_URI,
                        "Erebrus Drop",
                        authToken,
                    ).get()
                }

                clearTimeout()
                val payload = mapOf(
                    "authToken" to authResult.authToken,
                    "publicKey" to authResult.publicKey,
                    "walletUriBase" to authResult.walletUriBase?.toString(),
                    "accountLabel" to authResult.accountLabel,
                )
                mainHandler.post {
                    completePending(payload)
                    scenario.close()
                    pendingScenario = null
                }
            } catch (error: Throwable) {
                mainHandler.post {
                    failPending(error.message ?: "Wallet authorization failed.")
                    scenario.close()
                    pendingScenario = null
                }
            }
        }
    }

    fun signMessage(
        activity: Activity,
        packageName: String,
        authToken: String,
        message: String,
        result: MethodChannel.Result,
    ) {
        if (pendingResult != null) {
            result.error("BUSY", "Wallet connection already in progress.", null)
            return
        }
        if (packageName.isBlank() || authToken.isBlank() || message.isBlank()) {
            result.error("INVALID_ARGS", "packageName, authToken and message are required.", null)
            return
        }

        pendingResult = result
        val scenario = LocalAssociationScenario(Scenario.DEFAULT_CLIENT_TIMEOUT_MS)
        pendingScenario = scenario
        val packageManager = activity.packageManager
        val wallet = knownWalletFor(packageName)
        val associationIntent = if (wallet != null && canHandleMwaAssociation(packageManager, wallet)) {
            buildAssociationIntent(packageManager, wallet, scenario)
        } else {
            null
        }

        timeoutRunnable = Runnable {
            failPending("Wallet sign-in timed out after 30 seconds. Try again.")
        }
        mainHandler.postDelayed(timeoutRunnable!!, CONNECT_TIMEOUT_MS)

        executor.execute {
            try {
                if (associationIntent != null) {
                    val launchLatch = java.util.concurrent.CountDownLatch(1)
                    var launchError: Throwable? = null
                    mainHandler.post {
                        try {
                            activity.startActivityForResult(associationIntent, WALLET_REQUEST_CODE)
                        } catch (error: Throwable) {
                            launchError = error
                        } finally {
                            launchLatch.countDown()
                        }
                    }
                    launchLatch.await()
                    if (launchError != null) {
                        throw launchError!!
                    }
                }

                val client = scenario.start().get()
                val authResult = client.reauthorize(
                    MWA_IDENTITY_URI,
                    MWA_ICON_RELATIVE_URI,
                    "Erebrus Drop",
                    authToken,
                ).get()

                val messageBytes = message.toByteArray(Charsets.UTF_8)
                val signed: MobileWalletAdapterClient.SignMessagesResult = client.signMessagesDetached(
                    arrayOf(messageBytes),
                    arrayOf(authResult.publicKey),
                ).get()

                if (signed.messages.isEmpty() || signed.messages[0].signatures.isEmpty()) {
                    throw IllegalStateException("Wallet did not return a signature.")
                }

                val signatureBytes = signed.messages[0].signatures[0]
                val signatureHex = signatureBytes.joinToString("") { "%02x".format(it) }

                clearTimeout()
                mainHandler.post {
                    completePending(
                        mapOf(
                            "publicKey" to authResult.publicKey,
                            "authToken" to authResult.authToken,
                            "signature" to signatureHex,
                        ),
                    )
                    scenario.close()
                    pendingScenario = null
                }
            } catch (error: Throwable) {
                mainHandler.post {
                    failPending(error.message ?: "Wallet sign-in failed.")
                    scenario.close()
                    pendingScenario = null
                }
            }
        }
    }

    fun deauthorizeWallet(
        activity: Activity,
        packageName: String,
        authToken: String,
        result: MethodChannel.Result,
    ) {
        if (pendingResult != null) {
            result.error("BUSY", "Wallet connection already in progress.", null)
            return
        }

        pendingResult = result
        val scenario = LocalAssociationScenario(Scenario.DEFAULT_CLIENT_TIMEOUT_MS)
        pendingScenario = scenario
        val packageManager = activity.packageManager
        val wallet = knownWalletFor(packageName)
        val associationIntent = if (wallet != null && canHandleMwaAssociation(packageManager, wallet)) {
            buildAssociationIntent(packageManager, wallet, scenario)
        } else {
            null
        }

        timeoutRunnable = Runnable {
            failPending("Wallet disconnect timed out after 30 seconds. Try again.")
        }
        mainHandler.postDelayed(timeoutRunnable!!, CONNECT_TIMEOUT_MS)

        executor.execute {
            try {
                if (associationIntent != null) {
                    mainHandler.post {
                        try {
                            activity.startActivityForResult(associationIntent, WALLET_REQUEST_CODE)
                        } catch (_: Throwable) {
                            // Best-effort disconnect.
                        }
                    }
                }
                val client = scenario.start().get()
                client.deauthorize(authToken).get()
                clearTimeout()
                mainHandler.post {
                    completePending(null)
                    scenario.close()
                    pendingScenario = null
                }
            } catch (_: Throwable) {
                mainHandler.post {
                    completePending(null)
                    scenario.close()
                    pendingScenario = null
                }
            }
        }
    }

    fun cancelPendingOperation(result: MethodChannel.Result) {
        mainHandler.post {
            if (pendingResult == null) {
                result.success(mapOf("cancelled" to false))
                return@post
            }
            cancelPending("Wallet connection cancelled.")
            result.success(mapOf("cancelled" to true))
        }
    }

    fun onActivityResult(requestCode: Int, @Suppress("UNUSED_PARAMETER") resultCode: Int): Boolean {
        return requestCode == WALLET_REQUEST_CODE
    }

    private fun buildAssociationIntent(
        packageManager: PackageManager,
        wallet: KnownWallet,
        scenario: LocalAssociationScenario,
    ): Intent {
        val endpointPrefix = wallet.associationEndpoint?.let(Uri::parse)
        val component = resolveMwaActivity(packageManager, wallet.packageName, endpointPrefix)
            ?: throw IllegalStateException("No MWA activity for ${wallet.packageName}")
        val intent = LocalAssociationIntentCreator.createAssociationIntent(
            endpointPrefix,
            scenario.port,
            scenario.session,
        )
            .addCategory(Intent.CATEGORY_DEFAULT)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .setPackage(wallet.packageName)
        if (!component.className.substringAfterLast('.')
                .equals("MainActivity", ignoreCase = true)
        ) {
            intent.setComponent(component)
        }
        return intent
    }

    private fun canHandleMwaAssociation(
        packageManager: PackageManager,
        wallet: KnownWallet,
    ): Boolean {
        val endpointPrefix = wallet.associationEndpoint?.let(Uri::parse)
        return resolveMwaActivity(packageManager, wallet.packageName, endpointPrefix) != null
    }

    private fun knownWalletFor(packageName: String): KnownWallet? {
        return knownWallets.firstOrNull { it.packageName == packageName }
    }

    private fun resolveMwaActivity(
        packageManager: PackageManager,
        packageName: String,
        endpointPrefix: Uri?,
    ): ComponentName? {
        val intent = Intent(
            Intent.ACTION_VIEW,
            createProbeAssociationUri(endpointPrefix),
        )
            .addCategory(Intent.CATEGORY_BROWSABLE)
            .setPackage(packageName)
        val activities = packageManager.queryIntentActivities(
            intent,
            PackageManager.MATCH_DEFAULT_ONLY,
        )
        if (activities.isEmpty()) {
            return null
        }
        val info = activities.sortedWith(mwaActivityPriority()).first().activityInfo
        return ComponentName(info.packageName, info.name)
    }

    private fun mwaActivityPriority(): Comparator<android.content.pm.ResolveInfo> {
        return compareBy { resolveInfo ->
            val name = resolveInfo.activityInfo.name.lowercase()
            when {
                name.contains("mwa") -> 0
                name.contains("solana") && name.contains("connect") -> 1
                name.endsWith("mainactivity") -> 3
                else -> 2
            }
        }
    }

    private fun createProbeAssociationUri(endpointPrefix: Uri?): Uri {
        val builder = if (endpointPrefix != null) {
            endpointPrefix.buildUpon().clearQuery().fragment(null)
        } else {
            Uri.Builder().scheme("solana-wallet")
        }
        return builder
            .appendEncodedPath("v1/associate/local")
            .appendQueryParameter("association", "")
            .appendQueryParameter("port", "0")
            .build()
    }

    private fun KnownWallet.toMap(packageManager: PackageManager): Map<String, Any?> {
        return mapOf(
            "id" to packageName,
            "name" to name,
            "packageName" to packageName,
            "isSeedVault" to isSeedVault,
            "iconBase64" to appIconBase64(packageManager, packageName),
        )
    }

    private fun appIconBase64(packageManager: PackageManager, packageName: String): String? {
        return try {
            val drawable = packageManager.getApplicationIcon(packageName)
            val bitmap = drawableToBitmap(drawable)
            val scaled = Bitmap.createScaledBitmap(bitmap, WALLET_ICON_PX, WALLET_ICON_PX, true)
            if (scaled !== bitmap) {
                bitmap.recycle()
            }
            val output = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.PNG, 92, output)
            scaled.recycle()
            Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP)
        } catch (_: Throwable) {
            null
        }
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap {
        if (drawable is BitmapDrawable) {
            val existing = drawable.bitmap
            if (existing != null) {
                return existing
            }
        }
        val width = drawable.intrinsicWidth.coerceAtLeast(WALLET_ICON_PX)
        val height = drawable.intrinsicHeight.coerceAtLeast(WALLET_ICON_PX)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bitmap
    }

    private fun isPackageInstalled(packageManager: PackageManager, packageName: String): Boolean {
        return try {
            packageManager.getPackageInfo(packageName, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun walletSortKey(name: String): String = name.lowercase()

    private fun clearTimeout() {
        timeoutRunnable?.let(mainHandler::removeCallbacks)
        timeoutRunnable = null
    }

    private fun completePending(payload: Map<String, Any?>?) {
        clearTimeout()
        pendingResult?.success(payload)
        pendingResult = null
    }

    private fun cancelPending(message: String) {
        clearTimeout()
        pendingScenario?.close()
        pendingScenario = null
        pendingResult?.error("WALLET_CANCELLED", message, null)
        pendingResult = null
    }

    private fun failPending(message: String) {
        clearTimeout()
        pendingScenario?.close()
        pendingScenario = null
        pendingResult?.error("WALLET_ERROR", message, null)
        pendingResult = null
    }
}
