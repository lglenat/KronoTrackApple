//
//  ContentView.swift
//  kronotrack
//
//  Created by Lucas on 20/05/2025.
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit
import UserNotifications

struct Course: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let gpxUrl: String
}

struct GPXPoint: Identifiable, Hashable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    static func == (lhs: GPXPoint, rhs: GPXPoint) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(coordinate.latitude)
        hasher.combine(coordinate.longitude)
    }
}

struct RunnerInfo {
    let firstName: String
    let lastName: String
    let eventName: String
    let bib: String
    let birthYear: String
    let code: String
}

class AppViewModel: ObservableObject {
    @Published var courses: [Course] = []
    @Published var selectedCourse: Course? = nil
    @Published var bib: String = UserDefaults.standard.string(forKey: "bib") ?? "" {
        didSet { UserDefaults.standard.set(bib, forKey: "bib") }
    }
    @Published var birthYear: String = UserDefaults.standard.string(forKey: "birthYear") ?? "" {
        didSet { UserDefaults.standard.set(birthYear, forKey: "birthYear") }
    }
    @Published var code: String = UserDefaults.standard.string(forKey: "code") ?? "" {
        didSet { UserDefaults.standard.set(code, forKey: "code") }
    }
    @Published var isTracking: Bool = false
    @Published var mapRegion = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48.858844, longitude: 2.294351), span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
    @Published var gpxCoordinates: [GPXPoint] = []
    @Published var userLocation: CLLocationCoordinate2D? = nil
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var runnerInfo: RunnerInfo? = nil
    
    // Callback for region changes that need to be animated through programmatic ID
    var notifyRegionChange: ((MKCoordinateRegion) -> Void)?

    /// Returns the region that fits the given GPX points with padding and minimum span
    static func regionForGPXTrack(_ coords: [GPXPoint]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        var minLat = coords.first!.coordinate.latitude
        var maxLat = coords.first!.coordinate.latitude
        var minLon = coords.first!.coordinate.longitude
        var maxLon = coords.first!.coordinate.longitude
        for pt in coords {
            minLat = min(minLat, pt.coordinate.latitude)
            maxLat = max(maxLat, pt.coordinate.latitude)
            minLon = min(minLon, pt.coordinate.longitude)
            maxLon = max(maxLon, pt.coordinate.longitude)
        }
        let latDelta = maxLat - minLat
        let lonDelta = maxLon - minLon
        let latPad = latDelta * 0.2
        let lonPad = lonDelta * 0.2
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let minSpan = 0.002
        let span = MKCoordinateSpan(
            latitudeDelta: max(latDelta + 2 * latPad, minSpan),
            longitudeDelta: max(lonDelta + 2 * lonPad, minSpan)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    func fetchCourses() {
        guard let url = URL(string: "https://track.kronotiming.fr/events") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["events"] as? [String],
                  !arr.isEmpty else {
                DispatchQueue.main.async {
                    self.courses = []
                    self.selectedCourse = nil
                }
                return
            }
            let courseList = arr.map { Course(id: $0, name: $0, gpxUrl: "") }
            DispatchQueue.main.async {
                self.courses = courseList
                // Set a default selection to avoid Picker nil warning
                if self.selectedCourse == nil, let first = courseList.first {
                    self.selectedCourse = first
                }
            }
        }.resume()
    }
    func setRegionForTrack(_ coords: [GPXPoint]) {
        guard let region = Self.regionForGPXTrack(coords) else { return }
        if let notifyRegionChange = self.notifyRegionChange {
            notifyRegionChange(region)
        } else {
            // Fallback if callback is not set
            DispatchQueue.main.async {
                withAnimation {
                    self.mapRegion = region
                }
            }
        }
    }
    func fetchGPX(for course: Course) {
        guard let url = URL(string: course.gpxUrl) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let gpxString = String(data: data, encoding: .utf8) else { return }
            let coords = GPXParser.parseCoordinates(from: gpxString)
            DispatchQueue.main.async {
                self.gpxCoordinates = coords
                self.setRegionForTrack(coords)
            }
        }.resume()
    }
    func startTrackingIfPossible(locationManager: LocationManager, completion: @escaping (Bool) -> Void) {
        // 1. Validate input fields
        guard let course = selectedCourse, !bib.isEmpty, birthYear.count == 4, code.count == 6 else {
            DispatchQueue.main.async {
                self.errorMessage = NSLocalizedString("Veuillez remplir tous les champs correctement.", comment: "Missing fields")
            }
            completion(false)
            return
        }
        // Store selected course id to UserDefaults for background access
        UserDefaults.standard.set(course.id, forKey: "main_event")
        // 2. Request notification and location permissions
        NotificationManager.shared.requestPermissions()
        locationManager.requestPermissions { granted in
            guard granted else {
                DispatchQueue.main.async {
                    self.errorMessage = NSLocalizedString("Autorisation de localisation requise.", comment: "Location permission required")
                }
                completion(false)
                return
            }
            // 3. Call validation API
            self.isLoading = true
            let url = URL(string: "https://live.kronotiming.fr/track")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = [
                "main_event": course.id,
                "bib": Int(self.bib) ?? self.bib, // send as Int if possible
                "birth_year": Int(self.birthYear) ?? self.birthYear, // send as Int if possible
                "code": self.code
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            URLSession.shared.dataTask(with: req) { data, response, error in
                DispatchQueue.main.async {
                    self.isLoading = false
                }
                guard let data = data, error == nil,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    DispatchQueue.main.async {
                        self.errorMessage = NSLocalizedString("Erreur réseau ou serveur.", comment: "Network/server error")
                    }
                    completion(false)
                    return
                }
                if let errorMsg = obj["error"] as? String {
                    DispatchQueue.main.async {
                        self.errorMessage = errorMsg
                    }
                    completion(false)
                    return
                }
                if let trackArr = obj["track"] as? [[Any]] {
                    let coords: [GPXPoint] = trackArr.compactMap { arr in
                        if arr.count == 2, let lat = arr[0] as? Double, let lon = arr[1] as? Double {
                            return GPXPoint(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                        }
                        return nil
                    }
                    DispatchQueue.main.async {
                        self.gpxCoordinates = coords
                        self.errorMessage = nil
                        // --- Jump to GPX track region when starting tracking ---
                        if let region = Self.regionForGPXTrack(coords) {
                            self.notifyRegionChange?(region)
                        }
                    }
                }
                let firstName = obj["firstName"] as? String ?? ""
                let lastName = obj["lastName"] as? String ?? ""
                let eventName = obj["eventName"] as? String ?? self.selectedCourse?.name ?? ""
                DispatchQueue.main.async {
                    self.runnerInfo = RunnerInfo(
                        firstName: firstName,
                        lastName: lastName,
                        eventName: eventName,
                        bib: self.bib,
                        birthYear: self.birthYear,
                        code: self.code
                    )
                }
                DispatchQueue.main.async {
                    self.isTracking = true
                }
                DispatchQueue.main.async {
                    locationManager.startTracking()
                }
                completion(true)
            }.resume()
        }
    }
    // ...location tracking and upload logic will be added here...
}

