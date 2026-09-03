import Foundation
import CoreLocation

struct RoutePoint {
    let distanceM: Double
    let elevationM: Double
    let latitude: Double
    let longitude: Double
}

struct GPXRoute {
    let points: [RoutePoint]

    var totalDistanceM: Double {
        points.last?.distanceM ?? 0
    }

    /// The same forward terrain horizon used by RideModel.
    func terrainLookAheadM(maximum: Double = 150.0) -> Double {
        min(maximum, totalDistanceM / 20.0)
    }

    func terrainGrade(at distanceM: Double, maximumLookAheadM: Double = 150.0) -> Double {
        forwardGrade(
            at: distanceM,
            lookAheadM: terrainLookAheadM(maximum: maximumLookAheadM)
        )
    }

    func elevation(at distanceM: Double) -> Double {
        guard !points.isEmpty else { return 0 }

        let d = min(max(distanceM, 0), totalDistanceM)
        var low = 0
        var high = points.count - 1

        while low < high {
            let mid = (low + high) / 2
            if points[mid].distanceM < d {
                low = mid + 1
            } else {
                high = mid
            }
        }

        if low == 0 { return points[0].elevationM }

        let a = points[low - 1]
        let b = points[low]
        guard b.distanceM > a.distanceM else { return b.elevationM }

        let fraction = (d - a.distanceM) / (b.distanceM - a.distanceM)
        return a.elevationM + fraction * (b.elevationM - a.elevationM)
    }

    func grade(at distanceM: Double, windowM: Double = 50) -> Double {
        let half = max(5, windowM / 2)
        let a = max(0, distanceM - half)
        let b = min(totalDistanceM, distanceM + half)
        guard b - a >= 2 else { return 0 }
        return 100 * (elevation(at: b) - elevation(at: a)) / (b - a)
    }

    func forwardGrade(at distanceM: Double, lookAheadM: Double) -> Double {
        let start = min(max(distanceM, 0), totalDistanceM)
        let end = min(totalDistanceM, start + max(0, lookAheadM))
        guard end - start >= 2 else { return 0 }
        return 100 * (elevation(at: end) - elevation(at: start)) / (end - start)
    }
}

enum GPXParserError: Error {
    case noTrackPoints
}

/// Build 37 GPX preprocessing
///
/// The imported GPX is treated as a GUIDE, not as geometry that must be reproduced
/// point-for-point. The output preserves the real climb structure:
/// - primary climb length
/// - number/order/location of major hairpins
/// - elevation change of every inter-hairpin section
/// - total start/end elevation difference
///
/// It removes the two things that make dirty GPX files look bad in 3D:
/// - irregular point spacing
/// - noisy elevation inside each road section
///
/// Plan-view geometry is kept on the original GPX polyline and resampled at 5 m.
/// Elevation is rebuilt piecewise-linearly between detected hairpins, exactly as in
/// the successful manually regularized Alpe d'Huez test.
final class GPXParser: NSObject, XMLParserDelegate {
    private struct RawPoint {
        let lat: Double
        let lon: Double
        let ele: Double
    }

    private var rawPoints: [RawPoint] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var textBuffer = ""

    private let resampleStepM = 5.0
    private let minimumRawSpacingM = 0.50

    // Major-hairpin detector. 30 m before/after gives a stable road heading and
    // rejects normal bends; 90° selects true switchbacks. Nearby candidates are
    // clustered so one physical hairpin becomes one anchor.
    private let hairpinHeadingWindowM = 30.0
    private let hairpinMinimumTurnDeg = 90.0
    private let hairpinClusterM = 70.0

    func parse(data: Data) throws -> GPXRoute {
        rawPoints.removeAll(keepingCapacity: true)

        let parser = XMLParser(data: data)
        parser.delegate = self

        guard parser.parse(), rawPoints.count >= 2 else {
            throw parser.parserError ?? GPXParserError.noTrackPoints
        }

        let cleaned = removeNearDuplicates(rawPoints)
        guard cleaned.count >= 2 else { throw GPXParserError.noTrackPoints }

        var source = buildRoute(cleaned)
        guard source.count >= 2 else { throw GPXParserError.noTrackPoints }

        // If the file contains a flat/irregular approach before a sustained climb,
        // remove only that approach. If no unambiguous climb start exists, keep all.
        source = trimToPrimaryClimbIfUnambiguous(source)

        // Geometry: follow the original GPX polyline, but with regular 5 m spacing.
        // No Douglas-Peucker and no lat/lon moving average: genuine hairpins remain.
        let resampled = resample(source, every: resampleStepM)
        guard resampled.count >= 2 else { throw GPXParserError.noTrackPoints }

        // Detect the major switchbacks and use them as hard elevation anchors.
        let hairpins = detectHairpins(in: resampled)
        let anchors = normalizedAnchors(hairpins, pointCount: resampled.count)

        // Elevation: rebuild every inter-hairpin road section as one clean ramp,
        // retaining that section's original endpoint elevations. This preserves
        // average grade per section and removes vertical GPS noise/spikes.
        let regularized = rebuildElevationBySegments(resampled, anchors: anchors)

        return GPXRoute(points: regularized)
    }

