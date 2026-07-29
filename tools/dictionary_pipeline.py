#!/usr/bin/env python3
"""Build versioned MyDuo packs from Kaikki/Wiktextract JSONL."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import sqlite3
import sys
import zipfile
from collections.abc import Iterable, Iterator
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any

SCHEMA_VERSION = 1


def create_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
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
        CREATE INDEX IF NOT EXISTS idx_senses_entry
          ON senses(entry_id, position);
        CREATE INDEX IF NOT EXISTS idx_senses_zh ON senses(translation_zh);
        CREATE TABLE IF NOT EXISTS forms (
          id INTEGER PRIMARY KEY,
          entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
          form TEXT NOT NULL,
          tags_json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_forms_entry ON forms(entry_id);
        CREATE INDEX IF NOT EXISTS idx_forms_form
          ON forms(form COLLATE NOCASE);
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
        """
    )
    connection.execute(
        "INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)",
        ("schema_version", str(SCHEMA_VERSION)),
    )


def text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [item.strip() for item in value if isinstance(item, str) and item.strip()]


def iter_jsonl(path: Path) -> Iterator[dict[str, Any]]:
    opener: Any
    if path.suffix.lower() == ".gz":
        import gzip

        opener = gzip.open
    else:
        opener = path.open
    with opener(path, "rt", encoding="utf-8") if path.suffix.lower() == ".gz" else opener(
        "r", encoding="utf-8"
    ) as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {error}") from error
            if isinstance(item, dict):
                yield item


def zh_translations(item: dict[str, Any]) -> list[str]:
    found: list[str] = []
    for translation in item.get("translations", []):
        if not isinstance(translation, dict):
            continue
        language = text(translation.get("lang_code")).lower()
        language_name = text(translation.get("lang")).lower()
        if language.startswith("zh") or "chinese" in language_name:
            word = text(translation.get("word"))
            if word and word not in found:
                found.append(word)
    return found


def pick_ipa_and_audio(
    item: dict[str, Any],
    audio_plan: list[dict[str, Any]],
    headword: str,
    source: dict[str, str],
) -> tuple[str, str, str, str]:
    ipa_uk = ""
    ipa_us = ""
    audio_uk = ""
    audio_us = ""
    for sound in item.get("sounds", []):
        if not isinstance(sound, dict):
            continue
        tags = {tag.lower() for tag in string_list(sound.get("tags"))}
        accent = ""
        if tags.intersection({"uk", "british", "received pronunciation"}):
            accent = "uk"
        elif tags.intersection({"us", "american", "general american"}):
            accent = "us"
        ipa = text(sound.get("ipa"))
        if accent == "uk" and ipa and not ipa_uk:
            ipa_uk = ipa
        elif accent == "us" and ipa and not ipa_us:
            ipa_us = ipa
        elif ipa and not ipa_uk:
            ipa_uk = ipa
        elif ipa and not ipa_us:
            ipa_us = ipa

        url = next(
            (
                text(sound.get(key))
                for key in ("mp3_url", "ogg_url", "audio")
                if text(sound.get(key)).startswith(("https://", "http://"))
            ),
            "",
        )
        if not url or not accent:
            continue
        extension = Path(url.split("?", 1)[0]).suffix.lower()
        if extension not in {".mp3", ".ogg", ".wav"}:
            extension = ".ogg"
        relative = (
            f"{accent}/{hashlib.sha256((headword + url).encode()).hexdigest()[:24]}"
            f"{extension}"
        )
        audio_plan.append(
            {
                "headword": headword,
                "accent": accent,
                "url": url,
                "relative_path": relative,
                "source": source["name"],
                "source_url": source["url"],
                "license": source["license"],
                "attribution": source["attribution"],
            }
        )
        if accent == "uk" and not audio_uk:
            audio_uk = relative
        if accent == "us" and not audio_us:
            audio_us = relative
    return ipa_uk, ipa_us, audio_uk, audio_us


