"""Compare the text read from a medicine package with its DGDA record.

Every check ends in one of three states:

- ``match``        the detail was read and agrees with the record
- ``mismatch``     the detail was read and contradicts the record
- ``not_visible``  the detail could not be found in the OCR text

Only details that were actually read count towards the score. A detail that
is missing from a photo (cropped, blurry, on the other side of the pack) is
not evidence that the medicine is fake, so it never lowers the score.
"""
import re

from lookup import extract_and_normalize_dar_ma_number

MATCH = "match"
MISMATCH = "mismatch"
NOT_VISIBLE = "not_visible"

_MFG_PATTERN = re.compile(
    r'(?:mfg|mig)[\s.:]*lic[\s.:]*no[^\d]*((?:\d{3})(?:\s*&\s*\d{3})*)',
    re.IGNORECASE,
)
_STRENGTH = re.compile(r'\d+(\.\d+)?\s*(mg|gm|ml|mcg|iu).*', re.IGNORECASE)

PHOTO_TIP = ("For a fuller check, photograph the side of the pack that shows "
             "the brand name, the DAR / MA number and the MFG licence number, "
             "in good light.")


def _get(row: dict, *keys: str) -> str:
    for key in keys:
        value = row.get(key)
        if value is not None and str(value).strip() and str(value).lower() != "nan":
            return str(value).strip()
    return ""


def _check(field, status, extracted, registered, weight):
    return {
        "field": field,
        "status": status,
        "match": status == MATCH,
        "extracted": extracted if status != NOT_VISIBLE else "(not visible)",
        "registered": registered,
        "weight": weight,
    }


def _find_in_text(ocr_lower: str, target: str) -> str:
    idx = ocr_lower.find(target)
    return ocr_lower[idx:idx + len(target)] if idx >= 0 else ""


def compute_verification(extracted_text: str, db_row: dict) -> dict:
    checks = []
    ocr_lower = extracted_text.lower()

    # DAR / MA number: identifies the exact medicine.
    dar_db = _get(db_row, "DAR No", "dar_number")
    if dar_db:
        dar_read = extract_and_normalize_dar_ma_number(extracted_text)
        if not dar_read:
            status = NOT_VISIBLE
        else:
            status = MATCH if dar_read == dar_db else MISMATCH
        checks.append(_check("DAR / MA Number", status, dar_read or "", dar_db, 30))

    # Brand, manufacturer and generic name: we can only tell whether the
    # registered text appears on the pack, so these are match / not visible.
    trade_db = _get(db_row, "Trade Name", "brand_name")
    if trade_db:
        found = _find_in_text(ocr_lower, trade_db.lower())
        checks.append(_check("Brand / Trade Name", MATCH if found else NOT_VISIBLE,
                             found, trade_db, 20))

    company_db = _get(db_row, "Company", "manufacturer")
    if company_db:
        words = [w for w in company_db.lower().split() if len(w) > 2]
        matched_words = [w for w in words if w in ocr_lower]
        found = len(matched_words) >= max(1, len(words) // 2)
        checks.append(_check("Manufacturer", MATCH if found else NOT_VISIBLE,
                             " ".join(matched_words), company_db, 20))

    generic_db = _get(db_row, "Generic Name With Strength", "generic_name")
    base_generic = _STRENGTH.sub('', generic_db).strip().lower()
    if base_generic:
        found = _find_in_text(ocr_lower, base_generic)
        checks.append(_check("Generic Name", MATCH if found else NOT_VISIBLE,
                             found, generic_db, 15))

    # MFG licence number: identifies the manufacturer.
    licences_db = {
        v for v in (
            _get(db_row, "Bio_3", "MFG Lic (Biological)", "mfg_license_biological"),
            _get(db_row, "NonBio_3", "MFG Lic (Non-Biological)", "mfg_license_non_biological"),
        ) if v
    }
    if licences_db:
        mfg_match = _MFG_PATTERN.search(extracted_text)
        licences_read = re.findall(r'\d{3}', mfg_match.group(1)) if mfg_match else []
        if not licences_read:
            status = NOT_VISIBLE
        else:
            status = MATCH if set(licences_read) & licences_db else MISMATCH
        checks.append(_check("MFG License Number", status, ", ".join(licences_read),
                             ", ".join(sorted(licences_db)), 15))

    return _summarize(checks, is_medicine_record=bool(dar_db or trade_db),
                      company=company_db)


def _summarize(checks: list[dict], is_medicine_record: bool, company: str) -> dict:
    read = [c for c in checks if c["status"] != NOT_VISIBLE]
    matched = [c for c in read if c["status"] == MATCH]
    mismatched = [c for c in read if c["status"] == MISMATCH]

    read_weight = sum(c["weight"] for c in read)
    score = round(sum(c["weight"] for c in matched) / read_weight * 100) if read_weight else 0

    def names(items):
        labels = [c["field"] for c in items]
        return labels[0] if len(labels) == 1 else ", ".join(labels[:-1]) + " and " + labels[-1]

    if not read:
        verdict, label = "unverifiable", "Cannot Verify"
        description = ("A registration record was found, but none of its details "
                       "could be read clearly on the package. " + PHOTO_TIP)
    elif mismatched:
        if score >= 50:
            verdict, label = "suspicious", "Some Details Differ"
        else:
            verdict, label = "likely_counterfeit", "Details Do Not Match"
        description = (f"The {names(mismatched)} on the package "
                       f"{'does' if len(mismatched) == 1 else 'do'} not match the "
                       f"official DGDA record. Check the medicine with a pharmacist "
                       f"before using it.")
    elif not is_medicine_record:
        verdict, label = "manufacturer_only", "Manufacturer Identified"
        description = (f"The package matches the registered manufacturer "
                       f"{company}, but its DAR / MA number could not be read, so "
                       f"the medicine itself was not checked. " + PHOTO_TIP)
    elif len(matched) >= 2:
        verdict, label = "likely_genuine", "Matches DGDA Record"
        description = (f"{len(matched)} details read from the package match the "
                       f"official DGDA registration: {names(matched)}. "
                       f"No conflicting details were found.")
    else:
        verdict, label = "partial_match", "Registered, Partly Checked"
        description = (f"The {names(matched)} matches a registered medicine and "
                       f"nothing on the package contradicts it, but the other "
                       f"details could not be read. " + PHOTO_TIP)

    return {
        "verification_score": score,
        "verdict": verdict,
        "verdict_label": label,
        "verdict_description": description,
        "checks": checks,
        "matched_fields": len(matched),
        "mismatched_fields": len(mismatched),
        "read_fields": len(read),
        "total_fields": len(checks),
    }
