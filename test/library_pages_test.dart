// Pure tests for the Subscriptions, You, channel, playlist and comments
// work: the response parsers (each fixture is the shape measured against
// live YouTube in November 2026 by tool/check_channel_header.dart, trimmed
// to the fields read), the comment timestamp splitter, and the
// subscription batching and filters. No network, no device.
import 'package:ai_bit/src/data/browse_client.dart';
import 'package:ai_bit/src/data/comments_client.dart';
import 'package:ai_bit/src/data/models.dart';
import 'package:ai_bit/src/data/subscription_activity.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _text(String s) => {'content': s};

Map<String, dynamic> _part(String s) => {'text': _text(s)};

Map<String, dynamic> _tab(String title, String params) => {
  'tabRenderer': {
    'title': title,
    'endpoint': {
      'browseEndpoint': {'browseId': 'UCx', 'params': params},
    },
  },
};

Map<String, dynamic> _cont(String token) => {
  'continuationItemRenderer': {
    'continuationEndpoint': {
      'continuationCommand': {'token': token},
    },
  },
};

Map<String, dynamic> _channelJson({
  List<List<String>> rows = const [
    ['@mkbhd'],
    ['21.5M subscribers', '1.8K videos'],
  ],
}) => {
  'header': {
    'pageHeaderRenderer': {
      'content': {
        'pageHeaderViewModel': {
          'title': {
            'dynamicTextViewModel': {'text': _text('Marques Brownlee')},
          },
          'image': {
            'decoratedAvatarViewModel': {
              'avatar': {
                'avatarViewModel': {
                  'image': {
                    'sources': [
                      {'url': 'https://yt3/a=s72', 'width': 72},
                      {'url': 'https://yt3/a=s160', 'width': 160},
                    ],
                  },
                },
              },
            },
          },
          'banner': {
            'imageBannerViewModel': {
              'image': {
                'sources': [
                  {'url': 'https://yt3/b=w1060', 'width': 1060},
                  {'url': 'https://yt3/b=w1138', 'width': 1138},
                  {'url': 'https://yt3/b=w1707', 'width': 1707},
                  {'url': 'https://yt3/b=w2560', 'width': 2560},
                ],
              },
            },
          },
          'metadata': {
            'contentMetadataViewModel': {
              'metadataRows': [
                for (final row in rows)
                  {'metadataParts': [for (final p in row) _part(p)]},
              ],
            },
          },
          'description': {
            'descriptionPreviewViewModel': {
              'description': _text('Quality Tech Videos'),
              'truncationText': _text('...more'),
              'rendererContext': {
                'commandContext': {
                  'onTap': {
                    'innertubeCommand': {
                      'showEngagementPanelEndpoint': {
                        'engagementPanel': {
                          'content': _cont('ABOUT-TOKEN'),
                        },
                      },
                    },
                  },
                },
              },
            },
          },
          'attribution': {
            'attributionViewModel': {
              'text': _text(' X'),
              'suffix': _text('and 4 more links'),
            },
          },
        },
      },
    },
  },
  'contents': {
    'twoColumnBrowseResultsRenderer': {
      'tabs': [
        _tab('Home', 'EghmZWF0dXJlZPIGBAoCMgA%3D'),
        _tab('Videos', 'EgZ2aWRlb3PyBgQKAjoA'),
        _tab('Shorts', 'EgZzaG9ydHPyBgUKA5oBAA%3D%3D'),
        _tab('Playlists', 'EglwbGF5bGlzdHPyBgoKCEIGCgIQaCIA'),
      ],
    },
  },
};

