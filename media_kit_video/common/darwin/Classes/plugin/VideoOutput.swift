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

  // MARK: 常驻探针的字段

  // 计数的写方是 worker（`_updateCallback`），读方是 probeQueue —— 所以一把锁 + 一份
  // 自洽快照（分三次原子读会拼出「n 是新的、size 是旧的」那种组合）。
  private let probeStateLock = NSLock()
  // `_updateCallback()` 被调用的次数 / `texture.render(...)` 真正发出的次数。
  private var probeCallbackCount: Int = 0
  private var probeRenderedCount: Int = 0
  // `currentSize` 的镜像，只在它变化时更新（探针只读这份）。
  private var probeSharedSize: CGSize = .zero

  // 探针自己的两条队列：状态机（probeQueue，**永不进 mpv**）与 mpv 读数（probeReadQueue）。
  // 分成两条是为了「卡住的那一发读不能把状态机一起堵死」—— 读 mpv 属性要拿核锁，
  // 核锁被长持时那一发读永远不回来，状态机得照常活着才能把 `read-blocked` 报出来。
  private let probeQueue = DispatchQueue(label: "media_kit_video.video_output.probe")
  private let probeReadQueue = DispatchQueue(label: "media_kit_video.video_output.probe.read")
  // 节拍器；读超时看门狗平时挂在遥远的未来，只在发出读时排期。
  private var probeTimer: DispatchSourceTimer?
  private var probeReadTimeoutTimer: DispatchSourceTimer?

  private enum ProbePhase { case idle, alerting }

  private static let probeIdlePeriod: TimeInterval = 2.5
  private static let probeAlertPeriod: TimeInterval = 0.5
  // 连续几拍「没动静」才定罪（2 拍 ≈ 5s；健康装载「选流 → 配好输出」三局 85 次实测
  // 0.54~2.22s，余量足够）。
  private static let probeConfirmSamples = 2
  private static let probeReportPeriod: TimeInterval = 5.0
  // 定罪后最多再报几条（≈30s 覆盖）；中后段不缺料：app 侧 `无视频轨` 每 ~2.9s 一行。
  private static let probeReportLimit = 6
  private static let probeReadTimeout: TimeInterval = 1.0

  // —— 以下字段只在 probeQueue 上读写 ——
  private var probePhase: ProbePhase = .idle
  private var probePeriod: TimeInterval = VideoOutput.probeIdlePeriod
  private var probeLastN = -1
  private var probeLastRendered = -1
  private var probeQuietSamples = 0
  private var probeQuietSince: Date?
  private var probeAlertReports = 0
  private var probeLastReportAt: Date?
  // 最近一次读回来的值（`_probe` 上报时用它）。
  private var probeLastConfigured = false
  private var probeReadPending = false
  private var probeReadStartedAt: Date?
  private var probeReadBlockedReported = false

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

    // 探针在这里就装好，而不是等 `_init()` 末尾：即使 `_init()` 卡在它自己那句
    // `DispatchQueue.main.sync`（`:220`）上，探针也照常跑。
    _installProbeTimers()

    worker.enqueue {
      self._init()
    }
  }

  deinit {
    // 先停探针。这是唯一的清理点：`VideoOutputManager.destroy` 只是把字典项置 nil，
    // 靠 ARC 走到这里；两个 timer 的 handler 都是 `[weak self]`，cancel 前抢跑的那一次
    // 也只会 no-op。
    _teardownProbe()

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

  // MARK: - 常驻诊断探针（只出声、只观察、不改行为）

  // 要回答的唯一问题：iOS「有声音黑屏」时 `_updateCallback()` 到底有没有被叫过。
  // `n == 0` ⇒ 回调压根没跑；`n > 0` 却仍 `configured:false` ⇒ 回调跑过但输出没配上。
  // 两种情况修法相反。第三个答案是「探针自己进不去 mpv」—— 单独一行 `read-blocked`。
  //
  // 与上一版（`4c7f4f36`）的区别：不再只查头 7.5 秒（那版一个实例最多 3 拍，
  // 而真机上一个实例能撑 3 分钟 / 59 次装载 ⇒ 黑屏发生在后半程时探针全程是哑的），
  // 改成随实例常驻；也不再发那一发试探渲染（`poke`），观察到的必须是天然病程。

  // 上报一条探针记录。键名沿用旧版（src / n / rendered / configured / elapsedMs /
  // size，`handle` 由插件侧补上），只多几个可选键：`mainLagMs`、`quietMs` /
  // `quietSamples`、`timeoutMs`、`blockedMs`。`src` 现在是病程阶段：
  // `start` / `ongoing` / `recover` / `read-blocked` / `read-recovered`。
  //
  // 仍然走 `DispatchQueue.main.async` —— `FlutterMethodChannel.invokeMethod` 只能在
  // 平台线程调。顺带量一个 `mainLagMs`（入队 → 真跑）用来区分「回调没跑」和
  // 「回调跑了、但卡在 main 那一跳上」：iOS 侧 mpv 的 update callback 是先
  // `DispatchQueue.main.async` 再进 `VideoOutput.updateCallback()` 的
  //（`TextureHW.swift` 的 `mpv_render_context_set_update_callback`）—— main 一卡 `n` 就冻结，
  // 那会儿的 `n == 0` 是假结论，得靠这个数认出来。
  private func _probe(_ src: String, extra: [String: Any] = [:]) {
    let callback = probeCallback
    let snap = _probeSnapshot()
    let elapsedMs = Int(Date().timeIntervalSince(probeStartedAt) * 1000)
    var args: [String: Any] = [
      "src": src,
      "n": snap.n,
      "rendered": snap.rendered,
      "configured": probeLastConfigured,
      "elapsedMs": elapsedMs,
      "size": [snap.size.width, snap.size.height],
    ]
    for (key, value) in extra {
      args[key] = value
    }

    let queuedAt = Date()
    DispatchQueue.main.async {
      var arguments = args
      arguments["mainLagMs"] = Int(Date().timeIntervalSince(queuedAt) * 1000)
      callback(arguments)
    }
  }

  private struct ProbeSnapshot {
    let n: Int
    let rendered: Int
    let size: CGSize
  }

  // 一次取齐 n / rendered / size（自洽）；写方是 worker 上的 `_updateCallback`。
  private func _probeSnapshot() -> ProbeSnapshot {
    probeStateLock.lock()
    defer {
      probeStateLock.unlock()
    }

    return ProbeSnapshot(
      n: probeCallbackCount,
      rendered: probeRenderedCount,
      size: probeSharedSize
    )
  }

  // 一拍要进 mpv 读三个属性，都在 probeReadQueue 上：
  //   video-out-params —— 输出配没配上（探针要回答的核心）。必须用 mpv 原始参数判，
  //                       不能用 `videoSize`：被钉住时它返回的就是钉的值。
  //   video-codec      —— 有视频轨在解码。没有这道门，「实例刚建/媒体已卸载」的空闲期
  //                       与真死锁长得一模一样，健康局会被刷屏。
  //   pause            —— 暂停时本来就不要帧，`rendered` 停住是正常的，那时判「没动静」没意义。
  private struct ProbeRead {
    let configured: Bool
    let hasCodec: Bool
    let paused: Bool
  }

  private func _installProbeTimers() {
    let timer = DispatchSource.makeTimerSource(queue: probeQueue)
    timer.setEventHandler { [weak self] in
      self?._probeTick()
    }
    timer.schedule(
      deadline: .now() + VideoOutput.probeIdlePeriod,
      repeating: VideoOutput.probeIdlePeriod,
      leeway: .milliseconds(250)
    )
    probeTimer = timer
    timer.resume()

    // 读超时看门狗：平时挂在遥远的未来（对一发已经回来的读来说，排到未来等于空操作），
    // 只有发出读的那一刻才排期 —— 所以它量的是「这一发读挂了多久」，与采样周期无关。
    let watchdog = DispatchSource.makeTimerSource(queue: probeQueue)
    watchdog.setEventHandler { [weak self] in
      self?._probeReadTimeoutFired()
    }
    watchdog.schedule(deadline: .distantFuture)
    probeReadTimeoutTimer = watchdog
    watchdog.resume()
  }

  private func _teardownProbe() {
    probeReadTimeoutTimer?.cancel()
    probeReadTimeoutTimer = nil
    probeTimer?.cancel()
    probeTimer = nil
  }

  private func _probeTick() {
    // 上一发读还挂在那儿（可能正被核锁卡着）：看门狗负责出声，这里既不排队也不加压。
    if probeReadPending {
      return
    }
    _startProbeRead()
  }

  private func _startProbeRead() {
    let handle = self.handle
    let queue = probeQueue
    probeReadPending = true
    probeReadStartedAt = Date()
    probeReadTimeoutTimer?.schedule(deadline: .now() + VideoOutput.probeReadTimeout)

    // 闭包只捕获值（handle / queue），**不捕获 self**：万一 mpv 核锁永远不还，这一发读
    // 会永远挂在这条队列上，若它持着 self，`VideoOutput` 就再也释放不掉（纹理也永远
    // unregister 不了）。
    probeReadQueue.async {
      let params = MPVHelpers.getVideoOutParams(handle)
      let read = ProbeRead(
        configured: params.dw > 0 && params.dh > 0,
        hasCodec: !MPVHelpers.getStringProperty(handle, "video-codec").isEmpty,
        paused: MPVHelpers.getFlagProperty(handle, "pause")
      )

      queue.async { [weak self] in
        self?._onProbeRead(read)
      }
    }
  }

  private func _onProbeRead(_ read: ProbeRead) {
    probeReadTimeoutTimer?.schedule(deadline: .distantFuture)
    probeReadPending = false
    probeLastConfigured = read.configured

    if probeReadBlockedReported {
      probeReadBlockedReported = false
      let blockedMs = probeReadStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
      _probe("read-recovered", extra: ["blockedMs": blockedMs])
    }
    probeReadStartedAt = nil

    _evaluate(read)
  }

  // 探针的第三种答案：这一发读超时还没回来。读 mpv 属性要拿核锁，核锁被长持时探针会
  // 跟着哑 —— 那与「回调没跑」是两回事，必须单独说清楚。只报一次。
  private func _probeReadTimeoutFired() {
    guard probeReadPending, !probeReadBlockedReported, let started = probeReadStartedAt else {
      return
    }

    probeReadBlockedReported = true
    _probe(
      "read-blocked",
      extra: ["timeoutMs": Int(Date().timeIntervalSince(started) * 1000)]
    )
  }

  // 状态机（只在 probeQueue 上跑）。判据：
  //   progress = 回调数或渲染数有没有往前走
  //   没动静   = !configured && hasCodec && !paused && !progress
  // 三个与门各挡一类误报：有视频轨挡「空闲期」、没暂停挡「暂停不看帧」、
  // 输出没配上挡「换流/seek/缓冲时 rendered 也会停、但输出还配着」。
  // 健康路径上 progress 恒真（在播时 `rendered` ~9 次/秒），所以健康局一行都不写。
  private func _evaluate(_ read: ProbeRead) {
    let snap = _probeSnapshot()
    let progress = (snap.n != probeLastN) || (snap.rendered != probeLastRendered)
    probeLastN = snap.n
    probeLastRendered = snap.rendered

    let quiet = !read.configured && read.hasCodec && !read.paused && !progress

    if !quiet {
      if probePhase == .alerting {
        _probe("recover", extra: [
          "quietMs": _probeQuietMs(),
          "quietSamples": probeQuietSamples,
        ])
        probePhase = .idle
        probeAlertReports = 0
        probeLastReportAt = nil
      }
      probeQuietSamples = 0
      probeQuietSince = nil
      _setProbePeriod(VideoOutput.probeIdlePeriod)
      return
    }

    probeQuietSamples += 1
    if probeQuietSince == nil {
      probeQuietSince = Date()
    }

    switch probePhase {
      case .idle:
        guard probeQuietSamples >= VideoOutput.probeConfirmSamples else {
          return
        }
        probePhase = .alerting
        probeAlertReports = 0
        probeLastReportAt = Date()
        _probe("start", extra: [
          "quietMs": _probeQuietMs(),
          "quietSamples": probeQuietSamples,
        ])
        // 定罪后切细采：黑屏前 30 秒的形态比 2.5s 一拍看得清。
        _setProbePeriod(VideoOutput.probeAlertPeriod)

      case .alerting:
        guard probeAlertReports < VideoOutput.probeReportLimit else {
          return
        }
        guard let last = probeLastReportAt,
              Date().timeIntervalSince(last) >= VideoOutput.probeReportPeriod else {
          return
        }
        probeAlertReports += 1
        probeLastReportAt = Date()
        _probe("ongoing", extra: [
          "quietMs": _probeQuietMs(),
          "quietSamples": probeQuietSamples,
        ])
    }
  }

  private func _probeQuietMs() -> Int {
    guard let since = probeQuietSince else {
      return 0
    }
    return Int(Date().timeIntervalSince(since) * 1000)
  }

  private func _setProbePeriod(_ period: TimeInterval) {
    guard period != probePeriod else {
      return
    }
    probePeriod = period
    probeTimer?.schedule(deadline: .now() + period, repeating: period)
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

    // 探针不在这里起 —— `init` 里已经装好（`_installProbeTimers`），那条路不经过
    // 上面这句 `main.sync`，所以它卡住也不影响探针。
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
    probeStateLock.lock()
    probeCallbackCount += 1
    probeStateLock.unlock()
    // 探针不在这里出声：常驻状态机拿 `n` / `rendered` 判活，健康路径一行都不写。
    //（旧版这里有一次 `_videoOutConfigured()`，是 worker 侧唯一一笔 mpv 查询，已随
    //  `src:"cb"` 一起删掉 —— 探针的 mpv 读现在全在 probeReadQueue 上。）

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

      probeStateLock.lock()
      probeSharedSize = size
      probeStateLock.unlock()

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
    probeStateLock.lock()
    probeRenderedCount += 1
    probeStateLock.unlock()
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
