# Изолированные среды Pilot Web

Проект управляет только одноразовыми стендами разработки. Управляющий сервис можно разворачивать как production-инфраструктуру для разработчиков, но он не подключается к production Pilot, не читает его базы и каталоги и не управляет Windows-службами Pilot.

| Режим | Компоненты Pilot | Лицензия |
|---|---|---|
| `ice-dev` | Pilot Server, Pilot Web, Web myAdmin | не нужна |
| `bim-dev` | Pilot Server, Pilot-BIM Server, Pilot Web, Web myAdmin | локальная копия разрешённой лицензии |

TextSearch, Sign Server и CAD Farm не запускаются. Инфраструктурный nginx-ingress проксирует localhost-порты в отдельную сеть среды и не является компонентом Pilot.

## Независимые компоненты и сборки

Платформа разделена на `web-ui`, `control-api` и `environment-engine`. Номера релизов отсутствуют: идентификатор сборки — SHA-256 её manifest, который включает хеши всех файлов и требования совместимости. Один и тот же payload и manifest дают один и тот же `buildHash`. Номера форматов API, протокола движка и схем данных описывают совместимость; они не определяют пути установки.

Структура поставки стабильна:

```text
components/
  web-ui/
  control-api/
  environment-engine/
scripts/
bundle-manifest.json
```

После установки код размещается в служебном хранилище `.pilot-runtime/builds/<component>/<buildHash>`. Активные хеши и история переключений находятся в `.pilot-runtime/deployment-state.json`. Архивы баз и рабочие данные отделены от кода: `.pilot-instances`, `.pilot-templates`, `.pilot-runtime/api` сохраняются между обновлениями. Из кода нельзя восстановить путь по номеру релиза — компонент разрешается только через deployment-state.

Сборка:

```powershell
.\scripts\new-server-package.ps1 -OutputDirectory .\artifacts
```

Результат — `PilotEnvironment-web-ui.zip`, `PilotEnvironment-control-api.zip`, `PilotEnvironment-environment-engine.zip` и полный `PilotEnvironment-win-x64.zip`, каждый с файлом `.sha256`. Хеш ZIP проверяет перенос архива; `buildHash` идентифицирует содержимое компонента независимо от упаковки ZIP. Файлы поставки имеют постоянные имена. Для хранения нескольких загруженных архивов можно использовать внешний каталог с хешем, но установщик не требует особого имени архива.

Первую установку из распакованной поставки выполняет `deploy-server.ps1`. Служба создаётся под LocalSystem. Для перехода с любой предыдущей структуры установки сначала завершите queued/running операции и остановите только `PilotEnvironmentApi`. Из текущей поставки выполните:

```powershell
.\scripts\update-platform.ps1 -Component all `
  -Package 'D:\Packages\PilotEnvironment-win-x64.zip' `
  -InstallRoot 'C:\ProgramData\PilotEnvironment' -ValidateOnly

.\scripts\update-platform.ps1 -Component all `
  -Package 'D:\Packages\PilotEnvironment-win-x64.zip' `
  -InstallRoot 'C:\ProgramData\PilotEnvironment'
```

Миграция определяется форматом deployment-state, а не номером установленного продукта. Установщик проверяет отсутствие незавершённых операций, сохраняет конфигурацию, SQLite с WAL и CLI-адаптеры в защищённый `migration-backup-*`, затем активирует текущую поставку. Каталоги данных schema v4 и Docker-контейнеры не пересоздаются. Старые каталоги с кодом остаются доступными для отката и автоматически не удаляются. Информационный контракт `/api/v1/platform` обозначен `apiContractVersion: 2`: компоненты описываются `buildHash`, без поля релиза; остальные REST-маршруты сохраняются.

Последующие обновления:

```powershell
.\scripts\update-platform.ps1 -Component web-ui -Package 'D:\Packages\PilotEnvironment-web-ui.zip'
.\scripts\update-platform.ps1 -Component environment-engine -Package 'D:\Packages\PilotEnvironment-environment-engine.zip'
.\scripts\update-platform.ps1 -Component control-api -Package 'D:\Packages\PilotEnvironment-control-api.zip'
```

