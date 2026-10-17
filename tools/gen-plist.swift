// Builds the app's Info.plist from data/devicons.json, deciding which
// extensions the app claims and which system type (UTI) each one maps to.
//
// Usage: swift tools/gen-plist.swift <data-dir> <out-dir> <app-name> <bundle-id> <version>
//
// Writes <out-dir>/Info.plist and <out-dir>/types.json (consumed by the icon
// generator: one entry per document type, keyed by its icon name).

import Foundation
import UniformTypeIdentifiers

struct Devicon: Decodable {
  let ext: String
  let name: String
  let glyph: String
  let color: String
  let filetype: String?
}

struct DocType: Encodable {
  let icon: String
  let name: String
  let glyph: String
  let color: String
  let uti: String
  var exts: [String]
  let imported: Bool
}

let args = CommandLine.arguments
guard args.count == 6 else {
  FileHandle.standardError.write("usage: gen-plist.swift <data-dir> <out-dir> <app-name> <bundle-id> <version>\n".data(using: .utf8)!)
  exit(2)
}
let dataDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let appName = args[3], bundleID = args[4], version = args[5]

func readList(_ name: String) -> Set<String> {
  let text = (try? String(contentsOf: dataDir.appendingPathComponent(name), encoding: .utf8)) ?? ""
  return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { $0.lowercased() })
}

let devicons = try JSONDecoder().decode([Devicon].self, from: Data(contentsOf: dataDir.appendingPathComponent("devicons.json")))
let include = readList("include.txt"), exclude = readList("exclude.txt")
let validExt = try Regex("^[a-z0-9_+#-]+$")

// Ordered by first appearance so output is stable.
var docTypes: [DocType] = []
var indexByUTI: [String: Int] = [:]
var seenExts: Set<String> = []

for icon in devicons.sorted(by: { $0.ext.lowercased() < $1.ext.lowercased() }) {
  let ext = icon.ext.lowercased()
  // Compound extensions (test.ts, d.ts) can't be told apart by LaunchServices.
  guard (try? validExt.wholeMatch(in: ext)) != nil, !seenExts.contains(ext), !exclude.contains(ext) else { continue }

  let uti: String
  let imported: Bool
  // Types declared by an installed copy of this app don't count as known to macOS,
  // or rebuilding would stop declaring them.
  if let type = UTType(filenameExtension: ext), !type.isDynamic, !type.identifier.hasPrefix("\(bundleID).ext.") {
    guard include.contains(ext) || type.conforms(to: .text) else { continue }
    uti = type.identifier
    imported = false
  } else {
    guard include.contains(ext) || icon.filetype != nil else { continue }
    let safe = ext.replacingOccurrences(of: "+", with: "plus")
      .replacingOccurrences(of: "#", with: "sharp")
      .replacingOccurrences(of: "_", with: "-")
    uti = "\(bundleID).ext.\(safe)"
    imported = true
  }
  seenExts.insert(ext)

  if let index = indexByUTI[uti] {
    docTypes[index].exts.append(ext)
  } else {
    indexByUTI[uti] = docTypes.count
    let iconName = "doc-" + uti.replacingOccurrences(of: "\(bundleID).ext.", with: "").replacingOccurrences(of: ".", with: "-")
    docTypes.append(DocType(icon: iconName, name: icon.name, glyph: icon.glyph, color: icon.color, uti: uti, exts: [ext], imported: imported))
  }
}

// A system type shared by several extensions takes its name and icon from the
// type's preferred extension (public.toml claims cfg and toml; use toml's), and
// lists that extension first so the icon is labeled with it.
let deviconByExt = Dictionary(devicons.map { ($0.ext.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
for (index, type) in docTypes.enumerated() where !type.imported && type.exts.count > 1 {
  guard let preferred = UTType(type.uti)?.preferredFilenameExtension, type.exts.contains(preferred),
        let icon = deviconByExt[preferred] else { continue }
  let exts = [preferred] + type.exts.filter { $0 != preferred }
  docTypes[index] = DocType(icon: type.icon, name: icon.name, glyph: icon.glyph, color: icon.color, uti: type.uti, exts: exts, imported: false)
}

// Icons are rendered by gen-icons.swift from types.json.
let documentTypes: [[String: Any]] = docTypes.map { type in
  [
    "CFBundleTypeName": type.name,
    "CFBundleTypeRole": "Editor",
    "LSHandlerRank": "Default",
    "LSItemContentTypes": [type.uti],
    "CFBundleTypeIconFile": type.icon,
  ]
}

let importedTypes: [[String: Any]] = docTypes.filter(\.imported).map { type in
  [
    "UTTypeIdentifier": type.uti,
    "UTTypeDescription": type.name,
    "UTTypeConformsTo": ["public.source-code"],
    "UTTypeTagSpecification": ["public.filename-extension": type.exts],
  ]
}

let plist: [String: Any] = [
  "CFBundleDevelopmentRegion": "en",
  "CFBundleExecutable": "ft-forwarder",
  "CFBundleIdentifier": bundleID,
  "CFBundleInfoDictionaryVersion": "6.0",
  "CFBundleName": appName,
  "CFBundleDisplayName": appName,
  "CFBundlePackageType": "APPL",
  "CFBundleShortVersionString": version,
  "CFBundleVersion": version,
  "LSMinimumSystemVersion": "13.0",
  // Never show a Dock icon or menu bar; the app forwards and exits.
  "LSUIElement": true,
  "NSHighResolutionCapable": true,
  "CFBundleIconFile": "AppIcon",
  "CFBundleDocumentTypes": documentTypes,
  "UTImportedTypeDeclarations": importedTypes,
]

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  .write(to: outDir.appendingPathComponent("Info.plist"))

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(docTypes).write(to: outDir.appendingPathComponent("types.json"))

let extCount = docTypes.reduce(0) { $0 + $1.exts.count }
print("claimed \(extCount) extensions in \(docTypes.count) document types (\(importedTypes.count) declared by us)")
