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

    enum CustomSourceValidationError: LocalizedError {
        case invalidName
        case invalidTemplate
        case insecureTemplate
        case missingSongIdentifier
        case invalidResponsePath
        case duplicate
        case limitReached

        var errorDescription: String? {
            switch self {
            case .invalidName:
                return "请填写不超过 40 个字符的音源名称。"
            case .invalidTemplate:
                return "接口模板必须是有效的网址。"
            case .insecureTemplate:
                return "为保护隐私，仅支持 HTTPS 接口地址。"
            case .missingSongIdentifier:
                return "接口模板需至少包含 {id}、{name} 或 {keyword} 之一。"
            case .invalidResponsePath:
                return "返回字段路径只能使用字母、数字、点、下划线、横线和 |。"
            case .duplicate:
                return "相同的自定义音源已经存在。"
            case .limitReached:
                return "最多可保存 20 个自定义音源。"
            }
        }
    }

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

    var builtInSources: [ThirdPartySource] {
        presetSources.filter(\.isPreset)
    }

    var customSources: [ThirdPartySource] {
        presetSources.filter { !$0.isPreset }
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

    func addCustomSource(
        name: String,
        template: String,
        urlPath: String,
        provider: String,
        quality: String = "320k"
    ) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = urlPath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedName.isEmpty, normalizedName.count <= 40 else {
            throw CustomSourceValidationError.invalidName
        }
        guard normalizedTemplate.count <= 2_048 else {
            throw CustomSourceValidationError.invalidTemplate
        }
        guard ["{id}", "{name}", "{keyword}"].contains(where: { normalizedTemplate.contains($0) }) else {
            throw CustomSourceValidationError.missingSongIdentifier
        }

        let sampleTemplate = normalizedTemplate
            .replacingOccurrences(of: "{id}", with: "1")
            .replacingOccurrences(of: "{source}", with: "wy")
            .replacingOccurrences(of: "{quality}", with: "320k")
            .replacingOccurrences(of: "{name}", with: "song")
            .replacingOccurrences(of: "{keyword}", with: "song")
            .replacingOccurrences(of: "{artist}", with: "artist")
        guard let components = URLComponents(string: sampleTemplate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            throw CustomSourceValidationError.invalidTemplate
        }
        guard scheme == "https" else {
            throw CustomSourceValidationError.insecureTemplate
        }

        let allowedPathCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._|-"))
        guard !normalizedPath.isEmpty,
              normalizedPath.unicodeScalars.allSatisfy({ allowedPathCharacters.contains($0) }) else {
            throw CustomSourceValidationError.invalidResponsePath
        }
        guard customSources.count < 20 else {
            throw CustomSourceValidationError.limitReached
        }
        guard !customSources.contains(where: {
            $0.template == normalizedTemplate && $0.urlPath == normalizedPath
        }) else {
            throw CustomSourceValidationError.duplicate
        }

        var headers = ["quality": quality]
        if provider != "all" {
            headers["source"] = provider
        }
        presetSources.append(
            ThirdPartySource(
                name: normalizedName,
                kind: "custom",
                template: normalizedTemplate,
                urlPath: normalizedPath,
                headers: headers,
                isPreset: false
            )
        )
    }

    func removeCustomSource(id: String) {
        guard let index = presetSources.firstIndex(where: { $0.id == id && !$0.isPreset }) else { return }
        presetSources.remove(at: index)
    }
}
