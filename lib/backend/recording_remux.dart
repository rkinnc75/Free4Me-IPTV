import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/recording.dart';

/// fix685: app-side Scheduled Recording re-mux.
///
/// Live-TV `.ts` captures play in mpv but Android's MediaExtractor/MediaMuxer
/// cannot parse them ("Failed to instantiate extractor"), so the fix671 native
/// remux path was a dead end and was removed in this fix. Instead we stream-copy
/// (no re-encode) the captured `.ts` into a real container using the FFmpeg
/// (libavformat n6.0) symbols now EXPORTED by our custom `libmpv.so` — the
/// muxer allowlist added in the vnext libmpv build (mp4/mov/matroska/mpegts/…)
/// plus the mpegts/mov/matroska demuxers and the file/fd protocols. No NDK, no
/// JNI shim baked into libmpv: pure Dart FFI over `dlopen("libmpv.so")`, the same
/// library media_kit already loads.
///
/// Container policy (fail-open): probe input codecs → if every stream is
/// MP4-compatible (h264/hevc video, aac/mp3 audio) write **.mp4**; otherwise or
/// on any MP4 failure fall back to **.mkv** (Matroska takes anything mpv can
/// demux); if even that fails, keep the original **.ts**. A recording is never
/// lost by remuxing.
///
/// MediaStore I/O stays on the platform side (Kotlin, via the existing
/// `me.free4me.iptv/recording` channel): Dart asks for read/write file
/// descriptors and feeds them to libavformat through the `fd:` protocol. The
/// CPU-bound copy runs in a background isolate (fds are process-global) so the
/// UI isolate never janks; the UI isolate keeps sole ownership of the channel
/// and the DB (single-writer invariant from fix681 is preserved).
class RecordingRemux {
  RecordingRemux._();

  static const MethodChannel _ch = MethodChannel('me.free4me.iptv/recording');

  /// libavformat major shipped in our n6.0 build (Lavf60.x). The FFI struct
  /// offsets below are pinned to this ABI; if a future libmpv bumps ffmpeg we
  /// abort remux (keep the .ts) rather than read wrong offsets.
  static const int _expectedAvformatMajor = 60;

  static bool _debug = false;

  static void _d(String msg) {
    if (_debug) AppLog.info('[SRDBG] remux: $msg');
  }

  /// Remux every id in [ids] whose row is `done`, whose output is a `.ts`, and
  /// whose capture requested remux. Called by RecordingStatusJournal.drain after
  /// it has applied the native status events. Best-effort and fully guarded: any
  /// failure leaves the recording on its `.ts`.
  static Future<void> process(List<int> ids, {bool debugLogging = false}) async {
    if (!Platform.isAndroid || ids.isEmpty) return;
    _debug = debugLogging;
    for (final id in ids) {
      try {
        await _processOne(id);
      } catch (e) {
        _d('id=$id unexpected failure — $e (keeping .ts)');
        AppLog.warn('RecordingRemux: id=$id failed — $e');
      }
    }
  }

  static Future<void> _processOne(int id) async {
    final rec = await Sql.getRecordingById(id);
    if (rec == null) return;
    final src = rec.outputPath;
    // NB (fix686): do NOT gate on a ".ts" suffix. The captured file is a
    // MediaStore entry whose output_path is a content:// URI — the URI never
    // ends in ".ts" (only the display name does), so a suffix test skips EVERY
    // recording (observed on v4.0.1: "remux: id=17 skip ... path=content://…").
    // drain() only calls process() for ids the native service flagged
    // "remux":true on a fresh capture, so status==done + a non-null path is the
    // correct and sufficient guard; container choice is codec-probed, not
    // extension-based.
    if (rec.status != RecordingStatus.done || src == null) {
      _d('id=$id skip (status=${rec.status.name} path=$src)');
      return;
    }

    // Show progress in the UI while the copy runs.
    await Sql.updateRecordingStatus(id, RecordingStatus.compressing,
        outputPath: src, error: null);

    // Prefer MP4; on failure retry as MKV; else keep .ts. Each attempt opens its
    // own read fd (a spent fd can't be rewound) and its own output entry (a
    // failed muxer may have written bytes).
    for (final ext in const ['mp4', 'mkv']) {
      final int? inFd = await _openRead(src);
      if (inFd == null) {
        _d('id=$id openRead returned null — keeping .ts');
        break;
      }
      _RemuxTarget? target;
      try {
        target = await _createOutput(rec.channelName, ext);
        if (target == null) {
          _d('id=$id $ext createOutput returned null (channel/MediaStore)');
          continue;
        }
        // fix687: streamCopy returns '' on success, else "step rc=<AVERROR>".
        final err = await _copyInIsolate(inFd, target.fd, ext);
        if (err.isEmpty) {
          await _finalize(target.uri);
          await _deleteTs(src);
          await Sql.updateRecordingStatus(id, RecordingStatus.done,
              outputPath: target.uri, error: null);
          _d('id=$id remuxed -> $ext ${target.uri}; .ts deleted');
          return;
        }
        _d('id=$id $ext copy failed [$err]; discarding target');
        await _discard(target.uri);
      } finally {
        await _closeFd(inFd);
      }
    }

    _d('id=$id all containers failed — keeping .ts');
    await _revertDone(id, src);
  }

