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
import Combine

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

struct TrackMarker: Identifiable, Hashable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let type: String
    static func == (lhs: TrackMarker, rhs: TrackMarker) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.type == rhs.type
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(coordinate.latitude)
        hasher.combine(coordinate.longitude)
        hasher.combine(type)
    }
}

struct TrackData: Hashable {
    let points: [CLLocationCoordinate2D]
    let markers: [TrackMarker]
    static func == (lhs: TrackData, rhs: TrackData) -> Bool {
        lhs.points == rhs.points && lhs.markers == rhs.markers
    }
    func hash(into hasher: inout Hasher) {
        for pt in points {
            hasher.combine(pt.latitude)
            hasher.combine(pt.longitude)
        }
        for m in markers {
            hasher.combine(m)
        }
    }
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
    @Published var trackData: TrackData? = nil
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

    // Helper to compute region for a track
    static func regionForTrack(_ points: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !points.isEmpty else { return nil }
        var minLat = points.first!.latitude
        var maxLat = points.first!.latitude
        var minLon = points.first!.longitude
        var maxLon = points.first!.longitude
        for pt in points {
            minLat = min(minLat, pt.latitude)
            maxLat = max(maxLat, pt.latitude)
            minLon = min(minLon, pt.longitude)
            maxLon = max(maxLon, pt.longitude)
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
    func setRegionForTrack(_ coords: [CLLocationCoordinate2D]) {
        guard let region = Self.regionForTrack(coords) else { return }
        if let notifyRegionChange = self.notifyRegionChange {
            notifyRegionChange(region)
        } else {
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
            let coords = GPXParser.parseCoordinates(from: gpxString).map { $0.coordinate }
            DispatchQueue.main.async {
                self.trackData = TrackData(points: coords, markers: [])
                self.setRegionForTrack(coords)
            }
        }.resume()
    }
    func startTrackingIfPossible(_ locationManager: LocationManager, completion: @escaping (Bool) -> Void) {
        // 1. Validate input fields
        guard let course = selectedCourse, !bib.isEmpty, birthYear.count == 4, code.count == 6 else {
            DispatchQueue.main.async {
                self.errorMessage = NSLocalizedString("Please fill in all fields.", comment: "Missing fields")
                self.isLoading = false
            }
            completion(false)
            return
        }
        // Store selected course id to UserDefaults for background access
        UserDefaults.standard.set(course.id, forKey: "main_event")
        
        // 2. Call validation API
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
        
        // Debug output for API call
        #if DEBUG
        print("Sending API request: \(payload)")
        #endif
        
        URLSession.shared.dataTask(with: req) { data, response, error in
            // Print API response for debugging
            // if let data = data, let responseString = String(data: data, encoding: .utf8) {
            //     print("API Response: \(responseString)")
            // }
            
            // Handle network errors
            if let error = error {
#if DEBUG
                print("API Error: \(error.localizedDescription)")
#endif
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = NSLocalizedString("Server or network error", comment: "network error") + ": \(error.localizedDescription)"
                    completion(false)
                }
                return
            }
            
            // Handle HTTP errors with specific messages for 403 and 404
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
#if DEBUG
                print("API HTTP Error: \(httpResponse.statusCode)")
#endif
                DispatchQueue.main.async {
                    self.isLoading = false
                    switch httpResponse.statusCode {
                    case 404:
                        self.errorMessage = NSLocalizedString("Invalid bib number or birth year.", comment: "invalid bib or birth year")
                    case 403:
                        self.errorMessage = NSLocalizedString("Invalid code for this race.", comment: "invalid code")
                    default:
                        self.errorMessage = NSLocalizedString("Server error", comment: "Server error")
                    }
                    completion(false)
                }
                return
            }
            
            // Handle invalid JSON
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = NSLocalizedString("Failed to decode response.", comment: "JSON decoding error")
                    completion(false)
                }
                return
            }
            
