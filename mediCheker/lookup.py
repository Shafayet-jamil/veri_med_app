import pandas as pd
import re
import os
from functools import lru_cache

# ── File paths ──────────────────────────────────────────────────────────────
BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
MEDICINE_CSV = os.path.join(BACKEND_DIR, "excelFile", "medicine_information_DAR_MA.csv")
COMPANY_CSV = os.path.join(BACKEND_DIR, "excelFile", "Company Info functionalOrNonFunctional.csv")


# ── Helpers ──────────────────────────────────────────────────────────────────
def extract_3digit(value: str) -> str:

    if pd.isna(value):
        return ""
    match = re.search(r"\b(\d{3})\b", str(value).strip())
    return match.group(1) if match else str(value).strip()

def normalize_ma_number(ma_number: str) -> str:

    tablet_pattern = re.compile(r'^(\d+)-(\d{3})-(\d+)$')
    match = tablet_pattern.match(ma_number.strip())
    if match:
        prefix, middle, suffix = match.groups()
        return f"{prefix}-0{middle}-{suffix}"


    return ma_number

def extract_and_normalize_dar_ma_number(text: str) -> str | None:

    # Try explicit DAR/MA label first (most reliable)
    labeled = re.search(
        r'(?:DAR|MA|D[A4]R|OAR)[\s.:\-]*(?:No\.?[\s.:\-]*)?'
        r'(\d{2,4}[\s.:\-]+\d{2,5}[\s.:\-]+\d{2,5})',
        text, re.IGNORECASE
    )
    if labeled:
        raw = labeled.group(1)
        standardized = re.sub(r'[\s.:]', '-', raw).strip('-')
        return normalize_ma_number(standardized)

    # Fallback: any 3-part numeric pattern like 481-0003-034
    unlabeled = re.search(r'(\d{2,4})[\s.:\-]+(\d{2,5})[\s.:\-]+(\d{2,5})', text)
    if unlabeled:
        parts = f"{unlabeled.group(1)}-{unlabeled.group(2)}-{unlabeled.group(3)}"
        return normalize_ma_number(parts)

    return None


@lru_cache(maxsize=1)
def load_sheets() -> tuple[pd.DataFrame, pd.DataFrame]:
    """Load the medicine and company sheets.

    The result is cached, so the CSV files are read only once per process.
    Callers must treat the returned DataFrames as read-only.
    """
    med_df = pd.read_csv(MEDICINE_CSV, dtype=str).fillna("")
    cmp_df = pd.read_csv(COMPANY_CSV,  dtype=str).fillna("")


    med_df.columns = med_df.columns.str.strip()
    cmp_df.columns = cmp_df.columns.str.strip()


    cmp_df["Bio_3"]    = cmp_df["License No (Biological)"].apply(extract_3digit)
    cmp_df["NonBio_3"] = cmp_df["License No (Non Biological)"].apply(extract_3digit)

    # Normalize company name for matching (lower + strip)
    med_df["_company_key"] = med_df["Company"].str.lower().str.strip()
    cmp_df["_company_key"] = cmp_df["Company"].str.lower().str.strip()

    return med_df, cmp_df

def find_companies_by_mfg_no(mfg_numbers: list[str],
                             cmp_df: pd.DataFrame) -> pd.DataFrame:

    matching_cmp_rows = cmp_df[
        cmp_df["Bio_3"].isin(mfg_numbers) | cmp_df["NonBio_3"].isin(mfg_numbers)
    ].copy() # Use .copy() to avoid SettingWithCopyWarning
    return matching_cmp_rows


def lookup_by_dar(dar_query: str,
                  med_df: pd.DataFrame,
                  cmp_df: pd.DataFrame) -> pd.DataFrame:

    key = dar_query.strip()
    # Ensure DAR No in med_df is cleaned too for exact comparison
    med_rows = med_df[med_df["DAR No"].str.strip() == key].copy() # copy to avoid SettingWithCopyWarning

    if med_rows.empty:
        return pd.DataFrame()


    merged = med_rows.merge(
        cmp_df[["_company_key", "Address", "Bio_3", "NonBio_3", "Validity", "Status"]].drop_duplicates(subset=["_company_key"]),
        on="_company_key",
        how="left"
    )

    return merged


def prepare_for_display(df: pd.DataFrame) -> pd.DataFrame:
    """Renames columns and drops internal ones for final display."""
    df_copy = df.copy()
    if "Bio_3" in df_copy.columns:
        df_copy = df_copy.rename(columns={"Bio_3": "MFG Lic (Biological)"})
    if "NonBio_3" in df_copy.columns:
        df_copy = df_copy.rename(columns={"NonBio_3": "MFG Lic (Non-Biological)"})
    if "_company_key" in df_copy.columns:
        df_copy = df_copy.drop(columns=["_company_key"])
    return df_copy


