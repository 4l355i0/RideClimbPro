import Foundation
import SceneKit
import UIKit

@MainActor
final class Climb3DSceneController {
    let scene = SCNScene()

    private weak var view: SCNView?
    private let meshNode = SCNNode()
    private let routeNode = SCNNode()
    private let markerNode: SCNNode
    private let cameraNode = SCNNode()

    private let keyLightNode = SCNNode()
    private let fillLightNode = SCNNode()
    private let ambientNode = SCNNode()

    private var mesh: Climb3DMesh?
    private var route: GPXRoute?

    private var currentDistanceM: Double = 0
    private var followMode = true

    private let cameraBehindM: Double = 10
    private let cameraHeightM: Float = 5.5
    private let lookAheadM: Double = 14
    private let markerScreenLiftM: Float = 0.85

    init() {
        let markerGeometry = SCNSphere(radius: 0.78)
        markerGeometry.segmentCount = 24
        markerGeometry.firstMaterial?.diffuse.contents = UIColor.systemRed
        markerGeometry.firstMaterial?.emission.contents =
            UIColor.systemRed.withAlphaComponent(0.28)
        markerGeometry.firstMaterial?.lightingModel = .physicallyBased

        markerNode = SCNNode(geometry: markerGeometry)
        markerNode.isHidden = true

        scene.rootNode.addChildNode(meshNode)
        scene.rootNode.addChildNode(routeNode)
        scene.rootNode.addChildNode(markerNode)

        let camera = SCNCamera()
        camera.fieldOfView = 66
        camera.zNear = 0.12
        camera.zFar = 50_000
        camera.automaticallyAdjustsZRange = true
        camera.wantsHDR = true
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        keyLightNode.light = SCNLight()
        keyLightNode.light?.type = .directional
        keyLightNode.light?.intensity = 1450
        keyLightNode.light?.castsShadow = true
        keyLightNode.light?.shadowRadius = 4
        keyLightNode.light?.shadowSampleCount = 12
        keyLightNode.eulerAngles =
            SCNVector3(-Float.pi/3, Float.pi/4, 0)
        scene.rootNode.addChildNode(keyLightNode)

        fillLightNode.light = SCNLight()
        fillLightNode.light?.type = .directional
        fillLightNode.light?.intensity = 390
        fillLightNode.eulerAngles =
            SCNVector3(-Float.pi/4, -Float.pi/2, 0)
        scene.rootNode.addChildNode(fillLightNode)

        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.intensity = 400
        ambientNode.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambientNode)

