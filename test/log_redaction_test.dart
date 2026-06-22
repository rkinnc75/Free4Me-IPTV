// fix415: the issue-reporter transmits the log file, so the source HOST,
// username, and password must all be stripped before a log leaves the device.
// Verifies setSourceSecrets/scrubSecrets replaces all three with labelled
// tokens, and that the "Log User/Pass" setting defaults to false.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';

void main() {
  test('host, username and password are all redacted from a log line', () {
    AppLog.setSourceSecrets([
      Source(
        name: 'A 3000',
        url: 'http://stream.example.com:8080/get.php',
        username: 'joe',
        password: 'secret123',
        sourceType: SourceType.xtream,
      ),
    ]);

    const line =
        'MpvEngine: open url=http://stream.example.com:8080/live/joe/secret123/1.ts';
    final red = AppLog.scrubSecrets(line);

    // tokens present
    expect(red, contains('<A3000_HOST>'));
    expect(red, contains('<A3000_USER>'));
    expect(red, contains('<A3000_PASS>'));
    // raw values gone
    expect(red.contains('stream.example.com'), isFalse);
    expect(red.contains('joe'), isFalse);
    expect(red.contains('secret123'), isFalse);
  });

  test('host from urlOrigin is also redacted', () {
    AppLog.setSourceSecrets([
      Source(
        name: 'Trex',
        urlOrigin: 'http://my-portal.net:2095',
        username: 'u',
        password: 'p',
        sourceType: SourceType.xtream,
      ),
    ]);
    final red = AppLog.scrubSecrets('connect http://my-portal.net:2095/player_api.php');
    expect(red, contains('<Trex_HOST>'));
    expect(red.contains('my-portal.net'), isFalse);
  });

  test('overlapping hosts redact longest-first (no partial leak)', () {
    AppLog.setSourceSecrets([
      Source(name: 'A', url: 'http://example.com', sourceType: SourceType.xtream),
      Source(name: 'B', url: 'http://tv.example.com', sourceType: SourceType.xtream),
    ]);
    final red = AppLog.scrubSecrets('a=http://tv.example.com b=http://example.com');
    expect(red.contains('tv.example.com'), isFalse);
    expect(red.contains('example.com'), isFalse);
    expect(red, contains('<B_HOST>'));
    expect(red, contains('<A_HOST>'));
  });

  test('logUserPass setting defaults to false', () {
    expect(Settings().logUserPass, isFalse);
  });
}
