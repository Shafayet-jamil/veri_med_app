import pytest

import import_ddinter
from interactions import (
    check_interactions,
    data_sources,
    extract_base_name,
    load_interactions,
    load_medicine_names,
)


@pytest.fixture(scope="module")
def interactions_df():
    # Curated list only, whether or not DDInter was downloaded locally.
    return load_interactions(ddinter_path=None)


@pytest.fixture
def ddinter_df(tmp_path):
    """Curated list plus a tiny DDInter-format file."""
    path = tmp_path / "ddinter_interactions.csv"
    path.write_text(
        "drug_a,drug_b,level\n"
        "Clopidogrel,Esomeprazole,Major\n"
        "Acetaminophen,Warfarin,Moderate\n"      # also in the curated list
        "Ciprofloxacin,Calcium carbonate,Moderate\n"
        "Acetylsalicylic acid,Ketorolac,Minor\n"
        "Gliclazide,Metformin,\n"                 # severity not given
    )
    return load_interactions(ddinter_path=str(path))


def test_known_pair_is_found(interactions_df):
    result = check_interactions(["Warfarin", "Aspirin"], interactions_df)
    assert len(result) == 1
    assert result[0]["severity"] == "severe"
    assert result[0]["drug_a"] == "Warfarin"
    assert result[0]["drug_b"] == "Aspirin"


def test_order_does_not_matter(interactions_df):
    result = check_interactions(["Aspirin", "Warfarin"], interactions_df)
    assert len(result) == 1


def test_salt_names_and_strengths_still_match(interactions_df):
    result = check_interactions(
        ["Amlodipine Besilate 5 mg", "Simvastatin 20 mg"], interactions_df
    )
    assert len(result) == 1
    assert "muscle" in result[0]["effect"].lower()


def test_combination_product_matches_its_ingredient(interactions_df):
    # "Caffeine + Paracetamol" contains paracetamol as a whole word.
    result = check_interactions(["Warfarin", "Caffeine + Paracetamol"], interactions_df)
    assert any(r["drug_b"] == "Caffeine + Paracetamol" for r in result)


def test_partial_word_is_not_a_match(interactions_df):
    # Regression: "omeprazole" used to match inside "esomeprazole".
    result = check_interactions(["Warfarin", "Esomeprazole"], interactions_df)
    assert result == []


def test_unknown_pair_returns_nothing(interactions_df):
    assert check_interactions(["Paracetamol", "Vitamin C"], interactions_df) == []


def test_same_drug_twice_is_ignored(interactions_df):
    assert check_interactions(["Warfarin", "Warfarin"], interactions_df) == []


def test_three_drugs_report_every_interacting_pair(interactions_df):
    result = check_interactions(["Warfarin", "Aspirin", "Ibuprofen"], interactions_df)
    pairs = {(r["drug_a"], r["drug_b"]) for r in result}
    assert ("Warfarin", "Aspirin") in pairs
    assert ("Warfarin", "Ibuprofen") in pairs


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("Paracetamol 500 mg", "Paracetamol"),
        ("Amoxicillin 250 mg/5 ml", "Amoxicillin"),
        ("Insulin Glargine 100 IU/ml", "Insulin Glargine"),
        ("500 mg", "500 mg"),  # nothing left after stripping: keep original
    ],
)
def test_extract_base_name(raw, expected):
    assert extract_base_name(raw) == expected


def test_medicine_names_are_unique_and_cached():
    names = load_medicine_names()
    keys = [(n["trade_name"].lower(), n["generic_name"].lower()) for n in names]
    assert len(keys) == len(set(keys))
    assert all(n["trade_name"] for n in names)
    assert {"trade_name": "Napa", "generic_name": "Paracetamol",
            "generic_name_with_strength": "Paracetamol 500 mg"} in names

    # Callers get their own copies, so changing one can't corrupt the cache.
    names[0]["trade_name"] = "changed"
    assert load_medicine_names()[0]["trade_name"] != "changed"


# ── DDInter data ─────────────────────────────────────────────────────────────

def test_curated_only_sources(interactions_df):
    assert [s["name"] for s in data_sources(interactions_df)] == ["MediChecker curated list"]


def test_ddinter_pairs_are_found_with_severity_and_source(ddinter_df):
    result = check_interactions(["Esomeprazole Magnesium Trihydrate", "Clopidogrel"],
                                ddinter_df)
    assert len(result) == 1
    assert result[0]["severity"] == "severe"
    assert result[0]["source"] == "DDInter"
    assert "pharmacist" in result[0]["recommendation"] or "doctor" in result[0]["recommendation"]
    assert {s["name"] for s in data_sources(ddinter_df)} == {"MediChecker curated list", "DDInter"}


def test_british_names_match_us_names_in_ddinter(ddinter_df):
    # Labels say Aspirin / Paracetamol; DDInter says Acetylsalicylic acid /
    # Acetaminophen.
    result = check_interactions(["Aspirin", "Ketorolac"], ddinter_df)
    assert any(r["source"] == "DDInter" and r["severity"] == "mild" for r in result)


def test_us_name_on_label_matches_british_key(ddinter_df):
    result = check_interactions(["Acetaminophen", "Warfarin"], ddinter_df)
    assert len(result) == 1


def test_curated_entry_wins_over_ddinter_duplicate(ddinter_df):
    # Paracetamol + Warfarin is in both sources (as Acetaminophen in DDInter):
    # report it once, with the curated explanation.
    result = check_interactions(["Paracetamol 500 mg", "Warfarin Sodium"], ddinter_df)
    assert len(result) == 1
    assert result[0]["source"] == "MediChecker curated list"


def test_salt_and_combination_names_match_ddinter(ddinter_df):
    result = check_interactions(["Ciprofloxacin", "Calcium Carbonate + Vitamin D3"],
                                ddinter_df)
    assert [r["source"] for r in result] == ["DDInter"]


def test_missing_ddinter_severity_is_unknown(ddinter_df):
    result = check_interactions(["Metformin Hydrochloride", "Gliclazide"], ddinter_df)
    assert result[0]["severity"] == "unknown"


def test_results_are_sorted_most_severe_first(ddinter_df):
    result = check_interactions(["Aspirin", "Ketorolac", "Warfarin", "Ibuprofen"], ddinter_df)
    severities = [r["severity"] for r in result]
    order = {"severe": 0, "moderate": 1, "mild": 2, "unknown": 3}
    assert severities == sorted(severities, key=order.get)


def test_import_script_requires_license_acceptance(capsys):
    assert import_ddinter.main([]) == 1
    assert "NonCommercial" in capsys.readouterr().out


def test_import_script_combines_and_dedupes():
    import pandas as pd
    frames = [
        pd.DataFrame({"DDInterID_A": ["1"], "Drug_A": ["Warfarin"],
                      "DDInterID_B": ["2"], "Drug_B": ["Aspirin"], "Level": ["Major"]}),
        pd.DataFrame({"DDInterID_A": ["2", "3"], "Drug_A": ["Aspirin", "Digoxin"],
                      "DDInterID_B": ["1", "4"], "Drug_B": ["Warfarin", "Verapamil"],
                      "Level": ["Major", "Moderate"]}),
    ]
    out = import_ddinter.build(frames)
    assert list(out.columns) == ["drug_a", "drug_b", "level"]
    assert len(out) == 2   # Warfarin/Aspirin listed in both files: kept once
