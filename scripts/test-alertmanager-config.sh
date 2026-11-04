#!/usr/bin/env bash
# Asserts the Alertmanager config in helm/monitoring/ is valid and routes alerts
# to a real receiver. The chart default routes everything to "null", which drops
# every alert silently; this keeps a real receiver from regressing back to that.
# helm/monitoring/ is a values-only wrapper for the upstream chart, so this reads
# alertmanager.config and alertmanager.templateFiles straight from the values and
# checks them with amtool rather than rendering the chart.
# Run: ./scripts/test-alertmanager-config.sh   (needs amtool and python3 + PyYAML)
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { echo "  ✅ $1"; pass=$((pass+1)); }
bad() { echo "  ❌ $1"; fail=$((fail+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Write the config with its template glob pointed at the extracted template
# files, as the chart does when it mounts them at /etc/alertmanager/config/.
python3 - "$tmp" <<'PY' || { echo "could not extract alertmanager config"; exit 1; }
import sys, yaml
out = sys.argv[1]
am = yaml.safe_load(open("helm/monitoring/values.yaml"))["alertmanager"]
for name, body in (am.get("templateFiles") or {}).items():
    open(f"{out}/{name}", "w").write(body)
cfg = am["config"]
cfg["templates"] = [f"{out}/*.tmpl"]
yaml.safe_dump(cfg, open(f"{out}/alertmanager.yaml", "w"))
print(" ".join(am.get("alertmanagerSpec", {}).get("secrets") or []), file=open(f"{out}/secrets", "w"))
PY

cfg="$tmp/alertmanager.yaml"
if out="$(amtool check-config "$cfg" 2>&1)"; then
  ok "amtool check-config passes"
else
  bad "amtool check-config failed: $out"
fi

# route LABELS... EXPECTED — the receiver an alert with these labels reaches.
route() {
  local want="${*: -1}" labels=("${@:1:$#-1}") got
  got="$(amtool config routes test --config.file="$cfg" "${labels[@]}" 2>&1)"
  if [ "$got" = "$want" ]; then
    ok "${labels[*]} → $want"
  else
    bad "${labels[*]} → expected $want, got $got"
  fi
}

route alertname=Watchdog severity=none                          'null'
route alertname=ArgoCDControllerCrashLooping severity=warning   slack-warning
route alertname=KubePodCrashLooping severity=critical           slack-critical
route alertname=CPUThrottlingHigh severity=info                 'null'
# An alert with no severity label must still reach someone.
route alertname=SomethingUnlabelled                             slack-warning

# Every Slack receiver reads its webhook from a mounted Secret, never inline.
if grep -q 'api_url:' "$cfg"; then
  bad "a receiver sets an inline api_url — the webhook must come from a Secret"
else
  ok "no inline webhook URL"
fi
for f in $(grep -o 'api_url_file: .*' "$cfg" | awk '{print $2}' | sort -u); do
  secret="$(printf '%s' "$f" | sed -n 's#^/etc/alertmanager/secrets/\([^/]*\)/.*#\1#p')"
  if [ -n "$secret" ] && grep -qw "$secret" "$tmp/secrets"; then
    ok "$f is mounted via alertmanagerSpec.secrets"
  else
    bad "$f is not under a Secret listed in alertmanagerSpec.secrets"
  fi
done

echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
