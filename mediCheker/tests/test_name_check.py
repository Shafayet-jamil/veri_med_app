"""Brand-name spelling check against the DGDA register (real CSV data)."""
import pytest

from name_check import (EXACT, MISSPELLED, NOT_FOUND, UNREADABLE,
                        get_brand_index)


@pytest.fixture(scope="module")
def index():
    return get_brand_index()


def dar_of(index, result):
    return index.med_df.at[result.row_index, "DAR No"]


def test_correct_spelling_identifies_the_product(index):
    result = index.check("Napa Paracetamol 500 mg Beximco Pharmaceuticals Ltd. Tablet")
    assert result.status == EXACT
    assert result.registered_name == "Napa"
    # Plain "Napa" 500 mg tablet, not "Napa Rapid" or "Napa Extend".
    assert dar_of(index, result) == "186-0479-006"


def test_full_trade_name_is_preferred(index):
    result = index.check("Napa Extend Paracetamol 665 mg Beximco")
    assert result.registered_name == "Napa Extend"


def test_ocr_digit_for_letter_is_forgiven(index):
    result = index.check("Bi1tin Bilastine 20 mg Tablet")
    assert result.status == EXACT
    assert result.registered_name == "Biltin"


@pytest.mark.parametrize("text, registered", [
    ("Nappa Paracetamol 500 mg Beximco Pharmaceuticals Ltd. Tablet", "Napa"),
    ("Furoclov 500 Cefuroxime Clavulanic Acid Renata PLC", "Furoclav 500"),
])
def test_misspelled_brand_is_flagged(index, text, registered):
    result = index.check(text)
    assert result.status == MISSPELLED
    assert result.registered_name == registered
    assert result.read_name != registered.lower()


def test_unregistered_name_is_not_found(index):
    result = index.check("Zorbatex 500 Paracetamol tablet made by Healwell "
                         "Pharma Ltd keep away from children")
    assert result.status == NOT_FOUND
    assert result.row_index is None


def test_generic_name_alone_does_not_identify_a_brand(index):
    # "Paracetamol" is also some company's trade name; without that
    # company on the pack it must not count as a match.
    result = index.check("Each film coated tablet contains Paracetamol BP "
                         "500 mg Store in a cool dry place")
    assert result.status == NOT_FOUND


def test_too_little_text_is_unreadable(index):
    assert index.check("blurry nothing useful").status == UNREADABLE


def test_expected_brand_spelling(index):
    assert index.check("Napa 500 mg", expected_brand="Napa").status == EXACT
    assert index.check("Nappa 500 mg", expected_brand="Napa").status == MISSPELLED
    assert index.check("Antibiotic", expected_brand="Furoclav 500").status == NOT_FOUND


def test_lookup_typed_name(index):
    assert index.lookup_name("napa").registered_name == "Napa"
    assert index.lookup_name("Napa Extend").registered_name == "Napa Extend"
    typo = index.lookup_name("Nappa")
    assert typo.status == NOT_FOUND
    assert "Napa" in typo.suggestions
