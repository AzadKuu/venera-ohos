import image from '@ohos.multimedia.image';
import imageSuperResolution from '@hms.ai.vision.imageSuperResolution';
import visionBase from '@hms.ai.vision.visionBase';
import { Log } from '@ohos/flutter_ohos';
import fs from '@ohos.file.fs';

const TAG = "AiSuperResolutionHelper";

/**
 * AI 超分工具类。从 EntryAbility 提取，供 Flutter 侧（MethodChannel）
 * 和原生阅读器（NativeReader.ets）共用。
 *
 * 引擎实例懒加载并复用（模型加载开销大），随 Ability 生命周期存在。
 * 请求串行排队：Core Vision 端侧引擎不支持并发推理。
 */
export class AiSuperResolutionHelper {
  private static instance: AiSuperResolutionHelper | null = null;

  static getInstance(): AiSuperResolutionHelper {
    if (AiSuperResolutionHelper.instance == null) {
      AiSuperResolutionHelper.instance = new AiSuperResolutionHelper();
    }
    return AiSuperResolutionHelper.instance!;
  }

  /** AI 超分引擎实例，懒加载。 */
  private analyzer: imageSuperResolution.ImageSRAnalyzer | null = null;

  /** 请求串行队列。端侧引擎不支持并发推理。 */
  private queue: Promise<void> = Promise.resolve();

  /** 是否已初始化文件缓存（避免重复初始化）。 */
  private _enabled: boolean = true;

  /**
   * 提交一次超分请求到队列。返回 Promise<Uint8Array | null>。
   * 调用方不需要 await queue，内部自动排队。
   */
  enqueue(buffer: ArrayBuffer): Promise<Uint8Array | null> {
    return new Promise((resolve) => {
      this.queue = this.queue.then(async () => {
        const out = await this.superResolve(buffer);
        resolve(out);
      }).catch((err: Error) => {
        Log.e(TAG, "enqueue failed: " + JSON.stringify(err));
        resolve(null);
      });
    });
  }

  /**
   * 执行一次 AI 超分。输入原图字节，输出增强后的 JPEG 字节；失败返回 null。
   */
  private async superResolve(buffer: ArrayBuffer): Promise<Uint8Array | null> {
    if (!this._enabled) return null;

    // STEP 1: 创建引擎
    if (this.analyzer == null) {
      try {
        Log.i(TAG, "superResolve STEP=create begin");
        this.analyzer = await imageSuperResolution.ImageSRAnalyzer.create();
        Log.i(TAG, "superResolve STEP=create ok");
      } catch (e) {
        Log.e(TAG, "superResolve error STEP=create: " + JSON.stringify(e));
        this._enabled = false;
        return null;
      }
    }

    // STEP 2: 解码输入图
    let pixelMap: image.PixelMap;
    try {
      const source = image.createImageSource(buffer);
      pixelMap = await source.createPixelMap();
    } catch (e) {
      Log.e(TAG, "superResolve error STEP=decode: " + JSON.stringify(e));
      return null;
    }

    // STEP 2b: 大图片跳过超分
    try {
      const info = pixelMap.getImageInfoSync();
      if (info.size.width >= 1200 || info.size.height >= 1600) {
        pixelMap.release();
        return null;
      }
    } catch (e) {
      // 尺寸检查失败不阻断流程
    }

    // STEP 3: 构造 Request
    let request: visionBase.Request;
    try {
      request = {
        inputData: { pixelMap: pixelMap }
      } as visionBase.Request;
    } catch (e) {
      Log.e(TAG, "superResolve error STEP=newRequest: " + JSON.stringify(e));
      pixelMap.release();
      return null;
    }

    // STEP 4: AI 超分推理
    let response: imageSuperResolution.ISPResponse;
    try {
      response = await this.analyzer.process(request);
    } catch (e) {
      Log.e(TAG, "superResolve error STEP=process: " + JSON.stringify(e));
      pixelMap.release();
      return null;
    }

    // STEP 5: 编码为 JPEG
    try {
      const info = response.pixelMap.getImageInfoSync();
      const bytesNumber = response.pixelMap.getPixelBytesNumber();
      const pixelBuffer = new ArrayBuffer(bytesNumber);
      await response.pixelMap.readPixelsToBuffer(pixelBuffer);
      const stdPixelMap = await image.createPixelMapFromPixels(pixelBuffer, {
        size: { width: info.size.width, height: info.size.height },
        srcPixelFormat: info.pixelFormat,
        pixelFormat: image.PixelMapFormat.RGBA_8888
      });
      const packer = image.createImagePacker();
      const option: image.PackingOption = {
        format: 'image/jpeg',
        quality: 72,
        bufferSize: 100 * 1024 * 1024
      };
      const outBuffer = await packer.packing(stdPixelMap, option);
      packer.release();
      response.pixelMap.release();
      pixelMap.release();
      return new Uint8Array(outBuffer);
    } catch (e) {
      Log.e(TAG, "superResolve error STEP=pack: " + JSON.stringify(e));
      try { response.pixelMap.release(); } catch (_) {}
      try { pixelMap.release(); } catch (_) {}
      return null;
    }
  }

  /**
   * 从文件路径读取图片字节，做超分，返回增强后的 PixelMap。
   * 供 NativeReader 直接使用：先显示原图，后台超分完成后替换。
   * 失败返回 null（调用方保持原图）。
   */
  async superResolveFile(filePath: string): Promise<image.PixelMap | null> {
    try {
      const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);

      const result = await this.enqueue(buffer);
      if (result == null || result.length == 0) return null;

      const source = image.createImageSource(result.buffer);
      const pixelMap = await source.createPixelMap();
      return pixelMap;
    } catch (e) {
      Log.e(TAG, "superResolveFile failed: " + JSON.stringify(e));
      return null;
    }
  }
}
