import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/pothole.dart';

class LocationService {
  static Future<bool> requestPermission() async {
    try {
      final status = await Permission.locationWhenInUse.request();
      return status.isGranted;
    } catch (e) {
      print('[LocationService] Izin hatasi: $e');
      return false;
    }
  }

  static Future<Position?> getPosition() async {
    try {
      final granted = await requestPermission();
      if (!granted) return null;

      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return null;

      // 1. Önce cihazdaki son bilinen konumu hemen al (gecikmesiz)
      Position? lastKnown;
      try {
        lastKnown = await Geolocator.getLastKnownPosition();
      } catch (_) {}

      // 2. 4 saniyelik zaman aşımı ile yüksek doğruluklu canlı konumu dene
      try {
        final current = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 4),
          ),
        );
        return current;
      } catch (_) {
        // Canlı konum gecikirse son bilinen konumu döndür
        return lastKnown;
      }
    } catch (e) {
      print('[LocationService] Konum hatasi: $e');
      return null;
    }
  }

  static Future<String> getAddress(double lat, double lon) async {
    if (lat == 0.0 && lon == 0.0) return '';
    try {
      final places = await placemarkFromCoordinates(lat, lon);
      if (places.isEmpty) return '';
      final p = places.first;
      final parts = [p.street, p.subLocality, p.subAdministrativeArea, p.locality]
          .where((s) => s != null && s.trim().isNotEmpty)
          .toList();
      return parts.join(', ');
    } catch (e) {
      print('[LocationService] Adres hatasi: $e');
      return '';
    }
  }

  static String mapsLink(double lat, double lon) {
    return 'https://www.google.com/maps/search/?api=1&query=$lat,$lon';
  }

  /// Verilen konumu doğrudan Google Haritalar uygulamasında pini koyarak açar
  static Future<bool> openMaps(double lat, double lon, {String? title}) async {
    if (lat == 0.0 && lon == 0.0) return false;

    final label = Uri.encodeComponent(title ?? 'Çukur');
    final geoUri = Uri.parse('geo:$lat,$lon?q=$lat,$lon($label)');
    final webUri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lon');

    try {
      if (await canLaunchUrl(geoUri)) {
        return await launchUrl(geoUri, mode: LaunchMode.externalApplication);
      } else if (await canLaunchUrl(webUri)) {
        return await launchUrl(webUri, mode: LaunchMode.externalApplication);
      } else {
        return await launchUrl(webUri, mode: LaunchMode.platformDefault);
      }
    } catch (e) {
      print('[LocationService] Harita acma hatasi: $e');
      try {
        return await launchUrl(webUri, mode: LaunchMode.platformDefault);
      } catch (_) {
        return false;
      }
    }
  }

  /// İki koordinat arasındaki mesafeyi metre cinsinden hesaplar
  static double distanceBetween(double lat1, double lon1, double lat2, double lon2) {
    if (lat1 == 0.0 || lon1 == 0.0 || lat2 == 0.0 || lon2 == 0.0) return double.infinity;
    return Geolocator.distanceBetween(lat1, lon1, lat2, lon2);
  }

  /// Aracın hızına göre uyarı mesafesini hesaplar:
  /// Sürücü hızlı gidiyorsa fren mesafesi için uyarı mesafesi artırılır
  static double getAdaptiveRadius(double speedMps) {
    final speedKmh = speedMps * 3.6;
    if (speedKmh >= 75) return 150.0; // 75+ km/s -> 150 metre kala uyar
    if (speedKmh >= 45) return 110.0; // 45+ km/s -> 110 metre kala uyar
    return 80.0; // Şehir içi yavaş sürüş -> 80 metre kala uyar
  }

  /// Yakınlardaki kayıtlı çukuru bulur (hıza göre 80 - 150 metre)
  static MapEntry<Pothole, double>? findNearestPothole(
    double currentLat,
    double currentLon,
    List<Pothole> potholes, {
    double maxDistanceMeters = 80.0,
    double speedMps = 0.0,
  }) {
    if (currentLat == 0.0 || currentLon == 0.0 || potholes.isEmpty) return null;

    final effectiveRadius = speedMps > 3.0
        ? getAdaptiveRadius(speedMps)
        : maxDistanceMeters;

    Pothole? nearest;
    double minDistance = double.infinity;

    for (final p in potholes) {
      if (p.latitude == 0.0 && p.longitude == 0.0) continue;
      // Tamir edilmiş çukurları sürüş ikazından muaf tut
      if (p.status == 'resolved' || p.status == 'tamir_edildi') continue;
      final dist = distanceBetween(currentLat, currentLon, p.latitude, p.longitude);
      if (dist <= effectiveRadius && dist < minDistance) {
        minDistance = dist;
        nearest = p;
      }
    }

    if (nearest != null) {
      return MapEntry(nearest, minDistance);
    }
    return null;
  }

  /// Sesli ve titreşimli ikaz verir (Çukur Yaklaşma Alarmı)
  static void triggerAlertFeedback() {
    try {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    } catch (_) {}
  }
}
