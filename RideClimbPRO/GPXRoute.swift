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

/// GPXtruder-style preprocessing:
/// - keep the GPX as the source of truth for latitude, longitude and elevation;
/// - remove points that are closer than an automatically chosen minimum interval;
/// - choose that interval from route map extent / virtual model scale, following
///   GPXtruder's automatic smoothing principle;
/// - ALWAYS keep the true final GPX point;
/// - preserve each retained point's original cumulative route distance, so the
///   total RideClimb route length remains the original GPX length.
///
/// GPXtruder itself notes that its filtered geometric polyline becomes slightly
/// shorter because discarded points straighten the path. RideClimb instead keeps
/// the original cumulative distance axis because that distance is also used by
/// the trainer and ride simulation.
final class GPXParser: NSObject, XMLParserDelegate {
    private struct RawPoint {
        let lat: Double
        let lon: Double
        let ele: Double
        let originalDistanceM: Double
    }

    private var points: [(lat: Double, lon: Double, ele: Double)] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var currentElement = ""
    private var textBuffer = ""

    // Equivalent conceptual defaults to GPXtruder's Map model:
    // a ~200 x 200 mm virtual bed and a 2 mm wide printed route.
    // GPXtruder uses half the path width as "buffer", then:
    // smoothingDistance = floor(buffer / mapScale).
    private let virtualBedWidthMM = 200.0
    private let virtualBedHeightMM = 200.0
    private let virtualPathWidthMM = 2.0

    // Safety bounds: prevent pathological GPX extents from producing either
    // effectively no smoothing or excessive loss of genuine hairpin geometry.
    private let minimumAutomaticIntervalM = 5.0
    private let maximumAutomaticIntervalM = 35.0

    func parse(data: Data) throws -> GPXRoute {
        points.removeAll()

        let parser = XMLParser(data: data)
        parser.delegate = self

        guard parser.parse(), points.count >= 2 else {
            throw parser.parserError ?? GPXParserError.noTrackPoints
        }

        let raw = buildRawPointsWithOriginalDistance(points)
        guard raw.count >= 2 else {
            throw GPXParserError.noTrackPoints
        }

        let minimumIntervalM = automaticMinimumInterval(for: raw)
        let filtered = minimumDistanceFilter(raw, minimumDistanceM: minimumIntervalM)

        let routePoints = filtered.map {
            RoutePoint(
                distanceM: $0.originalDistanceM,
                elevationM: $0.ele,
                latitude: $0.lat,
                longitude: $0.lon
            )
        }

        return GPXRoute(points: routePoints)
    }

    /// Port of GPXtruder's core smoothing idea:
    /// retain the first point, then only retain a new point when its geographic
    /// distance from the LAST RETAINED point reaches the minimum interval.
    /// The true endpoint is explicitly retained.
    private func minimumDistanceFilter(
        _ source: [RawPoint],
        minimumDistanceM: Double
    ) -> [RawPoint] {
        guard source.count >= 2 else { return source }
        guard minimumDistanceM > 0 else { return source }

        var result: [RawPoint] = []
        result.reserveCapacity(source.count)
        result.append(source[0])

        for point in source.dropFirst() {
            guard let previousKept = result.last else {
                result.append(point)
                continue
            }

            let distance = geographicDistanceM(
                lat1: previousKept.lat,
                lon1: previousKept.lon,
                lat2: point.lat,
                lon2: point.lon
            )

            if distance >= minimumDistanceM {
                result.append(point)
            }
        }

        // GPXtruder's simple filter may omit an endpoint that lies inside the
        // minimum interval. RideClimb needs the exact route finish and exact total
        // distance, so force it back in.
        if let trueEnd = source.last {
            if let currentEnd = result.last {
                if currentEnd.originalDistanceM < trueEnd.originalDistanceM {
                    result.append(trueEnd)
                }
            } else {
                result.append(trueEnd)
            }
        }

        return result.count >= 2 ? result : source
    }

    /// GPXtruder automatic smoothing computes a real-world minimum interval from
    /// the displayed path width divided by map scale. Here we reproduce the same
    /// principle with a fixed virtual 200 mm model bed.
    private func automaticMinimumInterval(for source: [RawPoint]) -> Double {
        guard source.count >= 2 else { return minimumAutomaticIntervalM }

        let meanLatitude =
            source.reduce(0.0) { $0 + $1.lat } / Double(source.count)

        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon =
            metersPerDegreeLat * cos(meanLatitude * .pi / 180.0)

        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for point in source {
            let x = point.lon * metersPerDegreeLon
            let y = point.lat * metersPerDegreeLat
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        let extentX = max(1.0, maxX - minX)
        let extentY = max(1.0, maxY - minY)

        let bufferMM = virtualPathWidthMM / 2.0
        let usableBedX = max(1.0, virtualBedWidthMM - 2.0 * bufferMM)
        let usableBedY = max(1.0, virtualBedHeightMM - 2.0 * bufferMM)

        // mm of model per meter of real route.
        let scaleX = usableBedX / extentX
        let scaleY = usableBedY / extentY
        let mapScale = min(scaleX, scaleY)

        guard mapScale.isFinite, mapScale > 0 else {
            return minimumAutomaticIntervalM
        }

        let gpxtruderStyle = floor(bufferMM / mapScale)

        return min(
            maximumAutomaticIntervalM,
            max(minimumAutomaticIntervalM, gpxtruderStyle)
        )
    }

    private func buildRawPointsWithOriginalDistance(
        _ source: [(lat: Double, lon: Double, ele: Double)]
    ) -> [RawPoint] {
        guard !source.isEmpty else { return [] }

        var result: [RawPoint] = []
        result.reserveCapacity(source.count)

        var cumulative = 0.0
        result.append(
            RawPoint(
                lat: source[0].lat,
                lon: source[0].lon,
                ele: source[0].ele,
                originalDistanceM: 0
            )
        )

        for index in 1..<source.count {
            let previous = source[index - 1]
            let current = source[index]

            cumulative += geographicDistanceM(
                lat1: previous.lat,
                lon1: previous.lon,
                lat2: current.lat,
                lon2: current.lon
            )

            result.append(
                RawPoint(
                    lat: current.lat,
                    lon: current.lon,
                    ele: current.ele,
                    originalDistanceM: cumulative
                )
            )
        }

        return result
    }

    private func geographicDistanceM(
        lat1: Double,
        lon1: Double,
        lat2: Double,
        lon2: Double
    ) -> Double {
        let a = CLLocation(latitude: lat1, longitude: lon1)
        let b = CLLocation(latitude: lat2, longitude: lon2)
        return a.distance(from: b)
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

