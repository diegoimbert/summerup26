import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../sources/source_catalog.dart';

/// A source's brand mark on a soft tile tinted with its brand colour.
class SourceLogo extends StatelessWidget {
  const SourceLogo({super.key, required this.source, this.size = 40});

  final SourceDescriptor source;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: source.brandColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(size * 0.26),
      ),
      alignment: Alignment.center,
      child: SvgPicture.asset(
        source.logoAsset,
        width: size * 0.5,
        height: size * 0.5,
        // The marks are single-path and monochrome, so they take the brand
        // colour cleanly.
        colorFilter: ColorFilter.mode(source.brandColor, BlendMode.srcIn),
      ),
    );
  }
}
