import re
import pandas as pd
from lookup import load_sheets, lookup_by_dar, extract_and_normalize_dar_ma_number


def compute_verification(extracted_text: str, db_row: dict) -> dict:
    checks = []
    ocr_lower = extracted_text.lower()

    dar_extracted = extract_and_normalize_dar_ma_number(extracted_text)
    dar_db = (db_row.get("DAR No") or db_row.get("dar_number") or "").strip()
    if dar_extracted and dar_db:
        match = dar_extracted.strip() == dar_db.strip()
        checks.append({
            "field": "DAR / MA Number",
            "extracted": dar_extracted,
            "registered": dar_db,
            "match": match,
            "weight": 30,
        })

    trade_db = (db_row.get("Trade Name") or db_row.get("brand_name") or "").strip()
    if trade_db:
        found = trade_db.lower() in ocr_lower
        checks.append({
            "field": "Brand / Trade Name",
            "extracted": _find_in_text(ocr_lower, trade_db.lower()),
            "registered": trade_db,
            "match": found,
            "weight": 20,
        })

    company_db = (db_row.get("Company") or db_row.get("manufacturer") or "").strip()
    if company_db:
        company_words = [w for w in company_db.lower().split() if len(w) > 2]
        matched_words = sum(1 for w in company_words if w in ocr_lower)
        found = matched_words >= max(1, len(company_words) // 2)
        checks.append({
            "field": "Manufacturer",
            "extracted": _find_in_text(ocr_lower, company_db.lower()),
            "registered": company_db,
            "match": found,
            "weight": 20,
        })

    generic_db = (db_row.get("Generic Name With Strength") or
                  db_row.get("generic_name") or "").strip()
    if generic_db:
        base_generic = re.sub(r'\d+(\.\d+)?\s*(mg|gm|ml|mcg|iu).*', '',
                              generic_db, flags=re.IGNORECASE).strip().lower()
        if base_generic:
            found = base_generic in ocr_lower
            checks.append({
                "field": "Generic Name",
                "extracted": _find_in_text(ocr_lower, base_generic),
                "registered": generic_db,
                "match": found,
                "weight": 15,
            })

    mfg_pattern = r'(?:mfg|mig)[\s.:]*lic[\s.:]*no[^\d]*((?:\d{3})(?:\s*&\s*\d{3})*)'
    mfg_match = re.search(mfg_pattern, extracted_text, re.IGNORECASE)
    bio_db = (db_row.get("Bio_3") or db_row.get("MFG Lic (Biological)") or
              db_row.get("mfg_license_biological") or "").strip()
    nonbio_db = (db_row.get("NonBio_3") or db_row.get("MFG Lic (Non-Biological)") or
                 db_row.get("mfg_license_non_biological") or "").strip()
    if mfg_match and (bio_db or nonbio_db):
        extracted_mfg = re.findall(r'\d{3}', mfg_match.group(1))
        db_mfg_set = set()
        if bio_db:
            db_mfg_set.add(bio_db)
        if nonbio_db:
            db_mfg_set.add(nonbio_db)
        found = bool(set(extracted_mfg) & db_mfg_set)
        checks.append({
            "field": "MFG License Number",
            "extracted": ", ".join(extracted_mfg),
            "registered": ", ".join(sorted(db_mfg_set)),
            "match": found,
            "weight": 15,
        })

    total_weight = sum(c["weight"] for c in checks)
    matched_weight = sum(c["weight"] for c in checks if c["match"])

    if total_weight == 0:
        score = 0
        verdict = "unverifiable"
        verdict_label = "Cannot Verify"
        verdict_description = "Not enough information extracted from the image to verify."
    else:
        score = round((matched_weight / total_weight) * 100)
        if score >= 80:
            verdict = "likely_genuine"
            verdict_label = "Likely Genuine"
            verdict_description = "Most extracted fields match the official DGDA registration record."
        elif score >= 50:
            verdict = "suspicious"
            verdict_label = "Suspicious"
            verdict_description = "Some fields do not match the registered record. Verify manually."
        else:
            verdict = "likely_counterfeit"
            verdict_label = "Likely Counterfeit"
            verdict_description = "Significant mismatches with the official registration record."

    return {
        "verification_score": score,
        "verdict": verdict,
        "verdict_label": verdict_label,
        "verdict_description": verdict_description,
        "checks": checks,
        "matched_fields": sum(1 for c in checks if c["match"]),
        "total_fields": len(checks),
    }


def _find_in_text(ocr_lower: str, target: str) -> str:
    idx = ocr_lower.find(target)
    if idx >= 0:
        return ocr_lower[idx:idx + len(target)]
    return "(not found)"
