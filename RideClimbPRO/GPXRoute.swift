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

    /// Normalizes imported GPX tracks before they are used by both RideModel and 3D.
    ///
    /// Rules:
    /// - resample along the original polyline every 5 m;
    /// - never smooth latitude/longitude, so hairpins are not cut;
    /// - smooth elevation only, using a centered 25 m window;
    /// - preserve the exact first/last elevations and route endpoints.
    private func preprocess(_ source: [RoutePoint]) -> [RoutePoint] {
        let cleaned = removeNearDuplicates(source, minimumSpacingM: 0.5)
        guard cleaned.count >= 2 else { return cleaned }

        let resampled = resample(cleaned, stepM: 5.0)
        return smoothElevation(resampled, radiusM: 25.0)
    }

    private func removeNearDuplicates(
        _ source: [RoutePoint],
        minimumSpacingM: Double
    ) -> [RoutePoint] {
        guard let first = source.first else { return [] }

        var result: [RoutePoint] = [first]
        result.reserveCapacity(source.count)

        for point in source.dropFirst() {
            guard let last = result.last else { continue }
            if point.distanceM - last.distanceM >= minimumSpacingM {
                result.append(point)
            }
        }

        if let sourceLast = source.last,
           let resultLast = result.last,
           sourceLast.distanceM > resultLast.distanceM {
            result.append(sourceLast)
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

    private func smoothElevation(_ source: [RoutePoint], radiusM: Double) -> [RoutePoint] {
        guard source.count >= 3, radiusM > 0 else { return source }

        var result: [RoutePoint] = []
        result.reserveCapacity(source.count)

        var left = 0
        var right = 0
        var elevationSum = 0.0

        for index in source.indices {
            let centerDistance = source[index].distanceM
            let minDistance = centerDistance - radiusM
            let maxDistance = centerDistance + radiusM

            while right < source.count && source[right].distanceM <= maxDistance {
                elevationSum += source[right].elevationM
                right += 1
            }

            while left < right && source[left].distanceM < minDistance {
                elevationSum -= source[left].elevationM
                left += 1
            }

            let count = max(1, right - left)
            let smoothedElevation: Double

            if index == source.startIndex || index == source.index(before: source.endIndex) {
                smoothedElevation = source[index].elevationM
            } else {
                smoothedElevation = elevationSum / Double(count)
            }

            result.append(
                RoutePoint(
                    distanceM: source[index].distanceM,
                    elevationM: smoothedElevation,
                    latitude: source[index].latitude,
                    longitude: source[index].longitude
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
