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
    func fetchGPX(for course: Course) {
        guard let url = URL(string: course.gpxUrl) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let gpxString = String(data: data, encoding: .utf8) else { return }
            let coords = GPXParser.parseCoordinates(from: gpxString)
            DispatchQueue.main.async {
                self.gpxCoordinates = coords
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
                // 4. Parse GPX points from response
                if let trackArr = obj["track"] as? [[String: Any]] {
                    let coords: [GPXPoint] = trackArr.compactMap { dict in
                        if let lat = dict["lat"] as? Double, let lon = dict["lon"] as? Double {
                            return GPXPoint(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                        }
                        return nil
                    }
                    DispatchQueue.main.async {
                        self.gpxCoordinates = coords
                        if let first = coords.first {
                            self.mapRegion.center = first.coordinate
                        }
                        self.errorMessage = nil
                    }
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

struct ContentView: View {
    @StateObject var viewModel = AppViewModel()
    @StateObject var locationManager = LocationManager()
    @State private var showingAlert = false
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    Map(coordinateRegion: $viewModel.mapRegion, annotationItems: viewModel.gpxCoordinates, annotationContent: { point in
                        MapPin(coordinate: point.coordinate)
                    })
                    .edgesIgnoringSafeArea(.all)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                TextField(NSLocalizedString("Race Code", comment: "Race code input"), text: $viewModel.code)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Button(viewModel.isTracking ? NSLocalizedString("Stop Tracking", comment: "Stop tracking button") : NSLocalizedString("Start Tracking", comment: "Start tracking button")) {
                                if viewModel.isTracking {
                                    locationManager.stopTracking()
                                    viewModel.isTracking = false
                                    NotificationManager.shared.showTrackingNotification(isTracking: false)
                                } else {
                                    viewModel.startTrackingIfPossible(locationManager: locationManager) { success in
                                        if !success {
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
#if !targetEnvironment(simulator)
        manager.allowsBackgroundLocationUpdates = true
#endif
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
    }
    func requestPermissions(completion: ((Bool) -> Void)? = nil) {
        manager.requestAlwaysAuthorization()
        NotificationManager.shared.requestPermissions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
#if targetEnvironment(simulator)
            completion?(true)
#else
            let status = CLLocationManager.authorizationStatus()
            completion?(status == .authorizedAlways || status == .authorizedWhenInUse)
#endif
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

#Preview {
    ContentView()
}
