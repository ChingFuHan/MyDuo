from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
import zipfile
from pathlib import Path

from tools import dictionary_pipeline


class DictionaryPipelineTest(unittest.TestCase):
    def test_ingest_builds_searchable_fts5_database(self) -> None:
        project = Path(__file__).resolve().parents[2]
        fixture = project / "tools" / "fixtures" / "kaikki_sample.jsonl"
        with tempfile.TemporaryDirectory(prefix="myduo-pipeline-") as temp:
            output = Path(temp) / "dictionary.sqlite"
            exit_code = dictionary_pipeline.main(
                [
                    "ingest",
                    "--input",
                    str(fixture),
                    "--output",
                    str(output),
                    "--version",
                    "test-1",
                    "--source-name",
                    "Kaikki sample",
                    "--source-url",
                    "https://kaikki.org/",
                    "--license",
                    "CC BY-SA test fixture",
                    "--attribution",
                    "Wiktionary contributors",
                    "--dump-date",
                    "2026-01-01",
                ]
            )
            self.assertEqual(exit_code, 0)
            connection = sqlite3.connect(output)
            try:
                words = [
                    row[0]
                    for row in connection.execute(
                        """
                        SELECT e.headword FROM entry_fts
                        JOIN entries e ON e.id = entry_fts.rowid
                        WHERE entry_fts MATCH '"diction"*'
                        """
                    )
                ]
                self.assertIn("dictionary", words)
                reverse = connection.execute(
                    """
                    SELECT e.headword FROM entries e
                    JOIN senses s ON s.entry_id = e.id
                    WHERE s.translation_zh LIKE '%字典%'
                    """
                ).fetchone()
                self.assertEqual(reverse[0], "dictionary")
                metadata = dict(connection.execute("SELECT key, value FROM metadata"))
                self.assertEqual(metadata["pack_version"], "test-1")
            finally:
                connection.close()

    def test_audio_pack_keeps_provenance_and_accent_relative_path(self) -> None:
        with tempfile.TemporaryDirectory(prefix="myduo-audio-") as temp:
            root = Path(temp)
            audio_dir = root / "audio"
            source = audio_dir / "uk" / "sample.wav"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"RIFF-test-audio")
            plan = root / "plan.jsonl"
            plan.write_text(
                json.dumps(
                    {
                        "headword": "test",
                        "accent": "uk",
                        "relative_path": "uk/sample.wav",
                        "source": "Test",
                        "source_url": "https://example.invalid/audio",
                        "license": "CC0-1.0",
                        "attribution": "Test author",
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            output = root / "audio.zip"
            exit_code = dictionary_pipeline.main(
                [
                    "audio-pack",
                    "--plan",
                    str(plan),
                    "--input-dir",
                    str(audio_dir),
                    "--output",
                    str(output),
                    "--version",
                    "test-1",
                    "--accent",
                    "uk",
                ]
            )
            self.assertEqual(exit_code, 0)
            with zipfile.ZipFile(output) as archive:
                self.assertIn("sample.wav", archive.namelist())
                manifest = json.loads(archive.read("audio_manifest.json"))
                self.assertEqual(manifest["files"][0]["path"], "sample.wav")
                self.assertEqual(
                    manifest["files"][0]["license"],
                    "CC0-1.0",
                )


if __name__ == "__main__":
    unittest.main()
