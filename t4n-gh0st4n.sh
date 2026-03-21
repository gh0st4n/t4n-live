#!/bin/bash

set -eu

. ./lib.sh

PROGNAME=$(basename "$0")
ARCH=$(uname -m)
IMAGES="bspwm"
TRIPLET=
REPO=
DATE=$(date -u +%Y%m%d)

usage() {
	cat <<-EOH
	Usage: $PROGNAME [options ...] [-- t4n-live options ...]

	Wrapper script around t4n-gh0st4n.sh for several standard flavors of live images.
	Adds void-installer and other helpful utilities to the generated images.

	OPTIONS
	 -a <arch>     Set architecture (or platform) in the image
	 -b <variant>  One of bspwm(default: bspwm). May be specified multiple times
	 			   to build multiple variants.
	 -d <date>     Override the datestamp on the generated image (YYYYMMDD format)
	 -t <arch-date-variant>
	               Equivalent to setting -a, -b, and -d
	 -r <repo>     Use this XBPS repository. May be specified multiple times
	 -h            Show this help and exit
	 -V            Show version and exit

	Other options can be passed directly to t4n-live.sh by specifying them after the --.
	See t4n-gh0st4n.sh -h for more details.
	EOH
}

while getopts "a:b:d:t:hr:V" opt; do
case $opt in
    a) ARCH="$OPTARG";;
    b) IMAGES="$OPTARG";;
    d) DATE="$OPTARG";;
    r) REPO="-r $OPTARG $REPO";;
    t) TRIPLET="$OPTARG";;
    V) version; exit 0;;
    h) usage; exit 0;;
    *) usage >&2; exit 1;;
esac
done
shift $((OPTIND - 1))

INCLUDEDIR=$(mktemp -d)
trap "cleanup" INT TERM

cleanup() {
    rm -rf "$INCLUDEDIR"
}

include_installer() {
    if [ -x installer.sh ]; then
        MKLIVE_VERSION="$(PROGNAME='' version)"
        installer=$(mktemp)
        sed "s/@@MKLIVE_VERSION@@/${MKLIVE_VERSION}/" installer.sh > "$installer"
        install -Dm755 "$installer" "$INCLUDEDIR"/usr/bin/void-installer
        rm "$installer"
    else
        echo installer.sh not found >&2
        exit 1
    fi
}rtkit

setup_pipewire() {
    PKGS="$PKGS pipewire alsa-pipewire"
    case "$ARCH" in
        asahi*)
            PKGS="$PKGS asahi-audio"
            SERVICES="$SERVICES speakersafetyd"
            ;;
    esac
    mkdir -p "$INCLUDEDIR"/etc/xdg/autostart
    ln -sf /usr/share/applications/pipewire.desktop "$INCLUDEDIR"/etc/xdg/autostart/
    mkdir -p "$INCLUDEDIR"/etc/pipewire/pipewire.conf.d
    ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf "$INCLUDEDIR"/etc/pipewire/pipewire.conf.d/
    ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf "$INCLUDEDIR"/etc/pipewire/pipewire.conf.d/
    mkdir -p "$INCLUDEDIR"/etc/alsa/conf.d
    ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf "$INCLUDEDIR"/etc/alsa/conf.d
    ln -sf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf "$INCLUDEDIR"/etc/alsa/conf.d
}