  static Future<void> _revertDone(int id, String tsPath) =>
      Sql.updateRecordingStatus(id, RecordingStatus.done,
          outputPath: tsPath, error: null);

  // ── platform channel (MediaStore fds live on the Kotlin side) ──────────────

  static Future<int?> _openRead(String uri) async =>
      await _ch.invokeMethod<int>('remuxOpenRead', {'uri': uri});

  static Future<_RemuxTarget?> _createOutput(String name, String ext) async {
    final m = await _ch.invokeMapMethod<String, dynamic>(
        'remuxCreateOutput', {'name': name, 'ext': ext});
    if (m == null) return null;
    final uri = m['uri'] as String?;
    final fd = (m['fd'] as num?)?.toInt();
    if (uri == null || fd == null) return null;
    return _RemuxTarget(uri, fd);
  }

  static Future<void> _finalize(String uri) async =>
      _ch.invokeMethod('remuxFinalize', {'uri': uri});

  static Future<void> _discard(String uri) async =>
      _ch.invokeMethod('remuxDiscard', {'uri': uri});

  static Future<void> _deleteTs(String uri) async =>
      _ch.invokeMethod('remuxDeleteTs', {'uri': uri});

  static Future<void> _closeFd(int fd) async =>
      _ch.invokeMethod('remuxCloseFd', {'fd': fd});

  // ── background isolate: pure FFI stream-copy ───────────────────────────────

  static Future<String> _copyInIsolate(int inFd, int outFd, String ext) async {
    try {
      return await Isolate.run(() => _RemuxNative.streamCopy(inFd, outFd, ext));
    } catch (e) {
      return 'isolate-threw: $e';
    }
  }
}

class _RemuxTarget {
  final String uri;
  final int fd;
  const _RemuxTarget(this.uri, this.fd);
}

// ── FFI: libavformat n6.0 (exported from our custom libmpv.so) ──────────────
//
// Only the handful of struct fields a stream-copy remux touches are read, at
// offsets derived from the n6.0 headers (LP64 — identical on arm64/x86_64):
//   AVFormatContext: nb_streams @44 (u32), streams @48 (ptr), pb @32 (ptr)
//   AVStream:        codecpar   @16 (ptr), time_base @32 (AVRational, 2×i32)
//   AVCodecParameters: codec_type @0 (i32), codec_id @4 (i32), codec_tag @8 (u32)
//   AVPacket:        stream_index @36 (i32)
// Guarded at runtime by avformat_version() major == 60 (else abort → keep .ts).

