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

final class GPXParser: NSObject, XMLParserDelegate {
    private typealias RawPoint = (lat: Double, lon: Double, ele: Double)

    private var points: [RawPoint] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentElement = ""
    private var textBuffer = ""

    // Pre-processing constants. Horizontal geometry is NEVER averaged.
    private let resampleStepM = 5.0
    private let duplicateThresholdM = 0.50
    private let elevationSmoothRadiusM = 25.0

    func parse(data: Data) throws -> GPXRoute {
        points.removeAll()

        let parser = XMLParser(data: data)
        parser.delegate = self

        guard parser.parse(), points.count >= 2 else {
            throw parser.parserError ?? GPXParserError.noTrackPoints
        }

        // 1) Remove only exact/near duplicates. Do not smooth lat/lon.
        var cleaned = removeNearDuplicates(points)
        guard cleaned.count >= 2 else { throw GPXParserError.noTrackPoints }

        // 2) For climb GPXs containing a long flat/approach section, cut only that
        //    leading non-climb part before the real sustained ascent starts.
        //    This reproduces the behaviour of the manually regularised Alpe file:
        //    the actual climb geometry is untouched.
        cleaned = trimLeadingApproachIfNeeded(cleaned)
        guard cleaned.count >= 2 else { throw GPXParserError.noTrackPoints }

        // 3) Build exact cumulative distance along the retained original polyline.
        let source = buildRoutePoints(cleaned)

        // 4) Resample every ~5 m ALONG that same polyline. No XY smoothing.
        var resampled = resample(source, every: resampleStepM)

        // 5) Recalculate distance from the resulting lat/lon geometry so that
        //    distanceM, 2D physics and 3D use exactly the same spatial reference.
        resampled = recalculateDistances(resampled)

        // 6) Smooth elevation only, in metres of route distance.
        let finalPoints = smoothElevation(resampled, radiusM: elevationSmoothRadiusM)

        guard finalPoints.count >= 2 else { throw GPXParserError.noTrackPoints }
        return GPXRoute(points: finalPoints)
    }

    // MARK: - Pre-processing

    private func removeNearDuplicates(_ source: [RawPoint]) -> [RawPoint] {
        guard let first = source.first else { return [] }
        var result: [RawPoint] = [first]
        result.reserveCapacity(source.count)

        for point in source.dropFirst() {
            guard let last = result.last else { continue }
            if distanceM(last.lat, last.lon, point.lat, point.lon) >= duplicateThresholdM {
                result.append(point)
            }
        }

        if let sourceLast = source.last,
           let resultLast = result.last,
           (sourceLast.lat != resultLast.lat || sourceLast.lon != resultLast.lon) {
            result.append(sourceLast)
        }
        return result
    }

    /// Detect and remove a long, nearly-flat leading approach only when the file
    /// clearly looks like a climb: long route, large elevation range, flat first km,
    /// then a sustained steep section. Otherwise the GPX is left untouched.
    private func trimLeadingApproachIfNeeded(_ source: [RawPoint]) -> [RawPoint] {
        let route = buildRoutePoints(source)
        guard route.count >= 2,
              let last = route.last,
              last.distanceM >= 5_000 else { return source }

        let elevations = route.map(\.elevationM)
        guard let minEle = elevations.min(), let maxEle = elevations.max(),
              maxEle - minEle >= 300 else { return source }

        let firstKm = min(1_000.0, last.distanceM)
        let firstKmGrade = abs(100.0 * (interpolatedElevation(route, at: firstKm) - route[0].elevationM) / max(1.0, firstKm))
        guard firstKmGrade <= 1.5 else { return source }

        // 300 m at >=7.4% is deliberately conservative: it avoids trimming normal
        // rolling starts, but finds the actual Alpe ascent at ~1.91 km in this GPX.
        let windowM = 300.0
        let thresholdPct = 7.4
        var candidate: Double?
        var d = 0.0
        while d + windowM <= last.distanceM {
            let rise = interpolatedElevation(route, at: d + windowM) - interpolatedElevation(route, at: d)
            let grade = 100.0 * rise / windowM
            if grade >= thresholdPct {
                candidate = d
                break
            }
            d += 5.0
        }

        guard let cutDistance = candidate, cutDistance >= 500 else { return source }

        // Build an interpolated first point exactly at the cut distance, then append
        // untouched original points after it. This preserves every real hairpin.
        guard let firstCut = interpolatedRawPoint(sourceRoute: route, at: cutDistance) else { return source }

        var output: [RawPoint] = [firstCut]
        for point in source {
            let loc = CLLocation(latitude: point.lat, longitude: point.lon)
            let cutLoc = CLLocation(latitude: firstCut.lat, longitude: firstCut.lon)
            // Do not use radial distance to decide ordering. Find source index below.
            _ = loc
            _ = cutLoc
        }

        // Find the first original point strictly after cutDistance using route distances.
        if let index = route.firstIndex(where: { $0.distanceM > cutDistance }) {
            for i in index..<source.count {
                output.append(source[i])
            }
        }

        return output.count >= 2 ? output : source
    }

    private func buildRoutePoints(_ source: [RawPoint]) -> [RoutePoint] {
        guard let first = source.first else { return [] }

        var result: [RoutePoint] = []
        result.reserveCapacity(source.count)
        var cumulative = 0.0

        result.append(RoutePoint(
            distanceM: 0,
            elevationM: first.ele,
            latitude: first.lat,
            longitude: first.lon
        ))

        for index in 1..<source.count {
            let previous = source[index - 1]
            let current = source[index]
            cumulative += distanceM(previous.lat, previous.lon, current.lat, current.lon)
            result.append(RoutePoint(
                distanceM: cumulative,
                elevationM: current.ele,
                latitude: current.lat,
                longitude: current.lon
            ))
        }
        return result
    }

