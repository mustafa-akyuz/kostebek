import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import '../services/database_service.dart';
import '../services/location_service.dart';
import '../services/ai_detector.dart';
import '../services/voice_alert_service.dart';
import '../models/pothole.dart';
import '../widgets/pothole_card.dart';
import 'manual_camera_screen.dart';
import 'live_detection_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Pothole> _potholes = [];

  // Sürüş Çukur Radarı (GPS üzerinden arka plan yaklaşma ikazı)
  bool _radarActive = true;
  StreamSubscription<Position>? _radarSub;
  final Map<String, DateTime> _radarAlertCooldown = {};
  Pothole? _radarApproachingPothole;
  double? _radarApproachingDistance;

  @override
  void initState() {
    super.initState();
    _load();
    _startRadar();
  }

  void _load() {
    setState(() => _potholes = DatabaseService.getAll());
  }

  void _startRadar() async {
    await _radarSub?.cancel();
    if (!_radarActive) return;

    try {
      final granted = await LocationService.requestPermission();
      if (!granted) return;

      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;

      _radarSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 3,
        ),
      ).listen(
        _onRadarLocation,
        onError: (err) {
          print('[HomeScreen] Radar konum akis hatasi: $err');
        },
      );
    } catch (e) {
      print('[HomeScreen] Radar baslatma hatasi: $e');
    }
  }

  void _onRadarLocation(Position pos) {
    if (!_radarActive) return;

    final nearest = LocationService.findNearestPothole(
      pos.latitude,
      pos.longitude,
      _potholes,
      maxDistanceMeters: 80.0,
      speedMps: pos.speed,
    );

    if (nearest != null) {
      final pothole = nearest.key;
      final dist = nearest.value;
      final lastAlert = _radarAlertCooldown[pothole.id];

      // Aynı çukur için 90 saniyede 1 kez uyar
      if (lastAlert == null || DateTime.now().difference(lastAlert).inSeconds > 90) {
        _radarAlertCooldown[pothole.id] = DateTime.now();
        LocationService.triggerAlertFeedback();

        // TÜRKÇE SESLİ KONUŞMA İKAZI: "Dikkat! 75 metre ileride kritik çukur var, yavaşlayın!"
        final sev = AIDetector.getPotholeSeverity(pothole);
        VoiceAlertService.speakWarning(
          pothole.detectedClass,
          dist.round(),
          severityLabel: sev.label,
          speedMps: pos.speed,
        );

        if (mounted) {
          setState(() {
            _radarApproachingPothole = pothole;
            _radarApproachingDistance = dist;
          });

          // 8 saniye sonra ikaz kartını ekrandan kaldır
          Future.delayed(const Duration(seconds: 8), () {
            if (mounted && _radarApproachingPothole?.id == pothole.id) {
              setState(() => _radarApproachingPothole = null);
            }
          });
        }
      }
    }
  }

  @override
  void dispose() {
    _radarSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pending = _potholes.where((p) => p.status == 'pending').length;
    final hasLocations = _potholes.any((p) => p.latitude != 0.0 && p.longitude != 0.0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('🐾 Köstebek: Çukur Dedektörü'),
        actions: [
          if (hasLocations)
            IconButton(
              icon: const Icon(Icons.map, color: Color(0xFF1E88E5)),
              tooltip: 'Haritada Gör (Google Maps)',
              onPressed: () {
                final latest = _potholes.firstWhere((p) => p.latitude != 0.0 && p.longitude != 0.0);
                LocationService.openMaps(
                  latest.latitude,
                  latest.longitude,
                  title: '${latest.detectedClass} (Son Kayıt)',
                );
              },
            ),
          if (_potholes.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Tumunu Sil?'),
                    content: const Text('Tum kayitlar silinecek. Emin misiniz?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('Iptal'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Sil'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await DatabaseService.deleteAll();
                  _load();
                }
              },
            ),
        ],
      ),
      body: Column(
        children: [
          // Sürüş Esnası Çukur Yaklaşma Alarm Kartı (Sesli uyarırken ekranda da belirir)
          if (_radarApproachingPothole != null)
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFB71C1C),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.yellowAccent, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 4)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.yellowAccent, size: 36),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '🚨 DİKKAT! ÇUKUR VAR (${_radarApproachingDistance?.toStringAsFixed(0)}m İLERİDE)',
                              style: const TextStyle(
                                color: Colors.yellowAccent,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              'Daha önce kaydedilmiş ${_radarApproachingPothole!.detectedClass} yaklaştı! Yavaşlayın.',
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                        onPressed: () => setState(() => _radarApproachingPothole = null),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            final p = _radarApproachingPothole;
                            if (p != null) {
                              p.status = 'resolved';
                              await p.save();
                              HapticFeedback.mediumImpact();
                              setState(() => _radarApproachingPothole = null);
                              _load();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('✅ Çukur "Tamir Edildi" olarak güncellendi.'),
                                    backgroundColor: Colors.green,
                                  ),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.check_circle, size: 16),
                          label: const Text('Tamir Edilmiş', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green.shade700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 6),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            if (_radarApproachingPothole != null) {
                              LocationService.openMaps(
                                _radarApproachingPothole!.latitude,
                                _radarApproachingPothole!.longitude,
                                title: _radarApproachingPothole!.detectedClass,
                              );
                            }
                          },
                          icon: const Icon(Icons.directions, size: 16),
                          label: const Text('Haritada Gör', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1E88E5),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 6),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          // Sürüş Çukur Radarı Durum Bandı
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: _radarActive ? const Color(0xFF1B5E20) : Colors.grey.shade800,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _radarActive ? Colors.greenAccent : Colors.grey),
            ),
            child: Row(
              children: [
                Icon(
                  _radarActive ? Icons.radar : Icons.radar_outlined,
                  color: _radarActive ? Colors.greenAccent : Colors.white70,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _radarActive ? '🛡️ Çukur Radarı & Sesli İkaz: AÇIK' : '🛡️ Çukur Radarı: KAPALI',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                      ),
                      Text(
                        _radarActive ? 'Kayıtlı çukurlara yaklaşınca sesli Türkçe uyarır' : 'Sürüş korumasını açmak için dokunun',
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.volume_up, color: Colors.greenAccent, size: 22),
                  tooltip: 'Sesli Uyarıyı Dinle',
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    VoiceAlertService.testAlert();
                  },
                ),
                Switch(
                  value: _radarActive,
                  activeThumbColor: Colors.greenAccent,
                  onChanged: (val) {
                    setState(() => _radarActive = val);
                    if (val) {
                      _startRadar();
                    } else {
                      _radarSub?.cancel();
                    }
                  },
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Colors.orange.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat('Toplam', _potholes.length.toString(), Icons.list),
                _stat('Bekleyen', pending.toString(), Icons.hourglass_empty),
                _stat(
                  'Gonderilen',
                  _potholes.where((p) => p.status == 'sent').length.toString(),
                  Icons.send,
                ),
              ],
            ),
          ),
          Expanded(
            child: _potholes.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_road, size: 80, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        const Text('Henuz kayit yok', style: TextStyle(fontSize: 18)),
                        const SizedBox(height: 8),
                        Text(
                          'Alttaki butonlarla cukur tespit edin',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: () async => _load(),
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _potholes.length,
                      itemBuilder: (_, i) {
                        final pothole = _potholes[i];
                        return Dismissible(
                          key: Key(pothole.id),
                          direction: DismissDirection.horizontal,
                          background: _buildDismissBackground(isLeft: true),
                          secondaryBackground: _buildDismissBackground(isLeft: false),
                          onDismissed: (direction) async {
                            final deleted = pothole;
                            final deletedIndex = i;
                            final messenger = ScaffoldMessenger.of(context);
                            HapticFeedback.mediumImpact();

                            setState(() {
                              _potholes.removeAt(deletedIndex);
                            });
                            await DatabaseService.delete(deleted.id);

                            if (!mounted) return;
                            messenger.clearSnackBars();
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('${deleted.detectedClass} kaydı silindi'),
                                backgroundColor: const Color(0xFF323232),
                                duration: const Duration(seconds: 4),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                action: SnackBarAction(
                                  label: 'GERİ AL',
                                  textColor: Colors.amberAccent,
                                  onPressed: () async {
                                    await DatabaseService.add(deleted);
                                    _load();
                                  },
                                ),
                              ),
                            );
                          },
                          child: PotholeCard(
                            pothole: pothole,
                            onDeleted: _load,
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'live',
            backgroundColor: Colors.deepOrange,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.videocam),
            label: const Text('AI Tarama'),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LiveDetectionScreen()),
              );
              _load();
            },
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'manual',
            backgroundColor: Colors.blue,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.camera_alt),
            label: const Text('Manuel Çek / Yükle'),
            onPressed: () => _showManualCaptureSheet(context),
          ),
        ],
      ),
    );
  }

  void _showManualCaptureSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E222A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Manuel Çukur Tespiti & Kaydı',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Yeni bir fotoğraf çekebilir veya daha önce çektiğiniz bir görseli yükleyebilirsiniz.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.white60),
              ),
              const SizedBox(height: 20),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.camera_alt, color: Colors.blue),
                ),
                title: const Text('Kamera ile Çek', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: const Text('Kamerayı açarak yeni yol çukuru fotoğrafı çekin', style: TextStyle(color: Colors.white54, fontSize: 12)),
                trailing: const Icon(Icons.chevron_right, color: Colors.white30),
                onTap: () async {
                  Navigator.pop(ctx);
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ManualCameraScreen()),
                  );
                  _load();
                },
              ),
              const Divider(color: Colors.white12),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.photo_library, color: Colors.amber),
                ),
                title: const Text('Galeriden Görsel Yükle', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: const Text('Daha önce çektiğiniz bir fotoğrafı seçin ve AI ile taratın', style: TextStyle(color: Colors.white54, fontSize: 12)),
                trailing: const Icon(Icons.chevron_right, color: Colors.white30),
                onTap: () async {
                  Navigator.pop(ctx);
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ManualCameraScreen()),
                  );
                  _load();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: Colors.deepOrange),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[700])),
      ],
    );
  }

  Widget _buildDismissBackground({required bool isLeft}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFFD32F2F),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: isLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: isLeft
            ? const [
                Icon(Icons.delete_outline, color: Colors.white, size: 26),
                SizedBox(width: 8),
                Text(
                  'SİL',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    letterSpacing: 1.1,
                  ),
                ),
              ]
            : const [
                Text(
                  'SİL',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    letterSpacing: 1.1,
                  ),
                ),
                SizedBox(width: 8),
                Icon(Icons.delete_outline, color: Colors.white, size: 26),
              ],
      ),
    );
  }
}
