import Foundation
import CoreLocation

struct RoutePoint {
    let distanceM: Double
    let elevationM: Double
    let latitude: Double
    let longitude: Double
}

struct RouteGradeWarning: Identifiable {
    let id = UUID()
    let distanceM: Double
    let gradePercent: Double
    let windowM: Double
}

struct GPXRoute {
    let points: [RoutePoint]

    var totalDistanceM: Double { points.last?.distanceM ?? 0 }

    func terrainLookAheadM(maximum: Double = 150.0) -> Double {
        min(maximum, totalDistanceM / 20.0)
    }

    func terrainGrade(at distanceM: Double, maximumLookAheadM: Double = 150.0) -> Double {
        forwardGrade(at: distanceM, lookAheadM: terrainLookAheadM(maximum: maximumLookAheadM))
    }

    func elevation(at distanceM: Double) -> Double {
        guard !points.isEmpty else { return 0 }
        let d = min(max(distanceM, 0), totalDistanceM)

        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].distanceM < d { low = mid + 1 } else { high = mid }
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

    /// Diagnostic only. It never changes GPX elevation or trainer behaviour.
    /// A 50 m window avoids flagging harmless single-point elevation quantisation.
    func suspiciousGradeSegments(
        windowM: Double = 50,
        sampleStepM: Double = 25,
        uphillLimitPercent: Double = 25,
        downhillLimitPercent: Double = -8
    ) -> [RouteGradeWarning] {
        guard totalDistanceM > windowM else { return [] }
        var result: [RouteGradeWarning] = []
        var d = windowM / 2
        while d <= totalDistanceM - windowM / 2 {
            let g = grade(at: d, windowM: windowM)
            if g > uphillLimitPercent || g < downhillLimitPercent {
                result.append(RouteGradeWarning(distanceM: d, gradePercent: g, windowM: windowM))
            }
            d += max(10, sampleStepM)
        }
        return result
    }
}

enum GPXParserError: LocalizedError {
    case noTrackPoints

    var errorDescription: String? {
        switch self {
        case .noTrackPoints: return "No usable GPX track points with elevation were found."
        }
    }
}

/// Planned-GPX parser for RideClimbPRO.
/// Source of truth = the GPX polyline itself. No GPXtruder-style smoothing,
/// no route simplification and no automatic elevation repair are applied.
final class GPXParser: NSObject, XMLParserDelegate {
    private var rawPoints: [(lat: Double, lon: Double, ele: Double)] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double?
    private var textBuffer = ""

    func parse(data: Data) throws -> GPXRoute {
        rawPoints.removeAll(keepingCapacity: true)
        currentLat = nil
        currentLon = nil
        currentEle = nil
        textBuffer = ""

        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), rawPoints.count >= 2 else {
            throw parser.parserError ?? GPXParserError.noTrackPoints
        }

        var routePoints: [RoutePoint] = []
        routePoints.reserveCapacity(rawPoints.count)
        var cumulative = 0.0

        let first = rawPoints[0]
        routePoints.append(RoutePoint(distanceM: 0, elevationM: first.ele, latitude: first.lat, longitude: first.lon))

        for i in 1..<rawPoints.count {
            let previous = rawPoints[i - 1]
            let current = rawPoints[i]
            let segmentM = geographicDistanceM(
                lat1: previous.lat, lon1: previous.lon,
                lat2: current.lat, lon2: current.lon
            )

            // Ignore only true/near duplicate coordinates. This is not smoothing.
            guard segmentM >= 0.20 else { continue }
            cumulative += segmentM
            routePoints.append(RoutePoint(
                distanceM: cumulative,
                elevationM: current.ele,
                latitude: current.lat,
                longitude: current.lon
            ))
        }

        guard routePoints.count >= 2 else { throw GPXParserError.noTrackPoints }
        return GPXRoute(points: routePoints)
    }

    private func geographicDistanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        CLLocation(latitude: lat1, longitude: lon1)
            .distance(from: CLLocation(latitude: lat2, longitude: lon2))
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
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
            if let lat = currentLat, let lon = currentLon, let ele = currentEle {
                rawPoints.append((lat, lon, ele))
            }
            currentLat = nil
            currentLon = nil
            currentEle = nil
        }
        textBuffer = ""
    }
}
