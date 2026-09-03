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

        guard b.distanceM > a.distanceM else {
            return b.elevationM
        }

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

    /// RideControl-inspired terrain grade: compare the current elevation with
    /// a point ahead on the route, rather than differentiating adjacent GPX points.
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

/// GPX normalization used by BOTH RideModel and Climb3D.
///
/// Important design rule:
/// - no moving-average smoothing of latitude/longitude (that cuts hairpins);
/// - remove only GPS-scale noise / tiny loops;
/// - simplify with a small geometric tolerance;
/// - resample at a fixed 5 m spacing;
/// - smooth elevation only, in the distance domain.
private enum GPXPreprocessor {
    struct RawPoint {
        let lat: Double
        let lon: Double
        let ele: Double
    }

    private struct XYPoint {
        let raw: RawPoint
        let x: Double
        let y: Double
    }

    static let resampleStepM = 5.0
    static let duplicateThresholdM = 0.50
    static let spikeLegLimitM = 12.0
    static let spikeClosureLimitM = 3.0
    static let simplifyToleranceM = 1.25
    static let elevationSmoothRadiusM = 25.0

    static func process(_ input: [RawPoint]) -> [RoutePoint] {
        guard input.count >= 2 else { return [] }

        // 1. Remove true / near duplicates.
        let deduplicated = removeNearDuplicates(input)
        guard deduplicated.count >= 2 else { return [] }

        // 2. Remove tiny A-B-C GPS hooks only. A real hairpin has a much larger
        //    separation between A and C, so it survives this test.
        let despiked = removeMicroHooks(deduplicated)
        guard despiked.count >= 2 else { return [] }

        // 3. RDP removes sub-metre / metre-scale lateral GPS wobble without doing
        //    an averaging pass across neighbouring road legs. Tight hairpins are
        //    retained because the maximum allowed displacement is only 1.25 m.
        let simplified = simplifyRDP(despiked, toleranceM: simplifyToleranceM)
        guard simplified.count >= 2 else { return [] }

        // 4. Build a clean cumulative distance on the cleaned polyline.
        let cleanRoute = routePoints(from: simplified)
        guard cleanRoute.count >= 2,
              let last = cleanRoute.last,
              last.distanceM > 0 else {
            return cleanRoute
        }

        // 5. Fixed spatial sampling. This is the route consumed by both the
        //    physics and the 3D mesh, so distance mapping remains 1:1.
        let resampled = resample(cleanRoute, stepM: resampleStepM)

        // 6. Elevation only. No horizontal smoothing is performed here.
        return smoothElevation(resampled, radiusM: elevationSmoothRadiusM)
    }

    private static func removeNearDuplicates(_ source: [RawPoint]) -> [RawPoint] {
        guard let first = source.first else { return [] }
        var result: [RawPoint] = [first]
        result.reserveCapacity(source.count)

        for point in source.dropFirst() {
            guard let last = result.last else {
                result.append(point)
                continue
            }
            if distanceM(last, point) >= duplicateThresholdM {
                result.append(point)
            }
        }

        if let originalLast = source.last,
           let last = result.last,
           distanceM(last, originalLast) > 0.05 {
            result.append(originalLast)
        }

        return result
    }

    private static func removeMicroHooks(_ source: [RawPoint]) -> [RawPoint] {
        guard source.count >= 3 else { return source }

        var result: [RawPoint] = []
        result.reserveCapacity(source.count)
        result.append(source[0])

        var index = 1
        while index < source.count - 1 {
            let a = result.last ?? source[index - 1]
            let b = source[index]
            let c = source[index + 1]

            let ab = distanceM(a, b)
            let bc = distanceM(b, c)
            let ac = distanceM(a, c)

            // A very short out-and-back GPS spike. This deliberately does NOT
            // classify a normal U-turn / hairpin as noise.
            if ab <= spikeLegLimitM,
               bc <= spikeLegLimitM,
               ac <= spikeClosureLimitM {
                index += 1
                continue
            }

            result.append(b)
            index += 1
        }

        if let last = source.last {
            result.append(last)
        }

        return result
    }