def extract_senses(
    item: dict[str, Any], translations: list[str]
) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    part_of_speech = text(item.get("pos"))
    for index, raw_sense in enumerate(item.get("senses", [])):
        if not isinstance(raw_sense, dict):
            continue
        glosses = string_list(raw_sense.get("glosses"))
        if not glosses:
            glosses = string_list(raw_sense.get("raw_glosses"))
        definition = "; ".join(glosses)
        if not definition:
            continue
        examples = [
            example
            for example in raw_sense.get("examples", [])
            if isinstance(example, dict)
        ]
        example_en = text(examples[0].get("text")) if examples else ""
        example_zh = (
            text(examples[0].get("translation")) if examples else ""
        )
        sense_translations = zh_translations(raw_sense)
        if not sense_translations and index == 0:
            sense_translations = translations
        result.append(
            {
                "pos": part_of_speech,
                "definition": definition,
                "translation_zh": "；".join(sense_translations),
                "example_en": example_en,
                "example_zh": example_zh,
            }
        )
    return result


def extract_forms(item: dict[str, Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for raw in item.get("forms", []):
        if not isinstance(raw, dict):
            continue
        form = text(raw.get("form"))
        if form:
            result.append(
                {
                    "form": form,
                    "tags": string_list(raw.get("tags"))
                    + string_list(raw.get("raw_tags")),
                }
            )
    return result


def extract_relations(item: dict[str, Any]) -> list[dict[str, str]]:
    relation_keys = {
        "synonyms": "synonym",
        "antonyms": "antonym",
        "hypernyms": "hypernym",
        "hyponyms": "hyponym",
        "derived": "derived",
        "related": "related",
    }
    result: list[dict[str, str]] = []
    for key, relation_type in relation_keys.items():
        for raw in item.get(key, []):
            word = text(raw.get("word")) if isinstance(raw, dict) else text(raw)
            if word:
                result.append({"type": relation_type, "word": word})
    return result


def extract_phrases(item: dict[str, Any]) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    for key in ("proverbs", "compounds"):
        for raw in item.get(key, []):
            if not isinstance(raw, dict):
                continue
            phrase = text(raw.get("word"))
            if not phrase:
                continue
            result.append(
                {
                    "phrase": phrase,
                    "definition": text(raw.get("english")),
                    "translation_zh": "",
                    "example": "",
                }
            )
    return result


def insert_wiktextract_entry(
    connection: sqlite3.Connection,
    item: dict[str, Any],
    source: dict[str, str],
    audio_plan: list[dict[str, Any]],
) -> bool:
    headword = text(item.get("word"))
    language = text(item.get("lang_code")).lower()
    if not headword or language not in {"en", "english"}:
        return False
    translations = zh_translations(item)
    senses = extract_senses(item, translations)
    if not senses:
        return False
    ipa_uk, ipa_us, audio_uk, audio_us = pick_ipa_and_audio(
        item, audio_plan, headword, source
    )
    connection.execute(
        """
        INSERT INTO entries(
          headword, normalized, ipa_uk, ipa_us, audio_uk, audio_us,
          source, source_url, license, attribution
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(headword) DO UPDATE SET
          ipa_uk = CASE WHEN entries.ipa_uk = '' THEN excluded.ipa_uk
                        ELSE entries.ipa_uk END,
          ipa_us = CASE WHEN entries.ipa_us = '' THEN excluded.ipa_us
                        ELSE entries.ipa_us END,
          audio_uk = CASE WHEN entries.audio_uk = '' THEN excluded.audio_uk
                          ELSE entries.audio_uk END,
          audio_us = CASE WHEN entries.audio_us = '' THEN excluded.audio_us
                          ELSE entries.audio_us END
        """,
        (
            headword,
            headword.casefold(),
            ipa_uk,
            ipa_us,
            audio_uk,
            audio_us,
            source["name"],
            source["url"],
            source["license"],
            source["attribution"],
        ),
    )
    entry_id = connection.execute(
        "SELECT id FROM entries WHERE headword = ? COLLATE NOCASE", (headword,)
    ).fetchone()[0]
    position = connection.execute(
        "SELECT COUNT(*) FROM senses WHERE entry_id = ?", (entry_id,)
    ).fetchone()[0]
    for sense in senses:
        connection.execute(
            """
            INSERT INTO senses(
              entry_id, position, pos, definition, translation_zh,
              example_en, example_zh
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                entry_id,
                position,
                sense["pos"],
                sense["definition"],
                sense["translation_zh"],
                sense["example_en"],
                sense["example_zh"],
            ),
        )
        position += 1
    for form in extract_forms(item):
        connection.execute(
            """
            INSERT INTO forms(entry_id, form, tags_json)
            SELECT ?, ?, ? WHERE NOT EXISTS (
              SELECT 1 FROM forms WHERE entry_id = ? AND form = ? COLLATE NOCASE
            )
            """,
            (
                entry_id,
                form["form"],
                json.dumps(form["tags"], ensure_ascii=False),
                entry_id,
                form["form"],
            ),
        )
    for phrase in extract_phrases(item):
        connection.execute(
            """
            INSERT INTO phrases(
              entry_id, phrase, definition, translation_zh, example
            )
            SELECT ?, ?, ?, ?, ? WHERE NOT EXISTS (
              SELECT 1 FROM phrases WHERE entry_id = ? AND phrase = ?
                COLLATE NOCASE
            )
            """,
            (
                entry_id,
                phrase["phrase"],
                phrase["definition"],
                phrase["translation_zh"],
                phrase["example"],
                entry_id,
                phrase["phrase"],
            ),
        )
    for relation in extract_relations(item):
        connection.execute(
            """
            INSERT INTO relations(entry_id, relation_type, word)
            SELECT ?, ?, ? WHERE NOT EXISTS (
              SELECT 1 FROM relations
              WHERE entry_id = ? AND relation_type = ? AND word = ? COLLATE NOCASE
            )
            """,
            (
                entry_id,
                relation["type"],
                relation["word"],
                entry_id,
                relation["type"],
                relation["word"],
            ),
        )
    return True


def rebuild_fts(connection: sqlite3.Connection) -> None:
    connection.execute("DELETE FROM entry_fts")
    connection.execute(
        """
        INSERT INTO entry_fts(
          rowid, headword, forms, definitions, translations, phrases
        )
        SELECT
          e.id,
          e.headword,
          COALESCE((SELECT group_concat(f.form, ' ') FROM forms f
                    WHERE f.entry_id = e.id), ''),
          COALESCE((SELECT group_concat(s.definition, ' ') FROM senses s
                    WHERE s.entry_id = e.id), ''),
          COALESCE((SELECT group_concat(s.translation_zh, ' ') FROM senses s
                    WHERE s.entry_id = e.id), ''),
          COALESCE((SELECT group_concat(
                      p.phrase || ' ' || p.definition || ' ' ||
                      p.translation_zh, ' ')
                    FROM phrases p WHERE p.entry_id = e.id), '')
        FROM entries e
        """
    )


def command_ingest(args: argparse.Namespace) -> None:
    if args.output.exists() and not args.force:
        raise FileExistsError(f"output exists: {args.output}; pass --force")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        args.output.unlink()
    source = {
        "name": args.source_name,
        "url": args.source_url,
        "license": args.license,
        "attribution": args.attribution,
    }
    audio_plan: list[dict[str, Any]] = []
    connection = sqlite3.connect(args.output)
    connection.execute("PRAGMA journal_mode = WAL")
    connection.execute("PRAGMA synchronous = NORMAL")
    connection.execute("PRAGMA temp_store = MEMORY")
    create_schema(connection)
    connection.commit()
    accepted = 0
    scanned = 0
    try:
        connection.execute("BEGIN IMMEDIATE")
        for item in iter_jsonl(args.input):
            scanned += 1
            inserted = insert_wiktextract_entry(
                connection, item, source, audio_plan
            )
            if inserted:
                accepted += 1
            if inserted and accepted % args.commit_every == 0:
                connection.commit()
                connection.execute("BEGIN IMMEDIATE")
            if args.limit and scanned >= args.limit:
                break
        rebuild_fts(connection)
        connection.execute(
            "INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)",
            ("pack_version", args.version),
        )
        connection.execute(
            "INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)",
            ("source_json", json.dumps(source, ensure_ascii=False)),
        )
        connection.execute(
            "INSERT OR REPLACE INTO metadata(key, value) VALUES (?, ?)",
            ("source_dump_date", args.dump_date),
        )
        connection.commit()
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"SQLite integrity_check failed: {integrity}")
        if "ENABLE_FTS5" not in {
            row[0] for row in connection.execute("PRAGMA compile_options")
        }:
            connection.execute("SELECT rowid FROM entry_fts LIMIT 1").fetchall()
    finally:
        connection.close()
    if args.audio_plan:
        args.audio_plan.parent.mkdir(parents=True, exist_ok=True)
        with args.audio_plan.open("w", encoding="utf-8", newline="\n") as target:
            for item in audio_plan:
                target.write(json.dumps(item, ensure_ascii=False) + "\n")
    print(
        json.dumps(
            {
                "scanned": scanned,
                "accepted": accepted,
                "audio_candidates": len(audio_plan),
                "output": str(args.output),
                "sha256": hash_file(args.output),
            },
            ensure_ascii=False,
        )
    )


def export_entry(connection: sqlite3.Connection, entry_id: int) -> dict[str, Any]:
    connection.row_factory = sqlite3.Row
    row = connection.execute(
        "SELECT * FROM entries WHERE id = ?", (entry_id,)
    ).fetchone()
    if row is None:
        raise KeyError(entry_id)
    entry: dict[str, Any] = {
        "headword": row["headword"],
        "ipa_uk": row["ipa_uk"],
        "ipa_us": row["ipa_us"],
        "audio_uk": row["audio_uk"],
        "audio_us": row["audio_us"],
        "source": row["source"],
        "source_url": row["source_url"],
        "license": row["license"],
        "attribution": row["attribution"],
        "senses": [],
        "forms": [],
        "phrases": [],
        "relations": [],
    }
    for sense in connection.execute(
        "SELECT * FROM senses WHERE entry_id = ? ORDER BY position", (entry_id,)
    ):
        entry["senses"].append(
            {
                "pos": sense["pos"],
                "definition": sense["definition"],
                "translation_zh": sense["translation_zh"],
                "example_en": sense["example_en"],
                "example_zh": sense["example_zh"],
            }
        )
    for form in connection.execute(
        "SELECT * FROM forms WHERE entry_id = ? ORDER BY id", (entry_id,)
    ):
        entry["forms"].append(
            {"form": form["form"], "tags": json.loads(form["tags_json"])}
        )
    for phrase in connection.execute(
        "SELECT * FROM phrases WHERE entry_id = ? ORDER BY id", (entry_id,)
    ):
        entry["phrases"].append(
            {
                "phrase": phrase["phrase"],
                "definition": phrase["definition"],
                "translation_zh": phrase["translation_zh"],
                "example": phrase["example"],
            }
        )
    for relation in connection.execute(
        "SELECT * FROM relations WHERE entry_id = ? ORDER BY id", (entry_id,)
    ):
        entry["relations"].append(
            {"type": relation["relation_type"], "word": relation["word"]}
        )
    return entry


def entry_digest(entry: dict[str, Any]) -> str:
    canonical = json.dumps(
        entry, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def database_entries(
    connection: sqlite3.Connection,
) -> dict[str, tuple[int, str]]:
    result: dict[str, tuple[int, str]] = {}
    for entry_id, headword in connection.execute(
        "SELECT id, headword FROM entries ORDER BY headword"
    ):
        exported = export_entry(connection, entry_id)
        result[headword.casefold()] = (entry_id, entry_digest(exported))
    return result


def command_delta(args: argparse.Namespace) -> None:
    base = sqlite3.connect(f"file:{args.base}?mode=ro", uri=True)
    target = sqlite3.connect(f"file:{args.target}?mode=ro", uri=True)
    try:
        base_entries = database_entries(base)
        target_entries = database_entries(target)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        operations = 0
        with args.output.open("w", encoding="utf-8", newline="\n") as output:
            for normalized in sorted(base_entries.keys() - target_entries.keys()):
                entry = export_entry(base, base_entries[normalized][0])
                output.write(
                    json.dumps(
                        {"op": "delete", "headword": entry["headword"]},
                        ensure_ascii=False,
                    )
                    + "\n"
                )
                operations += 1
            for normalized in sorted(target_entries):
                target_id, target_hash = target_entries[normalized]
                if (
                    normalized not in base_entries
                    or base_entries[normalized][1] != target_hash
                ):
                    output.write(
                        json.dumps(
                            {
                                "op": "upsert",
                                "entry": export_entry(target, target_id),
                            },
                            ensure_ascii=False,
                        )
                        + "\n"
                    )
                    operations += 1
    finally:
        base.close()
        target.close()
    print(
        json.dumps(
            {
                "operations": operations,
                "output": str(args.output),
                "sha256": hash_file(args.output),
            }
        )
    )


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_artifact(value: str, version: str) -> dict[str, Any]:
    parts = value.split("|")
    if len(parts) < 3:
        raise argparse.ArgumentTypeError(
            "artifact must be KIND|FORMAT|PATH[|FROM_VERSION|ACCENT]"
        )
    path = Path(parts[2]).resolve()
    if not path.is_file():
        raise FileNotFoundError(path)
    return {
        "kind": parts[0],
        "format": parts[1],
        "url": path.name,
        "sha256": hash_file(path),
        "size": path.stat().st_size,
        "version": version,
        "from_version": parts[3] if len(parts) > 3 else "",
        "accent": parts[4] if len(parts) > 4 else "",
    }


def parse_source(value: str) -> dict[str, str]:
    parts = value.split("|")
    if len(parts) < 3:
        raise argparse.ArgumentTypeError(
            "source must be NAME|URL|LICENSE[|DUMP_DATE|ATTRIBUTION]"
        )
    return {
        "name": parts[0],
        "url": parts[1],
        "license": parts[2],
        "dump_date": parts[3] if len(parts) > 3 else "",
        "attribution": parts[4] if len(parts) > 4 else "",
    }


def command_manifest(args: argparse.Namespace) -> None:
    manifest = {
        "schema": 1,
        "version": args.version,
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "artifacts": [
            parse_artifact(value, args.version) for value in args.artifact
        ],
        "sources": [parse_source(value) for value in args.source],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(f"manifest={args.output} sha256={hash_file(args.output)}")


def load_private_key(path: Path) -> Any:
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import (
            Ed25519PrivateKey,
        )
    except ImportError as error:
        raise RuntimeError(
            "Install signing dependency: py -m pip install -r "
            "tools/requirements-tools.txt"
        ) from error
    raw = path.read_bytes()
    if raw.startswith(b"-----BEGIN"):
        return serialization.load_pem_private_key(raw, password=None)
    decoded = base64.b64decode(raw.strip(), validate=True)
    if len(decoded) != 32:
        raise ValueError("raw Ed25519 private key must contain 32 bytes")
    return Ed25519PrivateKey.from_private_bytes(decoded)


def load_public_key(value: str) -> Any:
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import (
            Ed25519PublicKey,
        )
    except ImportError as error:
        raise RuntimeError(
            "Install signing dependency: py -m pip install -r "
            "tools/requirements-tools.txt"
        ) from error
    possible_path = Path(value)
    raw = possible_path.read_bytes() if possible_path.is_file() else value.encode()
    if raw.startswith(b"-----BEGIN"):
        return serialization.load_pem_public_key(raw)
    decoded = base64.b64decode(raw.strip(), validate=True)
    if len(decoded) != 32:
        raise ValueError("raw Ed25519 public key must contain 32 bytes")
    return Ed25519PublicKey.from_public_bytes(decoded)


def command_sign(args: argparse.Namespace) -> None:
    private_key = load_private_key(args.private_key)
    signature = private_key.sign(args.manifest.read_bytes())
    output = args.output or Path(f"{args.manifest}.sig")
    output.write_text(base64.b64encode(signature).decode("ascii") + "\n")
    print(f"signature={output}")


def command_verify(args: argparse.Namespace) -> None:
    public_key = load_public_key(args.public_key)
    signature = base64.b64decode(args.signature.read_text().strip(), validate=True)
    public_key.verify(signature, args.manifest.read_bytes())
    print("Ed25519 signature valid")


def command_keygen(args: argparse.Namespace) -> None:
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import (
            Ed25519PrivateKey,
        )
    except ImportError as error:
        raise RuntimeError(
            "Install signing dependency: py -m pip install -r "
            "tools/requirements-tools.txt"
        ) from error
    for path in (args.private_key, args.public_key):
        if path.exists():
            raise FileExistsError(f"refusing to overwrite key: {path}")
        path.parent.mkdir(parents=True, exist_ok=True)
    private_key = Ed25519PrivateKey.generate()
    private_bytes = private_key.private_bytes(
        serialization.Encoding.Raw,
        serialization.PrivateFormat.Raw,
        serialization.NoEncryption(),
    )
    public_bytes = private_key.public_key().public_bytes(
        serialization.Encoding.Raw,
        serialization.PublicFormat.Raw,
    )
    args.private_key.write_text(base64.b64encode(private_bytes).decode() + "\n")
    args.public_key.write_text(base64.b64encode(public_bytes).decode() + "\n")
    print(f"private_key={args.private_key}")
    print(f"public_key={args.public_key}")


def safe_plan_relative_path(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"unsafe audio path: {value}")
    return path


def command_audio_pack(args: argparse.Namespace) -> None:
    records = [
        record
        for record in iter_jsonl(args.plan)
        if text(record.get("accent")) == args.accent
    ]
    manifest_files: list[dict[str, Any]] = []
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(
        args.output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
    ) as archive:
        for record in records:
            relative = safe_plan_relative_path(text(record.get("relative_path")))
            source = (args.input_dir / Path(*relative.parts)).resolve()
            if not source.is_file() or args.input_dir.resolve() not in source.parents:
                raise FileNotFoundError(source)
            archive_path = relative
            if archive_path.parts and archive_path.parts[0] == args.accent:
                archive_path = PurePosixPath(*archive_path.parts[1:])
            if not archive_path.parts:
                raise ValueError(f"invalid audio path: {relative}")
            archive.write(source, archive_path.as_posix())
            manifest_files.append(
                {
                    "path": archive_path.as_posix(),
                    "sha256": hash_file(source),
                    "size": source.stat().st_size,
                    "headword": text(record.get("headword")),
                    "accent": text(record.get("accent")),
                    "source": text(record.get("source")),
                    "source_url": text(record.get("source_url")),
                    "license": text(record.get("license")),
                    "attribution": text(record.get("attribution")),
                }
            )
        audio_manifest = {
            "schema": 1,
            "version": args.version,
            "files": manifest_files,
        }
        archive.writestr(
            "audio_manifest.json",
            json.dumps(audio_manifest, ensure_ascii=False, indent=2) + "\n",
        )
    print(
        f"audio_pack={args.output} files={len(manifest_files)} "
        f"sha256={hash_file(args.output)}"
    )


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)

    ingest = commands.add_parser("ingest", help="ingest Wiktextract JSONL")
    ingest.add_argument("--input", type=Path, required=True)
    ingest.add_argument("--output", type=Path, required=True)
    ingest.add_argument("--version", required=True)
    ingest.add_argument("--source-name", required=True)
    ingest.add_argument("--source-url", required=True)
    ingest.add_argument("--license", required=True)
    ingest.add_argument("--attribution", required=True)
    ingest.add_argument("--dump-date", required=True)
    ingest.add_argument("--audio-plan", type=Path)
    ingest.add_argument("--limit", type=int, default=0)
    ingest.add_argument("--commit-every", type=int, default=5000)
    ingest.add_argument("--force", action="store_true")
    ingest.set_defaults(handler=command_ingest)

    delta = commands.add_parser("delta", help="create incremental JSONL")
    delta.add_argument("--base", type=Path, required=True)
    delta.add_argument("--target", type=Path, required=True)
    delta.add_argument("--output", type=Path, required=True)
    delta.set_defaults(handler=command_delta)

    manifest = commands.add_parser("manifest", help="create pack manifest")
    manifest.add_argument("--version", required=True)
    manifest.add_argument("--output", type=Path, required=True)
    manifest.add_argument("--artifact", action="append", required=True)
    manifest.add_argument("--source", action="append", required=True)
    manifest.set_defaults(handler=command_manifest)

    sign = commands.add_parser("sign", help="sign manifest with Ed25519")
    sign.add_argument("--manifest", type=Path, required=True)
    sign.add_argument("--private-key", type=Path, required=True)
    sign.add_argument("--output", type=Path)
    sign.set_defaults(handler=command_sign)

    verify = commands.add_parser("verify", help="verify detached signature")
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--signature", type=Path, required=True)
    verify.add_argument("--public-key", required=True)
    verify.set_defaults(handler=command_verify)

    keygen = commands.add_parser("keygen", help="generate Ed25519 test keys")
    keygen.add_argument("--private-key", type=Path, required=True)
    keygen.add_argument("--public-key", type=Path, required=True)
    keygen.set_defaults(handler=command_keygen)

    audio = commands.add_parser("audio-pack", help="build licensed audio ZIP")
    audio.add_argument("--plan", type=Path, required=True)
    audio.add_argument("--input-dir", type=Path, required=True)
    audio.add_argument("--output", type=Path, required=True)
    audio.add_argument("--version", required=True)
    audio.add_argument("--accent", choices=("uk", "us"), required=True)
    audio.set_defaults(handler=command_audio_pack)
    return root


def main(argv: Iterable[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        args.handler(args)
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
