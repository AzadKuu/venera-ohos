part of 'components.dart';

class PaneItemEntry {
  String label;

  IconData icon;

  IconData activeIcon;

  PaneItemEntry({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });
}

class PaneActionEntry {
  String label;

  IconData icon;

  VoidCallback onTap;

  PaneActionEntry({
    required this.label,
    required this.icon,
    required this.onTap,
  });
}

class NaviPane extends StatefulWidget {
  const NaviPane({
    required this.paneItems,
    required this.paneActions,
    required this.pageBuilder,
    this.initialPage = 0,
    this.onPageChanged,
    required this.observer,
    required this.navigatorKey,
    this.sidebarOnRight = false,
    super.key,
  });

  final List<PaneItemEntry> paneItems;

  final List<PaneActionEntry> paneActions;

  final Widget Function(int page) pageBuilder;

  final void Function(int index)? onPageChanged;

  final int initialPage;

  final NaviObserver observer;

  final GlobalKey<NavigatorState> navigatorKey;

  /// 大屏时侧边栏是否显示在右侧（智感握姿：右手握持时切换为 true）。
  final bool sidebarOnRight;

  @override
  State<NaviPane> createState() => NaviPaneState();

  static NaviPaneState of(BuildContext context) {
    return context.findAncestorStateOfType<NaviPaneState>()!;
  }
}

typedef NaviItemTapListener = void Function(int);