Панель переключается без рестарта службы, движок — после завершения активных операций, API — с коротким рестартом управляющей службы. Повторная установка того же хеша возвращает `unchanged` и не перезапускает службу. Сборка движка фиксируется на всё время операции. Установщик ждёт до 30 минут; при активации API изменяющие запросы получают `503 platform_updating` и `Retry-After`. Обновление платформы не обновляет Docker release Pilot: для этого остаётся отдельный Recreate.

HTML получает `no-store`, а ресурсы панели доступны через `/ui-assets/<buildHash>/...` с immutable cache. Открытые вкладки сохраняют старые ресурсы; панель предлагает перезагрузить страницу при смене хеша. Авторизованный `GET /api/v1/platform` возвращает хеши компонентов, capabilities, контракт API и состояние обслуживания.

Откат: `update-platform.ps1 -Component web-ui -Rollback` (либо компонент последнего обновления, `all` для полной поставки). После прерывания обновления тот же `-Rollback` восстанавливает состояние по журналу. Сохраняются активный и три предыдущих снимка каждого компонента; старые вкладки более ранних снимков нужно перезагрузить.

Машинный запуск движка: `pilot-env.ps1 GetEngineInfo -Json -Machine`. Ответ содержит `buildHash`, поддерживаемые действия и форматы данных; stdout — envelope `{protocolVersion, success, data, error}`, диагностика — stderr. CLI-адаптер в корневом `scripts` выбирает сборку из deployment-state.

Проверки: `dotnet test`, `tests/Test-PlatformPackages.ps1`, `tests/Test-PlatformServiceUpdate.ps1`, `tests/Test-WindowsPowerShellCompatibility.ps1`. HTTP-проверка: `tests/Test-PlatformHttp.ps1 -TokenFile <путь>`; она создаёт временную установку и проверяет переключение/откат сборок без рестарта API. Проверки не зависят от номера релиза.

## API и веб-панель

`src/PilotEnv.Api` — ASP.NET Core 9 Windows Service, который предоставляет REST API, панель управления и единый reverse proxy. Через API можно создавать только `bim-dev`; существующие `ice-dev` видны как read-only. Один общий токен разрешает управление всеми BIM-стендами.

Подготовка хоста выполняется один раз из встроенного Windows PowerShell 5.1 от имени администратора:

```powershell
$adminPassword = Read-Host 'Пароль администратора Pilot Server' -AsSecureString
$bimPassword = Read-Host 'Пароль пользователя Pilot Web/BIM' -AsSecureString
.\scripts\configure-api.ps1 `
  -LicenseFile 'C:\Licenses\pilot-license' `
  -ConfigurationFile 'C:\PilotConfig\configuration_pilot-bim_ru.pilotcfx' `
  -PublicHost '360pilot.ru' `
  -AdminLogin admin -AdminPassword $adminPassword `
  -BimLogin admin -BimPassword $bimPassword
```

Скрипт копирует лицензию и `.pilotcfx` в защищённый runtime-каталог, шифрует пароли через DPAPI LocalMachine, сохраняет только PBKDF2-хеш API-токена и выводит сам токен один раз. Публичный API не принимает пароли, лицензию или пути к ним.

Установка службы от встроенной `NT AUTHORITY\SYSTEM`:

```powershell
.\scripts\install-api-service.ps1 -Start
```

Пользователь Windows и пароль для службы не создаются. Установщик не изменяет группу `docker-users`; LocalSystem получает доступ к рабочим каталогам по SID `S-1-5-18`.

Для запуска без установки службы:

```powershell
dotnet run --project .\src\PilotEnv.Api\PilotEnv.Api.csproj
```

Стабильный upstream — `http://127.0.0.1:17070`. Дополнительные DNS-записи не нужны: один существующий домен используется на разных HTTPS-портах:

- `https://360pilot.ru:17443` — панель и API;
- `https://360pilot.ru:18000–18049` — автоматически назначаемые Pilot Web;
- `https://360pilot.ru:19000–19049` — автоматически назначаемые myAdmin.

Основные методы API описаны в `/openapi/v1.json`. Изменяющие запросы возвращают `202 Accepted` и `operationId`; прогресс читается через `/api/v1/operations/{id}`. Для скриптов токен передаётся в `Authorization: Bearer <token>`, панель обменивает его на HttpOnly-cookie.

