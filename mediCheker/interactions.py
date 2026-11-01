import pandas as pd
import re
import os

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
INTERACTIONS_CSV = os.path.join(BACKEND_DIR, "excelFile", "drug_interactions.csv")
MEDICINE_CSV = os.path.join(BACKEND_DIR, "excelFile", "medicine_information_DAR_MA.csv")


def load_interactions() -> pd.DataFrame:
    df = pd.read_csv(INTERACTIONS_CSV, dtype=str).fillna("")
    df["drug_a_key"] = df["drug_a"].str.lower().str.strip()
    df["drug_b_key"] = df["drug_b"].str.lower().str.strip()
    return df


def load_medicine_names() -> list[dict]:
    med_df = pd.read_csv(MEDICINE_CSV, dtype=str).fillna("")
    seen = set()
    results = []
    for _, row in med_df.iterrows():
        trade = row.get("Trade Name", "").strip()
        generic_full = row.get("Generic Name With Strength", "").strip()
        generic_base = extract_base_name(generic_full)
        key = f"{trade.lower()}|{generic_base.lower()}"
        if key not in seen and trade:
            seen.add(key)
            results.append({
                "trade_name": trade,
                "generic_name": generic_base,
                "generic_name_with_strength": generic_full,
            })
    return results


def extract_base_name(generic_with_strength: str) -> str:
    cleaned = re.sub(r'\d+(\.\d+)?\s*(mg|gm|ml|mcg|iu|mm|kg|liter|%)\b.*',
                     '', generic_with_strength, flags=re.IGNORECASE).strip()
    if not cleaned:
        return generic_with_strength.strip()
    return cleaned


def check_interactions(drug_names: list[str],
                       interactions_df: pd.DataFrame) -> list[dict]:
    base_names = []
    for name in drug_names:
        base = extract_base_name(name).lower().strip()
        base_names.append(base)

    found = []
    checked_pairs = set()

    for i in range(len(base_names)):
        for j in range(i + 1, len(base_names)):
            a, b = base_names[i], base_names[j]
            pair_key = tuple(sorted([a, b]))
            if pair_key in checked_pairs:
                continue
            checked_pairs.add(pair_key)

            matches = interactions_df[
                ((interactions_df["drug_a_key"] == a) & (interactions_df["drug_b_key"] == b)) |
                ((interactions_df["drug_a_key"] == b) & (interactions_df["drug_b_key"] == a))
            ]

            if matches.empty:
                for idx, row in interactions_df.iterrows():
                    da = row["drug_a_key"]
                    db = row["drug_b_key"]
                    if (a in da or da in a) and (b in db or db in b):
                        matches = interactions_df.loc[[idx]]
                        break
                    if (a in db or db in a) and (b in da or da in b):
                        matches = interactions_df.loc[[idx]]
                        break

            for _, match in matches.iterrows():
                found.append({
                    "drug_a": drug_names[i],
                    "drug_b": drug_names[j],
                    "severity": match["severity"],
                    "effect": match["effect"],
                    "recommendation": match.get("recommendation", ""),
                })

    return found
