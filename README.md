<h1>
<p align="center">
  <img src="./docs/assets/logo.png" alt="Logo" width="128">
  <br>Slung
</h1>
  <p align="center">
      Write real-time functions that compute over temporal data streams with full historical context.
    <br />
    <a href="https://slung.tech">Homepage</a>
    ·
    <a href="https://slung.tech/docs">Documentation</a>
    ·
    <a href="#roadmap">Roadmap</a>
    </p>
</p>

> [!WARNING]
> This project is currently WIP and is no where near ready for production use.


## Roadmap
|  #  | Objective                                                                    | Status |
| :-: | ---------------------------------------------------------------------------- | :----: |
|  1  | Stream pipeline [[#1](https://github.com/slunghq/slung/issues/1)]            |   ⚠️   |
|  2  | TSM tree [[#2](https://github.com/slunghq/slung/issues/2)]                   |   ✅   |
|  3  | Parallel data query engine [[#3](https://github.com/slunghq/slung/issues/3)] |   📅   |
|  4  | Wasm execution                                                               |   📅   |
|  5  | Write-ahead log (WAL)                                                        |   🚫   |
|  6  | WebTransport                                                                 |   🚫   |

+ ✅ Done: Feature is implemented and verified.
+ ⚠️ In-progress: Active development or stabilization phase.
+ 📅 Planned: Queued for development; architecture defined.
+ 🚫 Deferred: Not currently in scope for the current milestone.

### Stream pipeline
+ [x] Non-blocking websocket channel [[#4](https://github.com/slunghq/slung/issues/4)]
+ [x] Stream rx/tx pool manager [[#5](https://github.com/slunghq/slung/issues/5)]
+ [ ] Multi-threaded networking (config). Note: this is implicitly supported.

### TSM tree
+ [x] Cache (Skip list)
+ [x] Disk entry
+ [x] AMQ Filter (Bloom filter)
+ [x] Encoding (Gorilla/delta)
+ [ ] Multi-level compaction

Optimisation: ReleaseFast. i5-10210U. SAMSUNG MZVLB256HAHQ-000H1:

```
...
ingested 1 billion in 772.57s
write latency per item: 772ns
write speed: 1295336 WPS
peak mem: 575 MiB

--- Storage ---
  Total: 9116360690 bytes (8.49 GB)
  Bytes per point: 9.12

--- Query Benchmark ---
  Querying h-9 range 999000000-999999999 (1M points)
  avg: 49.9944
  Run 1: 168.19ms
  Run 2: 166.62ms
  Run 3: 157.24ms
  Run 4: 158.76ms
  Run 5: 159.87ms
...
```

### Parallel query engine
+ [ ] Query DSL [[#6](https://github.com/slunghq/slung/issues/6)]
+ [ ] Async iterator [[#7](https://github.com/slunghq/slung/issues/7)]

### Wasm execution
+ [ ] Host functions template
+ [ ] Life cycle manager
