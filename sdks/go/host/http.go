package host

import (
	"encoding/binary"
	"fmt"
	"runtime"
	"unsafe"
)

// Header is an HTTP header name/value pair.
type Header struct {
	Name  string
	Value string
}

// Response is an outbound HTTP response.
type Response struct {
	Status  uint16
	Headers []Header
	Body    []byte
}

//go:wasmimport env slung_http_get
func abiHTTPGet(urlPtr, urlLen, requestHeadersPtr, requestHeadersLen, responsePtr, responseLen, responseHeadersPtr, responseHeadersLen uint32) uint32

//go:wasmimport env slung_http_post
func abiHTTPPost(urlPtr, urlLen, requestHeadersPtr, requestHeadersLen, bodyPtr, bodyLen, responsePtr, responseLen, responseHeadersPtr, responseHeadersLen uint32) uint32

//go:wasmimport env slung_http_put
func abiHTTPPut(urlPtr, urlLen, requestHeadersPtr, requestHeadersLen, bodyPtr, bodyLen, responsePtr, responseLen, responseHeadersPtr, responseHeadersLen uint32) uint32

//go:wasmimport env slung_http_delete
func abiHTTPDelete(urlPtr, urlLen, requestHeadersPtr, requestHeadersLen, responsePtr, responseLen, responseHeadersPtr, responseHeadersLen uint32) uint32

// HTTPGet performs an outbound HTTP GET request.
func HTTPGet(url string, headers ...Header) (Response, error) {
	encoded, err := encodeHeaders(headers)
	if err != nil {
		return Response{}, err
	}
	var response responseBuffers
	status := abiHTTPGet(
		stringPointer(url), uint32(len(url)), pointer(encoded), uint32(len(encoded)),
		pointerOf(&response.bodyPtr), pointerOf(&response.bodyLen),
		pointerOf(&response.headersPtr), pointerOf(&response.headersLen),
	)
	runtime.KeepAlive(url)
	runtime.KeepAlive(encoded)
	return response.result(status)
}

// HTTPPost performs an outbound HTTP POST request.
func HTTPPost(url string, body []byte, headers ...Header) (Response, error) {
	return httpBodyRequest(url, body, headers, false)
}

// HTTPPut performs an outbound HTTP PUT request.
func HTTPPut(url string, body []byte, headers ...Header) (Response, error) {
	return httpBodyRequest(url, body, headers, true)
}

// HTTPDelete performs an outbound HTTP DELETE request.
func HTTPDelete(url string, headers ...Header) (Response, error) {
	encoded, err := encodeHeaders(headers)
	if err != nil {
		return Response{}, err
	}
	var response responseBuffers
	status := abiHTTPDelete(
		stringPointer(url), uint32(len(url)), pointer(encoded), uint32(len(encoded)),
		pointerOf(&response.bodyPtr), pointerOf(&response.bodyLen),
		pointerOf(&response.headersPtr), pointerOf(&response.headersLen),
	)
	runtime.KeepAlive(url)
	runtime.KeepAlive(encoded)
	return response.result(status)
}

func httpBodyRequest(url string, body []byte, headers []Header, put bool) (Response, error) {
	encoded, err := encodeHeaders(headers)
	if err != nil {
		return Response{}, err
	}
	var response responseBuffers
	urlPtr, urlLen := stringPointer(url), uint32(len(url))
	headersPtr, headersLen := pointer(encoded), uint32(len(encoded))
	bodyPtr, bodyLen := pointer(body), uint32(len(body))
	var status uint32
	if put {
		status = abiHTTPPut(
			urlPtr, urlLen, headersPtr, headersLen, bodyPtr, bodyLen,
			pointerOf(&response.bodyPtr), pointerOf(&response.bodyLen),
			pointerOf(&response.headersPtr), pointerOf(&response.headersLen),
		)
	} else {
		status = abiHTTPPost(
			urlPtr, urlLen, headersPtr, headersLen, bodyPtr, bodyLen,
			pointerOf(&response.bodyPtr), pointerOf(&response.bodyLen),
			pointerOf(&response.headersPtr), pointerOf(&response.headersLen),
		)
	}
	runtime.KeepAlive(url)
	runtime.KeepAlive(encoded)
	runtime.KeepAlive(body)
	return response.result(status)
}

type responseBuffers struct {
	bodyPtr    uint32
	bodyLen    uint32
	headersPtr uint32
	headersLen uint32
}

func (r responseBuffers) result(status uint32) (Response, error) {
	if status == 0 {
		return Response{}, fmt.Errorf("HTTP request failed before receiving a response")
	}
	body := copyAndFree(r.bodyPtr, r.bodyLen)
	headers, err := decodeHeaders(r.headersPtr, r.headersLen)
	if err != nil {
		return Response{}, err
	}
	return Response{Status: uint16(status), Headers: headers, Body: body}, nil
}

func encodeHeaders(headers []Header) ([]byte, error) {
	var encoded []byte
	for _, header := range headers {
		if uint64(len(header.Name)) > uint64(^uint32(0)) || uint64(len(header.Value)) > uint64(^uint32(0)) {
			return nil, fmt.Errorf("HTTP header is too long")
		}
		var lengths [8]byte
		binary.LittleEndian.PutUint32(lengths[0:4], uint32(len(header.Name)))
		binary.LittleEndian.PutUint32(lengths[4:8], uint32(len(header.Value)))
		encoded = append(encoded, lengths[:]...)
		encoded = append(encoded, header.Name...)
		encoded = append(encoded, header.Value...)
	}
	return encoded, nil
}

func decodeHeaders(ptr, length uint32) ([]Header, error) {
	if ptr == 0 || length == 0 {
		return nil, nil
	}
	bytes := unsafe.Slice((*byte)(unsafe.Pointer(uintptr(ptr))), int(length))
	defer SlungDealloc(ptr, length)
	var headers []Header
	for cursor := 0; cursor < len(bytes); {
		if len(bytes)-cursor < 8 {
			return nil, fmt.Errorf("invalid HTTP response headers")
		}
		nameLen := int(binary.LittleEndian.Uint32(bytes[cursor : cursor+4]))
		valueLen := int(binary.LittleEndian.Uint32(bytes[cursor+4 : cursor+8]))
		cursor += 8
		nameEnd := cursor + nameLen
		valueEnd := nameEnd + valueLen
		if nameEnd < cursor || valueEnd < nameEnd || valueEnd > len(bytes) {
			return nil, fmt.Errorf("invalid HTTP response headers")
		}
		headers = append(headers, Header{
			Name:  string(bytes[cursor:nameEnd]),
			Value: string(bytes[nameEnd:valueEnd]),
		})
		cursor = valueEnd
	}
	return headers, nil
}

func stringPointer(value string) uint32 {
	if len(value) == 0 {
		return 0
	}
	return uint32(uintptr(unsafe.Pointer(unsafe.StringData(value))))
}
