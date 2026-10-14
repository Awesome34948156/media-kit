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
  // 自驱动剩余次数：钉住尺寸后最多再补 3 发强制渲染（只在「未配上视频输出」时消耗）。
  private var _forcedRenderBudget: Int = 3

  init(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback
  ) {
    let handle = OpaquePointer(bitPattern: Int(handle))
    assert(handle != nil, "handle casting")

    self.handle = handle!
    width = configuration.width
    height = configuration.height
    enableHardwareAcceleration = configuration.enableHardwareAcceleration
    self.registry = registry
    self.textureUpdateCallback = textureUpdateCallback

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
    let isPinned = width != nil && height != nil
    worker.enqueue {
      self.width = width
      self.height = height

      if self.disposed {
        return
      }

      // 钉尺寸本身不驱动 render —— 原生 `setSize` 原来只把尺寸存下来，而真正渲染只发生在
      // `_updateCallback()` 里；当 mpv 压根没配过视频输出、从不触发回调时，光钉尺寸就是空转。
      // 这里补一发强制渲染把死锁撬开：`_updateCallback()` 里 `texture.render(size)` 那行在
      // 尺寸未变时也会执行，所以哪怕尺寸没变也一定会 render 一次。
      self._updateCallback()

      // 只在 app 真的在钉（带的是非空尺寸，说明它已经判定画面没起来）时才自驱动。
      if isPinned {
        self._scheduleForcedRenderNudge()
      }
    }
  }

  // 有限次自驱动：mpv 仍未配上视频输出时，300ms 后再补一发同样的强制渲染，最多 3 次；
  // 配上 / disposed / 到上限即停。计数器是每个实例自己的，只在「未配上」时消耗。
  private func _scheduleForcedRenderNudge() {
    if disposed || _forcedRenderBudget <= 0 || _videoOutConfigured() {
      return
    }

    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self = self else { return }
      self.worker.enqueue {
        if self.disposed || self._forcedRenderBudget <= 0 || self._videoOutConfigured() {
          return
        }
        self._forcedRenderBudget -= 1
        self._updateCallback()
        self._scheduleForcedRenderNudge()
      }
    }
  }

  // mpv 是否已经配上视频输出。必须用 mpv 原始参数判 —— 不能用 `videoSize`：
  // 被钉住时 `videoSize` 返回的就是钉的值，判不出来。
  private func _videoOutConfigured() -> Bool {
    let params = MPVHelpers.getVideoOutParams(handle)
    return params.dw > 0 && params.dh > 0
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
