import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'models.dart';

class DictionaryRepository {
  DictionaryRepository._(
    this.dataRoot,
    this._dictionary,
    this._user,
    this._activePack,
  );

  static const int schemaVersion = 1;
  static const String starterVersion = 'starter-1';

  final Directory dataRoot;
  Database _dictionary;
  final Database _user;
  PackInfo _activePack;

  PackInfo get activePack => _activePack;
  File get activePointerFile => File(p.join(dataRoot.path, 'active.json'));
  File get activeDictionaryFile => File(_activePack.path);

  Future<String> audioDirectoryFor(String accent) async {
    final pointer = File(p.join(dataRoot.path, 'audio-active.json'));
    if (await pointer.exists()) {
      final document = _stringKeyedMap(
        jsonDecode(await pointer.readAsString()),
      );
      if (document['version'] == activePack.version) {
        final packs = _stringKeyedMap(document['packs']);
        final relative = packs[accent] as String?;
        if (relative != null && relative.isNotEmpty) {
          final absolute = p.normalize(p.join(dataRoot.path, relative));
          if (p.isWithin(dataRoot.path, absolute) &&
              await Directory(absolute).exists()) {
            return absolute;
          }
        }
      }
    }
    return p.dirname(activeDictionaryFile.path);
  }

  static Future<DictionaryRepository> open({
    Directory? dataRoot,
    List<Map<String, Object?>>? seedEntries,
  }) async {
    final Directory root;
    if (dataRoot != null) {
      root = dataRoot;
    } else {
      root = await _defaultDataRoot();
    }
    await root.create(recursive: true);

    final activeFile = File(p.join(root.path, 'active.json'));
    Map<String, Object?> active;
    if (!await activeFile.exists()) {
      final packDirectory =
          Directory(p.join(root.path, 'packs', starterVersion));
      await packDirectory.create(recursive: true);
      final dictionaryPath = p.join(packDirectory.path, 'dictionary.sqlite');
      final database = sqlite3.open(dictionaryPath);
      try {
        _createDictionarySchema(database);
        final data = seedEntries ?? await _loadStarterEntries();
        _replaceAllEntries(database, data, starterVersion);
      } finally {
        database.dispose();
      }
      active = <String, Object?>{
        'version': starterVersion,
        'database': p.relative(dictionaryPath, from: root.path),
        'activated_at': DateTime.now().toUtc().toIso8601String(),
      };
      await _writeJsonAtomically(activeFile, active);
    } else {
      active = _stringKeyedMap(
        jsonDecode(await activeFile.readAsString()),
      );
    }

    final version = active['version'] as String? ?? starterVersion;
    final databaseRelativePath = active['database'] as String? ??
        p.join('packs', version, 'dictionary.sqlite');
    final databasePath = p.normalize(p.join(root.path, databaseRelativePath));
    if (!p.isWithin(root.path, databasePath)) {
      throw StateError('Active dictionary path escapes data root.');
    }
    final dictionaryFile = File(databasePath);
    if (!await dictionaryFile.exists()) {
      throw StateError('Active dictionary database is missing: $databasePath');
    }

    final dictionary = sqlite3.open(databasePath);
    _validateDictionary(dictionary);
    final userDatabase = sqlite3.open(p.join(root.path, 'user.sqlite'));
    _createUserSchema(userDatabase);
    return DictionaryRepository._(
      root,
      dictionary,
      userDatabase,
      PackInfo(
        version: version,
        activatedAt:
            DateTime.tryParse(active['activated_at'] as String? ?? '') ??
                DateTime.now().toUtc(),
        path: databasePath,
      ),
    );
  }

