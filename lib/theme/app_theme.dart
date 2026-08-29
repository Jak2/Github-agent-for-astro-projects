// lib/theme/app_theme.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const Color bg = Colors.black;
  static const Color fg = Colors.white;
  static const Color muted = Color(0xFF888888);
  static const Color divider = Color(0xFF333333);
  static const Color surfaceMuted = Color(0xFF111111);
}

TextStyle appHeading({double size = 24, FontWeight weight = FontWeight.w800}) {
  return GoogleFonts.sora(fontSize: size, fontWeight: weight, color: AppColors.fg);
}

TextStyle appBody({double size = 13.5, Color? color, FontWeight weight = FontWeight.w400}) {
  return GoogleFonts.inter(fontSize: size, fontWeight: weight, color: color ?? AppColors.fg);
}

TextStyle appMono({double size = 13, Color? color, FontWeight weight = FontWeight.w400}) {
  return GoogleFonts.jetBrainsMono(fontSize: size, fontWeight: weight, color: color ?? AppColors.fg);
}

ThemeData appThemeData() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bg,
    fontFamily: GoogleFonts.inter().fontFamily,
    colorScheme: const ColorScheme.dark(
      surface: AppColors.bg,
      primary: AppColors.fg,
      onPrimary: AppColors.bg,
    ),
    dividerColor: AppColors.divider,
  );
}

Widget appBorderedField({
  required TextEditingController controller,
  required String hint,
  bool obscure = false,
  int maxLines = 1,
  TextInputType? keyboardType,
  bool enabled = true,
  ValueChanged<String>? onChanged,
}) {
  return TextField(
    controller: controller,
    obscureText: obscure,
    maxLines: maxLines,
    keyboardType: keyboardType,
    enabled: enabled,
    onChanged: onChanged,
    style: appMono(size: 13),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: appMono(size: 13, color: AppColors.muted),
      filled: true,
      fillColor: AppColors.bg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.fg, width: 2),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.fg, width: 2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.fg, width: 2),
      ),
    ),
  );
}

Widget appPrimaryButton({required String label, required VoidCallback? onPressed}) {
  return SizedBox(
    width: double.infinity,
    child: ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.fg,
        foregroundColor: AppColors.bg,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.fg, width: 2),
        ),
        elevation: 0,
      ),
      child: Text(label, style: GoogleFonts.sora(fontWeight: FontWeight.w700, fontSize: 15)),
    ),
  );
}

Widget appSecondaryButton({required String label, required VoidCallback? onPressed}) {
  return SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.fg,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.fg, width: 2),
        ),
      ),
      child: Text(label, style: appBody(size: 14, weight: FontWeight.w600)),
    ),
  );
}

/// A compact bordered chip for an action bar — sized to its own label, so it
/// is safe inside a `Row` (unlike appPrimaryButton/appSecondaryButton, which
/// are full-width `SizedBox`es and blow a Row's constraints unwrapped).
///
/// [emphasis] inverts it to filled white: reserved for the action that
/// publishes something outward, so it never looks like the read-only ones.
Widget appActionChip({
  required String label,
  required IconData icon,
  required VoidCallback? onPressed,
  bool emphasis = false,
}) {
  final enabled = onPressed != null;
  final fg = emphasis ? AppColors.bg : (enabled ? AppColors.fg : AppColors.muted);
  final bg = emphasis ? (enabled ? AppColors.fg : AppColors.muted) : AppColors.bg;
  final border = enabled ? AppColors.fg : AppColors.muted;

  return Material(
    color: bg,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              onPressed();
            }
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: border, width: 2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
            Text(label, style: appMono(size: 11.5, color: fg, weight: FontWeight.w600)),
          ],
        ),
      ),
    ),
  );
}

Widget appIconCircleButton({required IconData icon, required VoidCallback? onPressed, bool filled = false}) {
  return SizedBox(
    width: 40,
    height: 40,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: filled ? AppColors.fg : AppColors.bg,
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.fg, width: 2),
        ),
      ),
      child: Icon(icon, size: 18, color: filled ? AppColors.bg : AppColors.fg),
    ),
  );
}

// ---------------------------------------------------------------------------
// Popups.
//
// This app has no chat log to print into: every result, question and warning
// lands in one of these three. They share the framed black card so a git
// error and a delete confirmation read as the same app.
// ---------------------------------------------------------------------------

Widget _dialogFrame({required String title, required Widget content, required List<Widget> actions}) {
  return AlertDialog(
    backgroundColor: AppColors.bg,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: AppColors.fg, width: 2),
    ),
    title: Text(title, style: appHeading(size: 16)),
    content: content,
    actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    actions: actions,
  );
}

