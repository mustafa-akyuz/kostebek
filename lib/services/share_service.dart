import 'dart:io';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/pothole.dart';
import 'location_service.dart';

class ShareService {
  static String buildMessage(Pothole p) {
    final maps = LocationService.mapsLink(p.latitude, p.longitude);
    final date = '${p.createdAt.day}/${p.createdAt.month}/${p.createdAt.year}';
    final conf = (p.confidence * 100).toStringAsFixed(0);

    return '''🚧 YOL SORUNU BİLDİRİMİ 🚧

📍 Tespit: ${p.detectedClass}
🎯 Güvenilirlik: %$conf
📅 Tarih: $date
🗺️ Adres: ${p.address.isNotEmpty ? p.address : 'Bilinmiyor'}
🌐 Harita: $maps
📝 Not: ${p.note.isNotEmpty ? p.note : 'Yok'}

Lütfen en kısa sürede müdahale ediniz.''';
  }

  static Future<void> shareAnywhere(Pothole p) async {
    try {
      final msg = buildMessage(p);
      final file = File(p.imagePath);
      if (file.existsSync()) {
        await Share.shareXFiles(
          [XFile(p.imagePath)],
          text: msg,
          subject: 'Yol Sorunu Bildirimi',
        );
      } else {
        await Share.share(msg, subject: 'Yol Sorunu Bildirimi');
      }
      p.status = 'sent';
      await p.save();
    } catch (e) {
      print('[ShareService] Paylasim hatasi: $e');
    }
  }

  static Future<void> shareWhatsApp(Pothole p, {String? phone}) async {
    try {
      final text = Uri.encodeComponent(buildMessage(p));
      final url = phone != null && phone.isNotEmpty
          ? 'https://wa.me/$phone?text=$text'
          : 'https://wa.me/?text=$text';
      final uri = Uri.parse(url);

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        p.status = 'sent';
        await p.save();
      }
    } catch (e) {
      print('[ShareService] WhatsApp hatasi: $e');
    }
  }

  static Future<void> shareSMS(Pothole p, {String? phone}) async {
    try {
      final text = Uri.encodeComponent(buildMessage(p));
      final url = 'sms:${phone ?? ''}?body=$text';
      final uri = Uri.parse(url);

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        p.status = 'sent';
        await p.save();
      }
    } catch (e) {
      print('[ShareService] SMS hatasi: $e');
    }
  }
}
