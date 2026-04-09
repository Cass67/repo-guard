#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any

DEFAULT_CONFIG = {
    "version": 1,
    "audit": {
        "exclude": [],
        "output_dir": ".repo-guard/reports",
        "deep": False,
        "baseline_file": None,
    },
    "scanning": {
        "severity": "HIGH,CRITICAL",
        "image_name": "local/repo-guard:dev",
    },
    "suppressions": [],
}


@dataclass
class ParsedConfig:
    data: dict[str, Any]
    warnings: list[str]


def parse_scalar(raw: str):
    raw = raw.strip()
    if raw == "true":
        return True
    if raw == "false":
        return False
    if raw.isdigit():
        return int(raw)
    if raw.startswith("[") and raw.endswith("]"):
        items = [item.strip().strip('"') for item in raw[1:-1].split(",") if item.strip()]
        return items
    return raw.strip('"')


def finding_key(tool: str, finding_id: str, package_or_target: str | None) -> str:
    target = package_or_target or "-"
    return f"{tool}|{finding_id}|{target}"


def parse_config_file(path: Path) -> ParsedConfig:
    if not path.exists():
        return ParsedConfig({}, [])

    data: dict[str, Any] = {}
    warnings: list[str] = []
    section: str | None = None
    current_suppression: dict[str, Any] | None = None

    for lineno, raw_line in enumerate(path.read_text().splitlines(), start=1):
        line = raw_line.rstrip()
        if not line.strip():
            continue
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue

        indent = len(line) - len(stripped)
        if indent not in (0, 2, 4):
            raise ValueError(f"{path}:{lineno}: unsupported indentation")

        if indent == 0:
            current_suppression = None
            section = None
            if stripped.endswith(":"):
                key = stripped[:-1]
                if key in ("audit", "scanning"):
                    data.setdefault(key, {})
                    section = key
                    continue
                if key == "suppressions":
                    data.setdefault("suppressions", [])
                    section = "suppressions"
                    continue
                warnings.append(f"unknown top-level config key: {key}")
                continue
            if ":" not in stripped:
                raise ValueError(f"{path}:{lineno}: malformed config line")
            key, value = stripped.split(":", 1)
            key = key.strip()
            if key not in ("version",):
                warnings.append(f"unknown top-level config key: {key}")
                continue
            data[key] = parse_scalar(value)
            continue

        if section in ("audit", "scanning") and indent == 2:
            if ":" not in stripped:
                raise ValueError(f"{path}:{lineno}: malformed config line")
            key, value = stripped.split(":", 1)
            data.setdefault(section, {})[key.strip()] = parse_scalar(value)
            continue

        if section == "suppressions":
            if indent == 2 and stripped.startswith("- "):
                entry: dict[str, Any] = {}
                remainder = stripped[2:].strip()
                if remainder:
                    if ":" not in remainder:
                        raise ValueError(f"{path}:{lineno}: malformed suppression line")
                    key, value = remainder.split(":", 1)
                    entry[key.strip()] = parse_scalar(value)
                data.setdefault("suppressions", []).append(entry)
                current_suppression = entry
                continue
            if indent == 4 and current_suppression is not None:
                if ":" not in stripped:
                    raise ValueError(f"{path}:{lineno}: malformed suppression field")
                key, value = stripped.split(":", 1)
                current_suppression[key.strip()] = parse_scalar(value)
                continue

        raise ValueError(f"{path}:{lineno}: unsupported config structure")

    return ParsedConfig(data, warnings)


def merge_configs(root_config: dict[str, Any], repo_config: dict[str, Any]) -> dict[str, Any]:
    merged = json.loads(json.dumps(DEFAULT_CONFIG))

    def apply_layer(layer: dict[str, Any]) -> None:
        if not layer:
            return
        if "version" in layer:
            merged["version"] = layer["version"]
        for key in ("audit", "scanning"):
            if isinstance(layer.get(key), dict):
                merged.setdefault(key, {}).update(layer[key])
        if isinstance(layer.get("suppressions"), list):
            merged["suppressions"] = layer["suppressions"]

    apply_layer(root_config)
    apply_layer(repo_config)
    return merged


def normalize_pip_audit(document: dict[str, Any]) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    for dependency in document.get("dependencies", []):
        package = dependency.get("name")
        for vuln in dependency.get("vulns", []):
            finding_id = vuln.get("id")
            if not finding_id:
                continue
            severity = vuln.get("severity") or "UNKNOWN"
            findings.append(
                {
                    "finding_key": finding_key("pip-audit", finding_id, package),
                    "id": finding_id,
                    "package": package,
                    "severity": severity,
                    "suppressed": False,
                }
            )
    return findings


def normalize_trivy(document: dict[str, Any], tool_id: str) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    for result in document.get("Results", []):
        target = result.get("Target")
        for vuln in result.get("Vulnerabilities", []) or []:
            finding_id = vuln.get("VulnerabilityID")
            package = vuln.get("PkgName") or target
            if not finding_id:
                continue
            findings.append(
                {
                    "finding_key": finding_key(tool_id, finding_id, package),
                    "id": finding_id,
                    "package": package,
                    "severity": vuln.get("Severity") or "UNKNOWN",
                    "suppressed": False,
                }
            )
        for misconfig in result.get("Misconfigurations", []) or []:
            finding_id = misconfig.get("ID")
            if not finding_id:
                continue
            findings.append(
                {
                    "finding_key": finding_key(tool_id, finding_id, target),
                    "id": finding_id,
                    "target": target,
                    "severity": misconfig.get("Severity") or "UNKNOWN",
                    "suppressed": False,
                }
            )
    return findings


