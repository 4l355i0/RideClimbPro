import Foundation
import Combine

@MainActor
final class RideModel: ObservableObject {
    // MARK: - Persistent configuration
    @Published var riderWeightKg: Double { didSet { save() } }
    @Published var bikeWeightKg: Double { didSet { save() } }
    @Published var ftpW: Int { didSet { save() } }
    @Published var maxHR: Int { didSet { save() } }
    @Published var wheelCircumferenceM: Double { didSet { save() } }
    @Published var crr: Double { didSet { save() } }
    @Published var cda: Double { didSet { save() } }
    @Published var airDensity: Double { didSet { save() } }
    @Published var drivetrainEfficiency: Double { didSet { save() } }
    @Published var frontChainring: Int { didSet { save() } }
    @Published var cassette: [Int] { didSet { normalizeGearIndex(); save() } }
    @Published var rearIndex: Int { didSet { save() } }

    // MARK: - Session state
    @Published var route: GPXRoute?
    @Published var routeName: String?
    @Published var distanceM: Double = 0
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var status: String = "No route loaded"
    @Published var isRiding = false
    @Published var currentGradePercent: Double = 0
    @Published var currentElevationM: Double = 0
    @Published var virtualSpeedKPH: Double = 0
    @Published var targetPowerW: Int = 0
    @Published var targetResistancePercent: Double = 0
    @Published var rawGradePercent: Double = 0
    @Published var smoothedGradePercent: Double = 0
    @Published var logSampleCount: Int = 0

    private let defaults = UserDefaults.standard
    private let key = "RideClimb.PersistentConfig.v2"
    private var isLoading = true
    private var lastTick: Date?
    private var lastGearSignature: String?
    private var resistanceRampFrom: Double?
    private var resistanceRampTo: Double?
    private var resistanceRampStartedAt: Date?
    private var resistanceRampDurationS: Double = 0.6
    private var sessionLog: [SessionSample] = []

    // Terrain response / smoothing
    private let maxGradeLookAheadM: Double = 150.0
    private let minResistanceRampDurationS: Double = 0.6
    private let maxResistanceRampDurationS: Double = 3.0
    private let rampSecondsPerResistancePoint: Double = 0.045

    // RideControl-calibrated resistance baseline
    private let flatResistancePercent: Double = 12.0
    private let resistancePointsPerGradePercent: Double = 2.25
    private let hardGearResistanceFloorFactor: Double = 18.5

    struct SessionSample {
        let timestamp: Date
        let elapsedSeconds: TimeInterval
        let distanceM: Double
        let rawGradePercent: Double
        let smoothedGradePercent: Double
        let elevationM: Double
        let frontTeeth: Int
        let rearTeeth: Int
        let gearRatio: Double
        let cadenceRPM: Double
        let virtualSpeedKPH: Double
        let targetPowerW: Int
        let targetResistancePercent: Double
        let actualPowerW: Int
        let trainerSpeedKPH: Double
    }

    private struct PersistentConfig: Codable {
        var riderWeightKg: Double
        var bikeWeightKg: Double
        var ftpW: Int
        var maxHR: Int
        var wheelCircumferenceM: Double
        var crr: Double
        var cda: Double
        var airDensity: Double
        var drivetrainEfficiency: Double
        var frontChainring: Int
        var cassette: [Int]
        var rearIndex: Int
    }

    init() {
        riderWeightKg = 75
        bikeWeightKg = 9
        ftpW = 180
        maxHR = 190
        wheelCircumferenceM = 2.10
        crr = 0.005
        cda = 0.40
        airDensity = 1.225
        drivetrainEfficiency = 0.97
        frontChainring = 40
        cassette = [10,12,14,16,18,21,24,28,33,39,45,51]
        rearIndex = 7

        if let data = defaults.data(forKey: key),
           let cfg = try? JSONDecoder().decode(PersistentConfig.self, from: data) {
            riderWeightKg = cfg.riderWeightKg
            bikeWeightKg = cfg.bikeWeightKg
            ftpW = cfg.ftpW
            maxHR = cfg.maxHR
            wheelCircumferenceM = cfg.wheelCircumferenceM
            crr = cfg.crr
            cda = cfg.cda
            airDensity = cfg.airDensity
            drivetrainEfficiency = cfg.drivetrainEfficiency
            frontChainring = cfg.frontChainring
            cassette = cfg.cassette.isEmpty ? cassette : cfg.cassette
            rearIndex = cfg.rearIndex
        }
        normalizeGearIndex()
        isLoading = false
    }

