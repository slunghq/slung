package main

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"

	"github.com/slunghq/slung/sdks/go/host"
	"github.com/slunghq/slung/sdks/go/sdk"
)

// wireTrigger is the JSON shape accepted by the HTTP source.
type wireTrigger struct {
	RequestID string `json:"request_id"`
}

// HttpTrigger is the typed component watched by the rule.
type HttpTrigger struct {
	RequestID string `json:"request_id"`
}

func parseTrigger(raw []byte) (HttpTrigger, error) {
	var wire wireTrigger
	if err := json.Unmarshal(raw, &wire); err != nil {
		return HttpTrigger{}, err
	}
	return HttpTrigger{RequestID: wire.RequestID}, nil
}

var TriggerSourceTrigger = sdk.NewComponentKey[HttpTrigger](0, 0)

func sendHTTPRequests(ctx *sdk.RuleContext) error {
	trigger, err := sdk.Get(ctx, TriggerSourceTrigger)
	if err != nil {
		return err
	}

	get, err := host.HTTPGet(
		"http://127.0.0.1:2080/get",
		host.Header{Name: "X-Request-ID", Value: trigger.RequestID},
	)
	if err != nil {
		return err
	}
	if get.Status != 200 || string(get.Body) != "get-ok" || !hasTestHeader(get) {
		return fmt.Errorf("unexpected GET response")
	}

	post, err := host.HTTPPost(
		"http://127.0.0.1:2080/post",
		[]byte(`{"request_id":"`+trigger.RequestID+`"}`),
		host.Header{Name: "Content-Type", Value: "application/json"},
	)
	if err != nil {
		return err
	}
	if post.Status != 201 || string(post.Body) != "post-ok" || !hasTestHeader(post) {
		return fmt.Errorf("unexpected POST response")
	}

	put, err := host.HTTPPut(
		"http://127.0.0.1:2080/put",
		[]byte("put-body"),
		host.Header{Name: "X-Request-ID", Value: trigger.RequestID},
	)
	if err != nil {
		return err
	}
	if put.Status != 202 || string(put.Body) != "put-ok" || !hasTestHeader(put) {
		return fmt.Errorf("unexpected PUT response")
	}

	del, err := host.HTTPDelete(
		"http://127.0.0.1:2080/delete",
		host.Header{Name: "X-Request-ID", Value: trigger.RequestID},
	)
	if err != nil {
		return err
	}
	if del.Status != 204 || len(del.Body) != 0 || !hasTestHeader(del) {
		return fmt.Errorf("unexpected DELETE response")
	}

	log.Printf("HTTP requests completed: %s", trigger.RequestID)
	return nil
}

func hasTestHeader(response host.Response) bool {
	for _, header := range response.Headers {
		if strings.EqualFold(header.Name, "x-test-result") && header.Value == "passed" {
			return true
		}
	}
	return false
}

func main() {}
