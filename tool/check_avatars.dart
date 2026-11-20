// Do the rows the app shows carry a channel picture?
//
//   dart run tool/check_avatars.dart
//
// Reported: "channel images sometimes do not display". Up next rows and the
// co-watch half of Home come from the `next` endpoint's related list, which
// was parsed without the avatar every row carries, while search results had
// one — so the picture appeared on some rows and a letter on others. This
// counts avatars per source for a few videos and queries.
import 'dart:io';

import 'package:ai_bit/src/data/browse_client.dart';
import 'package:ai_bit/src/data/search_client.dart';

Future<void> main() async {
  final browse = YoutubeBrowseClient();
  final search = YoutubeSearchClient();
  var missing = 0;
  for (final id in ['dQw4w9WgXcQ', 'Ks-_Mh1QhMc', 'BnvrJ_lI5IQ']) {
    final rows = await browse.related(id);
    final with_ = rows.where((r) => (r.avatarUrl ?? '').isNotEmpty).length;
    missing += rows.length - with_;
    stdout.writeln('related $id: $with_/${rows.length} with a channel picture');
  }
  for (final q in ['cooking', 'cricket highlights']) {
    final rows = await search.search(q);
    final with_ = rows.where((r) => (r.avatarUrl ?? '').isNotEmpty).length;
    stdout.writeln('search "$q": $with_/${rows.length} with a channel picture');
  }
  browse.close();
  search.close();
  stdout.writeln(missing == 0 ? 'OK' : '$missing related rows without a picture');
}
