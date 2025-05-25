import SwiftUI
import MapKit
import CoreLocation
import CoreHaptics
import CoreMotion
import ActivityKit
import AppTrackingTransparency

// MARK: - Models

struct Place: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
    var distance: Double?
    
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
    @Published var isShowSplashScreen: Bool = true
    @Published var currentLocation: CLLocationCoordinate2D?
    @Published var heading: CLHeading?  // ← 追加
    @Published var isAuthorizedAlways: Bool = false
    
    private let manager = CLLocationManager()
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = kCLHeadingFilterNone
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        manager.startUpdatingHeading() // ← 追加
    }
    
    func requestTrackingPermissionIfNeeded() {
        ATTrackingManager.requestTrackingAuthorization { status in
            switch status {
            case .authorized:
                print("Tracking authorized")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    withAnimation {
                        self.isShowSplashScreen = false
                    }
                }
            case .denied, .restricted:
                print("Tracking denied")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    withAnimation {
                        self.isShowSplashScreen = false
                    }
                }
            case .notDetermined:
                print("Not determined – まだダイアログが出ていません")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    withAnimation {
                        self.isShowSplashScreen = true
                    }
                }
            @unknown default:
                break
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            DispatchQueue.main.async {
                self.currentLocation = loc.coordinate
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        DispatchQueue.main.async {
            self.heading = newHeading
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            isAuthorizedAlways = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.requestTrackingPermissionIfNeeded()
        }
    }
    
    
    
    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        return true
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Failed to get location: \(error.localizedDescription)")
    }
}


// MARK: - ViewModel
class MapSearchViewModel: NSObject, ObservableObject {
    @Published var searchText: String = "" {
        didSet {
            debounceTimer?.invalidate()
            debounceTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(performSearch), userInfo: nil, repeats: false)
        }
    }
    @Published var places: [Place] = []
    @Published var selectedPlace: Place? = nil
    @Published var destination: CLLocationCoordinate2D? = nil
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.6895, longitude: 139.6917), // Tokyo座標 最初の設定をしておく
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    
    var locationManager = LocationManager()
    private let searchQueue = DispatchQueue(label: "searchQueue")
    private var debounceTimer: Timer?
    private var requestCount = 0
    private let maxRequests = 50
    private let resetTime: TimeInterval = 60
    private var resetTimer: Timer?
    private var searchCache = [String: [Place]]()
    
    var directionAngle: Double {
        guard let current = currentLocation,
              let dest = destination,
              let heading = locationManager.heading?.trueHeading else { return 0 }
        
        let currentLoc = CLLocation(latitude: current.latitude, longitude: current.longitude)
        let destLoc = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
        
        let bearing = bearingBetween(startLocation: currentLoc, endLocation: destLoc)
        
        let angle = bearing - heading
        return angle
    }
    
    private func startMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkArrival()
        }
    }
    
    func setDestination(place: Place) {
        destination = place.coordinate
        selectedPlace = place
        hasArrived = false
        calculateDistances()
    }
    
    func calculateDistances() {
        guard let currentLocation = currentLocation else { return }
        let currentLoc = CLLocation(latitude: currentLocation.latitude, longitude: currentLocation.longitude)
        
        for index in places.indices {
            let placeLocation = CLLocation(latitude: places[index].coordinate.latitude, longitude: places[index].coordinate.longitude)
            let distance = currentLoc.distance(from: placeLocation) // 距離をメートル単位で取得
            places[index].distance = distance // 距離をplaceに設定
        }
    }
    
    @objc func performSearch() {
        if requestCount >= maxRequests {
            print("リクエストの制限を超えました。次のリクエストまで待機します。")
            return
        }
        
        if let cachedResults = searchCache[searchText] {
            DispatchQueue.main.async {
                self.places = cachedResults
            }
            return
        }
        
        guard let currentLoc = locationManager.currentLocation else {
            places = []
            return
        }
        
        requestCount += 1
        if resetTimer == nil {
            resetTimer = Timer.scheduledTimer(withTimeInterval: resetTime, repeats: false) { [weak self] _ in
                self?.requestCount = 0
                self?.resetTimer = nil
            }
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
                self.searchCache[self.searchText] = newPlaces
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
    
    var currentLocation: CLLocationCoordinate2D? {
        locationManager.currentLocation
    }
    
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
        
        // 現在地に戻すために現在地を取得して更新
        if let currentLoc = locationManager.currentLocation {
            region.center = currentLoc
        }
        
        startUpdatingHeading()
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

enum HalfModalType {
    case small
    case medium
    case long
}

struct CustomMapPinView: View {
    var place: Place // Place はアノテーションデータのモデルです
    var action: () -> Void

    var body: some View {
        VStack {
            Image(systemName: "mappin.circle.fill")
                            .resizable()
                            .frame(width: 24, height: 24) // 小さめのサイズに変更
                            .foregroundColor(.indigo) // 柔らかい色に変更
                            .padding(6) // 追加の余白を作成
                            .background(Color.white.opacity(0.7)) // 少し透明の背景を追加
                            .clipShape(Circle()) // 背景を円形にする
            Text(place.name) // 場所の名前を表示する場合
                .font(.caption)
                .padding(5)
                .background(Color.white)
                .cornerRadius(5)
                .shadow(radius: 5)
        }
        .onTapGesture {
            action()
        }
    }
}

struct PermissionWarningView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("位置情報の使用が許可されていません。")
                .foregroundColor(.red)
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(.systemBackground).opacity(0.9))
        .cornerRadius(12)
        .shadow(radius: 4)
    }
}