  static Future<Directory> _defaultDataRoot() async {
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData == null || localAppData.isEmpty) {
        throw StateError('LOCALAPPDATA is unavailable.');
      }
      return Directory(p.join(localAppData, 'MyDuo'));
    }
    if (Platform.isAndroid) {
      const channel = MethodChannel('io.github.chingfuhan.myduo/speech');
      final path = await channel.invokeMethod<String>('appDataPath');
      if (path == null || path.isEmpty) {
        throw StateError('Android app data path is unavailable.');
      }
      return Directory(p.join(path, 'MyDuo'));
    }
    throw UnsupportedError(
      'MyDuo supports Android and Windows data directories.',
    );
  }

  static Future<List<Map<String, Object?>>> _loadStarterEntries() async {
    final source = await rootBundle.loadString('assets/data/seed_entries.json');
    return (jsonDecode(source) as List<Object?>)
        .whereType<Map<Object?, Object?>>()
        .map(
          (item) => item.map(
            (key, value) => MapEntry(key.toString(), value),
          ),
        )
        .toList(growable: false);
  }

  static void _createDictionarySchema(Database database) {
    database.execute('''
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS entries (
        id INTEGER PRIMARY KEY,
        headword TEXT NOT NULL COLLATE NOCASE,
        normalized TEXT NOT NULL,
        ipa_uk TEXT NOT NULL DEFAULT '',
        ipa_us TEXT NOT NULL DEFAULT '',
        audio_uk TEXT NOT NULL DEFAULT '',
        audio_us TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL,
        source_url TEXT NOT NULL,
        license TEXT NOT NULL,
        attribution TEXT NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_entries_headword
        ON entries(headword COLLATE NOCASE);
      CREATE INDEX IF NOT EXISTS idx_entries_normalized ON entries(normalized);
      CREATE TABLE IF NOT EXISTS senses (
        id INTEGER PRIMARY KEY,
        entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        pos TEXT NOT NULL,
        definition TEXT NOT NULL,
        translation_zh TEXT NOT NULL,
        example_en TEXT NOT NULL,
        example_zh TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_senses_entry ON senses(entry_id, position);
      CREATE INDEX IF NOT EXISTS idx_senses_zh ON senses(translation_zh);
      CREATE TABLE IF NOT EXISTS forms (
        id INTEGER PRIMARY KEY,
        entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        form TEXT NOT NULL,
        tags_json TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_forms_entry ON forms(entry_id);
      CREATE INDEX IF NOT EXISTS idx_forms_form ON forms(form COLLATE NOCASE);
      CREATE TABLE IF NOT EXISTS phrases (
        id INTEGER PRIMARY KEY,
        entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        phrase TEXT NOT NULL,
        definition TEXT NOT NULL,
        translation_zh TEXT NOT NULL,
        example TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_phrases_entry ON phrases(entry_id);
      CREATE TABLE IF NOT EXISTS relations (
        id INTEGER PRIMARY KEY,
        entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        relation_type TEXT NOT NULL,
        word TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_relations_entry ON relations(entry_id);
      CREATE VIRTUAL TABLE IF NOT EXISTS entry_fts USING fts5(
        headword,
        forms,
        definitions,
        translations,
        phrases,
        tokenize = 'unicode61 remove_diacritics 2'
      );
    ''');
    database.execute(
      'INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)',
      <Object?>['schema_version', schemaVersion.toString()],
    );
  }

  static void _createUserSchema(Database database) {
    database.execute('''
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS favorites (
        headword TEXT PRIMARY KEY COLLATE NOCASE,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        headword TEXT NOT NULL COLLATE NOCASE,
        query TEXT NOT NULL,
        viewed_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_history_viewed_at
        ON history(viewed_at DESC);
    ''');
  }

  static void _validateDictionary(Database database) {
    final schemaRows = database.select(
      "SELECT value FROM metadata WHERE key = 'schema_version'",
    );
    if (schemaRows.isEmpty ||
        int.tryParse(schemaRows.first['value'] as String? ?? '') !=
            schemaVersion) {
      throw StateError('Unsupported dictionary schema.');
    }
    final ftsRows = database.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'entry_fts'",
    );
    if (ftsRows.isEmpty) {
      throw StateError('Dictionary does not contain required FTS5 index.');
    }
    database.select('SELECT rowid FROM entry_fts LIMIT 1');
  }

  static void _replaceAllEntries(
    Database database,
    List<Map<String, Object?>> entries,
    String packVersion,
  ) {
    database.execute('BEGIN IMMEDIATE');
    try {
      database.execute('DELETE FROM entry_fts');
      database.execute('DELETE FROM entries');
      for (final entry in entries) {
        _insertEntry(database, entry);
      }
      _rebuildFts(database);
      database.execute(
        'INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)',
        <Object?>['pack_version', packVersion],
      );
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  static void _insertEntry(Database database, Map<String, Object?> entry) {
    final headword = (entry['headword'] as String? ?? '').trim();
    if (headword.isEmpty) {
      return;
    }
    database.execute(
      '''
      INSERT INTO entries(
        headword, normalized, ipa_uk, ipa_us, audio_uk, audio_us,
        source, source_url, license, attribution
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      <Object?>[
        headword,
        _normalize(headword),
        entry['ipa_uk'] as String? ?? '',
        entry['ipa_us'] as String? ?? '',
        entry['audio_uk'] as String? ?? '',
        entry['audio_us'] as String? ?? '',
        entry['source'] as String? ?? 'Unknown source',
        entry['source_url'] as String? ?? '',
        entry['license'] as String? ?? 'Unknown license',
        entry['attribution'] as String? ?? '',
      ],
    );
    final id = database.lastInsertRowId;

    final senses = entry['senses'] as List<Object?>? ?? const <Object?>[];
    for (var index = 0; index < senses.length; index++) {
      final sense = _stringKeyedMap(senses[index]);
      database.execute(
        '''
        INSERT INTO senses(
          entry_id, position, pos, definition, translation_zh,
          example_en, example_zh
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          id,
          index,
          sense['pos'] as String? ?? '',
          sense['definition'] as String? ?? '',
          sense['translation_zh'] as String? ?? '',
          sense['example_en'] as String? ?? '',
          sense['example_zh'] as String? ?? '',
        ],
      );
    }

    for (final rawForm
        in entry['forms'] as List<Object?>? ?? const <Object?>[]) {
      final form = _stringKeyedMap(rawForm);
      final tags = form['tags'] as List<Object?>? ?? const <Object?>[];
      database.execute(
        'INSERT INTO forms(entry_id, form, tags_json) VALUES (?, ?, ?)',
        <Object?>[
          id,
          form['form'] as String? ?? '',
          jsonEncode(tags.whereType<String>().toList()),
        ],
      );
    }

    for (final rawPhrase
        in entry['phrases'] as List<Object?>? ?? const <Object?>[]) {
      final phrase = _stringKeyedMap(rawPhrase);
      database.execute(
        '''
        INSERT INTO phrases(
          entry_id, phrase, definition, translation_zh, example
        ) VALUES (?, ?, ?, ?, ?)
        ''',
        <Object?>[
          id,
          phrase['phrase'] as String? ?? '',
          phrase['definition'] as String? ?? '',
          phrase['translation_zh'] as String? ?? '',
          phrase['example'] as String? ?? '',
        ],
      );
    }

    for (final rawRelation
        in entry['relations'] as List<Object?>? ?? const <Object?>[]) {
      final relation = _stringKeyedMap(rawRelation);
      database.execute(
        '''
        INSERT INTO relations(entry_id, relation_type, word)
        VALUES (?, ?, ?)
        ''',
        <Object?>[
          id,
          relation['type'] as String? ?? 'related',
          relation['word'] as String? ?? '',
        ],
      );
    }
  }

  static Map<String, Object?> _stringKeyedMap(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      return <String, Object?>{};
    }
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  static void _rebuildFts(Database database) {
    database.execute('DELETE FROM entry_fts');
    database.execute('''
      INSERT INTO entry_fts(
        rowid, headword, forms, definitions, translations, phrases
      )
      SELECT
        e.id,
        e.headword,
        COALESCE((
          SELECT group_concat(f.form, ' ') FROM forms f WHERE f.entry_id = e.id
        ), ''),
        COALESCE((
          SELECT group_concat(s.definition, ' ') FROM senses s
          WHERE s.entry_id = e.id
        ), ''),
        COALESCE((
          SELECT group_concat(s.translation_zh, ' ') FROM senses s
          WHERE s.entry_id = e.id
        ), ''),
        COALESCE((
          SELECT group_concat(
            p.phrase || ' ' || p.definition || ' ' || p.translation_zh, ' '
          ) FROM phrases p WHERE p.entry_id = e.id
        ), '')
      FROM entries e
    ''');
  }

  static String _normalize(String value) => value.trim().toLowerCase();

  Future<List<SearchResult>> search(String rawQuery, {int limit = 40}) async {
    final query = rawQuery.trim();
    if (query.isEmpty) {
      return _browse(limit);
    }

    final found = <int, SearchResult>{};
    if (_containsCjk(query)) {
      for (final row in _dictionary.select(
        '''
        SELECT DISTINCT
          e.id, e.headword,
          COALESCE((SELECT pos FROM senses WHERE entry_id = e.id
            ORDER BY position LIMIT 1), '') AS pos,
          COALESCE((SELECT definition FROM senses WHERE entry_id = e.id
            ORDER BY position LIMIT 1), '') AS definition,
          COALESCE((SELECT translation_zh FROM senses WHERE entry_id = e.id
            AND translation_zh LIKE ? ORDER BY position LIMIT 1),
            (SELECT translation_zh FROM senses WHERE entry_id = e.id
              ORDER BY position LIMIT 1), '') AS translation_zh
        FROM entries e
        LEFT JOIN senses s ON s.entry_id = e.id
        LEFT JOIN phrases p ON p.entry_id = e.id
        WHERE s.translation_zh LIKE ?
           OR s.example_zh LIKE ?
           OR p.translation_zh LIKE ?
        ORDER BY
          CASE WHEN s.translation_zh = ? THEN 0 ELSE 1 END,
          e.headword
        LIMIT ?
        ''',
        <Object?>[
          '%$query%',
          '%$query%',
          '%$query%',
          '%$query%',
          query,
          limit,
        ],
      )) {
        final result = _searchResultFromRow(row, '繁中反查', 0);
        found[result.id] = result;
      }
    } else {
      final ftsQuery = query
          .split(RegExp(r'\s+'))
          .where((part) => part.isNotEmpty)
          .map((part) => '"${part.replaceAll('"', '""')}"*')
          .join(' AND ');
      try {
        for (final row in _dictionary.select(
          '''
          SELECT
            e.id, e.headword,
            COALESCE((SELECT pos FROM senses WHERE entry_id = e.id
              ORDER BY position LIMIT 1), '') AS pos,
            COALESCE((SELECT definition FROM senses WHERE entry_id = e.id
              ORDER BY position LIMIT 1), '') AS definition,
            COALESCE((SELECT translation_zh FROM senses WHERE entry_id = e.id
              ORDER BY position LIMIT 1), '') AS translation_zh,
            bm25(entry_fts, 12.0, 4.0, 1.0, 1.5, 2.0) AS rank
          FROM entry_fts
          JOIN entries e ON e.id = entry_fts.rowid
          WHERE entry_fts MATCH ?
          ORDER BY
            CASE WHEN e.normalized = ? THEN 0
                 WHEN e.normalized LIKE ? THEN 1 ELSE 2 END,
            rank,
            e.headword
          LIMIT ?
          ''',
          <Object?>[
            ftsQuery,
            _normalize(query),
            '${_normalize(query)}%',
            limit
          ],
        )) {
          final rank = (row['rank'] as num?)?.toDouble() ?? 0;
          final result = _searchResultFromRow(row, 'FTS5', rank);
          found[result.id] = result;
        }
      } on SqliteException {
        // Punctuation-only queries fall back to safe LIKE matching below.
      }

      for (final row in _dictionary.select(
        '''
        SELECT
          e.id, e.headword,
          COALESCE((SELECT pos FROM senses WHERE entry_id = e.id
            ORDER BY position LIMIT 1), '') AS pos,
          COALESCE((SELECT definition FROM senses WHERE entry_id = e.id
            ORDER BY position LIMIT 1), '') AS definition,
          COALESCE((SELECT translation_zh FROM senses WHERE entry_id = e.id
            ORDER BY position LIMIT 1), '') AS translation_zh
        FROM entries e
        LEFT JOIN forms f ON f.entry_id = e.id
        WHERE e.normalized LIKE ? OR lower(f.form) LIKE ?
        ORDER BY CASE WHEN e.normalized = ? THEN 0 ELSE 1 END, e.headword
        LIMIT ?
        ''',
        <Object?>[
          '${_normalize(query)}%',
          '${_normalize(query)}%',
          _normalize(query),
          limit,
        ],
      )) {
        final result = _searchResultFromRow(row, '前綴', -10);
        found[result.id] = result;
      }

      if (found.length < limit) {
        _addFuzzyMatches(found, query, limit);
      }
    }

    final results = found.values.toList()
      ..sort((left, right) {
        final leftExact = left.headword.toLowerCase() == query.toLowerCase();
        final rightExact = right.headword.toLowerCase() == query.toLowerCase();
        if (leftExact != rightExact) {
          return leftExact ? -1 : 1;
        }
        final score = left.score.compareTo(right.score);
        return score != 0 ? score : left.headword.compareTo(right.headword);
      });
    return results.take(limit).toList(growable: false);
  }

  List<SearchResult> _browse(int limit) {
    return _dictionary
        .select(
          '''
          SELECT
            e.id, e.headword,
            COALESCE((SELECT pos FROM senses WHERE entry_id = e.id
              ORDER BY position LIMIT 1), '') AS pos,
            COALESCE((SELECT definition FROM senses WHERE entry_id = e.id
              ORDER BY position LIMIT 1), '') AS definition,
            COALESCE((SELECT translation_zh FROM senses WHERE entry_id = e.id
              ORDER BY position LIMIT 1), '') AS translation_zh
          FROM entries e ORDER BY e.headword LIMIT ?
          ''',
          <Object?>[limit],
        )
        .map((row) => _searchResultFromRow(row, '瀏覽', 0))
        .toList(growable: false);
  }

  void _addFuzzyMatches(
    Map<int, SearchResult> found,
    String query,
    int limit,
  ) {
    final normalized = _normalize(query);
    if (normalized.length < 2) {
      return;
    }
    final candidates = <({Row row, int distance})>[];
    for (final row in _dictionary.select(
      'SELECT id, headword FROM entries LIMIT 5000',
    )) {
      final word = (row['headword'] as String).toLowerCase();
      final distance = _levenshtein(normalized, word);
      final threshold =
          normalized.length <= 4 ? 1 : (normalized.length / 3).ceil();
      if (distance <= threshold) {
        candidates.add((row: row, distance: distance));
      }
    }
    candidates.sort((a, b) => a.distance.compareTo(b.distance));
    for (final candidate in candidates) {
      final id = candidate.row['id'] as int;
      if (found.containsKey(id)) {
        continue;
      }
      final detail = _summaryById(id);
      if (detail != null) {
        found[id] = SearchResult(
          id: detail.id,
          headword: detail.headword,
          partOfSpeech: detail.partOfSpeech,
          definition: detail.definition,
          translationZh: detail.translationZh,
          matchKind: '模糊 ${candidate.distance}',
          score: 100 + candidate.distance.toDouble(),
        );
      }
      if (found.length >= limit) {
        return;
      }
    }
  }

  SearchResult? _summaryById(int id) {
    final rows = _dictionary.select(
      '''
      SELECT
        e.id, e.headword,
        COALESCE((SELECT pos FROM senses WHERE entry_id = e.id
          ORDER BY position LIMIT 1), '') AS pos,
        COALESCE((SELECT definition FROM senses WHERE entry_id = e.id
          ORDER BY position LIMIT 1), '') AS definition,
        COALESCE((SELECT translation_zh FROM senses WHERE entry_id = e.id
          ORDER BY position LIMIT 1), '') AS translation_zh
      FROM entries e WHERE e.id = ?
      ''',
      <Object?>[id],
    );
    return rows.isEmpty ? null : _searchResultFromRow(rows.first, '模糊', 0);
  }

  static SearchResult _searchResultFromRow(
    Row row,
    String kind,
    double score,
  ) {
    return SearchResult(
      id: row['id'] as int,
      headword: row['headword'] as String,
      partOfSpeech: row['pos'] as String? ?? '',
      definition: row['definition'] as String? ?? '',
      translationZh: row['translation_zh'] as String? ?? '',
      matchKind: kind,
      score: score,
    );
  }

  Future<DictionaryEntry?> entryById(int id) async {
    final rows = _dictionary.select(
      'SELECT * FROM entries WHERE id = ?',
      <Object?>[id],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _entryFromRow(rows.first);
  }

  Future<DictionaryEntry?> entryByHeadword(String headword) async {
    final rows = _dictionary.select(
      'SELECT * FROM entries WHERE headword = ? COLLATE NOCASE',
      <Object?>[headword],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _entryFromRow(rows.first);
  }

  DictionaryEntry _entryFromRow(Row row) {
    final id = row['id'] as int;
    final senses = _dictionary
        .select(
          'SELECT * FROM senses WHERE entry_id = ? ORDER BY position',
          <Object?>[id],
        )
        .map(
          (sense) => DictionarySense(
            partOfSpeech: sense['pos'] as String,
            definition: sense['definition'] as String,
            translationZh: sense['translation_zh'] as String,
            exampleEn: sense['example_en'] as String,
            exampleZh: sense['example_zh'] as String,
          ),
        )
        .toList(growable: false);
    final forms = _dictionary
        .select('SELECT * FROM forms WHERE entry_id = ?', <Object?>[id])
        .map(
          (form) => WordForm(
            form: form['form'] as String,
            tags: (jsonDecode(form['tags_json'] as String) as List<Object?>)
                .whereType<String>()
                .toList(growable: false),
          ),
        )
        .toList(growable: false);
    final phrases = _dictionary
        .select('SELECT * FROM phrases WHERE entry_id = ?', <Object?>[id])
        .map(
          (phrase) => DictionaryPhrase(
            phrase: phrase['phrase'] as String,
            definition: phrase['definition'] as String,
            translationZh: phrase['translation_zh'] as String,
            example: phrase['example'] as String,
          ),
        )
        .toList(growable: false);
    final relatedWords = _dictionary
        .select('SELECT * FROM relations WHERE entry_id = ?', <Object?>[id])
        .map(
          (relation) => RelatedWord(
            type: relation['relation_type'] as String,
            word: relation['word'] as String,
          ),
        )
        .toList(growable: false);
    final favoriteRows = _user.select(
      'SELECT 1 FROM favorites WHERE headword = ? COLLATE NOCASE',
      <Object?>[row['headword']],
    );
    return DictionaryEntry(
      id: id,
      headword: row['headword'] as String,
      ipaUk: row['ipa_uk'] as String,
      ipaUs: row['ipa_us'] as String,
      source: row['source'] as String,
      sourceUrl: row['source_url'] as String,
      license: row['license'] as String,
      attribution: row['attribution'] as String,
      senses: senses,
      forms: forms,
      phrases: phrases,
      relatedWords: relatedWords,
      audioUk: row['audio_uk'] as String,
      audioUs: row['audio_us'] as String,
      isFavorite: favoriteRows.isNotEmpty,
    );
  }

  Future<bool> toggleFavorite(DictionaryEntry entry) async {
    final exists = _user.select(
      'SELECT 1 FROM favorites WHERE headword = ? COLLATE NOCASE',
      <Object?>[entry.headword],
    );
    if (exists.isEmpty) {
      _user.execute(
        'INSERT INTO favorites(headword, created_at) VALUES (?, ?)',
        <Object?>[entry.headword, DateTime.now().toUtc().toIso8601String()],
      );
      return true;
    }
    _user.execute(
      'DELETE FROM favorites WHERE headword = ? COLLATE NOCASE',
      <Object?>[entry.headword],
    );
    return false;
  }

  Future<List<DictionaryEntry>> favorites() async {
    final result = <DictionaryEntry>[];
    for (final row in _user.select(
      'SELECT headword FROM favorites ORDER BY created_at DESC',
    )) {
      final entry = await entryByHeadword(row['headword'] as String);
      if (entry != null) {
        result.add(entry);
      }
    }
    return result;
  }

  Future<void> recordHistory(DictionaryEntry entry, String query) async {
    _user.execute(
      '''
      INSERT INTO history(headword, query, viewed_at) VALUES (?, ?, ?)
      ''',
      <Object?>[
        entry.headword,
        query,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    _user.execute('''
      DELETE FROM history
      WHERE id NOT IN (
        SELECT id FROM history ORDER BY viewed_at DESC LIMIT 500
      )
    ''');
  }

  Future<List<HistoryRecord>> history({int limit = 200}) async {
    final result = <HistoryRecord>[];
    for (final row in _user.select(
      'SELECT * FROM history ORDER BY viewed_at DESC LIMIT ?',
      <Object?>[limit],
    )) {
      final entry = await entryByHeadword(row['headword'] as String);
      if (entry == null) {
        continue;
      }
      result.add(
        HistoryRecord(
          id: row['id'] as int,
          entryId: entry.id,
          headword: entry.headword,
          query: row['query'] as String,
          viewedAt:
              DateTime.tryParse(row['viewed_at'] as String) ?? DateTime.now(),
        ),
      );
    }
    return result;
  }

  Future<void> clearHistory() async {
    _user.execute('DELETE FROM history');
  }

  Future<File> applyDeltaToStaging(
    File deltaJsonl,
    String targetVersion,
  ) async {
    final stagingDirectory = Directory(
      p.join(
        dataRoot.path,
        'staging',
        '$targetVersion-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await stagingDirectory.create(recursive: true);
    final stagedDatabase =
        File(p.join(stagingDirectory.path, 'dictionary.sqlite'));
    await activeDictionaryFile.copy(stagedDatabase.path);
    final database = sqlite3.open(stagedDatabase.path);
    try {
      _validateDictionary(database);
      database.execute('BEGIN IMMEDIATE');
      await for (final line in deltaJsonl
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.trim().isEmpty) {
          continue;
        }
        final operation = _stringKeyedMap(jsonDecode(line));
        final op = operation['op'] as String?;
        if (op == 'delete') {
          database.execute(
            'DELETE FROM entries WHERE headword = ? COLLATE NOCASE',
            <Object?>[operation['headword']],
          );
        } else if (op == 'upsert') {
          final entry = _stringKeyedMap(operation['entry']);
          database.execute(
            'DELETE FROM entries WHERE headword = ? COLLATE NOCASE',
            <Object?>[entry['headword']],
          );
          _insertEntry(database, entry);
        } else {
          throw FormatException('Unknown delta operation: $op');
        }
      }
      _rebuildFts(database);
      database.execute(
        'INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)',
        <Object?>['pack_version', targetVersion],
      );
      database.execute('COMMIT');
      _validateDictionary(database);
    } catch (_) {
      try {
        database.execute('ROLLBACK');
      } on SqliteException {
        // Transaction may already be closed by SQLite.
      }
      rethrow;
    } finally {
      database.dispose();
    }
    return stagedDatabase;
  }

  Future<void> activatePreparedDatabase(
    File preparedDatabase,
    String version,
  ) async {
    final validationDatabase =
        sqlite3.open(preparedDatabase.path, mode: OpenMode.readOnly);
    try {
      _validateDictionary(validationDatabase);
    } finally {
      validationDatabase.dispose();
    }

    final destinationDirectory =
        Directory(p.join(dataRoot.path, 'packs', version));
    await destinationDirectory.create(recursive: true);
    final destination =
        File(p.join(destinationDirectory.path, 'dictionary.sqlite'));
    final temporary = File('${destination.path}.new');
    await preparedDatabase.copy(temporary.path);
    if (await destination.exists()) {
      await destination.delete();
    }
    await temporary.rename(destination.path);

    final oldInfo = _activePack;
    final oldPointer = await activePointerFile.readAsBytes();
    _dictionary.dispose();
    final next = <String, Object?>{
      'version': version,
      'database': p.relative(destination.path, from: dataRoot.path),
      'activated_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      await _writeJsonAtomically(activePointerFile, next);
      final reopened = sqlite3.open(destination.path);
      _validateDictionary(reopened);
      _dictionary = reopened;
      _activePack = PackInfo(
        version: version,
        activatedAt: DateTime.parse(next['activated_at']! as String),
        path: destination.path,
      );
    } catch (_) {
      await activePointerFile.writeAsBytes(oldPointer, flush: true);
      _dictionary = sqlite3.open(oldInfo.path);
      _activePack = oldInfo;
      rethrow;
    }
  }

  Future<void> reactivate(PackInfo pack) async {
    final databaseFile = File(pack.path);
    if (!await databaseFile.exists() ||
        !p.isWithin(dataRoot.path, databaseFile.path)) {
      throw StateError('Rollback dictionary is missing or outside data root.');
    }
    final validation = sqlite3.open(databaseFile.path, mode: OpenMode.readOnly);
    try {
      _validateDictionary(validation);
    } finally {
      validation.dispose();
    }
    _dictionary.dispose();
    try {
      await _writeJsonAtomically(
        activePointerFile,
        <String, Object?>{
          'version': pack.version,
          'database': p.relative(pack.path, from: dataRoot.path),
          'activated_at': pack.activatedAt.toUtc().toIso8601String(),
        },
      );
      _dictionary = sqlite3.open(pack.path);
      _validateDictionary(_dictionary);
      _activePack = pack;
    } catch (_) {
      _dictionary = sqlite3.open(_activePack.path);
      rethrow;
    }
  }

  static Future<void> _writeJsonAtomically(
    File target,
    Map<String, Object?> value,
  ) async {
    final temporary = File('${target.path}.new');
    final backup = File('${target.path}.bak');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true,
    );
    if (await backup.exists()) {
      await backup.delete();
    }
    if (await target.exists()) {
      await target.rename(backup.path);
    }
    try {
      await temporary.rename(target.path);
      if (await backup.exists()) {
        await backup.delete();
      }
    } catch (_) {
      if (await backup.exists() && !await target.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }

  static bool _containsCjk(String value) =>
      RegExp(r'[\u3400-\u9fff]').hasMatch(value);

  static int _levenshtein(String left, String right) {
    if (left == right) {
      return 0;
    }
    if (left.isEmpty) {
      return right.length;
    }
    if (right.isEmpty) {
      return left.length;
    }
    var previous = List<int>.generate(right.length + 1, (index) => index);
    for (var i = 0; i < left.length; i++) {
      final current = List<int>.filled(right.length + 1, 0);
      current[0] = i + 1;
      for (var j = 0; j < right.length; j++) {
        final substitution = previous[j] + (left[i] == right[j] ? 0 : 1);
        final insertion = current[j] + 1;
        final deletion = previous[j + 1] + 1;
        current[j + 1] = substitution < insertion
            ? (substitution < deletion ? substitution : deletion)
            : (insertion < deletion ? insertion : deletion);
      }
      previous = current;
    }
    return previous.last;
  }

  void dispose() {
    _dictionary.dispose();
    _user.dispose();
  }
}
