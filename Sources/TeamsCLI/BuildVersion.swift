// Release builds supply this type in BuildVersion.generated.swift.
#if !TEAMS_RELEASE_BUILD
enum BuildVersion {
    static let value = "dev"
}
#endif
