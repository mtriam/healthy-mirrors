# Maintainer: mtriam <265996944+mtriam@users.noreply.github.com>

pkgname=healthy-mirrors-git
_pkgname=healthy-mirrors
pkgver=r0.0000000
pkgrel=1
pkgdesc='Keeps only healthy mirrors active in the CachyOS/Arch Linux mirrorlists, with an optional pacman guard daemon'
arch=('any')
url='https://github.com/mtriam/healthy-mirrors'
license=('GPL-3.0-or-later')
depends=(
    'bash' 'coreutils' 'curl' 'diffutils' 'findutils' 'gawk' 'grep' 'jq'
    'python' 'sed' 'sudo' 'systemd' 'util-linux'
)
makedepends=('git')
optdepends=('libnotify: desktop notifications on errors')
provides=("$_pkgname")
conflicts=("$_pkgname")
install="$_pkgname.install"
source=("git+$url.git")
sha256sums=('SKIP')

pkgver() {
    cd "$_pkgname"
    printf 'r%s.%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

check() {
    cd "$_pkgname"
    local f
    for f in hm hm-setup install.sh; do bash -n "$f"; done
    python -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' hm-daemon
}

package() {
    cd "$_pkgname"
    install -Dm755 hm        "$pkgdir/usr/bin/hm"
    install -Dm755 hm-daemon "$pkgdir/usr/bin/hm-daemon"
    install -Dm755 hm-setup  "$pkgdir/usr/bin/hm-setup"
    install -Dm644 hm-daemon.service "$pkgdir/usr/lib/systemd/system/hm-daemon.service"
    install -Dm644 README.md "$pkgdir/usr/share/doc/$_pkgname/README.md"
}
