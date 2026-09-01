import BarikoiTrace
import CoreLocation
import SwiftUI

/// Requests location authorization. `BarikoiTrace` doesn't do this itself —
/// asking for permission is a host-app UI decision (when, with what framing),
/// not something a background SDK should do implicitly. The two-step order
/// matters: request `WhenInUse` first, and only request `Always` once the
/// user has engaged with the feature that needs it (tapping "Start
/// Tracking" below) — see docs/APP_STORE_READINESS.md's "just in time"
/// guidance and docs/WORK_PLAN.md §Phase 1.
@MainActor
final class LocationPermissionRequester: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }
    func requestAlways() { manager.requestAlwaysAuthorization() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorizationStatus = status }
    }
}

struct ContentView: View {
    @StateObject private var permissions = LocationPermissionRequester()

    @State private var phone = "+8801700000000"
    @State private var user: TraceUser?
    @State private var isTracking = false
    @State private var lastLocation: CLLocation?
    @State private var statusMessage = ""

    var body: some View {
        NavigationView {
            Form {
                Section("1. Authenticate") {
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                    Button("Sign in / create user") { Task { await signIn() } }
                    if let user {
                        Text("Signed in as \(user.userId)").foregroundStyle(.secondary)
                    }
                }

                Section("2. Permissions") {
                    HStack {
                        Text("When In Use")
                        Spacer()
                        Text(statusText).foregroundStyle(.secondary)
                    }
                    Button("Request When In Use") { permissions.requestWhenInUse() }
                        .disabled(permissions.authorizationStatus != .notDetermined)
                    Button("Request Always") { permissions.requestAlways() }
                        .disabled(permissions.authorizationStatus == .authorizedAlways)
                }

                Section("3. Tracking") {
                    Toggle("Tracking active", isOn: Binding(
                        get: { isTracking },
                        set: { toggleTracking($0) }
                    ))
                    .disabled(user == nil || permissions.authorizationStatus == .notDetermined)

                    if let lastLocation {
                        Text("Last update: \(lastLocation.coordinate.latitude), \(lastLocation.coordinate.longitude)")
                            .font(.caption)
                    }

                    if BarikoiTrace.isBackgroundTrackingDegraded {
                        Label(
                            "Background tracking is degraded — Low Power Mode, a downgraded permission, or disabled Background App Refresh may be limiting updates.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                if !statusMessage.isEmpty {
                    Section("Status") {
                        Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("BarikoiTrace Example")
            .task { await observeLocationUpdates() }
        }
    }

    private var statusText: String {
        switch permissions.authorizationStatus {
        case .notDetermined: return "Not requested"
        case .denied, .restricted: return "Denied"
        case .authorizedWhenInUse: return "When In Use"
        case .authorizedAlways: return "Always"
        @unknown default: return "Unknown"
        }
    }

    @MainActor
    private func signIn() async {
        print("signIn() called")
        do {
            user = try await BarikoiTrace.setOrCreateUser(name: nil, email: nil, phone: phone)
            statusMessage = "Signed in."
            print("Signed in successfully")
        } catch {
            statusMessage = "Sign-in failed: \(error)"
            print("Sign-in failed: \(error)")
        }
    }

    private func toggleTracking(_ enabled: Bool) {
        if enabled {
            BarikoiTrace.startTracking(.active, withTrip: true)
        } else {
            BarikoiTrace.stopTracking()
        }
        isTracking = enabled
    }

    private func observeLocationUpdates() async {
        BarikoiTrace.setBroadcastingEnabled(true)
        for await location in BarikoiTrace.locationUpdates {
            lastLocation = location
        }
    }
}

#Preview {
    ContentView()
}