    struct DrivetrainSnapshot {
        let frontTeeth: Int
        let rearTeeth: [Int]
    }

    var drivetrain: DrivetrainSnapshot {
        DrivetrainSnapshot(frontTeeth: frontChainring, rearTeeth: cassette)
    }

    var rearSprocket: Int {
        guard !cassette.isEmpty else { return 0 }
        return cassette[max(0, min(rearIndex, cassette.count - 1))]
    }

    var gearRatio: Double {
        guard rearSprocket > 0 else { return 0 }
        return Double(frontChainring) / Double(rearSprocket)
    }

    var currentGearLabel: String { "\(frontChainring)×\(rearSprocket)" }
    var currentRatio: Double { gearRatio }
    var totalMassKg: Double { riderWeightKg + bikeWeightKg }

    var progress: Double {
        guard let route, route.totalDistanceM > 0 else { return 0 }
        return min(1, distanceM / route.totalDistanceM)
    }

    var remainingDistanceM: Double {
        guard let route else { return 0 }
        return max(0, route.totalDistanceM - distanceM)
    }

    func loadGPX(url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let parsed = try GPXParser().parse(data: data)
        route = parsed
        routeName = url.deletingPathExtension().lastPathComponent
        distanceM = 0
        elapsedSeconds = 0
        currentElevationM = parsed.elevation(at: 0)
        rawGradePercent = parsed.grade(at: 0, windowM: 10)
        // Grade must represent the rider's CURRENT position.
        // Do not use forward look-ahead here: it anticipates GPX transitions.
        smoothedGradePercent = rawGradePercent
        currentGradePercent = rawGradePercent
        resistanceRampFrom = nil
        resistanceRampTo = nil
        resistanceRampStartedAt = nil
        lastGearSignature = currentGearLabel
        virtualSpeedKPH = 0
        targetPowerW = 0
        isRiding = false
        lastTick = nil
        clearSessionLog()
        status = String(format: "Loaded %@ — %.1f km", routeName ?? "route", parsed.totalDistanceM / 1000)
    }

    func startRide() {
        guard route != nil else { status = "Import a GPX first"; return }
        isRiding = true
        lastTick = Date()
        status = "Ride running"
    }

    func pauseRide() {
        isRiding = false
        lastTick = nil
        status = "Ride paused"
    }

    func resetSession() {
        isRiding = false
        lastTick = nil
        distanceM = 0
        elapsedSeconds = 0
        virtualSpeedKPH = 0
        targetPowerW = 0
        if let route {
            currentElevationM = route.elevation(at: 0)
            rawGradePercent = route.grade(at: 0, windowM: 10)
            // Keep displayed/commanded grade spatially aligned with distance.
            smoothedGradePercent = rawGradePercent
            currentGradePercent = rawGradePercent
            resistanceRampFrom = nil
            resistanceRampTo = nil
            resistanceRampStartedAt = nil
            lastGearSignature = currentGearLabel
            status = "Route reset"
        } else {
            currentElevationM = 0
            currentGradePercent = 0
            status = "No route loaded"
        }
    }

    // MARK: - Physics
    private func terrainLookAheadM(for route: GPXRoute) -> Double {
        // Same spatial principle used by RideControl: up to 150 m,
        // reduced for very short courses (course distance / 20).
        return min(maxGradeLookAheadM, route.totalDistanceM / 20.0)
    }

    private func smoothstep(_ progress: Double) -> Double {
        let t = min(1.0, max(0.0, progress))
        return t * t * (3.0 - 2.0 * t)
    }

    private func rampDurationSeconds(from: Double, to: Double) -> Double {
        return min(maxResistanceRampDurationS,
                   max(minResistanceRampDurationS,
                       abs(to - from) * rampSecondsPerResistancePoint))
    }

    private func currentRampedResistance(at now: Date) -> Double? {
        guard let from = resistanceRampFrom,
              let to = resistanceRampTo,
              let started = resistanceRampStartedAt else { return nil }

        let duration = max(0.001, resistanceRampDurationS)
        let progress = now.timeIntervalSince(started) / duration
        if progress >= 1 { return to }
        return from + (to - from) * smoothstep(progress)
    }

    private var neutralGearRatio: Double {
        guard !cassette.isEmpty else { return max(gearRatio, 1.0) }
        let middle = cassette[cassette.count / 2]
        return Double(frontChainring) / Double(middle)
    }

