/// Build-time settings (the CI passes them with --dart-define).

/// Build number of this build (0 = local build).
const int kBuildNumber = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);

/// GitHub repository that publishes the releases, the store and the notices (public).
const String kRepo =
    String.fromEnvironment('REPO', defaultValue: '20091211mn/Direct-for-Sony-');

/// SideStore / AltStore source published by the iOS workflow.
const String kSourceUrl =
    'https://github.com/$kRepo/releases/download/ios-latest/altstore.json';

/// Name of the Android APK attached to every release.
const String kApkName = 'pkg-sender.apk';

/// Address of the support relay (Cloudflare Worker). Empty = support is off.
const String kSupportUrl = String.fromEnvironment('SUPPORT_URL');
