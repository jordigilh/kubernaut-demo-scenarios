#!/usr/bin/env python3
"""
RemediationWorkflow detectedLabels type/name validator.

Why this exists (kubernaut-demo-scenarios#416):
    The RemediationWorkflow CRD declares `spec.detectedLabels` with
    `x-kubernetes-preserve-unknown-fields: true` (kubebuilder marker
    `+kubebuilder:pruning:PreserveUnknownFields` on a raw
    `*apiextensionsv1.JSON` field in kubernaut's Go types). That means the
    CRD's own OpenAPI schema does NOT type-check anything inside
    detectedLabels -- `kubectl apply --dry-run=server` and any CRD-schema
    based tool (kubeconform, kubeval, ...) will happily accept
    `helmManaged: "true"` even though it's a string, not a bool.

    The actual type enforcement only happens later, at runtime, in
    kubernaut's KA workflow catalog cache
    (internal/kubernautagent/workflowcatalog/cache_convert.go), which does a
    plain `json.Unmarshal` of this blob into `sharedtypes.DetectedLabels`.
    A type mismatch on ANY workflow's detectedLabels fails that Unmarshal,
    which fails the *entire* catalog-list call -- breaking workflow
    discovery for every investigation, not just the offending workflow.

    This script closes that gap client-side, at PR time, by re-implementing
    the same field-name -> type contract as a standalone check (no
    dependency on kubernaut's Go module).

Source of truth this mirrors (keep in sync if kubernaut changes the struct):
    github.com/jordigilh/kubernaut pkg/shared/types/enrichment.go
    `type DetectedLabels struct { ... }`

Usage:
    python3 scripts/validate-detected-labels.py [DIR ...]

Defaults to deploy/remediation-workflows/ if no paths are given.

Exit codes:
    0  all detectedLabels blocks are well-typed
    1  one or more type/name errors found
    2  usage / file-read / YAML-parse error
"""
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("error: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

DEFAULT_ROOT = "deploy/remediation-workflows"

# Mirrors kubernaut's sharedtypes.DetectedLabels json tags exactly.
# "bool" fields must decode as a YAML/JSON boolean (not a quoted string).
# "enum" fields must decode as a string from the given allowed set
# (empty string is always allowed, matching `omitempty` + kubebuilder enum
# tags that include `""`).
BOOL_FIELDS = {
    "gitOpsManaged",
    "pdbProtected",
    "hpaEnabled",
    "stateful",
    "helmManaged",
    "networkIsolated",
    "resourceQuotaConstrained",
    "virtualMachine",
    "liveMigratable",
    "cdiManaged",
}

# "*" is not in kubernaut's kubebuilder:validation:Enum comment on these
# fields, but internal/kubernautagent/workflowcatalog/cache_filter.go's
# matchesDetectedStringField() treats it as an explicit wildcard ("matches
# any non-empty detected value") for every string detectedLabels field --
# it is a legitimate, intentionally-supported value, not a typo.
ENUM_FIELDS = {
    "gitOpsTool": {"argocd", "flux", "*", ""},
    "serviceMesh": {"istio", "linkerd", "*", ""},
    "storageBackend": {"odf-ceph", "lvms", "local", "*", ""},
}

FAILED_DETECTIONS_ALLOWED = {
    "gitOpsManaged",
    "gitOpsTool",
    "pdbProtected",
    "hpaEnabled",
    "stateful",
    "helmManaged",
    "networkIsolated",
    "serviceMesh",
    "resourceQuotaConstrained",
    "virtualMachine",
    "liveMigratable",
    "cdiManaged",
    "storageBackend",
}

KNOWN_FIELDS = BOOL_FIELDS | set(ENUM_FIELDS) | {"failedDetections"}


def _type_name(value: Any) -> str:
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, str):
        return "string"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    if value is None:
        return "null"
    return type(value).__name__


