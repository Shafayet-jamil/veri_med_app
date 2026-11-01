"""Drug-drug interaction checks.

Two data sources are used:

1. ``excelFile/drug_interactions.csv``: a small hand-written list with an
   effect and a recommendation for each pair. Always loaded.
2. ``excelFile/ddinter_interactions.csv``: optional, created by
   ``import_ddinter.py`` from the DDInter database (~160,000 pairs, severity
   only). DDInter is licensed CC BY-NC-SA 4.0 (non-commercial use only), so
   the file is not committed to the repository; each user downloads it.

When both sources list the same pair, the hand-written entry wins because
it carries an explanation.
"""
import os
import re
import weakref
from collections import defaultdict
from functools import lru_cache

import pandas as pd

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
INTERACTIONS_CSV = os.path.join(BACKEND_DIR, "excelFile", "drug_interactions.csv")
DDINTER_CSV = os.path.join(BACKEND_DIR, "excelFile", "ddinter_interactions.csv")
MEDICINE_CSV = os.path.join(BACKEND_DIR, "excelFile", "medicine_information_DAR_MA.csv")

CURATED_SOURCE = {"name": "MediChecker curated list", "license": "", "url": ""}
DDINTER_SOURCE = {
    "name": "DDInter",
    "license": "CC BY-NC-SA 4.0 (non-commercial use only)",
    "url": "https://ddinter.scbdd.com/",
}

_STRENGTH_PATTERN = re.compile(
    r'\d+(\.\d+)?\s*(mg|gm|ml|mcg|iu|mm|kg|liter|%)\b.*', re.IGNORECASE
)

# Bangladesh labels use British / INN names; DDInter uses US names for some
# drugs. Each key found in a medicine name also searches for its alias.
NAME_ALIASES = {
    "paracetamol": "acetaminophen",
    "aspirin": "acetylsalicylic acid",
    "glibenclamide": "glyburide",
    "frusemide": "furosemide",
    "adrenaline": "epinephrine",
    "noradrenaline": "norepinephrine",
    "lignocaine": "lidocaine",
    "pethidine": "meperidine",
    "ciclosporin": "cyclosporine",
    "colecalciferol": "cholecalciferol",
    "sodium valproate": "valproic acid",
    "valproate": "valproic acid",
    "amoxycillin": "amoxicillin",
    "cefalexin": "cephalexin",
    "sulphamethoxazole": "sulfamethoxazole",
    "dicycloverine": "dicyclomine",
    "chlorphenamine": "chlorpheniramine",
    "phenobarbitone": "phenobarbital",
    "oestradiol": "estradiol",
    "glyceryl trinitrate": "nitroglycerin",
    "thiamazole": "methimazole",
}

# US name -> British name, so both sources use one key per drug.
_CANONICAL = {us: brit for brit, us in NAME_ALIASES.items()}


def _canonical(key: str) -> str:
    return _CANONICAL.get(key, key)


# DDInter gives a severity level only; these are shown in its place.
_DDINTER_LEVELS = {
    "major": ("severe", "Avoid this combination unless a doctor has approved it."),
    "moderate": ("moderate", "Use together only on a doctor's or pharmacist's advice; "
                             "monitoring may be needed."),
    "minor": ("mild", "Usually minor. Mention it to your pharmacist."),
    "unknown": ("unknown", "The severity is not documented. Ask a pharmacist."),
}


def _word_pattern(name: str) -> re.Pattern:
    return re.compile(rf'(?<![a-z0-9]){re.escape(name)}(?![a-z0-9])')


def _mentions(name: str, drug_key: str) -> bool:
    """True when ``drug_key`` appears in ``name`` as whole word(s).

    "amlodipine" matches "amlodipine besilate", but "omeprazole" does not
    match "esomeprazole" and "iron" does not match "chironomid".
    """
    if not name or not drug_key:
        return False
    return _word_pattern(drug_key).search(name) is not None


def _load_curated() -> pd.DataFrame:
    df = pd.read_csv(INTERACTIONS_CSV, dtype=str).fillna("")
    df["source"] = CURATED_SOURCE["name"]
    return df[["drug_a", "drug_b", "severity", "effect", "recommendation", "source"]]


