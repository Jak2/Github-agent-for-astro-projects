// lib/theme/app_theme.dart
import 'package:flutter/material.dart';
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
}) {
  return TextField(
    controller: controller,
    obscureText: obscure,
    maxLines: maxLines,
    keyboardType: keyboardType,
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

Widget appChatBubble({required String text, required bool fromUser, bool mono = false}) {
  final style = fromUser
      ? appBody(size: 13.5, color: AppColors.bg)
      : (mono ? appMono(size: 12, color: AppColors.fg) : appBody(size: 13.5, color: AppColors.fg));
  return Align(
    alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 320),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: fromUser ? AppColors.fg : AppColors.bg,
        border: Border.all(color: AppColors.fg, width: 2),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: Radius.circular(fromUser ? 14 : 3),
          bottomRight: Radius.circular(fromUser ? 3 : 14),
        ),
      ),
      child: Text(text, style: style),
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