    func resistanceForCurrentState(gradePercent: Double) -> Double {
        // RideControl-calibrated terrain load curve.
        let terrain = min(55.0, max(4.0,
            flatResistancePercent + gradePercent * resistancePointsPerGradePercent))

        // Virtual gearing around the neutral ratio.
        let neutral = max(0.1, neutralGearRatio)
        let relativeRatio = max(0.1, gearRatio) / neutral
        let gearFactor = pow(relativeRatio, 2.0)

        // System-mass scaling around the 90 kg reference used by our app.
        let massFactor = max(0.25, min(5.0, totalMassKg / 90.0))

        var result = terrain * gearFactor * massFactor

        // RideControl-style minimum load in harder-than-neutral gears.
        // This prevents a hard virtual gear from becoming unrealistically light
        // on descents or low-terrain-load sections.
        if gearFactor > 1.0 {
            let floor = (gearFactor - 1.0) * hardGearResistanceFloorFactor
            result = max(result, floor)
        }

        return min(100.0, max(0.0, result))
    }

    func speedKPH(from cadenceRPM: Double) -> Double {
        guard cadenceRPM > 0, gearRatio > 0, wheelCircumferenceM > 0 else { return 0 }
        return cadenceRPM * gearRatio * wheelCircumferenceM * 60.0 / 1000.0
    }

    func physicalPowerW(gradePercent: Double, speedKPH: Double) -> Double {
        let g = 9.81
        let v = max(0, speedKPH) / 3.6
        guard v > 0 else { return 0 }

        let theta = atan(gradePercent / 100.0)
        let mass = totalMassKg

        let gravity = mass * g * sin(theta)
        let rolling = mass * g * crr * cos(theta)
        let aero = 0.5 * airDensity * cda * v * v
        let force = gravity + rolling + aero

        return max(0, v * force / max(0.5, drivetrainEfficiency))
    }

    /// Advances the route from virtual gearing + real trainer cadence.
    /// When cadence is zero on a descent, the trainer-reported wheel speed is
    /// used only for coasting so route distance does not freeze.
    /// Returns the legacy resistance diagnostic value (trainer control may ignore it).
    func tick(cadenceRPM: Double, trainerSpeedKPH: Double = 0, now: Date = Date()) -> Double? {
        guard isRiding, let route else { lastTick = now; return nil }
        guard let previous = lastTick else { lastTick = now; return nil }

        let dt = min(2.0, max(0, now.timeIntervalSince(previous)))
        lastTick = now
        guard dt > 0 else { return targetResistancePercent }

        // Pedalling keeps the validated cadence + virtual-gear speed model.
        // If cadence falls to zero while descending, use the trainer's own
        // decaying speed as a coasting source instead of forcing speed to zero.
        let pedallingSpeedKPH = speedKPH(from: cadenceRPM)
        if cadenceRPM > 0.5 {
            virtualSpeedKPH = pedallingSpeedKPH
        } else if currentGradePercent < -0.1 && trainerSpeedKPH > 0.5 {
            virtualSpeedKPH = trainerSpeedKPH
        } else {
            virtualSpeedKPH = 0
        }
        let speedMS = virtualSpeedKPH / 3.6
        distanceM = min(route.totalDistanceM, distanceM + speedMS * dt)
        elapsedSeconds += dt
        currentElevationM = route.elevation(at: distanceM)

        rawGradePercent = min(30, max(-30, route.grade(at: distanceM, windowM: 10)))

        // The grade used by UI/trainer belongs to the CURRENT distance.
        // The old forwardGrade look-ahead anticipated changes by up to 150 m.
        smoothedGradePercent = rawGradePercent
        currentGradePercent = rawGradePercent

        let requestedResistance = resistanceForCurrentState(
            gradePercent: currentGradePercent
        )

        let gearSignature = currentGearLabel
        let gearChanged = lastGearSignature != nil && lastGearSignature != gearSignature
        lastGearSignature = gearSignature

        let outputResistance: Double

        if gearChanged {
            // User-requested shift should feel immediate.
            outputResistance = requestedResistance
            resistanceRampFrom = requestedResistance
            resistanceRampTo = requestedResistance
            resistanceRampStartedAt = now
            resistanceRampDurationS = minResistanceRampDurationS
        } else {
            let current = currentRampedResistance(at: now) ?? targetResistancePercent

            if resistanceRampTo == nil ||
                abs(requestedResistance - (resistanceRampTo ?? requestedResistance)) >= 0.5 {
                resistanceRampFrom = current
                resistanceRampTo = requestedResistance
                resistanceRampStartedAt = now
                resistanceRampDurationS = rampDurationSeconds(from: current, to: requestedResistance)
            }

            outputResistance = currentRampedResistance(at: now) ?? requestedResistance
        }

        targetResistancePercent = min(100, max(0, outputResistance))

        // Retain theoretical watts as an engineering diagnostic only.
        targetPowerW = Int(physicalPowerW(
            gradePercent: currentGradePercent,
            speedKPH: virtualSpeedKPH
        ).rounded())

        if distanceM >= route.totalDistanceM {
            isRiding = false
            status = "Route complete"
        }
        return targetResistancePercent
    }


