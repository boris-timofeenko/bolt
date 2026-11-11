// bolt: the batch part of Bolt for scripts and Shortcuts' "Run Shell Script".
//
//   bolt convert IMG_*.HEIC --format jpeg --quality 85 --size 2560 --strip-location --out ~/Desktop/Telegram
//   bolt rename *.HEIC --template "{date:yyyy-MM-dd_HHmmss}" [--dry-run]
import BoltCore
import Foundation

struct Usage: Error, CustomStringConvertible {
    let description: String
}

func parse(_ arguments: ArraySlice<String>) throws -> (files: [URL], options: [String: String]) {
    var files: [URL] = []
    var options: [String: String] = [:]
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        if argument.hasPrefix("--") {
            let name = String(argument.dropFirst(2))
            let flags: Set<String> = ["strip-location", "strip-all", "dry-run"]
            options[name] = flags.contains(name) ? "yes" : try iterator.next() ?? { throw Usage(description: "\(argument) needs a value") }()
        } else {
            files.append(URL(fileURLWithPath: (argument as NSString).expandingTildeInPath))
        }
    }
    return (files, options)
}

func convert(_ files: [URL], _ options: [String: String]) throws {
    let format = try options["format"].map { name -> ExportFormat in
        let normalized = name.lowercased() == "jpg" ? "jpeg" : name.lowercased()
        guard let format = ExportFormat(rawValue: normalized), ExportFormat.available.contains(format) else {
            throw Usage(description: "unknown format \(name); this Mac writes \(ExportFormat.available.map(\.rawValue))")
        }
        return format
    }
    let metadata: MetadataPolicy = options["strip-all"] != nil ? .removeAll
        : options["strip-location"] != nil ? .removePrivate : .keep
    let settings = ExportSettings(format: format, quality: (options["quality"].flatMap(Double.init) ?? 85) / 100,
                                  maxLongSide: options["size"].flatMap(Int.init), metadata: metadata)
    let output = URL(fileURLWithPath: (options["out"].map { ($0 as NSString).expandingTildeInPath }) ?? ".")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let start = Date()
    let results = concurrentMap(files) { file -> String in
        do {
            let written = try ImageExporter.export(file, to: ImageExporter.destination(for: file, settings: settings, in: output),
                                                   settings: settings)
            return "\(file.lastPathComponent) → \(written.lastPathComponent)"
        } catch {
            return "\(file.lastPathComponent): \(error.localizedDescription)"
        }
    }
    results.forEach { print($0) }
    print(String(format: "%d files in %.1f s", files.count, Date().timeIntervalSince(start)))
}

func rename(_ files: [URL], _ options: [String: String]) throws {
    guard let pattern = options["template"] else { throw Usage(description: "rename needs --template") }
    let inputs = files.map { RenameTemplate.Input(url: $0, date: ImageDecoder.captureDate(at: $0) ?? PhotoItem(url: $0)?.modified ?? Date()) }
    for (file, name) in zip(files, RenameTemplate(pattern).names(for: inputs)) where name != file.lastPathComponent {
        if options["dry-run"] != nil {
            print("\(file.lastPathComponent) → \(name)")
        } else {
            let renamed = try FileOperations.rename(file, to: name)
            print("\(file.lastPathComponent) → \(renamed.lastPathComponent)")
        }
    }
}

let usage = """
usage: bolt convert FILE... [--format jpeg|heic|avif|png|tiff] [--quality 85] [--size 2560]
                            [--strip-location | --strip-all] [--out FOLDER]
       bolt rename FILE... --template "{date:yyyy-MM-dd_HHmmss}_{counter:3}" [--dry-run]
"""

do {
    let arguments = CommandLine.arguments.dropFirst()
    guard let command = arguments.first else { throw Usage(description: usage) }
    let (files, options) = try parse(arguments.dropFirst())
    guard !files.isEmpty else { throw Usage(description: usage) }
    switch command {
    case "convert": try convert(files, options)
    case "rename": try rename(files, options)
    default: throw Usage(description: usage)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
