# MediChecker

MediChecker is a Flutter app that checks whether a medicine is registered
with DGDA (Bangladesh) from a photo of its package, looks a medicine up by
its DAR / MA number or name, and checks medicines for known drug
interactions.

**It runs entirely on the phone.** Text is read with Google ML Kit
(on-device, offline) and the DGDA register ships inside the app, so no
computer, server or internet connection is needed. The Python server in
`mediCheker/` is optional (see [Optional: the Python server](#optional-the-python-server)).

## Install on an Android phone

You need [Flutter](https://docs.flutter.dev/get-started/install) and the
Android SDK (installed with Android Studio) on your computer, once, to
build the app.

1. Get the code and dependencies:

   ```powershell
   flutter pub get
   ```

2. Either plug the phone in with USB debugging on
   (Settings → About phone → tap *Build number* 7 times, then Developer
   options → USB debugging) and run:

   ```powershell
   flutter run --release
   ```

   or build an APK and copy it to the phone:

   ```powershell
   flutter build apk --release
   ```

   The file is `build\app\outputs\flutter-apk\app-release.apk` (about
   80 MB, works on every phone). For a smaller file (about 30 MB), build
   one per phone CPU type with `flutter build apk --release --split-per-abi`
   and use `app-arm64-v8a-release.apk`, which fits almost every phone from
   the last several years. Send it to
   the phone (USB, Google Drive, …), open it, and allow "Install unknown
   apps" when asked.

After that the app works on its own: unplug the phone, no PC needed.
The first scan after opening the app takes a second or two longer while
the medicine register loads.

## How a scan decides real or fake

1. The photo's text is read on the phone (Google ML Kit). The app scans as
   soon as the photo is taken.
2. The DAR / MA number and MFG licence number are looked up in the DGDA
   register (`mediCheker/excelFile/medicine_information_DAR_MA.csv`, bundled
   in the app).
3. The **medicine (brand) name is spell-checked** against every registered
   trade name (`lib/offline/name_check.dart`). This works even when the small
   numbers are not readable, because the brand name is the largest text on
   the pack.

| What the pack shows | Verdict |
|---|---|
| A registered name, spelled exactly, and details that agree | Matches DGDA Record |
| A name one or two letters off a registered brand of the same maker (e.g. "Nappa" for "Napa") | **Likely Fake: Name Misspelled** |
| No registered name, DAR / MA or MFG licence number at all | **Likely Fake: Not Registered** |
| Registration numbers that belong to a different medicine | Details Do Not Match |
| Too little text to read | Could Not Read the Package (retake the photo) |

Small OCR slips are forgiven before a name is called misspelled: digits
read for letters ("Bi1tin" -> "Biltin") and a strength glued to the name
("Napa500"). A word that is a generic, company or everyday word (such as
"Paracetamol" or "Each") only counts as a brand when its maker's name is
also on the pack.

## Optional: the Python server

The app does not need it. It is kept for testing the checking logic in
Python (`lib/offline/` is a line-by-line port of it, with the same tests)
and for serving the app from a computer or cloud host instead.

### Run the Python backend

From the project root, install the backend packages if needed:

```powershell
python -m pip install -r mediCheker\requirements.txt
```

Then start the server:

```powershell
python mediCheker\server.py
```

The API listens on port `5000`. Check that it is running by opening
`http://localhost:5000/`. OCR's first run may take longer while EasyOCR
downloads its language model.

### Server settings

All settings are optional environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `MEDICHECKER_API_KEY` | not set | When set, every request except `/` must send it in the `X-API-Key` header. Set it on any server reachable from the internet. |
| `MEDICHECKER_MAX_UPLOAD_MB` | `10` | Largest photo the server accepts. |
| `MEDICHECKER_SCANS_PER_MINUTE` | `10` | Scans allowed per client IP per minute (`0` = unlimited). |
| `MEDICHECKER_TRUST_PROXY` | not set | Set to `1` behind a reverse proxy or load balancer, so the real client IP is used. |
| `MEDICHECKER_HOST` / `PORT` | `0.0.0.0` / `5000` | Where the server listens. |

`server.py` runs on [Waitress](https://docs.pylonsproject.org/projects/waitress/),
a production-ready server, and only falls back to Flask's development server
if Waitress is not installed.

### More drug-interaction data (optional)

The interaction checker always uses the small hand-written list in
`mediCheker/excelFile/drug_interactions.csv` (65 pairs, with an explanation
for each). To add the [DDInter](https://ddinter.scbdd.com/) database (about
160,000 pairs with a severity level), run once:

```powershell
python mediCheker\import_ddinter.py --accept-license
```

and restart the server. DDInter is licensed
[CC BY-NC-SA 4.0](https://ddinter.scbdd.com/terms/): **non-commercial use
only**, with credit to DDInter (the app shows the source with each result).
That is why the downloaded file (`excelFile/ddinter_interactions.csv`) is
ignored by git and not part of this repository. Delete it to stop using
DDInter. If MediChecker is ever used commercially, replace DDInter with a
commercially licensed source.

### Use the server from the app

The app uses the server only when built with its address. For the Android
emulator (which reaches the host computer at `10.0.2.2`):

```powershell
flutter run --dart-define=MEDICHECKER_API_URL=http://10.0.2.2:5000
```

For a physical phone, use the computer's LAN IP, with both devices on the
same network:

```powershell
flutter run --dart-define=MEDICHECKER_API_URL=http://192.168.1.10:5000
```

If the server has an API key, pass the same key to the app:

```powershell
flutter run --dart-define=MEDICHECKER_API_URL=https://your-server.example.com --dart-define=MEDICHECKER_API_KEY=your-key
```

Plain HTTP is for development; use HTTPS for a deployed server.

## Run the tests

Backend (from the `mediCheker` folder):

```powershell
python -m pip install -r requirements-dev.txt
python -m pytest
```

The backend tests use the real CSV data but replace EasyOCR with a stub, so
they run in a few seconds without loading the OCR model.

Flutter app (from the project root):

```powershell
flutter test
```

`test/offline_checker_test.dart` runs the on-device checker on the real
DGDA data with the same cases as the Python tests, so both give the same
answers.

## Deploy the Python server (optional)

`mediCheker/Dockerfile` builds a self-contained image (CPU-only PyTorch, the
EasyOCR models downloaded at build time) that runs on any container host,
such as Google Cloud Run, Render, Railway or a VPS:

```powershell
docker build -t medichecker-api mediCheker
docker run -p 8080:8080 -e MEDICHECKER_API_KEY=your-key medichecker-api
```

Give the container at least 2 GB of memory. The hosting platform should
provide HTTPS. Then build the app with `MEDICHECKER_API_URL` set to the
`https://` address and `MEDICHECKER_API_KEY` set to the same key.

## Limitations

- **Interaction results are not medical advice.** Without DDInter the list
  has only 65 pairs. Even with it, "No known interactions" only means the
  pair is not listed. DDInter entries give a severity but no explanation.
- **A blurry photo can look like a misspelling.** OCR can misread a letter,
  so "Likely Fake" results tell the user to retake the photo first. Always
  confirm with a pharmacist before discarding a medicine.
- **Verification compares text, it cannot prove authenticity.** The scan
  checks the details it can read on the package against the DGDA
  registration record. Details that are not visible in the photo are reported
  as "not visible" and do not lower the result; only details that are read
  and contradict the record count against it. A good copy of a real package
  can still match.
