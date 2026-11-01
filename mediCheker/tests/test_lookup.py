import pytest

from lookup import (
    extract_and_normalize_dar_ma_number,
    load_sheets,
    lookup_by_dar,
    normalize_ma_number,
    run_lookup,
)

# A real record from medicine_information_DAR_MA.csv:
# Napa (Paracetamol 500 mg), Beximco Pharmaceuticals Ltd., MFG Lic 119 / 379.
NAPA_DAR = "186-0479-006"


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("481-003-034", "481-0003-034"),   # 3-digit middle part gets padded
        ("481-0003-034", "481-0003-034"),  # already normalized
        ("ABC", "ABC"),                     # not an MA number: unchanged
    ],
)
def test_normalize_ma_number(raw, expected):
    assert normalize_ma_number(raw) == expected


@pytest.mark.parametrize(
    "text, expected",
    [
        ("DAR No. 186-0479-006", NAPA_DAR),
        ("MA No: 186 479 006", NAPA_DAR),
        ("OAR No 186.0479.006", NAPA_DAR),      # common OCR misread of DAR
        ("printed 186-0479-006 on foil", NAPA_DAR),  # unlabeled fallback
        ("no registration number here", None),
    ],
)
def test_extract_dar_number(text, expected):
    assert extract_and_normalize_dar_ma_number(text) == expected


def test_load_sheets_is_cached():
    first = load_sheets()
    second = load_sheets()
    assert first[0] is second[0]
    assert first[1] is second[1]


def test_lookup_by_dar_returns_medicine_and_company_details():
    med_df, cmp_df = load_sheets()
    row = lookup_by_dar(NAPA_DAR, med_df, cmp_df).iloc[0].to_dict()

    assert row["Trade Name"] == "Napa"
    # The merge must not split "Company" into Company_x / Company_y.
    assert row["Company"] == "Beximco Pharmaceuticals Ltd."
    assert "Company_x" not in row and "Company_y" not in row
    assert {row["Bio_3"], row["NonBio_3"]} == {"119", "379"}


def test_lookup_by_dar_unknown_number_is_empty():
    med_df, cmp_df = load_sheets()
    assert lookup_by_dar("000-0000-000", med_df, cmp_df).empty


def test_run_lookup_with_dar_and_mfg_licence():
    result = run_lookup(f"Napa DAR No. {NAPA_DAR} Mfg. Lic. No. 379")
    row = result.iloc[0].to_dict()
    assert row["DAR No"] == NAPA_DAR
    assert row["Company"] == "Beximco Pharmaceuticals Ltd."
    assert row["MFG Lic (Non-Biological)"] == "379"


def test_run_lookup_with_dar_only():
    result = run_lookup(f"DAR No. {NAPA_DAR}")
    assert result.iloc[0]["DAR No"] == NAPA_DAR


def test_run_lookup_without_identifiers_is_empty():
    assert run_lookup("just some random label text").empty