Быстрый `Restart Web` вызывает перезапуск только `pilot-web-server`, ждёт HTTP-ready и проверяет вход пользователя. Для `pilot-server` можно передать `{"cascade":true}`, чтобы после него последовательно перезапустить BIM, Web и myAdmin.

Admission control резервирует 8 ГБ на работающий/запускаемый стенд, оставляет 8 ГБ хосту и требует минимум 20 ГБ свободного диска. Остановленный стенд освобождает RAM, но сохраняет данные, порты и URL. Автоматического TTL нет.

Для кратковременной диагностики на тестовом ПК проверку доступной памяти можно отключить параметром `-DisableMemoryAdmission` у `deploy-server.ps1` или `configure-api.ps1`. Это не снимает Docker memory limit с отдельных контейнеров и не увеличивает фактически доступную Docker память; при её исчерпании контейнеры могут быть остановлены OOM killer. В рабочем deployment этот параметр использовать нельзя.

## Автоматизированное развёртывание на сервере

Целевая платформа первой версии — Windows x64 со штатным Windows PowerShell 5.1 и Docker Engine в режиме Linux containers. Устанавливать PowerShell 7 на сервер не требуется. Docker должен быть доступен LocalSystem без интерактивного входа пользователя.

Сборка переносимого self-contained пакета выполняется на машине с .NET 9 SDK:

```powershell
.\scripts\new-server-package.ps1 -OutputDirectory .\artifacts
```

Скрипт создаёт ZIP, печатает его SHA-256 и записывает рядом файл `<package>.sha256`. В пакет входят API runtime для `win-x64`, Compose, ingress, PowerShell-движок, deployment-скрипты и manifest с хешем каждого файла. На целевом сервере распакуйте пакет в постоянный каталог, например `C:\ProgramData\PilotEnvironment`. Не запускайте службу непосредственно из временного каталога распаковки.

Preflight без изменений системы:

```powershell
.\scripts\test-server-prerequisites.ps1 `
  -LicenseFile 'D:\PilotSecrets\license.pilotlic' `
  -ConfigurationFile 'D:\PilotSecrets\configuration_pilot-bim_ru.pilotcfx'
```

Первичное развёртывание из повышенной консоли Windows PowerShell 5.1:

```powershell
$pilot = Get-Credential -UserName admin -Message 'Pilot Server administrator'
$bim = Get-Credential -UserName bimservice -Message 'Pilot-BIM service account'

.\scripts\deploy-server.ps1 `
  -LicenseFile 'D:\PilotSecrets\license.pilotlic' `
  -ConfigurationFile 'D:\PilotSecrets\configuration_pilot-bim_ru.pilotcfx' `
  -ApiTokenFile 'D:\PilotSecrets\api-token.txt' `
  -PublicHost '360pilot.ru' `
  -AdminCredential $pilot `
  -BimCredential $bim
```

Windows credentials для службы не нужны: новая служба всегда создаётся как LocalSystem. Токен и прикладные пароли Pilot/Pilot-BIM не передаются дочерним процессам в командной строке. Переданный токен не печатается в deployment-лог. Пароли сохраняются только в DPAPI LocalMachine, а служба публикуется self-contained и не зависит от установленного .NET Runtime. Для движка сред используется встроенный `%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe`; дополнительных версий PowerShell на сервере не требуется.

Если уже существующая служба использует другую identity, установщик сохраняет её и выводит предупреждение. Явный `LegacyServiceCredential` оставлен только для совместимости и не используется в стандартном deployment.

При первом переходе со schema v3 добавьте `-RemoveSchemaV3Environments`: найденные старые стенды будут перечислены и удалены без резервных копий. Без этого явного параметра deployment остановится до изменений. Schema v4 среды сохраняются при миграции структуры установки. Для последующих обновлений компонентов используйте `update-platform.ps1`; `deploy-server.ps1 -ForceReconfigure` нужен при изменении настроек или секретов.

Проверка после установки:

```powershell
.\scripts\test-server-deployment.ps1 `
  -ApiTokenFile 'D:\PilotSecrets\api-token.txt' `
  -ExternalControlUrl 'https://360pilot.ru:17443' `
  -ProxyContainerName 'nginx'
