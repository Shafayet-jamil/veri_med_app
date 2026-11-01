import cv2
import easyocr
import numpy as np
import os
import re
import tempfile
import threading

from lookup import MFG_LICENCE_PATTERN, normalize_ma_number


# Reusable reader — EasyOCR model loading is expensive (~2-4 s), so we do it once.
_reader = None
# OCR is CPU-heavy and the reader is shared, so scans run one at a time.
_ocr_lock = threading.Lock()


class UnreadableImageError(ValueError):
    """The uploaded file could not be decoded as an image."""


def _get_reader():
    global _reader
    if _reader is None:
        _reader = easyocr.Reader(['en'], gpu=False)
    return _reader


# ── Preprocessing strategies ──────────────────────────────────────────────────

# Small labels are enlarged (up to 2x) so EasyOCR can read the fine print, but
# the longest side is capped: OCR time grows with pixel count, and phone photos
# enlarged 2x (e.g. 2400 -> 4800 px) can take minutes per scan.
MAX_UPSCALE = 2.0
MAX_SIDE = 2000


def _resize_for_ocr(img, max_upscale=MAX_UPSCALE, max_side=MAX_SIDE):
    h, w = img.shape[:2]
    scale = min(max_upscale, max_side / max(h, w))
    if abs(scale - 1.0) < 0.01:
        return img
    interpolation = cv2.INTER_LANCZOS4 if scale > 1 else cv2.INTER_AREA
    return cv2.resize(img, (round(w * scale), round(h * scale)),
                      interpolation=interpolation)


def _to_gray(img):
    if len(img.shape) == 3:
        return cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    return img


def _deskew(gray):
    coords = np.column_stack(np.where(gray > 0))
    if coords.shape[0] < 50:
        return gray
    angle = cv2.minAreaRect(coords)[-1]
    if angle < -45:
        angle = -(90 + angle)
    else:
        angle = -angle
    if abs(angle) < 0.5 or abs(angle) > 15:
        return gray
    h, w = gray.shape
    center = (w // 2, h // 2)
    matrix = cv2.getRotationMatrix2D(center, angle, 1.0)
    return cv2.warpAffine(gray, matrix, (w, h), flags=cv2.INTER_CUBIC,
                          borderMode=cv2.BORDER_REPLICATE)


def _strategy_clahe_otsu(gray):
    """Good for printed text on white/light backgrounds."""
    bilateral = cv2.bilateralFilter(gray, d=9, sigmaColor=75, sigmaSpace=75)
    clahe = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8, 8))
    enhanced = clahe.apply(bilateral)
    blur = cv2.GaussianBlur(enhanced, (0, 0), sigmaX=2)
    sharpened = cv2.addWeighted(enhanced, 1.5, blur, -0.5, 0)
    _, binary = cv2.threshold(sharpened, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (2, 2))
    return cv2.morphologyEx(binary, cv2.MORPH_OPEN, kernel, iterations=1)


def _strategy_adaptive(gray):
    """Better for uneven lighting and metallic/foil surfaces."""
    denoised = cv2.fastNlMeansDenoising(gray, h=12)
    binary = cv2.adaptiveThreshold(
        denoised, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY, blockSize=31, C=10
    )
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (2, 2))
    return cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel, iterations=1)


def _strategy_inverted(gray):
    """Handles light text on dark/metallic backgrounds (common on foil packs)."""
    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
    enhanced = clahe.apply(gray)
    _, binary = cv2.threshold(enhanced, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    white_ratio = np.sum(binary == 255) / binary.size
    if white_ratio < 0.15 or white_ratio > 0.85:
        return None
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (2, 2))
    return cv2.morphologyEx(binary, cv2.MORPH_OPEN, kernel, iterations=1)


