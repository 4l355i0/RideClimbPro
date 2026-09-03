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

/// Build 42 GPX preprocessing — DEM-backed elevation
///
/// The imported GPX is treated as a GUIDE, not as geometry that must be reproduced
/// point-for-point. The output preserves the real climb structure:
/// - primary climb length
/// - number/order/location of major hairpins
/// - road geometry from the GPX guide
/// - total start/end elevation difference
///
/// It removes the two things that make dirty GPX files look bad in 3D:
/// - irregular point spacing
/// - noisy elevation inside each road section
///
/// Plan-view geometry is kept on the original GPX polyline and resampled at 5 m.
/// Elevation is reconstructed from the EU-DEM 25 m terrain database using
/// latitude/longitude, then aligned to the GPX start/end elevation. The GPX
/// altitude samples are therefore not used to define the local grade profile.
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

        // B42: do not infer the road profile from dirty GPX altitude samples.
        // Reconstruct elevation from a DEM using the cleaned lat/lon geometry.
        // For this test build we use OpenTopoData EU-DEM 25 m (Europe).
        // DEM samples are requested every 10 m, interpolated back onto the 5 m
        // route, and linearly aligned so the original start/end elevations and
        // therefore the net climb remain exact.
        let demBacked = try reconstructElevationFromDEM(resampled)

        return GPXRoute(points: demBacked)
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

    /// Forward grade helper used during preprocessing before a GPXRoute exists.
    private func forwardGrade(in source: [RoutePoint], at distanceM: Double, lookAheadM: Double) -> Double {
        guard source.count >= 2, let last = source.last else { return 0 }

        let start = min(max(distanceM, 0), last.distanceM)
        let end = min(last.distanceM, start + max(0, lookAheadM))
        guard end - start >= 2 else { return 0 }

        let z0 = interpolatedPoint(in: source, at: start).elevationM
        let z1 = interpolatedPoint(in: source, at: end).elevationM
        return 100.0 * (z1 - z0) / (end - start)
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


    // MARK: - B42 DEM-backed elevation

    /// Test implementation using OpenTopoData's public EU-DEM 25 m dataset.
    /// The public endpoint is suitable for testing and has rate limits; a
    /// production build should use a dedicated/paid endpoint or self-hosted DEM.
    private func reconstructElevationFromDEM(_ source: [RoutePoint]) throws -> [RoutePoint] {
        guard source.count >= 2, let last = source.last, last.distanceM > 0 else { return source }

        // Query at the native DEM scale. Asking for 5 m points from a 25 m DEM
        // adds no information and only consumes API quota.
        let demStepM = 10.0
        var samplePoints: [RoutePoint] = []
        var d = 0.0
        while d < last.distanceM {
            samplePoints.append(interpolatedPoint(in: source, at: d))
            d += demStepM
        }
        samplePoints.append(interpolatedPoint(in: source, at: last.distanceM))

        var demElevations: [Double] = []
        demElevations.reserveCapacity(samplePoints.count)

        let batchSize = 100
        var start = 0
        while start < samplePoints.count {
            let end = min(start + batchSize, samplePoints.count)
            let batch = Array(samplePoints[start..<end])
            if start > 0 { Thread.sleep(forTimeInterval: 1.05) } // public API: max 1 request/s
            let values = try fetchEUDEMElevations(batch)
            guard values.count == batch.count else {
                throw NSError(
                    domain: "RideClimb.DEM",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "DEM returned an incomplete elevation batch"]
                )
            }
            demElevations.append(contentsOf: values)
            start = end
        }

        guard demElevations.count == samplePoints.count else {
            throw NSError(
                domain: "RideClimb.DEM",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "DEM elevation count mismatch"]
            )
        }

        // A tiny 3-sample median suppresses isolated raster/cell artefacts without
        // flattening sustained changes of slope. At 10 m spacing it sees ~30 m.
        let cleanDEM = median3(demElevations)

        // Interpolate DEM elevations onto every 5 m route point.
        var out: [RoutePoint] = []
        out.reserveCapacity(source.count)
        var j = 0
        for p in source {
            while j + 1 < samplePoints.count && samplePoints[j + 1].distanceM < p.distanceM {
                j += 1
            }

            let z: Double
            if j + 1 >= samplePoints.count {
                z = cleanDEM.last ?? p.elevationM
            } else {
                let a = samplePoints[j]
                let b = samplePoints[j + 1]
                let span = max(0.001, b.distanceM - a.distanceM)
                let t = min(1.0, max(0.0, (p.distanceM - a.distanceM) / span))
                z = cleanDEM[j] + (cleanDEM[j + 1] - cleanDEM[j]) * t
            }

            out.append(RoutePoint(
                distanceM: p.distanceM,
                elevationM: z,
                latitude: p.latitude,
                longitude: p.longitude
            ))
        }

        // DEM absolute datum/road-vs-terrain offsets can differ by several metres.
        // Preserve the GPX's trusted boundary conditions and net elevation change
        // without reintroducing any of its local noisy altitude samples.
        guard let outLast = out.last else { return source }
        let startError = source[0].elevationM - out[0].elevationM
        let endError = source[source.count - 1].elevationM - outLast.elevationM
        let span = max(1.0, last.distanceM)

        for i in out.indices {
            let t = out[i].distanceM / span
            let correction = startError + (endError - startError) * t
            out[i] = RoutePoint(
                distanceM: out[i].distanceM,
                elevationM: out[i].elevationM + correction,
                latitude: out[i].latitude,
                longitude: out[i].longitude
            )
        }

        return out
    }

    private func fetchEUDEMElevations(_ points: [RoutePoint]) throws -> [Double] {
        guard !points.isEmpty else { return [] }

        let locations = points.map {
            String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), $0.latitude, $0.longitude)
        }.joined(separator: "|")

        var components = URLComponents(string: "https://api.opentopodata.org/v1/eudem25m")!
        components.queryItems = [
            URLQueryItem(name: "locations", value: locations),
            URLQueryItem(name: "interpolation", value: "cubic")
        ]

        guard let url = components.url else {
            throw NSError(domain: "RideClimb.DEM", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid DEM request URL"])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("RideClimbPRO/1.0", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var statusCode: Int?

        URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            statusCode = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }.resume()

        let wait = semaphore.wait(timeout: .now() + 25)
        if wait == .timedOut {
            throw NSError(domain: "RideClimb.DEM", code: 5, userInfo: [NSLocalizedDescriptionKey: "DEM request timed out"])
        }
        if let responseError { throw responseError }
        guard statusCode == 200, let data = responseData else {
            throw NSError(
                domain: "RideClimb.DEM",
                code: statusCode ?? 6,
                userInfo: [NSLocalizedDescriptionKey: "DEM service unavailable (HTTP \(statusCode ?? 0))"]
            )
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["status"] as? String, status == "OK",
              let results = root["results"] as? [[String: Any]] else {
            throw NSError(domain: "RideClimb.DEM", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid DEM response"])
        }

        var values: [Double] = []
        values.reserveCapacity(results.count)
        for item in results {
            guard let elevation = item["elevation"] as? NSNumber else {
                throw NSError(domain: "RideClimb.DEM", code: 8, userInfo: [NSLocalizedDescriptionKey: "DEM has no elevation for part of this route"])
            }
            values.append(elevation.doubleValue)
        }
        return values
    }

    private func median3(_ values: [Double]) -> [Double] {
        guard values.count >= 3 else { return values }
        var out = values
        for i in 1..<(values.count - 1) {
            let trio = [values[i - 1], values[i], values[i + 1]].sorted()
            out[i] = trio[1]
        }
        return out
    }

    // MARK: - Elevation regularization: robust median + Savitzky-Golay style fit

    /// B40: robust spatial altitude filtering based on two standard ideas:
    /// 1) a short median filter removes isolated altitude outliers without being
    ///    pulled by the outlier itself;
    /// 2) a local quadratic least-squares fit (Savitzky-Golay style) smooths the
    ///    altitude profile while preserving real ramps and gradual changes of grade.
    ///
    /// IMPORTANT: all windows are expressed in metres because GPX sampling is
    /// irregular before the 5 m resampling step. Geometry (lat/lon) is untouched.
    /// No hairpin is used as an elevation anchor.
    private func regularizeElevationMedianSavitzkyGolay(_ source: [RoutePoint]) -> [RoutePoint] {
        guard source.count >= 7, let last = source.last else { return source }

        let total = last.distanceM

        // Short robust despiking. At 5 m output spacing this corresponds to
        // roughly 25-35 m of road. It removes one/two-sample altitude glitches
        // but cannot flatten a sustained real ramp.
        let medianRadiusM: Double = total < 2_000 ? 12.5 : 15.0
        let despiked = spatialMedianElevation(source, radiusM: medianRadiusM)

        // Local polynomial smoothing. The window is deliberately much shorter
        // than the 200-300 m trend filter rejected in B39: real changes of grade
        // must survive. Quadratic local regression is the continuous/spatial
        // equivalent of a Savitzky-Golay smoother on our regular 5 m samples.
        let sgRadiusM: Double
        if total < 2_000 {
            sgRadiusM = 20.0       // ~40 m full window
        } else if total < 6_000 {
            sgRadiusM = 25.0       // ~50 m full window
        } else {
            sgRadiusM = 30.0       // ~60 m full window
        }

        var smoothed = localQuadraticElevationSmooth(despiked, radiusM: sgRadiusM)

        // Do NOT hard-reset the first/last sample: that creates an artificial
        // cliff at the boundary and can produce a false negative/positive grade.
        // Instead apply a tiny linear correction across the whole route so both
        // endpoints (and therefore the net elevation change) are exact.
        guard let smoothLast = smoothed.last else { return source }
        let startError = source[0].elevationM - smoothed[0].elevationM
        let endError = source[source.count - 1].elevationM - smoothLast.elevationM
        let span = max(1.0, total)

        for i in smoothed.indices {
            let t = smoothed[i].distanceM / span
            let correction = startError + (endError - startError) * t
            smoothed[i] = RoutePoint(
                distanceM: smoothed[i].distanceM,
                elevationM: smoothed[i].elevationM + correction,
                latitude: smoothed[i].latitude,
                longitude: smoothed[i].longitude
            )
        }

        return smoothed
    }

    /// Median of altitude values inside a spatial window. Median is robust to
    /// isolated GPS/barometric spikes and does not create overshoot.
    private func spatialMedianElevation(_ source: [RoutePoint], radiusM: Double) -> [RoutePoint] {
        guard source.count >= 3, radiusM > 0 else { return source }

        var out: [RoutePoint] = []
        out.reserveCapacity(source.count)
        var left = 0
        var right = 0

        for i in source.indices {
            let x0 = source[i].distanceM
            while left < i && x0 - source[left].distanceM > radiusM { left += 1 }
            if right < i { right = i }
            while right + 1 < source.count && source[right + 1].distanceM - x0 <= radiusM { right += 1 }

            var values: [Double] = []
            values.reserveCapacity(right - left + 1)
            if left <= right {
                for j in left...right { values.append(source[j].elevationM) }
            }
            values.sort()
            let m: Double
            if values.isEmpty {
                m = source[i].elevationM
            } else if values.count % 2 == 1 {
                m = values[values.count / 2]
            } else {
                let k = values.count / 2
                m = 0.5 * (values[k - 1] + values[k])
            }

            out.append(RoutePoint(
                distanceM: source[i].distanceM,
                elevationM: m,
                latitude: source[i].latitude,
                longitude: source[i].longitude
            ))
        }
        return out
    }

    /// Local quadratic least-squares fit of elevation versus distance.
    /// This is Savitzky-Golay style smoothing expressed directly in metres,
    /// avoiding assumptions about the original GPX sample interval.
    private func localQuadraticElevationSmooth(_ source: [RoutePoint], radiusM: Double) -> [RoutePoint] {
        guard source.count >= 5, radiusM > 0 else { return source }

        var out: [RoutePoint] = []
        out.reserveCapacity(source.count)
        var left = 0
        var right = 0

        for i in source.indices {
            let x0 = source[i].distanceM
            while left < i && x0 - source[left].distanceM > radiusM { left += 1 }
            if right < i { right = i }
            while right + 1 < source.count && source[right + 1].distanceM - x0 <= radiusM { right += 1 }

            // Weighted normal equations for y = a + b*x + c*x^2, with x local
            // to the target sample. The desired fitted elevation is simply a.
            var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
            var t0 = 0.0, t1 = 0.0, t2 = 0.0

            if left <= right {
                for j in left...right {
                    let x = source[j].distanceM - x0
                    let u = abs(x) / max(0.001, radiusM)
                    // Tri-cube weight: smooth at the edge, high weight near centre.
                    let q = max(0.0, 1.0 - u * u * u)
                    let w = max(0.001, q * q * q)
                    let x2 = x * x
                    let y = source[j].elevationM

                    s0 += w
                    s1 += w * x
                    s2 += w * x2
                    s3 += w * x2 * x
                    s4 += w * x2 * x2
                    t0 += w * y
                    t1 += w * x * y
                    t2 += w * x2 * y
                }
            }

            // Solve the symmetric 3x3 normal system with Gaussian elimination.
            var a = [[s0, s1, s2, t0],
                     [s1, s2, s3, t1],
                     [s2, s3, s4, t2]]
            var ok = true
            for col in 0..<3 {
                var pivot = col
                for r in (col + 1)..<3 where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
                if abs(a[pivot][col]) < 1e-10 { ok = false; break }
                if pivot != col { a.swapAt(pivot, col) }
                let p = a[col][col]
                for c in col..<4 { a[col][c] /= p }
                for r in 0..<3 where r != col {
                    let f = a[r][col]
                    for c in col..<4 { a[r][c] -= f * a[col][c] }
                }
            }

            let fitted = ok ? a[0][3] : source[i].elevationM
            out.append(RoutePoint(
                distanceM: source[i].distanceM,
                elevationM: fitted,
                latitude: source[i].latitude,
                longitude: source[i].longitude
            ))
        }
        return out
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

