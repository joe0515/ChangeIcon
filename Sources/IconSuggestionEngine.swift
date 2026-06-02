import AppKit
import Foundation

// MARK: - Icon Suggestion

struct IconSuggestion: Identifiable, Hashable {
    let id = UUID()
    let previewURL: URL
    let category: SuggestionCategory
    let label: String
    let mode: AppearanceMode
    let source: SuggestionSource

    enum SuggestionCategory: String, CaseIterable {
        case generated = "亮度调整"
        case flat = "简约平面"
        case duotone = "双色调"
        case coloroverlay = "色彩覆盖"
        case ai = "AI 创意"
    }

    enum SuggestionSource: String {
        case local
        case ai
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: IconSuggestion, rhs: IconSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Icon Suggestion Engine

@MainActor
final class IconSuggestionEngine: ObservableObject {
    @Published var suggestions: [IconSuggestion] = []
    @Published var isLoading = false
    @Published var loadingMessage = ""
    @Published var isAILoading = false

    private let fileManager = FileManager.default
    private let workDir: URL
    private let urlSession: URLSession

    init() {
        let tmp = fileManager.temporaryDirectory
        workDir = tmp.appendingPathComponent("ChangeIcon-Suggestions", isDirectory: true)
        try? fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        urlSession = URLSession(configuration: config)
    }

    func generateSuggestions(for appURL: URL, appName: String) async {
        isLoading = true
        loadingMessage = "正在生成图标建议..."
        defer { isLoading = false }

        let existing = try? fileManager.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
        for url in existing ?? [] {
            try? fileManager.removeItem(at: url)
        }

        var results: [IconSuggestion] = []

        let originalIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        let iconBase = originalIcon.copy() as! NSImage

        // ---- 亮度/饱和度调整 (基于原图标) ----

        if let url = adjustedIcon(from: iconBase, brightness: 0.15, saturation: 1.1, label: "light_bright") {
            results.append(IconSuggestion(previewURL: url, category: .generated, label: "浅色 · 提亮", mode: .light, source: .local))
        }
        if let url = adjustedIcon(from: iconBase, brightness: -0.15, saturation: 0.9, label: "dark_dim") {
            results.append(IconSuggestion(previewURL: url, category: .generated, label: "深色 · 暗化", mode: .dark, source: .local))
        }

        // ---- 简约平面 (基于原图标简化) ----

        if let url = flatStyleIcon(from: iconBase, mode: .light, label: "light_flat") {
            results.append(IconSuggestion(previewURL: url, category: .flat, label: "浅色 · 平面", mode: .light, source: .local))
        }
        if let url = flatStyleIcon(from: iconBase, mode: .dark, label: "dark_flat") {
            results.append(IconSuggestion(previewURL: url, category: .flat, label: "深色 · 平面", mode: .dark, source: .local))
        }

        // ---- 双色调 (基于原图标提取双色) ----

        if let url = duotoneIcon(from: iconBase, mode: .light, label: "light_duotone") {
            results.append(IconSuggestion(previewURL: url, category: .duotone, label: "浅色 · 双色", mode: .light, source: .local))
        }
        if let url = duotoneIcon(from: iconBase, mode: .dark, label: "dark_duotone") {
            results.append(IconSuggestion(previewURL: url, category: .duotone, label: "深色 · 双色", mode: .dark, source: .local))
        }

        // ---- 色彩覆盖 (基于原图标覆盖色调) ----

        if let url = colorOverlayIcon(from: iconBase, mode: .light, overlayColor: NSColor(red: 0.85, green: 0.35, blue: 0.25, alpha: 1), label: "light_overlay_warm") {
            results.append(IconSuggestion(previewURL: url, category: .coloroverlay, label: "浅色 · 暖色", mode: .light, source: .local))
        }
        if let url = colorOverlayIcon(from: iconBase, mode: .dark, overlayColor: NSColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1), label: "dark_overlay_cool") {
            results.append(IconSuggestion(previewURL: url, category: .coloroverlay, label: "深色 · 冷色", mode: .dark, source: .local))
        }

        suggestions = results

        // ---- AI 生成 (后台异步) ----
        isAILoading = true
        let aiResults = await generateAISuggestions(appName: appName)
        if !aiResults.isEmpty {
            suggestions.append(contentsOf: aiResults)
        }
        isAILoading = false
    }

    // MARK: - AI Generation (Pollinations.ai)

    private func generateAISuggestions(appName: String) async -> [IconSuggestion] {
        let themes: [(mode: AppearanceMode, label: String, promptStyle: String)] = [
            (.light, "AI · 浅色", "light theme, white background, bright colors, clean modern design"),
            (.dark, "AI · 深色", "dark theme, dark background, vibrant neon accents, sleek modern design"),
        ]

        var results: [IconSuggestion] = []

        for theme in themes {
            let prompt = """
            A professional macOS application icon for "\(appName)", \(theme.promptStyle), \
            rounded square shape with soft shadows, minimalist app icon style, \
            no text or letters in the icon, centered composition, high quality, \
            suitable for macOS dock
            """

            let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = "https://image.pollinations.ai/prompt/\(encoded)?width=512&height=512&model=flux&nologo=true"

            guard let url = URL(string: urlString) else { continue }

            do {
                let (data, response) = try await urlSession.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { continue }

                let label = "ai_\(theme.mode.rawValue)"
                let outputURL = workDir.appendingPathComponent("\(label).png")

                if let image = NSImage(data: data), savePNG(image, to: outputURL, size: 512) != nil {
                    results.append(IconSuggestion(
                        previewURL: outputURL,
                        category: .ai,
                        label: theme.label,
                        mode: theme.mode,
                        source: .ai
                    ))
                }
            } catch {
                continue
            }
        }

        return results
    }