// MARK: - Views
struct ContentView: View {
    @StateObject private var vm = MapSearchViewModel()
    @FocusState private var isTextFieldFocused: Bool
    @State private var showNavigation = false
    @State var halfModalType: HalfModalType = .medium
    @State var position = CGSize.zero
    @State private var viewSize = CGSize(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
    @State private var selectedPlace: Place? // 追加
    @State private var trackingMode: MapUserTrackingMode = .follow
    @State private var isKeyboardVisible = false
    @State private var isMenuPresented = false
    let categories = ["カフェ", "コンビニ", "レストラン", "銀行", "ホテル"] // カテゴリや履歴のデータ
    
    private func addKeyboardObservers() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            self.isKeyboardVisible = true
        }
        
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            self.isKeyboardVisible = false
        }
    }
    
    private func removeKeyboardObservers() {
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }
    
    var body: some View {
        if vm.locationManager.isShowSplashScreen {
            splashView
        } else {
            contentView
                .overlay {
                    if !vm.locationManager.isAuthorizedAlways {
                        PermissionWarningView()
                    }
                }
        }
    }
    
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0.0

    var splashView: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color.orange, Color.orange.opacity(0.7)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(.michipass)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)
                    .shadow(radius: 10)

                Image(.michipassTitle)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
        }
    }
    
    var contentView: some View {
        NavigationView {
            VStack {
                HStack {
                    Button(action: {
                        isMenuPresented = true
                    }) {
                        Image(systemName: "line.3.horizontal")
                            .resizable()
                            .foregroundColor(.gray)
                            .frame(width: 24, height: 24)
                    }
                    .padding(.leading, 15)
                    .padding(.top, 15)
                    .sheet(isPresented: $isMenuPresented) {
                        MenuSheetView()
                    }
                    
                    // 検索バー
                    ZStack {
                        // 背景の TextField
                        TextField("検索ワードを入力", text: $vm.searchText)
                            .padding(10)
                            .padding(.leading, 36) // 左側にアイコンのスペースを作る
                            .padding(.trailing, vm.searchText.isEmpty ? 0 : 36) // 右側にクリアボタンのスペースを作る
                            .background(Color(UIColor.systemGray6))
                            .cornerRadius(10)
                            .focused($isTextFieldFocused)
                            .onChange(of: isTextFieldFocused) {
                                if isTextFieldFocused {
                                    halfModalType = .long
                                }
                            }
                        
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.gray)
                                .padding(.leading, 10)
                            
                            Spacer()
                            
                            if !vm.searchText.isEmpty {
                                Button(action: {
                                    vm.searchText = "" // 検索テキストをクリア
                                    hideKeyboard()
                                }) {
                                    Image(systemName: "multiply.circle.fill")
                                        .foregroundColor(.gray)
                                        .padding(.trailing, 10)
                                }
                            }
                        }
                    }
                    .padding([.horizontal, .top])
                }
                
                ZStack {
                    Map(coordinateRegion: $vm.region, showsUserLocation: true, userTrackingMode: $trackingMode, annotationItems: vm.places) { place in
                        MapAnnotation(coordinate: place.coordinate) {
                            CustomMapPinView(place: place, action: {
                                selectedPlace = place
                            })
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            trackingMode = .none
                        }
                    }
                    
                    // 現在地に戻すボタンを追加
                    Button(action: {
                        if let currentLoc = vm.currentLocation {
                            vm.region.center = currentLoc
                        }
                    }) {
                        Image(systemName: "location.circle.fill")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .foregroundColor(.blue)
                            .padding()
                    }
                    .background(Color.white)
                    .clipShape(Circle())
                    .shadow(radius: 4)
                    .position(x: viewSize.width - 50, y: 50)
                    
                    halfModalView
                        .cornerRadius(getConerRadius())
                        .offset(y: getYoffset())
                        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.9), value: halfModalType)
                        .edgesIgnoringSafeArea(.all)
                }
            }
            .fullScreenCover(isPresented: $showNavigation) {
                NavigationViewScreen(viewModel: vm, isPresented: $showNavigation)
            }
        }
        .onAppear { self.addKeyboardObservers() }
        .onDisappear { self.removeKeyboardObservers() }
        .onChange(of: vm.searchText) {
            if vm.searchText.isEmpty {
                halfModalType = .medium
            } else {
                halfModalType = .long
            }
        }
    }
    
    @ViewBuilder
    var halfSheetContent: some View {
        if vm.searchText.isEmpty  {
            if halfModalType == .medium {
                VStack(spacing: 8) {
                    Text("地名や駅名を入力して検索してください")
                        .foregroundColor(.gray)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.top, 3)
                    
                    Spacer(minLength: 8)
                    
                    HStack(spacing: 20) {
                        ForEach(categories.prefix(3), id: \.self) { category in
                            VStack(spacing: 8) {
                                Button(action: {
                                    vm.searchText = category // ボタンをタップすると検索テキストを更新
                                }) {
                                    ZStack {
                                        Circle()
                                            .fill(LinearGradient(
                                                gradient: Gradient(colors: [Color.purple.opacity(0.6), Color.blue]),
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing))
                                            .frame(width: 50, height: 50)
                                            .shadow(color: Color.gray.opacity(0.3), radius: 4, x: 0, y: 2)
                                        
                                        Image(systemName: iconForCategory(category)) // カテゴリに応じたアイコンを表示
                                            .resizable()
                                            .frame(width: 24, height: 24)
                                            .foregroundColor(.white)
                                    }
                                }
                                
                                Text(category)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                    
                    Spacer(minLength: 8)
                    
                    HStack(spacing: 20) {
                        ForEach(categories.suffix(2), id: \.self) { category in
                            VStack(spacing: 8) {
                                Button(action: {
                                    vm.searchText = category // ボタンをタップすると検索テキストを更新
                                }) {
                                    ZStack {
                                        Circle()
                                            .fill(LinearGradient(
                                                gradient: Gradient(colors: [Color.purple.opacity(0.6), Color.blue]),
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing))
                                            .frame(width: 50, height: 50)
                                            .shadow(color: Color.gray.opacity(0.3), radius: 4, x: 0, y: 2)
                                        
                                        Image(systemName: iconForCategory(category)) // カテゴリに応じたアイコンを表示
                                            .resizable()
                                            .frame(width: 24, height: 24)
                                            .foregroundColor(.white)
                                    }
                                }
                                
                                Text(category)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: 220)
                .cornerRadius(20)
                .shadow(radius: 10)
                .onAppear {
                    halfModalType = .medium
                }
            } else {
                VStack(spacing: 16) {
                    if !isKeyboardVisible {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    gradient: Gradient(colors: [Color.orange.opacity(0.4), Color.orange.opacity(0.7)]),
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
                    
                    // カテゴリまたは履歴のボタンを表示
                    VStack(spacing: 10) {
                        ForEach(categories, id: \.self) { category in
                            Button(action: {
                                vm.searchText = category // ボタンをタップすると検索テキストを更新
                            }) {
                                HStack {
                                    Image(systemName: iconForCategory(category)) // カテゴリに応じたアイコンを表示
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                        .foregroundColor(.white)
                                    
                                    Text(category)
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                }
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(LinearGradient(
                                    gradient: Gradient(colors: [Color.purple.opacity(0.8), Color.blue]),
                                    startPoint: .leading,
                                    endPoint: .trailing))
                                .cornerRadius(12)
                                .shadow(color: Color.black.opacity(0.2), radius: 4, x: 2, y: 2)
                            }
                        }
                    }
                    .padding()
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .cornerRadius(20)
                .shadow(radius: 20)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(vm.places.enumerated()), id: \.element.id) { index, place in
                            if (index + 1) % 5 == 0 {
                                BannerAdView()
                                    .frame(height: 80)
                                    .padding(.horizontal, 8)
                                    .padding(.top)
                            }
                            
                            Rectangle()
                                .fill(.clear)
                                .frame(width: 1, height: 1)
                                .id(place.id)
                            
                            HStack {
                                Image(systemName: "mappin.and.ellipse")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 40, height: 40)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 8)
                                
                                VStack(alignment: .leading) {
                                    Text(place.name).font(.headline)
                                    Text(place.address)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                
                                Spacer()
                                
                                HStack {
                                    VStack {
                                        // 現在地からの距離
                                        if let distance = place.distance {
                                            Text(distanceString(from: distance))
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                        }
                                        
                                        Button(action: {
                                            vm.setDestination(place: place)
                                            showNavigation = true
                                        }) {
                                            HStack {
                                                Image(systemName: "arrow.forward.circle.fill")
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 20, height: 20)
                                                    .foregroundColor(.white)
                                                
                                                Text("GO!")
                                                    .foregroundColor(.white)
                                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                            }
                                            .padding(8)
                                            .background(LinearGradient(
                                                gradient: Gradient(colors: [Color.orange.opacity(0.8), Color.orange]),
                                                startPoint: .leading,
                                                endPoint: .trailing))
                                            .cornerRadius(10)
                                            .shadow(radius: 3)
                                            .contentShape(Rectangle())
                                            .padding(.trailing, 5)
                                        }
                                    }
                                }
                                .onAppear {
                                    vm.calculateDistances()
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 80)
                            .padding(.vertical, 6)
                            .background(Color.white)
                            .cornerRadius(10)
                            .shadow(radius: 1)
                            .onChange(of: selectedPlace) {
                                if let selectedPlace = selectedPlace {
                                    withAnimation {
                                        proxy.scrollTo(selectedPlace.id, anchor: .top)
                                    }
                                }
                            }
                            .onTapGesture {
                                halfModalType = .medium
                                let zoomLevel = 0.005 // 拡大する程度を調整
                                let newRegion = MKCoordinateRegion(
                                    center: place.coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: zoomLevel, longitudeDelta: zoomLevel)
                                )
                                vm.region = newRegion
                                selectedPlace = place
                            }
                            .padding(.top, 10)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top)
                    
                    Spacer()
                    
                    if halfModalType == .medium {
                        Rectangle()
                            .fill(.clear)
                            .frame(width: 1, height: 700)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
                .background(Color(UIColor.systemGroupedBackground)
                    .edgesIgnoringSafeArea(.all))
                .onAppear {
                    halfModalType = .long
                }
            }
        }
    }
    
    
    
    func getConerRadius() -> CGFloat {
        switch halfModalType {
        case .small:
            return 20
        case .medium:
            return 20
        case .long:
            return 0
        }
    }
    
    func getYoffset() -> CGFloat {
        switch halfModalType {
        case .small:
            return viewSize.height * 0.65
        case .medium:
            return viewSize.height * 0.54
        case .long:
            return 0
        }
    }
    
    func getForegroundColor() -> Color {
        switch halfModalType {
        case .small:
            return .white
        case .medium:
            return .white
        case .long:
            return Color(UIColor.systemGroupedBackground)
        }
    }
    
    // 距離をメートルまたはキロメートルの文字列にフォーマット
    func distanceString(from distance: Double) -> String {
        if distance > 1000 {
            return String(format: "%.1f km", distance / 1000)
        } else {
            return String(format: "%.0f m", distance)
        }
    }
    
    // カテゴリに応じたアイコンを返す関数
    func iconForCategory(_ category: String) -> String {
        switch category {
        case "カフェ":
            return "cup.and.saucer.fill"
        case "コンビニ":
            return "bag.fill"
        case "レストラン":
            return "fork.knife"
        case "銀行":
            return "building.columns"
        case "ホテル":
            return "bed.double.fill"
        default:
            return "questionmark"
        }
    }
    
    var halfModalView: some View {
            ZStack {
                Rectangle()
                    .foregroundColor(getForegroundColor())
                VStack {
                    Button(action: {
                        if halfModalType == .long {
                            halfModalType = .medium
                        } else if halfModalType == .medium {
                            halfModalType = .long
                        } else {
                            halfModalType = .medium
                        }
                    }) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.black .opacity(0.5))
                            .frame(width: 60, height: 5)
                            .padding(.top)
                    }
                    
                    halfSheetContent
                    
                    Spacer()
                }
            }
        }
}

struct MenuSheetView: View {
    var body: some View {
        NavigationView {
            VStack {
                List {
                    Button {
                        openURL("https://square-hockey-7b2.notion.site/1fdc71ad3e3b804497cdd7319678cf81?pvs=4")
                    } label: {
                        Label("プライバシーポリシー", systemImage: "lock.shield")
                            .foregroundColor(.black)
                    }

                    Button {
                        openURL("https://square-hockey-7b2.notion.site/1fdc71ad3e3b80f6a9b4ee047228eb5e?pvs=4")
                    } label: {
                        Label("利用規約", systemImage: "doc.text")
                            .foregroundColor(.black)
                    }

                    Button {
                        openURL("https://docs.google.com/forms/d/e/1FAIpQLScKdH6VkusLr3sSMfqbtbFgsLBW2JzhZ3uYpSOdpyvZo6x2nQ/viewform?usp=dialog")
                    } label: {
                        Label("問い合わせ", systemImage: "envelope")
                            .foregroundColor(.black)
                    }
                }
                .navigationTitle("メニュー")
                .navigationBarTitleDisplayMode(.inline)
                
                BannerAdView()
                    .frame(height: 400)
                    .padding(.horizontal, 20)
            }
        }
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }
}

struct NavigationViewScreen: View {
    @ObservedObject var viewModel: MapSearchViewModel
    @Binding var isPresented: Bool
    @State private var isShowingMap = false
    
    var formattedDistance: String {
        let dist = viewModel.distanceToDestination
        return dist > 1000 ? String(format: "%.1f km", dist / 1000) : String(format: "%.0f m", dist)
    }
    
    var body: some View {
        VStack(spacing: 24) {
            if isShowingMap {
                MapView(viewModel: viewModel)
                    .edgesIgnoringSafeArea(.all) // 地図をフルスクリーンに拡張
                    .overlay(
                        VStack {
                            HStack {
                                Spacer()
                                Button(action: {
                                    isShowingMap = false
                                }) {
                                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                                        .padding()
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .clipShape(Circle())
                                }
                                .padding()
                            }
                            Spacer()
                        }
                    )
            } else {
                VStack {
                    Text("目的地")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(viewModel.selectedPlace?.name ?? "不明")
                        .font(.title2)
                        .fontWeight(.bold)
                }
                .padding(.top, 16)
                
                Spacer()
                
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.1))
                        .frame(width: 200, height: 200)
                    Image(systemName: "arrow.up")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .rotationEffect(.degrees(viewModel.directionAngle))
                        .animation(.easeInOut(duration: 0.2), value: viewModel.directionAngle)
                        .foregroundColor(.orange)
                }
                
                VStack {
                    Text("残り距離")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if viewModel.hasArrived {
                        Text("0m")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                    } else {
                        Text(formattedDistance)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                    }
                }
                .padding(.top, 16)
                
                if viewModel.hasArrived {
                    Text("到着！")
                        .font(.title)
                        .foregroundColor(.green)
                        .padding()
                }
                
                Spacer()
                
                VStack(spacing: 12) {
                    Button("地図表示") {
                        isShowingMap = true
                    }
                    .buttonStyle(MichipassButtonStyle(backgroundColor: .orange))

                    Button("戻る") {
                        isPresented = false
                        viewModel.destination = nil
                        viewModel.selectedPlace = nil
                        viewModel.hasArrived = false
                    }
                    .buttonStyle(MichipassButtonStyle(backgroundColor: .gray))
                }
                .padding(.horizontal)
            }
        }
        .padding()
        .background(Color(.systemGroupedBackground).edgesIgnoringSafeArea(.all))
    }
}

