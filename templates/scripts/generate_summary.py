#!/usr/bin/env python3
"""Parse JUnit XML and emit a summary.json with a failed-test list.

Usage:
    python3 generate_summary.py <report.xml> <summary.json> [pytest-args]
"""
import json
import re
import sys
import xml.etree.ElementTree as ET


def parse(xml_path: str) -> dict:
    tree = ET.parse(xml_path)
    root = tree.getroot()
    ts = root if root.tag == "testsuite" else root.find("testsuite")

    failed_tests = []
    passed_tests = []
    skipped_tests = []

    for testcase in root.iter("testcase"):
        f = testcase.find("failure")
        e = testcase.find("error")
        s = testcase.find("skipped")
        name = testcase.attrib.get("name", "")
        classname = testcase.attrib.get("classname", "")
        if f is not None or e is not None:
            node = f if f is not None else e
            failed_tests.append({
                "name": name,
                "classname": classname,
                "message": (node.attrib.get("message", "") or "")[:200],
            })
        elif s is not None:
            reason = (s.attrib.get("message", "") or s.text or "")[:200]
            skipped_tests.append({
                "name": name,
                "classname": classname,
                "reason": reason.strip(),
            })
        else:
            passed_tests.append({
                "name": name,
                "classname": classname,
                "time": testcase.attrib.get("time", "0"),
            })

    return {
        "tests": int(ts.attrib.get("tests", 0)),
        "failures": int(ts.attrib.get("failures", 0)),
        "errors": int(ts.attrib.get("errors", 0)),
        "skipped": int(ts.attrib.get("skipped", 0)),
        "time": float(ts.attrib.get("time", 0)),
        "failed_tests": failed_tests,
        "passed_tests": passed_tests,
        "skipped_tests": skipped_tests,
    }


def detect_run_type(pytest_args: str) -> str:
    """Derive a human-readable label for the run from PYTEST_ARGS.

    Supported -m forms:
      -m smoke                    -> "smoke"
      -m "smoke and not slow"     -> "smoke and not slow"
      -m 'regression'             -> "regression"
    """
    args = (pytest_args or "").strip()
    if not args:
        return "full"
    m = re.search(r"""-m\s+(?:"([^"]+)"|'([^']+)'|(\S+))""", args)
    if m:
        marker = (m.group(1) or m.group(2) or m.group(3) or "").strip()
        if marker == "smoke":
            return "smoke"
        if marker in ("regression", "regress"):
            return "regression"
        return marker
    k = re.search(r"""-k\s+(?:"([^"]+)"|'([^']+)'|(\S+))""", args)
    if k:
        keyword = (k.group(1) or k.group(2) or k.group(3) or "").strip()
        return f"filter:{keyword[:20]}"
    return "full"


if __name__ == "__main__":
    xml_path = sys.argv[1]
    output = sys.argv[2] if len(sys.argv) > 2 else "summary.json"
    pytest_args = sys.argv[3] if len(sys.argv) > 3 else ""
    data = parse(xml_path)
    data["run_type"] = detect_run_type(pytest_args)
    with open(output, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"summary.json written: {output}")
