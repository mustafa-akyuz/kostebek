import 'package:flutter_tts/flutter_tts.dart';

class VoiceAlertService {
  static final FlutterTts _tts = FlutterTts();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    try {
      await _tts.setLanguage('tr-TR');
      await _tts.setSpeechRate(0.52); // Sürüşte en anlaşılır ve net konuşma hızı
      await _tts.setVolume(1.0); // Maksimum ses seviyesi
      await _tts.setPitch(1.0);
      _initialized = true;
    } catch (e) {
      print('[VoiceAlertService] TTS init hatasi: $e');
    }
  }

  /// Sesli Türkçe ikaz yapar: Hıza göre aciliyet tonu ayarlanır
  /// Normal: "Dikkat! 80 metre ileride Kritik Çukur var. Lütfen yavaşlayın!"
  /// Hızlı (50+ km/s): "Dikkat! Hızınızı azaltın! 110 metre ileride Kritik Çukur var!"
  static Future<void> speakWarning(
    String className,
    int distanceMeters, {
    String? severityLabel,
    double speedMps = 0.0,
  }) async {
    try {
      await init();
      final speedKmh = speedMps * 3.6;
      final severityText = (severityLabel != null && severityLabel.isNotEmpty)
          ? '$severityLabel '
          : '';
      
      String msg;
      if (speedKmh >= 50) {
        msg = 'Dikkat! Hızınızı azaltın! $distanceMeters metre ileride $severityText$className var!';
      } else {
        msg = 'Dikkat! $distanceMeters metre ileride $severityText$className var. Lütfen yavaşlayın!';
      }
      await _tts.speak(msg);
    } catch (e) {
      print('[VoiceAlertService] TTS speak hatasi: $e');
    }
  }

  /// Sesli ikazı test etmek için örnek ses çalma
  static Future<void> testAlert() async {
    await speakWarning('Çukur', 85, severityLabel: 'Kritik', speedMps: 16.0);
  }

  static Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