def _load_ddinter(path: str) -> pd.DataFrame:
    raw = pd.read_csv(path, dtype=str).fillna("")
    level = raw["level"].str.strip().str.lower()
    mapped = level.map(lambda l: _DDINTER_LEVELS.get(l, _DDINTER_LEVELS["unknown"]))
    return pd.DataFrame({
        "drug_a": raw["drug_a"],
        "drug_b": raw["drug_b"],
        "severity": mapped.str[0],
        "effect": "DDInter lists an interaction between these drugs (severity: "
                  + raw["level"].str.strip().replace("", "Unknown") + ").",
        "recommendation": mapped.str[1],
        "source": DDINTER_SOURCE["name"],
    })


def load_interactions(ddinter_path: str | None = DDINTER_CSV) -> pd.DataFrame:
    frames = [_load_curated()]
    if ddinter_path and os.path.exists(ddinter_path):
        frames.append(_load_ddinter(ddinter_path))
    df = pd.concat(frames, ignore_index=True)

    df["drug_a_key"] = df["drug_a"].str.lower().str.strip().map(_canonical)
    df["drug_b_key"] = df["drug_b"].str.lower().str.strip().map(_canonical)
    df = df[(df["drug_a_key"] != "") & (df["drug_b_key"] != "")
            & (df["drug_a_key"] != df["drug_b_key"])]

    # One row per unordered pair; the curated row comes first, so it wins.
    a, b = df["drug_a_key"], df["drug_b_key"]
    pair = a.where(a < b, b) + "|" + b.where(a < b, a)
    return df[~pair.duplicated()].reset_index(drop=True)


def data_sources(interactions_df: pd.DataFrame) -> list[dict]:
    """Where the loaded interaction data came from (for attribution)."""
    used = set(interactions_df["source"]) if len(interactions_df) else set()
    return [s for s in (CURATED_SOURCE, DDINTER_SOURCE) if s["name"] in used]


class _Index:
    """Pair lookup plus the list of known drug names, built once per table."""

    def __init__(self, df: pd.DataFrame):
        self.rows = df[["drug_a", "drug_b", "severity", "effect",
                        "recommendation", "source"]].to_dict("records")
        self.by_pair = defaultdict(list)
        for pos, (a, b) in enumerate(zip(df["drug_a_key"], df["drug_b_key"])):
            self.by_pair[frozenset((a, b))].append(pos)
        keys = set(df["drug_a_key"]) | set(df["drug_b_key"])
        self.patterns = [(k, _word_pattern(k)) for k in sorted(keys)]

    def drugs_in(self, name: str) -> set[str]:
        """Known drug names mentioned in a medicine name (with aliases)."""
        text = name.lower().strip()
        # Keys are British names; also accept a label written with US names.
        extra = [brit for us, brit in _CANONICAL.items() if _mentions(text, us)]
        text = " | ".join([text, *extra])
        return {key for key, pattern in self.patterns if pattern.search(text)}


# Built once per loaded table. Kept outside df.attrs, which pandas deep-copies
# on every row access.
_indexes: dict[int, tuple[weakref.ref, _Index]] = {}


def _index_for(df: pd.DataFrame) -> _Index:
    entry = _indexes.get(id(df))
    if entry is None or entry[0]() is not df:
        entry = (weakref.ref(df), _Index(df))
        _indexes[id(df)] = entry
    return entry[1]


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


def check_interactions(drug_names: list[str],
                       interactions_df: pd.DataFrame) -> list[dict]:
    index = _index_for(interactions_df)
    base_names = [extract_base_name(name).lower().strip() for name in drug_names]
    drugs = [index.drugs_in(name) for name in base_names]

    found = []
    checked_pairs = set()

    for i in range(len(base_names)):
        for j in range(i + 1, len(base_names)):
            pair_key = frozenset((base_names[i], base_names[j]))
            if len(pair_key) < 2 or pair_key in checked_pairs:
                continue
            checked_pairs.add(pair_key)

            rows = set()
            for a in drugs[i]:
                for b in drugs[j]:
                    if a != b:
                        rows.update(index.by_pair.get(frozenset((a, b)), ()))

            for pos in sorted(rows):
                row = index.rows[pos]
                found.append({
                    "drug_a": drug_names[i],
                    "drug_b": drug_names[j],
                    "severity": row["severity"],
                    "effect": row["effect"],
                    "recommendation": row["recommendation"],
                    "source": row["source"],
                    "interacting_drugs": [row["drug_a"], row["drug_b"]],
                })

    order = {"severe": 0, "moderate": 1, "mild": 2, "unknown": 3}
    found.sort(key=lambda r: order.get(r["severity"].lower(), 4))
    return found
