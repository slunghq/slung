# Outbound HTTP Example

This example tests outbound HTTP from a Slung pipeline module.

The Rust module exposes an inbound HTTP source at `/api/trigger`. When it receives a trigger, its rule sends four requests to the local Rust test server:

+ `GET /get` with an `X-Request-ID` header
+ `POST /post` with a JSON request ID and `Content-Type` header
+ `PUT /put` with `put-body` and an `X-Request-ID` header
+ `DELETE /delete` with an `X-Request-ID` header

The test server records the requests and verifies their methods, paths, bodies, request headers, response status codes, and response headers.

## Run

From the Slung repository root:

```sh
sh sdks/pipeline/rust/examples/http/test.sh
```

The script builds the module, starts the Rust test server on port `2080`, starts Slung's development runtime with its HTTP webhook on port `2074`, triggers the module at `/http_test/api/trigger`, and waits for the test server to verify all four requests.
