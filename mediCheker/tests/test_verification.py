from lookup import load_sheets, lookup_by_dar
from verification import compute_verification

NAPA_DAR = "186-0479-006"


def napa_record() -> dict:
    med_df, cmp_df = load_sheets()
    return lookup_by_dar(NAPA_DAR, med_df, cmp_df).iloc[0].to_dict()


def test_all_fields_match_is_likely_genuine():
    text = (f"Napa Paracetamol 500 mg Beximco Pharmaceuticals Ltd. "
            f"DAR No. {NAPA_DAR} Mfg. Lic. No. 379")
    result = compute_verification(text, napa_record())

    assert result["verdict"] == "likely_genuine"
    assert result["verification_score"] == 100
    fields = {c["field"] for c in result["checks"]}
    assert fields == {"DAR / MA Number", "Brand / Trade Name", "Manufacturer",
                      "Generic Name", "MFG License Number"}
    assert result["matched_fields"] == result["total_fields"] == 5


def test_manufacturer_is_checked():
    # Regression: the manufacturer check used to be skipped because the
    # merged record had Company_x / Company_y instead of Company.
    result = compute_verification(f"DAR No. {NAPA_DAR}", napa_record())
    assert "Manufacturer" in {c["field"] for c in result["checks"]}


def test_only_dar_matches_is_likely_counterfeit():
    text = f"Fakeol Acme Labs DAR No. {NAPA_DAR}"
    result = compute_verification(text, napa_record())

    # DAR (30) matched out of DAR + brand + manufacturer + generic (85).
    assert result["verification_score"] == round(30 / 85 * 100)
    assert result["verdict"] == "likely_counterfeit"


def test_partial_match_is_suspicious():
    text = f"Napa Acme Labs DAR No. {NAPA_DAR}"
    result = compute_verification(text, napa_record())

    # DAR (30) + brand (20) matched out of 85.
    assert result["verification_score"] == round(50 / 85 * 100)
    assert result["verdict"] == "suspicious"


def test_wrong_mfg_licence_does_not_match():
    text = (f"Napa Paracetamol Beximco Pharmaceuticals Ltd. "
            f"DAR No. {NAPA_DAR} Mfg. Lic. No. 999")
    result = compute_verification(text, napa_record())
    mfg = next(c for c in result["checks"] if c["field"] == "MFG License Number")
    assert mfg["match"] is False
    assert result["verdict"] == "likely_genuine"  # 85 / 100


def test_empty_record_cannot_be_verified():
    result = compute_verification("anything", {})
    assert result["verdict"] == "unverifiable"
    assert result["verification_score"] == 0
    assert result["checks"] == []
