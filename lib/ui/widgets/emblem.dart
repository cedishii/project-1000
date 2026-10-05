import 'package:flutter/material.dart';

/// The official logo emblem (extracted from the logo banner without
/// alteration by tool/prepare_branding.dart).
class Emblem extends StatelessWidget {
  const Emblem({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/branding/emblem.png',
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
    semanticLabel: 'Project: 1000 logo',
  );
}

/// The full official logo banner.
class LogoBanner extends StatelessWidget {
  const LogoBanner({super.key});

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: Image.asset(
      'assets/branding/logo_original.png',
      fit: BoxFit.cover,
      semanticLabel: 'Project: 1000 logo',
    ),
  );
}