    // MARK: - Raw cleanup / route construction

    private func removeNearDuplicates(_ source: [RawPoint]) -> [RawPoint] {
        guard source.count >= 2 else { return source }

        var result: [RawPoint] = [source[0]]
        result.reserveCapacity(source.count)

        for point in source.dropFirst() {
            guard let last = result.last else {
                result.append(point)
                continue
            }

            let a = CLLocation(latitude: last.lat, longitude: last.lon)
            let b = CLLocation(latitude: point.lat, longitude: point.lon)
            if a.distance(from: b) >= minimumRawSpacingM {
                result.append(point)
            }
        }

        if let final = source.last,
           let last = result.last,
           (final.lat != last.lat || final.lon != last.lon) {
            result.append(final)
        }

        return result
    }

    private func buildRoute(_ source: [RawPoint]) -> [RoutePoint] {
        guard !source.isEmpty else { return [] }

        var result: [RoutePoint] = []
        result.reserveCapacity(source.count)

        var cumulative = 0.0
        result.append(
            RoutePoint(
                distanceM: 0,
                elevationM: source[0].ele,
                latitude: source[0].lat,
                longitude: source[0].lon
            )
        )

        for i in 1..<source.count {
            let a = CLLocation(latitude: source[i - 1].lat, longitude: source[i - 1].lon)
            let b = CLLocation(latitude: source[i].lat, longitude: source[i].lon)
            cumulative += a.distance(from: b)

            result.append(
                RoutePoint(
                    distanceM: cumulative,
                    elevationM: source[i].ele,
                    latitude: source[i].lat,
                    longitude: source[i].lon
                )
            )
        }

        return result
    }

    // MARK: - Primary climb start

    /// Detect a clearly sustained uphill start. The 300/500 m dual test avoids
    /// triggering on a short ramp in an approach. Thresholds were chosen so the
    /// supplied Alpe file starts at ~13.8 km remaining, matching the known-good
    /// regularized test instead of the dirty 15.7 km approach-inclusive file.
    private func trimToPrimaryClimbIfUnambiguous(_ source: [RoutePoint]) -> [RoutePoint] {
        guard source.count >= 2,
              let last = source.last,
              last.distanceM >= 3_000 else {
            return source
        }

        let total = last.distanceM
        let netRise = source.last!.elevationM - source.first!.elevationM
        guard netRise > 150 else { return source }

        let searchLimit = min(total * 0.35, total - 500)
        var d = 0.0
        var startDistance: Double?

        while d <= searchLimit {
            let g300 = forwardGrade(in: source, at: d, lookAheadM: 300)
            let g500 = forwardGrade(in: source, at: d, lookAheadM: 500)

            if g300 >= 6.0 && g500 >= 8.0 {
                startDistance = d
                break
            }
            d += 5.0
        }

        guard let startDistance, startDistance > 100 else { return source }

        // Start exactly on the detected route distance, then rebase distance to 0.
        var cropped: [RoutePoint] = []
        let first = interpolatedPoint(in: source, at: startDistance)
        cropped.append(
            RoutePoint(
                distanceM: 0,
                elevationM: first.elevationM,
                latitude: first.latitude,
                longitude: first.longitude
            )
        )

        for p in source where p.distanceM > startDistance {
            cropped.append(
                RoutePoint(
                    distanceM: p.distanceM - startDistance,
                    elevationM: p.elevationM,
                    latitude: p.latitude,
                    longitude: p.longitude
                )
            )
        }

        return cropped.count >= 2 ? cropped : source
    }

    // MARK: - 5 m resampling along original polyline

    private func resample(_ source: [RoutePoint], every stepM: Double) -> [RoutePoint] {
        guard source.count >= 2,
              let last = source.last,
              last.distanceM > 0 else {
            return source
        }

        var result: [RoutePoint] = []
        result.reserveCapacity(Int(last.distanceM / stepM) + 2)

        var d = 0.0
        while d < last.distanceM {
            result.append(interpolatedPoint(in: source, at: d))
            d += stepM
        }

        result.append(interpolatedPoint(in: source, at: last.distanceM))
        return result
    }

