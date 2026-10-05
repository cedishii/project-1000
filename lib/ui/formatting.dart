import 'package:intl/intl.dart';

import '../data/models.dart';

final _long = DateFormat.yMMMMd();
final _short = DateFormat.yMMMd();

String longDate(CalendarDate d) => _long.format(d.toDateTime());
String shortDate(CalendarDate d) => _short.format(d.toDateTime());

/// 2.7%, 0%, 100% — one decimal only when it adds information.
String percent(int done, int total) {
  if (total == 0 || done == 0) return '0%';
  final p = done * 100 / total;
  if (p >= 100) return '100%';
  final s = p.toStringAsFixed(1);
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}%';
}

final _count = NumberFormat.decimalPattern();
String count(int n) => _count.format(n);

String plural(int n, String one, [String? many]) =>
    '${count(n)} ${n == 1 ? one : (many ?? '${one}s')}';

final _dateTime = DateFormat.yMMMMd().add_jm();
String longDateTime(DateTime d) => _dateTime.format(d);
