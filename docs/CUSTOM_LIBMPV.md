# Custom libmpv (LGPL-max) — Android native player

**Free4Me's Android libmpv is a CUSTOM LGPLv3 build, not stock media_kit.**
It is wired in via `dependency_overrides` in [`pubspec.yaml`](../pubspec.yaml)
and is on `main` since 2026-06-27 (commit `66045f3`); **muxers were added in
v4.0.0 (2026-07-09)**. Any release tagged from `main` ships it.

## Why

Stock `media_kit_libs_android_video` bundles a libmpv whose libavfilter has only
**`overlay` + `equalizer`** — no `fps`/`select`/`scale`/etc. That made the
low-RAM 30 fps output cap impossible (every attempt stalled playback, because a
missing lavfi filter makes mpv deselect the video track). The custom build adds
**every non-GPL filter + all codecs** while staying **LGPLv3** (no
x264/x265/libpostproc, 0 GPL filters → the app stays proprietary-licensable).

## What's enabled (FFmpeg 6.0, LGPLv3)

| Component | Stock | **Custom** |
|---|---|---|
| Video/audio filters | 2 | **435** |
| Decoders | ~40 | **505** |
| Demuxers | ~50 | **343** |
| Parsers | ~18 | **58** |
| Protocols | ~24 | **37** (network, TLS via mbedtls) |
| Bitstream filters | all | 41 |
| Encoders | image-only | image-only (screenshots) |
| Muxers | 0 | **9** (mp4, mov, matroska, mpegts, adts, mp3, flac, wav, latm) |

**Full enumerated lists:** [LIBMPV_COMPONENTS.md](./LIBMPV_COMPONENTS.md).

**Muxers (added v4.0.0):** enabled so the app can stream-copy a recorded
`.ts` into a standard container (MP4 preferred, Matroska/MKV fallback) via a
thin JNI shim, plus `mpegts` (timestamp repair) and audio-only extraction
(`adts`/`mp3`/`flac`/`wav`). Muxers are libavformat container writers and carry
no GPL/non-free dependency, so the LGPLv3 line is unchanged. libavformat mux
symbols (`avformat_alloc_output_context2`, `av_guess_format`, `av_write_trailer`)
are exported in the built `.so`. **Encoders remain image-only** — container
remux is lossless stream-copy (no re-encode); size-reducing re-encode is a
separate future feature that will use Android MediaCodec hardware (not ffmpeg
software encoders, which would break the LGPL line).

Key filters now available: `fps`, `select`, `framestep`, `scale`, `scale2ref`,
`crop`, `pad`, `rotate`, `transpose`, `hflip`, `vflip`, `tonemap`, `colorspace`,
`overlay`, `blend`, `hstack`/`vstack`/`xstack`, `yadif`/`bwdif`/`w3fdif`
(deinterlace), `lut`/`lut3d`/`curves`/`colorbalance`, `aresample`, `atempo`,
`loudnorm`, `dynaudnorm`, `equalizer`, … (435 total).

**GPL filters are deliberately EXCLUDED** (this keeps the LGPL line): `eq`,
`cropdetect`, `colormatrix`, `pp`, `spp`, `fspp`, `hqdn3d`, `mpdecimate`,
`kerndeint`, `nnedi`, `owdenoise`, …

Note: the libavfilter `subtitles`/`ass` *filters* are NOT built (they need
`--enable-libass` in ffmpeg); mpv renders subtitles **natively** via libass, so
subtitles work — you just can't burn them in through a `vf` filter.

## How it's wired

`pubspec.yaml` → `dependency_overrides: media_kit_libs_android_video` → the fork
**`rkinnc75/media-kit`** (`libs/android/media_kit_libs_android_video`), whose
`build.gradle` downloads custom per-ABI jars (MD5-verified) from the build fork
**`rkinnc75/libmpv-android-video-build`** release **`vnext`**. media_kit's
Dart/FFI layer is unchanged — only the native `libmpv.so` swaps.

**Fork ownership (v4.0.0):** both build repos were migrated from `rkalsky/*` to
`rkinnc75/*` and are now canonical. The old `rkalsky` artifacts remain intact for
rollback; the fork boundary itself provides the rollback point (no `vnext`
mutation needed).

## Status / behavior

- On `main`; **on-device verified** (onn 4K Plus): plays cleanly, and
  `vf=lavfi=[fps=fps=30]` creates + caps output to 30 fps with `voDrop=0`.
- The **fps cap is a separate opt-in** and is currently **OFF** in the engine.
  `framedrop=decoder` (low-RAM) is the active smoothness path; the two are
  orthogonal and can coexist.
- `libmpv.so` is ~18 MB (APK grows a few MB vs stock).

## License (LGPLv3) obligations

Ship a libmpv source offer + allow the user to replace the `.so` (unchanged from
media_kit's existing posture). Adding filters does not change the license tier;
the build excludes all GPL/nonfree components.

## Rebuilding (after a media_kit/libmpv bump)

In the build fork `rkinnc75/libmpv-android-video-build`,
`buildscripts/flavors/default.sh`: keep `--disable-gpl --disable-nonfree`,
`--enable-filters --enable-decoders --enable-demuxers --enable-parsers
--enable-protocols --enable-bsfs`, and the muxer allowlist
`--disable-muxers --enable-muxer=mp4 --enable-muxer=mov --enable-muxer=matroska
--enable-muxer=mpegts --enable-muxer=adts --enable-muxer=mp3 --enable-muxer=flac
--enable-muxer=wav`. Push to its `main` → GitHub Actions builds 4 ABIs → publish
the `vnext` release → recompute the per-ABI jar MD5s → update the
`rkinnc75/media-kit` fork's `build.gradle` URLs+MD5s → bump the
`dependency_overrides` `ref` in `pubspec.yaml`. Verify the ffmpeg configure log
shows the muxers under "Enabled muxers:" and that mux symbols are exported
(`nm -D`).
