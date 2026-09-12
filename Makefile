.PHONY: test validate checklist checklist-check syntax verify verify-release
PYTHON ?= python3

verify-release:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) Tools/verify_release.py $(if $(NATIVE_DESTINATION),--native-destination '$(NATIVE_DESTINATION)',)

test:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s LocalAI/tests -p 'test_*.py' -v
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Firewall/tests -p 'test_*.py' -v

validate:
	PYTHONDONTWRITEBYTECODE=1 python3 Firewall/validate_plan.py

checklist:
	PYTHONDONTWRITEBYTECODE=1 python3 Firewall/generate_checklist.py --output Firewall/DEPLOYMENT_CHECKLIST.generated.md

checklist-check:
	@temporary="$$(mktemp)"; \
	trap 'rm -f "$$temporary"' EXIT; \
	PYTHONDONTWRITEBYTECODE=1 python3 Firewall/generate_checklist.py --output "$$temporary" >/dev/null; \
	cmp -s "$$temporary" Firewall/DEPLOYMENT_CHECKLIST.generated.md || { \
		echo "Firewall/DEPLOYMENT_CHECKLIST.generated.md is stale; run 'make checklist'." >&2; \
		exit 1; \
	}

syntax:
	bash -n LocalAI/setup_local_ai.sh
	python3 -c 'import json,pathlib,plistlib; root=pathlib.Path("."); [json.loads(p.read_text()) for p in root.rglob("*.json")]; [(lambda f: plistlib.load(f))(p.open("rb")) for p in root.rglob("*.plist.template")]; print("Configuration syntax: PASS")'

verify: test validate checklist-check syntax
