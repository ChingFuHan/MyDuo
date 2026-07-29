import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myduo/src/dictionary_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporary;
  late DictionaryRepository repository;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('myduo-test-');
    repository = await DictionaryRepository.open(
      dataRoot: temporary,
      seedEntries: _testEntries,
    );
  });

  tearDown(() async {
    repository.dispose();
    if (await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  });

  test('FTS5, prefix, Traditional Chinese reverse, and fuzzy search work',
      () async {
    final fts = await repository.search('fruit');
    expect(fts.map((item) => item.headword), contains('apple'));

    final prefix = await repository.search('diction');
    expect(prefix.map((item) => item.headword), contains('dictionary'));

    final reverse = await repository.search('字典');
    expect(reverse.map((item) => item.headword), contains('dictionary'));

    final fuzzy = await repository.search('aple');
    expect(fuzzy.map((item) => item.headword), contains('apple'));
  });

  test('entry detail includes forms, phrases, examples, and provenance',
      () async {
    final entry = await repository.entryByHeadword('apple');
    expect(entry, isNotNull);
    expect(entry!.ipaUk, isNotEmpty);
    expect(entry.forms.single.form, 'apples');
    expect(entry.phrases.single.phrase, contains('eye'));
    expect(entry.senses.single.exampleEn, isNotEmpty);
    expect(entry.relatedWords.single.word, 'fruit');
    expect(entry.license, 'CC0-1.0');
  });

  test('favorites and history persist outside dictionary pack', () async {
    final entry = (await repository.entryByHeadword('apple'))!;
    expect(await repository.toggleFavorite(entry), isTrue);
    await repository.recordHistory(entry, 'apple');
    expect((await repository.favorites()).single.headword, 'apple');
    expect((await repository.history()).single.query, 'apple');

    repository.dispose();
    repository = await DictionaryRepository.open(
      dataRoot: temporary,
      seedEntries: _testEntries,
    );
    expect((await repository.favorites()).single.headword, 'apple');
    expect((await repository.history()).single.headword, 'apple');
  });

  test('delta staging and atomic activation retain user data', () async {
    final apple = (await repository.entryByHeadword('apple'))!;
    await repository.toggleFavorite(apple);
    final oldPack = repository.activePack;
    final delta = File('${temporary.path}${Platform.pathSeparator}delta.jsonl');
    final operation = <String, Object?>{
      'op': 'upsert',
      'entry': <String, Object?>{
        'headword': 'cloud',
        'ipa_uk': 'klaʊd',
        'ipa_us': 'klaʊd',
        'source': 'Test',
        'source_url': 'https://example.invalid',
        'license': 'CC0-1.0',
        'attribution': 'Test',
        'senses': <Object?>[
          <String, Object?>{
            'pos': 'noun',
            'definition': 'A visible mass of water drops.',
            'translation_zh': '雲',
          },
        ],
        'forms': <Object?>[],
        'phrases': <Object?>[],
        'relations': <Object?>[],
      },
    };
    await delta.writeAsString('${jsonEncode(operation)}\n');

    final staged = await repository.applyDeltaToStaging(delta, 'test-2');
    await repository.activatePreparedDatabase(staged, 'test-2');
    expect(repository.activePack.version, 'test-2');
    expect(
      (await repository.search('雲')).map((item) => item.headword),
      contains('cloud'),
    );
    expect((await repository.favorites()).single.headword, 'apple');

    await repository.reactivate(oldPack);
    expect(repository.activePack.version, oldPack.version);
    expect(await repository.entryByHeadword('cloud'), isNull);
  });
}

final List<Map<String, Object?>> _testEntries = <Map<String, Object?>>[
  <String, Object?>{
    'headword': 'apple',
    'ipa_uk': 'ˈæp.əl',
    'ipa_us': 'ˈæp.əl',
    'source': 'Test',
    'source_url': 'https://example.invalid',
    'license': 'CC0-1.0',
    'attribution': 'Test data',
    'senses': <Object?>[
      <String, Object?>{
        'pos': 'noun',
        'definition': 'A firm round fruit.',
        'translation_zh': '蘋果',
        'example_en': 'Eat an apple.',
        'example_zh': '吃一顆蘋果。',
      },
    ],
    'forms': <Object?>[
      <String, Object?>{
        'form': 'apples',
        'tags': <Object?>['plural'],
      },
    ],
    'phrases': <Object?>[
      <String, Object?>{
        'phrase': "the apple of someone's eye",
        'definition': 'A deeply loved person.',
        'translation_zh': '掌上明珠',
        'example': 'Their child is the apple of their eye.',
      },
    ],
    'relations': <Object?>[
      <String, Object?>{'type': 'hypernym', 'word': 'fruit'},
    ],
  },
  <String, Object?>{
    'headword': 'dictionary',
    'ipa_uk': 'ˈdɪk.ʃən.ər.i',
    'ipa_us': 'ˈdɪk.ʃə.ner.i',
    'source': 'Test',
    'source_url': 'https://example.invalid',
    'license': 'CC0-1.0',
    'attribution': 'Test data',
    'senses': <Object?>[
      <String, Object?>{
        'pos': 'noun',
        'definition': 'A reference that explains words.',
        'translation_zh': '字典；辭典',
        'example_en': 'Use a dictionary.',
        'example_zh': '使用字典。',
      },
    ],
    'forms': <Object?>[],
    'phrases': <Object?>[],
    'relations': <Object?>[],
  },
];