// MARK: - MapPolylineView for SwiftUI

struct MapPolylineView: UIViewRepresentable {
    var coordinates: [CLLocationCoordinate2D]
    var userLocation: CLLocationCoordinate2D?
    @Binding var region: MKCoordinateRegion
    var isMapInteractionEnabled: Bool = true // new property
    var onUserInteraction: (() -> Void)? = nil // new property
    var programmaticRegionChangeID: UUID = UUID() // new property

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.isZoomEnabled = isMapInteractionEnabled
        mapView.isScrollEnabled = isMapInteractionEnabled
        mapView.setRegion(region, animated: false)
        // Add overlays initially if coordinates exist
        context.coordinator.updateOverlaysIfNeeded(on: mapView, newCoordinates: coordinates)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Only update overlays if coordinates changed
        context.coordinator.updateOverlaysIfNeeded(on: mapView, newCoordinates: coordinates)
        // Detect programmaticRegionChangeID change to trigger region update
        if context.coordinator.lastProgrammaticRegionChangeID != programmaticRegionChangeID {
            context.coordinator.isProgrammaticRegionChange = true
            context.coordinator.lastProgrammaticRegionChangeID = programmaticRegionChangeID
        }
        // Only set region if a programmatic change is requested
        if context.coordinator.isProgrammaticRegionChange {
            let regionToSet = region
            if mapView.region.center.latitude != regionToSet.center.latitude ||
                mapView.region.center.longitude != regionToSet.center.longitude ||
                mapView.region.span.latitudeDelta != regionToSet.span.latitudeDelta ||
                mapView.region.span.longitudeDelta != regionToSet.span.longitudeDelta {
                mapView.setRegion(regionToSet, animated: true)
            }
            context.coordinator.isProgrammaticRegionChange = false
        }
        // Remove custom user location annotation: rely on showsUserLocation for blue dot
        mapView.isZoomEnabled = isMapInteractionEnabled
        mapView.isScrollEnabled = isMapInteractionEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(region: $region, onUserInteraction: onUserInteraction)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var region: Binding<MKCoordinateRegion>
        var isProgrammaticRegionChange = false
        var lastProgrammaticRegionChangeID: UUID? = nil // <--- add this
        private var lastCoordinates: [CLLocationCoordinate2D] = []
        var onUserInteraction: (() -> Void)? = nil