```

### Подключение reverse proxy

Если IIS/nginx/Caddy работает непосредственно на Windows-хосте, оставьте topology `Host`: API слушает только `127.0.0.1:17070`, а upstream proxy — `http://127.0.0.1:17070`.

Для nginx в Docker Desktop API по умолчанию слушает 127.0.0.1; контейнер обращается к нему через host.docker.internal. Укажите имя работающего контейнера:

```powershell
.\scripts\deploy-server.ps1 <остальные параметры> `
  -ProxyTopology Container `
  -ProxyContainerName 'nginx-proxy'
```

Для Docker Desktop upstream — `http://host.docker.internal:17070`, входящее разрешение на публичном интерфейсе не требуется. Deployment проверяет `/health/ready` из контейнера nginx (требуется curl). Для другого Docker-хоста явно задайте доступный адрес Windows через `-ListenAddress` и ограничьте firewall сетью proxy. Upstream генерируется из фактической конфигурации; bind на `0.0.0.0` запрещён.

Deployment создаёт `nginx-pilot-environment-ports.conf`. Подключите его внутри отдельного TLS `server { ... }` с сертификатом `360pilot.ru`. Фрагмент заранее слушает `17443`, `18000–18049` и `19000–19049`, поэтому новые среды не требуют перезагрузки nginx. У контейнера nginx один раз опубликуйте те же TCP-порты, например Compose mappings `17443:17443`, `18000-18049:18000-18049`, `19000-19049:19000-19049`.

Правила Windows Firewall можно создать одной командой из повышенной консоли: `./scripts/configure-public-port-firewall.ps1`. Скрипт поддерживает `-WhatIf`.

Proxy обязан:

- завершать HTTPS;
- сохранять исходный `Host`;
- передавать `X-Forwarded-For`, `X-Forwarded-Host`, `X-Forwarded-Proto`;
- поддерживать WebSocket Upgrade;
- иметь таймаут не менее 10 минут для длительных BIM/Web операций.

Проверка доступности proxy должна направляться на `/health/live`. Маршрут `/health/ready` дополнительно подтверждает доступ службы к Docker Engine.

### Что проверить до фактического размещения

- Тип сервера: Docker обязан возвращать `OSType=linux`; обычный Windows Server Docker с Windows containers для образов Pilot не подходит.
- Доступ LocalSystem к Docker Engine; установщик подтверждает его через обязательный `/health/ready`.
- Расположение proxy: `Host` или `Container`; от этого зависит bind API и Firewall.
- Сертификат существующего домена `360pilot.ru`; номер HTTPS-порта на валидность сертификата не влияет.
- Открытые в firewall TCP-порты `17443`, `18000–18049` и `19000–19049`; порт API `17070` извне закрыт.
- Память Docker: минимум 16 ГБ для одного активного BIM-стенда; далее по 8 ГБ на каждый дополнительный стенд.

## BIM-dev

Первое создание:

```powershell
.\scripts\start-bim-dev.ps1 bim-feature-a `
  -LicenseFile 'C:\Licenses\pilot-license'
```

Файл можно передать без расширения: скрипт проверяет XML, `license-id`, структуру XML-подписи, продукты 90/91, дату обновлений и SHA-256, затем копирует его как `<license-id>.pilotlic`; криптографическое принятие подписи подтверждает сам Pilot Server при smoke-тесте. Исходный путь и пароли не попадают в `instance.json`, `.env` и журналы. Пароли первоначальной настройки хранятся только в DPAPI-зашифрованных CLIXML текущего пользователя Windows, поэтому повторный запуск не спрашивает их:

```powershell
.\scripts\start-bim-dev.ps1 bim-feature-a
```

Новые стенды используют текущий проверенный last-known-good и запускаются только по immutable digest. Проверка нового набора выполняется явно через `POST /api/v1/releases/refresh` или действие `RefreshRelease`; обычный Stop/Start никогда не меняет release и не удаляет данные. Версия обновлений лицензии окончательно проверяется самим Pilot Server.

### BIM-ready шаблон

Для каждого digest Pilot Server создаётся отдельный чистый шаблон: временный локальный стек myAdmin создаёт пустую базу и импортирует официальную `configuration_pilot-bim_ru.pilotcfx`, после чего проверяются типы и автоматизация. Bootstrap-контейнеры и сеть удаляются. При необходимости действие можно вызвать явно:

```powershell
.\scripts\pilot-env.ps1 PrepareTemplate `
  -LicenseFile 'C:\Licenses\pilot-license' `
  -ConfigurationFile 'C:\PilotConfig\configuration_pilot-bim_ru.pilotcfx'
