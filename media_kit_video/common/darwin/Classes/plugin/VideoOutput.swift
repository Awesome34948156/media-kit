#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

// This class creates and manipulates the different types of FlutterTexture,
// handles resizing, rendering calls, and notify Flutter when a new frame is
// available to render.
//
// To improve the user experience, a worker is used to execute heavy tasks on a
// dedicated thread.
public class VideoOutput: NSObject {
  // Will be called on the main thread
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void

  // 诊断探针的上报回调（只出声，不改行为）。用来回答日志回答不了的问题：
  // 「iOS 有声黑屏（mpv 从不配视频输出）时，`_updateCallback()` 到底有没有被叫过」。
  // 由 `MediaKitVideoPlugin` 注入，转成 `VideoOutput.Probe` 方法调用回 Dart 侧。
  // Will be called on the main thread.
  public typealias ProbeCallback = ([String: Any]) -> Void

  private static let isSimulator: Bool = {
    let isSim: Bool
    #if targetEnvironment(simulator)
      isSim = true
    #else
      isSim = false
    #endif
    return isSim
  }()

  private let handle: OpaquePointer
  private let enableHardwareAcceleration: Bool
  private let registry: FlutterTextureRegistry
  private let textureUpdateCallback: TextureUpdateCallback
  private let worker: Worker = .init()
  private var width: Int64?
  private var height: Int64?
  private var texture: ResizableTextureProtocol!
  private var textureId: Int64 = -1
  private var currentSize: CGSize = CGSize.zero
  private var disposed: Bool = false
  private let probeCallback: ProbeCallback
  // 本实例创建时刻，用来算 `elapsedMs`。
  private let probeStartedAt: Date = Date()
  // 探针计数：`_updateCallback()` 被调用的次数 / `texture.render(...)` 真正发出的次数。
  private var probeCallbackCount: Int = 0
  private var probeRenderedCount: Int = 0

  init(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback,
    probeCallback: @escaping ProbeCallback
  ) {
    let handle = OpaquePointer(bitPattern: Int(handle))
    assert(handle != nil, "handle casting")

    self.handle = handle!
    width = configuration.width
    height = configuration.height
    enableHardwareAcceleration = configuration.enableHardwareAcceleration
    self.registry = registry
    self.textureUpdateCallback = textureUpdateCallback
    self.probeCallback = probeCallback

    super.init()

    worker.enqueue {
      self._init()
    }
  }

  deinit {
    worker.cancel()

    disposed = true
    disposeTextureId()
  }

  public func setSize(width: Int64?, height: Int64?) {
    worker.enqueue {
      self.width = width
      self.height = height
    }
  }

  // MARK: - 诊断探针（只出声，不改行为）

  // 上报一条探针记录。纯日志，所以走 `DispatchQueue.main.async`：既有
  // `textureUpdateCallback` 那条用的是 `main.sync`（它要和渲染对齐），探针不需要，
  // 用 async 也就没有死锁风险。参数键名：src / n / rendered / configured /
  // elapsedMs / size（宽、高两个数）；`handle` 由插件侧补上。
  private func _probe(_ src: String) {
    let callback = probeCallback
    let n = probeCallbackCount
    let rendered = probeRenderedCount
    let configured = _videoOutConfigured()
    let elapsedMs = Int(Date().timeIntervalSince(probeStartedAt) * 1000)
    let size = currentSize

    DispatchQueue.main.async {
      callback(
        [
          "src": src,
          "n": n,
          "rendered": rendered,
          "configured": configured,
          "elapsedMs": elapsedMs,
          "size": [size.width, size.height],
        ] as [String: Any]
      )
    }
  }

  // mpv 是否已经配上视频输出。必须用 mpv 原始参数判 —— 不能用 `videoSize`：
  // 被钉住时 `videoSize` 返回的就是钉的值，判不出来。
  private func _videoOutConfigured() -> Bool {
    let params = MPVHelpers.getVideoOutParams(handle)
    return params.dw > 0 && params.dh > 0
  }

  // 看门狗：`_init()` 之后 2.5s 查一次，最多 3 次；`disposed` 或已配上即停。
  // 一直没配上就发 `src:"watchdog"`（带上当时的 `n`）—— `n == 0` 就是「回调压根没跑」的铁证，
  // 没有它，日志里的沉默分不清「回调没跑」和「探针没插上」。
  private func _startWatchdog() {
    _scheduleWatchdog(remaining: 3)
  }