def display_result(result: pd.DataFrame, label: str = "Result") -> None:

    if result.empty:
        print(f"── {label}: (no data) ──")
        return

    print(f"\n{'═' * 80}")
    print(f"  {label}")
    print(f"{'═' * 80}")


    medicine_cols = ["SL", "Company", "Trade Name", "Generic Name With Strength",
                     "Dosage Form", "DAR No"]
    licence_cols  = ["Address", "MFG Lic (Biological)", "MFG Lic (Non-Biological)",
                     "Validity", "Status"]


    has_medicine_info_columns = any(col in result.columns for col in ["Trade Name", "Generic Name With Strength", "Dosage Form", "DAR No"])
    available_med_cols = [c for c in medicine_cols if c in result.columns]

    if has_medicine_info_columns and available_med_cols:
        print("\n── Medicine Information ──")
        print(result[available_med_cols].to_string(index=False))
    else:
        print("\n── No Medicine Information Available ──")



    available_lic_cols = [c for c in licence_cols  if c in result.columns]
    if available_lic_cols:
        print("\n── Company / MFG Licence Information ──")

        print(result[available_lic_cols].to_string(index=False))
    else:
        print("\n── No Company / MFG Licence Information Available ──") # Should ideally not happen if result is not empty

    print(f"{'═' * 80}\n")


def run_lookup(ocr_text: str) -> pd.DataFrame:

    med_df, cmp_df = load_sheets()
    query = ocr_text.strip()

    print(f"\n[*] OCR input received: '{query}'")

    extracted_mfg_numbers = []
    mfg_pattern = r'(?:mfg|mig)[\s.:]*lic[\s.:]*no[^\d]*((?:\d{3})(?:\s*&\s*\d{3})*)'
    mfg_match = re.search(mfg_pattern, query, re.IGNORECASE)

    if mfg_match:
        numbers_block = mfg_match.group(1)
        extracted_mfg_numbers = re.findall(r'\d{3}', numbers_block)

    extracted_dar_number = extract_and_normalize_dar_ma_number(query)

    final_result_for_display = pd.DataFrame()
    found_match = False

    if extracted_mfg_numbers and extracted_dar_number:
        print(f"[*] Both MFG Lic No(s) ({', '.join(extracted_mfg_numbers)}) and DAR/MA No ({extracted_dar_number}) found. Attempting combined lookup.")
        dar_lookup_results = lookup_by_dar(extracted_dar_number, med_df, cmp_df)

        if not dar_lookup_results.empty:
            combined_filtered_results = dar_lookup_results[
                (dar_lookup_results["Bio_3"].isin(extracted_mfg_numbers)) |
                (dar_lookup_results["NonBio_3"].isin(extracted_mfg_numbers))
            ]

            if not combined_filtered_results.empty:
                final_result_for_display = combined_filtered_results.iloc[0:1].copy()
                final_result_for_display = prepare_for_display(final_result_for_display)
                display_result(final_result_for_display, label=f"Combined Lookup (MFG & DAR/MA) - First Match")
                found_match = True
            else:
                print(f"[!] No combined match found for DAR/MA No '{extracted_dar_number}' and MFG Lic No(s) '{', '.join(extracted_mfg_numbers)}'.")
        else:
            print(f"[!] DAR/MA No '{extracted_dar_number}' did not yield any initial results for combined lookup.")

    if extracted_mfg_numbers and not found_match:
        print(f"[*] MFG Lic No(s) ({', '.join(extracted_mfg_numbers)}) found. Attempting MFG Lic No only lookup.")
        matched_companies_raw = find_companies_by_mfg_no(extracted_mfg_numbers, cmp_df)

        if not matched_companies_raw.empty:
            first_matched_company = matched_companies_raw.iloc[0:1].copy()
            company_key_to_search = first_matched_company["_company_key"].iloc[0]

            print(f"[*] Limiting output to the first matched company: '{first_matched_company['Company'].iloc[0]}'")

            med_rows_for_company = med_df[med_df["_company_key"] == company_key_to_search].copy()

            if not med_rows_for_company.empty:
                single_med_row = med_rows_for_company.iloc[0:1].copy()
                final_result_for_display = single_med_row.merge(
                    first_matched_company[["_company_key", "Address", "Bio_3", "NonBio_3", "Validity", "Status"]],
                    on="_company_key",
                    how="left"
                )
            else:
                final_result_for_display = first_matched_company.copy()

            final_result_for_display = prepare_for_display(final_result_for_display)
            display_result(final_result_for_display, label=f"MFG Lic Lookup (First Match for {', '.join(extracted_mfg_numbers)})")
            found_match = True
        else:
            print(f"[!] No company records found for MFG License Numbers: {', '.join(extracted_mfg_numbers)}.")


    if extracted_dar_number and not found_match:
        print(f"[*] DAR/MA No ({extracted_dar_number}) found. Attempting DAR/MA No only lookup.")
        dar_result = lookup_by_dar(extracted_dar_number, med_df, cmp_df)
        if not dar_result.empty:
            final_result_for_display = dar_result.iloc[0:1].copy()
            final_result_for_display = prepare_for_display(final_result_for_display)
            display_result(final_result_for_display, label=f"DAR/MA Lookup (First Match for '{extracted_dar_number}')")
            found_match = True
        else:
            print(f"[!] No medicine records found for DAR/MA No: '{extracted_dar_number}'.")

    if not found_match:
        print(f"[!] No relevant identifiers (MFG Lic No or DAR/MA No) found or matched for: '{query}'")

    return final_result_for_display