import Foundation

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

enum IconShape: String, Codable, CaseIterable, Identifiable {
    case none
    case rounded
    case circle
    case squircle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "原始"
        case .rounded: "圆角"
        case .circle: "圆形"
        case .squircle: "超椭圆"
        }
    }

    var systemImage: String {
        switch self {
        case .none: "square"
        case .rounded: "square.grid.2x2"
        case .circle: "circle"
        case .squircle: "app.dashed"
        }
    }

    func cornerRadius(for size: CGFloat) -> CGFloat {
        switch self {
        case .none: 0
        case .rounded: size * 0.2
        case .circle: size / 2
        case .squircle: size * 0.225
        }
    }
}

struct IconScheme: Codable, Identifiable, Equatable {
    var id: UUID
    var appURL: URL
    var lightIconURL: URL?
    var darkIconURL: URL?
    var enabled: Bool
    var lastAppliedMode: AppearanceMode?
    var originalIconBackupURL: URL?
    var iconShape: IconShape

    init(
        id: UUID = UUID(),
        appURL: URL,
        lightIconURL: URL? = nil,
        darkIconURL: URL? = nil,
        enabled: Bool = true,
        lastAppliedMode: AppearanceMode? = nil,
        originalIconBackupURL: URL? = nil,
        iconShape: IconShape = .none
    ) {
        self.id = id
        self.appURL = appURL
        self.lightIconURL = lightIconURL
        self.darkIconURL = darkIconURL
        self.enabled = enabled
        self.lastAppliedMode = lastAppliedMode
        self.originalIconBackupURL = originalIconBackupURL
        self.iconShape = iconShape
    }

    var appName: String {
        appURL.deletingPathExtension().lastPathComponent
    }

    func iconURL(for mode: AppearanceMode) -> URL? {
        switch mode {
        case .light:
            lightIconURL
        case .dark:
            darkIconURL
        }
    }

    // MARK: Codable - handle new fields with defaults

    enum CodingKeys: String, CodingKey {
        case id, appURL, lightIconURL, darkIconURL, enabled
        case lastAppliedMode, originalIconBackupURL, iconShape
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        appURL = try container.decode(URL.self, forKey: .appURL)
        lightIconURL = try container.decodeIfPresent(URL.self, forKey: .lightIconURL)
        darkIconURL = try container.decodeIfPresent(URL.self, forKey: .darkIconURL)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        lastAppliedMode = try container.decodeIfPresent(AppearanceMode.self, forKey: .lastAppliedMode)
        originalIconBackupURL = try container.decodeIfPresent(URL.self, forKey: .originalIconBackupURL)
        iconShape = try container.decodeIfPresent(IconShape.self, forKey: .iconShape) ?? .none
    }
}

struct OperationLog: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let message: String
    let isError: Bool
}