  // 试探渲染补完后 300ms 再取一次样：`configured` / `n` / `rendered` 变成什么样，
  // 就是「原生侧这一发渲染到底能不能救」的答案。抽成独立方法 —— 它的 `[weak self]`
  // 不在已强持有 `self` 的闭包词法范围内，不会触发 Swift 6 的 #ImplicitStrongCapture 警告。
  private func _schedulePokeReport() {
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self = self else { return }
      self.worker.enqueue {
        if self.disposed {
          return
        }
        self._probe("poke")
      }
    }
  }

  private func _scheduleWatchdog(remaining: Int) {
    if remaining <= 0 || disposed {
      return
    }

    DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { [weak self] in
      guard let self = self else { return }
      // 在 worker 上取数/上报：`width`/`currentSize`/`texture`/计数器都在 worker 上读写，
      // 走同一条线程既一致又没有数据竞争。
      self.worker.enqueue {
        if self.disposed || self._videoOutConfigured() {
          return
        }

        let isFirstCheck = remaining == 3
        let n = self.probeCallbackCount
        self._probe("watchdog")

        // 回调一次都没跑过 —— 原生侧自己补一发渲染，看能不能把 mpv 撬开（只一发，不是自驱动）。
        // 成不成就是「原生侧到底能不能救」的答案；不成也无害：画面本来空着，这一发渲染的是
        // 1x1 或上次已知尺寸的兜底帧（`2c8dfa71` 既有行为，Dart 侧在真尺寸到之前一直藏着它）。
        if isFirstCheck && n == 0 {
          self._updateCallback()
          self._schedulePokeReport()
        }

        self._scheduleWatchdog(remaining: remaining - 1)
      }
    }
  }

  private func _init() {
    let enableHardwareAcceleration =
      VideoOutput.isSimulator ? false : enableHardwareAcceleration

    NSLog(
      "VideoOutput: enableHardwareAcceleration: \(enableHardwareAcceleration)"
    )

    if VideoOutput.isSimulator {
      NSLog(
        "VideoOutput: warning: hardware rendering is disabled in the iOS simulator, due to an incompatibility with OpenGL ES"
      )
    }

    if enableHardwareAcceleration {
      texture = SafeResizableTexture(
        TextureHW(
          handle: handle,
          // Use `weak self` to prevent memory leaks
          updateCallback: { [weak self]() in
            guard let that = self else {
              return
            }
            that.updateCallback()
          }
        )
      )
    } else {
      texture = SafeResizableTexture(
        TextureSW(
          handle: handle,
          // Use `weak self` to prevent memory leaks
          updateCallback: { [weak self]() in
            guard let that = self else {
              return
            }
            that.updateCallback()
          }
        )
      )
    }

    DispatchQueue.main.sync { [weak self]() in
      guard let that = self else {
        return
      }
      that.registerTextureId()
    }

    // 探针看门狗：视频输出一直配不上时，「安静」是没法区分「回调没跑」和「探针没插上」的。
    _startWatchdog()
  }

  // Must be run on the main thread
  private func registerTextureId() {
    // Textures must be registered on the platform thread.
    textureId = registry.register(texture)
    // textureUpdateCallback must run on the main thread
    textureUpdateCallback(textureId, CGSize(width: 0, height: 0))
  }

  private func disposeTextureId() {
    let registry_ = self.registry
    let textureId_ = self.textureId
    textureId = -1
    DispatchQueue.main.async {
      // Textures must be unregistered on the platform thread
      registry_.unregisterTexture(textureId_)
    }
  }

  public func updateCallback() {
    worker.enqueue {
      self._updateCallback()
    }
  }

  private func _updateCallback() {
    probeCallbackCount += 1
    // 回调入口探针：只在视频输出仍未配上时才探头，且每个实例最多 3 条，防刷屏。
    // 计数超过 3 之后连 mpv 属性都不再查 —— 健康路径上这笔开销只在头 3 次回调里花。
    if probeCallbackCount <= 3, !_videoOutConfigured() {
      _probe("cb")
    }

    var size = videoSize

    // The video output may not be configured yet, in which case mpv reports 0x0
    // via `video-out-params`. Bailing here leaves `mpv_render_context_render`
    // never called, while mpv only fires the update callback once — both sides
    // then wait on each other forever (audio keeps playing, no picture).
    // Fall back to the last known size, or 1x1 for the very first frame: the
    // Dart side already hides a 1-pixel texture until real dimensions arrive,
    // and mpv reconfigures to the real size right after this render.
    if size.width == 0 || size.height == 0 {
      size = currentSize.width > 0 && currentSize.height > 0
          ? currentSize
          : CGSize(width: 1, height: 1)
    }

    if currentSize != size {
      currentSize = size

      texture.resize(size)
      DispatchQueue.main.sync { [weak self] in
        guard let that = self else { return }
        // textureUpdateCallback must run on the main thread
        that.textureUpdateCallback(that.textureId, size)
      }
    }

    if disposed {
      return
    }

    texture.render(size)
    probeRenderedCount += 1
    DispatchQueue.main.sync { [weak self] in
      guard let that = self else { return }
      // Textures must be marked as available from the main thread
      that.registry.textureFrameAvailable(that.textureId)
    }
  }

    private var videoSize: CGSize {
        // fixed size
        if width != nil && height != nil {
            return CGSize(
                width: Double(width!),
                height: Double(height!)
            )
        }
        
        let params = MPVHelpers.getVideoOutParams(handle)
        return CGSize(
            width: Double(width ?? (params.rotate == 0 || params.rotate == 180
                                    ? params.dw
                                    : params.dh)),
            height: Double(height ?? (params.rotate == 0 || params.rotate == 180
                                      ? params.dh
                                      : params.dw))
        )
  }
}