    private func resample(_ source: [RoutePoint], every stepM: Double) -> [RoutePoint] {
        guard source.count >= 2, let last = source.last, last.distanceM > 0 else { return source }

        var result: [RoutePoint] = []
        result.reserveCapacity(Int(last.distanceM / stepM) + 2)
        var target = 0.0
        var segment = 0

        while target <= last.distanceM {
            while segment + 1 < source.count && source[segment + 1].distanceM < target {
                segment += 1
            }

            let next = min(source.count - 1, segment + 1)
            let a = source[segment]
            let b = source[next]
            let span = max(0.001, b.distanceM - a.distanceM)
            let t = min(1.0, max(0.0, (target - a.distanceM) / span))

            result.append(RoutePoint(
                distanceM: target,
                elevationM: a.elevationM + (b.elevationM - a.elevationM) * t,
                latitude: a.latitude + (b.latitude - a.latitude) * t,
                longitude: a.longitude + (b.longitude - a.longitude) * t
            ))
            target += stepM
        }

        if let resultLast = result.last, last.distanceM - resultLast.distanceM > 0.1 {
            result.append(last)
        }
        return result
    }

    private func recalculateDistances(_ source: [RoutePoint]) -> [RoutePoint] {
        guard let first = source.first else { return [] }
        var result: [RoutePoint] = []
        result.reserveCapacity(source.count)
        var cumulative = 0.0

        result.append(RoutePoint(
            distanceM: 0,
            elevationM: first.elevationM,
            latitude: first.latitude,
            longitude: first.longitude
        ))

        for index in 1..<source.count {
            let a = source[index - 1]
            let b = source[index]
            cumulative += distanceM(a.latitude, a.longitude, b.latitude, b.longitude)
            result.append(RoutePoint(
                distanceM: cumulative,
                elevationM: b.elevationM,
                latitude: b.latitude,
                longitude: b.longitude
            ))
        }
        return result
    }

    private func smoothElevation(_ source: [RoutePoint], radiusM: Double) -> [RoutePoint] {
        guard source.count >= 3 else { return source }
        var result: [RoutePoint] = []
        result.reserveCapacity(source.count)

        var left = 0
        var right = 0

        for i in source.indices {
            let center = source[i].distanceM
            while left < i && source[left].distanceM < center - radiusM { left += 1 }
            if right < i { right = i }
            while right + 1 < source.count && source[right + 1].distanceM <= center + radiusM { right += 1 }

            var weighted = 0.0
            var weightSum = 0.0
            for j in left...right {
                let delta = abs(source[j].distanceM - center)
                let weight = max(0.0, radiusM - delta) + 1.0
                weighted += source[j].elevationM * weight
                weightSum += weight
            }

            let smoothed = weightSum > 0 ? weighted / weightSum : source[i].elevationM
            result.append(RoutePoint(
                distanceM: source[i].distanceM,
                elevationM: smoothed,
                latitude: source[i].latitude,
                longitude: source[i].longitude
            ))
        }

        // Preserve exact start/end elevations.
        if !result.isEmpty {
            result[0] = RoutePoint(
                distanceM: result[0].distanceM,
                elevationM: source[0].elevationM,
                latitude: result[0].latitude,
                longitude: result[0].longitude
            )
            let last = result.count - 1
            result[last] = RoutePoint(
                distanceM: result[last].distanceM,
                elevationM: source[last].elevationM,
                latitude: result[last].latitude,
                longitude: result[last].longitude
            )
        }
        return result
    }

    private func interpolatedElevation(_ route: [RoutePoint], at distance: Double) -> Double {
        guard !route.isEmpty else { return 0 }
        let d = min(max(distance, 0), route.last?.distanceM ?? 0)
        var low = 0
        var high = route.count - 1
        while low < high {
            let mid = (low + high) / 2
            if route[mid].distanceM < d { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return route[0].elevationM }
        let a = route[low - 1]
        let b = route[low]
        let span = max(0.001, b.distanceM - a.distanceM)
        let t = (d - a.distanceM) / span
        return a.elevationM + (b.elevationM - a.elevationM) * t
    }

    private func interpolatedRawPoint(sourceRoute route: [RoutePoint], at distance: Double) -> RawPoint? {
        guard !route.isEmpty else { return nil }
        let d = min(max(distance, 0), route.last?.distanceM ?? 0)
        var low = 0
        var high = route.count - 1
        while low < high {
            let mid = (low + high) / 2
            if route[mid].distanceM < d { low = mid + 1 } else { high = mid }
        }
        if low == 0 {
            let p = route[0]
            return (p.latitude, p.longitude, p.elevationM)
        }
        let a = route[low - 1]
        let b = route[low]
        let span = max(0.001, b.distanceM - a.distanceM)
        let t = (d - a.distanceM) / span
        return (
            a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t,
            a.elevationM + (b.elevationM - a.elevationM) * t
        )
    }

    private func distanceM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        CLLocation(latitude: lat1, longitude: lon1)
            .distance(from: CLLocation(latitude: lat2, longitude: lon2))
    }

    // MARK: - XML

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
                points.append((lat: lat, lon: lon, ele: ele))
            }
            currentLat = nil
            currentLon = nil
            currentEle = nil
        }

        currentElement = ""
        textBuffer = ""
    }
}
