import Foundation

/// Однократная загрузка при старте: только RPC `get_effects_home` — каталог эффектов для UI.
enum SupabaseSessionBootstrap {

    private static func log(_ message: String) {
        Swift.print("[Supabase] \(message)")
    }

    private static var supabaseURL: String {
        (ConfigurationManager.shared.getValue(for: .supabaseURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var anonKey: String {
        (ConfigurationManager.shared.getValue(for: .supabaseAnonKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var isConfigured: Bool {
        !supabaseURL.isEmpty && !anonKey.isEmpty && !supabaseURL.contains("YOUR_") && !anonKey.contains("YOUR_")
    }

    static func loadSessionSnapshot() async throws -> EffectsHomePayload {
        guard isConfigured else {
            log("bootstrap: пропуск — не заданы SUPABASE_URL / SUPABASE_ANON_KEY (или плейсхолдер YOUR_*)")
            throw NetworkError.invalidConfiguration
        }
        log("bootstrap: старт loadSessionSnapshot (base \(supabaseURL.prefix(48))…)")
        let effects = try await fetchEffectsHome()
        return effects
    }

    private static func fetchEffectsHome() async throws -> EffectsHomePayload {
        let trimmed = supabaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = "\(trimmed)/rest/v1/rpc/get_effects_home"
        guard let url = URL(string: endpoint) else {
            throw NetworkError.invalidURL
        }
        log("POST get_effects_home → \(endpoint)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
            log("get_effects_home HTTP \(http.statusCode) URL=\(endpoint) body: \(snippet)")
            throw NetworkError.httpError(http.statusCode)
        }
        let decoder = JSONDecoder()
        do {
            let rawPayload = try decoder.decode(EffectsHomePayload.self, from: data)
            let payload = rawPayload.mergingHeroPreviewMediaFromSections()
            let snippet = String(data: data.prefix(1200), encoding: .utf8) ?? ""
            log("get_effects_home HTTP \(http.statusCode) bytes=\(data.count) bodyPrefix=\(snippet)")
            return payload
        } catch {
            let snippet = String(data: data.prefix(800), encoding: .utf8) ?? ""
            log("decode EffectsHomePayload: \(error). Body prefix: \(snippet)")
            throw NetworkError.decodingFailed
        }
    }
}
