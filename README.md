# DBDeck

A native macOS database client built with SwiftUI. Connect to **PostgreSQL**, **MySQL** and **SQLite** databases, browse and edit data, and run SQL — all in a fast, lightweight Mac app.

> This is a **personal project** I build in my spare time, mostly for my own use. That said, **contributions are very welcome** — issues, ideas and pull requests alike.

## Features

- **Multiple engines**: PostgreSQL, MySQL/MariaDB and SQLite
- **SQL console** with syntax highlighting, autocomplete for tables and columns, multiple tabs and split view — run the selection (⌘⏎), a whole multi-statement script, or just the statement under the cursor (⌘⇧⏎), and cancel a running query (⌘.)
- **Data grid** built for large tables — cell-based rendering and streaming pagination keep millions of rows scrollable
- **Table structure editor** and schema DDL viewer
- **Dump & import**: SQL dumps with progress and cancellation
- **Export** query results as SQL, CSV or JSON
- **SSH tunnels** — reach a database behind a bastion, using the system `ssh` (so `~/.ssh/config` and `ProxyJump` apply)
- **Passwords stored in the macOS Keychain** — never written to disk or config files
- Command palette, saved queries and workspaces

### SSH tunnels

A connection can be opened through an SSH tunnel. DBDeck drives the system
`/usr/bin/ssh`, so everything already configured in `~/.ssh/config` keeps working —
`ProxyJump`, per-host keys, agent forwarding. Three ways to authenticate:

| Mode | What it uses |
| --- | --- |
| Agent / `~/.ssh/config` | Keys already loaded in `ssh-agent`. The app stores no secret at all. |
| Private key | A key file you pick; its passphrase, if any, goes to the Keychain. |
| Password | Stored in the Keychain, like the database password. |

Host keys follow `StrictHostKeyChecking=accept-new`: the first connection to a host is
trusted and recorded in `~/.ssh/known_hosts`, and a later key change is refused.
Passwords and passphrases reach `ssh` through a FIFO served to an `SSH_ASKPASS` helper —
never as a command-line argument or an environment variable, both of which any process
of the same user can read with `ps`.

## Requirements

- macOS 14.0+
- Xcode 16+ (Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build

## Building

```sh
xcodegen generate
xcodebuild -project DBDeck.xcodeproj -scheme DBDeck -configuration Release build
```

Or build, install to `/Applications` and launch in one step:

```sh
./install.sh
```

## iOS / iPadOS

The same core (drivers, keyset pagination, streaming, formatter, autocomplete) also ships
as a native iPhone and iPad app (`DBDeckMobile` target, iOS 17+). The interface is built
for touch:

- **Data grid** on `UICollectionView` with a spreadsheet layout — only visible cells exist,
  header and row numbers stay pinned, and the next page loads as you scroll (anchored on
  the primary key, so page 50 costs the same as page 1)
- **Tap a cell** to open the whole row as a form (edit, set NULL, follow foreign keys, step
  through rows); **touch and hold** for copy / copy as INSERT / filter by this value
- **Filters** as removable chips, **pull to refresh**, sort by tapping a header
- **SQL console** with syntax highlighting, autocomplete suggestions and SQL keys above the
  keyboard, run selection / statement under cursor, cancel, history and saved queries
- Structure editing, relations, triggers and DDL; CSV/JSON/SQL export and dumps through
  the share sheet
- SQLite files are imported from the Files app (they live in *On My iPhone › DBDeck*)
- On iPad, a three-column layout (connections › tables › content) with keyboard shortcuts

SSH tunnels rely on the system `ssh` and are macOS only for now.

```sh
./install-ios.sh                    # build and run on a simulator
./install-ios.sh device <TEAM_ID>   # build, sign and install on a connected device
```

## Tests

```sh
swift test
```

UI tests drive the iOS app through its main flows (they expect a SQLite connection named
"Loja (demo)"):

```sh
xcodebuild test -project DBDeck.xcodeproj -scheme DBDeckMobile -destination 'platform=iOS Simulator,name=iPhone 17'
```

Postgres integration tests are opt-in and run against a live server:

```sh
DBDECK_PG_HOST=localhost DBDECK_PG_USER=postgres swift test --filter PostgresIntegration
```

## Contributing

Contributions of any size are welcome:

1. Open an issue to discuss bugs or ideas
2. Fork, create a branch, and open a pull request
3. Please run `swift test` before submitting

There is no formal roadmap — if something annoys you or is missing, that's a great place to start.

## License

[MIT](LICENSE). The vendored [`ThirdParty/mysql-nio`](ThirdParty/mysql-nio) package keeps its own MIT license from the [Vapor](https://github.com/vapor/mysql-nio) project.
