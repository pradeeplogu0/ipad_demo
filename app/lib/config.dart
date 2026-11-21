/// NavLink configuration — edit these to change map tiles or servers.
class AppConfig {
  /// MapTiler API key (free tier at https://www.maptiler.com/cloud/).
  /// Leave empty to use the standard OpenStreetMap tile server instead.
  static const mapTilerKey = '';

  /// Tile URL used when [mapTilerKey] is set.
  static const mapTilerUrl =
      'https://api.maptiler.com/maps/streets-v2-dark/{z}/{x}/{y}.png?key={key}';

  /// Fallback: openstreetmap.org tiles. Fine for personal, light use only —
  /// see https://operations.osmfoundation.org/policies/tiles/ (no bulk download).
  static const osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Sent as the User-Agent for tiles, Nominatim and OSRM (required by OSM policy).
  static const userAgentPackage = 'com.prade.navdisplay';
  static const userAgent = 'NavLink/1.0 (com.prade.navdisplay; personal use)';

  /// Desktop/web fallback search + routing (iPhone uses Apple Maps).
  /// The public servers are for light testing only.
  static const nominatimUrl = 'https://nominatim.openstreetmap.org';
  static const osrmUrl = 'https://router.project-osrm.org';

  static String get tileUrl => mapTilerKey.isEmpty
      ? osmTileUrl
      : mapTilerUrl.replaceAll('{key}', mapTilerKey);

  /// Darken light OSM tiles for the dark driving UI.
  static bool get darkenTiles => mapTilerKey.isEmpty;
}
