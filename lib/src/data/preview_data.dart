import 'models.dart';

/// Sample rows used **only** in the web UI preview.
///
/// `youtube_explode_dart` does not run under dart2js (it throws
/// `NoSuchMethodError: 'getT'`), so a browser build has no way to reach
/// YouTube. Rather than showing an empty error state, the preview renders real
/// video ids — thumbnails load fine, since `<img>` is not CORS-restricted — so
/// the layout can be reviewed with realistic content.
///
/// None of this is reachable on iOS or Android.
const previewVideos = <VideoBrief>[
  VideoBrief(
    id: 'dQw4w9WgXcQ',
    title: 'Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)',
    author: 'Rick Astley',
    channelId: 'UCuAXFkgsw1L7xaCfnd5JJOw',
    duration: Duration(minutes: 3, seconds: 33),
    viewCount: 1802579945,
    uploadRaw: '16 years ago',
  ),
  VideoBrief(
    id: 'aqz-KE-bpKQ',
    title: 'Big Buck Bunny',
    author: 'Blender Foundation',
    channelId: 'UCSMOQeBJ2RAnuFungnQOxLg',
    duration: Duration(minutes: 10, seconds: 34),
    viewCount: 8420000,
    uploadRaw: '11 years ago',
  ),
  VideoBrief(
    id: 'kJQP7kiw5Fk',
    title: 'Luis Fonsi - Despacito ft. Daddy Yankee',
    author: 'Luis Fonsi',
    channelId: 'UCxoq-PAQeAdk_zyg8YS0JqA',
    duration: Duration(minutes: 4, seconds: 42),
    viewCount: 8600000000,
    uploadRaw: '8 years ago',
  ),
  VideoBrief(
    id: 'jNQXAC9IVRw',
    title: 'Me at the zoo',
    author: 'jawed',
    channelId: 'UC4QobU6STFB0P71PMvOGN5A',
    duration: Duration(seconds: 19),
    viewCount: 352000000,
    uploadRaw: '20 years ago',
  ),
  VideoBrief(
    id: '9bZkp7q19f0',
    title: 'PSY - GANGNAM STYLE(강남스타일) M/V',
    author: 'officialpsy',
    channelId: 'UCrDkAvwZum-UTjHmzDI2iIw',
    duration: Duration(minutes: 4, seconds: 13),
    viewCount: 5300000000,
    uploadRaw: '13 years ago',
  ),
  VideoBrief(
    id: 'fJ9rUzIMcZQ',
    title: 'Queen – Bohemian Rhapsody (Official Video Remastered)',
    author: 'Queen Official',
    channelId: 'UCiMhD4jzUqG-IgPzUmmytRQ',
    duration: Duration(minutes: 5, seconds: 59),
    viewCount: 1700000000,
    uploadRaw: '17 years ago',
  ),
  VideoBrief(
    id: 'ZZ5LpwO-An4',
    title: 'HEYYEYAAEYAAAEYAEYAA',
    author: 'CatFarts',
    channelId: 'UCLA7Ttr_zSSpUQOlbRC9SmA',
    duration: Duration(minutes: 2, seconds: 3),
    viewCount: 128000000,
    uploadRaw: '18 years ago',
  ),
  VideoBrief(
    id: '60ItHLz5WEA',
    title: 'Alan Walker - Faded',
    author: 'Alan Walker',
    channelId: 'UCJrOtniJ0-NWz37R30urifQ',
    duration: Duration(minutes: 3, seconds: 32),
    viewCount: 3900000000,
    uploadRaw: '10 years ago',
  ),
];
