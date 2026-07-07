// fix386: tests for the EPG auto-discovery package.
//
// Coverage:
//   - EpgValidator (the response validator) — pure functions
//   - XtreamM3uTvgUrl._extractTvgUrl — pure regex helper
//   - EpgDiscoveryResult.shortLabel — pure formatter
//
// The HTTP-based variant probes (StalkerXmltvQueryAuth, etc.) each
// construct their own `http.Client` internally and don't accept a
// client parameter. Mocking them would require either refactoring
// the production code to take a client (cleaner, but more
// change-for-test) or using `HttpOverrides` to patch the IO layer
// (fragile across `http` package versions; the IOClient's
// `createDefaultContext` is hard to intercept reliably). The variant
// network behavior is therefore on-device verification, not
// sandbox-provable. The pure-function tests below cover the
// components that ARE testable in a unit context.

import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:open_tv/backend/epg_discovery/epg_discovery_result.dart';
import 'package:open_tv/backend/epg_discovery/epg_validator.dart';
import 'package:open_tv/backend/epg_discovery/variants/xtream_m3u_tvg_url.dart';

void main() {
  group('EpgValidator', () {
    test('rejects non-200', () {
      final resp = http.Response.bytes(
        utf8.encode('<?xml version="1.0"?><tv><programme /></tv>'),
        404,
        headers: const {'content-type': 'application/xml'},
      );
      expect(EpgValidator.isValidEpgResponse(resp, resp.bodyBytes), isFalse);
    });

    test('finding 167: rejects gzip magic wrapping non-XMLTV content', () {
      // A real gzip stream whose inflated body is NOT XMLTV (e.g. a gzipped
      // HTML error page). Pre-fix this passed on magic bytes alone; now the
      // validator inflates and runs the structural checks, so it is rejected
      // and the variant walk continues.
      final notXmltv = gzip.encode(utf8.encode('<html>Forbidden</html>'));
      final resp = http.Response.bytes(notXmltv, 200, headers: const {
        'content-type': 'application/gzip',
      });
      expect(EpgValidator.isValidEpgResponse(resp, notXmltv), isFalse);
    });

    test('finding 167: accepts gzip wrapping a real XMLTV document', () {
      final head = '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<tv>\n'
          '  <programme start="..." channel="c1">\n'
          '    <title>X</title>\n'
          '  </programme>\n'
          '</tv>\n';
      final bytes = gzip.encode(utf8.encode(head));
      final resp = http.Response.bytes(bytes, 200, headers: const {
        'content-type': 'application/gzip',
      });
      expect(EpgValidator.isValidEpgResponse(resp, bytes), isTrue);
    });

    test('finding 167: rejects a fake gzip header (bad stream)', () {
      // Magic bytes but not a valid gzip stream — inflation throws → rejected.
      final bytes = [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00];
      final resp = http.Response.bytes(bytes, 200, headers: const {
        'content-type': 'application/gzip',
      });
      expect(EpgValidator.isValidEpgResponse(resp, bytes), isFalse);
    });

    test('accepts a real XMLTV head with programmes', () {
      final head = '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<tv>\n'
          '  <programme start="..." channel="c1">\n'
          '    <title>X</title>\n'
          '  </programme>\n'
          '</tv>\n';
      final bytes = utf8.encode(head);
      final resp = http.Response.bytes(bytes, 200, headers: const {
        'content-type': 'application/xml',
      });
      expect(EpgValidator.isValidEpgResponse(resp, bytes), isTrue);
    });

    test('rejects empty <tv/> (portal authed but no data)', () {
      final head = '<?xml version="1.0" encoding="UTF-8"?>\n<tv/>\n';
      final bytes = utf8.encode(head);
      final resp = http.Response.bytes(bytes, 200, headers: const {
        'content-type': 'application/xml',
      });
      expect(EpgValidator.isValidEpgResponse(resp, bytes), isFalse);
    });

    test('rejects non-XML content (octet-stream with no XML)', () {
      final bytes = utf8.encode('this is plain text, not XML');
      final resp = http.Response.bytes(bytes, 200, headers: const {
        'content-type': 'application/octet-stream',
      });
      expect(EpgValidator.isValidEpgResponse(resp, bytes), isFalse);
    });

    test('rejects XML without <tv> root', () {
      final head = '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<something>\n'
          '  <programme start="..." channel="c1">\n'
          '    <title>X</title>\n'
          '  </programme>\n'
          '</something>\n';
      final bytes = utf8.encode(head);
      final resp = http.Response.bytes(bytes, 200, headers: const {
        'content-type': 'application/xml',
      });
      expect(EpgValidator.isValidEpgResponse(resp, bytes), isFalse);
    });

    test('countProgrammes counts both <programme > and <programme>', () {
      // <programme a="1"/>  → matches "<programme " (1)
      // <programme></programme>  → matches "<programme>" (1)
      //                          → closing tag </programme> doesn't match
      const head = '<programme a="1"/><programme></programme>';
      expect(EpgValidator.countProgrammes(head), 2);
    });

    test('isXmltvGzip detects 0x1F 0x8B magic', () {
      expect(EpgValidator.isXmltvGzip([0x1F, 0x8B, 0x00]), isTrue);
      expect(EpgValidator.isXmltvGzip([0x1F, 0x88, 0x00]), isFalse);
      expect(EpgValidator.isXmltvGzip([0x1F]), isFalse);
    });
  });

  group('XtreamM3uTvgUrl.extractTvgUrlForTest', () {
    test('extracts url-tvg (Xtream standard)', () {
      const m3u = '#EXTM3U url-tvg="http://example.com/epg.xml"\n'
          '#EXTINF:-1 tvg-id="c1",Channel 1\n'
          'http://example.com/c1';
      final url = XtreamM3uTvgUrl.extractTvgUrlForTest(m3u);
      expect(url, 'http://example.com/epg.xml');
    });

    test('extracts tvg-url (fork variant)', () {
      const m3u = '#EXTM3U tvg-url="http://example.com/epg.xml"\n'
          '#EXTINF:-1,Channel 1\n'
          'http://example.com/c1';
      final url = XtreamM3uTvgUrl.extractTvgUrlForTest(m3u);
      expect(url, 'http://example.com/epg.xml');
    });

    test('returns the first comma-separated entry', () {
      const m3u =
          '#EXTM3U url-tvg="http://a.com/epg1.xml,http://b.com/epg2.xml"';
      final url = XtreamM3uTvgUrl.extractTvgUrlForTest(m3u);
      expect(url, 'http://a.com/epg1.xml');
    });

    test('returns null when neither attribute is present', () {
      const m3u = '#EXTM3U\n#EXTINF:-1,Channel 1\nhttp://example.com/c1';
      final url = XtreamM3uTvgUrl.extractTvgUrlForTest(m3u);
      expect(url, isNull);
    });

    test('returns null for an empty url-tvg=""', () {
      const m3u = '#EXTM3U url-tvg=""';
      final url = XtreamM3uTvgUrl.extractTvgUrlForTest(m3u);
      expect(url, isNull);
    });
  });

  group('EpgDiscoveryResult.shortLabel', () {
    test('query variant → "auto · query"', () {
      final r = EpgDiscoveryResult(
        variant: 'stalker-xmltv-query',
        url: 'http://x',
        probedAt: DateTime.now(),
        elapsedMs: 100,
      );
      expect(r.shortLabel(), 'auto · query');
    });

    test('cookie variant → "auto · cookie"', () {
      final r = EpgDiscoveryResult(
        variant: 'stalker-xmltv-cookie',
        url: 'http://x',
        probedAt: DateTime.now(),
        elapsedMs: 100,
      );
      expect(r.shortLabel(), 'auto · cookie');
    });

    test('m3u tvg variant → "auto · tvg"', () {
      final r = EpgDiscoveryResult(
        variant: 'xtream-m3u-tvg-url',
        url: 'http://x',
        probedAt: DateTime.now(),
        elapsedMs: 100,
      );
      expect(r.shortLabel(), 'auto · tvg');
    });

    test('unknown variant → "auto"', () {
      final r = EpgDiscoveryResult(
        variant: 'something-else',
        url: 'http://x',
        probedAt: DateTime.now(),
        elapsedMs: 100,
      );
      expect(r.shortLabel(), 'auto');
    });
  });
}