/// Two full-width buttons side by side. [appPrimaryButton] and
/// [appSecondaryButton] are full-width `SizedBox`es, so they must be wrapped
/// in `Expanded` inside a `Row` or they blow the frame's constraints.
Widget _dialogButtonRow({
  required String cancelLabel,
  required VoidCallback onCancel,
  required String confirmLabel,
  required VoidCallback onConfirm,
}) {
  return Row(
    children: [
      Expanded(child: appSecondaryButton(label: cancelLabel, onPressed: onCancel)),
      const SizedBox(width: 8),
      Expanded(child: appPrimaryButton(label: confirmLabel, onPressed: onConfirm)),
    ],
  );
}

/// Owns a [TextEditingController] for exactly as long as the dialog's element
/// is mounted.
///
/// Disposing the controller as soon as `showDialog`'s future completes is a
/// real crash, not a style point: the route keeps rebuilding its child through
/// the close animation, and the field then reads a controller that is already
/// gone ("A TextEditingController was used after being disposed", which
/// cascades into a framework assert and a red screen). So the route owns it,
/// and `State.dispose` runs when the route is actually finished.
class AppControllerScope extends StatefulWidget {
  final String initialText;
  final Widget Function(BuildContext context, TextEditingController controller) builder;

  const AppControllerScope({super.key, required this.initialText, required this.builder});

  @override
  State<AppControllerScope> createState() => _AppControllerScopeState();
}

class _AppControllerScopeState extends State<AppControllerScope> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

/// Read-only output — `git status`, a log, an access verdict, an error.
///
/// Monospace and scrollable: a 40-line status must not push the button off
/// the screen.
Future<void> showOutputPopup(
  BuildContext context, {
  required String title,
  required String body,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _dialogFrame(
      title: title,
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: SelectableText(body, style: appMono(size: 12)),
        ),
      ),
      actions: [
        Row(children: [
          Expanded(
            child: appPrimaryButton(label: 'Close', onPressed: () => Navigator.of(ctx).pop()),
          ),
        ]),
      ],
    ),
  );
}

/// A yes/no gate. Returns false on dismiss, never null, so callers cannot
/// treat "tapped outside" as consent.
Future<bool> showConfirmPopup(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  String? detail,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => _dialogFrame(
      title: title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (detail != null) ...[
            Text(detail, style: appMono(size: 12)),
            const SizedBox(height: 8),
          ],
          Text(message, style: appBody(size: 12.5, color: AppColors.muted)),
        ],
      ),
      actions: [
        _dialogButtonRow(
          cancelLabel: cancelLabel,
          onCancel: () => Navigator.of(ctx).pop(false),
          confirmLabel: confirmLabel,
          onConfirm: () => Navigator.of(ctx).pop(true),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// One text field in a popup. Returns null when cancelled, the trimmed text
/// otherwise; empty input is refused by the button rather than returned.
///
/// [validator] runs on every keystroke and its message is shown under the
/// field — used for repo-relative path rules. [obscure] masks the input, for
/// a credential someone may be typing in public.
Future<String?> showInputPopup(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
  String confirmLabel = 'Save',
  String? description,
  int maxLines = 1,
  bool obscure = false,
  String? Function(String value)? validator,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AppControllerScope(
      initialText: initial,
      builder: (ctx, controller) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final value = controller.text.trim();
          final problem = value.isEmpty ? null : validator?.call(value);
          final canConfirm = value.isNotEmpty && problem == null;
          return _dialogFrame(
            title: title,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (description != null) ...[
                  Text(description, style: appBody(size: 12.5, color: AppColors.muted)),
                  const SizedBox(height: 10),
                ],
                appBorderedField(
                  controller: controller,
                  hint: hint,
                  maxLines: maxLines,
                  obscure: obscure,
                  onChanged: (_) => setLocal(() {}),
                ),
                if (problem != null) ...[
                  const SizedBox(height: 8),
                  Text(problem, style: appMono(size: 11.5, color: AppColors.muted)),
                ],
              ],
            ),
            actions: [
              _dialogButtonRow(
                cancelLabel: 'Cancel',
                onCancel: () => Navigator.of(ctx).pop(),
                confirmLabel: confirmLabel,
                onConfirm: canConfirm ? () => Navigator.of(ctx).pop(value) : () {},
              ),
            ],
          );
        },
      ),
    ),
  );
}
