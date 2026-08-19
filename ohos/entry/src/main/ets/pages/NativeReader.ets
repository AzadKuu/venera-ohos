import { ImageKnifeComponent, ImageKnifeView, ImageKnifeOption } from '@ohos/imageknifepro';
import { AiSuperResolutionHelper } from '../utils/AiSuperResolutionHelper';
import { Log } from '@ohos/flutter_ohos';
import image from '@ohos.multimedia.image';
import router from '@ohos.router';
import display from '@ohos.display';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';

const TAG = "NativeReader";

@Entry
@Component
struct NativeReader {
  @State currentIndex: number = 0;
  @State showUI: boolean = true;
  @State pageOptions: ImageKnifeOption[] = [];
  @State windowWidthVp: number = 0;
  @State windowHeightVp: number = 0;
  @State statusBarHeightVp: number = 0;
  @State zoomScale: number = 1.0;
  @State panOffsetX: number = 0;
  @State panOffsetY: number = 0;

  private images: string[] = [];
  private title: string = '';
  private enableAiSuperResolution: boolean = false;
  private readerMode: string = 'galleryLeftToRight';
  private limitImageWidth: boolean = true;
  private swiperController: SwiperController = new SwiperController();
  private scroller: Scroller = new Scroller();
  private superResolvedMaps: Map<number, image.PixelMap> = new Map();
  private superResolvedPages: Set<number> = new Set();
  private winInstance: window.Window | null = null;
  private startZoomScale: number = 1.0;
  private startPanOffsetX: number = 0;
  private startPanOffsetY: number = 0;

  private isGallery(): boolean {
    return this.readerMode.startsWith('gallery');
  }

  private isVertical(): boolean {
    return this.readerMode === 'galleryTopToBottom' ||
      this.readerMode === 'continuousTopToBottom';
  }

  private isRightToLeft(): boolean {
    return this.readerMode === 'galleryRightToLeft' ||
      this.readerMode === 'continuousRightToLeft';
  }

  private displayPage(): number {
    if (this.isRightToLeft()) {
      return this.images.length - this.currentIndex;
    }
    return this.currentIndex + 1;
  }

  onBackPress(): boolean {
    router.back();
    return true;
  }

  aboutToAppear() {
    const params = router.getParams() as Record<string, Object>;
    if (params) {
      this.images = (params['images'] as string[]) ?? [];
      this.title = (params['title'] as string) ?? '';
      this.enableAiSuperResolution = (params['enableAiSuperResolution'] as boolean) ?? false;
      this.readerMode = (params['readerMode'] as string) ?? 'galleryLeftToRight';
      this.limitImageWidth = (params['limitImageWidth'] as boolean) ?? true;
      let initialPage = (params['initialPage'] as number) ?? 0;
      if (this.isRightToLeft()) {
        this.images = this.images.reverse();
        initialPage = this.images.length - 1 - initialPage;
      }
      this.currentIndex = Math.max(0, Math.min(initialPage, this.images.length - 1));
    }
    Log.i(TAG, `aboutToAppear: ${this.images.length} images, page=${this.currentIndex}, mode=${this.readerMode}`);

    this.pageOptions = this.images.map((path: string) => {
      const opt = new ImageKnifeOption();
      opt.loadSrc = this.normalizePath(path);
      opt.objectFit = ImageFit.Contain;
      return opt;
    });

    this.preloadSuperResolve(this.currentIndex);
    this.loadWindowSize();
  }

  private normalizePath(path: string): string {
    if (path.startsWith('file://')) {
      return path.substring(7);
    }
    return path;
  }

