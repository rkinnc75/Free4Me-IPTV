// Finding 83: M3U fallback name extraction used to anchor to the LAST comma
// (`,([^,]*)$`), truncating channel titles that contain commas. It now captures
// everything after the FIRST comma (`,(.+)$`).

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/m3u.dart';

void main() {
  test('finding 83: full title with commas is kept', () {
    expect(
      getName(
          '#EXTINF:-1 tvg-id="" group-title="Docs",Cosmos, A Spacetime Odyssey'),
      'Cosmos, A Spacetime Odyssey',
    );
  });

  test('finding 83: ordinary no-comma title is unchanged', () {
    expect(getName('#EXTINF:-1,ESPN'), 'ESPN');
  });

  test('finding 83: tvg-name still wins over the trailing title', () {
    expect(getName('#EXTINF:-1 tvg-name="HBO" ,ignored'), 'HBO');
  });
}
