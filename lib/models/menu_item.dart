import 'package:flutter/material.dart';

enum PreviewType {
  none,
  icon,
  artwork,
  nowPlaying,
  info,
}

class PodMenuItem {
  final String id;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool hasSubmenu;
  final PreviewType previewType;
  final String? previewAsset;
  final IconData? previewIcon;
  /// Optional MediaStore / library album id for right-pane artwork.
  final int? previewAlbumId;
  final VoidCallback? onSelect;
  final List<PodMenuItem> Function()? subMenuItems;
  /// When opening this item's submenu, use split (menu + preview) layout.
  final bool subMenuSplitView;
  /// When opening this item's submenu, stack title + subtitle as two-line rows.
  final bool subMenuTwoLineRows;

  const PodMenuItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.icon,
    this.hasSubmenu = true,
    this.previewType = PreviewType.none,
    this.previewAsset,
    this.previewIcon,
    this.previewAlbumId,
    this.onSelect,
    this.subMenuItems,
    this.subMenuSplitView = false,
    this.subMenuTwoLineRows = false,
  });
}

class PodMenuScreen {
  final String id;
  final String title;
  final List<PodMenuItem> items;
  final bool isSplitView;
  /// Full-width list with title on line 1 and gray subtitle on line 2 (Songs).
  final bool useTwoLineRows;

  const PodMenuScreen({
    required this.id,
    required this.title,
    required this.items,
    this.isSplitView = true,
    this.useTwoLineRows = false,
  });
}