import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/pothole.dart';
import '../services/ai_detector.dart';
import '../services/share_service.dart';
import '../services/location_service.dart';
import '../services/database_service.dart';

class PotholeDetailScreen extends StatefulWidget {
  final Pothole pothole;
  const PotholeDetailScreen({super.key, required this.pothole});

  @override
  State<PotholeDetailScreen> createState() => _PotholeDetailScreenState();
}

class _PotholeDetailScreenState extends State<PotholeDetailScreen> {
  late TextEditingController _noteCtrl;
  late TextEditingController _phoneCtrl;

  @override
  void initState() {
    super.initState();
    _noteCtrl = TextEditingController(text: widget.pothole.note);
    _phoneCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Kaydi Sil?'),
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
      await DatabaseService.delete(widget.pothole.id);
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _openMaps() async {
    try {
      final success = await LocationService.openMaps(
        widget.pothole.latitude,
        widget.pothole.longitude,
        title: '${widget.pothole.detectedClass} (${AIDetector.getPotholeSeverity(widget.pothole).label})',
      );
      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bu çukur için GPS konumu bulunamadı veya harita açılamadı.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      print('[PotholeDetailScreen] Harita hatasi: $e');
    }
  }

  Future<void> _saveNote() async {
    try {
      widget.pothole.note = _noteCtrl.text.trim();
      await widget.pothole.save();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not kaydedildi')),
        );
      }
    } catch (e) {
      print('[PotholeDetailScreen] Not kayit hatasi: $e');
    }
  }

  Future<void> _setStatus(String status) async {
    try {
      widget.pothole.status = status;
      await widget.pothole.save();
      if (mounted) setState(() {});
    } catch (e) {
      print('[PotholeDetailScreen] Durum hatasi: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pothole;
    final file = File(p.imagePath);
    final date = DateFormat('dd.MM.yyyy HH:mm').format(p.createdAt);
    final severity = AIDetector.getPotholeSeverity(p);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kayit Detayi'),
        actions: [
          IconButton(icon: const Icon(Icons.delete), onPressed: _confirmDelete),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (file.existsSync())
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child:
                    Image.file(file, width: double.infinity, fit: BoxFit.cover),
              ),
            const SizedBox(height: 14),
            // Tehlike ve Zarar Seviyesi Kartı
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: severity.color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: severity.color, width: 1.8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.report_problem, color: severity.color, size: 24),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'TEHLİKE DERECESİ: ${severity.label.toUpperCase()} (%${severity.score})',
                          style: TextStyle(
                            color: severity.color,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    severity.description,
                    style: TextStyle(
                      color: Colors.brown[900],
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _infoRow('Tespit', p.detectedClass, Icons.warning_amber),
            _infoRow('Guvenilirlik',
                '%${(p.confidence * 100).toStringAsFixed(0)}', Icons.shield),
            _infoRow('Tarih', date, Icons.calendar_today),
            _infoRow(
              'Konum',
              '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}',
              Icons.location_on,
            ),
            if (p.address.isNotEmpty)
              _infoRow('Adres', p.address, Icons.map),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _openMaps,
              icon: const Icon(Icons.directions),
              label: const Text(
                'Google Haritalar\'da Aç (Navigasyon Başlat)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1E88E5), // Google Maps mavisi
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Durum', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'pending',
                  label: Text('Bekliyor'),
                  icon: Icon(Icons.hourglass_empty),
                ),
                ButtonSegment(
                  value: 'sent',
                  label: Text('Bildirildi'),
                  icon: Icon(Icons.send),
                ),
                ButtonSegment(
                  value: 'resolved',
                  label: Text('Tamir Edildi'),
                  icon: Icon(Icons.check_circle),
                ),
              ],
              selected: {p.status},
              onSelectionChanged: (s) => _setStatus(s.first),
            ),
            if (p.status == 'resolved') ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.shade300),
                ),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green.shade700, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Bu çukur tamir edildi. Sürüş sırasında radar bu nokta için yaklaşma ikazı vermeyecektir.',
                        style: TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _noteCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Not',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _saveNote,
              icon: const Icon(Icons.save),
              label: const Text('Notu Kaydet'),
            ),
            const Divider(height: 32),
            const Text(
              'PAYLAS (kendi istedigin zaman)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Telefon (opsiyonel, orn: 905551234567)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () async {
                await ShareService.shareWhatsApp(
                  p,
                  phone: _phoneCtrl.text.trim(),
                );
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.chat),
              label: const Text('WhatsApp ile Gonder'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF25D366),
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 52),
              ),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: () async {
                await ShareService.shareSMS(p, phone: _phoneCtrl.text.trim());
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.sms),
              label: const Text('SMS ile Gonder'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 52),
              ),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: () async {
                await ShareService.shareAnywhere(p);
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.share),
              label: const Text('Diger Uygulamalar'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 52),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Colors.deepOrange),
          const SizedBox(width: 10),
          SizedBox(
            width: 100,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
