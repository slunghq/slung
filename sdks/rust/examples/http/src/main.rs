use slung::host::http;
use slung::prelude::*;
use slung_macros::{component, rule, source};

#[derive(serde::Deserialize)]
struct Trigger {
    request_id: String,
}

#[component]
struct HttpTrigger {
    request_id: String,
}

#[source(builtin = "http")]
struct TriggerSource {
    #[config(value = "/api/trigger")]
    endpoint: &'static str,

    #[component(map = parse_trigger)]
    trigger: HttpTrigger,
}

fn parse_trigger(raw: &[u8]) -> Result<HttpTrigger> {
    let trigger: Trigger = serde_json::from_slice(raw)?;
    Ok(HttpTrigger {
        request_id: trigger.request_id,
    })
}

#[rule(watch = [TriggerSource::trigger], priority = 10)]
fn send_http_requests(ctx: &RuleContext) -> Result<()> {
    let trigger = ctx.get::<HttpTrigger>(TriggerSource::trigger)?;

    let get_response = http::get(
        "http://127.0.0.1:2080/get",
        &[("X-Request-ID", trigger.request_id.as_str())],
    )?;
    if get_response.status != 200
        || get_response.body != b"get-ok"
        || !has_test_header(&get_response)
    {
        return Err(std::io::Error::other("unexpected GET response"));
    }

    let body = format!("{{\"request_id\":\"{}\"}}", trigger.request_id);
    let post_response = http::post(
        "http://127.0.0.1:2080/post",
        body.as_bytes(),
        &[("Content-Type", "application/json")],
    )?;
    if post_response.status != 201
        || post_response.body != b"post-ok"
        || !has_test_header(&post_response)
    {
        return Err(std::io::Error::other("unexpected POST response"));
    }

    let put_response = http::put(
        "http://127.0.0.1:2080/put",
        b"put-body",
        &[("X-Request-ID", trigger.request_id.as_str())],
    )?;
    if put_response.status != 202
        || put_response.body != b"put-ok"
        || !has_test_header(&put_response)
    {
        return Err(std::io::Error::other("unexpected PUT response"));
    }

    let delete_response = http::delete(
        "http://127.0.0.1:2080/delete",
        &[("X-Request-ID", trigger.request_id.as_str())],
    )?;
    if delete_response.status != 204
        || !delete_response.body.is_empty()
        || !has_test_header(&delete_response)
    {
        return Err(std::io::Error::other("unexpected DELETE response"));
    }

    eprintln!("HTTP requests completed: {}", trigger.request_id);
    Ok(())
}

fn has_test_header(response: &http::Response) -> bool {
    response
        .headers
        .iter()
        .any(|(name, value)| name.eq_ignore_ascii_case("x-test-result") && value == "passed")
}

fn main() {}