struct MichipassButtonStyle: ButtonStyle {
    var backgroundColor: Color
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .padding()
            .frame(maxWidth: .infinity)
            .background(backgroundColor)
            .foregroundColor(.white)
            .cornerRadius(16)
            .shadow(color: backgroundColor.opacity(0.3), radius: 4, x: 0, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct MapView: UIViewRepresentable {
    @ObservedObject var viewModel: MapSearchViewModel
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.userTrackingMode = .none // 追従を無効化
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        guard let destination = viewModel.destination, let currentLocation = viewModel.currentLocation else { return }
        // 最初のロード時だけ地図の位置とズームを設定
        if !context.coordinator.hasSetInitialRegion {
            let destinationAnnotation = MKPointAnnotation()
            destinationAnnotation.coordinate = destination
            destinationAnnotation.title = "目的地"
            
            uiView.removeAnnotations(uiView.annotations)
            uiView.addAnnotations([destinationAnnotation])
            
            
            let region = MKCoordinateRegion(
                center: currentLocation,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
            uiView.setRegion(region, animated: true)
            context.coordinator.hasSetInitialRegion = true
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapView
        var hasSetInitialRegion = false // 初回ロードかどうかを確認
        
        init(_ parent: MapView) {
            self.parent = parent
        }
    }
}

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