    // MARK: - Image Processing Helpers

    private func adjustedIcon(from image: NSImage, brightness: CGFloat, saturation: CGFloat, label: String) -> URL? {
        let size: CGFloat = 512
        let outputURL = workDir.appendingPathComponent("\(label).png")

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ciImage = CIImage(cgImage: cgImage)

        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(brightness, forKey: kCIInputBrightnessKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)

        guard let output = filter.outputImage else { return nil }

        let rep = NSCIImageRep(ciImage: output)
        let nsImage = NSImage(size: NSSize(width: size, height: size))
        nsImage.addRepresentation(rep)

        return savePNG(nsImage, to: outputURL, size: size)
    }

    private func flatStyleIcon(from image: NSImage, mode: AppearanceMode, label: String) -> URL? {
        let size: CGFloat = 512
        let outputURL = workDir.appendingPathComponent("\(label).png")

        let canvas = NSImage(size: NSSize(width: size, height: size))
        canvas.lockFocus()

        if mode == .light {
            NSColor(white: 0.95, alpha: 1).setFill()
        } else {
            NSColor(white: 0.1, alpha: 1).setFill()
        }
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        let iconSize = size * 0.65
        let origin = (size - iconSize) / 2
        image.draw(in: NSRect(x: origin, y: origin, width: iconSize, height: iconSize),
                   from: .zero, operation: .sourceOver, fraction: 0.85)

        if mode == .light {
            NSColor.black.withAlphaComponent(0.06).setFill()
        } else {
            NSColor.white.withAlphaComponent(0.06).setFill()
        }
        let shadowPath = NSBezierPath(ovalIn: NSRect(x: (size - iconSize * 0.5) / 2, y: origin * 0.4, width: iconSize * 0.5, height: iconSize * 0.15))
        shadowPath.fill()

        canvas.unlockFocus()
        return savePNG(canvas, to: outputURL, size: size)
    }

    private func duotoneIcon(from image: NSImage, mode: AppearanceMode, label: String) -> URL? {
        let size: CGFloat = 512
        let outputURL = workDir.appendingPathComponent("\(label).png")

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ciImage = CIImage(cgImage: cgImage)

        let mono = CIFilter(name: "CIPhotoEffectMono")!
        mono.setValue(ciImage, forKey: kCIInputImageKey)
        guard let monoOutput = mono.outputImage else { return nil }

        let colorFilter = CIFilter(name: "CIFalseColor")!
        colorFilter.setValue(monoOutput, forKey: kCIInputImageKey)

        if mode == .light {
            colorFilter.setValue(CIColor(red: 0.95, green: 0.92, blue: 0.88), forKey: "inputColor0")
            colorFilter.setValue(CIColor(red: 0.15, green: 0.20, blue: 0.30), forKey: "inputColor1")
        } else {
            colorFilter.setValue(CIColor(red: 0.08, green: 0.08, blue: 0.12), forKey: "inputColor0")
            colorFilter.setValue(CIColor(red: 0.70, green: 0.72, blue: 0.78), forKey: "inputColor1")
        }

        guard let duotone = colorFilter.outputImage else { return nil }

        let rep = NSCIImageRep(ciImage: duotone)
        let nsImage = NSImage(size: NSSize(width: size, height: size))
        nsImage.addRepresentation(rep)

        return savePNG(nsImage, to: outputURL, size: size)
    }

    private func colorOverlayIcon(from image: NSImage, mode: AppearanceMode, overlayColor: NSColor, label: String) -> URL? {
        let size: CGFloat = 512
        let outputURL = workDir.appendingPathComponent("\(label).png")

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ciImage = CIImage(cgImage: cgImage)

        let mono = CIFilter(name: "CIPhotoEffectMono")!
        mono.setValue(ciImage, forKey: kCIInputImageKey)
        guard let monoOutput = mono.outputImage else { return nil }

        let colorFilter = CIFilter(name: "CIColorMonochrome")!
        colorFilter.setValue(monoOutput, forKey: kCIInputImageKey)
        let ciOverlay = CIColor(cgColor: overlayColor.cgColor)
        colorFilter.setValue(ciOverlay, forKey: kCIInputColorKey)
        colorFilter.setValue(0.55, forKey: kCIInputIntensityKey)

        guard let output = colorFilter.outputImage else { return nil }

        let rep = NSCIImageRep(ciImage: output)
        let nsImage = NSImage(size: NSSize(width: size, height: size))
        nsImage.addRepresentation(rep)

        return savePNG(nsImage, to: outputURL, size: size)
    }

    private func savePNG(_ image: NSImage, to url: URL, size: CGFloat) -> URL? {
        let resized = NSImage(size: NSSize(width: size, height: size))
        resized.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                   from: .zero, operation: .copy, fraction: 1.0)
        resized.unlockFocus()

        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }

        do {
            try pngData.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
