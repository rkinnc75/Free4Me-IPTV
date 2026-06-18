/// fix400: whether a typed search query should trigger a (re)load.
///
/// A single typed character is skipped: a 1-char substring matches almost
/// everything and scans the whole catalogue (~2s on a large multi-source
/// library, per device logs) only to be immediately superseded by the next
/// keystroke. So:
///   • ≥2 non-whitespace characters → load (run the search)
///   • exactly 1 → skip, leaving the current list untouched
///   • empty / whitespace-only → load (restores the full browse)
bool searchQueryShouldLoad(String query) => query.trim().length != 1;
