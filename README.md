# FireWatch Contributor Console

A personal macOS wildfire incident console for a Watch Duty contributor. Its job is deliberately narrow: render every available incident quickly, make triage efficient, and reduce the time between noticing a signal and investigating it in the existing Watch Duty and Slack workflow.

The current build uses public WFIGS, WildCAD-E, ALERT wildfire camera, Open-Meteo, NWS, and NASA VIIRS feeds. It never contacts Watch Duty endpoints.

Open `FireWatch.xcodeproj` in Xcode 16 or newer, select the **FireWatch** scheme, and run. The deployment target is macOS 14. The app is sandboxed with outgoing network access and uses no third-party dependencies or API keys.

This is a personal situational-awareness tool, not an official alerting service.

## Contributor workflow

- Nationwide WFIGS incident and perimeter queries are paginated rather than silently stopping at the ArcGIS record limit.
- A hybrid satellite map combines authoritative WFIGS incidents/perimeters, early WildCAD-E dispatch signals, VIIRS hotspots, camera locations, and NWS observation stations.
- An optional wind streamline field supports **Model**, **Vane-corrected**, **Disagreement**, and **Confidence** modes. It is off by default so incident triage remains the fastest path.
- The right context deck switches between incident intelligence, dispatch details, and public camera imagery with a direct link to the live viewer.
- WildCAD records are labeled as unverified dispatch signals and never visually masquerade as confirmed WFIGS incidents.
- Native MapKit clustering keeps the combined operational layers navigable.
- Quick scopes expose **All**, **Attention**, **Nearby**, and **New** incidents. `⌘1` through `⌘4` switch scopes.
- Arrow keys move through the current incident list; `⌘R` refreshes all feeds.
- The command strip shows incident, dispatch, camera, infrared, layer, freshness, and feed-health state without covering the working map.
- Incidents without coordinates remain in the list and are counted instead of disappearing silently.

## Public data sources

- WFIGS current incident locations and interagency perimeters (ArcGIS)
- WildCAD-E public California dispatch-center incident feeds
- ALERT wildfire public camera catalog, with links to the network viewer
- Open-Meteo current 10 m model winds
- NWS station observations and active fire-weather alerts
- NASA/ArcGIS VIIRS thermal hotspots

Camera catalog records and preview endpoints can age or move. The viewer link remains the operational fallback. No source in this app should be treated as an official evacuation or alert channel.

## Performance and cache behavior

- Each public endpoint has a source-appropriate TTL: WildCAD 30 seconds, NWS 60 seconds, WFIGS 90 seconds, VIIRS 2 minutes, Open-Meteo 30 minutes, perimeters 5 minutes, and the camera catalog 24 hours.
- Responses are cached in memory and on disk. Concurrent requests for the same URL are coalesced, and a bounded stale response is used when a source temporarily fails.
- A normal automatic refresh respects TTLs. `⌘R` is an explicit network refresh.
- Unchanged decoded payloads do not mutate application state, so a cache hit does not trigger map work.
- Map annotations are diffed by stable IDs and remain installed while panning or zooming; MapKit clustering handles camera and hotspot density without zoom-time removal/reinsertion.
- Incident filtering and sorting are cached instead of repeating during every SwiftUI render.

## Wind accuracy

The default **Model** mode uses a 0.25-degree current 10 m Open-Meteo grid. Meteorological bearings are “wind from”; FireWatch converts these to physical flow-toward east/north vectors and then applies the current map projection when drawing them. Direction conversion has cardinal-direction regression tests.

Wind streamlines and directional arrowheads are rendered by a native `MKOverlayRenderer` in geographic map coordinates. MapKit therefore applies the same in-progress zoom and pan transform to wind, perimeters, and annotations instead of waiting for a SwiftUI viewport update. The layer is intentionally static between data refreshes; this avoids expensive tiled redraw loops and makes direction easier to read.

**Vane-corrected** is intentionally labeled heuristic. It blends normalized, age-decayed NWS station residuals into the model and must not be treated as a forecast or fire-spread model. Because local RAWS observations can differ sharply across terrain, raw model mode is the default.

## Highest-value Watch Duty contributor API request

The first private integration should be one small, documented, read-only contributor feed containing public incidents plus internal silenced incidents and external signals. Do not reverse-engineer or reuse private mobile endpoints.

The minimum useful contract is:

- Stable object ID and optional canonical incident ID
- Object kind: incident or external signal
- Visibility: silenced, notifying, inactive, or prescribed
- Title and coordinates
- Observed, created, updated, and last-verified timestamps
- Source label, source URL, signal type, confidence, and contributor-visible notes when shareable
- Acreage and containment when known
- A cursor or sequence value for incremental refresh, ideally with `updated_since`
- Explicit delete, merge, and replacement events

Once the schema is available, these records should flow through the same map pipeline with distinct operational colors: confirmed fire red, silenced incident violet, external signal cyan, prescribed burn orange, contained fire green, and stale record gray.

Useful follow-on read-only asks are Watch Duty's canonical incident-to-camera associations, incident merge/replacement history, contributor-visible change history, and source freshness/health metadata. No administrative writes, publishing, alert dispatch, or Slack replacement belongs in this personal console.

## Deferred ideas

These may be valuable later but are not part of the current contributor-map scope:

- Watch Duty reporter timelines and source provenance
- Evacuation zones and shelters
- Aircraft, AQI, smoke, fuels, and progression layers
- Historical incident replay and perimeter comparison
- Multi-place public-user alerting or consumer-facing features
- Flood, power-outage, and river-gauge coverage
- Contributor drafting, approval, or production admin actions

The promising long-term contributor feature is a compact “what changed since I last looked” view: new incident, renamed or merged incident, perimeter delta, new hotspot cluster, acreage/containment change, visibility upgrade, and stale-source warning. It should complement Watch Duty and Slack rather than duplicate either one.
