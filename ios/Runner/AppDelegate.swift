import Flutter
import MapKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MapKitNav") {
      MapKitNav.register(with: registrar)
    }
  }
}

/// Apple Maps search + turn-by-turn routes for Watch Lab navigation.
/// Channel "watchlab/mapkit":
///   search {query, lat?, lon?} -> [{name, subtitle, lat, lon}]
///   route  {fromLat, fromLon, toLat, toLon, mode: "drive"|"walk"}
///          -> {dist, time, steps: [{text, dist, notice, pts: [lat, lon, ...]}]}
final class MapKitNav: NSObject {
  private static var instance: MapKitNav?
  private var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let inst = MapKitNav()
    let ch = FlutterMethodChannel(name: "watchlab/mapkit", binaryMessenger: registrar.messenger())
    ch.setMethodCallHandler { call, result in inst.handle(call, result: result) }
    inst.channel = ch
    instance = inst
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "search": search(args, result: result)
    case "route": route(args, result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func search(_ args: [String: Any], result: @escaping FlutterResult) {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = args["query"] as? String ?? ""
    if let lat = args["lat"] as? Double, let lon = args["lon"] as? Double {
      request.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        latitudinalMeters: 60_000, longitudinalMeters: 60_000)
    }
    MKLocalSearch(request: request).start { response, error in
      if let error = error {
        result(FlutterError(code: "search", message: error.localizedDescription, details: nil))
        return
      }
      var items: [[String: Any]] = []
      for item in (response?.mapItems ?? []).prefix(12) {
        let c = item.placemark.coordinate
        items.append([
          "name": item.name ?? "",
          "subtitle": item.placemark.title ?? "",
          "lat": c.latitude,
          "lon": c.longitude,
        ])
      }
      result(items)
    }
  }

  private func route(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let fLat = args["fromLat"] as? Double, let fLon = args["fromLon"] as? Double,
          let tLat = args["toLat"] as? Double, let tLon = args["toLon"] as? Double
    else {
      result(FlutterError(code: "args", message: "Missing coordinates", details: nil))
      return
    }
    let request = MKDirections.Request()
    request.source = MKMapItem(placemark: MKPlacemark(
      coordinate: CLLocationCoordinate2D(latitude: fLat, longitude: fLon)))
    request.destination = MKMapItem(placemark: MKPlacemark(
      coordinate: CLLocationCoordinate2D(latitude: tLat, longitude: tLon)))
    request.transportType = (args["mode"] as? String) == "walk" ? .walking : .automobile
    request.requestsAlternateRoutes = false

    MKDirections(request: request).calculate { response, error in
      guard let route = response?.routes.first else {
        result(FlutterError(
          code: "route",
          message: error?.localizedDescription ?? "No route found",
          details: nil))
        return
      }
      var steps: [[String: Any]] = []
      for step in route.steps {
        let n = step.polyline.pointCount
        var pts: [Double] = []
        if n > 0 {
          var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(), count: n)
          step.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
          pts.reserveCapacity(n * 2)
          for c in coords {
            pts.append(c.latitude)
            pts.append(c.longitude)
          }
        }
        steps.append([
          "text": step.instructions,
          "dist": step.distance,
          "notice": step.notice ?? "",
          "pts": pts,
        ])
      }
      result([
        "dist": route.distance,
        "time": route.expectedTravelTime,
        "name": route.name,
        "steps": steps,
      ])
    }
  }
}
