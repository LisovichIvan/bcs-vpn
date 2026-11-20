# Настройка BCS VPN через ProxyBridge на macOS

Инструкция проверена для ProxyBridge 4.0.0. Готовый профиль находится в
[`proxybridge/BCS-VPN.pbprofile`](proxybridge/BCS-VPN.pbprofile).

## Что было проверено

- Установлен `/Applications/ProxyBridge.app`, версия 4.0.0.
- Системное расширение `com.interceptsuite.ProxyBridge.extension` включено и
  активно.
- `BCS VPN.app` имеет bundle identifier `com.bcs.vpn`, исполняемый файл —
  `bcs-vpn`.
- Локальный fallback SOCKS5 приложения слушает `127.0.0.1:8889`.
- В текущих настройках BCS VPN используется шлюз `fwm.bcs.ru`, который сейчас
  разрешается в `193.142.57.165`. В профиль также внесён старый шлюз
  `fw2.bcs.ru` / `193.142.56.141`.
- ProxyBridge применяет правила сверху вниз; первое подходящее правило побеждает.
  Если ни одно правило не совпало, соединение идёт напрямую.
- На macOS фильтры адреса и порта применяются только к TCP. Поэтому профиль не
  отправляет UDP в SOCKS5: fallback-прокси BCS предназначен для TCP CONNECT.

Источники по поведению ProxyBridge:

- [официальная документация macOS](https://interceptsuite.com/docs/proxybridge/configuration-macos/);
- [исходный код и описание macOS](https://github.com/InterceptSuite/ProxyBridge/blob/master/MacOS/README.md).

## Рекомендуемый способ: импорт готового профиля

1. Запустите **BCS VPN.app**. Даже до подключения оно должно открыть
   `127.0.0.1:8889`.
2. Откройте **ProxyBridge**.
3. В верхнем меню macOS выберите **Profile → Import Profile…** (не
   **Proxy → Proxy Rules → Import**).
4. Выберите файл:

   ```text
   /Users/admin/Documents/githab/bcs-vpn/proxybridge/BCS-VPN.json
   ```

   В ProxyBridge 4.0.0 файл с расширением `.pbprofile` иногда отображается
   неактивным из-за регистрации типа файла в macOS. JSON-копия имеет то же
   содержимое и поддерживается диалогом импорта профиля.

5. ProxyBridge создаст и сразу активирует отдельный профиль **BCS VPN**. Старый
   профиль `Default` и его правила останутся сохранены.
6. Убедитесь, что в **Proxy → Proxy Settings…** появился сервер:

   ```text
   Name:     bcs-vpn
   Type:     SOCKS5
   Host:     127.0.0.1
   Port:     8889
   Username: пусто
   Password: пусто
   ```

7. Откройте **Proxy → Proxy Rules…** и проверьте порядок правил, приведённый ниже.
8. На главном экране ProxyBridge нажмите **Start Proxy**, если отображается
   `Proxy Stopped`. Состояние должно стать `Proxy Running`.
9. Подключите **BCS VPN.app**.

## Объединённый профиль BCS VPN + Tor

ProxyBridge активирует только один профиль за раз. Чтобы одновременно направлять
BCS через VPN, а Telegram через Tor, импортируйте файл
[`proxybridge/BCS-VPN-and-Tor.json`](proxybridge/BCS-VPN-and-Tor.json)
через **Profile → Import Profile…** и выберите профиль **BCS VPN + Tor**.

Он содержит оба локальных прокси:

```text
tor      → SOCKS5 127.0.0.1:9150
bcs-vpn  → SOCKS5 127.0.0.1:8889
```

Правило Telegram расположено выше общего правила BCS. Оно повторяет правило из
текущего профиля `Default`: процесс `Telegram`, весь TCP-трафик, действие `tor`.
Для его работы Tor Browser или другой Tor-сервис должен действительно слушать
`127.0.0.1:9150`. Проверить можно командой:

```bash
lsof -nP -iTCP:9150 -sTCP:LISTEN
```

Удалённый прокси `bcs-ai-vpn`, найденный в локальном профиле `Default`, в файл не
включён: его правило сейчас не используется, а экспорт сохранил бы логин и пароль
открытым текстом. Исходный профиль `Default` при импорте не изменяется.

## Правила и их точные значения

### 1. BCS VPN processes direct

Предотвращает цикл, при котором VPN и его локальные прокси пытаются подключаться
через самих себя.

```text
Process / Bundle Identifier: com.bcs.vpn;bcs-vpn;openconnect;ocproxy
Target Hosts:                *
Target Ports:                *
Protocol:                    BOTH
Action:                      DIRECT
Enabled:                     yes
```

### 2. Localhost direct

```text
Process / Bundle Identifier: *
Target Hosts:                127.0.0.1;::1
Target Ports:                *
Protocol:                    TCP
Action:                      DIRECT
Enabled:                     yes
```

### 3. BCS VPN gateways direct

Шлюз OpenConnect обязан обходить SOCKS5, иначе возникает цикл подключения.

```text
Process / Bundle Identifier: *
Target Hosts:                fwm.bcs.ru;193.142.57.165;fw2.bcs.ru;193.142.56.141
Target Ports:                *
Protocol:                    TCP
Action:                      DIRECT
Enabled:                     yes
```

### 4. NuGet Artifactory direct

```text
Process / Bundle Identifier: dotnet
Target Hosts:                artifactory.gitlab.bcs.ru;193.142.56.242
Target Ports:                *
Protocol:                    TCP
Action:                      DIRECT
Enabled:                     yes
```

Это исключение сохраняет прямой доступ `dotnet` к Artifactory и предотвращает
зависание множества параллельных NuGet-соединений.

### 5. BCS through VPN

В поле **Action** выберите прокси **bcs-vpn — SOCKS5 127.0.0.1:8889**.

```text
Process / Bundle Identifier: *
Target Hosts:                gitlab.gitlab.bcs.ru;artifactory.gitlab.bcs.ru;confluence.bcs.ru;jira.bcs.ru;apis.tusvc.bcs.ru;*.global.bcs;ef-syspass.tusvc.t-global.bcs;193.142.56.242;193.142.56.243;193.142.56.247;172.18.8.20;172.17.174.48
Target Ports:                *
Protocol:                    TCP
Action:                      bcs-vpn (SOCKS5 127.0.0.1:8889)
Enabled:                     yes
```

Правило `Default` не требуется: ProxyBridge отправляет несовпавшие соединения
напрямую. Не создавайте общее правило `* → bcs-vpn`, иначе весь трафик macOS
пойдёт через корпоративный VPN.

## Почему используется порт 8889, а не 8890

- `8889` — постоянный fallback SOCKS5, к которому подключается ProxyBridge.
- `8890` — внутренний SOCKS5 процесса `ocproxy`; он существует только во время
  активного VPN.
- Когда `8890` доступен, fallback на `8889` передаёт соединение в VPN.
- Когда VPN отключён, fallback пытается соединиться напрямую. Это не kill switch.

## Проверка

После подключения выполните из каталога проекта:

```bash
./scripts/check-vpn.sh confluence.bcs.ru
```

Ожидаемый результат начинается так:

```text
OpenConnect: запущен в пользовательском режиме
Fallback SOCKS5: 127.0.0.1:8889
VPN SOCKS5: 127.0.0.1:8890
```

Дополнительно откройте журнал соединений ProxyBridge. Для BCS-адреса действие
должно быть `SOCKS5 127.0.0.1:8889`, а для `fwm.bcs.ru`, процессов BCS VPN и
обычных интернет-сайтов — `Direct`.

## Ограничение доменных правил ProxyBridge

В macOS-версии ProxyBridge 4.1.3 расширение наблюдает ответы первоначального
DNS-запроса Mac и связывает IP с hostname. При включённых **Enable DNS**
(`dnsEnabled`) и **Let proxy resolve DNS (send hostname)**
(`proxyConfigs[].sendDomain`) SOCKS5 получает hostname, если он известен
расширению; иначе отправляется IP. Настройка `sendDomain` не отправляет сам
первоначальный DNS-запрос через SOCKS5.

Если локальный DNS возвращает `NXDOMAIN`, браузер не создаёт TCP-соединение,
которое ProxyBridge мог бы перенаправить. В этой версии нет встроенного fake IP
или пользовательской таблицы DNS mappings, устраняющих такой отказ. Добавление
hostname либо IP в TCP-правило само по себе не решает разрешение имени.

Поведение сверено с [исходным кодом версии 4.1.3](https://github.com/InterceptSuite/ProxyBridge/tree/v4.1.3_Macos/MacOS/ProxyBridge/extension)
и описано в [документации DNS handling](https://interceptsuite.com/docs/proxybridge/macos-proxy-servers/#dns-handling).
Для неразрешающихся внутренних имён требуется либо поддержка разрешения DNS в
самом ProxyBridge, либо отдельно согласованное сопоставление имени с проверенным
IP в `/etc/hosts`. Системный PAC в этой схеме не используется.

В обновлённом BCS VPN разовый lookup доступен через
`./scripts/resolve-vpn-host.sh <hostname>` при подключённом VPN. Он использует
внутренний DNS ocproxy, не создавая системного DNS proxy и не меняя настройки
Mac. Это диагностическая команда, а не автоматическое устранение `NXDOMAIN`
для браузера. Перед изменением hosts по её результату нужны проверка HTTPS
с исходным hostname и отдельное разрешение на само изменение.

IP-адреса шлюзов могут измениться. Если изменится `serverURL` в настройках BCS
VPN, новый hostname/IP нужно добавить в правило **BCS VPN gateways direct**.

### Внутренний sysPass

В профили явно включён `ef-syspass.tusvc.t-global.bcs`: шаблон `*.global.bcs`
не покрывает домен `t-global.bcs`. Проверка профилей без подключения к сети:

```bash
python3 ./scripts/test-proxybridge-profiles.py
```

Одного правила недостаточно, если системный DNS возвращает `NXDOMAIN`.
Профиль ProxyBridge не настраивает корпоративный DNS. Для такого имени нужно
обеспечить разрешение имени внутри согласованной схемы ProxyBridge. Системный
прокси macOS, Wi-Fi PAC и отдельные настройки прокси браузера не используются.
Добавление hostname в профиль само по себе не устраняет `NXDOMAIN` и не
подтверждает доступ к sysPass через работающий ProxyBridge.

При согласованной записи в `/etc/hosts` сначала необходимо проверить IP через
VPN: соединение с этим IP должно вернуть страницу входа sysPass с исходным
hostname в SNI и HTTP Host, с успешной проверкой цепочки и имени сертификата.
IP виртуальной машины из документации может отличаться от адреса HTTPS-фронтенда;
без такой проверки его нельзя подставлять в `hosts`.

Перед изменением нужно сохранить `/etc/hosts`, не затрагивать остальные записи и
проверить, что **этот IP** покрыт VPN-правилом активного профиля ProxyBridge.
Одного доменного правила недостаточно: чтение `hosts` не создаёт DNS-запрос,
из которого расширение могло бы получить сопоставление имени с IP. Смена IP
потребует обновить и запись, и правило; при общем IP правило может затронуть
другие сервисы на нём. Запись `hosts` отвечает только за имя, сетевой путь
по-прежнему выбирает ProxyBridge.

Проверить сетевой путь с разрешением имени внутри VPN можно без изменения
настроек браузера:

```bash
curl --noproxy '' --socks5-hostname 127.0.0.1:8889 \
  --head --silent --show-error --connect-timeout 8 --max-time 15 \
  --output /dev/null --write-out 'HTTP %{http_code}\n' \
  'https://ef-syspass.tusvc.t-global.bcs/index.php?r=login'
```

Ошибка проверки сертификата означает отдельную проблему доверия или неполную
цепочку на сервере. Нужно проверить корпоративный удостоверяющий центр и цепочку;
отключать проверку TLS нельзя. Командные клиенты могут использовать своё
хранилище CA, отличное от Keychain браузера.

Для sysPass используется `T-BCS-GLOBAL-ROOT-CA`. Независимый источник — вложение
`T-BCS-GLOBAL-ROOT-CA.crt` в [корпоративной инструкции](https://confluence.bcs.ru/pages/viewpage.action?pageId=144541751).
SHA-256 отпечаток DER-сертификата:

```text
91:9D:D0:69:0F:A3:47:A6:56:50:53:D0:66:FA:DE:B7:4B:37:4D:3F:22:E4:DE:79:6E:3C:E5:1A:EC:D1:CE:EC
```

После сверки источника, подписи цепочки и срока действия CA его можно установить
в пользовательскую связку ключей с доверием для SSL только по отдельному
разрешению пользователя. Системную связку ключей и проверку имени сервера менять
не требуется. Изменение файла профиля в проекте не применяет его к уже
работающему ProxyBridge.