include_cli() {
  mkdir -p "$INCLUDEDIR"/etc
  mkdir -p "$INCLUDEDIR"/etc/default
  mkdir -p "$INCLUDEDIR"/etc/runit
  mkdir -p "$INCLUDEDIR"/etc/skel
  mkdir -p "$INCLUDEDIR"/etc/polkit-1
  mkdir -p "$INCLUDEDIR"/etc/polkit-1/rules.d
  mkdir -p "$INCLUDEDIR"/root

  cp ./common/script/resolv.conf "$INCLUDEDIR"/etc/
  cp ./common/script/os-release "$INCLUDEDIR"/etc/
  cp ./common/script/grub "$INCLUDEDIR"/etc/default/
  cp ./common/script/.bashrc "$INCLUDEDIR"/etc/skel/
  cp ./common/script/root/.bashrc "$INCLUDEDIR"/root/
  cp ./common/script/polkit/20-networkmanager.rules "$INCLUDEDIR"/etc/polkit-1/rules.d

  cp -r ./common/script/runit/* "$INCLUDEDIR"/etc/runit/
  cat >> "$INCLUDEDIR"/etc/group <<EOF
audio:x:29:anon
video:x:44:anon
input:x:105:anon
disk:x:6:anon
wheel:x:10:anon
EOF
}

# include_bspwm() {}

build_variant() {
    variant="$1"
    shift
    IMG=t4n_os-live-${ARCH}-${DATE}-${variant}.iso

    # el-cheapo installer is unsupported on arm because arm doesn't install a kernel by default
    # and to work around that would add too much complexity to it
    # thus everyone should just do a chroot install anyways
    WANT_INSTALLER=no
    case "$ARCH" in
        x86_64*|i686*)
            GRUB_PKGS="grub-i386-efi grub-x86_64-efi"
            GFX_PKGS="xorg-video-drivers xf86-video-intel xf86-video-amdgpu xf86-video-ati"
            GFX_WL_PKGS="mesa-dri"
            WANT_INSTALLER=yes
            TARGET_ARCH="$ARCH"
            ;;
        aarch64*)
            GRUB_PKGS="grub-arm64-efi"
            GFX_PKGS="xorg-video-drivers"
            GFX_WL_PKGS="mesa-dri"
            TARGET_ARCH="$ARCH"
            ;;
        asahi*)
            GRUB_PKGS="asahi-base asahi-scripts grub-arm64-efi"
            GFX_PKGS="mesa-asahi-dri"
            GFX_WL_PKGS="mesa-asahi-dri"
            KERNEL_PKG="linux-asahi"
            TARGET_ARCH="aarch64${ARCH#asahi}"
            if [ "$variant" = xfce ]; then
                info_msg "xfce is not supported on asahi, switching to xfce-wayland"
                variant="xfce-wayland"
            fi
            ;;
    esac

    A11Y_PKGS="espeakup void-live-audio brltty"
    PKGS="dialog cryptsetup lvm2 mdadm void-docs-browse chrony $A11Y_PKGS $GRUB_PKGS"
    FILE_PKGS="tar xz gzip zstd zip unzip 7zip p7zip"
    FONTS="fontconfig font-misc-misc terminus-font dejavu-fonts-ttf"
    WAYLAND_PKGS="$GFX_WL_PKGS $FONTS orca"
    XORG_PKGS="$GFX_PKGS $FONTS xorg-fonts xorg-server xorg-apps xorg-minimal xorg-input-drivers setxkbmap xauth orca"

    SERVICES_PKGS="dbus NetworkManager polkitd elogind lightdm rtkit"
    SERVICES="sshd chronyd dbus NetworkManager polkitd elogind lightdm rtkit"

    BSPWM0="xorg xf86-input-libinput network-manager alacritty xfce4-terminal rofi dmenu polybar picom Thunar gvfs gvfs-mtp"
    BSPWM1="thunar-archive-plugin thunar-media-tags-plugin feh brightnessctl xss-lock betterlockscreen i3lock-color xrdb xdg-user-dirs polkit-gnome"
    BSPWM2="power-profiles-daemon lm_sensors htop btop fastfetch playerctl firefox chromium flameshot galculator geany timeshift xmirror lxappearance"
    BSPWM3="papirus-icon-theme gtk-engine-murrine arc-theme pipewire wireplumber libspa-bluetooth alsa-pipewire libjack-pipewire pavucontrol pamixer"
    BSPWM4="tree bat eza nano vi vim neovim git curl wget zenity tmux fzf ranger base-devel xtools"

    BSPWM="$BSWPM0 $BSWPM1 $BSWPM2 $BSWPM3 $BSPWM4"

    LIGHTDM_SESSION=''

    case $variant in
        bspwm)
            PKGS="$SERVICE_PKGS $PKGS $FILE_PKGS $BSPWM"
            CLI=yes
            BSPWM=yes

            SERVICES="$SERVICES"
        ;;
        *)
            >&2 echo "Unknown variant $variant"
            exit 1
        ;;
    esac

    if [ -n "$LIGHTDM_SESSION" ]; then
        mkdir -p "$INCLUDEDIR"/etc/lightdm
        echo "$LIGHTDM_SESSION" > "$INCLUDEDIR"/etc/lightdm/.session
        # needed to show the keyboard layout menu on the login screen
        cat <<- EOF > "$INCLUDEDIR"/etc/lightdm/lightdm-gtk-greeter.conf
[greeter]
indicators = ~host;~spacer;~clock;~spacer;~layout;~session;~a11y;~power
EOF
    fi

    if [ "$CLI" = yes ]; then
      include_cli
    fi

    if [ "$BSPWM" = yes ]; then
      include_bspwm
    fi

    if [ "$WANT_INSTALLER" = yes ]; then
        include_installer
    else
        mkdir -p "$INCLUDEDIR"/usr/bin
        printf "#!/bin/sh\necho 'void-installer is not supported on this live image'\n" > "$INCLUDEDIR"/usr/bin/void-installer
        chmod 755 "$INCLUDEDIR"/usr/bin/void-installer
    fi

    case "$variant" in
      base|server)
        echo -e "\033[0;31m[!]\033[0m Without Pipewire"
      ;;
      *)
        setup_pipewire
      ;;
    esac

    ./t4n-live.sh -a "$TARGET_ARCH" -o "$IMG" -p "$PKGS" -S "$SERVICES" -I "$INCLUDEDIR" \
        ${KERNEL_PKG:+-v $KERNEL_PKG} ${REPO} "$@"

	cleanup
}

if [ ! -x t4n-live.sh ]; then
    echo t4n-live.sh not found >&2
    exit 1
fi

if [ -n "$TRIPLET" ]; then
    IFS=: read -r ARCH DATE VARIANT _ < <( echo "$TRIPLET" | sed -Ee 's/^(.+)-([0-9rc]+)-(.+)$/\1:\2:\3/' )
    build_variant "$VARIANT" "$@"
else
    for image in $IMAGES; do
        build_variant "$image" "$@"
    done
fi
