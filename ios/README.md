# Podcats for iPhone

Add a script, get a voiced episode, listen to it or hand it to another player. Everything happens on the phone.

- **Voices**: Phonon 31m (Gradium, Apache 2.0) through its Swift package `ptts` 0.7.1 (Core ML). Ten voices: Zoey, Harper, Everly, Juniper, Maeve, Easton, Trevor, Russell, Micah, Hugh. The model folder is inside the app; nothing is downloaded or imported.
- **Preparing**: every episode in the Library is voiced without being asked, one after another, and it carries on with the app in the background or the phone locked. A half-done episode continues from the piece it stopped at.
- **Files**: each finished episode is saved as an `.m4a` (AAC, 24 kHz mono) in the app's folder in the Files app (On My iPhone › Podcats), with no tap. Select several in the Library and Share hands them to VLC, Files or AirDrop as separate files.
- **Scripts in**: paste, Add Files (several `.txt`/`.md` at once), "Open in Podcats" from another app, or a backup `.zip` made by the web app (scripts, titles, voices and positions; audio is made again).
- **Listening**: lock screen controls, back 15, forward 30, speed, position kept per episode.

## Layout

| | |
|---|---|
| `Podcats/Core` | Foundation only: the script parser (a port of the web app's, held to it by `CoreTests`), the episode model, the backup reader. |
| `Podcats/App` | `Engine` (Phonon), `Preparer` (the queue), `Session` (audio session and staying alive in the background), `Player`, `AudioFiles`, `Log` and `Report` (diagnostics), the SwiftUI screens. |
| `PodcatsTests` | Run inside the app in the simulator: real voices, real preparing, real files. |
| `project.yml` | The Xcode project is generated from this with XcodeGen. |
| `ci/` | Fetching the model folder, picking a simulator, and remaking the parser fixtures from the web app. |

## Build

There is no Mac involved: `.github/workflows/ios.yml` builds on a hosted one at every push to `ios/`. It runs `swift test` (parser), the app tests in the simulator, takes screenshots, builds an unsigned `Podcats.ipa`, and uploads everything to the `ios-build` release. The .ipa is only uploaded when the tests pass. Sign it for your own iPhone (for example with Signulous) to install it.

On a Mac: `ci/get-models.sh && xcodegen generate && open Podcats.xcodeproj`.

Off a Mac, the parser can still be checked: `swift test` (Swift 6 toolchain for Linux).

## Staying alive in the background

The app declares the `audio` background mode. Playing an episode keeps it running by itself. While episodes are being prepared and nothing is playing, `Session` loops a silent sound in a session that mixes with other apps, so their audio is not stopped. The voices run on the CPU, not the Neural Engine, so that preparing does not depend on what iOS allows a background app to use.

Settings › Share Diagnostic Report writes a `.json` with a timeline; every entry says whether the app was in front and whether the phone was locked.
