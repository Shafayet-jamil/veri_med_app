"""Download the DDInter drug-interaction data for the interaction checker.

    python import_ddinter.py --accept-license

DDInter (https://ddinter.scbdd.com/) lists about 160,000 drug-drug
interaction pairs with a severity level (Major / Moderate / Minor /
Unknown). Its data is licensed under Creative Commons
Attribution-NonCommercial-ShareAlike 4.0 (https://ddinter.scbdd.com/terms/):

  - you may use it for non-commercial purposes only,
  - you must credit DDInter (the app shows the source with each result),
  - anything you build from the data must use the same license.

For that reason the data is not stored in this repository. This script
writes it to excelFile/ddinter_interactions.csv (ignored by git), and the
server uses it automatically on its next start. Delete the file to stop
using DDInter.
"""
import argparse
import io
import os
import sys
import urllib.request

import pandas as pd

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_CSV = os.path.join(BACKEND_DIR, "excelFile", "ddinter_interactions.csv")
BASE_URL = "https://ddinter.scbdd.com/static/media/download/ddinter_downloads_code_{}.csv"
# One file per ATC group (A = alimentary tract, B = blood, ... V = various).
ATC_CODES = ["A", "B", "D", "H", "L", "P", "R", "V"]


def download(code: str) -> pd.DataFrame:
    url = BASE_URL.format(code)
    request = urllib.request.Request(url, headers={"User-Agent": "MediChecker"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return pd.read_csv(io.BytesIO(response.read()), dtype=str)


def build(frames: list[pd.DataFrame]) -> pd.DataFrame:
    df = pd.concat(frames, ignore_index=True).fillna("")
    df = pd.DataFrame({
        "drug_a": df["Drug_A"].str.strip(),
        "drug_b": df["Drug_B"].str.strip(),
        "level": df["Level"].str.strip(),
    })
    df = df[(df["drug_a"] != "") & (df["drug_b"] != "")]
    a, b = df["drug_a"].str.lower(), df["drug_b"].str.lower()
    pair = a.where(a < b, b) + "|" + b.where(a < b, a)
    return df[~pair.duplicated()].sort_values(["drug_a", "drug_b"])


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--accept-license", action="store_true",
                        help="confirm you will use DDInter data under CC BY-NC-SA 4.0 "
                             "(non-commercial use only)")
    args = parser.parse_args(argv)

    if not args.accept_license:
        print(__doc__)
        print("Re-run with --accept-license to confirm you accept these terms.")
        return 1

    frames = []
    for code in ATC_CODES:
        print(f"Downloading DDInter group {code} ...", flush=True)
        frames.append(download(code))

    df = build(frames)
    df.to_csv(OUTPUT_CSV, index=False)
    print(f"Saved {len(df):,} interaction pairs to {OUTPUT_CSV}")
    print("Restart the server to use them.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
