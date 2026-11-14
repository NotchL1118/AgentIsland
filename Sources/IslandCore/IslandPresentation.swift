public enum IslandPresentation: String, CaseIterable, Codable {
    case notch
    case floating
    case menuBar

    public var displayName: String {
        switch self {
        case .notch: return "顶部刘海"
        case .floating: return "自由浮条"
        case .menuBar: return "仅菜单栏"
        }
    }

    /// Preserve the old floating preference until an explicit presentation is saved.
    public static func restored(rawValue: String?, legacyFloating: Bool) -> IslandPresentation {
        rawValue.flatMap(IslandPresentation.init(rawValue:)) ?? (legacyFloating ? .floating : .notch)
    }
}
