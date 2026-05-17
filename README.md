<h1>
<p align="center">
  <img src="./docs/assets/logo.png" alt="Logo" width="128">
  <br>Slung
</h1>
  <p align="center">
      Deploy resilient systems without all the complexity.
    <br />
    <a href="https://slung.tech">Homepage</a>
    ·
    <a href="https://slung.tech/docs">Documentation</a>
    ·
    <a href="https://slung.tech/roadmap">Roadmap</a>
    </p>
</p>

Slung is high-performance compute for deploying truly intelligent systems that are resilient and adapt to changes across your data stack. We're building a robust system around [rule engines](https://en.wikipedia.org/wiki/Rule_engine), where attributes and entities are a direct derivation of your data stack. Learn more [here](./docs/ARCHITECTURE.md).

> [!WARNING]
> This project is in alpha and not ready for production use.

## Quickstart (Alpha)

```bash
zig build
zig build run -- run --module src/testdata/e2e_local.wasm --namespace default --node-id node-1 --ws-port 2073
```
