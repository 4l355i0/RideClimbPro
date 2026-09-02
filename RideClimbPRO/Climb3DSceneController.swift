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
    private var lastDistanceUpdateAt: Date?
    private var visualSpeedKPH: Double = 0
    private var followMode = false
    private var showingOverview = true

    // Follow camera: keep the marker higher on screen at low speed, then
    // progressively open the view as speed increases.
    private let minCameraBehindM: Double = 8.5
    private let maxCameraBehindM: Double = 11.0
    private let minFollowLookAheadM: Double = 12.0
    private let maxFollowLookAheadM: Double = 24.0
    private let minCameraHeightM: Float = 4.7
    private let maxCameraHeightM: Float = 5.2
    private let minFollowTargetLiftM: Float = 0.15
    private let maxFollowTargetLiftM: Float = 0.70

    init() {
        let markerGeometry = SCNSphere(radius: 0.52)
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
            if showingOverview {
                showOverview(animated: false)
            } else if followMode {
                updateFollowCamera(
                    distanceM: currentDistanceM,
                    animated: false
                )
            }
        }
    }

    func setMesh(_ mesh: Climb3DMesh, route: GPXRoute) {
        self.mesh = mesh
        self.route = route

        meshNode.geometry = mesh.sceneGeometry()
        meshNode.castsShadow = false

        rebuildRoute(mesh.centerline)

        currentDistanceM = 0
        lastDistanceUpdateAt = nil
        visualSpeedKPH = 0
        followMode = false
        showingOverview = true
        updateMarker(distanceM: 0, animated: false)
        showOverview(animated: false)
    }

    /// RideClimbPRO is the source of truth. No independent progress clock exists here.
    func updateDistance(_ distanceM: Double) {
        guard let route, route.totalDistanceM > 0 else {
            markerNode.isHidden = true
            return
        }

        let previousDistance = currentDistanceM
        let now = Date()
        let animationDuration: CFTimeInterval
        if let lastDistanceUpdateAt {
            let deltaT = max(0.001, now.timeIntervalSince(lastDistanceUpdateAt))
            animationDuration = min(0.80, max(0.12, deltaT))

            let deltaM = max(0, distanceM - previousDistance)
            let instantaneousKPH = (deltaM / deltaT) * 3.6
            if instantaneousKPH.isFinite {
                visualSpeedKPH =
                    visualSpeedKPH * 0.70 +
                    min(80.0, instantaneousKPH) * 0.30
            }
        } else {
            animationDuration = 0.24
            visualSpeedKPH = 0
        }
        lastDistanceUpdateAt = now

        let distance =
            min(
                route.totalDistanceM,
                max(0, distanceM)
            )

        currentDistanceM = distance

        updateMarker(
            distanceM: distance,
            animated: true,
            duration: animationDuration
        )

        // A freshly imported/reset GPX is shown as a full-route perspective
        // overview. As soon as RideModel actually starts advancing, switch to
        // the riding camera automatically.
        if showingOverview {
            if distance > 0.05 &&
                distance > previousDistance {

                showingOverview = false
                followMode = true

                updateFollowCamera(
                    distanceM: distance,
                    animated: true
                )
            }

            return
        }

        if followMode {
            updateFollowCamera(
                distanceM: distance,
                animated: true
            )
        }
    }

    private func updateMarker(
        distanceM: Double,
        animated: Bool,
        duration: CFTimeInterval = 0.24
    ) {
        let position =
            meshPosition(
                atDistanceM: distanceM
            )

        let markerTarget =
            SCNVector3(
                position.x,
                position.y + 0.50,
                position.z
            )

        markerNode.isHidden = false

        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = duration
            SCNTransaction.animationTimingFunction =
                CAMediaTimingFunction(name: .linear)

            markerNode.position = markerTarget

            SCNTransaction.commit()
        } else {
            markerNode.position = markerTarget
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

        let speedFactor =
            min(
                1.0,
                max(
                    0.0,
                    visualSpeedKPH / 25.0
                )
            )

        let followLookAheadM =
            minFollowLookAheadM +
            (maxFollowLookAheadM - minFollowLookAheadM) *
            speedFactor

        let cameraBehindM =
            minCameraBehindM +
            (maxCameraBehindM - minCameraBehindM) *
            speedFactor

        let cameraHeightM =
            minCameraHeightM +
            (maxCameraHeightM - minCameraHeightM) *
            Float(speedFactor)

        let followTargetLiftM =
            minFollowTargetLiftM +
            (maxFollowTargetLiftM - minFollowTargetLiftM) *
            Float(speedFactor)

        // Build 32: keep the Follow camera on the same terrain side as the
        // rider. Near a crest the old look-ahead could point the camera into
        // the descent while RideModel was still on the climb, creating the
        // impression that 3D had jumped/reset.
        let futureDistance =
            followTargetDistance(
                from: distanceM,
                requestedLookAheadM: followLookAheadM,
                route: route
            )

        let future =
            meshPosition(
                atDistanceM: futureDistance
            )

        // Use the local forward tangent, rather than a point on the road
        // behind the rider. At a tight hairpin an actual "behind" route point
        // can lie on the previous leg and make the camera flip or lose
        // perspective.
        var dx =
            Double(
                future.x - current.x
            )

        var dz =
            Double(
                future.z - current.z
            )

        var horizontalLength =
            sqrt(
                dx * dx +
                dz * dz
            )

        // Very end of route: derive direction from a point behind.
        if horizontalLength < 0.01 {
            let back =
                meshPosition(
                    atDistanceM:
                        max(
                            0,
                            distanceM - followLookAheadM
                        )
                )

            dx =
                Double(
                    current.x - back.x
                )

            dz =
                Double(
                    current.z - back.z
                )

            horizontalLength =
                max(
                    0.01,
                    sqrt(
                        dx * dx +
                        dz * dz
                    )
                )
        }

        let ux =
            Float(
                dx /
                horizontalLength
            )

        let uz =
            Float(
                dz /
                horizontalLength
            )

        // Camera stays behind and above the rider. Because it looks 24 m
        // ahead instead of directly at the ball, the climb and upcoming
        // hairpins retain clear depth/perspective.
        let cameraPosition =
            SCNVector3(
                current.x -
                    ux *
                    Float(cameraBehindM),
                current.y +
                    cameraHeightM,
                current.z -
                    uz *
                    Float(cameraBehindM)
            )

        let target =
            SCNVector3(
                future.x,
                future.y +
                    followTargetLiftM,
                future.z
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
            SCNTransaction.animationDuration = 0.24
            SCNTransaction.animationTimingFunction =
                CAMediaTimingFunction(name: .linear)

            apply()

            SCNTransaction.commit()
        } else {
            apply()
        }
    }

    /// Full-climb perspective shown after GPX import and after a reset.
    func showOverview(animated: Bool = true) {
        guard let mesh,
              !mesh.centerline.isEmpty else {
            return
        }

        showingOverview = true
        followMode = false
        view?.allowsCameraControl = true

        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude

        for p in mesh.centerline {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
            minZ = min(minZ, p.z)
            maxZ = max(maxZ, p.z)
        }

        let center =
            SCNVector3(
                (minX + maxX) / 2,
                (minY + maxY) / 2,
                (minZ + maxZ) / 2
            )

        let spanX =
            Double(maxX - minX)

        let spanY =
            Double(maxY - minY)

        let spanZ =
            Double(maxZ - minZ)

        // Fit the complete 3D bounding box to the actual camera FOV/aspect.
        let halfX = max(1.0, spanX / 2.0)
        let halfY = max(1.0, spanY / 2.0)
        let halfZ = max(1.0, spanZ / 2.0)
        let boundingRadius =
            sqrt(
                halfX * halfX +
                halfY * halfY +
                halfZ * halfZ
            )

        let verticalFOVDegrees =
            Double(
                cameraNode.camera?.fieldOfView ?? 66
            )

        let verticalHalfFOV =
            max(
                0.20,
                verticalFOVDegrees *
                .pi / 360.0
            )

        let aspect =
            max(
                0.45,
                min(
                    2.2,
                    Double(
                        (view?.bounds.width ?? 3) /
                        max(1, view?.bounds.height ?? 4)
                    )
                )
            )

        let horizontalHalfFOV =
            atan(
                tan(verticalHalfFOV) *
                aspect
            )

        let limitingHalfFOV =
            max(
                0.20,
                min(
                    verticalHalfFOV,
                    horizontalHalfFOV
                )
            )

        let fitDistance =
            max(
                25.0,
                boundingRadius /
                tan(limitingHalfFOV) *
                1.18
            )

        // Diagonal elevated overview, aimed at the exact route centre.
        var dirX = -0.62
        var dirY = 0.56
        var dirZ = 0.62
        let dirLength =
            sqrt(
                dirX * dirX +
                dirY * dirY +
                dirZ * dirZ
            )

        dirX /= dirLength
        dirY /= dirLength
        dirZ /= dirLength

        let cameraPosition =
            SCNVector3(
                center.x + Float(dirX * fitDistance),
                center.y + Float(dirY * fitDistance),
                center.z + Float(dirZ * fitDistance)
            )

        let target = center

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
            SCNTransaction.animationDuration = 0.65
            SCNTransaction.animationTimingFunction =
                CAMediaTimingFunction(name: .easeInEaseOut)

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
        showingOverview = false
        followMode = true
        view?.allowsCameraControl = false

        updateFollowCamera(
            distanceM: currentDistanceM,
            animated: true
        )
    }

    func resetCamera() {
        enableFollowMode()
    }

    /// Returns a camera target ahead of the rider without crossing an
    /// upcoming climb/descend sign change. The marker itself always remains
    /// exactly at RideModel.distanceM.
    private func followTargetDistance(
        from distanceM: Double,
        requestedLookAheadM: Double,
        route: GPXRoute
    ) -> Double {
        let start = min(route.totalDistanceM, max(0, distanceM))
        let requestedEnd =
            min(
                route.totalDistanceM,
                start + max(1.0, requestedLookAheadM)
            )

        // Use the same current-position grade API used by RideModel.
        let startGrade = route.grade(at: start, windowM: 10)
        let deadband = 0.25

        func sign(_ grade: Double) -> Int {
            if grade > deadband { return 1 }
            if grade < -deadband { return -1 }
            return 0
        }

        let startSign = sign(startGrade)

        // On essentially flat terrain there is no meaningful crest boundary
        // to protect; use the normal look-ahead.
        if startSign == 0 {
            return requestedEnd
        }

        // Search forward in 1 m increments. As soon as the terrain changes
        // sign, keep the target just before that boundary. Once RideModel
        // itself crosses the crest, startSign flips and the camera follows
        // the descent normally.
        var probe = start + 1.0
        while probe < requestedEnd {
            let probeSign =
                sign(
                    route.grade(
                        at: probe,
                        windowM: 10
                    )
                )

            if probeSign != 0 &&
                probeSign != startSign {
                return max(start + 1.0, probe - 1.0)
            }

            probe += 1.0
        }

        return requestedEnd
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
        if target >= route.totalDistanceM {
            return mesh.centerline[mesh.centerline.count - 1]
        }

        var low = 0
        var high = min(route.points.count, mesh.centerline.count) - 1

        while low + 1 < high {
            let mid = (low + high) / 2
            if route.points[mid].distanceM < target {
                low = mid
            } else {
                high = mid
            }
        }

        let ra = route.points[low]
        let rb = route.points[high]
        let a = mesh.centerline[low]
        let b = mesh.centerline[high]

        let span = max(0.001, rb.distanceM - ra.distanceM)
        let t = Float((target - ra.distanceM) / span)

        return Climb3DVertex(
            x: a.x + (b.x-a.x)*t,
            y: a.y + (b.y-a.y)*t,
            z: a.z + (b.z-a.z)*t
        )
    }

    private func rebuildRoute(_ points: [Climb3DVertex]) {
        routeNode.childNodes.forEach { $0.removeFromParentNode() }
        guard points.count >= 2 else { return }

        for i in 1..<points.count {
            let a = points[i-1]
            let b = points[i]
            routeNode.addChildNode(
                lineNode(
                    from: SCNVector3(a.x, a.y+0.08, a.z),
                    to: SCNVector3(b.x, b.y+0.08, b.z)
                )
            )
        }
    }

    private func lineNode(from a: SCNVector3, to b: SCNVector3) -> SCNNode {
        let dx = b.x-a.x
        let dy = b.y-a.y
        let dz = b.z-a.z
        let length = sqrt(dx*dx + dy*dy + dz*dz)

        let cylinder = SCNCylinder(radius: 0.075, height: CGFloat(length))
        cylinder.radialSegmentCount = 5
        cylinder.firstMaterial?.diffuse.contents =
            UIColor.white.withAlphaComponent(0.78)
        cylinder.firstMaterial?.emission.contents =
            UIColor.white.withAlphaComponent(0.08)

        let node = SCNNode(geometry: cylinder)
        node.position =
            SCNVector3(
                (a.x+b.x)/2,
                (a.y+b.y)/2,
                (a.z+b.z)/2
            )

        node.look(
            at: b,
            up: SCNVector3(0,1,0),
            localFront: SCNVector3(0,1,0)
        )
        return node
    }
}
