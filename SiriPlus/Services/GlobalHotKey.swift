import Carbon.HIToolbox

/// A system-wide shortcut registered through Carbon. Unlike event monitors it
/// needs no Accessibility permission and works while another app is active.
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// Default: Control-Option-Space.
    init?(keyCode: Int = kVK_Space, modifiers: Int = controlKey | optionKey, action: @escaping @MainActor () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers hot key events on the main thread.
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        let identifier = EventHotKeyID(signature: OSType(0x5350_4C53), id: 1) // "SPLS"
        let registerStatus = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), identifier, GetApplicationEventTarget(), 0, &hotKey
        )
        guard installStatus == noErr, registerStatus == noErr else {
            unregister()
            return nil
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
