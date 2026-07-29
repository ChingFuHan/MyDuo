class DictionarySense {
  const DictionarySense({
    required this.partOfSpeech,
    required this.definition,
    required this.translationZh,
    required this.exampleEn,
    required this.exampleZh,
  });

  final String partOfSpeech;
  final String definition;
  final String translationZh;
  final String exampleEn;
  final String exampleZh;

  factory DictionarySense.fromJson(Map<String, Object?> json) {
    return DictionarySense(
      partOfSpeech: json['pos'] as String? ?? '',
      definition: json['definition'] as String? ?? '',
      translationZh: json['translation_zh'] as String? ?? '',
      exampleEn: json['example_en'] as String? ?? '',
      exampleZh: json['example_zh'] as String? ?? '',
    );
  }
}

class WordForm {
  const WordForm({required this.form, required this.tags});

  final String form;
  final List<String> tags;

  factory WordForm.fromJson(Map<String, Object?> json) {
    return WordForm(
      form: json['form'] as String? ?? '',
      tags: (json['tags'] as List<Object?>? ?? const <Object?>[])
          .whereType<String>()
          .toList(growable: false),
    );
  }
}

class DictionaryPhrase {
  const DictionaryPhrase({
    required this.phrase,
    required this.definition,
    required this.translationZh,
    required this.example,
  });

  final String phrase;
  final String definition;
  final String translationZh;
  final String example;

  factory DictionaryPhrase.fromJson(Map<String, Object?> json) {
    return DictionaryPhrase(
      phrase: json['phrase'] as String? ?? '',
      definition: json['definition'] as String? ?? '',
      translationZh: json['translation_zh'] as String? ?? '',
      example: json['example'] as String? ?? '',
    );
  }
}

class RelatedWord {
  const RelatedWord({required this.type, required this.word});

  final String type;
  final String word;

  factory RelatedWord.fromJson(Map<String, Object?> json) {
    return RelatedWord(
      type: json['type'] as String? ?? 'related',
      word: json['word'] as String? ?? '',
    );
  }
}

class DictionaryEntry {
  const DictionaryEntry({
    required this.id,
    required this.headword,
    required this.ipaUk,
    required this.ipaUs,
    required this.source,
    required this.sourceUrl,
    required this.license,
    required this.attribution,
    required this.senses,
    required this.forms,
    required this.phrases,
    required this.relatedWords,
    required this.audioUk,
    required this.audioUs,
    this.isFavorite = false,
  });

  final int id;
  final String headword;
  final String ipaUk;
  final String ipaUs;
  final String source;
  final String sourceUrl;
  final String license;
  final String attribution;
  final List<DictionarySense> senses;
  final List<WordForm> forms;
  final List<DictionaryPhrase> phrases;
  final List<RelatedWord> relatedWords;
  final String audioUk;
  final String audioUs;
  final bool isFavorite;

  DictionaryEntry copyWith({bool? isFavorite}) {
    return DictionaryEntry(
      id: id,
      headword: headword,
      ipaUk: ipaUk,
      ipaUs: ipaUs,
      source: source,
      sourceUrl: sourceUrl,
      license: license,
      attribution: attribution,
      senses: senses,
      forms: forms,
      phrases: phrases,
      relatedWords: relatedWords,
      audioUk: audioUk,
      audioUs: audioUs,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }
}

class SearchResult {
  const SearchResult({
    required this.id,
    required this.headword,
    required this.partOfSpeech,
    required this.definition,
    required this.translationZh,
    required this.matchKind,
    required this.score,
  });

  final int id;
  final String headword;
  final String partOfSpeech;
  final String definition;
  final String translationZh;
  final String matchKind;
  final double score;
}

class HistoryRecord {
  const HistoryRecord({
    required this.id,
    required this.entryId,
    required this.headword,
    required this.query,
    required this.viewedAt,
  });

  final int id;
  final int entryId;
  final String headword;
  final String query;
  final DateTime viewedAt;
}

class PackInfo {
  const PackInfo({
    required this.version,
    required this.activatedAt,
    required this.path,
  });

  final String version;
  final DateTime activatedAt;
  final String path;
}
