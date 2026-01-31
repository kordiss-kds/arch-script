#!/usr/bin/env bash
# Скрипт для Arch Linux
# Разметка /dev/nvme0n1: 2GiB EFI, остальное btrfs + создание subvolumes
# Subvolume-ы: @, @home, @root, @srv, @cache, @tmp, @log
# Автор: адаптирован для пользователя
set -euo pipefail

# --- НАСТРОЙКИ ---
DEVICE="/dev/nvme0n1"        # <- проверьте и замените при необходимости
EFI_SIZE="2GiB"              # размер EFI раздела
LABEL_BTRFS="arch_btrfs"
# Опции монтирования:
MOUNT_OPTS="defaults,noatime,compress=zstd:3,space_cache=v2"
# --------------------

if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите от root."
  exit 1
fi

if [ ! -b "$DEVICE" ]; then
  echo "Устройство $DEVICE не найдено."
  exit 1
fi

read -rp "ВНИМАНИЕ: Будет уничтожено всё на $DEVICE. Продолжить? (yes/NO): " CONF
if [ "$CONF" != "yes" ]; then
  echo "Отмена."
  exit 1
fi

# вычисляем имена разделов (nvme -> p1, обычные — 1)
if [[ "$DEVICE" =~ nvme ]]; then
  EFI_PART="${DEVICE}p1"
  BTRFS_PART="${DEVICE}p2"
else
  EFI_PART="${DEVICE}1"
  BTRFS_PART="${DEVICE}2"
fi

echo "1) Удаляю старые таблицы и создаю GPT..."
sgdisk --zap-all "$DEVICE"

parted -s "$DEVICE" mklabel gpt \
  mkpart primary fat32 1MiB "${EFI_SIZE}" \
  mkpart primary btrfs "${EFI_SIZE}" 100% \
  set 1 boot on

partprobe "$DEVICE" || true
sleep 1

echo "2) Форматирую разделы..."
wipefs -af "$EFI_PART" || true
wipefs -af "$BTRFS_PART" || true

mkfs.fat -F32 -n EFI "$EFI_PART"
mkfs.btrfs -f -L "$LABEL_BTRFS" "$BTRFS_PART"

echo "3) Монтирую Btrfs временно и создаю subvolumes..."
# не удаляем /mnt, если она используется; удаление старого /mnt оставлено по логике установки,
# но будьте внимательны: если вы работаете не в live-окружении, это может быть опасно.
rm -rf /mnt 2>/dev/null || true
mkdir -p /mnt
mount "$BTRFS_PART" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@root
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@log

echo "4) Отмонтирую и смонтирую subvolume=@ как корень (/mnt) с опциями..."
umount /mnt || true

mkdir -p /mnt
mount -o "subvol=@,${MOUNT_OPTS}" "$BTRFS_PART" /mnt

# создаём каталоги для остальных точек монтирования
mkdir -p /mnt/{home,root,srv,boot,var}
mkdir -p /mnt/var/{cache,tmp,log}

# монтируем остальные subvolume-ы с указанными опциями
mount -o "subvol=@home,${MOUNT_OPTS}" "$BTRFS_PART" /mnt/home
mount -o "subvol=@root,${MOUNT_OPTS}" "$BTRFS_PART" /mnt/root
mount -o "subvol=@srv,${MOUNT_OPTS}" "$BTRFS_PART" /mnt/srv
mount -o "subvol=@cache,${MOUNT_OPTS}" "$BTRFS_PART" /mnt/var/cache
mount -o "subvol=@tmp,${MOUNT_OPTS}" "$BTRFS_PART" /mnt/var/tmp
mount -o "subvol=@log,${MOUNT_OPTS}" "$BTRFS_PART" /mnt/var/log

echo "5) Монтирую EFI"
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# ---- НОВЫЙ БЛОК: проверки перед genfstab ----
echo "Проверяю, что /mnt смонтирован и готов для genfstab..."
if ! mountpoint -q /mnt; then
  echo "ОШИБКА: /mnt не смонтирован. Проверьте шаги монтирования."
  exit 1
fi

# создаём /mnt/etc если ещё не существует (перенаправление не создаёт родительские каталоги)
mkdir -p /mnt/etc

# проверяем genfstab и при возможности устанавливаем пакет arch-install-scripts через pacman
if ! command -v genfstab >/dev/null 2>&1; then
  echo "genfstab (arch-install-scripts) не найден."
  if command -v pacman >/dev/null 2>&1; then
    echo "Пытаюсь установить arch-install-scripts через pacman..."
    pacman -Sy --noconfirm arch-install-scripts || { echo "Не удалось установить arch-install-scripts"; exit 1; }
  else
    echo "pacman недоступен — установите arch-install-scripts вручную в live-окружении и повторите."
    exit 1
  fi
fi

echo "6) Генерирую /etc/fstab (genfstab) — сохраню в /mnt/etc/fstab"
genfstab -U /mnt > /mnt/etc/fstab

echo
echo "Готово. Краткие рекомендации:"
cat <<'EOF'
- Проверьте /mnt/etc/fstab и при необходимости отредактируйте опции.
- Для NVMe рекомендуется включить периодический fstrim (systemd fstrim.timer).
- Если хотите, могу дополнить скрипт, чтобы он автоматически выполнял:
    - pacstrap (установку base пакетов)
    - arch-chroot и базовую настройку загрузчика (systemd-boot/GRUB)
  Скажите, нужно ли добавить эти шаги.
EOF

echo
echo "Скрипт завершён успешно."