typedef _AvOpenInputNative = Int32 Function(Pointer<Pointer<Void>>,
    Pointer<Utf8>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _AvOpenInputDart = int Function(Pointer<Pointer<Void>>, Pointer<Utf8>,
    Pointer<Void>, Pointer<Pointer<Void>>);

typedef _AvFindStreamInfoNative = Int32 Function(
    Pointer<Void>, Pointer<Void>);
typedef _AvFindStreamInfoDart = int Function(Pointer<Void>, Pointer<Void>);

typedef _AvCloseInputNative = Void Function(Pointer<Pointer<Void>>);
typedef _AvCloseInputDart = void Function(Pointer<Pointer<Void>>);

typedef _AvAllocOutputCtxNative = Int32 Function(Pointer<Pointer<Void>>,
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _AvAllocOutputCtxDart = int Function(Pointer<Pointer<Void>>,
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);

typedef _AvFreeCtxNative = Void Function(Pointer<Void>);
typedef _AvFreeCtxDart = void Function(Pointer<Void>);

typedef _AvNewStreamNative = Pointer<Void> Function(
    Pointer<Void>, Pointer<Void>);
typedef _AvNewStreamDart = Pointer<Void> Function(
    Pointer<Void>, Pointer<Void>);

typedef _AvCodecParamsCopyNative = Int32 Function(
    Pointer<Void>, Pointer<Void>);
typedef _AvCodecParamsCopyDart = int Function(Pointer<Void>, Pointer<Void>);

typedef _AvWriteHeaderNative = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _AvWriteHeaderDart = int Function(Pointer<Void>, Pointer<Void>);

typedef _AvWriteTrailerNative = Int32 Function(Pointer<Void>);
typedef _AvWriteTrailerDart = int Function(Pointer<Void>);

typedef _AvInterleavedWriteNative = Int32 Function(
    Pointer<Void>, Pointer<Void>);
typedef _AvInterleavedWriteDart = int Function(Pointer<Void>, Pointer<Void>);

typedef _AvReadFrameNative = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _AvReadFrameDart = int Function(Pointer<Void>, Pointer<Void>);

typedef _AvPacketAllocNative = Pointer<Void> Function();
typedef _AvPacketAllocDart = Pointer<Void> Function();

typedef _AvPacketFreeNative = Void Function(Pointer<Pointer<Void>>);
typedef _AvPacketFreeDart = void Function(Pointer<Pointer<Void>>);

typedef _AvPacketUnrefNative = Void Function(Pointer<Void>);
typedef _AvPacketUnrefDart = void Function(Pointer<Void>);

// fix689: av_packet_rescale_ts takes two AVRational structs BY VALUE. Passing
// them as decomposed int32 args is the wrong ABI (arm64 packs {num,den} into
// one register) and corrupts pts/dts to AV_NOPTS_VALUE, so the first
// av_interleaved_write_frame fails with EINVAL. Bind the struct by value.
final class AVRational extends Struct {
  @Int32()
  external int num;
  @Int32()
  external int den;
}

typedef _AvPacketRescaleTsNative = Void Function(
    Pointer<Void>, AVRational, AVRational);
typedef _AvPacketRescaleTsDart = void Function(
    Pointer<Void>, AVRational, AVRational);

// fix688: fd must be passed to the ffmpeg "fd:" protocol as an AVDictionary
// option ("fd"=N), not embedded in the URL (n6.x rejects "fd:N" with EINVAL).
// avio_open2 takes the options dict; avio_open does not, so output moves to it.
typedef _AvioOpen2Native = Int32 Function(Pointer<Pointer<Void>>,
    Pointer<Utf8>, Int32, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _AvioOpen2Dart = int Function(Pointer<Pointer<Void>>, Pointer<Utf8>,
    int, Pointer<Void>, Pointer<Pointer<Void>>);

typedef _AvDictSetIntNative = Int32 Function(
    Pointer<Pointer<Void>>, Pointer<Utf8>, Int64, Int32);
typedef _AvDictSetIntDart = int Function(
    Pointer<Pointer<Void>>, Pointer<Utf8>, int, int);

typedef _AvDictFreeNative = Void Function(Pointer<Pointer<Void>>);
typedef _AvDictFreeDart = void Function(Pointer<Pointer<Void>>);

typedef _AvioClosepNative = Int32 Function(Pointer<Pointer<Void>>);
typedef _AvioClosepDart = int Function(Pointer<Pointer<Void>>);

typedef _AvVersionNative = Uint32 Function();
typedef _AvVersionDart = int Function();

// fix690: aac_adtstoasc bitstream filter — AAC from MPEG-TS is ADTS-framed and
// our n6.0 mp4 muxer needs the filter to emit a valid AudioSpecificConfig
// (esds). Without it strict players (Android's default) reject the audio while
// tolerant ones (VLC) play it.
typedef _AvBsfGetByNameNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _AvBsfGetByNameDart = Pointer<Void> Function(Pointer<Utf8>);

typedef _AvBsfAllocNative = Int32 Function(
    Pointer<Void>, Pointer<Pointer<Void>>);
typedef _AvBsfAllocDart = int Function(Pointer<Void>, Pointer<Pointer<Void>>);

typedef _AvBsfInitNative = Int32 Function(Pointer<Void>);
typedef _AvBsfInitDart = int Function(Pointer<Void>);

typedef _AvBsfSendNative = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _AvBsfSendDart = int Function(Pointer<Void>, Pointer<Void>);

typedef _AvBsfReceiveNative = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _AvBsfReceiveDart = int Function(Pointer<Void>, Pointer<Void>);

typedef _AvBsfFreeNative = Void Function(Pointer<Pointer<Void>>);
typedef _AvBsfFreeDart = void Function(Pointer<Pointer<Void>>);

class _RemuxNative {
  // --- struct offsets (bytes), n6.0 / LP64 ---
  static const int _fmtNbStreams = 44;
  static const int _fmtStreams = 48;
  static const int _fmtPb = 32;
  static const int _streamCodecpar = 16;
  static const int _streamTimeBaseNum = 32;
  static const int _streamTimeBaseDen = 36;
  static const int _parCodecType = 0;
  static const int _parCodecId = 4;
  static const int _parCodecTag = 8;
  static const int _pktStreamIndex = 36;

  // AVBSFContext offsets (n6.0 / LP64) — fix690 aac_adtstoasc.
  static const int _bsfParIn = 24;
  static const int _bsfParOut = 32;
  static const int _bsfTimeBaseInNum = 40;
  static const int _bsfTimeBaseInDen = 44;

  // AVMediaType
  static const int _typeVideo = 0;
  static const int _typeAudio = 1;

  // AVCodecID (n6.0 values)
  static const int _idH264 = 27;
  static const int _idHevc = 173;
  static const int _idAac = 86018;
  static const int _idMp3 = 86017;

  static const int _avioFlagWrite = 2;

  // fix690: AVERROR(EAGAIN)=-11 and AVERROR_EOF for the BSF receive loop.
  static const int _eagain = -11;
  static const int _averrorEof = -541478725;

  /// Stream-copy [inFd] → [outFd] into container [ext]. Returns '' on success,
  /// else a short `step rc=AVERROR` diagnostic (fix687) so the caller can log
  /// exactly which libavformat call failed. Runs in a background isolate.
  static String streamCopy(int inFd, int outFd, String ext) {
    final DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open('libmpv.so');
    } catch (e) {
      return 'dlopen-threw: $e';
    }

    final avVersion = lib
        .lookupFunction<_AvVersionNative, _AvVersionDart>('avformat_version');
    final ver = avVersion();
    if ((ver >> 16) != RecordingRemux._expectedAvformatMajor) {
      return 'abi-mismatch avformat_version=$ver'; // offsets not trusted.
    }

    final openInput = lib.lookupFunction<_AvOpenInputNative, _AvOpenInputDart>(
        'avformat_open_input');
    final findInfo = lib.lookupFunction<_AvFindStreamInfoNative,
        _AvFindStreamInfoDart>('avformat_find_stream_info');
    final closeInput = lib.lookupFunction<_AvCloseInputNative,
        _AvCloseInputDart>('avformat_close_input');
    final allocOut = lib.lookupFunction<_AvAllocOutputCtxNative,
        _AvAllocOutputCtxDart>('avformat_alloc_output_context2');
    final freeCtx = lib
        .lookupFunction<_AvFreeCtxNative, _AvFreeCtxDart>(
            'avformat_free_context');
    final newStream = lib.lookupFunction<_AvNewStreamNative, _AvNewStreamDart>(
        'avformat_new_stream');
    final copyParams = lib.lookupFunction<_AvCodecParamsCopyNative,
        _AvCodecParamsCopyDart>('avcodec_parameters_copy');
    final writeHeader = lib.lookupFunction<_AvWriteHeaderNative,
        _AvWriteHeaderDart>('avformat_write_header');
    final writeTrailer = lib.lookupFunction<_AvWriteTrailerNative,
        _AvWriteTrailerDart>('av_write_trailer');
    final interleavedWrite = lib.lookupFunction<_AvInterleavedWriteNative,
        _AvInterleavedWriteDart>('av_interleaved_write_frame');
    final readFrame = lib
        .lookupFunction<_AvReadFrameNative, _AvReadFrameDart>('av_read_frame');
    final packetAlloc = lib.lookupFunction<_AvPacketAllocNative,
        _AvPacketAllocDart>('av_packet_alloc');
    final packetFree = lib.lookupFunction<_AvPacketFreeNative,
        _AvPacketFreeDart>('av_packet_free');
    final packetUnref = lib.lookupFunction<_AvPacketUnrefNative,
        _AvPacketUnrefDart>('av_packet_unref');
    final rescaleTs = lib.lookupFunction<_AvPacketRescaleTsNative,
        _AvPacketRescaleTsDart>('av_packet_rescale_ts');
    final avioOpen2 = lib
        .lookupFunction<_AvioOpen2Native, _AvioOpen2Dart>('avio_open2');
    final dictSetInt = lib.lookupFunction<_AvDictSetIntNative,
        _AvDictSetIntDart>('av_dict_set_int');
    final dictFree = lib
        .lookupFunction<_AvDictFreeNative, _AvDictFreeDart>('av_dict_free');
    final avioClosep = lib.lookupFunction<_AvioClosepNative,
        _AvioClosepDart>('avio_closep');
    final bsfGetByName = lib.lookupFunction<_AvBsfGetByNameNative,
        _AvBsfGetByNameDart>('av_bsf_get_by_name');
    final bsfAlloc = lib
        .lookupFunction<_AvBsfAllocNative, _AvBsfAllocDart>('av_bsf_alloc');
    final bsfInit = lib
        .lookupFunction<_AvBsfInitNative, _AvBsfInitDart>('av_bsf_init');
    final bsfSend = lib.lookupFunction<_AvBsfSendNative, _AvBsfSendDart>(
        'av_bsf_send_packet');
    final bsfReceive = lib.lookupFunction<_AvBsfReceiveNative,
        _AvBsfReceiveDart>('av_bsf_receive_packet');
    final bsfFree = lib
        .lookupFunction<_AvBsfFreeNative, _AvBsfFreeDart>('av_bsf_free');

    final arena = Arena();
    Pointer<Void> ictx = nullptr;
    Pointer<Void> octx = nullptr;
    Pointer<Pointer<Void>> pkt = nullptr;
    // fix690: aac_adtstoasc filter state (MP4 + AAC only).
    final pBsf = arena<Pointer<Void>>();
    pBsf.value = nullptr;
    var aacIdx = -1;
    var pbOpened = false;
    try {
      // Input: the ffmpeg "fd:" protocol takes the fd as an option, not in the
      // URL (n6.x rejects "fd:N" with EINVAL: "please set it via -fd {num}").
      final inUrl = 'fd:'.toNativeUtf8(allocator: arena);
      final pInOpts = arena<Pointer<Void>>();
      pInOpts.value = nullptr;
      final fdKey = 'fd'.toNativeUtf8(allocator: arena);
      dictSetInt(pInOpts, fdKey, inFd, 0);
      final pIctx = arena<Pointer<Void>>();
      final rcOpen = openInput(pIctx, inUrl, nullptr, pInOpts);
      dictFree(pInOpts);
      if (rcOpen < 0) return 'open_input(fd=$inFd) rc=$rcOpen';
      ictx = pIctx.value;
      final rcInfo = findInfo(ictx, nullptr);
      if (rcInfo < 0) return 'find_stream_info rc=$rcInfo';

      final nStreams =
          (ictx.cast<Uint8>() + _fmtNbStreams).cast<Uint32>().value;
      if (nStreams == 0) return 'no-streams';
      // streams field holds AVStream** — read the pointer VALUE, then index it.
      final streamsArr =
          (ictx.cast<Uint8>() + _fmtStreams).cast<Pointer<Pointer<Void>>>().value;

      // Output context for the requested container. NB: the ffmpeg muxer short
      // name for Matroska is "matroska", not "mkv" (which isn't registered).
      final muxerName = ext == 'mkv' ? 'matroska' : 'mp4';
      final fmtName = muxerName.toNativeUtf8(allocator: arena);
      final pOctx = arena<Pointer<Void>>();
      final rcAlloc = allocOut(pOctx, nullptr, fmtName, nullptr);
      if (rcAlloc < 0) return 'alloc_output($muxerName) rc=$rcAlloc';
      octx = pOctx.value;
      if (octx == nullptr) return 'alloc_output($muxerName) null-ctx';

      // Map every audio/video stream, copying codec params (stream-copy).
      var mapped = 0;
      var mp4Compatible = true;
      for (var i = 0; i < nStreams; i++) {
        final ist = (streamsArr + i).value;
        if (ist == nullptr) continue;
        final ipar = _ptrAt(ist, _streamCodecpar);
        if (ipar == nullptr) continue;
        final codecType = (ipar.cast<Int32>() + (_parCodecType ~/ 4)).value;
        if (codecType != _typeVideo && codecType != _typeAudio) continue;
        final codecId = (ipar.cast<Int32>() + (_parCodecId ~/ 4)).value;
        if (!_mp4Ok(codecId)) mp4Compatible = false;

        final ost = newStream(octx, nullptr);
        if (ost == nullptr) return 'new_stream null (i=$i)';
        final opar = _ptrAt(ost, _streamCodecpar);

        // fix690: for AAC audio into MP4, run the packets through
        // aac_adtstoasc so the muxer gets a proper AudioSpecificConfig. The
        // filter fills par_out with the corrected params (incl. extradata),
        // which must go to the output stream BEFORE write_header.
        if (ext == 'mp4' && codecType == _typeAudio && codecId == _idAac) {
          final filt = bsfGetByName('aac_adtstoasc'.toNativeUtf8(allocator: arena));
          if (filt != nullptr && bsfAlloc(filt, pBsf) >= 0) {
            final bsf = pBsf.value;
            final rcPar = copyParams(_ptrAt(bsf, _bsfParIn), ipar);
            if (rcPar < 0) return 'bsf par_in copy rc=$rcPar';
            (bsf.cast<Uint8>() + _bsfTimeBaseInNum).cast<Int32>().value =
                _i32(ist, _streamTimeBaseNum);
            (bsf.cast<Uint8>() + _bsfTimeBaseInDen).cast<Int32>().value =
                _i32(ist, _streamTimeBaseDen);
            final rcInit = bsfInit(bsf);
            if (rcInit < 0) return 'bsf_init rc=$rcInit';
            final rcOut = copyParams(opar, _ptrAt(bsf, _bsfParOut));
            if (rcOut < 0) return 'bsf par_out copy rc=$rcOut';
            aacIdx = i;
          } else {
            // Filter unavailable — fall back to a plain copy (MKV-safe path).
            final rcCopy = copyParams(opar, ipar);
            if (rcCopy < 0) return 'copy_params rc=$rcCopy (i=$i)';
          }
        } else {
          final rcCopy = copyParams(opar, ipar);
          if (rcCopy < 0) return 'copy_params rc=$rcCopy (i=$i)';
        }
        // Let the muxer assign the tag for the target container.
        (opar.cast<Uint32>() + (_parCodecTag ~/ 4)).value = 0;
        mapped++;
      }
      if (mapped == 0) return 'no-av-streams-mapped (nStreams=$nStreams)';
      // MP4 container but a stream it can't hold → let caller fall back to MKV.
      if (ext == 'mp4' && !mp4Compatible) return 'mp4-incompatible-codec';

      // Output AVIO: same fd-as-option rule; avio_open2 accepts the dict.
      final outUrl = 'fd:'.toNativeUtf8(allocator: arena);
      final pbSlot = (octx.cast<Uint8>() + _fmtPb).cast<Pointer<Void>>();
      final pOutOpts = arena<Pointer<Void>>();
      pOutOpts.value = nullptr;
      dictSetInt(pOutOpts, fdKey, outFd, 0);
      final rcAvio = avioOpen2(pbSlot, outUrl, _avioFlagWrite, nullptr, pOutOpts);
      dictFree(pOutOpts);
      if (rcAvio < 0) return 'avio_open2(fd=$outFd) rc=$rcAvio';
      pbOpened = true;

      final rcHdr = writeHeader(octx, nullptr);
      if (rcHdr < 0) return 'write_header($muxerName) rc=$rcHdr';

      pkt = arena<Pointer<Void>>();
      pkt.value = packetAlloc();
      if (pkt.value == nullptr) return 'packet_alloc null';
      final packet = pkt.value;

      final istreamsArr = streamsArr;
      final ostreamsArr =
          (octx.cast<Uint8>() + _fmtStreams).cast<Pointer<Pointer<Void>>>().value;

      // fix689: reusable AVRational structs passed BY VALUE to rescale_ts.
      final srcTb = arena<AVRational>();
      final dstTb = arena<AVRational>();

      var frames = 0;
      while (readFrame(ictx, packet) >= 0) {
        final si = (packet.cast<Uint8>() + _pktStreamIndex).cast<Int32>();
        final idx = si.value;
        if (idx < 0 || idx >= nStreams) {
          packetUnref(packet);
          continue;
        }
        final ist = (istreamsArr + idx).value;
        final ost = (ostreamsArr + idx).value;
        if (ist == nullptr || ost == nullptr) {
          packetUnref(packet);
          continue;
        }
        srcTb.ref.num = _i32(ist, _streamTimeBaseNum);
        srcTb.ref.den = _i32(ist, _streamTimeBaseDen);
        dstTb.ref.num = _i32(ost, _streamTimeBaseNum);
        dstTb.ref.den = _i32(ost, _streamTimeBaseDen);

        // fix690: AAC audio → filter through aac_adtstoasc. send consumes the
        // packet; receive yields 0+ filtered packets (each unref'd after write).
        if (pBsf.value != nullptr && idx == aacIdx) {
          final rcSend = bsfSend(pBsf.value, packet);
          if (rcSend < 0) {
            packetUnref(packet);
            return 'bsf_send rc=$rcSend';
          }
          while (true) {
            final rcRecv = bsfReceive(pBsf.value, packet);
            if (rcRecv == _eagain || rcRecv == _averrorEof) break;
            if (rcRecv < 0) return 'bsf_receive rc=$rcRecv';
            rescaleTs(packet, srcTb.ref, dstTb.ref);
            final w = interleavedWrite(octx, packet);
            if (w < 0) {
              packetUnref(packet);
              return 'write_frame rc=$w (aac, after $frames)';
            }
            packetUnref(packet);
            frames++;
          }
          continue; // send already consumed the packet
        }

        rescaleTs(packet, srcTb.ref, dstTb.ref);
        final rcWrite = interleavedWrite(octx, packet);
        if (rcWrite < 0) {
          packetUnref(packet);
          return 'write_frame rc=$rcWrite (after $frames frames)';
        }
        packetUnref(packet);
        frames++;
      }
      if (frames == 0) return 'no-frames-read';

      final rcTrailer = writeTrailer(octx);
      if (rcTrailer < 0) return 'write_trailer rc=$rcTrailer';
      return ''; // success
    } catch (e) {
      return 'exception: $e';
    } finally {
      if (pBsf.value != nullptr) bsfFree(pBsf);
      if (pkt != nullptr && pkt.value != nullptr) packetFree(pkt);
      if (pbOpened && octx != nullptr) {
        final pbSlot =
            (octx.cast<Uint8>() + _fmtPb).cast<Pointer<Void>>();
        avioClosep(pbSlot);
      }
      if (octx != nullptr) freeCtx(octx);
      if (ictx != nullptr) {
        final pIctx = arena<Pointer<Void>>();
        pIctx.value = ictx;
        closeInput(pIctx);
      }
      arena.releaseAll();
    }
  }

  static bool _mp4Ok(int codecId) =>
      codecId == _idH264 ||
      codecId == _idHevc ||
      codecId == _idAac ||
      codecId == _idMp3;

  static Pointer<Void> _ptrAt(Pointer<Void> base, int byteOffset) =>
      (base.cast<Uint8>() + byteOffset).cast<Pointer<Void>>().value;

  static int _i32(Pointer<Void> base, int byteOffset) =>
      (base.cast<Uint8>() + byteOffset).cast<Int32>().value;
}
