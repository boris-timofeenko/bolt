import Foundation

/// Files that belong to a photo and should follow it when it is moved or deleted.
///
/// Only real companions: the RAW of a JPEG (or the JPEG of a RAW), the video half of a Live Photo,
/// .AAE and .XMP sidecars, and — for an iPhone original — its edited copy (IMG_E1234). Another photo that
/// just shares the name, like cover.png next to cover.jpg, is a photo of its own and stays put.
/// An edited copy doesn't take its original along: deleting the edit keeps the original.
public enum Companions {
    public static func of(_ url: URL, among names: [String]) -> [URL] {
        let folder = url.deletingLastPathComponent()
        let stem = stem(of: url.lastPathComponent)
        let subjectIsRaw = MediaTypes.isRaw(url)
        let editedStem = editedCopyStem(of: stem)
        return names
            .filter { name in
                guard name != url.lastPathComponent else { return false }
                let otherStem = Self.stem(of: name)
                if otherStem == stem { return isCompanion(name, ofRaw: subjectIsRaw) }
                return otherStem == editedStem || otherStem == editedStem.map(adjustmentsStem)
            }
            .map { folder.appendingPathComponent($0, isDirectory: false) }
    }

    /// Reads the folder and finds the companions of `url` in it.
    public static func of(_ url: URL) -> [URL] {
        let names = (try? FolderScanner.entries(in: url.deletingLastPathComponent()))?
            .filter { !$0.isDirectory }.map(\.name) ?? []
        return of(url, among: names)
    }

    private static let sidecarExtensions: Set<String> = ["aae", "xmp"]

    /// A same-named file goes along if it's a sidecar, a video, or the other half of a RAW+JPEG pair.
    private static func isCompanion(_ name: String, ofRaw subjectIsRaw: Bool) -> Bool {
        let url = URL(fileURLWithPath: name)
        if sidecarExtensions.contains(url.pathExtension.lowercased()) || MediaTypes.isVideo(name: name) { return true }
        return subjectIsRaw ? MediaTypes.isImage(name: name) : MediaTypes.isRaw(url)
    }

    /// "img_1234" → "img_e1234"; nil for names that aren't iPhone originals.
    private static func editedCopyStem(of stem: String) -> String? {
        guard stem.hasPrefix("img_"), stem.dropFirst(4).allSatisfy(\.isNumber), stem.count > 4 else { return nil }
        return "img_e" + stem.dropFirst(4)
    }

    /// "img_e1234" → "img_o1234": the .AAE with the edit's adjustments.
    private static func adjustmentsStem(of edited: String) -> String {
        "img_o" + edited.dropFirst(5)
    }

    private static func stem(of name: String) -> String {
        (name as NSString).deletingPathExtension.lowercased()
    }
}
