# MediChecker

MediChecker is a Flutter mobile app connected to the Flask API in `mediCheker`.
It can send a medicine package photo for OCR or look up a medicine by its
DAR / MA registration number, and check selected medicines for known drug
interactions.

## Run the Python backend

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

## Run the Flutter app

Install the Flutter dependencies, then run on an Android emulator:

```powershell
flutter pub get
flutter run
```

The default API URL is `http://10.0.2.2:5000`, which lets the Android emulator
reach the host computer. For a physical phone, use the computer's LAN IP and
make sure both devices are on the same network:

```powershell
flutter run --dart-define=MEDICHECKER_API_URL=http://192.168.1.10:5000
```

Replace `192.168.1.10` with the computer's actual LAN IP. For other targets,
override the URL similarly; for example, use `http://127.0.0.1:5000` for an
iOS simulator.

If the server has an API key, pass the same key to the app:

```powershell
flutter run --dart-define=MEDICHECKER_API_URL=https://your-server.example.com --dart-define=MEDICHECKER_API_KEY=your-key
```

The app supports camera/gallery selection and DAR / MA lookup. It displays
the extracted OCR text, medicine fields, and API errors. The local HTTP
configuration is for development; use HTTPS for a deployed backend.

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

## Deploy the backend

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

- **Interaction data is small.** `excelFile/drug_interactions.csv` lists 65
  pairs across about 50 drugs. "No known interactions" only means the pair is
  not in this file. Expand it from a vetted source before relying on it.
- **Verification is a heuristic.** The genuine / suspicious / counterfeit
  verdict compares the text on the package with the DGDA registration record.
  A good copy of a real package can still score as genuine.
