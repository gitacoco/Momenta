enum AppFeatureFlags {
    /// CloudKit requires a provisioning profile from a paid Apple Developer
    /// team. Keep the implementation compiled and tested while preventing
    /// Personal Team builds from activating it without the required
    /// entitlement.
    #if MOMENTA_ICLOUD_SYNC
    static let iCloudSync = true
    #else
    static let iCloudSync = false
    #endif
}
