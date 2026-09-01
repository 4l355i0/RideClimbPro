import Foundation

@MainActor
final class RideClimbPRO3DModel: ObservableObject {
    @Published private(set) var hasMesh = false
    @Published private(set) var status = "Import a GPX in Ride"

    let sceneController = Climb3DSceneController()

    private(set) var mesh: Climb3DMesh?

    func load(route: GPXRoute?) throws {
        guard let route else {
            hasMesh = false
            status = "Import a GPX in Ride"
            return
        }

        let generated = try Climb3DMeshBuilder().build(from: route)
        mesh = generated
        sceneController.setMesh(generated, route: route)
        hasMesh = true

        status = String(
            format: "3D ready • %.1f km",
            route.totalDistanceM / 1000
        )
    }

    func showOverview() {
        sceneController.showOverview()
    }

    func resetCamera() {
        sceneController.resetCamera()
    }
}
