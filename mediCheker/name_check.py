"""Check the medicine name printed on a package against the DGDA register.

The brand (trade) name is the largest, clearest text on almost every pack,
so it is usually read even when the small DAR / MA and MFG licence numbers
are not. This module finds the brand name in the OCR text and checks its
spelling against every registered trade name:

- ``exact``       a registered brand name is spelled correctly on the pack
- ``misspelled``  a word is one or two letters away from a registered brand
                  of the same manufacturer / generic, but not spelled the
                  same: a common sign of a counterfeit pack (or a misread)
- ``not_found``   no word on the pack is a registered brand name
- ``unreadable``  too little text was read to tell

Only the first word of a trade name is used as its "brand" ("Napa Extend"
-> "napa", "Furoclav-125" -> "furoclav"), because that is the part printed
large on the pack; strengths and suffixes are checked separately.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from functools import lru_cache

import pandas as pd
from rapidfuzz import fuzz, process
from rapidfuzz.distance import Levenshtein

EXACT = "exact"
MISSPELLED = "misspelled"
NOT_FOUND = "not_found"
UNREADABLE = "unreadable"

# Words printed on most packs that also happen to be (the first word of)
# some registered trade name. They never identify the medicine on their own.
_COMMON_WORDS = set("""
tablet tablets tab capsule capsules cap caps injection inj syrup suspension
solution drops cream ointment gel powder oral film coated each contains
contain store keep children reach dry place below above light protect
pharmaceuticals pharmaceutical pharma limited ltd plc company industries
laboratories healthcare bangladesh dhaka gazipur tongi manufactured marketed
for use only dose directed physician prescription batch date expiry exp mfg
lic dar reg price retail strip pack box usp bp rx medicine drug the and
with plus extra forte rapid one active ingredient warning read leaflet
carefully composition indications temperature room cool sunlight moisture
not more than mrp vat taka made new pure sugar free adult child children
care life plus max day night junior kids baby vet bolus
""".split())

# OCR often confuses these digits with letters inside a word.
_DIGIT_TO_LETTER = str.maketrans({"0": "o", "1": "l", "5": "s", "8": "b", "6": "g"})

# Less letters than this in the whole OCR text: the photo was not readable,
# so "no registered name found" would say nothing about the medicine.
MIN_LETTERS_TO_JUDGE = 20

_WORD = re.compile(r"[a-z0-9]+")


def _words(text: str) -> list[str]:
    return _WORD.findall(text.lower())


def _brand_of(trade_name: str) -> str:
    """First alphabetic word of a trade name ("Furoclav-125" -> "furoclav")."""
    for word in _words(trade_name):
        word = word.rstrip("0123456789")
        if len(word) >= 3 and word.isalpha():
            return word
        break
    return ""


def _ocr_variants(token: str) -> list[str]:
    """The token, plus fixes for common OCR slips: digits read for letters
    ("bi1tin" -> "biltin") and a strength glued on ("napa500" -> "napa")."""
    variants = [token]
    letters = sum(c.isalpha() for c in token)
    if letters and letters < len(token) and letters / len(token) >= 0.6:
        variants.append(token.translate(_DIGIT_TO_LETTER))
    stripped = token.rstrip("0123456789")
    if stripped != token and len(stripped) >= 3:
        variants.append(stripped)
    return [v for v in dict.fromkeys(variants) if v.isalpha()]


@dataclass
class _Candidate:
    row: int
    brand: str
    read_as: str
    status: str
    similarity: int
    support: int          # how many other pack details agree with this row
    position: int         # where in the text the brand was read
    weak: bool = False    # brand is also a generic / company / common word

    def rank(self):
        return (self.status == EXACT, not self.weak, self.support,
                len(self.brand), -self.position)


@dataclass
class NameCheckResult:
    status: str
    read_name: str = ""
    registered_name: str = ""
    similarity: int = 0
    row_index: int | None = None
    suggestions: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "status": self.status,
            "read_name": self.read_name,
            "registered_name": self.registered_name,
            "similarity": self.similarity,
            "suggestions": self.suggestions,
        }


class BrandIndex:
    """All registered brand names, indexed for exact and near spelling."""

    def __init__(self, med_df: pd.DataFrame):
        self.med_df = med_df
        self.rows_by_brand: dict[str, list[int]] = {}
        for idx, name in med_df["Trade Name"].items():
            brand = _brand_of(str(name))
            if brand:
                self.rows_by_brand.setdefault(brand, []).append(idx)
        self.brands = list(self.rows_by_brand)

        generic_words = {w for g in med_df["Generic Name With Strength"]
                         for w in _words(str(g)) if w.isalpha()}
        self.company_words = {w for c in med_df["Company"]
                              for w in _words(str(c)) if w.isalpha()}
        self.weak_words = _COMMON_WORDS | generic_words | self.company_words

    # ── corroboration ──────────────────────────────────────────────────────
    def _support(self, idx: int, text_words: set[str], text_lower: str) -> int:
        """Points for other details of row ``idx`` that appear on the pack.

        A score of 3 or more always includes the manufacturer's name.
        """
        row = self.med_df.loc[idx]
        points = 0
        if self._maker_on_pack(row, text_words):
            points += 3
        generic = [w for w in _words(str(row.get("Generic Name With Strength", "")))
                   if w.isalpha() and len(w) > 3]
        if generic and all(w in text_words for w in generic):
            points += 2
        for strength in re.findall(r"\d+(?:\.\d+)?", str(row.get("Generic Name With Strength", ""))):
            if re.search(rf"(?<![\d.]){re.escape(strength)}(?![\d.])", text_lower):
                points += 1
                break
        trade = " ".join(_words(str(row.get("Trade Name", ""))))
        if len(trade.split()) > 1 and trade in " ".join(_words(text_lower)):
            points += 2   # the full name, e.g. "napa extend", not just "napa"
        form = str(row.get("Dosage Form", "")).lower().split()
        if form and form[-1] in text_words:
            points += 1
        # "Napa Rapid" is a different product from "Napa": prefer the row
        # whose extra words (if any) are on the pack too.
        extra = [w for w in _words(trade)[1:] if w.isalpha() and w not in text_words]
        points -= len(extra)
        return points

    @staticmethod
    def _maker_on_pack(row, text_words) -> bool:
        company = [w for w in _words(str(row.get("Company", "")))
                   if len(w) > 3 and w not in _COMMON_WORDS]
        return bool(company) and company[0] in text_words

    def _best_row(self, brand, text_words, text_lower, require_maker=False):
        scored = [(self._support(i, text_words, text_lower), i)
                  for i in self.rows_by_brand[brand]]
        if require_maker:
            scored = [s for s in scored
                      if self._maker_on_pack(self.med_df.loc[s[1]], text_words)]
            if not scored:
                return None, 0
        # Highest support; on a tie the row listed first in the register.
        support, idx = max(scored, key=lambda s: (s[0], -s[1]))
        return idx, support

    # ── main entry point ───────────────────────────────────────────────────
    def check(self, text: str, expected_brand: str | None = None) -> NameCheckResult:
        """Find and spell-check the brand name in OCR ``text``.

        With ``expected_brand`` (from a DAR / MA lookup) only that brand is
        looked for, so the result says whether the pack spells it right.
        """
        text_lower = text.lower()
        tokens = _words(text)
        text_words = set(tokens)

        if expected_brand:
            return self._check_expected(_brand_of(expected_brand) or expected_brand.lower(),
                                        expected_brand, tokens)

        if sum(c.isalpha() for c in text) < MIN_LETTERS_TO_JUDGE:
            return NameCheckResult(UNREADABLE)

        candidates: list[_Candidate] = []
        near_words = []
        for pos, token in enumerate(tokens):
            for variant in _ocr_variants(token):
                if len(variant) < 3:
                    continue
                if variant in self.rows_by_brand:
                    weak = variant in self.weak_words
                    # A brand that is also an everyday / generic word ("each",
                    # "paracetamol") counts only when its maker is on the pack.
                    idx, support = self._best_row(variant, text_words, text_lower,
                                                  require_maker=weak)
                    if idx is None:
                        continue
                    candidates.append(_Candidate(idx, variant, token, EXACT, 100,
                                                 support, pos, weak))
                    break
            else:
                word = _ocr_variants(token)[-1] if _ocr_variants(token) else ""
                if len(word) >= 5 and word not in self.weak_words:
                    near_words.append((pos, token, word))

        exact = [c for c in candidates if c.status == EXACT]
        if exact:
            best = max(exact, key=_Candidate.rank)
            return self._result(best)

        # No registered name is spelled correctly. Look for a word one or two
        # letters away from a brand whose maker or generic is also on the pack:
        # that is how counterfeit packs typically differ from the real one.
        suggestions: dict[str, int] = {}
        for pos, token, word in near_words:
            max_edits = 1 if len(word) < 7 else 2
            for brand, score, _ in process.extract(word, self.brands, scorer=fuzz.ratio,
                                                   score_cutoff=75, limit=5):
                if Levenshtein.distance(word, brand) > max_edits:
                    continue
                idx, support = self._best_row(brand, text_words, text_lower)
                name = str(self.med_df.at[idx, "Trade Name"]).strip()
                suggestions[name] = max(suggestions.get(name, 0), round(score))
                if support >= 2:
                    candidates.append(_Candidate(idx, brand, token, MISSPELLED,
                                                 round(score), support, pos))

        ordered = [n for n, _ in sorted(suggestions.items(), key=lambda s: -s[1])][:5]
        if candidates:
            best = max(candidates, key=lambda c: (c.support, c.similarity, -c.position))
            result = self._result(best)
            result.suggestions = ordered
            return result
        return NameCheckResult(NOT_FOUND, suggestions=ordered)

    def lookup_name(self, name: str) -> NameCheckResult:
        """Check a name the user typed (not OCR text): the whole input is
        the medicine name, so no corroborating details are needed."""
        typed = " ".join(_words(name))
        if not typed:
            return NameCheckResult(UNREADABLE)
        trade_names = self.med_df["Trade Name"].str.lower().str.split().str.join(" ")
        exact_rows = trade_names.index[trade_names == typed]
        brand = _brand_of(name)
        if len(exact_rows):
            idx = exact_rows[0]
        elif brand in self.rows_by_brand and brand == typed:
            # "napa" -> the product named just "Napa", if there is one.
            rows = self.rows_by_brand[brand]
            plain = [i for i in rows if trade_names[i] == brand]
            idx = (plain or rows)[0]
        else:
            matches = process.extract(brand or typed, self.brands, scorer=fuzz.ratio,
                                      score_cutoff=70, limit=5)
            suggestions = [self._display_name(b) for b, _, _ in matches]
            return NameCheckResult(NOT_FOUND, read_name=name.strip(),
                                   suggestions=list(dict.fromkeys(suggestions)))
        return NameCheckResult(EXACT, name.strip(),
                               str(self.med_df.at[idx, "Trade Name"]).strip(), 100, idx)

    def _display_name(self, brand: str) -> str:
        """How a brand is registered: "napa" -> "Napa" (not "Napa One")."""
        names = [str(self.med_df.at[i, "Trade Name"]).strip()
                 for i in self.rows_by_brand[brand]]
        plain = [n for n in names if " ".join(_words(n)) == brand]
        return (plain or names)[0]

    def _check_expected(self, brand, display, tokens) -> NameCheckResult:
        best_word, best_score = "", 0
        for token in tokens:
            for variant in _ocr_variants(token):
                if variant == brand:
                    return NameCheckResult(EXACT, token, display, 100)
                score = round(fuzz.ratio(variant, brand))
                if score > best_score:
                    best_word, best_score = token, score
        max_edits = 1 if len(brand) < 7 else 2
        if best_word and len(brand) >= 4:
            variant = _ocr_variants(best_word)[-1]
            if 0 < Levenshtein.distance(variant, brand) <= max_edits:
                return NameCheckResult(MISSPELLED, best_word, display, best_score)
        return NameCheckResult(NOT_FOUND, registered_name=display)

    def _result(self, cand: _Candidate) -> NameCheckResult:
        return NameCheckResult(
            status=cand.status,
            read_name=cand.read_as,
            registered_name=str(self.med_df.at[cand.row, "Trade Name"]).strip(),
            similarity=cand.similarity,
            row_index=cand.row,
        )


@lru_cache(maxsize=1)
def get_brand_index() -> BrandIndex:
    from lookup import load_sheets
    med_df, _ = load_sheets()
    return BrandIndex(med_df)
