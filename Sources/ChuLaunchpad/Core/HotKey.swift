import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - 全局启动快捷键模型
struct LaunchHotKey: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// 默认快捷键：Command + F3
    static let defaultHotKey = LaunchHotKey(keyCode: UInt32(kVK_F3), modifiers: UInt32(cmdKey))

    /// 将 AppKit 修饰键标志转换为 Carbon 修饰键掩码
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// 常见独立修饰键键码集合（不可单独作为主键）
    private static let modifierOnlyKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_RightCommand),
        UInt32(kVK_Shift), UInt32(kVK_RightShift),
        UInt32(kVK_Option), UInt32(kVK_RightOption),
        UInt32(kVK_Control), UInt32(kVK_RightControl),
        UInt32(kVK_CapsLock), UInt32(kVK_Function)
    ]

    /// 功能键键码集合（F1–F20 允许单独或搭配修饰键使用）
    static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20)
    ]

    /// 校验快捷键是否合法（避免单按普通字符干扰正常输入）
    static func isValid(keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard !modifierOnlyKeyCodes.contains(keyCode) else { return false }
        let primaryMask = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        if (modifiers & primaryMask) != 0 {
            return true
        }
        return functionKeyCodes.contains(keyCode)
    }

    /// 拆分为适合渲染键帽的标记序列（遵循 macOS 标准顺序：⌃ ⌥ ⇧ ⌘ + 按键）
    var keyCapTokens: [String] {
        var tokens: [String] = []
        if (modifiers & UInt32(controlKey)) != 0 { tokens.append("⌃") }
        if (modifiers & UInt32(optionKey)) != 0 { tokens.append("⌥") }
        if (modifiers & UInt32(shiftKey)) != 0 { tokens.append("⇧") }
        if (modifiers & UInt32(cmdKey)) != 0 { tokens.append("⌘") }
        tokens.append(Self.keyName(for: keyCode))
        return tokens
    }

    /// 可读文本（例如 "⌘ F3"）
    var displayString: String {
        keyCapTokens.joined(separator: " ")
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        default: return "Key \(keyCode)"
        }
    }
}

// MARK: - 快捷键持久化存储
enum HotKeyStore {
    static let dataKey = "com.withqq.chu-launchpad.launchHotKey"
    static let disabledKey = "com.withqq.chu-launchpad.launchHotKeyDisabled"

    /// 读取已保存的快捷键；首次使用时返回默认 Command + F3，显式停用时返回 nil
    static func load(from defaults: UserDefaults = .standard) -> LaunchHotKey? {
        if defaults.bool(forKey: disabledKey) {
            return nil
        }
        guard let data = defaults.data(forKey: dataKey),
              let decoded = try? JSONDecoder().decode(LaunchHotKey.self, from: data) else {
            return .defaultHotKey
        }
        return decoded
    }

    /// 保存快捷键；传入 nil 表示停用全局快捷键
    static func save(_ hotKey: LaunchHotKey?, to defaults: UserDefaults = .standard) {
        if let hotKey {
            defaults.set(false, forKey: disabledKey)
            if let data = try? JSONEncoder().encode(hotKey) {
                defaults.set(data, forKey: dataKey)
            }
        } else {
            defaults.set(true, forKey: disabledKey)
            defaults.removeObject(forKey: dataKey)
        }
    }
}

// MARK: - 全局热键注册状态
enum HotKeyRegistrationStatus: Equatable, Sendable {
    case registered(LaunchHotKey)
    case disabled
    case conflict(LaunchHotKey, OSStatus)
}

// MARK: - Carbon 全局热键管理器（无需辅助功能权限）
@MainActor final class GlobalHotKeyManager {
    private static let hotKeySignature: OSType = 0x43485550 // 'CHUP'
    private static let hotKeyIdentifier: UInt32 = 1

    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    private(set) var currentHotKey: LaunchHotKey?
    private(set) var lastStatus: HotKeyRegistrationStatus = .disabled
    private var isSuspended = false

    var onTrigger: (() -> Void)?

    init() {
        installHandlerIfNeeded()
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == GlobalHotKeyManager.hotKeySignature,
                      hotKeyID.id == GlobalHotKeyManager.hotKeyIdentifier else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    manager.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
    }

    /// 注册或更新全局快捷键
    @discardableResult
    func register(_ hotKey: LaunchHotKey?) -> HotKeyRegistrationStatus {
        currentHotKey = hotKey
        unregisterActiveRef()

        guard let hotKey else {
            lastStatus = .disabled
            return lastStatus
        }

        if isSuspended {
            lastStatus = .registered(hotKey)
            return lastStatus
        }

        return applyRegistration(hotKey)
    }

    /// 录制快捷键期间临时暂停全局热键，防止录制当前按键时误触发
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        unregisterActiveRef()
    }

    /// 退出录制态后恢复当前全局热键
    @discardableResult
    func resume() -> HotKeyRegistrationStatus {
        guard isSuspended else { return lastStatus }
        isSuspended = false
        guard let currentHotKey else {
            lastStatus = .disabled
            return lastStatus
        }
        return applyRegistration(currentHotKey)
    }

    private func unregisterActiveRef() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func applyRegistration(_ hotKey: LaunchHotKey) -> HotKeyRegistrationStatus {
        unregisterActiveRef()
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyIdentifier)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRef = ref
            lastStatus = .registered(hotKey)
        } else {
            lastStatus = .conflict(hotKey, status)
        }
        return lastStatus
    }
}
