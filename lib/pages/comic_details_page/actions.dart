part of 'comic_page.dart';

abstract mixin class _ComicPageActions {
  void update();

  ComicDetails get comic;

  ComicSource get comicSource => ComicSource.find(comic.sourceKey)!;

  History? get history;

  bool isLiking = false;

  bool isLiked = false;

  void likeOrUnlike() async {
    if (isLiking) return;
    isLiking = true;
    update();
    var res = await comicSource.likeOrUnlikeComic!(comic.id, isLiked);
    if (res.error) {
      if (!App.rootContext.mounted) return;
      App.rootContext.showMessage(message: res.errorMessage!);
    } else {
      isLiked = !isLiked;
    }
    isLiking = false;
    update();
  }

  /// whether the comic is added to local favorite
  bool isAddToLocalFav = false;

  /// whether the comic is favorite on the server
  bool isFavorite = false;

  FavoriteItem _toFavoriteItem() {
    var tags = <String>[];
    for (var e in comic.tags.entries) {
      tags.addAll(e.value.map((tag) => '${e.key}:$tag'));
    }
    return FavoriteItem(
      id: comic.id,
      name: comic.title,
      coverPath: comic.cover,
      author: comic.subTitle ?? comic.uploader ?? '',
      type: comic.comicType,
      tags: tags,
    );
  }

  void openFavPanel() {
    showSideBar(
      App.rootContext,
      _FavoritePanel(
        cid: comic.id,
        type: comic.comicType,
        isFavorite: isFavorite,
        onFavorite: (local, network) {
          if (network != null) {
            isFavorite = network;
          }
          if (local != null) {
            isAddToLocalFav = local;
          }
          update();
        },
        favoriteItem: _toFavoriteItem(),
        updateTime: comic.findUpdateTime(),
      ),
    );
  }

  void quickFavorite() {
    var folder = appdata.settings['quickFavorite'];
    if (folder is! String) {
      return;
    }
    LocalFavoritesManager().addComic(
      folder,
      _toFavoriteItem(),
      null,
      comic.findUpdateTime(),
    );
    isAddToLocalFav = true;
    update();
    App.rootContext.showMessage(message: "Added".tl);
  }

  void share() {
    final uri = Uri(
      scheme: 'venera',
      host: 'c',
      pathSegments: [comic.sourceKey, comic.id],
    );
    Share.shareText('${comic.title}\n$uri');
  }

  /// read the comic
  ///
  /// [ep] the episode number, start from 1
  ///
  /// [page] the page number, start from 1
  ///
  /// [group] the chapter group number, start from 1
  void read([int? ep, int? page, int? group]) {
    // 原生阅读器：鸿蒙平台 + 设置开关 + 本地漫画时，使用 ArkTS 原生阅读器。
    if (NativeReader.isAvailable && comic.comicType == ComicType.local) {
      _openNativeReader(ep, page, group);
      return;
    }
    _openFlutterReader(ep, page, group);
  }

  /// 打开原生阅读器（ArkTS + @ohos/imageknifepro + AI 超分）。
  void _openNativeReader([int? ep, int? page, int? group]) async {
    final chapterEp = ep ?? 1;
    try {
      final images = await LocalManager().getImages(
        comic.id,
        comic.comicType,
        chapterEp,
      );
      if (images.isEmpty) {
        _openFlutterReader(ep, page, group);
        return;
      }
      final initialPage = (page != null && page > 0) ? page - 1 : 0;
      final enableAiSuperResolution =
          appdata.settings['enableAiSuperResolution'] == true;
      final readerMode = appdata.settings['readerMode'] as String? ?? 'galleryLeftToRight';
      final limitImageWidth = appdata.settings['limitImageWidth'] == true;
      final opened = await NativeReader.open(
        images: images,
        initialPage: initialPage,
        title: comic.title,
        enableAiSuperResolution: enableAiSuperResolution,
        readerMode: readerMode,
        limitImageWidth: limitImageWidth,
      );
      if (!opened) {
        // 原生阅读器打开失败，fallback 到 Flutter 阅读器
        _openFlutterReader(ep, page, group);
      }
    } catch (e) {
      Log.error("ComicPage", "native reader failed, fallback: $e");
      _openFlutterReader(ep, page, group);
    }
  }

  /// 打开 Flutter 阅读器（原有逻辑）。
  void _openFlutterReader([int? ep, int? page, int? group]) {
    App.rootContext
        .to(
          () => Reader(
            type: comic.comicType,
            cid: comic.id,
            name: comic.title,
            chapters: comic.chapters,
            initialChapter: ep,
            initialPage: page,
            initialChapterGroup: group,
            history: history ?? History.fromModel(model: comic, ep: 0, page: 0),
            author: comic.findAuthor() ?? '',
            tags: comic.plainTags,
          ),
        )
        .then((_) {
          onReadEnd();
        });
  }

  void continueRead() {
    var ep = history?.ep ?? 1;
    var page = history?.page ?? 1;
    var group = history?.group ?? 1;
    read(ep, page, group);
  }

  void onReadEnd();

  void download() async {
    if (LocalManager().isDownloading(comic.id, comic.comicType)) {
      App.rootContext.showMessage(message: "The comic is downloading".tl);
      return;
    }
    if (comic.chapters == null &&
        LocalManager().isDownloaded(comic.id, comic.comicType, 0)) {
      App.rootContext.showMessage(message: "The comic is downloaded".tl);
      return;
    }

    if (comicSource.archiveDownloader != null) {
      bool useNormalDownload = false;
      List<ArchiveInfo>? archives;
      int selected = -1;
      bool isLoading = false;
      bool isGettingLink = false;
      await showDialog(
        context: App.rootContext,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setState) {
              return ContentDialog(
                title: "Download".tl,
                content: RadioGroup<int>(
                  groupValue: selected,
                  onChanged: (v) {
                    setState(() {
                      selected = v ?? selected;
                    });
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<int>(value: -1, title: Text("Normal".tl)),
                      ExpansionTile(
                        title: Text("Archive".tl),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        collapsedShape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        onExpansionChanged: (b) {
                          if (!isLoading && b && archives == null) {
                            isLoading = true;
                            comicSource.archiveDownloader!
                                .getArchives(comic.id)
                                .then((value) {
                                  if (value.success) {
                                    archives = value.data;
                                  } else {
                                    if (!App.rootContext.mounted) return;
                                    App.rootContext.showMessage(
                                      message: value.errorMessage!,
                                    );
                                  }
                                  setState(() {
                                    isLoading = false;
                                  });
                                });
                          }
                        },
                        children: [
                          if (archives == null)
                            const ListLoadingIndicator().toCenter()
                          else
                            for (int i = 0; i < archives!.length; i++)
                              RadioListTile<int>(
                                value: i,
                                title: Text(archives![i].title),
                                subtitle: Text(archives![i].description),
                              ),
                        ],
                      ),
                    ],
                  ),
                ),
                actions: [
                  Button.filled(
                    isLoading: isGettingLink,
                    onPressed: () async {
                      if (selected == -1) {
                        useNormalDownload = true;
                        context.pop();
                        return;
                      }
                      setState(() {
                        isGettingLink = true;
                      });
                      var res = await comicSource.archiveDownloader!
                          .getDownloadUrl(comic.id, archives![selected].id);
                      if (res.error) {
                        if (!App.rootContext.mounted) return;
                        App.rootContext.showMessage(message: res.errorMessage!);
                        setState(() {
                          isGettingLink = false;
                        });
                      } else if (context.mounted) {
                        if (res.data.isNotEmpty) {
                          LocalManager().addTask(
                            ArchiveDownloadTask(res.data, comic),
                          );
                          App.rootContext.showMessage(
                            message: "Download started".tl,
                          );
                        }
                        context.pop();
                      }
                    },
                    child: Text("Confirm".tl),
                  ),
                ],
              );
            },
          );
        },
      );
      if (!useNormalDownload) {
        return;
      }
    }

    if (comic.chapters == null) {
      LocalManager().addTask(
        ImagesDownloadTask(
          source: comicSource,
          comicId: comic.id,
          comic: comic,
        ),
      );
    } else {
      List<int>? selected;
      var downloaded = <int>[];
      var localComic = LocalManager().find(comic.id, comic.comicType);
      if (localComic != null) {
        for (int i = 0; i < comic.chapters!.length; i++) {
          if (localComic.downloadedChapters.contains(
            comic.chapters!.ids.elementAt(i),
          )) {
            downloaded.add(i);
          }
        }
      }
      if (!App.rootContext.mounted) return;
      await showSideBar(
        App.rootContext,
        _SelectDownloadChapter(
          comic.chapters!.titles.toList(),
          (v) => selected = v,
          downloaded,
        ),
      );
      if (selected == null) return;
      if (!App.rootContext.mounted) return;
      LocalManager().addTask(
        ImagesDownloadTask(
          source: comicSource,
          comicId: comic.id,
          comic: comic,
          chapters: selected!.map((i) {
            return comic.chapters!.ids.elementAt(i);
          }).toList(),
        ),
      );
    }
    if (!App.rootContext.mounted) return;
    App.rootContext.showMessage(message: "Download started".tl);
    update();
  }

  void onTapTag(String tag, String namespace) {
    var target = comicSource.handleClickTagEvent?.call(namespace, tag);
    var context = App.mainNavigatorKey!.currentContext!;
    target?.jump(context);
  }

  void showMoreActions() {
    var context = App.rootContext;
    showMenuX(context, Offset(context.width - 16, context.padding.top), [
      MenuEntry(
        icon: Icons.copy,
        text: "Copy Title".tl,
        onClick: () {
          Clipboard.setData(ClipboardData(text: comic.title));
          context.showMessage(message: "Copied".tl);
        },
      ),
      MenuEntry(
        icon: Icons.copy_rounded,
        text: "Copy ID".tl,
        onClick: () {
          Clipboard.setData(ClipboardData(text: comic.id));
          context.showMessage(message: "Copied".tl);
        },
      ),
      if (comic.url != null)
        MenuEntry(
          icon: Icons.link,
          text: "Copy URL".tl,
          onClick: () {
            Clipboard.setData(ClipboardData(text: comic.url!));
            context.showMessage(message: "Copied".tl);
          },
        ),
      if (comic.url != null)
        MenuEntry(
          icon: Icons.open_in_browser,
          text: "Open in Browser".tl,
          onClick: () {
            launchUrlString(comic.url!);
          },
        ),
    ]);
  }

  void showComments() {
    showSideBar(
      App.rootContext,
      CommentsPage(data: comic, source: comicSource),
    );
  }

  void starRating() {
    if (!comicSource.isLogged) {
      return;
    }
    var rating = 0.0;
    var isLoading = false;
    showDialog(
      context: App.rootContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => SimpleDialog(
          title: const Text("Rating"),
          alignment: Alignment.center,
          children: [
            SizedBox(
              height: 100,
              child: Center(
                child: SizedBox(
                  width: 210,
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      RatingWidget(
                        padding: 2,
                        onRatingUpdate: (value) => rating = value,
                        value: 1,
                        selectable: true,
                        size: 40,
                      ),
                      const Spacer(),
                      Button.filled(
                        isLoading: isLoading,
                        onPressed: () {
                          setState(() {
                            isLoading = true;
                          });
                          comicSource.starRatingFunc!(comic.id, rating.round())
                              .then((value) {
                                if (value.success) {
                                  if (!App.rootContext.mounted) return;
                                  App.rootContext.showMessage(
                                    message: "Success".tl,
                                  );
                                  Navigator.of(dialogContext).pop();
                                } else {
                                  if (!App.rootContext.mounted) return;
                                  App.rootContext.showMessage(
                                    message: value.errorMessage!,
                                  );
                                  if (!context.mounted) return;
                                  setState(() {
                                    isLoading = false;
                                  });
                                }
                              });
                        },
                        child: Text("Submit".tl),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
