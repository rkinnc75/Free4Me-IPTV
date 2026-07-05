// Findings 45 / 40 / 82 (credential-redaction cluster): AppLogger.setSourceSecrets
// must mask credentials that appear in logged URLs in forms other than the raw
// username/password field values —
//   45: percent-encoded (encodeComponent / encodeQueryComponent) forms,
//   82: query-string creds on an m3uUrl source (s.username/password are null),
//   40: query-string creds AND an opaque path token in an EPG URL.
// All three route through the single _redactSecrets table, so one edit to
// setSourceSecrets covers every log-call site.

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';

Source _src({
  required String name,
  SourceType type = SourceType.xtream,
  String? url,
  String? username,
  String? password,
  String? epgUrl,
}) =>
    Source(
      name: name,
      sourceType: type,
      url: url,
      username: username,
      password: password,
      epgUrl: epgUrl,
    );

void main() {
  final logger = AppLogger.instance;

  test('finding 45: percent-encoded creds in a logged URL are redacted', () {
    final s = _src(
        name: 'S', username: 'my user', password: 'p@ss+word', url: 'http://h/');
    logger.setSourceSecrets([s]);
    final line =
        'XMLTV: GET http://h/xmltv.php?username=${Uri.encodeComponent("my user")}'
        '&password=${Uri.encodeComponent("p@ss+word")}';
    final out = logger.scrubSecrets(line);
    expect(out, contains('<S_USER>'));
    expect(out, contains('<S_PASS>'));
    expect(out, isNot(contains('my%20user')));
    expect(out, isNot(contains('p%40ss%2Bword')));
  });

  test('finding 82: m3uUrl query-string creds (null user/pass fields) redacted',
      () {
    final s = _src(
        name: 'M',
        type: SourceType.m3uUrl,
        url: 'http://h/get.php?username=SECRETU&password=SECRETP');
    logger.setSourceSecrets([s]);
    final out = logger.scrubSecrets(
        'url="http://h/get.php?username=SECRETU&password=SECRETP"');
    expect(out, isNot(contains('SECRETU')));
    expect(out, isNot(contains('SECRETP')));
    expect(out, contains('_CRED>'));
  });

  test('finding 40: EPG URL query creds and opaque path token redacted', () {
    final s = _src(
        name: 'E',
        url: 'http://h/',
        epgUrl:
            'http://epg.host/epg/ABCDEF123456.xml.gz?username=joe&password=s3cret');
    logger.setSourceSecrets([s]);
    final out = logger.scrubSecrets(
        'EPG: downloading "E" — http://epg.host/epg/ABCDEF123456.xml.gz'
        '?username=joe&password=s3cret');
    expect(out, isNot(contains('s3cret')));
    expect(out, isNot(contains('ABCDEF123456')));
    // 'joe' is 3 chars so it is registered; ensure it is masked too.
    expect(out, isNot(contains('=joe')));
  });

  test('short query values (<3 chars) are not registered as creds', () {
    final s = _src(
        name: 'Z', type: SourceType.m3uUrl, url: 'http://host/x?user=ab');
    logger.setSourceSecrets([s]);
    // 'ab' must NOT become a redaction literal (would mangle every "ab").
    final out = logger.scrubSecrets('crab tables and abacus');
    expect(out, equals('crab tables and abacus'));
  });
}
