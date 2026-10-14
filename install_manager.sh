#!/usr/bin/env bash
# 모델 관리 페이지만 설치/재설치한다 (update.sh 7단계와 동일). 관리 페이지와 모델은 wyhil 계정으로 실행된다.
# 반입 묶음 폴더(model_manager/ 가 있는 곳)에 두고 sudo 권한이 있는 계정으로 실행:
#
#   bash install_manager.sh [운영폴더] [포트]      # 기본값: /home/wyhil/biomodels_was 35000
#   RUN_USER=다른계정 bash install_manager.sh       # 실행 계정을 바꿀 때
#
# 다시 실행해도 안전하다 (기존 설정·등록한 모델·비밀번호 유지).
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${1:-/home/wyhil/biomodels_was}"
PORT="${2:-35000}"
RUN_USER="${RUN_USER:-wyhil}"
SERVICE=biomodels-model-manager
MANAGER_DIR="$APP_DIR/model_manager"
CONFIG="$MANAGER_DIR/model_manager.json"

fail() { printf '\n[중단] %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
id "$RUN_USER" >/dev/null 2>&1 || fail "$RUN_USER 계정이 없습니다."
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
as_run_user() { if [ "$(id -un)" = "$RUN_USER" ]; then "$@"; else sudo -u "$RUN_USER" "$@"; fi; }

[ -d "$APP_DIR" ] || fail "운영폴더가 없습니다: $APP_DIR"
[ -f "$BUNDLE_DIR/model_manager/model_manager.py" ] || fail "$BUNDLE_DIR/model_manager/model_manager.py 가 없습니다. 묶음 폴더 안에서 실행하세요."
command -v python3 >/dev/null || fail "python3가 없습니다."
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || fail "python3 3.8 이상이 필요합니다."
command -v systemctl >/dev/null || fail "systemd가 없는 서버입니다."
[ -z "$SUDO" ] || command -v sudo >/dev/null || fail "sudo가 필요합니다."

echo "==== 1/5 파일 복사 ($MANAGER_DIR, 실행 계정 $RUN_USER)"
$SUDO mkdir -p "$MANAGER_DIR/static"
$SUDO cp "$BUNDLE_DIR/model_manager/model_manager.py" "$BUNDLE_DIR/model_manager/README.md" "$MANAGER_DIR/"
$SUDO cp "$BUNDLE_DIR/model_manager/static/"* "$MANAGER_DIR/static/"
$SUDO chown -R "$RUN_USER" "$MANAGER_DIR"
as_run_user test -r "$MANAGER_DIR/model_manager.py" \
  || fail "$RUN_USER 계정이 $MANAGER_DIR 에 접근할 수 없습니다. 상위 폴더 권한을 확인하세요 (예: sudo chmod o+x $(dirname "$APP_DIR") $APP_DIR)"

echo "==== 2/5 설정"
if [ -f "$CONFIG" ]; then
  echo "  기존 설정 유지: $CONFIG"
else
  as_run_user python3 - "$CONFIG" "$PORT" "$RUN_HOME" <<'PY'
import json, sys
path, port, home = sys.argv[1], int(sys.argv[2]), sys.argv[3]
config = {"bind": "0.0.0.0", "port": port, "session_hours": 12, "log_dir": "logs", "state_dir": "state",
          "allowed_script_dirs": [home], "models": {}}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(config, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
  echo "  설정 생성: $CONFIG (스크립트 허용 폴더: $RUN_HOME)"
fi
PORT="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["port"])' "$CONFIG")"

echo "==== 3/5 비밀번호"
if [ -f "$MANAGER_DIR/auth.json" ]; then
  echo "  기존 비밀번호 유지 (바꾸려면: sudo -u $RUN_USER python3 $MANAGER_DIR/model_manager.py --config $CONFIG --set-password)"
else
  echo "  관리 페이지 비밀번호를 정하세요 (8자 이상, 화면에 표시되지 않음)."
  until as_run_user python3 "$MANAGER_DIR/model_manager.py" --config "$CONFIG" --set-password; do
    echo "  다시 입력하세요."
  done
fi

echo "==== 4/5 서비스 등록 ($SERVICE, User=$RUN_USER)"
UNIT="$(mktemp)"
cat > "$UNIT" <<EOF
[Unit]
Description=BioModels model manager
After=network-online.target docker.service

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$MANAGER_DIR
ExecStart=$(command -v python3) $MANAGER_DIR/model_manager.py --config $CONFIG
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
$SUDO install -m 644 "$UNIT" "/etc/systemd/system/$SERVICE.service"
rm -f "$UNIT"
$SUDO systemctl daemon-reload
$SUDO systemctl enable "$SERVICE" >/dev/null 2>&1
$SUDO systemctl restart "$SERVICE"

echo "==== 5/5 확인"
ok=0
for _ in $(seq 1 15); do
  if curl -s --noproxy '*' -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q 200; then ok=1; break; fi
  sleep 1
done
if [ "$ok" -ne 1 ]; then
  $SUDO systemctl status "$SERVICE" --no-pager || true
  fail "응답이 없습니다. journalctl -u $SERVICE -n 50 을 확인하세요."
fi
echo "  실행 중 (재부팅 시 자동 시작)"

if command -v ufw >/dev/null && $SUDO ufw status 2>/dev/null | grep -q 'Status: active'; then
  $SUDO ufw allow "$PORT/tcp" >/dev/null && echo "  방화벽(ufw): $PORT/tcp 허용"
elif command -v firewall-cmd >/dev/null && $SUDO firewall-cmd --state >/dev/null 2>&1; then
  $SUDO firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null && $SUDO firewall-cmd --reload >/dev/null && echo "  방화벽(firewalld): $PORT/tcp 허용"
fi

if [ "$RUN_USER" != root ] && ! id -nG "$RUN_USER" | grep -qw docker; then
  echo "  [주의] $RUN_USER 가 docker 그룹이 아니라 Evo2 20B/40B를 켜고 끌 수 없습니다: sudo usermod -aG docker $RUN_USER 후 sudo systemctl restart $SERVICE"
fi

echo
echo "==== 완료: http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT  (로그인 후 '+ 모델 추가')"
