import hmac
import logging
import os
import tempfile
import threading
import time
from collections import defaultdict, deque

from flask import Flask, request, jsonify
from werkzeug.exceptions import HTTPException
from werkzeug.middleware.proxy_fix import ProxyFix

# Import existing backend modules
from lookup import run_lookup, lookup_by_dar, load_sheets
from phase2_ocr import run_easyocr, UnreadableImageError
from interactions import (load_interactions, load_medicine_names, check_interactions,
                          data_sources)
from verification import compute_verification

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("medichecker")


def _env_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


# ── Configuration (all optional, set through environment variables) ─────────
# MEDICHECKER_API_KEY            if set, every request except "/" must send it
#                                in the X-API-Key header
# MEDICHECKER_MAX_UPLOAD_MB      largest accepted photo (default 10 MB)
# MEDICHECKER_SCANS_PER_MINUTE   scans allowed per client per minute
#                                (default 10, 0 = unlimited)
# MEDICHECKER_TRUST_PROXY        set to 1 behind a reverse proxy / load
#                                balancer so the real client IP is used
# MEDICHECKER_HOST, PORT         where the server listens (0.0.0.0:5000)
API_KEY = os.environ.get("MEDICHECKER_API_KEY", "")
MAX_UPLOAD_MB = _env_int("MEDICHECKER_MAX_UPLOAD_MB", 10)
SCANS_PER_MINUTE = _env_int("MEDICHECKER_SCANS_PER_MINUTE", 10)
MAX_INTERACTION_MEDICINES = 20

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_MB * 1024 * 1024
if os.environ.get("MEDICHECKER_TRUST_PROXY") == "1":
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1)

# Load medicine and company dataframes
med_df, cmp_df = load_sheets()
interactions_df = load_interactions()


def medicine_details(row, dar_number=None):
    return {
        "match_found": True,
        "dar_number": row.get("DAR No") or dar_number or "",
        "brand_name": row.get("Trade Name") or row.get("Brand Name") or "",
        "generic_name": row.get("Generic Name With Strength") or row.get("Generic Name") or "",
        "manufacturer": row.get("Company") or row.get("Manufacturer") or "",
        "strength": row.get("Strength") or "",
        "dosage_form": row.get("Dosage Form") or "",
        "status": row.get("Status") or row.get("Validity") or "",
        "validity": row.get("Validity") or "",
        "description": row.get("Address") or "",
        "mfg_license_biological": row.get("MFG Lic (Biological)") or row.get("Bio_3") or "",
        "mfg_license_non_biological": row.get("MFG Lic (Non-Biological)") or row.get("NonBio_3") or "",
    }


class _RateLimiter:
    """Sliding-window limit per client IP (in memory, per server process)."""

    def __init__(self, limit, window_seconds=60):
        self.limit = limit
        self.window = window_seconds
        self._hits = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, key):
        if self.limit <= 0:
            return True
        now = time.monotonic()
        with self._lock:
            hits = self._hits[key]
            while hits and now - hits[0] >= self.window:
                hits.popleft()
            if len(hits) >= self.limit:
                return False
            hits.append(now)
            return True


scan_limiter = _RateLimiter(SCANS_PER_MINUTE)


@app.before_request
def require_api_key():
    if not API_KEY or request.method == 'OPTIONS' or request.path == '/':
        return None
    supplied = request.headers.get('X-API-Key', '')
    if not hmac.compare_digest(supplied.encode(), API_KEY.encode()):
        return jsonify({"error": "Missing or invalid API key"}), 401
    return None


@app.errorhandler(413)
def upload_too_large(_error):
    return jsonify({
        "error": f"Image is too large. The maximum upload size is {MAX_UPLOAD_MB} MB."
    }), 413


@app.errorhandler(Exception)
def unexpected_error(error):
    if isinstance(error, HTTPException):
        return jsonify({"error": error.description}), error.code
    # Log the details on the server, but don't leak them to clients.
    log.exception("Unhandled error on %s", request.path)
    return jsonify({"error": "Internal server error"}), 500


@app.route('/', methods=['GET'])
def health_check():
    return jsonify({
        "status": "online",
        "message": "MediChecker Python Server is running!"
    })