    private func interpolatedPoint(in source: [RoutePoint], at distanceM: Double) -> RoutePoint {
        guard !source.isEmpty else {
            return RoutePoint(distanceM: 0, elevationM: 0, latitude: 0, longitude: 0)
        }

        let total = source.last?.distanceM ?? 0
        let target = min(total, max(0, distanceM))

        var low = 0
        var high = source.count - 1
        while low < high {
            let mid = (low + high) / 2
            if source[mid].distanceM < target {
                low = mid + 1
            } else {
                high = mid
            }
        }

        if low == 0 {
            let p = source[0]
            return RoutePoint(
                distanceM: target,
                elevationM: p.elevationM,
                latitude: p.latitude,
                longitude: p.longitude
            )
        }

        let a = source[low - 1]
        let b = source[low]
        let span = max(0.001, b.distanceM - a.distanceM)
        let t = min(1, max(0, (target - a.distanceM) / span))

        return RoutePoint(
            distanceM: target,
            elevationM: a.elevationM + (b.elevationM - a.elevationM) * t,
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    // MARK: - Hairpin detection

    private func detectHairpins(in points: [RoutePoint]) -> [Int] {
        guard points.count >= 7 else { return [] }

        let step = max(0.5, medianSpacing(points))
        let window = max(1, Int((hairpinHeadingWindowM / step).rounded()))
        guard points.count > window * 2 + 1 else { return [] }

        struct Candidate {
            let index: Int
            let angleDeg: Double
        }

        var candidates: [Candidate] = []

        for i in window..<(points.count - window) {
            let before = points[i - window]
            let center = points[i]
            let after = points[i + window]

            let h1 = heading(from: before, to: center)
            let h2 = heading(from: center, to: after)
            let turn = abs(normalizedAngle(h2 - h1)) * 180.0 / .pi

            if turn >= hairpinMinimumTurnDeg {
                candidates.append(Candidate(index: i, angleDeg: turn))
            }
        }

        guard !candidates.isEmpty else { return [] }

        var result: [Int] = []
        var cluster: [Candidate] = []

        func flushCluster() {
            guard !cluster.isEmpty else { return }
            if let best = cluster.max(by: { $0.angleDeg < $1.angleDeg }) {
                result.append(best.index)
            }
            cluster.removeAll(keepingCapacity: true)
        }

        for candidate in candidates {
            if let last = cluster.last {
                let gap = points[candidate.index].distanceM - points[last.index].distanceM
                if gap > hairpinClusterM {
                    flushCluster()
                }
            }
            cluster.append(candidate)
        }
        flushCluster()

        return result
    }

    private func normalizedAnchors(_ hairpins: [Int], pointCount: Int) -> [Int] {
        guard pointCount >= 2 else { return [0] }
        var anchors = [0]
        anchors.append(contentsOf: hairpins.filter { $0 > 0 && $0 < pointCount - 1 })
        anchors.append(pointCount - 1)
        return Array(Set(anchors)).sorted()
    }

    private func medianSpacing(_ points: [RoutePoint]) -> Double {
        guard points.count >= 2 else { return resampleStepM }
        let deltas = zip(points.dropFirst(), points).map { max(0, $0.distanceM - $1.distanceM) }
        let sorted = deltas.sorted()
        return sorted[sorted.count / 2]
    }

    private func heading(from a: RoutePoint, to b: RoutePoint) -> Double {
        let meanLat = (a.latitude + b.latitude) * 0.5 * .pi / 180.0
        let x = (b.longitude - a.longitude) * cos(meanLat)
        let y = b.latitude - a.latitude
        return atan2(y, x)
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        var a = angle
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }

    // MARK: - Elevation reconstruction

    private func rebuildElevationBySegments(_ source: [RoutePoint], anchors: [Int]) -> [RoutePoint] {
        guard source.count >= 2, anchors.count >= 2 else { return source }

        var elevations = source.map(\.elevationM)

        for segment in 0..<(anchors.count - 1) {
            let i0 = anchors[segment]
            let i1 = anchors[segment + 1]
            guard i1 > i0 else { continue }

            let d0 = source[i0].distanceM
            let d1 = source[i1].distanceM
            let e0 = source[i0].elevationM
            let e1 = source[i1].elevationM
            let length = max(0.001, d1 - d0)

            for i in i0...i1 {
                let t = min(1, max(0, (source[i].distanceM - d0) / length))
                elevations[i] = e0 + (e1 - e0) * t
            }
        }

        return source.indices.map { i in
            RoutePoint(
                distanceM: source[i].distanceM,
                elevationM: elevations[i],
                latitude: source[i].latitude,
                longitude: source[i].longitude
            )
        }
    }

    private func elevation(in source: [RoutePoint], at distanceM: Double) -> Double {
        interpolatedPoint(in: source, at: distanceM).elevationM
    }

    private func forwardGrade(in source: [RoutePoint], at distanceM: Double, lookAheadM: Double) -> Double {
        guard let total = source.last?.distanceM else { return 0 }
        let a = min(max(0, distanceM), total)
        let b = min(total, a + max(0, lookAheadM))
        guard b - a >= 2 else { return 0 }
        return 100.0 * (elevation(in: source, at: b) - elevation(in: source, at: a)) / (b - a)
    }

    // MARK: - XML

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        textBuffer = ""

        if elementName == "trkpt" || elementName == "rtept" {
            currentLat = Double(attributeDict["lat"] ?? "")
            currentLon = Double(attributeDict["lon"] ?? "")
            currentEle = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "ele" {
            currentEle = Double(textBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if elementName == "trkpt" || elementName == "rtept" {
            if let lat = currentLat,
               let lon = currentLon,
               let ele = currentEle {
                rawPoints.append(RawPoint(lat: lat, lon: lon, ele: ele))
            }
            currentLat = nil
            currentLon = nil
            currentEle = nil
        }

        textBuffer = ""
    }
}
