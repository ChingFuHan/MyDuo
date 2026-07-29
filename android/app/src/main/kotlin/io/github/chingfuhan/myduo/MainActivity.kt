package io.github.chingfuhan.myduo

import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = "io.github.chingfuhan.myduo/speech"
    private val handler = Handler(Looper.getMainLooper())
    private var textToSpeech: TextToSpeech? = null
    private var ttsReady = false
    private var mediaPlayer: MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        textToSpeech = TextToSpeech(applicationContext) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "appDataPath" -> result.success(filesDir.absolutePath)
                "speak" -> speak(call, result, 20)
                "playAudio" -> playAudio(call, result)
                "stop" -> {
                    textToSpeech?.stop()
                    mediaPlayer?.stop()
                    mediaPlayer?.release()
                    mediaPlayer = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun speak(
        call: MethodCall,
        result: MethodChannel.Result,
        remainingAttempts: Int,
    ) {
        if (!ttsReady) {
            if (remainingAttempts <= 0) {
                result.success(false)
                return
            }
            handler.postDelayed(
                { speak(call, result, remainingAttempts - 1) },
                100,
            )
            return
        }
        val text = call.argument<String>("text").orEmpty()
        val languageTag = call.argument<String>("locale") ?: "en-US"
        if (text.isBlank()) {
            result.success(false)
            return
        }
        val engine = textToSpeech ?: run {
            result.success(false)
            return
        }
        val locale = Locale.forLanguageTag(languageTag)
        if (engine.isLanguageAvailable(locale) < TextToSpeech.LANG_AVAILABLE) {
            result.success(false)
            return
        }
        val offlineVoices = engine.voices.orEmpty().filter {
            !it.isNetworkConnectionRequired &&
                it.locale.language.equals(locale.language, ignoreCase = true)
        }
        val voice = offlineVoices.firstOrNull {
            it.locale.country.equals(locale.country, ignoreCase = true)
        } ?: offlineVoices.firstOrNull()
        if (voice == null) {
            result.success(false)
            return
        }
        engine.voice = voice
        engine.setSpeechRate(0.92f)
        val status = engine.speak(
            text,
            TextToSpeech.QUEUE_FLUSH,
            null,
            "myduo-${System.nanoTime()}",
        )
        result.success(status == TextToSpeech.SUCCESS)
    }

    private fun playAudio(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path").orEmpty()
        val audio = File(path)
        if (!audio.isFile) {
            result.success(false)
            return
        }
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
            mediaPlayer = MediaPlayer().apply {
                setDataSource(audio.absolutePath)
                setOnCompletionListener {
                    it.release()
                    if (mediaPlayer === it) {
                        mediaPlayer = null
                    }
                }
                prepare()
                start()
            }
            result.success(true)
        } catch (_: Exception) {
            mediaPlayer?.release()
            mediaPlayer = null
            result.success(false)
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        mediaPlayer?.release()
        mediaPlayer = null
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        super.onDestroy()
    }
}