```

## ICE-dev

```powershell
.\scripts\start-dev.ps1 feature-a
```

ICE-dev использует `admin/admin` и подходит для общей разработки Pilot Web, но не проверяет BIM API.

## Изоляция и ресурсы

- Конфигурация имеет `schemaVersion: 4` и режим `ice-dev|bim-dev`.
- Внутренние порты выбираются атомарно с учётом слушателей ОС и публикуются только на `127.0.0.1`. API-среда дополнительно получает постоянную публичную пару Web/myAdmin из SQLite-резерва.
- Каждая среда имеет отдельную Compose bridge-сеть с NAT. Исходящие подключения контейнеров к интернету, внешним API и базам данных по умолчанию разрешены без списка разрешённых адресов. Доступ также зависит от маршрутов, DNS и firewall хоста и целевого сервиса; его credentials задаются самим расширением.
- Pilot-компоненты обращаются к своему серверу по `http://pilot-server:5545`. Для внешней базы используйте доступное контейнеру имя или адрес: `localhost` внутри контейнера означает сам контейнер. Входящие порты по-прежнему публикуются только на loopback; внешний доступ к Web/myAdmin идёт через управляющий proxy.
- Чтобы применить новую сетевую конфигурацию к ранее созданной среде, установите новый пакет движка, дождитесь завершения операций, выполните CLI `pilot-env.ps1 Down <имя>`, затем `pilot-env.ps1 Start <имя>` из каталога установки. Down удаляет контейнеры и старую Docker-сеть, сохраняя каталог базы и закреплённые порты; обычный Stop/Start или Restart Web не меняет свойства существующей сети. Не используйте Delete или Recreate для этой смены сети.
- BIM-dev ограничен 8 ГБ RAM (без CPU limit). Запуск отклоняется, если невозможно оставить резерв 8 ГБ.
- Данные одноразовые, но сохраняются между Stop/Start. Переход на новый проверенный release выполняется только явной подтверждённой операцией Recreate; миграции и резервные копии не выполняются.
- Cookies браузера не разделяются по TCP-портам. Для одновременной работы с разными Pilot-базами используйте отдельные профили браузера или приватные окна.

## Управление

```powershell
.\scripts\pilot-env.ps1 List
.\scripts\pilot-env.ps1 Status bim-feature-a
.\scripts\pilot-env.ps1 GetStatus bim-feature-a -Json
.\scripts\pilot-env.ps1 GetCapacity -Json
.\scripts\pilot-env.ps1 Stop bim-feature-a
.\scripts\pilot-env.ps1 Start bim-feature-a
.\scripts\pilot-env.ps1 RestartComponent bim-feature-a -Service pilot-web-server
.\scripts\pilot-env.ps1 RestartComponent bim-feature-a -Service pilot-server -Cascade
.\scripts\pilot-env.ps1 Recreate bim-feature-a -Force
.\scripts\pilot-env.ps1 Logs bim-feature-a -Service pilot-bim-server
.\scripts\pilot-env.ps1 Down bim-feature-a
.\scripts\pilot-env.ps1 Remove bim-feature-a -Force
.\scripts\pilot-env.ps1 ResolveRelease
.\scripts\pilot-env.ps1 RefreshRelease
.\scripts\pilot-env.ps1 Doctor
```

`start-prod.ps1` намеренно завершается ошибкой: production полностью вне области проекта.

## Проверки

```powershell
.\tests\Test-BimDevValidation.ps1 -LicenseFile 'C:\Licenses\pilot-license'
.\tests\Test-BimParallel.ps1 -NameA bim-ifc-a -NameB bim-ifc-b
.\tests\Test-PilotIsolation.ps1 `
  -DatabaseTemplate 'C:\ProgramData\ASCON\Pilot Server\Databases\pilot-ice_ru'
