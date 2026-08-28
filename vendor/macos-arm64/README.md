# Переносимый VPN runtime

Каталог содержит runtime для Mac с Apple Silicon и macOS 26 или новее. Для
работы не нужны Homebrew, Docker, системные расширения или права
администратора.

Исполняемые файлы используют только библиотеки из `../lib` и системные
фреймворки macOS. Относительные пути загрузки можно проверить командой:

```bash
otool -L bin/openconnect bin/ocproxy lib/*.dylib
```

Целостность проверяется перед каждым подключением:

```bash
shasum -a 256 -c CHECKSUMS.sha256
```

## Компоненты

| Компонент | Версия | Источник |
| --- | --- | --- |
| OpenConnect | 9.21 | <https://www.infradead.org/openconnect/> |
| ocproxy | 1.60 | <https://github.com/cernekee/ocproxy> |
| GnuTLS | 3.8.13 | <https://www.gnutls.org/> |
| p11-kit | 0.26.5 | <https://p11-glue.github.io/p11-glue/p11-kit.html> |
| Nettle | 4.0 | <https://www.lysator.liu.se/~nisse/nettle/> |
| GMP | 6.3.0 | <https://gmplib.org/> |
| GNU gettext | 1.0 | <https://www.gnu.org/software/gettext/> |
| libidn2 | 2.3.8 | <https://www.gnu.org/software/libidn/> |
| libunistring | 1.4.2 | <https://www.gnu.org/software/libunistring/> |
| libtasn1 | 4.21.0 | <https://www.gnu.org/software/libtasn1/> |
| libevent | 2.1.13 | <https://libevent.org/> |
| stoken | 0.93 | <https://stoken.sourceforge.io/> |
| LibTomCrypt | 1.18.2 | <https://www.libtom.net/LibTomCrypt/> |
| LibTomMath | 1.3.0 | <https://www.libtom.net/LibTomMath/> |

Тексты лицензий находятся в `licenses/`.
