import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/ai_detector.dart';
import '../services/location_service.dart';
import '../services/database_service.dart';
import '../services/voice_alert_service.dart';
import '../models/pothole.dart';

enum RecordFilter {
  criticalOnly('Sadece Kritik (%70+)', 'Yalnızca acil kaza riski taşıyan büyük çukurlar', 70),
  highAndAbove('Yüksek & Kritik (%50+)', 'Lastik ve can güvenliği tehdit edenler (Önerilen)', 50),
  mediumAndAbove('Orta ve Üzeri (%30+)', 'Tüm belirgin yol bozulmaları ve çukurlar', 30),
  all('Tümünü Kaydet (%1+)', 'Yapay zekanın gördüğü tüm yol kusurları', 0);

  final String title;
  final String subtitle;
  final int minScore;

  const RecordFilter(this.title, this.subtitle, this.minScore);
}

class LiveDetectionScreen extends StatefulWidget {
  const LiveDetectionScreen({super.key});

  @override
  State<LiveDetectionScreen> createState() => _LiveDetectionScreenState();
}

class _LiveDetectionScreenState extends State<LiveDetectionScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _busy = false;
  bool _running = false;
  List<Detection> _current = [];
  int _savedCount = 0;
  final Map<String, DateTime> _cooldown = {};
  static const Duration _cooldownDuration = Duration(seconds: 10);

  // Kayıt filtreleme seviyesi (Varsayılan: Yüksek & Kritik)
  RecordFilter _recordFilter = RecordFilter.highAndAbove;

  // Asfalt & Yol Doğrulama Filtresi (Masa, fare, oda eşyalarını engeller)
  bool _roadFilter = true;
  // Algılama Güven Eşiği (Varsayılan %35, sürüş için optimize)
  double _confThreshold = 0.35;

  // Yakınlaştırma (Zoom) ayarları
  double _minZoom = 1.0;
  double _maxZoom = 5.0;
  double _currentZoom = 1.5;
  double _baseZoom = 1.5;

  // Canlı GPS ve Çukur Yaklaşma Radarı (İkaz Sistemi)
  StreamSubscription<Position>? _positionSub;
  Position? _lastPosition;
  List<Pothole> _savedPotholes = [];
  Pothole? _approachingPothole;
  double? _approachingDistance;
  final Map<String, DateTime> _alertCooldown = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    try {
      final cam = await Permission.camera.request();
      await Permission.locationWhenInUse.request();
      if (!cam.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ Kamera izni verilmedi. AI çukur tespiti için lütfen ayarlardan kamera iznini onaylayın.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 4),
            ),
          );
          Navigator.pop(context);
        }
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ Bu cihazda / simülatörde kullanılabilir kamera sensörü bulunamadı.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
          Navigator.pop(context);
        }
        return;
      }

      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.bgra8888,
      );
      await _controller!.initialize();
      if (!mounted) return;

      // Kamera zoom sınırlarını al ve en uygun ayar olan 1.5x'e ayarla
      try {
        _minZoom = await _controller!.getMinZoomLevel();
        _maxZoom = await _controller!.getMaxZoomLevel();
        // 1.5x: Yol tespiti için en uygun ayardır. Gökyüzü ve araç kaputunu kırpıp
        // yoldaki çukurları 2-3 kat büyüterek yapay zekanın çok daha kolay algılamasını sağlar.
        _currentZoom = 1.5.clamp(_minZoom, _maxZoom);
        await _controller!.setZoomLevel(_currentZoom);
      } catch (e) {
        print('[LiveDetectionScreen] Zoom init hatasi: $e');
      }

      _savedPotholes = DatabaseService.getAll();
      _startLocationStream();

      setState(() => _running = true);
      await _controller!.startImageStream(_onFrame);
    } catch (e) {
      print('[LiveDetectionScreen] Init hatasi: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kamera hatasi: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  void _startLocationStream() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;

      _lastPosition = await LocationService.getPosition();

      _positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 3, // her 3 metrede bir güncelle
        ),
      ).listen(
        _onLocationUpdate,
        onError: (err) {
          print('[LiveDetectionScreen] Konum akis hatasi: $err');
        },
      );
    } catch (e) {
      print('[LiveDetectionScreen] Konum akışı hatası: $e');
    }
  }

  void _onLocationUpdate(Position pos) {
    _lastPosition = pos;

    // Veritabanındaki kayıtlı çukurlarla mesafeyi kontrol et (hıza göre 80-150m)
    final nearest = LocationService.findNearestPothole(
      pos.latitude,
      pos.longitude,
      _savedPotholes,
      maxDistanceMeters: 80.0,
      speedMps: pos.speed,
    );

    if (nearest != null) {
      final pothole = nearest.key;
      final dist = nearest.value;
      final lastAlert = _alertCooldown[pothole.id];

      // Aynı çukur için 90 saniyede en fazla 1 kez uyar
      if (lastAlert == null || DateTime.now().difference(lastAlert).inSeconds > 90) {
        _alertCooldown[pothole.id] = DateTime.now();
        LocationService.triggerAlertFeedback(); // Titreşim ve Bip Sesi

        // SESLİ TÜRKÇE SÜRÜŞ İKAZI ("Dikkat! 70 metre ileride kritik çukur var, yavaşlayın!")
        final sev = AIDetector.getPotholeSeverity(pothole);
        VoiceAlertService.speakWarning(
          pothole.detectedClass,
          dist.round(),
          severityLabel: sev.label,
          speedMps: pos.speed,
        );

        if (mounted) {
          setState(() {
            _approachingPothole = pothole;
            _approachingDistance = dist;
          });

          // 7 saniye sonra ikaz başlığını kaldır
          Future.delayed(const Duration(seconds: 7), () {
            if (mounted && _approachingPothole?.id == pothole.id) {
              setState(() => _approachingPothole = null);
            }
          });
        }
      }
    }
  }

  Future<void> _setZoom(double zoom) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final target = zoom.clamp(_minZoom, _maxZoom);
    try {
      await _controller!.setZoomLevel(target);
      setState(() => _currentZoom = target);
    } catch (e) {
      print('[LiveDetectionScreen] Zoom hatasi: $e');
    }
  }

  int _frameCount = 0;
  DateTime _lastInfer = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _inferGap = Duration(milliseconds: 400);
  int _imgW = 0;
  int _imgH = 0;

  Future<void> _onFrame(CameraImage frame) async {
    if (_busy || !_running) return;
    // Kasma önleme: saniyede en fazla ~2 çıkarım, aradaki kareler atlanır.
    final now = DateTime.now();
    if (now.difference(_lastInfer) < _inferGap) return;
    _busy = true;
    _lastInfer = now;
    _frameCount++;

    try {
      final image = _toImage(frame);
      if (image == null) {
        _busy = false;
        return;
      }
      _imgW = image.width;
      _imgH = image.height;

      final sw = Stopwatch()..start();
      final dets = await AIDetector.detect(
        image,
        threshold: _confThreshold,
        checkRoadSurface: _roadFilter,
      );
      sw.stop();
      if (_frameCount % 10 == 1) {
        final top = dets.isEmpty
            ? 'yok'
            : dets.map((d) =>
                '${d.className}%${(d.confidence * 100).toStringAsFixed(0)}').join(',');
        print('[LiveDetectionScreen] kare=$_frameCount '
            'format=${frame.format.group} boyut=${image.width}x${image.height} '
            'sure=${sw.elapsedMilliseconds}ms '
            'tespit=${dets.length} [$top]');
      }
      if (mounted) {
        setState(() => _current = dets);
      }

      for (final d in dets) {
        if (!AIDetector.isRoadIssue(d)) continue;
        final severity = AIDetector.calculateSeverity(d, image.width, image.height);
        if (severity.score >= _recordFilter.minScore && _canSave(d.className)) {
          await _save(image, d, severity);
        }
      }
    } catch (e) {
      print('[LiveDetectionScreen] Frame hatasi: $e');
    }

    _busy = false;
  }

  bool _canSave(String className) {
    final last = _cooldown[className];
    if (last == null) return true;
    return DateTime.now().difference(last) >= _cooldownDuration;
  }

  Future<void> _save(img.Image image, Detection d, SeverityInfo severity) async {
    _cooldown[d.className] = DateTime.now();

    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/${const Uuid().v4()}.jpg';

      // Çukuru ve tehlike derecesini görselin üzerine kalıcı damgala
      final stamped = AIDetector.stampDetectionOnImage(image, d, severity);
      await File(path).writeAsBytes(img.encodeJpg(stamped, quality: 85));

      final lat = _lastPosition?.latitude ?? (await LocationService.getPosition())?.latitude ?? 0.0;
      final lon = _lastPosition?.longitude ?? (await LocationService.getPosition())?.longitude ?? 0.0;
      final addr = (lat != 0 && lon != 0)
          ? await LocationService.getAddress(lat, lon)
          : '';

      final pothole = Pothole(
        id: const Uuid().v4(),
        imagePath: path,
        latitude: lat,
        longitude: lon,
        createdAt: DateTime.now(),
        detectedClass: d.className,
        confidence: d.confidence,
        address: addr,
        note: 'Tehlike: ${severity.label} (%${severity.score}) - ${severity.description}',
        status: 'pending',
      );
      await DatabaseService.add(pothole);
      _savedPotholes.add(pothole); // radara hemen dahil et

      if (mounted) {
        setState(() => _savedCount++);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${d.className} [${severity.label} %${severity.score}] damgalanarak kaydedildi!'),
            backgroundColor: severity.color,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('[LiveDetectionScreen] Kayit hatasi: $e');
    }
  }

  img.Image? _toImage(CameraImage frame) {
    try {
      img.Image? raw;
      final group = frame.format.group;
      if (group == ImageFormatGroup.bgra8888) {
        final plane = frame.planes.first;
        raw = img.Image.fromBytes(
          width: frame.width,
          height: frame.height,
          bytes: plane.bytes.buffer,
          order: img.ChannelOrder.bgra,
        );
      } else if (group == ImageFormatGroup.jpeg) {
        raw = img.decodeImage(frame.planes.first.bytes);
      } else {
        raw = _convertYUV420(frame);
      }
      if (raw == null) return null;

      // Android arka kamera sensörü landscape'dir.
      // Dikey (portrait) ekranda yolun düz açıyla yapay zekaya gitmesi için
      // 90 derece saat yönünde döndürülür:
      if (Platform.isAndroid) {
        return img.copyRotate(raw, angle: 90);
      }
      return raw;
    } catch (e) {
      print('[LiveDetectionScreen] Gorsel donusum hatasi: $e');
      return null;
    }
  }

  /// YUV420_888 -> RGB hızlı tamsayı dönüşümü
  img.Image _convertYUV420(CameraImage image) {
    final w = image.width;
    final h = image.height;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final yRowStride = yPlane.bytesPerRow;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    final out = img.Image(width: w, height: h);
    for (int y = 0; y < h; y++) {
      final yRow = y * yRowStride;
      final uvRow = (y >> 1) * uvRowStride;
      for (int x = 0; x < w; x++) {
        final yVal = yPlane.bytes[yRow + x];
        final uvIndex = uvRow + (x >> 1) * uvPixelStride;
        final uVal = uPlane.bytes[uvIndex] - 128;
        final vVal = vPlane.bytes[uvIndex] - 128;

        int r = yVal + ((1436 * vVal) >> 10);
        int g = yVal - ((352 * uVal + 731 * vVal) >> 10);
        int b = yVal + ((1814 * uVal) >> 10);

        if (r < 0) {
          r = 0;
        } else if (r > 255) {
          r = 255;
        }
        if (g < 0) {
          g = 0;
        } else if (g > 255) {
          g = 255;
        }
        if (b < 0) {
          b = 0;
        } else if (b > 255) {
          b = 255;
        }

        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  Future<void> _toggle() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      setState(() => _running = !_running);
      if (_running) {
        WakelockPlus.enable();
        await _controller!.startImageStream(_onFrame);
      } else {
        WakelockPlus.disable();
        await _controller!.stopImageStream();
      }
    } catch (e) {
      print('[LiveDetectionScreen] Toggle hatasi: $e');
    }
  }

  void _showFilterDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 1. Asfalt & Yol Filtresi Bölümü
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: _roadFilter ? Colors.green.shade50 : Colors.red.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _roadFilter ? Colors.green.shade300 : Colors.red.shade300,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _roadFilter ? Icons.verified : Icons.warning_amber_rounded,
                            color: _roadFilter ? Colors.green.shade800 : Colors.red.shade800,
                            size: 26,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _roadFilter ? '🛣️ Yol / Asfalt Filtresi: AÇIK' : '🛣️ Yol / Asfalt Filtresi: KAPALI',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: _roadFilter ? Colors.green.shade900 : Colors.red.shade900,
                                  ),
                                ),
                                Text(
                                  _roadFilter
                                      ? 'Masa, fare ve eşyaları eler; sadece gerçek asfalt/yol hasarlarını algılar.'
                                      : 'Filtre kapalı: Kameranın gördüğü her çöküntü/şekil algılanır.',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: _roadFilter,
                            activeThumbColor: Colors.green,
                            onChanged: (val) {
                              setState(() => _roadFilter = val);
                              setSheetState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 2. Algılama Hassasiyeti (Güven Eşiği)
                    const Text(
                      '🎯 Algılama Güven Eşiği (Hassasiyet):',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _buildThresholdChip(
                          label: '🚗 Sürüş (%35)',
                          threshold: 0.35,
                          setSheetState: setSheetState,
                        ),
                        const SizedBox(width: 8),
                        _buildThresholdChip(
                          label: '🛡️ Kesin (%45)',
                          threshold: 0.45,
                          setSheetState: setSheetState,
                        ),
                        const SizedBox(width: 8),
                        _buildThresholdChip(
                          label: '🧪 Test (%25)',
                          threshold: 0.25,
                          setSheetState: setSheetState,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    Row(
                      children: const [
                        Icon(Icons.shield, color: Colors.deepOrange, size: 28),
                        SizedBox(width: 10),
                        Text(
                          'Kayıt & Zarar Seviyesi Ayarı',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Yapay zeka çukurları can ve mal güvenliği riskine göre puanlar (1-100). Hangi derecedeki çukurların otomatik kaydedileceğini seçin:',
                      style: TextStyle(color: Colors.grey[700], fontSize: 13),
                    ),
                    const SizedBox(height: 14),
                    ...RecordFilter.values.map((f) {
                      final isSelected = _recordFilter == f;
                      Color itemColor;
                      switch (f) {
                        case RecordFilter.criticalOnly:
                          itemColor = const Color(0xFFD32F2F);
                          break;
                        case RecordFilter.highAndAbove:
                          itemColor = const Color(0xFFE65100);
                          break;
                        case RecordFilter.mediumAndAbove:
                          itemColor = const Color(0xFFF57C00);
                          break;
                        case RecordFilter.all:
                          itemColor = Colors.blueGrey;
                          break;
                      }

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: isSelected ? itemColor.withValues(alpha: 0.1) : Colors.grey[50],
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected ? itemColor : Colors.grey[300]!,
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            setState(() => _recordFilter = f);
                            setSheetState(() {});
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Kayıt filtresi ayarlandı: ${f.title}'),
                                backgroundColor: itemColor,
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            child: Row(
                              children: [
                                Icon(
                                  isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                                  color: isSelected ? itemColor : Colors.grey[400],
                                  size: 22,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        f.title,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: isSelected ? itemColor : Colors.black87,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        f.subtitle,
                                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.amber.shade300),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.info_outline, color: Colors.orange, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '💡 Derece Nasıl Hesaplanır?\n'
                              '• Çukurun Büyüklüğü (%50): Genişledikçe araç ve yaya riski katlanır.\n'
                              '• Hasar Tipi (%25): Çukur doğrudan tekerlek kıran en yüksek risktir.\n'
                              '• AI Güveni (%25): Modelin tespit kesinliği puana yansır.',
                              style: TextStyle(fontSize: 12, color: Colors.brown[800], height: 1.3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildThresholdChip({
    required String label,
    required double threshold,
    required void Function(void Function()) setSheetState,
  }) {
    final isSelected = (_confThreshold - threshold).abs() < 0.02;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _confThreshold = threshold);
          setSheetState(() {});
          HapticFeedback.selectionClick();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? Colors.deepOrange : Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? Colors.deepOrange : Colors.grey[300]!,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: isSelected ? Colors.white : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (_running) {
        cameraController.stopImageStream();
        _running = false;
        WakelockPlus.disable();
        if (mounted) setState(() {});
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _positionSub?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Tarama'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Kayıt Seviyesi Ayarı',
            onPressed: _showFilterDialog,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                'Kayit: $_savedCount',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
      body: _controller == null || !_controller!.value.isInitialized
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: AspectRatio(
                    aspectRatio: 1 / _controller!.value.aspectRatio,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: (_) => _baseZoom = _currentZoom,
                      onScaleUpdate: (details) =>
                          _setZoom(_baseZoom * details.scale),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CameraPreview(_controller!),
                          if (_current.isNotEmpty && _imgW > 0 && _imgH > 0)
                            Positioned.fill(
                              child: CustomPaint(
                                painter: DetectionPainter(
                                  detections: _current,
                                  imageSize: Size(_imgW.toDouble(), _imgH.toDouble()),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 12, left: 12, right: 12),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _running
                              ? (_current.isEmpty
                                  ? '🔴 TARAMA AKTIF (Yol taranıyor...)'
                                  : '🔴 ${_current.length} HEDEF BULUNDU')
                              : '⏸ DURAKLATILDI',
                          style: TextStyle(
                            color: _current.isEmpty ? Colors.white : Colors.amberAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      // Tıklanabilir filtre durum butonları
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          GestureDetector(
                            onTap: _showFilterDialog,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.6)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.shield, color: Colors.amberAccent, size: 13),
                                  const SizedBox(width: 5),
                                  Text(
                                    'Kayıt: ${_recordFilter.title}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.tune, color: Colors.white70, size: 12),
                                ],
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              setState(() => _roadFilter = !_roadFilter);
                              HapticFeedback.lightImpact();
                              ScaffoldMessenger.of(context).clearSnackBars();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(_roadFilter
                                      ? '🛣️ Yol / Asfalt Filtresi AÇIK (Masa ve fare gibi nesneler elenir)'
                                      : '⚠️ Yol Filtresi KAPALI (Tüm zeminler taranıyor)'),
                                  backgroundColor: _roadFilter ? const Color(0xFF1B5E20) : const Color(0xFFB71C1C),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: _roadFilter ? const Color(0xFF1B5E20).withValues(alpha: 0.9) : Colors.black87,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: _roadFilter ? Colors.greenAccent : Colors.redAccent,
                                  width: 1.4,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _roadFilter ? Icons.verified : Icons.warning_amber_rounded,
                                    color: _roadFilter ? Colors.greenAccent : Colors.redAccent,
                                    size: 13,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    _roadFilter ? '🛣️ Asfalt Filtresi: AÇIK' : '🛣️ Filtre: KAPALI',
                                    style: TextStyle(
                                      color: _roadFilter ? Colors.greenAccent : Colors.redAccent,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Kayıtlı Çukur Yaklaşma Alarmı (Radarda tespit edilince açılır)
                if (_approachingPothole != null)
                  Positioned(
                    top: 110,
                    left: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFB71C1C).withValues(alpha: 0.96),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.yellowAccent, width: 2.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.redAccent.withValues(alpha: 0.8),
                            blurRadius: 18,
                            spreadRadius: 2,
                          ),
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
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '🚨 DİKKAT! ÇUKUR İKAZI (${_approachingDistance?.toStringAsFixed(0)}m İLERİDE)',
                                      style: const TextStyle(
                                        color: Colors.yellowAccent,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Kayıtlı ${_approachingPothole!.detectedClass} yaklaştı! Yavaşlayın.',
                                      style: const TextStyle(color: Colors.white, fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                                constraints: const BoxConstraints(),
                                padding: EdgeInsets.zero,
                                onPressed: () => setState(() => _approachingPothole = null),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              // "Tamir Edilmiş" Butonu
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () async {
                                    final pothole = _approachingPothole;
                                    if (pothole != null) {
                                      pothole.status = 'resolved';
                                      final messenger = ScaffoldMessenger.of(context);
                                      await pothole.save();
                                      _savedPotholes.removeWhere((p) => p.id == pothole.id);
                                      HapticFeedback.mediumImpact();
                                      setState(() => _approachingPothole = null);
                                      if (!mounted) return;
                                      messenger.showSnackBar(
                                        const SnackBar(
                                          content: Text('✅ Harika! Çukur "Tamir Edildi" olarak kaydedildi.'),
                                          backgroundColor: Colors.green,
                                          duration: Duration(seconds: 3),
                                        ),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.check_circle, size: 16),
                                  label: const Text('Tamir Edildi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green.shade700,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // "Haritada Gör" Butonu
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    if (_approachingPothole != null) {
                                      LocationService.openMaps(
                                        _approachingPothole!.latitude,
                                        _approachingPothole!.longitude,
                                        title: 'Tehlike: ${_approachingPothole!.detectedClass}',
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.directions, size: 16),
                                  label: const Text('Haritada Gör', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF1E88E5),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                Positioned(
                  bottom: 110,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [1.0, 1.5, 2.0, 3.0].map((z) {
                          final isSelected = (_currentZoom - z).abs() < 0.2;
                          final isOptimal = z == 1.5;
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => _setZoom(z),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? (isOptimal ? Colors.amber : Colors.white)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text(
                                  isOptimal ? '1.5x (En İyi)' : '${z.toStringAsFixed(1)}x',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: isSelected
                                        ? Colors.black
                                        : (isOptimal ? Colors.amberAccent : Colors.white70),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: FloatingActionButton.large(
                      backgroundColor: _running ? Colors.red : Colors.green,
                      onPressed: _toggle,
                      child: Icon(
                        _running ? Icons.pause : Icons.play_arrow,
                        size: 40,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class DetectionPainter extends CustomPainter {
  final List<Detection> detections;
  final Size imageSize;

  DetectionPainter({required this.detections, required this.imageSize});

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return;

    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    for (final d in detections) {
      final isIssue = AIDetector.isRoadIssue(d);
      final Color boxColor;
      final String label;

      if (isIssue) {
        final sev = AIDetector.calculateSeverity(d, imageSize.width.toInt(), imageSize.height.toInt());
        boxColor = sev.color;
        label = '[${sev.label.toUpperCase()} %${sev.score}] ${d.className}';
      } else {
        boxColor = Colors.greenAccent;
        label = '${d.className} %${(d.confidence * 100).toStringAsFixed(0)}';
      }

      final paint = Paint()
        ..color = boxColor
        ..strokeWidth = 3.5
        ..style = PaintingStyle.stroke;

      final rect = Rect.fromLTRB(
        d.bbox.left * scaleX,
        d.bbox.top * scaleY,
        d.bbox.right * scaleX,
        d.bbox.bottom * scaleY,
      );

      // Yuvarlatılmış kutu çiz
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        paint,
      );

      // Etiket metni (% olasılık ve tehlike derecesi ile)
      final tp = TextPainter(
        text: TextSpan(
          text: ' $label ',
          style: TextStyle(
            color: Colors.white,
            backgroundColor: boxColor.withValues(alpha: 0.9),
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      tp.paint(canvas, Offset(rect.left, math.max(0, rect.top - 20)));
    }
  }

  @override
  bool shouldRepaint(covariant DetectionPainter old) => true;
}
