// Renders the app icon and a document icon for every claimed file type.
//
// Usage: gen-icons <types.json> <symbols-nerd-font.ttf> <out-dir>
//
// Writes <out-dir>/AppIcon.icns and <out-dir>/<icon>.icns for each entry in
// types.json (produced by gen-plist.swift).

import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

func hex(_ s: String, _ alpha: CGFloat = 1) -> CGColor {
  let v = UInt32(s.dropFirst(), radix: 16)!
  return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                 blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let chipTop = hex("#5DB6FF"), chipBottom = hex("#2A7FE6"), chipShade = hex("#123F80")
let paper = hex("#FFFFFF"), paperFold = hex("#E4E0E8")
/// devicons' fallback for types it has no glyph for.
let fallbackGlyph = "\u{E64E}", fallbackColor = "#6D8086"

func gradient(_ colors: [CGColor]) -> CGGradient {
  CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
}

func components(_ color: CGColor) -> [CGFloat] {
  color.converted(to: sRGB, intent: .defaultIntent, options: nil)!.components!
}

func luminance(_ color: CGColor) -> CGFloat {
  let c = components(color).prefix(3).map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}

/// Darken colors too pale to read on a white page. Grays (Markdown, CMake, Lock)
/// need real contrast; saturated colors (JS yellow) read fine when lighter.
func readableOnPaper(_ color: CGColor) -> CGColor {
  var c = components(color)
  let saturation = (c[0...2].max()! - c[0...2].min()!) / max(c[0...2].max()!, 0.001)
  let minimumContrast: CGFloat = saturation < 0.3 ? 3 : 1.6
  while (1.05 / (luminance(CGColor(colorSpace: sRGB, components: c)!) + 0.05)) < minimumContrast {
    c = [c[0] * 0.92, c[1] * 0.92, c[2] * 0.92, 1]
  }
  return CGColor(colorSpace: sRGB, components: c)!
}

// MARK: - Drawing helpers

/// Every drawing works in a 1024-point space; `pixels` is the real output size.
struct Canvas {
  let ctx: CGContext
  let pixels: Int
  var scale: CGFloat { CGFloat(pixels) / 1024 }

  func fill(_ path: CGPath, _ color: CGColor) {
    ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
  }

  func fillVertical(_ path: CGPath, top: CGColor, bottom: CGColor) {
    let box = path.boundingBox
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(gradient([top, bottom]), start: CGPoint(x: box.midX, y: box.maxY),
                           end: CGPoint(x: box.midX, y: box.minY), options: [])
    ctx.restoreGState()
  }

  /// Shadows are specified in device pixels, so scale them with the icon.
  func withShadow(dy: CGFloat, blur: CGFloat, color: CGColor, _ body: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: dy * scale), blur: blur * scale, color: color)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
  }

  /// Draw text centered on a point by its visual bounds.
  func text(_ string: String, font: CTFont, color: CGColor, center: CGPoint, kern: CGFloat = 0) {
    let line = makeLine(string, font: font, color: color, kern: kern)
    // Image bounds are relative to the current text position, which earlier draws advance.
    ctx.textPosition = .zero
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
    CTLineDraw(line, ctx)
  }
}

func makeLine(_ string: String, font: CTFont, color: CGColor = hex("#000000"), kern: CGFloat = 0) -> CTLine {
  let attributes: [NSAttributedString.Key: Any] = [
    .init(kCTFontAttributeName as String): font,
    .init(kCTForegroundColorAttributeName as String): color,
    .kern: kern,
  ]
  return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
}

func render(_ pixels: Int, _ draw: (Canvas) -> Void) -> CGImage {
  let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
  draw(Canvas(ctx: ctx, pixels: pixels))
  return ctx.makeImage()!
}

// MARK: - App icon

