import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/leica_colors.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: LeicaColors.black,
      appBar: AppBar(
        backgroundColor: LeicaColors.surface,
        title: const Text('SETTINGS', style: TextStyle(letterSpacing: 3, fontSize: 13)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, size: 16),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        children: [
          _SectionHeader('COLOR SCIENCE'),
          _SettingsTile(
            title: 'Save RAW + JPEG',
            subtitle: 'Capture DNG alongside processed JPEG',
            trailing: Switch(value: false, onChanged: (_) {}, activeThumbColor: LeicaColors.red),
          ),
          _SettingsTile(
            title: 'Apply Looks to RAW',
            subtitle: 'Embed look metadata in DNG sidecar',
            trailing: Switch(value: false, onChanged: (_) {}, activeThumbColor: LeicaColors.red),
          ),
          _SectionHeader('LENS SIMULATION'),
          _SettingsTile(title: 'Vignetting', subtitle: 'Apply lens-matched corner fall-off', trailing: Switch(value: true, onChanged: (_) {}, activeThumbColor: LeicaColors.red)),
          _SettingsTile(title: 'Chromatic Aberration', subtitle: 'Simulate lens colour fringing', trailing: Switch(value: true, onChanged: (_) {}, activeThumbColor: LeicaColors.red)),
          _SettingsTile(title: 'Barrel Distortion', subtitle: 'Apply lens-specific distortion', trailing: Switch(value: false, onChanged: (_) {}, activeThumbColor: LeicaColors.red)),
          _SectionHeader('APERTURE MODE'),
          _SettingsTile(title: 'ML Segmentation', subtitle: 'Use on-device portrait segmentation for bokeh', trailing: Switch(value: true, onChanged: (_) {}, activeThumbColor: LeicaColors.red)),
          _SettingsTile(title: 'Depth Estimation', subtitle: 'Use AI depth map for scene-aware blur', trailing: Switch(value: false, onChanged: (_) {}, activeThumbColor: LeicaColors.red)),
          _SectionHeader('STORAGE'),
          _SettingsTile(title: 'Save Location', subtitle: 'Pictures/iCamera', trailing: const Icon(Icons.chevron_right, color: LeicaColors.lightGray)),
          _SettingsTile(title: 'HEIF Output', subtitle: 'Save in HEIF format instead of JPEG', trailing: Switch(value: false, onChanged: (_) {}, activeThumbColor: LeicaColors.red)),
          _SectionHeader('ABOUT'),
          const _SettingsTile(title: 'iCamera', subtitle: 'Version 1.0.0 — Leica-inspired mobile photography'),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        text,
        style: const TextStyle(
          color: LeicaColors.red,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title, style: const TextStyle(color: LeicaColors.textPrimary, fontSize: 14)),
      subtitle: subtitle != null
          ? Text(subtitle!, style: const TextStyle(color: LeicaColors.textSecondary, fontSize: 12))
          : null,
      trailing: trailing,
    );
  }
}