        init(region: Binding<MKCoordinateRegion>, onUserInteraction: (() -> Void)? = nil) {
            self.region = region
            self.onUserInteraction = onUserInteraction
        }

        func updateOverlaysIfNeeded(on mapView: MKMapView, newCoordinates: [CLLocationCoordinate2D]) {
            guard newCoordinates != lastCoordinates else { return }
            // Remove all polylines (but not tile overlays)
            let overlaysToRemove = mapView.overlays.filter { !($0 is MKTileOverlay) }
            mapView.removeOverlays(overlaysToRemove)
            if newCoordinates.count > 1 {
                let glowPolyline = MKPolyline(coordinates: newCoordinates, count: newCoordinates.count)
                glowPolyline.title = "glow"
                mapView.addOverlay(glowPolyline, level: .aboveLabels)
                let mainPolyline = MKPolyline(coordinates: newCoordinates, count: newCoordinates.count)
                mainPolyline.title = "main"
                mapView.addOverlay(mainPolyline, level: .aboveLabels)
            }
            lastCoordinates = newCoordinates
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if isProgrammaticRegionChange {
                isProgrammaticRegionChange = false
                return
            }
            region.wrappedValue = mapView.region
            onUserInteraction?()
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // if let tileOverlay = overlay as? MKTileOverlay {
            //     return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            // }
            if let polyline = overlay as? MKPolyline {
                if polyline.title == "glow" {
                    let renderer = MKPolylineRenderer(polyline: polyline)
                    renderer.strokeColor = UIColor.white.withAlphaComponent(0.55)
                    renderer.lineWidth = 6
                    renderer.lineJoin = .round
                    renderer.lineCap = .round
                    return renderer
                } else if polyline.title == "main" {
                    let renderer = MKPolylineRenderer(polyline: polyline)
                    renderer.strokeColor = UIColor(red: 120/255, green: 0.7, blue: 1.0, alpha: 1.0) // Bright purple/indigo
                    renderer.lineWidth = 2 
                    renderer.lineJoin = .round
                    renderer.lineCap = .round
                    return renderer
                }
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }

    static func setNextProgrammaticRegionChange() {
        // This function can be used to set a flag for the next programmatic region change
    }
}

struct FloatingLabelTextField: View {
    let title: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(isFocused || !text.isEmpty ? .accentColor : .secondary)
                // .offset(y: isFocused || !text.isEmpty ? -20 : 0)
                .animation(.easeInOut(duration: 0.2), value: isFocused || !text.isEmpty)

