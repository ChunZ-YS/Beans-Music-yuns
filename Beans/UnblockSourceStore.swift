import Foundation

/// 内置第三方解锁源。
/// kind：用于在设置界面标识预设类型。
/// template：请求 URL 模板，支持 {id}、{source}、{quality} 占位符。
/// headers：可选的请求头与内置元数据。
struct ThirdPartySource: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var name: String
    var kind: String = "keyword"
    var template: String
    var urlPath: String = "url"
    var headers: [String: String] = [:]
    var enabled: Bool = true
    var isPreset: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, kind, template, urlPath, headers, enabled, isPreset
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        kind: String = "keyword",
        template: String,
        urlPath: String = "url",
        headers: [String: String] = [:],
        enabled: Bool = true,
        isPreset: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.template = template
        self.urlPath = urlPath
        self.headers = headers
        self.enabled = enabled
        self.isPreset = isPreset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名音源"
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "keyword"
        template = try container.decodeIfPresent(String.self, forKey: .template) ?? ""
        urlPath = try container.decodeIfPresent(String.self, forKey: .urlPath) ?? "url"
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        isPreset = try container.decodeIfPresent(Bool.self, forKey: .isPreset) ?? false
    }
}

/// 内置音源管理：首次启动时写入可直接调用的公益音源预设。
final class UnblockSourceStore: ObservableObject {
    static let shared = UnblockSourceStore()

    private static let publicAPIURL = "https://source.shiqianjiang.cn/api/music"
    private static let publicURLTemplate = "\(publicAPIURL)/url?source={source}&songId={id}&quality={quality}"

    /// 与 KMusic-2026 的“新澜音源”一致的公开 HTTPS 接口。
    /// Beans 仅调用与自身歌曲模型匹配的平台（网易云、QQ、酷狗），且不随应用携带 API 密钥。
    static let publicPresetSources: [ThirdPartySource] = [
        ThirdPartySource(
            id: "beans.preset.xinlan.public.v1",
            name: "新澜公益音源",
            kind: "public-lx",
            template: publicURLTemplate,
            headers: ["quality": "320k"],
            isPreset: true
        ),
    ]

    @Published var presetSources: [ThirdPartySource] {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard
    private let presetsKey = "beans.unblock.presets"
    private let legacyCustomKey = "beans.unblock.custom"
    private let legacyLXKey = "beans.unblock.lxScripts"

    private init() {
        let savedSources: [ThirdPartySource]
        if let data = defaults.data(forKey: presetsKey),
           let list = try? JSONDecoder().decode([ThirdPartySource].self, from: data) {
            savedSources = list
        } else if let data = defaults.data(forKey: legacyCustomKey),
                  let list = try? JSONDecoder().decode([ThirdPartySource].self, from: data) {
            savedSources = list
        } else {
            savedSources = []
        }

        // 迁移时移除旧版带密钥的预设，但保留用户自行添加的自定义项。
        let existingSources = savedSources.filter { source in
            !source.isPreset || publicPresetSources.contains(where: { $0.id == source.id })
        }
        presetSources = Self.seedPublicPresets(into: existingSources)
        defaults.removeObject(forKey: legacyCustomKey)
        defaults.removeObject(forKey: legacyLXKey)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presetSources) {
            defaults.set(data, forKey: presetsKey)
        }
    }

    private static func seedPublicPresets(into savedSources: [ThirdPartySource]) -> [ThirdPartySource] {
        var seeded = savedSources
        for preset in publicPresetSources {
            if let index = seeded.firstIndex(where: { $0.id == preset.id }) {
                var updated = preset
                updated.enabled = seeded[index].enabled
                seeded[index] = updated
            } else {
                seeded.append(preset)
            }
        }
        return seeded
    }
}