def check_detected_labels(detected_labels: dict, where: str) -> list[str]:
    errors = []

    if not isinstance(detected_labels, dict):
        errors.append(
            f"{where}: detectedLabels must be a mapping, got {_type_name(detected_labels)}"
        )
        return errors

    for field, value in detected_labels.items():
        if field not in KNOWN_FIELDS:
            errors.append(
                f"{where}: unrecognized detectedLabels field '{field}' -- not in "
                f"kubernaut's DetectedLabels struct (typo? silently ignored at runtime, "
                f"never takes effect)"
            )
            continue

        if field == "failedDetections":
            if not isinstance(value, list):
                errors.append(
                    f"{where}: detectedLabels.failedDetections must be an array of "
                    f"strings, got {_type_name(value)} ({value!r})"
                )
                continue
            for item in value:
                if not isinstance(item, str) or item not in FAILED_DETECTIONS_ALLOWED:
                    errors.append(
                        f"{where}: detectedLabels.failedDetections contains invalid "
                        f"entry {item!r} (must be one of {sorted(FAILED_DETECTIONS_ALLOWED)})"
                    )
            continue

        if field in BOOL_FIELDS:
            if not isinstance(value, bool):
                errors.append(
                    f"{where}: detectedLabels.{field} must be a boolean, got "
                    f"{_type_name(value)} ({value!r}) -- kubernaut's json.Unmarshal "
                    f"will fail on this and break workflow catalog discovery for "
                    f"EVERY workflow, not just this one (see kubernaut-demo-scenarios#416)"
                )
            continue

        if field in ENUM_FIELDS:
            allowed = ENUM_FIELDS[field]
            if not isinstance(value, str):
                errors.append(
                    f"{where}: detectedLabels.{field} must be a string, got "
                    f"{_type_name(value)} ({value!r})"
                )
            elif value not in allowed:
                errors.append(
                    f"{where}: detectedLabels.{field} value {value!r} is not one of "
                    f"the allowed values {sorted(allowed)}"
                )

    return errors


def check_file(path: Path) -> list[str]:
    errors = []
    try:
        text = path.read_text()
    except OSError as exc:
        return [f"{path}: failed to read file: {exc}"]

    try:
        docs = list(yaml.safe_load_all(text))
    except yaml.YAMLError as exc:
        return [f"{path}: failed to parse YAML: {exc}"]

    for i, doc in enumerate(docs):
        if not isinstance(doc, dict) or doc.get("kind") != "RemediationWorkflow":
            continue

        name = (doc.get("metadata") or {}).get("name", f"doc#{i}")
        where = f"{path} ({name})"

        spec = doc.get("spec") or {}
        detected_labels = spec.get("detectedLabels")
        if detected_labels is None:
            continue

        errors.extend(check_detected_labels(detected_labels, where))

    return errors


def main(argv: list[str]) -> int:
    roots = [Path(p) for p in argv] or [Path(DEFAULT_ROOT)]

    files: list[Path] = []
    for root in roots:
        if root.is_file():
            files.append(root)
        elif root.is_dir():
            files.extend(sorted(root.rglob("*.yaml")))
            files.extend(sorted(root.rglob("*.yml")))
        else:
            print(f"error: path not found: {root}", file=sys.stderr)
            return 2

    if not files:
        print(f"error: no YAML files found under {roots}", file=sys.stderr)
        return 2

    all_errors: list[str] = []
    checked_workflows = 0
    for path in files:
        errors = check_file(path)
        all_errors.extend(errors)
        checked_workflows += 1

    if all_errors:
        print(f"detectedLabels validation FAILED ({len(all_errors)} error(s)):\n")
        for err in all_errors:
            print(f"  - {err}")
        print(
            f"\nChecked {checked_workflows} file(s). See "
            f"scripts/validate-detected-labels.py header for the field-type "
            f"contract this enforces."
        )
        return 1

    print(f"detectedLabels validation passed ({checked_workflows} file(s) checked).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
