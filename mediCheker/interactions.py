import os
import re
from functools import lru_cache

import pandas as pd

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
INTERACTIONS_CSV = os.path.join(BACKEND_DIR, "excelFile", "drug_interactions.csv")
MEDICINE_CSV = os.path.join(BACKEND_DIR, "excelFile", "medicine_information_DAR_MA.csv")

_STRENGTH_PATTERN = re.compile(
    r'\d+(\.\d+)?\s*(mg|gm|ml|mcg|iu|mm|kg|liter|%)\b.*', re.IGNORECASE
)


def load_interactions() -> pd.DataFrame:
    df = pd.read_csv(INTERACTIONS_CSV, dtype=str).fillna("")
    df["drug_a_key"] = df["drug_a"].str.lower().str.strip()
    df["drug_b_key"] = df["drug_b"].str.lower().str.strip()
    return df


@lru_cache(maxsize=1)
def _medicine_names_cached() -> tuple[dict, ...]:
    med_df = pd.read_csv(
        MEDICINE_CSV, dtype=str,
        usecols=["Trade Name", "Generic Name With Strength"],
    ).fillna("")
    trade = med_df["Trade Name"].str.strip()
    generic_full = med_df["Generic Name With Strength"].str.strip()
    generic_base = generic_full.map(extract_base_name)

    names = pd.DataFrame({
        "trade_name": trade,
        "generic_name": generic_base,
        "generic_name_with_strength": generic_full,
    })
    names = names[names["trade_name"] != ""]
    dedupe_key = names["trade_name"].str.lower() + "|" + names["generic_name"].str.lower()
    names = names[~dedupe_key.duplicated()]
    return tuple(names.to_dict("records"))


def load_medicine_names() -> list[dict]:
    """Unique (trade name, generic name) pairs. The CSV is read only once."""
    return [dict(row) for row in _medicine_names_cached()]


def extract_base_name(generic_with_strength: str) -> str:
    cleaned = _STRENGTH_PATTERN.sub('', generic_with_strength).strip()
    if not cleaned:
        return generic_with_strength.strip()
    return cleaned


def _mentions(name: str, drug_key: str) -> bool:
    """True when ``drug_key`` appears in ``name`` as whole word(s).

    "amlodipine" matches "amlodipine besilate", but "omeprazole" does not
    match "esomeprazole" and "iron" does not match "chironomid".
    """
    if not name or not drug_key:
        return False
    return re.search(rf'(?<![a-z0-9]){re.escape(drug_key)}(?![a-z0-9])', name) is not None


def check_interactions(drug_names: list[str],
                       interactions_df: pd.DataFrame) -> list[dict]:
    base_names = [extract_base_name(name).lower().strip() for name in drug_names]

    found = []
    checked_pairs = set()

    for i in range(len(base_names)):
        for j in range(i + 1, len(base_names)):
            a, b = base_names[i], base_names[j]
            pair_key = tuple(sorted([a, b]))
            if a == b or pair_key in checked_pairs:
                continue
            checked_pairs.add(pair_key)

            seen_rows = set()
            for idx, row in interactions_df.iterrows():
                da, db = row["drug_a_key"], row["drug_b_key"]
                forward = _mentions(a, da) and _mentions(b, db)
                backward = _mentions(a, db) and _mentions(b, da)
                if not (forward or backward) or idx in seen_rows:
                    continue
                seen_rows.add(idx)
                found.append({
                    "drug_a": drug_names[i],
                    "drug_b": drug_names[j],
                    "severity": row["severity"],
                    "effect": row["effect"],
                    "recommendation": row.get("recommendation", ""),
                })

    return found
