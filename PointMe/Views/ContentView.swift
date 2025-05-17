import SwiftUI
import MapKit
import CoreLocation
import CoreHaptics
import CoreMotion
import ActivityKit

// MARK: - Models

struct Place: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: Place, rhs: Place) -> Bool {
        return lhs.id == rhs.id &&
               lhs.name == rhs.name &&
               lhs.address == rhs.address &&
               lhs.coordinate.latitude == rhs.coordinate.latitude &&
               lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentLocation: CLLocationCoordinate2D?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            DispatchQueue.main.async {
                self.currentLocation = loc.coordinate
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Failed to get location: \(error.localizedDescription)")
    }
}

// MARK: - ViewModel

class MapSearchViewModel: NSObject, ObservableObject {
    @Published var searchText: String = "" {
        didSet {
            if !searchText.isEmpty {
                performSearch()
            } else {
                places = []
            }
        }
    }
    @Published var places: [Place] = []
    @Published var selectedPlace: Place? = nil
    @Published var destination: CLLocationCoordinate2D? = nil

    private var locationManager = LocationManager()
    private let searchQueue = DispatchQueue(label: "searchQueue")

    func performSearch() {
        guard let currentLoc = locationManager.currentLocation else {
            places = []
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        request.region = MKCoordinateRegion(
            center: currentLoc,
            latitudinalMeters: 5000,
            longitudinalMeters: 5000
        )

        let search = MKLocalSearch(request: request)
        search.start { [weak self] response, error in
            guard let self = self else { return }
            if let items = response?.mapItems {
                let newPlaces = items.map {
                    Place(
                        name: $0.name ?? "不明",
                        address: $0.placemark.title ?? "住所不明",
                        coordinate: $0.placemark.coordinate
                    )
                }
                DispatchQueue.main.async {
                    self.places = newPlaces
                }
            } else {
                DispatchQueue.main.async {
                    self.places = []
                }
            }
        }
    }

    func setDestination(place: Place) {
        destination = place.coordinate
        selectedPlace = place
    }

    var currentLocation: CLLocationCoordinate2D? {
        locationManager.currentLocation
    }

    // MARK: Navigation helpers

    private var motionManager = CMMotionManager()
    @Published var hasArrived = false
    private var engine: CHHapticEngine?

    var distanceToDestination: Double {
        guard let current = currentLocation,
              let dest = destination else { return 0 }
        let currentLoc = CLLocation(latitude: current.latitude, longitude: current.longitude)
        let destLoc = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
        return currentLoc.distance(from: destLoc)
    }

    var directionAngle: Double {
        guard let current = currentLocation,
              let dest = destination else { return 0 }
        let currentLoc = CLLocation(latitude: current.latitude, longitude: current.longitude)
        let destLoc = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
        let bearing = bearingBetween(startLocation: currentLoc, endLocation: destLoc)
        let headingDegrees = (motionManager.deviceMotion?.attitude.yaw ?? 0) * 180 / .pi
        let angle = bearing - headingDegrees
        return angle
    }

    private func bearingBetween(startLocation: CLLocation, endLocation: CLLocation) -> Double {
        let lat1 = startLocation.coordinate.latitude.toRadians()
        let lon1 = startLocation.coordinate.longitude.toRadians()
        let lat2 = endLocation.coordinate.latitude.toRadians()
        let lon2 = endLocation.coordinate.longitude.toRadians()

        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radiansBearing = atan2(y, x)

        var degreesBearing = radiansBearing.toDegrees()
        if degreesBearing < 0 {
            degreesBearing += 360
        }
        return degreesBearing
    }

    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            try engine?.start()
        } catch {
            print("Haptics error: \(error)")
        }
    }

    private func triggerHaptic() {
        guard let engine = engine else { return }
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [sharpness, intensity], relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            print("Haptic error: \(error)")
        }
    }

    @Published var arrivalThreshold: Double = 20.0

    override init() {
        super.init()
        prepareHaptics()
        startMonitoring()
        startUpdatingHeading()
    }

    private func startMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkArrival()
        }
    }

    private func checkArrival() {
        guard let _ = destination else { return }
        if distanceToDestination <= arrivalThreshold && !hasArrived {
            hasArrived = true
            triggerHaptic()
        }
    }

    private func startUpdatingHeading() {
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.2
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let data = data else { return }
                let heading = data.attitude.yaw * 180 / .pi
                DispatchQueue.main.async {
                    self?.hasArrived = self?.hasArrived ?? false // trigger update
                }
            }
        }
    }
}

// MARK: - Extensions

extension Double {
    func toRadians() -> Double { self * .pi / 180 }
    func toDegrees() -> Double { self * 180 / .pi }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var vm = MapSearchViewModel()
    @State private var showNavigation = false

    var body: some View {
        NavigationView {
            VStack {
                // 検索バー
                TextField("検索ワードを入力", text: $vm.searchText)
                    .padding(10)
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(10)
                    .padding([.horizontal, .top])

                if vm.searchText.isEmpty {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    gradient: Gradient(colors: [Color.blue.opacity(0.4), Color.blue.opacity(0.7)]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing))
                                .frame(width: 100, height: 100)
                            Image(systemName: "magnifyingglass.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 60, height: 60)
                                .foregroundColor(.white)
                                .shadow(radius: 3)
                        }

                        Text("地名や駅名を入力して\n検索してください")
                            .foregroundColor(.gray)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(vm.places) { place in
                            HStack {
                                Image(systemName: "mappin.and.ellipse")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 40, height: 40)
                                    .foregroundColor(.blue)
                                    .padding(.trailing, 8)

                                VStack(alignment: .leading) {
                                    Text(place.name).font(.headline)
                                    Text(place.address)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }

                                Spacer()

                                Button("ここへ行く") {
                                    vm.setDestination(place: place)
                                    showNavigation = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .listStyle(.plain)
                    .animation(.default, value: vm.places)
                }
            }
            .navigationTitle("マップ検索")
            .fullScreenCover(isPresented: $showNavigation) {
                NavigationViewScreen(viewModel: vm, isPresented: $showNavigation)
            }
        }
    }

}


struct NavigationViewScreen: View {
    @ObservedObject var viewModel: MapSearchViewModel
    @Binding var isPresented: Bool
    

    var formattedDistance: String {
        let dist = viewModel.distanceToDestination
        return dist > 1000 ? String(format: "%.1f km", dist / 1000) : String(format: "%.0f m", dist)
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack {
                Text("目的地")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(viewModel.selectedPlace?.name ?? "不明")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            Spacer()

            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 180, height: 180)
                Image(systemName: "arrow.up")
                    .resizable()
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(viewModel.directionAngle))
                    .animation(.easeInOut(duration: 0.2), value: viewModel.directionAngle)
                    .foregroundColor(.blue)
            }

            VStack {
                Text("残り距離")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(formattedDistance)
                    .font(.title3)
            }

            if viewModel.hasArrived {
                Text("🎉 到着しました！")
                    .font(.title)
                    .foregroundColor(.green)
                    .padding()
            }

            Spacer()

            Button(action: {
                isPresented = false
                viewModel.destination = nil
                viewModel.selectedPlace = nil
                viewModel.hasArrived = false
            }) {
                Text("戻る")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(12)
            }
            .padding(.horizontal)
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }
}

