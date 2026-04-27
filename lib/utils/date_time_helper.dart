import 'package:block_flutter/block_flutter.dart';

class DateTimeHelper {
  static String formatDisplay(DateTime dateTime) {
    final local = dateTime.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  static String formatStorage(DateTime dateTime) {
    return iso8601WithOffset(dateTime.toLocal());
  }
}