  private async loadWindowSize() {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const win = await window.getLastWindow(context);
      this.winInstance = win;
      const props = win.getWindowProperties();
      this.windowWidthVp = px2vp(props.windowRect.width);
      this.windowHeightVp = px2vp(props.windowRect.height);
      // 获取状态栏高度：windowRect.top 在全屏模式下为 0，
      // 需要用屏幕物理高度减去窗口高度来计算
      const info = display.getDefaultDisplaySync();
      const displayHeightVp = px2vp(info.height);
      if (props.windowRect.top > 0) {
        this.statusBarHeightVp = px2vp(props.windowRect.top);
      } else {
        this.statusBarHeightVp = Math.max(0, displayHeightVp - this.windowHeightVp);
      }
      win.on('windowSizeChange', (size: window.Size) => {
        this.windowWidthVp = px2vp(size.width);
        this.windowHeightVp = px2vp(size.height);
      });
    } catch (e) {
      try {
        const info = display.getDefaultDisplaySync();
        this.windowWidthVp = px2vp(info.width);
        this.windowHeightVp = px2vp(info.height);
      } catch (_) {}
    }
  }

  private getEffectiveWidth(): number {
    if (this.limitImageWidth &&
        this.readerMode === 'continuousTopToBottom' &&
        this.windowHeightVp > 0 && this.windowWidthVp > 0) {
      // 仅在横屏/近方形屏（宽>=高）时按高度 70% 计算限制宽度
      // 竖屏时返回 0 表示不限制，由 getContinuousImageWidth 走 '100%' 自适应
      if (this.windowHeightVp <= this.windowWidthVp) {
        return this.windowHeightVp * 0.7;
      }
    }
    return 0;
  }

  private getContinuousImageWidth(): string | number {
    if (this.limitImageWidth &&
        this.readerMode === 'continuousTopToBottom') {
      const w = this.getEffectiveWidth();
      // 只在窗口宽度大于限制宽度时启用限制，否则自适应撑满
      if (w > 0 && this.windowWidthVp > w) return w;
    }
    return '100%';
  }

  private async trySuperResolve(pageIndex: number) {
    if (!this.enableAiSuperResolution) return;
    if (this.superResolvedPages.has(pageIndex)) return;
    if (pageIndex < 0 || pageIndex >= this.images.length) return;

    this.superResolvedPages.add(pageIndex);
    const filePath = this.normalizePath(this.images[pageIndex]);

    try {
      const pixelMap = await AiSuperResolutionHelper.getInstance().superResolveFile(filePath);
      if (pixelMap == null) return;
      if (pageIndex >= this.images.length) {
        pixelMap.release();
        return;
      }

      this.superResolvedMaps.set(pageIndex, pixelMap);
      const newOpt = new ImageKnifeOption();
      newOpt.loadSrc = pixelMap;
      newOpt.objectFit = ImageFit.Contain;

      const newOptions: ImageKnifeOption[] = [];
      for (let i = 0; i < this.pageOptions.length; i++) {
        newOptions.push(this.pageOptions[i]);
      }
      newOptions[pageIndex] = newOpt;
      this.pageOptions = newOptions;

      Log.i(TAG, `superResolve ok page=${pageIndex}`);
    } catch (e) {
      Log.e(TAG, `trySuperResolve failed: ${JSON.stringify(e)}`);
    }
  }

  private preloadSuperResolve(pageIndex: number) {
    this.trySuperResolve(pageIndex);
    if (pageIndex + 1 < this.images.length) {
      this.trySuperResolve(pageIndex + 1);
    }
  }

  @Builder
  GalleryMode() {
    Swiper(this.swiperController) {
      ForEach(this.pageOptions, (opt: ImageKnifeOption, index: number) => {
        Stack() {
          ImageKnifeComponent({ imageKnifeOption: opt })
            .width('100%')
            .height('100%')
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .onClick(() => {
          this.showUI = !this.showUI;
        })
      }, (opt: ImageKnifeOption, index: number) => index.toString())
    }
    .index(this.currentIndex)
    .indicator(false)
    .loop(false)
    .duration(250)
    .cachedCount(2)
    .vertical(this.isVertical())
    .onChange((index: number) => {
      this.currentIndex = index;
      this.preloadSuperResolve(index);
    })
    .width('100%')
    .height('100%')
  }

  @Builder
  ContinuousMode() {
    if (this.isVertical()) {
      Stack() {
        Scroll(this.scroller) {
          Column() {
            ForEach(this.pageOptions, (opt: ImageKnifeOption, index: number) => {
              Stack() {
                ImageKnifeView({ imageKnifeOption: opt, adaptable: true })
                  .width('100%')
                  .backgroundColor('#000000')
              }
              .width(this.getContinuousImageWidth())
              .onClick(() => {
                this.showUI = !this.showUI;
              })
            }, (opt: ImageKnifeOption, index: number) => index.toString())
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .scrollable(this.zoomScale <= 1.0 ? ScrollDirection.Vertical : ScrollDirection.None)
      }
      .width('100%')
      .height('100%')
      .scale({ x: this.zoomScale, y: this.zoomScale })
      .translate({ x: this.panOffsetX, y: this.panOffsetY })
      .gesture(
        PinchGesture({ fingers: 2 })
          .onActionStart(() => {
            this.startZoomScale = this.zoomScale;
          })
          .onActionUpdate((e: GestureEvent) => {
            let newScale = this.startZoomScale * e.scale;
            if (newScale < 1.0) newScale = 1.0;
            if (newScale > 4.0) newScale = 4.0;
            this.zoomScale = newScale;
          })
          .onActionEnd(() => {
            if (this.zoomScale <= 1.05) {
              this.zoomScale = 1.0;
              this.panOffsetX = 0;
              this.panOffsetY = 0;
            }
          })
      )
      .parallelGesture(
        PanGesture({ fingers: 1, distance: 10 })
          .onActionStart(() => {
            this.startPanOffsetX = this.panOffsetX;
            this.startPanOffsetY = this.panOffsetY;
          })
          .onActionUpdate((e: GestureEvent) => {
            if (this.zoomScale > 1.0) {
              this.panOffsetX = this.startPanOffsetX + e.offsetX / this.zoomScale;
              this.panOffsetY = this.startPanOffsetY + e.offsetY / this.zoomScale;
            }
          })
      )
    } else {
      List({ scroller: this.scroller }) {
        ForEach(this.pageOptions, (opt: ImageKnifeOption, index: number) => {
          ListItem() {
            ImageKnifeComponent({ imageKnifeOption: opt })
              .width('100%')
              .backgroundColor('#000000')
              .onClick(() => {
                this.showUI = !this.showUI;
              })
          }
        }, (opt: ImageKnifeOption, index: number) => index.toString())
      }
      .width('100%')
      .height('100%')
      .cachedCount(2)
      .scrollBar(BarState.Off)
      .listDirection(Axis.Horizontal)
      .onScrollIndex((start: number, end: number, center: number) => {
        this.currentIndex = center;
        this.preloadSuperResolve(center);
      })
    }
  }

  @Builder
  TopBar() {
    Column() {
      Row() {
        Text('←')
          .fontSize(28)
          .fontColor('#FFFFFF')
          .width(44)
          .height(44)
          .textAlign(TextAlign.Center)
          .margin({ left: 4 })
          .onClick(() => {
            router.back();
          })

        Text(this.title)
          .fontSize(16)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: 8, right: 52 })

        Blank()
          .width(44)
      }
      .width('100%')
      .height(56)
      .alignItems(VerticalAlign.Center)
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [['#80000000', 0], ['#00000000', 1]]
      })

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.statusBarHeightVp })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  BottomBar() {
    Column() {
      Blank()

      Row() {
        Text(`${this.displayPage()} / ${this.images.length}`)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height(48)
      .justifyContent(FlexAlign.Center)
      .linearGradient({
        direction: GradientDirection.Top,
        colors: [['#80000000', 0], ['#00000000', 1]]
      })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    Stack() {
      if (this.isGallery()) {
        this.GalleryMode()
      } else {
        this.ContinuousMode()
      }

      if (this.showUI) {
        this.TopBar()
      }

      if (this.showUI) {
        this.BottomBar()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }

  aboutToDisappear() {
    if (this.winInstance != null) {
      try {
        this.winInstance.off('windowSizeChange');
      } catch (_) {}
    }
    this.superResolvedMaps.forEach((pixelMap: image.PixelMap) => {
      try { pixelMap.release(); } catch (_) {}
    });
    this.superResolvedMaps.clear();
    Log.i(TAG, "aboutToDisappear");
  }
}
