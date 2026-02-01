#!/usr/bin/env bash
# Выполнить внутри arch-chroot /mnt
# Настройка времени, локалей, клавиатуры, hostname, NetworkManager, паролей, пользователя, zram, swap-файл, snapper и grub-btrfs
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите скрипт от root внутри chroot (arch-chroot /mnt)"
  exit 1
fi

read_tz() {
  while true; do
    read -rp $'1) Укажите часовой пояс (пример: Europe/Moscow): ' TZINPUT
    if [ -z "$TZINPUT" ]; then
      echo "Часовой пояс не указан, попробуйте снова."
      continue
    fi
    if [ -f "/usr/share/zoneinfo/$TZINPUT" ]; then
      ln -sf "/usr/share/zoneinfo/$TZINPUT" /etc/localtime
      hwclock --systohc
      echo "Часовой пояс установлен: $TZINPUT"
      break
    else
      echo "Путь /usr/share/zoneinfo/$TZINPUT не найден. Попробуйте ещё раз."
    fi
  done
}

setup_locales() {
  echo
  echo "2) Настройка локалей (en_US.UTF-8, ru_RU.UTF-8)..."
  grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
  grep -q '^ru_RU.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null || echo 'ru_RU.UTF-8 UTF-8' >> /etc/locale.gen

  locale-gen

  echo 'LANG=en_US.UTF-8' > /etc/locale.conf
  export LANG=en_US.UTF-8
  echo "Локали сгенерированы, LANG установлен в en_US.UTF-8"
}

setup_keyboard() {
  echo
  echo "3) Настройка клавиатуры: переключение раскладки Alt+Shift для X11 и консольной раскладки"
  echo "KEYMAP=us" > /etc/vconsole.conf

  mkdir -p /etc/X11/xorg.conf.d
  cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<'XKB'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbModel" "pc105"
    Option "XkbLayout" "us,ru"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
XKB

  if command -v localectl >/dev/null 2>&1; then
    localectl set-keymap us || true
    localectl set-x11-keymap "us,ru" "pc105" "" "grp:alt_shift_toggle" || true
  fi

  echo "Клавиатура настроена (X11: us,ru; переключение: Alt+Shift). Консоль: us."
}

set_hostname_and_hosts() {
  echo
  echo "4) Задать имя хоста и прописать /etc/hosts"
  while true; do
    read -rp $'Введите имя хоста (hostname) без пробелов, например myhost: ' HOSTNAME_INPUT
    if [ -z "$HOSTNAME_INPUT" ]; then
      echo "Имя хоста не может быть пустым."
      continue
    fi
    if [[ "$HOSTNAME_INPUT" =~ ^[a-zA-Z0-9][-a-zA-Z0-9]*$ ]]; then
      echo "$HOSTNAME_INPUT" > /etc/hostname
      cat > /etc/hosts <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	${HOSTNAME_INPUT}.localdomain	${HOSTNAME_INPUT}
EOF
      echo "Hostname установлен: $HOSTNAME_INPUT"
      break
    else
      echo "Недопустимое имя хоста. Разрешены a-z A-Z 0-9 и дефис. Попробуйте снова."
    fi
  done
}

enable_networkmanager() {
  echo
  echo "5) Включение и запуск NetworkManager (enable)..."
  if ! pacman -Qi networkmanager >/dev/null 2>&1; then
    echo "Пакет NetworkManager не установлен. Устанавливаю..."
    pacman -Sy --noconfirm networkmanager || { echo "Не удалось установить NetworkManager"; return 1; }
  fi

  # enable (в chroot enable создаст ссылки в /etc, start в chroot может не выполняться корректно)
  systemctl enable NetworkManager.service || true
  echo "NetworkManager помечен как enabled (проверьте systemctl enable), запуск можно выполнить после первой загрузки."
}

set_root_password() {
  echo
  echo "6) Задать пароль для root"
  while true; do
    read -rsp "Введите пароль root: " PASS1
    echo
    read -rsp "Повторите пароль root: " PASS2
    echo
    if [ "$PASS1" != "$PASS2" ]; then
      echo "Пароли не совпали, попробуйте снова."
      continue
    fi
    if [ -z "$PASS1" ]; then
      echo "Пустой пароль не разрешён, попробуйте снова."
      continue
    fi
    echo "root:$PASS1" | chpasswd
    echo "Пароль root задан."
    break
  done
}

