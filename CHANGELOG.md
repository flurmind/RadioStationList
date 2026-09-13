Changelog (v1.1.0)

## v1.1.0

### New
- **Automatic stream quality detection:** For stations where Radio Browser didn't report bitrate (or added manually), the plugin now measures it itself. It reads a small chunk of the live stream and parses AAC (ADTS) or MP3 frame headers directly — no need to start playback first. For formats without a compatible frame parser (FLAC, Ogg/Vorbis, Opus), bitrate is instead picked up automatically the first time the station is actually played.
- **Ogg container sniffing:** For streams served as generic Ogg (a common wrapper for Vorbis, Opus, and Ogg-FLAC), the plugin looks inside the container to report the real codec (Vorbis / Opus / FLAC) instead of a generic "OGG" label.
- **New "Refresh stream info" button** in settings: Bulk-measures bitrate/codec for every station where it's still unknown (useful for stations added before this update, or where a previous attempt failed due to a network error).
- **Background Metadata Extraction (ICY Tags):** When you add a bare URL manually or import a basic playlist, the plugin automatically extracts missing information (station name, genre, and homepage) directly from the stream's ICY headers in the background. Active input protection ensures background updates never overwrite fields you are currently editing, and unresponsive streams are safely dropped after a few polling attempts (`RR_MAX_NAME_POLLS`).
- Detection now runs automatically the moment a station is added — whether from Radio Browser search, entered manually, or restored via JSON/M3U import — whenever the codec/bitrate isn't already known.
- Settings page now live-updates the codec and bitrate columns as soon as a measurement completes, without requiring a full table reload.
- **Codec search filter** — the Radio Browser search now also supports a `!` prefix to filter by codec (e.g. `!AAC`).
- **JSON backup & restore:** Export your full station list (including bitrate, codec, country, homepage, etc.) as a single JSON file, and restore it later. New stations are merged into your existing list; duplicates by URL are skipped safely. Raw station exports from the Radio Browser website are also recognized and imported directly, no conversion needed. Imports are capped at 100 stations per file to avoid accidentally queuing a huge batch of network probes at once.
- **M3U export & import:** Export your stations as a standard M3U playlist for use in other players. Import reads name/URL from any M3U file, plus logo/genre if the source file used the common `tvg-logo`/`group-title` convention. Fields M3U can't carry (country, bitrate, codec, homepage) are simply left unknown and get filled in automatically afterwards where possible. Local file paths in imported playlists are recognized and skipped safely rather than reported as errors.
- **"Clear all stations" button** in settings — wipes the whole list at once (with a confirmation prompt), useful before a fresh JSON/M3U import.
- On-screen confirmation messages for common actions (station added, icon/stream-info refresh started, import results).

### Improved
- Reduced debug-log noise: Playback events are now ignored for local library tracks entirely, and no longer re-logged repeatedly for the same station while it keeps streaming (previously re-triggered on every ICY metadata/title change).
- The "reset icon errors" and "refresh stream info" actions now go through the same save queue as everything else, removing the last requests that could run in parallel outside the existing save-conflict protection.
- The notification banner now floats above the page instead of shifting the layout, and has better contrast against the background.

### Fixed
- Fixed a timing issue where a new notification could be hidden early by a leftover timer from a previous one.

## v1.0.0
- Initial release.