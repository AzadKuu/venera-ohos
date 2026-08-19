import { ImageKnifeComponent, ImageKnifeOption } from '@ohos/imageknifepro';
import { AiSuperResolutionHelper } from '../utils/AiSuperResolutionHelper';
import { Log } from '@ohos/flutter_ohos';
import image from '@ohos.multimedia.image';
import router from '@ohos.router';

const TAG = "NativeReader";

/**
 * 原生阅读器页面。使用 @ohos/imageknifepro 显示本地漫画图片，
 * 集成 AI 超分（先原图后替换）。
 *
 * 路由参数（router params）：
 * - images: string[]  图片路径数组（file:// 格式或绝对路径）
 * - initialPage: number  初始页码（0-based）
 * - title: string  漫画标题
 * - enableAiSuperResolution: boolean  是否启用 AI 超分
 */
@Entry
@Component
struct NativeReader {
  @State currentIndex: number = 0;
  @State showUI: boolean = true;
  @State pageOptions: ImageKnifeOption[] = [];

  private images: string[] = [];
  private title: string = '';
  private enableAiSuperResolution: boolean = false;
  private swiperController: SwiperController = new SwiperController();
  // 超分后的 PixelMap 缓存：pageIndex -> PixelMap
  private superResolvedMaps: Map<number, image.PixelMap> = new Map();
  // 已超分的页码集合（内部跟踪，不需要触发 UI）
  private superResolvedPages: Set<number> = new Set();

  /** 系统返回键 / 侧滑返回 */
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
      const initialPage = (params['initialPage'] as number) ?? 0;
      this.currentIndex = Math.max(0, Math.min(initialPage, this.images.length - 1));
    }
    Log.i(TAG, `NativeReader aboutToAppear: ${this.images.length} images, page=${this.currentIndex}, aiSr=${this.enableAiSuperResolution}`);

    // 初始化每页的 ImageKnifeOption
    this.pageOptions = this.images.map((path) => {
      const opt = new ImageKnifeOption();
      opt.loadSrc = this.normalizePath(path);
      opt.objectFit = ImageFit.Contain;
      return opt;
    });

    // 预加载初始页面的 AI 超分
    this.preloadSuperResolve(this.currentIndex);
  }

  /** 将 file:// URI 或绝对路径转换为 ImageKnife 可识别的格式。 */
  private normalizePath(path: string): string {
    if (path.startsWith('file://')) {
      return path.substring(7); // 去掉 file:// 前缀，保留绝对路径
    }
    return path;
  }

  /** 对指定页面执行 AI 超分。先显示原图，超分完成后替换。 */
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
      // 更新对应页的 ImageKnifeOption，用超分后的 PixelMap 替换原图
      const newOpt = new ImageKnifeOption();
      newOpt.loadSrc = pixelMap;
      newOpt.objectFit = ImageFit.Contain;

      // 触发 @State 更新
      const newOptions = [...this.pageOptions];
      newOptions[pageIndex] = newOpt;
      this.pageOptions = newOptions;

      Log.i(TAG, `superResolve ok page=${pageIndex}`);
    } catch (e) {
      Log.e(TAG, `trySuperResolve failed page=${pageIndex}: ${JSON.stringify(e)}`);
    }
  }

  /** 预加载相邻页面的超分。 */
  private preloadSuperResolve(pageIndex: number) {
    // 当前页 + 下一页
    this.trySuperResolve(pageIndex);
    if (pageIndex + 1 < this.images.length) {
      this.trySuperResolve(pageIndex + 1);
    }
  }

  build() {
    Stack() {
      // 图片翻页 Swiper
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
            // 点击图片区域切换 UI 显示/隐藏
            this.showUI = !this.showUI;
          })
        }, (opt: ImageKnifeOption, index: number) => index.toString())
      }
      .index(this.currentIndex)
      .indicator(false)
      .loop(false)
      .duration(250)
      .cachedCount(2)
      .onChange((index: number) => {
        this.currentIndex = index;
        this.preloadSuperResolve(index);
      })
      .width('100%')
      .height('100%')

      // 顶部 UI（返回按钮 + 标题）
      if (this.showUI) {
        Column() {
          Row() {
            // 返回按钮
            Text('←')
              .fontSize(28)
              .fontColor('#FFFFFF')
              .width(44)
              .height(44)
              .textAlign(TextAlign.Center)
              .margin({ left: 4 })
              .onClick(() => {
                Log.i(TAG, "back button clicked");
                router.back();
              })

            // 标题
            Text(this.title)
              .fontSize(16)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .margin({ left: 8, right: 52 })

            // 右侧占位（与返回按钮等宽，保持标题视觉居中）
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
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 底部页码
      if (this.showUI) {
        Column() {
          Blank()

          Row() {
            Text(`${this.currentIndex + 1} / ${this.images.length}`)
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }

  aboutToDisappear() {
    // 释放超分 PixelMap 资源
    this.superResolvedMaps.forEach((pixelMap) => {
      try { pixelMap.release(); } catch (_) {}
    });
    this.superResolvedMaps.clear();
    Log.i(TAG, "NativeReader aboutToDisappear");
  }
}
