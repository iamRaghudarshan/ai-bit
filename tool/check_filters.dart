// Checks that the search filter encoder produces parameters YouTube honours.
//
// The filters used to be pre-baked strings that replaced one another; this
// walks the combinations that were previously impossible and reports what
// comes back, so a change to the encoding is caught here rather than on a
// phone.
import 'package:ai_bit/src/data/search_client.dart';

Future<void> main() async {
  final client = YoutubeSearchClient();
  const query = 'kannada songs';

  final cases = <String, String?>{
    'no filters (videos only)': null,
    'sort: upload date': YoutubeSearchClient.buildParams(sortBy: 2),
    'sort: view count': YoutubeSearchClient.buildParams(sortBy: 3),
    'this week': YoutubeSearchClient.buildParams(uploadDate: 3),
    'under 4 minutes': YoutubeSearchClient.buildParams(duration: 1),
    'over 20 minutes': YoutubeSearchClient.buildParams(duration: 2),
    'date + short (was impossible)':
        YoutubeSearchClient.buildParams(sortBy: 2, uploadDate: 3, duration: 1),
    'views + long (was impossible)':
        YoutubeSearchClient.buildParams(sortBy: 3, duration: 2),
  };

  var failures = 0;
  for (final entry in cases.entries) {
    try {
      final results = await client.search(query, params: entry.value);
      final durations = results
          .where((v) => v.duration != null)
          .map((v) => v.duration!.inMinutes)
          .toList();
      final span = durations.isEmpty
          ? 'no durations'
          : '${durations.reduce((a, b) => a < b ? a : b)}-'
              '${durations.reduce((a, b) => a > b ? a : b)} min';
      final status = results.isEmpty ? 'EMPTY' : 'ok';
      if (results.isEmpty) failures++;
      print('${entry.key.padRight(30)} ${entry.value ?? '-'}'
          '\n  $status  ${results.length} videos  $span');
    } catch (e) {
      failures++;
      print('${entry.key.padRight(30)} THREW  $e');
    }
  }
  client.close();
  print(failures == 0
      ? '\nRESULT: every filter combination returned videos.'
      : '\nRESULT: $failures combination(s) failed.');
}
