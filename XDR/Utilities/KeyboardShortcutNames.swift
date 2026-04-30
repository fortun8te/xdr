import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleXDR = Self("toggleXDR", default: .init(.x, modifiers: [.command, .option]))
    static let increaseBrightness = Self("increaseBrightness", default: .init(.upArrow, modifiers: [.command, .option]))
    static let decreaseBrightness = Self("decreaseBrightness", default: .init(.downArrow, modifiers: [.command, .option]))
}
