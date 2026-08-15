public enum TalkKey: Sendable {
    public enum Route: String, Sendable, Equatable {
        case chinese
        case english

        public var localeIdentifier: String {
            switch self {
            case .chinese: "zh-CN"
            case .english: "en-US"
            }
        }
    }

    public static let leftOption: Int64 = 58
    public static let rightOption: Int64 = 61
    public static let function: Int64 = 63
    public static let escape: Int64 = 53

    public static func isOptionModifier(_ keycode: Int64) -> Bool {
        keycode == leftOption || keycode == rightOption
    }

    public static func isPushToTalk(_ keycode: Int64) -> Bool {
        route(for: keycode) != nil
    }

    public static func route(for keycode: Int64) -> Route? {
        switch keycode {
        case rightOption: .chinese
        case function: .english
        default: nil
        }
    }
}