def _strategy_high_contrast(gray):
    """Aggressive contrast for faded or low-contrast prints."""
    clahe = cv2.createCLAHE(clipLimit=4.0, tileGridSize=(4, 4))
    enhanced = clahe.apply(gray)
    blur = cv2.GaussianBlur(enhanced, (0, 0), sigmaX=3)
    sharpened = cv2.addWeighted(enhanced, 2.0, blur, -1.0, 0)
    _, binary = cv2.threshold(sharpened, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    return binary


# ── OCR text cleanup ─────────────────────────────────────────────────────────

# Common OCR misreads in the medicine/DAR-number context
_OCR_CORRECTIONS = [
    (r'\bMlG\b', 'MFG'),
    (r'\bMIG\b', 'MFG'),
    (r'\bL[1l]c\b', 'Lic'),
    (r'\bN[0o]\b', 'No'),
    (r'\bN[0o]\.\b', 'No.'),
    (r'\bDAF\b', 'DAR'),
    (r'\bOAR\b', 'DAR'),
    (r'\bD[A4]R\b', 'DAR'),
]


def _fix_ocr_errors(text: str) -> str:
    for pattern, replacement in _OCR_CORRECTIONS:
        text = re.sub(pattern, replacement, text, flags=re.IGNORECASE)
    return text


def _clean_text(text: str) -> str:
    text = text.strip()
    text = re.sub(r'[^\x20-\x7E]', ' ', text)
    text = re.sub(r'\s+', ' ', text)
    return text.strip()


# ── Spatial sorting ──────────────────────────────────────────────────────────

def _sort_by_position(ocr_results):
    """Sort OCR detections top-to-bottom, then left-to-right within each row."""
    if not ocr_results:
        return ocr_results

    entries = []
    for bbox, text, prob in ocr_results:
        top_y = min(pt[1] for pt in bbox)
        left_x = min(pt[0] for pt in bbox)
        entries.append((top_y, left_x, bbox, text, prob))

    if not entries:
        return ocr_results

    all_heights = []
    for bbox, text, prob in ocr_results:
        ys = [pt[1] for pt in bbox]
        all_heights.append(max(ys) - min(ys))
    row_threshold = max(np.median(all_heights) * 0.5, 10) if all_heights else 20

    entries.sort(key=lambda e: (e[0], e[1]))

    rows = []
    current_row = [entries[0]]
    for entry in entries[1:]:
        if abs(entry[0] - current_row[0][0]) <= row_threshold:
            current_row.append(entry)
        else:
            rows.append(current_row)
            current_row = [entry]
    rows.append(current_row)

    sorted_results = []
    for row in rows:
        row.sort(key=lambda e: e[1])
        for _, _, bbox, text, prob in row:
            sorted_results.append((bbox, text, prob))

    return sorted_results


# ── Deduplication ────────────────────────────────────────────────────────────

def _deduplicate(texts: list[str]) -> list[str]:
    """Remove near-duplicate strings (one is a substring of another)."""
    if len(texts) <= 1:
        return texts

    result = []
    seen_lower = []
    for text in texts:
        t = text.strip().lower()
        if not t:
            continue
        is_dup = False
        for s in seen_lower:
            if t in s or s in t:
                is_dup = True
                break
        if not is_dup:
            result.append(text)
            seen_lower.append(t)
    return result


# ── Multi-strategy OCR runner ────────────────────────────────────────────────

def _run_ocr_on_image(processed_gray, min_confidence=0.35):
    """Run EasyOCR on a preprocessed grayscale image and return filtered results."""
    fd, temp_path = tempfile.mkstemp(suffix=".png")
    os.close(fd)
    try:
        if not cv2.imwrite(temp_path, processed_gray):
            return []
        reader = _get_reader()
        raw = reader.readtext(
            temp_path,
            text_threshold=0.4,
            low_text=0.3,
            slope_ths=0.5,
            min_size=15,
            width_ths=0.8,
            paragraph=False,
        )
        return [(bbox, text, prob) for bbox, text, prob in raw if prob >= min_confidence]
    finally:
        if os.path.exists(temp_path):
            os.remove(temp_path)


_DAR_LABELLED = re.compile(
    r'\b(?:DAR|MA)[\s.:\-]*(?:No\.?[\s.:\-]*)?\d{2,4}[\s.:\-]+\d{2,5}[\s.:\-]+\d{2,5}',
    re.IGNORECASE,
)


def _has_key_identifiers(results):
    """True when the text already holds a labelled DAR/MA number and an MFG
    licence number: everything the database lookup needs."""
    text = _fix_ocr_errors(" ".join(_clean_text(t) for _, t, _ in results))
    return bool(_DAR_LABELLED.search(text) and MFG_LICENCE_PATTERN.search(text))


def _score_results(results):
    """Score a set of OCR results: prefer more high-confidence text."""
    if not results:
        return 0
    total_conf = sum(prob for _, _, prob in results)
    text_length = sum(len(text.strip()) for _, text, _ in results)
    return total_conf * 0.6 + text_length * 0.01


def run_easyocr(image_path):
    with _ocr_lock:
        return _run_easyocr(image_path)


def _run_easyocr(image_path):
    print("--Phase 2: Running Image Preprocessing & OCR--")

    img = cv2.imread(image_path)
    if img is None:
        raise UnreadableImageError("The uploaded file is not a readable image.")

    resized = _resize_for_ocr(img)
    gray = _to_gray(resized)
    gray = _deskew(gray)

    # Plain grayscale goes first: EasyOCR often reads it best, and when it
    # already finds the key identifiers the other passes are skipped.
    strategies = {
        "plain": lambda g: g,
        "clahe_otsu": _strategy_clahe_otsu,
        "adaptive": _strategy_adaptive,
        "inverted": _strategy_inverted,
        "high_contrast": _strategy_high_contrast,
    }

    best_results = []
    best_score = 0
    best_strategy = "none"

    for name, strategy_fn in strategies.items():
        processed = strategy_fn(gray)
        if processed is None:
            continue
        results = _run_ocr_on_image(processed, min_confidence=0.35)
        score = _score_results(results)
        print(f"  [{name}] {len(results)} detections, score={score:.1f}")
        if score > best_score:
            best_score = score
            best_results = results
            best_strategy = name
        if _has_key_identifiers(results):
            print(f"  [{name}] found DAR/MA and MFG licence numbers, stopping early")
            best_results = results
            best_strategy = name
            break

    print(f"  Best strategy: {best_strategy}")

    sorted_results = _sort_by_position(best_results)

    extracted = []
    for bbox, text, prob in sorted_results:
        cleaned = _clean_text(text)
        if len(cleaned) < 2:
            continue
        cleaned = _fix_ocr_errors(cleaned)
        extracted.append(cleaned)
        print(f"  [Confidence: {prob:.2f}] {cleaned}")

    extracted = _deduplicate(extracted)

    # Normalize MA/DAR numbers
    ma_pattern = re.compile(r'\d+-\d+-\d+')
    normalized = []
    for text in extracted:
        if ma_pattern.search(text):
            normed = normalize_ma_number(text)
            if normed != text:
                print(f"  [MA Normalized] '{text}' -> '{normed}'")
            normalized.append(normed)
        else:
            normalized.append(text)

    return normalized


if __name__ == "__main__":
    sample_image = os.path.join("dataset", "sample-4.jpeg")
    if os.path.exists(sample_image):
        results = run_easyocr(sample_image)
        print("\n--- Final extracted text ---")
        print(" ".join(results))
    else:
        print(f"Image not found: {sample_image}")
