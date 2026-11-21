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

## Updating without a new .ipa

Compiled Swift cannot be replaced on an iPhone without installing the app again. What can be replaced is data, and the app takes that from one file, `update/podcats-update.json` (`UpdatePack` in Core, `Updates` in the app):

- `rules`: regular expressions applied to every piece of text before it is voiced (how acronyms and the like are read);
- `js`: a JavaScript function `prepareText(text)` run after the rules, in JavaScriptCore, with nothing of the app exposed to it;
- `moreVoices`: further voices from the model folder (it holds 38) to offer in the pickers;
- `flags`: `computeUnit` (`cpu`/`neuralEngine`), `bitRate` of the .m4a, `pickerCopies`.

To publish one: edit the file, raise `version`, push. `.github/workflows/ios-update.yml` checks it (`swift test --filter UpdateTests`, `node update/check-script.js`) and uploads it to the `ios-update` release, which is where Settings › Check for Updates looks (also by itself about twice a day, unless switched off). A file can also be handed over by hand: put it in On My iPhone › Podcats, or pick it with Add Files.

An update cannot stop the app from working: it is checked before it is kept and its script is run once on a sample first; a script that fails later is switched off and the text goes to the voice as the rules left it; if the app ended while the script was running, the script stays off at the next launch; Settings › Remove Update goes back to the app as built. Episodes already prepared keep their audio; Prepare Again on an episode's screen makes it afresh. A script that never returns cannot be interrupted: `check-script.js` runs every published script with a time limit for that reason.

Everything else (screens, fixes to the app's code, a new voice model) still takes a new .ipa.

## Staying alive in the background

The app declares the `audio` background mode. Playing an episode keeps it running by itself. While episodes are being prepared and nothing is playing, `Session` loops a silent sound in a session that mixes with other apps, so their audio is not stopped. The voices run on the CPU, not the Neural Engine, so that preparing does not depend on what iOS allows a background app to use.

Settings › Share Diagnostic Report writes a `.json` with a timeline; every entry says whether the app was in front and whether the phone was locked.
