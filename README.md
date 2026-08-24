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
- **Passwords stored in the macOS Keychain** — never written to disk or config files
- Command palette, saved queries and workspaces

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

## Tests

```sh
swift test
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