class NaviPaneState extends State<NaviPane>
    with SingleTickerProviderStateMixin {
  bool _canPop = true;

  late int _currentPage = widget.initialPage;

  int get currentPage => _currentPage;

  set currentPage(int value) {
    if (value == _currentPage) return;
    _currentPage = value;
    widget.onPageChanged?.call(value);
  }

  void Function()? mainViewUpdateHandler;

  late AnimationController controller;

  /// 侧边栏方向动画：0 = 左侧（默认），1 = 右侧（右手握持）。
  /// widget.sidebarOnRight 变化时平滑过渡，避免生硬跳变。
  late AnimationController directionController;

  /// 当前顶层页面是否为"内容页"（漫画详情页等）。
  /// 内容页打开时隐藏侧边栏、主视图全屏；仅最外层页面保留侧边栏。
  bool get _isContentFullscreen {
    final routes = widget.observer.routes;
    if (routes.length <= 1) return false;
    final route = routes.last;
    if (route is AppPageRoute) {
      final label = route.label;
      return label == 'ComicPage' || label == 'Reader';
    }
    return false;
  }

  final _naviItemTapListeners = <NaviItemTapListener>[];

  void addNaviItemTapListener(NaviItemTapListener listener) {
    _naviItemTapListeners.add(listener);
  }

  void removeNaviItemTapListener(NaviItemTapListener listener) {
    _naviItemTapListeners.remove(listener);
  }

  static const _kBottomBarHeight = 58.0;

  static const _kFoldedSideBarWidth = 72.0;

  static const _kSideBarWidth = 224.0;

  static const _kTopBarHeight = 48.0;

  double get bottomBarHeight =>
      _kBottomBarHeight + MediaQuery.of(context).padding.bottom;

  void onNavigatorStateChange() {
    // 路由变化（push/pop 内容页）时延迟到下一帧重建，确保
    // AppPageRoute.label（页面类型）已构建就绪后再判断侧边栏显示，
    // 否则刚 push 详情页时 label 为 null 会误判为"非内容页"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
    onRebuild(context);
  }

  void updatePage(int index) {
    for (var listener in _naviItemTapListeners) {
      listener(index);
    }
    if (widget.observer.routes.length > 1) {
      widget.navigatorKey.currentState!.popUntil((route) => route.isFirst);
    }
    if (currentPage == index) {
      return;
    }
    setState(() {
      currentPage = index;
    });
    mainViewUpdateHandler?.call();
  }

  @override
  void initState() {
    controller = AnimationController(
      duration: const Duration(milliseconds: 250),
      lowerBound: 0,
      upperBound: 3,
      vsync: this,
    );
    directionController = AnimationController(
      duration: const Duration(milliseconds: 250),
      lowerBound: 0,
      upperBound: 1,
      value: widget.sidebarOnRight ? 1 : 0,
      vsync: this,
    );
    widget.observer.addListener(onNavigatorStateChange);
    super.initState();
  }

  @override
  void didUpdateWidget(covariant NaviPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 智感握姿方向变化：平滑过渡到新的一侧
    if (oldWidget.sidebarOnRight != widget.sidebarOnRight) {
      directionController.animateTo(widget.sidebarOnRight ? 1 : 0);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    directionController.dispose();
    widget.observer.removeListener(onNavigatorStateChange);
    super.dispose();
  }

  double targetFormContext(BuildContext context) {
    var width = MediaQuery.of(context).size.width;
    double target = 0;
    if (width > changePoint) {
      target = 2;
    }
    if (width > changePoint2) {
      target = 3;
    }
    return target;
  }

  double? animationTarget;

  void onRebuild(BuildContext context) {
    double target = targetFormContext(context);
    if (controller.value != target || animationTarget != target) {
      if (controller.isAnimating) {
        if (animationTarget == target) {
          return;
        } else {
          controller.stop();
        }
      }
      controller.animateTo(target);
      animationTarget = target;
    }
  }

  @override
  Widget build(BuildContext context) {
    onRebuild(context);
    final mq = MediaQuery.of(context);
    final sideInsets = (App.isMobile && mq.orientation == Orientation.landscape)
        ? EdgeInsets.only(
            left: math.max(mq.viewPadding.left, mq.systemGestureInsets.left),
            right: math.max(mq.viewPadding.right, mq.systemGestureInsets.right),
          )
        : EdgeInsets.zero;
    return _NaviPopScope(
      action: () {
        if (App.mainNavigatorKey!.currentState!.canPop()) {
          App.mainNavigatorKey!.currentState!.maybePop();
        } else {
          SystemNavigator.pop();
        }
      },
      popGesture: App.isIOS && context.width >= changePoint,
      child: AnimatedBuilder(
        animation: Listenable.merge([controller, directionController]),
        builder: (context, child) {
          final value = controller.value;
          // 方向动画：0 = 左侧（默认），1 = 右侧（右手握持），平滑过渡
          final d = directionController.value;
          // 内容页（漫画详情页等）打开时隐藏侧边栏、主视图全屏，
          // 仅最外层页面（主页/搜索等）保留侧边栏
          final contentFullscreen = _isContentFullscreen;
          // 侧边栏宽度（大屏展开/折叠）
          final sidebarWidth =
              _kFoldedSideBarWidth +
              (_kSideBarWidth - _kFoldedSideBarWidth) *
                  ((value - 2).clamp(0, 1));
          // 侧边栏基准偏移：大屏 0，窄屏负值移出屏幕
          final sidebarOffset =
              _kFoldedSideBarWidth * ((value - 2.0).clamp(-1.0, 0.0));
          // 内容页全屏：侧边栏完全移出屏幕
          final effSidebarOffset =
              contentFullscreen ? -sidebarWidth : sidebarOffset;
          // 主视图偏移
          final mainOffset =
              _kFoldedSideBarWidth * ((value - 1).clamp(0, 1)) +
              (_kSideBarWidth - _kFoldedSideBarWidth) *
                  ((value - 2).clamp(0, 1));
          final effMainOffset = contentFullscreen ? 0.0 : mainOffset;
          Widget content = LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              // 方向插值：d=0 侧边栏贴左，d=1 侧边栏贴右
              final sidebarLeft = ui.lerpDouble(
                effSidebarOffset,
                w - sidebarWidth - effSidebarOffset,
                d,
              )!;
              final mainLeft = ui.lerpDouble(effMainOffset, 0, d)!;
              final mainRight = ui.lerpDouble(0, effMainOffset, d)!;
              return Stack(
                children: [
                  Positioned(
                    left: sidebarLeft,
                    top: 0,
                    bottom: 0,
                    child: buildLeft(),
                  ),
                  Positioned(
                    // 主视图左右都设置才会拉伸填满剩余区域
                    left: mainLeft,
                    right: mainRight,
                    top: 0,
                    bottom: 0,
                    child: buildMainView(),
                  ),
                ],
              );
            },
          );
          if (sideInsets != EdgeInsets.zero) {
            content = Padding(padding: sideInsets, child: content);
          }
          return content;
        },
      ),
    );
  }

  Widget buildMainView() {
    return HeroControllerScope(
      controller: MaterialApp.createMaterialHeroController(),
      child: PopScope(
        canPop: _canPop,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) {
            return;
          }
          widget.navigatorKey.currentState?.maybePop(result);
        },
        child: NotificationListener<NavigationNotification>(
          onNotification: (NavigationNotification notification) {
            final bool nextCanPop = !notification.canHandlePop;
            if (nextCanPop != _canPop) {
              setState(() {
                _canPop = nextCanPop;
              });
            }
            return false;
          },
          child: Navigator(
            observers: [widget.observer],
            key: widget.navigatorKey,
            onGenerateRoute: (settings) => AppPageRoute(
              preventRebuild: false,
              builder: (context) {
                return _NaviMainView(state: this);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget buildMainViewContent() {
    return widget.pageBuilder(currentPage);
  }

  Widget buildTop() {
    return Material(
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 16),
        height: _kTopBarHeight,
        width: double.infinity,
        child: Row(
          children: [
            Text(
              widget.paneItems[currentPage].label,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            for (var action in widget.paneActions)
              Tooltip(
                message: action.label,
                child: IconButton(
                  icon: Icon(action.icon),
                  onPressed: action.onTap,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget buildBottom() {
    return Material(
      textStyle: Theme.of(context).textTheme.labelSmall,
      elevation: 0,
      child: Container(
        height: _kBottomBarHeight,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1,
            ),
          ),
        ),
        child: Row(
          children: List<Widget>.generate(widget.paneItems.length, (index) {
            return Expanded(
              child: _SingleBottomNaviWidget(
                enabled: currentPage == index,
                entry: widget.paneItems[index],
                onTap: () {
                  updatePage(index);
                },
                key: ValueKey(index),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget buildLeft() {
    final value = controller.value;
    const paddingHorizontal = 12.0;
    return Material(
      child: Container(
        width:
            _kFoldedSideBarWidth +
            (_kSideBarWidth - _kFoldedSideBarWidth) * ((value - 2).clamp(0, 1)),
        height: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: paddingHorizontal),
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1.0,
            ),
          ),
        ),
        child: Column(
          children: [
            DragToMoveArea(
              child: SizedBox(height: 16 + MediaQuery.of(context).padding.top),
            ),
            ...List<Widget>.generate(
              widget.paneItems.length,
              (index) => _SideNaviWidget(
                enabled: currentPage == index,
                entry: widget.paneItems[index],
                showTitle: value == 3,
                onTap: () {
                  updatePage(index);
                },
                key: ValueKey(index),
              ),
            ),
            const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
            ...List<Widget>.generate(
              widget.paneActions.length,
              (index) => _PaneActionWidget(
                entry: widget.paneActions[index],
                showTitle: value == 3,
                key: ValueKey(index + widget.paneItems.length),
              ),
            ),
            const DragToMoveArea(child: SizedBox(height: 16)),
          ],
        ),
      ),
    );
  }
}

class _SideNaviWidget extends StatelessWidget {
  const _SideNaviWidget({
    required this.enabled,
    required this.entry,
    required this.onTap,
    required this.showTitle,
    super.key,
  });

  final bool enabled;

  final PaneItemEntry entry;

  final VoidCallback onTap;

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = Icon(enabled ? entry.activeIcon : entry.icon);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 38,
        decoration: BoxDecoration(
          color: enabled ? colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: showTitle
            ? Row(
                children: [icon, const SizedBox(width: 12), Text(entry.label)],
              )
            : Align(alignment: Alignment.centerLeft, child: icon),
      ),
    ).paddingVertical(4);
  }
}

class _PaneActionWidget extends StatelessWidget {
  const _PaneActionWidget({
    required this.entry,
    required this.showTitle,
    super.key,
  });

  final PaneActionEntry entry;

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(entry.icon);
    return InkWell(
      onTap: entry.onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 38,
        child: showTitle
            ? Row(
                children: [icon, const SizedBox(width: 12), Text(entry.label)],
              )
            : Align(alignment: Alignment.centerLeft, child: icon),
      ),
    ).paddingVertical(4);
  }
}

class _SingleBottomNaviWidget extends StatefulWidget {
  const _SingleBottomNaviWidget({
    required this.enabled,
    required this.entry,
    required this.onTap,
    super.key,
  });

  final bool enabled;

  final PaneItemEntry entry;

  final VoidCallback onTap;

  @override
  State<_SingleBottomNaviWidget> createState() =>
      _SingleBottomNaviWidgetState();
}

class _SingleBottomNaviWidgetState extends State<_SingleBottomNaviWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController controller;

  bool isHovering = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _SingleBottomNaviWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      if (widget.enabled) {
        controller.forward(from: 0);
      } else {
        controller.reverse(from: 1);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      value: widget.enabled ? 1 : 0,
      vsync: this,
      duration: _fastAnimationDuration,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: CurvedAnimation(parent: controller, curve: Curves.ease),
      builder: (context, child) {
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (details) => setState(() => isHovering = true),
          onExit: (details) => setState(() => isHovering = false),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onTap,
            child: buildContent(),
          ),
        );
      },
    );
  }

  Widget buildContent() {
    final value = controller.value;
    final colorScheme = Theme.of(context).colorScheme;
    final icon = Icon(
      widget.enabled ? widget.entry.activeIcon : widget.entry.icon,
    );
    return Center(
      child: Container(
        width: 64,
        height: 28,
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(32)),
          color: isHovering ? colorScheme.surfaceContainer : Colors.transparent,
        ),
        child: Center(
          child: Container(
            width: 32 + value * 32,
            height: 28,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(32)),
              color: value != 0
                  ? colorScheme.secondaryContainer
                  : Colors.transparent,
            ),
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }
}

class NaviObserver extends NavigatorObserver implements Listenable {
  var routes = Queue<Route>();

  int get pageCount {
    int count = 0;
    for (var route in routes) {
      if (route is AppPageRoute) {
        count++;
      }
    }
    return count;
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    routes.removeLast();
    notifyListeners();
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    routes.addLast(route);
    notifyListeners();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    routes.remove(route);
    notifyListeners();
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    routes.remove(oldRoute);
    if (newRoute != null) {
      routes.add(newRoute);
    }
    notifyListeners();
  }

  List<VoidCallback> listeners = [];

  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
  }

  void notifyListeners() {
    for (var listener in listeners) {
      listener();
    }
  }
}

class _NaviPopScope extends StatelessWidget {
  const _NaviPopScope({
    required this.child,
    this.popGesture = false,
    required this.action,
  });

  final Widget child;
  final bool popGesture;
  final VoidCallback action;

  static bool panStartAtEdge = false;

  @override
  Widget build(BuildContext context) {
    Widget res = child;
    if (popGesture) {
      res = GestureDetector(
        onPanStart: (details) {
          if (details.globalPosition.dx < 64) {
            panStartAtEdge = true;
          }
        },
        onPanEnd: (details) {
          if (details.velocity.pixelsPerSecond.dx < 0 ||
              details.velocity.pixelsPerSecond.dx > 0) {
            if (panStartAtEdge) {
              action();
            }
          }
          panStartAtEdge = false;
        },
        child: res,
      );
    }
    return res;
  }
}

class _NaviMainView extends StatefulWidget {
  const _NaviMainView({required this.state});

  final NaviPaneState state;

  @override
  State<_NaviMainView> createState() => _NaviMainViewState();
}

class _NaviMainViewState extends State<_NaviMainView> {
  NaviPaneState get state => widget.state;

  @override
  void initState() {
    state.mainViewUpdateHandler = () {
      setState(() {});
    };
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var shouldShowAppBar = state.controller.value < 2;
    return Column(
      children: [
        if (shouldShowAppBar) state.buildTop().paddingTop(context.padding.top),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: shouldShowAppBar,
            child: AnimatedSwitcher(
              duration: _fastAnimationDuration,
              child: state.buildMainViewContent(),
            ),
          ),
        ),
        if (shouldShowAppBar)
          state.buildBottom().paddingBottom(context.padding.bottom),
      ],
    );
  }
}
