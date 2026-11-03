import Foundation

/// Which windows the phantom sweep may close. `TUINSWindow` is macOS text input:
/// a hidden 500×500 window with alpha 0. It is not one of ours, and `close()` does not remove it.
public enum PhantomWindowPolicy {
    public static func leaveAlone(className: String, visible: Bool, alpha: Double) -> Bool {
        if className != "NSWindow" && className != "NSPanel" { return true }
        if !visible || alpha == 0 { return true }
        return false
    }
}
