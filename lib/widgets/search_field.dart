import 'package:flutter/material.dart';

import '../theme.dart';

/// The rounded search input used at the top of a section.
class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.hintText,
    required this.onChanged,
    this.controller,
  });

  final String hintText;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(
      () => setState(() => _focused = _focusNode.hasFocus),
    );
  }

  @override
  void dispose() {
    _focusNode.dispose();
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    widget.onChanged('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _controller.text.isNotEmpty;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: _focused ? KandooColors.accent : KandooColors.divider,
          width: _focused ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.search,
            size: 17,
            color: _focused ? KandooColors.accent : KandooColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              onChanged: (value) {
                widget.onChanged(value);
                setState(() {});
              },
              cursorColor: KandooColors.accent,
              style: const TextStyle(
                fontSize: 13.5,
                color: KandooColors.textPrimary,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: widget.hintText,
                hintStyle: const TextStyle(
                  fontSize: 13.5,
                  color: KandooColors.textMuted,
                ),
              ),
            ),
          ),
          if (hasText)
            _ClearButton(onTap: _clear)
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}

class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: const Icon(
          Icons.close,
          size: 15,
          color: KandooColors.textMuted,
        ),
      ),
    );
  }
}
