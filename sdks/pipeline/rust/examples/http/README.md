# Outbound HTTP Example

This example tests outbound HTTP from a Slung pipeline module.

The Rust module exposes an inbound HTTP source at `/api/trigger`. When it receives a trigger, its rule sends four requests to the local test server:

+ `GET /get`
+ `POST /post` with a JSON request ID
+ `PUT /put` with `put-body`
+ `DELETE /delete`

The Go test server records the requests and verifies their methods, paths, and bodies.

## Run

From the Slung repository root:

```sh
sh sdks/pipeline/rust/examples/http/test.sh
```

The script builds the module, starts the Go test server on port `2080`, starts Slung's development runtime on port `22074`, triggers the module, and verifies the received requests.