create_user() {
  echo
  echo "7) Создание пользователя и назначение пароля"
  while true; do
    read -rp $'Введите имя пользователя (пример: alice): ' NEWUSER
    if [ -z "$NEWUSER" ]; then
      echo "Имя пользователя не может быть пустым."
      continue
    fi
    if id -u "$NEWUSER" >/dev/null 2>&1; then
      echo "Пользователь '$NEWUSER' уже существует. Введите другое имя или повторите."
      continue
    fi
    break
  done

  read -rp $'Добавить пользователя в группу wheel (для sudo)? [Y/n]: ' ADDWHEEL
  ADDWHEEL=${ADDWHEEL:-Y}

  if [[ "$ADDWHEEL" =~ ^([yY]|)$ ]]; then
    useradd -m -G wheel -s /bin/bash "$NEWUSER"
  else
    useradd -m -s /bin/bash "$NEWUSER"
  fi

  while true; do
    read -rsp "Введите пароль для $NEWUSER: " UP1
    echo
    read -rsp "Повторите пароль для $NEWUSER: " UP2
    echo
    if [ "$UP1" != "$UP2" ]; then
      echo "Пароли не совпали, попробуйте снова."
      continue
    fi
    if [ -z "$UP1" ]; then
      echo "Пустой пароль не разрешён, попробуйте снова."
      continue
    fi
    echo "$NEWUSER:$UP1" | chpasswd
    echo "Пароль для $NEWUSER установлен."
    break
  done

  if ! pacman -Qi sudo >/dev/null 2>&1; then
    echo "Пакет sudo не установлен. Устанавливаю..."
    pacman -Sy --noconfirm sudo || echo "Не удалось установить sudo; проверьте сеть и репозитории"
  fi

  # Раскомментируем %wheel ALL=(ALL) ALL в /etc/sudoers, если есть
  if grep -q '^[#[:space:]]*%wheel\s\+ALL=(ALL:ALL)\s\+ALL' /etc/sudoers 2>/dev/null; then
    sed -i 's/^[#[:space:]]*\(%wheel\s\+ALL=(ALL:ALL)\s\+ALL\)/\1/' /etc/sudoers || true
  else
    sed -i 's/^[#[:space:]]*\(%wheel\s\+ALL=(ALL)\s\+ALL\)/\1/' /etc/sudoers || true
  fi

  echo "Пользователь $NEWUSER создан. Добавлен в wheel: ${ADDWHEEL}"
}

configure_pacman_parallel() {
  echo
  echo "Настройка /etc/pacman.conf: ParallelDownloads = 5"

  local cf=/etc/pacman.conf
  if [ ! -f "$cf" ]; then
    echo "Файл $cf не найден! Пропускаю настройку pacman.conf."
    return 1
  fi

  cp -a "$cf" "${cf}.backup.$(date +%s)"

  if grep -qi '^[#[:space:]]*ParallelDownloads' "$cf"; then
    sed -i 's/^[#[:space:]]*ParallelDownloads.*/ParallelDownloads = 5/i' "$cf"
  else
    # вставим сразу после [options]
    awk -v add="ParallelDownloads = 5" '
      BEGIN{added=0}
      { print }
      /^\[options\]/{ print add; added=1; next }
      END{ if(!added) print "\n[options]\nParallelDownloads = 5" }
    ' "$cf" > "${cf}.tmp" && mv "${cf}.tmp" "$cf"
  fi

  echo "pacman.conf сконфигурирован (ParallelDownloads = 5). Резервная копия создана."
}

