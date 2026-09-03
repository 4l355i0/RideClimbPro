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

final class GPXParser: NSObject, XMLParserDelegate {
    private var points: [(lat: Double, lon: Double, ele: Double)] = []
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

        var routePoints: [RoutePoint] = []
        var cumulative = 0.0

        routePoints.append(
            RoutePoint(
                distanceM: 0,
                elevationM: points[0].ele,
                latitude: points[0].lat,
                longitude: points[0].lon
            )
        )

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]

            let a = CLLocation(latitude: previous.lat, longitude: previous.lon)
            let b = CLLocation(latitude: current.lat, longitude: current.lon)

            cumulative += a.distance(from: b)
            routePoints.append(
                RoutePoint(
                    distanceM: cumulative,
                    elevationM: current.ele,
                    latitude: current.lat,
                    longitude: current.lon
                )
            )
        }

        return GPXRoute(points: preprocess(routePoints))
    }

    // MARK: - GPX preprocessing

    /// Geometry-safe preprocessing used by both RideModel and Climb 3D.
    ///
    /// Important invariants:
    /// - the route distance is always recalculated from the coordinates actually kept;
    /// - latitude/longitude are never conventionally smoothed (hairpins are preserved);
    /// - only true near-duplicates / tiny out-and-back GPS spikes are removed;
    /// - the cleaned polyline is resampled at ~5 m;
    /// - elevation only is smoothed over +/-25 m.
    private func preprocess(_ source: [RoutePoint]) -> [RoutePoint] {
        guard source.count >= 2 else { return source }

        let deduplicated = removeNearDuplicateCoordinates(source, minimumSpacingM: 0.75)
        let despiked = removeTinyOutAndBackSpikes(deduplicated)
        let geometryAligned = recalculateDistances(despiked)
        let resampled = resample(geometryAligned, stepM: 5.0)
        let distanceAligned = recalculateDistances(resampled)
        return smoothElevation(distanceAligned, radiusM: 25.0)
    }

    private func horizontalDistanceM(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func removeNearDuplicateCoordinates(
        _ source: [RoutePoint],
        minimumSpacingM: Double
    ) -> [RoutePoint] {
        guard let first = source.first else { return [] }

        var result: [RoutePoint] = [first]
        result.reserveCapacity(source.count)

        for point in source.dropFirst() {
            guard let last = result.last else { continue }
            if horizontalDistanceM(last, point) >= minimumSpacingM {
                result.append(point)
            }
        }

        // Preserve the true final coordinate even when very close to the
        // preceding point.
        if let sourceLast = source.last,
           let resultLast = result.last,
           (sourceLast.latitude != resultLast.latitude ||
            sourceLast.longitude != resultLast.longitude) {
            result.append(sourceLast)
        }

        return result
    }

    /// Remove only very small GPS "hooks": A -> B -> C where B is only a
    /// couple of metres away and C returns almost to A. A genuine hairpin is
    /// much larger, so it is deliberately left untouched.
    private func removeTinyOutAndBackSpikes(_ source: [RoutePoint]) -> [RoutePoint] {
        guard source.count >= 3 else { return source }

        var result: [RoutePoint] = []
        result.reserveCapacity(source.count)
        result.append(source[0])

        var index = 1
        while index < source.count - 1 {
            let a = result.last ?? source[index - 1]
            let b = source[index]
            let c = source[index + 1]

            let ab = horizontalDistanceM(a, b)
            let bc = horizontalDistanceM(b, c)
            let ac = horizontalDistanceM(a, c)

            if ab <= 2.5 && bc <= 2.5 && ac <= 1.5 {
                index += 1
                continue
            }

            result.append(b)
            index += 1
        }

        result.append(source[source.count - 1])
        return result
    }

    private func recalculateDistances(_ source: [RoutePoint]) -> [RoutePoint] {
        guard let first = source.first else { return [] }

        var result: [RoutePoint] = []
        result.reserveCapacity(source.count)
        result.append(
            RoutePoint(
                distanceM: 0,
                elevationM: first.elevationM,
                latitude: first.latitude,
                longitude: first.longitude
            )
        )

        var cumulative = 0.0
        for index in 1..<source.count {
            cumulative += horizontalDistanceM(source[index - 1], source[index])
            let p = source[index]
            result.append(
                RoutePoint(
                    distanceM: cumulative,
                    elevationM: p.elevationM,
                    latitude: p.latitude,
                    longitude: p.longitude
                )
            )
        }

        return result
    }

    private func resample(_ source: [RoutePoint], stepM: Double) -> [RoutePoint] {
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
            while segmentIndex + 1 < source.count &&
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

        // Always append the exact endpoint when the regular grid did not land
        // on it.
        if let resultLast = result.last, total - resultLast.distanceM > 0.1 {
            result.append(
                RoutePoint(
                    distanceM: total,
                    elevationM: last.elevationM,
                    latitude: last.latitude,
                    longitude: last.longitude
                )
            )
        }

        return result
    }

    /// Triangular, distance-domain elevation filter. The horizontal path and
    /// route distances are not modified here.
    private func smoothElevation(_ source: [RoutePoint], radiusM: Double) -> [RoutePoint] {
        guard source.count >= 3, radiusM > 0 else { return source }

        var result: [RoutePoint] = []
        result.reserveCapacity(source.count)

        var left = 0
        var right = 0

        for index in source.indices {
            let center = source[index].distanceM

            while left < index && center - source[left].distanceM > radiusM {
                left += 1
            }
            if right < index { right = index }
            while right + 1 < source.count &&
                    source[right + 1].distanceM - center <= radiusM {
                right += 1
            }

            var weightedElevation = 0.0
            var weightSum = 0.0
            if left <= right {
                for sampleIndex in left...right {
                    let delta = abs(source[sampleIndex].distanceM - center)
                    let weight = max(0.0, 1.0 - delta / radiusM)
                    weightedElevation += source[sampleIndex].elevationM * weight
                    weightSum += weight
                }
            }

            let elevation: Double
            if index == source.startIndex || index == source.index(before: source.endIndex) {
                elevation = source[index].elevationM
            } else if weightSum > 0 {
                elevation = weightedElevation / weightSum
            } else {
                elevation = source[index].elevationM
            }

            let p = source[index]
            result.append(
                RoutePoint(
                    distanceM: p.distanceM,
                    elevationM: elevation,
                    latitude: p.latitude,
                    longitude: p.longitude
                )
            )
        }

        return result
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

        if elementName == "trkpt" {
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
        } else if elementName == "trkpt" {
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
