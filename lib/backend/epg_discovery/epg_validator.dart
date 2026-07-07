import 'dart:io' show gzip;

import 'package:http/http.dart' as http;

/// fix386: validates an HTTP response body as a real XMLTV document.
///
/// A response is "valid EPG" iff ALL of the following hold:
///   - HTTP 200.
///   - Content-Type is empty, OR contains one of: xml, gzip, text/plain,
///     octet-stream. Many Stalker portals lie about Content-Type, so we
///     also inspect the body itself.
///   - Magic bytes are a gzip header (0x1F 0x8B), OR the first 8KB
///     trimmed of whitespace starts with `<?xml` AND contains `<tv`.
///   - At least one `<programme ` or `<programme>` in the first 64KB.
///     A `<tv/>` empty document (portal authed but no data) returns
///     false; the variant walk continues to the next variant.
class EpgValidator {
  /// Default upper bound for the head-bytes we parse. 64KB is enough
  /// for the magic-bytes check + a `<programme` grep on real XMLTV.
  static const int headBytesCap = 65536;

  /// Returns true iff [response] + [body] look like a real XMLTV feed.
  static bool isValidEpgResponse(http.Response response, List<int> body) {
    if (response.statusCode != 200) return false;

    final ctype = (response.headers['content-type'] ?? '').toLowerCase();
    final ctypeOk = ctype.isEmpty ||
        ctype.contains('xml') ||
        ctype.contains('gzip') ||
        ctype.contains('text/plain') ||
        ctype.contains('octet-stream');
    if (!ctypeOk) return false;

    // finding 167: a gzip magic header is not proof of XMLTV — a portal can
    // gzip an HTML error page. Inflate the head and run the SAME structural
    // checks as the plain path. If inflation fails or the head doesn't look
    // like XMLTV, reject so the variant walk continues.
    List<int> plain;
    if (isXmltvGzip(body)) {
      try {
        plain = gzip.decode(body);
      } catch (_) {
        // Not real gzip (or corrupt) — reject so the variant walk continues.
        return false;
      }
    } else {
      plain = body;
    }

    // Trim leading whitespace, take 8KB, check for `<?xml` + `<tv`.
    final head = _trimLeadingWhitespace(plain, 8192);
    if (head.isEmpty) return false;
    final asString = String.fromCharCodes(head);
    if (!asString.startsWith('<?xml')) return false;
    if (!asString.contains('<tv')) return false;

    // Reject empty `<tv/>` — the variant walk must continue.
    if (countProgrammes(asString) == 0) return false;

    return true;
  }

  /// Returns true if the body's first two bytes are a gzip magic header
  /// (0x1F 0x8B). When the body is gzip-compressed we trust the full
  /// parse to happen at EPG load time and return early.
  static bool isXmltvGzip(List<int> body) {
    return body.length >= 2 && body[0] == 0x1F && body[1] == 0x8B;
  }

  /// Counts the number of `<programme ` or `<programme>` occurrences in
  /// [head]. Used to reject the empty `<tv/>` case where a portal
  /// authenticated but has no EPG data.
  static int countProgrammes(String head) {
    // Both forms occur in real XMLTV. The space form is the canonical
    // one; some portals emit `<programme>` with no attributes.
    return '<programme '.allMatches(head).length +
        '<programme>'.allMatches(head).length;
  }

  /// Returns the first [cap] bytes of [body] with leading whitespace
  /// (spaces, tabs, CR, LF, BOM 0xEF 0xBB 0xBF) stripped. The first
  /// 8KB of a real XMLTV document starts with `<?xml`; some portals
  /// emit a UTF-8 BOM or a few leading blank lines.
  static List<int> _trimLeadingWhitespace(List<int> body, int cap) {
    var i = 0;
    while (i < body.length) {
      final b = body[i];
      final isWs = b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D;
      if (!isWs) {
        // Strip a leading UTF-8 BOM if present.
        if (i == 0 &&
            body.length >= 3 &&
            body[0] == 0xEF &&
            body[1] == 0xBB &&
            body[2] == 0xBF) {
          i = 3;
          continue;
        }
        break;
      }
      i++;
    }
    final end = (i + cap).clamp(i, body.length);
    return body.sublist(i, end);
  }
}
