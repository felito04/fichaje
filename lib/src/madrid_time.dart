import 'package:timezone/timezone.dart' as tz;

final tz.Location _madrid = tz.getLocation('Europe/Madrid');

tz.TZDateTime madridNow() => tz.TZDateTime.now(_madrid);

tz.TZDateTime inMadrid(DateTime value) =>
    tz.TZDateTime.from(value.toUtc(), _madrid);
