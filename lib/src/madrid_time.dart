import 'package:timezone/timezone.dart' as tz;

final tz.Location _madrid = tz.getLocation('Europe/Madrid');

tz.TZDateTime madridNow() => tz.TZDateTime.now(_madrid);

tz.TZDateTime inMadrid(DateTime value) =>
    tz.TZDateTime.from(value.toUtc(), _madrid);

tz.TZDateTime madridDateTime(
  DateTime date, {
  required int hour,
  required int minute,
}) => tz.TZDateTime(_madrid, date.year, date.month, date.day, hour, minute);