/// The macOS app icon shape: an 824-point superellipse centered in the canvas.
let squircle: CGPath = {
  let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
  let path = CGMutablePath(), n: CGFloat = 5, steps = 360
  for i in 0...steps {
    let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
    let x = pow(abs(cos(t)), 2 / n) * (cos(t) < 0 ? -1 : 1)
    let y = pow(abs(sin(t)), 2 / n) * (sin(t) < 0 ? -1 : 1)
    let point = CGPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
    i == 0 ? path.move(to: point) : path.addLine(to: point)
  }
  path.closeSubpath()
  return path
}()

/// The Neovim mark, from neovim.io/logos/neovim-mark.svg (602×734).
struct Mark {
  let left, right, cross, shadow: CGPath

  init(center: CGPoint, height: CGFloat) {
    let s = height / 734, ox = center.x - 301 * s, oy = center.y - 367 * s
    func polygon(_ points: [(CGFloat, CGFloat)]) -> CGPath {
      let path = CGMutablePath()
      path.addLines(between: points.map { CGPoint(x: ox + ($0.0 + 2) * s, y: oy + (734 - ($0.1 + 3)) * s) })
      path.closeSubpath()
      return path
    }
    left = polygon([(0, 155.57), (155, -1), (155, 727), (0, 572.24)])
    right = polygon([(598.94, 156.98), (442, -1), (445.18, 727), (600, 572.22)])
    cross = polygon([(154.99, 0), (558, 615.19), (445.22, 728), (42, 114.17)])
    shadow = polygon([(155, 283.83), (154.79, 308), (31, 124.71), (42.46, 113)])
  }
}

/// A blue tile with a flat white Neovim mark and a glassy rim.
func drawAppIcon(_ canvas: Canvas) {
  canvas.fillVertical(squircle, top: chipTop, bottom: chipBottom)
  let mark = Mark(center: CGPoint(x: 512, y: 512), height: 540)
  canvas.fill(mark.left, hex("#FFFFFF", 0.88))
  canvas.fill(mark.right, hex("#FFFFFF", 0.88))
  canvas.fill(mark.cross, hex("#FFFFFF"))
  canvas.fill(mark.shadow, chipShade.copy(alpha: 0.25)!)

  let ctx = canvas.ctx
  ctx.saveGState(); ctx.addPath(squircle); ctx.clip()
  ctx.drawLinearGradient(gradient([hex("#FFFFFF", 0.22), hex("#FFFFFF", 0)]),
                         start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 512), options: [])
  ctx.addPath(squircle); ctx.setLineWidth(10); ctx.setStrokeColor(hex("#FFFFFF", 0.5)); ctx.strokePath()
  ctx.restoreGState()
}

// MARK: - Document icons

let page = CGRect(x: 182, y: 70, width: 660, height: 884), fold: CGFloat = 200

/// A page with its top-right corner folded over.
let pagePath: CGPath = {
  let path = CGMutablePath(), r: CGFloat = 56
  path.move(to: CGPoint(x: page.minX + r, y: page.minY))
  path.addArc(tangent1End: CGPoint(x: page.maxX, y: page.minY), tangent2End: CGPoint(x: page.maxX, y: page.maxY), radius: r)
  path.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
  path.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
  path.addArc(tangent1End: CGPoint(x: page.minX, y: page.maxY), tangent2End: CGPoint(x: page.minX, y: page.minY), radius: r)
  path.addArc(tangent1End: CGPoint(x: page.minX, y: page.minY), tangent2End: CGPoint(x: page.maxX, y: page.minY), radius: r)
  path.closeSubpath()
  return path
}()

let foldPath: CGPath = {
  let path = CGMutablePath()
  path.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
  path.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
  path.addArc(tangent1End: CGPoint(x: page.maxX - fold, y: page.maxY - fold),
              tangent2End: CGPoint(x: page.maxX - fold, y: page.maxY), radius: 28)
  path.closeSubpath()
  return path
}()

struct DocType: Decodable {
  let icon: String
  let name: String
  let glyph: String
  let color: String
  let exts: [String]
}

func labelFont(_ size: CGFloat) -> CTFont {
  let base = NSFont.systemFont(ofSize: size, weight: .heavy)
  return (base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base) as CTFont
}

