import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_notifier.dart';
import '../../core/models/http_transaction.dart';
import '../../core/models/traffic_state.dart';
import '../../widgets/platform_context_menu.dart';

/// Filter bar for traffic filtering
class FilterBar extends StatefulWidget {
  final FocusNode? focusNode;

  const FilterBar({super.key, this.focusNode});

  @override
  State<FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<FilterBar> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();
    final isDark = themeNotifier.isDarkMode;
    final isMacOS = Platform.isMacOS;
    final shortcutHint = isMacOS ? '⌘K' : 'Ctrl+K';

    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final background = isDark
        ? AppColors.background
        : AppColorsLight.background;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;
    final textPrimary = isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;

    return Consumer<TrafficState>(
      builder: (context, state, _) {
        final dividerColor = borderColor.withValues(
          alpha: isDark ? 0.35 : 0.55,
        );
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: surface,
            border: Border(bottom: BorderSide(color: dividerColor)),
          ),
          child: Row(
            children: [
              // Search field
              Expanded(
                child: Container(
                  height: 32,
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: borderColor.withValues(alpha: isDark ? 0.4 : 0.6),
                    ),
                  ),
                  child: Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.search, size: 16, color: textMuted),
                      ),
                      Expanded(
                        child: TextField(
                          focusNode: widget.focusNode,
                          controller: _searchController,
                          style: TextStyle(color: textPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'Filter requests... ($shortcutHint)',
                            hintStyle: TextStyle(
                              color: textMuted,
                              fontSize: 13,
                            ),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 8,
                            ),
                            isDense: true,
                          ),
                          onChanged: (value) {
                            state.setFilter(
                              state.filter.copyWith(searchText: value),
                            );
                          },
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear, size: 14),
                          color: textMuted,
                          onPressed: () {
                            _searchController.clear();
                            state.setFilter(
                              state.filter.copyWith(searchText: ''),
                            );
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 24,
                            minHeight: 24,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Method filter dropdown
              _FilterDropdown(
                label: 'Method',
                isActive: state.filter.methods.isNotEmpty,
                isDark: isDark,
                child: _MethodFilterPopup(
                  selectedMethods: state.filter.methods,
                  onChanged: (methods) {
                    state.setFilter(state.filter.copyWith(methods: methods));
                  },
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 8),

              // Status filter dropdown
              _FilterDropdown(
                label: 'Status',
                isActive: state.filter.statusCategories.isNotEmpty,
                isDark: isDark,
                child: _StatusFilterPopup(
                  selectedCategories: state.filter.statusCategories,
                  onChanged: (categories) {
                    state.setFilter(
                      state.filter.copyWith(statusCategories: categories),
                    );
                  },
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 8),

              // Type filter dropdown
              _FilterDropdown(
                label: 'Type',
                isActive: state.filter.resourceTypes.isNotEmpty,
                isDark: isDark,
                child: _TypeFilterPopup(
                  selectedTypes: state.filter.resourceTypes,
                  onChanged: (types) {
                    state.setFilter(
                      state.filter.copyWith(resourceTypes: types),
                    );
                  },
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 8),

              // Host filter dropdown
              _FilterDropdown(
                label: 'Host',
                isActive:
                    state.filter.host != null && state.filter.host!.isNotEmpty,
                isDark: isDark,
                child: _HostFilterPopup(
                  currentHost: state.filter.host,
                  onChanged: (host) {
                    state.setFilter(state.filter.copyWith(host: host));
                  },
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 12),

              // Clear filters button
              if (!state.filter.isEmpty)
                TextButton.icon(
                  icon: const Icon(Icons.clear_all, size: 16),
                  label: const Text('Clear'),
                  style: TextButton.styleFrom(
                    foregroundColor: textSecondary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                  ),
                  onPressed: () {
                    _searchController.clear();
                    state.setFilter(const TransactionFilter());
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Generic filter dropdown button
class _FilterDropdown extends StatelessWidget {
  final String label;
  final bool isActive;
  final bool isDark;
  final Widget child;

  const _FilterDropdown({
    required this.label,
    required this.isActive,
    required this.isDark,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final background = isDark
        ? AppColors.background
        : AppColorsLight.background;
    final surface = isDark ? AppColors.surface : AppColorsLight.surface;
    final borderColor = isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final textSecondary = isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textMuted = isDark ? AppColors.textMuted : AppColorsLight.textMuted;

    final button = Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: isActive
            ? AppColors.primary.withValues(alpha: 0.15)
            : background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: isActive ? AppColors.primary : borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isActive ? AppColors.primary : textSecondary,
              fontSize: 13,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.arrow_drop_down,
            size: 18,
            color: isActive ? AppColors.primary : textMuted,
          ),
        ],
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          final renderBox = context.findRenderObject() as RenderBox?;
          if (renderBox == null) return;
          final origin = renderBox.localToGlobal(Offset.zero);
          final anchor = Offset(
            origin.dx,
            origin.dy + renderBox.size.height + 6,
          );
          showPlatformMenuPanel(
            context: context,
            position: anchor,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220),
              child: child,
            ),
            backgroundColor: surface,
            borderColor: borderColor,
          );
        },
        child: button,
      ),
    );
  }
}

/// Method filter popup content
class _MethodFilterPopup extends StatefulWidget {
  final Set<String> selectedMethods;
  final ValueChanged<Set<String>> onChanged;
  final bool isDark;

  const _MethodFilterPopup({
    required this.selectedMethods,
    required this.onChanged,
    required this.isDark,
  });

  @override
  State<_MethodFilterPopup> createState() => _MethodFilterPopupState();
}

class _MethodFilterPopupState extends State<_MethodFilterPopup> {
  late Set<String> _localSelected;

  static const methods = [
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'OPTIONS',
    'HEAD',
  ];

  @override
  void initState() {
    super.initState();
    _localSelected = Set<String>.from(widget.selectedMethods);
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = widget.isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final hoverColor = AppColors.primary.withValues(
      alpha: widget.isDark ? 0.15 : 0.08,
    );
    final selectedHoverColor = AppColors.primary.withValues(
      alpha: widget.isDark ? 0.28 : 0.18,
    );

    return SizedBox(
      width: 180,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: methods.map((method) {
          final isSelected = _localSelected.contains(method);
          final rowHover = isSelected ? selectedHoverColor : hoverColor;
          return InkWell(
            onTap: () {
              setState(() {
                if (isSelected) {
                  _localSelected.remove(method);
                } else {
                  _localSelected.add(method);
                }
              });
              widget.onChanged(Set<String>.from(_localSelected));
            },
            borderRadius: BorderRadius.circular(6),
            hoverColor: rowHover,
            focusColor: rowHover,
            highlightColor: rowHover.withValues(alpha: 0.9),
            splashColor: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isSelected ? AppColors.primary : borderColor,
                        width: isSelected ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(3),
                      color: isSelected
                          ? AppColors.primary
                          : Colors.transparent,
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, size: 12, color: Colors.white)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    method,
                    style: TextStyle(
                      color: AppColors.getMethodColor(method),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Status filter popup content
class _StatusFilterPopup extends StatefulWidget {
  final Set<int> selectedCategories;
  final ValueChanged<Set<int>> onChanged;
  final bool isDark;

  const _StatusFilterPopup({
    required this.selectedCategories,
    required this.onChanged,
    required this.isDark,
  });

  @override
  State<_StatusFilterPopup> createState() => _StatusFilterPopupState();
}

class _StatusFilterPopupState extends State<_StatusFilterPopup> {
  late Set<int> _localSelected;

  static const categories = [
    (2, '2xx Success', AppColors.success),
    (3, '3xx Redirect', AppColors.redirect),
    (4, '4xx Client Error', AppColors.clientError),
    (5, '5xx Server Error', AppColors.serverError),
  ];

  @override
  void initState() {
    super.initState();
    _localSelected = Set<int>.from(widget.selectedCategories);
  }

  @override
  Widget build(BuildContext context) {
    final textPrimary = widget.isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final borderColor = widget.isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final hoverColor = AppColors.primary.withValues(
      alpha: widget.isDark ? 0.15 : 0.08,
    );
    final selectedHoverColor = AppColors.primary.withValues(
      alpha: widget.isDark ? 0.28 : 0.18,
    );

    return SizedBox(
      width: 200,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: categories.map((cat) {
          final isSelected = _localSelected.contains(cat.$1);
          final rowHover = isSelected ? selectedHoverColor : hoverColor;
          return InkWell(
            onTap: () {
              setState(() {
                if (isSelected) {
                  _localSelected.remove(cat.$1);
                } else {
                  _localSelected.add(cat.$1);
                }
              });
              widget.onChanged(Set<int>.from(_localSelected));
            },
            borderRadius: BorderRadius.circular(6),
            hoverColor: rowHover,
            focusColor: rowHover,
            highlightColor: rowHover.withValues(alpha: 0.9),
            splashColor: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isSelected ? AppColors.primary : borderColor,
                        width: isSelected ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(3),
                      color: isSelected
                          ? AppColors.primary
                          : Colors.transparent,
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, size: 12, color: Colors.white)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: cat.$3,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    cat.$2,
                    style: TextStyle(color: textPrimary, fontSize: 13),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Host filter popup content
class _HostFilterPopup extends StatefulWidget {
  final String? currentHost;
  final ValueChanged<String> onChanged;
  final bool isDark;

  const _HostFilterPopup({
    required this.currentHost,
    required this.onChanged,
    required this.isDark,
  });

  @override
  State<_HostFilterPopup> createState() => _HostFilterPopupState();
}

class _HostFilterPopupState extends State<_HostFilterPopup> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentHost);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final background = widget.isDark
        ? AppColors.background
        : AppColorsLight.background;
    final borderColor = widget.isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final textPrimary = widget.isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final textSecondary = widget.isDark
        ? AppColors.textSecondary
        : AppColorsLight.textSecondary;
    final textMuted = widget.isDark
        ? AppColors.textMuted
        : AppColorsLight.textMuted;

    return SizedBox(
      width: 220,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Filter by host',
              style: TextStyle(color: textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              style: TextStyle(color: textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'e.g., api.github.com',
                hintStyle: TextStyle(color: textMuted, fontSize: 13),
                filled: true,
                fillColor: background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: borderColor),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                isDense: true,
              ),
              onSubmitted: (value) {
                widget.onChanged(value);
                Navigator.of(context).pop();
              },
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    _controller.clear();
                    widget.onChanged('');
                    Navigator.of(context).pop();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: textSecondary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                  ),
                  child: const Text('Clear'),
                ),
                const SizedBox(width: 4),
                ElevatedButton(
                  onPressed: () {
                    widget.onChanged(_controller.text);
                    Navigator.of(context).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                  ),
                  child: const Text('Apply'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Type filter popup content
class _TypeFilterPopup extends StatefulWidget {
  final Set<ResourceType> selectedTypes;
  final ValueChanged<Set<ResourceType>> onChanged;
  final bool isDark;

  const _TypeFilterPopup({
    required this.selectedTypes,
    required this.onChanged,
    required this.isDark,
  });

  @override
  State<_TypeFilterPopup> createState() => _TypeFilterPopupState();
}

class _TypeFilterPopupState extends State<_TypeFilterPopup> {
  late Set<ResourceType> _localSelected;

  static const types = [
    (ResourceType.json, 'JSON', Icons.data_object),
    (ResourceType.xml, 'XML', Icons.code),
    (ResourceType.html, 'HTML', Icons.html),
    (ResourceType.js, 'JS', Icons.javascript),
    (ResourceType.css, 'CSS', Icons.style),
    (ResourceType.image, 'Image', Icons.image),
    (ResourceType.media, 'Media', Icons.movie),
    (ResourceType.font, 'Font', Icons.font_download),
    (ResourceType.websocket, 'WebSocket', Icons.sync_alt),
    (ResourceType.other, 'Other', Icons.help_outline),
  ];

  @override
  void initState() {
    super.initState();
    _localSelected = Set<ResourceType>.from(widget.selectedTypes);
  }

  @override
  Widget build(BuildContext context) {
    final textPrimary = widget.isDark
        ? AppColors.textPrimary
        : AppColorsLight.textPrimary;
    final borderColor = widget.isDark
        ? AppColors.surfaceBorder
        : AppColorsLight.surfaceBorder;
    final hoverColor = AppColors.primary.withValues(
      alpha: widget.isDark ? 0.15 : 0.08,
    );
    final selectedHoverColor = AppColors.primary.withValues(
      alpha: widget.isDark ? 0.28 : 0.18,
    );

    return SizedBox(
      width: 180,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: types.map((type) {
          final isSelected = _localSelected.contains(type.$1);
          final rowHover = isSelected ? selectedHoverColor : hoverColor;
          return InkWell(
            onTap: () {
              setState(() {
                if (isSelected) {
                  _localSelected.remove(type.$1);
                } else {
                  _localSelected.add(type.$1);
                }
              });
              widget.onChanged(Set<ResourceType>.from(_localSelected));
            },
            borderRadius: BorderRadius.circular(6),
            hoverColor: rowHover,
            focusColor: rowHover,
            highlightColor: rowHover.withValues(alpha: 0.9),
            splashColor: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isSelected ? AppColors.primary : borderColor,
                        width: isSelected ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(3),
                      color: isSelected
                          ? AppColors.primary
                          : Colors.transparent,
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, size: 12, color: Colors.white)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    type.$3,
                    size: 14,
                    color: isSelected ? AppColors.primary : borderColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    type.$2,
                    style: TextStyle(color: textPrimary, fontSize: 13),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
