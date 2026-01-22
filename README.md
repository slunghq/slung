<h1>
<p align="center">
  <img src="./assets/logo.png" alt="Logo" width="128">
  <br>Slung
</h1>
  <p align="center">
      Write real-time functions that compute over temporal data streams with full historical context.
    <br />
    <a href="https://slung.tech">Homepage</a>
    ·
    <a href="https://docs.slung.tech">Documentation</a>
    ·
    <a href="#roadmap">Roadmap</a>
    </p>
</p>

> [!WARNING]
> This project is currently WIP and is no where near ready for production use.


## Roadmap
|  #  | Objective                                                                  | Status |
| :-: | -------------------------------------------------------------------------- | :----: |
|  1  | Stream ingestion [[#1](https://github.com/slunghq/slung/issues/1)]           |   📅   |
|  2  | TSM tree [[#2](https://github.com/slunghq/slung/issues/2)]                   |   ⚠️   |
|  3  | Parallel data query engine [[#3](https://github.com/slunghq/slung/issues/3)] |   📅   |
|  4  | Wasm execution                                                               |   📅   |
|  5  | Write-ahead log (WAL)                                                        |   🚫   |
|  6  | WebTransport                                                                 |   🚫   |

+ ✅ Done: Feature is implemented and verified.
+ ⚠️ In-progress: Active development or stabilization phase.
+ 📅 Planned: Queued for development; architecture defined.
+ 🚫 Deferred: Not currently in scope for the current milestone.

### Stream ingestion
+ [ ] Non-blocking websocket channel [[#4](https://github.com/slunghq/slung/issues/4)]
+ [ ] Stream rx/tx pool manager [[#5](https://github.com/slunghq/slung/issues/5)]

### TSM tree
+ [ ] Skiplist
+ [ ] Columnar table
+ [x] Bloom filter

### Parallel query engine
+ [ ] Query DSL [[#6](https://github.com/slunghq/slung/issues/6)]
+ [ ] Async iterator [[#7](https://github.com/slunghq/slung/issues/7)]

### Wasm execution
+ [ ] Host functions template
+ [ ] Life cycle manager
