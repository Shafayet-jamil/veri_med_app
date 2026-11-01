import pytest

from interactions import (
    check_interactions,
    extract_base_name,
    load_interactions,
    load_medicine_names,
)


@pytest.fixture(scope="module")
def interactions_df():
    return load_interactions()


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
