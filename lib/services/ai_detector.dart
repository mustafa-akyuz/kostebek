import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

class Detection {
  final int classIndex;
  final String className;
  final double confidence;
  final Rect bbox;

  Detection({
    required this.classIndex,
    required this.className,
    required this.confidence,
    required this.bbox,
  });
}

class AIDetector {
  static Interpreter? _interpreter;
  static const int inputSize = 640;
  static double confThreshold = 0.35;
  static const List<String> classNames = [
    'Çukur',
    'Yol Hasarı',
    'Yol Yaması',
    'Sağlam Yol',
  ];

  /// Gerçek model sınıf adı → Türkçe görünen ad eşlemesi.
  /// Model metadata (best_saved_model/metadata.yaml):
  /// 0=pothole, 1=road_damage, 2=road_patch, 3=intact_road
  static const List<String> modelClassNames = [
    'pothole',
    'road_damage',
    'road_patch',
    'intact_road',
  ];

  /// Sadece yol sorunu olan sınıflar kaydedilir.
  /// 'Sağlam Yol' (intact_road) sorun değildir, kaydedilmez.
  static bool isRoadIssue(Detection d) => d.classIndex != 3;

  static bool isRoadIssueName(String className) =>
      className != 'Sağlam Yol';

  static bool gpuActive = false;

  static Future<void> loadModel() async {
    if (_interpreter != null) return;
    // Önce GPU dene, olmazsa XNNPACK/CPU'ya düş.
    try {
      final gpu = GpuDelegateV2();
      final options = InterpreterOptions()
        ..threads = 4
        ..addDelegate(gpu);
      _interpreter = await Interpreter.fromAsset(
          'assets/models/pothole.tflite',
          options: options);
      gpuActive = true;
      print('[AIDetector] AI model yuklendi (GPU)');
    } catch (e) {
      print('[AIDetector] GPU yok, CPU moduna geciliyor: $e');
      try {
        final options = InterpreterOptions()..threads = 4;
        try {
          options.addDelegate(XNNPackDelegate());
        } catch (_) {}
        _interpreter = await Interpreter.fromAsset(
            'assets/models/pothole.tflite',
            options: options);
        gpuActive = false;
        print('[AIDetector] AI model yuklendi (CPU/XNNPACK)');
      } catch (e2) {
        print('[AIDetector] Model yukleme hatasi: $e2');
        rethrow;
      }
    }
  }

  static Future<List<Detection>> detect(
    img.Image image, {
    double? threshold,
    bool checkRoadSurface = true,
  }) async {
    if (_interpreter == null) await loadModel();

    final resized =
        img.copyResize(image, width: inputSize, height: inputSize);

    // RGB kanallarını doğru sırada (stride=1) normalize float array'e aktar
    final bytes = resized.getBytes(order: img.ChannelOrder.rgb);
    final input = Float32List(1 * inputSize * inputSize * 3);
    for (int i = 0; i < bytes.length; i++) {
      input[i] = bytes[i] / 255.0;
    }

    // Model çıktısı [1, 8, 8400]: 4 bbox (cx, cy, w, h) + 4 sınıf olasılığı
    final numFeatures = 4 + classNames.length;
    const numBoxes = 8400;
    final outputBuffer = List.filled(1 * numFeatures * numBoxes, 0.0)
        .reshape([1, numFeatures, numBoxes]);

    try {
      _interpreter!.run(input.buffer, outputBuffer);
    } catch (e) {
      try {
        final inputBuffer = input.reshape([1, inputSize, inputSize, 3]);
        _interpreter!.run(inputBuffer, outputBuffer);
      } catch (e2) {
        print('[AIDetector] Inference hatasi: $e2');
        return [];
      }
    }

    final raw = outputBuffer[0] as List;
    final effectiveThreshold = threshold ?? confThreshold;
    final rawDetections = _parseTransposed(
      raw,
      image.width,
      image.height,
      numBoxes,
      effectiveThreshold,
    );
    final nmsDetections = _nms(rawDetections);

    if (!checkRoadSurface) {
      return nmsDetections;
    }

    // YOL VE ASFALT DOĞRULAMA FİLTRESİ:
    // Masaüstü, bilgisayar faresi, oda mobilyası gibi non-road nesneleri ve makro yakın çekimleri eler.
    return nmsDetections.where((d) {
      if (!isReasonableRoadPothole(d.bbox, image.width, image.height)) {
        return false;
      }
      return isLikelyRoadSurface(image, d.bbox);
    }).toList();
  }

