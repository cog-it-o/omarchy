echo "Remove the Validity post-suspend daemon restart that slowed wake"

rm -f /usr/lib/systemd/system-sleep/python-validity-wakeup
rm -f /usr/lib/systemd/system-sleep/fprint_wakeup

systemctl disable --now python3-validity-suspend-hotfix.service 2>/dev/null || true
systemctl mask python3-validity-suspend-hotfix.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
