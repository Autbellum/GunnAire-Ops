"""Fail CI when xcodebuild reports success without executing a requested test.

Consumes the authoritative xcresulttool summary and test tree, not console
phrases or a cached discovery list. No network, credentials, or app data access.
"""

import argparse
import json
from pathlib import Path
from urllib.parse import unquote, urlsplit


def verify(summary: dict, tree: dict, selectors: list[str]) -> dict:
    for name in ("passedTests", "failedTests", "skippedTests"):
        value = summary.get(name)
        if type(value) is not int or value < 0:
            raise ValueError(f"Missing or invalid result count: {name}")
    if summary["passedTests"] == 0 or summary["failedTests"] or summary["skippedTests"]:
        raise ValueError("Native tests must actually pass, without failures or skips")
    expected = []
    for selector in selectors:
        prefix = "-only-testing:"
        if not selector.startswith(prefix) or not selector[len(prefix):].strip():
            raise ValueError("Expected a nonempty -only-testing: selector")
        expected.append(selector[len(prefix):].removesuffix("()"))
    if not expected or len(set(expected)) != len(expected):
        raise ValueError("Required test selectors must be nonempty and unique")

    cases = []

    def visit(nodes):
        if not isinstance(nodes, list):
            raise ValueError("Malformed xcresult test tree")
        for node in nodes:
            if not isinstance(node, dict):
                raise ValueError("Malformed xcresult test node")
            if node.get("nodeType") == "Test Case":
                if node.get("result") != "Passed":
                    raise ValueError("A test case did not pass")
                url = urlsplit(node.get("nodeIdentifierURL", ""))
                parts = unquote(url.path).strip("/").split("/")
                if url.scheme != "test" or url.netloc != "com.apple.xcode" or len(parts) < 4:
                    raise ValueError("A test case has no authoritative target identity")
                cases.append("/".join(parts[1:]).removesuffix("()"))
            visit(node.get("children", []))

    visit(tree.get("testNodes"))
    missing = [selector for selector in expected if not any(
        case == selector or case.startswith(selector + "/") for case in cases
    )]
    if missing:
        raise ValueError("Required tests were not executed: " + ", ".join(missing))
    if len(cases) != summary["passedTests"]:
        raise ValueError("Actual test case count does not match passedTests count")
    if len(cases) != len(set(cases)):
        raise ValueError("Duplicate test case identities detected")
    return {"verifiedSelectors": len(expected), "passedTestCases": len(cases)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", required=True, type=Path)
    parser.add_argument("--tests", required=True, type=Path)
    parser.add_argument("selectors", nargs="+")
    args = parser.parse_args()
    try:
        result = verify(json.loads(args.summary.read_text()), json.loads(args.tests.read_text()), args.selectors)
    except (OSError, ValueError, TypeError, AttributeError) as error:
        parser.exit(1, f"Native execution verification failed: {error}\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