    private static func simplifyRDP(_ source: [RawPoint], toleranceM: Double) -> [RawPoint] {
        guard source.count > 2, toleranceM > 0 else { return source }

        let lat0 = source[0].lat * .pi / 180.0
        let latScale = 111_320.0
        let lonScale = 111_320.0 * cos(lat0)
        let lon0 = source[0].lon
        let baseLat = source[0].lat

        let xy: [XYPoint] = source.map { point in
            XYPoint(
                raw: point,
                x: (point.lon - lon0) * lonScale,
                y: (point.lat - baseLat) * latScale
            )
        }

        var keep = Array(repeating: false, count: xy.count)
        keep[0] = true
        keep[xy.count - 1] = true

        var stack: [(Int, Int)] = [(0, xy.count - 1)]

        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }

            let a = xy[start]
            let b = xy[end]
            var maxDistance = -1.0
            var maxIndex = -1

            for i in (start + 1)..<end {
                let d = pointToSegmentDistance(
                    px: xy[i].x,
                    py: xy[i].y,
                    ax: a.x,
                    ay: a.y,
                    bx: b.x,
                    by: b.y
                )
                if d > maxDistance {
                    maxDistance = d
                    maxIndex = i
                }
            }

            if maxIndex >= 0, maxDistance > toleranceM {
                keep[maxIndex] = true
                stack.append((start, maxIndex))
                stack.append((maxIndex, end))
            }
        }

        return xy.indices.compactMap { keep[$0] ? xy[$0].raw : nil }
    }

    private static func pointToSegmentDistance(
        px: Double,
        py: Double,
        ax: Double,
        ay: Double,
        bx: Double,
        by: Double
    ) -> Double {
        let dx = bx - ax
        let dy = by - ay
        let length2 = dx * dx + dy * dy

        if length2 <= 1e-12 {
            return hypot(px - ax, py - ay)
        }

        let t = min(1.0, max(0.0, ((px - ax) * dx + (py - ay) * dy) / length2))
        let qx = ax + t * dx
        let qy = ay + t * dy
        return hypot(px - qx, py - qy)
    }

    private static func routePoints(from source: [RawPoint]) -> [RoutePoint] {
        guard let first = source.first else { return [] }

        var result: [RoutePoint] = [
            RoutePoint(
                distanceM: 0,
                elevationM: first.ele,
                latitude: first.lat,
                longitude: first.lon
            )
        ]
        result.reserveCapacity(source.count)

        var cumulative = 0.0
        var previous = first

        for point in source.dropFirst() {
            cumulative += distanceM(previous, point)
            result.append(
                RoutePoint(
                    distanceM: cumulative,
                    elevationM: point.ele,
                    latitude: point.lat,
                    longitude: point.lon
                )
            )
            previous = point
        }

        return result
    }

    private static func resample(_ source: [RoutePoint], stepM: Double) -> [RoutePoint] {
        guard source.count >= 2,
              let last = source.last,
              last.distanceM > 0,
              stepM > 0 else {
            return source
        }

        let total = last.distanceM
        var result: [RoutePoint] = []
        result.reserveCapacity(Int(total / stepM) + 2)

        var target = 0.0
        var segmentIndex = 0

        while target <= total {
            while segmentIndex + 1 < source.count,
                  source[segmentIndex + 1].distanceM < target {
                segmentIndex += 1
            }

            let nextIndex = min(source.count - 1, segmentIndex + 1)
            let a = source[segmentIndex]
            let b = source[nextIndex]
            let span = max(0.001, b.distanceM - a.distanceM)
            let t = min(1.0, max(0.0, (target - a.distanceM) / span))

            result.append(
                RoutePoint(
                    distanceM: target,
                    elevationM: a.elevationM + (b.elevationM - a.elevationM) * t,
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t
                )
            )

            target += stepM
        }

        if let resultLast = result.last,
           total - resultLast.distanceM > 0.05 {
            result.append(last)
        } else if let resultLast = result.last,
                  abs(total - resultLast.distanceM) <= 0.05,
                  resultLast.distanceM != total {
            result[result.count - 1] = last
        }

        // The target distances above are intentionally the physical arc-length
        // positions on the cleaned polyline. Recalculate once from final XY to
        // eliminate any tiny lat/lon interpolation/projection discrepancy.
        return recalculateDistances(result)
    }

    private static func recalculateDistances(_ source: [RoutePoint]) -> [RoutePoint] {
        guard let first = source.first else { return [] }

        var result: [RoutePoint] = [
            RoutePoint(
                distanceM: 0,
                elevationM: first.elevationM,
                latitude: first.latitude,
                longitude: first.longitude
            )
        ]
        result.reserveCapacity(source.count)

        var cumulative = 0.0
        var previous = first

        for point in source.dropFirst() {
            cumulative += CLLocation(
                latitude: previous.latitude,
                longitude: previous.longitude
            ).distance(
                from: CLLocation(
                    latitude: point.latitude,
                    longitude: point.longitude
                )
            )

            result.append(
                RoutePoint(
                    distanceM: cumulative,
                    elevationM: point.elevationM,
                    latitude: point.latitude,
                    longitude: point.longitude
                )
            )
            previous = point
        }

        return result
    }

    private static func smoothElevation(_ source: [RoutePoint], radiusM: Double) -> [RoutePoint] {
        guard source.count >= 3, radiusM > 0 else { return source }

        var result: [RoutePoint] = []
        result.reserveCapacity(source.count)

        var left = 0
        var right = 0

        for i in source.indices {
            // Preserve the exact route endpoints.
            if i == 0 || i == source.count - 1 {
                result.append(source[i])
                continue
            }

            let center = source[i].distanceM

            while left < i && center - source[left].distanceM > radiusM {
                left += 1
            }

            if right < i { right = i }
            while right + 1 < source.count,
                  source[right + 1].distanceM - center <= radiusM {
                right += 1
            }

            var weightedElevation = 0.0
            var weightSum = 0.0

            for j in left...right {
                let delta = abs(source[j].distanceM - center)
                let weight = max(0.001, 1.0 - delta / radiusM)
                weightedElevation += source[j].elevationM * weight
                weightSum += weight
            }

            let smoothed = weightSum > 0
                ? weightedElevation / weightSum
                : source[i].elevationM

            result.append(
                RoutePoint(
                    distanceM: source[i].distanceM,
                    elevationM: smoothed,
                    latitude: source[i].latitude,
                    longitude: source[i].longitude
                )
            )
        }

        return result
    }

    private static func distanceM(_ a: RawPoint, _ b: RawPoint) -> Double {
        CLLocation(latitude: a.lat, longitude: a.lon)
            .distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
    }
}

final class GPXParser: NSObject, XMLParserDelegate {
    private var points: [GPXPreprocessor.RawPoint] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentElement = ""
    private var textBuffer = ""

    func parse(data: Data) throws -> GPXRoute {
        points.removeAll()

        let parser = XMLParser(data: data)
        parser.delegate = self

        guard parser.parse(), points.count >= 2 else {
            throw parser.parserError ?? GPXParserError.noTrackPoints
        }

        let processed = GPXPreprocessor.process(points)
        guard processed.count >= 2 else {
            throw GPXParserError.noTrackPoints
        }

        return GPXRoute(points: processed)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
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
                points.append(
                    GPXPreprocessor.RawPoint(
                        lat: lat,
                        lon: lon,
                        ele: ele
                    )
                )
            }
            currentLat = nil
            currentLon = nil
            currentEle = nil
        }

        currentElement = ""
        textBuffer = ""
    }
}
