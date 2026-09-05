import SwiftUI
import UniformTypeIdentifiers
import Foundation

struct ContentView: View {
    @EnvironmentObject private var trainer: TrainerManager
    @EnvironmentObject private var ride: RideModel
    @StateObject private var climb3D = RideClimbPRO3DModel()

    @State private var showImporter = false
    @State private var lastSentGrade: Double?
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var lastLogSampleAt: Date?
    @State private var showDiagnostics = false
    @State private var previewDistanceM: Double = 0

    // Drivetrain draft: nothing changes until Apply drivetrain is pressed.
    @State private var draftChainringCount = 1
    @State private var draftFront1 = 40
    @State private var draftFront2 = 53
    @State private var draftCassette = ""
    @State private var drivetrainDirty = false
    @State private var appliedMessage = false
    @AppStorage("drivetrainMode") private var drivetrainMode = "COG"

    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            ridePage
                .tabItem { Label("Ride", systemImage: "bicycle") }
            climb2DPage
                .tabItem { Label("2D", systemImage: "chart.xyaxis.line") }
            climb3DPage
                .tabItem { Label("3D", systemImage: "mountain.2.fill") }
            setupPage
                .tabItem { Label("Setup", systemImage: "slider.horizontal.3") }
            dataPage
                .tabItem { Label("Data", systemImage: "doc.text") }
        }
        .onAppear { loadDrivetrainDraft() }
        .onReceive(timer) { now in
            guard trainer.controlReady else { return }

            // Preserve the validated cadence + virtual-gear ride engine while pedalling.
            // Trainer speed is supplied only as a downhill coasting source when cadence is zero.
            // Trainer control is intentionally simple: current GPX grade + native virtual gear.
            _ = ride.tick(
                cadenceRPM: trainer.cadenceRPM,
                trainerSpeedKPH: trainer.speedKPH,
                now: now
            )

            if ride.isRiding {
                previewDistanceM = ride.distanceM
            }

            let grade = ride.currentGradePercent
            if lastSentGrade == nil ||
                abs(grade - (lastSentGrade ?? 0)) >= 0.1 {

                trainer.setGrade(grade)
                lastSentGrade = grade
            }

            if trainer.nativeVirtualShiftReady &&
                trainer.nativeVirtualGear != ride.nativeGear {

                trainer.setVirtualRatio(ride.currentRatio)
            }

            if ride.isRiding {
                if lastLogSampleAt == nil ||
                    now.timeIntervalSince(lastLogSampleAt!) >= 0.5 {

                    ride.recordSample(
                        actualPowerW: trainer.powerW,
                        power3sW: trainer.power3sW,
                        heartRateBPM: trainer.heartRateBPM,
                        trainerSpeedKPH: trainer.speedKPH,
                        cadenceRPM: trainer.cadenceRPM,
                        now: now
                    )

                    lastLogSampleAt = now
                }
            } else {
                lastLogSampleAt = nil
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "gpx") ?? .xml
            ],
            allowsMultipleSelection: false
        ) { result in

            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }

                do {
                    try ride.loadGPX(url: url)
                    try climb3D.load(route: ride.route)
                    previewDistanceM = 0
                    lastSentGrade = nil
                } catch {
                    ride.status = "GPX error: \(error.localizedDescription)"
                }

            case .failure(let error):
                ride.status = "Import error: \(error.localizedDescription)"
            }
        }
    }

    private var ridePage: some View {
        NavigationStack {
            GeometryReader { geo in
                let compact = geo.size.height < 700

                VStack(spacing: compact ? 7 : 9) {
                    connectionStrip

                    HStack(spacing: 10) {
                        heroMetric(
                            "POWER",
                            "\(trainer.power3sW)",
                            "W",
                            powerSubtitle,
                            powerZoneColor
                        )

                        heroMetric(
                            "HEART RATE",
                            trainer.heartRateBPM > 0
                                ? "\(trainer.heartRateBPM)"
                                : "—",
                            trainer.heartRateBPM > 0
                                ? "bpm"
                                : "",
                            hrSubtitle,
                            hrZoneColor
                        )
                    }
                    .frame(height: compact ? 116 : 132)

                    HStack(spacing: 7) {
                        dashMetric(
                            "GRADE",
                            String(
                                format: "%.1f",
                                ride.currentGradePercent
                            ),
                            "%"
                        )

                        dashMetric(
                            "CADENCE",
                            String(
                                format: "%.0f",
                                trainer.cadenceRPM
                            ),
                            "rpm"
                        )

                        dashMetric(
                            "SPEED",
                            String(
                                format: "%.1f",
                                ride.virtualSpeedKPH
                            ),
                            "km/h"
                        )

                        dashMetric(
                            "GEAR",
                            drivetrainMode == "REAL"
                                ? "REAL"
                                : ride.currentGearLabel,
                            ""
                        )
                    }
                    .frame(height: compact ? 60 : 66)

                    VStack(spacing: 5) {
                        if let route = ride.route {
                            RouteProfileView(
                                route: route,
                                progress: ride.progress
                            )
                            .frame(maxHeight: .infinity)

                            HStack {
                                Text(
                                    ride.routeName ?? "GPX"
                                )
                                .lineLimit(1)

                                Spacer()

                                VStack(
                                    alignment: .trailing,
                                    spacing: 1
                                ) {
                                    Text(
                                        String(
                                            format: "%.1f / %.1f km",
                                            ride.distanceM / 1000,
                                            route.totalDistanceM / 1000
                                        )
                                    )
                                    .monospacedDigit()

                                    Text(
                                        "ETA " + ride.etaText
                                    )
                                    .monospacedDigit()
                                }
                            }
                            .font(
                                .caption.weight(.semibold)
                            )
                            .foregroundStyle(.secondary)

                        } else {
                            Spacer(minLength: 0)

                            Image(
                                systemName: "mountain.2.fill"
                            )
                            .font(.title2)
                            .foregroundStyle(.secondary)

                            Text(
                                "Choose a GPX route in Setup"
                            )
                            .font(
                                .subheadline.weight(.semibold)
                            )
                            .foregroundStyle(.secondary)

                            Spacer(minLength: 0)
                        }
                    }
                    .padding(10)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: compact ? 250 : 290,
                        maxHeight: compact ? 250 : 290
                    )
                    .background(
                        .thinMaterial,
                        in: RoundedRectangle(
                            cornerRadius: 20
                        )
                    )

                    if drivetrainMode == "COG" {
                        HStack(spacing: 12) {
                            dashboardShifter(
                                "CHAINRING",
                                minus: {
                                    ride.shiftFrontSmaller()
                                    syncNativeGear()
                                },
                                plus: {
                                    ride.shiftFrontLarger()
                                    syncNativeGear()
                                },
                                minusDisabled:
                                    ride.frontChainrings.count < 2 ||
                                    ride.frontIndex == 0,
                                plusDisabled:
                                    ride.frontChainrings.count < 2 ||
                                    ride.frontIndex >=
                                    ride.frontChainrings.count - 1
                            )

                            dashboardShifter(
                                "SPROCKET",
                                minus: {
                                    ride.shiftRearSmaller()
                                    syncNativeGear()
                                },
                                plus: {
                                    ride.shiftRearLarger()
                                    syncNativeGear()
                                },
                                minusDisabled:
                                    ride.rearIndex == 0,
                                plusDisabled:
                                    ride.rearIndex >=
                                    ride.cassette.count - 1
                            )
                        }
                        .frame(
                            height: compact ? 70 : 78
                        )

                    } else {
                        HStack {
                            Image(
                                systemName: "bicycle"
                            )

                            VStack(
                                alignment: .leading,
                                spacing: 2
                            ) {
                                Text(
                                    "REAL DRIVETRAIN"
                                )
                                .font(.caption.bold())

                                Text(
                                    "Use the bike's physical shifters"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text("1.00×")
                                .font(
                                    .headline.monospacedDigit()
                                )
                        }
                        .padding(.horizontal, 14)
                        .frame(
                            height: compact ? 58 : 64
                        )
                        .background(
                            .thinMaterial,
                            in: RoundedRectangle(
                                cornerRadius: 18
                            )
                        )
                    }

                    HStack(spacing: 12) {
                        Button {
                            if ride.isRiding {
                                ride.pauseRide()
                            } else {
                                syncNativeGear()
                                ride.startRide()
                            }
                        } label: {
                            Label(
                                ride.isRiding
                                    ? "Pause"
                                    : "Start",
                                systemImage:
                                    ride.isRiding
                                    ? "pause.fill"
                                    : "play.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(
                            ride.route == nil ||
                            !trainer.controlReady
                        )

                        Button {
                            ride.resetSession()
                            lastSentGrade = nil
                        } label: {
                            Label(
                                "Reset",
                                systemImage:
                                    "arrow.counterclockwise"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(
                            ride.route == nil
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(
                    width: geo.size.width,
                    height: geo.size.height,
                    alignment: .top
                )
            }
            .navigationTitle("RideClimbPRO")
            .navigationBarTitleDisplayMode(.inline)
        }
    }


    private var climb2DPage: some View {
        NavigationStack {
            Group {
                if let route = ride.route {
                    VStack(spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ride.routeName ?? "GPX")
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(String(format: "%.1f km • %d points", route.totalDistanceM / 1000, route.points.count))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            let warnings = route.suspiciousGradeSegments()
                            if warnings.isEmpty {
                                Label("GPX OK", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                            } else {
                                Label("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }

                        RideClimbRoute2DView(
                            route: route,
                            distanceM: ride.isRiding ? ride.distanceM : previewDistanceM
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        VStack(spacing: 5) {
                            Slider(value: $previewDistanceM, in: 0...max(1, route.totalDistanceM))
                                .disabled(ride.isRiding)
                            HStack {
                                Text(String(format: "%.1f km", (ride.isRiding ? ride.distanceM : previewDistanceM) / 1000))
                                Spacer()
                                Text(String(format: "%.1f%%", route.grade(at: ride.isRiding ? ride.distanceM : previewDistanceM)))
                                Spacer()
                                Text(String(format: "%.0f m", route.elevation(at: ride.isRiding ? ride.distanceM : previewDistanceM)))
                            }
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        }
                    }
                    .padding()
                } else {
                    ContentUnavailableView(
                        "No 2D route",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Import a planned GPX route from the Ride tab.")
                    )
                }
            }
            .navigationTitle("Climb 2D")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var climb3DPage: some View {
        NavigationStack {
            ZStack {
                if climb3D.hasMesh, let route = ride.route {
                    RideClimbPRO3DView(
                        sceneController: climb3D.sceneController,
                        distanceM: ride.isRiding ? ride.distanceM : previewDistanceM
                    )
                    .ignoresSafeArea(edges: .top)

                    VStack {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ride.routeName ?? "GPX")
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)

                                    Text(
                                        String(
                                            format: "%.1f / %.1f km",
                                            (ride.isRiding ? ride.distanceM : previewDistanceM) / 1000,
                                            route.totalDistanceM / 1000
                                        )
                                    )
                                    .font(.caption2)
                                    .monospacedDigit()
                                }

                                Spacer()

                                Text(
                                    String(
                                        format: "%.1f%%",
                                        route.grade(at: ride.isRiding ? ride.distanceM : previewDistanceM)
                                    )
                                )
                                .font(.title2.bold())
                                .monospacedDigit()
                            }

                            HStack(spacing: 10) {
                                Label(
                                    "\(trainer.power3sW) W",
                                    systemImage: "bolt.fill"
                                )
                                .monospacedDigit()

                                Spacer()

                                Label(
                                    trainer.heartRateBPM > 0
                                        ? "\(trainer.heartRateBPM) bpm"
                                        : "— bpm",
                                    systemImage: "heart.fill"
                                )
                                .monospacedDigit()

                                Spacer()

                                Label(
                                    String(
                                        format: "%.1f km/h",
                                        ride.virtualSpeedKPH
                                    ),
                                    systemImage: "speedometer"
                                )
                                .monospacedDigit()
                            }
                            .font(.caption.weight(.semibold))
                        }
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()

                        Spacer()

                        VStack(spacing: 4) {
                            Slider(
                                value: $previewDistanceM,
                                in: 0...max(1, route.totalDistanceM)
                            )
                            .disabled(ride.isRiding)

                            HStack {
                                Text("Start")
                                Spacer()
                                Text(ride.isRiding ? "Live" : String(format: "%.1f km", previewDistanceM / 1000))
                                    .monospacedDigit()
                                Spacer()
                                Text("Finish")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)

                        HStack {
                            Text(
                                String(
                                    format: "%.0f m",
                                    route.elevation(at: ride.isRiding ? ride.distanceM : previewDistanceM)
                                )
                            )
                            .monospacedDigit()

                            Spacer()

                            Button("Overview") {
                                climb3D.showOverview()
                            }
                            .buttonStyle(.bordered)

                            Button("Follow") {
                                climb3D.resetCamera()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .font(.caption.weight(.semibold))
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "No 3D route",
                        systemImage: "mountain.2",
                        description: Text(
                            "Import the GPX from the Ride tab. The same RideClimbPRO route drives both the trainer and the 3D view."
                        )
                    )
                }
            }
            .navigationTitle("Climb 3D")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var setupPage: some View {
        NavigationStack {
            Form {
                Section("Ride mode") {
                    Picker(
                        "Shifting",
                        selection: $drivetrainMode
                    ) {
                        Text("COG / Virtual")
                            .tag("COG")

                        Text("Real drivetrain")
                            .tag("REAL")
                    }
                    .pickerStyle(.segmented)
                    .onChange(
                        of: drivetrainMode
                    ) { _, newMode in

                        if newMode == "REAL" {
                            setRealDrivetrainNeutral()
                        } else {
                            syncNativeGear()
                        }
                    }

                    if drivetrainMode == "COG" {
                        Text(
                            "RideClimbPRO converts your selected chainring and cassette to the closest native virtual gear."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    } else {
                        Text(
                            "RideClimbPRO holds the virtual drivetrain at 1.00×. Shift with the bike's real drivetrain."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Route") {
                    Button("Import GPX") {
                        showImporter = true
                    }

                    if let route = ride.route {
                        Text(
                            ride.routeName ?? "GPX"
                        )

                        Text(
                            String(
                                format: "%.1f km",
                                route.totalDistanceM / 1000
                            )
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Smart trainer") {
                    HStack {
                        Button("Scan") {
                            trainer.startScan()
                        }

                        Spacer()

                        Button("Disconnect") {
                            trainer.disconnect()
                        }
                        .disabled(
                            !trainer.isConnected
                        )
                    }

                    if !trainer.discoveredTrainers.isEmpty {
                        Picker(
                            "Trainer",
                            selection:
                                $trainer.selectedTrainerID
                        ) {
                            Text("Select")
                                .tag(
                                    Optional<UUID>.none
                                )

                            ForEach(
                                trainer.discoveredTrainers
                            ) {
                                Text($0.name)
                                    .tag(
                                        Optional($0.id)
                                    )
                            }
                        }

                        Button("Connect trainer") {
                            trainer.connectSelected()
                        }
                    }
                }

                Section("Heart-rate sensor") {
                    HStack {
                        Button("Scan HR") {
                            trainer.startHeartRateScan()
                        }

                        Spacer()

                        Button("Disconnect HR") {
                            trainer.disconnectHeartRate()
                        }
                        .disabled(
                            !trainer.heartRateConnected
                        )
                    }

                    if !trainer
                        .discoveredHeartRateDevices
                        .isEmpty {

                        Picker(
                            "HR sensor",
                            selection:
                                $trainer.selectedHeartRateID
                        ) {
                            Text("Select")
                                .tag(
                                    Optional<UUID>.none
                                )

                            ForEach(
                                trainer
                                    .discoveredHeartRateDevices
                            ) {
                                Text($0.name)
                                    .tag(
                                        Optional($0.id)
                                    )
                            }
                        }

                        Button("Connect HR") {
                            trainer
                                .connectSelectedHeartRate()
                        }
                    }
                }

                Section("Rider") {
                    Stepper(
                        "Rider weight: \(Int(ride.riderWeightKg)) kg",
                        value: $ride.riderWeightKg,
                        in: 40...150
                    )

                    Stepper(
                        "Bike + equipment: \(Int(ride.bikeWeightKg)) kg",
                        value: $ride.bikeWeightKg,
                        in: 5...30
                    )

                    Stepper(
                        "FTP: \(ride.ftpW) W",
                        value: $ride.ftpW,
                        in: 50...500,
                        step: 5
                    )

                    Stepper(
                        "HR max: \(ride.maxHR) bpm",
                        value: $ride.maxHR,
                        in: 100...230
                    )

                    Stepper(
                        "Age: \(ride.age) years",
                        value: $ride.age,
                        in: 10...100
                    )
                }

                if drivetrainMode == "COG" {
                    Section("Virtual drivetrain") {
                        Picker(
                            "Chainrings",
                            selection:
                                dirtyBinding(
                                    $draftChainringCount
                                )
                        ) {
                            Text("1x")
                                .tag(1)

                            Text("2x")
                                .tag(2)
                        }
                        .pickerStyle(.segmented)

                        Stepper(
                            "Chainring 1: \(draftFront1)T",
                            value:
                                dirtyBinding(
                                    $draftFront1
                                ),
                            in: 20...70
                        )

                        if draftChainringCount == 2 {
                            Stepper(
                                "Chainring 2: \(draftFront2)T",
                                value:
                                    dirtyBinding(
                                        $draftFront2
                                    ),
                                in: 20...70
                            )
                        }

                        TextField(
                            "Cassette: 11,12,13,14,15,17,19,21,24,27,30,34",
                            text:
                                dirtyBinding(
                                    $draftCassette
                                )
                        )
                        .textInputAutocapitalization(
                            .never
                        )
                        .autocorrectionDisabled()

                        Button(
                            drivetrainDirty
                                ? "Apply drivetrain"
                                : (
                                    appliedMessage
                                    ? "Applied ✓"
                                    : "Apply drivetrain"
                                )
                        ) {
                            applyDrivetrain()
                        }
                        .buttonStyle(
                            .borderedProminent
                        )
                        .disabled(
                            !drivetrainDirty
                        )

                        Text(
                            "Current: \(ride.frontChainrings.map(String.init).joined(separator: "/")) × \(ride.cassette.map(String.init).joined(separator: "-"))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Setup")
        }
    }

    private var dataPage: some View {
        NavigationStack {
            Form {
                Section("Activity") {
                    Text(
                        "\(ride.logSampleCount) samples"
                    )

                    Button("Export FIT") {
                        do {
                            exportURL =
                                try ride.writeSessionFIT()

                            showShareSheet = true
                        } catch {
                            ride.status =
                                "FIT export error: \(error.localizedDescription)"
                        }
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                    .disabled(
                        ride.logSampleCount == 0
                    )
                }

                Section("Diagnostics") {
                    Button("Export CSV") {
                        do {
                            exportURL =
                                try ride.writeSessionCSV()

                            showShareSheet = true
                        } catch {
                            ride.status =
                                "Log export error: \(error.localizedDescription)"
                        }
                    }
                    .disabled(
                        ride.logSampleCount == 0
                    )
                }

                Section {
                    DisclosureGroup(
                        "Diagnostics",
                        isExpanded: $showDiagnostics
                    ) {
                        Text(
                            String(
                                format:
                                    "raw grade %.2f%% • filtered %.2f%% • target resistance %.2f%% • theoretical %.0f W",
                                ride.rawGradePercent,
                                ride.smoothedGradePercent,
                                ride.targetResistancePercent,
                                Double(
                                    ride.targetPowerW
                                )
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        ScrollView {
                            Text(
                                trainer.logText
                            )
                            .font(
                                .system(
                                    .caption2,
                                    design: .monospaced
                                )
                            )
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .textSelection(.enabled)
                        }
                        .frame(
                            minHeight: 160,
                            maxHeight: 360
                        )
                    }
                }
            }
            .navigationTitle("Data")
        }
    }

    private var connectionStrip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    trainer.controlReady
                        ? Color.green
                        : (
                            trainer.isConnected
                            ? Color.orange
                            : Color.gray
                        )
                )
                .frame(
                    width: 8,
                    height: 8
                )

            Text(
                trainer.controlReady
                    ? "Trainer ready"
                    : trainer.connectionState
            )
            .font(
                .caption.weight(.semibold)
            )

            Spacer()

            if trainer.heartRateConnected {
                Image(
                    systemName: "heart.fill"
                )
                .foregroundStyle(.red)
            }

            if trainer.nativeVirtualShiftReady {
                Text("VSHIFT")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
            }
        }
    }

    private func intensityTile(
        title: String,
        value: String,
        unit: String,
        subtitle: String,
        color: Color
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 3
        ) {
            Text(title)
                .font(
                    .caption.weight(.bold)
                )
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack(
                alignment: .firstTextBaseline,
                spacing: 3
            ) {
                Text(value)
                    .font(
                        .system(
                            size: 44,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .minimumScaleFactor(0.6)

                Text(unit)
                    .font(
                        .headline.weight(.semibold)
                    )
            }
            .foregroundStyle(color)

            Text(subtitle)
                .font(
                    .caption.weight(.semibold)
                )
                .foregroundStyle(color)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 115,
            alignment: .leading
        )
        .padding(12)
        .background(
            color.opacity(0.09),
            in: RoundedRectangle(
                cornerRadius: 18
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: 18
            )
            .stroke(
                color.opacity(0.22)
            )
        )
    }

    private func compactMetric(
        _ title: String,
        _ value: String
    ) -> some View {

        VStack(spacing: 2) {
            Text(title)
                .font(
                    .system(
                        size: 9,
                        weight: .bold
                    )
                )
                .foregroundStyle(.secondary)

            Text(value)
                .font(
                    .system(
                        size: 16,
                        weight: .bold,
                        design: .rounded
                    )
                )
                .minimumScaleFactor(0.55)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            .thinMaterial,
            in: RoundedRectangle(
                cornerRadius: 11
            )
        )
    }

    private func compactShifter(
        label: String,
        minus: @escaping () -> Void,
        plus: @escaping () -> Void,
        minusDisabled: Bool,
        plusDisabled: Bool
    ) -> some View {

        HStack(spacing: 8) {
            Button(action: minus) {
                Image(
                    systemName: "minus"
                )
                .frame(
                    width: 34,
                    height: 30
                )
            }
            .buttonStyle(.bordered)
            .disabled(minusDisabled)

            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .frame(minWidth: 68)

            Button(action: plus) {
                Image(
                    systemName: "plus"
                )
                .frame(
                    width: 34,
                    height: 30
                )
            }
            .buttonStyle(.bordered)
            .disabled(plusDisabled)
        }
        .frame(maxWidth: .infinity)
    }

    private func heroMetric(
        _ title: String,
        _ value: String,
        _ unit: String,
        _ subtitle: String,
        _ color: Color
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 3
        ) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack(
                alignment: .firstTextBaseline,
                spacing: 3
            ) {
                Text(value)
                    .font(
                        .system(
                            size: 46,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)

                Text(unit)
                    .font(.headline.bold())
            }
            .foregroundStyle(color)

            Text(subtitle)
                .font(.caption.bold())
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .leading
        )
        .background(
            color.opacity(0.10),
            in: RoundedRectangle(
                cornerRadius: 22
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: 22
            )
            .stroke(
                color.opacity(0.24)
            )
        )
    }

    private func dashMetric(
        _ title: String,
        _ value: String,
        _ unit: String
    ) -> some View {

        VStack(spacing: 2) {
            Text(title)
                .font(
                    .system(
                        size: 9,
                        weight: .bold
                    )
                )
                .foregroundStyle(.secondary)

            HStack(
                alignment: .firstTextBaseline,
                spacing: 2
            ) {
                Text(value)
                    .font(
                        .system(
                            size: 20,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                if !unit.isEmpty {
                    Text(unit)
                        .font(
                            .system(
                                size: 9,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .background(
            .thinMaterial,
            in: RoundedRectangle(
                cornerRadius: 15
            )
        )
    }

    private func dashboardShifter(
        _ title: String,
        minus: @escaping () -> Void,
        plus: @escaping () -> Void,
        minusDisabled: Bool,
        plusDisabled: Bool
    ) -> some View {

        VStack(spacing: 5) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(action: minus) {
                    Image(
                        systemName: "minus"
                    )
                    .font(.title3.bold())
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                }
                .buttonStyle(.bordered)
                .disabled(minusDisabled)

                Button(action: plus) {
                    Image(
                        systemName: "plus"
                    )
                    .font(.title3.bold())
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                }
                .buttonStyle(
                    .borderedProminent
                )
                .disabled(plusDisabled)
            }
        }
        .padding(7)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .background(
            .thinMaterial,
            in: RoundedRectangle(
                cornerRadius: 18
            )
        )
    }

    private func dirtyBinding<T>(
        _ binding: Binding<T>
    ) -> Binding<T> {

        Binding(
            get: {
                binding.wrappedValue
            },
            set: {
                binding.wrappedValue = $0
                drivetrainDirty = true
                appliedMessage = false
            }
        )
    }

    private func loadDrivetrainDraft() {
        draftChainringCount =
            ride.frontChainrings.count

        draftFront1 =
            ride.frontChainrings.first ?? 40

        draftFront2 =
            ride.frontChainrings.count > 1
            ? ride.frontChainrings[1]
            : max(53, draftFront1)

        draftCassette =
            ride.cassette
                .map(String.init)
                .joined(separator: ",")

        drivetrainDirty = false
    }

    private func applyDrivetrain() {
        let cassette =
            draftCassette
                .split(
                    whereSeparator: {
                        $0 == "," ||
                        $0 == ";" ||
                        $0 == " " ||
                        $0 == "-"
                    }
                )
                .compactMap {
                    Int($0)
                }

        guard cassette.count >= 2 else {
            ride.status =
                "Drivetrain error: enter at least two sprockets"
            return
        }

        ride.setChainringCount(
            draftChainringCount
        )

        ride.setFrontTeeth(
            at: 0,
            teeth: draftFront1
        )

        if draftChainringCount == 2 {
            ride.setFrontTeeth(
                at: 1,
                teeth: draftFront2
            )
        }

        ride.setCassette(cassette)

        loadDrivetrainDraft()
        syncNativeGear()

        appliedMessage = true

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.5
        ) {
            appliedMessage = false
        }
    }

    private func syncNativeGear() {
        lastSentGrade = nil

        guard trainer
            .nativeVirtualShiftReady
        else {
            return
        }

        if drivetrainMode == "REAL" {
            trainer.setVirtualRatio(2.5)
        } else {
            trainer.setVirtualRatio(
                ride.currentRatio
            )
        }
    }

    private func setRealDrivetrainNeutral() {
        lastSentGrade = nil

        guard trainer
            .nativeVirtualShiftReady
        else {
            return
        }

        trainer.setVirtualRatio(2.5)
    }

    private var powerFraction: Double {
        ride.ftpW > 0
            ? Double(trainer.power3sW) /
              Double(ride.ftpW)
            : 0
    }

    private var hrFraction: Double {
        ride.maxHR > 0 &&
        trainer.heartRateBPM > 0
            ? Double(trainer.heartRateBPM) /
              Double(ride.maxHR)
            : 0
    }

    private var powerSubtitle: String {
        trainer.power3sW > 0
            ? String(
                format: "%.0f%% FTP",
                powerFraction * 100
            )
            : "— % FTP"
    }

    private var hrSubtitle: String {
        trainer.heartRateBPM > 0
            ? String(
                format: "%.0f%% HRmax",
                hrFraction * 100
            )
            : "Connect HR sensor"
    }

    private var powerZoneColor: Color {
        zoneColor(
            fraction: powerFraction,
            thresholds: [
                0.55,
                0.75,
                0.90,
                1.05,
                1.20
            ]
        )
    }

    private var hrZoneColor: Color {
        trainer.heartRateBPM > 0
            ? zoneColor(
                fraction: hrFraction,
                thresholds: [
                    0.60,
                    0.70,
                    0.80,
                    0.90,
                    0.95
                ]
            )
            : .gray
    }

    private func zoneColor(
        fraction: Double,
        thresholds: [Double]
    ) -> Color {

        if fraction < thresholds[0] {
            return .gray
        }

        if fraction < thresholds[1] {
            return .blue
        }

        if fraction < thresholds[2] {
            return .green
        }

        if fraction < thresholds[3] {
            return .yellow
        }

        if fraction < thresholds[4] {
            return .orange
        }

        return .red
    }
}

private struct RouteProfileView: View {
    let route: GPXRoute
    let progress: Double

    /// Display-only profile smoothing. RideModel/GPX physics remain untouched.
    /// Sampling uniformly by route distance removes the visible GPS "teeth"
    /// without changing the GPX plan-view geometry or the trainer controller.
    private var displayProfile: [(distanceM: Double, elevationM: Double)] {
        guard route.totalDistanceM > 0 else { return [] }

        let count = 220
        let radiusM = min(35.0, max(18.0, route.totalDistanceM / 180.0))
        let offsets: [Double] = [-1, -0.66, -0.33, 0, 0.33, 0.66, 1]
        let weights: [Double] = [1, 2, 3, 4, 3, 2, 1]
        let weightSum = weights.reduce(0, +)

        return (0..<count).map { index in
            let fraction = Double(index) / Double(count - 1)
            let distance = route.totalDistanceM * fraction
            var elevation = 0.0

            for i in offsets.indices {
                let sampleDistance = min(
                    route.totalDistanceM,
                    max(0, distance + offsets[i] * radiusM)
                )
                elevation += route.elevation(at: sampleDistance) * weights[i]
            }

            return (distance, elevation / weightSum)
        }
    }

    var body: some View {
        GeometryReader { _ in
            let points = displayProfile

            if points.count >= 2 {
                let minE = points.map { $0.elevationM }.min() ?? 0
                let maxE = points.map { $0.elevationM }.max() ?? minE + 1
                let spanE = max(1, maxE - minE)
                let maxD = max(1, route.totalDistanceM)

                Canvas { context, size in
                    var profile = Path()

                    for (index, point) in points.enumerated() {
                        let x = CGFloat(point.distanceM / maxD) * size.width
                        let y = size.height
                            - CGFloat((point.elevationM - minE) / spanE)
                            * (size.height - 10)
                            - 5

                        if index == 0 {
                            profile.move(to: CGPoint(x: x, y: y))
                        } else {
                            profile.addLine(to: CGPoint(x: x, y: y))
                        }
                    }

                    context.stroke(profile, with: .color(.primary), lineWidth: 2)

                    let x = CGFloat(min(1, max(0, progress))) * size.width
                    var marker = Path()
                    marker.move(to: CGPoint(x: x, y: 0))
                    marker.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(marker, with: .color(.red), lineWidth: 2)
                }
                .background(
                    .secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
        }
    }
}


private struct RideClimbRoute2DView: View {
    let route: GPXRoute
    let distanceM: Double

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard route.points.count >= 2 else { return }
                let first = route.points[0]
                let latScale = 111_320.0
                let lonScale = 111_320.0 * cos(first.latitude * .pi / 180.0)
                let xy = route.points.map { point in
                    CGPoint(
                        x: (point.longitude - first.longitude) * lonScale,
                        y: -(point.latitude - first.latitude) * latScale
                    )
                }

                let minX = xy.map(\.x).min() ?? 0
                let maxX = xy.map(\.x).max() ?? 1
                let minY = xy.map(\.y).min() ?? 0
                let maxY = xy.map(\.y).max() ?? 1
                let spanX = max(1, maxX - minX)
                let spanY = max(1, maxY - minY)
                let baseScale = min((size.width - 24) / spanX, (size.height - 24) / spanY)
                let scale = baseScale * zoom

                func screen(_ p: CGPoint) -> CGPoint {
                    CGPoint(
                        x: size.width / 2 + (p.x - (minX + maxX)/2) * scale + offset.width,
                        y: size.height / 2 + (p.y - (minY + maxY)/2) * scale + offset.height
                    )
                }

                var path = Path()
                path.move(to: screen(xy[0]))
                for p in xy.dropFirst() { path.addLine(to: screen(p)) }
                context.stroke(path, with: .color(.primary), lineWidth: 3)

                let clamped = min(max(distanceM, 0), route.totalDistanceM)
                var idx = 1
                while idx < route.points.count && route.points[idx].distanceM < clamped { idx += 1 }
                idx = min(idx, route.points.count - 1)
                let aIndex = max(0, idx - 1)
                let a = route.points[aIndex]
                let b = route.points[idx]
                let f = b.distanceM > a.distanceM ? (clamped - a.distanceM) / (b.distanceM - a.distanceM) : 0
                let markerMap = CGPoint(
                    x: xy[aIndex].x + (xy[idx].x - xy[aIndex].x) * f,
                    y: xy[aIndex].y + (xy[idx].y - xy[aIndex].y) * f
                )
                let marker = screen(markerMap)
                let rect = CGRect(x: marker.x - 6, y: marker.y - 6, width: 12, height: 12)
                context.fill(Path(ellipseIn: rect), with: .color(.red))
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .gesture(
                MagnificationGesture()
                    .onChanged { value in zoom = min(8, max(0.7, committedZoom * value)) }
                    .onEnded { _ in committedZoom = zoom }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(width: committedOffset.width + value.translation.width, height: committedOffset.height + value.translation.height)
                    }
                    .onEnded { _ in committedOffset = offset }
            )
            .overlay(alignment: .topTrailing) {
                Button("Fit") {
                    zoom = 1
                    committedZoom = 1
                    offset = .zero
                    committedOffset = .zero
                }
                .buttonStyle(.bordered)
                .padding(8)
            }
        }
    }
}
