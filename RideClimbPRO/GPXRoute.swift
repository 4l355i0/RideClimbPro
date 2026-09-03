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
/// - local elevation/grade profile
/// - total start/end elevation difference
///
/// It removes the two things that make dirty GPX files look bad in 3D:
/// - irregular point spacing
/// - noisy elevation inside each road section
///
/// Plan-view geometry is kept on the original GPX polyline and resampled at 5 m.
/// Elevation is spatially denoised with local-linear regression so real grade
/// changes remain present on climbs with or without hairpins.
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

        // Elevation must retain the REAL local profile. Hairpins are geometric
        // landmarks only; they must never be used as elevation anchors because
        // routes with few/no hairpins would collapse to one constant grade.
        // Use a spatial local-linear smoother instead: it removes GPS altitude
        // noise while preserving ramps and genuine grade changes.
        let regularized = regularizeElevationWithTrend(resampled)

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

    // MARK: - Elevation regularization with broad-trend consistency

    /// B39: preserve real ramps but reject short, implausible sign reversals.
    ///
    /// Example: if the broad 200-300 m terrain trend is uphill, a very short
    /// -6% dip embedded between positive grades is treated as altitude noise
    /// unless it persists long enough to be a credible road feature.
    ///
    /// Pipeline:
    /// 1. light local-linear smoothing removes point-to-point altitude jitter;
    /// 2. a broad local-linear trend estimates the terrain direction;
    /// 3. short local grade runs opposite to that trend are replaced by a
    ///    straight elevation bridge between their boundaries;
    /// 4. a final light pass removes joins introduced by the bridge.
    ///
    /// Geometry (lat/lon) is never changed here.
    private func regularizeElevationWithTrend(_ source: [RoutePoint]) -> [RoutePoint] {
        guard source.count >= 5, let last = source.last else { return source }

        let total = last.distanceM

        // Small-window denoising. This keeps genuine ramps while removing
        // sample-scale altitude noise.
        let localRadiusM: Double
        if total < 2_000 {
            localRadiusM = 15.0
        } else if total < 6_000 {
            localRadiusM = 20.0
        } else {
            localRadiusM = 25.0
        }

        var cleaned = localLinearElevationSmooth(source, radiusM: localRadiusM)

        // Broad terrain context. For short climbs do not let the context window
        // consume the whole route; for long climbs cap it at ~300 m.
        let broadWindowM = min(300.0, max(120.0, total * 0.25))
        let broadRadiusM = broadWindowM * 0.5
        let trend = localLinearElevationSmooth(cleaned, radiusM: broadRadiusM)

        // Local grade is intentionally evaluated over a distance longer than
        // one 5 m sample, otherwise normal GPS altitude quantisation can flip
        // the sign from sample to sample.
        let localGradeWindowM: Double = total < 2_000 ? 30.0 : 40.0
        let minimumTrendGradePercent = 1.0
        let minimumOppositeDifferencePercent = 2.0
        let maximumNoiseRunM: Double = total < 2_000 ? 65.0 : 80.0

        var suspicious = Array(repeating: false, count: cleaned.count)

        for i in cleaned.indices {
            let d = cleaned[i].distanceM
            let localGrade = centeredGrade(in: cleaned, at: d, windowM: localGradeWindowM)
            let trendGrade = centeredGrade(in: trend, at: d, windowM: broadWindowM)

            // Only reject a reversal if the broad trend itself is clear.
            // A flat/rolling road is allowed to change sign naturally.
            if abs(trendGrade) >= minimumTrendGradePercent,
               localGrade * trendGrade < 0,
               abs(localGrade - trendGrade) >= minimumOppositeDifferencePercent {
                suspicious[i] = true
            }
        }

        // Group contiguous suspicious points. A short opposite-sign run is
        // probably a false dip/bump; a long run is preserved as a real feature.
        var i = 0
        while i < suspicious.count {
            guard suspicious[i] else {
                i += 1
                continue
            }

            let runStart = i
            var runEnd = i
            while runEnd + 1 < suspicious.count, suspicious[runEnd + 1] {
                runEnd += 1
            }

            let runLengthM = cleaned[runEnd].distanceM - cleaned[runStart].distanceM

            if runLengthM <= maximumNoiseRunM {
                let leftIndex = max(0, runStart - 1)
                let rightIndex = min(cleaned.count - 1, runEnd + 1)

                if rightIndex > leftIndex {
                    let left = cleaned[leftIndex]
                    let right = cleaned[rightIndex]
                    let span = max(0.001, right.distanceM - left.distanceM)

                    if rightIndex - leftIndex >= 2 {
                        for j in (leftIndex + 1)..<rightIndex {
                            let t = (cleaned[j].distanceM - left.distanceM) / span
                            cleaned[j] = RoutePoint(
                                distanceM: cleaned[j].distanceM,
                                elevationM: left.elevationM + (right.elevationM - left.elevationM) * t,
                                latitude: cleaned[j].latitude,
                                longitude: cleaned[j].longitude
                            )
                        }
                    }
                }
            }

            i = runEnd + 1
        }

        // Very light final pass to avoid a visible kink at repaired boundaries.
        var out = localLinearElevationSmooth(cleaned, radiusM: 10.0)

        // Preserve exact route endpoints and therefore exact net elevation change.
        if !out.isEmpty {
            out[0] = RoutePoint(
                distanceM: out[0].distanceM,
                elevationM: source[0].elevationM,
                latitude: out[0].latitude,
                longitude: out[0].longitude
            )
            let k = out.count - 1
            out[k] = RoutePoint(
                distanceM: out[k].distanceM,
                elevationM: source[k].elevationM,
                latitude: out[k].latitude,
                longitude: out[k].longitude
            )
        }

        return out
    }

    /// Weighted local-linear regression of elevation against route distance.
    /// Linear ramps are preserved exactly; only local altitude noise is reduced.
    private func localLinearElevationSmooth(_ source: [RoutePoint], radiusM: Double) -> [RoutePoint] {
        guard source.count >= 3, radiusM > 0 else { return source }

        var out: [RoutePoint] = []
        out.reserveCapacity(source.count)

        var left = 0
        var right = 0

        for i in source.indices {
            let x0 = source[i].distanceM

            while left < i && x0 - source[left].distanceM > radiusM {
                left += 1
            }
            if right < i { right = i }
            while right + 1 < source.count && source[right + 1].distanceM - x0 <= radiusM {
                right += 1
            }

            var sw = 0.0
            var swx = 0.0
            var swy = 0.0
            var swxx = 0.0
            var swxy = 0.0

            if left <= right {
                for j in left...right {
                    let x = source[j].distanceM - x0
                    let distance = abs(x)
                    let w = max(0.05, 1.0 - distance / max(0.001, radiusM))
                    let y = source[j].elevationM

                    sw += w
                    swx += w * x
                    swy += w * y
                    swxx += w * x * x
                    swxy += w * x * y
                }
            }

            let denominator = sw * swxx - swx * swx
            let fittedElevation: Double
            if sw > 0, abs(denominator) > 1e-9 {
                fittedElevation = (swy * swxx - swx * swxy) / denominator
            } else if sw > 0 {
                fittedElevation = swy / sw
            } else {
                fittedElevation = source[i].elevationM
            }

            out.append(
                RoutePoint(
                    distanceM: source[i].distanceM,
                    elevationM: fittedElevation,
                    latitude: source[i].latitude,
                    longitude: source[i].longitude
                )
            )
        }

        return out
    }

    private func centeredGrade(in source: [RoutePoint], at distanceM: Double, windowM: Double) -> Double {
        guard let total = source.last?.distanceM else { return 0 }
        let half = max(5.0, windowM * 0.5)
        let a = max(0.0, distanceM - half)
        let b = min(total, distanceM + half)
        guard b - a >= 2.0 else { return 0 }
        return 100.0 * (elevation(in: source, at: b) - elevation(in: source, at: a)) / (b - a)
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

