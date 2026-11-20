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
| ocproxy | 1.60 + RESOLVE | <https://github.com/cernekee/ocproxy> |
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

## Локальная доработка ocproxy

К исходному ocproxy 1.60, commit `88b1087f6ab2c860c8729478643e081b6e97f6d3`,
применён [патч RESOLVE](../ocproxy/resolve.patch). Команда SOCKS5 `0xF0`
принимает hostname и возвращает один IPv4 из того же DNS resolver lwIP,
который обслуживает обычный SOCKS CONNECT. Она не подключается к целевому
серверу. Команда доступна только через существующий VPN SOCKS5; системные DNS,
маршруты и настройки proxy не меняются. Поддержка AAAA и обратных запросов
не добавлена.

Для пересборки только ocproxy на macOS arm64 нужны Command Line Tools,
Python для сборочного помощника и уже установленные заголовки libevent.
Библиотека берётся из этого runtime, новые зависимости не устанавливаются:

```bash
bash scripts/build-ocproxy-runtime.sh
python3 scripts/test-ocproxy-resolve.py --ocproxy run/ocproxy-build/runtime/bin/ocproxy
```

Команды выполняются из корня проекта. По умолчанию заголовки ищутся в
`/opt/homebrew/opt/libevent/include`; другой существующий путь можно передать
через `BCS_LIBEVENT_INCLUDE_DIRECTORY`. Homebrew не нужен для работы приложения.
Архив исходников закреплён commit и SHA-256. Загруженные build-скрипты не
исполняются: C-файлы компилируются непосредственно в sandbox без сети,
пользовательского окружения и доступа к пользовательским файлам. Предупреждения
старого upstream-кода не подавляются. Результат остаётся в `run/ocproxy-build`:
скрипт не заменяет ни этот runtime, ни установленное приложение.