void main() {
  group('channel header', () {
    test('reads every field of the modern header', () {
      final info = YoutubeBrowseClient.parseChannelHeader(_channelJson(), 'UCx');
      expect(info.title, 'Marques Brownlee');
      expect(info.handle, '@mkbhd');
      expect(info.subscriberLabel, '21.5M subscribers');
      expect(info.videoCountLabel, '1.8K videos');
      expect(info.avatarUrl, 'https://yt3/a=s160');
      expect(info.description, 'Quality Tech Videos');
      expect(info.aboutToken, 'ABOUT-TOKEN');
      expect(info.linkLabel, 'X and 4 more links');
    });

    test('takes the banner nearest 1280 wide, not the 2560 one', () {
      final info = YoutubeBrowseClient.parseChannelHeader(_channelJson(), 'UCx');
      expect(info.bannerUrl, 'https://yt3/b=w1138');
    });

    test('tells the counts apart by position when not in English', () {
      final info = YoutubeBrowseClient.parseChannelHeader(
        _channelJson(rows: [
          ['@mkbhd'],
          ['2.15 करोड़ सदस्य', '1.8 हज़ार वीडियो'],
        ]),
        'UCx',
      );
      expect(info.subscriberLabel, '2.15 करोड़ सदस्य');
      expect(info.videoCountLabel, '1.8 हज़ार वीडियो');
      expect(info.handle, '@mkbhd');
    });

    test('the legacy header keeps its handle instead of dropping it', () {
      final info = YoutubeBrowseClient.parseChannelHeader({
        'header': {
          'c4TabbedHeaderRenderer': {
            'title': 'Old Channel',
            'subscriberCountText': {'simpleText': '1K subscribers'},
            'videosCountText': {
              'runs': [
                {'text': '12'},
                {'text': ' videos'},
              ],
            },
            'channelHandleText': {
              'runs': [
                {'text': '@old'},
              ],
            },
          },
        },
      }, 'UCo');
      expect(info.title, 'Old Channel');
      expect(info.handle, '@old');
      expect(info.subscriberLabel, '1K subscribers');
      expect(info.videoCountLabel, '12 videos');
      expect(info.tabs, isNull);
    });

    test('tabs are read from params, not translated titles', () {
      final tabs = YoutubeBrowseClient.channelTabsOf(_channelJson());
      expect(tabs, {'featured', 'videos', 'shorts', 'playlists'});
      expect(tabs!.contains('streams'), isFalse);
    });
  });

  group('channel about', () {
    test('reads the facts and unwraps redirect links', () {
      final about = YoutubeBrowseClient.parseChannelAbout({
        'onResponseReceivedEndpoints': [
          {
            'aboutChannelViewModel': {
              'description': 'Long description\n\nNYC',
              'country': 'United States',
              'subscriberCountText': '21.5M subscribers',
              'viewCountText': '5,924,012,702 views',
              'joinedDateText': _text('Joined Mar 21, 2008'),
              'videoCountText': '1,869 videos',
              'canonicalChannelUrl': 'http://www.youtube.com/@mkbhd',
              'links': [
                {
                  'channelExternalLinkViewModel': {
                    'title': _text('Twitter'),
                    'link': {
                      'content': 'twitter.com/MKBHD',
                      'commandRuns': [
                        {
                          'onTap': {
                            'innertubeCommand': {
                              'urlEndpoint': {
                                'url': 'https://www.youtube.com/redirect?event=x'
                                    '&q=http%3A%2F%2Ftwitter.com%2FMKBHD',
                              },
                            },
                          },
                        },
                      ],
                    },
                  },
                },
              ],
            },
          },
        ],
      });
      expect(about, isNotNull);
      expect(about!.joinedText, 'Joined Mar 21, 2008');
      expect(about.country, 'United States');
      expect(about.viewCountText, '5,924,012,702 views');
      expect(about.links.single.title, 'Twitter');
      expect(about.links.single.url, 'http://twitter.com/MKBHD');
    });

    test('a plain link passes through unwrapRedirect', () {
      expect(
        YoutubeBrowseClient.unwrapRedirect('https://example.com/a?q=1'),
        'https://example.com/a?q=1',
      );
    });
  });

  group('channel tab paging', () {
    test('the next page comes from contents, never the header', () {
      // The header carries About-panel continuations of the same shape.
      final json = {
        'header': _cont('HEADER-ABOUT'),
        'contents': {
          'richGridRenderer': {
            'contents': [
              {'richItemRenderer': {}},
              _cont('PAGE-2'),
            ],
          },
        },
      };
      expect(YoutubeBrowseClient.listContinuation(json), 'PAGE-2');
    });

    test('a playlist page token in continuationItemViewModel is found', () {
      final json = {
        'onResponseReceivedActions': [
          {
            'appendContinuationItemsAction': {
              'continuationItems': [
                {
                  'continuationItemViewModel': {
                    'continuationCommand': {
                      'innertubeCommand': {
                        'continuationCommand': {'token': 'PL-PAGE-2'},
                      },
                    },
                  },
                },
              ],
            },
          },
        ],
      };
      expect(YoutubeBrowseClient.listContinuation(json), 'PL-PAGE-2');
    });

    test('sort chips keep order, label and selection', () {
      Map<String, dynamic> chip(String label, String token, bool selected) => {
        'chipViewModel': {
          'text': label,
          'selected': selected,
          'tapCommand': {
            'innertubeCommand': {
              'continuationCommand': {'token': token},
            },
          },
        },
      };
      final sorts = YoutubeBrowseClient.sortChipsOf({
        'chipBarViewModel': {
          'chips': [
            chip('Latest', 'T1', true),
            chip('Popular', 'T2', false),
            chip('Oldest', 'T3', false),
          ],
        },
      });
      expect(sorts.map((s) => s.label), ['Latest', 'Popular', 'Oldest']);
      expect(sorts.map((s) => s.token), ['T1', 'T2', 'T3']);
      expect(sorts.first.selected, isTrue);
    });
  });

  group('playlist header', () {
    test('reads owner, counts, views and cover', () {
      final p = YoutubeBrowseClient.parsePlaylistHeader({
        'header': {
          'pageHeaderRenderer': {
            'content': {
              'pageHeaderViewModel': {
                'title': {
                  'dynamicTextViewModel': {'text': _text('Retro Tech')},
                },
                'metadata': {
                  'contentMetadataViewModel': {
                    'metadataRows': [
                      {
                        'metadataParts': [
                          {
                            'avatarStack': {
                              'avatarStackViewModel': {
                                'text': {
                                  'content': 'by Marques Brownlee',
                                  'commandRuns': [
                                    {
                                      'onTap': {
                                        'innertubeCommand': {
                                          'browseEndpoint': {
                                            'browseId': 'UCBJycsmduvYEL83R_U4JriQ',
                                          },
                                        },
                                      },
                                    },
                                  ],
                                },
                              },
                            },
                          },
                        ],
                      },
                      {
                        'metadataParts': [
                          _part('Playlist'),
                          _part('11 videos'),
                          _part('737,170 views'),
                        ],
                      },
                    ],
                  },
                },
                'heroImage': {
                  'contentPreviewImageViewModel': {
                    'image': {
                      'sources': [
                        {'url': 'https://i.ytimg.com/vi/x/small.jpg'},
                        {'url': 'https://i.ytimg.com/vi/x/big.jpg'},
                      ],
                    },
                  },
                },
              },
            },
          },
        },
      }, 'PLx');
      expect(p.title, 'Retro Tech');
      expect(p.author, 'Marques Brownlee');
      expect(p.channelId, 'UCBJycsmduvYEL83R_U4JriQ');
      expect(p.videoCount, 11);
      expect(p.viewCountLabel, '737,170 views');
      expect(p.thumbnailUrl, 'https://i.ytimg.com/vi/x/big.jpg');
    });

    test('a saved playlist round-trips through JSON', () {
      const p = PlaylistBrief(
        id: 'PLx',
        title: 'Retro Tech',
        videoCount: 11,
        thumbnailUrl: 'https://t',
        author: 'MKBHD',
      );
      final back = PlaylistBrief.fromJson(p.toJson())!;
      expect(back.id, 'PLx');
      expect(back.title, 'Retro Tech');
      expect(back.videoCount, 11);
      expect(back.author, 'MKBHD');
      expect(PlaylistBrief.fromJson({'title': 'no id'}), isNull);
    });
  });

  group('comment page', () {
    Map<String, dynamic> payload(
      String key,
      String text, {
      String? replies,
      String like = '5',
      bool creator = false,
    }) => {
      'commentEntityPayload': {
        'key': key,
        'properties': {
          'content': {'content': text},
          'publishedTime': '2 days ago',
          'toolbarStateKey': 'S-$key',
        },
        'author': {'displayName': '@$key', 'isCreator': creator},
        'toolbar': {
          'likeCountNotliked': like,
          'replyCount': ?replies,
          'creatorThumbnailUrl': 'https://yt3/creator',
        },
      },
    };

    Map<String, dynamic> thread(String key, {String? repliesToken, String? pinned}) => {
      'commentThreadRenderer': {
        'commentViewModel': {
          'commentViewModel': {
            'commentKey': key,
            'toolbarStateKey': 'S-$key',
            'pinnedText': ?pinned,
          },
        },
        if (repliesToken != null)
          'replies': {
            'commentRepliesRenderer': {
              'contents': [_cont(repliesToken)],
            },
          },
      },
    };

    final page = {
      'onResponseReceivedEndpoints': [
        {
          'reloadContinuationItemsCommand': {
            'continuationItems': [
              thread('A', pinned: 'Pinned by @creator'),
              thread('B', repliesToken: 'REPLIES-B'),
              thread('C'),
              thread('D', repliesToken: 'REPLIES-D'),
              _cont('NEXT-PAGE'),
            ],
          },
        },
      ],
      'frameworkUpdates': {
        'entityBatchUpdate': {
          'mutations': [
            {'payload': payload('A', 'pinned one', creator: true)},
            {'payload': payload('B', 'has replies', replies: '13')},
            {'payload': payload('C', 'no likes', like: '')},
            {'payload': payload('D', 'also replies', replies: '2')},
            {
              'payload': {
                'engagementToolbarStateEntityPayload': {
                  'key': 'S-D',
                  'heartState': 'TOOLBAR_HEART_STATE_HEARTED',
                },
              },
            },
            {
              'payload': {
                'engagementToolbarStateEntityPayload': {
                  'key': 'S-A',
                  'heartState': 'TOOLBAR_HEART_STATE_UNHEARTED',
                },
              },
            },
          ],
        },
      },
    };

    test('reply tokens belong to their own thread', () {
      // The old pairing was by position: C (no replies) before D shifted
      // D onto nothing and B onto the wrong thread.
      final parsed = YoutubeCommentsClient.parseCommentPage(page);
      expect(parsed.comments.map((c) => c.text), [
        'pinned one',
        'has replies',
        'no likes',
        'also replies',
      ]);
      expect(parsed.comments[1].repliesToken, 'REPLIES-B');
      expect(parsed.comments[2].repliesToken, isNull);
      expect(parsed.comments[3].repliesToken, 'REPLIES-D');
    });

    test('the next page is not a reply thread token', () {
      final parsed = YoutubeCommentsClient.parseCommentPage(page);
      expect(parsed.continuation, 'NEXT-PAGE');
    });

    test('pinned, creator, heart and an empty like count', () {
      final c = YoutubeCommentsClient.parseCommentPage(page).comments;
      expect(c[0].pinnedText, 'Pinned by @creator');
      expect(c[0].isPinned, isTrue);
      expect(c[0].isCreator, isTrue);
      expect(c[0].isHearted, isFalse);
      expect(c[3].isHearted, isTrue);
      expect(c[3].heartAvatarUrl, 'https://yt3/creator');
      expect(c[2].likeLabel, isNull);
      expect(c[1].likeLabel, '5');
      expect(c[1].replyCount, 13);
    });

    test('a replies page reads view models and its Show more token', () {
      final replies = YoutubeCommentsClient.parseCommentPage({
        'onResponseReceivedEndpoints': [
          {
            'appendContinuationItemsAction': {
              'continuationItems': [
                {
                  'commentViewModel': {'commentKey': 'R1'},
                },
                {
                  'commentViewModel': {'commentKey': 'R2'},
                },
                {
                  'continuationItemRenderer': {
                    'button': {
                      'buttonRenderer': {
                        'text': {
                          'runs': [
                            {'text': 'Show more replies'},
                          ],
                        },
                        'command': {
                          'continuationCommand': {'token': 'MORE-REPLIES'},
                        },
                      },
                    },
                  },
                },
              ],
            },
          },
        ],
        'frameworkUpdates': {
          'entityBatchUpdate': {
            'mutations': [
              {'payload': payload('R2', 'second')},
              {'payload': payload('R1', 'first')},
            ],
          },
        },
      });
      // Document order of the view models, not of the payloads.
      expect(replies.comments.map((c) => c.text), ['first', 'second']);
      expect(replies.continuation, 'MORE-REPLIES');
    });

    test('sort menu and count come from the watch response', () {
      final json = {
        'engagementPanels': [
          {
            'engagementPanelSectionListRenderer': {
              'panelIdentifier': 'engagement-panel-comments-section',
              'header': {
                'engagementPanelTitleHeaderRenderer': {
                  'contextualInfo': {
                    'runs': [
                      {'text': '6.3K'},
                    ],
                  },
                  'menu': {
                    'sortFilterSubMenuRenderer': {
                      'subMenuItems': [
                        {
                          'title': 'Top',
                          'selected': true,
                          'serviceEndpoint': {
                            'continuationCommand': {'token': 'TOP'},
                          },
                        },
                        {
                          'title': 'Newest',
                          'selected': false,
                          'serviceEndpoint': {
                            'continuationCommand': {'token': 'NEW'},
                          },
                        },
                      ],
                    },
                  },
                },
              },
            },
          },
        ],
      };
      final sorts = YoutubeCommentsClient.commentSortsOf(json);
      expect(sorts.map((s) => s.label), ['Top', 'Newest']);
      expect(sorts.map((s) => s.token), ['TOP', 'NEW']);
      expect(sorts.first.selected, isTrue);
      expect(YoutubeCommentsClient.commentCountOf(json), '6.3K');
    });
  });

  group('comment timestamps', () {
    List<Duration?> seeks(String s) =>
        splitCommentTimestamps(s).map((x) => x.seekTo).whereType<Duration>().toList();

    test('minutes:seconds and hours:minutes:seconds', () {
      expect(seeks('best part at 1:23 and 12:05'), [
        const Duration(minutes: 1, seconds: 23),
        const Duration(minutes: 12, seconds: 5),
      ]);
      expect(seeks('1:02:03 is wild'), [
        const Duration(hours: 1, minutes: 2, seconds: 3),
      ]);
    });

    test('text around timestamps is kept exactly', () {
      final spans = splitCommentTimestamps('at 0:45, lol');
      expect(spans.map((s) => s.text).join(), 'at 0:45, lol');
      expect(spans.map((s) => s.text), ['at ', '0:45', ', lol']);
    });

    test('things that are not timestamps', () {
      expect(seeks('shot in 16:9'), isEmpty);
      expect(seeks('see you at 10:30pm'), isEmpty);
      expect(seeks('1:75 is no second'), isEmpty);
      expect(seeks('1:70:00 is no minute'), isEmpty);
      expect(seeks('dated 2024:11:05'), isEmpty);
      expect(seeks('ratio 3:4:5:6'), isEmpty);
    });

    test('a timestamp at the very start and end', () {
      expect(seeks('2:00'), [const Duration(minutes: 2)]);
      expect(splitCommentTimestamps('2:00').single.text, '2:00');
    });
  });

  group('subscription batches', () {
    final channels = [
      for (var i = 0; i < 40; i++) ChannelInfo(id: 'c$i', title: 'C$i'),
    ];

    test('every channel is reachable, exactly once', () {
      // The defect: only the first fifteen alphabetically were ever fetched.
      for (final rotation in [0, 1, 7]) {
        final batches = subscriptionBatches(channels, const {}, rotation: rotation);
        final ids = [for (final b in batches) ...b.map((c) => c.id)];
        expect(ids.length, 40);
        expect(ids.toSet().length, 40);
        expect(batches.every((b) => b.length <= 15), isTrue);
      }
    });

    test('the most recently active channels come first', () {
      final latest = {'c39': 300, 'c20': 200, 'c5': 100};
      final first = subscriptionBatches(channels, latest).first;
      expect(first.take(3).map((c) => c.id), ['c39', 'c20', 'c5']);
    });

    test('refreshing rotates the quiet channels into the first batch', () {
      final a = subscriptionBatches(channels, const {}, rotation: 0).first;
      final b = subscriptionBatches(channels, const {}, rotation: 1).first;
      expect(a.take(10).map((c) => c.id), b.take(10).map((c) => c.id));
      expect(a.skip(10).map((c) => c.id), isNot(b.skip(10).map((c) => c.id)));
    });

    test('fewer channels than a batch is one batch', () {
      final few = channels.take(4).toList();
      expect(subscriptionBatches(few, const {}).single.length, 4);
      expect(subscriptionBatches(const [], const {}), isEmpty);
    });

    test('orderByActivity keeps undated channels in their order', () {
      final ordered = orderByActivity(channels.take(4).toList(), {'c2': 5});
      expect(ordered.map((c) => c.id), ['c2', 'c0', 'c1', 'c3']);
    });
  });

  group('subscription activity', () {
    VideoBrief upload(String id, String age) =>
        VideoBrief(id: id, title: id, author: 'a', channelId: 'c', uploadRaw: age);

    test('a first look is seen; a new upload is not; looking clears it', () {
      final a = SubscriptionActivity.memory();
      final now = DateTime(2026, 11, 27, 12);
      a.recordUploads('c', [upload('v1', '2 days ago')], now);
      expect(a.hasUnseen('c'), isFalse);
      a.recordUploads('c', [upload('v2', '1 hour ago'), upload('v1', '2 days ago')], now);
      expect(a.hasUnseen('c'), isTrue);
      a.markViewed('c');
      expect(a.hasUnseen('c'), isFalse);
    });

    test('the same upload keeps its earlier, more precise time', () {
      final a = SubscriptionActivity.memory();
      final t0 = DateTime(2026, 11, 27, 12);
      a.recordUploads('c', [upload('v1', '23 hours ago')], t0);
      final first = a.latestUploads['c']!;
      // An hour later YouTube says "1 day ago", which reads as later.
      a.recordUploads('c', [upload('v1', '1 day ago')], t0.add(const Duration(hours: 1)));
      expect(a.latestUploads['c'], first);
    });
  });

  group('subscription filters', () {
    VideoBrief v(String id, {String? age, bool short = false}) => VideoBrief(
      id: id,
      title: id,
      author: 'a',
      channelId: 'c',
      uploadRaw: age,
      isShort: short,
    );
    int? age(VideoBrief x) => x.uploadRaw == '1h' ? 3600 : (x.uploadRaw == null ? null : 999999);
    final feed = [v('new', age: '1h'), v('old', age: 'x'), v('s', short: true)];

    test('each chip keeps what it says', () {
      List<String> f(SubsFilter filter) => filterSubscriptionFeed(
        feed,
        filter,
        progress: const {'old': 0.5, 'new': 0.97},
        watched: const {'old', 'new'},
        ageSeconds: age,
      ).map((x) => x.id).toList();
      expect(f(SubsFilter.all), ['new', 'old']);
      expect(f(SubsFilter.shorts), ['s']);
      expect(f(SubsFilter.today), ['new']);
      expect(f(SubsFilter.continueWatching), ['old']);
      expect(f(SubsFilter.unwatched), isEmpty);
    });
  });
}