  static List<Detection> _parseTransposed(
      List raw, int origW, int origH, int numBoxes, double threshold) {
    final detections = <Detection>[];

    for (int j = 0; j < numBoxes; j++) {
      double maxConf = 0.0;
      int maxIdx = 0;
      for (int i = 0; i < classNames.length; i++) {
        final c = (raw[4 + i][j] as num).toDouble();
        if (c > maxConf) {
          maxConf = c;
          maxIdx = i;
        }
      }
      if (maxConf < threshold) continue;

      // Model cx, cy, w, h çıktısı 0.0 - 1.0 arasında normalize edilmiştir!
      // Doğrudan görsel boyutlarıyla çarpılır.
      final cx = (raw[0][j] as num).toDouble();
      final cy = (raw[1][j] as num).toDouble();
      final w = (raw[2][j] as num).toDouble();
      final h = (raw[3][j] as num).toDouble();

      final left = (cx - w / 2) * origW;
      final top = (cy - h / 2) * origH;
      final right = (cx + w / 2) * origW;
      final bottom = (cy + h / 2) * origH;

      detections.add(Detection(
        classIndex: maxIdx,
        className: classNames[maxIdx],
        confidence: maxConf,
        bbox: Rect.fromLTRB(
          left.clamp(0.0, origW.toDouble()),
          top.clamp(0.0, origH.toDouble()),
          right.clamp(0.0, origW.toDouble()),
          bottom.clamp(0.0, origH.toDouble()),
        ),
      ));
    }

    return detections;
  }

  static List<Detection> _nms(List<Detection> dets,
      {double iouThreshold = 0.45}) {
    dets.sort((a, b) => b.confidence.compareTo(a.confidence));
    final result = <Detection>[];

    while (dets.isNotEmpty) {
      final best = dets.removeAt(0);
      result.add(best);
      dets.removeWhere((d) => _iou(best.bbox, d.bbox) > iouThreshold);
    }
    return result;
  }

  static double _iou(Rect a, Rect b) {
    final interLeft = a.left > b.left ? a.left : b.left;
    final interTop = a.top > b.top ? a.top : b.top;
    final interRight = a.right < b.right ? a.right : b.right;
    final interBottom = a.bottom < b.bottom ? a.bottom : b.bottom;

    if (interRight <= interLeft || interBottom <= interTop) return 0;

    final interArea = (interRight - interLeft) * (interBottom - interTop);
    final unionArea = a.width * a.height + b.width * b.height - interArea;
    return unionArea <= 0 ? 0 : interArea / unionArea;
  }

