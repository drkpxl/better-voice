import AppKit

/// 文本注入器
///
/// 用 clipboard + 模拟 ⌘V 粘贴。三个关键 fix（vs 早期版本）：
///
/// 1. **post 到 `.cgSessionEventTap`（不是 `.cghidEventTap`）**。
///    macOS 14+ 上 `.cghidEventTap` 注入键盘事件可能在更严格的安全策略下被静默丢弃；
///    `.cgSessionEventTap` 是 user-session 级别，对其他 app 的 Cmd+V 投递更可靠。
///
/// 2. **写剪贴板后给 5ms 让 OS commit**，再 post Cmd+V。
///    NSPasteboard 写入是非原子的（changeCount 立刻递增但实际内容跨进程可见有微延迟），
///    立刻 post Cmd+V 偶尔会被目标 app 用旧剪贴板内容粘贴。
///
/// 3. **post 后 30ms 验证 `pb.changeCount` 是否变化**。Cmd+V 不写剪贴板，但目标 app
///    粘贴后可能触发系统 paste history 等机制改 changeCount。光打 "Pasted" 日志而不
///    验证是 observability gap，verify 之后才知道是真粘贴还是失败。日志带 `verified=Y/N`。
enum TextInjector {
    @MainActor
    static func inject(text: String, to app: AppIdentity?) {
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general

        // 保存当前剪贴板
        let savedString = pb.string(forType: .string)
        let changeCountBeforeWrite = pb.changeCount

        // 写入要注入的文字
        pb.clearContents()
        pb.setString(text, forType: .string)
        let changeCountAfterWrite = pb.changeCount

        // 让 OS commit 剪贴板内容（跨进程可见）
        usleep(5_000)

        // 模拟 ⌘V —— 用 cgSessionEventTap，比 cghidEventTap 在 macOS 14+ 上更可靠
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)

        // 30ms 后 verify changeCount — 若变化说明 Cmd+V 实际被处理（目标 app 触发 paste）
        // 若没变化说明 Cmd+V 没生效（焦点 app 拦截 / 没收到 / 不响应 ⌘V）
        let appBundle = app?.bundleID ?? "unknown"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            let changeCountAfterPaste = pb.changeCount
            let verified = changeCountAfterPaste != changeCountAfterWrite
            Logger.log(
                "Injector",
                "Pasted to \(appBundle) verified=\(verified ? "Y" : "N") cc=\(changeCountBeforeWrite)→\(changeCountAfterWrite)→\(changeCountAfterPaste)"
            )

            // 再延迟 500ms 恢复剪贴板（只在没被其他操作改的情况下）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if pb.changeCount == changeCountAfterPaste, let saved = savedString {
                    pb.clearContents()
                    pb.setString(saved, forType: .string)
                }
            }
        }
    }
}
