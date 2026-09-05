use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

const ADDRESS: &str = "127.0.0.1:2080";

struct ReceivedRequest {
    body: Vec<u8>,
    request_id: Option<String>,
    content_type: Option<String>,
}

type Received = Arc<Mutex<HashMap<String, ReceivedRequest>>>;

fn main() -> std::io::Result<()> {
    let listener = TcpListener::bind(ADDRESS)?;
    let received: Received = Arc::new(Mutex::new(HashMap::new()));

    println!("HTTP test server listening on http://{ADDRESS}");
    for stream in listener.incoming() {
        let stream = stream?;
        let received = Arc::clone(&received);
        thread::spawn(move || {
            if let Err(error) = handle_connection(stream, received) {
                eprintln!("test server request failed: {error}");
            }
        });
    }

    Ok(())
}

fn handle_connection(mut stream: TcpStream, received: Received) -> std::io::Result<()> {
    let request = read_request(&mut stream)?;
    let mut lines = request.splitn(2, "\r\n");
    let request_line = lines.next().unwrap_or_default();
    let rest = lines.next().unwrap_or_default();
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts.next().unwrap_or_default();
    let path = request_parts.next().unwrap_or_default();

    if path == "/health" {
        return respond(&mut stream, 200, "OK", b"ok", None);
    }

    if path == "/verify" {
        return verify(&mut stream, received);
    }

    let expected_method = match path {
        "/get" => "GET",
        "/post" => "POST",
        "/put" => "PUT",
        "/delete" => "DELETE",
        _ => return respond(&mut stream, 404, "Not Found", b"unknown path", None),
    };

    if method != expected_method {
        return respond(
            &mut stream,
            405,
            "Method Not Allowed",
            b"unexpected method",
            None,
        );
    }

    let body = request_body(rest).to_vec();
    let request_headers = rest.as_bytes();
    received.lock().unwrap().insert(
        path.to_string(),
        ReceivedRequest {
            body,
            request_id: header_value(request_headers, "x-request-id").map(str::to_owned),
            content_type: header_value(request_headers, "content-type").map(str::to_owned),
        },
    );

    let (status, reason, response) = match path {
        "/get" => (200, "OK", b"get-ok".as_slice()),
        "/post" => (201, "Created", b"post-ok".as_slice()),
        "/put" => (202, "Accepted", b"put-ok".as_slice()),
        "/delete" => (204, "No Content", b"".as_slice()),
        _ => unreachable!(),
    };
    respond(
        &mut stream,
        status,
        reason,
        response,
        Some("X-Test-Result: passed"),
    )
}

fn read_request(stream: &mut TcpStream) -> std::io::Result<String> {
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 4096];
    loop {
        let read = stream.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        bytes.extend_from_slice(&buffer[..read]);

        if let Some(header_end) = find_bytes(&bytes, b"\r\n\r\n") {
            let content_length = header_value(&bytes[..header_end], "content-length")
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(0);
            let body_start = header_end + 4;
            if bytes.len() >= body_start + content_length {
                break;
            }
        }
    }

    String::from_utf8(bytes)
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "request was not UTF-8"))
}

fn request_body(headers_and_request: &str) -> &[u8] {
    headers_and_request
        .split_once("\r\n\r\n")
        .map(|(_, body)| body.as_bytes())
        .unwrap_or_default()
}

fn header_value<'a>(headers: &'a [u8], name: &str) -> Option<&'a str> {
    headers
        .split(|byte| *byte == b'\n')
        .filter_map(|line| std::str::from_utf8(line).ok())
        .find_map(|line| {
            let (key, value) = line.trim_end_matches('\r').split_once(':')?;
            key.eq_ignore_ascii_case(name).then_some(value.trim())
        })
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn verify(stream: &mut TcpStream, received: Received) -> std::io::Result<()> {
    let received = received.lock().unwrap();
    let expected = [
        ("/get", b"".as_slice()),
        ("/post", br#"{"request_id":"http-example"}"#.as_slice()),
        ("/put", b"put-body".as_slice()),
        ("/delete", b"".as_slice()),
    ];

    for (path, expected_body) in expected {
        match received.get(path) {
            Some(actual) if actual.body == expected_body => {}
            Some(actual) => {
                let message = format!("invalid body for {path}: {:?}", actual.body);
                return respond(stream, 400, "Bad Request", message.as_bytes(), None);
            }
            None => {
                let message = format!("missing request: {path}");
                return respond(stream, 400, "Bad Request", message.as_bytes(), None);
            }
        }
    }

    let post = received.get("/post").unwrap();
    if post.content_type.as_deref() != Some("application/json") {
        return respond(stream, 400, "Bad Request", b"missing content type", None);
    }
    for path in ["/get", "/put", "/delete"] {
        if received.get(path).unwrap().request_id.as_deref() != Some("http-example") {
            return respond(stream, 400, "Bad Request", b"missing request ID", None);
        }
    }

    respond(stream, 200, "OK", br#"{"ok":true,"requests":4}"#, None)
}

fn respond(
    stream: &mut TcpStream,
    status: u16,
    reason: &str,
    body: &[u8],
    extra_header: Option<&str>,
) -> std::io::Result<()> {
    write!(
        stream,
        "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n",
        body.len()
    )?;
    if let Some(header) = extra_header {
        write!(stream, "{header}\r\n")?;
    }
    write!(stream, "\r\n")?;
    stream.write_all(body)
}