  /// Nesnenin etrafındaki zeminin asfalt/yol benzeri nötr tonlarda olup olmadığını doğrular.
  /// Ahşap masa, canlı renkli mousepad, iç mekan mobilyaları gibi yüksek doygunluklu zeminleri eler.
  static bool isLikelyRoadSurface(img.Image image, Rect bbox) {
    try {
      final left = math.max(0, bbox.left.toInt() - 15);
      final top = math.max(0, bbox.top.toInt() - 15);
      final right = math.min(image.width - 1, bbox.right.toInt() + 15);
      final bottom = math.min(image.height - 1, bbox.bottom.toInt() + 15);

      int totalSamples = 0;
      double totalSaturation = 0.0;
      int highSaturationCount = 0;

      final stepX = math.max(1, (right - left) ~/ 8);
      final stepY = math.max(1, (bottom - top) ~/ 8);

      for (int y = top; y <= bottom; y += stepY) {
        for (int x = left; x <= right; x += stepX) {
          // Doğrudan kutunun iç merkezindeki çukur çöküntüsünü atla, çevre zemini analiz et
          if (x > bbox.left + 5 && x < bbox.right - 5 && y > bbox.top + 5 && y < bbox.bottom - 5) {
            continue;
          }

          final pixel = image.getPixel(x, y);
          final r = pixel.r.toDouble();
          final g = pixel.g.toDouble();
          final b = pixel.b.toDouble();

          final maxC = math.max(r, math.max(g, b));
          final minC = math.min(r, math.min(g, b));

          if (maxC > 15) {
            final sat = (maxC - minC) / maxC;
            totalSaturation += sat;
            if (sat > 0.30) {
              highSaturationCount++;
            }
          }
          totalSamples++;
        }
      }

      if (totalSamples == 0) return true;
      final avgSat = totalSaturation / totalSamples;
      final highSatRatio = highSaturationCount / totalSamples;

      // Gerçek asfalt/yol rengi nötr gridir (ortalama doygunluk < %25).
      // Ahşap masa, oda mobilyası veya renkli eşyalarda bu değer %40 - %70 çıkar ve elenir:
      if (avgSat > 0.25 || highSatRatio > 0.35) {
        return false;
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  /// Gerçek sürüşte yol üzerindeki çukurun makul boyut ve oranlarda olmasını sağlar
  static bool isReasonableRoadPothole(Rect bbox, int origW, int origH) {
    if (origW <= 0 || origH <= 0) return true;
    final areaPercent = ((bbox.width * bbox.height) / (origW * origH)) * 100.0;

    // Masadaki fareyi kameraya 10-15 cm dayayınca ekranın %35'inden fazlasını kaplar.
    // Araçta giderken yoldaki çukur tüm ekranın %35'ini kaplayamaz:
    if (areaPercent > 35.0) return false;

    // Aşırı ufak parazitleri ele (< %0.2)
    if (areaPercent < 0.2) return false;

    // Aşırı ince şerit parazitlerini ele
    final ratio = bbox.width / (bbox.height > 0 ? bbox.height : 1.0);
    if (ratio > 7.0 || ratio < 0.15) return false;

    return true;
  }

  /// Çukurun boyutu, sınıfı ve güvenine göre insana/araca zarar verme tehlike seviyesini hesaplar.
  static SeverityInfo calculateSeverity(Detection d, int imageW, int imageH) {
    final boxW = d.bbox.width;
    final boxH = d.bbox.height;
    final areaPercent = imageW > 0 && imageH > 0
        ? ((boxW * boxH) / (imageW * imageH)) * 100.0
        : 2.0;

    // Hasar sınıfı tehlike ağırlığı
    // 0: Çukur (Doğrudan tekerlek kırıcı, kaza/düşme riski en yüksek hasar)
    // 1: Yol Hasarı (Açık rögar, derin çatlak vb.)
    // 2: Yol Yaması (Hafif kabarma)
    double classWeight = 1.0;
    if (d.classIndex == 0) {
      classWeight = 1.0;
    } else if (d.classIndex == 1) {
      classWeight = 0.85;
    } else if (d.classIndex == 2) {
      classWeight = 0.45;
    } else {
      classWeight = 0.1;
    }

    // Puanlama (1 - 100):
    // Yol üzerinde 1-5% arası çukurlar en tehlikeli sürüş çukurlarıdır.
    // Aşırı devasa (> %25) nesneler kameraya aşırı yakın masa/eşya çekimidir, skor düşürülür.
    double areaScore;
    if (areaPercent > 25.0) {
      areaScore = 15.0; // Aşırı yakın çekim cezası
    } else {
      areaScore = (areaPercent / 5.0).clamp(0.1, 1.0) * 50.0;
    }

    // Güvenilirlik puanı (0-25 puan)
    final confScore = d.confidence.clamp(0.0, 1.0) * 25.0;
    // Hasar ciddiyet çarpanı (0-25 puan)
    final typeScore = classWeight * 25.0;

    final score = (areaScore + confScore + typeScore).round().clamp(1, 100);

    SeverityLevel lvl;
    if (score >= 70) {
      lvl = SeverityLevel.critical;
    } else if (score >= 50) {
      lvl = SeverityLevel.high;
    } else if (score >= 30) {
      lvl = SeverityLevel.medium;
    } else {
      lvl = SeverityLevel.low;
    }

    return SeverityInfo(
      level: lvl,
      score: score,
      areaPercent: areaPercent,
    );
  }

  /// Kaydedilen fotoğrafın üzerine çukur kutusunu ve tehlike derecesini kalıcı damgalar
  static img.Image stampDetectionOnImage(
      img.Image src, Detection d, SeverityInfo severity) {
    final stamped = img.Image.from(src);
    final w = stamped.width;
    final h = stamped.height;
    final maxDim = math.max(w, h);

    final x1 = d.bbox.left.round().clamp(0, w - 1);
    final y1 = d.bbox.top.round().clamp(0, h - 1);
    final x2 = d.bbox.right.round().clamp(0, w - 1);
    final y2 = d.bbox.bottom.round().clamp(0, h - 1);

    // Çözünürlüğe göre dinamik font ve çizgi kalınlığı
    final isHighRes = maxDim >= 1200;
    final isMedRes = maxDim >= 600;

    final boxThickness = isHighRes ? 8 : (isMedRes ? 5 : 3);
    final bannerFont = isHighRes ? img.arial48 : (isMedRes ? img.arial24 : img.arial14);
    final bannerH = isHighRes ? 56 : (isMedRes ? 34 : 24);
    final minBannerW = isHighRes ? 480 : (isMedRes ? 280 : 180);

    img.Color boxColor;
    if (severity.level == SeverityLevel.critical) {
      boxColor = img.ColorRgb8(230, 20, 20); // Canlı Kırmızı
    } else if (severity.level == SeverityLevel.high) {
      boxColor = img.ColorRgb8(240, 80, 20); // Turuncu-Kırmızı
    } else if (severity.level == SeverityLevel.medium) {
      boxColor = img.ColorRgb8(245, 140, 20); // Turuncu
    } else {
      boxColor = img.ColorRgb8(230, 190, 30); // Sarı
    }

    // 1. Resmin en üstüne resmi denetim şeridi (Top inspection banner)
    final topBarH = isHighRes ? 60 : (isMedRes ? 36 : 24);
    img.fillRect(
      stamped,
      x1: 0,
      y1: 0,
      x2: w - 1,
      y2: topBarH,
      color: img.ColorRgb8(20, 20, 25),
    );

    final topFont = isHighRes ? img.arial24 : img.arial14;
    final topText = 'CUKUR TESPIT | TEHLIKE: ${severity.label.toUpperCase()} (%${severity.score}) - ${severity.level == SeverityLevel.critical || severity.level == SeverityLevel.high ? "CAN VE MAL GUVENLIGI RISKI YUKSEK" : "YOL HASARI"}';
    img.drawString(
      stamped,
      topText,
      font: topFont,
      x: 12,
      y: (topBarH - 16) ~/ 2,
      color: boxColor,
    );

    // 2. Çukur etrafına kalın belirgin kutu çiz
    img.drawRect(
      stamped,
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      color: boxColor,
      thickness: boxThickness,
    );

    // 3. Çukur kutusunun üstüne bilgi şeridi çiz
    final bannerY1 = (y1 - bannerH).clamp(topBarH, h - bannerH);
    final bannerY2 = bannerY1 + bannerH;
    final boxW = (x2 - x1).abs();
    final bannerW = boxW < minBannerW ? minBannerW : boxW;
    final bannerX2 = (x1 + bannerW).clamp(0, w - 1);

    img.fillRect(
      stamped,
      x1: x1,
      y1: bannerY1,
      x2: bannerX2,
      y2: bannerY2,
      color: boxColor,
    );

    // 4. Çukur üstü etiket metni: Örn "[KRİTİK %88] CUKUR"
    final text = '[${severity.label.toUpperCase()} %${severity.score}] ${d.className.toUpperCase()}';
    img.drawString(
      stamped,
      text,
      font: bannerFont,
      x: x1 + 6,
      y: bannerY1 + (bannerH - (isHighRes ? 40 : (isMedRes ? 20 : 14))) ~/ 2,
      color: img.ColorRgb8(255, 255, 255),
    );

    return stamped;
  }

  /// Veritabanındaki Pothole nesnesinden tehlike derecesini çıkarır veya tahmin eder
  static SeverityInfo getPotholeSeverity(dynamic p) {
    final note = (p.note as String?) ?? '';
    if (note.contains('Kritik')) {
      final match = RegExp(r'%(\d+)').firstMatch(note);
      final score = match != null ? int.tryParse(match.group(1)!) ?? 85 : 85;
      return SeverityInfo(level: SeverityLevel.critical, score: score, areaPercent: 5.0);
    } else if (note.contains('Yüksek') || note.contains('Yuksek')) {
      final match = RegExp(r'%(\d+)').firstMatch(note);
      final score = match != null ? int.tryParse(match.group(1)!) ?? 65 : 65;
      return SeverityInfo(level: SeverityLevel.high, score: score, areaPercent: 3.5);
    } else if (note.contains('Orta')) {
      final match = RegExp(r'%(\d+)').firstMatch(note);
      final score = match != null ? int.tryParse(match.group(1)!) ?? 45 : 45;
      return SeverityInfo(level: SeverityLevel.medium, score: score, areaPercent: 2.0);
    } else if (note.contains('Düşük') || note.contains('Dusuk')) {
      final match = RegExp(r'%(\d+)').firstMatch(note);
      final score = match != null ? int.tryParse(match.group(1)!) ?? 25 : 25;
      return SeverityInfo(level: SeverityLevel.low, score: score, areaPercent: 1.0);
    }

    final conf = (p.confidence as double?) ?? 0.5;
    final cls = ((p.detectedClass as String?) ?? '').toLowerCase();
    final isPothole = cls.contains('çukur') || cls.contains('cukur') || cls.contains('pothole');
    if (isPothole && conf >= 0.6) {
      return const SeverityInfo(level: SeverityLevel.high, score: 75, areaPercent: 4.0);
    } else if (isPothole || conf >= 0.5) {
      return const SeverityInfo(level: SeverityLevel.medium, score: 50, areaPercent: 2.5);
    }
    return const SeverityInfo(level: SeverityLevel.low, score: 30, areaPercent: 1.5);
  }

  static void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}

enum SeverityLevel {
  critical('Kritik', 'ÇOK TEHLİKELİ - Kaza ve can güvenliği riski yüksek! Acil onarım gerekir.', Color(0xFFD32F2F)),
  high('Yüksek', 'TEHLİKELİ - Lastik patlatma, jant kırma veya yayanın düşme riski yüksek.', Color(0xFFE65100)),
  medium('Orta', 'ORTA HASAR - Araç alt takımı ve süspansiyona zarar verebilir.', Color(0xFFF57C00)),
  low('Düşük', 'HAFİF - Yüzey kusuru veya küçük çatlak.', Color(0xFFFBC02D));

  final String label;
  final String description;
  final Color color;

  const SeverityLevel(this.label, this.description, this.color);
}

class SeverityInfo {
  final SeverityLevel level;
  final int score; // 1 - 100
  final double areaPercent;

  const SeverityInfo({
    required this.level,
    required this.score,
    required this.areaPercent,
  });

  String get label => level.label;
  String get description => level.description;
  Color get color => level.color;
}
