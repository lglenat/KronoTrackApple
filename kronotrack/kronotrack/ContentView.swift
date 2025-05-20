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

    func fetchCourses() {
        guard let url = URL(string: "https://krono.timing.server/api/courses") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let courses = try? JSONDecoder().decode([Course].self, from: data) else { return }
            DispatchQueue.main.async {
                self.courses = courses
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
    // ...location tracking and upload logic will be added here...
}

struct ContentView: View {
    @StateObject var viewModel = AppViewModel()
    @StateObject var locationManager = LocationManager()
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Form {
                    Picker("Course", selection: $viewModel.selectedCourse) {
                        ForEach(viewModel.courses) { course in
                            Text(course.name).tag(course as Course?)
                        }
                    }
                    .onAppear { viewModel.fetchCourses() }
                    TextField("Bib Number", text: $viewModel.bib)
                        .keyboardType(.numberPad)
                    TextField("Birth Year", text: $viewModel.birthYear)
                        .keyboardType(.numberPad)
                    TextField("Race Code", text: $viewModel.code)
                    if let course = viewModel.selectedCourse {
                        Button("Show GPX Track") {
                            viewModel.fetchGPX(for: course)
                        }
                    }
                    Button(viewModel.isTracking ? "Stop Tracking" : "Start Tracking") {
                        if viewModel.isTracking {
                            locationManager.stopTracking()
                            viewModel.isTracking = false
                            NotificationManager.shared.showTrackingNotification(isTracking: false)
                        } else {
                            NotificationManager.shared.requestPermissions()
                            locationManager.requestPermissions()
                            locationManager.startTracking()
                            viewModel.isTracking = true
                            NotificationManager.shared.showTrackingNotification(isTracking: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: 340) // About half the screen on most iPhones
                Divider()
                Map(coordinateRegion: $viewModel.mapRegion, annotationItems: viewModel.gpxCoordinates, annotationContent: { point in
                    MapPin(coordinate: point.coordinate)
                })
                .edgesIgnoringSafeArea(.bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Krono Location")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let userLoc = locationManager.userLocation {
                        Text("\u{1F4CD} ") + Text("\(userLoc.latitude), \(userLoc.longitude)")
                    }
                }
            }
        }
        .onAppear {
            viewModel.fetchCourses()
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
    func requestPermissions() {
        manager.requestAlwaysAuthorization()
        NotificationManager.shared.requestPermissions()
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
        content.title = isTracking ? "Krono Location: Tracking Active" : "Krono Location: Tracking Stopped"
        content.body = isTracking ? "Your location is being uploaded every minute." : "Tracking has stopped."
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
        return coords
    }
}

#Preview {
    ContentView()
}
