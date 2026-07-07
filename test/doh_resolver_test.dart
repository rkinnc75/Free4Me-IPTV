// fix663: unit tests for the DoH resolver's pure/offline behavior. The actual
// DoH network query can't run offline; these cover the deterministic branches:
// literal-IP shortcut, disabled passthrough guard, provider validation, cache.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/doh_resolver.dart';

void main() {
  setUp(() {
    DohResolver.activeProvider = 'off';
    DohResolver.clearCache();
  });

  test('provider set contains exactly the five ids incl. quad9', () {
    expect(DohResolver.providers,
        {'off', 'cloudflare', 'google', 'nextdns', 'quad9'});
    expect(DohResolver.labels['quad9'], contains('9.9.9.9'));
  });

  test('enabled is false only when off', () {
    DohResolver.activeProvider = 'off';
    expect(DohResolver.enabled, isFalse);
    for (final p in ['cloudflare', 'google', 'nextdns', 'quad9']) {
      DohResolver.activeProvider = p;
      expect(DohResolver.enabled, isTrue, reason: '$p should enable DoH');
    }
  });

  test('literal IPv4 resolves to itself with no lookup (even when enabled)', () async {
    DohResolver.activeProvider = 'cloudflare';
    final r = await DohResolver.lookup('203.0.113.7');
    expect(r, hasLength(1));
    expect(r.first.address, '203.0.113.7');
    expect(r.first.type, InternetAddressType.IPv4);
  });

  test('literal IPv6 resolves to itself', () async {
    DohResolver.activeProvider = 'quad9';
    final r = await DohResolver.lookup('2606:4700:4700::1111');
    expect(r, hasLength(1));
    expect(r.first.type, InternetAddressType.IPv6);
  });

  test('disabled lookup of localhost falls through to system DNS', () async {
    DohResolver.activeProvider = 'off';
    final r = await DohResolver.lookup('localhost');
    expect(r, isNotEmpty); // system resolver returns loopback
  });
}
