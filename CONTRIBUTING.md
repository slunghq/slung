# Contributing to Slung

Thank you for your interest in contributing to Slung!

We're early and are always open to new contributors. We adhere to the [Zed Industries Code of Conduct](https://zed.dev/code-of-conduct). LLM-written contributions are looked down upon, but we do not discriminate against it as long as there's clear evidence of the human touch. See [brainmade](https://brainmade.org/) to learn more.

## Contributions

We suggest you start by looking at our [open issues](https://github.com/slunghq/slung/issues). Ensure to open an issue first for any new feature requests or bug reports to reduce the risk of rejecting your pull request.

### Development setup

Nix is used to set up our development environment. To get started:

```shell
# Clone the repository
git clone git@github.com:slunghq/slung.git

cd slung

# Enter development shell
nix develop

# Run tests
zig build test

# Watch for changes and run programme
./zig-watch

# Watch for changes and run tests
./zig-watch-test
```

### Style & Standards

+ Follow the Zig style guide with a single exception; keep all file names in snake_case.
+ Compound names should go from most significant to least significant item. E.g., use `index_row`, `index_column` over `row_index`, `column_index`. This helps with grouping items in our codebase.
+ Add tests to new feature.
+ Comments are currently optional but helpful when necessary.
+ Ask before using of any external dependencies.
+ Keep changes **SIMPLE**! We should be able to look at your code and know what it does.
+ Ensure commits simple and useful, following [Convention Commits](https://www.conventionalcommits.org/en/v1.0.0/).

Thank you for taking the time to contribute! We value your time and hope you value ours ❤️.
