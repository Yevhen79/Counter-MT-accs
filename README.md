# Counter-MT-accs

Ежедневный счётчик торгуемых инструментов (режим **trade = Full**) по счетам
ForexClub и Libertex Cyprus на MetaTrader 4 и 5. Работает на GitHub Actions
по будням ~13:00 Киева, дописывает строку в
[`data/history.csv`](data/history.csv) и показывает дашборд:
**https://yevhen79.github.io/Counter-MT-accs/**

Ничего не запускается на твоём компьютере. Робот сам ставит брокерские
терминалы, логинится в каждый счёт, считает инструменты и коммитит результат.

## Самостоятельное изменение счетов (без программиста)

Всё, что задаёт счета — это файл [`config.yaml`](config.yaml) (логин, сервер,
название) и GitHub Secrets (пароли). Менять можно прямо в браузере.

**Поменять пароль** счёта (например, сменил мастер-пароль у брокера):
- Settings → Secrets and variables → Actions → открыть нужный секрет
  (имя видно в `config.yaml` в поле `password_secret`) → **Update** → новый пароль.

**Поменять номер счёта / сервер** (например, счёт ушёл в close-only и нужен другой):
1. Открой `config.yaml` → ✏️ Edit → у нужного блока поправь `login` (число без
   кавычек) и при необходимости `server` (в кавычках).
2. Обнови значение его секрета (`password_secret`) на пароль нового счёта.
3. **Commit changes** в ветку `claude/trading-tools-report-MCrOV` — прогон
   запустится сам, через ~15-20 мин дашборд обновится.

**Добавить счёт**: скопируй целиком блок `- key: …` в `config.yaml`, задай
новые уникальные `key` и `label`, заполни поля, заведи новый секрет с именем
из `password_secret`. **Удалить** — удали блок `- key: …`.

**Запустить вручную** в любой момент: вкладка **Actions** → **Daily Instrument
Count** → **Run workflow**.

Конфиг проверяется перед каждым прогоном (шаг **Validate config**): при опечатке
(сломанные отступы, пропущенное поле, нечисловой `login`, повтор `label`)
прогон упадёт сразу с понятным описанием, что именно поправить — данные при
этом не портятся.

> Примечание: пароли хранятся **только** в GitHub Secrets (репозиторий
> публичный), поэтому в `config.yaml` их нет — там лишь имя секрета.

## What it counts

| Platform | Counts when                                                            |
| -------- | ---------------------------------------------------------------------- |
| MT5      | `SymbolInfoInteger(name, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_FULL` |
| MT4      | `MarketInfo(name, MODE_TRADEALLOWED) == 1`                             |

MT4's API does not expose `TRADE_CLOSE_ONLY` vs `TRADE_FULL` separately — the
above is the closest available signal. To keep the comparison meaningful, the
job runs Mon-Fri only (weekends would falsely report 0 for many symbols).

## One-time setup

### 1. Add 4 secrets

Repo → **Settings → Secrets and variables → Actions → New repository secret**.
Names must match exactly:

| Secret name             | Value (master password for…)            |
| ----------------------- | --------------------------------------- |
| `MT4_MARKET_PASSWORD`   | account 730232800 on `ForexClub-MT4 Market Real 2 Server` |
| `MT4_INSTANT_PASSWORD`  | account 710268540 on `ForexClub-MT4 Real 2 Server`        |
| `MT5_MARKET_PASSWORD`   | account 550459323 on `ForexClub-MT5 Real Server`          |
| `MT5_INSTANT_PASSWORD`  | account 555105689 on `ForexClub-MT5 Instant Real Server`  |

Logins and server names live in [`config.yaml`](config.yaml) (they are not
secret). If any of those need to change, edit the file.

### 2. Add the MT4 installer URL (optional, but required for MT4)

MT4 is not distributed by MetaQuotes as a generic installer the way MT5 is. We
use the ForexClub-branded MT4 installer so the broker's server list is
pre-bundled.

- Go to forexclub.com / libertex.com download page, right-click the
  **Download MT4** link, copy URL.
- Paste it into `config.yaml` → `mt4_installer_url`.
- Commit.

