// finding 124: tests for StalkerXmltvCookieAuth.probe re-validation gate.
//
// Variant 2 handshakes (cookie auth) then fetches xmltv.php?type=itv with a
// bearer cookie. The refresh pipeline later fetches the persisted URL WITHOUT
// any auth header, and the handshake token is ephemeral, so a URL that only
// serves XMLTV behind the cookie handshake would 401 on every future refresh.
// The fix re-fetches the same URL with NO Cookie/Bearer header before
// persisting and returns null if that unauthenticated fetch is rejected.
//
// These tests inject a MockClient via the new optional `client` param on
// probe(). The mock branches on the presence of the 'Cookie' request header:
//   - handshake  -> 200 JSON {"js":{"token":"t"}}
//   - authed xmltv (Cookie present) -> valid XMLTV
//   - unauth xmltv (Cookie absent)  -> per-case (401 or valid XMLTV)

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_tv/backend/epg_discovery/variants/stalker_xmltv_cookie_auth.dart';

const _validXmltv =
    '<?xml version="1.0"?><tv><programme start="20260101000000">'
    '<title>Show</title></programme></tv>';

void main() {
  group('StalkerXmltvCookieAuth.probe re-validation gate (finding 124)', () {
    test(
        'Case A: XMLTV only served with cookie auth — unauthenticated fetch '
        'rejected — probe returns null (not persisted)', () async {
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (path.contains('load.php')) {
          return http.Response('{"js":{"token":"t"}}', 200,
              headers: {'content-type': 'application/json'});
        }
        // xmltv.php: valid only when the cookie header is present.
        if (path.contains('xmltv.php')) {
          if (request.headers.containsKey('Cookie')) {
            return http.Response(_validXmltv, 200,
                headers: {'content-type': 'application/xml'});
          }
          // Unauthenticated refresh-style fetch: portal 401s.
          return http.Response('unauthorized', 401);
        }
        return http.Response('not found', 404);
      });

      final result = await StalkerXmltvCookieAuth.probe(
        'http://portal.example',
        'user',
        'pass',
        client: mock,
      );

      expect(result, isNull);
    });

    test(
        'Case B: XMLTV served both with and without auth — probe persists the '
        'itv URL', () async {
      final mock = MockClient((request) async {
        final path = request.url.path;
        if (path.contains('load.php')) {
          return http.Response('{"js":{"token":"t"}}', 200,
              headers: {'content-type': 'application/json'});
        }
        if (path.contains('xmltv.php')) {
          // Valid XMLTV regardless of whether Cookie is present.
          return http.Response(_validXmltv, 200,
              headers: {'content-type': 'application/xml'});
        }
        return http.Response('not found', 404);
      });

      final result = await StalkerXmltvCookieAuth.probe(
        'http://portal.example',
        'user',
        'pass',
        client: mock,
      );

      expect(result, isNotNull);
      expect(result!.variant, 'stalker-xmltv-cookie');
      expect(result.url, 'http://portal.example/xmltv.php?type=itv');
    });
  });
}
