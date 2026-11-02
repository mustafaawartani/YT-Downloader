# Toolbox

One app of small tools for **Android and Windows**:

| Tool | What it does |
|---|---|
| ⬇️ **Downloader** | Search YouTube inside the app, or paste a link from YouTube, TikTok, Instagram, Facebook, X, SoundCloud, Vimeo and [1,800+ other sites](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md). Save as **MP4 video** (up to 4K), **MP3** (128–320 kbps) or **M4A** (original audio). |
| 🎙️ **Voice notes** | Transcribe WhatsApp voice notes and translate them to **English** and/or **Arabic**. |

## Install

Every push to `main` builds both apps and publishes them as the **[latest release](../../releases/tag/latest)**.

- **Android:** on your phone, download `Toolbox.apk` and open it. Allow "Install unknown apps" when asked. Needs Android 10+ on a 64-bit phone.
- **Windows:** download `Toolbox-windows.zip`, extract it anywhere, then run `toolbox.exe`.
  The helper programs (yt-dlp, FFmpeg, Deno, whisper) are already inside its `tools` folder.

## Downloader

- **Search:** type, press Enter, then tap 🎬 for video or 🎵 for audio. Tap the tune icon to pick a format and quality.
- **Link:** tap *Paste* and you get a preview with *Video*, *Audio* and *More options* buttons. Playlists work too.
- **Share from other apps (Android):** in the YouTube or TikTok app, tap *Share → Toolbox* and the link opens ready to download.
- Downloads go to `Download/Toolbox/Video`, `…/MP3` and `…/M4A`. On Windows that's `Downloads\Toolbox\…`, and you can change it in Settings.
- **Full HD and MP3 work on Android too.** The app includes FFmpeg (which joins YouTube's separate HD video and audio streams) and a JavaScript engine (which YouTube needs to unlock all formats).
- yt-dlp **updates itself** every few days, because sites change often. You can also update it now from *Settings*.

## Voice notes

Ways to load voice notes:

| How | Steps |
|---|---|
| One voice note | In WhatsApp, long-press the voice note → **Share** → **Toolbox**. It transcribes right away. |
| Everything from one contact | Open the chat → **⋮ → More → Export chat → Include media** → **Toolbox**. You see every voice note with sender and date, and you can filter by person. |
| Browse all (Android) | Tap **Voice notes folder** and pick `Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Voice Notes`. |
| Windows | **Open files / chat .zip**: pick voice notes or an exported chat that you copied from your phone. |

The 🌐 button at the top picks the language the voice notes are spoken in. Spanish is the default.

### Speech-to-text: Groq (recommended) or on-device

- **Groq (best accuracy).** Paste your free Groq API key in **Settings** (get one at console.groq.com → *API Keys*).
  Voice notes are transcribed with **Whisper large-v3** and translated by a large language model on Groq.
  This is much more accurate than the small on-device model. The voice note is sent to Groq.
  The key is stored only on your device and is never in this repository or the app download.
- **On-device (offline).** Tap *Download offline model* (82 MB, one time). It's private and works without internet, but it's less accurate.
  On Android, translation then uses Google ML Kit on the phone. On Windows, it sends only the text to Google Translate.

If Groq translation fails, the app falls back to the platform translator.

## Building

Builds run on GitHub Actions (`.github/workflows/build.yml`), so you don't need Android Studio or Visual Studio.

### Android signing (so updates install over the old version)

Android only accepts an update signed with the same key as the installed app. Without a key, the workflow signs
with a temporary key, so you have to uninstall before installing a newer build. To fix that once:

1. Create a key on any computer with Java:

   ```bash
   keytool -genkeypair -keystore release.keystore -storepass YOUR_PASSWORD -keypass YOUR_PASSWORD -alias toolbox -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Toolbox"
   ```

2. Base64-encode it (on Windows PowerShell, use `[Convert]::ToBase64String([IO.File]::ReadAllBytes("release.keystore"))`):

   ```bash
   base64 -w0 release.keystore
   ```

3. In GitHub, go to **Settings → Secrets and variables → Actions** and add:
   - `ANDROID_KEYSTORE_B64`: the base64 text
   - `ANDROID_KEYSTORE_PASSWORD`: `YOUR_PASSWORD`

Keep `release.keystore` somewhere safe and **never commit it**.

### Local builds

```bash
git clone --depth 1 --branch v1.9.5 https://github.com/ggml-org/whisper.cpp android/app/src/main/cpp/whisper.cpp
flutter build apk --release --target-platform android-arm64
```

```bash
flutter build windows --release
```

The Windows build needs `yt-dlp.exe`, `ffmpeg.exe`, `ffprobe.exe`, `deno.exe` and `whisper-cli.exe` in
`build/windows/x64/runner/Release/tools/` (the workflow does this).

Tests: `flutter test`. They include real downloads from a local test server if `yt-dlp` and `ffmpeg` are on your PATH.

## Project layout

```
lib/main.dart                  home screen (tool grid), settings, share handling
lib/tools/downloader/          yt-dlp commands + parsing, engines, download queue, UI
lib/tools/voice/               chat-export import, Groq client, engines, controller, UI
android/app/src/main/kotlin/   youtubedl-android, whisper.cpp JNI, ML Kit, MediaStore, share intents
android/app/src/main/cpp/      whisper.cpp JNI bridge
```

Adding a new tool means adding a folder under `lib/tools/` and a card on the home screen.

## Legal

Only download content you own or have permission to download, and respect each platform's terms and copyright law.
