#!/bin/sh
# Test of the vendor/build.prop rewrite in usb/hook.sh (DEVICE_MODEL, DENSITY, the always-on overrides) and of DEVICE_MODEL=auto (fake DMI trees): the blocks are cut out of
# hook.sh and run on fake files, so what is tested is the shipped code.
# Run: sh tools/test_device_model.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/devmodel.XXXXXX"); trap 'rm -rf "$W"' EXIT
fail=0; n=0; H0=$ROOT/usb/hook.sh
ok()  { n=$((n+1)); echo "ok   $*"; }
bad() { n=$((n+1)); fail=$((fail+1)); echo "FAIL $*"; }

# the block: from 'case "$DENSITY" in' to the '} > /tmp/vendor.build.prop' redirect (the bind mount after it is cut off)
awk '/^case "\$DENSITY" in/{p=1} p{print} /^\} > \/tmp\/vendor.build.prop/{exit}' "$ROOT/usb/hook.sh" \
  | sed -e 's# && mount --bind.*$##' -e "s#/new/vendor/build.prop#$W/in.prop#g" -e "s#/tmp/vendor.build.prop#$W/out.prop#g" > "$W/block.sh"
[ -s "$W/block.sh" ] && ok "block extracted from hook.sh ($(wc -l < "$W/block.sh") lines)" || { bad "block not found in hook.sh"; exit 1; }

cat > "$W/in.prop" <<'EOF'
ro.product.vendor.model=Lapis
ro.product.vendor.marketname=Lapis Googlebook
ro.product.vendor.brand=google
ro.boot.hypervisor.protected_vm.supported=1
ro.sf.lcd_density=260
EOF
count() { grep -c "^$1\$" "$W/out.prop"; }

# with DEVICE_MODEL: old model/marketname lines replaced (each key exactly once), other lines kept
DEVICE_MODEL="Surface Laptop 7" GPU_SW=0 DENSITY= sh "$W/block.sh"
for k in "ro.product.model=Surface Laptop 7" "ro.product.vendor.model=Surface Laptop 7" "ro.product.marketname=Surface Laptop 7" "ro.product.vendor.marketname=Surface Laptop 7"; do
  [ "$(count "$k")" = 1 ] && ok "out.prop has: $k" || bad "out.prop lacks (or repeats): $k"
done
grep -q 'Lapis' "$W/out.prop" && bad "old model/marketname lines survived" || ok "old model/marketname lines are gone"
grep -q '^ro.product.vendor.brand=google$' "$W/out.prop" && ok "brand untouched" || bad "brand changed"
grep -q 'protected_vm' "$W/out.prop" && bad "protected_vm line not hidden" || ok "protected_vm.supported still hidden"
grep -q '^ro.sf.lcd_density=260$' "$W/out.prop" && ok "stock density kept when DENSITY unset" || bad "density changed without DENSITY"

# without DEVICE_MODEL: nothing about the model changes
DEVICE_MODEL= GPU_SW=0 DENSITY=180 sh "$W/block.sh"
grep -q '^ro.product.vendor.model=Lapis$' "$W/out.prop" && grep -q '^ro.product.vendor.marketname=Lapis Googlebook$' "$W/out.prop" && ok "DEVICE_MODEL unset: model lines untouched" || bad "DEVICE_MODEL unset but model lines changed"
grep -q '^ro.product.model=' "$W/out.prop" && bad "ro.product.model added although DEVICE_MODEL unset" || ok "DEVICE_MODEL unset: no ro.product.model added"
grep -q '^ro.sf.lcd_density=180$' "$W/out.prop" && ok "DENSITY still applied" || bad "DENSITY not applied"

# DEVICE_MODEL=auto: the name from fake DMI trees (the 'if [ "$DEVICE_MODEL" = auto ]' block of hook.sh, run with DMI= pointed at them)
awk '/^if \[ "\$DEVICE_MODEL" = auto \]; then/{p=1} p{print} p&&/^fi$/{exit}' "$H0" > "$W/auto.sh"
[ -s "$W/auto.sh" ] && ok "auto block extracted from hook.sh" || bad "auto block not found in hook.sh"
auto() { # auto VENDOR PRODUCT_NAME PRODUCT_VERSION -> the resulting DEVICE_MODEL
  rm -rf "$W/dmi"; mkdir -p "$W/dmi"
  printf '%s\n' "$1" > "$W/dmi/sys_vendor"; printf '%s\n' "$2" > "$W/dmi/product_name"; printf '%s\n' "$3" > "$W/dmi/product_version"
  DMI=$W/dmi sh -c 'log() { :; }; DEVICE_MODEL=auto; . "$1"; printf %s "$DEVICE_MODEL"' sh "$W/auto.sh"; }
chk_auto() { got=$(auto "$2" "$3" "$4"); [ "$got" = "$5" ] && ok "auto: $1 -> '$5'" || bad "auto: $1 gave '$got', expected '$5'"; }
chk_auto "Lenovo uses product_version" LENOVO 20XH005BUS "ThinkPad X13 Gen 2a" "ThinkPad X13 Gen 2a"
chk_auto "other vendors use product_name" "Dell Inc." "Latitude 5300" "" "Latitude 5300"
chk_auto "OEM placeholder -> Google default" "To Be Filled By O.E.M." "To Be Filled By O.E.M." "" ""
chk_auto "Default string -> Google default" "Default string" "Default string" "" ""
chk_auto "quotes and other unsafe characters dropped" "HP" "HP Laptop 14s-dq2xxx \"x\"'y'\$z" "" "HP Laptop 14s-dq2xxx xyz"
chk_auto "surrounding spaces trimmed" "ASUSTeK COMPUTER INC." "  Vivobook 15  " "" "Vivobook 15"

# the service that sets the Settings "Device name"
H=$ROOT/usb/hook.sh
grep -qF "settings put global device_name '\$DEVICE_MODEL'" "$H" && ok "hook: gbos_devname sets Settings.Global.device_name" || bad "hook: no device_name service"
grep -qF 'start gbos_devname' "$H" && ok "hook: gbos_devname is started" || bad "hook: gbos_devname never started"
sh -n "$H" && ok "sh -n hook.sh" || bad "syntax"

echo "$n checks, $fail failed"
[ $fail = 0 ] && echo DEVICE_MODEL_TEST_PASS
exit $fail
