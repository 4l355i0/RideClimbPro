import SwiftUI
import SceneKit

struct RideClimbPRO3DView: UIViewRepresentable {
    let sceneController: Climb3DSceneController
    let distanceM: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(sceneController: sceneController)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = sceneController.scene
        view.backgroundColor = .systemBackground
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        sceneController.attach(to: view)
        sceneController.updateDistance(distanceM)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        if uiView.scene !== sceneController.scene {
            uiView.scene = sceneController.scene
        }

        // This value comes directly from RideModel.distanceM.
        sceneController.updateDistance(distanceM)
    }

    final class Coordinator: NSObject {
        let sceneController: Climb3DSceneController

        init(sceneController: Climb3DSceneController) {
            self.sceneController = sceneController
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            Task { @MainActor in
                sceneController.enableFollowMode()
            }
        }
    }
}
