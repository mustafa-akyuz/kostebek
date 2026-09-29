import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image_picker/image_picker.dart';
import '../services/ai_detector.dart';
import '../services/location_service.dart';
import '../services/database_service.dart';
import '../models/pothole.dart';

class ManualCameraScreen extends StatefulWidget {
  const ManualCameraScreen({super.key});

  @override
  State<ManualCameraScreen> createState() => _ManualCameraScreenState();
}

class _ManualCameraScreenState extends State<ManualCameraScreen> {
  CameraController? _controller;
  Future<void>? _initFuture;
  bool _busy = false;
  String _status = 'Hazır. Fotoğraf çekin veya galeriden yükleyin.';

  // Zoom ayarları
  double _minZoom = 1.0;
  double _maxZoom = 5.0;
  double _currentZoom = 1.5;
  double _baseZoom = 1.5;

  @override
  void initState() {
    super.initState();
    _initFuture = _init();
  }

  Future<void> _init() async {
    try {
      final camStatus = await Permission.camera.request();
      if (!camStatus.isGranted) {
        setState(() => _status = 'Kamera izni verilmedi. Galeriden görsel yükleyebilirsiniz.');
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _status = 'Kamera bulunamadı. Galeriden görsel yükleyebilirsiniz.');
        return;
      }

      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await _controller!.initialize();

      try {
        _minZoom = await _controller!.getMinZoomLevel();
        _maxZoom = await _controller!.getMaxZoomLevel();
        _currentZoom = 1.5.clamp(_minZoom, _maxZoom);
        await _controller!.setZoomLevel(_currentZoom);
      } catch (_) {}

      if (mounted) setState(() {});
    } catch (e) {
      print('[ManualCameraScreen] Init hatasi: $e');
      if (mounted) setState(() => _status = 'Kamera başlatılamadı: $e');
    }
  }

  Future<void> _setZoom(double zoom) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final target = zoom.clamp(_minZoom, _maxZoom);
    try {
      await _controller!.setZoomLevel(target);
      setState(() => _currentZoom = target);
    } catch (_) {}
  }

  Future<void> _capture() async {
    if (_controller == null || !_controller!.value.isInitialized || _busy) {
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Fotoğraf çekiliyor...';
    });

    try {
      final shot = await _controller!.takePicture();
      final bytes = await shot.readAsBytes();
      await _processImageBytes(bytes, sourceTag: 'Kamera Çekimi');
    } catch (e) {
      setState(() => _status = 'Hata: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndAnalyzeImage() async {
    if (_busy) return;
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
      );
      if (picked == null) return;

      setState(() {
        _busy = true;
        _status = 'Görsel yükleniyor ve taranıyor...';
      });

      final bytes = await picked.readAsBytes();
      await _processImageBytes(bytes, sourceTag: 'Galeri Yüklemesi');
    } catch (e) {
      if (mounted) setState(() => _status = 'Görsel yükleme hatası: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _processImageBytes(List<int> bytes, {required String sourceTag}) async {
    setState(() => _status = 'Yapay zeka çukuru analiz ediyor...');
    final decoded = img.decodeImage(bytes as dynamic);
    if (decoded == null) throw Exception('Görsel çözümlenemedi');

    final detections = await AIDetector.detect(decoded);
    final issues = detections.where(AIDetector.isRoadIssue).toList();

    setState(() => _status = 'Konum alınıyor...');
    final pos = await LocationService.getPosition();
    final lat = pos?.latitude ?? 0.0;
    final lon = pos?.longitude ?? 0.0;
    final addr = (lat != 0 && lon != 0)
        ? await LocationService.getAddress(lat, lon)
        : '';

    final dir = await getApplicationDocumentsDirectory();
    final savePath = '${dir.path}/${const Uuid().v4()}.jpg';

    if (issues.isNotEmpty) {
      final best = issues.reduce(
        (a, b) => a.confidence > b.confidence ? a : b,
      );
      final severity = AIDetector.calculateSeverity(best, decoded.width, decoded.height);

      setState(() => _status = 'Damgalanarak kaydediliyor...');
      final stamped = AIDetector.stampDetectionOnImage(decoded, best, severity);
      await File(savePath).writeAsBytes(img.encodeJpg(stamped, quality: 85));

      final pothole = Pothole(
        id: const Uuid().v4(),
        imagePath: savePath,
        latitude: lat,
        longitude: lon,
        createdAt: DateTime.now(),
        detectedClass: best.className,
        confidence: best.confidence,
        address: addr,
        note: '$sourceTag - ${severity.label} (%${severity.score}) - ${severity.description}',
        status: 'pending',
      );
      await DatabaseService.add(pothole);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$sourceTag: ${best.className} [${severity.label} %${severity.score}] kaydedildi!',
            ),
            backgroundColor: severity.color,
            duration: const Duration(seconds: 3),
          ),
        );
        Navigator.pop(context);
      }
    } else {
      // AI tespit edememişse bile kullanıcıya manuel kaydetme şansı ver
      if (!mounted) return;
      final shouldSave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E222A),
          title: const Row(
            children: [
              Icon(Icons.help_outline, color: Colors.amber),
              SizedBox(width: 8),
              Text('Çukur Tespiti', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: const Text(
            'Yapay zeka bu fotoğrafta belirgin bir çukur algılayamadı.\n\nYine de bu fotoğrafı sisteme manuel çukur olarak kaydetmek istiyor musunuz?',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('İptal', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Evet, Çukur Olarak Kaydet', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );

      if (shouldSave == true) {
        await File(savePath).writeAsBytes(img.encodeJpg(decoded, quality: 85));
        final pothole = Pothole(
          id: const Uuid().v4(),
          imagePath: savePath,
          latitude: lat,
          longitude: lon,
          createdAt: DateTime.now(),
          detectedClass: 'Manuel Çukur',
          confidence: 1.0,
          address: addr,
          note: '$sourceTag - Kullanıcı tarafından manuel kaydedildi.',
          status: 'pending',
        );
        await DatabaseService.add(pothole);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Fotoğraf başarıyla manuel çukur olarak listeye kaydedildi!'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
          Navigator.pop(context);
        }
      } else {
        setState(() => _status = 'İşlem iptal edildi. Hazır.');
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Manuel Çekim & Yükleme'),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library),
            tooltip: 'Galeriden Görsel Yükle',
            onPressed: _busy ? null : _pickAndAnalyzeImage,
          ),
        ],
      ),
      body: FutureBuilder(
        future: _initFuture,
        builder: (context, snap) {
          final isReady = _controller != null && _controller!.value.isInitialized;

          return Stack(
            fit: StackFit.expand,
            children: [
              if (isReady)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: (_) => _baseZoom = _currentZoom,
                  onScaleUpdate: (details) => _setZoom(_baseZoom * details.scale),
                  child: CameraPreview(_controller!),
                )
              else
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.photo_size_select_actual_outlined, size: 64, color: Colors.white54),
                        const SizedBox(height: 16),
                        Text(
                          _status,
                          style: const TextStyle(color: Colors.white70, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepOrange,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          ),
                          icon: const Icon(Icons.photo_library),
                          label: const Text('Galeriden Fotoğraf Seç'),
                          onPressed: _busy ? null : _pickAndAnalyzeImage,
                        ),
                      ],
                    ),
                  ),
                ),
              if (isReady)
                Positioned(
                  bottom: 180,
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
                child: Container(
                  width: double.infinity,
                  color: Colors.black87,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _status,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          // Galeriden Seç / Yükle butonu
                          InkWell(
                            borderRadius: BorderRadius.circular(30),
                            onTap: _busy ? null : _pickAndAnalyzeImage,
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white12,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white24),
                              ),
                              child: const Icon(
                                Icons.photo_library,
                                size: 28,
                                color: Colors.amber,
                              ),
                            ),
                          ),
                          // Canlı Kamera Deklanşörü
                          FloatingActionButton.large(
                            heroTag: 'capture',
                            backgroundColor: isReady ? Colors.white : Colors.grey,
                            onPressed: (_busy || !isReady) ? null : _capture,
                            child: _busy
                                ? const CircularProgressIndicator()
                                : const Icon(Icons.camera_alt, size: 36, color: Colors.black),
                          ),
                          // Simetrik Yardım / Bilgi ikonu
                          InkWell(
                            borderRadius: BorderRadius.circular(30),
                            onTap: () {
                              showModalBottomSheet(
                                context: context,
                                backgroundColor: const Color(0xFF1E222A),
                                shape: const RoundedRectangleBorder(
                                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                                ),
                                builder: (_) => Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        '📸 Manuel Çekim & Görsel Yükleme',
                                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                                      ),
                                      const SizedBox(height: 12),
                                      const Text(
                                        '• Beyaz Deklanşör: Kamerayla anlık yol ve çukur fotoğrafı çeker.\n'
                                        '• Sarı Galeri İkonu: Daha önce çektiğiniz fotoğrafları albümden seçip yükler.\n'
                                        '• Yapay Zeka: Görseli anında tarar, çukurun derinliğini ve konumunu tespit ederek haritaya işler.',
                                        style: TextStyle(color: Colors.white70, height: 1.5),
                                      ),
                                      const SizedBox(height: 16),
                                      SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton(
                                          style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange),
                                          onPressed: () => Navigator.pop(context),
                                          child: const Text('Anladım', style: TextStyle(color: Colors.white)),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white12,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white24),
                              ),
                              child: const Icon(
                                Icons.info_outline,
                                size: 28,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
