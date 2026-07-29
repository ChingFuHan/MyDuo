import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dictionary_controller.dart';
import 'models.dart';
import 'speech_service.dart';

class MyDuoApp extends StatelessWidget {
  const MyDuoApp({super.key, required this.controller});

  final DictionaryController controller;

  @override
  Widget build(BuildContext context) {
    final lightScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff315e7a),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff7fc8eb),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'MyDuo',
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
            systemNavigationBarColor: Theme.of(context).scaffoldBackgroundColor,
            systemNavigationBarIconBrightness:
                dark ? Brightness.light : Brightness.dark,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: lightScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff7f8fa),
        cardTheme: const CardTheme(
          clipBehavior: Clip.antiAlias,
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: lightScheme.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: darkScheme,
        useMaterial3: true,
        cardTheme: const CardTheme(
          clipBehavior: Clip.antiAlias,
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: DictionaryShell(controller: controller),
    );
  }
}

class DictionaryShell extends StatefulWidget {
  const DictionaryShell({super.key, required this.controller});

  final DictionaryController controller;

  @override
  State<DictionaryShell> createState() => _DictionaryShellState();
}

class _DictionaryShellState extends State<DictionaryShell> {
  int _pageIndex = 0;

  Future<void> _openEntry(int id) async {
    setState(() => _pageIndex = 0);
    await widget.controller.selectEntry(id);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final pages = <Widget>[
          SearchPage(controller: controller),
          FavoritesPage(controller: controller, onOpen: _openEntry),
          HistoryPage(controller: controller, onOpen: _openEntry),
          DataPage(controller: controller),
        ];
        return LayoutBuilder(
          builder: (context, constraints) {
            final desktop = constraints.maxWidth >= 900;
            final body = Column(
              children: [
                if (controller.error != null)
                  MaterialBanner(
                    content: Text(controller.error!),
                    leading: const Icon(Icons.error_outline),
                    actions: [
                      TextButton(
                        onPressed: () {
                          controller.clearError();
                        },
                        child: const Text('關閉'),
                      ),
                    ],
                  ),
                if (controller.statusMessage != null &&
                    controller.error == null)
                  _StatusStrip(message: controller.statusMessage!),
                Expanded(
                  child: IndexedStack(index: _pageIndex, children: pages),
                ),
              ],
            );
            if (desktop) {
              return Scaffold(
                body: SafeArea(
                  child: Row(
                    children: [
                      NavigationRail(
                        extended: constraints.maxWidth >= 1180,
                        selectedIndex: _pageIndex,
                        onDestinationSelected: (value) {
                          setState(() => _pageIndex = value);
                          if (value == 1 || value == 2) {
                            controller.refreshCollections();
                          }
                        },
                        leading: const Padding(
                          padding: EdgeInsets.only(bottom: 18),
                          child: _BrandMark(),
                        ),
                        destinations: const [
                          NavigationRailDestination(
                            icon: Icon(Icons.search),
                            selectedIcon: Icon(Icons.manage_search),
                            label: Text('查字'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.bookmark_border),
                            selectedIcon: Icon(Icons.bookmark),
                            label: Text('收藏'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.history),
                            label: Text('歷史'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(Icons.storage_outlined),
                            selectedIcon: Icon(Icons.storage),
                            label: Text('資料包'),
                          ),
                        ],
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: body),
                    ],
                  ),
                ),
              );
            }
            return Scaffold(
              body: SafeArea(child: body),
              bottomNavigationBar: NavigationBar(
                selectedIndex: _pageIndex,
                onDestinationSelected: (value) {
                  setState(() => _pageIndex = value);
                  if (value == 1 || value == 2) {
                    controller.refreshCollections();
                  }
                },
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.search), label: '查字'),
                  NavigationDestination(
                    icon: Icon(Icons.bookmark_border),
                    selectedIcon: Icon(Icons.bookmark),
                    label: '收藏',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.history),
                    label: '歷史',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.storage_outlined),
                    label: '資料包',
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'MyDuo',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Padding(
          padding: EdgeInsets.all(11),
          child: Icon(Icons.menu_book_rounded, size: 28),
        ),
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.offline_bolt_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.controller});

  final DictionaryController controller;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _searchController;
  late final FocusNode _focusNode;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.controller.query);
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 180),
      () => widget.controller.search(value),
    );
  }

  void _searchFor(String word) {
    _searchController.text = word;
    _searchController.selection = TextSelection.collapsed(offset: word.length);
    widget.controller.clearSelection();
    widget.controller.search(word);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (!_focusNode.hasFocus &&
        _searchController.text != controller.query &&
        controller.query.isNotEmpty) {
      _searchController.text = controller.query;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final split = constraints.maxWidth >= 820;
        final searchPanel = Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                split ? 26 : 16,
                20,
                split ? 20 : 16,
                12,
              ),
              child: Row(
                children: [
                  if (!split) ...[
                    const _BrandMark(),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _focusNode,
                      autofocus: !split,
                      textInputAction: TextInputAction.search,
                      onChanged: _onChanged,
                      onSubmitted: controller.search,
                      decoration: InputDecoration(
                        hintText: '輸入英文或繁體中文',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除',
                                onPressed: () {
                                  _searchController.clear();
                                  controller.clearSelection();
                                  controller.search('');
                                  setState(() {});
                                },
                                icon: const Icon(Icons.close),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    controller.query.isEmpty
                        ? '離線詞庫'
                        : '${controller.results.length} 個結果',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const Spacer(),
                  if (controller.busy)
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const Row(
                      children: [
                        Icon(Icons.cloud_off, size: 16),
                        SizedBox(width: 5),
                        Text('離線'),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: controller.results.isEmpty
                  ? const _EmptyState(
                      icon: Icons.search_off,
                      title: '找不到詞條',
                      message: '可嘗試其他拼法或繁中關鍵字。',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                      itemCount: controller.results.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        final result = controller.results[index];
                        return _SearchResultTile(
                          result: result,
                          selected: result.id == controller.selected?.id,
                          onTap: () => controller.selectResult(result),
                        );
                      },
                    ),
            ),
          ],
        );

        if (!split) {
          if (controller.selected != null) {
            return EntryDetail(
              entry: controller.selected!,
              controller: controller,
              onBack: controller.clearSelection,
              onSearch: _searchFor,
            );
          }
          return searchPanel;
        }
        return Row(
          children: [
            SizedBox(width: 390, child: searchPanel),
            const VerticalDivider(width: 1),
            Expanded(
              child: controller.selected == null
                  ? const _DictionaryWelcome()
                  : EntryDetail(
                      entry: controller.selected!,
                      controller: controller,
                      onSearch: _searchFor,
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.result,
    required this.selected,
    required this.onTap,
  });

  final SearchResult result;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.primaryContainer : colors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      result.headword,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  Text(
                    result.matchKind,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.primary,
                        ),
                  ),
                ],
              ),
              if (result.partOfSpeech.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  result.partOfSpeech,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.secondary,
                      ),
                ),
              ],
              if (result.translationZh.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(result.translationZh),
              ],
              if (result.definition.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  result.definition,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DictionaryWelcome extends StatelessWidget {
  const _DictionaryWelcome();

  @override
  Widget build(BuildContext context) {
    return const _EmptyState(
      icon: Icons.auto_stories_outlined,
      title: 'MyDuo',
      message: '選擇詞條查看英英定義、繁中翻譯、IPA、詞形、片語與例句。',
    );
  }
}

class EntryDetail extends StatelessWidget {
  const EntryDetail({
    super.key,
    required this.entry,
    required this.controller,
    this.onBack,
    this.onSearch,
  });

  final DictionaryEntry entry;
  final DictionaryController controller;
  final VoidCallback? onBack;
  final ValueChanged<String>? onSearch;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          automaticallyImplyLeading: false,
          backgroundColor: colors.surface.withOpacity(0.96),
          title: Row(
            children: [
              if (onBack != null)
                IconButton(
                  onPressed: onBack,
                  tooltip: '返回搜尋',
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Text(
                  entry.headword,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: entry.isFavorite ? '移除收藏' : '加入收藏',
              onPressed: controller.toggleFavorite,
              icon: Icon(
                entry.isFavorite ? Icons.bookmark : Icons.bookmark_border,
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 42),
          sliver: SliverList.list(
            children: [
              Text(
                entry.headword,
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1,
                    ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  _PronunciationButton(
                    label: 'UK',
                    ipa: entry.ipaUk,
                    onPressed: () => controller.pronounce(EnglishAccent.uk),
                  ),
                  _PronunciationButton(
                    label: 'US',
                    ipa: entry.ipaUs,
                    onPressed: () => controller.pronounce(EnglishAccent.us),
                  ),
                ],
              ),
              if (entry.forms.isNotEmpty) ...[
                const SizedBox(height: 22),
                const _SectionHeading('詞形'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: entry.forms
                      .map(
                        (form) => Tooltip(
                          message: form.tags.join(' · '),
                          child: ActionChip(
                            label: Text(form.form),
                            onPressed: () => onSearch?.call(form.form),
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
              ],
              const SizedBox(height: 26),
              ...entry.senses.indexed.map(
                (indexed) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _SenseCard(
                    number: indexed.$1 + 1,
                    sense: indexed.$2,
                  ),
                ),
              ),
              if (entry.phrases.isNotEmpty) ...[
                const SizedBox(height: 12),
                const _SectionHeading('片語'),
                const SizedBox(height: 10),
                ...entry.phrases.map(
                  (phrase) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _PhraseCard(phrase: phrase),
                  ),
                ),
              ],
              if (entry.relatedWords.isNotEmpty) ...[
                const SizedBox(height: 18),
                const _SectionHeading('相關詞'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: entry.relatedWords
                      .map(
                        (relation) => ActionChip(
                          avatar: const Icon(Icons.arrow_outward, size: 16),
                          label: Text('${relation.word} · ${relation.type}'),
                          onPressed: () => onSearch?.call(relation.word),
                        ),
                      )
                      .toList(growable: false),
                ),
              ],
              const SizedBox(height: 28),
              Card(
                color: colors.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '來源與授權',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      Text('${entry.source} · ${entry.license}'),
                      if (entry.attribution.isNotEmpty)
                        Text(
                          entry.attribution,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (entry.sourceUrl.isNotEmpty)
                        SelectableText(
                          entry.sourceUrl,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PronunciationButton extends StatelessWidget {
  const _PronunciationButton({
    required this.label,
    required this.ipa,
    required this.onPressed,
  });

  final String label;
  final String ipa;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: const Icon(Icons.volume_up_outlined),
      label: Text('$label  /$ipa/'),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
    );
  }
}

class _SenseCard extends StatelessWidget {
  const _SenseCard({required this.number, required this.sense});

  final int number;
  final DictionarySense sense;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: colors.primaryContainer,
                  child: Text('$number'),
                ),
                const SizedBox(width: 9),
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(sense.partOfSpeech),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              sense.definition,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (sense.translationZh.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                sense.translationZh,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
            if (sense.exampleEn.isNotEmpty) ...[
              const Divider(height: 24),
              Text(
                sense.exampleEn,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
              ),
              if (sense.exampleZh.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  sense.exampleZh,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _PhraseCard extends StatelessWidget {
  const _PhraseCard({required this.phrase});

  final DictionaryPhrase phrase;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        title: Text(
          phrase.phrase,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(phrase.definition),
              if (phrase.translationZh.isNotEmpty)
                Text(
                  phrase.translationZh,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              if (phrase.example.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  phrase.example,
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({
    super.key,
    required this.controller,
    required this.onOpen,
  });

  final DictionaryController controller;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    return _CollectionPage(
      title: '收藏',
      count: controller.favoriteEntries.length,
      empty: const _EmptyState(
        icon: Icons.bookmark_add_outlined,
        title: '尚無收藏',
        message: '在詞條右上角加入收藏，資料會保留在本機。',
      ),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        itemCount: controller.favoriteEntries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final entry = controller.favoriteEntries[index];
          return Card(
            child: ListTile(
              leading: const Icon(Icons.bookmark),
              title: Text(entry.headword),
              subtitle: Text(
                entry.senses.isEmpty ? '' : entry.senses.first.translationZh,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpen(entry.id),
            ),
          );
        },
      ),
    );
  }
}

class HistoryPage extends StatelessWidget {
  const HistoryPage({
    super.key,
    required this.controller,
    required this.onOpen,
  });

  final DictionaryController controller;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    return _CollectionPage(
      title: '歷史',
      count: controller.historyRecords.length,
      action: TextButton.icon(
        onPressed:
            controller.historyRecords.isEmpty ? null : controller.clearHistory,
        icon: const Icon(Icons.delete_sweep_outlined),
        label: const Text('清除'),
      ),
      empty: const _EmptyState(
        icon: Icons.history_toggle_off,
        title: '尚無查詢歷史',
        message: '開啟詞條後，記錄會離線保存在此裝置。',
      ),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        itemCount: controller.historyRecords.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final record = controller.historyRecords[index];
          return Card(
            child: ListTile(
              leading: const Icon(Icons.history),
              title: Text(record.headword),
              subtitle: Text(
                '搜尋：${record.query} · ${_formatTime(record.viewedAt)}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpen(record.entryId),
            ),
          );
        },
      ),
    );
  }

  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _CollectionPage extends StatelessWidget {
  const _CollectionPage({
    required this.title,
    required this.count,
    required this.empty,
    required this.child,
    this.action,
  });

  final String title;
  final int count;
  final Widget empty;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 18, 14),
          child: Row(
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(width: 8),
              Badge(label: Text('$count')),
              const Spacer(),
              if (action != null) action!,
            ],
          ),
        ),
        Expanded(child: count == 0 ? empty : child),
      ],
    );
  }
}

class DataPage extends StatelessWidget {
  const DataPage({super.key, required this.controller});

  final DictionaryController controller;

  @override
  Widget build(BuildContext context) {
    final pack = controller.activePack;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 40),
      children: [
        Text('資料包', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.verified_user_outlined),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '啟用版本 ${pack.version}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('SQLite + FTS5 · 離線可用 · 收藏與歷史分離保存'),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: controller.canUpdate && !controller.busy
                      ? controller.installConfiguredUpdate
                      : null,
                  icon: const Icon(Icons.system_update_alt),
                  label: const Text('檢查已簽章更新'),
                ),
                if (!controller.canUpdate) ...[
                  const SizedBox(height: 10),
                  const Text(
                    '建置時以 --dart-define 設定 MYDUO_PACK_MANIFEST_URL '
                    '與 MYDUO_PACK_PUBLIC_KEY，才會啟用遠端更新。',
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        const _InfoCard(
          icon: Icons.security,
          title: '更新安全',
          body: 'Manifest 必須通過 Ed25519；每個 artifact 另驗 SHA-256 與大小。'
              '下載支援 HTTP Range 續傳；新資料庫先驗 schema/FTS5，再原子切換。'
              '失敗時重新啟用舊版本。',
        ),
        const SizedBox(height: 14),
        const _InfoCard(
          icon: Icons.copyright_outlined,
          title: '來源與授權',
          body: 'Starter 詞條為 CC0 原創示範資料。Kaikki/Wiktextract 資料包必須'
              '逐包保存來源 URL、dump 版本、CC BY-SA/GFDL 授權與 attribution。'
              '本 App 不含 Cambridge 文字、品牌、音檔或版面。',
        ),
        const SizedBox(height: 14),
        const _InfoCard(
          icon: Icons.record_voice_over_outlined,
          title: '發音',
          body: '優先播放授權離線英／美音檔；缺檔時呼叫 Android 系統 TTS 或 '
              'Windows SAPI。離線 voice 是否存在取決於作業系統語音套件。',
        ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(body),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 54,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 14),
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
