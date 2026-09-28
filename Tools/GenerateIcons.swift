import AppKit

/// Run from the repository root: see docs/DEVELOPMENT.md.
@main
struct GenerateIcons {
    static func main() throws {
        let fm = FileManager.default
        let assets = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Assets")
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        let temporary = fm.temporaryDirectory.appendingPathComponent("justgit-icons-" + UUID().uuidString)
        let iconset = temporary.appendingPathComponent("AppIcon.iconset")
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }

        func png(_ size: Int) throws -> Data {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw IconError.render }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            AppIcon.drawApplication(in: NSRect(x: 0, y: 0, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw IconError.render }
            return data
        }
        var images: [Int: Data] = [:]
        for size in [16, 24, 32, 48, 64, 128, 256, 512, 1024] { images[size] = try png(size) }
        for size in [16, 32, 128, 256, 512] {
            try images[size]!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
            try images[size * 2]!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
        }
        try images[512]!.write(to: assets.appendingPathComponent("AppIcon.png"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw IconError.convert }

        let sizes = [16, 24, 32, 48, 64, 128, 256]
        var ico = Data()
        func append16(_ value: Int) { ico.append(UInt8(value & 255)); ico.append(UInt8((value >> 8) & 255)) }
        func append32(_ value: Int) { for shift in stride(from: 0, through: 24, by: 8) { ico.append(UInt8((value >> shift) & 255)) } }
        append16(0); append16(1); append16(sizes.count)
        var offset = 6 + 16 * sizes.count
        for size in sizes {
            ico.append(UInt8(size == 256 ? 0 : size)); ico.append(UInt8(size == 256 ? 0 : size))
            ico.append(0); ico.append(0)
            append16(1); append16(32)
            append32(images[size]!.count); append32(offset)
            offset += images[size]!.count
        }
        for size in sizes { ico.append(images[size]!) }
        try ico.write(to: assets.appendingPathComponent("AppIcon.ico"))
        print("Generated AppIcon.png, AppIcon.icns and AppIcon.ico")
    }
    enum IconError: Error { case render, convert }
}
