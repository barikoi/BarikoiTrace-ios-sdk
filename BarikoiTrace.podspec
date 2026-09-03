#
# CocoaPods spec for the BarikoiTrace iOS SDK.
#
# The SDK's primary distribution is Swift Package Manager (`Package.swift`).
# This spec exists so CocoaPods-based host apps — including Flutter apps that
# have not enabled Flutter's SwiftPM support — can consume the same sources.
# The two manifests must be kept in step: dependencies and the deployment
# target are duplicated here because a podspec inherits nothing from
# `Package.swift`.
#
# Validate with:
#   pod lib lint BarikoiTrace.podspec --allow-warnings
#
# Consume it one of three ways:
#
#   # 1. Published to the CocoaPods trunk (after `pod trunk push`):
#   pod 'BarikoiTrace', '0.4.0'
#
#   # 2. Straight from the tag, no trunk needed:
#   pod 'BarikoiTrace',
#       :podspec => 'https://raw.githubusercontent.com/barikoi/BarikoiTrace-ios-sdk/main/BarikoiTrace.podspec'
#
#   # 3. From a local checkout — the iOS counterpart of the Android composite
#   #    build. Uses your working tree, so uncommitted SDK changes are picked up:
#   pod 'BarikoiTrace', :path => '../../../BarikoiTrace-ios-sdk'
#
Pod::Spec.new do |s|
  s.name             = 'BarikoiTrace'
  s.version          = '0.4.0'
  s.summary          = 'Background location tracing for iOS — MQTT streaming with a durable offline queue.'
  s.description      = <<-DESC
Authenticates a user against the Barikoi Trace backend, streams their location
to an MQTT broker in the foreground and the background, and queues fixes to
SQLite when the network is gone — flushing them when it returns. Mirrors the
Android `barikoitrace` SDK's feature set and public API shape.
                       DESC
  s.homepage         = 'https://github.com/barikoi/BarikoiTrace-ios-sdk'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Barikoi' => 'dev@barikoi.com' }

  s.source           = {
    :git => 'https://github.com/barikoi/BarikoiTrace-ios-sdk.git',
    :tag => s.version.to_s
  }

  s.source_files     = 'Sources/BarikoiTrace/**/*.swift'

  # Matches `Package.swift`'s platform floor. `CLLocation.sourceInformation`
  # (mock detection) and the background coordinator both need iOS 15.
  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.9'

  # Both are declared by `Package.swift` and are NOT inherited by a podspec —
  # `linkerSettings: [.linkedLibrary("sqlite3")]` for the offline queue, and
  # the MQTT client itself.
  s.dependency 'CocoaMQTT', '~> 2.1'
  s.libraries        = 'sqlite3'

  s.frameworks       = 'CoreLocation', 'BackgroundTasks', 'UserNotifications', 'Network'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
