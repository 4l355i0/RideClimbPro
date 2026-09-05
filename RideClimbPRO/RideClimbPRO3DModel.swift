import Foundation

@MainActor
final class RideClimbPRO3DModel: ObservableObject {
    @Published private(set) var hasMesh = false
    @Published private(set) var status = "Import a planned GPX in Ride"
    @Published private(set) var gradeWarnings: [RouteGradeWarning] = []

    let sceneController = Climb3DSceneController()
    private(set) var mesh: Climb3DMesh?

    func load(route: GPXRoute?) throws {
        guard let route else {
            hasMesh = false
            mesh = nil
            gradeWarnings = []
            status = "Import a planned GPX in Ride"
            return
        }

        let generated = try Climb3DMeshBuilder().build(from: route)
        mesh = generated
        sceneController.setMesh(generated, route: route)
        gradeWarnings = route.suspiciousGradeSegments()
        hasMesh = true

        if gradeWarnings.isEmpty {
            status = String(format: "3D ready • %.1f km • GPX check OK", route.totalDistanceM / 1000)
        } else {
            status = String(format: "3D ready • %.1f km • %d grade warning%@", route.totalDistanceM / 1000, gradeWarnings.count, gradeWarnings.count == 1 ? "" : "s")
        }
    }

    func showOverview() { sceneController.showOverview() }
    func resetCamera() { sceneController.resetCamera() }
}

