import 'package:flutter/material.dart';

import '../library/library_controller.dart';
import '../library/library_store.dart';
import '../settings/profile.dart';
import '../sources/item_actions.dart';
import '../theme.dart';
import '../widgets/page_shell.dart';
import '../widgets/source_logo.dart';

/// How the day is greeted, by the clock.
String greetingFor(DateTime when) {
  if (when.hour < 12) return 'Good morning';
  if (when.hour < 18) return 'Good afternoon';
  return 'Good evening';
}

/// The files most recently filed, newest first.
///
/// What the library knows about a file's age is when it last changed on its
/// source, which is as close to "this turned up" as Kandoo gets. A file with no
/// date at all goes last rather than pretending to be old or new.
List<LibraryEntry> recentlyFiled(List<LibraryEntry> entries, {int limit = 8}) {
  final dated = [
    for (final entry in entries)
      if (entry.file.modified != null) entry,
  ]..sort((a, b) => b.file.modified!.compareTo(a.file.modified!));

  return dated.length <= limit ? dated : dated.sublist(0, limit);
}

/// The Today section: the day, what it asks of you, and what Kandoo has been
/// doing with your files.
class TodayPage extends StatelessWidget {
  const TodayPage({
    super.key,
    required this.profile,
    required this.library,
    this.openUrl = openWithSystem,
    this.now,
  });

  final ProfileController profile;
  final LibraryController library;

  /// How a file is handed to the desktop, as on the Files page.
  final UrlOpener openUrl;

  /// Fixed by tests, which cannot wait for a particular hour of the day.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([profile, library]),
      builder: (context, _) {
        final today = now ?? DateTime.now();
        final name = profile.firstName;

        return PageShell(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(32, 4, 32, 32),
            children: [
              Text(
                '${greetingFor(today)}${name == null ? '' : ' $name'}!',
                style: const TextStyle(
                  fontFamily: KandooFonts.heading,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: KandooColors.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                _dayOf(today),
                style: const TextStyle(
                  fontSize: 13,
                  color: KandooColors.textMuted,
                ),
              ),
              const SizedBox(height: 24),

              // The two of them share the top of the section, one either side.
              const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _Card(
                      title: "Today's reminders",
                      icon: Icons.check_circle_outline,
                      child: _NotYet(
                        message:
                            'Nothing here yet. Reminders will come from the '
                            'places you already keep them — Todoist, your '
                            'calendar — once those are connected.',
                      ),
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: _Card(
                      title: 'Worth your attention',
                      icon: Icons.lightbulb_outline,
                      child: _NotYet(
                        message:
                            'Nothing here yet. Kandoo will put what it notices '
                            'in your files here: a bill coming due, a document '
                            'that has gone stale.',
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),
              _Card(
                title: 'Recent events',
                icon: Icons.history,
                child: _RecentEvents(
                  entries: recentlyFiled(library.entries),
                  library: library,
                  onOpen: (entry) => _open(context, entry),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _open(BuildContext context, LibraryEntry entry) async {
    final id = entry.file.externalId;
    final url = id == null
        ? localFileUrl(entry.file.path)
        : driveItemUrl(id, isFolder: false);

    if (await openUrl(url) || !context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not open ${entry.title}.'),
        behavior: SnackBarBehavior.floating,
        width: 320,
      ),
    );
  }

  /// 'Wednesday, 12 August 2026' — the date as a person would say it.
  static String _dayOf(DateTime when) {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];

    return '${days[when.weekday - 1]}, ${when.day} '
        '${months[when.month - 1]} ${when.year}';
  }
}

/// One panel of the section.
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 15, 18, 16),
      decoration: BoxDecoration(
        color: KandooColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: KandooColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: KandooColors.accentDeep),
              const SizedBox(width: 9),
              // Two panels side by side leave a narrow window little room for
              // a heading; it gives way rather than pushing past its card.
              Flexible(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: KandooFonts.heading,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: KandooColors.textPrimary,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// A panel that is built but not filled in yet, saying what will fill it.
class _NotYet extends StatelessWidget {
  const _NotYet({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        message,
        style: const TextStyle(
          fontSize: 12.5,
          height: 1.5,
          color: KandooColors.textMuted,
        ),
      ),
    );
  }
}

/// What Kandoo has filed lately: what turned up, and where it was put.
class _RecentEvents extends StatelessWidget {
  const _RecentEvents({
    required this.entries,
    required this.library,
    required this.onOpen,
  });

  final List<LibraryEntry> entries;
  final LibraryController library;
  final ValueChanged<LibraryEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return _NotYet(
        message: library.isBusy
            ? 'Kandoo is going through your files now.'
            : 'Nothing filed yet. Scan a source under Files, and what Kandoo '
                  'makes of it shows up here.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries)
          _EventRow(entry: entry, onTap: () => onOpen(entry)),
      ],
    );
  }
}

class _EventRow extends StatefulWidget {
  const _EventRow({required this.entry, required this.onTap});

  final LibraryEntry entry;
  final VoidCallback onTap;

  @override
  State<_EventRow> createState() => _EventRowState();
}

class _EventRowState extends State<_EventRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final folders = entry.folders.join('/');
    final modified = entry.file.modified;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: _hovered ? KandooColors.hoverFill : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              // The event itself — what turned up, and where it went — takes
              // whatever room is going, which keeps the date and the mark
              // against the right edge rather than adrift in the middle.
              Expanded(
                child: Row(
                  children: [
                    // What the file was called where it was found, which is how
                    // the user would recognise it arriving.
                    Flexible(
                      child: Text(
                        entry.file.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: KandooFonts.mono,
                          fontSize: 12,
                          color: KandooColors.textPrimary,
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 9),
                      child: Icon(
                        Icons.arrow_forward,
                        size: 13,
                        color: KandooColors.textMuted,
                      ),
                    ),
                    // Where it ended up, which is the part the user did not do.
                    Flexible(
                      child: Text(
                        folders.isEmpty ? 'the top level' : folders,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: KandooColors.accentDeep,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (modified != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    _isoDate(modified),
                    style: const TextStyle(
                      fontFamily: KandooFonts.mono,
                      fontSize: 11,
                      color: KandooColors.textMuted,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: SourceMarks(sourceNames: [entry.file.sourceName]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _isoDate(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }
}
