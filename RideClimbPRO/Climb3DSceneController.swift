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
    private var followMode = false
    private var overviewMode = true

    // Build 29 camera constants. These affect rendering only.
    private let cameraBehindM: Double = 10
    private let cameraHeightM: Float = 5.2
    private let tangentHalfWindowM: Double = 4.0
    private let followLookAheadM: Double = 11.0

    init() {
        let markerGeometry = SCNSphere(radius: 0.72)
        markerGeometry.segmentCount = 28
        markerGeometry.firstMaterial?.diffuse.contents = UIColor.systemRed
        markerGeometry.firstMaterial?.emission.contents =
            UIColor.systemRed.withAlphaComponent(0.24)
        markerGeometry.firstMaterial?.lightingModel = .physicallyBased

        markerNode = SCNNode(geometry: markerGeometry)
        markerNode.isHidden = true

        scene.rootNode.addChildNode(meshNode)
        scene.rootNode.addChildNode(routeNode)
        scene.rootNode.addChildNode(markerNode)

        let camera = SCNCamera()
        camera.fieldOfView = 62
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
        keyLightNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(keyLightNode)

        fillLightNode.light = SCNLight()
        fillLightNode.light?.type = .directional
        fillLightNode.light?.intensity = 390
        fillLightNode.eulerAngles = SCNVector3(-Float.pi / 4, -Float.pi / 2, 0)
        scene.rootNode.addChildNode(fillLightNode)

        ambientNode.light = SCNLight()
        ambientNode.light?.type = .ambient
        ambientNode.light?.intensity = 400
        ambientNode.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambientNode)

        scene.background.contents =
            UIColor(red: 0.42, green: 0.51, blue: 0.58, alpha: 1)
    }

    func attach(to view: SCNView) {
        self.view = view
        view.pointOfView = cameraNode

        guard mesh != nil else { return }
        if overviewMode {
            showOverview(animated: false)
        } else if followMode {
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
        followMode = false
        overviewMode = true
        updateMarker(distanceM: 0, animated: false)
        showOverview(animated: false)
    }

    /// The only position input is RideModel.distanceM. There is no second 3D
    /// clock, speed integrator or cadence calculation in the SceneKit layer.
    func updateDistance(_ distanceM: Double) {
        guard let route, route.totalDistanceM > 0 else {
            markerNode.isHidden = true
            return
        }

        let distance = min(route.totalDistanceM, max(0, distanceM))
        currentDistanceM = distance
        updateMarker(distanceM: distance, animated: true)

        // Overview remains an overview while riding: the marker therefore moves
        // visibly along the whole climb. Follow starts only when the user taps
        // Follow; we do not silently change camera mode.
        if followMode {
            updateFollowCamera(distanceM: distance, animated: true)
        }
    }

    private func updateMarker(distanceM: Double, animated: Bool) {
        let position = meshPosition(atDistanceM: distanceM)
        let target = SCNVector3(position.x, position.y + 0.72, position.z)
        markerNode.isHidden = false

        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.18
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .linear)
            markerNode.position = target
            SCNTransaction.commit()
        } else {
            markerNode.position = target
        }
    }

    private func updateFollowCamera(distanceM: Double, animated: Bool) {
        guard let route, route.totalDistanceM > 0 else { return }

        let current = meshPosition(atDistanceM: distanceM)
        let before = meshPosition(
            atDistanceM: max(0, distanceM - tangentHalfWindowM)
        )
        let after = meshPosition(
            atDistanceM: min(route.totalDistanceM, distanceM + tangentHalfWindowM)
        )

        var dx = Double(after.x - before.x)
        var dz = Double(after.z - before.z)
        var length = sqrt(dx * dx + dz * dz)

        if length < 0.01 {
            let future = meshPosition(
                atDistanceM: min(route.totalDistanceM, distanceM + followLookAheadM)
            )
            dx = Double(future.x - current.x)
            dz = Double(future.z - current.z)
            length = max(0.01, sqrt(dx * dx + dz * dz))
        }

        let ux = Float(dx / length)
        let uz = Float(dz / length)

        // Stay behind the rider along the LOCAL tangent. We deliberately do not
        // use a previous route point as the camera position: at a hairpin that
        // point can lie on the other leg and make the camera cut through it.
        let cameraPosition = SCNVector3(
            current.x - ux * Float(cameraBehindM),
            current.y + cameraHeightM,
            current.z - uz * Float(cameraBehindM)
        )

        let future = meshPosition(
            atDistanceM: min(route.totalDistanceM, distanceM + followLookAheadM)
        )
        let target = SCNVector3(future.x, future.y + 0.55, future.z)

        let apply = {
            self.cameraNode.camera?.fieldOfView = 66
            self.cameraNode.position = cameraPosition
            self.cameraNode.look(
                at: target,
                up: SCNVector3(0, 1, 0),
                localFront: SCNVector3(0, 0, -1)
            )
            self.view?.pointOfView = self.cameraNode
        }

        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.18
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            apply()
            SCNTransaction.commit()
        } else {
            apply()
        }
    }

    /// Full-route overview with a sphere-fit camera. Unlike the previous
    /// diagonal-span heuristic, a bounding sphere plus the actual view aspect
    /// guarantees margin around long/narrow routes and vertically exaggerated
    /// climbs, so the GPX cannot be cropped at the screen edges.
    func showOverview(animated: Bool = true) {
        guard let mesh, !mesh.centerline.isEmpty else { return }

        overviewMode = true
        followMode = false

        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude

        for p in mesh.centerline {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
            minZ = min(minZ, p.z); maxZ = max(maxZ, p.z)
        }

        let center = SCNVector3(
            (minX + maxX) / 2,
            (minY + maxY) / 2,
            (minZ + maxZ) / 2
        )

        var radius: Float = 1
        for p in mesh.centerline {
            let dx = p.x - center.x
            let dy = p.y - center.y
            let dz = p.z - center.z
            radius = max(radius, sqrt(dx * dx + dy * dy + dz * dz))
        }

        let aspect: Double = {
            guard let view, view.bounds.height > 1 else { return 0.55 }
            return max(0.35, Double(view.bounds.width / view.bounds.height))
        }()

        let verticalFOVDegrees = 54.0
        let verticalHalf = verticalFOVDegrees * .pi / 360.0
        let horizontalHalf = atan(tan(verticalHalf) * aspect)
        let limitingHalfFOV = max(0.12, min(verticalHalf, horizontalHalf))
        let fitDistance = Double(radius) / sin(limitingHalfFOV) * 1.18

        // Oblique "miniature climb" view: enough height to read elevation, but
        // enough lateral offset to keep hairpins visibly separated.
        let vx = -0.58
        let vy = 0.72
        let vz = 0.58
        let norm = sqrt(vx * vx + vy * vy + vz * vz)
        let d = Float(fitDistance)

        let cameraPosition = SCNVector3(
            center.x + Float(vx / norm) * d,
            center.y + Float(vy / norm) * d,
            center.z + Float(vz / norm) * d
        )

        let apply = {
            self.cameraNode.camera?.fieldOfView = CGFloat(verticalFOVDegrees)
            self.cameraNode.position = cameraPosition
            self.cameraNode.look(
                at: center,
                up: SCNVector3(0, 1, 0),
                localFront: SCNVector3(0, 0, -1)
            )
            self.view?.pointOfView = self.cameraNode
        }

        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.45
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
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
        overviewMode = false
        followMode = true
        updateFollowCamera(distanceM: currentDistanceM, animated: true)
    }

    func resetCamera() {
        enableFollowMode()
    }

    private func meshPosition(atDistanceM distanceM: Double) -> Climb3DVertex {
        guard let mesh,
              let route,
              !mesh.centerline.isEmpty,
              !route.points.isEmpty else {
            return Climb3DVertex(x: 0, y: 0, z: 0)
        }

        let target = min(route.totalDistanceM, max(0, distanceM))
        if target <= 0 { return mesh.centerline[0] }
        if target >= route.totalDistanceM { return mesh.centerline[mesh.centerline.count - 1] }

        var low = 0
        var high = min(route.points.count, mesh.centerline.count) - 1

        while low + 1 < high {
            let mid = (low + high) / 2
            if route.points[mid].distanceM < target { low = mid }
            else { high = mid }
        }

        let ra = route.points[low]
        let rb = route.points[high]
        let a = mesh.centerline[low]
        let b = mesh.centerline[high]
        let span = max(0.001, rb.distanceM - ra.distanceM)
        let t = Float((target - ra.distanceM) / span)

        return Climb3DVertex(
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t,
            z: a.z + (b.z - a.z) * t
        )
    }

    private func rebuildRoute(_ points: [Climb3DVertex]) {
        routeNode.childNodes.forEach { $0.removeFromParentNode() }
        guard points.count >= 2 else { return }

        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            routeNode.addChildNode(
                lineNode(
                    from: SCNVector3(a.x, a.y + 0.08, a.z),
                    to: SCNVector3(b.x, b.y + 0.08, b.z)
                )
            )
        }
    }

    private func lineNode(from a: SCNVector3, to b: SCNVector3) -> SCNNode {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dz = b.z - a.z
        let length = sqrt(dx * dx + dy * dy + dz * dz)

        let cylinder = SCNCylinder(radius: 0.075, height: CGFloat(length))
        cylinder.radialSegmentCount = 5
        cylinder.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(0.78)
        cylinder.firstMaterial?.emission.contents = UIColor.white.withAlphaComponent(0.08)

        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3(
            (a.x + b.x) / 2,
            (a.y + b.y) / 2,
            (a.z + b.z) / 2
        )
        node.look(
            at: b,
            up: SCNVector3(0, 1, 0),
            localFront: SCNVector3(0, 1, 0)
        )
        return node
    }
}

