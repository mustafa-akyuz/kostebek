import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../models/pothole.dart';
import '../services/ai_detector.dart';
import '../services/location_service.dart';
import '../services/share_service.dart';
import '../services/database_service.dart';
import '../screens/pothole_detail_screen.dart';

class PotholeCard extends StatelessWidget {
  final Pothole pothole;
  final VoidCallback? onDeleted;

  const PotholeCard({super.key, required this.pothole, this.onDeleted});

  IconData _statusIcon() {
    switch (pothole.status) {
      case 'sent':
        return Icons.check_circle;
      case 'resolved':
        return Icons.verified;
      default:
        return Icons.hourglass_empty;
    }
  }

  Color _statusColor() {
    switch (pothole.status) {
      case 'sent':
        return Colors.blue;
      case 'resolved':
        return Colors.green;
      default:
        return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('dd.MM.yyyy HH:mm').format(pothole.createdAt);
    final file = File(pothole.imagePath);
    final severity = AIDetector.getPotholeSeverity(pothole);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: severity.color.withValues(alpha: 0.3), width: 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PotholeDetailScreen(pothole: pothole),
            ),
          );
          onDeleted?.call();
        },
        onLongPress: () => _showQuickActions(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: file.existsSync()
                    ? Image.file(file, width: 78, height: 78, fit: BoxFit.cover)
                    : Container(
                        width: 78,
                        height: 78,
                        color: Colors.grey[300],
                        child: const Icon(Icons.broken_image),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            pothole.detectedClass,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        if (pothole.latitude != 0.0 && pothole.longitude != 0.0)
                          IconButton(
                            icon: const Icon(Icons.location_on, color: Color(0xFF1E88E5), size: 22),
                            tooltip: 'Google Haritalar\'da Aç',
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            constraints: const BoxConstraints(),
                            onPressed: () {
                              LocationService.openMaps(
                                pothole.latitude,
                                pothole.longitude,
                                title: '${pothole.detectedClass} (${severity.label})',
                              );
                            },
                          ),
                        const SizedBox(width: 6),
                        Icon(_statusIcon(), color: _statusColor(), size: 20),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        // Tehlike Seviyesi Rozeti
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: severity.color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: severity.color.withValues(alpha: 0.5)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.warning_amber_rounded, size: 14, color: severity.color),
                              const SizedBox(width: 4),
                              Text(
                                'Tehlike: ${severity.label} (%${severity.score})',
                                style: TextStyle(
                                  color: severity.color,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (pothole.status == 'resolved') ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.green.shade600),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.check_circle, size: 12, color: Colors.green),
                                SizedBox(width: 3),
                                Text(
                                  'Tamir Edildi',
                                  style: TextStyle(
                                    color: Colors.green,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.calendar_today, size: 12, color: Colors.grey[500]),
                        const SizedBox(width: 4),
                        Text(date,
                            style:
                                TextStyle(color: Colors.grey[600], fontSize: 11)),
                        const Spacer(),
                        Text(
                          'Güven: %${(pothole.confidence * 100).toStringAsFixed(0)}',
                          style: TextStyle(color: Colors.grey[600], fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showQuickActions(BuildContext context) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Text(
                        pothole.detectedClass,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const Spacer(),
                      Text(
                        DateFormat('dd.MM.yyyy HH:mm').format(pothole.createdAt),
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                if (pothole.latitude != 0.0 && pothole.longitude != 0.0)
                  ListTile(
                    leading: const Icon(Icons.directions, color: Color(0xFF1E88E5)),
                    title: const Text('Google Haritalar\'da Aç'),
                    subtitle: Text(
                      pothole.address.isNotEmpty
                          ? pothole.address
                          : '${pothole.latitude.toStringAsFixed(5)}, ${pothole.longitude.toStringAsFixed(5)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      LocationService.openMaps(
                        pothole.latitude,
                        pothole.longitude,
                        title: pothole.detectedClass,
                      );
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.chat, color: Color(0xFF25D366)),
                  title: const Text('WhatsApp ile Gönder'),
                  onTap: () {
                    Navigator.pop(ctx);
                    ShareService.shareWhatsApp(pothole);
                  },
                ),
                ListTile(
                  leading: Icon(
                    pothole.status == 'resolved' ? Icons.undo : Icons.check_circle,
                    color: Colors.green,
                  ),
                  title: Text(
                    pothole.status == 'resolved'
                        ? 'Tamir Edilmedi (Aktife Al)'
                        : 'Tamir Edildi Olarak İşaretle',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    pothole.status == 'resolved'
                        ? 'Radarda yaklaşma uyarısı tekrar açılır'
                        : 'Radarda yaklaşma uyarısı susturulur',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    pothole.status = pothole.status == 'resolved' ? 'pending' : 'resolved';
                    await pothole.save();
                    onDeleted?.call();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            pothole.status == 'resolved'
                                ? '✅ Çukur "Tamir Edildi" olarak işaretlendi (Radar susturuldu).'
                                : '⚠️ Çukur aktif olarak işaretlendi.',
                          ),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text('Bu Kaydı Sil', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await DatabaseService.delete(pothole.id);
                    onDeleted?.call();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('${pothole.detectedClass} silindi'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