            // Handle API errors
            if let errorMsg = obj["error"] as? String {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = errorMsg
                    completion(false)
                }
                return
            }
            
            // Parse track points
            var points: [CLLocationCoordinate2D] = []
            if let trackArr = obj["track"] as? [[Any]] {
                points = trackArr.compactMap { arr in
                    if arr.count == 2, let lat = arr[0] as? Double, let lon = arr[1] as? Double {
                        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    }
                    return nil
                }
            }
            // Parse markers (no label, just type)
            var markers: [TrackMarker] = []
            if let markerArr = obj["markers"] as? [[String: Any]] {
                for marker in markerArr {
                    if let lat = marker["lat"] as? Double,
                       let lon = marker["lon"] as? Double,
                       let type = marker["type"] as? String {
                        markers.append(TrackMarker(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), type: type))
                    }
                }
            }
            // Process runner info
            let firstName = obj["firstName"] as? String ?? ""
            let lastName = obj["lastName"] as? String ?? ""
            let eventName = obj["eventName"] as? String ?? self.selectedCourse?.name ?? ""
            
            // All good - update UI and start tracking
            DispatchQueue.main.async {
                self.trackData = TrackData(points: points, markers: markers)
                self.setRegionForTrack(points)
                
                self.runnerInfo = RunnerInfo(
                    firstName: firstName,
                    lastName: lastName,
                    eventName: eventName,
                    bib: self.bib,
                    birthYear: self.birthYear,
                    code: self.code
                )
                
                self.isLoading = false
                self.isTracking = true
                locationManager.startTracking()
                completion(true)
            }
        }.resume()
    }
}

// MARK: - MapPolylineView for SwiftUI