    func recordSample(actualPowerW: Int, trainerSpeedKPH: Double, cadenceRPM: Double, now: Date = Date()) {
        guard route != nil else { return }

        sessionLog.append(SessionSample(
            timestamp: now,
            elapsedSeconds: elapsedSeconds,
            distanceM: distanceM,
            rawGradePercent: rawGradePercent,
            smoothedGradePercent: smoothedGradePercent,
            elevationM: currentElevationM,
            frontTeeth: frontChainring,
            rearTeeth: rearSprocket,
            gearRatio: gearRatio,
            cadenceRPM: cadenceRPM,
            virtualSpeedKPH: virtualSpeedKPH,
            targetPowerW: targetPowerW,
            targetResistancePercent: targetResistancePercent,
            actualPowerW: actualPowerW,
            trainerSpeedKPH: trainerSpeedKPH
        ))
        logSampleCount = sessionLog.count
    }

    func clearSessionLog() {
        sessionLog.removeAll(keepingCapacity: true)
        logSampleCount = 0
    }

    func sessionCSV() -> String {
        var lines = [
            "timestamp,elapsed_s,distance_m,raw_grade_pct,filtered_grade_pct,elevation_m,front_teeth,rear_teeth,gear_ratio,cadence_rpm,virtual_speed_kph,theoretical_power_w,target_resistance_pct,actual_power_w,trainer_speed_kph"
        ]

        let iso = ISO8601DateFormatter()
        for s in sessionLog {
            lines.append([
                iso.string(from: s.timestamp),
                String(format: "%.1f", s.elapsedSeconds),
                String(format: "%.1f", s.distanceM),
                String(format: "%.3f", s.rawGradePercent),
                String(format: "%.3f", s.smoothedGradePercent),
                String(format: "%.1f", s.elevationM),
                "\(s.frontTeeth)",
                "\(s.rearTeeth)",
                String(format: "%.4f", s.gearRatio),
                String(format: "%.1f", s.cadenceRPM),
                String(format: "%.2f", s.virtualSpeedKPH),
                "\(s.targetPowerW)",
                String(format: "%.2f", s.targetResistancePercent),
                "\(s.actualPowerW)",
                String(format: "%.2f", s.trainerSpeedKPH)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    func writeSessionCSV() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let routePart = (routeName ?? "RideClimb")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        let filename = "\(routePart)_\(formatter.string(from: Date())).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try sessionCSV().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func shiftEasier() {
        guard !cassette.isEmpty else { return }
        rearIndex = min(rearIndex + 1, cassette.count - 1)
    }

    func shiftHarder() {
        guard !cassette.isEmpty else { return }
        rearIndex = max(rearIndex - 1, 0)
    }

    func setBike(front: Int, cassette newCassette: [Int]) {
        frontChainring = max(1, front)
        cassette = newCassette.filter { $0 > 0 }.sorted()
        normalizeGearIndex()
        save()
    }

    private func normalizeGearIndex() {
        guard !cassette.isEmpty else { rearIndex = 0; return }
        rearIndex = min(max(0, rearIndex), cassette.count - 1)
    }

    private func save() {
        guard !isLoading else { return }
        let cfg = PersistentConfig(
            riderWeightKg: riderWeightKg,
            bikeWeightKg: bikeWeightKg,
            ftpW: ftpW,
            maxHR: maxHR,
            wheelCircumferenceM: wheelCircumferenceM,
            crr: crr,
            cda: cda,
            airDensity: airDensity,
            drivetrainEfficiency: drivetrainEfficiency,
            frontChainring: frontChainring,
            cassette: cassette,
            rearIndex: rearIndex
        )
        if let data = try? JSONEncoder().encode(cfg) {
            defaults.set(data, forKey: key)
        }
    }
}
