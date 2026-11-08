# MediChecker: 8-Week Project Plan (Start to Now)

**Project:** MediChecker (`veri_med_app`), a Flutter mobile app with a Python/Flask backend
that reads a medicine package photo (OCR), checks it against the DGDA registration
database to spot fake or mismatched medicines, and checks drug-to-drug interactions.

**Period:** 14 September 2026 – 8 November 2026 (8 weeks)

**Order of work:** Planning → Backend → OCR & Database → Data Extraction → Frontend →
API → UI → Security → Testing, Deployment & Other

---

## Overview

| Week | Dates | Phase | Main output |
|---|---|---|---|
| 1 | 14 – 20 Sep | Planning & research | Problem statement, features, tech stack, data sources |
| 2 | 21 – 27 Sep | Backend setup | Flask server skeleton, project structure, dependencies |
| 3 | 28 Sep – 4 Oct | OCR & Database | EasyOCR + OpenCV pipeline, DGDA CSV datasets loaded |
| 4 | 5 – 11 Oct | Data extraction | DAR/MA and MFG licence parsing, lookup, verification score |
| 5 | 12 – 18 Oct | Frontend | Flutter app, camera/gallery, first screens |
| 6 | 19 – 25 Oct | API | REST endpoints, Flutter API service, interaction checker |
| 7 | 26 Oct – 1 Nov | UI | Three-tab UI, verification badge, fake medicine detection screen |
| 8 | 2 – 8 Nov | Security & other | API key, rate limit, upload limit, Docker, tests, DDInter, fixes |

---

## Week 1: Planning & Research (14 – 20 Sep)

**Goal:** Decide what to build and how.

- Define the problem: fake and unregistered medicines in Bangladesh, and unsafe drug combinations.
- List the core features:
  1. Scan a medicine package photo and read its text.
  2. Verify the medicine against the DGDA (Directorate General of Drug Administration) registration record.
  3. Look up a medicine by its DAR / MA registration number.
  4. Check selected medicines for known interactions.
- Choose the tech stack: **Flutter** (mobile app), **Python + Flask** (backend),
  **EasyOCR + OpenCV** (text recognition), **pandas + CSV** (data).
- Collect data sources: the DGDA medicine list (DAR/MA numbers), the manufacturer
  (company) list, and a drug interaction list.
- Collect sample package photos for testing (`mediCheker/dataset/sample-1 … sample-11`).
- Draw the system flow: Photo → OCR → extract numbers → database lookup → verification result → app.

**Deliverable:** Project proposal, feature list, system design diagram.

---

## Week 2: Backend Setup (21 – 27 Sep)

**Goal:** Build the base of the Python server.

- Create the `mediCheker/` backend folder and a Python virtual environment.
- Set up **Flask** in `server.py` with a health-check route (`GET /`).
- Add `requirements.txt` (Flask, pandas, opencv-python, easyocr, numpy).
- Plan the module layout:
  - `phase2_ocr.py`: OCR
  - `lookup.py`: database lookup
  - `verification.py`: authenticity checks
  - `interactions.py`: drug interactions
- Handle image upload (save the received file to a temporary path, then delete it).

**Deliverable:** A running Flask server on port 5000 that accepts an image upload.

---

## Week 3: OCR & Database (28 Sep – 4 Oct)

**Goal:** Read text from package photos and load the medicine database.

**OCR (`phase2_ocr.py`):**
- Integrate **EasyOCR** (English model, loaded once and reused).
- Image preprocessing with **OpenCV**: resize, grayscale, deskew.
- Several preprocessing strategies, keeping the best result:
  CLAHE + Otsu, adaptive threshold, inverted image, high contrast.
- Confidence filter, sorting text by position (top-to-bottom, left-to-right),
  removing duplicates, fixing common OCR mistakes.

**Database (`excelFile/`):**
- `medicine_information_DAR_MA.csv`: about 41,300 registered medicines
  (company, trade name, generic name with strength, dosage form, DAR No).
- `Company Info functionalOrNonFunctional.csv`: about 330 manufacturers with
  licence number and status.
- Load the CSV files with pandas once at startup (not on every request).

**Deliverable:** OCR returns clean text from the sample photos; database loads in memory.

---

## Week 4: Data Extraction (5 – 11 Oct)

**Goal:** Turn raw OCR text into structured, verifiable data.

**Lookup (`lookup.py`):**
- Regex to find the **DAR / MA number** (e.g. `481-0003-034`) in OCR text,
  including normalisation (pad short middle parts to 4 digits).
- Regex to find the **manufacturing (MFG) licence number** and match it to a company.
- Look up the medicine by DAR number; if not found, match the product name in the text.
- Prepare clean output fields: company, trade name, generic name, dosage form, DAR No.

**Verification (`verification.py`):**
- Compare each field read from the photo with the registered record.
- Each field gets a status (match / mismatch / not visible) and a weight.
- Produce an overall verdict and a short summary.
- Rule: details not visible in the photo do not lower the score; only
  details that are read and contradict the record count against it.

