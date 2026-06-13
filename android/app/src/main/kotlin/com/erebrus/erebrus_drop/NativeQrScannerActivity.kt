package com.erebrus.drop

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.util.Size
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import androidx.activity.SystemBarStyle
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.EnumMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class NativeQrScannerActivity : ComponentActivity() {
    private lateinit var previewView: PreviewView
    private lateinit var cameraExecutor: ExecutorService
    private val reader = MultiFormatReader().apply {
        setHints(
            EnumMap<DecodeHintType, Any>(DecodeHintType::class.java).apply {
                put(DecodeHintType.POSSIBLE_FORMATS, listOf(BarcodeFormat.QR_CODE))
                put(DecodeHintType.TRY_HARDER, true)
            }
        )
    }
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT)
        )
        cameraExecutor = Executors.newSingleThreadExecutor()
        setContentView(scannerView())
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), REQUEST_CAMERA)
        }
    }

    override fun onDestroy() {
        cameraExecutor.shutdown()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CAMERA) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            setResult(Activity.RESULT_CANCELED)
            finish()
        }
    }

    private fun scannerView(): View {
        previewView = PreviewView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        val topBar = topBar()
        val guideCard = guideCard()
        return FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(previewView)
            addView(topBar)
            addView(scanFrame())
            addView(guideCard)
            ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
                val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
                topBar.setPadding(0, bars.top, 0, 0)
                topBar.layoutParams = (topBar.layoutParams as FrameLayout.LayoutParams).apply {
                    height = dp(72) + bars.top
                }
                guideCard.layoutParams = (guideCard.layoutParams as FrameLayout.LayoutParams).apply {
                    bottomMargin = dp(32) + bars.bottom
                }
                insets
            }
        }
    }

    private fun topBar(): View {
        return FrameLayout(this).apply {
            setBackgroundColor(Color.rgb(15, 15, 15))
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(72),
                Gravity.TOP
            )
            addView(TextView(context).apply {
                text = "Scan Drop Code"
                setTextColor(Color.WHITE)
                textSize = 22f
                gravity = Gravity.CENTER_VERTICAL
                layoutParams = FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    Gravity.CENTER
                )
            })
            addView(TextView(context).apply {
                text = "‹"
                setTextColor(Color.WHITE)
                textSize = 42f
                gravity = Gravity.CENTER
                contentDescription = "Back"
                setOnClickListener {
                    setResult(Activity.RESULT_CANCELED)
                    finish()
                }
                layoutParams = FrameLayout.LayoutParams(dp(72), dp(72), Gravity.BOTTOM or Gravity.START)
            })
        }
    }

    private fun scanFrame(): View {
        return View(this).apply {
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(Color.TRANSPARENT)
                setStroke(dp(4), Color.rgb(255, 105, 42))
                cornerRadius = dp(24).toFloat()
            }
            layoutParams = FrameLayout.LayoutParams(dp(276), dp(276), Gravity.CENTER)
        }
    }

    private fun guideCard(): View {
        return TextView(this).apply {
            text = "Point the camera at the host device Drop Code."
            setTextColor(Color.WHITE)
            textSize = 17f
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(18), 0, dp(18), 0)
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(Color.rgb(18, 18, 18))
                setStroke(dp(1), Color.rgb(48, 48, 48))
                cornerRadius = dp(10).toFloat()
            }
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(82),
                Gravity.BOTTOM
            ).apply {
                leftMargin = dp(20)
                rightMargin = dp(20)
                bottomMargin = dp(32)
            }
        }
    }

    private fun startCamera() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()
            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }
            val analysis = ImageAnalysis.Builder()
                .setTargetResolution(Size(1280, 720))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { it.setAnalyzer(cameraExecutor, ::analyzeImage) }
            try {
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview,
                    analysis
                )
            } catch (error: Exception) {
                setResult(Activity.RESULT_CANCELED)
                finish()
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun analyzeImage(image: ImageProxy) {
        if (handled) {
            image.close()
            return
        }
        try {
            val luminance = copyLuminancePlane(image)
            val source = PlanarYUVLuminanceSource(
                luminance,
                image.width,
                image.height,
                0,
                0,
                image.width,
                image.height,
                false
            )
            val result = reader.decodeWithState(BinaryBitmap(HybridBinarizer(source)))
            finishWithCode(result.text)
        } catch (_: NotFoundException) {
            reader.reset()
        } catch (_: Exception) {
            reader.reset()
        } finally {
            image.close()
        }
    }

    private fun copyLuminancePlane(image: ImageProxy): ByteArray {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val width = image.width
        val height = image.height
        val rowStride = plane.rowStride
        val data = ByteArray(width * height)
        if (rowStride == width) {
            buffer.get(data, 0, data.size)
            return data
        }
        var outputOffset = 0
        val row = ByteArray(rowStride)
        for (y in 0 until height) {
            buffer.get(row, 0, rowStride.coerceAtMost(buffer.remaining()))
            System.arraycopy(row, 0, data, outputOffset, width)
            outputOffset += width
        }
        return data
    }

    private fun finishWithCode(code: String?) {
        if (handled || code.isNullOrBlank()) return
        handled = true
        runOnUiThread {
            setResult(
                Activity.RESULT_OK,
                Intent().putExtra(EXTRA_QR_CODE, code)
            )
            finish()
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        const val EXTRA_QR_CODE = "qrCode"
        private const val REQUEST_CAMERA = 8401
    }
}
