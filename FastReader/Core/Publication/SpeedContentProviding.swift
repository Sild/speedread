@MainActor
protocol SpeedContentProviding: AnyObject {
    func start(at locatorJSON: String?) async throws -> SpeedContentElement?
    func next() async throws -> SpeedContentElement?
    func previous() async throws -> SpeedContentElement?
    func seek(toTotalProgression progression: Double) async throws -> SpeedContentElement?
}