struct MapPolylineView: UIViewRepresentable {
    var trackData: TrackData?
    var userLocation: CLLocationCoordinate2D?
    @Binding var region: MKCoordinateRegion
    var isMapInteractionEnabled: Bool = true
    var onUserInteraction: (() -> Void)? = nil
    var programmaticRegionChangeID: UUID = UUID()

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.isZoomEnabled = isMapInteractionEnabled
        mapView.isScrollEnabled = isMapInteractionEnabled
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Remove overlays and annotations
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        // Draw polyline
        if let track = trackData, !track.points.isEmpty {
            let glowPolyline = MKPolyline(coordinates: track.points, count: track.points.count)
            glowPolyline.title = "glow"
            mapView.addOverlay(glowPolyline, level: .aboveLabels)
            let mainPolyline = MKPolyline(coordinates: track.points, count: track.points.count)
            mainPolyline.title = "main"
            mapView.addOverlay(mainPolyline, level: .aboveLabels)
            // Add markers
            for marker in track.markers {
                let annotation = MKPointAnnotation()
                annotation.coordinate = marker.coordinate
                annotation.title = markerTypeToLocalizedTitle(marker.type)
                mapView.addAnnotation(annotation)
            }
            // Add start marker at first point if not present
            if let first = track.points.first, !track.markers.contains(where: { $0.type == "start" }) {
                let annotation = MKPointAnnotation()
                annotation.coordinate = first
                annotation.title = markerTypeToLocalizedTitle("start")
                mapView.addAnnotation(annotation)
            }
        }
        // --- NEW: Animate to region if changed or programmaticRegionChangeID changes ---
        // Use associated object to store last region and last programmaticRegionChangeID
        struct Holder { static var lastRegion: MKCoordinateRegion?; static var lastID: UUID? }
        let regionChanged = Holder.lastRegion == nil ||
            Holder.lastRegion!.center.latitude != region.center.latitude ||
            Holder.lastRegion!.center.longitude != region.center.longitude ||
            Holder.lastRegion!.span.latitudeDelta != region.span.latitudeDelta ||
            Holder.lastRegion!.span.longitudeDelta != region.span.longitudeDelta
        let idChanged = Holder.lastID != programmaticRegionChangeID
        if regionChanged || idChanged {
            mapView.setRegion(region, animated: true)
            Holder.lastRegion = region
            Holder.lastID = programmaticRegionChangeID
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(region: $region, onUserInteraction: onUserInteraction)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var region: Binding<MKCoordinateRegion>
        var isProgrammaticRegionChange = false
        var lastProgrammaticRegionChangeID: UUID? = nil
        var onUserInteraction: (() -> Void)? = nil

        init(region: Binding<MKCoordinateRegion>, onUserInteraction: (() -> Void)? = nil) {
            self.region = region
            self.onUserInteraction = onUserInteraction
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
                    renderer.strokeColor = UIColor(red: 120/255, green: 0.7, blue: 1.0, alpha: 1.0)
                    renderer.lineWidth = 2
                    renderer.lineJoin = .round
                    renderer.lineCap = .round
                    return renderer
                }
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            let identifier = "TrackMarker"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.canShowCallout = true
            } else {
                view?.annotation = annotation
            }
            // Customize marker color/icon based on type
            let type = annotation.title ?? ""
            switch type {
            case NSLocalizedString("Water", comment: "marker type"):
                view?.markerTintColor = .systemBlue
                view?.glyphImage = UIImage(systemName: "drop.fill")
            case NSLocalizedString("Food", comment: "marker type"):
                view?.markerTintColor = .systemGreen
                view?.glyphImage = UIImage(systemName: "fork.knife")
            case NSLocalizedString("Signal", comment: "marker type"):
                view?.markerTintColor = .systemOrange
                view?.glyphImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
            case NSLocalizedString("Start", comment: "marker type"):
                view?.markerTintColor = .systemPurple
                view?.glyphImage = UIImage(systemName: "flag.fill")
            default:
                view?.markerTintColor = .systemGray
                view?.glyphImage = UIImage(systemName: "mappin")
            }
            return view
        }
    }

    private func markerTypeToLocalizedTitle(_ type: String) -> String {
        switch type.lowercased() {
        case "water": return NSLocalizedString("Water", comment: "marker type")
        case "food": return NSLocalizedString("Food", comment: "marker type")
        case "signal": return NSLocalizedString("Signal", comment: "marker type")
        case "start": return NSLocalizedString("Start", comment: "marker type")
        default: return type.capitalized
        }
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

// Alert handling with identifiable alert items
enum AlertType: Identifiable {
    case error(message: String)
    case locationServicesDisabled
    case locationPermission
    case preciseLocation
    case notificationPermission
    case trackingDisabled
    
    var id: Int {
        switch self {
        case .error: return 0
        case .locationServicesDisabled: return 4
        case .locationPermission: return 1
        case .preciseLocation: return 2
        case .notificationPermission: return 3
        case .trackingDisabled: return 5
        }
    }
    
    var titleKey: String {
        switch self {
        case .error: return "Error"
        case .locationServicesDisabled: return "Location Services"
        case .locationPermission: return "Background Location"
        case .preciseLocation: return "Precise Location"
        case .notificationPermission: return "Notifications"
        case .trackingDisabled: return "Tracking Disabled"
        }
    }
    
    var messageKey: String? {
        switch self {
        case .error(let message): return message // Already localized or dynamic
        case .locationServicesDisabled: return "To start tracking, please enable Location Services in Settings > Privacy & Security > Location Services."
        case .locationPermission: return "To start tracking, please allow access to your precise location, set to 'Always'."
        case .preciseLocation: return "To start tracking, please enable 'Precise Location' and 'Always' in your location settings."
        case .notificationPermission: return "To start tracking, please allow notifications."
        case .trackingDisabled: return "Tracking has been disabled because location permissions changed or Location Services were turned off."
        }
    }
}

struct ContentView: View {
    @StateObject var viewModel = AppViewModel()
    @StateObject var locationManager = LocationManager()
    @State private var currentAlert: AlertType? = nil
    @State private var mapSpan: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    @FocusState private var focusedField: Int?
    @State private var isAutoNavigating = false
    @State private var autoNavTimer: Timer? = nil
    @State private var programmaticRegionChangeID = UUID() // triggers region change
    @State private var isDrawerOpen = false // NEW: controls drawer menu
    @State private var cancellables: Set<AnyCancellable> = [] // NEW

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

    // Helper to open app settings
    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func handleStartTracking() {
        viewModel.isLoading = true

        if !CLLocationManager.locationServicesEnabled() {
            viewModel.isLoading = false
            currentAlert = .locationServicesDisabled
            return
        }

        let locationStatus = CLLocationManager.authorizationStatus()
#if DEBUG
        print("location status: \(locationStatus)")
#endif

        if locationStatus == .notDetermined {
#if DEBUG
            print("Requesting when in use authorization from handlestarttracking")
#endif
            viewModel.isLoading = false
            locationManager.manager.requestWhenInUseAuthorization()
            return
        }

        if locationStatus != .authorizedAlways {
#if DEBUG
            print("location status: not always authorized, user has to manually change")
#endif
            viewModel.isLoading = false
            currentAlert = .locationPermission
            return
        }

        let preciseLocation = locationManager.manager.accuracyAuthorization == .fullAccuracy
#if DEBUG
        print("precise location: \(preciseLocation)")
#endif
        if !preciseLocation {
#if DEBUG
            print("location status: precise location not granted")
#endif
            viewModel.isLoading = false
            currentAlert = .preciseLocation
            return
        }

        locationPermissionCheckedContinue()
    }

    private func locationPermissionCheckedContinue() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .notDetermined:
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                        DispatchQueue.main.async {
                            if granted {
                                self.continueStartTracking()
                            } else {
                                self.viewModel.isLoading = false
                                self.currentAlert = .notificationPermission
                            }
                        }
                    }
                case .denied:
                    self.viewModel.isLoading = false
                    self.currentAlert = .notificationPermission
                case .authorized, .provisional, .ephemeral:
                    self.continueStartTracking()
                @unknown default:
                    self.continueStartTracking()
                }
            }
        }
    }
    
    private func continueStartTracking() {
        viewModel.startTrackingIfPossible(locationManager) { success in
            DispatchQueue.main.async {
                self.viewModel.isLoading = false
                
                if success {
#if DEBUG
                    print("Tracking started successfully")
#endif
                    // Tracking started successfully
                } else if let errorMessage = self.viewModel.errorMessage {
                    // Show the error message from the view model
                    self.currentAlert = .error(message: errorMessage)
                } else {
                    // Generic error case
                    self.currentAlert = .error(message: NSLocalizedString("Start tracking error", comment: "start error"))
                }
            }
        }
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                MapPolylineView(
                    trackData: viewModel.trackData,
                    userLocation: locationManager.userLocation,
                    region: $viewModel.mapRegion,
                    isMapInteractionEnabled: !isAutoNavigating,
                    onUserInteraction: {
                        if isAutoNavigating {
                            isAutoNavigating = false
                            autoNavTimer?.invalidate()
                        }
                    },
                    programmaticRegionChangeID: programmaticRegionChangeID
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
                    // Ensure initial centering if trackData exists
                    if let points = viewModel.trackData?.points, !points.isEmpty {
                        if let region = AppViewModel.regionForTrack(points) {
                            jumpToRegion(region)
                        }
                    }
                }
                // Overlay controls and buttons
                VStack {
                    // Controls card moved up
                    HStack {
                        VStack(spacing: 4) {
                            Picker(NSLocalizedString("Race", comment: "Race"), selection: $viewModel.selectedCourse) {
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
                                    } else {
                                        // Use the dedicated method instead of inline logic
                                        handleStartTracking()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(viewModel.isLoading || viewModel.bib.isEmpty || viewModel.birthYear.isEmpty || viewModel.code.isEmpty) // Disable if any field is empty or loading
                                .opacity(viewModel.isLoading ? 0.5 : 1.0) // Dim button while loading
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground).opacity(0.85))
                        .cornerRadius(16)
                        .shadow(radius: 8)
                        .padding(.top, 16)
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
                                if let points = viewModel.trackData?.points, !points.isEmpty {
                                    if let region = AppViewModel.regionForTrack(points) {
                                        jumpToRegion(region)
                                    }
                                }
                            }) {
                                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                                    .font(.title2)
                                    .padding(10)
                                    .background(Color(.systemBackground).opacity(0.85))
                                    .clipShape(Circle())
                                    .shadow(radius: 2)
                            }
                            .disabled(!(viewModel.trackData?.points.isEmpty == false))
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
                            HStack {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.accentColor)
                                Link(NSLocalizedString("Privacy Policy", comment: "privacy"), destination: URL(string: "https://kronotiming.fr/privacy")!)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 12)
                            HStack {
                                Image(systemName: "flag.checkered")
                                    .foregroundColor(.accentColor)
                                Link(NSLocalizedString("Results", comment: "results"), destination: URL(string: "https://live.kronotiming.fr/results")!)
                            }
                            .padding(.horizontal, 4)
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
                setupLocationTrackingDisabledAlertObserver()
                // Propagate isTracking from LocationManager to viewModel
                locationManager.$isTracking
                    .receive(on: RunLoop.main)
                    .sink { newValue in
                        viewModel.isTracking = newValue
                    }
                    .store(in: &cancellables)
            }
            // Unified alert system for all types of alerts
            .alert(item: $currentAlert) { alertType in
                switch alertType {
                case .error(let message):
                    return Alert(
                        title: Text(NSLocalizedString(alertType.titleKey, comment: "")),
                        message: Text(message),
                        dismissButton: .default(Text("OK"))
                    )
                case .locationServicesDisabled, .trackingDisabled:
                    return Alert(
                        title: Text(NSLocalizedString(alertType.titleKey, comment: "")),
                        message: Text(alertType.messageKey != nil && !alertType.messageKey!.isEmpty ? NSLocalizedString(alertType.messageKey!, comment: "") : ""),
                        dismissButton: .default(Text("OK"))
                    )
                case .locationPermission, .preciseLocation, .notificationPermission:
                    return Alert(
                        title: Text(NSLocalizedString(alertType.titleKey, comment: "")),
                        message: Text(alertType.messageKey != nil && !alertType.messageKey!.isEmpty ? NSLocalizedString(alertType.messageKey!, comment: "") : ""),
                        primaryButton: .default(Text(NSLocalizedString("Open app settings", comment: "app settings"))) {
                            openAppSettings()
                        },
                        secondaryButton: .cancel(Text(NSLocalizedString("Cancel", comment: "cancel")))
                    )
                }
            }
        }
    }
}

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    internal let manager = CLLocationManager()
    @Published var userLocation: CLLocationCoordinate2D? = nil
    @Published var isTracking: Bool = false
    private var lastUpload: Date? = nil
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let uploadInterval: TimeInterval = 60 // seconds
    // --- NEW: Track if we're awaiting authorization and provide a callback ---
    var awaitingAuthorization: Bool = false
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)? = nil

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
        // manager.distanceFilter = kCLDistanceFilterNone
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    @objc private func appWillEnterForeground() {
        manager.distanceFilter = kCLDistanceFilterNone
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }
    func startTracking() {
        isTracking = true
        manager.startUpdatingLocation()
        // manager.startMonitoringSignificantLocationChanges()
        
        // Ensure we update the status immediately and handle notifications
        DispatchQueue.main.async {
            // Show notification in a small delay to ensure it appears after the UI is updated
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Refresh notification on tracking start
                NotificationManager.shared.showTrackingNotification(isTracking: true)
#if DEBUG
                print("📍 Tracking started and notification requested")
#endif
            }
        }
    }
    
    func stopTracking() {
        isTracking = false
        manager.stopUpdatingLocation()
        
        // Make sure notification is updated when tracking stops
        DispatchQueue.main.async {
            NotificationManager.shared.showTrackingNotification(isTracking: false)
#if DEBUG
            print("🛑 Tracking stopped and notifications cleared")
#endif
        }
        
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
#if DEBUG
            print("[LocationManager] Skipping upload, last upload was \(now.timeIntervalSince(last))s ago")
#endif
            return
        }
        lastUpload = now
        uploadLocation(location: loc)
    }
    private func uploadLocation(location: CLLocation) {
        #if DEBUG
            print("will try to upload location")
        #endif
        let token = "RyZpcmUpdU9jKz14cjA9e2wqMnF3WSRmNThDOmU4b3IqRjAvLTszMVorRV9DbUNiRihneSl7b1F9JH01c2ItVw"
        // Read all required info from UserDefaults
        let bib = UserDefaults.standard.string(forKey: "bib") ?? ""
        let birthYear = UserDefaults.standard.string(forKey: "birthYear") ?? ""
        let code = UserDefaults.standard.string(forKey: "code") ?? ""
        let mainEvent = UserDefaults.standard.string(forKey: "main_event") ?? ""
        guard !bib.isEmpty, !birthYear.isEmpty, !code.isEmpty, !mainEvent.isEmpty else {
#if DEBUG
            print("[LocationUpload] Missing required info in UserDefaults")
#endif
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
#if DEBUG
        print("[LocationUpload] Payload: \(payload)")
#endif
        // Start background task
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LocationUpload") {
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
#if DEBUG
                print("[LocationUpload] Error: \(error)")
#endif
            } else if let httpResp = response as? HTTPURLResponse {
#if DEBUG
                print("[LocationUpload] Response: \(httpResp.statusCode)")
#endif
            }
            if self.backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }.resume()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