/// White page with the type's devicon glyph and, centered beneath it, its
/// extension, both in the type's color. Small sizes drop the label and enlarge
/// the glyph so it stays legible; types without an extension have no label.
func drawDocument(_ canvas: Canvas, glyph: String, color: CGColor, label: String, symbols: CTFont) {
  let labeled = canvas.pixels >= 64 && !label.isEmpty
  canvas.withShadow(dy: -10, blur: 28, color: hex("#000000", 0.25)) {
    canvas.fill(pagePath, paper)
    canvas.fill(foldPath, paperFold)
  }

  let glyphSize: CGFloat = labeled ? 320 : 440
  let glyphCenter = CGPoint(x: 512, y: labeled ? 570 : 512)
  canvas.text(glyph, font: CTFontCreateCopyWithAttributes(symbols, glyphSize, nil, nil), color: color, center: glyphCenter)

  if labeled {
    // Long extensions shrink to fit the page.
    let text = label.uppercased(), maxWidth: CGFloat = 540
    let width = CTLineGetTypographicBounds(makeLine(text, font: labelFont(130), kern: 4), nil, nil, nil)
    let size = width > maxWidth ? 130 * maxWidth / width : 130
    canvas.text(text, font: labelFont(size), color: color, center: CGPoint(x: 512, y: 200), kern: 4 * size / 130)
  }
}

// MARK: - Output

/// The sizes an .icns file holds, as (name, pixels).
let iconsetSizes: [(String, Int)] = [16, 32, 128, 256, 512].flatMap { size in
  [("icon_\(size)x\(size).png", size), ("icon_\(size)x\(size)@2x.png", size * 2)]
}

func writeIcns(_ name: String, to outDir: URL, _ draw: @escaping (Canvas) -> Void) throws {
  let iconset = outDir.appendingPathComponent("\(name).iconset")
  try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
  for (file, pixels) in iconsetSizes {
    let dest = CGImageDestinationCreateWithURL(iconset.appendingPathComponent(file) as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, render(pixels, draw), nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "gen-icons", code: 1) }
  }
  let iconutil = Process()
  iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
  iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("\(name).icns").path]
  try iconutil.run()
  iconutil.waitUntilExit()
  guard iconutil.terminationStatus == 0 else { throw NSError(domain: "gen-icons", code: 2) }
  try FileManager.default.removeItem(at: iconset)
}

let args = CommandLine.arguments
guard args.count == 4 else {
  FileHandle.standardError.write("usage: gen-icons <types.json> <symbols-nerd-font.ttf> <out-dir>\n".data(using: .utf8)!)
  exit(2)
}
let types = try JSONDecoder().decode([DocType].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let outDir = URL(fileURLWithPath: args[3])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let fontData = CGDataProvider(url: URL(fileURLWithPath: args[2]) as CFURL).flatMap(CGFont.init) else {
  FileHandle.standardError.write("couldn't load font \(args[2])\n".data(using: .utf8)!)
  exit(1)
}
let symbols = CTFontCreateWithGraphicsFont(fontData, 100, nil, nil)

func hasGlyph(_ string: String) -> Bool {
  let utf16 = Array(string.utf16)
  var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
  return CTFontGetGlyphsForCharacters(symbols, utf16, &glyphs, utf16.count)
}

try writeIcns("AppIcon", to: outDir, drawAppIcon)

var failures = 0
let lock = NSLock()
DispatchQueue.concurrentPerform(iterations: types.count) { index in
  let type = types[index]
  let known = hasGlyph(type.glyph)
  let glyph = known ? type.glyph : fallbackGlyph
  let color = readableOnPaper(hex(known ? type.color : fallbackColor))
  do {
    try writeIcns(type.icon, to: outDir) { canvas in
      drawDocument(canvas, glyph: glyph, color: color, label: type.exts.first ?? "", symbols: symbols)
    }
  } catch {
    lock.lock(); failures += 1; lock.unlock()
    FileHandle.standardError.write("failed to render \(type.icon): \(error)\n".data(using: .utf8)!)
  }
}
print("rendered AppIcon and \(types.count - failures) document icons")
exit(failures == 0 ? 0 : 1)