If this URL is empty, the MT4 part of the workflow is skipped gracefully and
only the two MT5 columns get updated.

### 3. Enable GitHub Pages (optional, for the dashboard)

Repo → **Settings → Pages** → Source: **Deploy from a branch** → Branch:
your default branch, folder: **`/docs`**. The dashboard will be at
`https://yevhen79.github.io/counter-mt-accs/`.

### 4. First run

Repo → **Actions → Daily Instrument Count → Run workflow → ✅ Force**. This
bypasses the "already ran today" check and triggers a full run so we can see
the logs and iterate on any errors.

## What runs daily

`.github/workflows/daily-count.yml` triggers at:

- `10:00 UTC` Mon–Fri (= 13:00 Kyiv during EEST / summer)
- `11:00 UTC` Mon–Fri (= 13:00 Kyiv during EET / winter)

`scripts/should_run.py` skips the second trigger of the day so there is
always exactly one row per Kyiv date.

The pipeline:

1. **Install MT5** — silent install of MetaQuotes' generic MT5 (
   `https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe`).
2. **Count MT5** — `scripts/count_mt5.py` uses the official `MetaTrader5`
   Python package to log into each MT5 account, enumerate symbols, count
   those with `SYMBOL_TRADE_MODE_FULL`.
3. **Install MT4** — `scripts/install_mt4.ps1` downloads `mt4_installer_url`
   and tries a series of silent-install flags (`/auto`, `/S`,
   `/VERYSILENT`, …) until `terminal.exe` shows up in a known location.
4. **Count MT4** — `scripts/count_mt4.ps1` for each MT4 account:
   - Copies `mql4/CountInstruments.mq4` to `MQL4/Experts/` and compiles via
     `metaeditor.exe`.
   - Writes a `start.ini` with login/password/server and a `[StartUp]` block.
   - Launches `terminal.exe /portable /config:start.ini /skipupdate`.
   - Waits up to 180 s for `MQL4/Files/done.flag`.
   - Reads `MQL4/Files/count.json` and kills the terminal.
5. **Aggregate** — `scripts/aggregate.py` merges results, appends one row
   to `data/history.csv`, mirrors it to `docs/history.csv` for Pages.
6. **Commit & push** — committed by `trading-counter-bot`.

`continue-on-error: true` on each platform step means MT4 problems do not
prevent MT5 data from being recorded (and vice versa). Missing values appear
as `ERR` in the CSV.

## Files

```
.github/workflows/daily-count.yml   # the schedule and the pipeline
config.yaml                         # accounts (logins + servers + secret names)
mql4/CountInstruments.mq4           # MT4 EA: counts symbols, writes count.json
scripts/should_run.py               # idempotency check (Kyiv date)
scripts/count_mt5.py                # MT5 counter (Python + MetaTrader5)
scripts/install_mt4.ps1             # silent MT4 install
scripts/count_mt4.ps1               # launches MT4 headless, collects results
scripts/aggregate.py                # writes data/history.csv + docs/history.csv
data/history.csv                    # canonical history (append-only)
docs/                               # GitHub Pages dashboard + history.csv copy
```

## Cost

Windows runner minutes used per day: ~5–8 minutes. Monthly: ~150–200 min.
Free tier for private repos is 2000 min/month — well within budget.

## Troubleshooting

- **MT5 step fails with "initialize failed: (-10004, …)"** — wrong password,
  wrong server name, or account got archived. Verify the secret value and
  the server string in `config.yaml`.
- **MT4 step skipped with "mt4_installer_url is empty"** — paste the
  ForexClub MT4 installer URL into `config.yaml`.
- **MT4 step "EA compile failed"** — `metaeditor.exe` could not produce
  `CountInstruments.ex4`. Check the runner logs for the compiler output;
  usually means the broker's MetaEditor is in an unexpected path. Update
  `count_mt4.ps1` to locate it.
- **MT4 step "timeout"** — the headless terminal launched but the EA never
  wrote `done.flag` within 180 s. Could be: login failed (check broker
  password), `EnableExperts` not honored, or the broker's terminal needs
  additional flags. Inspect the uploaded `raw-counts-*` artifact and the
  terminal logs at `<TerminalDir>\logs\`.
