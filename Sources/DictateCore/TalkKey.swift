public enum TalkKey: Sendable {
    public static let leftOption: Int64 = 58
    public static let rightOption: Int64 = 61
    public static let escape: Int64 = 53

    public static func isOptionModifier(_ keycode: Int64) -> Bool {
        keycode == leftOption || keycode == rightOption
    }

    public static func isPushToTalk(_ keycode: Int64) -> Bool {
        keycode == rightOption
    }
}
