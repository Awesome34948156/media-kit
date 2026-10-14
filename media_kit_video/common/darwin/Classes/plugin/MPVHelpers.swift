public enum MPVHelpers {
  public static func checkError(_ status: CInt) {
    if status < 0 {
      NSLog("MPVHelpers: error: \(String(cString: mpv_error_string(status)))")
      exit(1)
    }
  }

  public static func getVideoOutParams(
    _ handle: OpaquePointer
  ) -> MPVVideoOutParams {
    var node = mpv_node()
    defer {
      mpv_free_node_contents(&node)
    }

    mpv_get_property(handle, "video-out-params", MPV_FORMAT_NODE, &node)

    if node.format != MPV_FORMAT_NODE_MAP {
      return MPVVideoOutParams.empty
    }

    let map: mpv_node_list = node.u.list!.pointee
    if map.num == 0 {
      return MPVVideoOutParams.empty
    }

    return MPVVideoOutParams.fromMPVNodeList(map)
  }

  // 诊断探针用：读一个字符串属性（`video-codec` 之类）。属性不存在/读不到都返回 ""。
  // 注意这两个读和 `getVideoOutParams` 一样要拿 mpv 的核锁 —— 核锁被长持时它们会卡住，
  // 所以探针把读放在自己的 probeReadQueue 上，并且量超时（`read-blocked`）。
  public static func getStringProperty(
    _ handle: OpaquePointer,
    _ name: String
  ) -> String {
    guard let value = mpv_get_property_string(handle, name) else {
      return ""
    }
    defer {
      mpv_free(value)
    }

    return String(cString: value)
  }

  // 诊断探针用：读一个开关属性（`pause`）。读不到当作 false。
  public static func getFlagProperty(
    _ handle: OpaquePointer,
    _ name: String
  ) -> Bool {
    var value: CInt = 0
    let status = mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value)
    return status >= 0 && value != 0
  }
}
