from lookup import load_sheets, lookup_by_dar, run_lookup
from verification import compute_verification

NAPA_DAR = "186-0479-006"
FULL_LABEL = (f"Napa Paracetamol 500 mg Beximco Pharmaceuticals Ltd. "
              f"DAR No. {NAPA_DAR} Mfg. Lic. No. 379")


def napa_record() -> dict:
    med_df, cmp_df = load_sheets()
    return lookup_by_dar(NAPA_DAR, med_df, cmp_df).iloc[0].to_dict()


def statuses(result) -> dict:
    return {c["field"]: c["status"] for c in result["checks"]}


def test_full_label_matches_record():
    result = compute_verification(FULL_LABEL, napa_record())

    assert result["verdict"] == "likely_genuine"
    assert result["verdict_label"] == "Matches DGDA Record"
    assert result["verification_score"] == 100
    assert set(statuses(result).values()) == {"match"}
    assert result["matched_fields"] == result["read_fields"] == 5


def test_manufacturer_is_checked():
    # Regression: the manufacturer check used to be skipped because the
    # merged record had Company_x / Company_y instead of Company.
    result = compute_verification(FULL_LABEL, napa_record())
    assert statuses(result)["Manufacturer"] == "match"


def test_details_missing_from_photo_do_not_count_against_it():
    # Only the DAR number is readable (like a cropped or blurry photo).
    # This used to score 35% and say "Likely Counterfeit".
    result = compute_verification(f"DAR No. {NAPA_DAR}", napa_record())

    assert result["verdict"] == "partial_match"
    assert result["verification_score"] == 100
    assert result["read_fields"] == 1
    assert statuses(result)["Brand / Trade Name"] == "not_visible"
    assert "counterfeit" not in result["verdict_label"].lower()
    assert "photograph" in result["verdict_description"].lower()


def test_two_matching_details_without_conflicts_is_a_match():
    result = compute_verification(f"Napa DAR No. {NAPA_DAR}", napa_record())
    assert result["verdict"] == "likely_genuine"
    assert result["matched_fields"] == 2


def test_wrong_mfg_licence_is_flagged():
    text = FULL_LABEL.replace("Lic. No. 379", "Lic. No. 999")
    result = compute_verification(text, napa_record())

    assert statuses(result)["MFG License Number"] == "mismatch"
    assert result["verdict"] == "suspicious"   # 85 of 100 points still match
    assert "MFG License Number" in result["verdict_description"]
    assert "pharmacist" in result["verdict_description"]


def test_mostly_conflicting_details_do_not_match():
    record = napa_record()
    text = "Napa DAR No. 999-9999-999 Mfg. Lic. No. 999"
    result = compute_verification(text, record)

    assert statuses(result)["DAR / MA Number"] == "mismatch"
    assert statuses(result)["MFG License Number"] == "mismatch"
    # brand (20) matched out of DAR + brand + MFG (65) read
    assert result["verification_score"] == round(20 / 65 * 100)
    assert result["verdict"] == "likely_counterfeit"


def test_nothing_readable_cannot_be_verified():
    result = compute_verification("blurry text", napa_record())
    assert result["verdict"] == "unverifiable"
    assert result["read_fields"] == 0
    assert result["verification_score"] == 0


def test_manufacturer_only_record():
    # Only the MFG licence number was read: the record describes the
    # company, so the medicine itself must not be reported as checked.
    record = run_lookup("Mfg. Lic. No. 379 tablets").iloc[0].to_dict()
    assert not record.get("DAR No")
    result = compute_verification("Mfg. Lic. No. 379 tablets", record)

    assert result["verdict"] == "manufacturer_only"
    assert "Beximco" in result["verdict_description"]


def test_empty_record_cannot_be_verified():
    result = compute_verification("anything", {})
    assert result["verdict"] == "unverifiable"
    assert result["checks"] == []