            TextField("", text: $text)
                .keyboardType(keyboardType)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle()) // Make the whole area tappable
        .onTapGesture {
            isFocused = true
        }
    }
}

struct ContentView: View {
    @StateObject var viewModel = AppViewModel()
    @StateObject var locationManager = LocationManager()
    @State private var showingAlert = false
    @State private var mapSpan: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    @FocusState private var focusedField: Int?
    @State private var isAutoNavigating = false
    @State private var autoNavTimer: Timer? = nil
    @State private var programmaticRegionChangeID = UUID() // triggers region change
    @State private var isDrawerOpen = false // NEW: controls drawer menu

    init() {
        let vm = AppViewModel()
        _viewModel = StateObject(wrappedValue: vm)
        // Connect the view model's region change notification to our jumpToRegion function
        vm.notifyRegionChange = { [weak vm] region in
            guard let vm = vm else { return }
            // We need to access self (ContentView), but we can't do that directly in init
            // We'll use a DispatchQueue to break the reference cycle
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("JumpToRegion"), object: region)
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func jumpToRegion(_ region: MKCoordinateRegion) {
        isAutoNavigating = true
        programmaticRegionChangeID = UUID() // force update
        viewModel.mapRegion = region
        autoNavTimer?.invalidate()
        autoNavTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            isAutoNavigating = false
        }
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                MapPolylineView(
                    coordinates: viewModel.gpxCoordinates.map { $0.coordinate },
                    userLocation: locationManager.userLocation,
                    region: $viewModel.mapRegion,
                    isMapInteractionEnabled: !isAutoNavigating,
                    onUserInteraction: {
                        if isAutoNavigating {
                            isAutoNavigating = false
                            autoNavTimer?.invalidate()
                        }
                    },
                    programmaticRegionChangeID: programmaticRegionChangeID // new param
                )
                .edgesIgnoringSafeArea(.all)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    mapSpan = viewModel.mapRegion.span
                    // Set up notification observer for region changes
                    NotificationCenter.default.addObserver(
                        forName: NSNotification.Name("JumpToRegion"),
                        object: nil,
                        queue: .main) { notification in
                            if let region = notification.object as? MKCoordinateRegion {
                                self.jumpToRegion(region)
                            }
                        }
                }
                // Overlay controls and buttons
                VStack {
                    // Controls card moved up
                    HStack {
                        VStack(spacing: 4) {
                            Picker("Course", selection: $viewModel.selectedCourse) {
                                ForEach(viewModel.courses) { course in
                                    Text(course.name).tag(course as Course?)
                                }
                            }
                            .pickerStyle(.automatic)
                            HStack(spacing: 4) {
                                FloatingLabelTextField(title: NSLocalizedString("Bib Number", comment: "Bib input"), text: $viewModel.bib, keyboardType: .numberPad)
                                FloatingLabelTextField(title: NSLocalizedString("Birth Year", comment: "Birth year input"), text: $viewModel.birthYear, keyboardType: .numberPad)
                                    .onChange(of: viewModel.birthYear) { newValue in
                                        let filtered = newValue.filter { $0.isNumber }
                                        if filtered.count > 4 {
                                            viewModel.birthYear = String(filtered.prefix(4))
                                        } else if filtered != newValue {
                                            viewModel.birthYear = filtered
                                        }
                                    }
                                FloatingLabelTextField(title: NSLocalizedString("Race Code", comment: "Race code input"), text: $viewModel.code)
                                    .onChange(of: viewModel.code) { newValue in
                                        if newValue.count > 6 {
                                            viewModel.code = String(newValue.prefix(6))
                                        }
                                    }
                            }
                            // Button and progress indicator row
                            HStack(spacing: 12) {
                                Button(viewModel.isTracking ? NSLocalizedString("Stop Tracking", comment: "Stop tracking button") : NSLocalizedString("Start Tracking", comment: "Start tracking button")) {
                                    dismissKeyboard()
                                    if viewModel.isTracking {
                                        locationManager.stopTracking()
                                        viewModel.isTracking = false
                                        NotificationManager.shared.showTrackingNotification(isTracking: false)
                                    } else {
                                        viewModel.startTrackingIfPossible(locationManager: locationManager) { success in
                                            if (!success) {
                                                showingAlert = true
                                            } else {
                                                NotificationManager.shared.showTrackingNotification(isTracking: true)
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.isLoading) // Disable button while loading
                                .opacity(viewModel.isLoading ? 0.5 : 1.0) // Dim button while loading
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground).opacity(0.85))
                        .cornerRadius(16)
                        .shadow(radius: 8)
                        .padding(.top, 32) // Move up by reducing top padding
                        .padding(.horizontal, 16)
                    }
                    Spacer()
                }
                // Map overlay buttons: burger menu (bottom left), center/track (bottom right)
                // Bottom left: burger menu
                VStack {
                    Spacer()
                    HStack {
                        Button(action: {
                            withAnimation { isDrawerOpen = true }
                        }) {
                            Image(systemName: "line.3.horizontal")
                                .font(.title2)
                                .frame(width: 44, height: 44)
                                .background(Color(.systemBackground).opacity(0.85))
                                .clipShape(Circle())
                                .shadow(radius: 2)
                                .foregroundColor(.primary)
                        }
                        .padding(.leading, 18)
                        .padding(.bottom, 32)
                        Spacer()
                    }
                }
                // Bottom right: center track & center location
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 16) {
                            Button(action: {
                                if !viewModel.gpxCoordinates.isEmpty {
                                    var minLat = viewModel.gpxCoordinates.first!.coordinate.latitude
                                    var maxLat = minLat
                                    var minLon = viewModel.gpxCoordinates.first!.coordinate.longitude
                                    var maxLon = minLon
                                    for pt in viewModel.gpxCoordinates {
                                        minLat = min(minLat, pt.coordinate.latitude)
                                        maxLat = max(maxLat, pt.coordinate.latitude)
                                        minLon = min(minLon, pt.coordinate.longitude)
                                        maxLon = max(maxLon, pt.coordinate.longitude)
                                    }
                                    let latDelta = maxLat - minLat
                                    let lonDelta = maxLon - minLon
                                    let latPad = latDelta * 0.2
                                    let lonPad = lonDelta * 0.2
                                    let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
                                    let minSpan = 0.002
                                    let span = MKCoordinateSpan(
                                        latitudeDelta: max(latDelta + 2 * latPad, minSpan),
                                        longitudeDelta: max(lonDelta + 2 * lonPad, minSpan)
                                    )
                                    let region = MKCoordinateRegion(center: center, span: span)
                                    jumpToRegion(region)
                                }
                            }) {
                                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                                    .font(.title2)
                                    .padding(10)
                                    .background(Color(.systemBackground).opacity(0.85))
                                    .clipShape(Circle())
                                    .shadow(radius: 2)
                            }
                            .disabled(!viewModel.isTracking)
                            Button(action: {
                                if let userLoc = locationManager.userLocation {
                                    let region = MKCoordinateRegion(center: userLoc, span: viewModel.mapRegion.span)
                                    jumpToRegion(region)
                                }
                            }) {
                                Image(systemName: "location.fill")
                                    .font(.title2)
                                    .padding(10)
                                    .background(Color(.systemBackground).opacity(0.85))
                                    .clipShape(Circle())
                                    .shadow(radius: 2)
                            }
                            .disabled(!viewModel.isTracking)
                        }
                        .padding(.trailing, 18)
                        .padding(.bottom, 32)
                    }
                }
                // Runner info card (bottom center)
                VStack {
                    Spacer()
                    if viewModel.isTracking, let info = viewModel.runnerInfo {
                        RunnerInfoCard(info: info)
                            .padding(.bottom, 36)
                            .padding(.horizontal, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(2)
                    }
                }
                // Drawer menu overlay
                if isDrawerOpen {
                    Color.black.opacity(0.3)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                            withAnimation { isDrawerOpen = false }
                        }
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .center) {
                                // App logo and title
                                Image("kronologo")
                                     .renderingMode(.template)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 40, height: 40)
                                    .padding(.leading, 16)
                                    .foregroundColor(Color(UIColor { trait in
                                        trait.userInterfaceStyle == .dark
                                            ? UIColor(red: 0xA8/255, green: 0x95/255, blue: 0xF7/255, alpha: 1)
                                            : UIColor(red: 0x62/255, green: 0x00/255, blue: 0xEE/255, alpha: 1)
                                    }))
                                Text("KronoTrack")
                                    .font(.title2)
                                    .foregroundColor(Color(UIColor { trait in
                                        trait.userInterfaceStyle == .dark ? UIColor(red: 0xA8/255, green: 0x95/255, blue: 0xF7/255, alpha: 1) : UIColor(red: 0x62/255, green: 0x00/255, blue: 0xEE/255, alpha: 1)
                                    }))
                                    .padding(.leading, 8)
                                Spacer()
                                Button(action: { withAnimation { isDrawerOpen = false } }) {
                                    Image(systemName: "xmark")
                                        .font(.title2)
                                        .foregroundColor(.primary)
                                        .padding(12)
                                }
                            }
                            .padding(.top, 64)
                            .padding(.trailing, 8)
                            .padding(.bottom, 8)
                            // Divider below title
                            Divider().padding(.horizontal, 8)
                            Spacer().frame(height: 16)
                            Link("Politique de confidentialité", destination: URL(string: "https://kronotiming.fr/privacy")!)
                                .padding(.horizontal, 0)
                                .padding(.vertical, 12)
                            Spacer()
                        }
                        .frame(width: UIScreen.main.bounds.width * 0.66)
                        .background(Color(.systemBackground))
                        .edgesIgnoringSafeArea(.vertical)
                        Spacer()
                    }
                    .transition(.move(edge: .leading))
                    .zIndex(10)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                dismissKeyboard()
            }
            .onAppear {
                viewModel.fetchCourses()
            }
            .alert(isPresented: $showingAlert) {
                Alert(title: Text("Erreur"), message: Text(viewModel.errorMessage ?? "Erreur inconnue"), dismissButton: .default(Text("OK")))
            }
        }
    }
}

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var userLocation: CLLocationCoordinate2D? = nil
    @Published var isTracking: Bool = false
    private var lastUpload: Date? = nil
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let uploadInterval: TimeInterval = 60 // seconds
    override init() {
        super.init()
        manager.allowsBackgroundLocationUpdates = true
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        // Observe app state changes
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    @objc private func appDidEnterBackground() {
        manager.distanceFilter = 100
        manager.pausesLocationUpdatesAutomatically = true
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    @objc private func appWillEnterForeground() {
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    func requestPermissions(completion: ((Bool) -> Void)? = nil) {
        let status = CLLocationManager.authorizationStatus()
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.requestPermissions(completion: completion)
            }
            return
        } else if status == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.requestPermissions(completion: completion)
            }
            return
        }
        NotificationManager.shared.requestPermissions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let newStatus = CLLocationManager.authorizationStatus()
            completion?(newStatus == .authorizedAlways)
        }
    }
    func startTracking() {
        isTracking = true
        manager.startUpdatingLocation()
        // No more view model access here
    }
    func stopTracking() {
        isTracking = false
        manager.stopUpdatingLocation()
        // End any background task if running
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        // Clear runner info when tracking stops
        if let appVM = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first?.rootViewController as? UIHostingController<ContentView> })
            .first?.rootView.viewModel {
            appVM.runnerInfo = nil
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async {
            self.userLocation = loc.coordinate
        }
        // Throttle uploads to once per 60s
        let now = Date()
        if let last = lastUpload, now.timeIntervalSince(last) < uploadInterval {
            print("[LocationManager] Skipping upload, last upload was \(now.timeIntervalSince(last))s ago")
            return
        }
        lastUpload = now
        uploadLocation(location: loc)
    }
    private func uploadLocation(location: CLLocation) {
        print("will try to upload location")
        let token = "RyZpcmUpdU9jKz14cjA9e2wqMnF3WSRmNThDOmU4b3IqRjAvLTszMVorRV9DbUNiRihneSl7b1F9JH01c2ItVw"
        // Read all required info from UserDefaults
        let bib = UserDefaults.standard.string(forKey: "bib") ?? ""
        let birthYear = UserDefaults.standard.string(forKey: "birthYear") ?? ""
        let code = UserDefaults.standard.string(forKey: "code") ?? ""
        let mainEvent = UserDefaults.standard.string(forKey: "main_event") ?? ""
        guard !bib.isEmpty, !birthYear.isEmpty, !code.isEmpty, !mainEvent.isEmpty else {
            print("[LocationUpload] Missing required info in UserDefaults")
            return
        }
        let bibNumber = Int(bib) ?? 0
        let timestamp = Int64(location.timestamp.timeIntervalSince1970 * 1000) // ms since epoch
        let accuracy = location.horizontalAccuracy
        let payload: [String: Any] = [
            "token": token,
            "bib_number": bibNumber,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "main_event": mainEvent,
            "timestamp": timestamp,
            "accuracy": accuracy
        ]
        guard let url = URL(string: "https://track.kronotiming.fr/update-location") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        print("[LocationUpload] Payload: \(payload)")
        // Start background task
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LocationUpload") {
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                print("[LocationUpload] Error: \(error)")
            } else if let httpResp = response as? HTTPURLResponse {
                print("[LocationUpload] Response: \(httpResp.statusCode)")
            }
            if self.backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }.resume()
    }
}

