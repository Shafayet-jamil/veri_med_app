"""Measure OCR accuracy on the labelled samples in dataset/.

Usage: python eval_ocr.py [path/to/ocr_module.py]
"""
import importlib.util
import os
import sys
import time

from lookup import extract_and_normalize_dar_ma_number

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
DATASET_DIR = os.path.join(BACKEND_DIR, "dataset")

# Ground truth read off the packs, in database format.
LABELS = {
    "sample-1.jpeg": ("308-0761-021", "biltin"),
    "sample-2.jpeg": ("308-0761-021", "biltin"),
    "sample-3.jpeg": ("308-0761-021", "biltin"),
    "sample-4.jpeg": ("186-0480-006", "napa"),
    "sample-5.jpeg": ("186-0480-006", "napa"),
    "sample-6.jpeg": ("186-0480-006", "napa"),
    "sample-7.jpeg": ("353-0041-023", "furoclav"),
    "sample-8.jpeg": ("353-0041-023", "furoclav"),
    "sample-9.jpeg": ("353-0041-023", "furoclav"),
    "sample-10.jpeg": ("353-0041-023", "furoclav"),
    "sample-11.jpeg": ("353-0041-023", "furoclav"),
}


def load_ocr(module_path):
    spec = importlib.util.spec_from_file_location("ocr_under_test", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.run_easyocr


def main():
    module_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(BACKEND_DIR, "phase2_ocr.py")
    run_ocr = load_ocr(module_path)

    dar_hits = brand_hits = 0
    total_time = 0.0
    rows = []
    for name, (want_dar, want_brand) in LABELS.items():
        path = os.path.join(DATASET_DIR, name)
        start = time.perf_counter()
        text = " ".join(run_ocr(path))
        elapsed = time.perf_counter() - start
        total_time += elapsed

        got_dar = extract_and_normalize_dar_ma_number(text) or "-"
        dar_ok = got_dar == want_dar
        brand_ok = want_brand in text.lower()
        dar_hits += dar_ok
        brand_hits += brand_ok
        rows.append((name, want_dar, got_dar, dar_ok, brand_ok, elapsed))

    print(f"\n{'image':<16}{'expected':<15}{'got':<15}{'DAR':<5}{'brand':<7}secs")
    for name, want, got, dar_ok, brand_ok, elapsed in rows:
        print(f"{name:<16}{want:<15}{got:<15}{'OK' if dar_ok else 'X':<5}"
              f"{'OK' if brand_ok else 'X':<7}{elapsed:.1f}")
    n = len(LABELS)
    print(f"\nDAR correct: {dar_hits}/{n}   brand found: {brand_hits}/{n}   "
          f"avg time: {total_time / n:.1f}s")


if __name__ == "__main__":
    main()
