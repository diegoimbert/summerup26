import 'package:flutter/widgets.dart';

/// How far a source has actually been built.
enum SourceSupport {
  /// Sign-in is wired up and credentials are persisted.
  connectable,

  /// Listed in the UI only. Nothing behind it yet.
  planned,
}

/// A content provider Kandoo can pull from.
@immutable
class SourceDescriptor {
  const SourceDescriptor({
    required this.id,
    required this.name,
    required this.tagline,
    required this.logoAsset,
    required this.brandColor,
    required this.support,
  });

  /// Stable key, also used to store this source's credentials.
  final String id;

  final String name;

  /// One-liner shown under the name.
  final String tagline;

  final String logoAsset;

  /// Used to tint the monochrome brand mark.
  final Color brandColor;

  final SourceSupport support;

  bool get isConnectable => support == SourceSupport.connectable;
}

/// Every source offered on the Sources page.
///
/// Only Google Drive and Notion are [SourceSupport.connectable]; the rest are
/// listed so the shape of the page is right, and are explicitly marked as not
/// yet built rather than pretending to connect.
const List<SourceDescriptor> kSourceCatalog = [
  SourceDescriptor(
    id: 'google_drive',
    name: 'Google Drive',
    tagline: 'Documents, sheets and folders',
    logoAsset: 'assets/logos/googledrive.svg',
    brandColor: Color(0xFF4285F4),
    support: SourceSupport.connectable,
  ),
  SourceDescriptor(
    id: 'notion',
    name: 'Notion',
    tagline: 'Pages, databases and notes',
    logoAsset: 'assets/logos/notion.svg',
    brandColor: Color(0xFF191919),
    support: SourceSupport.connectable,
  ),
  SourceDescriptor(
    id: 'file_system',
    name: 'File System',
    tagline: 'Folders on this Mac',
    logoAsset: 'assets/logos/filesystem.svg',
    brandColor: Color(0xFF6B6560),
    support: SourceSupport.planned,
  ),
  SourceDescriptor(
    id: 'apple_notes',
    name: 'Apple Notes',
    tagline: 'Notes and folders',
    logoAsset: 'assets/logos/applenotes.svg',
    brandColor: Color(0xFFE8A33D),
    support: SourceSupport.planned,
  ),
  SourceDescriptor(
    id: 'google_keep',
    name: 'Google Keep',
    tagline: 'Quick notes and lists',
    logoAsset: 'assets/logos/googlekeep.svg',
    brandColor: Color(0xFFFFBB00),
    support: SourceSupport.planned,
  ),
  SourceDescriptor(
    id: 'obsidian',
    name: 'Obsidian',
    tagline: 'Local markdown vaults',
    logoAsset: 'assets/logos/obsidian.svg',
    brandColor: Color(0xFF7C3AED),
    support: SourceSupport.planned,
  ),
  SourceDescriptor(
    id: 'omnifocus',
    name: 'OmniFocus',
    tagline: 'Projects and next actions',
    logoAsset: 'assets/logos/omnifocus.svg',
    brandColor: Color(0xFF8E44AD),
    support: SourceSupport.planned,
  ),
  SourceDescriptor(
    id: 'todoist',
    name: 'Todoist',
    tagline: 'Tasks and projects',
    logoAsset: 'assets/logos/todoist.svg',
    brandColor: Color(0xFFE44332),
    support: SourceSupport.planned,
  ),
  SourceDescriptor(
    id: 'things',
    name: 'Things',
    tagline: 'Areas, projects and to-dos',
    logoAsset: 'assets/logos/things.svg',
    brandColor: Color(0xFF1F79E8),
    support: SourceSupport.planned,
  ),
  SourceDescriptor(
    id: 'roam',
    name: 'Roam',
    tagline: 'Networked daily notes',
    logoAsset: 'assets/logos/roamresearch.svg',
    brandColor: Color(0xFF343A40),
    support: SourceSupport.planned,
  ),
  SourceDescriptor(
    id: 'onedrive',
    name: 'OneDrive',
    tagline: 'Files and Office documents',
    logoAsset: 'assets/logos/microsoftonedrive.svg',
    brandColor: Color(0xFF0078D4),
    support: SourceSupport.planned,
  ),
  SourceDescriptor(
    id: 'dropbox',
    name: 'Dropbox',
    tagline: 'Shared files and folders',
    logoAsset: 'assets/logos/dropbox.svg',
    brandColor: Color(0xFF0061FF),
    support: SourceSupport.planned,
  ),
  SourceDescriptor(
    id: 'icloud_drive',
    name: 'iCloud Drive',
    tagline: 'Documents synced across devices',
    logoAsset: 'assets/logos/icloud.svg',
    brandColor: Color(0xFF3693F3),
    support: SourceSupport.planned,
  ),
];