class NotificationManager {
    static let shared = NotificationManager()
    private init() {}
    func requestPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    func showTrackingNotification(isTracking: Bool) {
        let content = UNMutableNotificationContent()
        content.title = isTracking ? NSLocalizedString("Krono Location: Tracking Active", comment: "Tracking active notification title") : NSLocalizedString("Krono Location: Tracking Stopped", comment: "Tracking stopped notification title")
        content.body = isTracking ? NSLocalizedString("Your location is being uploaded every minute.", comment: "Tracking active notification body") : NSLocalizedString("Tracking has stopped.", comment: "Tracking stopped notification body")
        let request = UNNotificationRequest(identifier: "trackingStatus", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

struct GPXParser {
    static func parseCoordinates(from gpx: String) -> [GPXPoint] {
        var coords: [GPXPoint] = []
        let regex = try! NSRegularExpression(pattern: #"<trkpt lat="([0-9.\-]+)" lon="([0-9.\-]+)""#, options: [])
        let nsrange = NSRange(gpx.startIndex..<gpx.endIndex, in: gpx)
        for match in regex.matches(in: gpx, options: [], range: nsrange) {
            if let latRange = Range(match.range(at: 1), in: gpx), let lonRange = Range(match.range(at: 2), in: gpx) {
                let lat = Double(gpx[latRange]) ?? 0
                let lon = Double(gpx[lonRange]) ?? 0
                coords.append(GPXPoint(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
            }
        }
        return coords;
    }
}

struct RunnerInfoCard: View {
    let info: RunnerInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.fill")
                    .foregroundColor(Color.purple)
                Text("\(info.firstName) \(info.lastName)")
                    .font(.headline)
            }
            HStack {
                Image(systemName: "flag.fill")
                    .foregroundColor(.secondary)
                Text(info.eventName)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 18)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.purple.opacity(0.3), lineWidth: 1)
        )
    }
}

extension CLLocationCoordinate2D: Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}

#Preview {
    ContentView()
}
