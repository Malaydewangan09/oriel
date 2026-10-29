import Carbon.HIToolbox

// Global shortcuts via Carbon's hotkey API, which needs no Accessibility permission.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey | controlKey), action: @escaping () -> Void) {
        if !Hotkey.installed {
            Hotkey.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, _ in
                    var hk = EventHotKeyID()
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil,
                        &hk)
                    Hotkey.actions[hk.id]?()
                    return noErr
                }, 1, &spec, nil, nil)
        }
        id = Hotkey.nextID
        Hotkey.nextID += 1
        Hotkey.actions[id] = action
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4445534B), id: id), GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Hotkey.actions[id] = nil
    }
}
