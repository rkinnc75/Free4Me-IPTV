import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/epg_discovery/epg_discovery.dart';
import 'package:open_tv/backend/epg_discovery/epg_discovery_result.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';

/// fix386: bridges [EpgDiscovery] (the variant walker) with the
/// [Sql] persistence layer.
///
/// Called by [Utils.processSource] after a brand-new Xtream source is
/// added (gated on `!namePreExisted`). The runner:
///   1. Reads the source's current [Source.epgDiscoveryState].
///   2. If non-null (sticky), returns immediately — the source was
///      already probed, or the user set the EPG manually, or a prior
///      probe came back 'none'. No re-probe.
///   3. Otherwise, calls [EpgDiscovery.discover] with the source's
///      host / username / password.
///   4. On hit: persists the discovered URL + state 'auto'.
///   5. On miss: persists state 'none' (the existing `epg_url` is
///      preserved — the user might have set it manually, and we
///      don't want to clobber their value just because a probe
///      missed).
///
/// The runner is fire-and-forget from the caller's perspective. It
/// logs the result via [AppLog] and does not throw.
class EpgDiscoveryRunner {
  /// Run the discovery + persistence for [source] iff the source is
  /// Xtream AND has no existing EPG discovery state.
  ///
  /// The caller is responsible for ensuring the source row is
  /// committed (id is set) and that this is a new add (not a
  /// refresh of an existing source).
  static Future<void> runIfNewXtream(Source source) async {
    // fix386 (review): honour the "does not throw" contract. The probe is
    // detached via `unawaited` in Utils.processSource, so any throw here
    // (e.g. a DB error in getSourceById / setSourceEpgDiscovery, which are
    // outside the inner discover() try) would surface as an unhandled async
    // error in the zone. Swallow + log instead.
    try {
      await _run(source);
    } catch (e) {
      AppLog.warn(
          'EpgDiscoveryRunner: unexpected error for "${source.name}" — $e');
    }
  }

  static Future<void> _run(Source source) async {
    if (source.sourceType != SourceType.xtream) return;
    if (source.id == null) {
      AppLog.warn(
          'EpgDiscoveryRunner: source "${source.name}" has no id, '
          'skipping');
      return;
    }
    // Stickiness check: re-read the source from DB to be safe.
    final fresh = await Sql.getSourceById(source.id!);
    if (fresh == null) {
      AppLog.warn(
          'EpgDiscoveryRunner: source ${source.id} not in DB, skipping');
      return;
    }
    if (fresh.epgDiscoveryState != null) {
      AppLog.info(
          'EpgDiscoveryRunner: source "${fresh.name}" already has '
          'epgDiscoveryState=${fresh.epgDiscoveryState} — sticky, skip');
      return;
    }
    if (fresh.url == null || fresh.username == null || fresh.password == null) {
      AppLog.warn(
          'EpgDiscoveryRunner: source "${fresh.name}" missing url/creds, '
          'skipping');
      return;
    }

    // Strip credentials from the URL for the host: we want the origin
    // (scheme + host + port), not the userinfo. The variants build
    // their own URLs from this origin.
    final uri = Uri.tryParse(fresh.url!);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      AppLog.warn(
          'EpgDiscoveryRunner: source "${fresh.name}" has non-http url, '
          'skipping: ${fresh.url}');
      return;
    }
    final host = uri.origin;

    AppLog.info(
        'EpgDiscoveryRunner: starting probe for "${fresh.name}" at $host');

    EpgDiscoveryResult? result;
    try {
      result = await EpgDiscovery.discover(
        host,
        fresh.username!,
        fresh.password!,
      );
    } catch (e) {
      AppLog.warn(
          'EpgDiscoveryRunner: probe threw for "${fresh.name}": $e');
      result = null;
    }

    if (result != null) {
      AppLog.info(
          'EpgDiscoveryRunner: hit for "${fresh.name}" — variant='
          '${result.variant}, url=${result.url}, ${result.elapsedMs}ms');
      await Sql.setSourceEpgDiscovery(
        fresh.id!,
        url: result.url,
        state: 'auto',
      );
    } else {
      AppLog.info(
          'EpgDiscoveryRunner: no hit for "${fresh.name}"');
      await Sql.setSourceEpgDiscovery(fresh.id!, state: 'none');
    }
  }
}
