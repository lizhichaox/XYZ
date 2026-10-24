import UniformTypeIdentifiers

public extension UTType {
    /// Markdown (`.md` and `.markdown`).
    ///
    /// The SDK used to build XYZ has no `UTType.markdown` member. This matches the
    /// imported type `net.daringfireball.markdown` declared in the app Info.plist.
    static let markdown = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .plainText
    )
}
