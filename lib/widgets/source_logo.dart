import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../sources/source_catalog.dart';
import '../theme.dart';

/// The marks of the sources something came from, standing in for their names.
///
/// A row in the library repeats its origin on every line, and spelling it out
/// crowds out the thing the row is actually about.
class SourceMarks extends StatelessWidget {
  const SourceMarks({
    super.key,
    required this.sourceNames,
    this.size = 16,
    this.maxShown = 3,
  });

  /// Source names as the scan recorded them, resolved through the catalog.
  final Iterable<String> sourceNames;

  final double size;

  /// Beyond this, the rest are counted rather than drawn.
  final int maxShown;

  @override
  Widget build(BuildContext context) {
    final sources = [for (final name in sourceNames) ?sourceNamed(name)];
    if (sources.isEmpty) return const SizedBox.shrink();

    final shown = sources.take(maxShown).toList();
    final hidden = sources.length - shown.length;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final source in shown)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: SourceLogo(source: source, size: size),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(left: 5),
            child: Text(
              '+$hidden',
              style: TextStyle(
                fontFamily: KandooFonts.mono,
                fontSize: size * 0.62,
                color: KandooColors.textMuted,
              ),
            ),
          ),
      ],
    );
  }
}

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