@app.route('/scan-medicine', methods=['POST', 'OPTIONS'])
@app.route('/extract-text', methods=['POST', 'OPTIONS'])
def scan_medicine():
    if request.method == 'OPTIONS':
        return jsonify({}), 200

    file = request.files.get('image') or request.files.get('file')
    if not file:
        return jsonify({"error": "No image file provided in request"}), 400

    if not scan_limiter.allow(request.remote_addr or "unknown"):
        return jsonify({
            "error": "Too many scans. Please wait a minute and try again."
        }), 429

    extension = os.path.splitext(file.filename or "")[1].lower()
    if extension not in {".jpg", ".jpeg", ".png", ".webp", ".bmp"}:
        extension = ".img"
    with tempfile.NamedTemporaryFile(delete=False, suffix=extension) as temp_file:
        temp_path = temp_file.name

    try:
        file.save(temp_path)
        extracted_list = run_easyocr(temp_path)
        extracted_text = " ".join(extracted_list) if isinstance(extracted_list, list) else str(extracted_list)
        display_text = " | ".join(extracted_list) if isinstance(extracted_list, list) else str(extracted_list)

        result_df = run_lookup(extracted_text)
        response_data = {
            "extracted_text": display_text,
            "match_found": result_df is not None and not result_df.empty,
        }

        if result_df is not None and not result_df.empty:
            row_dict = result_df.iloc[0].to_dict()
            response_data.update(medicine_details(row_dict))
            # "manufacturer": only the MFG licence number was recognised, so
            # the record describes the company, not a specific medicine.
            response_data["match_type"] = "medicine" if row_dict.get("DAR No") else "manufacturer"
            verification = compute_verification(extracted_text, row_dict)
            response_data["verification"] = verification
        else:
            response_data["match_type"] = "none"
            response_data["status"] = "No matching record"
            response_data["verification"] = {
                "verification_score": 0,
                "verdict": "no_record",
                "verdict_label": "Not Found in DGDA Records",
                "verdict_description": (
                    "No DAR / MA number or MFG licence number on the package "
                    "matched the DGDA database. The numbers may not have been "
                    "readable in this photo: try a clearer photo, or type the "
                    "DAR / MA number in the Lookup tab. If the number is "
                    "readable and still not found, the medicine may not be "
                    "registered."
                ),
                "checks": [],
                "matched_fields": 0,
                "mismatched_fields": 0,
                "read_fields": 0,
                "total_fields": 0,
            }

        return jsonify(response_data)

    except UnreadableImageError as e:
        return jsonify({"error": str(e)}), 400
    except Exception:
        log.exception("Scan failed")
        return jsonify({
            "error": "Could not process the image. Please try again.",
            "extracted_text": "Error processing image text"
        }), 500
    finally:
        if os.path.exists(temp_path):
            os.remove(temp_path)

@app.route('/verify-license', methods=['GET', 'POST'])
@app.route('/check-dar', methods=['GET', 'POST'])
def verify_license():
    dar_number = request.args.get('dar_number') or request.args.get('license_no')
    if not dar_number and request.is_json:
        data = request.get_json(silent=True) or {}
        dar_number = data.get('dar_number') or data.get('license_no')

    if not dar_number:
        return jsonify({"error": "Missing dar_number parameter"}), 400

    try:
        # Attempt lookup by DAR
        result_df = lookup_by_dar(dar_number, med_df, cmp_df)

        if result_df is not None and not result_df.empty:
            row = result_df.iloc[0].to_dict()
            return jsonify(medicine_details(row, dar_number))
        else:
            # Fallback using run_lookup
            result_df = run_lookup(dar_number)
            if result_df is not None and not result_df.empty:
                row = result_df.iloc[0].to_dict()
                return jsonify(medicine_details(row, dar_number))

            return jsonify({
                "dar_number": dar_number,
                "match_found": False,
                "status": "Not Found / Unregistered",
                "description": f"No license records found for DAR number: {dar_number}"
            }), 404

    except Exception:
        log.exception("License lookup failed")
        return jsonify({"error": "Internal server error"}), 500

@app.route('/medicine-names', methods=['GET'])
def get_medicine_names():
    try:
        names = load_medicine_names()
        return jsonify({"medicines": names})
    except Exception:
        log.exception("Loading medicine names failed")
        return jsonify({"error": "Internal server error"}), 500


@app.route('/check-interactions', methods=['POST'])
def check_drug_interactions():
    data = request.get_json(silent=True) or {}
    medicines = data.get('medicines', [])

    if not isinstance(medicines, list) or len(medicines) < 2:
        return jsonify({"error": "Provide at least 2 medicine names"}), 400
    if len(medicines) > MAX_INTERACTION_MEDICINES:
        return jsonify({
            "error": f"Check at most {MAX_INTERACTION_MEDICINES} medicines at a time"
        }), 400
    if not all(isinstance(m, str) and m.strip() for m in medicines):
        return jsonify({"error": "Medicine names must be non-empty text"}), 400

    try:
        results = check_interactions(medicines, interactions_df)
        return jsonify({
            "interactions_found": len(results) > 0,
            "interaction_count": len(results),
            "interactions": results,
            "medicines_checked": medicines,
            "sources": data_sources(interactions_df),
        })
    except Exception:
        log.exception("Interaction check failed")
        return jsonify({"error": "Internal server error"}), 500


if __name__ == '__main__':
    host = os.environ.get("MEDICHECKER_HOST", "0.0.0.0")
    port = _env_int("PORT", 5000)
    if not API_KEY:
        log.warning("MEDICHECKER_API_KEY is not set: anyone who can reach "
                    "this server can use it. Set it before deploying.")
    try:
        from waitress import serve
    except ImportError:
        log.warning("waitress is not installed; using Flask's development server.")
        app.run(host=host, port=port, debug=False)
    else:
        print(f"Starting MediChecker Python Server on http://{host}:{port} ...")
        serve(app, host=host, port=port, threads=4)
