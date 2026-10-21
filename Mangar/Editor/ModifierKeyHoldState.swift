import Foundation

/// Panel positions are independent of the set of modifiers the editor supports.
enum ModifierPanelKey: CaseIterable, Hashable {
    case command, shift, commandOption, option
    var components: [EditorModifier] {
        switch self {
        case .command: [.command]
        case .shift: [.shift]
        case .commandOption: [.command, .option]
        case .option: [.option]
        }
    }
    var modifiers: Set<EditorModifier> { Set(components) }
    var symbol: String { components.map(\.symbol).joined() }
    var name: String { components.map(\.name).joined(separator: " + ") }
}

/// Releasing a compound key must not release a modifier still held by another key.
struct ModifierKeyHoldState {
    private var held: Set<ModifierPanelKey> = []
    var modifiers: Set<EditorModifier> { held.reduce(into: []) { $0.formUnion($1.modifiers) } }
    mutating func set(_ key: ModifierPanelKey, pressed: Bool) -> (pressed: Set<EditorModifier>, released: Set<EditorModifier>) {
        let before = modifiers
        if pressed { held.insert(key) } else { held.remove(key) }
        let after = modifiers
        return (after.subtracting(before), before.subtracting(after))
    }
    mutating func releaseAll() -> Set<EditorModifier> {
        let released = modifiers
        held.removeAll()
        return released
    }
}
