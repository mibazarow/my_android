// Иконка My Android: смартфон с волнами трансляции.
// Рисуется кодом, чтобы не тащить бинарные ассеты в репозиторий.
//
// Запуск: swift IconGen.swift <output.png>

import AppKit

let size: CGFloat = 1024

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Не удалось создать битмап")
}

guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Не удалось создать графический контекст")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("Нет CGContext")
}

// MARK: - Фон: скруглённый квадрат с зелёно-бирюзовым градиентом

let inset: CGFloat = 88
let bgRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 180, cornerHeight: 180, transform: nil)

ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -12),
    blur: 30,
    color: NSColor.black.withAlphaComponent(0.30).cgColor
)
ctx.addPath(bgPath)
ctx.setFillColor(NSColor(calibratedRed: 0.05, green: 0.30, blue: 0.28, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

let bgGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(calibratedRed: 0.20, green: 0.80, blue: 0.62, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.04, green: 0.36, blue: 0.42, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: bgRect.minX, y: bgRect.maxY),
    end: CGPoint(x: bgRect.maxX, y: bgRect.minY),
    options: []
)
ctx.restoreGState()

// MARK: - Телефон по центру

let phoneWidth: CGFloat = 360
let phoneHeight: CGFloat = 620
let phoneRect = CGRect(
    x: (size - phoneWidth) / 2,
    y: (size - phoneHeight) / 2,
    width: phoneWidth,
    height: phoneHeight
)
let phoneRadius: CGFloat = 58
let phonePath = CGPath(
    roundedRect: phoneRect,
    cornerWidth: phoneRadius,
    cornerHeight: phoneRadius,
    transform: nil
)

// Корпус
ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: -10),
    blur: 26,
    color: NSColor.black.withAlphaComponent(0.35).cgColor
)
ctx.addPath(phonePath)
ctx.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// Экран
let screenInset: CGFloat = 18
let screenRect = phoneRect.insetBy(dx: screenInset, dy: screenInset)
let screenPath = CGPath(
    roundedRect: screenRect,
    cornerWidth: phoneRadius - screenInset,
    cornerHeight: phoneRadius - screenInset,
    transform: nil
)

ctx.saveGState()
ctx.addPath(screenPath)
ctx.clip()

let screenGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.20, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.12, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    screenGradient,
    start: CGPoint(x: screenRect.minX, y: screenRect.maxY),
    end: CGPoint(x: screenRect.maxX, y: screenRect.minY),
    options: []
)

// Символ зеркалирования: волны трансляции из центра экрана
let center = CGPoint(x: screenRect.midX, y: screenRect.midY - 20)
ctx.setLineCap(.round)

for (index, radius) in [CGFloat(70), CGFloat(130), CGFloat(190)].enumerated() {
    let alpha = 0.95 - CGFloat(index) * 0.26
    ctx.setStrokeColor(NSColor(calibratedRed: 0.35, green: 1.0, blue: 0.78, alpha: alpha).cgColor)
    ctx.setLineWidth(26)
    ctx.addArc(
        center: center,
        radius: radius,
        startAngle: -.pi * 0.36,
        endAngle: .pi * 0.36,
        clockwise: false
    )
    ctx.strokePath()
}

// Точка-источник
ctx.setFillColor(NSColor(calibratedRed: 0.45, green: 1.0, blue: 0.82, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52))

ctx.restoreGState()

// MARK: - Динамик и индикатор

let speakerRect = CGRect(
    x: phoneRect.midX - 42,
    y: phoneRect.maxY - 30,
    width: 84,
    height: 11
)
ctx.addPath(CGPath(roundedRect: speakerRect, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil))
ctx.setFillColor(NSColor(calibratedWhite: 0.45, alpha: 1).cgColor)
ctx.fillPath()

// Блик по левому краю стекла
ctx.saveGState()
ctx.addPath(screenPath)
ctx.clip()
let shine = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor.white.withAlphaComponent(0.16).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    shine,
    start: CGPoint(x: screenRect.minX, y: screenRect.maxY),
    end: CGPoint(x: screenRect.minX + screenRect.width * 0.75, y: screenRect.midY),
    options: []
)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

// MARK: - Сохранение

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("Использование: swift IconGen.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Не удалось создать PNG\n".data(using: .utf8)!)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("Иконка сохранена: \(CommandLine.arguments[1])")
} catch {
    FileHandle.standardError.write("Ошибка записи: \(error)\n".data(using: .utf8)!)
    exit(1)
}