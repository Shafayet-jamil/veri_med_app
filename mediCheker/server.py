import os
import tempfile
from flask import Flask, request, jsonify

# Import existing backend modules
from lookup import run_lookup, lookup_by_dar, load_sheets
from phase2_ocr import run_easyocr

app = Flask(__name__)

# Load medicine and company dataframes
med_df, cmp_df = load_sheets()


def medicine_details(row, dar_number=None):
    return {
        "match_found": True,
        "dar_number": dar_number or row.get("DAR No", ""),
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

    extension = os.path.splitext(file.filename or "")[1].lower()
    if extension not in {".jpg", ".jpeg", ".png", ".webp", ".bmp"}:
        extension = ".img"
    with tempfile.NamedTemporaryFile(delete=False, suffix=extension) as temp_file:
        temp_path = temp_file.name

    try:
        file.save(temp_path)
        # Run EasyOCR extraction
        extracted_list = run_easyocr(temp_path)
        extracted_text = " ".join(extracted_list) if isinstance(extracted_list, list) else str(extracted_list)

        # Lookup details using extracted text
        result_df = run_lookup(extracted_text)
        response_data = {
            "extracted_text": extracted_text,
            "match_found": result_df is not None and not result_df.empty,
        }

        if result_df is not None and not result_df.empty:
            response_data.update(medicine_details(result_df.iloc[0].to_dict()))
        else:
            response_data["status"] = "No matching record"

        return jsonify(response_data)

    except Exception as e:
        return jsonify({
            "error": str(e),
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

    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    print("Starting MediChecker Python Server on http://0.0.0.0:5000 ...")
    app.run(host='0.0.0.0', port=5000, debug=False)