# ---------------- zram + swap ----------------
configure_zram_and_swap() {
  echo
  echo "8) Установка и настройка zram (zram-generator) и swap-файла"

  # Установим необходимые пакеты
  PKGS=(zram-generator lz4)
  for p in "${PKGS[@]}"; do
    if ! pacman -Qi "$p" >/dev/null 2>&1; then
      echo "Устанавливаю $p..."
      pacman -Sy --noconfirm "$p" || { echo "Не удалось установить $p"; return 1; }
    fi
  done

  # Настройка zram-generator (8G)
  cat > /etc/systemd/zram-generator.conf <<'ZCONF'
[zram0]
zram-size = 8G
compression-algorithm = lz4
swap-priority = 100
ZCONF
  echo "Создан /etc/systemd/zram-generator.conf (zram-size = 8G)."

  if systemctl list-unit-files | grep -q 'systemd-zram-setup@'; then
    systemctl daemon-reload || true
    systemctl enable systemd-zram-setup@zram0.service >/dev/null 2>&1 || true
    echo "Если возможен, systemd-zram-setup@zram0.service помечен как enabled."
  fi

  # Swap-file: спросим размер (по умолчанию 2G)
  while true; do
    read -rp $'Укажите размер swap-файла (пример 2G) [default: 2G]: ' SWAPSIZE
    SWAPSIZE=${SWAPSIZE:-2G}
    if [[ "$SWAPSIZE" =~ ^[0-9]+[GgMm]$ ]]; then
      break
    else
      echo "Неверный формат. Укажите вроде 2G или 512M."
    fi
  done

  SWAPFILE=/swapfile
  if [ -f "$SWAPFILE" ]; then
    echo "$SWAPFILE уже существует. Пропускаю создание, но включаю swapon."
  else
    echo "Создаю $SWAPFILE размером $SWAPSIZE..."
    if ! fallocate -l "$SWAPSIZE" "$SWAPFILE" >/dev/null 2>&1; then
      echo "fallocate не сработал, использую dd (может занять время)..."
      if [[ "$SWAPSIZE" =~ ^([0-9]+)[Gg]$ ]]; then
        MB=$(( ${BASH_REMATCH[1]} * 1024 ))
      else
        MB=$(( ${BASH_REMATCH[1]} ))
      fi
      dd if=/dev/zero of="$SWAPFILE" bs=1M count="$MB" status=progress
    fi
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
  fi

  swapon "$SWAPFILE" || echo "swapon вернул ошибку (возможно уже включен)."

  if ! grep -qF "$SWAPFILE" /etc/fstab 2>/dev/null; then
    echo "$SWAPFILE none swap defaults 0 0" >> /etc/fstab
    echo "Запись в /etc/fstab добавлена для $SWAPFILE."
  else
    echo "Запись для $SWAPFILE уже присутствует в /etc/fstab."
  fi

  cat > /etc/sysctl.d/99-swap.conf <<'SYS'
vm.swappiness=10
vm.vfs_cache_pressure=50
SYS
  echo "Создан /etc/sysctl.d/99-swap.conf (vm.swappiness=10)."
  echo "zram и swap-файл настроены. При первой загрузке zram-generator создаст /dev/zram0 и включит swap на нём."
}

# ---------------- snapper ----------------
configure_snapper() {
  echo
  echo "9) Установка и настройка snapper для Btrfs"

  # Установим snapper и btrfs-progs (обычно btrfs-progs уже установлен)
  PKGS=(snapper btrfs-progs)
  for p in "${PKGS[@]}"; do
    if ! pacman -Qi "$p" >/dev/null 2>&1; then
      echo "Устанавливаю $p..."
      pacman -Sy --noconfirm "$p" || { echo "Не удалось установить $p"; return 1; }
    fi
  done

  if snapper -c root get-config >/dev/null 2>&1; then
    echo "Конфиг snapper для 'root' уже существует. Пропускаю create-config."
  else
    snapper -c root create-config /
    echo "snapper config 'root' создан."
  fi

  systemctl enable snapper-timeline.timer >/dev/null 2>&1 || true
  systemctl enable snapper-cleanup.timer >/dev/null 2>&1 || true
  echo "Snapper таймеры помечены как enabled (snapper-timeline.timer, snapper-cleanup.timer)."

  echo "Проверьте /etc/snapper/configs/root и при необходимости отрегулируйте параметры (number, cleanup)."
}

