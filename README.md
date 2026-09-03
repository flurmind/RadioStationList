# My Stations

🌐 **English** | [Русский](README.ru.md)

**P**lugin for [Lyrion Music Server (LMS)](https://lyrion.org/) lets you build and conveniently manage your own collection of internet radio stations: edit station data (including logos), reorder them, and search for and add new stations from the [Radio Browser](https://www.radio-browser.info) database with filtering by stream quality and metadata.
> Technical package name: `RadioStationList`

## 📸 Screenshots

<p align="center">
  <img src="screenshots/mystations_page.png" alt="My Stations" width="28%">
  <img src="screenshots/radiobrowser_search.png" alt="Radio Browser Search" width="28%">
  <img src="screenshots/settings.png" alt="Settings" width="40%">
</p>

## 📻 Station Management

A fully customizable personal list of internet radio stations. For each station you can set or edit:

- logo;
- name;
- audio stream URL;
- genre;
- country.

The station order can be changed on the settings page using **drag-and-drop** or the ▲▼ move buttons.

* * *

## 📊 Stream Quality Information

In the "My Stations" list, you can enable an extra line under the logo showing stream info, for example: `MP3 128k • Chillout • Germany` (codec and bitrate, genre, country).

In Radio Browser search mode this line is always shown, and a color indicator is added before the codec so you can gauge stream quality at a glance:

| Indicator | Quality |
| --- | --- |
| 🟢  | **256 kbps and above** |
| ⚪   | **192–255 kbps** |
| 🟡  | **128–191 kbps** |
| 🔴  | **below 128 kbps** |

> For manually added stations, the codec and bitrate are initially unknown — they are detected automatically the first time playback starts. For some streams (e.g. AAC) this information may be unavailable.

* * *

## 🖼️ Station Logos

The plugin supports logos from an external URL and from a local folder. Successfully downloaded logos are saved in the plugin's internal cache and used from there afterward without any network access.

In the settings page, some logos are shown with a badge indicating their current state:

| Situation | Settings | Playlist |
| --- | --- | --- |
| Station has no logo set (neither a URL nor a local file) | "No logo" icon | Default logo |
| LMS can't download the logo, even though a browser can open it directly | Logo by URL + ⚠️ | Default logo |
| File downloaded but corrupted — retries in progress | Logo by URL + ⚠️ (temporary) | Default logo |
| Both attempts failed — URL is blocked | "Corrupted image" icon | Default logo |
| WebP — format not supported by the LMS graphics engine | Logo by URL + ⚠️ | Logo passed through directly, bypassing LMS (if enabled in settings), otherwise — default |
| A matching file was found in the local folder | Local logo + 📁 | From the plugin cache |
| Successfully downloaded and cached | Logo without a badge | From the plugin cache |

### WebP

LMS's internal graphics engine doesn't support WebP, even though modern browsers display such images without any issue. The web UI implements a separate workaround that passes such a logo directly into the playlist, bypassing LMS's limitation.

> The workaround works in the web UI. WebP may not display on hardware players.

### Local Logos

You can point to a local folder on the LMS server containing logos in the following formats:

`.png`, `.jpg`, `.jpeg`, `.gif`, `.ico`, `.svg`

A logo is automatically matched to a station by an exact match between the station name and the file name — case-insensitive and ignoring the extension.

A local logo takes priority over an external URL: if a station has a URL set but a matching file is found in the custom folder, the local file is used instead. In the settings, such a logo is marked with a folder badge 📁.

The folder path must be absolute. For example, when using Docker, you can mount the desired folder from the host into the LMS container and specify the path to it inside the container.

> A matched local logo is copied into the plugin's internal cache and used from there afterward.

* * *

## 🌐 Reliable Logo Downloading

The plugin separates image-handling logic into two paths:

- in Radio Browser search: logos are loaded by the client directly from external URLs in the catalog. The LMS server doesn't spend resources, memory, or time downloading temporary icons from search results;
- for saved stations: icons are downloaded asynchronously by the plugin to the LMS server into a local cache (the `RadioLogo` folder inside the plugin), with failure protection and proxy support.

Downloading logos for saved stations is the most "unpredictable" part of the plugin: external servers can be slow, unavailable, return corrupted files, or require non-standard handling. That's why local caching includes several protection mechanisms.

### Automatic Validation

Before saving to disk, the plugin checks the integrity of downloaded images. If the server returned a corrupted or incomplete file, the plugin rejects it and prevents the LMS interface from breaking, automatically moving on to the second download stage.

### Two-Stage Download

The first attempt is always made directly. If it fails — for example due to a network error, server unavailability (403/404 errors), receiving an HTML page instead of an image, a corrupted file, or LMS being unable to process the image — a second attempt is made:

- via the `wsrv.nl` CDN proxy, if proxying is enabled in the settings. The proxy forcibly converts the image to PNG;
- directly again, if proxying is disabled.

After two failed attempts, the logo URL is blocked and the default logo is used instead. The block is only lifted manually — via the button or by restarting LMS. If a station is removed from the list, its logo block is lifted automatically (the cache file is deleted).

### Retry Download

The **"Retry failed icons"** button clears all blocks and restarts downloading of problem logos — both those marked "corrupted image" and those with the ⚠️ badge (except for the `webp` format).

### Caching

Successfully downloaded logos for saved stations are placed in the plugin's internal folder (`RadioLogo`) and reused by LMS without any network access.

> This is a separate internal cache folder — not the user's custom logo folder. A file in the cache is named using a hash of the station's audio stream URL, not the logo URL. So the same logo can end up stored in the cache as several files — one per station.

### Download Deduplication

If several stations use the same logo URL, it is only downloaded once — regardless of whether the logos are being downloaded at the same time or the logo for one of the stations was already fetched earlier, including in a previous session.

A local logo is only used for the station whose file name it matches. It does not carry over to other stations — even if they have the same logo URL set.

### Protection Against Stuck Downloads

In addition to the timeout on each individual download attempt, an extra background safeguard runs: if a download hangs for any reason and doesn't finish normally, the plugin automatically clears its state — with no need to manually reset errors or restart LMS.

* * *

## 🔎 Radio Browser Search

The plugin lets you search for stations directly in the **Radio Browser** database. The following prefixes are supported:

| Prefix | Purpose | Example |
| --- | --- | --- |
| `#` | search by genre | `#rock` |
| `@` | country code (ISO) | `@DE` |
| `?` | minimum bitrate | `?192` |
| plain text | search by name | `record chill` |

A found station can be added straight to "My Stations".

### Search Cache Size

The **"Search cache size"** setting determines how many stations are fetched per request to the Radio Browser API.

A larger value:

- reduces the number of network requests while scrolling through results;
- increases the size of the first response and the number of logos loaded at once on the search page.

This also affects infinite-scroll auto-loading on large screens: if more stations fit on screen than a single request returns, the list doesn't fill the screen, no scrolling occurs, and the next batch isn't requested automatically. In that case, increase the search cache size so a single request returns more stations than fit on screen (results should extend past the bottom edge).

> Search results are cached for 5 minutes — repeating the same search returns results instantly, without a new request to Radio Browser.

* * *

## 📦 Installation

1.  Open the LMS web interface.
    
2.  Go to **Settings → Plugins**.
    
3.  Scroll down to the **Additional Repositories** section.
    
4.  Add the repository address:
    
    ```text
    https://raw.githubusercontent.com/flurmind/RadioStationList/main/repository.xml
    ```
    
5.  Click **Apply**.
    
6.  Find **My Stations** in the list of third-party plugins and install it.
    
7.  Restart LMS.
    

After installation, the plugin will appear in the LMS menu.

## 🌍 Languages

The plugin is translated into Russian and English.  
If you'd like to add a new language or improve an existing translation:

1.  Copy the `strings.txt` file from the repository.
2.  Add strings for the language you want (e.g. `DE`, `FR`, `NL`).
3.  Submit a Pull Request.
