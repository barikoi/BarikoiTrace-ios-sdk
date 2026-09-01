import Foundation

/// Mirrors `TraceApiClient.kt` — same two endpoints, same request/response
/// shapes, async/await instead of Kotlin coroutines.
public final class TraceApiClient {
    private let dataStore: TraceDataStore
    private var baseURL: URL
    private var apiKey: String?
    private var userId: String?
    private let session: URLSession

    public init(dataStore: TraceDataStore, session: URLSession = .shared) {
        self.dataStore = dataStore
        self.session = session
        let stored = dataStore.getBaseURL() ?? TraceApiRoutes.baseURL
        self.baseURL = TraceApiClient.normalized(stored)
        self.apiKey = dataStore.getApiKey()
        self.userId = dataStore.getUserId()
    }

    private static func normalized(_ raw: String) -> URL {
        let withSlash = raw.hasSuffix("/") ? raw : raw + "/"
        return URL(string: withSlash) ?? URL(string: TraceApiRoutes.baseURL)!
    }

    public func setBaseURL(_ url: String) {
        baseURL = TraceApiClient.normalized(url)
    }

    public func setApiKey(_ key: String) { apiKey = key }
    public func setUserId(_ id: String) { userId = id }

    /// POST /sdk/authenticate — logs in or creates a trace user. Throws
    /// `.noCompanyError()` if the account has zero company associations,
    /// mirroring `TraceApiClient.kt`'s `companies[0]` requirement.
    public func authenticate(name: String?, email: String?, phone: String) async throws -> TraceUser {
        var body: [String: Any] = ["api_key": apiKey ?? ""]
        if let name, !name.isEmpty { body["name"] = name }
        if let email, !email.isEmpty { body["email"] = email }
        body["phone"] = phone

        let json = try await post(path: TraceApiRoutes.authenticate, body: body)

        guard let userJson = json["user"] as? [String: Any],
              let id = userJson["_id"] as? String,
              let userName = userJson["name"] as? String,
              let userEmail = userJson["email"] as? String,
              let companies = userJson["companies"] as? [[String: Any]] else {
            throw TraceError.jsonError("Malformed authenticate() response")
        }
        guard let firstCompany = companies.first,
              let companyId = firstCompany["company_id"] as? String,
              let groupId = firstCompany["group_id"] as? String else {
            throw TraceError.noCompanyError()
        }

        let user = TraceUser(
            userId: id, name: userName, email: userEmail, phone: phone,
            companyId: companyId, group: groupId
        )
        userId = user.userId
        dataStore.setUser(user)
        return user
    }

    /// POST /sdk/company/settings — pulls the company-level `TraceMode` override.
    public func getCompanySettings(phone: String) async throws -> TraceMode {
        let body: [String: Any] = ["api_key": apiKey ?? "", "phone": phone]
        let json = try await post(path: TraceApiRoutes.companySettings, body: body)

        guard let settings = json["settings"] as? [String: Any],
              let updateInterval = settings["update_time_interval"] as? Int,
              let distanceInterval = settings["distance_interval"] as? Int,
              let accuracyFilter = settings["accuracy_filter"] as? Int,
              let offlineSync = settings["offline_sync"] as? Bool else {
            throw TraceError.jsonError("Malformed company settings response")
        }

        let builder = TraceMode.Builder()
            .setUpdateInterval(updateInterval)
            .setDistanceFilter(distanceInterval)
            .setAccuracyFilter(accuracyFilter)
            .setOfflineSync(offlineSync)

        if let startStr = settings["tracking_start_time"] as? String,
           let start = TraceApiClient.parseTime(startStr) {
            builder.setStartTime(start)
        }
        if let endStr = settings["tracking_end_time"] as? String,
           let end = TraceApiClient.parseTime(endStr) {
            builder.setEndTime(end)
        }

        return builder.build()
    }

    // MARK: - Helpers

    private static func parseTime(_ value: String) -> DateComponents? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var comps = DateComponents()
        comps.hour = parts[0]
        comps.minute = parts[1]
        comps.second = parts.count > 2 ? parts[2] : 0
        return comps
    }

    private func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TraceError.networkError()
        }

        // Request/response tracing, the counterpart to Kotlin's
        // `HttpLoggingInterceptor`. That one runs at `Level.BODY`, which puts
        // the raw `api_key` into logcat on every call — deliberately not
        // reproduced. Method, path and status carry the diagnostic value; the
        // bodies do not.
        TraceManager.shared.log(
            level: "DEBUG", tag: "TraceApi",
            message: "POST \(path) → \((response as? HTTPURLResponse)?.statusCode ?? -1) (\(data.count) bytes)"
        )

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TraceError(code: "SERVER", message: "Server error: \(code)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TraceError.jsonError("Response was not a JSON object")
        }
        return json
    }
}