# ---------------- grub-btrfs ----------------
configure_grub_btrfs() {
  echo
  echo "10) Установка и настройка grub-btrfs (генерация записей Grub для Btrfs snapshots)"

  if [ ! -d /boot ]; then
    echo "/boot не найден в chroot. Убедитесь, что /boot смонтирован и содержит загрузочные файлы (EFI или grub)."
    return 1
  fi
  if ! mountpoint -q /boot; then
    echo "Предупреждение: /boot не смонтирован. Продолжайте только если вы уверены, что /boot будет доступен при первой загрузке."
  fi

  if ! pacman -Qi grub >/dev/null 2>&1; then
    echo "Пакет grub не установлен. Устанавливаю grub и efibootmgr (если необходимо)..."
    pacman -Sy --noconfirm grub efibootmgr || { echo "Не удалось установить grub. Пропускаю grub-btrfs."; return 1; }
  fi

  if pacman -Qi grub-btrfs >/dev/null 2>&1; then
    echo "grub-btrfs уже установлен."
  else
    echo "Пакет grub-btrfs не найден в установленных пакетах."
    echo "Пробую установить grub-btrfs через репозитории..."
    if pacman -Sy --noconfirm grub-btrfs >/dev/null 2>&1; then
      echo "grub-btrfs установлен через pacman."
    else
      echo "grub-btrfs не доступен в репозитории. Попробую собрать из AUR (требуется git и base-devel)."

      if ! pacman -Qi base-devel >/dev/null 2>&1; then
        echo "Устанавливаю группу base-devel..."
        pacman -Sy --noconfirm --needed base-devel || { echo "Не удалось установить base-devel"; return 1; }
      fi
      if ! pacman -Qi git >/dev/null 2>&1; then
        echo "Устанавливаю git..."
        pacman -Sy --noconfirm --needed git || { echo "Не удалось установить git"; return 1; }
      fi

      TMPDIR=$(mktemp -d)
      echo "Клонирую AUR repo grub-btrfs в $TMPDIR..."
      if git clone https://aur.archlinux.org/grub-btrfs.git "$TMPDIR/grub-btrfs"; then
        pushd "$TMPDIR/grub-btrfs" >/dev/null
        echo "Собираю и устанавливаю пакет grub-btrfs через makepkg..."
        if makepkg -si --noconfirm; then
          echo "grub-btrfs успешно собран и установлен."
        else
          echo "Ошибка сборки/установки grub-btrfs и�� AUR."
          popd >/dev/null
          rm -rf "$TMPDIR"
          return 1
        fi
        popd >/dev/null
      else
        echo "Не удалось клонировать AUR репозиторий grub-btrfs."
        rm -rf "$TMPDIR"
        return 1
      fi
      rm -rf "$TMPDIR"
    fi
  fi

  if systemctl list-unit-files | grep -q 'grub-btrfs'; then
    echo "Включаю юниты grub-btrfs (если доступны)..."
    systemctl enable grub-btrfs.path >/dev/null 2>&1 || true
    systemctl enable grub-btrfs.service >/dev/null 2>&1 || true
  else
    if [ -f /usr/lib/systemd/system/grub-btrfs.path ] || [ -f /etc/systemd/system/grub-btrfs.path ]; then
      systemctl enable grub-btrfs.path >/dev/null 2>&1 || true
    fi
    if [ -f /usr/lib/systemd/system/grub-btrfs.service ] || [ -f /etc/systemd/system/grub-btrfs.service ]; then
      systemctl enable grub-btrfs.service >/dev/null 2>&1 || true
    fi
  fi

  if command -v grub-mkconfig >/dev/null 2>&1; then
    GRUBCFG="/boot/grub/grub.cfg"
    echo "Генерирую $GRUBCFG..."
    grub-mkconfig -o "$GRUBCFG" || echo "grub-mkconfig завершился с ошибкой. Проверьте вручную."
  else
    echo "grub-mkconfig не найден — пропускаю генерацию grub.cfg. После первой загрузки выполните grub-mkconfig -o /boot/grub/grub.cfg"
  fi

  echo "Настройка grub-btrfs завершена. Проверьте, что /boot содержит grub и что grub-btrfs/*.timer/path/service присутствуют."
}

main() {
  echo "=== Скрипт настройки внутри chroot ==="
  read_tz
  setup_locales
  setup_keyboard
  set_hostname_and_hosts
  enable_networkmanager
  set_root_password
  create_user
  configure_pacman_parallel
  configure_zram_and_swap
  configure_snapper
  configure_grub_btrfs
  echo
  echo "Настройка завершена."
  echo "Проверьте /etc/locale.conf, /etc/hosts, /etc/sudoers, /etc/pacman.conf, /etc/fstab и конфиги snapper."
  echo "Когда всё готово: exit chroot и перезагрузите систему."
}

main "$@"
