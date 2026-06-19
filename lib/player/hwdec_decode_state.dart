/// fix403: a human-readable decode-state label for the `DECODE[...]` probe.
///
/// The probe samples `hwdec-current` directly. At the first decoded frame the
/// hardware decoder may still be initializing — mpv decodes the first frame(s)
/// in software while mediacodec spins up, so `hwdec-current` reads "no" (or "")
/// *transiently* even when hardware decode is about to (and does) engage. Only
/// the settled `[+3s]` sample is authoritative.
///
/// This labels the sample so a first-frame "no" cannot be misread as a
/// permanent software fallback (which is exactly what happened during the
/// fix402 investigation). Returns one of:
///   • "hardware"    — a mediacodec decoder is active
///   • "software"    — settled on software (a "no" at/after the [+3s] sample,
///                     or a "no" when software was actually requested)
///   • "initializing(transient; trust [+3s])" — a "no" at an early probe while
///                     a hardware decoder was requested (do not trust yet)
///   • "initializing" — no value yet
///   • "unknown"     — the property read failed
String hwdecDecodeState({
  required String tag,
  required String req,
  required String current,
}) {
  const hw = {'mediacodec', 'mediacodec-copy', 'mediacodec-ndk'};
  if (current == '?') return 'unknown';
  if (current.isEmpty) return 'initializing';
  if (hw.contains(current)) return 'hardware';
  if (current == 'no') {
    final settled = tag.contains('+3s');
    if (hw.contains(req) && !settled) {
      return 'initializing(transient; trust [+3s])';
    }
    return 'software';
  }
  return current; // some other hwdec (vaapi, vdpau, …)
}
