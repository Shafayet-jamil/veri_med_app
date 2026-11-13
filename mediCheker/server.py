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
from lookup import run_lookup, lookup_by_dar, load_sheets, prepare_for_display
from phase2_ocr import run_easyocr, UnreadableImageError
from interactions import (load_interactions, load_medicine_names, check_interactions,
                          data_sources)
from verification import compute_verification
from name_check import get_brand_index, EXACT, MISSPELLED, NOT_FOUND

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
brand_index = get_brand_index()


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


def _record_for_row(row_index):
    """The registration record (with company licence details) of one row of
    the medicine sheet, in the same shape as ``run_lookup`` returns."""
    dar = med_df.at[row_index, "DAR No"]
    rows = lookup_by_dar(dar, med_df, cmp_df)
    if rows.empty:
        rows = med_df.loc[[row_index]]
    trade = med_df.at[row_index, "Trade Name"]
    same = rows[rows["Trade Name"] == trade]
    return prepare_for_display((same if not same.empty else rows).iloc[0:1]).iloc[0].to_dict()


def _brand_check_for_record(text, trade_name):
    """Spell-check the record's brand name on the pack. When it is not there,
    note a *different* registered brand that is: the numbers may have been
    copied from another medicine."""
    check = brand_index.check(text, expected_brand=trade_name)
    if check.status == NOT_FOUND:
        other = brand_index.check(text)
        if (other.status == EXACT and other.row_index is not None
                and brand_index.med_df.at[other.row_index, "Trade Name"].split()[0].lower()
                != trade_name.split()[0].lower()):
            result = other.to_dict()
            result["status"] = "other_brand"
            result["registered_name"] = trade_name
            return result
    return check.to_dict()


NO_RECORD_VERIFICATION = {
    "verification_score": 0,
    "verdict": "no_record",
    "verdict_label": "Could Not Read the Package",
    "verdict_description": (
        "Too little text could be read from this photo to check the medicine. "
        "Retake the photo of the side that shows the brand name, in good "
        "light and in focus, or type the DAR / MA number in the Lookup tab."
    ),
    "checks": [],
    "matched_fields": 0,
    "mismatched_fields": 0,
    "read_fields": 0,
    "total_fields": 0,
}


def _not_registered_verification(suggestions):
    description = (
        "No medicine name, DAR / MA number or MFG licence number on this "
        "package matches the official DGDA register of medicines. A medicine "
        "that is not registered is treated as fake: do not use it, and show "
        "it to a pharmacist."
    )
    if suggestions:
        description += (" Closest registered names: " + ", ".join(suggestions[:3]) + ".")
    description += (" If the brand name is not in the photo or the photo is "
                    "blurry, retake it showing the front of the pack.")
    return {
        **NO_RECORD_VERIFICATION,
        "verdict": "not_registered",
        "verdict_label": "Likely Fake: Not Registered",
        "verdict_description": description,
    }


def identify_and_verify(text):
    """Identify the medicine in OCR ``text`` and check it against DGDA.

    The DAR / MA and MFG licence numbers are tried first, then the brand
    name's spelling. Returns the response fields for /scan-medicine.
    """
    result_df = run_lookup(text)
    if result_df is not None and not result_df.empty:
        row = result_df.iloc[0].to_dict()
        response = medicine_details(row)
        # "manufacturer": only the MFG licence number was recognised, so
        # the record describes the company, not a specific medicine.
        if row.get("DAR No"):
            response["match_type"] = "medicine"
            name = _brand_check_for_record(text, row.get("Trade Name", ""))
        else:
            # run_lookup already picks this maker's product when its name is
            # spelled right; here look for one of its brands misspelled.
            name = None
            brand = brand_index.check(text)
            if brand.row_index is not None:
                record = _record_for_row(brand.row_index)
                if _same_company(record, row):
                    row = record
                    response = medicine_details(row)
                    response["match_type"] = "medicine"
                    name = brand.to_dict()
            response.setdefault("match_type", "manufacturer")
        response["name_check"] = name
        response["verification"] = compute_verification(text, row, name_check=name)
        return response

    name = brand_index.check(text)
    if name.row_index is not None:
        row = _record_for_row(name.row_index)
        response = medicine_details(row)
        response["match_type"] = "brand_name"
        response["name_check"] = name.to_dict()
        response["verification"] = compute_verification(text, row,
                                                        name_check=name.to_dict())
        return response

    response = {
        "match_found": False,
        "match_type": "none",
        "status": "Not registered" if name.status == NOT_FOUND else "No matching record",
        "name_check": name.to_dict(),
    }
    response["verification"] = (_not_registered_verification(name.suggestions)
                                if name.status == NOT_FOUND
                                else NO_RECORD_VERIFICATION)
    return response


def _same_company(a, b):
    def key(row):
        return str(row.get("Company", "")).lower().strip()
    return bool(key(a)) and key(a) == key(b)


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

        response_data = {"extracted_text": display_text}
        response_data.update(identify_and_verify(extracted_text))
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

@app.route('/verify-name', methods=['GET', 'POST'])
def verify_name():
    """Is a typed medicine (brand) name registered with DGDA?"""
    name = request.args.get('name')
    if not name and request.is_json:
        name = (request.get_json(silent=True) or {}).get('name')
    if not isinstance(name, str) or not name.strip():
        return jsonify({"error": "Missing name parameter"}), 400
    if len(name) > 100:
        return jsonify({"error": "Name is too long"}), 400

    check = brand_index.lookup_name(name)
    if check.row_index is None:
        suggestions = check.suggestions
        description = f"\"{name.strip()}\" is not a medicine name registered with DGDA."
        if suggestions:
            description += " Did you mean: " + ", ".join(suggestions) + "?"
        return jsonify({
            "match_found": False,
            "brand_name": name.strip(),
            "status": "Not registered",
            "description": description,
            "name_check": check.to_dict(),
        }), 404
    response = medicine_details(_record_for_row(check.row_index))
    response["name_check"] = check.to_dict()
    return jsonify(response)


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