        scene.background.contents =
            UIColor(red: 0.55, green: 0.69, blue: 0.80, alpha: 1)
    }

    func attach(to view: SCNView) {
        self.view = view
        view.pointOfView = cameraNode

        if mesh != nil {
            updateFollowCamera(distanceM: currentDistanceM, animated: false)
        }
    }

    func setMesh(_ mesh: Climb3DMesh, route: GPXRoute) {
        self.mesh = mesh
        self.route = route

        meshNode.geometry = mesh.sceneGeometry()
        meshNode.castsShadow = false

        rebuildRoute(mesh.centerline)

        currentDistanceM = 0
        followMode = true
        updateDistance(0)
    }

    /// RideClimbPRO is the source of truth.
    /// No independent progress clock exists here.
    func updateDistance(_ distanceM: Double) {
        guard let route, route.totalDistanceM > 0 else {
            markerNode.isHidden = true
            return
        }

        let distance = min(route.totalDistanceM, max(0, distanceM))
        currentDistanceM = distance

        let position = meshPosition(atDistanceM: distance)

        let markerTarget =
            SCNVector3(
                position.x,
                position.y + 0.82,
                position.z
            )

        markerNode.isHidden = false

        // Distance is updated about every 0.2 s.
        // Slightly overlapping animations remove the visible stepping.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.24
        SCNTransaction.animationTimingFunction =
            CAMediaTimingFunction(name: .linear)

        markerNode.position = markerTarget

        SCNTransaction.commit()

        if followMode {
            updateFollowCamera(
                distanceM: distance,
                animated: true
            )
        }
    }

    private func updateFollowCamera(
        distanceM: Double,
        animated: Bool
    ) {
        guard let route,
              route.totalDistanceM > 0 else {
            return
        }

        let current =
            meshPosition(
                atDistanceM: distanceM
            )

        let behindDistance =
            max(
                0,
                distanceM - cameraBehindM
            )

        let futureDistance =
            min(
                route.totalDistanceM,
                distanceM + lookAheadM
            )

        let behind =
            meshPosition(
                atDistanceM: behindDistance
            )

        let future =
            meshPosition(
                atDistanceM: futureDistance
            )

        // The marker is the visual anchor.
        // Camera moves with the route while always looking at the rider.
        var cameraPosition =
            SCNVector3(
                behind.x,
                behind.y + cameraHeightM,
                behind.z
            )

        // At the beginning there is no route point behind the rider.
        // Extend backwards using the local path direction.
        if distanceM < cameraBehindM {

            let dx =
                Double(
                    future.x -
                    current.x
                )

            let dz =
                Double(
                    future.z -
                    current.z
                )

            let length =
                max(
                    0.001,
                    sqrt(
                        dx * dx +
                        dz * dz
                    )
                )

            cameraPosition =
                SCNVector3(
                    current.x -
                        Float(
                            dx /
                            length *
                            cameraBehindM
                        ),

                    current.y +
                        cameraHeightM,

                    current.z -
                        Float(
                            dz /
                            length *
                            cameraBehindM
                        )
                )
        }

        // Always aim directly at the current marker position.
        // Therefore the red ball cannot disappear outside the frame,
        // including through sharp hairpins.
        let target =
            SCNVector3(
                current.x,
                current.y +
                    markerScreenLiftM,
                current.z
            )

        let apply = {

            self.cameraNode.position =
                cameraPosition

            self.cameraNode.look(
                at: target,
                up:
                    SCNVector3(
                        0,
                        1,
                        0
                    ),
                localFront:
                    SCNVector3(
                        0,
                        0,
                        -1
                    )
            )

            self.view?.pointOfView =
                self.cameraNode
        }

        if animated {

            SCNTransaction.begin()

            SCNTransaction.animationDuration =
                0.24

            SCNTransaction.animationTimingFunction =
                CAMediaTimingFunction(
                    name: .linear
                )

            apply()

            SCNTransaction.commit()

        } else {

            apply()
        }
    }

    func disableFollowMode() {
        followMode = false
    }

    func enableFollowMode() {

        followMode = true

        updateFollowCamera(
            distanceM:
                currentDistanceM,
            animated: true
        )
    }

    func resetCamera() {
        enableFollowMode()
    }

    private func meshPosition(
        atDistanceM distanceM: Double
    ) -> Climb3DVertex {

        guard let mesh,
              let route,
              !mesh.centerline.isEmpty,
              !route.points.isEmpty else {

            return Climb3DVertex(
                x: 0,
                y: 0,
                z: 0
            )
        }

        let target =
            min(
                route.totalDistanceM,
                max(
                    0,
                    distanceM
                )
            )

        if target <= 0 {
            return mesh.centerline[0]
        }

        if target >=
            route.totalDistanceM {

            return mesh.centerline[
                mesh.centerline.count - 1
            ]
        }

        var low = 0

        var high =
            min(
                route.points.count,
                mesh.centerline.count
            ) - 1

        while low + 1 < high {

            let mid =
                (low + high) / 2

            if route.points[mid]
                .distanceM < target {

                low = mid

            } else {

                high = mid
            }
        }

        let ra =
            route.points[low]

        let rb =
            route.points[high]

        let a =
            mesh.centerline[low]

        let b =
            mesh.centerline[high]

        let span =
            max(
                0.001,
                rb.distanceM -
                ra.distanceM
            )

        let t =
            Float(
                (
                    target -
                    ra.distanceM
                ) /
                span
            )

        return Climb3DVertex(
            x:
                a.x +
                (b.x - a.x) *
                t,

            y:
                a.y +
                (b.y - a.y) *
                t,

            z:
                a.z +
                (b.z - a.z) *
                t
        )
    }

    private func rebuildRoute(
        _ points: [Climb3DVertex]
    ) {

        routeNode.childNodes
            .forEach {
                $0.removeFromParentNode()
            }

        guard points.count >= 2 else {
            return
        }

        for i in 1..<points.count {

            let a =
                points[i - 1]

            let b =
                points[i]

            routeNode.addChildNode(
                lineNode(
                    from:
                        SCNVector3(
                            a.x,
                            a.y + 0.08,
                            a.z
                        ),
                    to:
                        SCNVector3(
                            b.x,
                            b.y + 0.08,
                            b.z
                        )
                )
            )
        }
    }

    private func lineNode(
        from a: SCNVector3,
        to b: SCNVector3
    ) -> SCNNode {

        let dx =
            b.x - a.x

        let dy =
            b.y - a.y

        let dz =
            b.z - a.z

        let length =
            sqrt(
                dx * dx +
                dy * dy +
                dz * dz
            )

        let cylinder =
            SCNCylinder(
                radius: 0.075,
                height: CGFloat(length)
            )

        cylinder.radialSegmentCount = 5

        cylinder
            .firstMaterial?
            .diffuse.contents =
            UIColor.white
                .withAlphaComponent(
                    0.78
                )

        cylinder
            .firstMaterial?
            .emission.contents =
            UIColor.white
                .withAlphaComponent(
                    0.08
                )

        let node =
            SCNNode(
                geometry: cylinder
            )

        node.position =
            SCNVector3(
                (a.x + b.x) / 2,
                (a.y + b.y) / 2,
                (a.z + b.z) / 2
            )

        node.look(
            at: b,
            up:
                SCNVector3(
                    0,
                    1,
                    0
                ),
            localFront:
                SCNVector3(
                    0,
                    1,
                    0
                )
        )

        return node
    }
}
