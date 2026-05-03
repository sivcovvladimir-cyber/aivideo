import Foundation

/// Единый префикс `[Supabase]` для фильтра в консоли Xcode (все сетевые/кэш-логи этого файла).
fileprivate enum SupabaseLog {
    static func line(_ message: String) {
        Swift.print("[Supabase] \(message)")
    }
}

/// Протокол для работы с Supabase (конфиги, опциональные категории PostgREST, фото, логи).
protocol SupabaseServiceProtocol {
    /// Категории для группировки (если таблица `style_categories` есть в проекте).
    func fetchSupabaseEffectCategories(completion: @escaping (Result<[SupabaseEffectCategoryRow], NetworkError>) -> Void)
    /// Загружает конфиг (например, styles_last_updated)
    func fetchConfig(key: String, completion: @escaping (Result<String, NetworkError>) -> Void)
    /// Загружает фото пользователя в Supabase Storage
    func uploadUserPhoto(data: Data, fileName: String, completion: @escaping (Result<String, NetworkError>) -> Void)
    /// Записывает историю генерации (лог) в Supabase
    func logGeneration(userId: String?, userPhotoId: String?, effectRowId: Int?, resultUrl: String?, status: String, errorMessage: String?, completion: ((Result<Void, NetworkError>) -> Void)?)
    /// RPC `increment_style_usage` — колонка в БД по-прежнему `style_id`.
    func incrementEffectRowUsage(effectRowId: Int, completion: ((Result<Void, NetworkError>) -> Void)?)
}

/// Сервис для работы с Supabase
public class SupabaseService: SupabaseServiceProtocol {
    // MARK: - Singleton
    public static let shared = SupabaseService()
    private init() {}

    // MARK: - Constants
    private let supabaseUrl = ConfigurationManager.shared.getValue(for: .supabaseURL) ?? ""
    private let supabaseApiKey = ConfigurationManager.shared.getValue(for: .supabaseAnonKey) ?? ""
    
    // MARK: - Custom URLSession with HTTP/1.1
    private lazy var customSession: URLSession = {
        let config = URLSessionConfiguration.default
        
        // Принудительно отключаем HTTP/3 и используем HTTP/1.1
        config.httpMaximumConnectionsPerHost = 1
        config.httpShouldUsePipelining = false
        
        // Отключаем HTTP/2 и HTTP/3, принудительно используем HTTP/1.1
        if #available(iOS 13.0, *) {
            // Отключаем multiplexing (HTTP/2 feature)
            config.multipathServiceType = .none
        }
        
        // Настройки таймаутов остаются прежними
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 10.0
        
        SupabaseLog.line("🌐 [SupabaseService] URLSession configured for HTTP/1.1 only")
        
