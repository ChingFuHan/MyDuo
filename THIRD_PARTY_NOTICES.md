# Third-party notices

MyDuo source uses:

- Flutter and Dart SDK — BSD-style licenses; see the selected Flutter SDK.
- `archive` — MIT License.
- `crypto` — BSD-3-Clause.
- `cryptography` — Apache-2.0.
- `http` — BSD-3-Clause.
- `path` — BSD-3-Clause.
- `sqlite3` Dart package — MIT License.
- SQLite — public domain.
- Temurin OpenJDK, Android SDK, Windows SDK, and Visual Studio Build Tools are
  build tools and are governed by their respective licenses.

Exact transitive versions are locked in `pubspec.lock`. Flutter generates its
runtime third-party notice bundle during build.

Kaikki/Wiktextract/Wiktionary data is not committed with this repository.
Any generated dictionary or audio pack must ship its own source-specific
license and attribution notices. See `docs/DATA_PACKS.md`.

Starter entries in `assets/data/seed_entries.json` are original CC0-1.0
demonstration data. See `assets/licenses/STARTER_DATA.md`.