def apply_suppressions(
    findings: list[dict[str, Any]],
    suppressions: list[dict[str, Any]],
    warnings: list[str],
) -> list[dict[str, Any]]:
    today = date.today()
    for finding in findings:
        tool_id = finding["finding_key"].split("|", 1)[0]
        package_or_target = finding.get("package") or finding.get("target")
        for suppression in suppressions:
            suppression_id = suppression.get("id")
            reason = suppression.get("reason")
            if not suppression_id or not reason:
                continue
            if suppression_id != finding.get("id"):
                continue
            if "tools" in suppression:
                tools = suppression["tools"]
                if isinstance(tools, str):
                    tools = [tools]
                if tool_id not in tools:
                    continue
            if "package" in suppression and suppression["package"] != package_or_target:
                continue
            expires = suppression.get("expires")
            if expires:
                try:
                    if date.fromisoformat(expires) < today:
                        warnings.append(f"expired suppression ignored: {suppression_id}")
                        continue
                except ValueError:
                    warnings.append(f"invalid suppression expiry ignored: {suppression_id}")
                    continue
            finding["suppressed"] = True
            break
    return findings


def build_repo_result(payload: dict[str, Any]) -> dict[str, Any]:
    repo_path = Path(payload["repo_path"])
    parsed = parse_config_file(Path(payload.get("config_path", "")))
    merged = merge_configs({}, parsed.data)
    repo_warnings = list(parsed.warnings)

    checks: list[dict[str, Any]] = []
    for check_payload in payload.get("checks", []):
        check_warnings: list[str] = []
        stdout_text = ""
        stderr_text = ""
        if check_payload.get("stdout_path"):
            stdout_text = Path(check_payload["stdout_path"]).read_text().strip()
        if check_payload.get("stderr_path"):
            stderr_text = Path(check_payload["stderr_path"]).read_text().strip()

        findings: list[dict[str, Any]]
        parse_error = False
        if not stdout_text:
            findings = []
        else:
            try:
                document = json.loads(stdout_text)
                if check_payload["id"] == "pip-audit":
                    findings = normalize_pip_audit(document)
                else:
                    findings = normalize_trivy(document, check_payload["id"])
            except json.JSONDecodeError:
                findings = []
                parse_error = True
                check_warnings.append("scanner output was not valid JSON")

        findings = apply_suppressions(findings, merged.get("suppressions", []), check_warnings)
        suppressed_count = sum(1 for item in findings if item.get("suppressed"))
        unsuppressed_count = sum(1 for item in findings if not item.get("suppressed"))
        exit_code = int(check_payload.get("exit_code", 0))

        status = "clean"
        if parse_error or exit_code >= 2:
            status = "error"
        elif unsuppressed_count > 0:
            status = "issues"

        if status == "error" and stderr_text:
            check_warnings.append(stderr_text)

        checks.append(
            {
                "id": check_payload["id"],
                "status": status,
                "finding_count": len(findings),
                "unsuppressed_count": unsuppressed_count,
                "suppressed_count": suppressed_count,
                "warnings": check_warnings,
                "findings": findings,
                "resolved_findings": [],
            }
        )

    overall_status = "skipped"
    if checks:
        if any(check["status"] == "error" for check in checks):
            overall_status = "error"
        elif any(check["status"] == "issues" for check in checks):
            overall_status = "issues"
        else:
            overall_status = "clean"

    return {
        "repo": {
            "name": repo_path.name,
            "path": str(repo_path),
            "relative_path": payload.get("relative_path", "."),
        },
        "status": overall_status,
        "detected": payload.get("detected", []),
        "missing_tools": payload.get("missing_tools", []),
        "warnings": repo_warnings,
        "checks": checks,
    }


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: repo_guard_runtime.py <resolve-run-config|build-repo-result> ...", file=sys.stderr)
        return 2

    command = argv[1]
    if command == "resolve-run-config":
        if len(argv) != 3:
            print("usage: repo_guard_runtime.py resolve-run-config <repo-config-path>", file=sys.stderr)
            return 2
        parsed = parse_config_file(Path(argv[2]))
        merged = merge_configs({}, parsed.data)
        print(
            json.dumps(
                {
                    "severity": merged["scanning"]["severity"],
                    "image_name": merged["scanning"]["image_name"],
                    "warnings": parsed.warnings,
                }
            )
        )
        return 0

    if command == "build-repo-result":
        if len(argv) != 3:
            print("usage: repo_guard_runtime.py build-repo-result <payload-json-path>", file=sys.stderr)
            return 2
        payload = json.loads(Path(argv[2]).read_text())
        print(json.dumps(build_repo_result(payload)))
        return 0

    print(f"unknown command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