**Deliverable:** `run_lookup(ocr_text)` and `compute_verification(...)` working on sample data.

---

## Week 5: Frontend (12 – 18 Oct)

**Goal:** Build the Flutter mobile app.

- Create the Flutter project (`lib/main.dart`), Android and iOS targets.
- Add packages: `image_picker` (camera / gallery) and `http`.
- Build the first screens: pick or take a photo, show the photo, show a result area.
- Add a manual DAR / MA number input for lookup without a photo.
- Reusable widgets, starting with `lib/widgets/section_card.dart`.

**Deliverable:** A Flutter app that runs on the Android emulator and can pick a photo.

---

## Week 6: API (19 – 25 Oct)

**Goal:** Connect the app and the server through a REST API.

**Backend endpoints (`server.py`):**

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/` | Health check |
| POST | `/scan-medicine` (also `/extract-text`) | Upload photo → OCR → lookup → verification |
| GET/POST | `/verify-license` (also `/check-dar`) | Look up by DAR / MA number |
| GET | `/medicine-names` | List of medicine names for the interaction picker |
| POST | `/check-interactions` | Check selected medicines for interactions |

- JSON responses with clear error messages.
- **Drug interaction checker** (`interactions.py`): curated list of 65 pairs
  (`drug_interactions.csv`), matching whole drug names, generic-name extraction.

**Flutter API service (`lib/services/medicine_api.dart`):**
- Multipart photo upload, DAR lookup, medicine list, interaction check.
- Configurable server URL (`--dart-define=MEDICHECKER_API_URL=...`,
  default `http://10.0.2.2:5000` for the emulator).

**Deliverable:** The app sends a photo and receives the medicine details end to end.

---

## Week 7: UI (26 Oct – 1 Nov)

**Goal:** Make the app clear and easy to use.

- Redesign into a **three-tab layout**: Scan, DAR / MA Lookup, Interactions.
- **Verification badge** (`lib/widgets/verification_badge.dart`): shows the verdict
  (genuine-looking / suspicious / not found) and a field-by-field breakdown.
- **Fake medicine detection** result screen with the manufacturer shown.
- **Interaction checker screen** (`lib/screens/interaction_checker_screen.dart`):
  search and select medicines, show severity and explanation, warn about limited data.
- Loading states, error messages, and the extracted OCR text shown for transparency.
- OCR accuracy improvements found during UI testing (multi-strategy preprocessing, text cleanup).

**Deliverable:** Complete, polished user interface (git: “fake medicine detection + UI overhaul”).

---

## Week 8: Security, Testing, Deployment & Other (2 – 8 Nov) ← current week

**Goal:** Make the app safe, tested, and ready to deploy.

**Security:**
- Optional **API key** (`MEDICHECKER_API_KEY`) checked with a constant-time compare
  (`hmac.compare_digest`) in the `X-API-Key` header.
- **Rate limiting:** scans per client IP per minute (`MEDICHECKER_SCANS_PER_MINUTE`).
- **Upload size limit** (`MEDICHECKER_MAX_UPLOAD_MB`, default 10 MB).
- Proxy-aware client IP (`MEDICHECKER_TRUST_PROXY`) for use behind a load balancer.
- Production server **Waitress** instead of the Flask development server.

**Testing:**
- Backend tests with pytest: `test_lookup.py`, `test_verification.py`,
  `test_interactions.py`, `test_server.py` (OCR replaced with a stub so tests are fast).
- Flutter tests: `widget_test.dart`, `medicine_api_test.dart`.
- OCR evaluation script on the sample photos (`eval_ocr.py`, in progress).

**Deployment:**
- `Dockerfile` with CPU-only PyTorch and EasyOCR models downloaded at build time
  (runs on Cloud Run, Render, Railway, or a VPS).

**Other improvements:**
- Optional **DDInter** interaction data (about 160,000 pairs) via `import_ddinter.py`
  (CC BY-NC-SA, non-commercial only).
- Performance: cap image size and stop OCR once the key identifiers are found.
- Bug fixes: MFG licence regex grabbing unrelated digits, DAR/MA padding,
  verification judging only what the photo shows.
- README with setup, settings, deployment, and limitations.

**Deliverable:** Secure, tested, deployable version (merged into `main` through PRs #1 and #2).

---

## Current Status (8 Nov 2026)

| Phase | Status |
|---|---|
| Planning | Done |
| Backend | Done |
| OCR & Database | Done |
| Data extraction | Done |
| Frontend | Done |
| API | Done |
| UI | Done |
| Security | Done |
| Testing & deployment | Mostly done (OCR evaluation script still in progress) |

**Code size:** about 1,200 lines of Python backend, 1,900 lines of Flutter/Dart,
and 750 lines of tests.

## Possible Next Steps

- Finish and report OCR accuracy on the sample dataset (`eval_ocr.py`).
- Deploy the backend over HTTPS and test on a physical phone.
- Add more labelled package photos to measure verification accuracy.
- Bangla text support in OCR.
- Final report and presentation.
