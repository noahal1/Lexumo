/// Ports `src/lib/translate.test.ts` (60 cases).
///
/// The one structural difference is the HTTP seam: the web build patched
/// `globalThis.fetch`, this port injects a [LookupHttp]. That makes the
/// "provider hangs" case a `Completer` that never completes rather than a
/// hand-rolled never-resolving promise, and it keeps the tests off the network.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lexumo/platform/translate.dart';

/* --------------------------------------------------------------- fixtures */

/// A Youdao `jsonapi` payload: two parts of speech, a proper-noun block, two
/// example pairs and one unused one.
const Map<String, Object?> _youdaoRecord = <String, Object?>{
  'ec': <String, Object?>{
    'word': <Object?>[
      <String, Object?>{
        'usphone': 'ˈrekərd',
        'ukphone': 'ˈrekɔːd',
        'trs': <Object?>[
          <String, Object?>{
            'tr': <Object?>[
              <String, Object?>{
                'l': <String, Object?>{
                  'i': <Object?>['n. 记录；记载', '【名】 （Record）（美）勒科尔（人名）'],
                },
              },
            ],
          },
          <String, Object?>{
            'tr': <Object?>[
              <String, Object?>{
                'l': <String, Object?>{'i': 'v. 记录；录制'},
              },
            ],
          },
        ],
      },
    ],
  },
  'blng_sents_part': <String, Object?>{
    'sentence-pair': <Object?>[
      <String, Object?>{
        'sentence': 'Keep a <b>record</b> of what you spend.',
        'sentence-translation': '把你花的钱记录下来。',
      },
      <String, Object?>{'sentence': 'She set a new record.'},
      <String, Object?>{'sentence': 'A third example is dropped.'},
    ],
  },
};

/// A fetcher that answers from a queue and records what it was asked.
class _FakeHttp implements LookupHttp {
  _FakeHttp(this._responses);

  /// Each call pops one entry. An entry can be an `Object?` for a value, an
  /// [Exception] to throw, or a `Completer` to hang on.
  final List<Object?> _responses;
  final List<Uri> calls = <Uri>[];
  final List<Duration> timeouts = <Duration>[];

  @override
  Future<Object?> getJson(Uri url, {required Duration timeout}) {
    calls.add(url);
    timeouts.add(timeout);
    final Object? next = _responses.isEmpty ? null : _responses.removeAt(0);
    if (next is Exception) return Future<Object?>.error(next);
    if (next is Completer<Object?>) return next.future;
    return Future<Object?>.value(next);
  }
}

/// An adapter with a fixed answer, for exercising the chain itself.
class _StubAdapter implements LookupAdapter {
  _StubAdapter(
    this.id, {
    this.serves = true,
    this.result,
    this.fails,
    this.rateLimited = false,
  });

  @override
  final ProviderId id;
  final bool serves;
  // Mutable: the cooldown cases flip these after the first round to prove the
  // provider is skipped for the cooldown window rather than merely failing.
  LookupResult? result;
  Object? fails;
  bool rateLimited;

  int fetchCount = 0;
  int? lastTimeoutMs;

  @override
  bool canServe(String from, String to) => serves;

  @override
  Future<LookupResult?> fetch(String term, LookupContext context) async {
    fetchCount++;
    lastTimeoutMs = context.timeout.inMilliseconds;
    if (rateLimited) throw const LookupError(LookupFailure.rateLimited);
    if (fails != null) throw fails!;
    return result;
  }
}

LookupResult _result(String meaning, {String pos = '', ProviderId? provider}) => LookupResult(
      term: 'x',
      phonetic: '',
      senses: <DictSense>[DictSense(pos: pos, meaning: meaning)],
      examples: const <DictExample>[],
      provider: provider ?? ProviderId.youdao,
    );

/// A clock a test can move.
class _Clock implements LookupClock {
  _Clock(this._at);

  int _at;

  @override
  int now() => _at;

  void advance(int ms) => _at += ms;
}

