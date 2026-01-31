#!/usr/bin/env bash
# Включить периодический fstrim и (опционально) выполнить pacstrap без arch-chroot
# Usage:
#   ./enable-fstrim-and-pacstrap.sh [--no-fstrim] [--no-pacstrap] [--packages "pkg1 pkg2 ..."] [--interactive]
#
set -euo pipefail

TARGET="/mnt"                      # целевой корень установки
ENABLE_FSTRIM=1
DO_PACSTRAP=1
# По умолчанию добавлены sudo и nano:
PACSTRAP_PKGS=(base linux linux-firmware sudo nano)
PACSTRAP_NONINTERACTIVE=1

print_usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --no-fstrim           не включать fstrim.timer
  --no-pacstrap         не запускать pacstrap
  --packages "a b c"    список пакетов для pacstrap (по умолчанию: ${PACSTRAP_PKGS[*]})
  --interactive         НЕ использовать --noconfirm при pacstrap
  -h, --help            показать это сообщение
EOF
}

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --no-fstrim) ENABLE_FSTRIM=0; shift ;;
    --no-pacstrap) DO_PACSTRAP=0; shift ;;
    --packages) shift; PACSTRAP_PKGS=($1); shift ;;
    --interactive) PACSTRAP_NONINTERACTIVE=0; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "Unknown arg: $1"; print_usage; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите скрипт от root."
  exit 1
fi

if [ ! -d "$TARGET" ]; then
  echo "Целевой каталог $TARGET не найден."
  exit 1
fi

if ! mountpoint -q "$TARGET"; then
  echo "ОШИБКА: $TARGET не смонтирован. Смонтируйте корень установки (subvol=@) в $TARGET и повторите."
  exit 1
fi

echo "Цель: $TARGET"
echo "Опции: enable_fstrim=$ENABLE_FSTRIM, do_pacstrap=$DO_PACSTRAP, pacstrap_pkgs=${PACSTRAP_PKGS[*]}, pacstrap_noconfirm=$PACSTRAP_NONINTERACTIVE"
echo

# --------- Включение fstrim.timer в целевой системе ----------
enable_fstrim_in_target() {
  echo "==> Включение fstrim.timer для системы в $TARGET ..."

  # Попытка 1: systemctl --root (если поддерживается)
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --version >/dev/null 2>&1; then
      if systemctl --root="$TARGET" enable fstrim.timer >/dev/null 2>&1; then
        echo "systemctl --root успешно включил fstrim.timer"
        return 0
      else
        echo "systemctl --root не удалось; пробую ручную установку ссылок..."
      fi
    fi
  fi

  # Попытка 2: создать вручную ссылку в /etc/systemd/system/...wants
  UNIT_CANDIDATES=("$TARGET/usr/lib/systemd/system/fstrim.timer" "$TARGET/lib/systemd/system/fstrim.timer" "$TARGET/etc/systemd/system/fstrim.timer")
  UNIT_FOUND=""
  for u in "${UNIT_CANDIDATES[@]}"; do
    if [ -f "$u" ]; then
      UNIT_FOUND="$u"
      break
    fi
  done

  if [ -z "$UNIT_FOUND" ]; then
    echo "ОШИБКА: unit-файл fstrim.timer не найден в $TARGET (ищено: ${UNIT_CANDIDATES[*]})."
    echo "Убедитесь, что пакет systemd присутствует в целевой системе (pacstrap должен установить его)."
    return 1
  fi

  WANTS_DIR="$TARGET/etc/systemd/system/multi-user.target.wants"
  mkdir -p "$WANTS_DIR"

  if [[ "$UNIT_FOUND" == "$TARGET/"* ]]; then
    REL_PATH="${UNIT_FOUND#${TARGET}}"
  else
    REL_PATH="/usr/lib/systemd/system/fstrim.timer"
  fi

  ln -sf "$REL_PATH" "$WANTS_DIR/fstrim.timer"
  echo "Создан символьный линк: $WANTS_DIR/fstrim.timer -> $REL_PATH"
  echo "fstrim.timer включён (через создание ссылки)."
  return 0
}

# --------- Выполнение pacstrap (без chroot) ----------
run_pacstrap() {
  echo "==> Выполнение pacstrap в $TARGET ..."
  if ! command -v pacstrap >/dev/null 2>&1; then
    echo "ОШИБКА: pacstrap не найден в live-окружении. Установите arch-install-scripts."
    return 1
  fi

  # Проверка сети (не жёсткая)
  if ! ping -c1 -W1 archlinux.org >/dev/null 2>&1; then
    echo "Предупреждение: нет ответа от archlinux.org. Убедитесь, что сеть доступна для загрузки пакетов."
  fi

  PKG_ARGS=("${PACSTRAP_PKGS[@]}")
  if [ "$PACSTRAP_NONINTERACTIVE" -eq 1 ]; then
    pacstrap "$TARGET" "${PKG_ARGS[@]}" --noconfirm
  else
    pacstrap "$TARGET" "${PKG_ARGS[@]}"
  fi

  echo "pacstrap завершён."
}

# Main
if [ "$ENABLE_FSTRIM" -eq 1 ]; then
  if ! enable_fstrim_in_target; then
    echo "Не удалось включить fstrim.timer автоматически."
    echo "Проверьте вручную: systemctl --root=$TARGET enable fstrim.timer или создайте ссылку в $TARGET/etc/systemd/system/multi-user.target.wants/"
  fi
fi

if [ "$DO_PACSTRAP" -eq 1 ]; then
  if ! run_pacstrap; then
    echo "pacstrap не выполнён."
    exit 1
  fi
fi

echo
echo "Готово."
echo "Проверьте /etc/fstab в $TARGET и, при необходимости, выполните arch-chroot $TARGET для дальнейшей ручной настройки."
