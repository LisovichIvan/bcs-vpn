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
Target Hosts:                gitlab.gitlab.bcs.ru;artifactory.gitlab.bcs.ru;confluence.bcs.ru;jira.bcs.ru;apis.tusvc.bcs.ru;*.global.bcs;193.142.56.242;193.142.56.243;193.142.56.247;172.18.8.20;172.17.174.48
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

На macOS ProxyBridge сопоставляет домен с уже разрешённым IP через DNS-механизм
системного расширения, после чего передаёт SOCKS5 конечный IP. Поэтому в профиль
добавлены известные IP BCS наряду с доменами. Если новый внутренний домен не
разрешается локальным DNS до подключения, одного шаблона `*.global.bcs` может
оказаться недостаточно. В таком случае добавьте его IP в `Target Hosts` правила
**BCS through VPN** или передайте разработчику имя домена для включения в профиль.

IP-адреса шлюзов могут измениться. Если изменится `serverURL` в настройках BCS
VPN, новый hostname/IP нужно добавить в правило **BCS VPN gateways direct**.
