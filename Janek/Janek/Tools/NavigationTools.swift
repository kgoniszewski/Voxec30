import Contacts
import CoreLocation
import MapKit

/// Jednorazowe pobranie lokalizacji przez CLLocationManager.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()
    private let manager = CLLocationManager()
    private var locationContinuations: [CheckedContinuation<CLLocation, Error>] = []
    private var authContinuations: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func requestAuthorization() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            authContinuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    func currentLocation() async throws -> CLLocation {
        await requestAuthorization()
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: break
        default: throw ToolError.permissionDenied("Lokalizacja")
        }
        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -60 { return recent }
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuations.append(continuation)
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let pending = self.locationContinuations
            self.locationContinuations.removeAll()
            pending.forEach { $0.resume(returning: location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let pending = self.locationContinuations
            self.locationContinuations.removeAll()
            pending.forEach { $0.resume(throwing: error) }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.manager.authorizationStatus != .notDetermined else { return }
            let pending = self.authContinuations
            self.authContinuations.removeAll()
            pending.forEach { $0.resume() }
        }
    }
}

enum PlaceFormatting {
    static func address(of item: MKMapItem) -> String {
        let placemark = item.placemark
        return [placemark.thoroughfare.map { street in [street, placemark.subThoroughfare].compactMap { $0 }.joined(separator: " ") },
                placemark.locality]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    static func distance(_ meters: CLLocationDistance) -> String {
        meters < 1000 ? "\(Int((meters / 10).rounded() * 10)) m" : String(format: "%.1f km", meters / 1000).replacingOccurrences(of: ".", with: ",")
    }
}

struct NavigateTool: AssistantTool {
    let name = "maps_navigate"
    let description = "Wyznacza trasę do celu i uruchamia nawigację w Mapach Apple (lub Google Maps / Waze, jeśli użytkownik o to poprosi). Cel może być adresem, nazwą miejsca albo kontaktem („do domu mamy”)."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "destination": JSONSchema.string("Adres lub nazwa miejsca, np. „Rynek Główny Kraków”, „najbliższa Orlen”"),
            "contact_name": JSONSchema.string("Jeśli celem jest adres kontaktu – imię w mianowniku"),
            "mode": JSONSchema.enumeration(["driving", "walking", "transit", "cycling"], "Środek transportu, domyślnie driving"),
            "app": JSONSchema.enumeration(["apple", "google", "waze"], "Aplikacja nawigacji, domyślnie apple"),
        ])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        var query = input.optionalString("destination")
        if let contactName = input.optionalString("contact_name") {
            let contact = try await ContactsProvider.shared.resolveSingle(contactName)
            guard let postal = contact.postalAddresses.first?.value else {
                throw ToolError.notFound("adres kontaktu „\(ContactsProvider.displayName(contact))”")
            }
            query = CNPostalAddressFormatter().string(from: postal).replacingOccurrences(of: "\n", with: ", ")
        }
        guard let query else { throw ToolError.missingArgument("destination") }
        let mode = input.optionalString("mode") ?? "driving"

        switch input.optionalString("app") {
        case "google":
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let url = URL(string: "comgooglemaps://?daddr=\(encoded)&directionsmode=\(mode == "cycling" ? "bicycling" : mode)")!
            guard await context.open(url) else { return .error("Google Maps nie jest zainstalowane.") }
            return .ok("Uruchomiono nawigację Google Maps do: \(query).")
        case "waze":
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            guard await context.open(URL(string: "waze://?q=\(encoded)&navigate=yes")!) else { return .error("Waze nie jest zainstalowany.") }
            return .ok("Uruchomiono nawigację Waze do: \(query).")
        default:
            break
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let location = try? await LocationProvider.shared.currentLocation() {
            request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        guard let destination = try await MKLocalSearch(request: request).start().mapItems.first else {
            throw ToolError.notFound("miejsce „\(query)”")
        }
        let directionsMode = switch mode {
        case "walking": MKLaunchOptionsDirectionsModeWalking
        case "transit": MKLaunchOptionsDirectionsModeTransit
        case "cycling": MKLaunchOptionsDirectionsModeCycling
        default: MKLaunchOptionsDirectionsModeDriving
        }
        let opened = destination.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: directionsMode])
        guard opened else { return .error("Nie udało się otworzyć Map.") }
        return .ok("Uruchomiono nawigację do: \(destination.name ?? query), \(PlaceFormatting.address(of: destination)).")
    }
}

struct NearbySearchTool: AssistantTool {
    let name = "maps_search_nearby"
    let description = "Szuka miejsc w pobliżu użytkownika (apteka, stacja paliw, bankomat, restauracja, ładowarka EV…). Zwraca listę z odległościami."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "query": JSONSchema.string("Czego szukać, po polsku, np. „apteka”, „stacja benzynowa”"),
            "open_now_hint": JSONSchema.boolean("Użytkownik pyta o coś czynnego teraz"),
        ], required: ["query"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let location = try await LocationProvider.shared.currentLocation()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = try input.requiredString("query")
        request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 8_000, longitudinalMeters: 8_000)
        request.resultTypes = .pointOfInterest
        let items = try await MKLocalSearch(request: request).start().mapItems
            .compactMap { item -> (MKMapItem, CLLocationDistance)? in
                guard let itemLocation = item.placemark.location else { return nil }
                return (item, itemLocation.distance(from: location))
            }
            .sorted { $0.1 < $1.1 }
            .prefix(5)
        guard !items.isEmpty else { return .ok("Nic nie znaleziono w promieniu kilku kilometrów.") }
        let lines = items.map { item, distance in
            "\(item.name ?? "?") – \(PlaceFormatting.distance(distance)), \(PlaceFormatting.address(of: item))"
        }
        var result = lines.joined(separator: "\n")
        if input["open_now_hint"]?.boolValue == true {
            result += "\n(Godziny otwarcia nie są dostępne – zasugeruj sprawdzenie w Mapach.)"
        }
        return .ok(result + "\nAby poprowadzić do któregoś z miejsc, użyj maps_navigate z jego nazwą i adresem.")
    }
}

struct WhereAmITool: AssistantTool {
    let name = "location_current"
    let description = "Mówi, gdzie jest użytkownik (adres/okolica) na podstawie GPS."
    var inputSchema: JSONValue { JSONSchema.object([:]) }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let location = try await LocationProvider.shared.currentLocation()
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "pl_PL"))
        guard let placemark = placemarks.first else { throw ToolError.notFound("adres dla bieżącej pozycji") }
        let street = [placemark.thoroughfare, placemark.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        let parts = [street.isEmpty ? nil : street, placemark.subLocality, placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
        return .ok("Użytkownik jest w pobliżu: \(parts.joined(separator: ", ")) (dokładność ok. \(Int(location.horizontalAccuracy)) m).")
    }
}