#if DEBUG
        print("locationManagerDidChangeAuthorization status changed: \(status)")
#endif
        
        // Check if location services are enabled
        if isTracking && !CLLocationManager.locationServicesEnabled() {
#if DEBUG
            print("Location services disabled, stopping tracking")
#endif
            self.stopTracking() 
            isTracking = false
            NotificationCenter.default.post(name: NSNotification.Name("LocationTrackingDisabledAlert"), object: AlertType.trackingDisabled)
            NotificationManager.shared.showSimpleNotification(title: "Suivi désactivé", body: "Le suivi a été arrêté car le service de localisation a été désactivé.")
            return
        }

        // If not authorizedAlways, stop tracking and alert
        if isTracking && status != .authorizedAlways {
#if DEBUG
            print("Authorization lost (not always authorized), stopping tracking")
#endif
            self.stopTracking()
            isTracking = false
            NotificationCenter.default.post(name: NSNotification.Name("LocationTrackingDisabledAlert"), object: AlertType.trackingDisabled)
            NotificationManager.shared.showSimpleNotification(title: "Suivi désactivé", body: "Le suivi a été arrêté car l'autorisation de position \"Toujours\" n'est plus accordée.")
            return
        }

        let preciseLocation = manager.accuracyAuthorization == .fullAccuracy
        if isTracking && !preciseLocation {
#if DEBUG
            print("Precise location lost, stopping tracking")
#endif
            self.stopTracking()
            isTracking = false
            NotificationCenter.default.post(name: NSNotification.Name("LocationTrackingDisabledAlert"), object: AlertType.trackingDisabled)
            NotificationManager.shared.showSimpleNotification(title: "Suivi désactivé", body: "Le suivi a été arrêté car l'autorisation de position exacte n'est plus accordée.")
            return
        }

        if status == .notDetermined {
#if DEBUG
            print("Requesting when in use authorization")
#endif
            manager.requestWhenInUseAuthorization()
            return
        }

        if status == .authorizedWhenInUse {
#if DEBUG
            print("Requesting always authorization")
#endif
            manager.requestAlwaysAuthorization()
            return
        }

        if status == .denied {
#if DEBUG
            print("Denied, will show alert when tracking is disabled")
#endif
            return
        }

        if status == .authorizedAlways {
#if DEBUG
            print("Authorized always, nothing to do")
#endif
            return
        }
    }
}

// --- Add observer in ContentView to show alert when tracking is disabled ---
extension ContentView {
    private func setupLocationTrackingDisabledAlertObserver() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("LocationTrackingDisabledAlert"), object: nil, queue: .main) { notification in
            if let alertType = notification.object as? AlertType {
                self.currentAlert = alertType
            }
        }
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
