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
    @Published var bib: String = ""
    @Published var birthYear: String = ""
    @Published var code: String = ""
    @Published var isTracking: Bool = false
    @Published var mapRegion = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48.858844, longitude: 2.294351), span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
    @Published var gpxCoordinates: [GPXPoint] = []
    @Published var userLocation: CLLocationCoordinate2D? = nil
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var runnerInfo: RunnerInfo? = nil

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
        guard !coords.isEmpty else { return }
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
        // Improved padding: 20% on each side (total 40%)
        let latDelta = maxLat - minLat
        let lonDelta = maxLon - minLon
        let latPad = latDelta * 0.2
        let lonPad = lonDelta * 0.2
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        // Ensure a minimum span so the map doesn't zoom in too much
        let minSpan = 0.002
        let span = MKCoordinateSpan(
            latitudeDelta: max(latDelta + 2 * latPad, minSpan),
            longitudeDelta: max(lonDelta + 2 * lonPad, minSpan)
        )
        DispatchQueue.main.async {
            withAnimation {
                self.mapRegion = MKCoordinateRegion(center: center, span: span)
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
            print("Krono payload: \(payload)") // DEBUG: print payload
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            URLSession.shared.dataTask(with: req) { data, response, error in
                DispatchQueue.main.async {
                    self.isLoading = false
                }
                // DEBUG: print server response
                if let data = data, let str = String(data: data, encoding: .utf8) {
                    print("Krono response: \(str)")
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
                // 4. Parse track points from response (array of [lat, lon])
                if let trackArr = obj["track"] as? [[Any]] {
                    let coords: [GPXPoint] = trackArr.compactMap { arr in
                        if arr.count == 2, let lat = arr[0] as? Double, let lon = arr[1] as? Double {
                            return GPXPoint(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                        }
                        return nil
                    }
                    DispatchQueue.main.async {
                        self.gpxCoordinates = coords
                        self.setRegionForTrack(coords)
                        self.errorMessage = nil
                    }
                }
                // 4b. Parse runner info if present
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
                // 5. Mark as tracking
                DispatchQueue.main.async {
                    self.isTracking = true
                }
                // 6. Start location updates
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

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.setRegion(region, animated: false)
        // Add OpenTopoMap tile overlay ONCE here only
        let overlay = MKTileOverlay(urlTemplate: "https://tile.opentopomap.org/{z}/{x}/{y}.png")
        overlay.canReplaceMapContent = true
        mapView.addOverlay(overlay, level: .aboveRoads)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Only remove and add polylines, NOT the tile overlay
        let overlaysToRemove = mapView.overlays.filter { !($0 is MKTileOverlay) }
        mapView.removeOverlays(overlaysToRemove)
        if coordinates.count > 1 {
            let glowPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            glowPolyline.title = "glow"
            mapView.addOverlay(glowPolyline, level: .aboveLabels)
            let mainPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            mainPolyline.title = "main"
            mapView.addOverlay(mainPolyline, level: .aboveLabels)
        }
        // ...existing code for zoom restriction and logging...
        let maxZoomDelta = 180.0 / pow(2.0, 15.0)
        let minZoomDelta = 180.0 / pow(2.0, 0.0)
        let minSpan = maxZoomDelta
        let maxSpan = minZoomDelta
        var regionToSet = region
        regionToSet.span.latitudeDelta = min(max(region.span.latitudeDelta, minSpan), maxSpan)
        regionToSet.span.longitudeDelta = min(max(region.span.longitudeDelta, minSpan), maxSpan)
        let zoomLat = log2(180.0 / regionToSet.span.latitudeDelta)
        let zoomLon = log2(180.0 / regionToSet.span.longitudeDelta)
        let zoomLevel = min(zoomLat, zoomLon)
        // print("[Map] Current zoom level: z=\(zoomLevel)")
        if mapView.region.center.latitude != regionToSet.center.latitude ||
            mapView.region.center.longitude != regionToSet.center.longitude ||
            mapView.region.span.latitudeDelta != regionToSet.span.latitudeDelta ||
            mapView.region.span.longitudeDelta != regionToSet.span.longitudeDelta {
            context.coordinator.isProgrammaticRegionChange = true
            mapView.setRegion(regionToSet, animated: true)
        }
        // Remove custom user location annotation: rely on showsUserLocation for blue dot
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(region: $region)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var region: Binding<MKCoordinateRegion>
        var isProgrammaticRegionChange = false
        init(region: Binding<MKCoordinateRegion>) {
            self.region = region
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if isProgrammaticRegionChange {
                isProgrammaticRegionChange = false
                return
            }
            region.wrappedValue = mapView.region
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            if let polyline = overlay as? MKPolyline {
                if polyline.title == "glow" {
                    let renderer = MKPolylineRenderer(polyline: polyline)
                    renderer.strokeColor = UIColor.white.withAlphaComponent(0.55)
                    renderer.lineWidth = 10
                    renderer.lineJoin = .round
                    renderer.lineCap = .round
                    return renderer
                } else if polyline.title == "main" {
                    let renderer = MKPolylineRenderer(polyline: polyline)
                    renderer.strokeColor = UIColor(red: 120/255, green: 0.7, blue: 1.0, alpha: 1.0) // Bright purple/indigo
                    renderer.lineWidth = 4
                    renderer.lineJoin = .round
                    renderer.lineCap = .round
                    return renderer
                }
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

struct ContentView: View {
    @StateObject var viewModel = AppViewModel()
    @StateObject var locationManager = LocationManager()
    @State private var showingAlert = false
    // Add a state for map zoom
    @State private var mapSpan: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)

    private func zoom(factor: Double) {
        let maxZoomDelta = 180.0 / pow(2.0, 19.0) // ~0.000343
        let minZoomDelta = 180.0 / pow(2.0, 0.0)  // 180.0 (whole world)
        let minSpan = maxZoomDelta
        let maxSpan = minZoomDelta
        let newLat = min(max(viewModel.mapRegion.span.latitudeDelta * factor, minSpan), maxSpan)
        let newLon = min(max(viewModel.mapRegion.span.longitudeDelta * factor, minSpan), maxSpan)
        viewModel.mapRegion.span = MKCoordinateSpan(latitudeDelta: newLat, longitudeDelta: newLon)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    // Use MapPolylineView instead of Map
                    MapPolylineView(coordinates: viewModel.gpxCoordinates.map { $0.coordinate }, userLocation: locationManager.userLocation, region: $viewModel.mapRegion)
                        .edgesIgnoringSafeArea(.all)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear {
                            // Sync initial span
                            mapSpan = viewModel.mapRegion.span
                        }
                    // Center on user location button overlay
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            VStack(spacing: 12) {
                                // Focus on GPX track button
                                Button(action: {
                                    viewModel.setRegionForTrack(viewModel.gpxCoordinates)
                                }) {
                                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                                        .font(.title2)
                                        .padding(10)
                                        .background(Color(.systemBackground).opacity(0.85))
                                        .clipShape(Circle())
                                        .shadow(radius: 2)
                                }
                                // My location button (existing)
                                Button(action: {
                                    if let userLoc = locationManager.userLocation {
                                        print("[DEBUG] Go to my location button tapped. User location: \(userLoc.latitude), \(userLoc.longitude)")
                                        viewModel.mapRegion = MKCoordinateRegion(center: userLoc, span: viewModel.mapRegion.span)
                                    } else {
                                        print("[DEBUG] Go to my location button tapped. User location is nil.")
                                    }
                                }) {
                                    Image(systemName: "location.fill")
                                        .font(.title2)
                                        .padding(10)
                                        .background(Color(.systemBackground).opacity(0.85))
                                        .clipShape(Circle())
                                        .shadow(radius: 2)
                                }
                            }
                            .padding(.leading, 18)
                            .padding(.bottom, 32)
                            Spacer()
                            if viewModel.isTracking, let info = viewModel.runnerInfo {
                                RunnerInfoCard(info: info)
                                    .padding(.bottom, 36)
                                    .padding(.horizontal, 8)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                                    .zIndex(2)
                            }
                            Spacer()
                            VStack(spacing: 12) {
                                Button(action: { zoom(factor: 0.5) }) {
                                    Image(systemName: "plus.magnifyingglass")
                                        .font(.title2)
                                        .padding(10)
                                        .background(Color(.systemBackground).opacity(0.85))
                                        .clipShape(Circle())
                                        .shadow(radius: 2)
                                }
                                Button(action: { zoom(factor: 2.0) }) {
                                    Image(systemName: "minus.magnifyingglass")
                                        .font(.title2)
                                        .padding(10)
                                        .background(Color(.systemBackground).opacity(0.85))
                                        .clipShape(Circle())
                                        .shadow(radius: 2)
                                }
                            }
                            .padding(.trailing, 18)
                            .padding(.bottom, 32)
                        }
                    }
                    // ...existing code for HStack with controls...
                    HStack { // Add HStack to allow horizontal padding
                        VStack(spacing: 12) {
                            Picker("Course", selection: $viewModel.selectedCourse) {
                                ForEach(viewModel.courses) { course in
                                    Text(course.name).tag(course as Course?)
                                }
                            }
                            .pickerStyle(.automatic)
                            HStack(spacing: 8) {
                                TextField(NSLocalizedString("Bib Number", comment: "Bib input"), text: $viewModel.bib)
                                    .keyboardType(.numberPad)
                                    .textFieldStyle(.roundedBorder)
                                TextField(NSLocalizedString("Birth Year", comment: "Birth year input"), text: $viewModel.birthYear)
                                    .keyboardType(.numberPad)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: viewModel.birthYear) { newValue in
                                        // Only allow up to 4 digits
                                        let filtered = newValue.filter { $0.isNumber }
                                        if filtered.count > 4 {
                                            viewModel.birthYear = String(filtered.prefix(4))
                                        } else if filtered != newValue {
                                            viewModel.birthYear = filtered
                                        }
                                    }
                                TextField(NSLocalizedString("Race Code", comment: "Race code input"), text: $viewModel.code)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: viewModel.code) { newValue in
                                        // Only allow up to 6 characters
                                        if (newValue.count > 6) {
                                            viewModel.code = String(newValue.prefix(6))
                                        }
                                    }
                            }
                            Button(viewModel.isTracking ? NSLocalizedString("Stop Tracking", comment: "Stop tracking button") : NSLocalizedString("Start Tracking", comment: "Start tracking button")) {
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
                            .disabled(viewModel.isLoading)
                            if viewModel.isLoading {
                                ProgressView()
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground).opacity(0.85))
                        .cornerRadius(16)
                        .shadow(radius: 8)
                        .padding(.top, 16)
                        .padding(.horizontal, 16)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("KronoTrack", comment: "App title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Link(NSLocalizedString("Privacy Policy", comment: "Privacy policy link"), destination: URL(string: "https://kronotiming.fr/privacy")!)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    if let userLoc = locationManager.userLocation {
                        Text("\u{1F4CD} ") + Text("\(userLoc.latitude), \(userLoc.longitude)")
                    }
                }
            }
        }
        .onAppear {
            viewModel.fetchCourses()
        }
        .alert(isPresented: $showingAlert) {
            Alert(title: Text("Erreur"), message: Text(viewModel.errorMessage ?? "Erreur inconnue"), dismissButton: .default(Text("OK")))
        }
    }
}

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var userLocation: CLLocationCoordinate2D? = nil
    @Published var isTracking: Bool = false
    private var uploadTimer: Timer?
    private var lastUpload: Date? = nil
    override init() {
        super.init()
// #if !targetEnvironment(simulator)
        manager.allowsBackgroundLocationUpdates = true
// #endif
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
    }
    func requestPermissions(completion: ((Bool) -> Void)? = nil) {
        manager.requestAlwaysAuthorization()
        NotificationManager.shared.requestPermissions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
// #if targetEnvironment(simulator)
            completion?(true)
// #else
            let status = CLLocationManager.authorizationStatus()
            completion?(status == .authorizedAlways || status == .authorizedWhenInUse)
// #endif
        }
    }
    func startTracking() {
        isTracking = true
        manager.startUpdatingLocation()
        startUploadTimer()
    }
    func stopTracking() {
        isTracking = false
        manager.stopUpdatingLocation()
        stopUploadTimer()
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
    }
    private func startUploadTimer() {
        uploadTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.uploadLocation()
        }
    }
    private func stopUploadTimer() {
        uploadTimer?.invalidate()
        uploadTimer = nil
    }
    private func uploadLocation() {
        guard let coord = userLocation else { return }
        // TODO: Add bib, birthYear, code, course, and server endpoint
        let payload: [String: Any] = [
            "lat": coord.latitude,
            "lon": coord.longitude,
            "timestamp": Date().timeIntervalSince1970,
            "bib": AppViewModel().bib,
            "birthYear": AppViewModel().birthYear,
            "code": AppViewModel().code,
            "courseId": AppViewModel().selectedCourse?.id ?? ""
        ]
        guard let url = URL(string: "https://krono.timing.server/api/location") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
        lastUpload = Date()
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

#Preview {
    ContentView()
}