        return URLSession(configuration: config)
    }()

    // MARK: - Methods
    /// Получает значение конфига из Supabase (например, styles_last_updated)
    public func fetchConfig(key: String, completion: @escaping (Result<String, NetworkError>) -> Void) {
        let urlString = "\(supabaseUrl)/rest/v1/config?config_key=eq.\(key)"
        SupabaseLog.line("[SupabaseService] fetchConfig URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            SupabaseLog.line("[SupabaseService] Неверный URL для config")
            completion(.failure(.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue(supabaseApiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                SupabaseLog.line("[SupabaseService] Ошибка запроса config: \(error)")
                completion(.failure(.requestFailed(error)))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                SupabaseLog.line("[SupabaseService] HTTP статус config: \(httpResponse.statusCode)")
            }
            
            guard let data = data else {
                SupabaseLog.line("[SupabaseService] Нет данных в ответе config")
                completion(.failure(.invalidResponse))
                return
            }
            
            // Выводим сырые данные для отладки
            if let responseString = String(data: data, encoding: .utf8) {
                SupabaseLog.line("[SupabaseService] Ответ config: \(responseString)")
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    SupabaseLog.line("[SupabaseService] JSON config: \(json)")
                    if let value = json.first?["config_value"] as? String {
                        SupabaseLog.line("[SupabaseService] Найден config_value: \(value)")
                    completion(.success(value))
                    } else {
                        SupabaseLog.line("[SupabaseService] config_value не найден в JSON")
                        completion(.failure(.decodingFailed))
                    }
                } else {
                    SupabaseLog.line("[SupabaseService] Не удалось распарсить JSON как массив")
                    completion(.failure(.decodingFailed))
                }
            } catch {
                SupabaseLog.line("[SupabaseService] Ошибка парсинга JSON config: \(error)")
                completion(.failure(.decodingFailed))
            }
        }
        task.resume()
    }
    
    /// Создает или обновляет запись в таблице config
    public func upsertConfig(key: String, value: String, completion: @escaping (Result<Void, NetworkError>) -> Void) {
        let urlString = "\(supabaseUrl)/rest/v1/config"
        SupabaseLog.line("[SupabaseService] upsertConfig URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            SupabaseLog.line("[SupabaseService] Неверный URL для upsert config")
            completion(.failure(.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseApiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        
        let body: [String: String] = [
            "config_key": key,
            "config_value": value
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            SupabaseLog.line("[SupabaseService] Ошибка сериализации body: \(error)")
            completion(.failure(.decodingFailed))
            return
        }
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                SupabaseLog.line("[SupabaseService] Ошибка upsert config: \(error)")
                completion(.failure(.requestFailed(error)))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                SupabaseLog.line("[SupabaseService] HTTP статус upsert config: \(httpResponse.statusCode)")
            }
            
            if let data = data, let responseString = String(data: data, encoding: .utf8) {
                SupabaseLog.line("[SupabaseService] Ответ upsert config: \(responseString)")
            }
            
            completion(.success(()))
        }
        task.resume()
    }

    /// Записывает историю генерации (лог) в Supabase
    public func logGeneration(userId: String?, userPhotoId: String?, effectRowId: Int?, resultUrl: String?, status: String, errorMessage: String?, completion: ((Result<Void, NetworkError>) -> Void)?) {
        guard let url = URL(string: "\(supabaseUrl)/rest/v1/generation_history") else {
            completion?(.failure(.invalidURL))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseApiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any?] = [
            "user_id": userId,
            "user_photo_id": userPhotoId,
            "style_id": effectRowId,
            "result_url": resultUrl,
            "status": status,
            "error_message": errorMessage
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: [body], options: [])
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion?(.failure(.requestFailed(error)))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                completion?(.failure(.invalidResponse))
                return
            }
            completion?(.success(()))
        }
        task.resume()
    }

    /// Диагностика журнала `generation_logs` из `GenerationJobService`: тот же префикс `[Supabase]`, метка `generation_log` для фильтра в Xcode.
    public static func logGenerationJournal(_ message: String) {
        SupabaseLog.line("generation_log \(message)")
    }

    /// Журнал `generation_logs` через RPC `upsert_generation_log`: bundle id для фильтра в Supabase Table Editor между таргетами/сборками.
    func upsertVideoGenerationLog(
        clientGenerationId: Int,
        generationType: String,
        status: String,
        effectPresetId: Int?,
        providerJobId: String?,
        prompt: String?,
        aspectRatio: String?,
        durationSeconds: Int?,
        audioEnabled: Bool?,
        tokenCost: Int?,
        resultURL: String?,
        errorMessage: String?,
        startedAt: Date?,
        completedAt: Date?
    ) async {
        let base = supabaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = supabaseApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            Self.logGenerationJournal("RPC upsert_generation_log: пропуск — пустой supabase URL (проверь ConfigurationManager / APIKeys)")
            return
        }
        if key.isEmpty {
            Self.logGenerationJournal("RPC upsert_generation_log: пропуск — пустой anon key")
            return
        }
        if base.contains("YOUR_") {
            Self.logGenerationJournal("RPC upsert_generation_log: пропуск — в URL остался плейсхолдер YOUR_…")
            return
        }
        if key.contains("YOUR_") {
            Self.logGenerationJournal("RPC upsert_generation_log: пропуск — в ключе остался плейсхолдер YOUR_…")
            return
        }

        let endpoint = "\(base)/rest/v1/rpc/upsert_generation_log"
        guard let url = URL(string: endpoint) else {
            Self.logGenerationJournal("RPC upsert_generation_log: невалидный URL после сборки endpoint (первые 96 символов): \(String(endpoint.prefix(96)))")
            return
        }

        var body: [String: Any] = [
            "p_client_generation_id": clientGenerationId,
            "p_user_install_id": UserInstallIDService.shared.installId,
            "p_generation_type": generationType,
            "p_status": status,
            "p_provider": "pixverse",
            "p_request_metadata": ["platform": "ios"] as [String: Any],
            "p_response_metadata": [String: Any](),
            "p_result_urls": [Any]()
        ]
        if let bundleId = Bundle.main.bundleIdentifier {
            body["p_app_bundle_id"] = bundleId
        }
        if let effectPresetId { body["p_effect_preset_id"] = effectPresetId }
        if let providerJobId { body["p_provider_job_id"] = providerJobId }
        if let prompt { body["p_prompt"] = prompt }
        if let aspectRatio { body["p_aspect_ratio"] = aspectRatio }
        if let durationSeconds { body["p_duration_seconds"] = durationSeconds }
        if let audioEnabled { body["p_audio_enabled"] = audioEnabled }
        if let tokenCost { body["p_token_cost"] = tokenCost }
        if let resultURL { body["p_result_url"] = resultURL }
        if let errorMessage { body["p_error_message"] = errorMessage }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let startedAt { body["p_started_at"] = iso.string(from: startedAt) }
        if let completedAt { body["p_completed_at"] = iso.string(from: completedAt) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            Self.logGenerationJournal("RPC upsert_generation_log: JSONSerialization не удалась client=\(clientGenerationId) status=\(status)")
            return
        }
        request.httpBody = httpBody

        let installId = UserInstallIDService.shared.installId
        let promptPreview: String = {
            guard let p = prompt, !p.isEmpty else { return "nil" }
            if p.count <= 160 { return "\"\(p)\"" }
            return "\"\(String(p.prefix(160)))…\" (total \(p.count) chars)"
        }()
        let hostForLog = url.host ?? "(no host)"
        Self.logGenerationJournal(
            "RPC upsert_generation_log → POST …/rpc/upsert_generation_log host=\(hostForLog) client=\(clientGenerationId) job_status=\(status) gen_type=\(generationType) preset=\(effectPresetId.map(String.init) ?? "nil") provider_job=\(providerJobId ?? "nil") tokens=\(tokenCost.map(String.init) ?? "nil") install_id=\(installId) bundle=\(Bundle.main.bundleIdentifier ?? "nil") body_bytes=\(httpBody.count) prompt=\(promptPreview)"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                Self.logGenerationJournal("RPC upsert_generation_log: ответ без HTTPURLResponse client=\(clientGenerationId)")
                return
            }
            if (200 ... 299).contains(http.statusCode) {
                Self.logGenerationJournal("RPC upsert_generation_log: успех HTTP \(http.statusCode) client=\(clientGenerationId) job_status=\(status)")
            } else {
                let snippet: String = {
                    guard !data.isEmpty else { return "(пустое тело)" }
                    let s = String(decoding: data, as: UTF8.self)
                    if s.count <= 900 { return s }
                    return String(s.prefix(900)) + "…"
                }()
                Self.logGenerationJournal("RPC upsert_generation_log: ошибка HTTP \(http.statusCode) client=\(clientGenerationId) — тело: \(snippet)")
            }
        } catch {
            Self.logGenerationJournal("RPC upsert_generation_log: сеть client=\(clientGenerationId): \(error.localizedDescription)")
        }
    }

    /// Атомарно увеличивает usage_count для стиля
    public func incrementEffectRowUsage(effectRowId: Int, completion: ((Result<Void, NetworkError>) -> Void)?) {
        // Используем RPC функцию для атомарного увеличения
        guard let url = URL(string: "\(supabaseUrl)/rest/v1/rpc/increment_style_usage") else {
            completion?(.failure(.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseApiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        // PostgREST ожидает ключ `style_id` (legacy-схема). функции
        let body: [String: Any] = [
            "style_id": effectRowId
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion?(.failure(.decodingFailed))
            return
        }
        

        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                SupabaseLog.line("❌ [SupabaseService] incrementEffectRowUsage error: \(error)")
                completion?(.failure(.requestFailed(error)))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if !(200...299).contains(httpResponse.statusCode) {
                    SupabaseLog.line("❌ [SupabaseService] incrementEffectRowUsage HTTP error: \(httpResponse.statusCode)")
                    completion?(.failure(.invalidResponse))
                    return
                }
            }
            
            completion?(.success(()))
        }
        task.resume()
    }

    /// Очищает кэш категорий
    func clearCategoriesCache() {
        UserDefaults.standard.removeObject(forKey: "categories_cache")
        SupabaseLog.line("[SupabaseService] Кэш категорий очищен")
    }
    
    /// Сохраняет категории в кэш
    private func saveCategoriesToCache(_ categories: [SupabaseEffectCategoryRow]) {
        if let data = try? JSONEncoder().encode(categories) {
            UserDefaults.standard.set(data, forKey: "categories_cache")
            SupabaseLog.line("[SupabaseService] Категории сохранены в кэш: \(categories.count) шт.")
        }
    }
    
    /// Загружает категории из кэша
    private func loadCategoriesFromCache() -> [SupabaseEffectCategoryRow]? {
        guard let data = UserDefaults.standard.data(forKey: "categories_cache"),
              let categories = try? JSONDecoder().decode([SupabaseEffectCategoryRow].self, from: data) else {
            SupabaseLog.line("[SupabaseService] Кэш категорий не найден или поврежден")
            return nil
        }
        SupabaseLog.line("[SupabaseService] Загружено категорий из кэша: \(categories.count) шт.")
        return categories
    }

    // MARK: - File Operations
    
    /// Upload a file to Supabase Storage
    func uploadFile(fileName: String, data: Data) async throws -> String {
        let url = URL(string: "\(supabaseUrl)/storage/v1/object/user-photos/\(fileName)")!
        
        SupabaseLog.line("📤 [SupabaseService] uploadFile called:")
        SupabaseLog.line("   URL: \(url)")
        SupabaseLog.line("   File name: \(fileName)")
        SupabaseLog.line("   Data size: \(data.count) bytes")
        SupabaseLog.line("   Supabase URL: \(supabaseUrl)")
        SupabaseLog.line("   Bucket: user-photos")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5.0 // Короткий таймаут для быстрых retry
        
        request.setValue(supabaseApiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        
        SupabaseLog.line("📤 [SupabaseService] Sending request with headers:")
        SupabaseLog.line("   apikey: \(String(supabaseApiKey.prefix(10)))...")
        SupabaseLog.line("   Authorization: Bearer \(String(supabaseApiKey.prefix(10)))...")
        SupabaseLog.line("   Content-Type: image/jpeg")
        SupabaseLog.line("   Using key type: anon")
        SupabaseLog.line("   Request body size: \(data.count) bytes")
        SupabaseLog.line("   Timeout: 5 seconds")
        
        do {
            SupabaseLog.line("📤 [SupabaseService] Starting network request...")
            SupabaseLog.line("🌐 [SupabaseService] Using custom URLSession (HTTP/1.1 only)")
            let startTime = Date()
            let (data, response) = try await customSession.data(for: request)
            let endTime = Date()
            let duration = endTime.timeIntervalSince(startTime)
            
            SupabaseLog.line("📤 [SupabaseService] Network request completed in \(String(format: "%.2f", duration)) seconds")
        
        if let httpResponse = response as? HTTPURLResponse {
            SupabaseLog.line("📤 [SupabaseService] HTTP response status: \(httpResponse.statusCode)")
            SupabaseLog.line("📤 [SupabaseService] Response headers: \(httpResponse.allHeaderFields)")
            
            if httpResponse.statusCode == 200 {
                // Return the public URL for the uploaded file
                let publicUrl = "\(supabaseUrl)/storage/v1/object/public/user-photos/\(fileName)"
                SupabaseLog.line("✅ [SupabaseService] Upload successful, public URL: \(publicUrl)")
                return publicUrl
                        } else {
                SupabaseLog.line("❌ [SupabaseService] HTTP error: \(httpResponse.statusCode)")
                SupabaseLog.line("❌ [SupabaseService] Response headers: \(httpResponse.allHeaderFields)")
                if let responseData = String(data: data, encoding: .utf8) {
                    SupabaseLog.line("❌ [SupabaseService] Error response body: \(responseData)")
                }
                SupabaseLog.line("❌ [SupabaseService] Common HTTP error meanings:")
                SupabaseLog.line("   400: Bad Request - Invalid request format")
                SupabaseLog.line("   401: Unauthorized - Invalid API key")
                SupabaseLog.line("   403: Forbidden - Insufficient permissions")
                SupabaseLog.line("   404: Not Found - Bucket or file not found")
                SupabaseLog.line("   413: Payload Too Large - File too big")
                SupabaseLog.line("   500: Internal Server Error - Server issue")
                throw NetworkError.httpError(httpResponse.statusCode)
            }
            } else {
                SupabaseLog.line("❌ [SupabaseService] Invalid response type")
                throw NetworkError.invalidResponse
            }
        } catch {
            SupabaseLog.line("❌ [SupabaseService] Request failed: \(error.localizedDescription)")
            SupabaseLog.line("❌ [SupabaseService] Error type: \(type(of: error))")
            if let urlError = error as? URLError {
                SupabaseLog.line("❌ [SupabaseService] URL Error code: \(urlError.code.rawValue)")
                SupabaseLog.line("❌ [SupabaseService] URL Error description: \(urlError.localizedDescription)")
                SupabaseLog.line("❌ [SupabaseService] URL Error failure reason: \(urlError.failureURLString ?? "none")")
            }
            if let networkError = error as? NetworkError {
                SupabaseLog.line("❌ [SupabaseService] NetworkError: \(networkError)")
            }
            SupabaseLog.line("❌ [SupabaseService] Full error: \(error)")
            throw error
        }
    }
    
    /// Проверяет существование файла в Supabase Storage
    func checkFileExists(fileName: String, completion: @escaping (Bool) -> Void) {
        let url = URL(string: "\(supabaseUrl)/storage/v1/object/user-photos/\(fileName)")!
        
        SupabaseLog.line("🔍 [SupabaseService] Checking file existence: \(fileName)")
        SupabaseLog.line("   URL: \(url)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD" // Используем HEAD для проверки существования
        request.timeoutInterval = 10.0
        
        request.setValue(supabaseApiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseApiKey)", forHTTPHeaderField: "Authorization")
        
        Task {
            do {
                let (_, response) = try await customSession.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse {
                    let exists = httpResponse.statusCode == 200
                    SupabaseLog.line("🔍 [SupabaseService] File check result: \(exists) (status: \(httpResponse.statusCode))")
                    DispatchQueue.main.async {
                        completion(exists)
                    }
                } else {
                    SupabaseLog.line("❌ [SupabaseService] Invalid response type for file check")
                    DispatchQueue.main.async {
                        completion(false)
                    }
                }
            } catch {
                SupabaseLog.line("❌ [SupabaseService] File check failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }
    
    /// Delete a file from Supabase Storage
    func deleteFile(fileName: String) async throws {
        let url = URL(string: "\(supabaseUrl)/storage/v1/object/user-photos/\(fileName)")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        request.setValue(supabaseApiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseApiKey)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await customSession.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 200 {
                // File deleted successfully
            } else if httpResponse.statusCode == 404 {
                // Файл не найден - это нормально, если загрузка еще не завершилась
                return
            } else {
                throw NetworkError.httpError(httpResponse.statusCode)
            }
        } else {
            throw NetworkError.invalidResponse
        }
    }

    /// Загружает фото пользователя в Supabase Storage (wrapper для совместимости)
    public func uploadUserPhoto(data: Data, fileName: String, completion: @escaping (Result<String, NetworkError>) -> Void) {
        SupabaseLog.line("📤 [SupabaseService] Starting upload for file: \(fileName)")
        SupabaseLog.line("   Data size: \(data.count) bytes")
        SupabaseLog.line("   File extension: \(fileName.components(separatedBy: ".").last ?? "unknown")")
        SupabaseLog.line("   Supabase URL: \(supabaseUrl)")
        SupabaseLog.line("   Anon key available: \(!supabaseApiKey.isEmpty)")
        
        let startTime = Date()
        Task {
            do {
                let url = try await uploadFile(fileName: fileName, data: data)
                let endTime = Date()
                let duration = endTime.timeIntervalSince(startTime)
                
                SupabaseLog.line("✅ [SupabaseService] Upload successful for file: \(fileName)")
                SupabaseLog.line("   URL: \(url)")
                SupabaseLog.line("   Total upload time: \(String(format: "%.2f", duration)) seconds")
                DispatchQueue.main.async {
                    completion(.success(url))
                }
            } catch {
                let endTime = Date()
                let duration = endTime.timeIntervalSince(startTime)
                
                SupabaseLog.line("❌ [SupabaseService] Upload failed for file: \(fileName)")
                SupabaseLog.line("   Error: \(error.localizedDescription)")
                SupabaseLog.line("   Error type: \(type(of: error))")
                SupabaseLog.line("   Failed after: \(String(format: "%.2f", duration)) seconds")
                DispatchQueue.main.async {
                    if let networkError = error as? NetworkError {
                        completion(.failure(networkError))
                    } else {
                        completion(.failure(.uploadFailed))
                    }
                }
            }
        }
    }
    
    // MARK: - Supabase effect categories (PostgREST)
    
    /// Загружает категории стилей из Supabase с кэшированием
    public func fetchSupabaseEffectCategories(completion: @escaping (Result<[SupabaseEffectCategoryRow], NetworkError>) -> Void) {
        let startTime = Date()
        SupabaseLog.line("🔄 [SupabaseService] fetchSupabaseEffectCategories started")
        
        // Сначала проверяем кэш
        if let cachedCategories = loadCategoriesFromCache() {
            let duration = Date().timeIntervalSince(startTime)
            SupabaseLog.line("⏱️ [SupabaseService] Categories loaded from CACHE in \(String(format: "%.3f", duration))s")
            SupabaseLog.line("[SupabaseService] Используем кэшированные категории: \(cachedCategories.count) шт.")
            completion(.success(cachedCategories))
            return
        }
        
        let urlString = "\(supabaseUrl)/rest/v1/style_categories?is_active=eq.true&order=sort_order.asc"
        SupabaseLog.line("[SupabaseService] fetchSupabaseEffectCategories URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            SupabaseLog.line("[SupabaseService] Неверный URL для style_categories")
            completion(.failure(.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue(supabaseApiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                SupabaseLog.line("[SupabaseService] Ошибка запроса style_categories: \(error)")
                // Fallback: используем кэш если есть
                if let cached = self?.loadCategoriesFromCache() {
                    completion(.success(cached))
                } else {
                    completion(.failure(.requestFailed(error)))
                }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                SupabaseLog.line("[SupabaseService] HTTP статус style_categories: \(httpResponse.statusCode)")
            }
            
            guard let data = data else {
                SupabaseLog.line("[SupabaseService] Нет данных в ответе style_categories")
                // Fallback: используем кэш если есть
                if let cached = self?.loadCategoriesFromCache() {
                    completion(.success(cached))
                } else {
                    completion(.failure(.invalidResponse))
                }
                return
            }
            
            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                
                let categories = try decoder.decode([SupabaseEffectCategoryRow].self, from: data)
                SupabaseLog.line("[SupabaseService] Загружено категорий: \(categories.count)")
                
                let duration = Date().timeIntervalSince(startTime)
                SupabaseLog.line("⏱️ [SupabaseService] Categories loaded from SERVER in \(String(format: "%.3f", duration))s")
                
                // Сохраняем категории в кэш
                self?.saveCategoriesToCache(categories)
                
                completion(.success(categories))
            } catch {
                SupabaseLog.line("[SupabaseService] Ошибка парсинга JSON style_categories: \(error)")
                // Fallback: используем кэш если есть
                if let cached = self?.loadCategoriesFromCache() {
                    completion(.success(cached))
                } else {
                    completion(.failure(.decodingFailed))
                }
            }
        }
        task.resume()
    }
    
    // MARK: - Effects archive URL (config)
    
    /// Получает URL архива стилей из Supabase
    public func fetchEffectsArchiveURL(completion: @escaping (Result<String, NetworkError>) -> Void) {
        fetchConfig(key: "styles_archive_url") { result in
            switch result {
            case .success(let url):
                completion(.success(url))
            case .failure(let error):
                // Fallback: используем URL из APIKeys.plist
                if let fallbackURL = ConfigurationManager.shared.getValue(for: .stylesArchiveURL) {
                    completion(.success(fallbackURL))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }
} 

// MARK: - New Logo Supabase Models

struct SupabaseGenerationCreatePayload: Encodable {
    /// PK в `logo_generations`: тот же UUID, что и `client_generation_id` и локальный `GeneratedMedia.id`, иначе PostgREST генерирует другой `id` и Edge по `generation_id` из приложения не находит строку.
    let id: String
    let clientGenerationId: String
    let userInstallId: String
    let status: String
    let prompt: String
    let brandName: String?
    let description: String?
    let styleId: String
    let fontId: String
    let paletteId: String?
    let logoColorIds: [String]?
    let backgroundColorId: String?
    let aiModelId: String?
    let isProUser: Bool
    let userRequestedShowcase: Bool

    /// Один UUID на PK, колонку `client_generation_id` и `media.id` — без расхождения с серверным `gen_random_uuid()`.
    init(
        unifiedGenerationId: String,
        userInstallId: String,
        status: String,
        prompt: String,
        brandName: String?,
        description: String?,
        styleId: String,
        fontId: String,
        paletteId: String?,
        logoColorIds: [String]?,
        backgroundColorId: String?,
        aiModelId: String?,
        isProUser: Bool,
        userRequestedShowcase: Bool
    ) {
        self.id = unifiedGenerationId
        self.clientGenerationId = unifiedGenerationId
        self.userInstallId = userInstallId
        self.status = status
        self.prompt = prompt
        self.brandName = brandName
        self.description = description
        self.styleId = styleId
        self.fontId = fontId
        self.paletteId = paletteId
        self.logoColorIds = logoColorIds
        self.backgroundColorId = backgroundColorId
        self.aiModelId = aiModelId
        self.isProUser = isProUser
        self.userRequestedShowcase = userRequestedShowcase
    }

    enum CodingKeys: String, CodingKey {
        case id
        case clientGenerationId = "client_generation_id"
        case userInstallId = "user_install_id"
        case status
        case prompt
        case brandName = "brand_name"
        case description
        case styleId = "style_id"
        case fontId = "font_id"
        case paletteId = "palette_id"
        case logoColorIds = "logo_color_ids"
        case backgroundColorId = "background_color_id"
        case aiModelId = "ai_model_id"
        case isProUser = "is_pro_user"
        case userRequestedShowcase = "user_requested_showcase"
    }
}

struct SupabaseGenerationRow: Identifiable, Decodable {
    let id: String
    let completedAt: Date?
    let resultUrl: String?
    let userRequestedShowcase: Bool
    let prompt: String
    let brandName: String?
    let description: String?
    let styleId: String
    let fontId: String
    let paletteId: String?
    let logoColorIds: [String]?
    let backgroundColorId: String?
    let aiModelId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case completedAt = "completed_at"
        case resultUrl = "result_url"
        case userRequestedShowcase = "user_requested_showcase"
        case prompt
        case brandName = "brand_name"
        case description
        case styleId = "style_id"
        case fontId = "font_id"
        case paletteId = "palette_id"
        case logoColorIds = "logo_color_ids"
        case backgroundColorId = "background_color_id"
        case aiModelId = "ai_model_id"
    }

}

struct SupabaseShowcaseRow: Identifiable, Decodable {
    let id: String
    let generationId: String?
    let storageUrl: String
    let isActive: Bool
    let likesCount: Int
    let prompt: String
    let brandName: String?
    let description: String?
    let styleId: String
    let fontId: String
    let paletteId: String?
    let logoColorIds: [String]?
    let backgroundColorId: String?
    let aiModelId: String?
    let isModerated: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case generationId = "generation_id"
        case storageUrl = "storage_url"
        case isActive = "is_active"
        case likesCount = "likes_count"
        case prompt
        case brandName = "brand_name"
        case description
        case styleId = "style_id"
        case fontId = "font_id"
        case paletteId = "palette_id"
        case logoColorIds = "logo_color_ids"
        case backgroundColorId = "background_color_id"
        case aiModelId = "ai_model_id"
        case isModerated = "is_moderated"
    }

    init(
        id: String,
        generationId: String?,
        storageUrl: String,
        isActive: Bool,
        likesCount: Int,
        prompt: String,
        brandName: String?,
        description: String?,
        styleId: String,
        fontId: String,
        paletteId: String?,
        logoColorIds: [String]?,
        backgroundColorId: String?,
        aiModelId: String?,
        isModerated: Bool
    ) {
        self.id = id
        self.generationId = generationId
        self.storageUrl = storageUrl
        self.isActive = isActive
        self.likesCount = likesCount
        self.prompt = prompt
        self.brandName = brandName
        self.description = description
        self.styleId = styleId
        self.fontId = fontId
        self.paletteId = paletteId
        self.logoColorIds = logoColorIds
        self.backgroundColorId = backgroundColorId
        self.aiModelId = aiModelId
        self.isModerated = isModerated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        generationId = try container.decodeIfPresent(String.self, forKey: .generationId)
        storageUrl = try container.decode(String.self, forKey: .storageUrl)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        likesCount = try container.decode(Int.self, forKey: .likesCount)
        prompt = try container.decode(String.self, forKey: .prompt)
        brandName = try container.decodeIfPresent(String.self, forKey: .brandName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        styleId = try container.decode(String.self, forKey: .styleId)
        fontId = try container.decode(String.self, forKey: .fontId)
        paletteId = try container.decodeIfPresent(String.self, forKey: .paletteId)
        logoColorIds = try container.decodeIfPresent([String].self, forKey: .logoColorIds)
        backgroundColorId = try container.decodeIfPresent(String.self, forKey: .backgroundColorId)
        aiModelId = try container.decodeIfPresent(String.self, forKey: .aiModelId)
        isModerated = try container.decodeIfPresent(Bool.self, forKey: .isModerated) ?? false
    }

}

struct SupabaseFeedbackPayload: Encodable {
    let type: String
    let message: String
    let userInstallId: String
    let appVersion: String
    let buildNumber: String
    let iosVersion: String
    let deviceModel: String
    let locale: String
    let timezone: String

    enum CodingKeys: String, CodingKey {
        case type
        case message
        case userInstallId = "user_install_id"
        case appVersion = "app_version"
        case buildNumber = "build_number"
        case iosVersion = "ios_version"
        case deviceModel = "device_model"
        case locale
        case timezone
    }
}

// MARK: - New Logo Supabase API

extension SupabaseService {
    // MARK: - Logo Generations

    /// Пишем лог генерации в новую таблицу logo_generations.
    /// Нужен для debug Last Results и дальнейшего отбора контента в витрину.
    func createLogoGenerationLog(
        payload: SupabaseGenerationCreatePayload,
        completion: @escaping (Result<Void, NetworkError>) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/rest/v1/logo_generations") else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        // Совпадает с колонкой user_install_id: политики RLS могут сопоставлять anon-запрос с строкой через заголовок (PostgREST отдаёт его в request.headers).
        request.setValue(UserInstallIDService.shared.installId, forHTTPHeaderField: "X-User-Install-Id")

        do {
            request.httpBody = try JSONEncoder().encode([payload])
        } catch {
            completion(.failure(.invalidData))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.requestFailed(error)))
                return
            }
            guard let data else {
                completion(.failure(.invalidResponse))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8)
                completion(.failure(.serverError(message)))
                return
            }
            // Успех = строка реально вставлена; не завязываемся на декодирование id (тип/формат с сервера могут меняться).
            completion(.success(()))
        }.resume()
    }

    /// Обновление статуса генерации по `client_generation_id`: стабильный ключ известен до ответа POST, не зависит от декода id.
    /// Prefer return=representation: при RLS без UPDATE PostgREST вернёт [] — отличим от реального успеха.
    /// Если в дашборде строка есть, а PATCH не меняет поля: в SQL для `logo_generations` нужна политика `FOR UPDATE TO anon`
    /// (часто по `user_install_id`, совпадающему с телом INSERT и с заголовком `X-User-Install-Id`).
    func updateLogoGenerationLog(
        clientGenerationId: String,
        status: String,
        resultURL: String? = nil,
        errorMessage: String? = nil,
        replicatePredictionId: String? = nil,
        completion: ((Result<Void, NetworkError>) -> Void)? = nil
    ) {
        updateLogoGenerationLogAttempt(
            clientGenerationId: clientGenerationId,
            status: status,
            resultURL: resultURL,
            errorMessage: errorMessage,
            replicatePredictionId: replicatePredictionId,
            attemptIndex: 0,
            completion: completion
        )
    }

    private func updateLogoGenerationLogAttempt(
        clientGenerationId: String,
        status: String,
        resultURL: String?,
        errorMessage: String?,
        replicatePredictionId: String?,
        attemptIndex: Int,
        completion: ((Result<Void, NetworkError>) -> Void)?
    ) {
        let maxAttempts = 3
        guard var components = URLComponents(string: "\(baseURL)/rest/v1/logo_generations") else {
            completion?(.failure(.invalidURL))
            return
        }
        components.queryItems = [
            URLQueryItem(name: "client_generation_id", value: "eq.\(clientGenerationId)")
        ]
        guard let url = components.url else {
            completion?(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.setValue(UserInstallIDService.shared.installId, forHTTPHeaderField: "X-User-Install-Id")

        var body: [String: Any] = ["status": status]
        if let resultURL {
            body["result_url"] = resultURL
            body["completed_at"] = ISO8601DateFormatter().string(from: Date())
        }
        if let errorMessage {
            body["error_message"] = errorMessage
        }
        if let replicatePredictionId {
            body["replicate_prediction_id"] = replicatePredictionId
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion?(.failure(.invalidData))
            return
        }

        let scheduleRetry: () -> Void = {
            guard attemptIndex + 1 < maxAttempts else { return }
            let delays: [TimeInterval] = [0.45, 1.2]
            let delay = delays[min(attemptIndex, delays.count - 1)]
            SupabaseLog.line("⚠️ [SupabaseService] updateLogoGenerationLog retry \(attemptIndex + 2)/\(maxAttempts) after \(delay)s clientId=\(clientGenerationId)")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                self.updateLogoGenerationLogAttempt(
                    clientGenerationId: clientGenerationId,
                    status: status,
                    resultURL: resultURL,
                    errorMessage: errorMessage,
                    replicatePredictionId: replicatePredictionId,
                    attemptIndex: attemptIndex + 1,
                    completion: completion
                )
            }
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                if attemptIndex + 1 < maxAttempts {
                    SupabaseLog.line("⚠️ [SupabaseService] updateLogoGenerationLog network error (will retry): \(error.localizedDescription)")
                    scheduleRetry()
                } else {
                    completion?(.failure(.requestFailed(error)))
                }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                if attemptIndex + 1 < maxAttempts { scheduleRetry() } else { completion?(.failure(.invalidResponse)) }
                return
            }
            guard let data else {
                if attemptIndex + 1 < maxAttempts, Self.shouldRetryTransientHTTPStatus(http.statusCode) {
                    scheduleRetry()
                } else {
                    completion?(.failure(.invalidResponse))
                }
                return
            }
            let bodyText = String(data: data, encoding: .utf8)
            guard (200...299).contains(http.statusCode) else {
                let err = NetworkError.serverError(bodyText)
                SupabaseLog.line("❌ [SupabaseService] updateLogoGenerationLog HTTP \(http.statusCode) clientId=\(clientGenerationId): \(bodyText ?? "")")
                if attemptIndex + 1 < maxAttempts, Self.shouldRetryTransientHTTPStatus(http.statusCode) {
                    scheduleRetry()
                } else {
                    completion?(.failure(err))
                }
                return
            }
            // PostgREST возвращает массив обновлённых строк; [] значит 0 строк (часто RLS на UPDATE).
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                SupabaseLog.line("❌ [SupabaseService] updateLogoGenerationLog: не JSON-массив, clientId=\(clientGenerationId): \(bodyText ?? "")")
                if attemptIndex + 1 < maxAttempts { scheduleRetry() } else { completion?(.failure(.serverError(bodyText))) }
                return
            }
            if json.isEmpty {
                let msg = bodyText ?? "logo_generations: PATCH updated 0 rows (check RLS UPDATE for anon / X-User-Install-Id)"
                SupabaseLog.line("❌ [SupabaseService] updateLogoGenerationLog: 0 строк, clientId=\(clientGenerationId). Добавьте политику UPDATE для role anon.")
                if attemptIndex + 1 < maxAttempts {
                    scheduleRetry()
                } else {
                    completion?(.failure(.serverError(msg)))
                }
                return
            }
            completion?(.success(()))
        }.resume()
    }

    private static func shouldRetryTransientHTTPStatus(_ status: Int) -> Bool {
        [408, 425, 429].contains(status) || (500...599).contains(status)
    }

    /// После локального сохранения полного файла: Edge тянет Replicate, кладёт JPEG ~80% в `generation-previews/` и обновляет `result_url` на постоянный URL Supabase.
    /// Ретраи: Edge иногда отвечает 400 «generation not ready» сразу после PATCH или 502 при fetch с Replicate — без повтора в БД остаётся URL Replicate, файл в бакете не появляется.
    func persistGenerationPreview(
        clientGenerationId: String,
        replicateImageURL: String,
        completion: ((Result<Void, NetworkError>) -> Void)? = nil
    ) {
        persistGenerationPreviewAttempt(
            clientGenerationId: clientGenerationId,
            replicateImageURL: replicateImageURL,
            attemptIndex: 0,
            completion: completion
        )
    }

    private func persistGenerationPreviewAttempt(
        clientGenerationId: String,
        replicateImageURL: String,
        attemptIndex: Int,
        completion: ((Result<Void, NetworkError>) -> Void)?
    ) {
        let maxAttempts = 4
        guard let url = URL(string: "\(baseURL)/functions/v1/persist-generation-preview") else {
            completion?(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UserInstallIDService.shared.installId, forHTTPHeaderField: "X-User-Install-Id")

        let payload: [String: Any] = [
            "client_generation_id": clientGenerationId,
            "replicate_image_url": replicateImageURL
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let scheduleRetry: () -> Void = {
            guard attemptIndex + 1 < maxAttempts else { return }
            let delays: [TimeInterval] = [0.6, 1.5, 3.0]
            let delay = delays[min(attemptIndex, delays.count - 1)]
            SupabaseLog.line("⚠️ [SupabaseService] persistGenerationPreview retry \(attemptIndex + 2)/\(maxAttempts) after \(delay)s clientId=\(clientGenerationId)")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                self.persistGenerationPreviewAttempt(
                    clientGenerationId: clientGenerationId,
                    replicateImageURL: replicateImageURL,
                    attemptIndex: attemptIndex + 1,
                    completion: completion
                )
            }
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                if attemptIndex + 1 < maxAttempts {
                    SupabaseLog.line("⚠️ [SupabaseService] persistGenerationPreview network error (will retry): \(error.localizedDescription)")
                    scheduleRetry()
                } else {
                    completion?(.failure(.requestFailed(error)))
                }
                return
            }
            let message = data.flatMap { String(data: $0, encoding: .utf8) }
            guard let http = response as? HTTPURLResponse else {
                if attemptIndex + 1 < maxAttempts { scheduleRetry() } else { completion?(.failure(.invalidResponse)) }
                return
            }
            if (200...299).contains(http.statusCode) {
                completion?(.success(()))
                return
            }
            SupabaseLog.line("❌ [SupabaseService] persistGenerationPreview HTTP \(http.statusCode): \(message ?? "")")
            if attemptIndex + 1 < maxAttempts, Self.shouldRetryPersistPreviewStatus(http.statusCode) {
                scheduleRetry()
            } else {
                completion?(.failure(.serverError(message)))
            }
        }.resume()
    }

    private static func shouldRetryPersistPreviewStatus(_ status: Int) -> Bool {
        if [408, 425, 429].contains(status) || (500...599).contains(status) { return true }
        // 400: generation not ready / mismatch; 404: строка не найдена — часто гонка сразу после PATCH.
        if [400, 404, 502, 503].contains(status) { return true }
        return false
    }

    func fetchRecentSuccessfulLogoGenerations(
        hours: Int = 24,
        completion: @escaping (Result<[SupabaseGenerationRow], NetworkError>) -> Void
    ) {
        let since = Date().addingTimeInterval(-Double(hours) * 3600)
        let sinceISO = ISO8601DateFormatter().string(from: since)
        guard let encodedSince = sinceISO.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/rest/v1/logo_generations?select=id,completed_at,result_url,user_requested_showcase,prompt,brand_name,description,style_id,font_id,palette_id,logo_color_ids,background_color_id,ai_model_id&status=eq.succeeded&completed_at=gte.\(encodedSince)&order=completed_at.desc&limit=200")
        else {
            completion(.failure(.invalidURL))
            return
        }

        makeGET(url: url, completion: completion)
    }

    // MARK: - Showcase

    func fetchShowcaseItems(
        includeInactive: Bool = false,
        completion: @escaping (Result<[SupabaseShowcaseRow], NetworkError>) -> Void
    ) {
        let filter = includeInactive ? "" : "&is_active=eq.true"
        guard let url = URL(string: "\(baseURL)/rest/v1/showcase_items?select=id,generation_id,storage_url,is_active,is_moderated,likes_count,prompt,brand_name,description,style_id,font_id,palette_id,logo_color_ids,background_color_id,ai_model_id\(filter)&order=is_moderated.asc,is_active.desc,likes_count.desc,selected_at.desc&limit=500")
        else {
            completion(.failure(.invalidURL))
            return
        }

        makeGET(url: url, completion: completion)
    }

    func fetchActiveShowcaseGenerationIds(completion: @escaping (Result<Set<String>, NetworkError>) -> Void) {
        guard let url = URL(string: "\(baseURL)/rest/v1/showcase_items?select=generation_id&is_active=eq.true") else {
            completion(.failure(.invalidURL))
            return
        }

        makeGET(url: url) { (result: Result<[SupabaseShowcaseGenerationRefRow], NetworkError>) in
            switch result {
            case .success(let rows):
                let ids = Set(rows.compactMap { $0.generationId })
                completion(.success(ids))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Обновляем likes_count в showcase. На первом этапе лайк хранится локально, а сервер хранит агрегат.
    func setShowcaseLikesCount(
        showcaseId: String,
        likesCount: Int,
        completion: ((Result<Void, NetworkError>) -> Void)? = nil
    ) {
        guard let url = URL(string: "\(baseURL)/rest/v1/showcase_items?id=eq.\(showcaseId)") else {
            completion?(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        let body: [String: Any] = ["likes_count": max(0, likesCount)]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                completion?(.failure(.requestFailed(error)))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                completion?(.failure(.invalidResponse))
                return
            }
            completion?(.success(()))
        }.resume()
    }

    /// Админский publish из Last Results: используем единый endpoint submit-showcase-candidate с publish_now=true.
    func addGenerationToShowcase(
        generationId: String,
        completion: @escaping (Result<Void, NetworkError>) -> Void
    ) {
        submitShowcaseCandidate(generationId: generationId, publishNow: true, completion: completion)
    }

    /// Единый endpoint: ⭐ — `publish_now: false` (на Edge: кандидат, `is_active=false` до апрува); Last Results — `publish_now: true` (сразу в ленте).
    func submitShowcaseCandidate(
        generationId: String,
        publishNow: Bool = false,
        completion: @escaping (Result<Void, NetworkError>) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/functions/v1/submit-showcase-candidate") else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "generation_id": generationId,
            "publish_now": publishNow
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.requestFailed(error)))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) }
                completion(.failure(.serverError(message)))
                return
            }
            completion(.success(()))
        }.resume()
    }

    /// Модерация: подтверждаем pending-кандидата и публикуем его в витрине.
    func approveShowcaseCandidate(
        showcaseId: String,
        completion: @escaping (Result<Void, NetworkError>) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/functions/v1/approve-showcase-candidate") else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["showcase_id": showcaseId])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.requestFailed(error)))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) }
                completion(.failure(.serverError(message)))
                return
            }
            completion(.success(()))
        }.resume()
    }

    /// Удаляет элемент витрины (и файл в storage) по showcase_id.
    /// Используется и для pending (бывший reject), и для админского "выбытия" скрытых карточек.
    func deleteShowcaseItem(
        showcaseId: String,
        completion: @escaping (Result<Void, NetworkError>) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/functions/v1/delete-showcase-item") else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["showcase_id": showcaseId])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.requestFailed(error)))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) }
                completion(.failure(.serverError(message)))
                return
            }
            completion(.success(()))
        }.resume()
    }

    func removeGenerationFromShowcase(
        generationId: String,
        completion: @escaping (Result<Void, NetworkError>) -> Void
    ) {
        setShowcaseActive(generationId: generationId, isActive: false, completion: completion)
    }

    /// Переключаем публикацию в витрине мягко (soft-hide), без удаления записи.
    func setShowcaseActive(
        showcaseId: String,
        isActive: Bool,
        completion: @escaping (Result<Void, NetworkError>) -> Void
    ) {
        guard var components = URLComponents(string: "\(baseURL)/rest/v1/showcase_items") else {
            completion(.failure(.invalidURL))
            return
        }
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(showcaseId)")]
        guard let url = components.url else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["is_active": isActive])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.requestFailed(error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.invalidResponse))
                return
            }

            guard (200...299).contains(http.statusCode) else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) }
                completion(.failure(.serverError(message)))
                return
            }
            completion(.success(()))
        }.resume()
    }

    func setShowcaseActive(
        generationId: String,
        isActive: Bool,
        completion: @escaping (Result<Void, NetworkError>) -> Void
    ) {
        guard var components = URLComponents(string: "\(baseURL)/rest/v1/showcase_items") else {
            completion(.failure(.invalidURL))
            return
        }
        components.queryItems = [URLQueryItem(name: "generation_id", value: "eq.\(generationId)")]
        guard let url = components.url else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["is_active": isActive])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.requestFailed(error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.invalidResponse))
                return
            }
            guard (200...299).contains(http.statusCode) else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) }
                completion(.failure(.serverError(message)))
                return
            }
            completion(.success(()))
        }.resume()
    }

    // MARK: - Feedback

    func submitAppFeedback(
        payload: SupabaseFeedbackPayload,
        completion: @escaping (Result<Void, NetworkError>) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/rest/v1/app_feedback") else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONEncoder().encode([payload])

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                completion(.failure(.requestFailed(error)))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                completion(.failure(.invalidResponse))
                return
            }
            completion(.success(()))
        }.resume()
    }

    // MARK: - Helpers

    private var baseURL: String {
        ConfigurationManager.shared.getValue(for: .supabaseURL) ?? ""
    }

    private var anonKey: String {
        ConfigurationManager.shared.getValue(for: .supabaseAnonKey) ?? ""
    }

    private func makeGET<T: Decodable>(
        url: URL,
        completion: @escaping (Result<T, NetworkError>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.requestFailed(error)))
                return
            }
            guard let data else {
                completion(.failure(.invalidResponse))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                completion(.failure(.invalidResponse))
                return
            }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(T.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(.decodingFailed))
            }
        }.resume()
    }
}

private struct SupabaseShowcaseGenerationRefRow: Decodable {
    let generationId: String?

    enum CodingKeys: String, CodingKey {
        case generationId = "generation_id"
    }
}

// MARK: - User Install ID

final class UserInstallIDService {
    static let shared = UserInstallIDService()
    private init() {}

    private let key = "user_install_id"

    /// Стабильный анонимный идентификатор установки приложения.
    /// Нужен для глобальных логов/фидбека без внедрения полноценного аккаунта.
    var installId: String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let newValue = UUID().uuidString
        UserDefaults.standard.set(newValue, forKey: key)
        return newValue
    }
}