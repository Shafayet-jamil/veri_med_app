# MediChecker

MediChecker is a Flutter mobile app connected to the Flask API in `mediCheker`.
It can send a medicine package photo for OCR or look up a medicine by its
DAR / MA registration number.

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

The app supports camera/gallery selection and DAR / MA lookup. It displays
the extracted OCR text, medicine fields, and API errors. The local HTTP
configuration is for development; use HTTPS for a deployed backend.