```

Расширенный BIM smoke-тест должен подтвердить лицензию, Web/myAdmin, BIM online, вход тестового пользователя и обработку небольшого IFC. Если RAM хоста не позволяет одновременно зарезервировать два стенда и безопасный остаток, тест обязан отказать, а не ослаблять лимит.

## Локальные сборки

Исходники находятся в source, готовые пакеты — в соседней папке builds. Запустите .\scripts\new-server-package.ps1 из source: каждый запуск создаёт отдельный каталог builds\yyyy-MM-dd_HH-mm-ss по московскому времени. Для первой установки перенесите PilotEnvironment-win-x64.zip; остальные ZIP предназначены для независимых обновлений. Идентичность компонентов и проверка целостности по-прежнему определяются SHA-256.

## Проверки установки и диагностика службы

Команда Windows-службы задаётся через CIM с отдельными полями PathName/StartMode, затем проверяется чтением Win32_Service.PathName. Это исключает зависимость пути EXE от передачи кавычек в sc.exe на Windows PowerShell 5.1. Recovery policy по-прежнему задаётся через sc.exe без путей.

Для Docker Desktop и контейнерного nginx используйте -ProxyTopology Container -ProxyContainerName nginx-proxy без -ListenAddress: API слушает loopback, nginx обращается через host.docker.internal. Для других Docker-хостов адрес задаётся явно. Установщик заранее проверяет запущенный nginx и наличие curl; после запуска службы проверяет /health/ready из nginx. Неудачная проверка связи оставляет API для диагностики, но завершается ошибкой и не объявляет deployment завершённым. Настройка внешнего TLS, port mappings и внешняя проверка остаются отдельным этапом.

Прямые проверки API должны передавать Host: 360pilot.ru:17443; иначе порт 17070 не является маршрутом панели и может возвращать 404. Используйте test-server-deployment.ps1 вместо запросов без Host. Существующую службу необходимо проверять даже при первой установке в новый каталог: она может остаться от старого размещения. Откат на прежний PathName не гарантирует работоспособность, если прежний каталог уже удалён.

Регрессии: tests/Test-ServiceCommand.ps1 проверяет пробелы и кавычки, отказ SCM и несовпадение read-back. tests/Test-PlatformServiceUpdate.ps1 моделирует обновление, drain и rollback; он не заменяет интеграционный тест реальной SCM на сервере.

## Панель и общий журнал операций

Панель показывает среды, создание стенда, общий журнал, ресурсы и проверку обновлений Pilot. Названия действий и состояния отображаются на русском. Точечный перезапуск вынесен в отдельную строку карточки; каскадный запуск для pilot-server включается отдельным флажком.

После отправки команды панель отслеживает её до завершения. Последняя операция восстанавливается из API после перезагрузки страницы. Журнал общий для всех обладателей токена, включая историю удалённых сред. Пользователь-инициатор не определяется: токен общий. Техническая диагностика раскрывается отдельно.

`GET /api/v1/operations` возвращает страницы по 25 записей, максимум 100. Фильтры: environmentName, kind, state (включая active). nextCursor передаётся в cursor следующего запроса; при смене фильтров следует начать заново без cursor. В списке не возвращаются requestJson, resultJson и вывод команд. В статусе среды добавлено lastOperation. Capability журнала: operations-journal-v1, контракт API остаётся 2.

Для этого обновления установить сначала control-api, затем web-ui штатным update-platform.ps1. Допустим один полный bundle через -Component all. Контейнеры Pilot не пересоздаются, nginx и адреса не меняются. Новая панель без capability журнала сохраняет управление средами и предлагает обновить API. Frontend-модули при сборке объединяются в один app.js, совместимый со статическими маршрутами прежнего API; на сервере Node.js не нужен.

Если отправка команды прервалась, панель не утверждает, что операция отменена. Повторная отправка использует прежний Idempotency-Key и тело команды. Перезагрузка страницы не отправляет команды автоматически. sessionStorage хранит только неподтверждённые команды, без токенов и паролей.

Локальные проверки: `dotnet test tests/PilotEnv.Api.Tests/PilotEnv.Api.Tests.csproj` и `node tests/ui-state.test.mjs`. tests/ui-fixture-server.py — только loopback HTTP-fixture для задержек, сбоев сети и интерфейсных подтверждений; он не вызывает Docker и не проверяет фактическое пересоздание базы Pilot.