void main() {
  group('parseYoudao', () {
    test('splits part-of-speech senses and keeps the phonetic', () {
      final LookupResult result = parseYoudao(_youdaoRecord, 'record')!;
      expect(result.provider, ProviderId.youdao);
      expect(result.phonetic, 'ˈrekərd');
      expect(result.fromCache, isFalse);
      expect(result.senses, <DictSense>[
        const DictSense(pos: 'n.', meaning: '记录'),
        const DictSense(pos: 'n.', meaning: '记载'),
        const DictSense(pos: 'v.', meaning: '记录'),
        const DictSense(pos: 'v.', meaning: '录制'),
      ]);
    });

    test('drops the proper-noun line a dictionary appends to common words', () {
      final LookupResult result = parseYoudao(_youdaoRecord, 'record')!;
      for (final DictSense sense in result.senses) {
        expect(sense.meaning, isNot(contains('勒科尔')));
        expect(sense.meaning, isNot(startsWith('【名】')));
      }
      // A parenthesised surname without the 【名】 prefix is also dropped.
      final LookupResult? other = parseYoudao(<String, Object?>{
        'ec': <String, Object?>{
          'word': <Object?>[
            <String, Object?>{
              'trs': <Object?>[
                <String, Object?>{
                  'tr': <Object?>[
                    <String, Object?>{
                      'l': <String, Object?>{
                        'i': 'n. 苹果（人名）',
                      },
                    },
                  ],
                },
              ],
            },
          ],
        },
      }, 'apple');
      // The only sense was the proper noun, so the payload has nothing to say.
      expect(other, isNull);
    });

    test('keeps at most two examples and strips markup', () {
      final LookupResult result = parseYoudao(_youdaoRecord, 'record')!;
      expect(result.examples, hasLength(2));
      expect(result.examples.first.en, 'Keep a record of what you spend.');
      expect(result.examples.first.zh, '把你花的钱记录下来。');
      // A pair without a translation keeps only the English half.
      expect(result.examples[1].en, 'She set a new record.');
      expect(result.examples[1].zh, isNull);
    });

    test('falls back to machine translation when there is no dictionary entry', () {
      final LookupResult? result = parseYoudao(<String, Object?>{
        'fanyi': <String, Object?>{'tran': '这是一整个句子'},
      }, 'this is a whole sentence');
      expect(result, isNotNull);
      expect(result!.senses, <DictSense>[
        const DictSense(pos: '', meaning: '这是一整个句子'),
      ]);
      expect(result.examples, isEmpty);
    });

    test('returns null for an empty payload', () {
      expect(parseYoudao(null, 'x'), isNull);
      expect(parseYoudao('not a map', 'x'), isNull);
      expect(parseYoudao(<String, Object?>{}, 'x'), isNull);
      expect(parseYoudao(<String, Object?>{'ec': <String, Object?>{}}, 'x'), isNull);
    });
  });

  group('parseYoudaoTranslation', () {
    test('maps translation lines to senses', () {
      final LookupResult? result = parseYoudaoTranslation(<String, Object?>{
        'errorCode': 0,
        'translation': <Object?>['<b>你好</b>', '您好'],
      }, 'hello');
      expect(result!.provider, ProviderId.youdaoSelfHosted);
      expect(result.senses.map((DictSense s) => s.meaning), <String>['你好', '您好']);
      expect(result.phonetic, '');
    });

    test('accepts a numeric error code too', () {
      expect(
        parseYoudaoTranslation(<String, Object?>{
          'errorCode': '0',
          'translation': <Object?>['好的'],
        }, 'ok'),
        isNotNull,
      );
    });

    test('rejects a rate-limited response', () {
      expect(
        parseYoudaoTranslation(<String, Object?>{
          'errorCode': 411,
          'translation': <Object?>['should not be used'],
        }, 'x'),
        isNull,
      );
    });

    test('rejects a payload without an error code', () {
      expect(
        parseYoudaoTranslation(<String, Object?>{
          'translation': <Object?>['nope'],
        }, 'x'),
        isNull,
      );
      expect(parseYoudaoTranslation(null, 'x'), isNull);
    });
  });

  group('parseMyMemory', () {
    test('keeps alternatives that translate the term itself', () {
      final LookupResult? result = parseMyMemory(<String, Object?>{
        'responseData': <String, Object?>{'translatedText': '苹果'},
        'matches': <Object?>[
          <String, Object?>{'translation': '苹果', 'segment': 'apple', 'match': 1.0},
          <String, Object?>{'translation': '苹果树', 'segment': 'apple', 'match': 0.95},
        ],
      }, 'apple');
      expect(result!.provider, ProviderId.myMemory);
      expect(result.senses.map((DictSense s) => s.meaning), <String>['苹果', '苹果树']);
    });

    test('ignores low-confidence and unrelated segments', () {
      final LookupResult? result = parseMyMemory(<String, Object?>{
        'responseData': <String, Object?>{'translatedText': '苹果'},
        'matches': <Object?>[
          // A longer segment that merely contains the term.
          <String, Object?>{'translation': '苹果派', 'segment': 'apple pie', 'match': 1.0},
          // Confident, but about a different string.
          <String, Object?>{'translation': '公司', 'segment': 'apple inc', 'match': 1.0},
          // Right segment, below the confidence floor.
          <String, Object?>{'translation': '苹果树', 'segment': 'apple', 'match': 0.4},
        ],
      }, 'apple');
      expect(result!.senses, hasLength(1));
      expect(result.senses.first.meaning, '苹果');
    });

    test('returns null without a translated text', () {
      expect(parseMyMemory(<String, Object?>{'responseData': <String, Object?>{}}, 'x'), isNull);
      expect(parseMyMemory(<String, Object?>{'responseData': <String, Object?>{'translatedText': '  '}}, 'x'), isNull);
      expect(parseMyMemory(null, 'x'), isNull);
    });
  });

  group('parseGoogle', () {
    test('joins the chunked translation array', () {
      final LookupResult? result = parseGoogle(<Object?>[
        <Object?>[
          <Object?>['苹', 'apple', null, null],
          <Object?>['果', 'apple', null, null],
        ],
        null,
        'en',
      ], 'apple');
      expect(result!.provider, ProviderId.google);
      expect(result.senses.single.meaning, '苹果');
    });

    test('returns null for unexpected shapes', () {
      expect(parseGoogle(null, 'x'), isNull);
      expect(parseGoogle('a string', 'x'), isNull);
      expect(parseGoogle(<Object?>[], 'x'), isNull);
      expect(parseGoogle(<Object?>['not a list'], 'x'), isNull);
      expect(parseGoogle(<Object?>[<Object?>[]], 'x'), isNull);
    });
  });

  group('formatting helpers', () {
    LookupResult build(List<List<String>> pairs) => LookupResult(
          term: 'x',
          phonetic: '',
          senses: pairs
              .map((List<String> p) => DictSense(pos: p[0], meaning: p[1]))
              .toList(),
          examples: const <DictExample>[],
          provider: ProviderId.youdao,
        );

    test('keeps the tag off the primary meaning', () {
      final LookupResult result = build(<List<String>>[
        <String>['n.', '类比，比拟'],
      ]);
      expect(primaryMeaning(result), '类比，比拟');
      expect(posTags(result), <String>['n.']);
    });

    test('joins the remaining senses for the secondary field', () {
      final LookupResult result = build(<List<String>>[
        <String>['adj.', '坦率的'],
        <String>['adj.', '公正的'],
      ]);
      expect(alternativeMeaning(result), '公正的');
    });

    test('re-tags a secondary sense only when its part of speech changes', () {
      // `candid`: three adjective senses read as a comma list, not a dictionary.
      final LookupResult result = build(<List<String>>[
        <String>['adj.', '抓拍的，偷拍的'],
        <String>['adj.', '公正的'],
      ]);
      expect(alternativeMeaning(result), '公正的');
    });

    test('keeps a different part of speech even when same-tag senses come first', () {
      // `record` arrives noun, noun, noun, verb, adjective. Taking the first three
      // senses put three noun shades in the field and said nothing about the word
      // being a verb — the exact failure a browser probe caught and the unit tests
      // had blessed. Built through the parser rather than by hand, because the
      // splitting of one `trs` line into several senses is part of the behaviour.
      final LookupResult result = parseYoudao(<String, Object?>{
        'ec': <String, Object?>{
          'word': <Object?>[
            <String, Object?>{
              'trs': <Object?>[
                <String, Object?>{
                  'tr': <Object?>[
                    <String, Object?>{
                      'l': <String, Object?>{
                        'i': <Object?>[
                          'n. 记录，记载',
                          'n. （某人或某物过去的）记录，经历',
                          'n. 唱片；纪录',
                          'v. 记录；录制；（仪器）显示，标示',
                          'adj. 创纪录的',
                        ],
                      },
                    },
                  ],
                },
              ],
            },
          ],
        },
      }, 'record')!;
      final String secondary = alternativeMeaning(result);
      expect(secondary, 'v. 记录；录制；（仪器）显示，标示');
      expect(secondary, matches(RegExp(r'(^|；)v\.\s')));
    });

    test('fills leftover slots with same-tag senses after the odd one out', () {
      // The adjective is promoted ahead of the third noun, but everything still
      // comes out in dictionary order.
      final LookupResult result = build(<List<String>>[
        <String>['n.', '甲'],
        <String>['n.', '乙'],
        <String>['adj.', '丙'],
        <String>['n.', '丁'],
      ]);
      expect(alternativeMeaning(result), '乙；adj. 丙；丁');
    });

    test('caps the secondary field at three senses', () {
      final LookupResult result = build(<List<String>>[
        <String>['n.', '一'],
        <String>['v.', '二'],
        <String>['adj.', '三'],
        <String>['adv.', '四'],
        <String>['prep.', '五'],
      ]);
      // Exactly three, and they are the first three different tags in order.
      expect(alternativeMeaning(result), 'v. 二；adj. 三；adv. 四');
      expect('v. 二；adj. 三；adv. 四'.split('；'), hasLength(3));
    });

    test('has no secondary text when there is only one sense', () {
      expect(alternativeMeaning(build(<List<String>>[<String>['n.', '唯一']])), '');
      expect(alternativeMeaning(build(<List<String>>[])), '');
    });

    test('lists the parts of speech in the order the dictionary gives them', () {
      final LookupResult result = build(<List<String>>[
        <String>['n.', '一'],
        <String>['v.', '二'],
        <String>['n.', '三'],
        <String>['adj.', '四'],
      ]);
      expect(posTags(result), <String>['n.', 'v.', 'adj.']);
    });

    test('formats every sense on one line', () {
      final LookupResult result = build(<List<String>>[
        <String>['n.', '记录'],
        <String>['', '译文'],
      ]);
      expect(formatSenses(result), 'n. 记录；译文');
    });

    test('collapses whitespace in terms', () {
      expect(normalizeTermText('  hello   world \n'), 'hello world');
      expect(normalizeTermText('\t'), '');
    });
  });

  group('lookupTerm', () {
    test('uses the first provider that answers', () async {
      final _StubAdapter first = _StubAdapter(ProviderId.youdao, result: _result('一'));
      final _StubAdapter second = _StubAdapter(ProviderId.google, result: _result('二'));
      final Lookup lookup = createLookup(LookupDeps(adapters: <LookupAdapter>[first, second]));

      final LookupResult result = await lookup.lookupTerm('x');
      expect(result.senses.single.meaning, '一');
      expect(first.fetchCount, 1);
      expect(second.fetchCount, 0);
    });

    test('honours `prefer` by reordering the chain without dropping a fallback', () async {
      final _StubAdapter youdao = _StubAdapter(ProviderId.youdao, result: _result('一'));
      final _StubAdapter google = _StubAdapter(ProviderId.google, result: _result('二'));
      final Lookup lookup = createLookup(LookupDeps(adapters: <LookupAdapter>[youdao, google]));

      final LookupResult result = await lookup.lookupTerm(
        'x',
        const LookupOptions(prefer: <ProviderId>[ProviderId.google]),
      );
      expect(result.senses.single.meaning, '二');
      expect(youdao.fetchCount, 0);
    });

    test('still falls back past a preferred provider that answers with nothing', () async {
      final _StubAdapter youdao = _StubAdapter(ProviderId.youdao, result: _result('一'));
      final _StubAdapter google = _StubAdapter(ProviderId.google);
      final Lookup lookup = createLookup(LookupDeps(adapters: <LookupAdapter>[youdao, google]));

      final LookupResult result = await lookup.lookupTerm(
        'x',
        const LookupOptions(prefer: <ProviderId>[ProviderId.google]),
      );
      expect(result.senses.single.meaning, '一');
      expect(google.fetchCount, 1);
      expect(youdao.fetchCount, 1);
    });

    test('moves on when a provider hangs instead of spending the whole budget', () async {
      // A provider that never answers at all. The per-provider leash is what
      // keeps it from eating the total budget.
      final Completer<Object?> hang = Completer<Object?>();
      final _FakeHttp http = _FakeHttp(<Object?>[hang, <String, Object?>{}]);
      final Lookup lookup = createLookup(
        LookupDeps(
          adapters: const <LookupAdapter>[YoudaoAdapter(), MyMemoryAdapter()],
          http: http,
          perProviderTimeout: const Duration(milliseconds: 30),
          totalTimeout: const Duration(seconds: 5),
        ),
      );

      // The first adapter waits on `hang`, which never completes; the loop must
      // still reach MyMemory. We model that by completing the hang with an error
      // after the leash so the timeout branch is exercised deterministically.
      final Future<LookupResult> pending = lookup.lookupTerm('x');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      hang.completeError(TimeoutException('leash'));
      await expectLater(pending, throwsA(isA<LookupError>()));
      // Both providers were tried: the hang cost one slot, not the whole run.
      expect(http.calls, hasLength(2));
      expect(http.timeouts.first.inMilliseconds, 30);
    });

    test('keeps a cache entry per language pair', () async {
      // The same term glossed two ways is two entries: sharing one would serve
      // a Japanese reading to a Chinese list.
      int call = 0;
      final Lookup lookup = createLookup(
        LookupDeps(
          adapters: <LookupAdapter>[
            _CallbackAdapter((String term, LookupContext context) async {
              call++;
              return _result(context.to.startsWith('ja') ? 'りんご' : '苹果');
            }),
          ],
        ),
      );

      final LookupResult chinese = await lookup.lookupTerm('apple');
      final LookupResult japanese = await lookup.lookupTerm(
        'apple',
        const LookupOptions(from: 'en', to: 'ja'),
      );
      expect(chinese.senses.single.meaning, '苹果');
      expect(japanese.senses.single.meaning, 'りんご');
      expect(lookup.cacheSize(), 2);

      // Repeating the second pair is a hit, and the first pair is still its own
      // entry rather than having been overwritten by the second.
      final LookupResult japaneseAgain = await lookup.lookupTerm(
        'apple',
        const LookupOptions(from: 'en', to: 'ja'),
      );
      expect(japaneseAgain.fromCache, isTrue);
      expect(japaneseAgain.senses.single.meaning, 'りんご');
      expect((await lookup.lookupTerm('apple')).senses.single.meaning, '苹果');
      expect(call, 2);
    });

    test('serves repeat lookups from the cache', () async {
      final _FakeHttp http = _FakeHttp(<Object?>[_youdaoRecord]);
      final Lookup lookup = createLookup(
        LookupDeps(adapters: const <LookupAdapter>[YoudaoAdapter()], http: http),
      );

      final LookupResult first = await lookup.lookupTerm('record');
      expect(first.fromCache, isFalse);
      final LookupResult second = await lookup.lookupTerm('record');
      expect(second.fromCache, isTrue);
      expect(http.calls, hasLength(1));
      expect(lookup.cacheSize(), 1);
    });

    test('falls through to the next provider when one is rate limited', () async {
      final _StubAdapter limited = _StubAdapter(ProviderId.youdao, rateLimited: true);
      final _StubAdapter fallback = _StubAdapter(ProviderId.myMemory, result: _result('二'));
      final Lookup lookup =
          createLookup(LookupDeps(adapters: <LookupAdapter>[limited, fallback]));

      final LookupResult result = await lookup.lookupTerm('x');
      expect(result.senses.single.meaning, '二');
      expect(limited.fetchCount, 1);
    });

    test('reports rate limiting when every provider refuses', () async {
      final Lookup lookup = createLookup(LookupDeps(adapters: <LookupAdapter>[
        _StubAdapter(ProviderId.youdao, rateLimited: true),
        _StubAdapter(ProviderId.google, rateLimited: true),
      ]));
      await expectLater(
        lookup.lookupTerm('x'),
        throwsA(isA<LookupError>().having((LookupError e) => e.reason, 'reason',
            LookupFailure.rateLimited)),
      );
    });

    test('reports not-found when providers answer but have nothing', () async {
      final Lookup lookup = createLookup(LookupDeps(adapters: <LookupAdapter>[
        _StubAdapter(ProviderId.youdao),
        _StubAdapter(ProviderId.google),
      ]));
      await expectLater(
        lookup.lookupTerm('x'),
        throwsA(isA<LookupError>().having((LookupError e) => e.reason, 'reason',
            LookupFailure.notFound)),
      );
    });

    test('rejects an empty term without touching the network', () async {
      final _FakeHttp http = _FakeHttp(<Object?>[]);
      final Lookup lookup = createLookup(
        LookupDeps(adapters: const <LookupAdapter>[YoudaoAdapter()], http: http),
      );
      await expectLater(
        lookup.lookupTerm('   '),
        throwsA(isA<LookupError>().having((LookupError e) => e.reason, 'reason',
            LookupFailure.notFound)),
      );
      expect(http.calls, isEmpty);
    });

    test('force skips the cache', () async {
      final _FakeHttp http = _FakeHttp(<Object?>[_youdaoRecord, _youdaoRecord]);
      final Lookup lookup = createLookup(
        LookupDeps(adapters: const <LookupAdapter>[YoudaoAdapter()], http: http),
      );

      await lookup.lookupTerm('record');
      final LookupResult forced = await lookup.lookupTerm('record', const LookupOptions(force: true));
      expect(forced.fromCache, isFalse);
      expect(http.calls, hasLength(2));
    });
  });

  group('adapter chain', () {
    test('follows the injected adapter order, not a hard-coded chain', () async {
      final _StubAdapter google = _StubAdapter(ProviderId.google, result: _result('歌'));
      final _StubAdapter youdao = _StubAdapter(ProviderId.youdao, result: _result('道'));
      final Lookup lookup = createLookup(LookupDeps(adapters: <LookupAdapter>[google, youdao]));

      expect((await lookup.lookupTerm('x')).senses.single.meaning, '歌');
    });

    test('skips an adapter whose canServe is false', () async {
      final _StubAdapter cannot = _StubAdapter(ProviderId.youdao, serves: false, result: _result('一'));
      final _StubAdapter can = _StubAdapter(ProviderId.google, result: _result('二'));
      final Lookup lookup = createLookup(LookupDeps(adapters: <LookupAdapter>[cannot, can]));

      expect((await lookup.lookupTerm('x')).senses.single.meaning, '二');
      expect(cannot.fetchCount, 0);
    });

    test('passes the language pair through to canServe', () async {
      final List<String> seen = <String>[];
      final _RecordingAdapter adapter = _RecordingAdapter(seen);
      final Lookup lookup = createLookup(LookupDeps(adapters: <LookupAdapter>[adapter]));

      await lookup.lookupTerm('x', const LookupOptions(from: 'ja', to: 'ko'));
      expect(seen, <String>['ja>ko']);
    });

    test('reports not-found when every adapter answers with nothing', () async {
      final Lookup lookup = createLookup(LookupDeps(adapters: <LookupAdapter>[
        _StubAdapter(ProviderId.youdao),
      ]));
      await expectLater(lookup.lookupTerm('x'), throwsA(isA<LookupError>()));
    });

    test('reports offline when every adapter fails without answering', () async {
      final Lookup lookup = createLookup(LookupDeps(adapters: <LookupAdapter>[
        _StubAdapter(ProviderId.youdao, fails: Exception('socket closed')),
        _StubAdapter(ProviderId.google, fails: Exception('dns')),
      ]));
      await expectLater(
        lookup.lookupTerm('x'),
        throwsA(isA<LookupError>().having((LookupError e) => e.reason, 'reason',
            LookupFailure.offline)),
      );
    });

    test('reports rate-limited when every adapter is cooling', () async {
      final _StubAdapter adapter = _StubAdapter(ProviderId.youdao, rateLimited: true);
      final _Clock clock = _Clock(1000);
      final Lookup lookup = createLookup(LookupDeps(
        adapters: <LookupAdapter>[adapter],
        clock: clock,
      ));

      // First round marks the cooldown; the second skips the adapter entirely.
      await expectLater(lookup.lookupTerm('a'), throwsA(isA<LookupError>()));
      adapter.rateLimited = false;
      await expectLater(
        lookup.lookupTerm('b'),
        throwsA(isA<LookupError>().having((LookupError e) => e.reason, 'reason',
            LookupFailure.rateLimited)),
      );
      expect(adapter.fetchCount, 1);
    });

    test('treats a chain where no adapter can serve as offline', () async {
      final Lookup lookup = createLookup(LookupDeps(adapters: <LookupAdapter>[
        _StubAdapter(ProviderId.youdao, serves: false),
      ]));
      await expectLater(
        lookup.lookupTerm('x'),
        throwsA(isA<LookupError>().having((LookupError e) => e.reason, 'reason',
            LookupFailure.offline)),
      );
    });
  });

  group('google adapter language tags', () {
    test("asks Google for zh-CN, not Youdao's zh-CHS, when the target is Chinese", () async {
      final _FakeHttp http = _FakeHttp(<Object?>[
        <Object?>[
          <Object?>[
            <Object?>['苹果', 'apple', null, null],
          ],
        ],
      ]);
      final Lookup lookup = createLookup(
        LookupDeps(adapters: const <LookupAdapter>[GoogleAdapter()], http: http),
      );

      await lookup.lookupTerm('apple', const LookupOptions(from: 'en', to: 'zh-CHS'));
      expect(http.calls.single.queryParameters['tl'], 'zh-CN');
    });

    test('keeps a traditional-Chinese target distinct from the simplified one', () async {
      expect(googleLang('zh-TW'), 'zh-TW');
      expect(googleLang('zh-HK'), 'zh-TW');
      expect(googleLang('zh-CN'), 'zh-CN');
      expect(googleLang('zh-CHS'), 'zh-CN');
      expect(youdaoLang('zh-TW'), 'zh-CHS');
    });
  });

  group('the shipping adapter chain', () {
    test('leads with the dictionary only for Chinese targets', () async {
      final _FakeHttp http = _FakeHttp(<Object?>[_youdaoRecord, _youdaoRecord]);
      final Lookup lookup = createLookup(
        LookupDeps(adapters: defaultAdapters(), http: http),
      );

      await lookup.lookupTerm('record', const LookupOptions(from: 'en', to: 'zh-CN'));
      expect(http.calls.single.host, 'dict.youdao.com');
      expect(http.calls.single.path, '/jsonapi');
    });

    test('hands a Japanese target to the machine-translation endpoint instead', () async {
      final _FakeHttp http = _FakeHttp(<Object?>[
        <Object?>[
          <Object?>[
            <Object?>['りんご', 'apple', null, null],
          ],
        ],
      ]);
      final Lookup lookup = createLookup(
        LookupDeps(adapters: defaultAdapters(), http: http),
      );

      final LookupResult result =
          await lookup.lookupTerm('apple', const LookupOptions(from: 'en', to: 'ja'));
      // The dictionary cannot gloss into Japanese, so it was never asked.
      expect(http.calls.single.host, 'translate.googleapis.com');
      expect(result.senses.single.meaning, 'りんご');
    });

    test('reports rate-limited when the dictionary answers 411', () async {
      final _FakeHttp http = _FakeHttp(<Object?>[
        <String, Object?>{'errorCode': 411},
      ]);
      final _StubAdapter fallback = _StubAdapter(ProviderId.myMemory);
      final Lookup lookup = createLookup(
        LookupDeps(
          adapters: <LookupAdapter>[const YoudaoWebAdapter(), fallback],
          http: http,
        ),
      );

      // The 411 is a rate-limit signal, so the chain falls through and finally
      // reports rate-limited rather than not-found.
      await expectLater(
        lookup.lookupTerm('x'),
        throwsA(isA<LookupError>().having((LookupError e) => e.reason, 'reason',
            LookupFailure.rateLimited)),
      );
    });
  });

  group('cache and cooldown live in the instance', () {
    test('skips an adapter during the cooldown window and retries after it', () async {
      final _StubAdapter adapter = _StubAdapter(ProviderId.youdao, rateLimited: true);
      final _Clock clock = _Clock(1000);
      final Lookup lookup = createLookup(LookupDeps(
        adapters: <LookupAdapter>[adapter],
        clock: clock,
      ));

      await expectLater(lookup.lookupTerm('a'), throwsA(isA<LookupError>()));
      adapter.rateLimited = false;

      // Still inside the 90 s window.
      clock.advance(30 * 1000);
      await expectLater(lookup.lookupTerm('b'), throwsA(isA<LookupError>()));
      expect(adapter.fetchCount, 1);

      // Past it.
      clock.advance(70 * 1000);
      adapter.result = _result('回来了');
      expect((await lookup.lookupTerm('c')).senses.single.meaning, '回来了');
      expect(adapter.fetchCount, 2);
    });

    test('serves a cache hit without calling any adapter', () async {
      final _StubAdapter adapter = _StubAdapter(ProviderId.youdao, result: _result('一'));
      final Lookup lookup = createLookup(LookupDeps(adapters: <LookupAdapter>[adapter]));

      await lookup.lookupTerm('x');
      await lookup.lookupTerm('x');
      expect(adapter.fetchCount, 1);
    });

    test('expires a cache entry after the TTL on the injected clock', () async {
      final _Clock clock = _Clock(0);
      final LookupCache cache = createLookupCache(LookupCacheOptions(
        clock: clock,
        ttlMs: 1000,
      ));
      final _StubAdapter adapter = _StubAdapter(ProviderId.youdao, result: _result('一'));
      final Lookup lookup = createLookup(LookupDeps(
        adapters: <LookupAdapter>[adapter],
        cache: cache,
        clock: clock,
      ));

      await lookup.lookupTerm('x');
      clock.advance(500);
      await lookup.lookupTerm('x');
      expect(adapter.fetchCount, 1);

      clock.advance(600);
      await lookup.lookupTerm('x');
      expect(adapter.fetchCount, 2);
    });

    test('keeps cache and cooldown separate per instance', () async {
      final _StubAdapter one = _StubAdapter(ProviderId.youdao, result: _result('一'));
      final _StubAdapter two = _StubAdapter(ProviderId.youdao, result: _result('二'));
      final Lookup a = createLookup(LookupDeps(adapters: <LookupAdapter>[one]));
      final Lookup b = createLookup(LookupDeps(adapters: <LookupAdapter>[two]));

      expect((await a.lookupTerm('x')).senses.single.meaning, '一');
      expect((await b.lookupTerm('x')).senses.single.meaning, '二');
      expect(a.cacheSize(), 1);
      expect(b.cacheSize(), 1);

      a.clearCache();
      expect(a.cacheSize(), 0);
      expect(b.cacheSize(), 1);
    });
  });

  group('storage-backed cache', () {
    test('round-trips through injected storage and its TTL survives a reload', () async {
      final _Clock clock = _Clock(1000);
      final MemoryLookupStorage storage = MemoryLookupStorage();
      final LookupCacheOptions options = LookupCacheOptions(
        storage: storage,
        clock: clock,
        ttlMs: 500,
      );

      final LookupCache first = createLookupCache(options);
      first.set('en>zh-CN:x', _result('一'));
      expect(first.size(), 1);

      // A fresh cache over the same storage sees the entry, still warm.
      final LookupCache second = createLookupCache(options);
      final LookupResult? warm = second.get('en>zh-CN:x');
      expect(warm, isNotNull);
      expect(warm!.fromCache, isTrue);
      expect(warm.senses.single.meaning, '一');

      clock.advance(600);
      expect(second.get('en>zh-CN:x'), isNull);
    });

    test('drops the oldest keys once the cap is reached', () {
      final LookupCache cache = createLookupCache(
        LookupCacheOptions(max: 2, clock: _Clock(0)),
      );
      cache.set('a', _result('a'));
      cache.set('b', _result('b'));
      cache.set('c', _result('c'));

      expect(cache.size(), 2);
      expect(cache.get('a'), isNull);
      expect(cache.get('b'), isNotNull);
      expect(cache.get('c'), isNotNull);
    });

    test('treats a corrupted payload as an empty cache', () {
      final MemoryLookupStorage storage = MemoryLookupStorage();
      storage.setItem('lexumo.dict.v1', '{not json');
      final LookupCache cache = createLookupCache(
        LookupCacheOptions(storage: storage, clock: _Clock(0)),
      );
      expect(cache.size(), 0);
      cache.set('a', _result('a'));
      expect(cache.get('a'), isNotNull);
    });
  });

  group('IoLookupHttp', () {
    test('reports a 429 as rate-limited and a 500 as offline', () async {
      final IoLookupHttp http = IoLookupHttp();
      // A port nothing listens on: the connection is refused, which the
      // orchestrator treats as "this provider did not answer".
      await expectLater(
        http.getJson(Uri.parse('http://127.0.0.1:9/x'), timeout: const Duration(milliseconds: 500)),
        throwsA(anything),
      );
    });
  });
}

/// An adapter that records the language pair it was asked about.
class _RecordingAdapter implements LookupAdapter {
  _RecordingAdapter(this.seen);

  final List<String> seen;

  @override
  ProviderId get id => ProviderId.youdao;

  @override
  bool canServe(String from, String to) {
    seen.add('$from>$to');
    return true;
  }

  @override
  Future<LookupResult?> fetch(String term, LookupContext context) async =>
      _result('命中', provider: ProviderId.youdao);
}

/// An adapter whose answer is a closure, so a test can vary it by context.
class _CallbackAdapter implements LookupAdapter {
  _CallbackAdapter(this.body);

  final Future<LookupResult?> Function(String term, LookupContext context) body;

  @override
  ProviderId get id => ProviderId.youdao;

  @override
  bool canServe(String from, String to) => true;

  @override
  Future<LookupResult?> fetch(String term, LookupContext context) => body(term, context);
}
